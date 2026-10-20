#!/usr/bin/env python3
"""Decode the SWEET persistent console log (kernel patch 0047).

  sweet-log.py AREA.bin [OUT.txt]

AREA.bin is the last (1 + ring/4096) device blocks of the userdata partition
as read by tools/sweet-log-pull.sh: block 0 is the header ("SWEETLOG",
u32 version, u32 ring size, u64 total bytes, u64 flush sequence) and the ring
follows. Byte n of the console stream lives at ring offset n % size, so the
oldest bytes are overwritten once the boot has printed more than the ring.
"""
import struct
import sys

if len(sys.argv) < 2:
    sys.exit(__doc__)

data = open(sys.argv[1], 'rb').read()
magic, version, size, total, seq = struct.unpack_from('<8sIIQQ', data, 0)
if magic != b'SWEETLOG':
    sys.exit('no SWEETLOG header (log never flushed, or wrong area)')
if size == 0 or size > len(data):
    sys.exit(f'implausible ring size {size} in a {len(data)}-byte read')

ring = data[4096:4096 + size]
if total <= size:
    text = ring[:total]
else:
    start = total % size
    text = ring[start:] + ring[:start]
out = text.decode('utf-8', 'replace').replace('\r', '')

print(f'# version {version}, ring {size}, total {total} bytes, flush #{seq}'
      f'{" (wrapped: oldest bytes lost)" if total > size else ""}', file=sys.stderr)
if len(sys.argv) > 2:
    open(sys.argv[2], 'w').write(out)
    print(f'# wrote {len(out)} bytes to {sys.argv[2]}', file=sys.stderr)
else:
    sys.stdout.write(out)
