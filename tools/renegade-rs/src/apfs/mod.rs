//! A read-only APFS reader: container, volumes, the file-system tree as a unix tree, and file data
//! (extents, holes, and transparent decmpfs decompression). Everything reads through [`ReadAt`]
//! at offset 0 of the container, so a 9 GB decrypted dmg behind a decrypting reader works the same as
//! a file; the library does no file-system access of its own.
//!
//! ```no_run
//! use renegade::apfs::{Container, Kind};
//! use renegade::io::{FileAt, ReadAt};
//! # fn main() -> std::io::Result<()> {
//! let c = Container::open(FileAt::open("os.dmg")?)?;
//! let vol = c.volume(0)?;
//! vol.walk(&mut |n| {
//!     if n.kind == Kind::File {
//!         let f = vol.open_file(n.ino)?;
//!         let mut head = vec![0u8; f.size().min(16) as usize];
//!         f.read_at(0, &mut head)?;
//!     }
//!     Ok(())
//! })?;
//! # Ok(()) }
//! ```
//!
//! Scope: the current file-system tree of unencrypted volumes (sealed system volumes included; their
//! integrity and snapshot trees are not consulted for listing). Fusion containers and encrypted
//! volumes are refused with an error. Corrupt input produces `io::Error`s, never panics.

mod btree;
mod file;
mod fs;
pub(crate) mod lzbitmap;
pub(crate) mod lzvn;
mod obj;

pub use file::File;
pub use fs::FsckStats;

use crate::io::{ReadAt, bad};
use btree::{Cursor, Omap, Space, Tree as BTree};
use fs::*;
use obj::*;
use std::io::Result;
use std::rc::Rc;

const NXSB_MAGIC: u32 = 0x4253_584e; // "NXSB"
const APSB_MAGIC: u32 = 0x4253_5041; // "APSB"

/// APFS_INCOMPAT_* / APFS_FS_* bits.
pub const INCOMPAT_CASE_INSENSITIVE: u64 = 0x1;
pub const INCOMPAT_NORMALIZATION_INSENSITIVE: u64 = 0x8;
pub const INCOMPAT_SEALED_VOLUME: u64 = 0x20;
pub const FS_UNENCRYPTED: u64 = 0x1;

/// What a node is. `Other` carries the mode's file-type bits (`S_IFMT`: 0o140000 socket, 0o010000 fifo,
/// 0o020000 char device, 0o060000 block device, ...).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Dir,
    File,
    Symlink,
    Other(u16),
}

impl Kind {
    fn of(mode: u16) -> Kind {
        match mode & S_IFMT {
            S_IFDIR => Kind::Dir,
            S_IFREG => Kind::File,
            S_IFLNK => Kind::Symlink,
            m => Kind::Other(m),
        }
    }
}

/// The metadata of one inode, as `lstat` on a mounted volume shows it.
#[derive(Clone, Copy, Debug)]
pub struct Stat {
    /// The inode id (`st_ino`): names with the same `ino` are hard links of one file.
    pub ino: u64,
    /// The id the file's data stream is keyed by (the same as `ino` except for some clones).
    pub private_id: u64,
    pub kind: Kind,
    /// Permission bits including setuid/setgid/sticky (`mode & 0o7777`).
    pub mode: u16,
    pub uid: u32,
    pub gid: u32,
    /// Modification time, unix seconds.
    pub mtime: i64,
    /// Data size in bytes: the decompressed size for compressed files, the target length for symlinks, 0 for others.
    pub size: u64,
    /// Link count (for directories, entries + 2 as `st_nlink` shows).
    pub nlink: u32,
    /// decmpfs compression type (0: not compressed; 255: a type this reader does not know).
    pub compression: u32,
}

impl Stat {
    pub(crate) fn new(id: u64, r: &InodeRaw, size: u64, compression: u32) -> Stat {
        Stat {
            ino: id,
            private_id: r.private_id,
            kind: Kind::of(r.mode),
            mode: r.mode & 0o7777,
            uid: r.uid,
            gid: r.gid,
            mtime: mtime_secs(r.mtime_ns),
            size,
            nlink: if r.mode & S_IFMT == S_IFDIR { r.nlink.saturating_add(2).max(0) as u32 } else { r.nlink.max(0) as u32 },
            compression,
        }
    }

