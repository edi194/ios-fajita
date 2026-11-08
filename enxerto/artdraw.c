/* The identity's drawing primitives, see artdraw.h. */
#include "artdraw.h"
#include "art.h"
#include "console.h"

#ifndef ENXERTO_IOS
#define ENXERTO_IOS	26
#endif

#define GRID		14	/* ground dot pitch, px */
#define DOT_R4		10	/* ground dot radius in quarter pixels (2.5 px) */

static inline uint32_t mix(uint32_t bg, uint32_t fg, unsigned a15)
{
	if (a15 >= 15)
		return fg;
	unsigned r = ((bg >> 16 & 255) * (15 - a15) + (fg >> 16 & 255) * a15) / 15;
	unsigned g = ((bg >> 8 & 255) * (15 - a15) + (fg >> 8 & 255) * a15) / 15;
	unsigned b = ((bg & 255) * (15 - a15) + (fg & 255) * a15) / 15;
	return 0xff000000U | r << 16 | g << 8 | b;
}

static inline volatile uint32_t *px(int x, int y)
{
	return con_fb + y * (FB_STRIDE / 4) + x;
}

/* One GRID x GRID tile of the ground, the dot anti-aliased by 4x4 supersampling. */
static uint32_t tile[GRID * GRID];
static int tile_ready;

static void make_tile(void)
{
	for (int y = 0; y < GRID; y++)
		for (int x = 0; x < GRID; x++) {
			unsigned in = 0;
			for (int sy = 0; sy < 4; sy++)
				for (int sx = 0; sx < 4; sx++) {
					int dx = (x * 4 + sx) * 2 + 1 - GRID * 4, dy = (y * 4 + sy) * 2 + 1 - GRID * 4;	/* eighth px from centre */
					if (dx * dx + dy * dy <= (DOT_R4 * 2) * (DOT_R4 * 2))
						in++;
				}
			tile[y * GRID + x] = mix(ID_LIME, ID_DOT, in * 15 / 16);
		}
	tile_ready = 1;
}

void art_ground(int x, int y, int w, int h)
{
	if (!tile_ready)
		make_tile();
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > FB_W) w = FB_W - x;
	if (y + h > FB_H) h = FB_H - y;
	for (int j = y; j < y + h; j++) {
		const uint32_t *row = tile + (j % GRID) * GRID;
		volatile uint32_t *d = px(x, j);
		int tx = x % GRID;
		for (int i = 0; i < w; i++) {
			d[i] = row[tx];
			if (++tx == GRID)
				tx = 0;
		}
	}
}

/* Rows of (count-1) << 4 | alpha4 bytes, blended over what is on screen. */
static void blit_rle4(const unsigned char *p, int w, int h, int x0, int y0, uint32_t color, int clip0, int clip1)
{
	for (int y = 0; y < h; y++) {
		int x = 0, sy = y0 + y;
		while (x < w) {
			unsigned b = *p++, n = (b >> 4) + 1, a = b & 15;
			if (a && sy >= clip0 && sy < clip1 && sy >= 0 && sy < FB_H)
				for (unsigned k = 0; k < n; k++) {
					int sx = x0 + x + (int)k;
					if (sx >= 0 && sx < FB_W) {
						volatile uint32_t *d = px(sx, sy);
						*d = mix(*d, color, a);
					}
				}
			x += (int)n;
		}
	}
}

/* Looked up with switches, not a table of pointers: the image runs where ABL loads it with no relocation pass, and a
 * static pointer table would need ABS64 relocations (build.sh refuses them). */
struct img { const unsigned char *rle; int w, h; };

static struct img image_of(enum art_image im)
{
	struct img r;	/* if/else, not a switch: gcc turns that into a table of pointers too */
	if (im == ART_NUM_26) {
		r.rle = art_num_26; r.w = ART_NUM_26_W; r.h = ART_NUM_26_H;
	} else if (im == ART_NUM_18) {
		r.rle = art_num_18; r.w = ART_NUM_18_W; r.h = ART_NUM_18_H;
	} else if (im == ART_PCT) {
		r.rle = art_pct; r.w = ART_PCT_W; r.h = ART_PCT_H;
	} else {
		r.rle = art_wordmark; r.w = ART_WORDMARK_W; r.h = ART_WORDMARK_H;
	}
	return r;
}

