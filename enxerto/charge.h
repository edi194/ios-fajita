#pragma once
#include <stdint.h>
#include "pmic.h"

/*
 * Off-mode charging screen (docs/BERGAMOTA_CHARGE.md): the stage of artdraw.h (tools/identity/IDENTITY.md) with
 * the state of charge as the giant white numerals behind Newton, the state on the pill (CHARGING, CHARGED, NOT
 * CHARGING, LOW BATTERY), and on the ink console panel the status line ("Charging | 4.12 V | 1.1 A"), a segmented
 * charge bar, a notice line, the key hints and diagnostics. Pure drawing (host-testable, no hardware access);
 * aligned 32-bit stores, only the regions whose content changed are redrawn after charge_ui_init.
 */
enum charge_state {
	CHARGE_UNAVAILABLE,	/* no battery readings: "--%" and "Battery info unavailable" */
	CHARGE_CHARGING,
	CHARGE_FULL,
	CHARGE_NOT_CHARGING,
};

struct charge_view {
	enum charge_state state;
	unsigned soc;		/* percent 0..100 */
	unsigned mv;		/* battery voltage, 0 = unknown */
	int ma;			/* current magnitude source: >0 charging; shown as |ma| */
	int ma_valid;
};

/* Full redraw of the static parts; forgets everything cached. */
void charge_ui_init(void);
/* The static charging picture for the logo partition (tools/mksplash.py, slot 2). */
void charge_ui_splash(void);
/* Redraw whatever differs from the last call. */
void charge_ui_update(const struct charge_view *v);
/* One-line notice above the footer in colour fg (0 or "" clears it). */
void charge_ui_notice(const char *s, uint32_t fg);
/* Small muted diagnostic lines at the bottom (0 hides). */
void charge_ui_diag(const char *l0, const char *l1);
/* Map PMIC readings to what the screen shows (the policy lives here so the host test covers it). */
void charge_view_from(struct charge_view *v, const struct pmic_batt *b);
