//! The chained-fixup page-in check (`tools/renegade/fixupcheck.py`): walk every page's chain from its
//! page_start through the file's own bytes with the checks of xnu's vm_dyld_pager.c (the chain stays in its
//! page, a bind ordinal is below the import count). A file whose bytes no longer match its fixup tables
//! fails here instead of panicking the phone at boot.

use crate::bytes::{cstr, u16le, u32be, u32le, u64le};
use crate::macho::{CPU_TYPE_ARM64, FAT_MAGIC, LC_DYLD_CHAINED_FIXUPS, LC_SEGMENT_64, MH_MAGIC_64};

const START_NONE: u16 = 0xFFFF;

/// pointer_format -> (stride in bytes, mask of the "next" field after >> 51)
fn format(fmt: u16) -> Option<(u64, u64)> {
    match fmt {
        1 | 9 | 12 => Some((8, 0x7FF)),
        2 | 6 => Some((4, 0xFFF)),
        _ => None,
    }
}

/// Problems of the Mach-O slice at `b[base..base + size]`, worded as fixupcheck.py.
pub fn check_slice(b: &[u8], base: usize, size: usize, name: &str) -> Vec<String> {
    let mut out = Vec::new();
    if b.len() < base + 32 || u32le(b, base) != MH_MAGIC_64 || u32le(b, base + 4) != CPU_TYPE_ARM64 {
        return out;
    }
    let ncmds = u32le(b, base + 16);
    let mut segs: Vec<(String, u64, u64)> = Vec::new(); // (name, fileoff, filesize)
    let mut fix: Option<(usize, usize)> = None;
    let mut off = base + 32;
    for _ in 0..ncmds {
        if off + 8 > b.len() {
            return vec![format!("{name}: load commands run past the end")];
        }
        let cmd = u32le(b, off);
        let cmdsize = u32le(b, off + 4) as usize;
        if cmd == LC_SEGMENT_64 && off + 56 <= b.len() {
            segs.push((cstr(&b[off + 8..off + 24]), u64le(b, off + 40), u64le(b, off + 48)));
        } else if cmd == LC_DYLD_CHAINED_FIXUPS && off + 16 <= b.len() {
            fix = Some((u32le(b, off + 8) as usize, u32le(b, off + 12) as usize));
        }
        if cmdsize < 8 {
            return vec![format!("{name}: load command of size {cmdsize}")];
        }
        off += cmdsize;
    }
    let Some((dataoff, datasize)) = fix else { return out };
    let h = base + dataoff;
    if dataoff + datasize > size || h + 28 > b.len() {
        return vec![format!("{name}: chained fixups outside the file")];
    }
    let starts_off = u32le(b, h + 4) as usize;
    let imports_count = u32le(b, h + 16) as u64;
    let si = h + starts_off;
    let seg_count = u32le(b, si) as usize;
    for (s, (segname, fileoff, filesize)) in segs.iter().enumerate().take(seg_count) {
        let io = u32le(b, si + 4 + 4 * s) as usize;
        if io == 0 {
            continue;
        }
        let ss = si + io;
        let page_size = u16le(b, ss + 4) as u64;
        let fmt = u16le(b, ss + 6);
        let page_count = u16le(b, ss + 20) as u64;
        let Some((stride, nmask)) = format(fmt) else { continue };
        for p in 0..page_count {
            let start = u16le(b, ss + 22 + 2 * p as usize);
            if start == START_NONE {
                continue;
            }
            let page_file = fileoff + p * page_size;
            let (mut o, mut steps) = (start as u64, 0u64);
            loop {
                if o + 8 > page_size || page_file + o + 8 > fileoff + filesize || page_file + o + 8 > size as u64 {
                    out.push(format!(
                        "{name}: {segname} page {p}: chain at page offset {o:#x} leaves the page (page size {page_size:#x}, start {start:#x}, {steps} steps)"
                    ));
                    break;
                }
                let v = u64le(b, base + (page_file + o) as usize);
                if matches!(fmt, 1 | 9 | 12) && v >> 63 != 0 && (v >> 62) & 1 != 0 && (v & 0xFF_FFFF) >= imports_count {
                    out.push(format!("{name}: {segname} page {p}: bind ordinal {} >= {imports_count} imports", v & 0xFF_FFFF));
                    break;
                }
                let nxt = (v >> 51) & nmask;
                if nxt == 0 {
                    break;
                }
                o += nxt * stride;
                steps += 1;
            }
        }
    }
    out
}

/// fixupcheck.py's `check_bytes`: thin files and the first 32 slices of a fat file.
pub fn check_bytes(b: &[u8], name: &str) -> Vec<String> {
    if b.len() < 32 {
        return Vec::new();
    }
    if u32be(b, 0) == FAT_MAGIC {
        let n = u32be(b, 4) as usize;
        let mut res = Vec::new();
        for i in 0..n.min(32) {
            let e = 8 + 20 * i;
            if e + 20 > b.len() {
                break;
            }
            let off = u32be(b, e + 8) as usize;
            let sz = u32be(b, e + 12) as usize;
            if off + sz <= b.len() && sz >= 32 {
                res.extend(check_slice(b, off, sz, &format!("{name} (slice {i})")));
            }
        }
        return res;
    }
    if u32le(b, 0) == MH_MAGIC_64 {
        return check_slice(b, 0, b.len(), name);
    }
    Vec::new()
}

/// Whether the first bytes look like a thin 64-bit or a fat Mach-O (fixupcheck.py's filter).
pub fn looks_like_macho(head: &[u8]) -> bool {
    head.len() >= 4 && (head[..4] == [0xCF, 0xFA, 0xED, 0xFE] || head[..4] == [0xCA, 0xFE, 0xBA, 0xBE])
}