void art_image(enum art_image im, int x, int y, uint32_t color)
{
	struct img i = image_of(im);
	blit_rle4(i.rle, i.w, i.h, x, y, color, 0, FB_H);
}

void art_image_rows(enum art_image im, int x, int y, uint32_t color, int row0, int row1)
{
	struct img i = image_of(im);
	blit_rle4(i.rle, i.w, i.h, x, y, color, row0, row1);
}

int art_image_w(enum art_image im) { return image_of(im).w; }
int art_image_h(enum art_image im) { return image_of(im).h; }

enum art_image art_ios_numerals(void)
{
	return ENXERTO_IOS == 18 ? ART_NUM_18 : ART_NUM_26;
}

int art_portrait_h(int w)
{
	return w * ART_NEWTON_ROWS / ART_NEWTON_COLS;
}

/* Round dots again at this size: a pixel inks when its spot threshold is below the cell's density. */
void art_portrait_rows(int x0, int y0, int w, int row0, int row1)
{
	int h = art_portrait_h(w);
	uint32_t step = ((uint32_t)ART_NEWTON_COLS << 16) / (uint32_t)w;	/* cells per pixel, 16.16 */
	for (int y = 0; y < h; y++) {
		int sy = y0 + y;
		if (sy < 0 || sy >= FB_H || sy < row0 || sy >= row1)
			continue;
		uint32_t cyf = (uint32_t)y * step;
		int row = cyf >> 16, fy = (cyf >> 12) & 15;
		if (row >= ART_NEWTON_ROWS)
			break;
		int mrow = (int)((cyf >> 15));
		const unsigned char *mrow_p = art_newton_mask + mrow * ((ART_NEWTON_MCOLS + 7) / 8);
		const unsigned char *cells = art_newton + row * ART_NEWTON_COLS;
		const unsigned char *spot = art_spot16 + fy * 16;
		volatile uint32_t *d = px(0, sy);
		for (int x = 0; x < w; x++) {
			int sx = x0 + x;
			if (sx < 0 || sx >= FB_W)
				continue;
			uint32_t cxf = (uint32_t)x * step;
			int col = cxf >> 16, mcol = cxf >> 15;
			if (col >= ART_NEWTON_COLS)
				break;
			if (!(mrow_p[mcol >> 3] >> (mcol & 7) & 1))
				continue;
			d[sx] = spot[(cxf >> 12) & 15] < cells[col] ? ID_INK : ID_PAPER;
		}
	}
}

void art_portrait(int x0, int y0, int w)
{
	art_portrait_rows(x0, y0, w, 0, FB_H);
}

static int big_index(char c)
{
	for (int i = 0; art_digits_chars[i]; i++)
		if (art_digits_chars[i] == c)
			return i;
	return -1;
}

int art_big_w(const char *s, int gap)
{
	int w = 0;
	for (; *s; s++) {
		int i = big_index(*s);
		if (i >= 0)
			w += art_digits_widths[i] + (s[1] ? gap : 0);
	}
	return w;
}

int art_big_h(void)
{
	return ART_DIGITS_H;
}

void art_big(int x, int y, int gap, uint32_t color, const char *s, int row0, int row1)
{
	for (; *s; s++) {
		int i = big_index(*s);
		if (i < 0)
			continue;
		blit_rle4(art_digits + art_digits_offs[i], art_digits_widths[i], ART_DIGITS_H, x, y, color, row0, row1);
		x += art_digits_widths[i] + gap;
	}
}

#define DISSOLVE_CELL	12	/* px per halftone cell */

void art_dissolve(int y0, int h, uint32_t color, int row0, int row1)
{
	for (int y = 0; y < h; y++) {
		int sy = y0 + y;
		if (sy < 0 || sy >= FB_H || sy < row0 || sy >= row1)
			continue;
		unsigned d = (unsigned)((y + 1) * 256 / h);	/* ink coverage 0..256, eased in: the first dots stay small */
		d = d * d / 256;
		const unsigned char *spot = art_spot16 + (y % DISSOLVE_CELL) * 16 / DISSOLVE_CELL * 16;
		volatile uint32_t *row = px(0, sy);
		for (int x = 0; x < FB_W; x++)
			if (spot[(x % DISSOLVE_CELL) * 16 / DISSOLVE_CELL] < d)
				row[x] = color;
	}
}

int art_pill_h(void)
{
	return ART_MONO30_H + 20;
}

