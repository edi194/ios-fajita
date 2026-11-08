/*
 * Branded boot screen, see bootui.h. Layout for a 1080-wide a8r8g8b8 framebuffer; all
 * positions derive from FB_W/FB_H so sweet (2400) and beryllium (2246) both work. The block
 * (logo, title, bar, status) is centred between the notch area and the log window.
 */
#include "bootui.h"
#include "console.h"
/* Apple logo for the hand-off screen: generated from the iOS root by tools/mkapplelogo.py (git-ignored). */
#if defined(__has_include)
#if __has_include("applelogo.h")
#include "applelogo.h"
#define HAVE_APPLELOGO 1
#endif
#endif

#include "artdraw.h"

#ifndef BOOTUI_LOG
#define BOOTUI_LOG	0	/* logo only; the log is recorded and shown if the boot fails */
#endif

#define LOG_SCALE	2
#define LOG_ROWS	24
#define LOG_Y		(FB_H - 24 - LOG_ROWS * 16 * LOG_SCALE)

/* tools/identity/IDENTITY.md: wordmark, subtitle, progress and status at the top; the iOS generation's giant white
 * numerals behind the Newton portrait, which stands on the bottom edge. */
#define WORD_Y		205
#define SUB_Y		350
#define BAR_W		640
#define BAR_H		16
#define BAR_X		((FB_W - BAR_W) / 2)
#define BAR_Y		450
#define STATUS_Y	492
#define PORTRAIT_W	1000
#define PORTRAIT_X	((FB_W - PORTRAIT_W) / 2)
#define BAR_TRACK	0xffbccb7aU	/* ink at 14 % over the lime */

#ifdef BOARD_BERYLLIUM
#define DEVICE_NAME	"POCO F1"
#else
#define DEVICE_NAME	"REDMI NOTE 10 PRO"
#endif

static int active;
static unsigned bar_px;		/* filled width so far */

/* Row-wise palette RLE (tools/mkapplelogo.py) straight into the framebuffer: the Apple logo of the hand-off screen. */
void bootui_draw_rle(const unsigned int *pal, const unsigned char *p, int w, int h, int x0, int y0)
{
	for (int y = 0; y < h; y++) {
		volatile uint32_t *line = con_fb + (y0 + y) * (FB_STRIDE / 4) + x0;
		int x = 0;
		while (x < w) {
			unsigned c = *p++;
			if (c & 0x80) {
				for (unsigned n = (c & 0x7f) + 1; n; n--)
					line[x++] = pal[*p++];
			} else {
				uint32_t col = pal[*p++];
				for (unsigned n = c + 1; n; n--)
					line[x++] = col;
			}
		}
	}
}

/* The ground with the giant numerals and the portrait, as every identity screen starts. */
void bootui_scene(int portrait_x, int portrait_w, int numerals_x, int numerals_lift, enum art_image numerals)
{
	int ph = art_portrait_h(portrait_w), py = FB_H - ph;
	art_ground(0, 0, FB_W, FB_H);
	art_image(numerals, numerals_x, py - numerals_lift, ID_WHITE);
	art_portrait(portrait_x, py, portrait_w);
	art_image(ART_WORDMARK, (FB_W - art_image_w(ART_WORDMARK)) / 2, WORD_Y, ID_INK);
}

static void status(uint32_t fg, const char *s)
{
	art_ground(0, STATUS_Y, FB_W, art_text_h(ART_MONO30));
	art_text_centered(ART_MONO30, STATUS_Y, fg, s);
}

void bootui_init(void)
{
	enum art_image num = art_ios_numerals();
	bootui_scene(PORTRAIT_X, PORTRAIT_W, (FB_W - art_image_w(num)) / 2, 150, num);
	art_text_centered(ART_MONO30, SUB_Y, ID_INK, num == ART_NUM_18 ? "iOS 18 / " DEVICE_NAME : "iOS 26 / " DEVICE_NAME);
	art_rrect(BAR_X, BAR_Y, BAR_W, BAR_H, BAR_H / 2, BAR_TRACK);
	bar_px = 0;
	status(ID_INK, "STARTING");
	con_set_bg(BG_BOOT);
	con_set_scale(LOG_SCALE);
	con_window(BOOTUI_LOG ? LOG_Y : 0, BOOTUI_LOG ? LOG_ROWS : -1);
	if (BOOTUI_LOG)
		con_replay();	/* lines printed before the boot screen existed (e.g. usb_power_up) */
	active = 1;
}

void bootui_handoff(void)
{
#ifdef HAVE_APPLELOGO
	/* iBoot-style: black, Apple logo centred, nothing else. Stays on the panel (xnu keeps the boot
	 * framebuffer untouched in graphics mode) until backboardd presents its own identical logo. */
	if (!active)
		return;
	con_clear(0xff000000U);
	bootui_draw_rle(applelogo_pal, applelogo_rle, APPLELOGO_W, APPLELOGO_H,
			(FB_W - APPLELOGO_W) / 2, (FB_H - APPLELOGO_H) / 2);
#endif
}

static void bar_to(unsigned permille)
{
	if (permille > 1000)
		permille = 1000;
	unsigned px = (unsigned)((uint64_t)BAR_W * permille / 1000);
	if (px > bar_px && px >= BAR_H) {
		art_rrect(BAR_X, BAR_Y, (int)px, BAR_H, BAR_H / 2, ID_INK);	/* redrawn whole: the round end moves */
		bar_px = px;
	}
}

void bootui_progress(unsigned permille, const char *s)
{
	bar_to(permille);
	status(ID_INK, s);
}

static char *put_u(char *d, uint64_t v)
{
	char t[20];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 20);
	while (n)
		*d++ = t[--n];
	return d;
}

void bootui_mib(const char *label, uint64_t done, uint64_t total, unsigned from, unsigned to)
{
	char buf[64], *d = buf;
	while (*label && d < buf + 24)
		*d++ = *label++;
	*d++ = ' ';
	d = put_u(d, done);
	*d++ = ' '; *d++ = '/'; *d++ = ' ';
	d = put_u(d, total);
	const char *u = " MiB";
	while (*u)
		*d++ = *u++;
	*d = 0;
	bar_to(total ? from + (unsigned)((uint64_t)(to - from) * (done > total ? total : done) / total) : from);
	status(ID_INK, buf);
}

void bootui_fail(const char *msg)
{
	status(ID_ALERT, msg);
}

int bootui_active(void)
{
	return active;
}
