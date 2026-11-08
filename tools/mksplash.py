#!/usr/bin/env python3
"""Build / decode the Xiaomi-style `logo` partition image (ABL power-on + fastboot screens).

Format (verified on backup/logo.img of the Poco F1; splash.img is empty: just a "DDPH" tag + zeros):
  0x0000-0x3fff  zeros
  0x4000         "LOGO!!!!" then little-endian u32 words: start0, (len0, start1), (len1, start2), ... lenN
                 i.e. N+1 slots; start/len are in 4 KiB blocks from the start of the partition and len is
                 the slot's allocated size (gap to the next start), zero padded.
  each slot      a plain 24-bpp BI_RGB bottom-up BMP, 4 KiB aligned.
Slots in the stock image: 0 power-on logo (MI + mi.com, 161x321), 1 fastboot (1080x920; rebuilt full screen 1080x2246), 2 charging,
3/6/8 Google logo 458x154, 4 "system has been destroyed" (1080x1920), 5/7 blank 1080x320.

  mksplash.py build  [--base backup/logo.img] [-o out/logo-bergamota.img] [--size 1080x2246]
  mksplash.py decode <logo.img> <outdir>        # slots -> PNG (+ slots.txt)
  mksplash.py verify <logo.img>                 # structure check
Rebranded: slots 0 (power-on), 1 (fastboot) and 2 (off-mode charging), Enxerto's own renders
(enxerto/out/preview/splash-*.ppm, drawn by enxerto/host_test with the tools/identity artwork), and the Google logo
slots 3/6/8, which get the Bergamota boot mark (tools/identity/mkbootmark.sh, same 458x154 size). Every other slot
(destroyed/verity warning, blanks) is copied byte for byte. Stdlib only.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bergamota_img import Canvas, read_png, write_png

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 32 * 1024 * 1024
HDR = 0x4000
BLK = 4096


def parse(d):
    assert d[HDR:HDR + 8] == b"LOGO!!!!", "no LOGO!!!! header at 0x4000"
    words = []
    p = HDR + 8
    while True:
        w, = struct.unpack_from("<I", d, p)
        p += 4
        if w == 0:
            break
        words.append(w)
    # words = start0, len0, start1, len1, ..., start_{n-1}, len_{n-1}
    assert len(words) % 2 == 0
    slots = [(words[i], words[i + 1]) for i in range(0, len(words), 2)]
    return slots


def bmp_info(b):
    assert b[:2] == b"BM"
    w, h, planes, bpp, comp = struct.unpack_from("<iihhI", b, 18)
    off, = struct.unpack_from("<I", b, 10)
    sz, = struct.unpack_from("<I", b, 2)
    return w, h, bpp, comp, off, sz


def slot_bmp(d, start):
    o = start * BLK
    sz, = struct.unpack_from("<I", d, o + 2)
    return d[o:o + sz]


def bmp_to_rgb(b):
    w, h, bpp, comp, off, _ = bmp_info(b)
    assert bpp == 24 and comp == 0
    rs = (w * 3 + 3) // 4 * 4
    out = bytearray(w * abs(h) * 3)
    for y in range(abs(h)):
        sy = abs(h) - 1 - y if h > 0 else y
        row = b[off + sy * rs:off + sy * rs + w * 3]
        o = y * w * 3
        out[o:o + w * 3] = row
        out[o:o + w * 3:3], out[o + 2:o + w * 3:3] = row[2::3], row[0::3]
    return w, abs(h), out


def rgb_to_bmp(w, h, rgb, template=None):
    rs = (w * 3 + 3) // 4 * 4
    pad = bytes(rs - w * 3)
    body = bytearray()
    for y in range(h - 1, -1, -1):
        row = bytearray(rgb[y * w * 3:(y + 1) * w * 3])
        row[0::3], row[2::3] = rgb[y * w * 3 + 2:(y + 1) * w * 3:3], rgb[y * w * 3:(y + 1) * w * 3:3]
        body += row + pad
    hdr = struct.pack("<2sIHHIIiiHHIIiiII", b"BM", 54 + len(body), 0, 0, 54, 40, w, h, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    return hdr + bytes(body)


def read_ppm(path):
    d = open(path, "rb").read()
    parts = d.split(None, 4)
    assert parts[0] == b"P6" and parts[3] == b"255", path + ": binary PPM expected"
    w, h = int(parts[1]), int(parts[2])
    return w, h, bytearray(parts[4][:w * h * 3])


def rendered(name, w, h):
    """The screen as Enxerto draws it (tools/identity: enxerto/host_test renders it to out/preview/NAME.ppm)."""
    path = os.path.join(HERE, "..", "enxerto", "out", "preview", name + ".ppm")
    if not os.path.exists(path):
        raise SystemExit("%s missing: build Enxerto first (enxerto/build.sh renders the previews)" % path)
    pw, ph, px = read_ppm(path)
    assert (pw, ph) == (w, h), "%s is %dx%d, the logo slot is %dx%d" % (path, pw, ph, w, h)
    c = Canvas(w, h, (0, 0, 0))
    c.px[:] = px
    return c


def compose_poweron(w, h):
    """Slot 0, ABL's power-on screen: the identity's boot scene without text (tools/identity/IDENTITY.md)."""
    return rendered("splash-poweron", w, h)


def compose_charging(w, h):
    """Slot 2, ABL's off-mode charging picture: Enxerto's charging scene with an empty battery and the bolt."""
    return rendered("splash-charging", w, h)


def compose_fastboot(w, h):
    """Slot 1, ABL's own fastboot: the scene with an ink BOOTLOADER pill (Enxerto's fastboot screen has the leaf
    green FASTBOOT one, so the two are told apart at a glance)."""
    return rendered("splash-fastboot", w, h)


GOOGLE_SLOTS = (3, 6, 8)


def bootmark(path, w, h):
    """The boot mark PNG as RGB, checked against the stock Google logo's size (ABL places the slot by its size)."""
    if not os.path.exists(path):
        raise SystemExit("%s missing: run tools/identity/mkbootmark.sh" % path)
    bw, bh, px = read_png(path)
    assert (bw, bh) == (w, h), "%s is %dx%d, the Google slot is %dx%d" % (path, bw, bh, w, h)
    ch = len(px) // (bw * bh)
    rgb = bytearray(bw * bh * 3)
    for i in range(bw * bh):
        rgb[i * 3:i * 3 + 3] = px[i * ch:i * ch + 3]
    return rgb


