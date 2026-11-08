/*
 * UFS host driver: see ufs.h. UFSHCI register layout and descriptor formats: JEDEC JESD223.
 *
 * The host was brought up by ABL (link up, device ready); we only replace the transfer request list
 * base with our own and ring doorbells. Interrupts are never enabled, everything is polled.
 *
 * Request list: we use only the EVEN entries of the 32-byte UTRD array (slot i = entry 2i, doorbell
 * bit 2i), so every descriptor sits in its own 64-byte cache line: cleaning/invalidating one
 * descriptor can never touch another one the host is updating at the same time.
 *
 * DMA coherency (SDM845 UFS has no dma-coherent): see cache.h. Per command
 *   - descriptors: written by the CPU, then dc cvac, then doorbell; after completion dc ivac, then read
 *   - write data (device reads): dc cvac of the buffer before the doorbell
 *   - read data (device writes): dc civac before the doorbell, dc ivac after completion
 * All static descriptor memory is flushed once in ufs_init before the first store, so no stale dirty
 * line from ABL can be evicted over our descriptors later.
 */
#include <stdint.h>
#include "board.h"
#include "cache.h"
#include "console.h"
#include "storage.h"
#include "ufs.h"

#define REG_CAP		0x00
#define REG_VER		0x08
#define REG_IS		0x20
#define REG_HCS		0x30
#define REG_HCE		0x34
#define REG_UTRLBA	0x50
#define REG_UTRLBAU	0x54
#define REG_UTRLDBR	0x58
#define REG_UTRLCLR	0x5c
#define REG_UTRLRSR	0x60

#define HCS_DP		(1u << 0)
#define HCS_UTRLRDY	(1u << 1)

#define CAP_64AS	(1u << 24)

#define NQ		8			/* commands in flight */
#define CMD_BLKS	64u			/* 256 KiB per command = one PRDT entry */
#define CMD_BYTES	(CMD_BLKS * UFS_BLK)
#define TICKS_PER_S	19200000ULL
#define CMD_TIMEOUT	(10 * TICKS_PER_S)	/* writes can stall behind device garbage collection */

struct ufs_last ufs_last;
uint64_t ufs_blocks_read, ufs_blocks_written;

static inline uint32_t ufs_rd(uint32_t off) { return *(volatile uint32_t *)(UFS_BASE + off); }
static inline void ufs_wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(UFS_BASE + off) = v; }
static inline void w32(volatile void *p, uint32_t v) { *(volatile uint32_t *)p = v; }
static inline uint32_t r32(const volatile void *p) { return *(const volatile uint32_t *)p; }

/* UTP transfer request descriptor (32 bytes). */
struct utrd {
	uint32_t dw0;		/* [31:28] CT, [26:25] DD, [24] I */
	uint32_t dw1;
	uint32_t dw2;		/* [7:0] OCS */
	uint32_t dw3;
	uint32_t ucdba;		/* command descriptor base, 128-byte aligned */
	uint32_t ucdbau;
	uint32_t resp;		/* [31:16] response UPIU offset, [15:0] length (DWORDs) */
	uint32_t prdt;		/* [31:16] PRDT offset (DWORDs), [15:0] number of PRDT entries */
};

/* UTP command descriptor: command UPIU, response UPIU, PRDT (1152 bytes = 9 * 128). */
struct ucd {
	uint8_t cmd[512];
	uint8_t resp[512];
	struct {
		uint32_t addr_lo, addr_hi, rsvd, dbc;	/* dbc = byte count - 1 */
	} prdt[8];
};

static struct utrd utrl[32] __attribute__((aligned(1024)));
static struct ucd ucd[NQ] __attribute__((aligned(128)));
/* small DMA buffer for READ CAPACITY / UNMAP parameter lists, one cache line */
static uint8_t pbuf[64] __attribute__((aligned(64)));

static int inited, nq, qd = NQ;	/* nq: slots available, qd: commands allowed in flight (oem ufsq) */
static uint32_t cap_reg;
static void (*idle_fn)(void);

static uint64_t ticks(void)
{
	uint64_t t;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(t));
	return t;
}

static uint32_t pk(uint32_t b0, uint32_t b1, uint32_t b2, uint32_t b3)
{
	return b0 | b1 << 8 | b2 << 16 | b3 << 24;
}

