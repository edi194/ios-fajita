//! File data: data-stream extents (with holes) and transparent decmpfs decompression.

use super::VolCore;
use super::btree::{Cursor, Space, Tree};
use super::fs::*;
use super::obj::*;
use crate::io::{ReadAt, bad, short};
use std::cell::RefCell;
use std::cmp::Ordering;
use std::io::Result;
use std::rc::Rc;

/// decmpfs chunk size of the resource-fork types.
const CHUNK: u64 = 65536;
/// Compressed chunks are never much larger than the 64 KiB they hold.
const MAX_CHUNK_RAW: u64 = CHUNK + 4096;
/// Whole-file decompression of the inline (xattr) types is bounded.
const MAX_INLINE: u64 = 64 << 20;
const CACHED_CHUNKS: usize = 8;

pub(crate) type LzCell = RefCell<Option<lzfse_rust::LzfseRingDecoder>>;

#[derive(Clone, Copy)]
struct Ext {
    logical: u64,
    len: u64,
    /// Physical block number; 0 is a hole.
    phys: u64,
}

struct Stream {
    exts: Vec<Ext>,
}

impl Stream {
    fn read<R: ReadAt>(&self, sh: &Shared<R>, off: u64, buf: &mut [u8]) -> Result<()> {
        let bs = sh.bs as u64;
        let end = off + buf.len() as u64;
        let mut pos = off;
        while pos < end {
            let idx = self.exts.partition_point(|e| e.logical <= pos);
            let mut src = None;
            let n;
            match idx.checked_sub(1).map(|i| self.exts[i]) {
                Some(e) if pos < e.logical.saturating_add(e.len) => {
                    n = (end - pos).min(e.logical.saturating_add(e.len) - pos);
                    if e.phys != 0 {
                        let base = e.phys.checked_mul(bs).ok_or_else(|| bad("extent address overflows"))?;
                        src = Some(base.checked_add(pos - e.logical).ok_or_else(|| bad("extent address overflows"))?);
                    }
                }
                _ => {
                    let next = self.exts.get(idx).map_or(u64::MAX, |e| e.logical);
                    n = (end - pos).min(next - pos);
                }
            }
            let dst = &mut buf[(pos - off) as usize..][..n as usize];
            match src {
                Some(o) => sh.read_bytes(o, dst)?,
                None => dst.fill(0),
            }
            pos += n;
        }
        Ok(())
    }
}

enum Rsrc {
    Embedded(Vec<u8>),
    Stream(Stream, u64),
}

impl Rsrc {
    fn size(&self) -> u64 {
        match self {
            Rsrc::Embedded(v) => v.len() as u64,
            Rsrc::Stream(_, n) => *n,
        }
    }
    fn read<R: ReadAt>(&self, sh: &Shared<R>, off: u64, len: usize) -> Result<Vec<u8>> {
        let end = off.checked_add(len as u64).ok_or_else(|| short(off))?;
        if end > self.size() {
            return Err(bad("resource fork read past its end"));
        }
        match self {
            Rsrc::Embedded(v) => Ok(v[off as usize..end as usize].to_vec()),
            Rsrc::Stream(s, _) => {
                let mut b = vec![0; len];
                s.read(sh, off, &mut b)?;
                Ok(b)
            }
        }
    }
}

enum Body {
    Stream(Stream),
    /// decmpfs data in the attribute itself, decoded on first use.
    Inline {
        ty: u32,
        raw: Vec<u8>,
        decoded: RefCell<Option<Rc<Vec<u8>>>>,
    },
    /// 64 KiB chunks in the resource fork: (offset in the fork, compressed length) of each.
    Chunked {
        ty: u32,
        rsrc: Rsrc,
        blocks: Vec<(u64, u32)>,
        cache: RefCell<Vec<(usize, Rc<Vec<u8>>)>>,
    },
}

/// A regular file's content, random access: [`ReadAt`] over the decompressed bytes.
pub struct File<R: ReadAt> {
    vol: Rc<VolCore<R>>,
    size: u64,
    compression: u32,
    body: Body,
}

