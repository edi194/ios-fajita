/*
 * Bergamota fastboot protocol core: see fastboot.h. No libc, no hardware, no
 * absolute pointers in data (the shim image runs wherever ABL put it); the
 * host test (fastboot_test.c) compiles this file unchanged.
 */
#include "fastboot.h"
#include "sparse.h"

#ifndef FB_PRODUCT
#define FB_PRODUCT	"beryllium"
#endif
#define FB_VERSION_BL	"bergamota-2"
#define FB_SERIAL	"bergamota0001"
#define FB_PKT		64	/* fastboot packet limit: 4 byte status + 60 */

static int fb_starts(const char *s, const char *p)
{
	while (*p && *s == *p)
		s++, p++;
	return !*p;
}

static int fb_eq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

static void fb_copy(char *d, const char *s, int max)
{
	int i = 0;
	while (i < max - 1 && s[i])
		d[i] = s[i], i++;
	d[i] = 0;
}

static int fb_hex(char *out, uint64_t v, int min_digits)
{
	static const char hex[] = "0123456789abcdef";
	char tmp[16];
	int n = 0, o = 0;
	do {
		tmp[n++] = hex[v & 0xf];
		v >>= 4;
	} while (v);
	while (n < min_digits)
		tmp[n++] = '0';
	while (n)
		out[o++] = tmp[--n];
	out[o] = 0;
	return o;
}

void fb_init(struct fb *fb, const struct fb_transport *t, const struct fb_platform *p)
{
	fb->t = t;
	fb->p = p;
	fb->dl_len = fb->dl_want = fb->dl_got = 0;
	fb->last_cmd[0] = fb->last_resp[0] = 0;
	fb->n_cmds = fb->n_links = 0;
	fb->op_kind = FB_OP_NONE;
	fb->op_name[0] = 0;
	fb->op_done = fb->op_total = fb->op_sub = fb->wr_bytes = fb->staged_len = 0;
	fb->verify = 0;
}

int fb_part_allowed(const char *name)
{
	return fb_eq(name, "userdata") || fb_eq(name, "boot") || fb_eq(name, "logo");
}

/* "OKAY" / "FAIL" / "INFO" / "DATA" + text, at most 64 bytes. */
static int fb_resp(struct fb *fb, const char *kind, const char *text)
{
	char buf[FB_PKT + 1];
	int n = 0;

	for (; n < 4; n++)
		buf[n] = kind[n];
	for (int i = 0; text[i] && n < FB_PKT; i++)
		buf[n++] = text[i];
	buf[n] = 0;
	if (kind[0] != 'I' && kind[0] != 'D')	/* the screen shows the final answer, not INFO/DATA */
		fb_copy(fb->last_resp, buf, sizeof fb->last_resp);
	return fb->t->send(fb->t->ctx, buf, n);
}

void fb_info(struct fb *fb, const char *text)
{
	fb_resp(fb, "INFO", text);
}

static void fb_drop_session(struct fb *fb)
{
	fb->dl_len = fb->dl_want = fb->dl_got = fb->staged_len = 0;
	fb->op_kind = FB_OP_NONE;
	fb->n_links++;
}

/*
 * Variable table as code: a static array of string pointers would need absolute
 * relocations, and the shim image runs wherever ABL put it (build.sh rejects ABS64).
 */
#define FB_NVARS 15
#define FB_VBUF 48	/* value buffer of fb_getvar */

static const char *fb_var(struct fb *fb, unsigned i, const char **name, char *buf)
{
	switch (i) {
	case 0: *name = "version"; return "0.4";
	case 1: *name = "version-bootloader"; return FB_VERSION_BL;
	case 2: *name = "product"; return FB_PRODUCT;
	case 3: *name = "serialno"; return FB_SERIAL;
	case 4: *name = "secure"; return "no";
	case 5: *name = "unlocked"; return "yes";
	case 6:
		*name = "max-download-size";
		buf[0] = '0';
		buf[1] = 'x';
		fb_hex(buf + 2, fb->p->dl_max, 1);
		return buf;
	case 7: *name = "is-userspace"; return "no";
	case 8: *name = "bergamota"; return "1";
	case 9: *name = "bergamota-flash"; return "1";	/* flash/erase/upload/oem hash exist (userdata, boot, logo) */
	case 10: *name = "verify"; return fb->verify ? "on" : "off";
	case 11: *name = "slot-count"; return "0";	/* the Poco F1 is not A/B */
	case 12: *name = "usb-speed"; return fb->p->usb_speed ? fb->p->usb_speed(fb->p->ctx) : "unknown";
	case 13:
	case 14:
		*name = i == 13 ? "bergamota-charger" : "bergamota-charger-raw";
		buf[0] = 0;
		if (!fb->p->charger)
			return "unavailable";
		fb->p->charger(fb->p->ctx, i == 14, buf, FB_VBUF);
		return buf[0] ? buf : "unavailable";
	}
	return 0;
}