static uint32_t be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

int ufs_set_depth(int n)
{
	if (n < 1)
		n = 1;
	if (n > NQ)
		n = NQ;
	qd = n;
	return qd;
}

void ufs_set_idle(void (*fn)(void))
{
	idle_fn = fn;
}

/* no lookup table of string pointers (ABS64 relocations) */
__attribute__((optimize("no-tree-switch-conversion")))
const char *ufs_errstr(int rc)
{
	switch (rc) {
	case 0: return "ok";
	case UFS_E_NOTREADY: return "UFS host not ready";
	case UFS_E_TIMEOUT: return "UFS command timeout";
	case UFS_E_OCS: return "UFS host error (OCS)";
	case UFS_E_RESP: return "UFS target failure";
	case UFS_E_SCSI: return "UFS SCSI error";
	case UFS_E_ARGS: return "UFS bad request";
	}
	return "UFS error";
}

/*
 * Build and ring one command in slot i. dir: 0 none, 1 host->device (write), 2 device->host (read).
 * buf/len: one contiguous range of at most 256 KiB.
 */
static int cmd_submit(unsigned i, unsigned lun, const uint8_t *cdb, unsigned cdb_len, void *buf, uint32_t len, int dir)
{
	struct utrd *d = &utrl[2 * i];
	struct ucd *c = &ucd[i];
	uintptr_t ucd_pa = (uintptr_t)c, buf_pa = (uintptr_t)buf;

	if (len > CMD_BYTES || (len && (buf_pa & 3)) || cdb_len > 16)
		return UFS_E_ARGS;
	if (!(cap_reg & CAP_64AS) && (((ucd_pa + sizeof *c) >> 32) || ((buf_pa + len) >> 32)))
		return UFS_E_ARGS;

	/* command UPIU: type 0x01 COMMAND, flags (R=0x40, W=0x20), LUN, task tag; expected length BE; CDB */
	w32(&c->cmd[0], pk(0x01, dir == 2 ? 0x40 : dir == 1 ? 0x20 : 0, lun, 2 * i));	/* task tag = UTRD index */
	w32(&c->cmd[4], 0);
	w32(&c->cmd[8], 0);
	w32(&c->cmd[12], __builtin_bswap32(len));
	for (unsigned k = 0; k < 16; k += 4) {
		uint32_t v = 0;
		for (unsigned b = 0; b < 4; b++)
			v |= (uint32_t)(k + b < cdb_len ? cdb[k + b] : 0) << (8 * b);
		w32(&c->cmd[16 + k], v);
	}
	/* response UPIU header cleared so a stale response can never be mistaken for a new one */
	for (unsigned k = 0; k < 64; k += 4)
		w32(&c->resp[k], 0);
	if (len) {
		w32(&c->prdt[0].addr_lo, (uint32_t)buf_pa);
		w32(&c->prdt[0].addr_hi, (uint32_t)(buf_pa >> 32));
		w32(&c->prdt[0].rsvd, 0);
		w32(&c->prdt[0].dbc, len - 1);
	}
	w32(&d->dw0, (1u << 28) | ((uint32_t)dir << 25) | (1u << 24));	/* CT = UFS storage, DD, interrupt bit */
	w32(&d->dw1, 0);
	w32(&d->dw2, 0x0f);		/* OCS: invalid until the host updates it */
	w32(&d->dw3, 0);
	w32(&d->ucdba, (uint32_t)ucd_pa);
	w32(&d->ucdbau, (uint32_t)(ucd_pa >> 32));
	w32(&d->resp, (512u / 4) << 16 | (512u / 4));
	w32(&d->prdt, (1024u / 4) << 16 | (len ? 1u : 0u));

	/* descriptors out to memory (the host reads them), data per direction */
	dc_clean(d, sizeof *d);
	dc_clean(c->cmd, 64);
	dc_clean(c->resp, 64);
	dc_clean(&c->prdt[0], 16);
	if (len) {
		if (dir == 1)
			dc_clean(buf, len);
		else
			dc_flush(buf, len);
	}
	ufs_wr(REG_UTRLDBR, 1u << (2 * i));
	return 0;
}