impl<R: ReadAt> File<R> {
    /// The decmpfs type the file is stored with (0: not compressed).
    pub fn compression(&self) -> u32 {
        self.compression
    }

    /// Where the file's data starts in the container (lowest physical byte of its extents; `u64::MAX` for a
    /// file stored in its attributes): visiting many files in this order reads the image front to back.
    pub fn physical_hint(&self) -> u64 {
        let bs = self.vol.sh.bs as u64;
        let first = |s: &Stream| s.exts.iter().filter(|e| e.phys != 0).map(|e| e.phys.saturating_mul(bs)).min().unwrap_or(u64::MAX);
        match &self.body {
            Body::Stream(s) => first(s),
            Body::Chunked { rsrc: Rsrc::Stream(s, _), .. } => first(s),
            _ => u64::MAX,
        }
    }
}

/// The bytes of an extended attribute's value: inline, or read through its data stream.
pub(crate) fn xattr_bytes<R: ReadAt>(vol: &VolCore<R>, tree: &Tree<'_, R>, flags: u16, data: &[u8]) -> Result<Vec<u8>> {
    if flags & XATTR_DATA_EMBEDDED != 0 {
        return Ok(data.to_vec());
    }
    if flags & XATTR_DATA_STREAM == 0 {
        return Err(bad("extended attribute has no data"));
    }
    let id = le64(data, 0)?;
    let size = le64(data, 8)?;
    if size > MAX_INLINE {
        return Err(bad(format!("extended attribute stream of {size} bytes is too large")));
    }
    let s = load_extents(vol, tree, id)?;
    let mut b = vec![0u8; size as usize];
    s.read(&vol.sh, 0, &mut b)?;
    Ok(b)
}

fn load_extents<R: ReadAt>(vol: &VolCore<R>, tree: &Tree<'_, R>, id: u64) -> Result<Stream> {
    let mut exts: Vec<Ext> = Vec::new();
    fn add(exts: &mut Vec<Ext>, id: u64, logical: u64, v: &[u8]) -> Result<()> {
        let len = le64(v, 0)? & 0x00ff_ffff_ffff_ffff;
        let phys = le64(v, 8)?;
        if len == 0 || exts.last().is_some_and(|l| l.logical.saturating_add(l.len) > logical) {
            return Err(bad(format!("file extents of object {id:#x} are empty or overlap")));
        }
        exts.push(Ext { logical, len, phys });
        Ok(())
    }
    vol.for_records(tree, id, T_FILE_EXTENT, &mut |r| {
        add(&mut exts, id, le64(r.key(), 8)?, r.val())?;
        Ok(true)
    })?;
    if exts.is_empty() && vol.info.fext_tree_oid != 0 {
        // sealed volumes keep the extents in a separate physical tree keyed by (private id, logical address)
        let ft = Tree::open(&vol.sh, Space::Phys, vol.info.fext_tree_oid)?;
        let mut c = Cursor::seek(&ft, &|k| match (le64(k, 0), le64(k, 8)) {
            (Ok(a), Ok(b)) => (a, b).cmp(&(id, 0)),
            _ => Ordering::Less,
        })?;
        while let Some(r) = c.next()? {
            if le64(r.key(), 0)? != id {
                break;
            }
            add(&mut exts, id, le64(r.key(), 8)?, r.val())?;
        }
    }
    Ok(Stream { exts })
}

pub(crate) fn open<R: ReadAt>(vol: &Rc<VolCore<R>>, ino: u64) -> Result<File<R>> {
    let tree = vol.fs_tree()?;
    let r = vol.find_inode(&tree, ino)?.ok_or_else(|| bad(format!("no inode {ino}")))?;
    if r.mode & S_IFMT != S_IFREG {
        return Err(bad(format!("inode {ino} is not a regular file")));
    }
    if r.bsd_flags & SF_DATALESS != 0 {
        return Err(bad(format!("inode {ino} is a dataless file (its data is not on the volume)")));
    }
    if r.bsd_flags & UF_COMPRESSED != 0 {
        if let Some((fl, raw)) = vol.xattr(&tree, ino, XA_DECMPFS)? {
            let attr = xattr_bytes(vol, &tree, fl, &raw)?;
            return open_compressed(vol, &tree, ino, &attr);
        }
    }
    let size = r.dstream_size.unwrap_or(0);
    let s = load_extents(vol, &tree, r.private_id)?;
    Ok(File { vol: vol.clone(), size, compression: 0, body: Body::Stream(s) })
}

