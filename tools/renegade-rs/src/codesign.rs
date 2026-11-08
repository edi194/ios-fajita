//! Ad-hoc code signing the way `codesign -f -s - -i IDENT -o OPTIONS --entitlements ENTS` signs (pacstrip.py
//! `--sign` on macOS), so the re-signed root has the same bytes as the Python build's:
//!
//! - one SHA-256 CodeDirectory, version 0x20400 (0x20500 with the hardened runtime: + the SDK version of
//!   LC_BUILD_VERSION; 0x20100, without team and exec segment, for kexts), 16 KiB pages, code limit = the signature's offset, exec segment = __TEXT, special slots for
//!   Info.plist (the bundle's, or the embedded __TEXT,__info_plist section), the requirements, the bundle's
//!   CodeResources, the entitlements and the DER entitlements;
//! - an empty requirement set, the entitlements as given (XML) and as CoreEntitlements DER, an empty CMS wrapper;
//! - the signature where the old one was (a new one is appended to __LINKEDIT), in the space codesign reserves
//!   (its estimate, which counts a 0x20400 header, + 8, rounded up to 16), __LINKEDIT
//!   and LC_CODE_SIGNATURE resized, fat slices re-aligned; the padding keeps the bytes the file had there (codesign
//!   writes only the blob, so leftovers of the previous signature stay).
//!
//! [`resign`] keeps what pacstrip.py's `sign()` keeps: the identifier, the CS option flags and the entitlements of
//! the old signature.

use crate::bytes::{cstr, u32be, u32le, u64le};
use crate::io::bad;
use crate::plist::{self, Value};
use sha2::{Digest, Sha256};
use std::io::Result;

pub const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xFADE_0CC0;
pub const CSMAGIC_CODEDIRECTORY: u32 = 0xFADE_0C02;
pub const CSMAGIC_REQUIREMENTS: u32 = 0xFADE_0C01;
pub const CSMAGIC_ENTITLEMENTS: u32 = 0xFADE_7171;
pub const CSMAGIC_ENTITLEMENTS_DER: u32 = 0xFADE_7172;
pub const CSMAGIC_BLOBWRAPPER: u32 = 0xFADE_0B01;
/// CodeDirectory flags that are signing options (codesign -o), kept across a re-sign (renegade_platform.py).
pub const CS_FLAG_OPTIONS: u32 = 0x1 | 0x100 | 0x200 | 0x400 | 0x800 | 0x2000 | 0x10000;
pub const CS_ADHOC: u32 = 0x2;
pub const CS_RUNTIME: u32 = 0x10000;
const PAGE_SHIFT: u8 = 14;
const PAGE: usize = 1 << PAGE_SHIFT;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1D;
const LC_BUILD_VERSION: u32 = 0x32;
const MH_EXECUTE: u32 = 2;
const MH_KEXT_BUNDLE: u32 = 0xb;

pub type Hash = [u8; 32];

pub fn sha256(b: &[u8]) -> Hash {
    Sha256::digest(b).into()
}

/// What a signature says (the first arm64 slice's, as pacstrip.py's cs_identity / entitlements_xml read it).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Identity {
    pub ident: String,
    pub team: String,
    pub flags: u32,
    /// The XML entitlements blob's payload, verbatim.
    pub entitlements: Option<Vec<u8>>,
}

/// The blobs of the embedded signature of the slice at `base`: (slot type, whole blob).
fn blobs(b: &[u8], base: usize) -> Option<Vec<(u32, Vec<u8>)>> {
    let ncmds = u32le(b, base + 16);
    let mut off = base + 32;
    for _ in 0..ncmds {
        let cmd = u32le(b, off);
        let size = u32le(b, off + 4) as usize;
        if cmd == LC_CODE_SIGNATURE {
            let sb = base + u32le(b, off + 8) as usize;
            if b.len() < sb + 12 || u32be(b, sb) != CSMAGIC_EMBEDDED_SIGNATURE {
                return None;
            }
            let n = u32be(b, sb + 8) as usize;
            let mut out = Vec::new();
            for i in 0..n {
                let t = u32be(b, sb + 12 + 8 * i);
                let o = sb + u32be(b, sb + 16 + 8 * i) as usize;
                let l = u32be(b, o + 4) as usize;
                out.push((t, b.get(o..o + l)?.to_vec()));
            }
            return Some(out);
        }
        if size < 8 {
            return None;
        }
        off += size;
    }
    None
}

