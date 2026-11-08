#!/usr/bin/env python3
"""Generate enxerto/art.h, the identity's artwork for the Enxerto screens (tools/identity/IDENTITY.md).
  python3 -I tools/identity/mkidentity.py [--chrome PATH] [--out enxerto/art.h] [--keep DIR]

What goes in (standard library only, plus Google Chrome to rasterise the two typefaces):
  - the Newton portrait as a halftone CELL MAP: per cell an ink density 0..252, and a cutout mask at twice the cell
    resolution. art.c redraws round dots from it at any size (a 16x16 Euclidean-spot threshold matrix), so the portrait
    costs ~50 KB instead of a run-length image of dots;
  - Archivo (wordmark, the giant numerals) as 4-bit alpha images, run-length coded per row;
  - Archivo digits, one image each on a common baseline, for the charging screen's giant percentage;
  - JetBrains Mono glyph atlases (4-bit coverage) for the text the screens draw at run time.
Text is rendered white on black by tools/identity/render.html, so a pixel's brightness is its coverage.
"""
import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools'))
from bergamota_img import read_png  # noqa: E402

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
PAD = 32                                  # render.html draws at (32, 32)
NEWTON_COLS = 200                         # portrait cells across (1280 px master -> 6.4 px a cell, the master's own screen)
ASCII = ''.join(chr(c) for c in range(0x20, 0x7f))

# (name, font, size, weight, stretch, track, text)  -- static Archivo pieces, cropped to their ink
IMAGES = [
    ('wordmark', 'archivo', 108, 900, 118, 0.02, 'BERGAMOTA'),
    ('num_26', 'archivo', 820, 900, 112, -0.04, '26'),
    ('num_18', 'archivo', 820, 900, 112, -0.04, '18'),
    ('pct', 'archivo', 236, 900, 112, 0, '%'),
]
# (name, size, weight, stretch, chars)  -- Archivo glyphs cut one by one to their ink, all rows of the set kept
# (common baseline), so the screen can set any string of them with its own spacing
GLYPHS = [
    ('digits', 520, 900, 112, '0123456789-'),
]
# (name, size, weight, chars)  -- JetBrains Mono atlases (advance 0.6 em)
FONTS = [
    ('mono30', 30, 600, ASCII),
    ('mono22', 22, 500, ASCII),
]


def chrome_shot(chrome, query, w, h, out_png, prof):
    url = 'file://' + os.path.join(HERE, 'render.html') + '?' + urllib.parse.urlencode(query)
    cmd = [chrome, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
           '--user-data-dir=' + prof, '--force-device-scale-factor=1', '--window-size=%d,%d' % (w, h),
           '--virtual-time-budget=4000', '--screenshot=' + out_png, url]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, check=False)
    for _ in range(50):
        if os.path.exists(out_png) and os.path.getsize(out_png) > 0:
            return
        time.sleep(0.1)
    raise SystemExit('chrome produced no ' + out_png)


def coverage(png):
    w, h, px = read_png(png)
    ch = 4
    cov = bytearray(w * h)
    for i in range(w * h):
        r, g, b = px[i * ch], px[i * ch + 1], px[i * ch + 2]
        cov[i] = max(r, g, b)
    return w, h, cov