/* After the doorbell bit cleared: translate the completion into a UFS_E_* code and fill ufs_last. */
static int cmd_result(unsigned i)
{
	struct utrd *d = &utrl[2 * i];
	struct ucd *c = &ucd[i];
	uint32_t ocs, st;

	dc_inval(d, sizeof *d);
	dc_inval(c->resp, 64);
	ocs = r32(&d->dw2) & 0xff;
	st = ((const volatile uint8_t *)c->resp)[7];
	ufs_last.ocs = ocs;
	ufs_last.status = st;
	ufs_last.sense_key = ufs_last.asc = ufs_last.ascq = 0;
	if (ocs)
		return ufs_last.rc = UFS_E_OCS;
	if (((const volatile uint8_t *)c->resp)[0] != 0x21 || ((const volatile uint8_t *)c->resp)[6] != 0)
		return ufs_last.rc = UFS_E_RESP;	/* not RESPONSE UPIU, or target failure */
	if (st) {
		const volatile uint8_t *sd = (const volatile uint8_t *)c->resp + 34;	/* sense data after the 2-byte length */
		ufs_last.sense_key = sd[2] & 0xf;
		ufs_last.asc = sd[12];
		ufs_last.ascq = sd[13];
		return ufs_last.rc = UFS_E_SCSI;
	}
	return ufs_last.rc = 0;
}

static void slot_abort(unsigned i)
{
	ufs_wr(REG_UTRLCLR, ~(1u << (2 * i)));	/* writing 0 to a bit clears that slot */
	uint64_t t = ticks();
	while ((ufs_rd(REG_UTRLDBR) & (1u << (2 * i))) && ticks() - t < TICKS_PER_S / 2)
		;
}

static int x_active(void);

/* One synchronous command in slot 0 (no transfer running). */
static int scsi_sync(unsigned lun, const uint8_t *cdb, unsigned cdb_len, void *buf, uint32_t len, int dir)
{
	int rc = 0;

	if (x_active())
		return UFS_E_ARGS;		/* slot 0 belongs to the running transfer */
	for (int attempt = 0; attempt < 3; attempt++) {
		rc = cmd_submit(0, lun, cdb, cdb_len, buf, len, dir);
		if (rc)
			return rc;
		uint64_t t = ticks();
		while (ufs_rd(REG_UTRLDBR) & 1u) {
			if (ticks() - t > CMD_TIMEOUT) {
				slot_abort(0);
				return ufs_last.rc = UFS_E_TIMEOUT;
			}
			if (idle_fn)
				idle_fn();
		}
		if (len && dir == 2)
			dc_inval(buf, len);
		rc = cmd_result(0);
		if (rc == UFS_E_SCSI && ufs_last.sense_key == 6)	/* UNIT ATTENTION (after reset/link events): retry */
			continue;
		return rc;
	}
	return rc;
}

int ufs_init(void)
{
	uint32_t hcs, hce;

	if (inited)
		return 0;
	cap_reg = ufs_rd(REG_CAP);
	hcs = ufs_rd(REG_HCS);
	hce = ufs_rd(REG_HCE);
	if (!(hce & 1) || !(hcs & HCS_DP) || !(hcs & HCS_UTRLRDY))
		return UFS_E_NOTREADY;
	if (ufs_rd(REG_UTRLDBR))
		return UFS_E_NOTREADY;		/* ABL left requests outstanding: do not touch */
	nq = (int)(((cap_reg & 0x1f) + 1) / 2);
	if (nq > NQ)
		nq = NQ;
	if (nq < 1)
		return UFS_E_NOTREADY;

	/* drop whatever ABL's cache holds for our static memory before the first store */
	dc_flush(utrl, sizeof utrl);
	dc_flush(ucd, sizeof ucd);
	dc_flush(pbuf, sizeof pbuf);
	for (unsigned i = 0; i < 32; i++)
		w32(&utrl[i].dw2, 0x0f);
	dc_clean(utrl, sizeof utrl);

	/* take over the transfer request list: stop, point at ours, run */
	ufs_wr(REG_UTRLRSR, 0);
	uintptr_t list = (uintptr_t)utrl;
	ufs_wr(REG_UTRLBA, (uint32_t)list);
	ufs_wr(REG_UTRLBAU, (uint32_t)(list >> 32));
	ufs_wr(REG_UTRLRSR, 1);
	/* never ring a doorbell unless the host really uses our list (it would run ABL's leftovers) */
	if (ufs_rd(REG_UTRLBA) != (uint32_t)list || ufs_rd(REG_UTRLBAU) != (uint32_t)(list >> 32) ||
	    !(ufs_rd(REG_UTRLRSR) & 1))
		return UFS_E_NOTREADY;

	static const uint8_t tur[6] = { 0x00 };
	int rc = 0;
	for (int i = 0; i < 4; i++) {		/* the first command may report a unit attention */
		rc = scsi_sync(0, tur, sizeof tur, 0, 0, 0);
		if (!rc)
			break;
	}
	if (rc)
		return rc;
	inited = 1;
	return 0;
}

