"""Tiny stdlib-only image helpers shared by mksplash.py, mkapplelogo.py and tools/identity/mkidentity.py.

RGB canvases are bytearrays (3 bytes/pixel); RGBA images are (w, h, bytearray) with
non-premultiplied alpha, as written by tools/make-boot-assets.swift.
"""
import struct
import zlib

BG = (0x1a, 0x59, 0x33)	# BG_BOOT in enxerto/console.h, dark bergamot green
LIME = (0xcc, 0xec, 0x59)	# LABEL
PALE = (0xff, 0xf7, 0x8c)	# TEXT


def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, plte = 8, b"", None
    while pos < len(d):
        n, typ = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and inter == 0 and ctype in (2, 6), "need 8-bit non-interlaced RGB/RGBA"
        elif typ == b"IDAT":
            idat += body
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        if bpp == 4:
            out[y * w * 4:(y + 1) * w * 4] = line
        else:
            for x in range(w):
                o = y * w * 4 + x * 4
                out[o:o + 3] = line[x * 3:x * 3 + 3]
                out[o + 3] = 255
    return w, h, out


def write_png(path, w, h, rgb, channels=3):
    """rgb: bytes of w*h*channels (3 = RGB)."""
    raw = bytearray()
    stride = w * channels
    for y in range(h):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(t, b):
        c = struct.pack(">I", len(b)) + t + b
        return c + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if channels == 3 else 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def resize_rgba(img, nw, nh):
    """Area-average resize of a premultiplied-alpha image (good for down-scaling)."""
    w, h, px = img
    if (nw, nh) == (w, h):
        return img
    # horizontal pass into premultiplied float rows, then vertical
    def hpass(row):
        out = []
        for nx in range(nw):
            x0, x1 = nx * w / nw, (nx + 1) * w / nw
            r = g = b = a = ws = 0.0
            xi = int(x0)
            while xi < x1 and xi < w:
                wt = min(x1, xi + 1) - max(x0, xi)
                o = xi * 4
                al = row[o + 3] / 255.0
                r += row[o] * al * wt; g += row[o + 1] * al * wt; b += row[o + 2] * al * wt; a += al * wt
                ws += wt
                xi += 1
            out.append((r / ws, g / ws, b / ws, a / ws))
        return out
    rows = [hpass(px[y * w * 4:(y + 1) * w * 4]) for y in range(h)]
    out = bytearray(nw * nh * 4)
    for ny in range(nh):
        y0, y1 = ny * h / nh, (ny + 1) * h / nh
        acc = [[0.0, 0.0, 0.0, 0.0] for _ in range(nw)]
        ws = 0.0
        yi = int(y0)
        while yi < y1 and yi < h:
            wt = min(y1, yi + 1) - max(y0, yi)
            for x, v in enumerate(rows[yi]):
                a_ = acc[x]
                a_[0] += v[0] * wt; a_[1] += v[1] * wt; a_[2] += v[2] * wt; a_[3] += v[3] * wt
            ws += wt
            yi += 1
        for x, a_ in enumerate(acc):
            al = a_[3] / ws
            o = (ny * nw + x) * 4
            if al > 0:
                out[o] = min(255, int(a_[0] / ws / al + 0.5)); out[o + 1] = min(255, int(a_[1] / ws / al + 0.5))
                out[o + 2] = min(255, int(a_[2] / ws / al + 0.5))
            out[o + 3] = min(255, int(al * 255 + 0.5))
    return nw, nh, out


def crop_alpha(img, pad=0):
    """Trim fully transparent borders."""
    w, h, px = img
    xs0, ys0, xs1, ys1 = w, h, -1, -1
    for y in range(h):
        row = px[y * w * 4 + 3:(y + 1) * w * 4:4]
        if any(row):
            xs = [i for i, a in enumerate(row) if a > 3]
            if xs:
                xs0, xs1 = min(xs0, xs[0]), max(xs1, xs[-1])
                ys0, ys1 = min(ys0, y), max(ys1, y)
    xs0, ys0 = max(0, xs0 - pad), max(0, ys0 - pad)
    xs1, ys1 = min(w - 1, xs1 + pad), min(h - 1, ys1 + pad)
    nw, nh = xs1 - xs0 + 1, ys1 - ys0 + 1
    out = bytearray()
    for y in range(ys0, ys1 + 1):
        out += px[(y * w + xs0) * 4:(y * w + xs1 + 1) * 4]
    return nw, nh, out


class Canvas:
    def __init__(self, w, h, color=BG):
        self.w, self.h = w, h
        self.px = bytearray(bytes(color) * (w * h))

    def blit(self, img, x, y):
        """Alpha-over an RGBA image at (x, y)."""
        iw, ih, src = img
        for sy in range(ih):
            dy = y + sy
            if not 0 <= dy < self.h:
                continue
            for sx in range(iw):
                dx = x + sx
                if not 0 <= dx < self.w:
                    continue
                o = (sy * iw + sx) * 4
                a = src[o + 3]
                if a == 0:
                    continue
                d = (dy * self.w + dx) * 3
                if a == 255:
                    self.px[d:d + 3] = src[o:o + 3]
                else:
                    for c in range(3):
                        self.px[d + c] = (src[o + c] * a + self.px[d + c] * (255 - a) + 127) // 255