    fn of_ino(i: &Ino) -> Stat {
        Stat {
            ino: i.id,
            private_id: i.private_id,
            kind: Kind::of(i.mode),
            mode: i.mode & 0o7777,
            uid: i.uid,
            gid: i.gid,
            mtime: i.mtime,
            size: i.size,
            nlink: i.nlink.max(0) as u32,
            compression: i.cmp as u32,
        }
    }
}

/// One name in the tree, as [`Tree::walk`] and [`Volume::walk`] hand it out. Dereferences to [`Stat`].
pub struct Node<'a> {
    /// Path relative to the volume root, no leading slash; "" for the root. Names as stored (UTF-8).
    pub path: &'a str,
    /// The last component of `path` ("" for the root).
    pub name: &'a str,
    /// The symlink target for symlinks.
    pub target: Option<&'a str>,
    pub stat: Stat,
}

impl std::ops::Deref for Node<'_> {
    type Target = Stat;
    fn deref(&self) -> &Stat {
        &self.stat
    }
}

/// A volume's superblock, digested.
#[derive(Clone, Debug)]
pub struct VolumeInfo {
    /// Position in the container's volume array.
    pub index: usize,
    pub oid: u64,
    pub xid: u64,
    pub name: String,
    pub role: u16,
    pub uuid: [u8; 16],
    pub features: u64,
    pub readonly_compat_features: u64,
    pub incompat_features: u64,
    pub fs_flags: u64,
    pub case_insensitive: bool,
    pub normalization_insensitive: bool,
    pub sealed: bool,
    pub encrypted: bool,
    pub omap_oid: u64,
    pub root_tree_oid: u64,
    pub extentref_tree_oid: u64,
    pub snap_meta_tree_oid: u64,
    pub integrity_meta_oid: u64,
    pub fext_tree_oid: u64,
    pub num_files: u64,
    pub num_directories: u64,
    pub num_symlinks: u64,
    pub num_other: u64,
    pub num_snapshots: u64,
    /// Last modification, unix seconds.
    pub last_mod: i64,
}

impl VolumeInfo {
    pub fn role_name(&self) -> &'static str {
        match self.role {
            0 => "none",
            0x1 => "system",
            0x2 => "user",
            0x4 => "recovery",
            0x8 => "vm",
            0x10 => "preboot",
            0x20 => "installer",
            0x40 => "data",
            0x80 => "baseband",
            0xc0 => "update",
            0x100 => "xart",
            0x140 => "hardware",
            0x180 => "backup",
            0x240 => "enterprise",
            0x2c0 => "prelogin",
            _ => "other",
        }
    }
}

/// A volume snapshot (from the snapshot metadata tree).
#[derive(Clone, Debug)]
pub struct SnapshotInfo {
    /// The transaction id the snapshot was taken at.
    pub xid: u64,
    pub name: String,
    /// Unix seconds.
    pub create_time: i64,
    pub change_time: i64,
    /// The block holding the volume superblock as it was.
    pub sblock_oid: u64,
    pub flags: u32,
}

pub(crate) struct VolCore<R: ReadAt> {
    pub sh: Rc<Shared<R>>,
    pub omap: Omap,
    pub root_oid: u64,
    pub info: VolumeInfo,
    pub lzfse: file::LzCell,
}

/// An APFS container: the newest checkpoint of the superblock, the container object map and the volumes.
pub struct Container<R: ReadAt> {
    sh: Rc<Shared<R>>,
    xid: u64,
    omap: Omap,
    fs_oids: Vec<u64>,
    incompat: u64,
    uuid: [u8; 16],
}

