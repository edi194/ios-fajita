//! Read-only HFS+/HFSX reader (`tools/renegade/hfsx.py`): the catalog B-tree is parsed into memory, hard
//! links resolve through the iNode files of the private directory, symlinks are followed, and the
//! extents-overflow file is honoured. Reads straight from a [`crate::sparse::Sparse`] image (or any
//! [`ReadAt`]), so a 15 GB root needs no raw copy and no mount.

use crate::bytes::{u16be, u32be, u64be};
use crate::io::{bad, ReadAt};
use std::collections::HashMap;
use std::io::Result;
use unicode_normalization::UnicodeNormalization;

pub const FOLDER: u16 = 1;
pub const FILE: u16 = 2;
const HLNK: (u32, u32) = (0x686C_6E6B, 0x6866_732B); // 'hlnk', 'hfs+'
pub const ROOT_CNID: u32 = 2;

/// A catalog entry: record type (1 folder, 2 file), CNID and the offset of its record in the catalog
/// (None only for the root folder reached by an empty path, as hfsx.py's `(1, 2, None)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub rt: u16,
    pub cnid: u32,
    pub rec: Option<usize>,
}

pub type Extent = (u32, u32); // (start block, block count)
/// (file id, fork type) -> [(first file block, extents)] from the extents-overflow B-tree.
type Overflow = HashMap<(u32, u8), Vec<(u32, Vec<Extent>)>>;

pub struct Volume<R: ReadAt> {
    img: R,
    pub block_size: u32,
    vh: Vec<u8>,
    overflow: Overflow,
    /// The catalog file, whole.
    pub cat: Vec<u8>,
    /// parent CNID -> children in catalog order, and a name index into that list.
    children: HashMap<u32, Vec<(String, Entry)>>,
    index: HashMap<u32, HashMap<String, usize>>,
    pub private: Option<u32>,
}

impl<R: ReadAt> Volume<R> {
    pub fn open(img: R) -> Result<Self> {
        let vh = img.read_vec(1024, 512)?;
        if &vh[..2] != b"H+" && &vh[..2] != b"HX" {
            return Err(bad("no HFS+ / HFSX volume header at byte 1024"));
        }
        let block_size = u32be(&vh, 40);
        let mut v = Volume { img, block_size, vh, overflow: HashMap::new(), cat: Vec::new(), children: HashMap::new(), index: HashMap::new(), private: None };
        v.load_overflow()?;
        let (l, ext) = v.fork(272);
        let ext = v.all_extents(4, 0, &ext);
        v.cat = v.read_extents(&ext, l)?;
        v.parse_catalog()?;
        Ok(v)
    }

    fn fork(&self, off: usize) -> (u64, Vec<Extent>) {
        fork_at(&self.vh, off)
    }

    fn load_overflow(&mut self) -> Result<()> {
        let (l, e) = self.fork(192);
        let data = self.read_extents(&e, l)?;
        if data.len() < 14 + 20 {
            return Ok(());
        }
        let ns = u16be(&data, 14 + 18) as usize;
        let mut node = u32be(&data, 14 + 10) as usize;
        while node != 0 {
            let nd = data.get(node * ns..(node + 1) * ns).ok_or_else(|| bad("extents B-tree node out of range"))?;
            let flink = u32be(nd, 0) as usize;
            let nrec = u16be(nd, 10) as usize;
            for i in 0..nrec {
                let ro = u16be(nd, ns - 2 * (i + 1)) as usize;
                let klen = u16be(nd, ro) as usize;
                let fk = nd[ro + 2];
                let fid = u32be(nd, ro + 4);
                let start = u32be(nd, ro + 8);
                let mut ex = Vec::new();
                for j in 0..8 {
                    let st = u32be(nd, ro + 2 + klen + 8 * j);
                    let c = u32be(nd, ro + 2 + klen + 8 * j + 4);
                    if c != 0 {
                        ex.push((st, c));
                    }
                }
                self.overflow.entry((fid, fk)).or_default().push((start, ex));
            }
            node = flink;
        }
        Ok(())
    }

    fn all_extents(&self, fid: u32, fk: u8, ext: &[Extent]) -> Vec<Extent> {
        let mut out = ext.to_vec();
        if let Some(more) = self.overflow.get(&(fid, fk)) {
            let mut more = more.clone();
            more.sort();
            for (_, ex) in more {
                out.extend(ex);
            }
        }
        out
    }

