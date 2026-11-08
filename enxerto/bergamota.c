/*
 * Bergamota fastboot glue: wires the protocol core (fastboot.c) to the polled
 * DWC3 driver (usb_dwc3.c), the UFS storage (ufs.c + storage.c), the text console,
 * the loader and the reset machinery.
 *
 * MMU stays off while USB runs (all memory is Device; the USB driver assumes that). It is turned on
 * only for a CACHED WINDOW around CPU-heavy storage work (BLAKE2b hashing of what the phone holds,
 * read-back compare): [window: mmu_enable_ranges with the scratch area and the compared image Normal
 * write-back] ... [mmu_off_ret cleans and invalidates everything again]. USB is never polled inside a
 * window. All DMA (UFS, USB) does its own cache maintenance (cache.h) so it is right in both states.
 * The cached MMU for the payload comes up inside loader_boot_payload, after usb_dwc3_stop().
 *
 * No static tables of pointers anywhere in this file (build.sh rejects ABS64
 * relocations): the transport/platform structs are filled in at run time.
 */
#include <stdint.h>
#include "board.h"
#include "bergamota.h"
#include "bootui.h"
#include "cache.h"
#include "charger.h"
#include "console.h"
#include "fastboot.h"
#include "fbui.h"
#include "fdt.h"
#include "loader.h"
#include "mmu.h"
#include "storage.h"
#include "ufs.h"
#include "usb_dwc3.h"

/*
 * Download window. Derived from the live DT (dtb/beryllium/live.dts) and tools/mkadt.py:
 * every fixed carve-out ends below 0xb0400000 and the ADT's own pools are validated inside
 * 0x9f800000..0xfd000000 (mkadt.py LOWPOOL_MIN/MAX); the kernel payloads put phys_base at
 * 0x100000000 with mem_size 0xfcc00000 (whole upper DDR bank), so the buffer must live in the
 * low bank. 0xb8000000 + 1 GiB = 0xf8000000 keeps clear of ramoops/ramdump (<= 0xb0400000) and
 * of the ABL scratch area near the top of 4 GiB (its USB event buffer was at 0xfdfc8000).
 * It overlaps xnu's default zero-copy low pool (0xb0400000 + 252 MiB), which xnu only touches
 * after the buffer is dead (the loader has copied everything out by then).
 */
#define DL_BASE		0xb8000000UL
#define DL_SIZE		0x40000000UL	/* 1 GiB */
#define DL_MIN		0x04000000UL	/* refuse to run with less than 64 MiB */

#define RESTART_BOOTLOADER	0x77665500U
#define RESTART_REBOOT		0x77665501U
#define PSCI_SYSTEM_RESET	0x84000009UL

_Static_assert(USB_LINK_LOST == FB_LINK_LOST, "transport codes");

#define rsr(r) ({ uint64_t _v; __asm__ volatile("mrs %0, " r : "=r"(_v)); _v; })

extern char _head[], _end[];

static uint64_t ms_now(void)
{
	uint64_t t, f;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	f = rsr("cntfrq_el0");
	return t / (f / 1000);
}

static void delay_ms(unsigned ms)
{
	uint64_t end = ms_now() + ms;
	while (ms_now() < end)
		;
}

static uint32_t be32(uintptr_t a)
{
	return __builtin_bswap32(*(volatile uint32_t *)a);
}

/* ---- boot.img cmdline options ---- */

static int starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

/* Value of "key=" as a whole word of /chosen bootargs, or 0. */
static const char *cmdline_opt(uintptr_t dtb, const char *key)
{
	uint32_t len = 0;
	const char *a = (const char *)fdt_chosen_prop(dtb, "bootargs", &len);

	if (!a)
		return 0;
	for (uint32_t i = 0; i < len && a[i]; i++)
		if ((i == 0 || a[i - 1] == ' ') && starts(a + i, key)) {
			const char *v = a + i;
			while (*key++)
				v++;
			return v;
		}
	return 0;
}

