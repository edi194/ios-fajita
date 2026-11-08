#!/usr/bin/env python3
"""Split a squashed Qualcomm firmware ELF (e.g. a630_zap.mbn) into the .mdt + .bNN form PIL loaders use.

  zap-split.py a630_zap.mbn OUTDIR

.mdt = ELF header + program headers followed by the hash segment (the layout Linux's
qcom_mdt_read_metadata builds for the secure world); .bNN = the file contents of segment NN.
"""
import os
import struct
import sys


def main():
    src, out = sys.argv[1], sys.argv[2]
    d = open(src, 'rb').read()
    if d[:5] != b'\x7fELF\x01':
        sys.exit('not an ELF32 file')
    phoff, = struct.unpack_from('<I', d, 0x1c)
    phsz, phn = struct.unpack_from('<HH', d, 0x2a)
    ph = [struct.unpack_from('<8I', d, phoff + i * phsz) for i in range(phn)]
    hashes = [p for p in ph if (p[6] >> 24) & 7 == 2]
    if len(hashes) != 1:
        sys.exit('expected exactly one hash segment, found %d' % len(hashes))
    base = os.path.splitext(os.path.basename(src))[0]
    os.makedirs(out, exist_ok=True)
    h = hashes[0]
    open(os.path.join(out, base + '.mdt'), 'wb').write(d[:phoff + phsz * phn] + d[h[1]:h[1] + h[4]])
    for i, p in enumerate(ph):
        if p[4]:
            open(os.path.join(out, '%s.b%02u' % (base, i)), 'wb').write(d[p[1]:p[1] + p[4]])
    print('\n'.join(sorted(os.listdir(out))))


if __name__ == '__main__':
    main()