#define FB_NOT_ALLOWED	"partition not allowed (only userdata, boot, logo)"

/* partition-size:/partition-type:/has-slot:/is-logical: for the three allowed partitions */
static void fb_getvar_part(struct fb *fb, const char *want)
{
	const char *name;
	int kind;
	uint64_t size = 0;
	char buf[24];

	if (fb_starts(want, "partition-size:")) {
		kind = 0;
		name = want + 15;
	} else if (fb_starts(want, "partition-type:")) {
		kind = 1;
		name = want + 15;
	} else if (fb_starts(want, "has-slot:")) {
		kind = 2;
		name = want + 9;
	} else {
		kind = 3;
		name = want + 11;
	}
	if (!fb_part_allowed(name)) {
		fb_resp(fb, "FAIL", FB_NOT_ALLOWED);
		return;
	}
	if (kind >= 2) {
		fb_resp(fb, "OKAY", "no");
		return;
	}
	if (!fb->p->part_info) {
		fb_resp(fb, "FAIL", "no storage");
		return;
	}
	const char *e = fb->p->part_info(fb->p->ctx, name, &size);
	if (e) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	if (kind == 1) {
		fb_resp(fb, "OKAY", "raw");
		return;
	}
	buf[0] = '0';
	buf[1] = 'x';
	fb_hex(buf + 2, size, 1);
	fb_resp(fb, "OKAY", buf);
}

static void fb_getvar(struct fb *fb, const char *want)
{
	char vbuf[FB_VBUF], line[FB_PKT];
	const char *name;

	if (fb_eq(want, "all")) {
		for (unsigned i = 0; i < FB_NVARS; i++) {
			int n = 0;
			const char *v = fb_var(fb, i, &name, vbuf);
			for (const char *s = name; *s && n < 40; s++)
				line[n++] = *s;
			line[n++] = ':';
			line[n++] = ' ';
			for (; *v && n < FB_PKT - 5; v++)
				line[n++] = *v;
			line[n] = 0;
			fb_resp(fb, "INFO", line);
		}
		fb_resp(fb, "OKAY", "");
		return;
	}
	if (fb_starts(want, "partition-size:") || fb_starts(want, "partition-type:") ||
	    fb_starts(want, "has-slot:") || fb_starts(want, "is-logical:")) {
		fb_getvar_part(fb, want);
		return;
	}
	for (unsigned i = 0; i < FB_NVARS; i++) {
		const char *v = fb_var(fb, i, &name, vbuf);
		if (fb_eq(want, name)) {
			fb_resp(fb, "OKAY", v);
			return;
		}
	}
	fb_resp(fb, "FAIL", "unknown variable");
}

static int fb_parse_hex(const char *s, uint64_t *out)
{
	uint64_t v = 0;
	int n = 0;

	for (; *s; s++, n++) {
		char c = *s;
		int d;
		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			return 0;
		if (n >= 8)
			return 0;
		v = v << 4 | (uint64_t)d;
	}
	*out = v;
	return n > 0;
}

