#!/usr/bin/env python3
"""Renegade for the iOS 18 dyld shared cache (`renegade cache`): rewrite every cache file (main + sub-caches) in place.

  pacstrip_cache.py CACHE_DIR [--scan] [--jobs N] [--no-resign] [--whitelist-ldra IMAGE-SUBSTR ...]

Same semantics as pacstrip.py (4 bytes for 4 bytes, tools/renegade/pacstrip.py rewrite_word): only the EXECUTABLE
SECTIONS of the cached images are touched (not the whole r-x mapping: it also holds __cstring, __const, unwind
info, ... which must not change), minus LC_DATA_IN_CODE ranges. The cache has no per-image file: every image
is located through the main file's image table and the mapping tables of every file (addresses are global,
sub-cache files carry their own mapping table), so a section is translated address -> (file, file offset).

Cache images are stripped of LC_DATA_IN_CODE by the cache builder, so data embedded in code (jump tables
and literals in a few images, e.g. TextToSpeechMauiSupport) can look like LDRAA/LDRAB. Words of those classes
are rewritten only inside images listed with --whitelist-ldra (libc++abi, libobjc ... where the real ones
are); elsewhere they are counted and reported, not touched. Default whitelist: see DEFAULT_LDRA below.

Code signatures: dyld registers every cache file's embedded signature (F_ADDFILESIGS_RETURN) and the kernel
validates pages against its CodeDirectory hashes at fault time, so after rewriting the page hashes of every
changed page are recomputed IN PLACE in every CodeDirectory of the file's SuperBlob (no size change, the CDHash
of the file changes: nothing in the cache refers to it). --no-resign skips that.

Also reported: PAC instructions inside r-x mappings but outside every image section (branch islands, stubs
file): counted, not rewritten unless --islands (they should be plain adrp/add/br).
"""
import argparse
import hashlib
import mmap
import os
import struct
import sys
import time
from array import array
from collections import Counter
from multiprocessing import Pool

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pacstrip  # noqa: E402

PROT_EXEC = 4
LC_SEGMENT_64, LC_DATA_IN_CODE = 0x19, 0x29
CSMAGIC_EMBEDDED_SIGNATURE, CSMAGIC_CODEDIRECTORY = 0xFADE0CC0, 0xFADE0C02
HASH_NAMES = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}   # 3 = SHA256 truncated to 20 bytes
DEFAULT_LDRA = ('libc++abi', 'libobjc.A', 'libc++.1', 'libdispatch', 'libsystem_', 'libdyld', 'dyld')


def read_header(buf):
    m = buf[:16]
    assert m.startswith(b'dyld_v1'), f'not a dyld cache file: {bytes(m)!r}'
    h = {}
    h['magic'] = bytes(m).split(b'\0')[0].decode()
    h['mappingOffset'], h['mappingCount'] = struct.unpack_from('<II', buf, 0x10)
    h['codeSignatureOffset'], h['codeSignatureSize'] = struct.unpack_from('<QQ', buf, 0x28)
    h['dyldInCacheMH'] = struct.unpack_from('<Q', buf, 0x78)[0]
    h['subCacheArrayOffset'], h['subCacheArrayCount'] = struct.unpack_from('<II', buf, 0x188)
    h['imagesOffset'], h['imagesCount'] = struct.unpack_from('<II', buf, 0x1C0)
    if h['imagesCount'] == 0:
        h['imagesOffset'], h['imagesCount'] = struct.unpack_from('<II', buf, 0x18)
    h['mappingWithSlideOffset'], h['mappingWithSlideCount'] = struct.unpack_from('<II', buf, 0x138)
    return h


def read_mappings(buf, h):
    maps = []
    for i in range(h['mappingCount']):
        addr, size, foff, maxp, initp = struct.unpack_from('<QQQII', buf, h['mappingOffset'] + 32 * i)
        maps.append((addr, size, foff, initp))
    return maps


