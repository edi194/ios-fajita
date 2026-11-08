/*
 * Off-mode charging: glue between the PMIC readers (pmic.c), the screen (charge.c), the WLED
 * backlight, the keys and the existing Bergamota fastboot. MMU off, polled, no interrupts.
 * Charging itself is done by the PMIC hardware; this code never touches the charger config.
 *
 * No static tables of pointers anywhere (build.sh rejects ABS64 relocations).
 */
#include <stdint.h>
#include "bergamota.h"
#include "charge.h"
#include "charge_mode.h"
#include "charger.h"
#include "console.h"
#include "fbui.h"
#include "fdt.h"
#include "pmic.h"
#include "usb_power.h"

#define POLL_MS		40
#define BATT_MS		5000
#define IDLE_MS		20000
#define HOLD_MS		2000
#define BLACK		0xff000000U

static uint64_t ms_now(void)
{
	uint64_t t, f;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	return t / (f / 1000);
}

static void delay_ms(unsigned ms)
{
	uint64_t end = ms_now() + ms;
	while (ms_now() < end)
		;
}

static int starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

static char how[24];	/* what triggered charging mode (an array: no ABS64 pointer) */

static void set_how(const char *s)
{
	unsigned i = 0;
	while (*s && i < sizeof how - 1)
		how[i++] = *s++;
	how[i] = 0;
}

