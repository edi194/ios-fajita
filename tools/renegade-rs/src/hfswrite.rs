//! HFSX writer: a case-sensitive, unjournaled HFS+ volume built from a file tree, without newfs_hfs, a mount
//! or ditto, so the root can be built where none of those exist (Linux without root, the browser).
//!
//! What Renegade's Python root build gets from `newfs_hfs -s` + `ditto` + `hfsroot_owners.py`, this writes in one
//! pass: folders, files, symlinks and macOS-style hard links (an `iNode<N>` file in the private directory, link
//! records with the link chain in their owner/group fields, as xnu writes them), real owners and modes, folder
//! counts. No extended attributes (the IPSW root carries none that iOS needs; the only ones in a ditto-built
//! root are the Mac's com.apple.provenance), no resource forks, no compression, one extent per file.
//! Checked with fsck_hfs, by mounting on macOS and by reading it back (tests/hfswrite.rs).

use crate::io::{bad, WriteAt};
use std::collections::{BTreeMap, HashMap};
use std::io::Result;
use unicode_normalization::UnicodeNormalization;

/// Seconds between 1904-01-01 (HFS) and 1970-01-01 (Unix).
pub const HFS_EPOCH_OFFSET: u32 = 2_082_844_800;
const FIRST_USER_CNID: u32 = 16;
const CAT_NODE: usize = 8192;
const EXT_NODE: usize = 4096;
const ATTR_NODE: usize = 8192;
pub const PRIVATE_DIR: &str = "\0\0\0\0HFS+ Private Data";
const PRIVATE_DIR_DIRS: &str = ".HFS+ Private Directory Data\r";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    Dir,
    /// `source`: the caller's handle for the data, `len`: its size.
    File { len: u64, source: usize },
    Symlink { target: String },
}