def build(base_path, out_path, size, preview_dir, mark_path=None):
    d = open(base_path, "rb").read()
    assert len(d) == SIZE, "base must be 32 MiB"
    slots = parse(d)
    bmps = [slot_bmp(d, s) for s, _ in slots]
    keep_len = [l for _, l in slots]
    pw, ph = size
    c0 = compose_poweron(pw, ph)
    c1 = compose_fastboot(pw, ph)
    c2 = compose_charging(pw, ph)
    new = list(bmps)
    new[0] = rgb_to_bmp(c0.w, c0.h, c0.px)
    new[1] = rgb_to_bmp(c1.w, c1.h, c1.px)
    new[2] = rgb_to_bmp(c2.w, c2.h, c2.px)
    if mark_path:
        for i in GOOGLE_SLOTS:
            gw, gh = bmp_info(bmps[i])[:2]
            new[i] = rgb_to_bmp(gw, abs(gh), bootmark(mark_path, gw, abs(gh)))
    def layout(tight):
        words, cur = [], HDR // BLK + 1
        for i, b in enumerate(new):
            need = (len(b) + BLK - 1) // BLK
            ln = need if (tight or i < 3) else max(keep_len[i], need)  # stock slots keep their allocation if it fits
            words += [cur, ln]
            cur += ln
        return words, cur

    words, cur = layout(False)
    if cur * BLK > SIZE:
        # The stock image pads slots 3/6/8 to ~6 MiB each; a full-screen power-on BMP does not fit with that.
        print("note: stock slot padding does not fit, packing slots tightly (len = BMP size)")
        words, cur = layout(True)
    assert cur * BLK <= SIZE, "image does not fit"
    out = bytearray(SIZE)
    for i, b in enumerate(new):
        out[words[2 * i] * BLK:words[2 * i] * BLK + len(b)] = b
    out[HDR:HDR + 8] = b"LOGO!!!!"
    struct.pack_into("<%dI" % len(words), out, HDR + 8, *words)
    open(out_path, "wb").write(out)
    print("wrote %s (%d bytes, %d slots, used %.1f MiB)" % (out_path, len(out), len(new), cur * BLK / 1048576))
    if preview_dir:
        decode(out_path, preview_dir)


def decode(path, outdir):
    d = open(path, "rb").read()
    os.makedirs(outdir, exist_ok=True)
    slots = parse(d)
    lines = []
    for i, (s, l) in enumerate(slots):
        b = slot_bmp(d, s)
        w, h, rgb = bmp_to_rgb(b)
        write_png(os.path.join(outdir, "slot%d.png" % i), w, h, rgb)
        lines.append("slot %d: start=%d (0x%x) len=%d blocks bmp=%dx%d %d bytes" % (i, s, s * BLK, l, w, h, len(b)))
    open(os.path.join(outdir, "slots.txt"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


def verify(path):
    d = open(path, "rb").read()
    assert len(d) == SIZE
    slots = parse(d)
    prev_end = HDR // BLK + 1
    for i, (s, l) in enumerate(slots):
        assert s == prev_end, "slot %d not contiguous" % i
        b = slot_bmp(d, s)
        w, h, bpp, comp, off, sz = bmp_info(b)
        assert bpp == 24 and comp == 0 and off == 54 and len(b) <= l * BLK, "slot %d bad bmp" % i
        prev_end = s + l
    assert prev_end * BLK <= SIZE
    print("OK: %d slots, ends at 0x%x" % (len(slots), prev_end * BLK))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--base", default=os.path.join(HERE, "..", "backup", "logo.img"))
    b.add_argument("-o", "--out", default=os.path.join(HERE, "..", "out", "logo-bergamota.img"))
    b.add_argument("--size", default="1080x2246", help="power-on image size (panel is 1080x2246)")
    b.add_argument("--preview", help="also decode the result to PNGs in this directory")
    b.add_argument("--bootmark", default=os.path.join(HERE, "identity", "out", "bootmark.png"),
                   help="boot mark for the Google logo slots 3/6/8 ('' keeps Google's)")
    dd = sub.add_parser("decode"); dd.add_argument("img"); dd.add_argument("outdir")
    v = sub.add_parser("verify"); v.add_argument("img")
    a = ap.parse_args()
    if a.cmd == "build":
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        w, h = map(int, a.size.split("x"))
        build(a.base, a.out, (w, h), a.preview, a.bootmark or None)
        verify(a.out)
    elif a.cmd == "decode":
        decode(a.img, a.outdir)
    else:
        verify(a.img)


if __name__ == "__main__":
    main()
