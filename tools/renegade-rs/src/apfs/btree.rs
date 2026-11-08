//! B-trees: node parsing, the object map and an in-order cursor with seek.
//!
//! Every block comes through [`Shared::block`] (checksummed, cached); a node is a cheap view over the
//! cached block. A child's level must be below its parent's, so a cyclic or garbage tree
//! cannot loop and the recursion depth is bounded by the root's level (sealed volumes' hashed trees do
//! not number levels one by one, so only a strict decrease is required).

use super::obj::*;
use crate::io::{ReadAt, bad};
use std::cmp::Ordering;
use std::io::Result;
use std::ops::Range;
use std::rc::Rc;

pub(crate) const BT_ROOT: u16 = 0x1;
pub(crate) const BT_LEAF: u16 = 0x2;
pub(crate) const BT_FIXED: u16 = 0x4;
pub(crate) const BT_HASHED: u16 = 0x8;
pub(crate) const BT_NOHEADER: u16 = 0x10;
const MAX_LEVEL: u16 = 24;

pub(crate) struct BNode {
    pub blk: Rc<Vec<u8>>,
    pub level: u16,
    pub n: usize,
    pub flags: u16,
    toc: usize,
    key_base: usize,
    val_end: usize,
    fixed: Option<(usize, usize)>,
}

impl BNode {
    fn parse(blk: Rc<Vec<u8>>, fixed: Option<(usize, usize)>) -> Result<BNode> {
        let flags = le16(&blk, 32)?;
        let level = le16(&blk, 34)?;
        let n = le32(&blk, 36)? as usize;
        let toff = le16(&blk, 40)? as usize;
        let tlen = le16(&blk, 42)? as usize;
        let toc = 56 + toff;
        let key_base = toc + tlen;
        let esz = if flags & BT_FIXED != 0 { 4 } else { 8 };
        let val_end = if flags & BT_ROOT != 0 { blk.len().saturating_sub(40) } else { blk.len() };
        if n.checked_mul(esz).is_none_or(|t| t > tlen) || key_base > val_end {
            return Err(bad("B-tree node: table of contents out of range"));
        }
        if flags & BT_FIXED != 0 && fixed.is_none() {
            return Err(bad("B-tree: fixed-size node without tree info"));
        }
        Ok(BNode { blk, level, n, flags, toc, key_base, val_end, fixed })
    }

    pub fn is_leaf(&self) -> bool {
        self.flags & BT_LEAF != 0
    }

    /// Byte ranges (into the block) of entry `i`'s key and value.
    pub fn entry(&self, i: usize) -> Result<(Range<usize>, Range<usize>)> {
        if i >= self.n {
            return Err(bad("B-tree entry index out of range"));
        }
        let (ko, kl, vo, vl);
        if self.flags & BT_FIXED != 0 {
            let (ks, vs) = self.fixed.unwrap_or((0, 0));
            ko = le16(&self.blk, self.toc + 4 * i)? as usize;
            vo = le16(&self.blk, self.toc + 4 * i + 2)? as usize;
            kl = ks;
            vl = if self.is_leaf() { vs } else { 8 };
        } else {
            ko = le16(&self.blk, self.toc + 8 * i)? as usize;
            kl = le16(&self.blk, self.toc + 8 * i + 2)? as usize;
            vo = le16(&self.blk, self.toc + 8 * i + 4)? as usize;
            vl = le16(&self.blk, self.toc + 8 * i + 6)? as usize;
        }
        let ks = self.key_base + ko;
        let key = ks..ks + kl;
        let val = if vo == 0xffff || vl == 0 {
            0..0
        } else {
            let vs = self.val_end.checked_sub(vo).ok_or_else(|| bad("B-tree value offset out of range"))?;
            vs..vs + vl
        };
        if key.end > self.blk.len() || val.end > self.blk.len() {
            return Err(bad("B-tree entry out of range"));
        }
        Ok((key, val))
    }

    pub fn key(&self, i: usize) -> Result<&[u8]> {
        let (k, _) = self.entry(i)?;
        Ok(&self.blk[k])
    }

    /// The child object id of index entry `i`.
    pub fn child(&self, i: usize) -> Result<u64> {
        let (_, v) = self.entry(i)?;
        le64(&self.blk[v], 0)
    }
}

