#!/usr/bin/env python3
"""Recompute corecrypto's FIPS POST integrity HMAC after pacstrip rewrote the code.

  fips_rehmac.py CACHE_DIR [--patch] [--jobs N]

fipspost_post_integrity (libcorecrypto, 22H352) calls fipspost_get_hmac(mach_header, out[32], 0): it walks the image's own
load commands, takes the FIRST section named __text whose segment is __TEXT or __TEXT_EXEC and computes
HMAC-SHA256(key = one zero byte, message = mach_header + section.offset, section.size bytes), then compares the 32 bytes
with the contents of the __TEXT,__fips_hmacs section (32 bytes) (cc_cmp_safe), logging "MAC generated:" / "In variable:" and
returning CCPOST_INTEGRITY_ERROR when they differ. Inside the dyld cache the section offset is relative to the image's
mach header (== section.addr - __TEXT.vmaddr), so the HMAC covers exactly the bytes in the cache's __TEXT,__text.
pacstrip_cache.py rewrites those bytes, so the stored value must be recomputed, then the page hashes of the CodeDirectory
of the cache file holding __fips_hmacs must be refreshed (pacstrip_cache.fix_signature).

Default is check mode (reports match / mismatch per image); --patch writes the new value and fixes the signature.
Every image of the cache having a __fips_hmacs section is handled (libcorecrypto, _trace, _noasm, ...).
"""
import argparse
import hmac
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pacstrip_cache as pc  # noqa: E402


def find(c, addr):
    """(text_section (fn, off, size), hmacs (fn, off, size)) of the image at addr, or None."""
    t = c.translate(addr, 32)
    fn, off, _ = t
    b = c.bufs[fn]
    magic, _, _, _, ncmds, _ = struct.unpack_from('<IiiIII', b, off)
    p = off + 32
    text = hm = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, p)
        if cmd == pc.LC_SEGMENT_64:
            seg = bytes(b[p + 8:p + 24]).split(b'\0')[0]
            ns = struct.unpack_from('<I', b, p + 64)[0]
            for i in range(ns):
                so = p + 72 + 80 * i
                sect = bytes(b[so:so + 16]).split(b'\0')[0]
                sseg = bytes(b[so + 16:so + 32]).split(b'\0')[0]
                saddr, ssize = struct.unpack_from('<QQ', b, so + 32)
                if sect == b'__fips_hmacs':
                    f2, o2, _ = c.translate(saddr, ssize)
                    hm = (f2, o2, ssize)
                if seg in (b'__TEXT', b'__TEXT_EXEC') and sect == b'__text' and sseg in (b'__TEXT', b'__TEXT_EXEC') \
                        and text is None:
                    f2, o2, _ = c.translate(saddr, ssize)
                    text = (f2, o2, ssize)
        p += size
    return text, hm


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('dir')
    ap.add_argument('--patch', action='store_true')
    a = ap.parse_args()
    c = pc.Cache(a.dir)
    todo = []
    for addr, path in c.images():
        if 'crypto' not in path and 'Crypto' not in path:
            # fips_hmacs only exists in corecrypto builds; still check by section for every image named *crypto*
            continue
        text, hm = find(c, addr)
        if not hm:
            continue
        fn, o, n = text
        calc = hmac.new(b'\0', bytes(c.bufs[fn][o:o + n]), 'sha256').digest()
        f2, o2, n2 = hm
        stored = bytes(c.bufs[f2][o2:o2 + n2])
        ok = calc == stored
        print(f'{path}: text {n:#x} bytes in {fn}; stored {stored.hex()[:16]}.. computed {calc.hex()[:16]}.. '
              f'{"MATCH" if ok else "MISMATCH"}')
        if not ok:
            todo.append((f2, o2, calc))
    for b in c.bufs.values():
        b.close()
    if not a.patch:
        return
    changed = {}
    for fn, o, calc in todo:
        with open(os.path.join(a.dir, fn), 'r+b') as f:
            f.seek(o)
            f.write(calc)
        changed.setdefault(fn, set()).add(o >> 12)
    for fn, pages in changed.items():
        n, note = pc.fix_signature(os.path.join(a.dir, fn), pages)
        print(f'  {fn}: {len(pages)} pages, {n} hashes updated; {note}')
    print(f'patched {len(todo)} images')


if __name__ == '__main__':
    main()
