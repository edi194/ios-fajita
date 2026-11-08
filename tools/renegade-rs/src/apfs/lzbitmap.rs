//! LZBITMAP ("ZBM\x09" streams, decmpfs types 13 and 14), a decoder written from the format as
//! documented by libzbitmap (Corellium, MIT): 32 KiB chunks, each either stored or a sequence of
//! 8-byte groups where a bitmap says which bytes are literals and which repeat the byte one
//! "period" back.

use crate::io::bad;
use std::io::Result;

const MAGIC: &[u8; 4] = b"ZBM\x09";
const MAX_CHUNK: usize = 0x8000;
const BITMAPS: usize = 12;
const BITMAP_BYTES: usize = 17;

fn u24(b: &[u8], o: usize) -> usize {
    b[o] as usize | (b[o + 1] as usize) << 8 | (b[o + 2] as usize) << 16
}

#[derive(Clone, Copy, Default)]
struct Bmap {
    bits: u8,
    period_bytes: u8,
}

struct Chunk<'a> {
    c: &'a [u8],
    data: usize,
    m1: usize,
    m2: usize,
    /// Position in nibbles from the start of the chunk.
    m3: usize,
    period: usize,
    written: usize,
    dec: usize,
}

impl Chunk<'_> {
    fn nibble(&mut self) -> Result<u8> {
        let byte = *self.c.get(self.m3 / 2).ok_or_else(|| bad("LZBITMAP: metadata past the chunk"))?;
        let n = if self.m3 % 2 == 0 { byte & 0xf } else { byte >> 4 };
        self.m3 += 1;
        Ok(n)
    }

    fn apply(&mut self, bm: Bmap, out: &mut Vec<u8>) -> Result<()> {
        if bm.period_bytes > 0 {
            self.period = 0;
            for i in 0..bm.period_bytes as usize {
                let b = *self.c.get(self.m1).ok_or_else(|| bad("LZBITMAP: period past the chunk"))?;
                self.period |= (b as usize) << (8 * i);
                self.m1 += 1;
            }
        }
        if self.period == 0 {
            return Err(bad("LZBITMAP: zero period"));
        }
        for i in 0..8 {
            if self.written == self.dec {
                break;
            }
            if bm.bits >> i & 1 != 0 {
                let b = *self.c.get(self.data).ok_or_else(|| bad("LZBITMAP: literal past the chunk"))?;
                self.data += 1;
                out.push(b);
            } else {
                if out.len() < self.period {
                    return Err(bad("LZBITMAP: repeat reaches before the start"));
                }
                let b = out[out.len() - self.period];
                out.push(b);
            }
            self.written += 1;
        }
        Ok(())
    }

    fn apply_number(&mut self, n: u8, table: &[Bmap; BITMAPS], out: &mut Vec<u8>) -> Result<()> {
        match n {
            0xf => Err(bad("LZBITMAP: bad bitmap number")),
            3..=0xe => self.apply(table[n as usize - 3], out),
            _ => {
                let bits = *self.c.get(self.m2).ok_or_else(|| bad("LZBITMAP: bitmap past the chunk"))?;
                self.m2 += 1;
                self.apply(Bmap { bits, period_bytes: n }, out)
            }
        }
    }
}

fn chunk(c: &[u8], dec: usize, out: &mut Vec<u8>) -> Result<()> {
    if c.len() < 15 {
        return Err(bad("LZBITMAP: chunk too short"));
    }
    let (m1, m2, m3) = (u24(c, 6), u24(c, 9), u24(c, 12));
    if m1 >= c.len() || m2 >= c.len() || m3 >= c.len() {
        return Err(bad("LZBITMAP: metadata offsets out of range"));
    }
    if c.len() < BITMAP_BYTES {
        return Err(bad("LZBITMAP: chunk too short for its bitmaps"));
    }
    // twelve (bitmap, period byte count) records of 8 + 2 bits, packed LSB first, at the chunk's end
    let base = c.len() - BITMAP_BYTES;
    let mut table = [Bmap::default(); BITMAPS];
    let mut bit = 0usize;
    let mut take = |n: usize| -> Result<u8> {
        let mut v = 0u8;
        for i in 0..n {
            let byte = *c.get(base + bit / 8).ok_or_else(|| bad("LZBITMAP: bitmaps past the chunk"))?;
            v |= (byte >> (bit % 8) & 1) << i;
            bit += 1;
        }
        Ok(v)
    };
    for t in table.iter_mut() {
        t.bits = take(8)?;
        t.period_bytes = take(2)?;
        if t.period_bytes > 2 {
            return Err(bad("LZBITMAP: bad period size"));
        }
    }
    let mut st = Chunk { c, data: 15, m1, m2, m3: m3 * 2, period: 8, written: 0, dec };
    while st.written < dec {
        let n = st.nibble()?;
        // repetition count: absent for the last group, else 0xf starts a count of 4 + nibbles
        let mut repeat = 1usize;
        if dec - st.written > 8 {
            let nb = st.nibble()?;
            if nb == 0xf {
                repeat = 4;
                loop {
                    let k = st.nibble()?;
                    repeat += k as usize;
                    if k != 0xf {
                        break;
                    }
                }
            } else {
                st.m3 -= 1;
            }
        }
        for _ in 0..repeat {
            st.apply_number(n, &table, out)?;
        }
    }
    Ok(())
}

/// Decodes a whole "ZBM\x09" stream; the result must have exactly `out_len` bytes.
pub(crate) fn decode(src: &[u8], out_len: usize) -> Result<Vec<u8>> {
    if src.get(..4) != Some(&MAGIC[..]) {
        return Err(bad(format!("LZBITMAP: bad magic (first bytes {:02x?}, {} bytes, wanted {out_len})", &src[..src.len().min(12)], src.len())));
    }
    let mut out: Vec<u8> = Vec::with_capacity(out_len);
    let mut pos = 4;
    loop {
        let h = src.get(pos..pos + 6).ok_or_else(|| bad("LZBITMAP: truncated chunk header"))?;
        let (len, dec) = (u24(h, 0), u24(h, 3));
        if len < 6 || pos + len > src.len() || dec > MAX_CHUNK || out.len() + dec > out_len {
            return Err(bad("LZBITMAP: bad chunk header"));
        }
        let c = &src[pos..pos + len];
        if len == dec + 6 {
            out.extend_from_slice(&c[6..]);
        } else {
            let before = out.len();
            chunk(c, dec, &mut out)?;
            if out.len() - before != dec {
                return Err(bad("LZBITMAP: chunk decoded to the wrong length"));
            }
        }
        pos += len;
        if dec == 0 {
            break;
        }
    }
    Ok(out)
}