fn open_compressed<R: ReadAt>(vol: &Rc<VolCore<R>>, tree: &Tree<'_, R>, ino: u64, attr: &[u8]) -> Result<File<R>> {
    let (ty, size) = decmpfs_header(attr).ok_or_else(|| bad(format!("inode {ino}: malformed decmpfs attribute")))?;
    let mk = |body| File { vol: vol.clone(), size, compression: ty, body };
    match ty {
        1 | 3 | 7 | 9 | 11 | 13 => {
            if size > MAX_INLINE {
                return Err(bad(format!("inode {ino}: inline compressed data claims {size} bytes")));
            }
            Ok(mk(Body::Inline { ty, raw: attr[16..].to_vec(), decoded: RefCell::new(None) }))
        }
        4 | 8 | 10 | 12 | 14 => {
            let (fl, d) =
                vol.xattr(tree, ino, XA_RSRC)?.ok_or_else(|| bad(format!("inode {ino}: compressed file without a resource fork")))?;
            let rsrc = if fl & XATTR_DATA_EMBEDDED != 0 {
                Rsrc::Embedded(d)
            } else if fl & XATTR_DATA_STREAM != 0 {
                let id = le64(&d, 0)?;
                let sz = le64(&d, 8)?;
                Rsrc::Stream(load_extents(vol, tree, id)?, sz)
            } else {
                return Err(bad("resource fork attribute has no data"));
            };
            let blocks = chunk_table(&vol.sh, ty, &rsrc, size)?;
            Ok(mk(Body::Chunked { ty, rsrc, blocks, cache: RefCell::new(Vec::new()) }))
        }
        5 => Err(bad(format!("inode {ino}: decmpfs type 5 (dataless / sparse compressed file) is not supported"))),
        0x8000_0001 => Err(bad(format!("inode {ino}: decmpfs faulting file (data not on the volume)"))),
        _ => Err(bad(format!("inode {ino}: unknown decmpfs type {ty}"))),
    }
}

/// (offset, length) of each 64 KiB chunk in the resource fork.
fn chunk_table<R: ReadAt>(sh: &Shared<R>, ty: u32, rsrc: &Rsrc, size: u64) -> Result<Vec<(u64, u32)>> {
    let n = size.div_ceil(CHUNK);
    let fsz = rsrc.size();
    let mut out = Vec::new();
    if n == 0 {
        return Ok(out);
    }
    if ty == 4 {
        // 0x100: data length (BE), 0x104: chunk count (LE), then (offset from 0x104, length) pairs (LE)
        let need = 0x108u64.checked_add(n.checked_mul(8).unwrap_or(u64::MAX)).unwrap_or(u64::MAX);
        if need > fsz {
            return Err(bad("zlib resource fork is too small for its chunk table"));
        }
        let t = rsrc.read(sh, 0x104, 4 + 8 * n as usize)?;
        if le32(&t, 0)? as u64 != n {
            return Err(bad("zlib resource fork: chunk count does not match the file size"));
        }
        for i in 0..n as usize {
            let off = 0x104 + le32(&t, 4 + 8 * i)? as u64;
            let len = le32(&t, 8 + 8 * i)?;
            if len as u64 > MAX_CHUNK_RAW || off + len as u64 > fsz {
                return Err(bad("zlib resource fork: chunk outside the fork"));
            }
            out.push((off, len));
        }
    } else {
        // n + 1 little-endian offsets from the start of the fork
        if (n + 1) * 4 > fsz {
            return Err(bad("resource fork is too small for its chunk table"));
        }
        let t = rsrc.read(sh, 0, 4 * (n as usize + 1))?;
        let mut prev = le32(&t, 0)? as u64;
        if prev < 4 * (n + 1) {
            return Err(bad("resource fork: first chunk overlaps the chunk table"));
        }
        for i in 1..=n as usize {
            let next = le32(&t, 4 * i)? as u64;
            if next < prev || next - prev > MAX_CHUNK_RAW || next > fsz {
                return Err(bad("resource fork: chunk table is not monotonic or points outside the fork"));
            }
            out.push((prev, (next - prev) as u32));
            prev = next;
        }
    }
    Ok(out)
}

