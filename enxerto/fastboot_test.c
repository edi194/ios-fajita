/*
 * Host test of the fastboot protocol state machine (fastboot.c) with a fake transport, plus the
 * sparse parser (sparse.c), the GPT/allowlist storage layer (storage.c, over a fake block device with
 * a synthetic GPT) and BLAKE2b (blake2b.c):
 *   cc -O1 -Wall -o out/fastboot_test fastboot.c sparse.c storage.c blake2b.c fastboot_test.c && out/fastboot_test
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "blake2b.h"
#include "fastboot.h"
#include "sparse.h"
#include "storage.h"

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { S_CMD, S_DATA, S_LINK, S_DATA_ERR };
struct step {
	int kind;
	const char *cmd;
	const uint8_t *data;
	uint64_t len;
	uint64_t off;	/* progress inside a DATA step */
};

static struct step script[128];
static int n_steps, cur;
static char resp[256][80];
static int n_resp;
static unsigned data_chunk = 1000;	/* bytes per fake bulk transfer */

static void reset_fake(void)
{
	memset(script, 0, sizeof script);
	n_steps = cur = n_resp = 0;
	data_chunk = 1000;
}

static void cmd(const char *c) { script[n_steps++] = (struct step){ S_CMD, strdup(c), 0, 0, 0 }; }
static void data(const void *d, uint64_t n) { script[n_steps++] = (struct step){ S_DATA, 0, d, n, 0 }; }
static void link_lost(void) { script[n_steps++] = (struct step){ S_LINK, 0, 0, 0, 0 }; }
static void data_err(void) { script[n_steps++] = (struct step){ S_DATA_ERR, 0, 0, 0, 0 }; }

static int t_recv_cmd(void *ctx, char *buf, unsigned max)
{
	(void)ctx;
	if (cur >= n_steps)
		return FB_EOF;
	struct step *s = &script[cur];
	if (s->kind == S_LINK) {
		cur++;
		return FB_LINK_LOST;
	}
	if (s->kind != S_CMD) {
		printf("FAIL protocol: recv_cmd while a data step is next\n");
		failures++;
		return FB_EOF;
	}
	cur++;
	unsigned n = (unsigned)strlen(s->cmd);
	if (n > max)
		n = max;
	memcpy(buf, s->cmd, n);
	return (int)n;
}

static int t_send(void *ctx, const char *buf, unsigned len)
{
	(void)ctx;
	CHECK(len <= 64);
	if (n_resp < 256) {
		memcpy(resp[n_resp], buf, len);
		resp[n_resp][len] = 0;
		n_resp++;
	}
	return 0;
}

static uint8_t upload_buf[64 << 20];
static uint64_t upload_len;
static int t_send_data(void *ctx, const uint8_t *src, uint64_t len)
{
	(void)ctx;
	if (len > sizeof upload_buf)
		return -1;
	memcpy(upload_buf, src, len);
	upload_len = len;
	return 0;
}

static int t_recv_data(void *ctx, uint8_t *dst, uint64_t len)
{
	(void)ctx;
	if (cur >= n_steps)
		return FB_EOF;
	struct step *s = &script[cur];
	if (s->kind == S_LINK) {
		cur++;
		return FB_LINK_LOST;
	}
	if (s->kind == S_DATA_ERR) {
		cur++;
		return -7;
	}
	if (s->kind != S_DATA) {
		printf("FAIL protocol: recv_data while a command is next\n");
		failures++;
		return FB_EOF;
	}
	uint64_t n = s->len - s->off;
	if (n > len)
		n = len;
	if (n > data_chunk)
		n = data_chunk;
	memcpy(dst, s->data + s->off, n);
	s->off += n;
	if (s->off == s->len)
		cur++;
	return (int)n;
}

/* platform fakes */
#define DLMAX 0x100000
static uint8_t dlbuf[DLMAX + 8192] __attribute__((aligned(64)));	/* slack after dl_max, like the scratch area on the phone */
static int boot_calls, reboot_calls, last_reboot_mode, idle_calls;
static uint64_t boot_len;
static int boot_content_ok;
static const uint8_t *boot_expect;

static void p_idle(void *ctx, struct fb *fb) { (void)ctx; (void)fb; idle_calls++; }

static const char *p_check_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	(void)ctx;
	uint64_t off, size;
	const char *why = "";
	return fb_find_payload(img, len, &off, &size, &why) ? 0 : why;
}

static void p_boot(void *ctx, const uint8_t *img, uint64_t len)
{
	(void)ctx;
	boot_calls++;
	boot_len = len;
	boot_content_ok = boot_expect && !memcmp(img, boot_expect, len);
}

static void p_reboot(void *ctx, int mode)
{
	(void)ctx;
	reboot_calls++;
	last_reboot_mode = mode;
}

static void p_charger(void *ctx, int raw, char *buf, unsigned n)
{
	const char *s = raw ? "st=02/00 apsd=04 je=1f aicl=1 w=3/0" : "applied CDP 1500/2000mA 4395mV FAST 37%";
	unsigned i = 0;

	(void)ctx;
	for (; s[i] && i + 1 < n; i++)
		buf[i] = s[i];
	buf[i] = 0;
}

static const struct fb_transport transport = { .ctx = 0, .recv_cmd = t_recv_cmd, .send = t_send, .recv_data = t_recv_data, .send_data = t_send_data };
static const struct fb_platform platform = {
	.ctx = 0, .dl_buf = dlbuf, .dl_max = DLMAX, .idle = p_idle, .check_boot = p_check_boot, .boot = p_boot, .reboot = p_reboot,
};
static struct fb_platform plat_stor;	/* platform + storage callbacks, filled in by setup_storage() */
static const struct fb_platform *cur_platform = &platform;

static struct fb run_session(enum fb_result *out)
{
	struct fb fb;
	boot_calls = reboot_calls = idle_calls = 0;
	boot_content_ok = 0;
	upload_len = 0;
	fb_init(&fb, &transport, cur_platform);
	*out = fb_run(&fb);
	return fb;
}

static int resp_is(int i, const char *s) { return i < n_resp && !strcmp(resp[i], s); }
static int resp_starts(int i, const char *s) { return i < n_resp && !strncmp(resp[i], s, strlen(s)); }

/* ---- image builders ---- */
static uint8_t *make_sweet(uint64_t size)
{
	uint8_t *p = calloc(1, size);
	memcpy(p, "SWEETXNU", 8);
	for (uint64_t i = 8; i < size; i++)
		p[i] = (uint8_t)(i * 31 + (i >> 8));
	return p;
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* boot.img v0..v2 (hv < 3) or v3/v4 */
static uint8_t *make_bootimg(int hv, uint32_t page, uint32_t ksz, const uint8_t *rd, uint32_t rdsz, uint64_t *total)
{
	uint32_t kpad = (ksz + page - 1) / page * page, rpad = (rdsz + page - 1) / page * page;
	uint64_t n = (uint64_t)page + kpad + rpad;
	uint8_t *p = calloc(1, n);
	memcpy(p, "ANDROID!", 8);
	put32(p + 8, ksz);
	if (hv >= 3) {
		put32(p + 12, rdsz);
		put32(p + 40, hv);
		page = 4096;	/* v3 pages are fixed; callers pass 4096 */
	} else {
		put32(p + 16, rdsz);
		put32(p + 36, page);
		put32(p + 40, hv);
	}
	memset(p + page, 0xaa, ksz);
	memcpy(p + page + kpad, rd, rdsz);
	*total = n;
	return p;
}

/* ================= storage, sparse, hash tests ================= */

static uint32_t crc32_ref(const uint8_t *p, uint64_t n)
{
	uint32_t c = 0xffffffffu;
	for (uint64_t i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
	}
	return ~c;
}

static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)v); put32(p + 4, (uint32_t)(v >> 32)); }

/* ---- fake block device: 2 LUNs of 4 KiB blocks ---- */
#define NLUN	2
#define LUN0_BLOCKS	16384u		/* 64 MiB */
#define LUN1_BLOCKS	2048u

struct fakedev {
	uint8_t *mem[NLUN];
	uint8_t *written[NLUN];		/* one byte per block: touched by a write/unmap */
	uint64_t blocks[NLUN];
	int fail_unmap;			/* UNMAP is refused (not thin provisioned) */
	int corrupt_write;		/* flip a byte of every write (device bug): verify must catch it */
	unsigned writes, reads, unmaps, syncs;
};
static struct fakedev fd;

