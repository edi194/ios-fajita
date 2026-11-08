#!/usr/bin/env python3
"""Android sparse image -> raw image (sparse file on APFS), the inverse of img2simg.py.

  simg2img.py IN.simg OUT.img [--consume]

Zero FILL chunks and DONT_CARE chunks become holes. --consume punches a hole (F_PUNCHHOLE) over the part of IN.simg
that was already converted, so both files never need the full disk at once; afterwards IN.simg is destroyed.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import renegade_platform as rplat  # noqa: E402

RAW, FILL, DONT_CARE, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
PIECE = 16 << 20


def punch(fd, off, length):
    rplat.punch_hole_safe(fd, off, length)


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    consume = '--consume' in sys.argv
    f = open(a[0], 'r+b' if consume else 'rb')
    m, mj, mn, hs, cs, bs, tb, nc, crc = struct.unpack('<IHHHHIIII', f.read(28))
    assert m == 0xED26FF3A and bs % 4096 == 0
    out = open(a[1], 'wb')
    out.truncate(tb * bs)
    pos = 0                       # output block
    punched = 0                   # bytes of the simg already punched
    for i in range(nc):
        t, _, sz, tot = struct.unpack('<HHII', f.read(12))
        if t == RAW:
            out.seek(pos * bs)
            left = sz * bs
            while left:
                b = f.read(min(left, PIECE))
                if b.count(0) != len(b):
                    out.write(b)
                else:
                    out.seek(len(b), 1)
                left -= len(b)
        elif t == FILL:
            v = f.read(4)
            if v != b'\0\0\0\0':
                out.seek(pos * bs)
                out.write(v * (bs // 4) * sz)
        elif t == DONT_CARE:
            pass
        else:
            f.seek(tot - 12, 1)
        pos += sz if t != CRC else 0
        if consume:
            cur = f.tell() & ~4095
            if cur - punched >= PIECE:
                out.flush()
                os.fsync(out.fileno())
                punch(f.fileno(), punched, cur - punched)
                punched = cur
        if i % 2000 == 0:
            print(f'\r{i * 100 // nc}%', end='', file=sys.stderr, flush=True)
    assert pos == tb, (pos, tb)
    out.close()
    if consume:
        punch(f.fileno(), punched, (os.path.getsize(a[0]) - punched) & ~4095)
    print(f'\r{a[1]}: {tb} blocks', file=sys.stderr)


if __name__ == '__main__':
    main()
