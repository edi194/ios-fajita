//! Android sparse images: raw -> sparse exactly like `tools/renegade/img2simg.py` (byte-identical output),
//! sparse -> raw like `simg2img.py`, and random access into a sparse image without expanding it (the
//! reader of `hfsx.py`).

use crate::bytes::{u16le, u32le};
use crate::io::{bad, ReadAt};
use std::io::{Read, Result, Seek, SeekFrom, Write};

pub const SPARSE_MAGIC: u32 = 0xED26_FF3A;
pub const RAW: u16 = 0xCAC1;
pub const FILL: u16 = 0xCAC2;
pub const DONT_CARE: u16 = 0xCAC3;
pub const CRC: u16 = 0xCAC4;
/// Blocks per RAW chunk (16 MiB at 4 KiB), as img2simg.py.
pub const CHUNK_MAX: usize = 4096;
/// Read size of img2simg.py / simg2img.py.
pub const PIECE: usize = 16 << 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Img2SimgStats {
    pub blocks: u32,
    pub chunks: u32,
}

/// Raw image -> sparse image. All-zero blocks become FILL chunks of zero, runs of other blocks RAW chunks
/// of at most 4096 blocks; the header is written last. Same bytes as `img2simg.py RAW OUT [--block BS]`.
pub fn img2simg<R: Read, W: Write + Seek>(mut raw: R, size: u64, mut out: W, bs: u32, mut progress: impl FnMut(u64, u64)) -> Result<Img2SimgStats> {
    let bsz = bs as usize;
    if bs == 0 || !size.is_multiple_of(bs as u64) || !PIECE.is_multiple_of(bsz) {
        return Err(bad("image size must be a multiple of the block size"));
    }
    let total = u32::try_from(size / bs as u64).map_err(|_| bad("image has more than 2^32 blocks"))?;
    out.write_all(&[0; 28])?;
    #[derive(PartialEq)]
    enum Kind {
        None,
        Raw,
        Zero,
    }
    let mut kind = Kind::None;
    let mut run: Vec<u8> = Vec::with_capacity(CHUNK_MAX * bsz);
    let mut zero_run: u32 = 0;
    let mut chunks: u32 = 0;
    let flush = |kind: &mut Kind, run: &mut Vec<u8>, zero_run: &mut u32, out: &mut W, chunks: &mut u32| -> Result<()> {
        match kind {
            Kind::Raw if !run.is_empty() => {
                let blocks = (run.len() / bsz) as u32;
                out.write_all(&RAW.to_le_bytes())?;
                out.write_all(&0u16.to_le_bytes())?;
                out.write_all(&blocks.to_le_bytes())?;
                out.write_all(&(12 + run.len() as u32).to_le_bytes())?;
                out.write_all(run)?;
                *chunks += 1;
            }
            Kind::Zero if *zero_run > 0 => {
                out.write_all(&FILL.to_le_bytes())?;
                out.write_all(&0u16.to_le_bytes())?;
                out.write_all(&zero_run.to_le_bytes())?;
                out.write_all(&16u32.to_le_bytes())?;
                out.write_all(&0u32.to_le_bytes())?;
                *chunks += 1;
            }
            _ => {}
        }
        *kind = Kind::None;
        run.clear();
        *zero_run = 0;
        Ok(())
    };
    let mut piece = vec![0u8; PIECE];
    let mut done: u64 = 0;
    while done < size {
        let n = PIECE.min((size - done) as usize);
        raw.read_exact(&mut piece[..n])?;
        for b in piece[..n].chunks(bsz) {
            if b.iter().all(|&c| c == 0) {
                if kind != Kind::Zero {
                    flush(&mut kind, &mut run, &mut zero_run, &mut out, &mut chunks)?;
                    kind = Kind::Zero;
                }
                zero_run += 1;
            } else {
                if kind != Kind::Raw || run.len() / bsz >= CHUNK_MAX {
                    flush(&mut kind, &mut run, &mut zero_run, &mut out, &mut chunks)?;
                    kind = Kind::Raw;
                }
                run.extend_from_slice(b);
            }
        }
        done += n as u64;
        progress(done, size);
    }
    flush(&mut kind, &mut run, &mut zero_run, &mut out, &mut chunks)?;
    out.seek(SeekFrom::Start(0))?;
    let mut h = Vec::with_capacity(28);
    h.extend_from_slice(&SPARSE_MAGIC.to_le_bytes());
    for v in [1u16, 0, 28, 12] {
        h.extend_from_slice(&v.to_le_bytes());
    }
    for v in [bs, total, chunks, 0] {
        h.extend_from_slice(&v.to_le_bytes());
    }
    out.write_all(&h)?;
    out.seek(SeekFrom::End(0))?;
    Ok(Img2SimgStats { blocks: total, chunks })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkKind {
    Raw { data: u64 },
    Fill { value: [u8; 4] },
    DontCare,
}

#[derive(Debug, Clone, Copy)]
pub struct Chunk {
    /// First byte of the expanded image this chunk covers.
    pub start: u64,
    pub len: u64,
    pub kind: ChunkKind,
}

/// A sparse image read in place: the chunk table maps expanded offsets to RAW data, FILL patterns or
/// DONT_CARE (reads as zeros). Implements [`ReadAt`] for the expanded image.
pub struct Sparse<R: ReadAt> {
    src: R,
    pub block_size: u32,
    pub total_blocks: u32,
    pub chunks: Vec<Chunk>,
}

impl<R: ReadAt> Sparse<R> {
    pub fn open(src: R) -> Result<Self> {
        let h = src.read_vec(0, 28)?;
        if u32le(&h, 0) != SPARSE_MAGIC {
            return Err(bad("not an Android sparse image"));
        }
        let hdr = u16le(&h, 8) as u64;
        let chdr = u16le(&h, 10) as u64;
        let bs = u32le(&h, 12);
        let tb = u32le(&h, 16);
        let nc = u32le(&h, 20);
        if bs == 0 || !bs.is_multiple_of(4) || chdr < 12 {
            return Err(bad("bad sparse header"));
        }
        let mut chunks = Vec::with_capacity(nc as usize);
        let mut off = hdr;
        let mut pos: u64 = 0;
        let mut buf = [0u8; 16];
        for i in 0..nc {
            src.read_at(off, &mut buf[..12])?;
            let t = u16le(&buf, 0);
            let sz = u32le(&buf, 4) as u64;
            let tot = u32le(&buf, 8) as u64;
            let data = off + chdr;
            let kind = match t {
                RAW => ChunkKind::Raw { data },
                FILL => {
                    let mut v = [0u8; 4];
                    src.read_at(data, &mut v)?;
                    ChunkKind::Fill { value: v }
                }
                DONT_CARE => ChunkKind::DontCare,
                CRC => {
                    off += tot;
                    continue;
                }
                _ => return Err(bad(format!("chunk {i}: unknown type {t:#x}"))),
            };
            chunks.push(Chunk { start: pos * bs as u64, len: sz * bs as u64, kind });
            pos += sz;
            off += tot;
        }
        if pos != tb as u64 {
            return Err(bad(format!("chunks cover {pos} blocks, header says {tb}")));
        }
        Ok(Self { src, block_size: bs, total_blocks: tb, chunks })
    }

    fn chunk_at(&self, off: u64) -> usize {
        self.chunks.partition_point(|c| c.start <= off) - 1
    }
}

impl<R: ReadAt> ReadAt for Sparse<R> {
    fn size(&self) -> u64 {
        self.total_blocks as u64 * self.block_size as u64
    }
    fn read_at(&self, mut off: u64, mut buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size() {
            return Err(crate::io::short(off));
        }
        while !buf.is_empty() {
            let c = &self.chunks[self.chunk_at(off)];
            let o = off - c.start;
            let k = (buf.len() as u64).min(c.len - o) as usize;
            let (head, rest) = buf.split_at_mut(k);
            match c.kind {
                ChunkKind::Raw { data } => self.src.read_at(data + o, head)?,
                // the pattern repeats from the chunk start
                ChunkKind::Fill { value } => head.iter_mut().enumerate().for_each(|(i, b)| *b = value[(o as usize + i) % 4]),
                ChunkKind::DontCare => head.fill(0),
            }
            off += k as u64;
            buf = rest;
        }
        Ok(())
    }
}

/// Sparse -> raw like `simg2img.py`: only RAW data that is not all zeros and non-zero FILLs are written
/// (`write(offset, bytes)`), everything else is left as a hole. Returns the expanded size; the caller sets
/// the output length to it first.
pub fn simg2img<R: ReadAt>(img: &Sparse<R>, mut write: impl FnMut(u64, &[u8]) -> Result<()>) -> Result<u64> {
    let mut buf = vec![0u8; PIECE];
    for c in &img.chunks {
        match c.kind {
            ChunkKind::Raw { data } => {
                let mut left = c.len;
                let mut o = 0;
                while left > 0 {
                    let k = (left as usize).min(PIECE);
                    img.src.read_at(data + o, &mut buf[..k])?;
                    if buf[..k].iter().any(|&b| b != 0) {
                        write(c.start + o, &buf[..k])?;
                    }
                    o += k as u64;
                    left -= k as u64;
                }
            }
            ChunkKind::Fill { value } if value != [0; 4] => {
                let mut left = c.len;
                let mut o = 0;
                let pat: Vec<u8> = value.iter().copied().cycle().take(PIECE).collect();
                while left > 0 {
                    let k = (left as usize).min(PIECE);
                    write(c.start + o, &pat[..k])?;
                    o += k as u64;
                    left -= k as u64;
                }
            }
            _ => {}
        }
    }
    Ok(img.size())
}

/// A sequential writer that turns the bytes it is given into an Android sparse image on the fly (zero blocks
/// become FILL chunks, runs of other blocks RAW chunks of at most [`CHUNK_MAX`] blocks, as [`img2simg`]); the
/// header, which holds the chunk count, is written by [`SparseWriter::finish`]. As a [`crate::io::WriteAt`] it
/// accepts only increasing offsets and fills gaps with zeros: the HFS writer produces the image in order.
pub struct SparseWriter<W: Write + Seek> {
    out: W,
    bs: usize,
    /// bytes accepted so far
    pos: u64,
    /// the block being filled
    cur: Vec<u8>,
    run: Vec<u8>,
    zero_run: u32,
    raw: bool,
    pub chunks: u32,
    blocks: u32,
}

impl<W: Write + Seek> SparseWriter<W> {
    pub fn new(mut out: W, bs: u32) -> Result<Self> {
        out.write_all(&[0; 28])?;
        Ok(Self { out, bs: bs as usize, pos: 0, cur: Vec::with_capacity(bs as usize), run: Vec::with_capacity(CHUNK_MAX * bs as usize), zero_run: 0, raw: false, chunks: 0, blocks: 0 })
    }

    fn flush(&mut self) -> Result<()> {
        if self.raw && !self.run.is_empty() {
            let blocks = (self.run.len() / self.bs) as u32;
            self.out.write_all(&RAW.to_le_bytes())?;
            self.out.write_all(&0u16.to_le_bytes())?;
            self.out.write_all(&blocks.to_le_bytes())?;
            self.out.write_all(&(12 + self.run.len() as u32).to_le_bytes())?;
            self.out.write_all(&self.run)?;
            self.chunks += 1;
        } else if !self.raw && self.zero_run > 0 {
            self.out.write_all(&FILL.to_le_bytes())?;
            self.out.write_all(&0u16.to_le_bytes())?;
            self.out.write_all(&self.zero_run.to_le_bytes())?;
            self.out.write_all(&16u32.to_le_bytes())?;
            self.out.write_all(&0u32.to_le_bytes())?;
            self.chunks += 1;
        }
        self.run.clear();
        self.zero_run = 0;
        Ok(())
    }

    fn block(&mut self, b: &[u8]) -> Result<()> {
        self.blocks += 1;
        if b.iter().all(|&c| c == 0) {
            if self.raw {
                self.flush()?;
                self.raw = false;
            }
            self.zero_run += 1;
        } else {
            if !self.raw || self.run.len() / self.bs >= CHUNK_MAX {
                self.flush()?;
                self.raw = true;
            }
            self.run.extend_from_slice(b);
        }
        Ok(())
    }

    /// Appends bytes.
    pub fn push(&mut self, mut d: &[u8]) -> Result<()> {
        self.pos += d.len() as u64;
        if !self.cur.is_empty() {
            let k = (self.bs - self.cur.len()).min(d.len());
            self.cur.extend_from_slice(&d[..k]);
            d = &d[k..];
            if self.cur.len() == self.bs {
                let b = std::mem::take(&mut self.cur);
                self.block(&b)?;
                self.cur = b;
                self.cur.clear();
            }
        }
        while d.len() >= self.bs {
            let (b, rest) = d.split_at(self.bs);
            self.block(b)?;
            d = rest;
        }
        self.cur.extend_from_slice(d);
        Ok(())
    }

    /// Appends `n` zero bytes.
    pub fn push_zeros(&mut self, mut n: u64) -> Result<()> {
        if !self.cur.is_empty() {
            let k = (self.bs - self.cur.len()).min(n as usize);
            let z = vec![0u8; k];
            self.push(&z)?;
            n -= k as u64;
        }
        let whole = n / self.bs as u64;
        if whole > 0 {
            self.pos += whole * self.bs as u64;
            if self.raw {
                self.flush()?;
                self.raw = false;
            }
            let mut left = whole;
            while left > 0 {
                let k = left.min((u32::MAX - self.zero_run) as u64);
                self.zero_run += k as u32;
                self.blocks += k as u32;
                left -= k;
                if left > 0 {
                    self.flush()?;
                }
            }
        }
        let rest = (n % self.bs as u64) as usize;
        if rest > 0 {
            self.push(&vec![0u8; rest])?;
        }
        Ok(())
    }

    pub fn position(&self) -> u64 {
        self.pos
    }

    /// Pads with zeros to `total` bytes (a multiple of the block size), writes the header and returns the output.
    pub fn finish(mut self, total: u64) -> Result<(W, Img2SimgStats)> {
        if total < self.pos || !total.is_multiple_of(self.bs as u64) {
            return Err(bad("sparse image size must cover what was written and be a multiple of the block size"));
        }
        self.push_zeros(total - self.pos)?;
        self.flush()?;
        let mut h = Vec::with_capacity(28);
        h.extend_from_slice(&SPARSE_MAGIC.to_le_bytes());
        for v in [1u16, 0, 28, 12] {
            h.extend_from_slice(&v.to_le_bytes());
        }
        let total_blocks = u32::try_from(total / self.bs as u64).map_err(|_| bad("image has more than 2^32 blocks"))?;
        for v in [self.bs as u32, total_blocks, self.chunks, 0] {
            h.extend_from_slice(&v.to_le_bytes());
        }
        self.out.seek(SeekFrom::Start(0))?;
        self.out.write_all(&h)?;
        self.out.seek(SeekFrom::End(0))?;
        self.out.flush()?;
        Ok((self.out, Img2SimgStats { blocks: total_blocks, chunks: self.chunks }))
    }
}

impl<W: Write + Seek> crate::io::WriteAt for SparseWriter<W> {
    fn write_at(&mut self, off: u64, data: &[u8]) -> Result<()> {
        if off < self.pos {
            return Err(bad(format!("sparse writer: write at {off} but {} bytes are already written (the image must be written in order)", self.pos)));
        }
        if off > self.pos {
            self.push_zeros(off - self.pos)?;
        }
        self.push(data)
    }
}

#[cfg(test)]
mod writer_tests {
    use super::*;
    use crate::io::WriteAt;
    use std::io::Cursor;

    #[test]
    fn matches_img2simg() {
        let bs = 4096usize;
        let mut raw = vec![0u8; 9000 * bs + 100];
        raw.truncate(9000 * bs);
        for (i, blk) in raw.chunks_mut(bs).enumerate() {
            if i % 7 < 3 || (4300..4400).contains(&i) {
                blk[(i * 31) % bs] = 1 + (i % 250) as u8;
            }
        }
        let mut want = Cursor::new(Vec::new());
        img2simg(&raw[..], raw.len() as u64, &mut want, 4096, |_, _| {}).unwrap();
        // pieces of odd sizes, with gaps that are zeros
        let mut w = SparseWriter::new(Cursor::new(Vec::new()), 4096).unwrap();
        let mut at = 0usize;
        let cuts = [1usize, 4095, 4097, 12345, 50_000, 1 << 20];
        let mut k = 0;
        while at < raw.len() {
            let n = cuts[k % cuts.len()].min(raw.len() - at);
            // a zero-only piece is passed as a gap
            if raw[at..at + n].iter().all(|&c| c == 0) && k % 2 == 0 {
                w.write_at(at as u64 + n as u64, &[]).unwrap();
                w.push_zeros(0).unwrap();
            } else {
                w.write_at(at as u64, &raw[at..at + n]).unwrap();
            }
            at += n;
            k += 1;
        }
        let (got, _) = w.finish(raw.len() as u64).unwrap();
        assert_eq!(got.into_inner(), want.into_inner());
    }
}
