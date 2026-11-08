//! The dyld shared cache stage of the root build (`pacstrip_cache.py` with `--stubs`, then `fips_rehmac.py
//! --patch`): every cache file (main + sub-caches) gets its executable sections (and the TEXT_STUBS mappings)
//! rewritten 4 bytes for 4 bytes by [`crate::pacstrip::rewrite_word`], corecrypto's FIPS integrity HMAC is
//! recomputed over the rewritten code, and the page hashes of every CodeDirectory of the file's embedded
//! signature are refreshed for the pages that changed.
//!
//! Nothing here changes a file's size, so the root build needs no planning pass over the data: [`Cache::open`]
//! reads only headers, tables and the load commands of the images ([`Cache::plan`]), and [`FilePlan::apply`]
//! transforms one file's bytes (a cache file is 256 MiB at most) when the image writer asks for them.

use crate::bytes::{u32be, u32le, u64le};
use crate::io::{bad, ReadAt, Src};
use crate::macho::{LC_DATA_IN_CODE, LC_SEGMENT_64};
use crate::pacstrip::{in_prefix, rewrite_word};
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha384};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Result;

const MH_MAGIC_64: u32 = 0xFEED_FACF;
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x8000_0000;
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x0000_0400;
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xFADE_0CC0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xFADE_0C02;
const DYLD_CACHE_MAPPING_TEXT_STUBS: u64 = 1 << 3;
/// Images whose LDRAA/LDRAB-looking words are real (pacstrip_cache.py DEFAULT_LDRA).
pub const DEFAULT_LDRA: [&str; 7] = ["libc++abi", "libobjc.A", "libc++.1", "libdispatch", "libsystem_", "libdyld", "dyld"];
pub const MAIN_NAME: &str = "dyld_shared_cache_arm64e";

#[derive(Debug, Clone)]
pub struct Options {
    /// also rewrite the TEXT_STUBS mappings (iOS 26: cross-image stubs ending in BRAA x16, x17)
    pub stubs: bool,
    /// recompute corecrypto's FIPS HMAC (fips_rehmac.py --patch)
    pub fips: bool,
    pub whitelist_ldra: Vec<String>,
}

impl Default for Options {
    fn default() -> Self {
        Options { stubs: true, fips: true, whitelist_ldra: DEFAULT_LDRA.iter().map(|s| s.to_string()).collect() }
    }
}

#[derive(Debug, Clone, Copy)]
struct Mapping {
    addr: u64,
    size: u64,
    off: u64,
    prot: u32,
    file: usize,
}

struct Header {
    mapping_off: u32,
    mapping_count: u32,
    sig_off: u64,
    sig_size: u64,
    dyld_in_cache_mh: u64,
    subcache_off: u32,
    subcache_count: u32,
    images_off: u32,
    images_count: u32,
    slide_off: u32,
    slide_count: u32,
}

fn read_header(src: &dyn ReadAt) -> Result<Header> {
    let n = src.size().min(0x200) as usize;
    let b = src.read_vec(0, n)?;
    if n < 0x1D0 || !b.starts_with(b"dyld_v1") {
        return Err(bad("not a dyld cache file"));
    }
    let mut h = Header {
        mapping_off: u32le(&b, 0x10),
        mapping_count: u32le(&b, 0x14),
        sig_off: u64le(&b, 0x28),
        sig_size: u64le(&b, 0x30),
        dyld_in_cache_mh: u64le(&b, 0x78),
        subcache_off: u32le(&b, 0x188),
        subcache_count: u32le(&b, 0x18C),
        images_off: u32le(&b, 0x1C0),
        images_count: u32le(&b, 0x1C4),
        slide_off: u32le(&b, 0x138),
        slide_count: u32le(&b, 0x13C),
    };
    if h.images_count == 0 {
        h.images_off = u32le(&b, 0x18);
        h.images_count = u32le(&b, 0x1C);
    }
    Ok(h)
}