    pub fn read_extents(&self, ext: &[Extent], size: u64) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(size as usize);
        for &(st, c) in ext {
            let n = c as u64 * self.block_size as u64;
            let take = n.min(size - out.len() as u64) as usize;
            let at = out.len();
            out.resize(at + take, 0);
            self.img.read_at(st as u64 * self.block_size as u64, &mut out[at..])?;
            if out.len() as u64 >= size {
                break;
            }
        }
        out.truncate(size as usize);
        Ok(out)
    }

    fn parse_catalog(&mut self) -> Result<()> {
        let cat = &self.cat;
        let ns = u16be(cat, 14 + 18) as usize;
        let mut n = u32be(cat, 14 + 10) as usize;
        while n != 0 {
            let base = n * ns;
            if base + ns > cat.len() {
                return Err(bad("catalog node out of range"));
            }
            let flink = u32be(cat, base) as usize;
            let nrec = u16be(cat, base + 10) as usize;
            for i in 0..nrec {
                let ro = base + u16be(cat, base + ns - 2 * (i + 1)) as usize;
                let klen = u16be(cat, ro) as usize;
                let parent = u32be(cat, ro + 2);
                let nlen = u16be(cat, ro + 6) as usize;
                let units: Vec<u16> = (0..nlen).map(|k| u16be(cat, ro + 8 + 2 * k)).collect();
                let name = String::from_utf16_lossy(&units);
                let mut d = ro + 2 + klen;
                d += d & 1;
                let rt = u16be(cat, d);
                if rt == FOLDER || rt == FILE {
                    let cnid = u32be(cat, d + 8);
                    let e = Entry { rt, cnid, rec: Some(d) };
                    let list = self.children.entry(parent).or_default();
                    let idx = self.index.entry(parent).or_default();
                    // a later record of the same name replaces the earlier one (a Python dict assignment)
                    match idx.get(&name) {
                        Some(&k) => list[k].1 = e,
                        None => {
                            idx.insert(name.clone(), list.len());
                            list.push((name, e));
                        }
                    }
                }
            }
            n = flink;
        }
        self.private = self.children.get(&ROOT_CNID).and_then(|c| c.iter().find(|(nm, _)| nm.starts_with("\0\0\0\0HFS+")).map(|(_, e)| e.cnid));
        Ok(())
    }

    /// Children of a folder in catalog order.
    pub fn children(&self, cnid: u32) -> &[(String, Entry)] {
        self.children.get(&cnid).map(|v| v.as_slice()).unwrap_or(&[])
    }

    pub fn child(&self, parent: u32, name: &str) -> Option<Entry> {
        let k = *self.index.get(&parent)?.get(name)?;
        Some(self.children[&parent][k].1)
    }

    /// (type, creator) of a file record.
    pub fn finder_info(&self, d: usize) -> (u32, u32) {
        (u32be(&self.cat, d + 48), u32be(&self.cat, d + 52))
    }
    pub fn mode(&self, d: usize) -> u16 {
        u16be(&self.cat, d + 32 + 10)
    }
    pub fn owner(&self, d: usize) -> (u32, u32) {
        (u32be(&self.cat, d + 32), u32be(&self.cat, d + 36))
    }
    pub fn is_hard_link(&self, d: usize) -> bool {
        self.finder_info(d) == HLNK
    }

    /// A hard link's iNode file.
    pub fn resolve_link(&self, e: Entry) -> Option<Entry> {
        let d = e.rec?;
        if e.rt != FILE || !self.is_hard_link(d) {
            return Some(e);
        }
        let num = u32be(&self.cat, d + 32 + 12);
        self.child(self.private?, &format!("iNode{num}"))
    }

    pub fn lookup(&self, path: &str, follow: bool) -> Result<Option<Entry>> {
        self.lookup_depth(path, follow, 0)
    }

    fn lookup_depth(&self, path: &str, follow: bool, depth: u32) -> Result<Option<Entry>> {
        let mut cur = ROOT_CNID;
        let mut rec: Option<Entry> = None;
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let mut i = 0;
        while i < parts.len() {
            let nfd: String = parts[i].nfd().collect();
            let Some(mut e) = self.child(cur, &nfd).or_else(|| self.child(cur, parts[i])) else { return Ok(None) };
            if e.rt == FILE {
                let mut mode = self.mode(e.rec.unwrap());
                if self.is_hard_link(e.rec.unwrap()) {
                    e = self.resolve_link(e).ok_or_else(|| bad(format!("{path}: hard link without its iNode")))?;
                    mode = self.mode(e.rec.unwrap());
                }
                if mode & 0o170000 == 0o120000 && (follow || i < parts.len() - 1) {
                    if depth >= 20 {
                        return Err(bad(format!("{path}: too many symlinks")));
                    }
                    let tgt = String::from_utf8_lossy(&self.read_file(e)?).into_owned();
                    let np = if tgt.starts_with('/') { tgt } else { format!("/{}/{}", parts[..i].join("/"), tgt) };
                    let rest = parts[i + 1..].join("/");
                    return self.lookup_depth(&format!("{}/{}", normpath(&np), rest), follow, depth + 1);
                }
                if i < parts.len() - 1 {
                    return Ok(None);
                }
                return Ok(Some(e));
            }
            cur = e.cnid;
            rec = Some(e);
            i += 1;
        }
        Ok(Some(rec.unwrap_or(Entry { rt: FOLDER, cnid: ROOT_CNID, rec: None })))
    }

    pub fn fork_of(&self, d: usize) -> (u64, Vec<Extent>) {
        fork_at(&self.cat, d + 88)
    }

    pub fn file_extents(&self, cnid: u32, d: usize) -> (u64, Vec<Extent>) {
        let (l, ext) = self.fork_of(d);
        (l, self.all_extents(cnid, 0, &ext))
    }

    pub fn read_file(&self, e: Entry) -> Result<Vec<u8>> {
        let d = e.rec.ok_or_else(|| bad("not a file"))?;
        let (l, ext) = self.file_extents(e.cnid, d);
        self.read_extents(&ext, l)
    }

    /// The data fork of the file with this CNID (as a [`ReadAt`]); `rec` is its catalog record offset.
    pub fn file_at(&self, cnid: u32, rec: usize) -> VFile<'_, R> {
        let (l, ext) = self.file_extents(cnid, rec);
        VFile::new(self, l, &ext)
    }

    /// A regular file (hard links and symlinks resolved) as a [`ReadAt`].
    pub fn open_file(&self, path: &str) -> Result<VFile<'_, R>> {
        let e = self.lookup(path, true)?.filter(|e| e.rt == FILE).ok_or_else(|| bad(format!("{path}: no such file")))?;
        let (l, ext) = self.file_extents(e.cnid, e.rec.unwrap());
        Ok(VFile::new(self, l, &ext))
    }
}

