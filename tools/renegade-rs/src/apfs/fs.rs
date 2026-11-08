//! The file-system tree: record parsing, the one-pass scan that builds the listing, lookups by path.

use super::btree::{Cursor, Rec, Space, Tree};
use super::obj::*;
use super::{Stat, VolCore};
use crate::io::{ReadAt, bad};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::io::Result;

pub(crate) const T_INODE: u8 = 3;
pub(crate) const T_XATTR: u8 = 4;
pub(crate) const T_FILE_EXTENT: u8 = 8;
pub(crate) const T_DREC: u8 = 9;
const ID_MASK: u64 = 0x0fff_ffff_ffff_ffff;

pub(crate) const ROOT_DIR_INO: u64 = 2;

pub(crate) const S_IFMT: u16 = 0o170000;
pub(crate) const S_IFDIR: u16 = 0o040000;
pub(crate) const S_IFREG: u16 = 0o100000;
pub(crate) const S_IFLNK: u16 = 0o120000;

pub(crate) const UF_COMPRESSED: u32 = 0x20;
pub(crate) const SF_DATALESS: u32 = 0x4000_0000;

pub(crate) const XATTR_DATA_STREAM: u16 = 1;
pub(crate) const XATTR_DATA_EMBEDDED: u16 = 2;

pub(crate) const XA_SYMLINK: &[u8] = b"com.apple.fs.symlink";
pub(crate) const XA_DECMPFS: &[u8] = b"com.apple.decmpfs";
pub(crate) const XA_RSRC: &[u8] = b"com.apple.ResourceFork";

/// (object id, record type) of a file-system record key.
pub(crate) fn key_hdr(key: &[u8]) -> Result<(u64, u8)> {
    let h = le64(key, 0)?;
    Ok((h & ID_MASK, (h >> 60) as u8))
}

pub(crate) fn cmp_hdr(key: &[u8], id: u64, ty: u8) -> Ordering {
    match key_hdr(key) {
        Ok(h) => h.cmp(&(id, ty)),
        Err(_) => Ordering::Less,
    }
}

/// The inode fields we use.
#[derive(Clone, Copy, Debug)]
pub(crate) struct InodeRaw {
    pub private_id: u64,
    pub mtime_ns: u64,
    pub nlink: i32,
    pub bsd_flags: u32,
    pub uid: u32,
    pub gid: u32,
    pub mode: u16,
    pub dstream_size: Option<u64>,
}

pub(crate) fn parse_inode(v: &[u8]) -> Result<InodeRaw> {
    if v.len() < 92 {
        return Err(bad("inode record is too short"));
    }
    let mut ino = InodeRaw {
        private_id: le64(v, 8)?,
        mtime_ns: le64(v, 24)?,
        nlink: le32(v, 56)? as i32,
        bsd_flags: le32(v, 68)?,
        uid: le32(v, 72)?,
        gid: le32(v, 76)?,
        mode: le16(v, 80)?,
        dstream_size: None,
    };
    // extended fields: count, used bytes, (type, flags, size) descriptors, then 8-aligned data
    if v.len() >= 96 {
        let n = le16(v, 92)? as usize;
        let descr = 96;
        let mut data = descr + 4 * n;
        for k in 0..n {
            let ty = *v.get(descr + 4 * k).ok_or_else(|| bad("inode xfield table truncated"))?;
            let sz = le16(v, descr + 4 * k + 2)? as usize;
            if ty == 8 && sz >= 8 {
                ino.dstream_size = Some(le64(v, data)?);
            }
            data += (sz + 7) & !7;
        }
    }
    Ok(ino)
}

