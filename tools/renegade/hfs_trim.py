#!/usr/bin/env python3
"""Punch holes (APFS F_PUNCHHOLE; Linux fallocate) into a raw HFS+ image over every block the volume's allocation bitmap says is free.

  hfs_trim.py IMAGE            (image must be unmounted/detached)

The raw image is a sparse file; blocks that HFS+ freed again (a file deleted after copying) stay allocated on the host
and non-zero, which costs disk now and makes the .simg bigger later. Free blocks are zero by definition, so punching
is lossless. Prints the freed amount.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import renegade_platform as rplat  # noqa: E402



def main():
    path = sys.argv[1]
    f = open(path, 'r+b')
    f.seek(1024)
    vh = f.read(512)
    assert vh[:2] in (b'H+', b'HX')
    bsize, total = struct.unpack_from('>II', vh, 40)[0], struct.unpack_from('>I', vh, 44)[0]
    logical = struct.unpack_from('>Q', vh, 112)[0]
    ext = [struct.unpack_from('>II', vh, 112 + 16 + 8 * i) for i in range(8)]
    assert sum(c for s, c in ext) * bsize >= (total + 7) // 8, 'bitmap extents beyond the volume header (unsupported)'
    bm = bytearray()
    for s, c in ext:
        if c:
            f.seek(s * bsize)
            bm += f.read(c * bsize)
    bm = bm[:(total + 7) // 8]
    assert bsize % 4096 == 0
    freed = runs = 0
    start = None
    for blk in range(total + 1):
        used = True if blk == total else bool(bm[blk >> 3] & (0x80 >> (blk & 7)))
        if not used and start is None:
            start = blk
        elif used and start is not None:
            off, ln = start * bsize, (blk - start) * bsize
            rplat.punch_hole_safe(f.fileno(), off, ln)
            freed += ln
            runs += 1
            start = None
    f.close()
    print(f'{path}: {total} blocks of {bsize}, punched {runs} free runs = {freed >> 20} MiB')


if __name__ == '__main__':
    main()
