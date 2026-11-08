#!/usr/bin/env python3
"""Raw image -> Android sparse image (like AOSP img2simg), for macOS where fastboot fails on a huge raw file.

  img2simg.py RAW.img OUT.simg [--consume] [--block 4096]

All-zero blocks become FILL chunks of zero (same as tools/img2simg.py in the main checkout and as libsparse:
tiny to send, the device really writes the zeros, so no old data stays behind). The raw image is a sparse file;
the .simg is as big as its DATA, so with little free disk RAW and SIMG together do not fit.
--consume punches a hole (F_PUNCHHOLE, APFS) over every 16 MiB piece right after it was read, so the raw image
shrinks while the simg grows: afterwards RAW.img is destroyed (all zeros) and only OUT.simg is left.
Flash with:  fastboot -S 512M flash userdata OUT.simg
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import renegade_platform as rplat  # noqa: E402

SPARSE_MAGIC = 0xED26FF3A
RAW, FILL = 0xCAC1, 0xCAC2
CHUNK_MAX = 4096                      # blocks per RAW chunk (16 MiB at 4K)
PIECE = 16 << 20


def punch(fd, off, length):
    rplat.punch_hole_safe(fd, off, length)      # macOS F_PUNCHHOLE, Linux fallocate(PUNCH_HOLE)


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    consume = '--consume' in sys.argv
    bs = int(sys.argv[sys.argv.index('--block') + 1]) if '--block' in sys.argv else 4096
    if '--block' in sys.argv:
        a.remove(sys.argv[sys.argv.index('--block') + 1])
    src, dst = a[0], a[1]
    size = os.path.getsize(src)
    assert size % bs == 0 and PIECE % bs == 0, 'image size must be a multiple of the block size'
    total = size // bs
    zero = bytes(bs)
    chunks = 0
    f = open(src, 'r+b' if consume else 'rb')
    with open(dst, 'wb') as o:
        o.write(bytes(28))
        kind, run = None, []

        def flush():
            nonlocal chunks, kind, run
            if kind == 'raw' and run:
                data = b''.join(run)
                o.write(struct.pack('<HHII', RAW, 0, len(run), 12 + len(data)))
                o.write(data)
                chunks += 1
            elif kind == 'zero' and run:
                o.write(struct.pack('<HHII', FILL, 0, run[0], 16))
                o.write(struct.pack('<I', 0))
                chunks += 1
            kind, run = None, []

        done = 0
        while done < size:
            piece = f.read(min(PIECE, size - done))
            mv = memoryview(piece)
            for i in range(0, len(piece), bs):
                b = mv[i:i + bs]
                if b == zero:
                    if kind != 'zero':
                        flush()
                        kind, run = 'zero', [0]
                    run[0] += 1
                else:
                    if kind != 'raw' or len(run) >= CHUNK_MAX:
                        flush()
                        kind = 'raw'
                    run.append(bytes(b))
            if consume:
                o.flush()
                punch(f.fileno(), done, len(piece))
            done += len(piece)
            print(f'\r{done * 100 // size}%', end='', file=sys.stderr, flush=True)
        flush()
        o.seek(0)
        o.write(struct.pack('<IHHHHIIII', SPARSE_MAGIC, 1, 0, 28, 12, bs, total, chunks, 0))
    print(f'\r{dst}: {total} blocks, {chunks} chunks, {os.path.getsize(dst) >> 20} MiB', file=sys.stderr)


if __name__ == '__main__':
    main()
