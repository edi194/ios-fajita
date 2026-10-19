#!/usr/bin/env python3
"""Extract every flattened device tree (FDT) appended to a kernel image.

Qualcomm kernels built with CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE carry the
board DTBs after the kernel payload.  This writes them as OUT/NAME-N.dtb.
"""
import sys

if len(sys.argv) < 3:
    sys.exit(f"usage: {sys.argv[0]} KERNEL OUTDIR [PREFIX]")
src, outdir = sys.argv[1], sys.argv[2]
prefix = sys.argv[3] if len(sys.argv) > 3 else "dtb"
data = open(src, "rb").read()
magic = b"\xd0\x0d\xfe\xed"
import os

os.makedirs(outdir, exist_ok=True)
pos = n = 0
while True:
    pos = data.find(magic, pos)
    if pos < 0:
        break
    if pos + 8 > len(data):
        break
    size = int.from_bytes(data[pos + 4:pos + 8], "big")
    if 64 <= size <= len(data) - pos:
        path = f"{outdir}/{prefix}{n}.dtb"
        open(path, "wb").write(data[pos:pos + size])
        print(f"{path}: offset 0x{pos:x} size {size}")
        n += 1
    pos += 4
print(f"{n} DTB(s)")