impl<R: ReadAt> Container<R> {
    /// Opens the container that starts at offset 0 of `r` (the NXSB superblock at byte 0x20).
    pub fn open(r: R) -> Result<Self> {
        if r.size() < 4096 {
            return Err(bad("too small for an APFS container"));
        }
        let head = r.read_vec(0, 4096)?;
        if le32(&head, 32)? != NXSB_MAGIC {
            return Err(bad("no APFS container: NXSB magic not found at byte 0x20"));
        }
        let bs = le32(&head, 36)? as usize;
        if !(4096..=65536).contains(&bs) || !bs.is_power_of_two() {
            return Err(bad(format!("implausible APFS block size {bs}")));
        }
        let blk0 = r.read_vec(0, bs)?;
        if !checksum_ok(&blk0) {
            return Err(bad("container superblock (block 0): checksum mismatch"));
        }
        let nblocks = le64(&blk0, 40)?.min(r.size() / bs as u64);
        let sh = Shared::new(r, bs, nblocks);
        // The newest valid superblock of the checkpoint descriptor area (block 0 is only a copy of
        // some earlier one).
        let mut best = blk0.clone();
        let desc_base = le64(&blk0, 112)?;
        if desc_base >> 63 != 0 {
            return Err(bad("checkpoint descriptor area is not contiguous (not supported)"));
        }
        let desc_blocks = (le32(&blk0, 104)? & 0x7fff_ffff).min(4096) as u64;
        for i in 0..desc_blocks {
            let Ok(b) = sh.block(desc_base.saturating_add(i)) else { continue };
            if hdr_type(&b)? & TYPE_MASK == T_NX_SUPERBLOCK
                && le32(&b, 32)? == NXSB_MAGIC
                && le32(&b, 36)? as usize == bs
                && hdr_xid(&b)? > hdr_xid(&best)?
            {
                best = (*b).clone();
            }
        }
        if le64(&best, 64)? & 0x100 != 0 {
            return Err(bad("Fusion containers are not supported"));
        }
        let xid = hdr_xid(&best)?;
        let omap = Omap::open(&sh, le64(&best, 160)?, xid)?;
        let max_fs = (le32(&best, 180)? as usize).min(100);
        let mut fs_oids = Vec::with_capacity(max_fs);
        for i in 0..max_fs {
            fs_oids.push(le64(&best, 184 + 8 * i)?);
        }
        let mut uuid = [0u8; 16];
        uuid.copy_from_slice(&best[72..88]);
        Ok(Container { sh: Rc::new(sh), xid, omap, fs_oids, incompat: le64(&best, 64)?, uuid })
    }

    /// The transaction id of the checkpoint in use.
    pub fn xid(&self) -> u64 {
        self.xid
    }
    pub fn block_size(&self) -> u32 {
        self.sh.bs as u32
    }
    pub fn block_count(&self) -> u64 {
        self.sh.nblocks
    }
    pub fn uuid(&self) -> [u8; 16] {
        self.uuid
    }
    pub fn incompatible_features(&self) -> u64 {
        self.incompat
    }
    /// Sets how many blocks (B-tree nodes, checksummed) are kept in memory (default 8192).
    pub fn set_cache_blocks(&self, n: usize) {
        self.sh.set_cache_blocks(n);
    }
    /// (blocks read from the underlying reader, cache hits) so far.
    pub fn cache_stats(&self) -> (u64, u64) {
        (self.sh.misses.get(), self.sh.hits.get())
    }

    /// Every volume of the container.
    pub fn volumes(&self) -> Result<Vec<VolumeInfo>> {
        let mut v = Vec::new();
        for (i, &oid) in self.fs_oids.iter().enumerate() {
            if oid != 0 {
                v.push(self.vol_info(i, oid)?);
            }
        }
        Ok(v)
    }

    fn vol_info(&self, index: usize, oid: u64) -> Result<VolumeInfo> {
        let val =
            self.omap.lookup(&self.sh, oid)?.ok_or_else(|| bad(format!("volume object {oid:#x} is not in the container object map")))?;
        let b = self.sh.block(val.paddr)?;
        parse_volume_info(&b, index, oid)
    }

    /// Opens the volume in slot `index` (the `index` field of [`Container::volumes`]).
    pub fn volume(&self, index: usize) -> Result<Volume<R>> {
        let oid = *self.fs_oids.get(index).ok_or_else(|| bad(format!("no volume slot {index}")))?;
        if oid == 0 {
            return Err(bad(format!("volume slot {index} is empty")));
        }
        let info = self.vol_info(index, oid)?;
        if info.encrypted {
            return Err(bad(format!("volume {index} ({}) is encrypted (not supported)", info.name)));
        }
        let omap = Omap::open(&self.sh, info.omap_oid, info.xid)?;
        Ok(Volume(Rc::new(VolCore { sh: self.sh.clone(), omap, root_oid: info.root_tree_oid, info, lzfse: Default::default() })))
    }
}