#[derive(Clone, Copy)]
pub(crate) struct OmapVal {
    pub flags: u32,
    pub paddr: u64,
}

const OMAP_VAL_DELETED: u32 = 1;
const OMAP_VAL_ENCRYPTED: u32 = 4;
const OMAP_VAL_NOHEADER: u32 = 8;

/// An object map (virtual oid, xid -> physical address) as of one transaction.
#[derive(Clone, Copy)]
pub(crate) struct Omap {
    pub tree: u64,
    pub xid: u64,
}

impl Omap {
    pub fn open<R: ReadAt>(sh: &Shared<R>, omap_oid: u64, xid: u64) -> Result<Omap> {
        let blk = sh.block(omap_oid)?;
        if hdr_type(&blk)? & TYPE_MASK != T_OMAP {
            return Err(bad(format!("block {omap_oid} is not an object map")));
        }
        Ok(Omap { tree: le64(&blk, 48)?, xid })
    }

    /// The newest mapping of `oid` at or before this map's transaction.
    pub fn lookup<R: ReadAt>(&self, sh: &Shared<R>, oid: u64) -> Result<Option<OmapVal>> {
        let tree = Tree::open(sh, Space::Phys, self.tree)?;
        let mut node = tree.root.clone();
        loop {
            // last entry with (oid, xid) <= (target oid, self.xid)
            let (mut lo, mut hi) = (0usize, node.n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                let k = node.key(mid)?;
                let ord = (le64(k, 0)?, le64(k, 8)?).cmp(&(oid, self.xid));
                if ord != Ordering::Greater {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if lo == 0 {
                return Ok(None);
            }
            let i = lo - 1;
            if node.is_leaf() {
                let (k, v) = node.entry(i)?;
                if le64(&node.blk[k], 0)? != oid {
                    return Ok(None);
                }
                let v = &node.blk[v];
                let val = OmapVal { flags: le32(v, 0)?, paddr: le64(v, 8)? };
                if val.flags & OMAP_VAL_DELETED != 0 {
                    return Ok(None);
                }
                if val.flags & OMAP_VAL_ENCRYPTED != 0 {
                    return Err(bad("object map entry is encrypted (not supported)"));
                }
                return Ok(Some(val));
            }
            node = tree.load_child(&node, node.child(i)?)?;
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) enum Space<'a> {
    /// Child pointers are physical block addresses.
    Phys,
    /// Child pointers are virtual oids resolved through this object map.
    Virt(&'a Omap),
}

pub(crate) struct Tree<'a, R> {
    pub sh: &'a Shared<R>,
    space: Space<'a>,
    pub root: Rc<BNode>,
    root_ref: u64,
    fixed: Option<(usize, usize)>,
}

impl<'a, R: ReadAt> Tree<'a, R> {
    /// `root_ref` is a physical address or, in a virtual space, the root's virtual oid.
    pub fn open(sh: &'a Shared<R>, space: Space<'a>, root_ref: u64) -> Result<Self> {
        let blk = fetch(sh, space, root_ref)?;
        let flags = le16(&blk, 32)?;
        let fixed = if flags & BT_FIXED != 0 {
            if flags & BT_ROOT == 0 {
                return Err(bad("B-tree root node lacks the root flag"));
            }
            let info = blk.len().checked_sub(40).ok_or_else(|| bad("B-tree root too small"))?;
            Some((le32(&blk, info + 8)? as usize, le32(&blk, info + 12)? as usize))
        } else {
            None
        };
        let root = Rc::new(BNode::parse(blk, fixed)?);
        if root.level > MAX_LEVEL {
            return Err(bad("B-tree is implausibly deep"));
        }
        Ok(Tree { sh, space, root, root_ref, fixed })
    }

    fn load_child(&self, parent: &BNode, oid: u64) -> Result<Rc<BNode>> {
        // sealed volumes: a hashed index node's child pointer is relative to the tree's root oid
        let oid =
            if parent.flags & BT_HASHED != 0 { self.root_ref.checked_add(oid).ok_or_else(|| bad("child oid overflows"))? } else { oid };
        let blk = fetch(self.sh, self.space, oid)?;
        let n = BNode::parse(blk, self.fixed)?;
        if n.level >= parent.level {
            return Err(bad("B-tree child level does not drop below its parent's (corrupt or cyclic tree)"));
        }
        Ok(Rc::new(n))
    }
}

fn fetch<R: ReadAt>(sh: &Shared<R>, space: Space<'_>, oid: u64) -> Result<Rc<Vec<u8>>> {
    let (paddr, noheader) = match space {
        Space::Phys => (oid, false),
        Space::Virt(om) => {
            let v = om.lookup(sh, oid)?.ok_or_else(|| bad(format!("virtual object {oid:#x} is not in the object map")))?;
            (v.paddr, v.flags & OMAP_VAL_NOHEADER != 0)
        }
    };
    if noheader {
        // sealed volumes: the node has no object header and no checksum (its parent holds a hash)
        let blk = sh.block_unchecked(paddr)?;
        if le16(&blk, 32)? & BT_NOHEADER == 0 {
            return Err(bad(format!("block {paddr}: object map says no header, node flags disagree")));
        }
        return Ok(blk);
    }
    let blk = sh.block(paddr)?;
    let t = hdr_type(&blk)?;
    if t & TYPE_MASK != T_BTREE && t & TYPE_MASK != T_BTREE_NODE {
        return Err(bad(format!("block {paddr} is not a B-tree node (type {t:#x})")));
    }
    if t & OBJ_ENCRYPTED != 0 {
        return Err(bad("B-tree node is encrypted (not supported)"));
    }
    if matches!(space, Space::Virt(_)) && hdr_oid(&blk)? != oid {
        return Err(bad(format!("B-tree node {paddr}: object id {:#x}, expected {oid:#x}", hdr_oid(&blk)?)));
    }
    Ok(blk)
}

/// A record handed out by a cursor: a view into its node's block.
pub(crate) struct Rec {
    node: Rc<BNode>,
    k: Range<usize>,
    v: Range<usize>,
}

impl Rec {
    pub fn key(&self) -> &[u8] {
        &self.node.blk[self.k.clone()]
    }
    pub fn val(&self) -> &[u8] {
        &self.node.blk[self.v.clone()]
    }
}

/// In-order iteration. Each stack entry is a node and the next entry to visit in it.
pub(crate) struct Cursor<'t, 'a, R> {
    t: &'t Tree<'a, R>,
    stack: Vec<(Rc<BNode>, usize)>,
}

impl<'t, 'a, R: ReadAt> Cursor<'t, 'a, R> {
    pub fn first(t: &'t Tree<'a, R>) -> Self {
        Cursor { t, stack: vec![(t.root.clone(), 0)] }
    }

    /// Positioned at the first record whose key does not compare `Less` (`cmp(key)` is the key's order
    /// against the sought one).
    pub fn seek(t: &'t Tree<'a, R>, cmp: &dyn Fn(&[u8]) -> Ordering) -> Result<Self> {
        let mut stack = Vec::new();
        let mut node = t.root.clone();
        loop {
            let (mut lo, mut hi) = (0usize, node.n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                if cmp(node.key(mid)?) == Ordering::Less {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if node.is_leaf() {
                stack.push((node, lo));
                break;
            }
            // the child that can hold the first key >= target is the last one starting below it
            let c = lo.saturating_sub(1);
            if node.n == 0 {
                stack.push((node, 0));
                break;
            }
            let child = t.load_child(&node, node.child(c)?)?;
            stack.push((node, c + 1));
            node = child;
        }
        Ok(Cursor { t, stack })
    }

    pub fn next(&mut self) -> Result<Option<Rec>> {
        loop {
            let Some((node, idx)) = self.stack.last_mut() else { return Ok(None) };
            if *idx >= node.n {
                self.stack.pop();
                continue;
            }
            let i = *idx;
            *idx += 1;
            if node.is_leaf() {
                let (k, v) = node.entry(i)?;
                return Ok(Some(Rec { node: node.clone(), k, v }));
            }
            let parent = node.clone();
            let child = self.t.load_child(&parent, parent.child(i)?)?;
            self.stack.push((child, 0));
        }
    }
}
