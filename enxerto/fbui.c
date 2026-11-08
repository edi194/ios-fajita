/*
 * Bergamota fastboot screen, see fbui.h. The stage of artdraw.h (wordmark, pill, the giant iOS numerals behind
 * Newton, his coat dissolving into the ink console panel); the state lives on the panel.
 * Layout for a 1080-wide a8r8g8b8 framebuffer, everything below the 128 px notch area.
 */
#include "artdraw.h"
#include "console.h"
#include "fbui.h"

#define IN_X		96
#define IN_W		(FB_W - 2 * IN_X)
#define STATUS_Y	(STAGE_PANEL_Y + 40)
#define DETAIL_Y	(STATUS_Y + 54)
#define BAR_Y		(DETAIL_Y + 52)
#define BAR_W		IN_W
#define BAR_H		14
#define BAR_X		IN_X
#define CHG_Y		(BAR_Y + 36)
#define DIAG_Y		(CHG_Y + 44)
#define HINT_Y		(FB_H - 118)
#define ENTRY_Y		(HINT_Y + 40)
/* failed boot: the log on the ink, from LOG_Y down to the panel; the dissolve moves up above it */
#define LOG_ROWS	22
#define LOG_Y		(STAGE_PANEL_Y - LOG_ROWS * 32 - 24)

#define STR_MAX		96

static char cur_text[STR_MAX], cur_detail[STR_MAX], cur_diag[3][STR_MAX], cur_chg[STR_MAX];
static int cur_color_set;
static uint32_t cur_fg;
static int bar_px = -1;	/* -1: hidden */
static char entry_txt[48];

static void copy(char *d, const char *s)
{
	int i = 0;
	while (s && s[i] && i < STR_MAX - 1) {
		d[i] = s[i];
		i++;
	}
	d[i] = 0;
}

static int same(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

/* Ink across the panel's text column, from y for h rows. */
static void panel_clear(int y, int h)
{
	con_rect(IN_X - 8, y, IN_W + 16, h, ID_INK);
}

/* A line of mono text on the panel, cut to the column's width. */
static void panel_text(enum art_font f, int y, uint32_t fg, const char *s)
{
	char buf[STR_MAX];
	int max = IN_W / art_text_w(f, "M"), i = 0;
	for (; s[i] && i < max && i < STR_MAX - 1; i++)
		buf[i] = s[i];
	buf[i] = 0;
	panel_clear(y, art_text_h(f));
	art_text(f, IN_X, y, fg, buf);
}

static void draw_bar(int permille)
{
	if (permille < 0) {
		if (bar_px >= 0)
			panel_clear(BAR_Y, BAR_H);
		bar_px = -1;
		return;
	}
	if (permille > 1000)
		permille = 1000;
	int px = BAR_W * permille / 1000;
	if (px == bar_px)
		return;
	panel_clear(BAR_Y, BAR_H);
	art_rrect(BAR_X, BAR_Y, BAR_W, BAR_H, BAR_H / 2, STAGE_TRACK);
	if (px >= BAR_H)
		art_rrect(BAR_X, BAR_Y, px, BAR_H, BAR_H / 2, ID_LIME);
	bar_px = px;
}

void fbui_init(const char *entry)
{
	enum art_image num = art_ios_numerals();
	art_ground(0, 0, FB_W, FB_H);
	art_image(num, (FB_W - art_image_w(num)) / 2, STAGE_NUM_Y, ID_WHITE);
	art_stage_front(STAGE_PORTRAIT_W, 0, FB_H);
	art_pill(FB_W / 2, STAGE_PILL_Y, ID_LEAF, ID_PAPER, "FASTBOOT");
	art_text_centered(ART_MONO22, HINT_Y, ID_PAPER, "Hold Power + Volume Down for the bootloader");
	entry_txt[0] = 0;
	if (entry) {
		int i = 0;
		for (const char *p = "entered via: "; *p; p++)
			entry_txt[i++] = *p;
		for (; *entry && i < (int)sizeof(entry_txt) - 1; entry++)
			entry_txt[i++] = *entry;
		entry_txt[i] = 0;
		art_text_centered(ART_MONO22, ENTRY_Y, STAGE_MUTED, entry_txt);
	}
	cur_text[0] = cur_detail[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = cur_diag[2][0] = cur_chg[0] = 0;
	cur_color_set = 0;
	bar_px = -1;
	con_set_bg(BG_INK);
	con_set_scale(2);
	con_window(0, -1);	/* log lines are recorded, not drawn */
}

void fbui_status(const char *text, const char *detail, int permille, uint32_t fg)
{
	/* callers pass ink (FBUI_OK_COLOR, TEXT) or alert red, colours for the paper: on the ink panel they are
	 * paper and the lightened alert */
	uint32_t c = fg == FBUI_ERR_COLOR ? STAGE_ALERT : ID_PAPER;
	if (!cur_color_set || c != cur_fg || !same(cur_text, text)) {
		panel_text(ART_MONO30, STATUS_Y, c, text);
		copy(cur_text, text);
		cur_fg = c;
		cur_color_set = 1;
	}
	if (!detail)
		detail = "";
	if (!same(cur_detail, detail)) {
		panel_text(ART_MONO22, DETAIL_Y, ID_LIME, detail);
		copy(cur_detail, detail);
	}
	draw_bar(permille);
}

void fbui_charge(const char *s)
{
	if (!s)
		s = "";
	if (same(cur_chg, s))
		return;
	panel_text(ART_MONO22, CHG_Y, STAGE_MUTED, s);
	copy(cur_chg, s);
}

void fbui_diag(const char *l0, const char *l1, const char *l2)
{
	const char *l[3] = { l0, l1, l2 };
	for (int i = 0; i < 3; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		panel_clear(DIAG_Y + i * 18, 16);
		con_text(IN_X, DIAG_Y + i * 18, 1, 0, STAGE_MUTED, s);
		copy(cur_diag[i], s);
	}
}

void fbui_error(const char *why, const char *detail)
{
	char buf[STR_MAX];
	int i = 0;
	for (const char *p = "BOOT FAILED: "; *p; p++)
		buf[i++] = *p;
	for (; *why && i < STR_MAX - 1; why++)
		buf[i++] = *why;
	buf[i] = 0;
	fbui_status(buf, detail, FBUI_NOBAR, FBUI_ERR_COLOR);
	/* the panel grows up over the portrait for the log tail (console.c draws its rows across the whole width, on
	 * BG_INK: paper text, lime labels), its top edge dissolving like the panel's own */
	art_dissolve(LOG_Y - 24 - STAGE_DISSOLVE_H, STAGE_DISSOLVE_H, ID_INK, 0, FB_H);
	con_rect(0, LOG_Y - 24, FB_W, STAGE_PANEL_Y - LOG_Y + 24, ID_INK);
	con_set_scale(2);
	con_window(LOG_Y, LOG_ROWS);
	con_replay_tail(LOG_ROWS - 1);
	con_window(0, -1);
}