/// The names of the main cache's sub-cache files (main name + suffix), from its header.
pub fn subcache_names(main: &dyn ReadAt) -> Result<Vec<String>> {
    let h = read_header(main)?;
    if h.subcache_count > 4096 {
        return Err(bad("implausible sub-cache count"));
    }
    let raw = main.read_vec(h.subcache_off as u64, h.subcache_count as usize * 56)?;
    Ok((0..h.subcache_count as usize)
        .map(|i| {
            let s = &raw[56 * i + 24..56 * i + 56];
            let z = s.iter().position(|&c| c == 0).unwrap_or(s.len());
            format!("{MAIN_NAME}{}", String::from_utf8_lossy(&s[..z]))
        })
        .collect())
}

/// What is to be done to one cache file.
#[derive(Debug, Default, Clone)]
pub struct FilePlan {
    /// (start, end, ldra_ok) file ranges of code to rewrite
    pub ranges: Vec<(u64, u64, bool)>,
    /// (file offset, bytes) written after the rewrite (the FIPS HMACs)
    pub patches: Vec<(u64, Vec<u8>)>,
    sig_off: u64,
    sig_size: u64,
}

impl FilePlan {
    pub fn is_empty(&self) -> bool {
        self.ranges.is_empty() && self.patches.is_empty()
    }
}

#[derive(Debug, Default, Clone)]
pub struct Stats {
    pub counts: BTreeMap<String, u64>,
    pub skipped: BTreeMap<String, u64>,
    pub pages_changed: u64,
    pub hashes_updated: u64,
}

pub struct Cache {
    files: Vec<(String, Src)>,
    /// sorted by address
    maps: Vec<Mapping>,
    stubs: HashMap<usize, Vec<(u64, u64)>>,
    main: usize,
    hdr: Header,
}

/// Rewrites the words of `data[range]` (4-byte aligned from its start) in place; returns the changed offsets
/// (relative to `base`, the file offset of data[0]) as 4 KiB page numbers.
fn rewrite_range(data: &mut [u8], base: u64, ldra_ok: bool, st: &mut Stats, pages: &mut BTreeSet<u64>) {
    let n = data.len() / 4;
    for i in 0..n {
        let o = i * 4;
        let w = u32le(data, o);
        if !in_prefix(w) {
            continue;
        }
        let (nw, cls) = rewrite_word(w);
        let Some(cls) = cls else { continue };
        let Some(nw) = nw else {
            let k = if cls.starts_with("FJCVTZS") { "FJCVTZS(left)".to_string() } else { cls.to_string() };
            *st.counts.entry(k).or_default() += 1;
            continue;
        };
        if cls.starts_with("LDRA") && !ldra_ok {
            *st.skipped.entry(cls.to_string()).or_default() += 1;
            continue;
        }
        *st.counts.entry(cls.to_string()).or_default() += 1;
        data[o..o + 4].copy_from_slice(&nw.to_le_bytes());
        pages.insert((base + o as u64) >> 12);
    }
}

impl Cache {
    /// `files`: every file of the cache by name (the main one is [`MAIN_NAME`]); only the headers are read here.
    pub fn open(mut files: Vec<(String, Src)>) -> Result<Self> {
        files.sort_by(|a, b| a.0.cmp(&b.0));
        let main = files.iter().position(|(n, _)| n == MAIN_NAME).ok_or_else(|| bad(format!("no {MAIN_NAME} in the cache directory")))?;
        let listed = subcache_names(&*files[main].1)?;
        let mut order: Vec<usize> = vec![main];
        for n in &listed {
            order.push(files.iter().position(|(m, _)| m == n).ok_or_else(|| bad(format!("{n}: sub-cache file missing")))?);
        }
        let mut maps = Vec::new();
        let mut stubs: HashMap<usize, Vec<(u64, u64)>> = HashMap::new();
        let mut hdr = None;
        for &fi in &order {
            let src = &files[fi].1;
            let h = read_header(&**src)?;
            let mp = src.read_vec(h.mapping_off as u64, h.mapping_count as usize * 32)?;
            for i in 0..h.mapping_count as usize {
                let e = &mp[32 * i..];
                maps.push(Mapping { addr: u64le(e, 0), size: u64le(e, 8), off: u64le(e, 16), prot: u32le(e, 28), file: fi });
            }
            if h.slide_count > 0 {
                let sp = src.read_vec(h.slide_off as u64, h.slide_count as usize * 56)?;
                for i in 0..h.slide_count as usize {
                    let e = &sp[56 * i..];
                    if u64le(e, 40) & DYLD_CACHE_MAPPING_TEXT_STUBS != 0 {
                        stubs.entry(fi).or_default().push((u64le(e, 16), u64le(e, 8)));
                    }
                }
            }
            if fi == main {
                hdr = Some(h);
            }
        }
        maps.sort_by_key(|m| m.addr);
        Ok(Cache { files, maps, stubs, main, hdr: hdr.unwrap() })
    }