#define RR_BERGAMOTA	0x42455247U	/* 'BERG': written by the kernel for `sweetreboot bergamota` */

static char entry_why[16];	/* an array: a static string pointer would need an ABS64 relocation */

static void set_entry(const char *s)
{
	unsigned i = 0;
	while (*s && i < sizeof entry_why - 1)
		entry_why[i++] = *s++;
	entry_why[i] = 0;
}

int bergamota_wanted(uintptr_t dtb)
{
	volatile uint32_t *rr = (volatile uint32_t *)IMEM_RESTART_REASON;
	const char *v;

	if (*rr == RR_BERGAMOTA) {
		*rr = 0;	/* one-shot: the next reboot boots normally */
		__asm__ volatile("dsb sy" ::: "memory");
		set_entry("restart reason");
		con_str("ENXERTO", "entered via restart reason");
		return 1;
	}
	v = cmdline_opt(dtb, "bergamota.fastboot=");
	if (v) {
		set_entry("cmdline");
		return *v == '1';
	}
	set_entry("no payload");
	return !loader_has_payload(dtb);
}

/* ---- reset ---- */

static uint64_t smc(uint64_t fn)
{
	register uint64_t x0 __asm__("x0") = fn;
	register uint64_t x1 __asm__("x1") = 0;
	register uint64_t x2 __asm__("x2") = 0;
	register uint64_t x3 __asm__("x3") = 0;
	__asm__ volatile("smc #0" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3) : : "x4", "x5", "x6", "x7", "x8",
			 "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory");
	return x0;
}

/* Like shim.c reset(): IMEM restart reason, PSCI SYSTEM_RESET, PS_HOLD as the fallback. */
static void __attribute__((noreturn)) hw_reset(uint32_t reason)
{
	usb_dwc3_stop();
	*(volatile uint32_t *)IMEM_RESTART_REASON = reason;
	__asm__ volatile("dsb sy" ::: "memory");
	smc(PSCI_SYSTEM_RESET);
	*(volatile uint32_t *)PSHOLD = 0;
	for (;;)
		__asm__ volatile("wfe");
}

/* ---- screen (fbui.c) ---- */

static struct fb *g_fb;
static uint64_t ui_last_ms, ui_start_ms;
static uint64_t buf_base, buf_size;

/* no lookup table of string pointers (ABS64 relocations): keep this a real switch */
__attribute__((optimize("no-tree-switch-conversion")))
static const char *usb_state_str(enum usb_state s)
{
	switch (s) {
	case USB_ST_DOWN: return "down";
	case USB_ST_RUNNING: return "no host";
	case USB_ST_RESET: return "reset";
	case USB_ST_ADDRESSED: return "addressed";
	case USB_ST_CONFIGURED: return "configured";
	}
	return "?";
}