int ufs_lun_blocks(unsigned lun, uint64_t *nblk)
{
	static const uint8_t cdb[10] = { 0x25 };	/* READ CAPACITY(10) */
	int rc;

	if (!inited)
		return UFS_E_NOTREADY;
	rc = scsi_sync(lun, cdb, sizeof cdb, pbuf, 8, 2);
	if (rc)
		return rc;
	uint32_t last = be32(pbuf), blk = be32(pbuf + 4);
	if (blk != UFS_BLK)
		return ufs_last.rc = UFS_E_ARGS;
	*nblk = (uint64_t)last + 1;
	return 0;
}

/* ---- pipelined transfers ---- */

static struct {
	int active, err;
	uint8_t lun, write;
	uint8_t *buf;
	uint64_t lba, left;		/* not yet submitted */
	uint64_t done;			/* blocks completed */
	uint32_t inflight;		/* bit i = slot i */
	struct {
		uint64_t lba;
		uint32_t nblk;
		uint8_t *buf;
		uint64_t t0;
		uint8_t tries;
	} c[NQ];
} x;

static int xfer_issue(unsigned i, int retry)
{
	uint8_t cdb[10];
	uint32_t n = x.c[i].nblk;
	uint64_t lba = x.c[i].lba;

	cdb[0] = x.write ? 0x2a : 0x28;		/* WRITE(10) / READ(10) */
	cdb[1] = 0;
	cdb[2] = lba >> 24;
	cdb[3] = lba >> 16;
	cdb[4] = lba >> 8;
	cdb[5] = lba;
	cdb[6] = 0;
	cdb[7] = n >> 8;
	cdb[8] = n;
	cdb[9] = 0;
	(void)retry;
	int rc = cmd_submit(i, x.lun, cdb, 10, x.c[i].buf, n * UFS_BLK, x.write ? 1 : 2);
	if (rc)
		return rc;
	x.c[i].t0 = ticks();
	x.inflight |= 1u << i;
	return 0;
}

static int popcount8(uint32_t v)
{
	int n = 0;
	for (; v; v &= v - 1)
		n++;
	return n;
}

static void xfer_fill(void)
{
	for (int i = 0; i < nq && x.left && !x.err; i++) {
		if (x.inflight & (1u << i))
			continue;
		if (popcount8(x.inflight) >= qd)
			break;
		uint32_t n = x.left > CMD_BLKS ? CMD_BLKS : (uint32_t)x.left;
		x.c[i].lba = x.lba;
		x.c[i].nblk = n;
		x.c[i].buf = x.buf;
		x.c[i].tries = 0;
		int rc = xfer_issue(i, 0);
		if (rc) {
			x.err = rc;
			break;
		}
		x.lba += n;
		x.buf += (uint64_t)n * UFS_BLK;
		x.left -= n;
	}
}

static int x_active(void)
{
	return x.active;
}

int ufs_xfer_start(unsigned lun, uint64_t lba, uint64_t nblk, void *buf, int write)
{
	if (!inited)
		return UFS_E_NOTREADY;
	if (x.active || !nblk || ((uintptr_t)buf & (write ? 3 : 63)) || lba + nblk > 0xffffffffULL)
		return UFS_E_ARGS;
	x.active = 1;
	x.err = 0;
	x.lun = (uint8_t)lun;
	x.write = (uint8_t)write;
	x.buf = buf;
	x.lba = lba;
	x.left = nblk;
	x.done = 0;
	x.inflight = 0;
	xfer_fill();
	return 0;
}