fn parse_volume_info(b: &[u8], index: usize, oid: u64) -> Result<VolumeInfo> {
    if hdr_type(b)? & TYPE_MASK != T_FS || le32(&b, 32)? != APSB_MAGIC {
        return Err(bad("not a volume superblock (APSB)"));
    }
    if b.len() < 1100 {
        return Err(bad("volume superblock truncated"));
    }
    let incompat = le64(&b, 56)?;
    let flags = le64(&b, 264)?;
    let name_raw = &b[704..960];
    let end = name_raw.iter().position(|&c| c == 0).unwrap_or(256);
    let mut uuid = [0u8; 16];
    uuid.copy_from_slice(&b[240..256]);
    Ok(VolumeInfo {
        index,
        oid,
        xid: hdr_xid(b)?,
        name: String::from_utf8_lossy(&name_raw[..end]).into_owned(),
        role: le16(&b, 964)?,
        uuid,
        features: le64(&b, 40)?,
        readonly_compat_features: le64(&b, 48)?,
        incompat_features: incompat,
        fs_flags: flags,
        case_insensitive: incompat & INCOMPAT_CASE_INSENSITIVE != 0,
        normalization_insensitive: incompat & INCOMPAT_NORMALIZATION_INSENSITIVE != 0,
        sealed: incompat & INCOMPAT_SEALED_VOLUME != 0,
        encrypted: flags & FS_UNENCRYPTED == 0,
        omap_oid: le64(&b, 128)?,
        root_tree_oid: le64(&b, 136)?,
        extentref_tree_oid: le64(&b, 144)?,
        snap_meta_tree_oid: le64(&b, 152)?,
        integrity_meta_oid: le64(&b, 1024)?,
        fext_tree_oid: le64(&b, 1032)?,
        num_files: le64(&b, 184)?,
        num_directories: le64(&b, 192)?,
        num_symlinks: le64(&b, 200)?,
        num_other: le64(&b, 208)?,
        num_snapshots: le64(&b, 216)?,
        last_mod: (le64(&b, 256)? / 1_000_000_000) as i64,
    })
}

/// One volume's current file-system tree.
pub struct Volume<R: ReadAt>(pub(crate) Rc<VolCore<R>>);

impl<R: ReadAt> Clone for Volume<R> {
    fn clone(&self) -> Self {
        Volume(self.0.clone())
    }
}

impl<R: ReadAt> Volume<R> {
    pub fn info(&self) -> &VolumeInfo {
        &self.0.info
    }

    /// Scans the whole tree once and keeps a compact listing (about 100 bytes per name).
    pub fn tree(&self) -> Result<Tree> {
        let scan = fs::scan(&self.0)?;
        Ok(Tree { scan, info: self.0.info.clone() })
    }