/// The page size (log2) of the first arm64 slice's CodeDirectory.
pub fn page_shift(b: &[u8]) -> Option<u8> {
    let base = *crate::macho::slices(b).first()?;
    let bl = blobs(b, base)?;
    bl.iter().find(|(t, x)| *t == 0 && u32be(x, 0) == CSMAGIC_CODEDIRECTORY).map(|(_, cd)| cd[39])
}

/// The identity of the first arm64 slice's signature, or None if unsigned or unparsable.
pub fn identity(b: &[u8]) -> Option<Identity> {
    let base = *crate::macho::slices(b).first()?;
    let bl = blobs(b, base)?;
    let (_, cd) = bl.iter().find(|(t, x)| *t == 0 && u32be(x, 0) == CSMAGIC_CODEDIRECTORY)?;
    let ver = u32be(cd, 8);
    let flags = u32be(cd, 12);
    let io = u32be(cd, 20) as usize;
    let ident = cstr(cd.get(io..)?);
    let team = if ver >= 0x20200 {
        let to = u32be(cd, 48) as usize;
        if to != 0 { cstr(cd.get(to..)?) } else { String::new() }
    } else {
        String::new()
    };
    let entitlements = bl.iter().find(|(t, x)| *t == 5 && u32be(x, 0) == CSMAGIC_ENTITLEMENTS).map(|(_, x)| x[8..].to_vec());
    Some(Identity { ident, team, flags, entitlements })
}

// ------------------------------------------------------------------------------------------------- DER entitlements

fn der_len(out: &mut Vec<u8>, n: usize) {
    if n < 0x80 {
        out.push(n as u8);
    } else {
        let bytes = (n as u64).to_be_bytes();
        let skip = bytes.iter().take_while(|&&x| x == 0).count();
        out.push(0x80 | (8 - skip) as u8);
        out.extend_from_slice(&bytes[skip..]);
    }
}

fn der_tlv(tag: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![tag];
    der_len(&mut out, body.len());
    out.extend_from_slice(body);
    out
}

fn der_int(n: i128) -> Vec<u8> {
    // minimal two's complement
    let bytes = n.to_be_bytes();
    let mut i = 0;
    while i < 15 && ((bytes[i] == 0 && bytes[i + 1] & 0x80 == 0) || (bytes[i] == 0xFF && bytes[i + 1] & 0x80 != 0)) {
        i += 1;
    }
    der_tlv(0x02, &bytes[i..])
}

fn der_value(v: &Value) -> Result<Vec<u8>> {
    Ok(match v.inner() {
        Value::Bool(b) => der_tlv(0x01, &[if *b { 0xFF } else { 0x00 }]),
        Value::String(s) => der_tlv(0x0C, s.as_bytes()),
        Value::Integer(i) => der_int(*i),
        Value::Array(a) => {
            let mut body = Vec::new();
            for x in a {
                body.extend(der_value(x)?);
            }
            der_tlv(0x30, &body)
        }
        Value::Dict(d) => der_tlv(0xB0, &der_dict_body(d)?),
        other => return Err(bad(format!("entitlement value {other:?} has no DER form"))),
    })
}

fn der_dict_body(d: &std::collections::BTreeMap<String, Value>) -> Result<Vec<u8>> {
    let mut body = Vec::new();
    for (k, v) in d {
        let mut pair = der_tlv(0x0C, k.as_bytes());
        pair.extend(der_value(v)?);
        body.extend(der_tlv(0x30, &pair));
    }
    Ok(body)
}