int ufs_xfer_poll(int *rc)
{
	if (!x.active) {
		*rc = x.err;
		return 1;
	}
	uint32_t dbr = ufs_rd(REG_UTRLDBR);
	uint64_t now = ticks();

	for (int i = 0; i < nq; i++) {
		if (!(x.inflight & (1u << i)))
			continue;
		if (dbr & (1u << (2 * i))) {
			if (now - x.c[i].t0 > CMD_TIMEOUT) {
				slot_abort(i);
				x.inflight &= ~(1u << i);
				ufs_last.rc = UFS_E_TIMEOUT;
				if (!x.err)
					x.err = UFS_E_TIMEOUT;
				x.left = 0;
			}
			continue;
		}
		x.inflight &= ~(1u << i);
		if (!x.write)
			dc_inval(x.c[i].buf, (uint64_t)x.c[i].nblk * UFS_BLK);
		int r = cmd_result(i);
		if (r == UFS_E_SCSI && ufs_last.sense_key == 6 && x.c[i].tries < 3 && !x.err) {
			x.c[i].tries++;			/* unit attention: same command again */
			if (xfer_issue(i, 1) == 0)
				continue;
		}
		if (r) {
			if (!x.err)
				x.err = r;
			x.left = 0;
			continue;
		}
		x.done += x.c[i].nblk;
		if (x.write)
			ufs_blocks_written += x.c[i].nblk;
		else
			ufs_blocks_read += x.c[i].nblk;
	}
	xfer_fill();
	if (!x.inflight && !x.left) {
		x.active = 0;
		*rc = x.err;
		return 1;
	}
	return 0;
}

int ufs_xfer_wait(void)
{
	int rc;

	while (!ufs_xfer_poll(&rc))
		if (idle_fn)
			idle_fn();
	return rc;
}

uint64_t ufs_xfer_done_blocks(void)
{
	return x.done;
}

int ufs_read(unsigned lun, uint64_t lba, uint64_t nblk, void *dst)
{
	int rc = ufs_xfer_start(lun, lba, nblk, dst, 0);
	return rc ? rc : ufs_xfer_wait();
}

int ufs_write(unsigned lun, uint64_t lba, uint64_t nblk, const void *src)
{
	int rc = ufs_xfer_start(lun, lba, nblk, (void *)(uintptr_t)src, 1);
	return rc ? rc : ufs_xfer_wait();
}

int ufs_unmap(unsigned lun, uint64_t lba, uint64_t nblk)
{
	/* one block descriptor per command, at most 64 Ki blocks (256 MiB) each */
	while (nblk) {
		uint32_t n = nblk > 0x10000 ? 0x10000 : (uint32_t)nblk;
		uint8_t cdb[10] = { 0x42, 0, 0, 0, 0, 0, 0, 0, 24, 0 };	/* UNMAP, parameter list length 24 */
		dc_flush(pbuf, sizeof pbuf);
		for (unsigned i = 0; i < 24; i++)
			pbuf[i] = 0;
		pbuf[1] = 22;		/* UNMAP data length */
		pbuf[3] = 16;		/* block descriptor data length */
		for (unsigned b = 0; b < 8; b++)
			pbuf[8 + b] = (uint8_t)(lba >> (8 * (7 - b)));
		pbuf[16] = n >> 24;
		pbuf[17] = n >> 16;
		pbuf[18] = n >> 8;
		pbuf[19] = n;
		int rc = scsi_sync(lun, cdb, sizeof cdb, pbuf, 24, 1);
		if (rc)
			return rc;
		lba += n;
		nblk -= n;
	}
	return 0;
}

int ufs_sync(unsigned lun)
{
	static const uint8_t cdb[10] = { 0x35 };	/* SYNCHRONIZE CACHE(10): whole LUN */
	return scsi_sync(lun, cdb, sizeof cdb, 0, 0, 0);
}

/* ---- blkdev adapter for storage.c ---- */

static const char *rc_str(int rc)
{
	return rc ? ufs_errstr(rc) : 0;
}

static const char *bd_cap(void *ctx, unsigned lun, uint64_t *nblk)
{
	(void)ctx;
	return rc_str(ufs_lun_blocks(lun, nblk));
}

static const char *bd_read(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst)
{
	(void)ctx;
	return rc_str(ufs_read(lun, lba, nblk, dst));
}

static const char *bd_read_start(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst)
{
	(void)ctx;
	return rc_str(ufs_xfer_start(lun, lba, nblk, dst, 0));
}