fn fork_at(b: &[u8], off: usize) -> (u64, Vec<Extent>) {
    let logical = u64be(b, off);
    let ext = (0..8).map(|i| (u32be(b, off + 16 + 8 * i), u32be(b, off + 20 + 8 * i))).filter(|e| e.1 != 0).collect();
    (logical, ext)
}

/// posixpath.normpath for absolute paths (`.`, `..`, duplicate slashes).
pub fn normpath(p: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for c in p.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    format!("/{}", out.join("/"))
}

/// A file inside the volume: its extents mapped to the volume's blocks.
pub struct VFile<'a, R: ReadAt> {
    vol: &'a Volume<R>,
    size: u64,
    ext: Vec<(u64, u32, u32)>, // (file offset, start block, count)
}

impl<'a, R: ReadAt> VFile<'a, R> {
    fn new(vol: &'a Volume<R>, size: u64, ext: &[Extent]) -> Self {
        let mut o = 0;
        let ext = ext
            .iter()
            .map(|&(st, c)| {
                let e = (o, st, c);
                o += c as u64 * vol.block_size as u64;
                e
            })
            .collect();
        Self { vol, size, ext }
    }
}

impl<R: ReadAt> ReadAt for VFile<'_, R> {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, mut pos: u64, mut buf: &mut [u8]) -> Result<()> {
        if pos + buf.len() as u64 > self.size {
            return Err(crate::io::short(pos));
        }
        let bs = self.vol.block_size as u64;
        while !buf.is_empty() {
            let i = self.ext.partition_point(|e| e.0 <= pos) - 1;
            let (o, st, c) = self.ext[i];
            let rel = pos - o;
            let k = (buf.len() as u64).min(c as u64 * bs - rel) as usize;
            let (head, rest) = buf.split_at_mut(k);
            self.vol.img.read_at(st as u64 * bs + rel, head)?;
            pos += k as u64;
            buf = rest;
        }
        Ok(())
    }
}