    /// Lists every node, the root first, then depth first with children in byte order of their names.
    pub fn walk(&self, f: &mut dyn FnMut(&Node<'_>) -> Result<()>) -> Result<()> {
        self.tree()?.walk(f)
    }

    /// Counts what the tree holds and how well its parts agree (see [`FsckStats::consistent`]).
    pub fn fsck_stats(&self) -> Result<FsckStats> {
        Ok(self.tree()?.fsck())
    }

    /// `lstat` of one inode.
    pub fn stat(&self, ino: u64) -> Result<Option<Stat>> {
        let t = self.0.fs_tree()?;
        self.0.stat_in(&t, ino)
    }

    /// Resolves a path (no leading slash needed; "" is the root); intermediate symlinks are not followed.
    pub fn lookup(&self, path: &str) -> Result<Option<Stat>> {
        let t = self.0.fs_tree()?;
        let mut ino = ROOT_DIR_INO;
        for comp in path.split('/').filter(|c| !c.is_empty()) {
            match self.0.lookup_child(&t, ino, comp)? {
                Some(i) => ino = i,
                None => return Ok(None),
            }
        }
        self.0.stat_in(&t, ino)
    }

    /// The target of a symlink inode.
    pub fn read_link(&self, ino: u64) -> Result<String> {
        let t = self.0.fs_tree()?;
        let (_, d) = self.0.xattr(&t, ino, XA_SYMLINK)?.ok_or_else(|| bad(format!("inode {ino} has no symlink target")))?;
        let end = d.iter().position(|&c| c == 0).unwrap_or(d.len());
        Ok(String::from_utf8_lossy(&d[..end]).into_owned())
    }

    /// The names (and inode ids) in a directory, unsorted (B-tree order).
    pub fn read_dir(&self, ino: u64) -> Result<Vec<(String, u64)>> {
        let t = self.0.fs_tree()?;
        let mut out = Vec::new();
        self.0.for_records(&t, ino, T_DREC, &mut |r| {
            out.push((String::from_utf8_lossy(drec_name(r.key())?).into_owned(), parse_drec(r.val())?.0));
            Ok(true)
        })?;
        Ok(out)
    }

    /// The volume's snapshots, oldest first. [`Volume::walk`] and friends read the live tree, not these.
    pub fn snapshots(&self) -> Result<Vec<SnapshotInfo>> {
        let oid = self.0.info.snap_meta_tree_oid;
        let mut out = Vec::new();
        if oid == 0 {
            return Ok(out);
        }
        let t = BTree::open(&self.0.sh, Space::Phys, oid)?;
        let mut c = Cursor::first(&t);
        while let Some(r) = c.next()? {
            let (xid, ty) = key_hdr(r.key())?;
            if ty != 1 {
                continue;
            }
            let v = r.val();
            let name_len = le16(v, 48)? as usize;
            let name = v.get(50..50 + name_len).ok_or_else(|| bad("snapshot record truncated"))?;
            let end = name.iter().position(|&c| c == 0).unwrap_or(name.len());
            out.push(SnapshotInfo {
                xid,
                name: String::from_utf8_lossy(&name[..end]).into_owned(),
                create_time: (le64(v, 16)? / 1_000_000_000) as i64,
                change_time: (le64(v, 24)? / 1_000_000_000) as i64,
                sblock_oid: le64(v, 8)?,
                flags: le32(v, 44)?,
            });
        }
        Ok(out)
    }

    /// The volume as of a snapshot (its file-system tree and object map at that transaction).
    /// Not exercised against a real snapshot (none could be made on the test machine).
    pub fn at_snapshot(&self, xid: u64) -> Result<Volume<R>> {
        let snap = self.snapshots()?.into_iter().find(|s| s.xid == xid).ok_or_else(|| bad(format!("no snapshot with xid {xid}")))?;
        let b = self.0.sh.block(snap.sblock_oid)?;
        let mut info = parse_volume_info(&b, self.0.info.index, self.0.info.oid)?;
        info.xid = xid;
        let omap = Omap::open(&self.0.sh, info.omap_oid, xid)?;
        Ok(Volume(Rc::new(VolCore { sh: self.0.sh.clone(), omap, root_oid: info.root_tree_oid, info, lzfse: Default::default() })))
    }

    /// Opens a regular file's content for random access: the data stream (holes read as zeros) or,
    /// for decmpfs-compressed files, the transparently decompressed bytes.
    pub fn open_file(&self, ino: u64) -> Result<File<R>> {
        file::open(&self.0, ino)
    }

    /// Visits every record of the tree in key order: (object id, record type, key, value). For tools
    /// and tests; the record types are APFS's `J_TYPE_*`.
    pub fn for_each_record(&self, f: &mut dyn FnMut(u64, u8, &[u8], &[u8]) -> Result<()>) -> Result<()> {
        let t = self.0.fs_tree()?;
        let mut c = Cursor::first(&t);
        while let Some(r) = c.next()? {
            let (id, ty) = key_hdr(r.key())?;
            f(id, ty, r.key(), r.val())?;
        }
        Ok(())
    }
}

/// The compact listing of a volume: inodes, names, symlink targets.
pub struct Tree {
    scan: Scan,
    info: VolumeInfo,
}

impl Tree {
    /// Number of inodes.
    pub fn inode_count(&self) -> usize {
        self.scan.inodes.len()
    }

    /// Number of names (directory records).
    pub fn name_count(&self) -> usize {
        self.scan.drecs.len()
    }

    pub fn info(&self) -> &VolumeInfo {
        &self.info
    }

    pub fn stat(&self, ino: u64) -> Option<Stat> {
        let i = self.scan.inodes.binary_search_by(|x| x.id.cmp(&ino)).ok()?;
        Some(Stat::of_ino(&self.scan.inodes[i]))
    }

    fn children(&self, dir: u64) -> std::ops::Range<usize> {
        let d = &self.scan.drecs;
        let lo = d.partition_point(|x| x.parent < dir);
        let hi = d.partition_point(|x| x.parent <= dir);
        lo..hi
    }

    fn name_of(&self, d: &Drec) -> &str {
        let b = &self.scan.names[d.name as usize..d.name as usize + d.name_len as usize];
        // valid UTF-8 by construction (made lossy when collected)
        std::str::from_utf8(b).unwrap_or("")
    }

