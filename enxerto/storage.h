#pragma once
/*
 * Allowlisted partition storage for Bergamota fastboot: GPT discovery over a block device (UFS on the
 * phone, an in-memory fake in the host tests) and the only write/erase/hash entry points.
 *
 * HARD ALLOWLIST: only "userdata", "boot" and "logo" can ever be found, hence written, erased or
 * hashed. stor_find() refuses every other name, and the partition table only ever holds allowlisted
 * entries, so nothing else is reachable even if a caller passes a bad name. The GPT itself is never
 * written: a partition must lie inside [first_usable_lba, last_usable_lba] of its LUN's header.
 * Blocks are 4096 bytes (UFS on this phone); all offsets and lengths are multiples of that.
 */
#include <stdint.h>

#define STOR_BLK	4096u
#define STOR_MAX_PARTS	8
#define STOR_SCRATCH	(4u << 20)	/* two 2 MiB halves, 4 KiB aligned, cache-line aligned */
#define STOR_HALF	(2u << 20)
#define STOR_HASH_LEN	16u		/* BLAKE2b-128 per block */

struct blkdev {
	void *ctx;
	/* block count of a LUN, error string if there is no such LUN */
	const char *(*cap)(void *ctx, unsigned lun, uint64_t *nblk);
	const char *(*read)(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst);
	/* asynchronous read: start, then wait (the CPU may work in between) */
	const char *(*read_start)(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, void *dst);
	const char *(*read_wait)(void *ctx);
	const char *(*write)(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk, const void *src);
	const char *(*unmap)(void *ctx, unsigned lun, uint64_t lba, uint64_t nblk);
	const char *(*sync)(void *ctx, unsigned lun);
};

struct stor_part {
	char name[16];
	uint8_t lun;
	uint64_t first, nblk;	/* LBA of the first block, size in blocks */
	uint8_t dup;		/* the name occurs more than once (refused) */
};

struct stor {
	struct blkdev bd;
	void *ctx;		/* passed to cached / progress */
	uint8_t *scratch;	/* STOR_SCRATCH bytes, 64-byte aligned, set by the platform */
	/*
	 * Platform hook: turn CPU caching on (on=1, [lo,hi) plus the scratch area become Normal write-back,
	 * used by hash and read-back verify) or off again. May be NULL (then everything works, only slow
	 * where the CPU touches data).
	 */
	void (*cached)(void *ctx, int on, const void *lo, const void *hi);
	/* bytes processed since the last call (progress, UI refresh); may be NULL */
	void (*progress)(void *ctx, uint64_t bytes);
	int verify;		/* read back and compare everything written */
	uint64_t bad_off;	/* byte offset (inside the partition) of the first verify mismatch */
	uint32_t fill_pat;	/* scratch half A holds this pattern for fill_len bytes (0 = invalid) */
	uint64_t fill_len;
	unsigned nparts, luns_found;
	int scanned;
	const char *scan_err;
	struct stor_part parts[STOR_MAX_PARTS];
	/* diagnostics: GPT of each LUN scanned (entries, names seen) for `oem gpt` */
	struct {
		uint8_t lun, valid;
		uint32_t entries;
		uint64_t blocks;
	} lun_info[8];
};

int stor_name_allowed(const char *name);
/* Scan LUN 0..7 for valid GPTs, record allowlisted partitions. NULL or an error. Re-scans if called again. */
const char *stor_scan(struct stor *s);
/* Allowlisted partition by exact name (scans first if needed); NULL + *why if unknown/not allowed/ambiguous. */
const struct stor_part *stor_find(struct stor *s, const char *name, const char **why);

/* off/len multiples of STOR_BLK, inside the partition. */
const char *stor_write(struct stor *s, const struct stor_part *p, uint64_t off, const uint8_t *src, uint64_t len);
const char *stor_fill(struct stor *s, const struct stor_part *p, uint64_t off, uint64_t len, uint32_t pattern);
/* Whole partition: UNMAP, falling back to zeroing for partitions <= 1 GiB. */
const char *stor_erase(struct stor *s, const struct stor_part *p);
/*
 * Per-block BLAKE2b-128 of [off, off+len) in blocks of bs bytes (bs: power of two, 4 KiB..2 MiB; the
 * last block may be shorter) into out (16 bytes per block).
 */
const char *stor_hash(struct stor *s, const struct stor_part *p, uint64_t off, uint64_t len, uint32_t bs, uint8_t *out);
/*
 * Read-only self test of the read path with DIRTY CPU caches (the failure mode of a driver without DMA
 * cache maintenance): inside a cached window both scratch halves are filled with patterns (dirty lines),
 * the same 2 MiB at the start of the partition is read into both halves, and the halves must be equal and
 * must not contain the old pattern. Repeated for three offsets. NULL = pass.
 */
const char *stor_selftest(struct stor *s, const struct stor_part *p);
/* Call after the last write of a flash: flush the device cache. */
const char *stor_sync(struct stor *s, const struct stor_part *p);
