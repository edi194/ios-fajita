#!/usr/bin/env python3
"""Flash a partition through Bergamota fastboot (Enxerto's own fastboot), by default as a DELTA.

  bergamota-flash.py [-s SERIAL] [--fastboot PATH] flash PARTITION IMAGE [--delta | --full] [options]
  bergamota-flash.py [-s SERIAL] [--fastboot PATH] hash  PARTITION [--length BYTES] [--block 65536]
  bergamota-flash.py [-s SERIAL] [--fastboot PATH] info

PARTITION is userdata, boot or logo: nothing else is ever accepted here (and Enxerto refuses everything
else too). IMAGE is a raw image or an Android sparse image; a sparse image is streamed, never expanded
on disk (a 20 GB root costs a few MB of RAM).

Delta mode (default for userdata):
  1. the phone hashes what its partition really holds (`oem hash`, BLAKE2b-128 per 64 KiB block, read by
     Enxerto straight from UFS) and the Mac hashes the new image at the same time;
  2. the blocks that differ become a sparse image (RAW chunks for the changed blocks, FILL for blocks that
     are one repeated 32-bit word such as zeros, DONT_CARE for everything else);
  3. `fastboot -s SERIAL -S 512M flash PARTITION delta.simg` sends only that;
  4. the phone is hashed again and compared with the image (disable with --no-verify).
`--full` sends the whole image (the file as it is: a sparse input keeps fastboot's DONT_CARE = "not
written" meaning). In delta mode DONT_CARE regions of a sparse INPUT count as zeros (simg2img meaning):
the result is the fully expanded image.
boot and logo default to --full (they are small).

Machine readable lines on stdout (the Bergamota app parses them), everything else is for humans:
  PROGRESS <phase> <done_bytes> <total_bytes>     phase: hash-phone, hash-image, send, verify
  DELTA <changed_bytes> <image_bytes>
  RESULT OK <message>  |  RESULT FAIL <reason>    (exit status 0 / 1)
Protocol and design: docs/BERGAMOTA_FASTBOOT.md.
"""
import argparse
import bisect
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor

ALLOWED = ("userdata", "boot", "logo")
SERIAL = "bergamota0001"
BLK = 4096
HASH_BS = 65536
HASH_LEN = 16
PHONE_SLICE = 1 << 30            # bytes hashed per `oem hash` call (progress granularity)
SPARSE_MAGIC = 0xED26FF3A
RAW, FILL, SKIP, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
MAX_RAW_CHUNK = 64 << 20


class FlashError(Exception):
    pass


# ---------------------------------------------------------------- output

_out_lock = threading.Lock()


def say(msg):
    with _out_lock:
        print(msg, flush=True)


def progress(phase, done, total):
    say(f"PROGRESS {phase} {int(done)} {int(total)}")


def h16(data):
    return hashlib.blake2b(data, digest_size=HASH_LEN).digest()


# ---------------------------------------------------------------- image reader (raw or sparse, streamed)

class Seg:
    __slots__ = ("start", "length", "kind", "foff", "pat")

    def __init__(self, start, length, kind, foff=0, pat=b"\0\0\0\0"):
        self.start, self.length, self.kind, self.foff, self.pat = start, length, kind, foff, pat

    @property
    def end(self):
        return self.start + self.length


