#pragma once
/*
 * Bergamota fastboot: the Android fastboot protocol subset (getvar, download, boot, flash, erase,
 * upload, oem hash/verify/gpt, reboot, reboot-bootloader, continue) as a transport-independent
 * state machine, so fastboot_test.c can drive it with a fake transport and a fake storage.
 *
 * Storage commands (flash/erase/oem hash/getvar partition-*) only ever accept the names userdata, boot
 * and logo (fb_part_allowed, checked here AND again in storage.c); everything else, and format /
 * set_active / flashing / logical-partition commands, answers FAIL.
 * Hardware glue (USB, screen, UFS, boot, reset): bergamota.c.
 */
#include <stdint.h>

/* Transport return codes (anything else < 0 is a failure of that call). */
#define FB_LINK_LOST	(-1)	/* host reset / unplugged: drop the session, keep serving */
#define FB_EOF		(-2)	/* fake transport only: script over, fb_run returns */

struct fb_transport {
	void *ctx;
	/* One command packet (no terminator): >0 length, 0 = nothing yet, <0 = FB_LINK_LOST / FB_EOF. */
	int (*recv_cmd)(void *ctx, char *buf, unsigned max);
	/* 0 or <0 */
	int (*send)(void *ctx, const char *buf, unsigned len);
	/* One bulk transfer of up to len bytes into dst: >0 bytes, 0 = empty packet (retried), <0 = FB_LINK_LOST / error. */
	int (*recv_data)(void *ctx, uint8_t *dst, uint64_t len);
	/* Bulk IN of len bytes straight from memory (upload): 0 or <0; NULL = `upload` unsupported. */
	int (*send_data)(void *ctx, const uint8_t *src, uint64_t len);
};

struct fb;

struct fb_platform {
	void *ctx;
	uint8_t *dl_buf;	/* download buffer */
	uint64_t dl_max;	/* its size = max-download-size; at least 4096 more bytes of slack follow it (raw flash pads the last block) */
	/* Called while nothing is happening (UI refresh); may be NULL. */
	void (*idle)(void *ctx, struct fb *fb);
	/* 'boot' pre-check on the downloaded image: NULL = acceptable, else a short reason (sent as FAIL). */
	const char *(*check_boot)(void *ctx, const uint8_t *img, uint64_t len);
	/* After OKAY was sent: boot it (does not return on success). */
	void (*boot)(void *ctx, const uint8_t *img, uint64_t len);
	/* After OKAY was sent: mode 0 = normal reboot, 1 = bootloader (does not return on hardware). */
	void (*reboot)(void *ctx, int mode);

	/*
	 * ---- storage (all optional; without part_info the storage commands answer FAIL) ----
	 * Every callback returns NULL on success or a short error text (sent as FAIL). `name` has already
	 * passed fb_part_allowed. Offsets/lengths are bytes inside the partition, multiples of 4096.
	 */
	const char *(*part_info)(void *ctx, const char *name, uint64_t *size);
	/* img/img_len: the downloaded image (for a cached verify window), total: bytes that will be written */
	const char *(*flash_begin)(void *ctx, const char *name, const uint8_t *img, uint64_t img_len, uint64_t total);
	const char *(*part_write)(void *ctx, const char *name, uint64_t off, const uint8_t *src, uint64_t len);
	const char *(*part_fill)(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t pattern);
	/* ok = 0 when a write failed. Flushes the device cache; returns an error text if that fails. */
	const char *(*flash_end)(void *ctx, const char *name, int ok);
	const char *(*part_erase)(void *ctx, const char *name);
	/* 16 bytes (BLAKE2b-128) per block of bs bytes into out; bs is a power of two, 4 KiB..2 MiB */
	const char *(*part_hash)(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t bs, uint8_t *out);
	void (*set_verify)(void *ctx, int on);
	/* oem selftest:<p>: read-only UFS read-path test with dirty caches (NULL = pass) */
	const char *(*part_selftest)(void *ctx, const char *name);
	/* oem ufsq:<n>: UFS commands in flight 1..8 (debug knob) */
	void (*set_ufs_depth)(void *ctx, int n);
	/* `oem gpt`: report what the GPT scan found through fb_info() */
	void (*gpt_info)(void *ctx, struct fb *fb);
	/* getvar usb-speed: "high", "super", "full", ...; may be NULL */
	const char *(*usb_speed)(void *ctx);
	/* getvar bergamota-charger (raw=0) / bergamota-charger-raw (raw=1): at most 47 characters into buf; may be NULL */
	void (*charger)(void *ctx, int raw, char *buf, unsigned n);
};

/* what a long command is doing, for the screen */
#define FB_OP_NONE	0
#define FB_OP_FLASH	1
#define FB_OP_ERASE	2
#define FB_OP_HASH	3
/* The only partitions that may ever be written, erased or hashed. */
int fb_part_allowed(const char *name);

enum fb_result {
	FB_R_BOOT,		/* 'boot' accepted; platform boot returned (= failed) */
	FB_R_REBOOT,
	FB_R_REBOOT_BL,
	FB_R_CONTINUE,
	FB_R_EOF,		/* transport script ended (tests) */
};

struct fb {
	const struct fb_transport *t;
	const struct fb_platform *p;
	uint64_t dl_len;	/* bytes in the buffer from the last complete download */
	uint64_t dl_want, dl_got; /* download in progress */
	/* long operation in progress (screen): kind, partition, bytes done / total, bytes done inside the current callback */
	int op_kind;
	char op_name[16];
	uint64_t op_done, op_total, op_sub;
	uint64_t wr_bytes;	/* bytes flashed since boot (all pieces) */
	uint64_t staged_len;	/* bytes at dl_buf that `upload` sends (oem hash result), 0 = none */
	int verify;		/* oem verify: read back and compare after every write */
	char last_cmd[64];	/* NUL terminated, for the screen */
	char last_resp[64];
	unsigned n_cmds, n_links;
};

void fb_init(struct fb *fb, const struct fb_transport *t, const struct fb_platform *p);
/* One INFO line to the host (progress of a long command, diagnostics). Failures are ignored. */
void fb_info(struct fb *fb, const char *text);
/* Serve until a terminal command ran (platform callback returned) or the transport ended. */
enum fb_result fb_run(struct fb *fb);

/* ---- image helpers (pure; also used by the boot pre-check) ---- */
#define FB_IMG_SWEETXNU	1	/* raw SWEETXNU payload */
#define FB_IMG_BOOTIMG	2	/* Android boot.img with a SWEETXNU ramdisk */
/*
 * Locate the SWEETXNU payload: (*off, *size) = its place inside img. Returns the
 * kind (FB_IMG_*), or 0 with a short reason in *why.
 */
int fb_find_payload(const uint8_t *img, uint64_t len, uint64_t *off, uint64_t *size, const char **why);