struct Bounded {
    v: Vec<u8>,
    max: usize,
}

impl std::io::Write for Bounded {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        if self.v.len() + b.len() > self.max {
            return Err(std::io::Error::other("LZFSE output larger than expected"));
        }
        self.v.extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Decodes one decmpfs block (a whole inline attribute or one 64 KiB chunk) to exactly `expect` bytes.
fn decode_block(lz: &LzCell, ty: u32, raw: &[u8], expect: usize) -> Result<Vec<u8>> {
    let first = *raw.first().ok_or_else(|| bad("empty compressed block"))?;
    let out = match ty {
        1 => raw.to_vec(),
        3 | 4 => {
            if first & 0x0f == 0x0f {
                raw[1..].to_vec()
            } else {
                miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(raw, expect)
                    .map_err(|e| bad(format!("zlib block: {:?}", e.status)))?
            }
        }
        7 | 8 => {
            if first == 0x06 {
                raw[1..].to_vec()
            } else {
                super::lzvn::decode(raw, expect)?
            }
        }
        11 | 12 => {
            if first == 0xff {
                raw[1..].to_vec()
            } else {
                let mut slot = lz.borrow_mut();
                let dec = slot.get_or_insert_with(Default::default);
                let mut w = Bounded { v: Vec::with_capacity(expect), max: expect };
                match dec.decode(&mut &raw[..], &mut w) {
                    Ok(_) => w.v,
                    Err(e) => {
                        *slot = None;
                        return Err(bad(format!("LZFSE block: {e}")));
                    }
                }
            }
        }
        13 | 14 => {
            // an incompressible block is stored as 0xFF + the data (as for LZFSE), seen in the real iOS 26 cryptex
            if first == 0xff && raw.len() == expect + 1 {
                raw[1..].to_vec()
            } else {
                super::lzbitmap::decode(raw, expect)?
            }
        }
        9 | 10 => {
            if raw.len() == expect {
                raw.to_vec()
            } else if first == 0xcc && raw.len() == expect + 1 {
                raw[1..].to_vec()
            } else {
                return Err(bad("raw decmpfs block has an unexpected size"));
            }
        }
        _ => return Err(bad(format!("unsupported decmpfs type {ty}"))),
    };
    if out.len() != expect {
        return Err(bad(format!("decompressed block has {} bytes, expected {expect}", out.len())));
    }
    Ok(out)
}

impl<R: ReadAt> File<R> {
    fn inline(&self) -> Result<Rc<Vec<u8>>> {
        let Body::Inline { ty, raw, decoded } = &self.body else { unreachable!() };
        if let Some(d) = decoded.borrow().as_ref() {
            return Ok(d.clone());
        }
        let d = if self.size == 0 { Vec::new() } else { decode_block(&self.vol.lzfse, *ty, raw, self.size as usize)? };
        let d = Rc::new(d);
        *decoded.borrow_mut() = Some(d.clone());
        Ok(d)
    }

