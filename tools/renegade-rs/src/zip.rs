//! A read-only ZIP reader for IPSWs: the central directory (ZIP64 included), stored members as windows of
//! the archive (no copy, so a 7 GB dmg is read in place) and deflated members decoded whole (the small ones:
//! BuildManifest.plist, SystemVersion.plist).

use crate::bytes::{u16le, u32le, u64le};
use crate::io::{bad, ReadAt, Src, SubRange};
use std::io::Result;

#[derive(Debug, Clone)]
pub struct ZipEntry {
    pub name: String,
    /// 0 stored, 8 deflate
    pub method: u16,
    pub csize: u64,
    pub size: u64,
    pub crc: u32,
    header: u64,
}

pub struct Zip {
    src: Src,
    pub entries: Vec<ZipEntry>,
}

impl Zip {
    pub fn open(src: Src) -> Result<Self> {
        let total = src.size();
        let tail_len = total.min(65536 + 22 + 20 + 56) as usize;
        let tail = src.read_vec(total - tail_len as u64, tail_len)?;
        let e = tail.windows(4).rposition(|w| w == b"PK\x05\x06").ok_or_else(|| bad("not a zip file (no end of central directory)"))?;
        let mut count = u16le(&tail, e + 10) as u64;
        let mut cd_size = u32le(&tail, e + 12) as u64;
        let mut cd_off = u32le(&tail, e + 16) as u64;
        if (cd_off == 0xffff_ffff || cd_size == 0xffff_ffff || count == 0xffff) && e >= 20 && &tail[e - 20..e - 16] == b"PK\x06\x07" {
            let z64 = u64le(&tail, e - 20 + 8);
            let rec = src.read_vec(z64, 56)?;
            if &rec[..4] != b"PK\x06\x06" {
                return Err(bad("bad ZIP64 end of central directory"));
            }
            count = u64le(&rec, 32);
            cd_size = u64le(&rec, 40);
            cd_off = u64le(&rec, 48);
        }
        if cd_off.checked_add(cd_size).is_none_or(|x| x > total) || cd_size > (1 << 30) {
            return Err(bad("central directory out of range"));
        }
        let cd = src.read_vec(cd_off, cd_size as usize)?;
        let mut entries = Vec::new();
        let mut i = 0usize;
        while i + 46 <= cd.len() && &cd[i..i + 4] == b"PK\x01\x02" && (entries.len() as u64) < count {
            let method = u16le(&cd, i + 10);
            let crc = u32le(&cd, i + 16);
            let mut csize = u32le(&cd, i + 20) as u64;
            let mut size = u32le(&cd, i + 24) as u64;
            let (nl, xl, cl) = (u16le(&cd, i + 28) as usize, u16le(&cd, i + 30) as usize, u16le(&cd, i + 32) as usize);
            let mut header = u32le(&cd, i + 42) as u64;
            let name = String::from_utf8_lossy(cd.get(i + 46..i + 46 + nl).ok_or_else(|| bad("truncated central directory"))?).into_owned();
            let extra = cd.get(i + 46 + nl..i + 46 + nl + xl).ok_or_else(|| bad("truncated central directory"))?;
            let mut j = 0;
            while j + 4 <= extra.len() {
                let (id, len) = (u16le(extra, j), u16le(extra, j + 2) as usize);
                if id == 1 {
                    let mut k = j + 4;
                    let end = (j + 4 + len).min(extra.len());
                    let mut take = |v: &mut u64| {
                        if *v == 0xffff_ffff && k + 8 <= end {
                            *v = u64le(extra, k);
                            k += 8;
                        }
                    };
                    take(&mut size);
                    take(&mut csize);
                    take(&mut header);
                }
                j += 4 + len;
            }
            entries.push(ZipEntry { name, method, csize, size, crc, header });
            i += 46 + nl + xl + cl;
        }
        Ok(Zip { src, entries })
    }

    pub fn find(&self, name: &str) -> Option<&ZipEntry> {
        self.entries.iter().find(|e| e.name == name)
    }

    /// File offset of the member's data.
    pub fn data_offset(&self, e: &ZipEntry) -> Result<u64> {
        let h = self.src.read_vec(e.header, 30)?;
        if &h[..4] != b"PK\x03\x04" {
            return Err(bad(format!("{}: bad local header", e.name)));
        }
        Ok(e.header + 30 + u16le(&h, 26) as u64 + u16le(&h, 28) as u64)
    }

    /// A stored member as a window of the archive.
    pub fn stored(&self, e: &ZipEntry) -> Result<SubRange<Src>> {
        if e.method != 0 {
            return Err(bad(format!("{}: compressed member (method {}), expected a stored one", e.name, e.method)));
        }
        SubRange::new(self.src.clone(), self.data_offset(e)?, e.size)
    }

    /// The whole member, inflated if needed (checks the CRC-32).
    pub fn read_all(&self, e: &ZipEntry) -> Result<Vec<u8>> {
        if e.size > (2 << 30) {
            return Err(bad(format!("{}: too big to read whole", e.name)));
        }
        let raw = self.src.read_vec(self.data_offset(e)?, e.csize as usize)?;
        let out = match e.method {
            0 => raw,
            8 => miniz_oxide::inflate::decompress_to_vec_with_limit(&raw, e.size as usize + 1).map_err(|x| bad(format!("{}: inflate: {:?}", e.name, x.status)))?,
            m => return Err(bad(format!("{}: unsupported compression method {m}", e.name))),
        };
        if out.len() as u64 != e.size {
            return Err(bad(format!("{}: {} bytes, expected {}", e.name, out.len(), e.size)));
        }
        if crc32(&out) != e.crc {
            return Err(bad(format!("{}: CRC-32 mismatch", e.name)));
        }
        Ok(out)
    }
}

pub fn crc32(d: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in d {
        c ^= b as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ (0xEDB8_8320 & (!(c & 1)).wrapping_add(1));
        }
    }
    !c
}