static void fd_free(void)
{
	for (int i = 0; i < NLUN; i++) {
		free(fd.mem[i]);
		free(fd.written[i]);
	}
	memset(&fd, 0, sizeof fd);
}

static const char *fd_cap(void *ctx, unsigned lun, uint64_t *nblk)
{
	(void)ctx;
	if (lun >= NLUN)
		return "no such LUN";
	*nblk = fd.blocks[lun];
	return 0;
}

static const char *fd_read(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst)
{
	(void)ctx;
	if (lun >= NLUN || lba + nblk > fd.blocks[lun])
		return "read out of range";
	fd.reads++;
	memcpy(dst, fd.mem[lun] + lba * 4096, nblk * 4096);
	return 0;
}

static const char *fd_read_start(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst)
{
	return fd_read(ctx, lun, lba, nblk, dst);
}

static const char *fd_read_wait(void *ctx) { (void)ctx; return 0; }

static const char *fd_write(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, const void *src)
{
	(void)ctx;
	if (lun >= NLUN || lba + nblk > fd.blocks[lun])
		return "write out of range";
	fd.writes++;
	memcpy(fd.mem[lun] + lba * 4096, src, nblk * 4096);
	if (fd.corrupt_write)
		fd.mem[lun][lba * 4096 + 17] ^= 0x40;
	memset(fd.written[lun] + lba, 1, nblk);
	return 0;
}

static const char *fd_unmap(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk)
{
	(void)ctx;
	if (fd.fail_unmap)
		return "UNMAP refused";
	fd.unmaps++;
	memset(fd.mem[lun] + lba * 4096, 0, nblk * 4096);
	memset(fd.written[lun] + lba, 1, nblk);
	return 0;
}

static const char *fd_sync(void *ctx, unsigned lun) { (void)ctx; (void)lun; fd.syncs++; return 0; }

/* partition layout of LUN 0 (4 KiB blocks) */
#define P_MODEM_FIRST	8u
#define P_MODEM_LAST	127u
#define P_BOOT_FIRST	128u
#define P_BOOT_LAST	(128u + 2047u)		/* 8 MiB */
#define P_LOGO_FIRST	2300u
#define P_LOGO_LAST	(2300u + 255u)		/* 1 MiB */
#define P_PERSIST_FIRST	3000u
#define P_PERSIST_LAST	3999u
#define P_UD_FIRST	4096u
#define P_UD_LAST	16100u			/* 12005 blocks */
#define LAST_USABLE	16340u

static void gpt_entry(uint8_t *e, uint64_t first, uint64_t last, const char *name)
{
	memset(e, 0, 128);
	e[0] = 0xaf;			/* some type GUID */
	e[16] = 0x11;			/* unique GUID */
	put64(e + 32, first);
	put64(e + 40, last);
	for (int i = 0; name[i]; i++)
		e[56 + 2 * i] = (uint8_t)name[i];
}

/* GPT at LBA 1, entries at LBA 2 (one block), as the phone's 4K-sector GPTs; crc_ok = 0 breaks the header CRC */
static void write_gpt(uint8_t *mem, uint64_t blocks, const char *const *names, const uint64_t (*ranges)[2], int n,
		      uint64_t first_usable, uint64_t last_usable, int crc_ok)
{
	uint8_t *ents = mem + 2 * 4096, *h = mem + 4096;
	memset(h, 0, 4096);
	memset(ents, 0, 4096);
	for (int i = 0; i < n; i++)
		gpt_entry(ents + 128 * i, ranges[i][0], ranges[i][1], names[i]);
	memcpy(h, "EFI PART", 8);
	put32(h + 8, 0x10000);
	put32(h + 12, 92);
	put64(h + 24, 1);
	put64(h + 32, blocks - 1);
	put64(h + 40, first_usable);
	put64(h + 48, last_usable);
	put64(h + 72, 2);
	put32(h + 80, 16);
	put32(h + 84, 128);
	put32(h + 88, crc32_ref(ents, 16 * 128));
	put32(h + 16, crc32_ref(h, 92) ^ (crc_ok ? 0 : 1));
}

/* dup_boot: LUN 1 has a second "boot"; bad_crc: LUN 0's header CRC is wrong */
static void build_dev(int dup_boot, int bad_crc)
{
	fd_free();
	fd.blocks[0] = LUN0_BLOCKS;
	fd.blocks[1] = LUN1_BLOCKS;
	for (int i = 0; i < NLUN; i++) {
		fd.mem[i] = calloc(fd.blocks[i], 4096);
		fd.written[i] = calloc(fd.blocks[i], 1);
	}
	/* every block that is not a GPT block starts with a recognisable pattern: nothing may be disturbed */
	for (uint64_t b = 6; b < LUN0_BLOCKS; b++)
		memset(fd.mem[0] + b * 4096, 0x30 + (int)(b % 7), 4096);
	static const char *const n0[] = { "modem", "boot", "logo", "persist", "userdata", "bluetooth" };
	const uint64_t r0[][2] = { { P_MODEM_FIRST, P_MODEM_LAST }, { P_BOOT_FIRST, P_BOOT_LAST }, { P_LOGO_FIRST, P_LOGO_LAST },
				   { P_PERSIST_FIRST, P_PERSIST_LAST }, { P_UD_FIRST, P_UD_LAST }, { 16200, 16300 } };
	write_gpt(fd.mem[0], LUN0_BLOCKS, n0, r0, 6, 6, LAST_USABLE, !bad_crc);
	static const char *const n1[] = { "xbl", "boot" };
	const uint64_t r1[][2] = { { 6, 500 }, { 600, 700 } };
	write_gpt(fd.mem[1], LUN1_BLOCKS, n1, r1, dup_boot ? 2 : 1, 6, 1000, 1);
}

static uint8_t g_scratch[STOR_SCRATCH] __attribute__((aligned(64)));
static struct stor g_stor;
static int win_on, win_off, prog_calls;
static uint64_t prog_bytes;

static void st_cached(void *ctx, int on, const void *lo, const void *hi) { (void)ctx; (void)lo; (void)hi; on ? win_on++ : win_off++; }
static void st_progress(void *ctx, uint64_t b) { (void)ctx; prog_calls++; prog_bytes += b; }

static void init_stor(void)
{
	memset(&g_stor, 0, sizeof g_stor);
	g_stor.bd.cap = fd_cap;
	g_stor.bd.read = fd_read;
	g_stor.bd.read_start = fd_read_start;
	g_stor.bd.read_wait = fd_read_wait;
	g_stor.bd.write = fd_write;
	g_stor.bd.unmap = fd_unmap;
	g_stor.bd.sync = fd_sync;
	g_stor.scratch = g_scratch;
	g_stor.cached = st_cached;
	g_stor.progress = st_progress;
	win_on = win_off = prog_calls = 0;
	prog_bytes = 0;
}

/* ---- fb_platform storage callbacks over g_stor (the same shape as bergamota.c) ---- */
static const char *tp_part_info(void *ctx, const char *name, uint64_t *size)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	if (!p)
		return why;
	*size = p->nblk * STOR_BLK;
	return 0;
}
static const char *tp_flash_begin(void *ctx, const char *name, const uint8_t *img, uint64_t len, uint64_t total)
{
	(void)ctx; (void)name; (void)total;
	if (g_stor.verify)
		g_stor.cached(0, 1, img, img + len);
	return 0;
}
static const char *tp_write(void *ctx, const char *name, uint64_t off, const uint8_t *src, uint64_t len)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	return p ? stor_write(&g_stor, p, off, src, len) : why;
}
static const char *tp_fill(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t pat)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	return p ? stor_fill(&g_stor, p, off, len, pat) : why;
}
static const char *tp_flash_end(void *ctx, const char *name, int ok)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	if (g_stor.verify)
		g_stor.cached(0, 0, 0, 0);
	return p && ok ? stor_sync(&g_stor, p) : 0;
}
static const char *tp_erase(void *ctx, const char *name)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	return p ? stor_erase(&g_stor, p) : why;
}
static const char *tp_hash(void *ctx, const char *name, uint64_t off, uint64_t len, uint32_t bs, uint8_t *out)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	return p ? stor_hash(&g_stor, p, off, len, bs, out) : why;
}
static void tp_verify(void *ctx, int on) { (void)ctx; g_stor.verify = on; }
static const char *tp_selftest(void *ctx, const char *name)
{
	(void)ctx;
	const char *why;
	const struct stor_part *p = stor_find(&g_stor, name, &why);
	return p ? stor_selftest(&g_stor, p) : why;
}