int art_pill(int cx, int y, uint32_t bg, uint32_t fg, const char *s)
{
	int tw = art_text_w(ART_MONO30, s), pw = tw + 56, ph = art_pill_h();
	art_rrect(cx - pw / 2, y, pw, ph, ph / 2, bg);
	art_text(ART_MONO30, cx - tw / 2, y + 10, fg, s);
	return pw;
}

struct fnt { const unsigned char *g; const char *chars; int w, h; };

static struct fnt font_of(enum art_font f)
{
	struct fnt r;
	if (f == ART_MONO22) {
		r.g = art_mono22; r.chars = art_mono22_chars; r.w = ART_MONO22_W; r.h = ART_MONO22_H;
	} else {
		r.g = art_mono30; r.chars = art_mono30_chars; r.w = ART_MONO30_W; r.h = ART_MONO30_H;
	}
	return r;
}

static int glyph_index(const struct fnt *f, char c)
{
	for (int i = 0; f->chars[i]; i++)
		if (f->chars[i] == c)
			return i;
	return -1;
}

int art_text_w(enum art_font f, const char *s)
{
	int n = 0;
	while (*s++)
		n++;
	return n * font_of(f).w;
}

int art_text_h(enum art_font f)
{
	return font_of(f).h;
}

void art_text(enum art_font f, int x, int y, uint32_t color, const char *s)
{
	struct fnt ft = font_of(f);
	int gw = ft.w, gh = ft.h, bytes = (gw * gh + 1) / 2;
	for (; *s; s++, x += gw) {
		int gi = glyph_index(&ft, *s);
		if (gi < 0 || *s == ' ')
			continue;
		const unsigned char *g = ft.g + gi * bytes;
		for (int yy = 0; yy < gh; yy++) {
			int sy = y + yy;
			if (sy < 0 || sy >= FB_H)
				continue;
			for (int xx = 0; xx < gw; xx++) {
				int i = yy * gw + xx, sx = x + xx;
				unsigned a = (g[i >> 1] >> ((i & 1) * 4)) & 15;
				if (a && sx >= 0 && sx < FB_W) {
					volatile uint32_t *d = px(sx, sy);
					*d = mix(*d, color, a);
				}
			}
		}
	}
}

void art_text_centered(enum art_font f, int y, uint32_t color, const char *s)
{
	art_text(f, (FB_W - art_text_w(f, s)) / 2, y, color, s);
}

void art_rrect(int x, int y, int w, int h, int r, uint32_t color)
{
	for (int j = 0; j < h; j++) {
		int sy = y + j;
		if (sy < 0 || sy >= FB_H)
			continue;
		int dy = j < r ? r - j : (j >= h - r ? j - (h - r - 1) : 0);
		for (int i = 0; i < w; i++) {
			int sx = x + i;
			if (sx < 0 || sx >= FB_W)
				continue;
			int dx = i < r ? r - i : (i >= w - r ? i - (w - r - 1) : 0);
			volatile uint32_t *d = px(sx, sy);
			if (!dx || !dy) {
				*d = color;
				continue;
			}
			/* corner: 4x4 supersampled coverage of the quarter circle */
			unsigned in = 0;
			for (int sj = 0; sj < 4; sj++)
				for (int si = 0; si < 4; si++) {
					int ex = dx * 8 - si * 2 - 1, ey = dy * 8 - sj * 2 - 1;
					if (ex * ex + ey * ey <= r * r * 64)
						in++;
				}
			if (in)
				*d = mix(*d, color, in * 15 / 16);
		}
	}
}

void art_stage_front(int portrait_w, int row0, int row1)
{
	int ph = art_portrait_h(portrait_w);
	int top = STAGE_PANEL_Y - STAGE_DISSOLVE_H;

	art_portrait_rows((FB_W - portrait_w) / 2, FB_H - ph, portrait_w, row0, row1);
	art_dissolve(top, STAGE_DISSOLVE_H, ID_INK, row0, row1);
	if (row1 > STAGE_PANEL_Y) {
		int y = row0 > STAGE_PANEL_Y ? row0 : STAGE_PANEL_Y;
		con_rect(0, y, FB_W, (row1 < FB_H ? row1 : FB_H) - y, ID_INK);
	}
	art_image_rows(ART_WORDMARK, (FB_W - art_image_w(ART_WORDMARK)) / 2, STAGE_WORD_Y, ID_INK, row0, row1);
}