static uint32_t le32p(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* tiny string builder, no libc */
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

static void sb_strn(struct sb *b, const char *s, unsigned n)
{
	while (*s && n-- && b->n + 1 < b->max)
		b->d[b->n++] = *s++;
	b->d[b->n] = 0;
}

static void sb_u(struct sb *b, uint64_t v)
{
	char t[20];
	int n = 0;
	do
		t[n++] = '0' + v % 10;
	while ((v /= 10) && n < 20);
	while (n && b->n + 1 < b->max)
		b->d[b->n++] = t[--n];
	b->d[b->n] = 0;
}

static void sb_hex(struct sb *b, uint32_t v)
{
	static const char hex[] = "0123456789abcdef";
	for (int i = 28; i >= 0 && b->n + 1 < b->max; i -= 4)
		b->d[b->n++] = hex[(v >> i) & 15];
	b->d[b->n] = 0;
}

/* bytes as "12.3" MiB */
static void sb_mib(struct sb *b, uint64_t bytes)
{
	uint64_t t = (bytes * 10) >> 20;
	sb_u(b, t / 10);
	sb_str(b, ".");
	sb_u(b, t % 10);
}

static void ui_diag(enum usb_state st, int show)
{
	static char l0[96], l1[96], l2[96];
	struct usb_dwc3_info *u = &usb_info;
	struct fb *fb = g_fb;
	struct sb b0 = { l0, 0, sizeof l0 }, b1 = { l1, 0, sizeof l1 }, b2 = { l2, 0, sizeof l2 };

	if (!show) {
		fbui_diag(0, 0, 0);
		return;
	}
	l0[0] = l1[0] = l2[0] = 0;
	sb_str(&b0, "usb "); sb_str(&b0, usb_state_str(st));
	sb_str(&b0, "  ev "); sb_hex(&b0, u->events);
	sb_str(&b0, " rst "); sb_hex(&b0, u->resets);
	sb_str(&b0, " setup "); sb_hex(&b0, u->setups);
	sb_str(&b0, " last "); sb_hex(&b0, le32p(u->last_setup));
	sb_str(&b1, "dwc3 id "); sb_hex(&b1, u->gsnpsid);
	sb_str(&b1, " dsts "); sb_hex(&b1, u->dsts);
	sb_str(&b1, " gctl "); sb_hex(&b1, u->gctl_abl); sb_str(&b1, "/"); sb_hex(&b1, u->gctl_now);
	sb_str(&b1, " qusb "); sb_hex(&b1, u->qusb_pwr_before << 8 | u->qusb_pwr_after);
	sb_str(&b1, " pll "); sb_hex(&b1, u->qusb_pll_after);
	sb_str(&b1, " smmu "); sb_hex(&b1, (uint32_t)u->smmu_rc); sb_str(&b1, "/"); sb_hex(&b1, u->smmu_info);
	sb_str(&b2, "buf "); sb_hex(&b2, (uint32_t)buf_base); sb_str(&b2, "+"); sb_u(&b2, buf_size >> 20); sb_str(&b2, "MiB");
	if (fb) {
		sb_str(&b2, "  cmd "); sb_strn(&b2, fb->last_cmd, 24);
		sb_str(&b2, "  reply "); sb_strn(&b2, fb->last_resp, 24);
	}
	fbui_diag(l0, l1, l2);
}

/* "187 MB/s" from bytes over milliseconds (decimal MB like fastboot tools print) */
static void sb_rate(struct sb *b, uint64_t bytes, uint64_t ms)
{
	if (!ms)
		return;
	sb_u(b, bytes / 1000 / ms);
	sb_str(b, " MB/s");
}

static char last_summary[64];	/* result of the last flash/hash, shown while idle */
static uint64_t op_t0_ms, dl_t0_ms;
static int op_prev_kind;

/* no lookup table of string pointers (ABS64 relocations) */
__attribute__((optimize("no-tree-switch-conversion")))
static const char *op_title(int kind)
{
	switch (kind) {
	case FB_OP_FLASH: return "FLASHING ";
	case FB_OP_ERASE: return "ERASING ";
	}
	return "READING ";	/* hash: the phone's partition is read and hashed */
}

static void upper(struct sb *b, const char *s)
{
	for (; *s && b->n + 1 < b->max; s++)
		b->d[b->n++] = (*s >= 'a' && *s <= 'z') ? (char)(*s - 32) : *s;
	b->d[b->n] = 0;
}

/* Derive the status from USB + protocol state; fbui only redraws what changed. */
static void ui_update(void)
{
	static char text[48], detail[72];
	static uint64_t prev_dl_want;
	struct fb *fb = g_fb;
	enum usb_state st = usb_dwc3_state();
	struct sb bt = { text, 0, sizeof text }, bd = { detail, 0, sizeof detail };
	int permille = FBUI_NOBAR;
	uint32_t fg = FBUI_OK_COLOR;
	uint64_t now = ms_now();

	text[0] = detail[0] = 0;
	if (fb && fb->op_kind != op_prev_kind) {
		op_prev_kind = fb->op_kind;
		op_t0_ms = now;
	}
	if (fb && fb->dl_want && !prev_dl_want)
		dl_t0_ms = now;
	prev_dl_want = fb ? fb->dl_want : 0;
	if (fb && fb->op_kind != FB_OP_NONE) {
		/* partition, MiB done, speed (Bergamota style: lime status, pale detail) */
		uint64_t done = fb->op_done + fb->op_sub, total = fb->op_total;
		unsigned pm = total ? (unsigned)(done * 1000 / total) : 0;
		if (pm > 1000)
			pm = 1000;
		sb_str(&bt, op_title(fb->op_kind));
		upper(&bt, fb->op_name);
		sb_str(&bt, " "); sb_u(&bt, pm / 10); sb_str(&bt, "%");
		sb_mib(&bd, done); sb_str(&bd, " / "); sb_mib(&bd, total); sb_str(&bd, " MiB  ");
		sb_rate(&bd, done, now - op_t0_ms);
		if (fb->op_kind == FB_OP_FLASH) {
			sb_str(&bd, "  total "); sb_mib(&bd, fb->wr_bytes + fb->op_sub); sb_str(&bd, " MiB written");
		}
		permille = (int)pm;
		fg = TEXT;
	} else if (fb && fb->dl_want) {
		unsigned pm = (unsigned)(fb->dl_got * 1000 / fb->dl_want);
		sb_str(&bt, "RECEIVING "); sb_u(&bt, pm / 10); sb_str(&bt, "%");
		sb_str(&bd, "("); sb_mib(&bd, fb->dl_got); sb_str(&bd, " / "); sb_mib(&bd, fb->dl_want); sb_str(&bd, " MiB)  ");
		sb_rate(&bd, fb->dl_got, now - dl_t0_ms);
		permille = (int)pm;
		fg = TEXT;
	} else if (st == USB_ST_CONFIGURED) {
		if (fb && fb->dl_len) {
			sb_str(&bt, "READY");
			sb_str(&bd, "image in memory: "); sb_mib(&bd, fb->dl_len); sb_str(&bd, " MiB");
			permille = 1000;
		} else {
			sb_str(&bt, fb && fb->n_cmds ? "READY" : "CONNECTED");
			if (last_summary[0])
				sb_str(&bd, last_summary);
			else
				sb_str(&bd, "waiting for fastboot commands");
		}
		fg = TEXT;
	} else if (st == USB_ST_RESET || st == USB_ST_ADDRESSED) {
		sb_str(&bt, "CONNECTING");
		sb_str(&bd, "USB host found");
	} else {
		sb_str(&bt, "CONNECT TO YOUR MAC");
		sb_str(&bd, "plug in the USB cable");
	}
	fbui_status(text, detail, permille, fg);
	{
		static char chg[48];

		enxerto_charger_line(chg, sizeof chg);	/* cached text, no hardware access */
		fbui_charge(chg);
	}
	ui_diag(st, st != USB_ST_CONFIGURED && now - ui_start_ms > 20000);
}

/* Cheap enough to call from every wait loop: updates at most every 250 ms. */
static void ui_tick(void)
{
	uint64_t t = ms_now();
	if (t - ui_last_ms < 250)
		return;
	ui_last_ms = t;
	enxerto_charger_tick(0);	/* re-plug / APSD / temperature re-check, at most every 5 s */
	ui_update();
}

/* ---- transport + platform callbacks ---- */

static void p_charger(void *ctx, int raw, char *buf, unsigned n)
{
	(void)ctx;
	enxerto_charger_tick(1);	/* a getvar answers with fresh registers */
	if (raw)
		enxerto_charger_raw(buf, n);
	else
		enxerto_charger_status(buf, n);
}

static int t_recv_cmd(void *ctx, char *buf, unsigned max)
{
	(void)ctx;
	return usb_dwc3_cmd_poll(buf, max);
}

static int t_send(void *ctx, const char *buf, unsigned len)
{
	(void)ctx;
	return usb_dwc3_bulk_in(buf, len);
}

static void usb_idle(void)
{
	ui_tick();
}

static int t_recv_data(void *ctx, uint8_t *dst, uint64_t len)
{
	(void)ctx;
	return usb_dwc3_bulk_out(dst, len, usb_idle);
}

static int t_send_data(void *ctx, const uint8_t *src, uint64_t len)
{
	(void)ctx;
	return usb_dwc3_bulk_in_dma(src, len, usb_idle);
}

static void p_idle(void *ctx, struct fb *fb)
{
	(void)ctx;
	(void)fb;
	ui_tick();
}

/* [off, off + size) of the SWEETXNU payload inside the download, or a reason. */
static const char *payload_range(const uint8_t *img, uint64_t len, uintptr_t *lo, uintptr_t *hi)
{
	uint64_t off = 0, size = 0;
	const char *why = "bad image";

	if (!fb_find_payload(img, len, &off, &size, &why))
		return why;
	*lo = (uintptr_t)img + off;
	*hi = *lo + size;
	return 0;
}

static const char *p_check_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	uintptr_t lo = 0, hi = 0;
	const char *why = payload_range(img, len, &lo, &hi);

	(void)ctx;
	if (why)
		return why;
	return loader_check(lo, hi);
}

