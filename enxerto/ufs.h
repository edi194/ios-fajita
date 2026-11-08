#pragma once
/*
 * UFS host driver (UFSHCI, JESD223) for the internal UFS the stock ABL booted from, polled, one
 * request list of our own. Block size 4096 on every LUN of the Poco F1.
 *
 * Reads AND writes (SCSI READ(10) / WRITE(10)), UNMAP and SYNCHRONIZE CACHE. This driver is only the
 * transport: which blocks may be written is decided by storage.c (GPT + hard allowlist), the only
 * caller of ufs_write / ufs_unmap besides tests.
 *
 * DMA is NOT cache coherent on SDM845: every command cleans (device reads) or flushes before and
 * invalidates after (device writes) the data and the descriptors, see cache.h.
 */
#include <stdint.h>

#define UFS_BLK		4096u

/* return codes (0 = ok) */
#define UFS_E_NOTREADY	(-1)	/* host not enabled / not ready / outstanding requests */
#define UFS_E_TIMEOUT	(-2)
#define UFS_E_OCS	(-3)	/* host controller overall command status != success */
#define UFS_E_RESP	(-4)	/* not a RESPONSE UPIU / target failure */
#define UFS_E_SCSI	(-5)	/* SCSI status != GOOD (ufs_last has the sense data) */
#define UFS_E_ARGS	(-6)	/* misaligned buffer, DMA above 4 GiB, busy ... */

struct ufs_last {
	uint32_t ocs, status, sense_key, asc, ascq;
	int rc;
};
extern struct ufs_last ufs_last;

/* Counters for the screen / tests. */
extern uint64_t ufs_blocks_read, ufs_blocks_written;

void test_ufs(void);

/* Take over the transfer request list (idempotent). 0 or UFS_E_*. */
int ufs_init(void);
const char *ufs_errstr(int rc);
/* Commands in flight during a transfer: 1..8 (default 8). `oem ufsq:<n>`: 1 = no pipelining, for debugging on hardware. */
int ufs_set_depth(int n);
/* Called while waiting (screen refresh, USB keep-alive); may be NULL. */
void ufs_set_idle(void (*fn)(void));

/* READ CAPACITY(10): number of 4 KiB blocks of the LUN. */
int ufs_lun_blocks(unsigned lun, uint64_t *nblk);

/*
 * Asynchronous transfer of nblk blocks starting at lba, pipelined as 256 KiB commands with several in
 * flight. buf must be 64-byte aligned (reads: whole cache lines are invalidated). Only one transfer at
 * a time: ufs_xfer_start submits what fits, ufs_xfer_wait (or repeated ufs_xfer_poll) finishes it.
 * Between start and wait the CPU is free (e.g. to hash the previous chunk) but only the first few
 * commands fly without a poll.
 */
int ufs_xfer_start(unsigned lun, uint64_t lba, uint64_t nblk, void *buf, int write);
/* 1 = finished (result in *rc), 0 = still running */
int ufs_xfer_poll(int *rc);
int ufs_xfer_wait(void);
/* Blocks completed so far by the running/last transfer (progress). */
uint64_t ufs_xfer_done_blocks(void);

int ufs_read(unsigned lun, uint64_t lba, uint64_t nblk, void *dst);
int ufs_write(unsigned lun, uint64_t lba, uint64_t nblk, const void *src);
/* UNMAP (discard) of a block range; the device may refuse (not thin provisioned). */
int ufs_unmap(unsigned lun, uint64_t lba, uint64_t nblk);
/* SYNCHRONIZE CACHE(10) of the whole LUN: call after the last write. */
int ufs_sync(unsigned lun);

struct blkdev;
/* Fill a blkdev (storage.h) with the functions above. */
void ufs_blkdev(struct blkdev *bd);
