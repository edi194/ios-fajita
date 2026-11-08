//! APFS objects: checksummed blocks, the block cache and bounds-checked little-endian reads.

use crate::io::{ReadAt, bad};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io::Result;
use std::rc::Rc;

pub(crate) const TYPE_MASK: u32 = 0xffff;
pub(crate) const T_NX_SUPERBLOCK: u32 = 1;
pub(crate) const T_BTREE: u32 = 2;
pub(crate) const T_BTREE_NODE: u32 = 3;
pub(crate) const T_OMAP: u32 = 0xb;
pub(crate) const T_FS: u32 = 0xd;
pub(crate) const OBJ_ENCRYPTED: u32 = 0x1000_0000;

#[inline]
pub(crate) fn le16(b: &[u8], o: usize) -> Result<u16> {
    match b.get(o..o.wrapping_add(2)) {
        Some(s) => Ok(u16::from_le_bytes([s[0], s[1]])),
        None => Err(bad("APFS structure truncated")),
    }
}

#[inline]
pub(crate) fn le32(b: &[u8], o: usize) -> Result<u32> {
    match b.get(o..o.wrapping_add(4)) {
        Some(s) => Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]])),
        None => Err(bad("APFS structure truncated")),
    }
}

#[inline]
pub(crate) fn le64(b: &[u8], o: usize) -> Result<u64> {
    match b.get(o..o.wrapping_add(8)) {
        Some(s) => Ok(u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]])),
        None => Err(bad("APFS structure truncated")),
    }
}

/// Fletcher-64 as APFS stores it: over the little-endian words after the 8-byte checksum field.
pub(crate) fn fletcher64(data: &[u8]) -> u64 {
    const M: u64 = 0xffff_ffff;
    let (mut s1, mut s2) = (0u64, 0u64);
    // At most 16384 words (64 KiB blocks): s2 stays below 2^61, so one reduction at the end is exact.
    for w in data.chunks_exact(4) {
        s1 += u32::from_le_bytes([w[0], w[1], w[2], w[3]]) as u64;
        s2 += s1;
    }
    s1 %= M;
    s2 %= M;
    let c1 = M - (s1 + s2) % M;
    let c2 = M - (s1 + c1) % M;
    (c2 << 32) | c1
}

/// Does the block's stored checksum match its contents?
pub(crate) fn checksum_ok(blk: &[u8]) -> bool {
    blk.len() >= 32 && blk.len() % 4 == 0 && le64(blk, 0).ok() == Some(fletcher64(&blk[8..]))
}

struct Cache {
    map: HashMap<u64, (Rc<Vec<u8>>, u64)>,
    tick: u64,
    cap: usize,
}

/// The container: the reader, the block size and a cache of checksummed blocks (B-tree nodes are
/// read over and over; one read of the underlying reader may cost a segment decrypt).
pub(crate) struct Shared<R> {
    pub r: R,
    pub bs: usize,
    pub nblocks: u64,
    cache: RefCell<Cache>,
    pub misses: Cell<u64>,
    pub hits: Cell<u64>,
}

impl<R: ReadAt> Shared<R> {
    pub fn new(r: R, bs: usize, nblocks: u64) -> Self {
        Shared {
            r,
            bs,
            nblocks,
            cache: RefCell::new(Cache { map: HashMap::new(), tick: 0, cap: 8192 }),
            misses: Cell::new(0),
            hits: Cell::new(0),
        }
    }

    pub fn set_cache_blocks(&self, cap: usize) {
        let mut c = self.cache.borrow_mut();
        c.cap = cap.max(16);
        c.map.clear();
    }

    /// Reads one block by physical address and checks its Fletcher-64 checksum (cached).
    pub fn block(&self, paddr: u64) -> Result<Rc<Vec<u8>>> {
        self.block_with(paddr, true)
    }

    fn block_with(&self, paddr: u64, verify: bool) -> Result<Rc<Vec<u8>>> {
        {
            let mut c = self.cache.borrow_mut();
            c.tick += 1;
            let t = c.tick;
            if let Some(e) = c.map.get_mut(&paddr) {
                e.1 = t;
                self.hits.set(self.hits.get() + 1);
                return Ok(e.0.clone());
            }
        }
        if paddr >= self.nblocks {
            return Err(bad(format!("block {paddr} is outside the container ({} blocks)", self.nblocks)));
        }
        self.misses.set(self.misses.get() + 1);
        let blk = self.r.read_vec(paddr * self.bs as u64, self.bs)?;
        if verify && !checksum_ok(&blk) {
            return Err(bad(format!("block {paddr}: checksum mismatch")));
        }
        let blk = Rc::new(blk);
        let mut c = self.cache.borrow_mut();
        if c.map.len() >= c.cap {
            let mut v: Vec<(u64, u64)> = c.map.iter().map(|(k, (_, t))| (*t, *k)).collect();
            v.sort_unstable();
            for (_, k) in v.iter().take(c.cap / 2) {
                c.map.remove(k);
            }
        }
        let t = c.tick;
        c.map.insert(paddr, (blk.clone(), t));
        Ok(blk)
    }

    /// A block with no object header (sealed volumes' B-tree nodes): no checksum to verify.
    pub fn block_unchecked(&self, paddr: u64) -> Result<Rc<Vec<u8>>> {
        self.block_with(paddr, false)
    }

    /// Raw container bytes (file data): bounds-checked against the container size.
    pub fn read_bytes(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        let end = off.checked_add(buf.len() as u64).ok_or_else(|| bad("read offset overflows"))?;
        if end > self.nblocks.saturating_mul(self.bs as u64) {
            return Err(bad(format!("data at byte {off} lies outside the container")));
        }
        self.r.read_at(off, buf)
    }
}

pub(crate) fn hdr_oid(b: &[u8]) -> Result<u64> {
    le64(b, 8)
}
pub(crate) fn hdr_xid(b: &[u8]) -> Result<u64> {
    le64(b, 16)
}
pub(crate) fn hdr_type(b: &[u8]) -> Result<u32> {
    le32(b, 24)
}