static void __attribute__((noreturn)) boot_failed(const char *why)
{
	if (bootui_active()) {
		bootui_fail(why);
		delay_ms(8000);
	}
	fbui_init(entry_why);
	fbui_error(why, "back to ABL fastboot in 20 s");
	delay_ms(20000);
	hw_reset(RESTART_BOOTLOADER);
}

static void p_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	uintptr_t lo = 0, hi = 0;
	const char *why = payload_range(img, len, &lo, &hi);

	(void)ctx;
	if (why)
		boot_failed(why);
	fbui_status("BOOTING PAYLOAD", "stopping USB, handing over", 1000, TEXT);
	con_str("BOOT", "downloaded image, stopping USB");
	usb_dwc3_stop();
	why = loader_boot_payload(lo, hi, 1);
	boot_failed(why);
}

static void p_reboot(void *ctx, int mode)
{
	(void)ctx;
	fbui_status("REBOOTING", mode ? "to the bootloader" : "", FBUI_NOBAR, LABEL);
	con_str("RESET", mode ? "reboot-bootloader" : "reboot");
	delay_ms(300);		/* the OKAY has completed on the wire; give the host a moment */
	hw_reset(mode ? RESTART_BOOTLOADER : RESTART_REBOOT);
}

/* ---- storage: UFS + GPT allowlist (ufs.c, storage.c), lazily brought up on the first storage command ---- */

