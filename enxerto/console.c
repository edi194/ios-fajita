/*
 * Minimal text console on the ABL splash framebuffer. With the MMU off
 * every access is Device memory, so stay aligned (-mstrict-align).
 */
#include "console.h"
#include "font.h"

static int SCALE = 3;
#define CH_W		(8 * SCALE)
#define CH_H		(16 * SCALE)
#define MARGIN		24
#define LABEL_COLS	8

volatile uint32_t *con_fb = (volatile uint32_t *)FB_BASE;
static uint32_t con_bg;
static int row;
/* Text window (boot screen log): base_y pixel origin, win_rows lines (0 = full screen, <0 = muted). */
static int base_y = MARGIN, win_rows;

/*
 * Every console line is also kept here, so a muted boot log (logo-only boot screen) can be shown
 * after the fact when something fails (con_replay).
 */
#define HIST_LINES	48
#define HIST_COLS	64
static char hist_ch[HIST_LINES][HIST_COLS];
static uint32_t hist_fg[HIST_LINES][HIST_COLS];
static unsigned hist_n;	/* lines started so far; the current one is hist_n % HIST_LINES */
static int replaying;

static void hist_put(int col, char ch, uint32_t fg)
{
	if (replaying || col < 0 || col >= HIST_COLS)
		return;
	unsigned l = hist_n % HIST_LINES;
	hist_ch[l][col] = ch;
	hist_fg[l][col] = fg;
}

static void hist_newline(void)
{
	if (replaying)
		return;
	hist_n++;
	unsigned l = hist_n % HIST_LINES;
	for (int i = 0; i < HIST_COLS; i++)
		hist_ch[l][i] = 0;
}

void con_set_bg(uint32_t bg)
{
	con_bg = bg;
}

void con_clear(uint32_t bg)
{
	for (int y = 0; y < FB_H; y++) {
		volatile uint32_t *line = con_fb + y * (FB_STRIDE / 4);
		for (int x = 0; x < FB_W; x++)
			line[x] = bg;
	}
	con_bg = bg;
	row = TOP_ROWS;
	base_y = MARGIN;
	win_rows = 0;
}

void con_rect(int x, int y, int w, int h, uint32_t c)
{
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > FB_W) w = FB_W - x;
	if (y + h > FB_H) h = FB_H - y;
	for (int j = 0; j < h; j++) {
		volatile uint32_t *line = con_fb + (y + j) * (FB_STRIDE / 4) + x;
		for (int i = 0; i < w; i++)
			line[i] = c;
	}
}

/* Glyph with transparent background, scaled; one aligned 32-bit store per lit pixel. */
static void glyph(int x0, int y0, int scale, char ch, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	for (int gy = 0; gy < 16; gy++) {
		unsigned bits = g[gy];
		for (int gx = 0; gx < 8; gx++) {
			if (!(bits & (0x80 >> gx)))
				continue;
			int x = x0 + gx * scale;
			if (x + scale > FB_W)
				return;
			for (int sy = 0; sy < scale; sy++) {
				int y = y0 + gy * scale + sy;
				if (y >= FB_H)
					return;
				volatile uint32_t *p = con_fb + y * (FB_STRIDE / 4) + x;
				for (int sx = 0; sx < scale; sx++)
					p[sx] = fg;
			}
		}
	}
}

int con_text_w(const char *s, int scale, int spacing)
{
	int n = 0;
	while (s[n])
		n++;
	return n ? n * 8 * scale + (n - 1) * spacing : 0;
}

void con_text(int x, int y, int scale, int spacing, uint32_t fg, const char *s)
{
	for (; *s; s++, x += 8 * scale + spacing)
		glyph(x, y, scale, *s, fg);
}

void con_window(int y_px, int rows)
{
	base_y = y_px;
	win_rows = rows;
	row = 0;
	if (rows > 0)
		con_rect(0, base_y, FB_W, rows * CH_H, con_bg);
}