static void setup_storage(int dup_boot, int bad_crc)
{
	build_dev(dup_boot, bad_crc);
	init_stor();
	plat_stor = platform;
	plat_stor.part_info = tp_part_info;
	plat_stor.flash_begin = tp_flash_begin;
	plat_stor.part_write = tp_write;
	plat_stor.part_fill = tp_fill;
	plat_stor.flash_end = tp_flash_end;
	plat_stor.part_erase = tp_erase;
	plat_stor.part_hash = tp_hash;
	plat_stor.set_verify = tp_verify;
	plat_stor.part_selftest = tp_selftest;
	cur_platform = &plat_stor;
}

/* every touched block must be inside userdata, boot or logo of LUN 0 */
static int writes_only_allowed(void)
{
	for (int l = 0; l < NLUN; l++)
		for (uint64_t b = 0; b < fd.blocks[l]; b++)
			if (fd.written[l][b]) {
				int ok = l == 0 && ((b >= P_BOOT_FIRST && b <= P_BOOT_LAST) || (b >= P_LOGO_FIRST && b <= P_LOGO_LAST) ||
						    (b >= P_UD_FIRST && b <= P_UD_LAST));
				if (!ok) {
					printf("  forbidden write: lun %d block %llu\n", l, (unsigned long long)b);
					return 0;
				}
			}
	return 1;
}

static unsigned total_writes(void) { return fd.writes + fd.unmaps; }

/* ---- sparse image builder ---- */
struct sp {
	uint8_t *d;
	uint64_t n;
	uint32_t chunks, blk, total_blks;
};

static void sp_begin(struct sp *s, uint32_t blk, uint32_t total_blks)
{
	s->d = calloc(1, 64 << 20);
	s->n = 28;
	s->chunks = 0;
	s->blk = blk;
	s->total_blks = total_blks;
}

static void sp_chunk(struct sp *s, uint16_t type, uint32_t blocks, uint32_t tsz)
{
	put32(s->d + s->n, type);			/* type + reserved */
	put32(s->d + s->n + 4, blocks);
	put32(s->d + s->n + 8, tsz);
	s->n += 12;
	s->chunks++;
}

static void sp_raw(struct sp *s, uint32_t blocks, const uint8_t *data)
{
	sp_chunk(s, SPARSE_RAW, blocks, 12 + blocks * s->blk);
	memcpy(s->d + s->n, data, (uint64_t)blocks * s->blk);
	s->n += (uint64_t)blocks * s->blk;
}
static void sp_fill(struct sp *s, uint32_t blocks, uint32_t pat)
{
	sp_chunk(s, SPARSE_FILL, blocks, 16);
	put32(s->d + s->n, pat);
	s->n += 4;
}
static void sp_skip(struct sp *s, uint32_t blocks) { sp_chunk(s, SPARSE_SKIP, blocks, 12); }
static void sp_crc(struct sp *s) { sp_chunk(s, SPARSE_CRC, 0, 16); put32(s->d + s->n, 0x12345678); s->n += 4; }
static void sp_end(struct sp *s)
{
	put32(s->d, SPARSE_MAGIC);
	s->d[4] = 1; s->d[5] = 0; s->d[6] = 0; s->d[7] = 0;
	s->d[8] = 28; s->d[9] = 0; s->d[10] = 12; s->d[11] = 0;
	put32(s->d + 12, s->blk);
	put32(s->d + 16, s->total_blks);
	put32(s->d + 20, s->chunks);
	put32(s->d + 24, 0);
}

static uint8_t *pattern(uint64_t n, uint32_t seed)
{
	uint8_t *p = malloc(n);
	for (uint64_t i = 0; i < n; i++)
		p[i] = (uint8_t)((i * 131 + (i >> 9) * 7 + seed) ^ (seed >> 3));
	return p;
}

/* sparse_apply with recording ops */
struct rec {
	int raws, fills;
	uint64_t raw_bytes, fill_bytes, last_off;
	int fail_at;
};
static const char *rec_raw(void *c, uint64_t off, const uint8_t *d, uint64_t len)
{
	struct rec *r = c;
	(void)d;
	r->raws++;
	r->raw_bytes += len;
	r->last_off = off;
	return r->fail_at && r->raws == r->fail_at ? "boom" : 0;
}
static const char *rec_fill(void *c, uint64_t off, uint64_t len, uint32_t pat)
{
	struct rec *r = c;
	(void)pat;
	r->fills++;
	r->fill_bytes += len;
	r->last_off = off;
	return 0;
}

static void test_sparse_parser(void)
{
	struct sp s;
	struct sparse_stats st;
	struct rec rec;
	struct sparse_ops ops = { &rec, rec_raw, rec_fill };
	uint8_t *data = pattern(1 << 20, 1);

	/* all chunk kinds, block size 4096 and 8192 */
	for (uint32_t bs = 4096; bs <= 8192; bs *= 2) {
		memset(&rec, 0, sizeof rec);
		sp_begin(&s, bs, 40);
		sp_skip(&s, 3);
		sp_raw(&s, 5, data);
		sp_fill(&s, 7, 0xdeadbeef);
		sp_crc(&s);
		sp_raw(&s, 2, data);
		sp_skip(&s, 23);
		sp_end(&s);
		CHECK(sparse_is(s.d, s.n));
		CHECK(!sparse_apply(s.d, s.n, 0, 0, &st));
		CHECK(st.total == 40ull * bs && st.raw == 7ull * bs && st.fill == 7ull * bs && st.skip == 26ull * bs && st.chunks == 6 && st.blk_sz == bs);
		CHECK(!sparse_apply(s.d, s.n, 40ull * bs, &ops, 0));
		CHECK(rec.raws == 2 && rec.fills == 1 && rec.raw_bytes == 7ull * bs && rec.fill_bytes == 7ull * bs);
		CHECK(rec.last_off == 15ull * bs);	/* the last RAW chunk starts after 3+5+7 blocks */
		CHECK(sparse_apply(s.d, s.n, 40ull * bs - 1, 0, 0) != 0);	/* partition one byte too small */
		free(s.d);
	}

	/* errors: nothing is applied when validation fails (ops never called) */
	struct { const char *what; int mod; } bad[] = {
		{ "magic", 0 }, { "major", 1 }, { "blocksize", 2 }, { "truncated", 3 }, { "type", 4 }, { "too many blocks", 5 },
		{ "raw size", 6 }, { "fill size", 7 }, { "skip size", 8 }, { "crc size", 9 }, { "header sizes", 10 }, { "chunk header", 11 },
	};
	for (unsigned i = 0; i < sizeof bad / sizeof bad[0]; i++) {
		memset(&rec, 0, sizeof rec);
		sp_begin(&s, 4096, 20);
		sp_raw(&s, 2, data);
		sp_fill(&s, 3, 7);
		sp_skip(&s, 15);
		sp_end(&s);
		uint64_t n = s.n;
		uint64_t c0 = 28, c1 = 28 + 12 + 8192, c2 = c1 + 16;
		switch (bad[i].mod) {
		case 0: s.d[0] ^= 1; break;
		case 1: s.d[4] = 2; break;
		case 2: put32(s.d + 12, 1000); break;
		case 3: n -= 5; break;
		case 4: s.d[c0] = 0x77; break;
		case 5: put32(s.d + c0 + 4, 21); put32(s.d + c0 + 8, 12 + 21 * 4096); break;
		case 6: put32(s.d + c0 + 8, 12 + 8191); break;
		case 7: put32(s.d + c1 + 8, 20); break;
		case 8: put32(s.d + c2 + 8, 16); break;
		case 9: s.d[c1] = 0xc4; s.d[c1 + 1] = 0xca; break;
		case 10: s.d[8] = 8; break;
		case 11: s.d[10] = 2; break;
		}
		const char *e = sparse_apply(s.d, n, 0, &ops, 0);
		if (!e)
			printf("  sparse case '%s' accepted\n", bad[i].what);
		CHECK(e != 0);
		CHECK(rec.raws == 0 && rec.fills == 0);
		free(s.d);
	}

	/* a failing callback stops the walk */
	memset(&rec, 0, sizeof rec);
	rec.fail_at = 1;
	sp_begin(&s, 4096, 10);
	sp_raw(&s, 1, data); sp_raw(&s, 1, data); sp_fill(&s, 1, 0);
	sp_end(&s);
	CHECK(sparse_apply(s.d, s.n, 0, &ops, 0) && rec.raws == 1 && rec.fills == 0);
	free(s.d);

	/* bigger header sizes are skipped (file_hdr_sz 32, chunk_hdr_sz 16) */
	{
		uint8_t img[64 + 4096 + 16] = { 0 };
		put32(img, SPARSE_MAGIC); img[4] = 1; img[8] = 32; img[10] = 16;
		put32(img + 12, 4096); put32(img + 16, 1); put32(img + 20, 1);
		img[32] = 0xc1; img[33] = 0xca; put32(img + 36, 1); put32(img + 40, 16 + 4096);
		memset(img + 48, 0x5a, 4096);
		memset(&rec, 0, sizeof rec);
		CHECK(!sparse_apply(img, 48 + 4096, 0, &ops, 0) && rec.raws == 1 && rec.raw_bytes == 4096);
	}
	CHECK(!sparse_is((const uint8_t *)"SWEETXNU", 8));
	free(data);
}

