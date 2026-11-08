#!/usr/bin/env python3
"""Raw image -> Android sparse image (what AOSP img2simg does), for macOS
where platform-tools has no img2simg and fastboot fails on huge raw files.

  img2simg.py RAW.img OUT.simg [BLOCK_SIZE]   (default 4096)

All-zero blocks become FILL chunks of zero (like libsparse): tiny to send,
but the device really writes the zeros, so no old data stays behind.
Flash with:  fastboot -S 512M flash userdata OUT.simg
"""
import os, struct, sys, zlib

SPARSE_MAGIC = 0xED26FF3A
RAW, FILL, DONT_CARE, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
CHUNK_MAX = 4096          # blocks per RAW chunk (16 MiB at 4K)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    bs = int(sys.argv[3]) if len(sys.argv) > 3 else 4096
    size = os.path.getsize(src)
    assert size % bs == 0, 'image size must be a multiple of the block size'
    total = size // bs
    zero = bytes(bs)
    chunks = 0
    with open(src, 'rb') as f, open(dst, 'wb') as o:
        o.write(bytes(28))                       # header, written at the end
        run_kind, run = None, []                 # current chunk: 'raw' blocks or zero count

        def flush():
            nonlocal chunks, run_kind, run
            if run_kind == 'raw' and run:
                data = b''.join(run)
                o.write(struct.pack('<HHII', RAW, 0, len(run), 12 + len(data)))
                o.write(data)
                chunks += 1
            elif run_kind == 'zero' and run:
                o.write(struct.pack('<HHII', FILL, 0, run[0], 16))
                o.write(struct.pack('<I', 0))
                chunks += 1
            run_kind, run = None, []

        for i in range(total):
            b = f.read(bs)
            if b == zero:
                if run_kind != 'zero':
                    flush()
                    run_kind, run = 'zero', [0]
                run[0] += 1
            else:
                if run_kind != 'raw' or len(run) >= CHUNK_MAX:
                    flush()
                    run_kind = 'raw'
                run.append(b)
            if i % 262144 == 0:
                print(f'\r{i * 100 // total}%', end='', file=sys.stderr, flush=True)
        flush()
        o.seek(0)
        o.write(struct.pack('<IHHHHIIII', SPARSE_MAGIC, 1, 0, 28, 12, bs, total, chunks, 0))
    print(f'\r{dst}: {total} blocks, {chunks} chunks, {os.path.getsize(dst) >> 20} MiB', file=sys.stderr)


if __name__ == '__main__':
    main()