/* Returns 0 = answered, FB_LINK_LOST / FB_EOF to bubble up. */
static int fb_download(struct fb *fb, const char *arg)
{
	uint64_t n;
	char buf[12];

	fb->dl_len = 0;
	fb->staged_len = 0;
	if (!fb_parse_hex(arg, &n)) {
		fb_resp(fb, "FAIL", "bad download size");
		return 0;
	}
	if (n == 0) {
		fb_resp(fb, "FAIL", "empty download");
		return 0;
	}
	if (n > fb->p->dl_max) {
		fb_resp(fb, "FAIL", "data too large");
		return 0;
	}
	fb_hex(buf, n, 8);
	if (fb_resp(fb, "DATA", buf) < 0)
		return FB_LINK_LOST;
	fb->dl_want = n;
	fb->dl_got = 0;
	int empty = 0;
	while (fb->dl_got < n) {
		int r = fb->t->recv_data(fb->t->ctx, fb->p->dl_buf + fb->dl_got, n - fb->dl_got);
		if (r == 0) {
			if (++empty > 64) {
				fb->dl_want = fb->dl_got = 0;
				fb_resp(fb, "FAIL", "download stalled");
				return 0;
			}
			continue;
		}
		if (r < 0 || (uint64_t)r > n - fb->dl_got) {
			fb->dl_want = fb->dl_got = 0;
			if (r == FB_LINK_LOST || r == FB_EOF)
				return r;
			fb_resp(fb, "FAIL", "data transfer error");
			return 0;
		}
		empty = 0;
		fb->dl_got += (uint64_t)r;
		if (fb->p->idle)
			fb->p->idle(fb->p->ctx, fb);
	}
	fb->dl_len = n;
	fb->dl_want = fb->dl_got = 0;
	fb_resp(fb, "OKAY", "");
	return 0;
}

/* ---- storage commands ---- */

/* 1..16 hex digits */
static int fb_parse_hex64(const char *s, uint64_t *out, const char **end)
{
	uint64_t v = 0;
	int n = 0;

	for (;; s++) {
		char c = *s;
		int d;
		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			break;
		if (++n > 16)
			return 0;
		v = v << 4 | (uint64_t)d;
	}
	*out = v;
	*end = s;
	return n > 0;
}

static unsigned fb_dec(char *out, uint64_t v)
{
	char tmp[20];
	unsigned n = 0, o = 0;
	do
		tmp[n++] = (char)('0' + v % 10);
	while ((v /= 10) && n < 20);
	while (n)
		out[o++] = tmp[--n];
	out[o] = 0;
	return o;
}

/* "<prefix><n> MiB<suffix>" into line */
static void fb_line_mib(char *line, const char *prefix, uint64_t bytes, const char *suffix)
{
	unsigned n = 0;
	while (*prefix && n < 40)
		line[n++] = *prefix++;
	n += fb_dec(line + n, bytes >> 20);
	for (const char *m = " MiB"; *m;)
		line[n++] = *m++;
	while (*suffix && n < FB_PKT - 5)
		line[n++] = *suffix++;
	line[n] = 0;
}

static void fb_op_begin(struct fb *fb, int kind, const char *name, uint64_t total)
{
	fb->op_kind = kind;
	fb_copy(fb->op_name, name, sizeof fb->op_name);
	fb->op_done = fb->op_sub = 0;
	fb->op_total = total;
}

static void fb_op_end(struct fb *fb)
{
	fb->op_kind = FB_OP_NONE;
	fb->op_sub = 0;
}

struct fb_fl {
	struct fb *fb;
	const char *name;
};

static const char *fl_raw(void *c, uint64_t off, const uint8_t *data, uint64_t len)
{
	struct fb_fl *f = c;
	const char *e = f->fb->p->part_write(f->fb->p->ctx, f->name, off, data, len);

	f->fb->op_done += len;
	f->fb->op_sub = 0;
	f->fb->wr_bytes += len;
	if (f->fb->p->idle)
		f->fb->p->idle(f->fb->p->ctx, f->fb);
	return e;
}

static const char *fl_fill(void *c, uint64_t off, uint64_t len, uint32_t pat)
{
	struct fb_fl *f = c;
	const char *e = f->fb->p->part_fill(f->fb->p->ctx, f->name, off, len, pat);

	f->fb->op_done += len;
	f->fb->op_sub = 0;
	f->fb->wr_bytes += len;
	if (f->fb->p->idle)
		f->fb->p->idle(f->fb->p->ctx, f->fb);
	return e;
}