static struct stor g_stor;
static int stor_up;
static uint64_t scratch_base;
static int win_depth;
static struct mmu_range win_r[3];
static uint64_t last_info_ms;

#define PAGE16K	0x4000UL

/*
 * Cached window (see the file comment): the scratch area and [lo, hi) become Normal write-back, the image
 * too. USB must not run inside. Nested requests share one window.
 */
static void st_cached(void *ctx, int on, const void *lo, const void *hi)
{
	(void)ctx;
	if (on) {
		if (win_depth++)
			return;
		struct mmu_range ex[2];
		unsigned n = 0;
		ex[n++] = (struct mmu_range){ scratch_base, scratch_base + STOR_SCRATCH };
		if (hi > lo)
			ex[n++] = (struct mmu_range){ (uintptr_t)lo, (uintptr_t)hi };
		struct mmu_info mi;
		if (mmu_enable_ranges(&mi, ex, (int)n)) {
			win_depth = 0;		/* no window: everything still works, only slow where the CPU reads data */
			return;
		}
		/* the ranges mmu_off_ret cleans: the image and the extra ranges, rounded like the mapping */
		win_r[0] = (struct mmu_range){ mi.img_lo, mi.img_hi };
		for (unsigned i = 0; i < 2; i++) {
			struct mmu_range r = ex[i < n ? i : 0];
			win_r[1 + i] = (struct mmu_range){ r.lo & ~(PAGE16K - 1), (r.hi + PAGE16K - 1) & ~(PAGE16K - 1) };
		}
		return;
	}
	if (win_depth && --win_depth == 0)
		mmu_off_ret(win_r);
}

