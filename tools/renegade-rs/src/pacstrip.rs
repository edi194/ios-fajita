//! Renegade's core rewriter (`tools/renegade/pacstrip.py`): rewrite arm64e code to run on a CPU without
//! pointer authentication. Every rewrite is 4 bytes for 4 bytes, so no offset, branch target, unwind
//! table or fixup chain moves:
//!
//! ```text
//! RETAA/RETAB                 -> RET            BRAA/BRAB(Z) Xn      -> BR Xn       BLRAA/BLRAB(Z) -> BLR Xn
//! LDRAA/LDRAB Xt,[Xn,#i]{!}   -> LDR / LDUR     PAC*/AUT*/XPAC*      -> NOP
//! PACGA Xd,Xn,Xm              -> EOR Xd,Xn,Xm,ROR #13 (Xm = SP: MOV Xd,Xn)
//! ```
//!
//! HINT-space instructions (PACIBSP, AUTIBSP, BTI...) are already NOPs without PAuth and stay; FJCVTZS
//! has no 1:1 replacement and is only reported. Only executable sections are touched, minus
//! LC_DATA_IN_CODE ranges; every arm64 slice of a fat file is processed. Ad-hoc re-signing (`--sign`)
//! is not ported yet: it stays in pacstrip.py (codesign / ldid).

use crate::bytes::u32le;
use crate::io::bad;
use crate::macho::{code_ranges, load_commands, slices, LC_LOAD_DYLINKER, LC_SEGMENT_64};
use std::collections::BTreeMap;
use std::io::Result;

pub const NOP: u32 = 0xD503_201F;
pub const RET: u32 = 0xD65F_03C0;
const PREFIX: [u8; 6] = [0xD6, 0xD7, 0xDA, 0x9A, 0xF8, 0x1E];

#[inline]
pub fn in_prefix(w: u32) -> bool {
    PREFIX.contains(&((w >> 24) as u8))
}