/// The name in a directory-record key (hashed or not; the form is told by the key's length).
pub(crate) fn drec_name(key: &[u8]) -> Result<&[u8]> {
    let t = key.get(8..).ok_or_else(|| bad("directory record key truncated"))?;
    let name = if t.len() >= 4 && 4 + (le32(t, 0)? & 0x3ff) as usize == t.len() {
        &t[4..]
    } else if t.len() >= 2 && 2 + le16(t, 0)? as usize == t.len() {
        &t[2..]
    } else {
        return Err(bad("directory record key has an inconsistent name length"));
    };
    let end = name.iter().position(|&c| c == 0).unwrap_or(name.len());
    Ok(&name[..end])
}

/// A directory record's value: the file id and the DT_* type.
pub(crate) fn parse_drec(v: &[u8]) -> Result<(u64, u8)> {
    Ok((le64(v, 0)?, (le16(v, 16)? & 0xf) as u8))
}

pub(crate) fn xattr_name(key: &[u8]) -> Result<&[u8]> {
    let n = le16(key, 8)? as usize;
    let name = key.get(10..10 + n).ok_or_else(|| bad("xattr key truncated"))?;
    let end = name.iter().position(|&c| c == 0).unwrap_or(name.len());
    Ok(&name[..end])
}

/// An extended attribute's value: flags and the payload (inline bytes, or object id + dstream).
pub(crate) fn parse_xattr(v: &[u8]) -> Result<(u16, &[u8])> {
    let flags = le16(v, 0)?;
    let len = le16(v, 2)? as usize;
    let data = v.get(4..4 + len).ok_or_else(|| bad("xattr value truncated"))?;
    Ok((flags, data))
}

pub(crate) fn mtime_secs(ns: u64) -> i64 {
    (ns / 1_000_000_000) as i64
}

/// Compact per-inode data of the listing.
#[derive(Clone, Copy)]
pub(crate) struct Ino {
    pub id: u64,
    pub private_id: u64,
    pub size: u64,
    pub mtime: i64,
    pub uid: u32,
    pub gid: u32,
    pub nlink: i32,
    pub mode: u16,
    pub cmp: u8,
    pub names: u32,
}

#[derive(Clone, Copy)]
pub(crate) struct Drec {
    pub parent: u64,
    pub child: u64,
    pub name: u32,
    pub name_len: u16,
}

pub(crate) fn cmp_type_byte(t: u32) -> u8 {
    if t < 255 { t as u8 } else { 255 }
}

/// The decmpfs header of an attribute: (compression type, uncompressed size).
pub(crate) fn decmpfs_header(v: &[u8]) -> Option<(u32, u64)> {
    if v.len() < 16 || &v[..4] != b"fpmc" {
        return None;
    }
    Some((u32::from_le_bytes([v[4], v[5], v[6], v[7]]), u64::from_le_bytes([v[8], v[9], v[10], v[11], v[12], v[13], v[14], v[15]])))
}

/// What the scan counted besides the listing.
#[derive(Default, Clone, Debug)]
pub(crate) struct ScanStats {
    pub extents: u64,
    pub sparse_extents: u64,
    pub extent_bytes: u64,
    pub bad_extents: u64,
    pub records: u64,
}

pub(crate) struct Scan {
    pub inodes: Vec<Ino>,
    pub drecs: Vec<Drec>,
    pub names: Vec<u8>,
    pub targets: std::collections::HashMap<u64, String>,
    pub stats: ScanStats,
    pub lossy_names: u64,
}

