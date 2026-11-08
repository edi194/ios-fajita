#!/usr/bin/env python3
"""Build enxerto/applelogo.h: the Apple logo for Enxerto's hand-off screen, from YOUR iOS root.

  python3 tools/mkapplelogo.py [--root research/ios18/ios18-root-full.simg | --png logo.png] [--size 390]
                               [--out enxerto/applelogo.h] [--preview png]

iOS shows the Apple logo (white on black) from iBoot until SpringBoard's first frame, but that
phase is Enxerto + the kernel on this phone, and backboardd's own logo (BKDisplayRenderOverlayAppleLogo,
ProgressUI apple-logo-n84@2x~iphone.png) only lives ~2 s once it finally starts.  mkboot-full.sh runs
this so the last Enxerto frame ("STARTING IOS") is that same logo, which then stays on the panel until
backboardd's first swap.  The artwork is Apple's: it is read out of the iOS root you built, converted
at image build time into the (git-ignored) header and never committed.  Without the header Enxerto
keeps the Bergamota screen.

The source is ProgressUI's CgBI PNG (Apple "optimised": BGRA, premultiplied, raw deflate).  The logo is
a single-colour shape, so only its coverage is kept: 256 grey levels on black, the palette RLE enxerto/bootui.c draws.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
INROOT = "/System/Library/PrivateFrameworks/ProgressUI.framework/apple-logo-n84@2x~iphone.png"


def read_cgbi(path):
    """-> (w, h, coverage bytearray w*h): premultiplied white logo => the premultiplied value is the coverage."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, cgbi, hdr = 8, b"", False, None
    while pos < len(d):
        n, typ = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        if typ == b"CgBI":
            cgbi = True
        elif typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, ctype, _, _, il = hdr
    assert (depth, ctype, il) == (8, 6, 0), "expected 8-bit RGBA, non-interlaced"
    raw = zlib.decompressobj(-15).decompress(idat) if cgbi else zlib.decompress(idat)
    bpp, stride = 4, w * 4
    out, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                row[i] = (row[i] + a) & 255
            elif f == 2:
                row[i] = (row[i] + b) & 255
            elif f == 3:
                row[i] = (row[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out.append(row)
        prev = row
    cov = bytearray(w * h)
    for y, row in enumerate(out):
        for x in range(w):
            cov[y * w + x] = max(row[x * 4], row[x * 4 + 1], row[x * 4 + 2])	# premultiplied B/G/R (white logo)
    return w, h, cov


def bilinear(w, h, cov, nw, nh):
    out = bytearray(nw * nh)
    for y in range(nh):
        fy = min(max((y + 0.5) * h / nh - 0.5, 0), h - 1)
        y0 = int(fy); y1 = min(y0 + 1, h - 1); ty = fy - y0
        for x in range(nw):
            fx = min(max((x + 0.5) * w / nw - 0.5, 0), w - 1)
            x0 = int(fx); x1 = min(x0 + 1, w - 1); tx = fx - x0
            v = (cov[y0 * w + x0] * (1 - tx) + cov[y0 * w + x1] * tx) * (1 - ty) + \
                (cov[y1 * w + x0] * (1 - tx) + cov[y1 * w + x1] * tx) * ty
            out[y * nw + x] = int(v + 0.5)
    return out


def rle_row(row):
    out, i, n, lit = bytearray(), 0, len(row), bytearray()

    def flush():
        nonlocal lit
        while lit:
            chunk, lit = lit[:128], lit[128:]
            out.append(0x80 | (len(chunk) - 1))
            out.extend(chunk)

    while i < n:
        j = i
        while j < n and row[j] == row[i] and j - i < 128:
            j += 1
        if j - i >= 3:
            flush()
            out += bytes([j - i - 1, row[i]])
            i = j
        else:
            lit.append(row[i])
            i += 1
    flush()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", help="iOS root sparse image (read with tools/renegade/hfsx.py)")
    ap.add_argument("--png", help="an already extracted apple-logo CgBI/RGBA PNG")
    ap.add_argument("--size", type=int, default=390, help="edge in px (iPhone XR 150 pt logo at this panel's ~2.6 px/pt)")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "enxerto", "applelogo.h"))
    ap.add_argument("--preview")
    a = ap.parse_args()

    png, tmp = a.png, None
    if not png:
        if not a.root or not os.path.exists(a.root):
            sys.exit("mkapplelogo: no --png and no readable --root")
        tmp = tempfile.mkdtemp()
        png = os.path.join(tmp, "logo.png")
        subprocess.run([sys.executable, os.path.join(HERE, "renegade", "hfsx.py"), a.root, "get", INROOT, png], check=True)
    w, h, cov = read_cgbi(png)
    cov = bilinear(w, h, cov, a.size, a.size)
    W = H = a.size
    rle = bytearray()
    for y in range(H):
        rle += rle_row(cov[y * W:(y + 1) * W])
    with open(a.out, "w") as f:
        f.write("/* generated by tools/mkapplelogo.py from the iOS root's ProgressUI artwork: do not edit, do not commit */\n")
        f.write("#define APPLELOGO_W %d\n#define APPLELOGO_H %d\n" % (W, H))
        f.write("/* a8r8g8b8 grey ramp, index = coverage, 0 = black background */\nstatic const unsigned int applelogo_pal[256] = {")
        for i in range(256):
            f.write("%s0xff%02x%02x%02x," % ("\n\t" if i % 8 == 0 else " ", i, i, i))
        f.write("\n};\n/* per-row RLE: c & 0x80 ? (c & 0x7f) + 1 literal indices : c + 1 copies of the next index */\n")
        f.write("static const unsigned char applelogo_rle[%d] = {" % len(rle))
        for i, v in enumerate(rle):
            f.write("%s0x%02x," % ("\n\t" if i % 16 == 0 else "", v))
        f.write("\n};\n")
    print("apple logo %dx%d, RLE %d bytes (raw %d) -> %s" % (W, H, len(rle), W * H, a.out))
    if a.preview:
        sys.path.insert(0, HERE)
        from bergamota_img import write_png
        write_png(a.preview, W, H, bytes(b for v in cov for b in (v, v, v)))


if __name__ == "__main__":
    main()