static void next_row(void)
{
	hist_newline();
	row++;
	if (win_rows > 0) {
		if (row >= win_rows)
			row = 0;
		con_rect(0, base_y + row * CH_H, FB_W, CH_H, con_bg);	/* wipe the line about to be written */
	}
}

static void put_char(int col, char ch, uint32_t fg)
{
	if (ch < 0x20 || ch > 0x7e)
		ch = '?';
	const unsigned char *g = font8x16[ch - 0x20];
	int x0 = MARGIN + col * CH_W, y0 = base_y + row * CH_H;
	hist_put(col, ch, fg);
	if (con_bg == BG_PANIC)		/* ink on the alert red does not read: paper text, pale labels */
		fg = fg == LABEL ? 0xffffcfc4U : 0xfff4f3ecU;
	else if (con_bg == BG_INK)	/* nor on ink: paper text, lime labels */
		fg = fg == LABEL ? 0xffd7e98aU : 0xfff4f3ecU;
	if (win_rows < 0)
		return;
	if (x0 + CH_W > FB_W || y0 + CH_H > FB_H)
		return;
	for (int gy = 0; gy < 16; gy++)
		for (int gx = 0; gx < 8; gx++) {
			uint32_t c = (g[gy] & (0x80 >> gx)) ? fg : con_bg;
			for (int sy = 0; sy < SCALE; sy++) {
				volatile uint32_t *p = con_fb + (y0 + gy * SCALE + sy) * (FB_STRIDE / 4)
						       + x0 + gx * SCALE;
				for (int sx = 0; sx < SCALE; sx++)
					p[sx] = c;
			}
		}
}

static int put_str(int col, const char *s, uint32_t fg)
{
	while (*s)
		put_char(col++, *s++, fg);
	return col;
}

static void fmt_hex(char *buf, uint64_t v, int digits)
{
	static const char hex[] = "0123456789ABCDEF";
	for (int i = 0; i < digits; i++)
		buf[i] = hex[(v >> (4 * (digits - 1 - i))) & 0xf];
	buf[digits] = 0;
}

void con_set_scale(int s)
{
	SCALE = s;
}

void con_skip(void)
{
	next_row();
}

void con_str(const char *label, const char *s)
{
	put_str(0, label, LABEL);
	put_str(LABEL_COLS, s, TEXT);
	next_row();
}

void con_hex(const char *label, uint64_t v)
{
	char buf[17];
	fmt_hex(buf, v, 16);
	con_str(label, buf);
}

void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb)
{
	char buf[9];
	int col = put_str(0, label, LABEL);
	col = col < LABEL_COLS ? LABEL_COLS : col + 1;
	col = put_str(col, a, LABEL);
	fmt_hex(buf, va, 8);
	col = put_str(col, buf, TEXT);
	if (b) {
		col = put_str(col + 1, b, LABEL);
		fmt_hex(buf, vb, 8);
		put_str(col, buf, TEXT);
	}
	next_row();
}

/* Print the recorded lines (oldest first) at the current position, e.g. after a failed muted boot. */
void con_replay_tail(unsigned n)
{
	unsigned first = hist_n >= HIST_LINES - 1 ? hist_n - (HIST_LINES - 1) : 0;
	if (n < hist_n - first)
		first = hist_n - n;
	replaying = 1;
	for (unsigned i = first; i < hist_n; i++) {
		unsigned l = i % HIST_LINES;
		int end = HIST_COLS;
		while (end && !hist_ch[l][end - 1])
			end--;	/* label/value gap columns are never written: print them as blanks */
		for (int c = 0; c < end; c++)
			put_char(c, hist_ch[l][c] ? hist_ch[l][c] : ' ', hist_fg[l][c]);
		next_row();
	}
	replaying = 0;
}

void con_replay(void)
{
	con_replay_tail(HIST_LINES);
}