    /// Visits the root and then every name below it, depth first, children by byte order of the name.
    /// A directory reachable twice (corrupt tree) is listed again but not entered again.
    pub fn walk(&self, f: &mut dyn FnMut(&Node<'_>) -> Result<()>) -> Result<()> {
        let sc = &self.scan;
        let root = sc.inodes.binary_search_by(|x| x.id.cmp(&ROOT_DIR_INO)).map_err(|_| bad("the volume has no root directory inode"))?;
        let mut visited = vec![false; sc.inodes.len()];
        visited[root] = true;
        f(&Node { path: "", name: "", target: None, stat: Stat::of_ino(&sc.inodes[root]) })?;
        let mut path = String::new();
        // (children still to visit, length of their directory's path)
        let mut stack = vec![(self.children(ROOT_DIR_INO), 0usize)];
        while let Some((range, base)) = stack.last_mut() {
            if range.start >= range.end {
                stack.pop();
                continue;
            }
            let d = &sc.drecs[range.start];
            range.start += 1;
            let base = *base;
            let Ok(idx) = sc.inodes.binary_search_by(|x| x.id.cmp(&d.child)) else { continue };
            path.truncate(base);
            if !path.is_empty() {
                path.push('/');
            }
            let name_start = path.len();
            path.push_str(self.name_of(d));
            let ino = &sc.inodes[idx];
            let target = sc.targets.get(&ino.id).map(|s| s.as_str());
            f(&Node { path: &path, name: &path[name_start..], target, stat: Stat::of_ino(ino) })?;
            if ino.mode & S_IFMT == S_IFDIR && !visited[idx] {
                visited[idx] = true;
                let len = path.len();
                stack.push((self.children(ino.id), len));
            }
        }
        Ok(())
    }

    /// The counts and cross-checks (see [`FsckStats`]).
    pub fn fsck(&self) -> FsckStats {
        let sc = &self.scan;
        let mut s = FsckStats {
            inodes: sc.inodes.len() as u64,
            records: sc.stats.records,
            file_extents: sc.stats.extents,
            sparse_extents: sc.stats.sparse_extents,
            mapped_bytes: sc.stats.extent_bytes,
            bad_extents: sc.stats.bad_extents,
            lossy_names: sc.lossy_names,
            sb_files: self.info.num_files,
            sb_dirs: self.info.num_directories,
            sb_symlinks: self.info.num_symlinks,
            sb_others: self.info.num_other,
            ..Default::default()
        };
        for i in &sc.inodes {
            match i.mode & S_IFMT {
                S_IFDIR if i.id == 2 || i.id == 3 => {} // the root and the private directory are not in the superblock's count
                S_IFDIR => s.dirs += 1,
                S_IFREG => {
                    s.files += 1;
                    s.total_size += i.size;
                    if i.cmp != 0 {
                        *s.compressed.entry(i.cmp as u32).or_default() += 1;
                    }
                }
                S_IFLNK => s.symlinks += 1,
                _ => s.others += 1,
            }
            if i.mode & S_IFMT != S_IFDIR {
                if i.names > 1 {
                    s.hardlink_groups += 1;
                    s.hardlink_extra_names += i.names as u64 - 1;
                }
                if i.names > 0 && i.names as i64 != i.nlink as i64 {
                    s.nlink_mismatches += 1;
                }
            }
        }
        // names and reachability, by walking
        let mut seen = vec![false; sc.inodes.len()];
        let (mut names, mut cycles, mut dangling) = (0u64, 0u64, 0u64);
        if let Ok(root) = sc.inodes.binary_search_by(|x| x.id.cmp(&ROOT_DIR_INO)) {
            seen[root] = true;
            let mut stack = vec![self.children(ROOT_DIR_INO)];
            while let Some(range) = stack.last_mut() {
                if range.start >= range.end {
                    stack.pop();
                    continue;
                }
                let d = &sc.drecs[range.start];
                range.start += 1;
                names += 1;
                let Ok(idx) = sc.inodes.binary_search_by(|x| x.id.cmp(&d.child)) else {
                    dangling += 1;
                    continue;
                };
                let first = !seen[idx];
                seen[idx] = true;
                if sc.inodes[idx].mode & S_IFMT == S_IFDIR {
                    if first {
                        stack.push(self.children(sc.inodes[idx].id));
                    } else {
                        cycles += 1;
                    }
                }
            }
        }
        s.nodes = names;
        s.dangling_names = dangling;
        s.directory_cycles = cycles;
        // the private directory (inode 3) hangs off no name
        s.unreachable_inodes = sc.inodes.iter().zip(&seen).filter(|(i, s)| !**s && i.id > 3).count() as u64;
        s
    }
}
