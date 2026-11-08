//! In-place edits of an unjournaled HFS+/HFSX image: the owner/mode pass (`hfsroot_owners.py`, byte-identical),
//! the owner map file (`owners.tsv` of mkroot-full.py) and the free-block runs `hfs_trim.py` punches.

use crate::bytes::{u16be, u32be, u64be};
use crate::io::{bad, ReadAt, WriteAt};
use std::collections::{BTreeMap, HashMap};
use std::io::Result;
use unicode_normalization::UnicodeNormalization;

const ROOT_CNID: u32 = 2;
const HLNK: (u32, u32) = (0x686C_6E6B, 0x6866_732B);

/// relative path (NFD) -> (uid, gid, permission bits). "" is the root folder.
pub type OwnerMap = BTreeMap<String, (u32, u32, u32)>;

/// Parses an owners.tsv ("path\tuid\tgid\tmode-octal" per line), keys NFD-normalized as hfsroot_owners.py.
pub fn parse_map(text: &str) -> Result<OwnerMap> {
    let mut m = OwnerMap::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let [p, u, g, mode] = f[..] else { return Err(bad(format!("bad owner map line {line:?}"))) };
        let num = |s: &str| s.parse::<u32>().map_err(|_| bad(format!("bad number in {line:?}")));
        let mode = u32::from_str_radix(mode, 8).map_err(|_| bad(format!("bad mode in {line:?}")))?;
        m.insert(p.nfd().collect(), (num(u)?, num(g)?, mode));
    }
    Ok(m)
}

/// owners.tsv text exactly as mkroot-full.py's `write_map` (sorted keys; Python sorts by code point, so does
/// a BTreeMap of Strings).
pub fn format_map(m: &OwnerMap) -> String {
    let mut s = String::new();
    for (k, (u, g, mode)) in m {
        s.push_str(&format!("{k}\t{u}\t{g}\t{mode:o}\n"));
    }
    s
}

struct Vol<'a, I: ReadAt + WriteAt> {
    img: &'a mut I,
    bsize: u64,
    vh: Vec<u8>,
}

fn fork(vh: &[u8], off: usize) -> (u64, Vec<(u32, u32)>) {
    let logical = u64be(vh, off);
    let ext = (0..8).map(|i| (u32be(vh, off + 16 + 8 * i), u32be(vh, off + 20 + 8 * i))).filter(|e| e.1 != 0).collect();
    (logical, ext)
}

impl<I: ReadAt + WriteAt> Vol<'_, I> {
    fn read_extents(&self, ext: &[(u32, u32)], size: u64) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        for &(s, c) in ext {
            let at = out.len();
            out.resize(at + (c as u64 * self.bsize) as usize, 0);
            self.img.read_at(s as u64 * self.bsize, &mut out[at..])?;
        }
        out.truncate(size as usize);
        Ok(out)
    }

    /// The catalog's extents, through the extents-overflow B-tree when the volume header's 8 are not enough.
    fn catalog_extents(&self) -> Result<(u64, Vec<(u32, u32)>)> {
        let (logical, ext) = fork(&self.vh, 272);
        let have: u64 = ext.iter().map(|e| e.1 as u64).sum();
        let need = logical.div_ceil(self.bsize);
        if have >= need {
            return Ok((logical, ext));
        }
        let (el, eext) = fork(&self.vh, 192);
        let data = self.read_extents(&eext, el)?;
        let ns = u16be(&data, 14 + 18) as usize;
        let mut node = u32be(&data, 14 + 10) as usize;
        let mut extra = Vec::new();
        while node != 0 {
            let nd = &data[node * ns..(node + 1) * ns];
            let flink = u32be(nd, 0) as usize;
            for i in 0..u16be(nd, 10) as usize {
                let ro = u16be(nd, ns - 2 * (i + 1)) as usize;
                let klen = u16be(nd, ro) as usize;
                let (forkt, fid, start) = (nd[ro + 2], u32be(nd, ro + 4), u32be(nd, ro + 8));
                if fid == 4 && forkt == 0 {
                    for j in 0..8 {
                        let (s, c) = (u32be(nd, ro + 2 + klen + 8 * j), u32be(nd, ro + 6 + klen + 8 * j));
                        if c != 0 {
                            extra.push((start, s, c));
                        }
                    }
                }
            }
            node = flink;
        }
        extra.sort();
        let mut ext = ext;
        ext.extend(extra.into_iter().map(|(_, s, c)| (s, c)));
        if ext.iter().map(|e| e.1 as u64).sum::<u64>() < need {
            return Err(bad("catalog extents incomplete"));
        }
        Ok((logical, ext))
    }
}

/// What the owner pass did, printed like hfsroot_owners.py.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct OwnerStats {
    pub records: usize,
    pub leaf_nodes: usize,
    pub catalog_extents: usize,
    pub mapped: usize,
    pub defaulted: usize,
    pub links: usize,
    pub missing_inode: usize,
    pub skipped: usize,
    pub folder_counts_set: usize,
}

