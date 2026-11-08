#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Derive a boot image from an existing Enxerto/SWEETXNU boot image by editing ONLY the kernel command line of its payload
(kernel, ADT, Enxerto and the Android boot header stay byte-identical; nothing is flashed or booted here).

  make-boot-image.py BASE.img OUT.img [--add ARG]... [--del KEY]... [--print]

--del KEY removes every argument KEY or KEY=value, --add ARG appends ARG (replacing an existing KEY=...). The command line
field is the 608-byte `cmdline` of the payload (tools/mkpayload.py layout, offset 0x48 from the "SWEETXNU" magic).
Examples (docs/GPU_EAGL.md):
  shim-boot-gles-soft.img = shim-boot-ios18-fixvar-dma.img --del sweetfixvar --add bglrender=soft
  shim-boot-gles-gpu.img  = the gpu-kernel 8d boot image                     --add bglrender=1
"""
import argparse, sys

MAGIC, CMDLINE, LEN = b'SWEETXNU', 0x48, 608


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('base'); ap.add_argument('out')
    ap.add_argument('--add', action='append', default=[]); ap.add_argument('--del', dest='dele', action='append', default=[])
    ap.add_argument('--print', action='store_true')
    a = ap.parse_args()
    img = bytearray(open(a.base, 'rb').read())
    off = img.find(MAGIC)
    if off < 0 or img.find(MAGIC, off + 1) >= 0 and False:
        sys.exit('no SWEETXNU payload in ' + a.base)
    cur = bytes(img[off + CMDLINE:off + CMDLINE + LEN]).split(b'\0')[0].decode()
    args = cur.split()
    key = lambda s: s.split('=', 1)[0]
    args = [x for x in args if key(x) not in [key(d) for d in a.dele] and key(x) not in [key(d) for d in a.add]]
    args += a.add
    new = ' '.join(args)
    if len(new) >= LEN:
        sys.exit('command line too long (%d >= %d)' % (len(new), LEN))
    img[off + CMDLINE:off + CMDLINE + LEN] = new.encode().ljust(LEN, b'\0')
    open(a.out, 'wb').write(img)
    print('payload at 0x%x\nold: %s\nnew: %s' % (off, cur, new))


if __name__ == '__main__':
    main()