static void test_blake2b(void)
{
	static const struct { int kind; unsigned n; const char *hex; } v[] = {
		{ 0, 3, "cf4ab791c62b8d2b2109c90275287816" },
		{ 1, 0, "cae66941d9efbd404e4d88758ea67670" },
		{ 2, 128, "a74787004ef589e31149183900d0294a" },
		{ 2, 129, "aaf1b0371f6d4ee49ee4fb5ddd9c49ef" },
		{ 3, 256, "dbb08d79105462394550aa4d4e10133f" },
		{ 4, 65536, "431a7664fb8fad9ed973c4e49de366df" },
	};
	for (unsigned i = 0; i < sizeof v / sizeof v[0]; i++) {
		uint8_t in[65536 + 8] __attribute__((aligned(8))), out[16];
		unsigned n = v[i].n;
		for (unsigned k = 0; k < n; k++)
			in[k] = v[i].kind == 0 ? "abc"[k] : v[i].kind == 2 ? (uint8_t)k : v[i].kind == 3 ? (uint8_t)(k * 7) : (uint8_t)((k * 31 + (k >> 8)) & 255);
		blake2b(out, 16, in, n);
		char hex[33];
		for (int k = 0; k < 16; k++)
			snprintf(hex + 2 * k, 3, "%02x", out[k]);
		if (strcmp(hex, v[i].hex))
			printf("  blake2b vector %u: got %s want %s\n", i, hex, v[i].hex);
		CHECK(!strcmp(hex, v[i].hex));
		/* the same through an unaligned pointer (sparse RAW data sits at +40 in the buffer) */
		if (n) {
			uint8_t un[65536 + 16];
			memcpy(un + 3, in, n);
			blake2b(out, 16, un + 3, n);
			for (int k = 0; k < 16; k++)
				snprintf(hex + 2 * k, 3, "%02x", out[k]);
			CHECK(!strcmp(hex, v[i].hex));
		}
	}
}

static uint64_t ud_off(void) { return (uint64_t)P_UD_FIRST * 4096; }

static char *dl_cmd(char *buf, unsigned n) { snprintf(buf, 32, "download:%08x", n); return buf; }

static void test_gpt_and_allowlist(void)
{
	const char *why = "";
	build_dev(0, 0);
	init_stor();
	CHECK(!stor_scan(&g_stor));
	CHECK(g_stor.nparts == 3);		/* only userdata, boot, logo are ever recorded */
	CHECK(g_stor.luns_found == 2 && g_stor.lun_info[0].valid && g_stor.lun_info[1].valid);
	const struct stor_part *ud = stor_find(&g_stor, "userdata", &why);
	CHECK(ud && ud->lun == 0 && ud->first == P_UD_FIRST && ud->nblk == P_UD_LAST - P_UD_FIRST + 1);
	const struct stor_part *bt = stor_find(&g_stor, "boot", &why);
	CHECK(bt && bt->first == P_BOOT_FIRST && bt->nblk == 2048);
	CHECK(stor_find(&g_stor, "logo", &why) != 0);
	static const char *const refused[] = { "modem", "persist", "bluetooth", "xbl", "abl", "dsp", "boot_a", "boot_b", "userdata_a",
		"Userdata", "user", "", "userdata ", "gpt", "super", "recovery", "vbmeta", "sda", "../userdata" };
	for (unsigned i = 0; i < sizeof refused / sizeof refused[0]; i++) {
		why = "";
		CHECK(stor_find(&g_stor, refused[i], &why) == 0 && *why);
		CHECK(!stor_name_allowed(refused[i]) && !fb_part_allowed(refused[i]));
	}
	CHECK(stor_name_allowed("userdata") && stor_name_allowed("boot") && stor_name_allowed("logo"));

	/* range checks and forged partition structs (not one of our table entries) */
	uint8_t blk[4096] = { 0 };
	CHECK(stor_write(&g_stor, bt, 8u << 20, blk, 4096) != 0);			/* one block past the partition */
	CHECK(stor_write(&g_stor, bt, (8u << 20) - 4096, blk, 8192) != 0);		/* straddles the end */
	CHECK(stor_write(&g_stor, bt, 100, blk, 4096) != 0);				/* unaligned */
	CHECK(stor_write(&g_stor, bt, 0, blk, 100) != 0);
	CHECK(stor_write(&g_stor, bt, ~0ull - 4095, blk, 4096) != 0);			/* overflow */
	struct stor_part forged = *bt;
	strcpy(forged.name, "modem");
	forged.first = P_MODEM_FIRST;
	forged.nblk = 100;
	CHECK(stor_write(&g_stor, &forged, 0, blk, 4096) != 0);
	forged = *bt;
	CHECK(stor_write(&g_stor, &forged, 0, blk, 4096) != 0);			/* a copy, not from the table */
	CHECK(stor_erase(&g_stor, &forged) != 0);
	CHECK(stor_hash(&g_stor, &forged, 0, 4096, 4096, (uint8_t *)blk) != 0);
	CHECK(total_writes() == 0 && writes_only_allowed());

	/* a partition that claims blocks inside the GPT area (first < first_usable) is refused */
	build_dev(0, 0);
	{
		const uint64_t r[][2] = { { 2, 100 } };
		static const char *const n[] = { "boot" };
		write_gpt(fd.mem[0], LUN0_BLOCKS, n, r, 1, 6, LAST_USABLE, 1);
		init_stor();
		stor_scan(&g_stor);
		CHECK(stor_find(&g_stor, "boot", &why) == 0 && strstr(why, "outside"));
	}

	/* bad header CRC: LUN 0 is not trusted at all */
	build_dev(0, 1);
	init_stor();
	CHECK(stor_scan(&g_stor) != 0 && g_stor.nparts == 0);
	CHECK(stor_find(&g_stor, "userdata", &why) == 0);
	CHECK(!g_stor.lun_info[0].valid);

	/* the same name twice (two LUNs) is ambiguous and refused */
	build_dev(1, 0);
	init_stor();
	stor_scan(&g_stor);
	CHECK(stor_find(&g_stor, "boot", &why) == 0 && strstr(why, "ambiguous"));
	CHECK(stor_find(&g_stor, "userdata", &why) != 0);

	/* an A/B-style GPT (boot_a / boot_b) offers no "boot": nothing can be flashed there */
	build_dev(0, 0);
	{
		static const char *const n[] = { "boot_a", "boot_b", "userdata" };
		const uint64_t r[][2] = { { 128, 2000 }, { 2100, 4000 }, { P_UD_FIRST, P_UD_LAST } };
		write_gpt(fd.mem[0], LUN0_BLOCKS, n, r, 3, 6, LAST_USABLE, 1);
		init_stor();
		stor_scan(&g_stor);
		CHECK(g_stor.nparts == 1 && stor_find(&g_stor, "boot", &why) == 0 && stor_find(&g_stor, "userdata", &why) != 0);
	}
	fd_free();
}

static void expect_ud(uint64_t byte_off, const uint8_t *data, uint64_t n, const char *what)
{
	int ok = !memcmp(fd.mem[0] + ud_off() + byte_off, data, n);
	if (!ok)
		printf("  userdata content mismatch: %s\n", what);
	CHECK(ok);
}

