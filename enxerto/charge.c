/*
 * Off-mode charging screen, see charge.h. The stage of artdraw.h, like the Bergamota fastboot screen (fbui.c), with
 * the state of charge as its giant numerals; everything below the 128 px notch area of the 1080-wide a8r8g8b8 FB.
 */
#include "artdraw.h"
#include "charge.h"
#include "console.h"
#include "fbui.h"

#define PORTRAIT_W	1000			/* smaller than fastboot's: the percentage stays clear of the hair */
#define NUM_Y		(FB_H - 1710)		/* the giant percentage; its foot just touching the hair */
#define NUM_GAP		6
#define PCT_GAP		18
#define IN_X		96
#define IN_W		(FB_W - 2 * IN_X)
#define STATUS_Y	(STAGE_PANEL_Y + 40)
#define SEGS		20			/* the charge bar: 5 % a segment */
#define SEG_GAP		8
#define SEG_W		((IN_W - (SEGS - 1) * SEG_GAP) / SEGS)
#define SEG_H		28
#define SEG_X		((FB_W - SEGS * SEG_W - (SEGS - 1) * SEG_GAP) / 2)
#define BAR_Y		(STATUS_Y + 66)
#define NOTICE_Y	(BAR_Y + SEG_H + 30)
#define HINT_Y		(FB_H - 150)
#define DIAG_Y		(FB_H - 96)

#define STR_MAX		96

static int cur_valid;			/* numerals/pill/bar/status cache valid */
static unsigned cur_soc;
static enum charge_state cur_state;
static int cur_avail, cur_low, cur_segs;
static char cur_status[STR_MAX], cur_notice[STR_MAX], cur_diag[2][STR_MAX];
static uint32_t cur_notice_fg;

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

/* ---- tiny string builder ---- */

struct sb {
	char *d;
	unsigned n, max;
};

static void sb_str(struct sb *b, const char *s)
{
	while (*s && b->n + 1 < b->max)
		b->d[b->n++] = *s++;
	b->d[b->n] = 0;
}

static void sb_u(struct sb *b, unsigned v)
{
	char t[12];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 12);
	while (n && b->n + 1 < b->max)
		b->d[b->n++] = t[--n];
	b->d[b->n] = 0;
}

/* "a | b | c" centred, in one mono size. */
static void parts_line(int y, enum art_font f, uint32_t fg, const char *const *p, int n)
{
	char buf[STR_MAX];
	struct sb b = { buf, 0, sizeof buf };
	buf[0] = 0;
	for (int i = 0; i < n; i++) {
		if (i)
			sb_str(&b, "  |  ");
		sb_str(&b, p[i]);
	}
	art_text_centered(f, y, fg, buf);
}

/* ---- the giant percentage: white Archivo digits and a small %, in front of the ground, behind the portrait ---- */

static void numerals(const char *digits, int avail)
{
	int dw = art_big_w(digits, NUM_GAP), pw = art_image_w(ART_PCT);
	int with_pct = avail && dw + PCT_GAP + pw <= FB_W - 2 * 40;	/* "100" leaves no room for it */
	int w = dw + (with_pct ? PCT_GAP + pw : 0), x = (FB_W - w) / 2, h = art_big_h();

	art_ground(0, NUM_Y, FB_W, h);
	art_big(x, NUM_Y, NUM_GAP, ID_WHITE, digits, NUM_Y, NUM_Y + h);
	if (with_pct)
		art_image(ART_PCT, x + dw + PCT_GAP, NUM_Y + 8, ID_WHITE);
	art_stage_front(PORTRAIT_W, NUM_Y, NUM_Y + h);
}

/* The state on the pill, on its band of plain ground. */
static void pill(enum charge_state st, int low)
{
	int h = art_pill_h();

	art_ground(0, STAGE_PILL_Y, FB_W, h);
	if (st == CHARGE_CHARGING)
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_LEAF, ID_PAPER, "CHARGING");
	else if (st == CHARGE_FULL)
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_INK, ID_LIME, "CHARGED");
	else if (st == CHARGE_UNAVAILABLE)
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_INK, ID_PAPER, "BATTERY");
	else if (low)
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_ALERT, ID_PAPER, "LOW BATTERY");
	else
		art_pill(FB_W / 2, STAGE_PILL_Y, ID_INK, ID_PAPER, "NOT CHARGING");
}

/* 20 segments of 5 %, lit in lime (alert red when low and not charging). */
static void bar(int lit, int low)
{
	con_rect(IN_X - 8, BAR_Y, IN_W + 16, SEG_H, ID_INK);
	for (int i = 0; i < SEGS; i++)
		art_rrect(SEG_X + i * (SEG_W + SEG_GAP), BAR_Y, SEG_W, SEG_H, 6,
			  i < lit ? (low ? STAGE_ALERT : ID_LIME) : STAGE_TRACK);
}

/* Key hints: the key in lime, what it does in paper. */
static void hints(void)
{
	const char *p[4];	/* filled at run time: a static pointer table would need ABS64 relocations */
	int w = 0, x;

	p[0] = "Vol -";
	p[1] = " fastboot      ";
	p[2] = "hold Power";
	p[3] = " start iOS";
	for (int i = 0; i < 4; i++)
		w += art_text_w(ART_MONO22, p[i]);
	x = (FB_W - w) / 2;
	for (int i = 0; i < 4; i++) {
		art_text(ART_MONO22, x, HINT_Y, i & 1 ? ID_PAPER : ID_LIME, p[i]);
		x += art_text_w(ART_MONO22, p[i]);
	}
}

/* ---- public ---- */