/* flash:<partition> of the downloaded raw or sparse image */
static void fb_flash(struct fb *fb, const char *name)
{
	const struct fb_platform *p = fb->p;
	struct sparse_stats st;
	uint64_t psize = 0, total;
	const char *e;
	int sparse;

	if (!fb_part_allowed(name)) {
		fb_resp(fb, "FAIL", FB_NOT_ALLOWED);
		return;
	}
	if (!p->part_info || !p->part_write || !p->part_fill || !p->flash_begin || !p->flash_end) {
		fb_resp(fb, "FAIL", "no storage");
		return;
	}
	if (!fb->dl_len) {
		fb_resp(fb, "FAIL", "no image downloaded");
		return;
	}
	if ((e = p->part_info(p->ctx, name, &psize))) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	sparse = sparse_is(p->dl_buf, fb->dl_len);
	if (sparse) {
		if ((e = sparse_apply(p->dl_buf, fb->dl_len, psize, 0, &st))) {
			fb_resp(fb, "FAIL", e);
			return;
		}
		total = st.raw + st.fill;
	} else {
		if (fb->dl_len > psize) {
			fb_resp(fb, "FAIL", "image is larger than the partition");
			return;
		}
		total = (fb->dl_len + 4095) & ~4095ULL;
		for (uint64_t i = fb->dl_len; i < total; i++)	/* pad the last block with zeros (buffer has slack) */
			p->dl_buf[i] = 0;
	}
	{
		char line[FB_PKT];
		if (sparse) {
			fb_line_mib(line, "sparse: write ", total, "");
			fb_info(fb, line);
		}
	}
	if ((e = p->flash_begin(p->ctx, name, p->dl_buf, fb->dl_len, total))) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	fb_op_begin(fb, FB_OP_FLASH, name, total);
	{
		struct fb_fl f = { fb, name };
		if (sparse) {
			struct sparse_ops ops = { &f, fl_raw, fl_fill };
			e = sparse_apply(p->dl_buf, fb->dl_len, psize, &ops, 0);
		} else {
			e = fl_raw(&f, 0, p->dl_buf, total);
		}
	}
	const char *e2 = p->flash_end(p->ctx, name, e == 0);
	fb_op_end(fb);
	if (e || e2)
		fb_resp(fb, "FAIL", e ? e : e2);
	else
		fb_resp(fb, "OKAY", "");
}

static void fb_erase(struct fb *fb, const char *name)
{
	const struct fb_platform *p = fb->p;
	uint64_t psize = 0;
	const char *e;

	if (!fb_part_allowed(name)) {
		fb_resp(fb, "FAIL", FB_NOT_ALLOWED);
		return;
	}
	if (!p->part_info || !p->part_erase) {
		fb_resp(fb, "FAIL", "no storage");
		return;
	}
	if ((e = p->part_info(p->ctx, name, &psize))) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	fb_op_begin(fb, FB_OP_ERASE, name, psize);
	e = p->part_erase(p->ctx, name);
	fb_op_end(fb);
	fb_resp(fb, e ? "FAIL" : "OKAY", e ? e : "");
}

/*
 * oem hash:<partition>:<offset>:<length>:<blocksize>   (hex; length 0 = to the end of the partition)
 * Stages 16 bytes per block (BLAKE2b-128 of the block, the last block may be shorter) at the start of the
 * download buffer (the downloaded image is lost) and answers OKAY; `upload` (fastboot get_staged FILE)
 * then returns them. Read-only.
 */
static void fb_oem_hash(struct fb *fb, const char *a)
{
	const struct fb_platform *p = fb->p;
	char name[16];
	uint64_t off, len, bs, psize = 0, nblk;
	const char *e, *end;
	unsigned n = 0;

	while (a[n] && a[n] != ':' && n < sizeof name - 1) {
		name[n] = a[n];
		n++;
	}
	name[n] = 0;
	if (a[n] != ':' || !fb_part_allowed(name)) {
		fb_resp(fb, "FAIL", a[n] == ':' ? FB_NOT_ALLOWED : "usage: oem hash:<part>:<off>:<len>:<bs> (hex)");
		return;
	}
	a += n + 1;
	if (!fb_parse_hex64(a, &off, &end) || *end != ':' || !fb_parse_hex64(end + 1, &len, &end) || *end != ':' ||
	    !fb_parse_hex64(end + 1, &bs, &end) || *end) {
		fb_resp(fb, "FAIL", "usage: oem hash:<part>:<off>:<len>:<bs> (hex)");
		return;
	}
	if (!p->part_info || !p->part_hash) {
		fb_resp(fb, "FAIL", "no storage");
		return;
	}
	if ((e = p->part_info(p->ctx, name, &psize))) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	if ((off & 4095) || off > psize) {
		fb_resp(fb, "FAIL", "bad offset");
		return;
	}
	if (!len)
		len = psize - off;
	len &= ~4095ULL;
	if (!len || len > psize - off) {
		fb_resp(fb, "FAIL", "bad length");
		return;
	}
	if (bs < 4096 || bs > (2u << 20) || (bs & (bs - 1))) {
		fb_resp(fb, "FAIL", "block size must be a power of two, 4 KiB..2 MiB");
		return;
	}
	nblk = (len + bs - 1) / bs;
	if (nblk * 16 > p->dl_max) {
		fb_resp(fb, "FAIL", "hash table does not fit the buffer: ask for less");
		return;
	}
	fb->dl_len = fb->staged_len = 0;	/* the table overwrites the download buffer */
	fb_op_begin(fb, FB_OP_HASH, name, len);
	e = p->part_hash(p->ctx, name, off, len, (uint32_t)bs, p->dl_buf);
	fb_op_end(fb);
	if (e) {
		fb_resp(fb, "FAIL", e);
		return;
	}
	fb->staged_len = nblk * 16;
	{
		char buf[24];
		buf[0] = 'n';
		buf[1] = '=';
		fb_hex(buf + 2, nblk, 1);
		fb_resp(fb, "OKAY", buf);
	}
}