    pub fn file_names(&self) -> impl Iterator<Item = &str> {
        self.files.iter().map(|(n, _)| n.as_str())
    }

    /// (file, file offset, initprot) of a VM address, if `length` bytes fit in one mapping.
    fn translate(&self, addr: u64, length: u64) -> Option<(usize, u64, u32)> {
        let i = self.maps.partition_point(|m| m.addr <= addr);
        let m = self.maps.get(i.checked_sub(1)?)?;
        if addr + length > m.addr + m.size {
            return None;
        }
        Some((m.file, m.off + (addr - m.addr), m.prot))
    }

    fn images(&self) -> Result<Vec<(u64, String)>> {
        let main = &*self.files[self.main].1;
        let h = &self.hdr;
        let raw = main.read_vec(h.images_off as u64, h.images_count as usize * 32)?;
        let mut out = Vec::new();
        for i in 0..h.images_count as usize {
            let e = &raw[32 * i..];
            let (addr, pathoff) = (u64le(e, 0), u32le(e, 24) as u64);
            let want = 512.min(main.size().saturating_sub(pathoff)) as usize;
            let b = main.read_vec(pathoff, want)?;
            let z = b.iter().position(|&c| c == 0).unwrap_or(b.len());
            out.push((addr, String::from_utf8_lossy(&b[..z]).into_owned()));
        }
        if h.dyld_in_cache_mh != 0 {
            out.push((h.dyld_in_cache_mh, "/usr/lib/dyld (in cache)".into()));
        }
        Ok(out)
    }

    /// The load commands of the Mach-O header at VM address `addr`: (file, file offset) of the header and the commands.
    fn load_commands(&self, addr: u64) -> Result<(usize, u64, Vec<u8>)> {
        let (fi, off, _) = self.translate(addr, 32).ok_or_else(|| bad(format!("image header at {addr:#x} is not mapped")))?;
        let src = &*self.files[fi].1;
        let h = src.read_vec(off, 32)?;
        if u32le(&h, 0) != MH_MAGIC_64 {
            return Err(bad(format!("bad Mach-O at {addr:#x}")));
        }
        let sizeofcmds = u32le(&h, 20) as usize;
        if sizeofcmds > (1 << 20) {
            return Err(bad("implausible load command size"));
        }
        Ok((fi, off, src.read_vec(off + 32, sizeofcmds)?))
    }