/// CoreEntitlements DER of an entitlements plist: [APPLICATION 16] { INTEGER 1, [16] { SEQUENCE {key, value} } }.
pub fn der_entitlements(xml: &[u8]) -> Result<Vec<u8>> {
    let v = plist::parse(xml)?;
    let d = v.as_dict().ok_or_else(|| bad("entitlements are not a dict"))?;
    let mut body = der_int(1);
    body.extend(der_tlv(0xB0, &der_dict_body(d)?));
    Ok(der_tlv(0x70, &body))
}

fn xml_esc(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c => out.push(c),
        }
    }
}

fn xml_value(v: &Value, out: &mut String) -> Result<()> {
    match v.inner() {
        Value::Bool(b) => out.push_str(if *b { "<true/>" } else { "<false/>" }),
        Value::String(s) => {
            out.push_str("<string>");
            xml_esc(s, out);
            out.push_str("</string>");
        }
        Value::Integer(i) => out.push_str(&format!("<integer>{i}</integer>")),
        Value::Array(a) => {
            out.push_str("<array>");
            for x in a {
                xml_value(x, out)?;
            }
            out.push_str("</array>");
        }
        Value::Dict(d) => {
            out.push_str("<dict>");
            for (k, x) in d {
                out.push_str("<key>");
                xml_esc(k, out);
                out.push_str("</key>");
                xml_value(x, out)?;
            }
            out.push_str("</dict>");
        }
        other => return Err(bad(format!("entitlement value {other:?} has no CoreEntitlements form"))),
    }
    Ok(())
}

/// The entitlements as `codesign -d --entitlements - --xml` prints them (what pacstrip.py reads and passes back
/// to codesign): the CoreEntitlements view written as compact XML, keys sorted, empty containers as
/// `<dict></dict>`.
pub fn codesign_xml(xml: &[u8]) -> Result<Vec<u8>> {
    let v = plist::parse(xml)?;
    let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"https://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\">");
    xml_value(&v, &mut s)?;
    s.push_str("</plist>\n");
    Ok(s.into_bytes())
}

/// codesign's exec segment flags: main binary, plus what the entitlements allow.
fn exec_seg_flags(filetype: u32, ents: Option<&Value>) -> u64 {
    let mut f = if filetype == MH_EXECUTE { 0x1 } else { 0 };
    let on = |k: &str| ents.and_then(|e| e.get(k)).is_some_and(|v| matches!(v.inner(), Value::Bool(true)));
    if filetype == MH_EXECUTE {
        if on("get-task-allow") {
            f |= 0x10 | 0x20; // CS_EXECSEG_ALLOW_UNSIGNED | CS_EXECSEG_DEBUGGER
        }
        if on("run-unsigned-code") {
            f |= 0x10;
        }
        if on("com.apple.private.cs.debugger") {
            f |= 0x20;
        }
        if on("dynamic-codesigning") {
            f |= 0x40; // CS_EXECSEG_JIT
        }
        if on("com.apple.private.skip-library-validation") {
            f |= 0x80;
        }
        if on("com.apple.private.amfi.can-load-cdhash") {
            f |= 0x100;
        }
        if on("com.apple.private.amfi.can-execute-cdhash") {
            f |= 0x200;
        }
    }
    f
}

// ------------------------------------------------------------------------------------------------- signing

/// What a new signature binds. `info_plist`: the bundle's Info.plist bytes (None: the embedded __info_plist
/// section, if any); `code_resources`: the bundle's _CodeSignature/CodeResources bytes.
#[derive(Debug, Clone, Default)]
pub struct Params {
    pub ident: String,
    /// Signing options (CS_FLAG_OPTIONS bits); CS_ADHOC is always added.
    pub flags: u32,
    pub entitlements: Option<Vec<u8>>,
    pub info_plist: Option<Vec<u8>>,
    pub code_resources: Option<Vec<u8>>,
    /// log2 of the hashed page size (None: 14, 16 KiB, what codesign writes for a binary it signs first);
    /// re-signing keeps the page size the old signature had (Apple's libramrod.dylib is signed with 4 KiB pages).
    pub page_shift: Option<u8>,
}

struct Seg {
    off: usize, // load command offset
    name: String,
    fileoff: u64,
    filesize: u64,
}

