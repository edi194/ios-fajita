/*
 * Allowlisted partition storage: see storage.h. Pure logic over a struct blkdev, so the host test
 * (fastboot_test.c) runs the real code against a fake device.
 */
#include "blake2b.h"
#include "storage.h"

#define WRITE_CHUNK	(8u << 20)
#define FILL_BOUNCE	STOR_HALF

static int str_eq(const char *a, const char *b)
{
	while (*a && *a == *b)
		a++, b++;
	return *a == *b;
}

/* THE allowlist. Nothing else is ever written, erased or hashed. */
int stor_name_allowed(const char *name)
{
	return str_eq(name, "userdata") || str_eq(name, "boot") || str_eq(name, "logo");
}

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p)
{
	return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

static uint32_t crc32(const uint8_t *p, uint64_t n, uint32_t skip_from, uint32_t skip_to)
{
	uint32_t c = 0xffffffffu;
	for (uint64_t i = 0; i < n; i++) {
		uint32_t b = p[i];
		if (i >= skip_from && i < skip_to)
			b = 0;
		c ^= b;
		for (int k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
	}
	return ~c;
}

/* Parse the GPT of one LUN (cap blocks); record allowlisted partitions. Returns 1 if the GPT is valid. */
static int scan_lun(struct stor *s, unsigned lun, uint64_t cap, uint32_t *entries_out)
{
	uint8_t *hdr = s->scratch, *ents = s->scratch + STOR_BLK;
	const char *e = s->bd.read(s->bd.ctx, lun, 1, 1, hdr);

	if (e)
		return 0;
	static const char sig[8] = { 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
	for (int i = 0; i < 8; i++)
		if (hdr[i] != (uint8_t)sig[i])
			return 0;
	uint32_t hsz = le32(hdr + 12);
	if (hsz < 92 || hsz > STOR_BLK || crc32(hdr, hsz, 16, 20) != le32(hdr + 16))
		return 0;
	if (le64(hdr + 24) != 1)
		return 0;
	uint64_t first_usable = le64(hdr + 40), last_usable = le64(hdr + 48), elba = le64(hdr + 72);
	uint32_t nent = le32(hdr + 80), esz = le32(hdr + 84), ecrc = le32(hdr + 88);
	if (esz != 128 || nent == 0 || nent > 128 || elba < 2 || last_usable >= cap || first_usable > last_usable)
		return 0;
	uint32_t eb = (nent * esz + STOR_BLK - 1) / STOR_BLK;
	if (elba + eb > first_usable)
		return 0;
	if (s->bd.read(s->bd.ctx, lun, elba, eb, ents))
		return 0;
	if (crc32(ents, (uint64_t)nent * esz, ~0u, ~0u) != ecrc)
		return 0;
	*entries_out = nent;
	for (uint32_t i = 0; i < nent; i++) {
		const uint8_t *en = ents + (uint64_t)i * esz;
		uint64_t first = le64(en + 32), last = le64(en + 40);
		char name[16];
		unsigned n = 0;
		for (unsigned c = 0; c < 36; c++) {
			uint8_t lo = en[56 + 2 * c], hi = en[57 + 2 * c];
			if (!lo && !hi)
				break;
			if (n < 15)
				name[n] = (hi || lo < 32 || lo >= 127) ? '?' : (char)lo;
			n++;
		}
		if (n == 0 || n > 15)
			continue;
		name[n] = 0;
		if (!stor_name_allowed(name))
			continue;
		/* a partition must lie inside the usable area: the GPT copies are never reachable */
		int sane = first >= first_usable && last <= last_usable && first <= last;
		struct stor_part *p = 0;
		for (unsigned k = 0; k < s->nparts; k++)
			if (str_eq(s->parts[k].name, name))
				p = &s->parts[k];
		if (p) {
			p->dup = 1;
			continue;
		}
		if (s->nparts >= STOR_MAX_PARTS)
			continue;
		p = &s->parts[s->nparts++];
		for (unsigned k = 0; k <= n; k++)
			p->name[k] = name[k];
		p->lun = (uint8_t)lun;
		p->first = first;
		p->nblk = sane ? last - first + 1 : 0;
		p->dup = 0;
	}
	return 1;
}

const char *stor_scan(struct stor *s)
{
	s->nparts = 0;
	s->luns_found = 0;
	s->scan_err = 0;
	s->scanned = 1;
	s->fill_len = 0;
	if (!s->scratch)
		return s->scan_err = "no scratch memory";
	for (unsigned lun = 0; lun < 8; lun++) {
		uint64_t cap = 0;
		s->lun_info[lun].lun = (uint8_t)lun;
		s->lun_info[lun].valid = 0;
		s->lun_info[lun].entries = 0;
		s->lun_info[lun].blocks = 0;
		if (s->bd.cap(s->bd.ctx, lun, &cap))
			continue;
		s->luns_found++;
		s->lun_info[lun].blocks = cap;
		if (scan_lun(s, lun, cap, &s->lun_info[lun].entries))
			s->lun_info[lun].valid = 1;
	}
	if (!s->luns_found)
		return s->scan_err = "no UFS LUN answered";
	if (!s->nparts)
		return s->scan_err = "no userdata/boot/logo partition in any GPT";
	return 0;
}

const struct stor_part *stor_find(struct stor *s, const char *name, const char **why)
{
	if (!stor_name_allowed(name)) {
		*why = "partition not allowed (only userdata, boot, logo)";
		return 0;
	}
	if (!s->scanned)
		stor_scan(s);
	for (unsigned i = 0; i < s->nparts; i++)
		if (str_eq(s->parts[i].name, name)) {
			if (s->parts[i].dup) {
				*why = "partition name is ambiguous in the GPTs: refused";
				return 0;
			}
			if (!s->parts[i].nblk) {
				*why = "partition lies outside the GPT usable area: refused";
				return 0;
			}
			return &s->parts[i];
		}
	*why = s->scan_err ? s->scan_err : "partition not found";
	return 0;
}

/* p must be one of our own table entries (never a caller-made struct) and the range must be inside it. */
static const char *check_range(const struct stor *s, const struct stor_part *p, uint64_t off, uint64_t len)
{
	if (p < s->parts || p >= s->parts + s->nparts || !stor_name_allowed(p->name) || p->dup || !p->nblk)
		return "partition not allowed";
	if ((off | len) & (STOR_BLK - 1))
		return "unaligned range";
	if (off > p->nblk * STOR_BLK || len > p->nblk * STOR_BLK - off)
		return "range outside the partition";
	return 0;
}

static int same(const uint8_t *a, const uint8_t *b, uint64_t n)
{
	if (!(((uintptr_t)a | (uintptr_t)b) & 7)) {
		const uint64_t *x = (const uint64_t *)a, *y = (const uint64_t *)b;
		for (uint64_t i = 0; i < n / 8; i++)
			if (x[i] != y[i])
				return 0;
		return 1;
	}
	for (uint64_t i = 0; i < n; i++)
		if (a[i] != b[i])
			return 0;
	return 1;
}

static void note_progress(struct stor *s, uint64_t bytes)
{
	if (s->progress)
		s->progress(s->ctx, bytes);
}

/* Read back [lba, +n blocks) into scratch half B and compare with expect (n*4096 bytes). */
static const char *readback(struct stor *s, const struct stor_part *p, uint64_t off, const uint8_t *expect, uint64_t len)
{
	uint8_t *b = s->scratch + STOR_HALF;
	uint64_t done = 0;

	while (done < len) {
		uint64_t n = len - done > STOR_HALF ? STOR_HALF : len - done;
		const char *e = s->bd.read(s->bd.ctx, p->lun, p->first + (off + done) / STOR_BLK, n / STOR_BLK, b);
		if (e)
			return e;
		if (!same(expect + done, b, n)) {
			for (uint64_t i = 0; i < n; i++)
				if (expect[done + i] != b[i]) {
					s->bad_off = off + done + i;
					break;
				}
			return "read-back verify FAILED: the device holds different data";
		}
		done += n;
	}
	return 0;
}

const char *stor_write(struct stor *s, const struct stor_part *p, uint64_t off, const uint8_t *src, uint64_t len)
{
	const char *e = check_range(s, p, off, len);
	uint64_t done = 0;

	if (e)
		return e;
	while (done < len) {
		uint64_t n = len - done > WRITE_CHUNK ? WRITE_CHUNK : len - done;
		e = s->bd.write(s->bd.ctx, p->lun, p->first + (off + done) / STOR_BLK, n / STOR_BLK, src + done);
		if (e)
			return e;
		if (s->verify && (e = readback(s, p, off + done, src + done, n)))
			return e;
		done += n;
		note_progress(s, n);
	}
	return 0;
}

const char *stor_fill(struct stor *s, const struct stor_part *p, uint64_t off, uint64_t len, uint32_t pattern)
{
	const char *e = check_range(s, p, off, len);
	uint8_t *a = s->scratch;
	uint64_t done = 0;

	if (e)
		return e;
	while (done < len) {
		uint64_t n = len - done > FILL_BOUNCE ? FILL_BOUNCE : len - done;
		/* the bounce is filled once per pattern (CPU stores to uncached memory are slow) */
		if (s->fill_len < n || s->fill_pat != pattern || !s->fill_len) {
			volatile uint32_t *w = (volatile uint32_t *)a;
			for (uint64_t i = 0; i < n / 4; i++)
				w[i] = pattern;
			s->fill_pat = pattern;
			s->fill_len = n;
		}
		e = s->bd.write(s->bd.ctx, p->lun, p->first + (off + done) / STOR_BLK, n / STOR_BLK, a);
		if (e)
			return e;
		if (s->verify && (e = readback(s, p, off + done, a, n)))
			return e;
		done += n;
		note_progress(s, n);
	}
	return 0;
}

const char *stor_erase(struct stor *s, const struct stor_part *p)
{
	const char *e = check_range(s, p, 0, 0);

	if (e)
		return e;
	e = s->bd.unmap(s->bd.ctx, p->lun, p->first, p->nblk);
	if (!e)
		return 0;
	if (p->nblk * STOR_BLK > (1ull << 30))
		return "erase failed: the device refused UNMAP and the partition is too big to zero";
	return stor_fill(s, p, 0, p->nblk * STOR_BLK, 0);
}

const char *stor_hash(struct stor *s, const struct stor_part *p, uint64_t off, uint64_t len, uint32_t bs, uint8_t *out)
{
	const char *e = check_range(s, p, off, len);
	uint8_t *buf[2];
	uint64_t nchunks, k;

	if (e)
		return e;
	if (!len || bs < STOR_BLK || bs > STOR_HALF || (bs & (bs - 1)))
		return "bad hash block size";
	buf[0] = s->scratch;
	buf[1] = s->scratch + STOR_HALF;
	nchunks = (len + STOR_HALF - 1) / STOR_HALF;
	s->fill_len = 0;		/* both halves are about to be overwritten */
	if (s->cached)
		s->cached(s->ctx, 1, 0, 0);
	uint64_t n0 = len > STOR_HALF ? STOR_HALF : len;
	e = s->bd.read(s->bd.ctx, p->lun, p->first + off / STOR_BLK, n0 / STOR_BLK, buf[0]);
	for (k = 0; !e && k < nchunks; k++) {
		uint64_t pos = k * STOR_HALF, n = len - pos > STOR_HALF ? STOR_HALF : len - pos;
		int next = k + 1 < nchunks;
		if (next) {
			uint64_t np = pos + STOR_HALF, nn = len - np > STOR_HALF ? STOR_HALF : len - np;
			e = s->bd.read_start(s->bd.ctx, p->lun, p->first + (off + np) / STOR_BLK, nn / STOR_BLK, buf[(k + 1) & 1]);
			if (e)
				break;
		}
		for (uint64_t b = 0; b < n; b += bs) {
			uint64_t bl = n - b > bs ? bs : n - b;
			blake2b(out + (pos + b) / bs * STOR_HASH_LEN, STOR_HASH_LEN, buf[k & 1] + b, bl);
		}
		if (next && (e = s->bd.read_wait(s->bd.ctx)))
			break;
		note_progress(s, n);
	}
	if (s->cached)
		s->cached(s->ctx, 0, 0, 0);
	return e;
}

const char *stor_selftest(struct stor *s, const struct stor_part *p)
{
	const char *e = check_range(s, p, 0, 0);
	uint8_t *a = s->scratch, *b = s->scratch + STOR_HALF;
	uint64_t span = STOR_HALF / STOR_BLK, nblk = p ? p->nblk : 0;

	if (e)
		return e;
	if (nblk < 3 * span)
		return "partition too small for the self test";
	s->fill_len = 0;
	if (s->cached)
		s->cached(s->ctx, 1, 0, 0);
	for (unsigned round = 0; round < 3 && !e; round++) {
		uint64_t lba = p->first + round * (nblk / 3 / span) * span;	/* start, ~1/3, ~2/3 */
		volatile uint64_t *va = (volatile uint64_t *)a, *vb = (volatile uint64_t *)b;
		for (uint64_t i = 0; i < STOR_HALF / 8; i++) {		/* dirty cache lines in both halves */
			va[i] = 0xa5a5a5a5a5a5a5a5ULL ^ i;
			vb[i] = 0x5a5a5a5a5a5a5a5aULL ^ i;
		}
		if ((e = s->bd.read(s->bd.ctx, p->lun, lba, span, a)) || (e = s->bd.read(s->bd.ctx, p->lun, lba, span, b)))
			break;
		if (!same(a, b, STOR_HALF)) {
			e = "selftest FAILED: two reads of the same blocks differ (DMA/cache problem)";
			break;
		}
		uint64_t stale = 0;		/* lines still holding our dirty pattern would mean the read never landed or was overwritten */
		for (uint64_t i = 0; i < STOR_HALF / 8; i++)
			stale += (va[i] == (0xa5a5a5a5a5a5a5a5ULL ^ i));
		if (stale > STOR_HALF / 8 / 2)
			e = "selftest FAILED: the buffer still holds the pre-read pattern";
		note_progress(s, STOR_HALF);
	}
	if (s->cached)
		s->cached(s->ctx, 0, 0, 0);
	return e;
}

const char *stor_sync(struct stor *s, const struct stor_part *p)
{
	const char *e = check_range(s, p, 0, 0);
	return e ? e : s->bd.sync(s->bd.ctx, p->lun);
}