/* upload: DATA<len>, the staged bytes, OKAY. Returns 0 or FB_LINK_LOST / FB_EOF. */
static int fb_upload(struct fb *fb)
{
	char buf[12];
	int r;

	if (!fb->staged_len || !fb->t->send_data) {
		fb_resp(fb, "FAIL", "no staged data");
		return 0;
	}
	fb_hex(buf, fb->staged_len, 8);
	if (fb_resp(fb, "DATA", buf) < 0)
		return FB_LINK_LOST;
	r = fb->t->send_data(fb->t->ctx, fb->p->dl_buf, fb->staged_len);
	if (r < 0)
		return r == FB_EOF ? FB_EOF : FB_LINK_LOST;
	fb_resp(fb, "OKAY", "");
	return 0;
}

static void fb_oem(struct fb *fb, const char *a)
{
	if (fb_starts(a, "hash:")) {
		fb_oem_hash(fb, a + 5);
	} else if (fb_starts(a, "verify:")) {
		int on = a[7] == '1' || fb_eq(a + 7, "on");
		fb->verify = on;
		if (fb->p->set_verify)
			fb->p->set_verify(fb->p->ctx, on);
		fb_resp(fb, "OKAY", on ? "verify on" : "verify off");
	} else if (fb_starts(a, "selftest:")) {
		const char *name = a + 9;
		const char *e = "no storage";
		if (!fb_part_allowed(name))
			e = FB_NOT_ALLOWED;
		else if (fb->p->part_selftest) {
			fb_op_begin(fb, FB_OP_HASH, name, 3ULL << 21);
			e = fb->p->part_selftest(fb->p->ctx, name);
			fb_op_end(fb);
		}
		fb_resp(fb, e ? "FAIL" : "OKAY", e ? e : "selftest passed");
	} else if (fb_starts(a, "ufsq:") && a[5] >= '1' && a[5] <= '8' && !a[6]) {
		if (fb->p->set_ufs_depth)
			fb->p->set_ufs_depth(fb->p->ctx, a[5] - '0');
		fb_resp(fb, "OKAY", "");
	} else if (fb_eq(a, "gpt")) {
		if (fb->p->gpt_info)
			fb->p->gpt_info(fb->p->ctx, fb);
		fb_resp(fb, "OKAY", "");
	} else {
		fb_resp(fb, "FAIL", "unknown oem command");
	}
}

enum fb_result fb_run(struct fb *fb)
{
	char cmd[FB_PKT + 1];