static const char *bd_read_wait(void *ctx)
{
	(void)ctx;
	return rc_str(ufs_xfer_wait());
}

static const char *bd_write(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, const void *src)
{
	(void)ctx;
	return rc_str(ufs_write(lun, lba, nblk, src));
}

static const char *bd_unmap(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk)
{
	(void)ctx;
	return rc_str(ufs_unmap(lun, lba, nblk));
}

static const char *bd_sync(void *ctx, unsigned lun)
{
	(void)ctx;
	return rc_str(ufs_sync(lun));
}

void ufs_blkdev(struct blkdev *bd)
{
	bd->ctx = 0;
	bd->cap = bd_cap;
	bd->read = bd_read;
	bd->read_start = bd_read_start;
	bd->read_wait = bd_read_wait;
	bd->write = bd_write;
	bd->unmap = bd_unmap;
	bd->sync = bd_sync;
}

/* ---- boot-time read-only probe (legacy diagnostics path, enxerto.c) ---- */

static uint8_t data[2 * UFS_BLK] __attribute__((aligned(4096)));

static uint64_t le64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--)
		v = v << 8 | p[i];
	return v;
}

/* One line per GPT entry of at least 64 MiB: name, first LBA, size in MiB (4K blocks). */
static void list_partitions(uint32_t entry_lba, uint32_t nent)
{
	static uint8_t ents[128 * 128] __attribute__((aligned(4096)));
	uint32_t blocks = (nent * 128 + UFS_BLK - 1) / UFS_BLK;
	if (ufs_read(0, entry_lba, blocks, ents)) {
		con_str("UFS PART", "read error");
		return;
	}
	for (uint32_t i = 0; i < nent; i++) {
		const uint8_t *e = ents + i * 128;
		uint64_t first = le64(e + 32), last = le64(e + 40);
		if (!first)
			continue;
		char name[17];
		for (int c = 0; c < 16; c++) {
			uint8_t ch = e[56 + 2 * c];
			name[c] = (ch >= 32 && ch < 127) ? ch : (ch ? '?' : 0);
		}
		name[16] = 0;
		if (((last - first + 1) >> 8) < 64)	/* keep the screen to the big ones */
			continue;
		con_hex2(name, "lba=", (uint32_t)first, "MiB=", (uint32_t)((last - first + 1) >> 8));
	}
}

void test_ufs(void)
{
	con_str("UFS", "probe (read-only)");
	uint32_t cap = ufs_rd(REG_CAP), hcs = ufs_rd(REG_HCS), hce = ufs_rd(REG_HCE);
	con_hex2("UFS", "ver=", ufs_rd(REG_VER), "cap=", cap);
	con_hex2("UFS", "hce=", hce, "hcs=", hcs);
	con_hex2("UFS", "is=", ufs_rd(REG_IS), "rsr=", ufs_rd(REG_UTRLRSR));
	int rc = ufs_init();
	con_hex2("UFS", "init=", (uint32_t)rc, "nq=", (uint32_t)nq);
	if (rc)
		return;
	uint64_t blocks = 0;
	rc = ufs_lun_blocks(0, &blocks);
	con_hex2("UFS LUN0", "rc=", (uint32_t)rc, "blocks=", (uint32_t)blocks);
	if (rc)
		return;
	rc = ufs_read(0, 0, 2, data);
	con_hex2("UFS READ", "rc=", (uint32_t)rc, "ocs/st=", ufs_last.ocs << 8 | ufs_last.status);
	if (rc)
		return;
	con_hex2("UFS MBR", "sig=", data[510] | data[511] << 8, "type=", data[450]);
	const uint8_t *gpt = data + UFS_BLK;
	char sig[9];
	for (int i = 0; i < 8; i++)
		sig[i] = (gpt[i] >= 32 && gpt[i] < 127) ? gpt[i] : '.';
	sig[8] = 0;
	con_str("UFS GPT", sig);
	uint32_t nent = gpt[80] | gpt[81] << 8 | gpt[82] << 16, esz = gpt[84] | gpt[85] << 8;
	uint32_t elba = gpt[72] | gpt[73] << 8;
	con_hex2("UFS GPT", "entries=", nent, "lba=", elba);
	if (esz != 128 || nent > 128)
		return;
	list_partitions(elba, nent);
}
