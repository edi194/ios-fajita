#!/usr/bin/env python3
"""Set owner/group of EVERY catalog record of an unjournaled HFS+/HFSX image to root:wheel (0:0), in place.

  hfsroot_chown.py IMAGE

The Mac user cannot chown, and a noowners mount writes whatever uid it likes, so the image is built unprivileged
and then fixed here. Walks the catalog B-tree leaf chain; permissions sit at offset 32 of a folder/file record
(ownerID, groupID); modes (setuid, executable bits) are left alone. Only the first 8 catalog extents are
followed (a fresh image of ~100 MB is far below that).
"""
import struct
import sys


def main():
    f = open(sys.argv[1], 'r+b')
    f.seek(1024)
    vh = f.read(512)
    sig = vh[:2]
    assert sig in (b'H+', b'HX'), f'not HFS+/HFSX: {sig!r}'
    assert not (struct.unpack_from('>I', vh, 4)[0] & (1 << 13)), 'volume is journaled (newfs_hfs without -J)'
    bsize = struct.unpack_from('>I', vh, 40)[0]
    logical, clump, total = struct.unpack_from('>QII', vh, 272)
    extents = [struct.unpack_from('>II', vh, 288 + 8 * i) for i in range(8)]
    assert sum(c for s, c in extents) >= total, 'catalog has overflow extents (not supported)'

    def read_node(n, size):
        pos = n * size
        for s, c in extents:
            span = c * bsize
            if pos < span:
                return s * bsize + pos
            pos -= span
        raise SystemExit('node outside extents')

    off = read_node(0, 512)           # header node: node size is inside, read with a temporary 512 guess
    f.seek(off)
    hdr = f.read(512)
    nodesize = struct.unpack_from('>H', hdr, 14 + 18)[0]
    first = struct.unpack_from('>I', hdr, 14 + 10)[0]
    n, changed, nodes = first, 0, 0
    while n:
        o = read_node(n, nodesize)
        f.seek(o)
        node = bytearray(f.read(nodesize))
        flink, blink, kind, height, nrec = struct.unpack_from('>IIbBH', node, 0)
        assert kind == -1, f'node {n} is not a leaf'
        for i in range(nrec):
            ro = struct.unpack_from('>H', node, nodesize - 2 * (i + 1))[0]
            klen = struct.unpack_from('>H', node, ro)[0]
            d = ro + 2 + klen
            d += d & 1
            rtype = struct.unpack_from('>H', node, d)[0]
            if rtype in (1, 2):
                struct.pack_into('>II', node, d + 32, 0, 0)
                changed += 1
        f.seek(o)
        f.write(node)
        nodes += 1
        n = flink
    f.close()
    print(f'{changed} catalog records set to 0:0 ({nodes} leaf nodes)')


if __name__ == '__main__':
    main()