static void st_progress(void *ctx, uint64_t bytes)
{
	(void)ctx;
	if (!g_fb)
		return;
	g_fb->op_sub += bytes;
	ui_tick();
	/* keep the host's fastboot client talking during long commands (not inside the cached window:
	   the USB driver assumes MMU off) */
	uint64_t t = ms_now();
	if (!win_depth && t - last_info_ms > 2000 && g_fb->op_total) {
		static char line[40];
		struct sb b = { line, 0, sizeof line };
		line[0] = 0;
		sb_str(&b, g_fb->op_name); sb_str(&b, " ");
		sb_u(&b, (g_fb->op_done + g_fb->op_sub) * 100 / g_fb->op_total); sb_str(&b, "%");
		fb_info(g_fb, line);
		last_info_ms = t;
	}
}

/* NULL when UFS and the GPT scan are usable, else why not. */
static const char *st_ensure(void)
{
	if (!stor_up) {
		int rc = ufs_init();
		if (rc)
			return ufs_errstr(rc);
		ufs_blkdev(&g_stor.bd);
		g_stor.ctx = 0;
		g_stor.scratch = (uint8_t *)scratch_base;
		g_stor.cached = st_cached;
		g_stor.progress = st_progress;
		ufs_set_idle(ui_tick);
		/* stale dirty lines ABL left in the scratch area must never be evicted over our data */
		dc_flush(g_stor.scratch, STOR_SCRATCH);
		stor_up = 1;
	}
	if (!g_stor.scanned) {
		const char *e = stor_scan(&g_stor);
		if (e && !g_stor.nparts)
			return e;
	}
	return 0;
}

static const char *p_part_info(void *ctx, const char *name, uint64_t *size)
{
	const char *why = st_ensure();
	const struct stor_part *p;

	(void)ctx;
	if (why)
		return why;
	p = stor_find(&g_stor, name, &why);
	if (!p)
		return why;
	*size = p->nblk * STOR_BLK;
	return 0;
}

static const struct stor_part *st_part(const char *name, const char **why)
{
	*why = st_ensure();
	return *why ? 0 : stor_find(&g_stor, name, why);
}

static uint64_t fl_t0_ms;

static const char *p_flash_begin(void *ctx, const char *name, const uint8_t *img, uint64_t img_len, uint64_t total)
{
	const char *why;

	(void)ctx;
	(void)total;
	if (!st_part(name, &why))
		return why;
	last_summary[0] = 0;
	fl_t0_ms = ms_now();
	if (g_stor.verify)
		st_cached(0, 1, img, img + img_len);
	return 0;
}

static const char *p_part_write(void *ctx, const char *name, uint64_t off, const uint8_t *src, uint64_t len)
{
	const char *why;
	const struct stor_part *p = st_part(name, &why);

	(void)ctx;
	return p ? stor_write(&g_stor, p, off, src, len) : why;
}

static const char *p_part_fill(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t pat)
{
	const char *why;
	const struct stor_part *p = st_part(name, &why);

	(void)ctx;
	return p ? stor_fill(&g_stor, p, off, len, pat) : why;
}