pub(crate) fn scan<R: ReadAt>(vol: &VolCore<R>) -> Result<Scan> {
    let tree = vol.fs_tree()?;
    let mut cur = Cursor::first(&tree);
    let mut s = Scan {
        inodes: Vec::new(),
        drecs: Vec::new(),
        names: Vec::new(),
        targets: Default::default(),
        stats: ScanStats::default(),
        lossy_names: 0,
    };
    let side = vol.fs_tree()?; // for attributes kept in data streams
    let mut cur_flags = 0u32;
    let nblocks = vol.sh.nblocks;
    let bs = vol.sh.bs as u64;
    while let Some(rec) = cur.next()? {
        s.stats.records += 1;
        let (id, ty) = key_hdr(rec.key())?;
        match ty {
            T_INODE => {
                if s.inodes.last().is_some_and(|l| l.id >= id) {
                    return Err(bad("file-system tree is out of order"));
                }
                let r = parse_inode(rec.val())?;
                cur_flags = r.bsd_flags;
                let nlink = r.nlink;
                let (kind, size) = match r.mode & S_IFMT {
                    S_IFDIR => (S_IFDIR, 0),
                    S_IFLNK => (S_IFLNK, 0),
                    m => (m, r.dstream_size.unwrap_or(0)),
                };
                s.inodes.push(Ino {
                    id,
                    private_id: r.private_id,
                    size,
                    mtime: mtime_secs(r.mtime_ns),
                    uid: r.uid,
                    gid: r.gid,
                    nlink: if kind == S_IFDIR { nlink.saturating_add(2) } else { nlink },
                    mode: r.mode,
                    cmp: 0,
                    names: 0,
                });
            }
            T_DREC => {
                let name = drec_name(rec.key())?;
                let (child, _dtype) = parse_drec(rec.val())?;
                let off = s.names.len();
                match std::str::from_utf8(name) {
                    Ok(_) => s.names.extend_from_slice(name),
                    Err(_) => {
                        s.lossy_names += 1;
                        s.names.extend_from_slice(String::from_utf8_lossy(name).as_bytes());
                    }
                }
                let len = s.names.len() - off;
                if off > u32::MAX as usize || len > u16::MAX as usize {
                    return Err(bad("name table overflows"));
                }
                s.drecs.push(Drec { parent: id, child, name: off as u32, name_len: len as u16 });
            }
            T_XATTR => {
                let Some(last) = s.inodes.last_mut() else { continue };
                if last.id != id {
                    continue;
                }
                let name = xattr_name(rec.key())?;
                if name == XA_SYMLINK && last.mode & S_IFMT == S_IFLNK {
                    let (flags, data) = parse_xattr(rec.val())?;
                    if flags & XATTR_DATA_EMBEDDED != 0 {
                        let end = data.iter().position(|&c| c == 0).unwrap_or(data.len());
                        let t = String::from_utf8_lossy(&data[..end]).into_owned();
                        last.size = t.len() as u64;
                        s.targets.insert(id, t);
                    }
                } else if name == XA_DECMPFS && cur_flags & UF_COMPRESSED != 0 {
                    let (flags, data) = parse_xattr(rec.val())?;
                    if let Some((t, size)) = decmpfs_header(&super::file::xattr_bytes(vol, &side, flags, data)?) {
                        last.cmp = cmp_type_byte(t);
                        last.size = size;
                    }
                }
            }
            T_FILE_EXTENT => {
                s.stats.extents += 1;
                let v = rec.val();
                if v.len() < 24 {
                    s.stats.bad_extents += 1;
                    continue;
                }
                let len = le64(v, 0)? & 0x00ff_ffff_ffff_ffff;
                let phys = le64(v, 8)?;
                if phys == 0 {
                    s.stats.sparse_extents += 1;
                } else {
                    s.stats.extent_bytes += len;
                    let blocks = len.div_ceil(bs);
                    if len == 0 || phys.checked_add(blocks).is_none_or(|e| e > nblocks) {
                        s.stats.bad_extents += 1;
                    }
                }
            }
            _ => {}
        }
    }
    if vol.info.fext_tree_oid != 0 {
        let ft = Tree::open(&vol.sh, Space::Phys, vol.info.fext_tree_oid)?;
        let mut c = Cursor::first(&ft);
        while let Some(r) = c.next()? {
            s.stats.records += 1;
            s.stats.extents += 1;
            let v = r.val();
            let (len, phys) = (le64(v, 0)? & 0x00ff_ffff_ffff_ffff, le64(v, 8)?);
            if phys == 0 {
                s.stats.sparse_extents += 1;
            } else {
                s.stats.extent_bytes += len;
                if len == 0 || phys.checked_add(len.div_ceil(bs)).is_none_or(|e| e > nblocks) {
                    s.stats.bad_extents += 1;
                }
            }
        }
    }
    // children grouped by parent, sorted by name inside a directory
    let names = &s.names;
    let nm = |d: &Drec| &names[d.name as usize..d.name as usize + d.name_len as usize];
    s.drecs.sort_by(|a, b| a.parent.cmp(&b.parent).then_with(|| nm(a).cmp(nm(b))));
    // names per inode, for the hard-link and nlink checks
    for d in &s.drecs {
        if let Ok(i) = s.inodes.binary_search_by(|x| x.id.cmp(&d.child)) {
            s.inodes[i].names += 1;
        }
    }
    Ok(s)
}