DYLD_CACHE_MAPPING_TEXT_STUBS = 1 << 3


def stub_mappings(buf, h):
    """(file offset, size) of the mappings flagged TEXT_STUBS (dyld_cache_mapping_and_slide_info, 56 bytes each)"""
    out = []
    for i in range(h['mappingWithSlideCount']):
        addr, size, foff, _, _, flags = struct.unpack_from('<QQQQQQ', buf, h['mappingWithSlideOffset'] + 56 * i)
        if flags & DYLD_CACHE_MAPPING_TEXT_STUBS:
            out.append((foff, size))
    return out


def cache_files(d):
    """Main cache file and the sub-cache files (suffixes from the main header), in order."""
    main = None
    for n in sorted(os.listdir(d)):
        if n.startswith('dyld_shared_cache_arm64e') and '.' not in n[len('dyld_shared_cache_arm64e'):]:
            main = n
    assert main, 'no dyld_shared_cache_arm64e in ' + d
    with open(os.path.join(d, main), 'rb') as f:
        buf = f.read(0x1000)
        h = read_header(buf)
        f.seek(h['subCacheArrayOffset'])
        raw = f.read(h['subCacheArrayCount'] * 56)
    subs = []
    for i in range(h['subCacheArrayCount']):
        suffix = raw[56 * i + 24:56 * i + 56].split(b'\0')[0].decode()
        subs.append(main + suffix)
    return main, subs