static const char *p_flash_end(void *ctx, const char *name, int ok)
{
	const char *why, *e = 0;
	const struct stor_part *p = st_part(name, &why);
	struct fb *fb = g_fb;

	(void)ctx;
	if (g_stor.verify)
		st_cached(0, 0, 0, 0);
	if (!p)
		return why;
	if (ok)
		e = stor_sync(&g_stor, p);	/* device write cache -> flash before anyone resets the phone */
	if (ok && !e && fb) {
		static char line[64];
		struct sb b = { line, 0, sizeof line };
		uint64_t ms = ms_now() - fl_t0_ms;
		line[0] = 0;
		sb_str(&b, "wrote "); sb_str(&b, name); sb_str(&b, " ");
		sb_mib(&b, fb->op_done); sb_str(&b, " MiB ");
		sb_rate(&b, fb->op_done, ms ? ms : 1);
		if (g_stor.verify)
			sb_str(&b, " (verified)");
		for (unsigned i = 0; i < sizeof last_summary - 1 && line[i]; i++)
			last_summary[i] = line[i], last_summary[i + 1] = 0;
	}
	return e;
}

static const char *p_part_erase(void *ctx, const char *name)
{
	const char *why;
	const struct stor_part *p = st_part(name, &why);

	(void)ctx;
	if (!p)
		return why;
	const char *e = stor_erase(&g_stor, p);
	return e ? e : stor_sync(&g_stor, p);
}

static const char *p_part_hash(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t bs, uint8_t *out)
{
	const char *why;
	const struct stor_part *p = st_part(name, &why);

	(void)ctx;
	if (!p)
		return why;
	/* the table is written with CPU stores into memory USB will DMA from: no stale dirty line may remain there */
	dc_flush(out, (len + bs - 1) / bs * STOR_HASH_LEN);
	last_summary[0] = 0;
	uint64_t t0 = ms_now();
	const char *e = stor_hash(&g_stor, p, off, len, bs, out);
	if (!e && g_fb) {
		static char line[64];
		struct sb b = { line, 0, sizeof line };
		line[0] = 0;
		sb_str(&b, "hashed "); sb_str(&b, name); sb_str(&b, " "); sb_mib(&b, len); sb_str(&b, " MiB ");
		sb_rate(&b, len, ms_now() - t0 + 1);
		for (unsigned i = 0; i < sizeof last_summary - 1 && line[i]; i++)
			last_summary[i] = line[i], last_summary[i + 1] = 0;
	}
	return e;
}

static const char *p_part_selftest(void *ctx, const char *name)
{
	const char *why;
	const struct stor_part *p = st_part(name, &why);

	(void)ctx;
	if (!p)
		return why;
	last_summary[0] = 0;
	return stor_selftest(&g_stor, p);
}

static void p_set_ufs_depth(void *ctx, int n)
{
	(void)ctx;
	ufs_set_depth(n);
}

static void p_set_verify(void *ctx, int on)
{
	(void)ctx;
	g_stor.verify = on;
}

static void p_gpt_info(void *ctx, struct fb *fb)
{
	static char line[64];
	const char *why = st_ensure();

	(void)ctx;
	if (why) {
		fb_info(fb, why);
		return;
	}
	stor_scan(&g_stor);	/* oem gpt re-reads the GPTs */
	for (unsigned l = 0; l < 8; l++) {
		struct sb b = { line, 0, sizeof line };
		if (!g_stor.lun_info[l].blocks)
			continue;
		line[0] = 0;
		sb_str(&b, "lun "); sb_u(&b, l);
		sb_str(&b, g_stor.lun_info[l].valid ? " gpt ok " : " no valid gpt ");
		sb_u(&b, g_stor.lun_info[l].blocks >> 8); sb_str(&b, " MiB");
		fb_info(fb, line);
	}
	for (unsigned i = 0; i < g_stor.nparts; i++) {
		const struct stor_part *p = &g_stor.parts[i];
		struct sb b = { line, 0, sizeof line };
		line[0] = 0;
		sb_str(&b, p->name); sb_str(&b, " lun "); sb_u(&b, p->lun);
		sb_str(&b, " lba "); sb_hex(&b, (uint32_t)p->first);
		sb_str(&b, " "); sb_u(&b, p->nblk >> 8); sb_str(&b, " MiB");
		if (p->dup)
			sb_str(&b, " AMBIGUOUS");
		fb_info(fb, line);
	}
}