impl<R: ReadAt> VolCore<R> {
    pub(crate) fn fs_tree(&self) -> Result<Tree<'_, R>> {
        Tree::open(&self.sh, Space::Virt(&self.omap), self.root_oid)
    }

    pub(crate) fn find_inode(&self, tree: &Tree<'_, R>, id: u64) -> Result<Option<InodeRaw>> {
        let mut c = Cursor::seek(tree, &|k| cmp_hdr(k, id, T_INODE))?;
        match c.next()? {
            Some(r) if key_hdr(r.key())? == (id, T_INODE) => Ok(Some(parse_inode(r.val())?)),
            _ => Ok(None),
        }
    }

    /// Calls `f` for every record of (id, ty), in key order.
    pub(crate) fn for_records(&self, tree: &Tree<'_, R>, id: u64, ty: u8, f: &mut dyn FnMut(&Rec) -> Result<bool>) -> Result<()> {
        let mut c = Cursor::seek(tree, &|k| cmp_hdr(k, id, ty))?;
        while let Some(r) = c.next()? {
            if key_hdr(r.key())? != (id, ty) || !f(&r)? {
                break;
            }
        }
        Ok(())
    }

    /// The extended attribute `name` of `id` (flags and a copy of the payload).
    pub(crate) fn xattr(&self, tree: &Tree<'_, R>, id: u64, name: &[u8]) -> Result<Option<(u16, Vec<u8>)>> {
        let mut out = None;
        self.for_records(tree, id, T_XATTR, &mut |r| {
            if xattr_name(r.key())? == name {
                let (f, d) = parse_xattr(r.val())?;
                out = Some((f, d.to_vec()));
                return Ok(false);
            }
            Ok(true)
        })?;
        Ok(out)
    }

    pub(crate) fn stat_in(&self, tree: &Tree<'_, R>, id: u64) -> Result<Option<Stat>> {
        let Some(r) = self.find_inode(tree, id)? else { return Ok(None) };
        let mut size = match r.mode & S_IFMT {
            S_IFDIR | S_IFLNK => 0,
            _ => r.dstream_size.unwrap_or(0),
        };
        let mut compression = 0;
        if r.mode & S_IFMT == S_IFLNK {
            if let Some((_, d)) = self.xattr(tree, id, XA_SYMLINK)? {
                let end = d.iter().position(|&c| c == 0).unwrap_or(d.len());
                size = end as u64;
            }
        } else if r.mode & S_IFMT == S_IFREG && r.bsd_flags & UF_COMPRESSED != 0 {
            if let Some((f, d)) = self.xattr(tree, id, XA_DECMPFS)? {
                if let Some((t, s)) = decmpfs_header(&super::file::xattr_bytes(self, tree, f, &d)?) {
                    compression = t;
                    size = s;
                }
            }
        }
        Ok(Some(Stat::new(id, &r, size, compression)))
    }

    /// Looks one name up in a directory (case/normalization-insensitively on such volumes).
    pub(crate) fn lookup_child(&self, tree: &Tree<'_, R>, dir: u64, name: &str) -> Result<Option<u64>> {
        let fold = self.info.case_insensitive || self.info.normalization_insensitive;
        let want = if fold { fold_name(name, self.info.case_insensitive) } else { name.to_string() };
        let mut found = None;
        self.for_records(tree, dir, T_DREC, &mut |r| {
            let n = drec_name(r.key())?;
            let hit = if fold { fold_name(&String::from_utf8_lossy(n), self.info.case_insensitive) == want } else { n == name.as_bytes() };
            if hit {
                found = Some(parse_drec(r.val())?.0);
                return Ok(false);
            }
            Ok(true)
        })?;
        Ok(found)
    }
}

