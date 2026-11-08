#!/usr/bin/env python3
"""addlc.py BIN DYLIB_PATH [OUT]: append an LC_LOAD_DYLIB to a thin Mach-O (uses the slack before __text).
Re-sign afterwards: codesign -f -s - --entitlements ents.plist OUT"""
import struct, sys
src, path = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else src
d = bytearray(open(src, 'rb').read())
magic, cpu, sub, ft, ncmds, scmds, flags, _ = struct.unpack_from('<8I', d, 0)
assert magic == 0xfeedfacf, 'thin 64-bit Mach-O only'
# find lowest section/segment file offset after the load commands
off, lowest = 32, 1 << 62
for i in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        nsects = struct.unpack_from('<I', d, off + 64)[0]
        for s in range(nsects):
            so = off + 72 + s * 80
            soff = struct.unpack_from('<I', d, so + 48)[0]
            if soff: lowest = min(lowest, soff)
    off += sz
nm = path.encode() + b'\0'
cmdsz = (24 + len(nm) + 7) & ~7
end = 32 + scmds
assert end + cmdsz <= lowest, 'no slack for a new load command (%d free, %d needed)' % (lowest - end, cmdsz)
lc = struct.pack('<IIIIII', 0xc, cmdsz, 24, 2, 0x10000, 0x10000) + nm
d[end:end + cmdsz] = lc.ljust(cmdsz, b'\0')
struct.pack_into('<II', d, 16, ncmds + 1, scmds + cmdsz)
open(out, 'wb').write(d)
print('added LC_LOAD_DYLIB', path, 'to', out)