fn put32le(b: &mut [u8], o: usize, v: u32) {
    b[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn put64le(b: &mut [u8], o: usize, v: u64) {
    b[o..o + 8].copy_from_slice(&v.to_le_bytes());
}

fn blob(magic: u32, payload: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(8 + payload.len());
    b.extend_from_slice(&magic.to_be_bytes());
    b.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    b.extend_from_slice(payload);
    b
}

/// Signs one thin 64-bit Mach-O.
pub fn sign_slice(src: &[u8], p: &Params) -> Result<Vec<u8>> {
    if src.len() < 32 || u32le(src, 0) != crate::macho::MH_MAGIC_64 {
        return Err(bad("not a 64-bit Mach-O"));
    }
    let filetype = u32le(src, 12);
    let ncmds = u32le(src, 16) as usize;
    let sizeofcmds = u32le(src, 20) as usize;
    let mut segs: Vec<Seg> = Vec::new();
    let mut cs_lc: Option<usize> = None;
    let mut sdk: u32 = 0;
    let mut info_sect: Option<(usize, usize)> = None;
    let mut off = 32;
    for _ in 0..ncmds {
        let cmd = u32le(src, off);
        let size = u32le(src, off + 4) as usize;
        match cmd {
            LC_SEGMENT_64 => {
                let name = cstr(&src[off + 8..off + 24]);
                if name == "__TEXT" {
                    for i in 0..u32le(src, off + 64) as usize {
                        let so = off + 72 + i * 80;
                        if cstr(&src[so..so + 16]) == "__info_plist" {
                            info_sect = Some((u32le(src, so + 48) as usize, u64le(src, so + 40) as usize));
                        }
                    }
                }
                segs.push(Seg { off, name, fileoff: u64le(src, off + 40), filesize: u64le(src, off + 48) });
            }
            LC_CODE_SIGNATURE => cs_lc = Some(off),
            LC_BUILD_VERSION => sdk = u32le(src, off + 16),
            _ => {}
        }
        if size < 8 {
            return Err(bad("bad load command"));
        }
        off += size;
    }
    let linkedit = segs.iter().position(|s| s.name == "__LINKEDIT").ok_or_else(|| bad("no __LINKEDIT"))?;
    let text = segs.iter().find(|s| s.name == "__TEXT").ok_or_else(|| bad("no __TEXT"))?;
    let (text_off, text_size) = (text.fileoff, text.filesize);
    let mut b = src.to_vec();
    // where the signature goes: over the old one, or at the 16-byte aligned end of __LINKEDIT with a new command
    let dataoff = match cs_lc {
        Some(o) => u32le(src, o + 8) as usize,
        None => {
            let le = &segs[linkedit];
            let end = ((le.fileoff + le.filesize) as usize).next_multiple_of(16);
            let first_data = segs.iter().filter(|s| s.filesize > 0 && s.fileoff > 0).map(|s| s.fileoff as usize).min().unwrap_or(usize::MAX);
            if 32 + sizeofcmds + 16 > first_data {
                return Err(bad("no room for LC_CODE_SIGNATURE in the header"));
            }
            let at = 32 + sizeofcmds;
            put32le(&mut b, at, LC_CODE_SIGNATURE);
            put32le(&mut b, at + 4, 16);
            put32le(&mut b, 16, (ncmds + 1) as u32);
            put32le(&mut b, 20, (sizeofcmds + 16) as u32);
            cs_lc = Some(at);
            end
        }
    };
    let cs_lc = cs_lc.unwrap();
    b.truncate(dataoff);
    b.resize(dataoff, 0);

    // the blobs other than the CodeDirectory
    let req = blob(CSMAGIC_REQUIREMENTS, &[0, 0, 0, 0]);
    let ents_v = p.entitlements.as_deref().map(plist::parse).transpose()?;
    let ents = p.entitlements.as_deref().map(|x| blob(CSMAGIC_ENTITLEMENTS, x));
    let der = p.entitlements.as_deref().map(der_entitlements).transpose()?.map(|d| blob(CSMAGIC_ENTITLEMENTS_DER, &d));
    let cms = blob(CSMAGIC_BLOBWRAPPER, &[]);

    // special slots (index 1..=7): Info.plist, requirements, resources, application, entitlements, -, DER
    let info = p.info_plist.as_deref().map(sha256).or_else(|| info_sect.and_then(|(o, n)| src.get(o..o + n)).map(sha256));
    let mut special: [Option<Hash>; 8] = [None; 8];
    special[1] = info;
    special[2] = Some(sha256(&req));
    special[3] = p.code_resources.as_deref().map(sha256);
    special[5] = ents.as_deref().map(sha256);
    special[7] = der.as_deref().map(sha256);
    let nspecial = (1..=7).rev().find(|&i| special[i].is_some()).unwrap_or(0);

    let flags = CS_ADHOC | (p.flags & CS_FLAG_OPTIONS);
    // kexts get the 0x20100 layout (up to scatterOffset: no team, no exec segment)
    let version: u32 = if filetype == MH_KEXT_BUNDLE {
        0x20100
    } else if flags & CS_RUNTIME != 0 {
        0x20500
    } else {
        0x20400
    };
    let hdr = match version {
        0x20100 => 48,
        0x20500 => 96,
        _ => 88,
    };
    let code_limit = dataoff;
    let shift = p.page_shift.unwrap_or(PAGE_SHIFT);
    let page = 1usize << shift;
    let ncode = code_limit.div_ceil(page);
    let mut ident = p.ident.as_bytes().to_vec();
    ident.push(0);
    let hash_off = hdr + ident.len() + 32 * nspecial;
    let cd_len = hash_off + 32 * ncode;
    let mut cd = vec![0u8; cd_len];
    cd[0..4].copy_from_slice(&CSMAGIC_CODEDIRECTORY.to_be_bytes());
    cd[4..8].copy_from_slice(&(cd_len as u32).to_be_bytes());
    cd[8..12].copy_from_slice(&version.to_be_bytes());
    cd[12..16].copy_from_slice(&flags.to_be_bytes());
    cd[16..20].copy_from_slice(&(hash_off as u32).to_be_bytes());
    cd[20..24].copy_from_slice(&(hdr as u32).to_be_bytes());
    cd[24..28].copy_from_slice(&(nspecial as u32).to_be_bytes());
    cd[28..32].copy_from_slice(&(ncode as u32).to_be_bytes());
    cd[32..36].copy_from_slice(&(code_limit as u32).to_be_bytes());
    cd[36] = 32; // hash size
    cd[37] = 2; // SHA-256
    cd[38] = 0; // platform
    cd[39] = shift;
    // 40 spare2, 44 scatter, 48 team, 52 spare3, 56 codeLimit64: zero
    if version >= 0x20400 {
        cd[64..72].copy_from_slice(&text_off.to_be_bytes());
        cd[72..80].copy_from_slice(&text_size.to_be_bytes());
        cd[80..88].copy_from_slice(&exec_seg_flags(filetype, ents_v.as_ref()).to_be_bytes());
    }
    if version >= 0x20500 {
        cd[88..92].copy_from_slice(&sdk.to_be_bytes());
    }
    cd[hdr..hdr + ident.len()].copy_from_slice(&ident);
    for (i, h) in special.iter().enumerate().take(nspecial + 1).skip(1) {
        if let Some(h) = h {
            let at = hash_off - 32 * i;
            cd[at..at + 32].copy_from_slice(h);
        }
    }

    // the superblob, then its size decides the load command and __LINKEDIT, then the code hashes
    let mut parts: Vec<(u32, Vec<u8>)> = vec![(0, cd), (2, req)];
    if let Some(e) = ents {
        parts.push((5, e));
    }
    if let Some(d) = der {
        parts.push((7, d));
    }
    parts.push((0x10000, cms));
    let index_len = 12 + 8 * parts.len();
    let total: usize = index_len + parts.iter().map(|(_, x)| x.len()).sum::<usize>();
    // codesign reserves the size it estimates, rounded: its estimate counts an 88-byte CodeDirectory header (the
    // 0x20400 one) whatever the version, plus 8
    let datasize = (total + 88 - hdr + 8).next_multiple_of(16);
    put32le(&mut b, cs_lc + 8, dataoff as u32);
    put32le(&mut b, cs_lc + 12, datasize as u32);
    let le = &segs[linkedit];
    let new_filesize = (dataoff + datasize) as u64 - le.fileoff;
    put64le(&mut b, le.off + 48, new_filesize);
    put64le(&mut b, le.off + 32, new_filesize.next_multiple_of(PAGE as u64));
    // code hashes over the final header and data up to the signature
    {
        let cd = &mut parts[0].1;
        for i in 0..ncode {
            let pg = &b[i * page..((i + 1) * page).min(code_limit)];
            let at = hash_off + 32 * i;
            cd[at..at + 32].copy_from_slice(&sha256(pg));
        }
    }
    let mut sb = Vec::with_capacity(datasize);
    sb.extend_from_slice(&CSMAGIC_EMBEDDED_SIGNATURE.to_be_bytes());
    sb.extend_from_slice(&(total as u32).to_be_bytes());
    sb.extend_from_slice(&(parts.len() as u32).to_be_bytes());
    let mut o = index_len;
    for (t, x) in &parts {
        sb.extend_from_slice(&t.to_be_bytes());
        sb.extend_from_slice(&(o as u32).to_be_bytes());
        o += x.len();
    }
    for (_, x) in &parts {
        sb.extend_from_slice(x);
    }
    // the padding keeps what the file held there before (codesign writes only the blob), zeros past the old end
    for i in sb.len()..datasize {
        sb.push(src.get(dataoff + i).copied().unwrap_or(0));
    }
    b.extend_from_slice(&sb);
    Ok(b)
}

/// Signs a thin or fat file (every slice; fat slices re-aligned to their 2^align).
pub fn sign(file: &[u8], p: &Params) -> Result<Vec<u8>> {
    if file.len() >= 8 && u32be(file, 0) == crate::macho::FAT_MAGIC {
        let n = u32be(file, 4) as usize;
        let mut out_slices = Vec::new();
        for i in 0..n {
            let e = 8 + 20 * i;
            let (ct, cs, off, size, align) = (u32be(file, e), u32be(file, e + 4), u32be(file, e + 8) as usize, u32be(file, e + 12) as usize, u32be(file, e + 16));
            let s = sign_slice(&file[off..off + size], p)?;
            out_slices.push((ct, cs, off, align, s));
        }
        let mut out = file[..8 + 20 * n].to_vec();
        let mut pos = out_slices.first().map(|s| s.2).unwrap_or(0x4000);
        for (i, (ct, cs, _, align, s)) in out_slices.iter().enumerate() {
            pos = pos.next_multiple_of(1usize << align);
            let e = 8 + 20 * i;
            out[e..e + 4].copy_from_slice(&ct.to_be_bytes());
            out[e + 4..e + 8].copy_from_slice(&cs.to_be_bytes());
            out[e + 8..e + 12].copy_from_slice(&(pos as u32).to_be_bytes());
            out[e + 12..e + 16].copy_from_slice(&(s.len() as u32).to_be_bytes());
            out.resize(pos, 0);
            out.extend_from_slice(s);
            pos += s.len();
        }
        return Ok(out);
    }
    sign_slice(file, p)
}

/// pacstrip.py's sign(): a new ad-hoc signature keeping the old identifier, CS options and entitlements (re-read the
/// way pacstrip.py reads them, through `codesign -d --xml`: [`codesign_xml`]).
pub fn resign(file: &[u8], info_plist: Option<Vec<u8>>, code_resources: Option<Vec<u8>>) -> Result<Vec<u8>> {
    let old = identity(file).ok_or_else(|| bad("not signed: no identifier to keep"))?;
    let entitlements = old.entitlements.as_deref().map(codesign_xml).transpose()?;
    // codesign replaces a linker-signed signature (4 KiB pages) with a 16 KiB one, and keeps the page size of any other
    let keep = if old.flags & 0x2_0000 != 0 { None } else { page_shift(file) };
    let p = Params { ident: old.ident, flags: old.flags, entitlements, info_plist, code_resources, page_shift: keep };
    sign(file, &p)
}