int charge_wanted(uintptr_t dtb)
{
	const char *v = fdt_cmdline_opt(dtb, "bergamota.charge=");

	if (v) {
		set_how("bergamota.charge");
		return *v == '1';
	}
	v = fdt_cmdline_opt(dtb, "androidboot.mode=");
	if (v && starts(v, "charger") && (v[7] == ' ' || v[7] == 0)) {
		set_how("mode=charger");
		return 1;
	}
	return 0;
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

static void sb_hex(struct sb *b, uint32_t v, int digits)
{
	static const char hex[] = "0123456789abcdef";
	for (int i = 4 * (digits - 1); i >= 0 && b->n + 1 < b->max; i -= 4)
		b->d[b->n++] = hex[(v >> i) & 15];
	b->d[b->n] = 0;
}

/* ---- state ---- */

static struct pmic_batt batt;
static struct charge_view view;
static int pmic_rc;
static int screen_on = 1, pixel_blank, have_wled;
static uint16_t wled_on[2];

static void draw_diag(void)
{
	static char l0[96], l1[96];
	struct sb b0 = { l0, 0, sizeof l0 }, b1 = { l1, 0, sizeof l1 };
	int pon = pmic_pon_reason();
	uint16_t w[2] = { 0, 0 };

	l0[0] = l1[0] = 0;
	sb_str(&b0, pmic_rc ? "pmic arbiter unavailable" : "pmic ok");
	sb_str(&b0, "  msoc "); sb_hex(&b0, batt.msoc_raw, 2);
	sb_str(&b0, "  chg "); sb_hex(&b0, batt.chg_state, 1);
	sb_str(&b0, "  usbin "); sb_str(&b0, batt.usb_present ? "1" : "0");
	sb_str(&b0, "  apsd "); sb_hex(&b0, batt.apsd, 2);
	sb_str(&b0, "  pon "); if (pon < 0) sb_str(&b0, "--"); else sb_hex(&b0, (uint32_t)pon, 2);
	if (have_wled && pmic_wled_get(w) == 0) {
		sb_str(&b1, "wled "); sb_hex(&b1, w[0], 4); sb_str(&b1, "/"); sb_hex(&b1, w[1], 4);
	} else {
		sb_str(&b1, "wled n/a (pixel blank)");
	}
	sb_str(&b1, "  entered via "); sb_str(&b1, how);
	charge_ui_diag(l0, l1);
}

static void refresh(void)
{
	pmic_read_batt(&batt);
	charge_view_from(&view, &batt);
	if (screen_on || !pixel_blank) {
		charge_ui_update(&view);
		draw_diag();
	}
}

/* ---- backlight ---- */

static void backlight_init(void)
{
	uint16_t w[2];

	have_wled = 0;
	if (pmic_rc || pmic_wled_get(w) || !pmic_wled_enabled())
		return;
	have_wled = 1;
	if (w[0] & 0xfff || w[1] & 0xfff) {
		wled_on[0] = w[0];
		wled_on[1] = w[1];
	} else {
		/* ABL left the driver enabled but at 0: light it at half the 12-bit range */
		wled_on[0] = wled_on[1] = 0x7ff;
		if (pmic_wled_set(wled_on))
			have_wled = 0;
	}
}

static void blank(void)
{
	if (have_wled) {
		/* quadratic ramp down, same shape as the kernel's fade; any failed write -> pixel fallback */
		for (unsigned s = 5; s > 0 && have_wled; s--) {
			uint16_t v[2] = { (uint16_t)((wled_on[0] & 0xfff) * s * s / 36),
					  (uint16_t)((wled_on[1] & 0xfff) * s * s / 36) };
			if (pmic_wled_set(v))
				have_wled = 0;
			else
				delay_ms(25);
		}
		if (have_wled) {
			uint16_t z[2] = { 0, 0 };
			if (pmic_wled_set(z))
				have_wled = 0;
		}
		if (!have_wled) {
			/* put back what we found before falling back to black pixels */
			(void)pmic_wled_set(wled_on);
		}
	}
	if (!have_wled) {
		con_rect(0, 0, FB_W, FB_H, BLACK);
		pixel_blank = 1;
	}
	screen_on = 0;
}

static void wake(void)
{
	if (pixel_blank) {
		charge_ui_init();
		pixel_blank = 0;
		charge_ui_update(&view);
		draw_diag();
	} else if (have_wled && pmic_wled_set(wled_on)) {
		have_wled = 0;
	}
	screen_on = 1;
}

/* ---- fastboot ---- */

static char notice_buf[96];

static void enter_fastboot(uintptr_t dtb)
{
	struct sb nb = { notice_buf, 0, sizeof notice_buf };
	const char *why;

	charge_ui_notice("Starting fastboot...", TEXT);
	usb_power_up();
	why = bergamota_fastboot(dtb);	/* returns only when it could not start / ended */
	charge_ui_init();
	charge_ui_update(&view);
	notice_buf[0] = 0;
	sb_str(&nb, "fastboot stopped: ");
	sb_str(&nb, why ? why : "?");
	charge_ui_notice(notice_buf, FBUI_ERR_COLOR);
	draw_diag();
}


/* ---- main loop ---- */

void charge_run(uintptr_t dtb)
{
	uint64_t t = ms_now(), last_batt = t - BATT_MS, last_input = t, pw_t0 = 0;
	unsigned raw_prev = 0, stable = 0, pw = 0, vd = 0;
	int pw_woke = 0, keys_ok = 0, key_errs = 0, no_keys_told = 0;

	con_str("ENXERTO", "off-mode charging");
	pmic_rc = pmic_init();
	backlight_init();
	charge_ui_init();
	refresh();
	last_batt = ms_now();

	for (;;) {
		t = ms_now();

		/* keys: a new state counts after two equal samples (40 ms) */
		unsigned raw = pmic_keys();
		if (raw & PMIC_KEY_ERR) {
			if (++key_errs >= 5 && !keys_ok && !no_keys_told) {
				/* no input possible: keep the screen on and tell the user how to leave */
				no_keys_told = 1;
				charge_ui_notice("keys unavailable: hold Power 10 s to restart", FBUI_ERR_COLOR);
			}
		} else {
			key_errs = 0;
			keys_ok = 1;
			stable = raw == raw_prev ? stable + 1 : 0;
			raw_prev = raw;
			if (stable >= 1) {
				unsigned npw = raw & PMIC_KEY_POWER, nvd = raw & PMIC_KEY_VOLDN;

				if (npw && !pw) {		/* power pressed */
					pw_t0 = t;
					pw_woke = !screen_on;
					last_input = t;
					if (!screen_on)
						wake();
				} else if (!npw && pw) {	/* power released */
					last_input = t;
					if (t - pw_t0 < HOLD_MS && !pw_woke && screen_on)
						blank();
				}
				if (nvd && !vd) {		/* volume down pressed */
					last_input = t;
					if (!screen_on) {
						wake();
					} else {
						enter_fastboot(dtb);
						last_input = ms_now();
					}
					raw_prev = stable = 0;
				}
				pw = npw;
				vd = nvd;
				if (pw && t - pw_t0 >= HOLD_MS) {
					charge_ui_notice("Starting iOS...", TEXT);
					return;
				}
			}
		}

		if (t - last_batt >= BATT_MS) {
			last_batt = t;
			enxerto_charger_tick(0);
			refresh();
		}
		if (screen_on && keys_ok && t - last_input >= IDLE_MS)
			blank();
		delay_ms(POLL_MS);
	}
}
