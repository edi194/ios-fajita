#pragma once
#include <stdint.h>

#include "board.h"

/* Text-console palette (tools/identity/IDENTITY.md): ink on paper, labels in leaf green. The branded screens draw
 * their own ground (artdraw.c). */
#define BG_BOOT	0xfff4f3ecU	/* paper: text screens and log panels */
#define BG_PANIC 0xffb3261eU	/* alert red: shim exceptions */
#define BG_INK	0xff161616U	/* ink: the console panel of the fastboot screen (its log on a failed boot) */
#define LABEL	0xff1a5933U	/* leaf green */
#define TEXT	0xff161616U	/* ink */
#define WHITE	0xffffffffU
#define GREEN	0xff00ff00U

/* First text row: rows 0-1 sit under the notch/status area. */
#define TOP_ROWS 2

extern volatile uint32_t *con_fb;

void con_clear(uint32_t bg);
/* The background text rows and log windows are drawn on, without clearing (screens that paint their own ground). */
void con_set_bg(uint32_t bg);
void con_skip(void);
/* Re-print the recorded console lines (kept even while the boot-screen log is muted). */
void con_replay(void);
/* Like con_replay, but only the last n lines. */
void con_replay_tail(unsigned n);
void con_rect(int x, int y, int w, int h, uint32_t c);	/* clipped solid fill, 32-bit stores */
/* Text at pixel position, transparent background; spacing = extra px between glyphs. */
void con_text(int x, int y, int scale, int spacing, uint32_t fg, const char *s);
int con_text_w(const char *s, int scale, int spacing);
/* Route con_str/con_hex* into a window of `rows` lines (current scale) at y_px that wraps; rows < 0 mutes them. */
void con_window(int y_px, int rows);
void con_set_scale(int s);	/* 2 or 3; applies to the following rows */
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
