//! Just enough Mach-O: arm64 slices of thin and fat files, load commands, executable ranges.

use crate::bytes::{cstr, u32be, u32le, u64be};
use crate::io::bad;
use std::io::Result;

pub const MH_MAGIC_64: u32 = 0xFEED_FACF;
pub const FAT_MAGIC: u32 = 0xCAFE_BABE;
pub const FAT_MAGIC_64: u32 = 0xCAFE_BABF;
pub const CPU_TYPE_ARM64: u32 = 0x0100_000C;
pub const LC_SEGMENT_64: u32 = 0x19;
pub const LC_DATA_IN_CODE: u32 = 0x29;
pub const LC_LOAD_DYLINKER: u32 = 0x0E;
pub const LC_CODE_SIGNATURE: u32 = 0x1D;
pub const LC_DYLD_CHAINED_FIXUPS: u32 = 0x8000_0034;
const S_ZEROFILL: u32 = 0x1;
const S_GB_ZEROFILL: u32 = 0xC;
const S_THREAD_LOCAL_ZEROFILL: u32 = 0x12;
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x8000_0000;
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x0000_0400;

/// File offsets of the arm64 slices (`[0]` for a thin file), as pacstrip.py's `slices()`.
pub fn slices(buf: &[u8]) -> Vec<usize> {
    if buf.len() < 8 {
        return vec![0];
    }
    let magic = u32be(buf, 0);
    if magic != FAT_MAGIC && magic != FAT_MAGIC_64 {
        return vec![0];
    }
    let n = u32be(buf, 4) as usize;
    let mut out = Vec::new();
    for i in 0..n {
        let (ct, off) = if magic == FAT_MAGIC {
            let e = 8 + i * 20;
            if e + 20 > buf.len() {
                break;
            }
            (u32be(buf, e), u32be(buf, e + 8) as usize)
        } else {
            let e = 8 + i * 32;
            if e + 32 > buf.len() {
                break;
            }
            (u32be(buf, e), u64be(buf, e + 8) as usize)
        };
        if ct == CPU_TYPE_ARM64 {
            out.push(off);
        }
    }
    out
}

#[derive(Debug, Clone, Copy)]
pub struct LoadCommand {
    pub cmd: u32,
    pub off: usize,
    pub size: usize,
}

/// The load commands of the 64-bit Mach-O at `buf[base..]`.
pub fn load_commands(buf: &[u8], base: usize) -> Result<Vec<LoadCommand>> {
    if buf.len() < base + 32 || u32le(buf, base) != MH_MAGIC_64 {
        return Err(bad("not a 64-bit little-endian Mach-O"));
    }
    let ncmds = u32le(buf, base + 16);
    let mut off = base + 32;
    let mut out = Vec::with_capacity(ncmds as usize);
    for _ in 0..ncmds {
        if off + 8 > buf.len() {
            return Err(bad("load commands run past the end"));
        }
        let cmd = u32le(buf, off);
        let size = u32le(buf, off + 4) as usize;
        out.push(LoadCommand { cmd, off, size });
        if size < 8 {
            return Err(bad(format!("load command of size {size}")));
        }
        off += size;
    }
    Ok(out)
}

/// Executable file ranges `(start, end, "SEG,sect")` of the slice at `base`, minus LC_DATA_IN_CODE ranges.
pub fn code_ranges(buf: &[u8], base: usize) -> Result<Vec<(usize, usize, String)>> {
    let mut sects = Vec::new();
    let mut dice = Vec::new();
    for lc in load_commands(buf, base)? {
        let off = lc.off;
        if lc.cmd == LC_SEGMENT_64 {
            let nsects = u32le(buf, off + 64) as usize;
            for i in 0..nsects {
                let so = off + 72 + i * 80;
                let sectname = cstr(&buf[so..so + 16]);
                let segname = cstr(&buf[so + 16..so + 32]);
                let ssize = crate::bytes::u64le(buf, so + 40) as usize;
                let foff = u32le(buf, so + 48) as usize;
                let flags = u32le(buf, so + 64);
                let stype = flags & 0xFF;
                if flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) != 0
                    && ![S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL].contains(&stype)
                    && foff != 0
                {
                    sects.push((base + foff, base + foff + ssize, format!("{segname},{sectname}")));
                }
            }
        } else if lc.cmd == LC_DATA_IN_CODE {
            let dataoff = u32le(buf, off + 8) as usize;
            let datasize = u32le(buf, off + 12) as usize;
            for j in 0..datasize / 8 {
                let e = base + dataoff + j * 8;
                let o = u32le(buf, e) as usize;
                let len = crate::bytes::u16le(buf, e + 4) as usize;
                dice.push((base + o, base + o + len));
            }
        }
    }
    let mut out = Vec::new();
    for (s, e, n) in sects {
        let mut pos = s;
        let mut inside: Vec<(usize, usize)> = dice.iter().copied().filter(|d| d.0 < e && d.1 > s).collect();
        inside.sort();
        for (ds, de) in inside {
            if ds > pos {
                out.push((pos, ds, n.clone()));
            }
            pos = pos.max(de);
        }
        if pos < e {
            out.push((pos, e, n));
        }
    }
    Ok(out)
}
