#!/usr/bin/env python3
"""Write a same-size replacement of a root file into an Android sparse image of the HFSX root, in place.

  simg_putfile.py SIMG ROOTPATH LOCALFILE [--dry-run]

For fixes that do not change a file's size (pacstrip_cache.py --islands on cache files extracted with
`hfsx.py SIMG dsc DIR`, page hashes re-computed in place): the file's extents are found with hfsx.py and only the
4 KiB blocks that differ are rewritten inside the RAW chunks of the simg. Neither the sparse format nor HFS checksum
file data, and nothing else in the image moves, so a delta flash (Bergamota `flash-userdata`) then sends only these
blocks. Refuses a size change and a block that is not inside a RAW chunk.
"""
import argparse
import bisect
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hfsx  # noqa: E402

BLK = 4096


def image_offset(f, pos):
    """offset in the raw image of byte `pos` of the hfsx.VFile `f`, and how many bytes follow contiguously"""
    bs = f.vol.bsize
    i = bisect.bisect_right(f.starts, pos) - 1
    o, st, c = f.ext[i]
    rel = pos - o
    return st * bs + rel, c * bs - rel


def simg_offset(img, off):
    """offset in the simg file of raw image offset `off` (RAW chunks only), and bytes left in that chunk"""
    i = bisect.bisect_right(img.starts, off) - 1
    t, ln, data, _ = img.chunks[i]
    if t != hfsx.RAW:
        raise SystemExit(f'raw offset {off:#x} is not in a RAW chunk (type {t:#x})')
    o = off - img.starts[i]
    return data + o, ln - o


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('simg')
    ap.add_argument('rootpath')
    ap.add_argument('local')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()
    img = hfsx.Simg(a.simg)
    vol = hfsx.Vol(img)
    f = vol.open(a.rootpath)
    new = open(a.local, 'rb').read()
    if len(new) != f.size:
        raise SystemExit(f'{a.rootpath}: size {f.size} in the image, {len(new)} locally: not a same-size fix')
    out = None if a.dry_run else open(a.simg, 'r+b')
    changed = 0
    for pos in range(0, f.size, BLK):
        n = min(BLK, f.size - pos)
        f.seek(pos)
        if f.read(n) == new[pos:pos + n]:
            continue
        changed += 1
        done = 0
        while done < n:
            raw, k1 = image_offset(f, pos + done)
            so, k2 = simg_offset(img, raw)
            k = min(n - done, k1, k2)
            if out:
                out.seek(so)
                out.write(new[pos + done:pos + done + k])
            done += k
    if out:
        out.close()
    print(f'{a.rootpath}: {changed} block(s) of {BLK} bytes {"would change" if a.dry_run else "written"}')


if __name__ == '__main__':
    main()