class Cache:
    def __init__(self, d):
        self.dir = d
        self.main, self.subs = cache_files(d)
        self.files = [self.main] + self.subs
        self.maps = []                       # (addr, size, fileoff, initprot, filename)
        self.stubs = {}                      # filename -> [(fileoff, size)] of the TEXT_STUBS mappings
        self.bufs = {}
        for fn in self.files:
            f = open(os.path.join(d, fn), 'rb')
            b = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            self.bufs[fn] = b
            h = read_header(b)
            for m in read_mappings(b, h):
                self.maps.append(m + (fn,))
            if h['mappingWithSlideCount']:
                self.stubs[fn] = stub_mappings(b, h)
            if fn == self.main:
                self.hdr = h
        self.maps.sort()

    def translate(self, addr, length=1):
        lo, hi = 0, len(self.maps)
        while lo < hi:
            mid = (lo + hi) // 2
            if self.maps[mid][0] <= addr:
                lo = mid + 1
            else:
                hi = mid
        if lo == 0:
            return None
        a, size, foff, prot, fn = self.maps[lo - 1]
        if addr + length > a + size:
            return None
        return fn, foff + (addr - a), prot

    def images(self):
        b = self.bufs[self.main]
        h = self.hdr
        out = []
        for i in range(h['imagesCount']):
            addr, mod, ino, pathoff, pad = struct.unpack_from('<QQQII', b, h['imagesOffset'] + 32 * i)
            end = b.find(b'\0', pathoff)
            out.append((addr, bytes(b[pathoff:end]).decode()))
        if h['dyldInCacheMH']:
            out.append((h['dyldInCacheMH'], '/usr/lib/dyld (in cache)'))
        return out

    def image_code_ranges(self, addr):
        """[(file, start, end, sectname)] executable section ranges of the Mach-O header at VM address addr."""
        t = self.translate(addr, 32)
        fn, off, _ = t
        b = self.bufs[fn]
        magic, cputype, cpusub, ftype, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', b, off)
        assert magic == pacstrip.MH_MAGIC_64, f'bad Mach-O at {addr:#x}'
        p = off + 32
        secs, dice, linkedit = [], None, None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', b, p)
            if cmd == LC_SEGMENT_64:
                segname = bytes(b[p + 8:p + 24]).split(b'\0')[0].decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', b, p + 24)
                if segname == '__LINKEDIT':
                    linkedit = (vmaddr, fileoff)
                nsects = struct.unpack_from('<I', b, p + 64)[0]
                for i in range(nsects):
                    so = p + 72 + 80 * i
                    sectname = bytes(b[so:so + 16]).split(b'\0')[0].decode()
                    saddr, ssize = struct.unpack_from('<QQ', b, so + 32)
                    flags = struct.unpack_from('<I', b, so + 64)[0]
                    if flags & (pacstrip.S_ATTR_PURE_INSTRUCTIONS | pacstrip.S_ATTR_SOME_INSTRUCTIONS) and ssize:
                        secs.append((saddr, ssize, f'{segname},{sectname}'))
            elif cmd == LC_DATA_IN_CODE:
                dice = struct.unpack_from('<II', b, p + 8)
            p += size
        excl = []
        if dice and dice[1] and linkedit:
            # data-in-code offsets are file offsets of the cache file holding __LINKEDIT
            dataoff, datasize = dice
            va = linkedit[0] + (dataoff - linkedit[1])
            t2 = self.translate(va, datasize)
            if t2:
                fn2, o2, _ = t2
                for j in range(datasize // 8):
                    o, ln, kind = struct.unpack_from('<IHH', self.bufs[fn2], o2 + 8 * j)
                    excl.append((cache_vmaddr_of(self, fn, o), ln))
        out = []
        for saddr, ssize, name in secs:
            t3 = self.translate(saddr, ssize)
            if t3 is None:
                raise SystemExit(f'section {name} at {saddr:#x}+{ssize:#x} not inside one mapping')
            fn3, o3, prot = t3
            out.append((fn3, o3, o3 + ssize, name))
        return out


def cache_vmaddr_of(cache, fn, off):                      # unused fallback (cache images have no data-in-code)
    return 0


# --- worker: rewrite ranges of one file ---------------------------------------------------------------------------
def rewrite_ranges(args):
    path, ranges, allow_ldra, scan = args
    counts, skipped = Counter(), Counter()
    changed_pages = set()
    t0 = time.time()
    f = open(path, 'rb' if scan else 'r+b')
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ if scan else mmap.ACCESS_WRITE)
    for start, end, name, ldra_ok in ranges:
        n = (end - start) // 4
        words = array('I')
        words.frombytes(mm[start:start + n * 4])
        dirty = False
        for i, w in enumerate(words):
            if (w >> 24) not in pacstrip.PREFIX:
                continue
            nw, cls = pacstrip.rewrite_word(w)
            if cls is None:
                continue
            if nw is None:
                if cls.startswith('FJCVTZS'):
                    counts['FJCVTZS(left)'] += 1
                else:
                    counts[cls] += 1
                continue
            if cls.startswith('LDRA') and not ldra_ok:
                skipped[f'{cls}@{name}'] += 1
                continue
            counts[cls] += 1
            if not scan:
                words[i] = nw
                dirty = True
                changed_pages.add((start + i * 4) >> 12)
        if dirty:
            mm[start:start + n * 4] = words.tobytes()
    if not scan:
        mm.flush()
    mm.close()
    f.close()
    return path, counts, skipped, changed_pages, time.time() - t0