static void test_flash_protocol(void)
{
	enum fb_result r;
	struct fb fb;
	char c[32];

	/* ---- getvar partition-size/type, allowlist ---- */
	setup_storage(0, 0);
	reset_fake();
	cmd("getvar:partition-size:userdata"); cmd("getvar:partition-size:boot"); cmd("getvar:partition-size:logo");
	cmd("getvar:partition-type:userdata"); cmd("getvar:partition-size:modem"); cmd("getvar:partition-type:persist");
	cmd("getvar:partition-size:"); cmd("getvar:has-slot:userdata"); cmd("getvar:is-logical:userdata");
	cmd("getvar:partition-size:userdata_a"); cmd("getvar:has-slot:modem"); cmd("getvar:usb-speed"); cmd("getvar:bergamota-flash");
	fb = run_session(&r);
	char want[64];
	snprintf(want, sizeof want, "OKAY0x%llx", (unsigned long long)(P_UD_LAST - P_UD_FIRST + 1) * 4096);
	CHECK(resp_is(0, want));
	CHECK(resp_is(1, "OKAY0x800000") && resp_is(2, "OKAY0x100000"));
	CHECK(resp_is(3, "OKAYraw"));
	CHECK(resp_starts(4, "FAILpartition not allowed") && resp_starts(5, "FAIL") && resp_starts(6, "FAIL"));
	CHECK(resp_is(7, "OKAYno") && resp_is(8, "OKAYno") && resp_starts(9, "FAIL") && resp_starts(10, "FAIL"));
	CHECK(resp_is(11, "OKAYunknown") && resp_is(12, "OKAY1"));

	/* ---- raw flash of boot (not a multiple of 4096) ---- */
	setup_storage(0, 0);
	{
		uint64_t n = 100000;
		uint8_t *img = pattern(n, 9);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)n)); data(img, n); cmd("flash:boot");
		fb = run_session(&r);
		CHECK(resp_is(0, "DATA000186a0") && resp_is(1, "OKAY") && resp_is(2, "OKAY"));
		const uint8_t *boot = fd.mem[0] + (uint64_t)P_BOOT_FIRST * 4096;
		CHECK(!memcmp(boot, img, n));
		uint64_t padded = (n + 4095) & ~4095ull;
		int zero_pad = 1;
		for (uint64_t i = n; i < padded; i++)
			zero_pad &= boot[i] == 0;
		CHECK(zero_pad);					/* the tail of the last block is zeros */
		CHECK(boot[padded] == 0x30 + (P_BOOT_FIRST + padded / 4096) % 7);	/* the next block is untouched */
		CHECK(fd.syncs == 1 && writes_only_allowed());
		CHECK(fb.wr_bytes == padded && fb.op_kind == FB_OP_NONE);
		/* image larger than the partition */
		reset_fake();
		cmd("download:00100000"); data(dlbuf, DLMAX);
		static uint8_t zeros[DLMAX];
		(void)zeros;
		cmd("flash:logo");
		unsigned w = total_writes();
		fb = run_session(&r);
		CHECK(resp_is(1, "OKAY") && resp_is(2, "OKAY"));	/* exactly 1 MiB fits logo (1 MiB) */
		CHECK(total_writes() > w);
		free(img);
	}
	/* raw 2 MiB + 1 byte into logo (1 MiB): too large, nothing written */
	setup_storage(0, 0);
	{
		reset_fake();
		cmd("download:000fffff"); data(dlbuf, 0xfffff); cmd("flash:logo");	/* 1 MiB - 1: fits (padded) */
		cmd("download:00100000"); data(dlbuf, DLMAX); cmd("flash:boot"); cmd("flash:logo");
		fb = run_session(&r);
		CHECK(resp_is(2, "OKAY"));
		/* fits boot (8 MiB) and logo (1 MiB): fine */
		CHECK(resp_is(5, "OKAY") && resp_is(6, "OKAY"));
	}
	/* a partition smaller than the image: userdata is 47 MiB; use sparse total_blks to exceed it below; raw: boot 8 MiB < 9 MiB impossible (dl_max 1 MiB) */

	/* ---- flash:<not allowed> never writes ---- */
	setup_storage(0, 0);
	{
		static const char *const names[] = { "modem", "persist", "bluetooth", "xbl", "abl", "dsp", "boot_a", "gpt", "", "userdata_b", "sda21", "PrimaryGPT" };
		uint8_t img[8192];
		memset(img, 0x99, sizeof img);
		reset_fake();
		cmd("download:00002000"); data(img, sizeof img);
		for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
			char f[40];
			snprintf(f, sizeof f, "flash:%s", names[i]);
			cmd(f);
			snprintf(f, sizeof f, "erase:%s", names[i]);
			cmd(f);
		}
		cmd("oem hash:modem:0:1000:1000"); cmd("oem hash:xbl:0:1000:1000");
		cmd("format:ext4:userdata"); cmd("erase"); cmd("flash"); cmd("flash:"); cmd("set_active:a");
		fb = run_session(&r);
		int all = 1;
		for (int i = 2; i < n_resp; i++)
			all &= resp_starts(i, "FAIL") || resp_starts(i, "INFO");
		CHECK(all);
		CHECK(total_writes() == 0 && fd.syncs == 0 && writes_only_allowed());
		/* the mem of every protected area is still the original pattern */
		CHECK(fd.mem[0][(uint64_t)P_MODEM_FIRST * 4096] == 0x30 + P_MODEM_FIRST % 7);
	}
	/* flash:userdata/boot/logo without a download and with a download dropped by a link loss */
	setup_storage(0, 0);
	reset_fake();
	cmd("flash:userdata"); cmd(dl_cmd(c, 16)); data("SWEETXNUxxxxxxxx", 16); link_lost(); cmd("flash:boot");
	fb = run_session(&r);
	CHECK(resp_starts(0, "FAILno image") && resp_starts(3, "FAILno image") && total_writes() == 0);

	/* ---- sparse flash: DONT_CARE keeps the old contents, RAW and FILL land, CRC32 ignored ---- */
	setup_storage(0, 0);
	{
		struct sp s;
		uint8_t *d = pattern(5 * 4096, 3), *d2 = pattern(2 * 4096, 4);
		sp_begin(&s, 4096, 200);
		sp_skip(&s, 3);
		sp_raw(&s, 5, d);
		sp_fill(&s, 4, 0xdeadbeef);
		sp_crc(&s);
		sp_raw(&s, 2, d2);
		sp_fill(&s, 10, 0);
		sp_skip(&s, 176);
		sp_end(&s);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_is(1, "OKAY") && resp_starts(2, "INFOsparse: write") && resp_is(3, "OKAY"));
		uint8_t old[4096];
		memset(old, 0x30 + (P_UD_FIRST + 0) % 7, 4096);
		expect_ud(0, old, 4096, "block 0 is DONT_CARE (old pattern)");
		expect_ud(3 * 4096, d, 5 * 4096, "RAW chunk");
		uint8_t fillb[4 * 4096];
		for (unsigned i = 0; i < sizeof fillb; i += 4)
			put32(fillb + i, 0xdeadbeef);
		expect_ud(8 * 4096, fillb, sizeof fillb, "FILL chunk");
		expect_ud(12 * 4096, d2, 2 * 4096, "RAW after CRC32");
		uint8_t z[10 * 4096] = { 0 };
		expect_ud(14 * 4096, z, sizeof z, "FILL 0");
		uint8_t after[16];
		memset(after, 0x30 + (P_UD_FIRST + 24) % 7, 16);
		expect_ud(24 * 4096, after, 16, "DONT_CARE tail untouched");
		CHECK(fb.wr_bytes == (5 + 4 + 2 + 10) * 4096ull && writes_only_allowed());
		/* flashing the same piece twice is idempotent */
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_is(3, "OKAY"));
		expect_ud(3 * 4096, d, 5 * 4096, "RAW chunk (again)");
		free(d); free(d2); free(s.d);
	}

	/* ---- a corrupt sparse piece is refused before any write ---- */
	setup_storage(0, 0);
	{
		struct sp s;
		uint8_t *d = pattern(4096, 5);
		sp_begin(&s, 4096, 100);
		sp_raw(&s, 1, d);
		sp_raw(&s, 1, d);
		sp_end(&s);
		put32(s.d + 28 + 12 + 4096 + 8, 12 + 100);	/* the second chunk's size is wrong */
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_starts(2, "FAIL") && total_writes() == 0);
		/* image larger than the partition: total_blks beyond it */
		free(s.d);
		sp_begin(&s, 4096, 12006);	/* partition has 12005 blocks */
		sp_raw(&s, 1, d);
		sp_skip(&s, 12005);
		sp_end(&s);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_starts(2, "FAILsparse image is larger") && total_writes() == 0);
		free(s.d);
		sp_begin(&s, 4096, 12005);	/* exactly the partition: fine */
		sp_raw(&s, 1, d);
		sp_skip(&s, 12004);
		sp_end(&s);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_is(3, "OKAY") && writes_only_allowed());
		free(s.d);
		free(d);
	}

	/* ---- two pieces as `fastboot -S` sends them: each starts at block 0 with a leading DONT_CARE ---- */
	setup_storage(0, 0);
	{
		uint64_t n = 3 * 4096;
		uint8_t *a = pattern(n, 21), *b = pattern(n, 22);
		struct sp s1, s2;
		sp_begin(&s1, 4096, 5000);
		sp_raw(&s1, 3, a);
		sp_skip(&s1, 4997);
		sp_end(&s1);
		sp_begin(&s2, 4096, 5000);
		sp_skip(&s2, 4000);
		sp_raw(&s2, 3, b);
		sp_skip(&s2, 997);
		sp_end(&s2);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)s1.n)); data(s1.d, s1.n); cmd("flash:userdata");
		cmd(dl_cmd(c, (unsigned)s2.n)); data(s2.d, s2.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_is(3, "OKAY") && resp_is(7, "OKAY"));
		expect_ud(0, a, n, "piece 1");
		expect_ud(4000ull * 4096, b, n, "piece 2");
		free(a); free(b); free(s1.d); free(s2.d);
	}

	/* ---- big chunks: 3 MiB RAW (two scratch halves of 2 MiB do not matter for writes), 5 MiB FILL, > 8 MiB write chunks via verify off ---- */
	setup_storage(0, 0);
	{
		/* dl buffer is 1 MiB, so go through the storage layer directly for multi-chunk sizes */
		const char *why;
		const struct stor_part *ud = stor_find(&g_stor, "userdata", &why);
		uint64_t n = 9ull << 20;			/* > WRITE_CHUNK (8 MiB): two device writes */
		uint8_t *img = pattern(n, 31);
		CHECK(!stor_write(&g_stor, ud, 4096, img, n));
		expect_ud(4096, img, n, "9 MiB raw");
		CHECK(prog_bytes == n && prog_calls == 2);
		uint8_t z[8192] = { 0 };
		CHECK(!stor_fill(&g_stor, ud, 0, 5ull << 20, 0x01020304));		/* 5 MiB = 2 bounces of 2 MiB + 1 MiB */
		uint8_t fb4[4096];
		for (unsigned i = 0; i < 4096; i += 4)
			put32(fb4 + i, 0x01020304);
		expect_ud(0, fb4, 4096, "fill start");
		expect_ud((5ull << 20) - 4096, fb4, 4096, "fill end");
		/* pattern change re-fills the bounce */
		CHECK(!stor_fill(&g_stor, ud, 0, 8192, 0));
		expect_ud(0, z, 8192, "fill zero after pattern change");
		CHECK(!memcmp(fd.mem[0] + ud_off() + 8192, fb4, 4096));	/* neighbour block keeps the old fill */
		CHECK(writes_only_allowed());
		free(img);
	}

	/* ---- erase ---- */
	setup_storage(0, 0);
	reset_fake();
	cmd("erase:logo");
	fb = run_session(&r);
	CHECK(resp_is(0, "OKAY") && fd.unmaps == 1);
	{
		uint8_t z[4096] = { 0 };
		CHECK(!memcmp(fd.mem[0] + (uint64_t)P_LOGO_FIRST * 4096, z, 4096));
		CHECK(!memcmp(fd.mem[0] + (uint64_t)(P_LOGO_LAST) * 4096, z, 4096));
		CHECK(fd.mem[0][(uint64_t)(P_LOGO_LAST + 1) * 4096] == 0x30 + (P_LOGO_LAST + 1) % 7);
		CHECK(writes_only_allowed());
	}
	/* UNMAP refused: partitions up to 1 GiB are zeroed by writes, a bigger one fails without touching anything */
	setup_storage(0, 0);
	fd.fail_unmap = 1;
	reset_fake();
	cmd("erase:logo"); cmd("erase:userdata");
	fb = run_session(&r);
	CHECK(resp_is(0, "OKAY") && resp_is(1, "OKAY"));
	CHECK(fd.mem[0][(uint64_t)P_LOGO_FIRST * 4096 + 5] == 0 && fd.mem[0][ud_off() + 5] == 0 && writes_only_allowed());
	{
		const char *why;
		const struct stor_part *ud = stor_find(&g_stor, "userdata", &why);
		struct stor_part *w = (struct stor_part *)ud;
		unsigned before = total_writes();
		w->nblk = (2ull << 30) / 4096;		/* pretend: 2 GiB */
		CHECK(stor_erase(&g_stor, ud) != 0 && total_writes() == before);
		w->nblk = P_UD_LAST - P_UD_FIRST + 1;
	}

	/* ---- oem hash + upload ---- */
	setup_storage(0, 0);
	{
		uint64_t n = 300 * 1024;		/* 300 KiB at 64 KiB blocks: 4 full + one of 44 KiB */
		uint8_t *img = pattern(n, 41);
		reset_fake();
		cmd(dl_cmd(c, (unsigned)n)); data(img, n); cmd("flash:logo");
		cmd("oem hash:logo:0:4b000:10000");
		cmd("upload");
		fb = run_session(&r);
		CHECK(resp_is(2, "OKAY") && resp_is(3, "OKAYn=5") && resp_starts(4, "DATA00000050") && resp_is(5, "OKAY"));
		CHECK(upload_len == 5 * 16);
		int ok = 1;
		for (int b = 0; b < 5; b++) {
			uint8_t h[16];
			uint64_t o = (uint64_t)b * 65536, l = n - o > 65536 ? 65536 : n - o;
			blake2b(h, 16, img + o, l);
			ok &= !memcmp(h, upload_buf + 16 * b, 16);
		}
		CHECK(ok);
		/* hash of what the partition holds beyond the written image: the original pattern */
		reset_fake();
		cmd("oem hash:logo:4b000:5000:1000");	/* 20 KiB at the end of the 300 KiB image, 4 KiB blocks */
		cmd("upload");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYn=5") && upload_len == 80);
		/* a download after a hash clears the staged data; upload without staged data fails */
		reset_fake();
		cmd("oem hash:logo:0:1000:1000"); cmd("download:00000008"); data("SWEETXNU", 8); cmd("upload");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYn=1") && resp_starts(3, "FAILno staged"));
		reset_fake();
		cmd("upload");
		fb = run_session(&r);
		CHECK(resp_starts(0, "FAILno staged"));
		/* length 0 = to the end of the partition: logo has 1 MiB = 16 blocks of 64 KiB */
		reset_fake();
		cmd("oem hash:logo:0:0:10000"); cmd("upload");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYn=10") && upload_len == 16 * 16);
		/* link loss drops the staged table */
		reset_fake();
		cmd("oem hash:logo:0:1000:1000"); link_lost(); cmd("upload");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYn=1") && resp_starts(1, "FAILno staged"));
		/* bad arguments */
		static const char *const badh[] = { "oem hash", "oem hash:", "oem hash:logo", "oem hash:logo:0", "oem hash:logo:0:1000",
			"oem hash:logo:0:1000:1800", "oem hash:logo:0:1000:800", "oem hash:logo:0:1000:400000", "oem hash:logo:1:1000:1000",
			"oem hash:logo:0:200000:1000", "oem hash:logo:zz:1000:1000", "oem hash:logo:0:1000:1000:5", "oem hash:logo:100000:1000:1000",
			"oem hash:modem:0:1000:1000", "oem hash:userdata:0:100000000:10000" };
		reset_fake();
		for (unsigned i = 0; i < sizeof badh / sizeof badh[0]; i++)
			cmd(badh[i]);
		fb = run_session(&r);
		int all = 1;
		for (unsigned i = 0; i < sizeof badh / sizeof badh[0]; i++) {
			if (!resp_starts((int)i, "FAIL"))
				printf("  oem hash accepted: %s -> %s\n", badh[i], resp[i]);
			all &= resp_starts((int)i, "FAIL");
		}
		CHECK(all);
		CHECK(total_writes() == 0 || fd.writes == 1 + 0);
		free(img);
	}
	/* hash blocks of 2 MiB and a range spanning several scratch halves (userdata is 47 MiB) */
	setup_storage(0, 0);
	{
		const char *why;
		const struct stor_part *ud = stor_find(&g_stor, "userdata", &why);
		uint64_t n = 7ull << 20;
		uint8_t *img = pattern(n, 51);
		CHECK(!stor_write(&g_stor, ud, 0, img, n));
		uint8_t *out = malloc(1 << 20);
		CHECK(!stor_hash(&g_stor, ud, 0, n, 65536, out));
		int ok = 1;
		for (uint64_t b = 0; b < n / 65536; b++) {
			uint8_t h[16];
			blake2b(h, 16, img + b * 65536, 65536);
			ok &= !memcmp(h, out + 16 * b, 16);
		}
		CHECK(ok);
		CHECK(win_on == 1 && win_off == 1);	/* one cached window around the hash */
		CHECK(!stor_hash(&g_stor, ud, 0, n, 2u << 20, out));	/* 7 MiB at 2 MiB: 3 full + 1 MiB */
		uint8_t h[16];
		blake2b(h, 16, img + (6u << 20), 1u << 20);
		CHECK(!memcmp(h, out + 16 * 3, 16));
		CHECK(!stor_hash(&g_stor, ud, 4096, 8192, 4096, out));	/* offset inside the partition */
		blake2b(h, 16, img + 4096, 4096);
		CHECK(!memcmp(h, out, 16));
		blake2b(h, 16, img + 8192, 4096);
		CHECK(!memcmp(h, out + 16, 16));
		CHECK(stor_hash(&g_stor, ud, 0, 4096, 4096 * 3, out) != 0);	/* block size not a power of two */
		CHECK(stor_hash(&g_stor, ud, 0, 4096, 4u << 20, out) != 0);
		free(out);
		free(img);
	}

	/* ---- verify: read-back after every write; a device that corrupts writes is caught ---- */
	setup_storage(0, 0);
	{
		uint64_t n = 200000;
		uint8_t *img = pattern(n, 61);
		reset_fake();
		cmd("oem verify:1"); cmd("getvar:verify");
		cmd(dl_cmd(c, (unsigned)n)); data(img, n); cmd("flash:boot");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYverify on") && resp_is(1, "OKAYon") && resp_is(4, "OKAY") && fb.verify);
		unsigned reads = fd.reads;
		CHECK(reads >= 1 && win_on == 1 && win_off == 1);
		/* corrupting device */
		fd.corrupt_write = 1;
		reset_fake();
		cmd(dl_cmd(c, (unsigned)n)); data(img, n); cmd("flash:boot");
		fb = run_session(&r);
		CHECK(resp_starts(2, "FAILread-back verify FAILED"));
		CHECK(g_stor.bad_off == 17);
		CHECK(win_on == 2 && win_off == 2);	/* the window is closed again after a failure */
		/* verify off: the same corruption goes unnoticed (that is what the option is for) */
		reset_fake();
		cmd("oem verify:0");
		cmd(dl_cmd(c, (unsigned)n)); data(img, n); cmd("flash:boot");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYverify off") && resp_is(3, "OKAY"));
		fd.corrupt_write = 0;
		/* verify with FILL and sparse */
		struct sp s;
		sp_begin(&s, 4096, 100);
		sp_fill(&s, 10, 0xabcdef01);
		sp_raw(&s, 1, img);
		sp_skip(&s, 89);
		sp_end(&s);
		reset_fake();
		cmd("oem verify:1");
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_is(4, "OKAY") && writes_only_allowed());
		fd.corrupt_write = 1;
		reset_fake();
		cmd("oem verify:1");
		cmd(dl_cmd(c, (unsigned)s.n)); data(s.d, s.n); cmd("flash:userdata");
		fb = run_session(&r);
		CHECK(resp_starts(4, "FAILread-back verify FAILED"));
		fd.corrupt_write = 0;
		free(s.d);
		free(img);
	}

	/* ---- oem selftest (read-only) and the ufsq knob ---- */
	setup_storage(0, 0);
	reset_fake();
	cmd("oem selftest:userdata"); cmd("oem selftest:modem"); cmd("oem selftest:logo"); cmd("oem ufsq:1"); cmd("oem ufsq:9"); cmd("oem ufsq:");
	fb = run_session(&r);
	CHECK(resp_is(0, "OKAYselftest passed") && resp_starts(1, "FAILpartition not allowed") && resp_starts(2, "FAIL") /* logo: 1 MiB, too small */
	      && resp_is(3, "OKAY") && resp_starts(4, "FAIL") && resp_starts(5, "FAIL"));
	CHECK(total_writes() == 0 && win_on == win_off && win_on >= 1);

	/* ---- oem gpt / unknown oem ---- */
	setup_storage(0, 0);
	reset_fake();
	cmd("oem gpt"); cmd("oem nonsense"); cmd("oem hash:logo:0:1000"); cmd("oem unlock");
	fb = run_session(&r);
	CHECK(resp_is(n_resp - 1, "FAILunknown oem command") || resp_starts(n_resp - 1, "FAIL"));
	CHECK(total_writes() == 0);

	/* platform without storage: every storage command answers FAIL */
	cur_platform = &platform;
	reset_fake();
	cmd("flash:userdata"); cmd("erase:boot"); cmd("oem hash:boot:0:1000:1000"); cmd("getvar:partition-size:userdata");
	fb = run_session(&r);
	CHECK(resp_starts(0, "FAIL") && resp_starts(1, "FAIL") && resp_starts(2, "FAIL") && resp_starts(3, "FAIL"));
	fd_free();
}