def crop(w, h, cov):
    xs = [i % w for i in range(w * h) if cov[i] > 8]
    ys = [i // w for i in range(w * h) if cov[i] > 8]
    x0, x1, y0, y1 = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    out = bytearray()
    for y in range(y0, y1):
        out += cov[y * w + x0:y * w + x1]
    return x1 - x0, y1 - y0, out


def rle4(w, h, cov):
    """Rows of bytes (count-1) << 4 | alpha4, count 1..16."""
    out = bytearray()
    for y in range(h):
        row = [(v * 15 + 127) // 255 for v in cov[y * w:(y + 1) * w]]
        x = 0
        while x < w:
            v, n = row[x], 1
            while x + n < w and n < 16 and row[x + n] == v:
                n += 1
            out.append((n - 1) << 4 | v)
            x += n
    return out


def pack4(vals):
    vals = [(v * 15 + 127) // 255 for v in vals]
    if len(vals) % 2:
        vals.append(0)
    return bytes(vals[i] | vals[i + 1] << 4 for i in range(0, len(vals), 2))


def portrait(path):
    w, h, px = read_png(path)
    cell = w / NEWTON_COLS
    rows = int(h / cell)
    lum = [0.0] * (w * h)
    alp = [0.0] * (w * h)
    for i in range(w * h):
        r, g, b, a = px[i * 4:i * 4 + 4]
        lum[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b)
        alp[i] = a / 255.0
    # density: the master's own screen (~6.5 px) averaged away over a window a cell and a half wide
    cells = bytearray()
    rad = cell * 0.55
    for cy in range(rows):
        for cx in range(NEWTON_COLS):
            mx, my = (cx + 0.5) * cell, (cy + 0.5) * cell
            x0, x1 = max(0, int(mx - rad)), min(w, int(mx + rad) + 1)
            y0, y1 = max(0, int(my - rad)), min(h, int(my + rad) + 1)
            s = n = 0.0
            for y in range(y0, y1):
                base = y * w
                for x in range(x0, x1):
                    a = alp[base + x]
                    if a > 0.5:
                        s += lum[base + x]
                        n += 1
            if n == 0:
                cells.append(0)
                continue
            d = (244.0 - s / n) / (244.0 - 22.0)
            cells.append(int(round(max(0.0, min(1.0, d)) * 252)))
    # cutout mask at twice the cell resolution, 1 bit, rows padded to bytes
    mcols, mrows = NEWTON_COLS * 2, rows * 2
    mask = bytearray()
    for my in range(mrows):
        bits = 0
        nb = 0
        for mx in range(mcols):
            sx, sy = int((mx + 0.5) * cell / 2), int((my + 0.5) * cell / 2)
            on = sx < w and sy < h and alp[sy * w + sx] > 0.5
            bits |= (1 if on else 0) << nb
            nb += 1
            if nb == 8:
                mask.append(bits)
                bits = nb = 0
        if nb:
            mask.append(bits)
    return NEWTON_COLS, rows, cells, mcols, mrows, mask, w / h


def spot_matrix(n=16):
    """Rank-normalised Euclidean spot: thresholds 0..255 so a density d inks a fraction d of the cell."""
    vals = []
    for y in range(n):
        for x in range(n):
            fx, fy = (x + 0.5) / n - 0.5, (y + 0.5) / n - 0.5
            vals.append(((math.cos(2 * math.pi * fx) + math.cos(2 * math.pi * fy)) / 2, y * n + x))
    vals.sort(reverse=True)            # the centre inks first
    m = [0] * (n * n)
    for rank, (_, i) in enumerate(vals):
        m[i] = rank * 256 // (n * n)
    return m


def carray(name, data, ctype='unsigned char', per=24):
    lines = ['static const %s %s[%d] = {' % (ctype, name, len(data))]
    for i in range(0, len(data), per):
        lines.append('\t' + ','.join(str(v) for v in data[i:i + per]) + ',')
    lines.append('};')
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--chrome', default=os.environ.get('CHROME', CHROME))
    ap.add_argument('--out', default=os.path.join(REPO, 'enxerto', 'art.h'))
    ap.add_argument('--keep', help='keep the intermediate screenshots here')
    ap.add_argument('--console', metavar='HEADER',
                    help='instead: write the xnu verbose console\'s portrait (osfmk/console/console_logo.h, patch 0230)')
    a = ap.parse_args()
    if a.console:
        cols, rows, cells, mcols, mrows, mask, _ = portrait(os.path.join(HERE, 'newton-halftone.png'))
        parts = ['/* generated by Bergamota tools/identity/mkidentity.py --console: do not edit */',
                 '/* The Newton halftone as cells (density 0..252) and a 2x cutout mask; video_console.c draws the dots. */',
                 '#define CONSOLE_LOGO_COLS %d' % cols, '#define CONSOLE_LOGO_ROWS %d' % rows,
                 '#define CONSOLE_LOGO_MCOLS %d' % mcols, '#define CONSOLE_LOGO_MROWS %d' % mrows,
                 carray('console_logo_cells', cells), carray('console_logo_mask', mask), carray('console_logo_spot', spot_matrix()), '']
        with open(a.console, 'w') as f:
            f.write('\n'.join(parts))
        print('wrote', a.console)
        return
    if not os.path.exists(a.chrome):
        raise SystemExit('Google Chrome not found (--chrome PATH)')
    tmp = a.keep or tempfile.mkdtemp(prefix='mkidentity-')
    os.makedirs(tmp, exist_ok=True)
    prof = os.path.join(tmp, 'profile')
    parts = ['/* generated by tools/identity/mkidentity.py from tools/identity (IDENTITY.md): do not edit */',
             '#ifndef ART_H', '#define ART_H', '']

    for name, font, size, weight, stretch, track, text in IMAGES:
        png = os.path.join(tmp, name + '.png')
        wpx = int(size * 0.9 * max(1, len(text))) + 2 * PAD + 200
        chrome_shot(a.chrome, {'font': font, 'size': size, 'weight': weight, 'stretch': stretch, 'track': track,
                               'text': text}, wpx, int(size * 1.4) + 2 * PAD, png, prof)
        w, h, cov = crop(*coverage(png))
        data = rle4(w, h, cov)
        up = name.upper()
        parts += ['#define ART_%s_W %d' % (up, w), '#define ART_%s_H %d' % (up, h),
                  carray('art_%s' % name, data), '']
        print('%-10s %4dx%-4d %6d bytes' % (name, w, h, len(data)))

    for name, size, weight, stretch, chars in GLYPHS:
        shots = []
        for k, ch in enumerate(chars):
            png = os.path.join(tmp, '%s-%d.png' % (name, k))
            chrome_shot(a.chrome, {'font': 'archivo', 'size': size, 'weight': weight, 'stretch': stretch, 'text': ch},
                        int(size * 1.2) + 2 * PAD, int(size * 1.4) + 2 * PAD, png, prof)
            shots.append(coverage(png))
        ys = [i // w for w, h, cov in shots for i in range(w * h) if cov[i] > 8]
        y0, y1 = min(ys), max(ys) + 1
        data, offs, widths = bytearray(), [], []
        for w, h, cov in shots:
            xs = [i % w for i in range(w * h) if cov[i] > 8]
            x0, x1 = min(xs), max(xs) + 1
            sub = bytearray()
            for y in range(y0, y1):
                sub += cov[y * w + x0:y * w + x1]
            offs.append(len(data))
            widths.append(x1 - x0)
            data += rle4(x1 - x0, y1 - y0, sub)
        up = name.upper()
        parts += ['#define ART_%s_H %d' % (up, y1 - y0),
                  'static const char art_%s_chars[] = "%s";' % (name, chars),
                  carray('art_%s_widths' % name, widths, 'unsigned short'),
                  carray('art_%s_offs' % name, offs, 'unsigned int'),
                  carray('art_%s' % name, data), '']
        print('%-10s %d glyphs, %d high, widths %s  %6d bytes' % (name, len(chars), y1 - y0, widths, len(data)))

    for name, size, weight, chars in FONTS:
        cw, chh = int(math.ceil(size * 0.6)), int(math.ceil(size * 1.32))
        png = os.path.join(tmp, name + '.png')
        chrome_shot(a.chrome, {'atlas': 1, 'font': 'jbm', 'size': size, 'weight': weight, 'cellw': cw, 'cellh': chh,
                               'chars': chars}, cw * len(chars) + 2 * PAD + 16, chh + 2 * PAD + 16, png, prof)
        w, h, cov = coverage(png)
        glyphs = bytearray()
        for k in range(len(chars)):
            vals = []
            for y in range(chh):
                for x in range(cw):
                    vals.append(cov[(PAD + y) * w + PAD + k * cw + x])
            glyphs += pack4(vals)
        up = name.upper()
        parts += ['#define ART_%s_W %d' % (up, cw), '#define ART_%s_H %d' % (up, chh),
                  'static const char art_%s_chars[] = "%s";' % (name, chars.replace('\\', '\\\\').replace('"', '\\"')),
                  carray('art_%s' % name, glyphs), '']
        print('%-10s %2dx%-3d x %3d  %6d bytes' % (name, cw, chh, len(chars), len(glyphs)))

    cols, rows, cells, mcols, mrows, mask, aspect = portrait(os.path.join(HERE, 'newton-halftone.png'))
    parts += ['/* the portrait: %d x %d cells (density 0..252), cutout mask %d x %d bits; master aspect %.4f */'
              % (cols, rows, mcols, mrows, aspect),
              '#define ART_NEWTON_COLS %d' % cols, '#define ART_NEWTON_ROWS %d' % rows,
              '#define ART_NEWTON_MCOLS %d' % mcols, '#define ART_NEWTON_MROWS %d' % mrows,
              carray('art_newton', cells), carray('art_newton_mask', mask), '',
              carray('art_spot16', spot_matrix()), '', '#endif']
    print('newton     %dx%d cells  %d + %d bytes' % (cols, rows, len(cells), len(mask)))
    with open(a.out, 'w') as f:
        f.write('\n'.join(parts) + '\n')
    print('wrote', a.out)
    if not a.keep:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