# --- code signature -----------------------------------------------------------------------------------------------
def fix_signature(path, changed_4k_pages):
    """Recompute page hashes in every CodeDirectory of the file's embedded SuperBlob for the changed pages."""
    f = open(path, 'r+b')
    mm = mmap.mmap(f.fileno(), 0)
    h = read_header(mm)
    off, size = h['codeSignatureOffset'], h['codeSignatureSize']
    if not size:
        mm.close()
        f.close()
        return 0, 'no signature'
    magic, length, count = struct.unpack_from('>III', mm, off)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        mm.close()
        f.close()
        return 0, f'signature blob magic {magic:#x}'
    updated = 0
    notes = []
    for i in range(count):
        typ, boff = struct.unpack_from('>II', mm, off + 12 + 8 * i)
        cd = off + boff
        cmagic, clen, ver, flags, hashOff, identOff, nSpecial, nCode, codeLimit = struct.unpack_from('>IIIIIIIII', mm, cd)
        if cmagic != CSMAGIC_CODEDIRECTORY:
            continue
        hashSize, hashType, spare1, pageLog2 = struct.unpack_from('>BBBB', mm, cd + 36)
        if hashType not in HASH_NAMES:
            notes.append(f'unknown hash type {hashType}')
            continue
        ps = 1 << pageLog2 if pageLog2 else codeLimit
        pages = set()
        for p4 in changed_4k_pages:
            lo, hi = p4 << 12, (p4 + 1) << 12
            for p in range(lo // ps, (hi - 1) // ps + 1):
                pages.add(p)
        for p in pages:
            if p >= nCode:
                continue
            a, b = p * ps, min((p + 1) * ps, codeLimit)
            d = hashlib.new(HASH_NAMES[hashType], mm[a:b]).digest()[:hashSize]
            ho = cd + hashOff + p * hashSize
            mm[ho:ho + hashSize] = d
            updated += 1
        notes.append(f'CD type {typ:#x} hash {HASH_NAMES[hashType]} page {ps} codeLimit {codeLimit:#x}')
    mm.flush()
    mm.close()
    f.close()
    return updated, '; '.join(notes)


def verify_signature(path):
    """Check EVERY page hash of every CodeDirectory of the file; returns (checked, bad)."""
    f = open(path, 'rb')
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    h = read_header(mm)
    off = h['codeSignatureOffset']
    magic, length, count = struct.unpack_from('>III', mm, off)
    checked = bad = 0
    for i in range(count):
        typ, boff = struct.unpack_from('>II', mm, off + 12 + 8 * i)
        cd = off + boff
        if struct.unpack_from('>I', mm, cd)[0] != CSMAGIC_CODEDIRECTORY:
            continue
        cmagic, clen, ver, flags, hashOff, identOff, nSpecial, nCode, codeLimit = struct.unpack_from('>IIIIIIIII', mm, cd)
        hashSize, hashType, spare1, pageLog2 = struct.unpack_from('>BBBB', mm, cd + 36)
        ps = 1 << pageLog2
        for p in range(nCode):
            d = hashlib.new(HASH_NAMES[hashType], mm[p * ps:min((p + 1) * ps, codeLimit)]).digest()[:hashSize]
            ho = cd + hashOff + p * hashSize
            checked += 1
            if mm[ho:ho + hashSize] != d:
                bad += 1
    mm.close()
    f.close()
    return checked, bad


def verify_one(path):
    return path, verify_signature(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('dir')
    ap.add_argument('--scan', action='store_true', help='count only, write nothing')
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    ap.add_argument('--no-resign', action='store_true')
    ap.add_argument('--whitelist-ldra', nargs='*', default=None)
    ap.add_argument('--islands', action='store_true', help='also rewrite r-x ranges outside image sections')
    ap.add_argument('--stubs', action='store_true',
                    help='also rewrite the TEXT_STUBS mappings (iOS 26: cross-image stubs ending in BRAA x16, x17); '
                         'unlike --islands it leaves non-code bytes of __TEXT (strings, constants, the cache header) alone')
    ap.add_argument('--verify-sig', action='store_true', help='verify all page hashes of every file, then continue')
    ap.add_argument('--limit', type=int, default=0, help='only the first N images (testing)')
    a = ap.parse_args()
    wl = tuple(a.whitelist_ldra) if a.whitelist_ldra is not None else DEFAULT_LDRA
    t0 = time.time()
    if a.verify_sig:
        names = [os.path.join(a.dir, n) for n in sorted(os.listdir(a.dir)) if n.startswith('dyld_shared_cache_arm64e')
                 and not n.endswith(('.atlas', '.symbols'))]
        tot = totbad = 0
        with Pool(a.jobs) as pool:
            for path, (n, bad) in pool.imap_unordered(verify_one, names):
                tot += n
                totbad += bad
                if bad:
                    print(f'SIGNATURE MISMATCH {os.path.basename(path)}: {bad}/{n} page hashes wrong')
        print(f'signature check: {len(names)} files, {tot} page hashes, {totbad} wrong ({time.time() - t0:.1f}s)')
        if totbad and a.scan:
            sys.exit(1)
    c = Cache(a.dir)
    imgs = c.images()
    if a.limit:
        imgs = imgs[:a.limit]
    print(f'{len(c.files)} cache files, {len(imgs)} images, {len(c.maps)} mappings ({time.time() - t0:.1f}s)')
    per_file = {}
    covered = {}
    nsec = 0
    for addr, path in imgs:
        ldra_ok = any(w in path for w in wl)
        for fn, s, e, name in c.image_code_ranges(addr):
            per_file.setdefault(fn, []).append((s, e, f'{os.path.basename(path)}:{name}', ldra_ok))
            covered.setdefault(fn, []).append((s, e))
            nsec += 1
    total_words = sum((e - s) // 4 for r in per_file.values() for s, e, _, _ in r)
    print(f'{nsec} executable sections, {total_words * 4 >> 20} MiB of code ({time.time() - t0:.1f}s)')
    # r-x mapping bytes outside every image section
    outside = Counter()
    for addr, size, foff, prot, fn in c.maps:
        if prot & PROT_EXEC:
            cov = sum(e - s for s, e in covered.get(fn, []) if foff <= s < foff + size)
            outside[fn] += size - cov
    print('r-x mapping bytes outside image sections:', {k: v for k, v in outside.items() if v})
    isl = {}
    if a.islands:
        for addr, size, foff, prot, fn in c.maps:
            if prot & PROT_EXEC:
                cov = sorted((s, e) for s, e in covered.get(fn, []) if foff <= s < foff + size)
                pos = foff
                for s, e in cov + [(foff + size, foff + size)]:
                    if s > pos:
                        isl.setdefault(fn, []).append((pos, s, 'island', False))
                    pos = max(pos, e)
        for fn, r in isl.items():
            per_file.setdefault(fn, []).extend(r)
    if a.stubs and not a.islands:
        for fn, r in c.stubs.items():
            for foff, size in r:
                per_file.setdefault(fn, []).append((foff, foff + size, 'stubs', False))
        print('TEXT_STUBS mappings:', sum(len(r) for r in c.stubs.values()),
              f'({sum(sz for r in c.stubs.values() for _, sz in r) >> 10} KiB)')
    for b in c.bufs.values():
        b.close()
    jobs = []
    for fn, r in per_file.items():
        # split long lists so the pool balances
        r.sort()
        k = max(1, len(r) // (a.jobs * 2) + 1)
        for i in range(0, len(r), k):
            jobs.append((os.path.join(a.dir, fn), r[i:i + k], True, a.scan))
    total, skipped = Counter(), Counter()
    changed = {}
    with Pool(a.jobs) as pool:
        for path, counts, sk, pages, dt in pool.imap_unordered(rewrite_ranges, jobs):
            total.update(counts)
            skipped.update(sk)
            changed.setdefault(path, set()).update(pages)
    print('rewritten:', ', '.join(f'{k}={v}' for k, v in sorted(total.items())) or 'nothing', f'({time.time() - t0:.1f}s)')
    if skipped:
        agg = Counter()
        for k, v in skipped.items():
            agg[k.split('@')[1].split(':')[0] + ':' + k.split('@')[0]] += v
        print('LDRAx-looking words left alone (images outside the whitelist):', dict(agg.most_common(12)))
    if not a.scan and not a.no_resign:
        for path, pages in sorted(changed.items()):
            n, note = fix_signature(path, pages)
            print(f'  {os.path.basename(path)}: {len(pages)} pages changed, {n} hashes updated; {note}')
    print(f'done in {time.time() - t0:.1f}s')


if __name__ == '__main__':
    main()