class Image:
    """Random access to the EXPANDED contents of a raw or sparse image (DONT_CARE reads as zeros)."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY)
        self.sparse = False
        self.segs = []
        with open(path, "rb") as f:
            head = f.read(28)
            if len(head) >= 4 and struct.unpack("<I", head[:4])[0] == SPARSE_MAGIC:
                self._parse_sparse(f, head)
            else:
                size = os.fstat(self.fd).st_size
                self.size = size
                self.padded = (size + BLK - 1) // BLK * BLK
                self.segs = [Seg(0, size, "raw", 0)]
                if self.padded > size:
                    self.segs.append(Seg(size, self.padded - size, "skip"))
        self.starts = [s.start for s in self.segs]
        self.skips = [(s.start, s.end) for s in self.segs if s.kind == "skip" and not self._is_pad(s)]
        self._zero = {}

    def _is_pad(self, seg):
        return not self.sparse and seg.start == self.size

    def _parse_sparse(self, f, head):
        magic, major, minor, fhs, chs, bs, total_blks, nchunks, _ = struct.unpack("<IHHHHIIII", head)
        if major != 1 or fhs < 28 or chs < 12 or not bs or bs % 4:
            raise FlashError(f"{self.path}: unsupported sparse header")
        self.sparse = True
        self.size = self.padded = total_blks * bs
        f.seek(fhs)
        pos = 0
        filesize = os.fstat(self.fd).st_size
        for _ in range(nchunks):
            ch = f.read(12)
            if len(ch) < 12:
                raise FlashError(f"{self.path}: truncated sparse image")
            ctype, _r, csz, tsz = struct.unpack("<HHII", ch)
            if chs > 12:
                f.seek(chs - 12, 1)
            body = tsz - chs
            length = csz * bs
            if ctype == RAW:
                if body != length:
                    raise FlashError(f"{self.path}: bad RAW chunk")
                self.segs.append(Seg(pos, length, "raw", f.tell()))
                f.seek(body, 1)
            elif ctype == FILL:
                pat = f.read(4)
                self.segs.append(Seg(pos, length, "fill", 0, pat))
            elif ctype == SKIP:
                if length:
                    self.segs.append(Seg(pos, length, "skip"))
            elif ctype == CRC:
                f.seek(body, 1)
            else:
                raise FlashError(f"{self.path}: unknown sparse chunk type {ctype:#x}")
            pos += length
            if f.tell() > filesize:
                raise FlashError(f"{self.path}: truncated sparse image")
        if pos > self.size:
            raise FlashError(f"{self.path}: sparse chunks exceed the image size")
        if pos < self.size:
            self.segs.append(Seg(pos, self.size - pos, "skip"))

    def close(self):
        os.close(self.fd)

    def seg_at(self, off):
        return bisect.bisect_right(self.starts, off) - 1

    def read(self, off, n):
        """Exactly n bytes of the expanded image at off (zeros past the end)."""
        out = bytearray()
        end = off + n
        i = self.seg_at(off) if self.segs else 0
        while off < end and i < len(self.segs):
            s = self.segs[i]
            take = min(end, s.end) - off
            if take <= 0:
                i += 1
                continue
            if s.kind == "raw":
                got = os.pread(self.fd, take, s.foff + off - s.start)
                if len(got) != take:
                    raise FlashError(f"{self.path}: short read")
                out += got
            elif s.kind == "fill":
                phase = (off - s.start) % 4
                out += (s.pat * ((take + phase) // 4 + 1))[phase:phase + take]
            else:
                out += bytes(take)
            off += take
            i += 1
        if len(out) < n:
            out += bytes(n - len(out))
        return bytes(out)

    def has_dontcare(self, off, length):
        """True if [off, off+length) overlaps a DONT_CARE region of a sparse input."""
        i = bisect.bisect_left(self.skips, (off, 0)) - 1
        for a, b in self.skips[max(i, 0):]:
            if a >= off + length:
                break
            if b > off and a < off + length:
                return True
        return False

    def _zero_hash(self, pat, bs):
        k = (pat, bs)
        if k not in self._zero:
            self._zero[k] = h16(pat * (bs // 4))
        return self._zero[k]

    def block_hashes(self, bs=HASH_BS, workers=None, on_progress=None):
        """16 bytes BLAKE2b-128 per block of bs bytes of the padded image (the last block may be shorter)."""
        nb = (self.padded + bs - 1) // bs
        out = [None] * nb
        workers = workers or min(12, os.cpu_count() or 4)
        batch_blocks = max(1, (16 << 20) // bs)
        pending = deque()
        done_bytes = 0
        report_at = 0

        def hash_batch(off, nbytes, count):
            # reading happens in the worker too (pread is thread safe): disk and BLAKE2b overlap
            mv = memoryview(self.read(off, nbytes))
            return [h16(mv[k * bs:(k + 1) * bs]) for k in range(count)]

        def drain(limit):
            nonlocal done_bytes, report_at
            while len(pending) > limit:
                b0, cnt, fut = pending.popleft()
                out[b0:b0 + cnt] = fut.result()
                done_bytes = min(self.padded, (b0 + cnt) * bs)
                if on_progress and done_bytes - report_at >= (64 << 20):
                    report_at = done_bytes
                    on_progress(done_bytes, self.padded)

        with ThreadPoolExecutor(max_workers=workers) as ex:
            b = 0
            while b < nb:
                off = b * bs
                si = self.seg_at(off)
                s = self.segs[si]
                full = off + bs <= self.padded
                if s.kind in ("fill", "skip") and full and off + bs <= s.end and (off - s.start) % 4 == 0:
                    k = min((s.end - off) // bs, (self.padded - off) // bs)
                    d = self._zero_hash(s.pat if s.kind == "fill" else b"\0\0\0\0", bs)
                    out[b:b + k] = [d] * k
                    b += k
                    done_bytes = min(self.padded, b * bs)
                    if on_progress and done_bytes - report_at >= (64 << 20):
                        report_at = done_bytes
                        on_progress(done_bytes, self.padded)
                    continue
                # a run of ordinary blocks, up to the next uniform block or the batch size
                cnt = 0
                while cnt < batch_blocks and b + cnt < nb:
                    o = (b + cnt) * bs
                    t = self.segs[self.seg_at(o)]
                    if cnt and t.kind in ("fill", "skip") and o + bs <= t.end and o + bs <= self.padded and (o - t.start) % 4 == 0 \
                            and t.end - o >= 2 * bs:
                        break
                    cnt += 1
                nbytes = min(self.padded, (b + cnt) * bs) - off
                pending.append((b, cnt, ex.submit(hash_batch, off, nbytes, cnt)))
                b += cnt
                drain(workers * 2)
            drain(0)
        if on_progress:
            on_progress(self.padded, self.padded)
        return b"".join(out)


# ---------------------------------------------------------------- delta sparse writer

class SparseWriter:
    """Writes an Android sparse image (block 4096) with coalescing of neighbouring chunks of the same kind."""

    def __init__(self, path, total_blks):
        self.f = open(path, "wb")
        self.total = total_blks
        self.pos = 0
        self.nchunks = 0
        self.f.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, 28, 12, BLK, total_blks, 0, 0))
        self.open = None     # ("raw", bytearray) | ("fill", pat, nblk)
        self.skipping = 0

    def _chunk_hdr(self, ctype, nblk, total):
        self.f.write(struct.pack("<HHII", ctype, 0, nblk, total))
        self.nchunks += 1

    def _flush(self):
        if self.skipping:
            self._chunk_hdr(SKIP, self.skipping, 12)
            self.pos += self.skipping
            self.skipping = 0
        o = self.open
        if o is None:
            return
        if o[0] == "raw":
            nblk = len(o[1]) // BLK
            self._chunk_hdr(RAW, nblk, 12 + len(o[1]))
            self.f.write(o[1])
            self.pos += nblk
        else:
            self._chunk_hdr(FILL, o[2], 16)
            self.f.write(o[1])
            self.pos += o[2]
        self.open = None

    def _cur(self):
        """Block position including the chunk that is still open."""
        if self.open is None:
            return self.pos + self.skipping
        return self.pos + (len(self.open[1]) // BLK if self.open[0] == "raw" else self.open[2])

    def skip_to(self, blk):
        """DONT_CARE up to block index blk."""
        gap = blk - self._cur()
        if gap <= 0:
            return
        if self.open is None:
            self.skipping += gap
        else:
            self._flush()
            self.skipping = gap

    def raw(self, data):
        assert len(data) % BLK == 0
        if self.skipping:
            self._flush()
        if self.open is not None and (self.open[0] != "raw" or len(self.open[1]) + len(data) > MAX_RAW_CHUNK):
            self._flush()
        if self.open is None:
            self.open = ("raw", bytearray())
        self.open[1].extend(data)

    def fill(self, pat, nblk):
        if self.skipping:
            self._flush()
        if self.open is not None and (self.open[0] != "fill" or self.open[1] != pat):
            self._flush()
        if self.open is None:
            self.open = ("fill", pat, 0)
        self.open = ("fill", pat, self.open[2] + nblk)

    def close(self):
        self.skip_to(self.total)
        self._flush()
        if self.pos != self.total:
            raise FlashError("internal error: sparse writer position mismatch")
        self.f.seek(20)
        self.f.write(struct.pack("<I", self.nchunks))
        self.f.close()


def uniform_pattern(data):
    """The 4-byte pattern if data is that word repeated (e.g. zeros), else None."""
    pat = data[:4]
    if len(data) % 4 == 0 and data == pat * (len(data) // 4):
        return pat
    return None


def build_delta(img, changed, bs, out_path, on_progress=None):
    """changed: sorted hash-block indices that differ. Returns the number of bytes of image data written."""
    w = SparseWriter(out_path, img.padded // BLK)
    sent = 0
    batch = max(1, (16 << 20) // bs)
    i = 0
    n = len(changed)
    while i < n:
        j = i
        while j + 1 < n and changed[j + 1] == changed[j] + 1 and j + 1 - i < batch:
            j += 1
        off = changed[i] * bs
        end = min(img.padded, (changed[j] + 1) * bs)
        data = img.read(off, end - off)
        w.skip_to(off // BLK)
        for k in range(0, len(data), bs):
            blk = data[k:k + bs]
            pat = uniform_pattern(blk)
            if pat is not None:
                w.fill(pat, len(blk) // BLK)
            else:
                w.raw(blk)
        sent += len(data)
        if on_progress:
            on_progress(sent)
        i = j + 1
    w.close()
    return sent


def diff_blocks(phone, image):
    if len(phone) != len(image):
        raise FlashError(f"hash tables differ in size ({len(phone)} vs {len(image)})")
    return [k for k in range(len(image) // HASH_LEN) if phone[k * HASH_LEN:(k + 1) * HASH_LEN] != image[k * HASH_LEN:(k + 1) * HASH_LEN]]


# ---------------------------------------------------------------- devices

class FastbootDevice:
    """Bergamota fastboot through the `fastboot` command line tool."""

    def __init__(self, fastboot, serial=SERIAL, log=None):
        self.fastboot = fastboot
        self.serial = serial
        self.log = log or (lambda s: None)

    def _run(self, args, timeout=900, show=False):
        cmd = [self.fastboot, "-s", self.serial] + args
        self.log("$ " + " ".join(cmd))
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise FlashError(f"fastboot {' '.join(args[:2])} timed out")
        except FileNotFoundError:
            raise FlashError(f"fastboot not found: {self.fastboot}")
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 0 or "FAILED" in out:
            raise FlashError(f"fastboot {' '.join(args[:2])} failed: {out.strip().splitlines()[-1] if out.strip() else r.returncode}")
        return out

    def getvar(self, name):
        out = self._run(["getvar", name], timeout=30)
        m = re.search(re.escape(name) + r":\s*(\S+)", out)
        if not m:
            raise FlashError(f"getvar {name}: no answer ({out.strip()})")
        return m.group(1)

    def check(self):
        v = self.getvar("version-bootloader")
        if not v.startswith("bergamota"):
            raise FlashError(f"this is not Bergamota fastboot (version-bootloader {v}): enter it first ('Enter Bergamota fastboot')")
        if self.getvar("bergamota-flash") != "1":
            raise FlashError(f"{v} cannot flash: build Enxerto with flash support (bergamota-fastboot-flash.img)")

    def partition_size(self, part):
        return int(self.getvar(f"partition-size:{part}"), 16)

    def hashes(self, part, off, length, bs):
        n = (length + bs - 1) // bs
        self._run(["oem", f"hash:{part}:{off:x}:{length:x}:{bs:x}"], timeout=3600)
        fd, tmp = tempfile.mkstemp(prefix="bergamota-hash-", suffix=".bin")
        os.close(fd)
        try:
            self._run(["get_staged", tmp], timeout=300)
            data = open(tmp, "rb").read()
        finally:
            os.unlink(tmp)
        if len(data) != n * HASH_LEN:
            raise FlashError(f"phone returned {len(data)} bytes of hashes, expected {n * HASH_LEN}")
        return data

    def flash(self, part, path, on_send=None):
        cmd = [self.fastboot, "-s", self.serial, "-S", "512M", "flash", part, path]
        self.log("$ " + " ".join(cmd))
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except FileNotFoundError:
            raise FlashError(f"fastboot not found: {self.fastboot}")
        buf = b""
        tail = []
        total = os.path.getsize(path)
        while True:
            chunk = p.stdout.read1(4096) if hasattr(p.stdout, "read1") else p.stdout.read(1)
            if not chunk:
                break
            buf += chunk
            while True:
                m = re.search(rb"[\r\n]", buf)
                if not m:
                    break
                line, buf = buf[:m.start()].decode("utf-8", "replace"), buf[m.end():]
                if not line.strip():
                    continue
                say(line)
                tail.append(line)
                tail = tail[-5:]
                m2 = re.search(r"Sending sparse '?\w+'? (\d+)/(\d+)", line)
                if m2 and on_send:
                    a, b = int(m2.group(1)), int(m2.group(2))
                    on_send(total * (a - 1) // max(b, 1), total)
        rc = p.wait()
        if rc != 0 or any("FAILED" in t for t in tail):
            raise FlashError("fastboot flash failed: " + (tail[-1] if tail else f"exit {rc}"))
        if on_send:
            on_send(total, total)


# ---------------------------------------------------------------- the flash

def check_partition(part):
    if part not in ALLOWED:
        raise FlashError(f"refusing partition {part!r}: only {', '.join(ALLOWED)} can be flashed")


def phone_hashes(dev, part, length, bs, on_progress=None):
    """Hash [0, length) on the phone in slices of PHONE_SLICE (a multiple of bs)."""
    out = []
    done = 0
    while done < length:
        n = min(PHONE_SLICE, length - done)
        out.append(dev.hashes(part, done, n, bs))
        done += n
        if on_progress:
            on_progress(done, length)
    return b"".join(out)


def flash_partition(dev, part, image_path, mode=None, bs=HASH_BS, verify=True, dry_run=False, keep_delta=None,
                    log=say):
    """Returns a one-line result message. Raises FlashError."""
    check_partition(part)
    if mode is None:
        mode = "delta" if part == "userdata" else "full"
    if not os.path.isfile(image_path):
        raise FlashError(f"{image_path} does not exist")
    if part == "boot":
        with open(image_path, "rb") as f:
            if f.read(8) != b"ANDROID!":
                raise FlashError(f"{image_path} is not an Android boot image (no ANDROID! header)")
    img = Image(image_path)
    t0 = time.time()
    try:
        psize = dev.partition_size(part)
        if img.padded > psize:
            raise FlashError(f"image ({img.padded} bytes) is larger than the {part} partition ({psize} bytes)")
        log(f"{part}: partition {psize >> 20} MiB, image {img.padded >> 20} MiB ({'sparse' if img.sparse else 'raw'}), mode {mode}")
        want_hashes = mode == "delta" or verify
        ih = None
        pool = ThreadPoolExecutor(max_workers=1)
        fut = None
        if want_hashes:
            fut = pool.submit(img.block_hashes, bs, None, lambda d, t: progress("hash-image", d, t))
        sent_path = image_path
        sent_bytes = img.padded
        tmpdir = None
        if mode == "delta":
            ph = phone_hashes(dev, part, img.padded, bs, lambda d, t: progress("hash-phone", d, t))
            ih = fut.result()
            changed = diff_blocks(ph, ih)
            changed_bytes = sum(min(img.padded, (k + 1) * bs) - k * bs for k in changed)
            say(f"DELTA {changed_bytes} {img.padded}")
            log(f"{len(changed)} of {len(ih) // HASH_LEN} blocks differ ({changed_bytes >> 20} MiB of {img.padded >> 20} MiB)")
            if not changed:
                pool.shutdown()
                return f"{part} already identical to the image ({img.padded >> 20} MiB compared in {time.time() - t0:.0f} s), nothing sent"
            # The delta is a file of about changed_bytes and it has to fit somewhere: /tmp is often a RAM-backed tmpfs on Linux
            # (ENOSPC there with a 16 GiB delta), so it goes next to the image when that disk has room, else the temp dir.
            # Only when neither has room is the image itself sent ("full"): its DONT_CARE regions then keep the partition's
            # old contents instead of becoming zeros (for an HFS root image they are free space).
            where = None
            if not keep_delta:
                need = changed_bytes + (64 << 20)
                for d in (os.path.dirname(os.path.abspath(image_path)), tempfile.gettempdir()):
                    try:
                        if os.access(d, os.W_OK) and shutil.disk_usage(d).free > need:
                            where = d
                            break
                    except OSError:
                        pass
            if not keep_delta and where is None:
                log(f"sending the image itself: no writable directory with {need >> 20} MiB free for the delta "
                    f"(DONT_CARE regions keep their old contents)")
                mode = "full"
            else:
                tmpdir = tempfile.mkdtemp(prefix="bergamota-delta-", dir=where)
                delta = keep_delta or os.path.join(tmpdir, "delta.simg")
                build_delta(img, changed, bs, delta)
                sent_path = delta
                sent_bytes = os.path.getsize(delta)
                log(f"delta image {delta}: {sent_bytes >> 20} MiB")
            if dry_run:
                pool.shutdown()
                if mode == "full":
                    return f"dry run: the whole image ({img.padded >> 20} MiB) would be sent ({len(changed)} blocks differ)"
                return f"dry run: {len(changed)} blocks / {changed_bytes >> 20} MiB would be sent"
        else:
            say(f"DELTA {img.padded} {img.padded}")
            if dry_run:
                pool.shutdown()
                return f"dry run: the whole image ({img.padded >> 20} MiB) would be sent"
        try:
            progress("send", 0, sent_bytes)
            dev.flash(part, sent_path, lambda d, t: progress("send", d, t))
        finally:
            if tmpdir:
                if not keep_delta:
                    shutil.rmtree(tmpdir, ignore_errors=True)
        if verify:
            if ih is None:
                ih = fut.result()       # full mode: the image was hashed while it was being sent
            ph2 = phone_hashes(dev, part, img.padded, bs, lambda d, t: progress("verify", d, t))
            bad = []
            for k in range(len(ih) // HASH_LEN):
                if ph2[k * HASH_LEN:(k + 1) * HASH_LEN] != ih[k * HASH_LEN:(k + 1) * HASH_LEN]:
                    if mode == "full" and img.sparse and img.has_dontcare(k * bs, min(bs, img.padded - k * bs)):
                        continue        # fastboot never writes DONT_CARE: those blocks keep their old contents
                    bad.append(k)
            if bad:
                raise FlashError(f"verify FAILED: {len(bad)} block(s) of the phone differ from the image, first at offset {bad[0] * bs:#x}")
            log(f"verified: the phone's {part} matches the image")
        pool.shutdown()
        return f"FLASHED {part}: {sent_bytes >> 20} MiB sent ({mode}){' and verified' if verify else ''} in {time.time() - t0:.0f} s"
    finally:
        img.close()


# ---------------------------------------------------------------- command line

def main(argv=None):
    ap = argparse.ArgumentParser(description="Flash userdata/boot/logo through Bergamota fastboot (delta by default for userdata)")
    ap.add_argument("-s", "--serial", default=SERIAL)
    ap.add_argument("--fastboot", default=None, help="fastboot executable (default: from PATH)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("flash")
    f.add_argument("partition")
    f.add_argument("image")
    g = f.add_mutually_exclusive_group()
    g.add_argument("--delta", action="store_true")
    g.add_argument("--full", action="store_true")
    f.add_argument("--no-verify", action="store_true", help="skip the final hash comparison")
    f.add_argument("--device-verify", action="store_true", help="also ask Enxerto to read back and compare every write (oem verify:1; slower)")
    f.add_argument("--block", type=int, default=HASH_BS, help="hash block size in bytes (power of two, 4 KiB..2 MiB)")
    f.add_argument("--keep-delta", metavar="FILE", help="keep the delta sparse image at FILE")
    f.add_argument("--dry-run", action="store_true", help="compare and report, send nothing")
    h = sub.add_parser("hash", help="read-only: partition size and block hashes of the phone")
    h.add_argument("partition")
    h.add_argument("--length", type=lambda s: int(s, 0), default=0, help="bytes from the start (default: a sample of 1 GiB)")
    h.add_argument("--block", type=int, default=HASH_BS)
    h.add_argument("--out", help="write the raw hash table to this file")
    sub.add_parser("info", help="read-only: bootloader version, USB speed and partition sizes")
    a = ap.parse_args(argv)

    fb = a.fastboot or shutil.which("fastboot") or "fastboot"
    dev = FastbootDevice(fb, a.serial, log=lambda s: say("  " + s))
    try:
        if a.cmd == "flash":
            check_partition(a.partition)
            if a.block < BLK or a.block > (2 << 20) or a.block & (a.block - 1):
                raise FlashError("--block must be a power of two between 4 KiB and 2 MiB")
            dev.check()
            if a.device_verify:
                dev._run(["oem", "verify:1"], timeout=30)
            msg = flash_partition(dev, a.partition, a.image, "full" if a.full else "delta" if a.delta else None,
                                  a.block, not a.no_verify, a.dry_run, a.keep_delta)
        elif a.cmd == "hash":
            check_partition(a.partition)
            dev.check()
            size = dev.partition_size(a.partition)
            length = (a.length or min(size, 1 << 30)) // BLK * BLK
            length = min(length, size)
            t0 = time.time()
            data = phone_hashes(dev, a.partition, length, a.block, lambda d, t: progress("hash-phone", d, t))
            zero = h16(bytes(a.block))
            n = len(data) // HASH_LEN
            zeros = sum(1 for k in range(n) if data[k * HASH_LEN:(k + 1) * HASH_LEN] == zero)
            if a.out:
                open(a.out, "wb").write(data)
            say(f"{a.partition}: size {size} bytes ({size >> 20} MiB); hashed {length >> 20} MiB in {n} blocks of {a.block} "
                f"in {time.time() - t0:.1f} s ({length / max(time.time() - t0, 1e-3) / 1e6:.0f} MB/s); {zeros} all-zero blocks")
            say(f"first hashes: {' '.join(data[k * HASH_LEN:(k + 1) * HASH_LEN].hex()[:16] for k in range(min(n, 4)))}")
            say(f"digest of the table: {h16(data).hex()}")
            msg = "hash done"
        else:
            dev.check()
            say(f"version-bootloader {dev.getvar('version-bootloader')}  usb-speed {dev.getvar('usb-speed')}  "
                f"max-download-size {dev.getvar('max-download-size')}")
            for p in ALLOWED:
                try:
                    say(f"{p}: {dev.partition_size(p) >> 20} MiB")
                except FlashError as e:
                    say(f"{p}: {e}")
            msg = "info done"
    except FlashError as e:
        say(f"RESULT FAIL {e}")
        return 1
    except KeyboardInterrupt:
        say("RESULT FAIL interrupted")
        return 1
    say(f"RESULT OK {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