void charge_ui_init(void)
{
	art_ground(0, 0, FB_W, FB_H);
	art_stage_front(PORTRAIT_W, 0, FB_H);
	hints();
	cur_valid = 0;
	cur_status[0] = cur_notice[0] = 0;
	cur_diag[0][0] = cur_diag[1][0] = 0;
	con_set_bg(BG_INK);
	con_set_scale(2);
	con_window(0, -1);	/* con_* log lines are recorded, not drawn */
}

/* The static picture of the logo partition's charging slot (ABL shows it before Enxerto runs): the stage with the
 * CHARGING pill and an empty bar, no numbers, no key hints (those are Enxerto's, not ABL's). */
void charge_ui_splash(void)
{
	charge_ui_init();
	con_rect(0, HINT_Y, FB_W, art_text_h(ART_MONO22), ID_INK);
	pill(CHARGE_CHARGING, 0);
	bar(0, 0);
	art_text_centered(ART_MONO30, STATUS_Y, ID_PAPER, "Charging");
}

void charge_ui_update(const struct charge_view *v)
{
	char digits[8], status[STR_MAX], volt[12], amp[12];
	struct sb bd = { digits, 0, sizeof digits }, bs = { status, 0, sizeof status };
	struct sb bv = { volt, 0, sizeof volt }, ba = { amp, 0, sizeof amp };
	const char *parts[3];
	int np = 0, avail = v->state != CHARGE_UNAVAILABLE;
	unsigned soc = v->soc > 100 ? 100 : v->soc;
	int charging = v->state == CHARGE_CHARGING;
	int low = avail && soc <= 15 && !charging;
	int segs = avail ? (int)(soc * SEGS + 99) / 100 : 0;	/* any charge lights the first segment */
	uint32_t scol = ID_PAPER;

	digits[0] = status[0] = volt[0] = amp[0] = 0;
	if (avail) {
		sb_u(&bd, soc);
		sb_u(&bv, v->mv / 1000);
		sb_str(&bv, ".");
		sb_u(&bv, (v->mv % 1000) / 100);
		sb_u(&bv, (v->mv % 1000) / 10 % 10);
		sb_str(&bv, " V");
		unsigned ma = (unsigned)(v->ma < 0 ? -v->ma : v->ma);
		unsigned dec = (ma + 50) / 100;
		sb_u(&ba, dec / 10);
		sb_str(&ba, ".");
		sb_u(&ba, dec % 10);
		sb_str(&ba, " A");
		parts[np++] = v->state == CHARGE_CHARGING ? "Charging" : v->state == CHARGE_FULL ? "Charged" : "Not charging";
		if (v->mv)
			parts[np++] = volt;
		if (v->ma_valid && charging)
			parts[np++] = amp;
		if (low)
			scol = STAGE_ALERT;
	} else {
		sb_str(&bd, "--");
		parts[np++] = "Battery info unavailable";
		scol = STAGE_MUTED;
	}
	for (int i = 0; i < np; i++) {
		if (i)
			sb_str(&bs, "|");
		sb_str(&bs, parts[i]);
	}

	if (!cur_valid || soc != cur_soc || avail != cur_avail)
		numerals(digits, avail);
	if (!cur_valid || v->state != cur_state || low != cur_low)
		pill(v->state, low);
	if (!cur_valid || segs != cur_segs || low != cur_low)
		bar(segs, low);
	if (!cur_valid || !same(status, cur_status) || low != cur_low) {
		con_rect(0, STATUS_Y, FB_W, art_text_h(ART_MONO30), ID_INK);
		parts_line(STATUS_Y, ART_MONO30, scol, parts, np);
		copy(cur_status, status);
	}
	cur_soc = soc;
	cur_state = v->state;
	cur_avail = avail;
	cur_low = low;
	cur_segs = segs;
	cur_valid = 1;
}

void charge_ui_notice(const char *s, uint32_t fg)
{
	if (!s)
		s = "";
	if (same(cur_notice, s) && fg == cur_notice_fg)
		return;
	cur_notice_fg = fg;
	con_rect(0, NOTICE_Y, FB_W, art_text_h(ART_MONO22), ID_INK);
	/* callers pass colours for the paper (ink, alert red): on the ink they are lime and the lightened alert */
	if (*s)
		art_text_centered(ART_MONO22, NOTICE_Y, fg == FBUI_ERR_COLOR ? STAGE_ALERT : fg == TEXT ? ID_LIME : fg, s);
	copy(cur_notice, s);
}

void charge_ui_diag(const char *l0, const char *l1)
{
	const char *l[2] = { l0, l1 };

	for (int i = 0; i < 2; i++) {
		const char *s = l[i] ? l[i] : "";
		if (same(cur_diag[i], s))
			continue;
		con_rect(0, DIAG_Y + i * 18, FB_W, 16, ID_INK);
		con_text((FB_W - con_text_w(s, 1, 0)) / 2, DIAG_Y + i * 18, 1, 0, STAGE_MUTED, s);
		copy(cur_diag[i], s);
	}
}

void charge_view_from(struct charge_view *v, const struct pmic_batt *b)
{
	v->soc = b->soc;
	v->mv = b->mv;
	v->ma = b->ma;
	v->ma_valid = b->ma_valid;
	if (!b->valid)
		v->state = CHARGE_UNAVAILABLE;
	else if (b->chg == PMIC_CHG_CHARGING)
		v->state = CHARGE_CHARGING;
	else if (b->chg == PMIC_CHG_FULL || (b->usb_present && b->soc >= 100))
		v->state = CHARGE_FULL;
	else
		v->state = CHARGE_NOT_CHARGING;
}