/// One entry of the tree. `path` is relative ("usr/lib/dyld"); "" is the root folder.
#[derive(Debug, Clone)]
pub struct Entry {
    pub path: String,
    pub kind: Kind,
    pub uid: u32,
    pub gid: u32,
    /// Permission bits (07777); the type bits come from `kind`.
    pub perm: u16,
    /// Unix seconds.
    pub mtime: u32,
    /// Files that share a `link_group` are hard links of one another (one iNode, N link records).
    pub link_group: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct Options {
    pub volume_name: String,
    pub block_size: u32,
    /// Image size in bytes; `None`: just big enough (used blocks plus 1/16, at least 1 MiB free).
    pub size: Option<u64>,
    /// Unix seconds for the volume dates (reproducible images).
    pub date: u32,
    /// Where each file's data lies in the image, by file `source`: smaller first (default: path order). The
    /// root build uses the source image's own order so that it reads it front to back.
    pub data_order: Option<Vec<u64>>,
}

impl Default for Options {
    fn default() -> Self {
        Self { volume_name: "iOSRoot".into(), block_size: 4096, size: None, date: 0, data_order: None }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stats {
    pub folders: u32,
    pub files: u32,
    pub hard_links: u32,
    pub inodes: u32,
    pub total_blocks: u32,
    pub free_blocks: u32,
    pub catalog_nodes: u32,
}

/// The file name as HFS+ stores it: canonical decomposition, except the ranges HFS+ leaves composed
/// (U+2000-U+2FFF, U+F900-U+FAFF, U+2F800-U+2FAFF), as UTF-16.
pub fn hfs_name(name: &str) -> Vec<u16> {
    let mut s = String::new();
    for c in name.chars() {
        let u = c as u32;
        if (0x2000..=0x2FFF).contains(&u) || (0xF900..=0xFAFF).contains(&u) || (0x2F800..=0x2FAFF).contains(&u) {
            s.push(c);
        } else {
            s.extend(std::iter::once(c).nfd());
        }
    }
    // POSIX ':' is '/' in the catalog (the colon/slash swap of the HFS+ kernel layer: what ditto onto a mounted HFS+ writes)
    s.encode_utf16().map(|c| if c == b':' as u16 { b'/' as u16 } else { c }).collect()
}

/// One catalog record: key (parent, name) and data.
struct Rec {
    parent: u32,
    name: Vec<u16>,
    data: Vec<u8>,
}

fn key_bytes(parent: u32, name: &[u16]) -> Vec<u8> {
    let mut k = Vec::with_capacity(8 + 2 * name.len());
    k.extend_from_slice(&((6 + 2 * name.len()) as u16).to_be_bytes());
    k.extend_from_slice(&parent.to_be_bytes());
    k.extend_from_slice(&(name.len() as u16).to_be_bytes());
    for u in name {
        k.extend_from_slice(&u.to_be_bytes());
    }
    k
}

fn be16(v: &mut Vec<u8>, x: u16) {
    v.extend_from_slice(&x.to_be_bytes());
}
fn be32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_be_bytes());
}
fn put32(b: &mut [u8], o: usize, x: u32) {
    b[o..o + 4].copy_from_slice(&x.to_be_bytes());
}
fn put16(b: &mut [u8], o: usize, x: u16) {
    b[o..o + 2].copy_from_slice(&x.to_be_bytes());
}
fn put64(b: &mut [u8], o: usize, x: u64) {
    b[o..o + 8].copy_from_slice(&x.to_be_bytes());
}

struct Perm {
    uid: u32,
    gid: u32,
    owner_flags: u8,
    mode: u16,
    special: u32,
}

fn perm_bytes(v: &mut Vec<u8>, p: &Perm) {
    be32(v, p.uid);
    be32(v, p.gid);
    v.push(0);
    v.push(p.owner_flags);
    be16(v, p.mode);
    be32(v, p.special);
}

/// `finder`: the 16 bytes of FolderInfo (Finder flags and location).
fn folder_rec(flags: u16, valence: u32, cnid: u32, date: u32, p: &Perm, finder: [u8; 16], folder_count: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity(88);
    be16(&mut v, 1);
    be16(&mut v, flags);
    be32(&mut v, valence);
    be32(&mut v, cnid);
    for _ in 0..4 {
        be32(&mut v, date);
    }
    be32(&mut v, 0); // backup date
    perm_bytes(&mut v, p);
    v.extend_from_slice(&finder);
    v.extend_from_slice(&[0; 16]);
    be32(&mut v, 0); // text encoding
    be32(&mut v, folder_count);
    debug_assert_eq!(v.len(), 88);
    v
}

/// `first_link`: for an iNode file, the CNID of the first link of its chain (xnu keeps it in reserved1).
#[allow(clippy::too_many_arguments)]
fn file_rec(flags: u16, cnid: u32, date: u32, p: &Perm, finfo: [u8; 16], text_encoding: u32, data: (u64, u32, u32), first_link: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity(248);
    be16(&mut v, 2);
    be16(&mut v, flags);
    be32(&mut v, first_link);
    be32(&mut v, cnid);
    for _ in 0..4 {
        be32(&mut v, date);
    }
    be32(&mut v, 0);
    perm_bytes(&mut v, p);
    v.extend_from_slice(&finfo);
    v.extend_from_slice(&[0; 16]);
    be32(&mut v, text_encoding);
    be32(&mut v, 0);
    let (len, start, count) = data;
    let mut fork = [0u8; 80];
    put64(&mut fork, 0, len);
    put32(&mut fork, 12, count);
    if count > 0 {
        put32(&mut fork, 16, start);
        put32(&mut fork, 20, count);
    }
    v.extend_from_slice(&fork);
    v.extend_from_slice(&[0; 80]);
    debug_assert_eq!(v.len(), 248);
    v
}

fn thread_rec(kind: u16, parent: u32, name: &[u16]) -> Vec<u8> {
    let mut v = Vec::with_capacity(10 + 2 * name.len());
    be16(&mut v, kind);
    be16(&mut v, 0);
    be32(&mut v, parent);
    be16(&mut v, name.len() as u16);
    for u in name {
        be16(&mut v, *u);
    }
    v
}

/// A B-tree file image: header node, then leaf nodes, then index levels.
struct BTree {
    nodes: Vec<Vec<u8>>,
}

fn node(ns: usize, flink: u32, blink: u32, kind: i8, height: u8, recs: &[Vec<u8>]) -> Vec<u8> {
    let mut n = vec![0u8; ns];
    put32(&mut n, 0, flink);
    put32(&mut n, 4, blink);
    n[8] = kind as u8;
    n[9] = height;
    put16(&mut n, 10, recs.len() as u16);
    let mut off = 14;
    for (i, r) in recs.iter().enumerate() {
        n[off..off + r.len()].copy_from_slice(r);
        put16(&mut n, ns - 2 * (i + 1), off as u16);
        off += r.len();
    }
    put16(&mut n, ns - 2 * (recs.len() + 1), off as u16);
    n
}

#[allow(clippy::too_many_arguments)]
fn header_node(ns: usize, depth: u16, root: u32, leaf_records: u32, first_leaf: u32, last_leaf: u32, max_key: u16, total: u32, used: u32, clump: u32, compare: u8, attrs: u32) -> Result<Vec<u8>> {
    let mut h = Vec::with_capacity(106);
    be16(&mut h, depth);
    be32(&mut h, root);
    be32(&mut h, leaf_records);
    be32(&mut h, first_leaf);
    be32(&mut h, last_leaf);
    be16(&mut h, ns as u16);
    be16(&mut h, max_key);
    be32(&mut h, total);
    be32(&mut h, total - used);
    be16(&mut h, 0);
    be32(&mut h, clump);
    h.push(0); // btreeType: HFS
    h.push(compare);
    be32(&mut h, attrs);
    h.extend_from_slice(&[0; 64]);
    let map_len = ns - 256;
    if used as usize > map_len * 8 {
        return Err(bad("B-tree needs map nodes (more than the header map covers): not supported yet"));
    }
    let mut map = vec![0u8; map_len];
    for i in 0..used as usize {
        map[i / 8] |= 0x80 >> (i % 8);
    }
    Ok(node(ns, 0, 0, 1, 0, &[h, vec![0; 128], map]))
}

impl BTree {
    /// Packs sorted (key, data) leaf records into nodes and builds the index levels above them.
    fn build(ns: usize, recs: &[(Vec<u8>, Vec<u8>)], max_key: u16, compare: u8, attrs: u32, min_nodes: u32) -> Result<(Self, u32)> {
        let mut nodes: Vec<Vec<u8>> = vec![Vec::new()]; // node 0: header, filled last
        let mut leaves: Vec<(u32, Vec<u8>)> = Vec::new(); // (node number, first key)
        let mut cur: Vec<Vec<u8>> = Vec::new();
        let mut cur_first: Option<Vec<u8>> = None;
        let mut used = 14 + 2; // descriptor + free-space offset
        let mut pending: Vec<(Vec<Vec<u8>>, Vec<u8>)> = Vec::new();
        for (k, d) in recs {
            let mut r = k.clone();
            r.extend_from_slice(d);
            if r.len() % 2 == 1 {
                r.push(0);
            }
            if used + r.len() + 2 > ns && !cur.is_empty() {
                pending.push((std::mem::take(&mut cur), cur_first.take().unwrap()));
                used = 16;
            }
            if cur.is_empty() {
                cur_first = Some(k.clone());
            }
            used += r.len() + 2;
            cur.push(r);
        }
        if !cur.is_empty() {
            pending.push((cur, cur_first.take().unwrap()));
        }
        let nleaves = pending.len() as u32;
        for (i, (rs, first)) in pending.iter().enumerate() {
            let no = 1 + i as u32;
            let flink = if i + 1 < pending.len() { no + 1 } else { 0 };
            let blink = if i > 0 { no - 1 } else { 0 };
            nodes.push(node(ns, flink, blink, -1, 1, rs));
            leaves.push((no, first.clone()));
        }
        // index levels: records are (key, child node)
        let mut level = leaves;
        let mut height = 1u8;
        while level.len() > 1 {
            height += 1;
            let mut next: Vec<(u32, Vec<u8>)> = Vec::new();
            let mut cur: Vec<Vec<u8>> = Vec::new();
            let mut first: Option<Vec<u8>> = None;
            let mut used = 16;
            let mut groups: Vec<(Vec<Vec<u8>>, Vec<u8>)> = Vec::new();
            for (child, key) in &level {
                let mut r = key.clone();
                r.extend_from_slice(&child.to_be_bytes());
                if used + r.len() + 2 > ns && !cur.is_empty() {
                    groups.push((std::mem::take(&mut cur), first.take().unwrap()));
                    used = 16;
                }
                if cur.is_empty() {
                    first = Some(key.clone());
                }
                used += r.len() + 2;
                cur.push(r);
            }
            groups.push((cur, first.unwrap()));
            let base = nodes.len() as u32;
            for (i, (rs, fk)) in groups.iter().enumerate() {
                let no = base + i as u32;
                let flink = if i + 1 < groups.len() { no + 1 } else { 0 };
                let blink = if i > 0 { no - 1 } else { 0 };
                nodes.push(node(ns, flink, blink, 0, height, rs));
                next.push((no, fk.clone()));
            }
            level = next;
        }
        let used = nodes.len() as u32;
        let total = used.max(min_nodes);
        let (depth, root, first_leaf, last_leaf) = if nleaves == 0 { (0, 0, 0, 0) } else { (height as u16, level[0].0, 1, nleaves) };
        nodes[0] = header_node(ns, depth, root, recs.len() as u32, first_leaf, last_leaf, max_key, total, used, total * ns as u32, compare, attrs)?;
        nodes.resize(total as usize, vec![0; ns]);
        Ok((BTree { nodes }, total))
    }