impl OwnerStats {
    /// The summary line of hfsroot_owners.py (a Python dict repr).
    pub fn line(&self) -> String {
        format!(
            "{} records in {} leaf nodes ({} catalog extents): {{'mapped': {}, 'defaulted': {}, 'links': {}, 'missing_inode': {}, 'skipped': {}, 'folder_counts_set': {}}}",
            self.records, self.leaf_nodes, self.catalog_extents, self.mapped, self.defaulted, self.links, self.missing_inode, self.skipped, self.folder_counts_set
        )
    }
}

fn utf16be(b: &[u8]) -> String {
    let u: Vec<u16> = b.chunks(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
    String::from_utf16_lossy(&u)
}

/// hfsroot_owners.py: real owners/modes from `map` on every catalog record (hard links: on their iNode),
/// with `default_root` everything else becomes 0:0 (mode kept); folder counts set on every folder.
pub fn apply_owners<I: ReadAt + WriteAt>(img: &mut I, map: &OwnerMap, default_root: bool) -> Result<OwnerStats> {
    let vh = img.read_vec(1024, 512)?;
    if &vh[..2] != b"H+" && &vh[..2] != b"HX" {
        return Err(bad("not HFS+/HFSX"));
    }
    if u32be(&vh, 4) & (1 << 13) != 0 {
        return Err(bad("volume is journaled (newfs_hfs without -J)"));
    }
    let bsize = u32be(&vh, 40) as u64;
    let vol = Vol { img, bsize, vh };
    let (logical, extents) = vol.catalog_extents()?;
    let mut cat = vol.read_extents(&extents, logical)?;
    let ns = u16be(&cat, 14 + 18) as usize;
    let first = u32be(&cat, 14 + 10) as usize;

    struct Rec {
        d: usize,
        rt: u16,
        parent: u32,
        name: String,
        cnid: u32,
    }
    let mut recs: Vec<Rec> = Vec::new();
    let mut thread_of: HashMap<u32, (u32, String)> = HashMap::new();
    let mut n = first;
    let mut leaf_nodes = 0;
    while n != 0 {
        let base = n * ns;
        let flink = u32be(&cat, base) as usize;
        if cat[base + 8] as i8 != -1 {
            return Err(bad(format!("node {n} is not a leaf")));
        }
        for i in 0..u16be(&cat, base + 10) as usize {
            let ro = base + u16be(&cat, base + ns - 2 * (i + 1)) as usize;
            let klen = u16be(&cat, ro) as usize;
            let parent = u32be(&cat, ro + 2);
            let nlen = u16be(&cat, ro + 6) as usize;
            let name = utf16be(&cat[ro + 8..ro + 8 + 2 * nlen]);
            let mut d = ro + 2 + klen;
            d += d & 1;
            match u16be(&cat, d) {
                3 => {
                    let tp = u32be(&cat, d + 4);
                    let tl = u16be(&cat, d + 8) as usize;
                    thread_of.insert(parent, (tp, utf16be(&cat[d + 10..d + 10 + 2 * tl])));
                }
                rt @ (1 | 2) => recs.push(Rec { d, rt, parent, name, cnid: u32be(&cat, d + 8) }),
                _ => {}
            }
        }
        n = flink;
        leaf_nodes += 1;
    }

    let mut cache: HashMap<u32, String> = HashMap::from([(ROOT_CNID, String::new())]);
    fn fpath(c: u32, thread_of: &HashMap<u32, (u32, String)>, cache: &mut HashMap<u32, String>) -> Result<String> {
        if let Some(p) = cache.get(&c) {
            return Ok(p.clone());
        }
        let (tp, nm) = thread_of.get(&c).ok_or_else(|| bad(format!("folder {c} has no thread record")))?.clone();
        let p = fpath(tp, thread_of, cache)?;
        let full = if p.is_empty() { nm } else { format!("{p}/{nm}") };
        cache.insert(c, full.clone());
        Ok(full)
    }
    let private = thread_of.iter().filter(|(_, (tp, nm))| *tp == ROOT_CNID && nm.starts_with("\0\0\0\0HFS+")).map(|(c, _)| *c).next();
    let mut inode: HashMap<u32, usize> = HashMap::new();
    for r in &recs {
        if r.rt == 2
            && Some(r.parent) == private
            && let Some(Ok(num)) = r.name.strip_prefix("iNode").map(str::parse::<u32>)
        {
            inode.insert(num, r.d);
        }
    }
    let mut st = OwnerStats { records: recs.len(), leaf_nodes, catalog_extents: extents.len(), ..Default::default() };
    let put = |cat: &mut Vec<u8>, d: usize, uid: u32, gid: u32, mode: Option<u32>| {
        cat[d + 32..d + 36].copy_from_slice(&uid.to_be_bytes());
        cat[d + 36..d + 40].copy_from_slice(&gid.to_be_bytes());
        if let Some(m) = mode {
            let old = u16be(cat, d + 42);
            cat[d + 42..d + 44].copy_from_slice(&((old & !0o7777) | (m as u16 & 0o7777)).to_be_bytes());
        }
    };
    for r in &recs {
        if Some(r.parent) == private && r.rt == 2 && r.name.starts_with("iNode") {
            continue;
        }
        if r.parent == 1 && r.rt == 1 {
            continue;
        }
        if r.rt == 2 && Some(r.parent) == private {
            continue;
        }
        let path = if r.parent != ROOT_CNID { fpath(r.parent, &thread_of, &mut cache)? } else { String::new() };
        let rel = if r.rt == 1 { fpath(r.cnid, &thread_of, &mut cache)? } else if path.is_empty() { r.name.clone() } else { format!("{path}/{}", r.name) };
        let mut target = r.d;
        if r.rt == 2 && (u32be(&cat, r.d + 48), u32be(&cat, r.d + 52)) == HLNK {
            let num = u32be(&cat, r.d + 44);
            st.links += 1;
            match inode.get(&num) {
                Some(&d) => target = d,
                None => {
                    st.missing_inode += 1;
                    continue;
                }
            }
        }
        if let Some(&(u, g, m)) = map.get(&rel) {
            put(&mut cat, target, u, g, Some(m));
            st.mapped += 1;
        } else if default_root {
            put(&mut cat, target, 0, 0, None);
            st.defaulted += 1;
        } else {
            st.skipped += 1;
        }
    }
    if default_root {
        for r in &recs {
            if r.rt == 1 && (r.cnid == ROOT_CNID || Some(r.cnid) == private) {
                match (r.cnid == ROOT_CNID).then(|| map.get("")).flatten() {
                    Some(&(u, g, m)) => put(&mut cat, r.d, u, g, Some(m)),
                    None => put(&mut cat, r.d, 0, 0, None),
                }
            }
        }
    }
    let mut subdirs: HashMap<u32, u32> = HashMap::new();
    for r in recs.iter().filter(|r| r.rt == 1) {
        *subdirs.entry(r.parent).or_default() += 1;
    }
    for r in recs.iter().filter(|r| r.rt == 1) {
        let flags = u16be(&cat, r.d + 2);
        if flags & 0x10 == 0 {
            cat[r.d + 2..r.d + 4].copy_from_slice(&(flags | 0x10).to_be_bytes());
            cat[r.d + 84..r.d + 88].copy_from_slice(&subdirs.get(&r.cnid).copied().unwrap_or(0).to_be_bytes());
            st.folder_counts_set += 1;
        }
    }
    // write the catalog back, extent by extent
    let mut pos = 0usize;
    for &(s, c) in &extents {
        let span = (c as u64 * bsize) as usize;
        if pos >= cat.len() {
            break;
        }
        let end = (pos + span).min(cat.len());
        vol.img.write_at(s as u64 * bsize, &cat[pos..end])?;
        pos += span;
    }
    Ok(st)
}

/// The free-block runs of the allocation bitmap, `(byte offset, byte length)`, as hfs_trim.py punches them.
/// (total blocks, block size, free runs as (byte offset, byte length)).
pub type FreeRuns = (u32, u32, Vec<(u64, u64)>);

pub fn free_runs<R: ReadAt>(img: &R) -> Result<FreeRuns> {
    let vh = img.read_vec(1024, 512)?;
    if &vh[..2] != b"H+" && &vh[..2] != b"HX" {
        return Err(bad("not HFS+/HFSX"));
    }
    let bsize = u32be(&vh, 40);
    let total = u32be(&vh, 44);
    let (_, ext) = fork(&vh, 112);
    let need = (total as u64).div_ceil(8);
    if ext.iter().map(|e| e.1 as u64).sum::<u64>() * bsize as u64 >= need {
        let mut bm = Vec::new();
        for &(s, c) in &ext {
            let at = bm.len();
            bm.resize(at + (c as u64 * bsize as u64) as usize, 0);
            img.read_at(s as u64 * bsize as u64, &mut bm[at..])?;
        }
        bm.truncate(need as usize);
        if !(bsize as u64).is_multiple_of(4096) {
            return Err(bad("block size is not a multiple of 4096"));
        }
        let mut runs = Vec::new();
        let mut start: Option<u32> = None;
        for blk in 0..=total {
            let used = blk == total || bm[(blk >> 3) as usize] & (0x80 >> (blk & 7)) != 0;
            match (used, start) {
                (false, None) => start = Some(blk),
                (true, Some(s)) => {
                    runs.push((s as u64 * bsize as u64, (blk - s) as u64 * bsize as u64));
                    start = None;
                }
                _ => {}
            }
        }
        return Ok((total, bsize, runs));
    }
    Err(bad("bitmap extents beyond the volume header (unsupported)"))
}