__attribute__((optimize("no-tree-switch-conversion")))
static const char *p_usb_speed(void *ctx)
{
	(void)ctx;
	switch (usb_info.speed) {
	case 0: return "high";
	case 4: return "super";
	case 1: case 3: return "full";
	case 2: return "low";
	}
	return "unknown";
}

/* ---- download window ---- */

static void carve(uint64_t *base, uint64_t *end, uint64_t lo, uint64_t hi)
{
	if (hi <= *base || lo >= *end)
		return;
	if (lo > *base && lo - *base >= *end - hi)
		*end = lo;
	else
		*base = (hi + 0x1fffffUL) & ~0x1fffffUL;
}

static const char *pick_buffer(uintptr_t dtb)
{
	uint64_t base = DL_BASE, end = DL_BASE + DL_SIZE, a, b;

	carve(&base, &end, (uintptr_t)_head, (uintptr_t)_end);
	if (dtb && be32(dtb) == 0xd00dfeed)
		carve(&base, &end, dtb, dtb + be32(dtb + 4));
	if (fdt_chosen_u64(dtb, "linux,initrd-start", &a) && fdt_chosen_u64(dtb, "linux,initrd-end", &b))
		carve(&base, &end, a, b);
	if (end <= base || end - base < DL_MIN)
		return "no free download buffer";
	buf_base = base;
	buf_size = (end - base) & ~0xfffffUL;	/* whole MiB */
	if (buf_size < DL_MIN + STOR_SCRATCH)
		return "no free download buffer";
	buf_size -= STOR_SCRATCH;		/* the last 4 MiB are the storage scratch area, not part of the download */
	scratch_base = buf_base + buf_size;
	return 0;
}

const char *bergamota_fastboot(uintptr_t dtb)
{
	static struct fb fb;
	static struct fb_transport tr;
	static struct fb_platform pl;
	fbui_init(entry_why);
	fbui_status("STARTING", "", FBUI_NOBAR, LABEL);
	con_str("ENXERTO", "Bergamota fastboot " BOARD_NAME);
	const char *why = pick_buffer(dtb);

	if (why)
		return why;
	const char *smmu_opt = cmdline_opt(dtb, "bergamota.smmu=");
	int use_smmu = !(smmu_opt && *smmu_opt == '0');

	ui_start_ms = ms_now();
	con_str("USB", "starting controller...");
	int rc = usb_dwc3_init(use_smmu);
	if (rc) {
		usb_dwc3_stop();
		return usb_dwc3_errstr(rc);
	}

	tr.ctx = 0;
	tr.recv_cmd = t_recv_cmd;
	tr.send = t_send;
	tr.recv_data = t_recv_data;
	tr.send_data = t_send_data;
	pl.ctx = 0;
	pl.dl_buf = (uint8_t *)buf_base;
	pl.dl_max = buf_size;
	pl.idle = p_idle;
	pl.check_boot = p_check_boot;
	pl.boot = p_boot;
	pl.reboot = p_reboot;
	pl.part_info = p_part_info;
	pl.flash_begin = p_flash_begin;
	pl.part_write = p_part_write;
	pl.part_fill = p_part_fill;
	pl.flash_end = p_flash_end;
	pl.part_erase = p_part_erase;
	pl.part_hash = p_part_hash;
	pl.set_verify = p_set_verify;
	pl.part_selftest = p_part_selftest;
	pl.set_ufs_depth = p_set_ufs_depth;
	pl.gpt_info = p_gpt_info;
	pl.usb_speed = p_usb_speed;
	pl.charger = p_charger;
	fb_init(&fb, &tr, &pl);
	g_fb = &fb;
	ui_last_ms = ms_now();
	ui_update();
	fb_run(&fb);
	usb_dwc3_stop();
	return "fastboot ended";
}