    fn chunk(&self, i: usize) -> Result<Rc<Vec<u8>>> {
        let Body::Chunked { ty, rsrc, blocks, cache } = &self.body else { unreachable!() };
        {
            let mut c = cache.borrow_mut();
            if let Some(p) = c.iter().position(|(k, _)| *k == i) {
                let e = c.remove(p);
                let v = e.1.clone();
                c.push(e);
                return Ok(v);
            }
        }
        let (off, len) = *blocks.get(i).ok_or_else(|| bad("chunk index out of range"))?;
        let raw = rsrc.read(&self.vol.sh, off, len as usize)?;
        let expect = (self.size - i as u64 * CHUNK).min(CHUNK) as usize;
        let out = Rc::new(decode_block(&self.vol.lzfse, *ty, &raw, expect)?);
        let mut c = cache.borrow_mut();
        if c.len() >= CACHED_CHUNKS {
            c.remove(0);
        }
        c.push((i, out.clone()));
        Ok(out)
    }
}

impl<R: ReadAt> ReadAt for File<R> {
    fn size(&self) -> u64 {
        self.size
    }

    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        let end = off.checked_add(buf.len() as u64).ok_or_else(|| short(off))?;
        if end > self.size {
            return Err(short(off));
        }
        if buf.is_empty() {
            return Ok(());
        }
        match &self.body {
            Body::Stream(s) => s.read(&self.vol.sh, off, buf),
            Body::Inline { .. } => {
                let d = self.inline()?;
                buf.copy_from_slice(&d[off as usize..end as usize]);
                Ok(())
            }
            Body::Chunked { .. } => {
                let mut pos = off;
                while pos < end {
                    let c = self.chunk((pos / CHUNK) as usize)?;
                    let co = (pos % CHUNK) as usize;
                    let n = (c.len() - co).min((end - pos) as usize);
                    buf[(pos - off) as usize..][..n].copy_from_slice(&c[co..co + n]);
                    pos += n as u64;
                }
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pseudo(n: usize, seed: u64) -> Vec<u8> {
        let mut x = seed.wrapping_mul(0x9e3779b97f4a7c15) | 1;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 24) as u8
            })
            .collect()
    }

    fn sample(n: usize) -> Vec<u8> {
        // compressible text with a few incompressible stretches
        let mut v = Vec::new();
        let mut i = 0u64;
        while v.len() < n {
            v.extend_from_slice(format!("line {i} of some quite repetitive text, repeated, repeated\n").as_bytes());
            if i % 400 == 399 {
                v.extend(pseudo(3000, i));
            }
            i += 1;
        }
        v.truncate(n);
        v
    }

    fn lzfse(d: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        lzfse_rust::encode_bytes(d, &mut out).unwrap();
        out
    }

    /// A raw LZVN stream, taken out of the "bvxn" block the LZFSE encoder writes for small inputs.
    fn lzvn(d: &[u8]) -> Option<Vec<u8>> {
        let e = lzfse(d);
        if e.get(..4) != Some(b"bvxn") {
            return None;
        }
        let n = u32::from_le_bytes(e[8..12].try_into().unwrap()) as usize;
        Some(e[12..12 + n].to_vec())
    }

    /// Chunk encoder: the compressed bytes of one chunk, with decmpfs's "stored" marker when that is shorter.
    fn zlib_chunk(c: &[u8]) -> Vec<u8> {
        let z = miniz_oxide::deflate::compress_to_vec_zlib(c, 6);
        if z.len() < c.len() { z } else { [&[0xffu8][..], c].concat() }
    }

    fn fork_zlib(chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut f = vec![0u8; 0x104];
        f.extend((chunks.len() as u32).to_le_bytes());
        let mut off = 4 + 8 * chunks.len() as u32;
        for c in chunks {
            f.extend(off.to_le_bytes());
            f.extend((c.len() as u32).to_le_bytes());
            off += c.len() as u32;
        }
        for c in chunks {
            f.extend(c);
        }
        f.extend([0u8; 50]);
        f
    }

    fn fork_offsets(chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut f = Vec::new();
        let mut off = 4 * (chunks.len() as u32 + 1);
        for c in chunks {
            f.extend(off.to_le_bytes());
            off += c.len() as u32;
        }
        f.extend(off.to_le_bytes());
        for c in chunks {
            f.extend(c);
        }
        f
    }