    /// Executable sections of an image: (file, start, end, section name).
    fn code_ranges(&self, addr: u64) -> Result<Vec<(usize, u64, u64)>> {
        let (_fi, _off, lc) = self.load_commands(addr)?;
        let ncmds = u32le(&self.files[_fi].1.read_vec(_off + 16, 4)?, 0) as usize;
        let mut p = 0usize;
        let mut out = Vec::new();
        for _ in 0..ncmds {
            if p + 8 > lc.len() {
                break;
            }
            let (cmd, size) = (u32le(&lc, p), u32le(&lc, p + 4) as usize);
            if size < 8 || p + size > lc.len() {
                return Err(bad("bad load command"));
            }
            if cmd == LC_SEGMENT_64 {
                let nsects = u32le(&lc, p + 64) as usize;
                for i in 0..nsects {
                    let so = p + 72 + 80 * i;
                    if so + 80 > lc.len() {
                        return Err(bad("bad section table"));
                    }
                    let (saddr, ssize) = (u64le(&lc, so + 32), u64le(&lc, so + 40));
                    let flags = u32le(&lc, so + 64);
                    if flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) != 0 && ssize != 0 {
                        let (f3, o3, _) = self.translate(saddr, ssize).ok_or_else(|| bad(format!("section at {saddr:#x}+{ssize:#x} is not inside one mapping")))?;
                        out.push((f3, o3, o3 + ssize));
                    }
                }
            } else if cmd == LC_DATA_IN_CODE {
                // cache images carry none (the cache builder strips them); pacstrip_cache.py computes and ignores them
            }
            p += size;
        }
        Ok(out)
    }

    /// corecrypto's `__text` (first, in __TEXT or __TEXT_EXEC) and `__fips_hmacs`: (file, offset, size) each.
    #[allow(clippy::type_complexity)]
    fn fips_sections(&self, addr: u64) -> Result<(Option<(usize, u64, u64)>, Option<(usize, u64, u64)>)> {
        let (fi, off, lc) = self.load_commands(addr)?;
        let ncmds = u32le(&self.files[fi].1.read_vec(off + 16, 4)?, 0) as usize;
        let (mut text, mut hm) = (None, None);
        let mut p = 0usize;
        let name = |b: &[u8]| -> Vec<u8> { b[..b.iter().position(|&c| c == 0).unwrap_or(b.len())].to_vec() };
        for _ in 0..ncmds {
            if p + 8 > lc.len() {
                break;
            }
            let (cmd, size) = (u32le(&lc, p), u32le(&lc, p + 4) as usize);
            if size < 8 || p + size > lc.len() {
                return Err(bad("bad load command"));
            }
            if cmd == LC_SEGMENT_64 {
                let seg = name(&lc[p + 8..p + 24]);
                let nsects = u32le(&lc, p + 64) as usize;
                for i in 0..nsects {
                    let so = p + 72 + 80 * i;
                    let sect = name(&lc[so..so + 16]);
                    let sseg = name(&lc[so + 16..so + 32]);
                    let (saddr, ssize) = (u64le(&lc, so + 32), u64le(&lc, so + 40));
                    if sect == b"__fips_hmacs" {
                        let (f2, o2, _) = self.translate(saddr, ssize).ok_or_else(|| bad("__fips_hmacs is not mapped"))?;
                        hm = Some((f2, o2, ssize));
                    }
                    if (seg == b"__TEXT" || seg == b"__TEXT_EXEC") && sect == b"__text" && (sseg == b"__TEXT" || sseg == b"__TEXT_EXEC") && text.is_none() {
                        let (f2, o2, _) = self.translate(saddr, ssize).ok_or_else(|| bad("__text is not mapped"))?;
                        text = Some((f2, o2, ssize));
                    }
                }
            }
            p += size;
        }
        Ok((text, hm))
    }

    /// Plans the whole cache: code ranges per file and the FIPS patches. Returns plans by file name.
    pub fn plan(&self, opts: &Options, progress: &mut dyn FnMut(&str)) -> Result<BTreeMap<String, FilePlan>> {
        let imgs = self.images()?;
        progress(&format!("{} cache files, {} images, {} mappings", self.files.len(), imgs.len(), self.maps.len()));
        let mut plans: BTreeMap<usize, FilePlan> = BTreeMap::new();
        for (fi, (_, src)) in self.files.iter().enumerate() {
            if let Ok(h) = read_header(&**src) {
                plans.insert(fi, FilePlan { sig_off: h.sig_off, sig_size: h.sig_size, ..Default::default() });
            }
        }
        let ldra = |path: &str| opts.whitelist_ldra.iter().any(|w| path.contains(w.as_str()));
        for (addr, path) in &imgs {
            let ok = ldra(path);
            for (fi, s, e) in self.code_ranges(*addr)? {
                plans.get_mut(&fi).ok_or_else(|| bad("code in a file without a cache header"))?.ranges.push((s, e, ok));
            }
        }
        if opts.stubs {
            for (fi, r) in &self.stubs {
                for &(off, size) in r {
                    plans.get_mut(fi).ok_or_else(|| bad("stubs in a file without a cache header"))?.ranges.push((off, off + size, false));
                }
            }
        }
        for p in plans.values_mut() {
            p.ranges.sort();
        }
        if opts.fips {
            for (addr, path) in &imgs {
                if !path.contains("crypto") && !path.contains("Crypto") {
                    continue;
                }
                let (text, hm) = self.fips_sections(*addr)?;
                let (Some((tf, to, tn)), Some((hf, ho, hn))) = (text, hm) else { continue };
                // HMAC over the bytes as they will be after the rewrite
                let mut t = self.files[tf].1.read_vec(to, tn as usize)?;
                let mut scratch = Stats::default();
                rewrite_range(&mut t, to, ldra(path), &mut scratch, &mut BTreeSet::new());
                let mut m = <Hmac<Sha256> as Mac>::new_from_slice(&[0u8]).expect("hmac key");
                m.update(&t);
                let calc = m.finalize().into_bytes().to_vec();
                let stored = self.files[hf].1.read_vec(ho, hn as usize)?;
                progress(&format!("{path}: FIPS HMAC {}", if stored == calc { "matches" } else { "recomputed" }));
                if stored != calc {
                    plans.get_mut(&hf).ok_or_else(|| bad("__fips_hmacs in a file without a cache header"))?.patches.push((ho, calc));
                }
            }
        }
        Ok(plans.into_iter().map(|(fi, p)| (self.files[fi].0.clone(), p)).collect())
    }
}