	for (;;) {
		int n = fb->t->recv_cmd(fb->t->ctx, cmd, FB_PKT);
		if (n == FB_EOF)
			return FB_R_EOF;
		if (n == FB_LINK_LOST) {
			fb_drop_session(fb);
			if (fb->p->idle)
				fb->p->idle(fb->p->ctx, fb);
			continue;
		}
		if (n <= 0) {
			if (fb->p->idle)
				fb->p->idle(fb->p->ctx, fb);
			continue;
		}
		cmd[n] = 0;
		fb_copy(fb->last_cmd, cmd, sizeof fb->last_cmd);
		fb->last_resp[0] = 0;
		fb->n_cmds++;

		int rc = 0;
		if (fb_starts(cmd, "getvar:")) {
			fb_getvar(fb, cmd + 7);
		} else if (fb_starts(cmd, "download:")) {
			rc = fb_download(fb, cmd + 9);
		} else if (fb_eq(cmd, "boot")) {
			const char *why = 0;
			if (!fb->dl_len)
				why = "no image downloaded";
			else if (fb->p->check_boot)
				why = fb->p->check_boot(fb->p->ctx, fb->p->dl_buf, fb->dl_len);
			if (why) {
				fb_resp(fb, "FAIL", why);
			} else {
				fb_resp(fb, "OKAY", "");
				if (fb->p->boot)
					fb->p->boot(fb->p->ctx, fb->p->dl_buf, fb->dl_len);
				fb_copy(fb->last_resp, "boot failed", sizeof fb->last_resp);
				return FB_R_BOOT;
			}
		} else if (fb_eq(cmd, "reboot") || fb_eq(cmd, "continue")) {
			int cont = fb_eq(cmd, "continue");
			fb_resp(fb, "OKAY", "");
			if (fb->p->reboot)
				fb->p->reboot(fb->p->ctx, 0);
			return cont ? FB_R_CONTINUE : FB_R_REBOOT;
		} else if (fb_eq(cmd, "reboot-bootloader")) {
			fb_resp(fb, "OKAY", "");
			if (fb->p->reboot)
				fb->p->reboot(fb->p->ctx, 1);
			return FB_R_REBOOT_BL;
		} else if (fb_starts(cmd, "flash:")) {
			fb_flash(fb, cmd + 6);
		} else if (fb_starts(cmd, "erase:")) {
			fb_erase(fb, cmd + 6);
		} else if (fb_starts(cmd, "oem ")) {
			fb_oem(fb, cmd + 4);
		} else if (fb_eq(cmd, "upload")) {
			rc = fb_upload(fb);
		} else if (fb_starts(cmd, "format") ||
			   fb_starts(cmd, "set_active") || fb_starts(cmd, "oem") || fb_starts(cmd, "flashing") ||
			   fb_starts(cmd, "create-logical") || fb_starts(cmd, "delete-logical") ||
			   fb_starts(cmd, "resize-logical") || fb_starts(cmd, "update-super") ||
			   fb_starts(cmd, "snapshot-update")) {
			fb_resp(fb, "FAIL", "not supported: only flash/erase of userdata, boot, logo");
		} else {
			fb_resp(fb, "FAIL", "unknown command");
		}
		if (rc == FB_EOF)
			return FB_R_EOF;
		if (rc == FB_LINK_LOST)
			fb_drop_session(fb);
		if (fb->p->idle)
			fb->p->idle(fb->p->ctx, fb);
	}
}

/* ---- images ---- */

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int magic8(const uint8_t *p, const char *m)
{
	for (int i = 0; i < 8; i++)
		if (p[i] != (uint8_t)m[i])
			return 0;
	return 1;
}

int fb_find_payload(const uint8_t *img, uint64_t len, uint64_t *off, uint64_t *size, const char **why)
{
	if (len >= 8 && magic8(img, "SWEETXNU")) {
		*off = 0;
		*size = len;
		return FB_IMG_SWEETXNU;
	}
	if (len < 8 || !magic8(img, "ANDROID!")) {
		*why = "not a boot.img or SWEETXNU payload";
		return 0;
	}
	if (len < 48) {
		*why = "boot.img header truncated";
		return 0;
	}
	uint32_t hv = le32(img + 40), ksz = le32(img + 8), rsz, page;
	if (hv >= 3) {			/* v3/v4: fixed 4096-byte pages */
		rsz = le32(img + 12);
		page = 4096;
	} else {			/* v0..v2 */
		rsz = le32(img + 16);
		page = le32(img + 36);
	}
	if (page < 2048 || page > 65536 || (page & (page - 1))) {
		*why = "boot.img bad page size";
		return 0;
	}
	if (!rsz) {
		*why = "boot.img has no ramdisk";
		return 0;
	}
	uint64_t rd_off = (uint64_t)page + (((uint64_t)ksz + page - 1) / page) * page;
	if (rd_off + rsz > len || rd_off + rsz < rd_off) {
		*why = "boot.img truncated";
		return 0;
	}
	if (rsz < 8 || !magic8(img + rd_off, "SWEETXNU")) {
		*why = "boot.img ramdisk is not SWEETXNU";
		return 0;
	}
	*off = rd_off;
	*size = rsz;
	return FB_IMG_BOOTIMG;
}