/// `(Some(new), class)` for a rewrite, `(None, Some(class))` for a reported word that stays,
/// `(None, None)` for everything else. Same classes and encodings as pacstrip.py's `rewrite_word`.
pub fn rewrite_word(w: u32) -> (Option<u32>, Option<&'static str>) {
    let top = w >> 24;
    match top {
        0xD6 | 0xD7 => {
            if w == 0xD65F_0BFF {
                return (Some(RET), Some("RETAA"));
            }
            if w == 0xD65F_0FFF {
                return (Some(RET), Some("RETAB"));
            }
            let rn = (w >> 5) & 31;
            let b = w & 0x400 != 0;
            let z = w & 0x0100_0000 == 0;
            if w & 0xFEFF_F800 == 0xD61F_0800 {
                let cls = match (b, z) {
                    (false, false) => "BRAA",
                    (false, true) => "BRAAZ",
                    (true, false) => "BRAB",
                    (true, true) => "BRABZ",
                };
                return (Some(0xD61F_0000 | rn << 5), Some(cls));
            }
            if w & 0xFEFF_F800 == 0xD63F_0800 {
                let cls = match (b, z) {
                    (false, false) => "BLRAA",
                    (false, true) => "BLRAAZ",
                    (true, false) => "BLRAB",
                    (true, true) => "BLRABZ",
                };
                return (Some(0xD63F_0000 | rn << 5), Some(cls));
            }
            if w & 0xFFFF_F800 == 0xD69F_0800 {
                return (None, Some("ERETA*(unhandled)"));
            }
            (None, None)
        }
        0xDA => {
            if w & 0xFFFF_C000 == 0xDAC1_0000 {
                // pacstrip.py appends "Z" to the base name: PACIA + Z = "PACIAZ"
                const NAMES: [&str; 16] = [
                    "PACIA", "PACIB", "PACDA", "PACDB", "AUTIA", "AUTIB", "AUTDA", "AUTDB", "PACIAZ", "PACIBZ", "PACDAZ", "PACDBZ", "AUTIAZ", "AUTIBZ", "AUTDAZ", "AUTDBZ",
                ];
                let k = ((w >> 10) & 7) as usize + if w & 0x2000 != 0 { 8 } else { 0 };
                return (Some(NOP), Some(NAMES[k]));
            }
            if w & 0xFFFF_FBE0 == 0xDAC1_43E0 {
                return (Some(NOP), Some(if w & 0x400 != 0 { "XPACD" } else { "XPACI" }));
            }
            (None, None)
        }
        0x9A => {
            if w & 0xFFE0_FC00 == 0x9AC0_3000 {
                let (rd, rn, rm) = (w & 31, (w >> 5) & 31, (w >> 16) & 31);
                if rm == 31 {
                    return (Some(0xAA00_03E0 | rn << 16 | rd), Some("PACGA")); // MOV Xd, Xn
                }
                // EOR Xd, Xn, Xm, ROR #13: k must not depend on the registers (see pacstrip.py)
                let k = 13;
                return (Some(0xCA00_0000 | 3 << 22 | rm << 16 | k << 10 | rn << 5 | rd), Some("PACGA"));
            }
            (None, None)
        }
        0xF8 => {
            if w & 0xFF20_0400 == 0xF820_0400 {
                let m = (w >> 23) & 1;
                let s = (w >> 22) & 1;
                let imm9 = (w >> 12) & 0x1FF;
                let wb = (w >> 11) & 1;
                let (rn, rt) = ((w >> 5) & 31, w & 31);
                let imm = (((s << 9) | imm9) as i32 - if s != 0 { 1 << 10 } else { 0 }) * 8;
                let name = if m != 0 { "LDRAB" } else { "LDRAA" };
                if wb != 0 {
                    if (-256..=255).contains(&imm) {
                        return (Some(0xF840_0C00 | ((imm as u32) & 0x1FF) << 12 | rn << 5 | rt), Some(name));
                    }
                } else if imm >= 0 {
                    return (Some(0xF940_0000 | ((imm / 8) as u32) << 10 | rn << 5 | rt), Some(name));
                } else if imm >= -256 {
                    return (Some(0xF840_0000 | ((imm as u32) & 0x1FF) << 12 | rn << 5 | rt), Some(name));
                }
                return (None, Some(if m != 0 { "LDRAB(unencodable)" } else { "LDRAA(unencodable)" }));
            }
            (None, None)
        }
        0x1E => {
            if w & 0xFFFF_FC00 == 0x1E7E_0000 {
                return (None, Some("FJCVTZS(left)"));
            }
            (None, None)
        }
        _ => (None, None),
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Report {
    /// class -> count, sorted by name like pacstrip.py's summary.
    pub counts: BTreeMap<String, u64>,
    /// FJCVTZS sites: (section, file offset within the slice).
    pub fjcvtzs: Vec<(String, usize)>,
    /// Reported but not rewritten (verbose lines): (class, file offset within the slice).
    pub left: Vec<(String, usize)>,
}

impl Report {
    /// "BRAA=3, RETAB=10" or "no PAC code", as pacstrip.py prints.
    pub fn summary(&self) -> String {
        if self.counts.is_empty() {
            return "no PAC code".into();
        }
        self.counts.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join(", ")
    }
}

pub fn process_slice(buf: &mut [u8], base: usize, write: bool, rep: &mut Report) -> Result<()> {
    for (s, e, sec) in code_ranges(buf, base)? {
        let n = (e - s) / 4;
        for i in 0..n {
            let at = s + i * 4;
            let w = u32le(buf, at);
            if !in_prefix(w) {
                continue;
            }
            let (nw, cls) = rewrite_word(w);
            let Some(cls) = cls else { continue };
            *rep.counts.entry(cls.to_string()).or_default() += 1;
            match nw {
                None if cls.starts_with("FJCVTZS") => rep.fjcvtzs.push((sec.clone(), at - base)),
                None => rep.left.push((cls.to_string(), at - base)),
                Some(nw) if write => buf[at..at + 4].copy_from_slice(&nw.to_le_bytes()),
                Some(_) => {}
            }
        }
    }
    Ok(())
}

/// Replaces the LC_LOAD_DYLINKER path, repacking the load commands into the header slack.
pub fn repack_dylinker(buf: &mut [u8], base: usize, newpath: &str) -> Result<()> {
    let sizeofcmds = u32le(buf, base + 20) as usize;
    let mut first_content: Option<usize> = None;
    let mut blob = Vec::new();
    for lc in load_commands(buf, base)? {
        let mut data = buf[lc.off..lc.off + lc.size].to_vec();
        if lc.cmd == LC_SEGMENT_64 {
            let nsects = u32le(buf, lc.off + 64) as usize;
            for i in 0..nsects {
                let foff = u32le(buf, lc.off + 72 + i * 80 + 48) as usize;
                if foff != 0 && first_content.is_none_or(|f| foff < f) {
                    first_content = Some(foff);
                }
            }
        }
        if lc.cmd == LC_LOAD_DYLINKER {
            let mut p = newpath.as_bytes().to_vec();
            p.push(0);
            let size = (12 + p.len() + 7) & !7;
            data = Vec::with_capacity(size);
            data.extend_from_slice(&LC_LOAD_DYLINKER.to_le_bytes());
            data.extend_from_slice(&(size as u32).to_le_bytes());
            data.extend_from_slice(&12u32.to_le_bytes());
            data.extend_from_slice(&p);
            data.resize(size, 0);
        }
        blob.extend_from_slice(&data);
    }
    let limit = base + first_content.unwrap_or(1 << 30);
    if base + 32 + blob.len() > limit {
        return Err(bad(format!("not enough header slack for the new dylinker path ({} bytes short)", base + 32 + blob.len() - limit)));
    }
    let new_size = blob.len() as u32;
    let span = blob.len().max(sizeofcmds);
    blob.resize(span, 0);
    buf[base + 32..base + 32 + span].copy_from_slice(&blob);
    buf[base + 20..base + 24].copy_from_slice(&new_size.to_le_bytes());
    Ok(())
}

#[derive(Debug, Default, Clone)]
pub struct Options {
    pub write: bool,
    pub dylinker: Option<String>,
    /// Set the CPU subtype to arm64 (ALL).
    pub subtype_arm64: bool,
}

/// pacstrip.py on a whole file (every arm64 slice), in place in `buf`.
pub fn strip(buf: &mut [u8], opts: &Options) -> Result<Report> {
    let mut rep = Report::default();
    for base in slices(buf) {
        process_slice(buf, base, opts.write, &mut rep)?;
        if opts.write {
            if let Some(p) = &opts.dylinker {
                repack_dylinker(buf, base, p)?;
            }
            if opts.subtype_arm64 {
                let cs = u32le(buf, base + 8);
                buf[base + 8..base + 12].copy_from_slice(&(cs & 0xFF00_0000).to_le_bytes());
            }
        }
    }
    Ok(rep)
}