impl FilePlan {
    /// Transforms one cache file in place: rewrite the code ranges, write the patches, refresh the page hashes of
    /// the pages that changed. Returns what it did.
    pub fn apply(&self, data: &mut [u8]) -> Result<Stats> {
        let mut st = Stats::default();
        let mut pages = BTreeSet::new();
        for &(s, e, ok) in &self.ranges {
            let (s, e) = (s as usize, e as usize);
            if e > data.len() || s > e {
                return Err(bad("code range outside its cache file"));
            }
            rewrite_range(&mut data[s..e], s as u64, ok, &mut st, &mut pages);
        }
        for (off, bytes) in &self.patches {
            let o = *off as usize;
            data.get_mut(o..o + bytes.len()).ok_or_else(|| bad("patch outside its cache file"))?.copy_from_slice(bytes);
            pages.insert(*off >> 12);
        }
        st.pages_changed = pages.len() as u64;
        if !pages.is_empty() {
            st.hashes_updated = fix_signature(data, self.sig_off, self.sig_size, &pages)?;
        }
        Ok(st)
    }
}

/// Recomputes the page hashes of every CodeDirectory of the embedded signature for the changed 4 KiB pages.
fn fix_signature(d: &mut [u8], off: u64, size: u64, changed: &BTreeSet<u64>) -> Result<u64> {
    if size == 0 {
        return Ok(0);
    }
    let off = off as usize;
    if off + 12 > d.len() {
        return Err(bad("code signature outside its file"));
    }
    if u32be(d, off) != CSMAGIC_EMBEDDED_SIGNATURE {
        return Ok(0);
    }
    let count = u32be(d, off + 8) as usize;
    let mut updated = 0;
    for i in 0..count {
        let boff = u32be(d, off + 12 + 8 * i + 4) as usize;
        let cd = off + boff;
        if cd + 44 > d.len() {
            return Err(bad("CodeDirectory outside its file"));
        }
        if u32be(d, cd) != CSMAGIC_CODEDIRECTORY {
            continue;
        }
        let hash_off = u32be(d, cd + 16) as usize;
        let n_code = u32be(d, cd + 28) as usize;
        let code_limit = u32be(d, cd + 32) as usize;
        let (hash_size, hash_type, page_log2) = (d[cd + 36] as usize, d[cd + 37], d[cd + 39]);
        if !(1..=4).contains(&hash_type) {
            continue;
        }
        let ps = if page_log2 != 0 { 1usize << page_log2 } else { code_limit };
        if ps == 0 {
            continue;
        }
        let mut pset = BTreeSet::new();
        for &p4 in changed {
            let (lo, hi) = ((p4 << 12) as usize, ((p4 + 1) << 12) as usize);
            for p in lo / ps..=(hi - 1) / ps {
                pset.insert(p);
            }
        }
        for p in pset {
            if p >= n_code {
                continue;
            }
            let (a, b) = (p * ps, ((p + 1) * ps).min(code_limit));
            if b > d.len() || a > b {
                return Err(bad("signed range outside its file"));
            }
            let dig: Vec<u8> = match hash_type {
                1 => Sha1::digest(&d[a..b]).to_vec(),
                4 => Sha384::digest(&d[a..b]).to_vec(),
                _ => Sha256::digest(&d[a..b]).to_vec(),
            };
            let ho = cd + hash_off + p * hash_size;
            d.get_mut(ho..ho + hash_size).ok_or_else(|| bad("hash slot outside its file"))?.copy_from_slice(&dig[..hash_size]);
            updated += 1;
        }
    }
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::rc::Rc;

    fn put32(b: &mut [u8], o: usize, v: u32) {
        b[o..o + 4].copy_from_slice(&v.to_le_bytes());
    }
    fn put64(b: &mut [u8], o: usize, v: u64) {
        b[o..o + 8].copy_from_slice(&v.to_le_bytes());
    }

    /// One cache file with one image whose __text holds PAC code, a stubs mapping, and a CodeDirectory with
    /// 16 KiB pages, signed correctly.
    fn synthetic() -> Vec<u8> {
        let mut f = vec![0u8; 0x8000];
        f[..16].copy_from_slice(b"dyld_v1  arm64e\0");
        put32(&mut f, 0x10, 0x200); // mappings
        put32(&mut f, 0x14, 1);
        put64(&mut f, 0x28, 0x6000); // signature
        put64(&mut f, 0x30, 0x1000);
        put32(&mut f, 0x138, 0x240); // mappings with slide: one, flagged TEXT_STUBS
        put32(&mut f, 0x13C, 1);
        put32(&mut f, 0x1C0, 0x300); // images
        put32(&mut f, 0x1C4, 1);
        // mapping 0: the whole file, r-x
        put64(&mut f, 0x200, 0x1_8000_0000);
        put64(&mut f, 0x208, 0x8000);
        put64(&mut f, 0x210, 0);
        put32(&mut f, 0x21C, 5);
        // mapping with slide: stubs at file offset 0x5000, 0x100 bytes
        put64(&mut f, 0x240 + 8, 0x100);
        put64(&mut f, 0x240 + 16, 0x5000);
        put64(&mut f, 0x240 + 40, DYLD_CACHE_MAPPING_TEXT_STUBS);
        // image 0 at VM 0x180004000 (file 0x4000), path at 0x400
        put64(&mut f, 0x300, 0x1_8000_4000);
        put32(&mut f, 0x318, 0x400);
        f[0x400..0x400 + 24].copy_from_slice(b"/usr/lib/libobjc.A.dylib");
        // the Mach-O: one segment with one __text section at VM 0x180004200, 0x100 bytes
        let m = 0x4000;
        put32(&mut f, m, MH_MAGIC_64);
        put32(&mut f, m + 16, 1);
        put32(&mut f, m + 20, 72 + 80);
        put32(&mut f, m + 32, LC_SEGMENT_64);
        put32(&mut f, m + 36, 72 + 80);
        f[m + 40..m + 46].copy_from_slice(b"__TEXT");
        put32(&mut f, m + 32 + 64, 1);
        let s = m + 32 + 72;
        f[s..s + 6].copy_from_slice(b"__text");
        put64(&mut f, s + 32, 0x1_8000_4200);
        put64(&mut f, s + 40, 0x100);
        put32(&mut f, s + 64, S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
        for i in 0..0x40 {
            put32(&mut f, 0x4200 + 4 * i, if i % 2 == 0 { 0xD65F_0BFF } else { 0xD503_201F }); // RETAA / NOP
        }
        put32(&mut f, 0x5000, 0xD71F_0A10); // BRAA x16, x17 in the stubs
        // signature: SuperBlob (1 blob) + CodeDirectory, 2 pages of 16 KiB (the last one short)
        let sig = 0x6000;
        f[sig..sig + 4].copy_from_slice(&CSMAGIC_EMBEDDED_SIGNATURE.to_be_bytes());
        f[sig + 8..sig + 12].copy_from_slice(&1u32.to_be_bytes());
        f[sig + 16..sig + 20].copy_from_slice(&20u32.to_be_bytes());
        let cd = sig + 20;
        f[cd..cd + 4].copy_from_slice(&CSMAGIC_CODEDIRECTORY.to_be_bytes());
        f[cd + 16..cd + 20].copy_from_slice(&88u32.to_be_bytes()); // hashOffset
        f[cd + 28..cd + 32].copy_from_slice(&2u32.to_be_bytes()); // nCodeSlots
        f[cd + 32..cd + 36].copy_from_slice(&0x6000u32.to_be_bytes()); // codeLimit
        f[cd + 36] = 32;
        f[cd + 37] = 2;
        f[cd + 39] = 14;
        for p in 0..2 {
            let h = Sha256::digest(&f[p * 0x4000..((p + 1) * 0x4000).min(0x6000)]);
            f[cd + 88 + 32 * p..cd + 88 + 32 * p + 32].copy_from_slice(&h);
        }
        f
    }

    #[test]
    fn rewrites_code_stubs_and_page_hashes() {
        let orig = synthetic();
        let src: Src = Rc::new(orig.clone());
        let cache = Cache::open(vec![(MAIN_NAME.to_string(), src)]).unwrap();
        let plans = cache.plan(&Options::default(), &mut |_| {}).unwrap();
        let p = &plans[MAIN_NAME];
        assert_eq!(p.ranges.len(), 2, "the image's __text and the stubs");
        let mut d = orig.clone();
        let st = p.apply(&mut d).unwrap();
        assert_eq!(st.counts["RETAA"], 0x20);
        assert_eq!(st.counts["BRAA"], 1);
        assert_eq!(u32le(&d, 0x4200), 0xD65F_03C0, "RETAA -> RET");
        assert_eq!(u32le(&d, 0x4204), 0xD503_201F, "NOP stays");
        assert_eq!(u32le(&d, 0x5000), 0xD61F_0200 | (16 << 5) & 0x3E0, "BRAA x16, x17 -> BR x16");
        // only the touched 16 KiB page has a new hash, and it is the hash of the new bytes
        let cd = 0x6000 + 20 + 88;
        assert_eq!(d[cd..cd + 32], orig[cd..cd + 32], "page 0 untouched");
        assert_eq!(d[cd + 32..cd + 64], Sha256::digest(&d[0x4000..0x6000])[..]);
        assert_ne!(d[cd + 32..cd + 64], orig[cd + 32..cd + 64]);
        // without --stubs the stubs stay
        let plans = cache.plan(&Options { stubs: false, ..Default::default() }, &mut |_| {}).unwrap();
        let mut d2 = orig.clone();
        plans[MAIN_NAME].apply(&mut d2).unwrap();
        assert_eq!(u32le(&d2, 0x5000), 0xD71F_0A10);
    }
}