    fn roundtrip(ty: u32, data: &[u8], enc: &dyn Fn(&[u8]) -> Vec<u8>, fork: &dyn Fn(&[Vec<u8>]) -> Vec<u8>) {
        let sh = Shared::new(Vec::<u8>::new(), 4096, 0);
        let lz = LzCell::default();
        let chunks: Vec<Vec<u8>> = data.chunks(65536).map(enc).collect();
        let rsrc = Rsrc::Embedded(fork(&chunks));
        let table = chunk_table(&sh, ty, &rsrc, data.len() as u64).unwrap();
        assert_eq!(table.len(), chunks.len());
        let mut out = Vec::new();
        for (i, (off, len)) in table.iter().enumerate() {
            let raw = rsrc.read(&sh, *off, *len as usize).unwrap();
            let expect = (data.len() - i * 65536).min(65536);
            out.extend(decode_block(&lz, ty, &raw, expect).unwrap());
        }
        assert_eq!(out, data, "type {ty}");
    }

    #[test]
    fn chunked_types_round_trip() {
        let data = sample(150_000);
        roundtrip(4, &data, &zlib_chunk, &fork_zlib);
        roundtrip(
            12,
            &data,
            &|c| {
                let e = lzfse(c);
                if e.len() < c.len() { e } else { [&[0xffu8][..], c].concat() }
            },
            &fork_offsets,
        );
        roundtrip(10, &data, &|c| [&[0xccu8][..], c].concat(), &fork_offsets);
        // LZVN chunks of 64 KiB are not what the encoder makes bvxn blocks of, so cut the data into
        // small pieces for the stream (one "chunk" per piece is enough to exercise the decoder)
        let small = sample(3000);
        let enc = lzvn(&small).expect("small input encodes as bvxn");
        assert_eq!(super::super::lzvn::decode(&enc, small.len()).unwrap(), small);
        roundtrip(8, &small, &|c| lzvn(c).unwrap(), &fork_offsets);
        // stored chunk marker
        roundtrip(8, &pseudo(2000, 4), &|c| [&[0x06u8][..], c].concat(), &fork_offsets);
    }

    #[test]
    fn inline_types_round_trip() {
        let lz = LzCell::default();
        let d = sample(3000);
        assert_eq!(decode_block(&lz, 1, &d, d.len()).unwrap(), d);
        assert_eq!(decode_block(&lz, 3, &zlib_chunk(&d), d.len()).unwrap(), d);
        assert_eq!(decode_block(&lz, 7, &lzvn(&d).unwrap(), d.len()).unwrap(), d);
        assert_eq!(decode_block(&lz, 11, &lzfse(&d), d.len()).unwrap(), d);
        assert_eq!(decode_block(&lz, 9, &d, d.len()).unwrap(), d);
        // a long (multi-block) LZFSE stream
        let big = sample(1 << 20);
        assert_eq!(decode_block(&lz, 11, &lzfse(&big), big.len()).unwrap(), big);
    }

    #[test]
    fn decoders_reject_garbage() {
        let lz = LzCell::default();
        let g = pseudo(5000, 11);
        for ty in [3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 99] {
            for first in [0u8, 0x78, 0x62, 0xff, 0x06, 0xcc, b'Z'] {
                let mut d = g.clone();
                d[0] = first;
                // must be an error or the right length, never a panic or an oversized allocation
                let _ = decode_block(&lz, ty, &d, 65536);
                let _ = decode_block(&lz, ty, &d[..3], 100);
            }
        }
        // a decompression bomb is cut at the expected size
        let z = miniz_oxide::deflate::compress_to_vec_zlib(&vec![0u8; 50_000_000], 9);
        assert!(decode_block(&lz, 3, &z, 65536).is_err());
        let bomb = lzfse(&vec![0u8; 20_000_000]);
        assert!(decode_block(&lz, 11, &bomb, 65536).is_err());
        // the resource-fork tables refuse absurd counts without allocating for them
        let sh = Shared::new(Vec::<u8>::new(), 4096, 0);
        let rsrc = Rsrc::Embedded(vec![0u8; 64]);
        for ty in [4, 8, 12] {
            assert!(chunk_table(&sh, ty, &rsrc, u64::MAX).is_err());
        }
    }
}