    fn bytes(&self) -> Vec<u8> {
        self.nodes.concat()
    }
}

fn parent_of(p: &str) -> &str {
    p.rfind('/').map(|i| &p[..i]).unwrap_or("")
}

/// Builds the volume into `out` (a raw image). `data(source, sink)` feeds the bytes of a file to `sink`, in
/// pieces of any size, exactly `len` of them.
/// Feeds the data of file `source` to the sink, in pieces of any size.
pub type DataFn<'a> = dyn FnMut(usize, &mut dyn FnMut(&[u8]) -> Result<()>) -> Result<()> + 'a;

pub fn build<W: WriteAt>(entries: &[Entry], opts: &Options, out: &mut W, data: &mut DataFn) -> Result<Stats> {
    let bs = opts.block_size;
    if bs < 4096 || !bs.is_power_of_two() {
        return Err(bad("block size must be a power of two >= 4096"));
    }
    let date = opts.date + HFS_EPOCH_OFFSET;
    let blocks_of = |n: u64| n.div_ceil(bs as u64) as u32;

    // --- the tree: folders by path, children by parent ------------------------------------------------------
    let mut by_path: HashMap<&str, usize> = HashMap::new();
    for (i, e) in entries.iter().enumerate() {
        if by_path.insert(e.path.as_str(), i).is_some() {
            return Err(bad(format!("{}: listed twice", e.path)));
        }
    }
    let root_entry = by_path.get("").map(|&i| &entries[i]);
    let mut cnid_of: HashMap<&str, u32> = HashMap::new();
    cnid_of.insert("", 2);
    let mut next_cnid = FIRST_USER_CNID;
    let private = next_cnid;
    let private_dirs = next_cnid + 1;
    next_cnid += 2;
    // folders first (parents before children), then files, both in path order: stable CNIDs
    let mut order: Vec<usize> = (0..entries.len()).filter(|&i| !entries[i].path.is_empty()).collect();
    order.sort_by(|&a, &b| entries[a].path.cmp(&entries[b].path));
    for &i in &order {
        let e = &entries[i];
        let parent = parent_of(&e.path);
        if !parent.is_empty() && !matches!(by_path.get(parent).map(|&j| &entries[j].kind), Some(Kind::Dir)) {
            return Err(bad(format!("{}: parent folder {parent} is not in the tree", e.path)));
        }
        cnid_of.insert(e.path.as_str(), next_cnid);
        next_cnid += 1;
    }
    // hard link groups: the iNode file gets its own CNID
    let mut groups: BTreeMap<u64, Vec<usize>> = BTreeMap::new();
    for &i in &order {
        if let (Kind::File { .. }, Some(g)) = (&entries[i].kind, entries[i].link_group) {
            groups.entry(g).or_default().push(i);
        }
    }
    groups.retain(|_, v| v.len() > 1);
    let mut inode_of_group: HashMap<u64, u32> = HashMap::new();
    for g in groups.keys() {
        inode_of_group.insert(*g, next_cnid);
        next_cnid += 1;
    }

    // --- allocation: metadata files, then file data ------------------------------------------------------------
    let mut file_bytes: u64 = 0;
    let mut data_files: Vec<(usize, u64)> = Vec::new(); // (entry, len) whose data is written once
    let mut seen_group: HashMap<u64, ()> = HashMap::new();
    for &i in &order {
        match &entries[i].kind {
            Kind::File { len, .. } => {
                if let Some(g) = entries[i].link_group.filter(|g| groups.contains_key(g))
                    && seen_group.insert(g, ()).is_some()
                {
                    continue;
                }
                file_bytes += (blocks_of(*len) as u64) * bs as u64;
                data_files.push((i, *len));
            }
            Kind::Symlink { target } => file_bytes += blocks_of(target.len() as u64) as u64 * bs as u64,
            Kind::Dir => {}
        }
    }
    if let Some(key) = &opts.data_order {
        let k = |i: usize| match entries[i].kind {
            Kind::File { source, .. } => key.get(source).copied().unwrap_or(u64::MAX),
            _ => u64::MAX,
        };
        data_files.sort_by_key(|&(i, _)| k(i)); // stable: ties keep path order
    }
    // catalog size estimate: records are at most ~ 520 + 248 bytes; leave room for index nodes
    let nrec = 2 * (order.len() + groups.len() + 3);
    let cat_bytes_est = (nrec as u64 * 330 + 4 * CAT_NODE as u64) * 5 / 4;
    let cat_blocks_est = blocks_of(cat_bytes_est.max(16 * CAT_NODE as u64));
    let ext_blocks = blocks_of(16 * EXT_NODE as u64);
    let attr_blocks = blocks_of(4 * ATTR_NODE as u64);
    let meta_blocks_wo_bitmap = 1 + ext_blocks + cat_blocks_est + attr_blocks + 1;
    let used_est = meta_blocks_wo_bitmap as u64 + file_bytes / bs as u64;
    let total_blocks: u64 = match opts.size {
        Some(s) => s / bs as u64,
        None => (used_est + used_est / 16 + (1 << 20) / bs as u64 + 64).next_multiple_of(8),
    };
    let total_blocks = u32::try_from(total_blocks).map_err(|_| bad("volume has more than 2^32 blocks"))?;
    let bitmap_blocks = blocks_of((total_blocks as u64).div_ceil(8));
    if (meta_blocks_wo_bitmap + bitmap_blocks) as u64 + file_bytes / bs as u64 > total_blocks as u64 {
        return Err(bad(format!("{} bytes of data do not fit in a {}-byte volume", file_bytes, total_blocks as u64 * bs as u64)));
    }
    let alloc_start = 1u32;
    let ext_start = alloc_start + bitmap_blocks;
    let cat_start = ext_start + ext_blocks;
    let attr_start = cat_start + cat_blocks_est;
    let mut next_block = attr_start + attr_blocks;

    // --- place file data (extents depend on sizes only; the bytes are written last, in image order) -------------
    let mut extent_of: HashMap<usize, (u64, u32, u32)> = HashMap::new(); // entry -> (len, start, count)
    let mut extent_of_group: HashMap<u64, (u64, u32, u32)> = HashMap::new();
    for &(i, len) in &data_files {
        let count = blocks_of(len);
        let start = if count > 0 { next_block } else { 0 };
        next_block += count;
        let ext = (len, start, count);
        match entries[i].link_group.filter(|g| groups.contains_key(g)) {
            Some(g) => {
                extent_of_group.insert(g, ext);
            }
            None => {
                extent_of.insert(i, ext);
            }
        }
    }
    let mut symlink_blocks: Vec<(u32, Vec<u8>)> = Vec::new();
    for &i in &order {
        if let Kind::Symlink { target } = &entries[i].kind {
            let len = target.len() as u64;
            let count = blocks_of(len);
            let mut blk = target.as_bytes().to_vec();
            blk.resize((count as u64 * bs as u64) as usize, 0);
            symlink_blocks.push((next_block, blk));
            extent_of.insert(i, (len, next_block, count));
            next_block += count;
        }
    }

    // --- catalog records -----------------------------------------------------------------------------------------
    let mut recs: Vec<Rec> = Vec::new();
    let mut valence: HashMap<u32, u32> = HashMap::new();
    let mut subfolders: HashMap<u32, u32> = HashMap::new();
    let mut st = Stats::default();
    let name_of = |p: &str| -> Vec<u16> { hfs_name(p.rsplit('/').next().unwrap_or(p)) };
    let mode_of = |e: &Entry| -> u16 {
        (e.perm & 0o7777)
            | match e.kind {
                Kind::Dir => 0o040000,
                Kind::File { .. } => 0o100000,
                Kind::Symlink { .. } => 0o120000,
            }
    };
    for &i in &order {
        let e = &entries[i];
        let parent = cnid_of[parent_of(&e.path)];
        *valence.entry(parent).or_default() += 1;
        if e.kind == Kind::Dir {
            *subfolders.entry(parent).or_default() += 1;
        }
    }
    // private directories in the root
    *valence.entry(2).or_default() += 2;
    *subfolders.entry(2).or_default() += 2;
    valence.insert(private, groups.len() as u32);
    let vname = hfs_name(&opts.volume_name);
    // the root folder
    let rp = root_entry.map(|e| Perm { uid: e.uid, gid: e.gid, owner_flags: 0, mode: mode_of(e), special: 0 }).unwrap_or(Perm { uid: 0, gid: 0, owner_flags: 0, mode: 0o40755, special: 0 });
    let rdate = root_entry.map(|e| e.mtime + HFS_EPOCH_OFFSET).unwrap_or(date);
    // folder flags 0x10: kHFSHasFolderCountMask (HFSX keeps the subfolder count in every folder record)
    recs.push(Rec { parent: 1, name: vname.clone(), data: folder_rec(0x10, valence.get(&2).copied().unwrap_or(0), 2, rdate, &rp, [0; 16], subfolders.get(&2).copied().unwrap_or(0)) });
    recs.push(Rec { parent: 2, name: vec![], data: thread_rec(3, 1, &vname) });
    st.folders += 1;
    // the private directories as newfs_hfs makes them: immutable, invisible + name locked, Finder location 0x4000
    let hidden: [u8; 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0x50, 0x00, 0x40, 0x00, 0x40, 0x00, 0, 0];
    for (cnid, nm, mode) in [(private, PRIVATE_DIR, 0o40000u16), (private_dirs, PRIVATE_DIR_DIRS, 0o41555)] {
        let n = hfs_name(nm);
        let p = Perm { uid: 0, gid: 0, owner_flags: 0x02, mode, special: 1 };
        recs.push(Rec { parent: 2, name: n.clone(), data: folder_rec(0x10, valence.get(&cnid).copied().unwrap_or(0), cnid, date, &p, hidden, 0) });
        recs.push(Rec { parent: cnid, name: vec![], data: thread_rec(3, 2, &n) });
        st.folders += 1;
    }
    for &i in &order {
        let e = &entries[i];
        let cnid = cnid_of[e.path.as_str()];
        let parent = cnid_of[parent_of(&e.path)];
        let name = name_of(&e.path);
        let edate = e.mtime + HFS_EPOCH_OFFSET;
        let perm = Perm { uid: e.uid, gid: e.gid, owner_flags: 0, mode: mode_of(e), special: 1 };
        match &e.kind {
            Kind::Dir => {
                recs.push(Rec { parent, name: name.clone(), data: folder_rec(0x10, valence.get(&cnid).copied().unwrap_or(0), cnid, edate, &perm, [0; 16], subfolders.get(&cnid).copied().unwrap_or(0)) });
                recs.push(Rec { parent: cnid, name: vec![], data: thread_rec(3, parent, &name) });
                st.folders += 1;
            }
            Kind::Symlink { .. } => {
                let mut fi = [0u8; 16];
                fi[..8].copy_from_slice(b"slnkrhap");
                recs.push(Rec { parent, name: name.clone(), data: file_rec(0x02, cnid, edate, &perm, fi, 0, extent_of[&i], 0) });
                recs.push(Rec { parent: cnid, name: vec![], data: thread_rec(4, parent, &name) });
                st.files += 1;
            }
            Kind::File { .. } => match e.link_group.filter(|g| groups.contains_key(g)) {
                None => {
                    recs.push(Rec { parent, name: name.clone(), data: file_rec(0x02, cnid, edate, &perm, [0; 16], 0, extent_of[&i], 0) });
                    recs.push(Rec { parent: cnid, name: vec![], data: thread_rec(4, parent, &name) });
                    st.files += 1;
                }
                Some(g) => {
                    // a link record: the chain (prev in ownerID, next in groupID) runs in path order
                    let members = &groups[&g];
                    let k = members.iter().position(|&m| m == i).unwrap();
                    let prev = if k > 0 { cnid_of[entries[members[k - 1]].path.as_str()] } else { 0 };
                    let next = if k + 1 < members.len() { cnid_of[entries[members[k + 1]].path.as_str()] } else { 0 };
                    let inode = inode_of_group[&g];
                    let mut fi = [0u8; 16];
                    fi[..8].copy_from_slice(b"hlnkhfs+");
                    fi[8] = 0x01; // fdFlags kHasBeenInited
                    let p = Perm { uid: prev, gid: next, owner_flags: 0x02, mode: 0o100444, special: inode };
                    // a link record's creation date is the private directory's (fsck_hfs checks it)
                    recs.push(Rec { parent, name: name.clone(), data: file_rec(0x22, cnid, date, &p, fi, 126, (0, 0, 0), 0) });
                    recs.push(Rec { parent: cnid, name: vec![], data: thread_rec(4, parent, &name) });
                    st.files += 1;
                    st.hard_links += 1;
                }
            },
        }
    }
    // iNode files: real owner/mode/data, linkCount = number of links
    for (g, members) in &groups {
        let inode = inode_of_group[g];
        let e = &entries[members[0]];
        let name = hfs_name(&format!("iNode{inode}"));
        let p = Perm { uid: e.uid, gid: e.gid, owner_flags: 0, mode: mode_of(e), special: members.len() as u32 };
        let first = cnid_of[entries[members[0]].path.as_str()];
        recs.push(Rec { parent: private, name: name.clone(), data: file_rec(0x22, inode, e.mtime + HFS_EPOCH_OFFSET, &p, [0; 16], 0, extent_of_group[g], first) });
        recs.push(Rec { parent: inode, name: vec![], data: thread_rec(4, private, &name) });
        st.files += 1;
        st.inodes += 1;
    }
    recs.sort_by(|a, b| a.parent.cmp(&b.parent).then_with(|| a.name.cmp(&b.name)));
    for w in recs.windows(2) {
        if w[0].parent == w[1].parent && w[0].name == w[1].name {
            return Err(bad(format!("two catalog records with the same key under folder {} (names differing only in normalization?)", w[0].parent)));
        }
    }
    let leaf: Vec<(Vec<u8>, Vec<u8>)> = recs.into_iter().map(|r| (key_bytes(r.parent, &r.name), r.data)).collect();
    // HFSX: binary key compare (0xBC); big keys + variable index keys
    let cat_nodes_min = (cat_blocks_est as u64 * bs as u64 / CAT_NODE as u64) as u32;
    let (cat, cat_nodes) = BTree::build(CAT_NODE, &leaf, 516, 0xBC, 0x6, cat_nodes_min)?;
    if cat_nodes as u64 * CAT_NODE as u64 > cat_blocks_est as u64 * bs as u64 {
        return Err(bad("catalog bigger than its estimate (internal error)"));
    }
    let (ext, _) = BTree::build(EXT_NODE, &[], 10, 0, 0x2, (ext_blocks as u64 * bs as u64 / EXT_NODE as u64) as u32)?;
    let (attr, _) = BTree::build(ATTR_NODE, &[], 266, 0, 0x6, (attr_blocks as u64 * bs as u64 / ATTR_NODE as u64) as u32)?;
    // --- allocation bitmap: block 0 (boot + header), metadata, data, the last block (alternate header) ------
    let mut bm = vec![0u8; (bitmap_blocks as u64 * bs as u64) as usize];
    let mut mark = |b: u32| bm[(b / 8) as usize] |= 0x80 >> (b % 8);
    for b in 0..next_block {
        mark(b);
    }
    mark(total_blocks - 1);
    let used = next_block + 1;

    // --- volume headers ---------------------------------------------------------------------------------------
    let mut vh = vec![0u8; 512];
    vh[0..2].copy_from_slice(b"HX");
    put16(&mut vh, 2, 5);
    put32(&mut vh, 4, 0x8000_0100); // kHFSUnusedNodeFixBit (31) | kHFSVolumeUnmountedBit (8), as newfs_hfs
    vh[8..12].copy_from_slice(b"10.0");
    put32(&mut vh, 16, date);
    put32(&mut vh, 20, date);
    put32(&mut vh, 28, date);
    put32(&mut vh, 32, st.files);
    put32(&mut vh, 36, st.folders - 1);
    put32(&mut vh, 40, bs);
    put32(&mut vh, 44, total_blocks);
    put32(&mut vh, 48, total_blocks - used);
    put32(&mut vh, 52, next_block);
    put32(&mut vh, 56, 65536);
    put32(&mut vh, 60, 65536);
    put32(&mut vh, 64, next_cnid);
    put32(&mut vh, 68, 1);
    put64(&mut vh, 72, 1);
    let fork = |vh: &mut [u8], off: usize, len: u64, start: u32, count: u32, clump: u32| {
        put64(vh, off, len);
        put32(vh, off + 8, clump);
        put32(vh, off + 12, count);
        put32(vh, off + 16, start);
        put32(vh, off + 20, count);
    };
    fork(&mut vh, 112, bitmap_blocks as u64 * bs as u64, alloc_start, bitmap_blocks, bs);
    fork(&mut vh, 192, ext_blocks as u64 * bs as u64, ext_start, ext_blocks, ext_blocks * bs);
    fork(&mut vh, 272, cat_blocks_est as u64 * bs as u64, cat_start, cat_blocks_est, cat_blocks_est * bs);
    fork(&mut vh, 352, attr_blocks as u64 * bs as u64, attr_start, attr_blocks, attr_blocks * bs);
    // block 0: 1024 bytes of boot blocks (zero), the header, the rest of the block zero
    let mut b0 = vec![0u8; bs as usize];
    b0[1024..1536].copy_from_slice(&vh);
    let size = total_blocks as u64 * bs as u64;
    let mut last = vec![0u8; bs as usize];
    last[bs as usize - 1024..bs as usize - 512].copy_from_slice(&vh);

    // --- write everything in image order: block 0, bitmap, B-trees, file data, symlinks, the last block ------
    out.write_at(0, &b0)?;
    out.write_at(alloc_start as u64 * bs as u64, &bm)?;
    drop(bm);
    out.write_at(ext_start as u64 * bs as u64, &ext.bytes())?;
    out.write_at(cat_start as u64 * bs as u64, &cat.bytes())?;
    drop(cat);
    out.write_at(attr_start as u64 * bs as u64, &attr.bytes())?;
    for &(i, len) in &data_files {
        let Kind::File { source, .. } = entries[i].kind else { continue };
        let ext = match entries[i].link_group.filter(|g| groups.contains_key(g)) {
            Some(g) => extent_of_group[&g],
            None => extent_of[&i],
        };
        let start = ext.1;
        let mut at = start as u64 * bs as u64;
        let mut got = 0u64;
        data(source, &mut |b: &[u8]| {
            if b.is_empty() {
                return Ok(());
            }
            if got + b.len() as u64 > len {
                return Err(bad(format!("{}: more data than its size", entries[i].path)));
            }
            out.write_at(at, b)?;
            at += b.len() as u64;
            got += b.len() as u64;
            Ok(())
        })?;
        if got != len {
            return Err(bad(format!("{}: got {got} bytes, expected {len}", entries[i].path)));
        }
        // zero the tail of the last block (the image may be a reused file)
        let tail = (blocks_of(len) as u64 * bs as u64) - len;
        if tail > 0 {
            out.write_at(start as u64 * bs as u64 + len, &vec![0; tail as usize])?;
        }
    }
    for (blk, bytes) in &symlink_blocks {
        out.write_at(*blk as u64 * bs as u64, bytes)?;
    }
    out.write_at(size - bs as u64, &last)?;
    st.total_blocks = total_blocks;
    st.free_blocks = total_blocks - used;
    st.catalog_nodes = cat_nodes;
    Ok(st)
}
