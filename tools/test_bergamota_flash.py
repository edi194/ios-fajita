#!/usr/bin/env python3
"""End-to-end test of tools/bergamota-flash.py against a FAKE DEVICE: a file stands in for the partition.

  python3 tools/test_bergamota_flash.py

The fake device answers like Enxerto does (partition-size, per-block BLAKE2b-128 hashes of the real
file contents, flash of a sparse or raw file) but applies the sparse image with its OWN minimal parser
(written independently of the tool's reader/writer), so a bug in the tool's sparse writer or hash
logic cannot hide. Covers: raw and sparse inputs, a block size that does not divide the image, delta
sends only the changed blocks, an identical image sends nothing, FILL chunks for uniform changed blocks,
--full, verification catching a device that corrupts a write, size and allowlist refusals.
"""
import hashlib
import importlib.util
import os
import random
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bergamota_flash", os.path.join(HERE, "bergamota-flash.py"))
bf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bf)

failures = 0
checks = 0


def check(cond, what):
    global failures, checks
    checks += 1
    if not cond:
        failures += 1
        print(f"FAIL: {what}")


def apply_sparse(path, out_fd_path, part_size):
    """Independent sparse applier: writes RAW/FILL into the partition file, DONT_CARE leaves it alone."""
    d = open(path, "rb").read()
    magic, major, minor, fhs, chs, bs, total_blks, nchunks, _ = struct.unpack_from("<IHHHHIIII", d, 0)
    assert magic == 0xED26FF3A and major == 1 and fhs == 28 and chs == 12
    assert total_blks * bs <= part_size
    pos = fhs
    blk = 0
    written = 0
    with open(out_fd_path, "r+b") as f:
        for _ in range(nchunks):
            t, _r, csz, tsz = struct.unpack_from("<HHII", d, pos)
            body = d[pos + 12:pos + tsz]
            f.seek(blk * bs)
            if t == 0xCAC1:
                assert len(body) == csz * bs
                f.write(body)
                written += len(body)
            elif t == 0xCAC2:
                f.write(body[:4] * (csz * bs // 4))
                written += csz * bs
            elif t == 0xCAC3:
                assert tsz == 12
            elif t == 0xCAC4:
                assert csz == 0
            else:
                raise AssertionError(f"chunk type {t:#x}")
            blk += csz
            pos += tsz
        assert pos == len(d), "trailing bytes in sparse image"
        assert blk == total_blks, f"chunks cover {blk} of {total_blks} blocks"
    return written


class FakeDevice:
    """Stand-in for FastbootDevice."""

    def __init__(self, partfile, size, corrupt=False):
        self.partfile = partfile
        self.size = size
        self.corrupt = corrupt
        self.flash_calls = []
        self.hash_calls = 0
        self.bytes_sent = 0
        self.written = 0

    def partition_size(self, part):
        assert part in ("userdata", "boot", "logo")
        return self.size

    def hashes(self, part, off, length, bs):
        assert part in bf.ALLOWED and off % 4096 == 0 and length % 4096 == 0 and bs % 4096 == 0
        self.hash_calls += 1
        out = bytearray()
        with open(self.partfile, "rb") as f:
            f.seek(off)
            data = f.read(length)
        for i in range(0, length, bs):
            out += hashlib.blake2b(data[i:i + bs], digest_size=16).digest()
        return bytes(out)

    def flash(self, part, path, on_send=None):
        assert part in bf.ALLOWED
        size = os.path.getsize(path)
        self.flash_calls.append((part, path, size))
        self.bytes_sent += size
        with open(path, "rb") as f:
            sparse = struct.unpack("<I", f.read(4))[0] == 0xED26FF3A
        if sparse:
            self.written += apply_sparse(path, self.partfile, self.size)
        else:
            data = open(path, "rb").read()
            data += bytes((-len(data)) % 4096)      # the device pads the last block with zeros
            with open(self.partfile, "r+b") as f:
                f.write(data)
            self.written += len(data)
        if self.corrupt:
            with open(self.partfile, "r+b") as f:
                f.seek(12345)
                b = f.read(1)
                f.seek(12345)
                f.write(bytes([b[0] ^ 0x10]))
        if on_send:
            on_send(size, size)


def make_image(rng, size):
    """Mixed contents: random data, zero runs, a repeated word, runs of text."""
    out = bytearray()
    while len(out) < size:
        kind = rng.choice("rzfzt")
        n = rng.choice([4096, 8192, 65536, 100000, 262144, 700000])
        if kind == "r":
            out += rng.randbytes(n)
        elif kind == "z":
            out += bytes(n)
        elif kind == "f":
            out += b"\xde\xad\xbe\xef" * (n // 4)
        else:
            out += (b"bergamota " * (n // 10 + 1))[:n]
    return bytes(out[:size])


def to_sparse(raw, path, bs=4096):
    """Android sparse image of raw: zero blocks -> FILL, repeated-word -> FILL, others RAW, a DONT_CARE hole in the middle."""
    assert len(raw) % bs == 0
    chunks = []
    nblk = len(raw) // bs
    i = 0
    while i < nblk:
        blk = raw[i * bs:(i + 1) * bs]
        pat = blk[:4]
        if blk == pat * (bs // 4):
            j = i + 1
            while j < nblk and raw[j * bs:(j + 1) * bs] == blk:
                j += 1
            chunks.append((0xCAC2, j - i, pat))
            i = j
        else:
            j = i + 1
            while j < nblk and raw[j * bs:(j + 1) * bs] != raw[j * bs:j * bs + 4] * (bs // 4) and j - i < 300:
                j += 1
            chunks.append((0xCAC1, j - i, raw[i * bs:j * bs]))
            i = j
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHHHIIII", 0xED26FF3A, 1, 0, 28, 12, bs, nblk, len(chunks) + 1, 0))
        for t, n, body in chunks:
            if t == 0xCAC1:
                f.write(struct.pack("<HHII", t, 0, n, 12 + len(body)) + body)
            else:
                f.write(struct.pack("<HHII", t, 0, n, 16) + body)
        f.write(struct.pack("<HHII", 0xCAC4, 0, 0, 16) + struct.pack("<I", 0))   # a CRC32 chunk: ignored


def run(dev, part, img, **kw):
    return bf.flash_partition(dev, part, img, log=lambda s: None, **kw)


def main():
    rng = random.Random(1234)
    with tempfile.TemporaryDirectory() as td:
        P = lambda n: os.path.join(td, n)
        # ---- image A (new) and image B (what the phone has): B differs from A in a few places
        size = 9 * (1 << 20) + 3 * 4096              # not a multiple of the 64 KiB hash block
        a = make_image(rng, size)
        b = bytearray(a)
        for off, n in [(0, 10), (70000, 5000), (3_000_000, 70000), (size - 100, 100), (5 * (1 << 20), 4096 * 3)]:
            b[off:off + n] = rng.randbytes(n)
        b[2_000_000:2_000_000 + 65536] = bytes(65536)     # B has zeros where A has data
        b = bytes(b)
        open(P("a.img"), "wb").write(a)
        part_size = 16 << 20
        tail = rng.randbytes(part_size - len(b))
        pad = lambda raw: raw + bytes((-len(raw)) % 4096)

        def fresh(content=b):
            with open(P("part.bin"), "wb") as f:
                f.write(pad(content))
                f.write(tail[:part_size - len(pad(content))])
            return FakeDevice(P("part.bin"), part_size)

        def part_head(n):
            return open(P("part.bin"), "rb").read(n)

        apad = pad(a)

        # ---- 1. delta from a raw image: only the changed 64 KiB blocks travel, result == A, tail untouched
        dev = fresh()
        msg = run(dev, "userdata", P("a.img"))
        check(part_head(len(apad)) == apad, "delta raw: partition equals the image")
        check(open(P("part.bin"), "rb").read()[len(pad(b)):] == tail[:part_size - len(pad(b))], "delta raw: beyond the image untouched")
        changed_blocks = {0, 1, 2, 45, 46, 30, 31, 32, 78, 144, 145, size // 65536}
        check(0 < dev.bytes_sent < len(a) // 4, f"delta raw: sent {dev.bytes_sent} of {len(a)}")
        check(dev.written <= 12 * 65536 + 65536, f"delta raw: wrote {dev.written} bytes")
        check(len(dev.flash_calls) == 1 and dev.flash_calls[0][1].endswith(".simg"), "delta raw: one sparse flash")
        check("verified" in msg, "delta raw: verified")

        # ---- 2. the identical image sends nothing
        dev = fresh(a)
        msg = run(dev, "userdata", P("a.img"))
        check(dev.flash_calls == [] and "nothing sent" in msg, "identical image: nothing sent")

        # ---- 3. sparse input (FILL/RAW/CRC chunks), streamed, delta
        to_sparse(apad, P("a.simg"))
        dev = fresh()
        run(dev, "userdata", P("a.simg"))
        check(part_head(len(apad)) == apad, "delta sparse input: partition equals the expanded image")
        check(dev.bytes_sent < len(a) // 4, "delta sparse input: small delta")
        dev = fresh(a)
        msg = run(dev, "userdata", P("a.simg"))
        check(dev.flash_calls == [] and "nothing sent" in msg, "sparse vs raw hashes agree (identical -> nothing sent)")

        # ---- 4. the delta image: only changed blocks, FILL for uniform ones, DONT_CARE elsewhere
        dev = fresh()
        keep = P("kept.simg")
        run(dev, "userdata", P("a.img"), keep_delta=keep)
        d = open(keep, "rb").read()
        magic, major, minor, fhs, chs, bs, total_blks, nchunks, _ = struct.unpack_from("<IHHHHIIII", d, 0)
        check(bs == 4096 and total_blks == len(apad) // 4096, "delta header")
        kinds = []
        pos = fhs
        for _ in range(nchunks):
            t, _r, csz, tsz = struct.unpack_from("<HHII", d, pos)
            kinds.append((t, csz))
            pos += tsz
        check(any(t == 0xCAC3 for t, _ in kinds) and any(t == 0xCAC1 for t, _ in kinds), "delta has DONT_CARE and RAW chunks")
        check(sum(c for t, c in kinds) == total_blks, "delta chunks cover the image")

        # a block that is zeros in A but data in B becomes a FILL chunk
        a2 = bytearray(a)
        a2[1_000_000 - 1_000_000 % 65536:1_000_000 - 1_000_000 % 65536 + 65536] = bytes(65536)
        open(P("a2.img"), "wb").write(a2)
        dev = fresh(a)
        run(dev, "userdata", P("a2.img"), keep_delta=P("fill.simg"))
        d = open(P("fill.simg"), "rb").read()
        nch = struct.unpack_from("<I", d, 20)[0]
        pos = 28
        types = []
        for _ in range(nch):
            t, _r, csz, tsz = struct.unpack_from("<HHII", d, pos)
            types.append(t)
            pos += tsz
        check(0xCAC2 in types, "zeroed block travels as a FILL chunk")
        check(os.path.getsize(P("fill.simg")) < 4096, "...so the delta image is tiny")
        check(part_head(len(a2)) == bytes(a2), "FILL delta applied")

        # ---- 5. --full sends everything
        dev = fresh()
        run(dev, "userdata", P("a.img"), mode="full")
        check(dev.flash_calls[0][1] == P("a.img") and dev.bytes_sent == len(a), "full: the original file goes to fastboot")
        check(part_head(len(apad)) == apad, "full: partition equals the image")
        dev = fresh()
        run(dev, "userdata", P("a.simg"), mode="full")
        check(dev.flash_calls[0][1] == P("a.simg") and part_head(len(apad)) == apad, "full sparse")

        # ---- 6. boot and logo default to full; boot needs an Android header
        dev = fresh()
        small = rng.randbytes(300000)
        open(P("logo.img"), "wb").write(small)
        run(dev, "logo", P("logo.img"))
        check(dev.flash_calls[0][1] == P("logo.img") and part_head(len(small)) == small, "logo: full by default")
        open(P("boot.img"), "wb").write(b"ANDROID!" + rng.randbytes(100000))
        dev = fresh()
        run(dev, "boot", P("boot.img"))
        check(dev.flash_calls[0][1] == P("boot.img"), "boot: full by default")
        try:
            open(P("notboot.img"), "wb").write(b"JUNK" + bytes(5000))
            run(fresh(), "boot", P("notboot.img"))
            check(False, "a non boot image is refused for boot")
        except bf.FlashError:
            check(True, "")

        # ---- 7. verification catches a device that corrupts a write (and the delta is still correct without it)
        dev = fresh()
        dev.corrupt = True
        try:
            run(dev, "userdata", P("a.img"))
            check(False, "verify must fail on a corrupting device")
        except bf.FlashError as e:
            check("verify FAILED" in str(e), "verify FAILED message")
        dev = fresh()
        dev.corrupt = True
        run(dev, "userdata", P("a.img"), verify=False)
        check(part_head(len(apad)) != apad, "without verify the corruption is not noticed (what verify is for)")

        # ---- 8. refusals
        for bad in ("modem", "persist", "userdata_a", "abl", "xbl", "../userdata", ""):
            try:
                run(fresh(), bad, P("a.img"))
                check(False, f"partition {bad!r} must be refused")
            except bf.FlashError:
                check(True, "")
        check(bf.main(["flash", "modem", P("a.img")]) == 1, "CLI refuses modem before touching anything")
        small_dev = FakeDevice(P("part.bin"), 1 << 20)
        try:
            run(small_dev, "userdata", P("a.img"))
            check(False, "image larger than the partition must be refused")
        except bf.FlashError as e:
            check("larger than" in str(e), "size refusal")

        # ---- 9. dry run sends nothing
        dev = fresh()
        msg = run(dev, "userdata", P("a.img"), dry_run=True)
        check(dev.flash_calls == [] and "dry run" in msg, "dry run")

        # ---- 10. block size 4 KiB and 1 MiB give the same result
        for bs in (4096, 1 << 20):
            dev = fresh()
            run(dev, "userdata", P("a.img"), bs=bs)
            check(part_head(len(apad)) == apad, f"block size {bs}")

        # ---- 11. reader: sparse and raw views of the same bytes hash identically, odd reads work
        ia, isp = bf.Image(P("a.img")), bf.Image(P("a.simg"))
        check(ia.padded == isp.padded == len(apad), "padded sizes")
        for off, n in [(0, 10), (4090, 20), (65530, 40000), (len(apad) - 7, 7), (1_234_567, 99_999)]:
            check(ia.read(off, n) == apad[off:off + n] == isp.read(off, n), f"read {off}+{n}")
        check(ia.block_hashes(65536) == isp.block_hashes(65536), "block hashes of raw and sparse agree")
        want = b"".join(hashlib.blake2b(apad[i:i + 65536], digest_size=16).digest() for i in range(0, len(apad), 65536))
        check(ia.block_hashes(65536) == want, "block hashes match hashlib")
        ia.close()
        isp.close()

        # ---- 12. DONT_CARE in a sparse input counts as zeros in delta mode
        with open(P("hole.simg"), "wb") as f:
            f.write(struct.pack("<IHHHHIIII", 0xED26FF3A, 1, 0, 28, 12, 4096, 32, 2, 0))
            f.write(struct.pack("<HHII", 0xCAC3, 0, 16, 12))
            f.write(struct.pack("<HHII", 0xCAC1, 0, 16, 12 + 16 * 4096) + bytes([7]) * (16 * 4096))
        dev = fresh()
        run(dev, "userdata", P("hole.simg"))
        check(part_head(16 * 4096) == bytes(16 * 4096) and part_head(32 * 4096)[16 * 4096:] == bytes([7]) * (16 * 4096),
              "hole.simg: DONT_CARE became zeros, data in place")

    print(f"test_bergamota_flash: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
