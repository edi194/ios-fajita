#pragma once
#include <stdint.h>

/*
 * Branded boot screen ("Bergamota Project"): logo, title, progress bar, status line and a small
 * log window at the bottom (con_str/con_hex* output goes there while it is up). Everything is
 * drawn with aligned 32-bit stores, so it is correct with the MMU off (Device) and on (NC).
 * Build with -DBOOTUI_LOG=0 to hide the log window. Exception screens use plain con_* text.
 */
void bootui_init(void);
/* Advance the bar to `permille` (never moves back; only the new part is drawn), set the status line. */
void bootui_progress(unsigned permille, const char *status);
/* Status line "<label> <done> / <total> MiB", bar mapped linearly from `from` to `to` permille. */
void bootui_mib(const char *label, uint64_t done, uint64_t total, unsigned from, unsigned to);
/* Error: red status line, bar stays; the log stays readable. */
void bootui_fail(const char *msg);
int bootui_active(void);
/* Last act before xnu: swap the branded screen for the Apple logo (no-op if applelogo.h was not generated). */
void bootui_handoff(void);
/* Draw a palette+RLE picture (tools/mkapplelogo.py format) at x0,y0. */
/* The identity's background: ground, giant numerals, the portrait (width portrait_w at portrait_x, standing on the
 * bottom edge) and the wordmark. numerals_lift: how far the numerals start above the portrait's top. */
#include "artdraw.h"
void bootui_scene(int portrait_x, int portrait_w, int numerals_x, int numerals_lift, enum art_image numerals);
void bootui_draw_rle(const unsigned int *pal, const unsigned char *rle, int w, int h, int x0, int y0);