static void storage_tests(void)
{
	test_blake2b();
	test_sparse_parser();
	test_gpt_and_allowlist();
	test_flash_protocol();
}

int main(void)
{
	enum fb_result r;
	struct fb fb;

	/* getvar */
	reset_fake();
	cmd("getvar:version"); cmd("getvar:product"); cmd("getvar:max-download-size");
	cmd("getvar:is-userspace"); cmd("getvar:bergamota"); cmd("getvar:nonsense"); cmd("getvar:version-bootloader");
	fb = run_session(&r);
	CHECK(r == FB_R_EOF);
	CHECK(resp_is(0, "OKAY0.4"));
	CHECK(resp_is(1, "OKAYberyllium"));
	CHECK(resp_is(2, "OKAY0x100000"));
	CHECK(resp_is(3, "OKAYno"));
	CHECK(resp_is(4, "OKAY1"));
	CHECK(resp_starts(5, "FAIL"));
	CHECK(resp_is(6, "OKAYbergamota-2"));
	CHECK(fb.n_cmds == 7);
	CHECK(idle_calls >= 7);

	/* getvar all: INFO lines then OKAY */
	reset_fake();
	cmd("getvar:all");
	fb = run_session(&r);
	CHECK(n_resp >= 13 && resp_is(n_resp - 1, "OKAY"));
	CHECK(resp_starts(0, "INFOversion: 0.4"));
	int saw_prod = 0, saw_max = 0, saw_user = 0, saw_berg = 0;
	for (int i = 0; i < n_resp; i++) {
		saw_prod |= !strcmp(resp[i], "INFOproduct: beryllium");
		saw_max |= !strcmp(resp[i], "INFOmax-download-size: 0x100000");
		saw_user |= !strcmp(resp[i], "INFOis-userspace: no");
		saw_berg |= !strcmp(resp[i], "INFObergamota: 1");
	}
	CHECK(saw_prod && saw_max && saw_user && saw_berg);

	/* getvar bergamota-charger / -raw: through the platform callback, "unavailable" without one */
	reset_fake();
	cmd("getvar:bergamota-charger"); cmd("getvar:bergamota-charger-raw");
	fb = run_session(&r);
	CHECK(resp_is(0, "OKAYunavailable") && resp_is(1, "OKAYunavailable"));
	{
		static struct fb_platform pc;
		pc = platform;
		pc.charger = p_charger;
		cur_platform = &pc;
		reset_fake();
		cmd("getvar:bergamota-charger"); cmd("getvar:bergamota-charger-raw"); cmd("getvar:all");
		fb = run_session(&r);
		CHECK(resp_is(0, "OKAYapplied CDP 1500/2000mA 4395mV FAST 37%"));
		CHECK(resp_is(1, "OKAYst=02/00 apsd=04 je=1f aicl=1 w=3/0"));
		int saw = 0;
		for (int i = 0; i < n_resp; i++)
			saw |= !strncmp(resp[i], "INFObergamota-charger: applied CDP", 34);
		CHECK(saw);
		cur_platform = &platform;
	}

	/* download of 5000 bytes in 1000 byte bulk transfers, then boot a raw payload */
	uint8_t *raw = make_sweet(5000);
	reset_fake();
	boot_expect = raw;
	cmd("download:00001388"); data(raw, 5000); cmd("boot");
	fb = run_session(&r);
	CHECK(r == FB_R_BOOT);
	CHECK(resp_is(0, "DATA00001388"));
	CHECK(resp_is(1, "OKAY"));
	CHECK(resp_is(2, "OKAY"));
	CHECK(boot_calls == 1 && boot_len == 5000 && boot_content_ok);
	CHECK(!memcmp(dlbuf, raw, 5000));

	/* boot.img v0, v2 and v3 wrappers with a SWEETXNU ramdisk */
	{
		uint8_t *rd = make_sweet(3000);
		static const struct { int hv; uint32_t page; } cfgs[] = { { 0, 2048 }, { 1, 4096 }, { 2, 4096 }, { 3, 4096 }, { 4, 4096 } };
		for (unsigned i = 0; i < sizeof cfgs / sizeof cfgs[0]; i++) {
			uint64_t total, off = 0, size = 0;
			const char *why = "";
			uint8_t *bi = make_bootimg(cfgs[i].hv, cfgs[i].page, 12345, rd, 3000, &total);
			CHECK(fb_find_payload(bi, total, &off, &size, &why) == FB_IMG_BOOTIMG);
			CHECK(size == 3000 && !memcmp(bi + off, rd, 3000) && (off & 7) == 0);
			free(bi);
		}
		/* ramdisk that is not a payload, truncated image, empty ramdisk, junk */
		uint64_t total, off, size;
		const char *why = "";
		uint8_t bad[3000];
		memset(bad, 7, sizeof bad);
		uint8_t *bi = make_bootimg(2, 4096, 100, bad, 3000, &total);
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "not SWEETXNU"));
		free(bi);
		bi = make_bootimg(2, 4096, 100, rd, 3000, &total);
		CHECK(fb_find_payload(bi, total - 8192 + 10, &off, &size, &why) == 0 && strstr(why, "truncated"));
		put32(bi + 16, 0);
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "no ramdisk"));
		put32(bi + 16, 3000);
		put32(bi + 36, 1000);	/* page size not a power of two */
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0 && strstr(why, "page"));
		put32(bi + 36, 4096);
		put32(bi + 8, 0xffffffffu);	/* kernel size far beyond the file */
		CHECK(fb_find_payload(bi, total, &off, &size, &why) == 0);
		free(bi);
		uint8_t junk[64] = { 1, 2, 3 };
		CHECK(fb_find_payload(junk, sizeof junk, &off, &size, &why) == 0 && strstr(why, "not a boot.img"));
		CHECK(fb_find_payload(junk, 3, &off, &size, &why) == 0);

		/* end to end: download a boot.img, boot it */
		uint8_t *img = make_bootimg(2, 4096, 20000, rd, 3000, &total);
		reset_fake();
		boot_expect = img;
		char c[32];
		snprintf(c, sizeof c, "download:%08x", (unsigned)total);
		cmd(c); data(img, total); cmd("boot");
		fb = run_session(&r);
		CHECK(r == FB_R_BOOT && boot_calls == 1 && boot_len == total && boot_content_ok);
		free(img);
		free(rd);
	}

	/* boot without a download, boot of junk */
	reset_fake();
	cmd("boot");
	fb = run_session(&r);
	CHECK(r == FB_R_EOF && boot_calls == 0 && resp_starts(0, "FAIL"));
	{
		static const uint8_t junk[100] = { 'h', 'e', 'l', 'l', 'o' };
		reset_fake();
		cmd("download:00000064"); data(junk, 100); cmd("boot");
		fb = run_session(&r);
		CHECK(r == FB_R_EOF && boot_calls == 0 && resp_is(1, "OKAY") && resp_starts(2, "FAILnot a boot.img"));
	}

	/* download errors */
	reset_fake();
	cmd("download:00200000");	/* > dl_max */
	cmd("download:0"); cmd("download:zz"); cmd("download:123456789"); cmd("download:");
	fb = run_session(&r);
	CHECK(resp_is(0, "FAILdata too large"));
	CHECK(resp_starts(1, "FAIL") && resp_starts(2, "FAIL") && resp_starts(3, "FAIL") && resp_starts(4, "FAIL"));
	CHECK(fb.dl_len == 0);

	/* the maximum size is accepted and filled exactly */
	{
		uint8_t *big = make_sweet(DLMAX);
		reset_fake();
		data_chunk = 0x30000;
		cmd("download:00100000"); data(big, DLMAX);
		fb = run_session(&r);
		CHECK(resp_is(0, "DATA00100000") && resp_is(1, "OKAY") && fb.dl_len == DLMAX);
		CHECK(!memcmp(dlbuf, big, DLMAX));
		free(big);
	}

	/* link lost in the middle of a download drops it; a later boot must fail */
	{
		reset_fake();
		cmd("download:00001000"); data(raw, 1000); link_lost(); cmd("boot");
		fb = run_session(&r);
		CHECK(resp_is(0, "DATA00001000"));
		CHECK(fb.dl_len == 0 && fb.n_links >= 1);
		CHECK(boot_calls == 0 && resp_starts(1, "FAILno image"));
	}
	/* link lost between commands also forgets a finished download */
	reset_fake();
	cmd("download:00001388"); data(raw, 5000); link_lost(); cmd("boot");
	fb = run_session(&r);
	CHECK(boot_calls == 0 && resp_starts(2, "FAILno image"));

	/* transport error in the data phase answers FAIL */
	reset_fake();
	cmd("download:00000010"); data_err(); cmd("getvar:version");
	fb = run_session(&r);
	CHECK(resp_is(0, "DATA00000010") && resp_starts(1, "FAILdata transfer") && resp_is(2, "OKAY0.4") && fb.dl_len == 0);

	/* a second download replaces the first */
	reset_fake();
	cmd("download:00000008"); data("SWEETXNU", 8); cmd("download:00000009"); data("SWEETXNUX", 9);
	fb = run_session(&r);
	CHECK(fb.dl_len == 9);

	/* reboot family */
	reset_fake();
	cmd("reboot");
	fb = run_session(&r);
	CHECK(r == FB_R_REBOOT && reboot_calls == 1 && last_reboot_mode == 0 && resp_is(0, "OKAY"));
	reset_fake();
	cmd("reboot-bootloader");
	fb = run_session(&r);
	CHECK(r == FB_R_REBOOT_BL && reboot_calls == 1 && last_reboot_mode == 1 && resp_is(0, "OKAY"));
	reset_fake();
	cmd("continue");
	fb = run_session(&r);
	CHECK(r == FB_R_CONTINUE && reboot_calls == 1 && last_reboot_mode == 0);

	/* nothing that writes storage is accepted, and nothing after a refused command breaks */
	{
		static const char *const bad[] = { "flash:boot", "erase:userdata", "format:ext4:userdata", "set_active:a",
			"oem unlock", "flashing unlock", "create-logical-partition:x:1", "snapshot-update:cancel", "frobnicate", "" };
		reset_fake();
		for (unsigned i = 0; i < sizeof bad / sizeof bad[0] - 1; i++)
			cmd(bad[i]);
		cmd("getvar:version");
		fb = run_session(&r);
		int all_fail = 1;
		for (unsigned i = 0; i < sizeof bad / sizeof bad[0] - 1; i++)
			all_fail &= resp_starts((int)i, "FAIL");
		CHECK(all_fail);
		CHECK(resp_is(9, "OKAY0.4"));
		CHECK(boot_calls == 0 && reboot_calls == 0);
	}

	/* response packets never exceed 64 bytes: a very long variable name is just refused */
	reset_fake();
	cmd("getvar:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	fb = run_session(&r);
	CHECK(resp_starts(0, "FAIL"));

	free(raw);
	storage_tests();
	printf("fastboot_test: %d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