fn fold_name(s: &str, lower: bool) -> String {
    use unicode_normalization::UnicodeNormalization;
    let d: String = s.nfd().collect();
    if lower { d.chars().flat_map(|c| c.to_lowercase()).collect() } else { d }
}

#[derive(Default, Debug, Clone)]
pub struct FsckStats {
    /// Directories other than the root and the private directory (as the superblock counts them).
    pub dirs: u64,
    pub files: u64,
    pub symlinks: u64,
    pub others: u64,
    /// Names in the tree (directory records reachable from the root, the root not counted).
    pub nodes: u64,
    /// Inodes with more than one name.
    pub hardlink_groups: u64,
    /// Names beyond the first of those inodes.
    pub hardlink_extra_names: u64,
    /// Compressed files by decmpfs type (255: unknown type).
    pub compressed: BTreeMap<u32, u64>,
    /// Sum of the sizes of the regular files, each inode once (decompressed size for compressed files).
    pub total_size: u64,
    pub inodes: u64,
    pub unreachable_inodes: u64,
    pub dangling_names: u64,
    pub directory_cycles: u64,
    pub nlink_mismatches: u64,
    pub lossy_names: u64,
    pub records: u64,
    pub file_extents: u64,
    pub sparse_extents: u64,
    pub mapped_bytes: u64,
    pub bad_extents: u64,
    /// The counts the volume superblock keeps (files, directories, symlinks, other objects).
    pub sb_files: u64,
    pub sb_dirs: u64,
    pub sb_symlinks: u64,
    pub sb_others: u64,
}

impl FsckStats {
    /// Do the superblock's counters, the names and the inodes agree?
    pub fn consistent(&self) -> bool {
        self.unreachable_inodes == 0
            && self.dangling_names == 0
            && self.directory_cycles == 0
            && self.nlink_mismatches == 0
            && self.bad_extents == 0
            && self.files == self.sb_files
            && self.dirs == self.sb_dirs
            && self.symlinks == self.sb_symlinks
            && self.others == self.sb_others
    }
}

impl std::fmt::Display for FsckStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(
            f,
            "inodes {} (dirs {}, files {}, symlinks {}, other {})",
            self.inodes, self.dirs, self.files, self.symlinks, self.others
        )?;
        writeln!(
            f,
            "superblock counts: dirs {}, files {}, symlinks {}, other {}",
            self.sb_dirs, self.sb_files, self.sb_symlinks, self.sb_others
        )?;
        writeln!(f, "names {}, hard-link groups {} ({} extra names)", self.nodes, self.hardlink_groups, self.hardlink_extra_names)?;
        writeln!(f, "total file size {} bytes", self.total_size)?;
        for (t, n) in &self.compressed {
            writeln!(f, "compressed type {t}: {n}")?;
        }
        writeln!(
            f,
            "file extents {} ({} sparse, {} bytes mapped, {} bad)",
            self.file_extents, self.sparse_extents, self.mapped_bytes, self.bad_extents
        )?;
        writeln!(
            f,
            "unreachable inodes {}, dangling names {}, directory cycles {}, nlink mismatches {}, non-UTF-8 names {}",
            self.unreachable_inodes, self.dangling_names, self.directory_cycles, self.nlink_mismatches, self.lossy_names
        )?;
        write!(f, "{} tree records; consistent: {}", self.records, self.consistent())
    }
}
