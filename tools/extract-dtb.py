#!/usr/bin/env python3
"""Extract the stock device tree(s) from an Android boot.img and pick the one for your phone.

  extract-dtb.py BOOT.img OUTDIR [--live LIVE.dtb] [--pick N]

Works for boot.img header v0-v2:
  * v2 (e.g. Redmi Note 10 Pro `sweet`): the DTB has its own section in the header.
  * v0/v1 (e.g. Poco F1 `beryllium`): the kernel is `Image.gz-dtb`, a gzip stream with the
    DTBs appended right after it (21 of them on the Poco F1 ROM). Generic unpackers only give
    you `kernel`; this tool gunzips it, finds the trailing FDT blobs (magic d00dfeed + totalsize)
    and writes each as OUTDIR/rom-N.dtb.

It prints model, qcom,msm-id and qcom,board-id of every blob. ABL picks the blob whose msm-id
and board-id match the SoC and board; use the same one:
  * --live LIVE.dtb   the phone's running device tree, read in recovery with
                      `adb pull /sys/firmware/fdt live.dtb` (OrangeFox/TWRP, adb root). The blob
                      with the same msm-id + board-id (and model, if several match) is selected.
  * --pick N          choose blob N by hand.
The selected blob is also written as OUTDIR/dtb, the path Enxerto's build.sh expects
(DTB=../dtb/<board>/dtb). For the Poco F1 the right one is "Beryllium MP v2.1"
(msm-id <0x141 0x20001>, board-id <0x45 0>).
"""
import argparse
import os
import struct
import sys
import zlib

FDT_MAGIC = 0xd00dfeed


def boot_parts(b):
    if b[:8] != b'ANDROID!':
        sys.exit('not an Android boot image (no ANDROID! magic)')
    ks, _, rs, _, ss, _, _, ps, ver = struct.unpack_from('<9I', b, 8)
    rnd = lambda n: (n + ps - 1) // ps * ps
    off = ps
    kernel = b[off:off + ks]
    off += rnd(ks) + rnd(rs) + rnd(ss)
    dtb = b''
    if ver >= 1:
        rds, = struct.unpack_from('<I', b, 1632)
        off += rnd(rds)
    if ver >= 2:
        ds, = struct.unpack_from('<I', b, 1648)
        dtb = b[off:off + ds]
    return ver, kernel, dtb


def split_fdts(buf):
    out, i = [], 0
    while True:
        i = buf.find(struct.pack('>I', FDT_MAGIC), i)
        if i < 0 or i + 8 > len(buf):
            return out
        size, = struct.unpack_from('>I', buf, i + 4)
        if 40 <= size <= len(buf) - i:
            out.append(buf[i:i + size])
            i += size
        else:
            i += 4


def fdt_root_props(blob):
    """Properties of the root node only (model, qcom,msm-id, qcom,board-id)."""
    _, _, off_struct, off_strings = struct.unpack_from('>4I', blob, 0)[:4]
    off_struct, = struct.unpack_from('>I', blob, 8)
    off_strings, = struct.unpack_from('>I', blob, 12)
    p, depth, props = off_struct, 0, {}
    while p + 4 <= len(blob):
        tok, = struct.unpack_from('>I', blob, p)
        p += 4
        if tok == 1:  # BEGIN_NODE
            end = blob.index(b'\0', p)
            p = (end + 4) & ~3
            depth += 1
        elif tok == 2:  # END_NODE
            depth -= 1
            if depth == 0:
                break
        elif tok == 3:  # PROP
            ln, nameoff = struct.unpack_from('>II', blob, p)
            p += 8
            val = blob[p:p + ln]
            p = (p + ln + 3) & ~3
            if depth == 1:
                name = blob[off_strings + nameoff:blob.index(b'\0', off_strings + nameoff)].decode()
                props[name] = val
        elif tok == 9:  # END
            break
    return props


def cells(v):
    return tuple(struct.unpack('>%dI' % (len(v) // 4), v)) if v else ()


def describe(blob):
    pr = fdt_root_props(blob)
    model = pr.get('model', b'').split(b'\0')[0].decode(errors='replace')
    return model, cells(pr.get('qcom,msm-id')), cells(pr.get('qcom,board-id'))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('boot'); ap.add_argument('out')
    ap.add_argument('--live', help="the phone's running FDT (adb pull /sys/firmware/fdt)")
    ap.add_argument('--pick', type=int, help='index of the blob to use')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    ver, kernel, dtb = boot_parts(open(a.boot, 'rb').read())
    if dtb:
        blobs = split_fdts(dtb)
        where = 'the header v%d dtb section' % ver
    else:
        if kernel[:2] != b'\x1f\x8b':
            sys.exit('kernel is not gzip (Image.gz-dtb expected for header v%d); try binwalk' % ver)
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        d.decompress(kernel)
        blobs = split_fdts(d.unused_data)
        where = 'after the gzip kernel (Image.gz-dtb, header v%d)' % ver
    if not blobs:
        sys.exit('no device tree found ' + where)
    print('%d device tree(s) found %s:' % (len(blobs), where))
    descs = []
    for i, b in enumerate(blobs):
        open(os.path.join(a.out, 'rom-%d.dtb' % i), 'wb').write(b)
        m, msm, board = describe(b)
        descs.append((m, msm, board))
        print('  rom-%-2d %7d bytes  msm-id %-24s board-id %-14s %s' % (
            i, len(b), ' '.join(hex(x) for x in msm), ' '.join(hex(x) for x in board), m))
    pick = a.pick
    if pick is None and a.live:
        lm, lmsm, lboard = describe(open(a.live, 'rb').read())
        print('live: msm-id %s board-id %s model %s' % (' '.join(map(hex, lmsm)), ' '.join(map(hex, lboard)), lm))
        hits = [i for i, (m, msm, board) in enumerate(descs)
                if set(zip(lmsm[::2], lmsm[1::2])) & set(zip(msm[::2], msm[1::2])) and board[:2] == lboard[:2]]
        if len(hits) > 1:
            hits = [i for i in hits if descs[i][0] == lm] or hits
        if hits:
            pick = hits[0]
            if len(hits) > 1:
                print('live tree matches %s; using the first (ABL picks the first match), override with --pick' % hits)
        else:
            print('live tree matches nothing; choose one with --pick')
    if pick is None:
        print('\nno blob selected: rerun with --live LIVE.dtb or --pick N (OUTDIR/rom-N.dtb are written)')
        return
    open(os.path.join(a.out, 'dtb'), 'wb').write(blobs[pick])
    print('\nselected rom-%d (%s) -> %s' % (pick, descs[pick][0], os.path.join(a.out, 'dtb')))


if __name__ == '__main__':
    main()
