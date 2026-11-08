#pragma once
/*
 * Android sparse image parser (libsparse format, sparse_format.h): header 28 bytes, chunks RAW (0xCAC1),
 * FILL (0xCAC2), DONT_CARE (0xCAC3), CRC32 (0xCAC4). Pure code, host tested.
 *
 * `fastboot -S 512M flash` sends every piece as a complete sparse image whose chunk offsets start at 0
 * of the partition (leading DONT_CARE for the part that is not in this piece), so a piece is applied
 * on its own as soon as it has arrived: that is how images much bigger than the download buffer work.
 * Block size must be a multiple of 4096 (the UFS block). The whole piece is validated before the first
 * byte is written.
 */
#include <stdint.h>

#define SPARSE_MAGIC	0xed26ff3aU
#define SPARSE_RAW	0xcac1
#define SPARSE_FILL	0xcac2
#define SPARSE_SKIP	0xcac3
#define SPARSE_CRC	0xcac4

struct sparse_stats {
	uint64_t total;		/* expanded size in bytes (total_blks * blk_sz) */
	uint64_t raw, fill, skip;	/* bytes covered by each chunk kind */
	uint32_t blk_sz, chunks;
};

struct sparse_ops {
	void *ctx;
	/* data points into the image; off is the byte offset inside the partition; NULL = ok else error text */
	const char *(*raw)(void *ctx, uint64_t off, const uint8_t *data, uint64_t len);
	const char *(*fill)(void *ctx, uint64_t off, uint64_t len, uint32_t pattern);
};

int sparse_is(const uint8_t *img, uint64_t len);
/*
 * Validate the image (limit = partition size in bytes, 0 = no limit) and, if ops != NULL, apply it in
 * order. Returns NULL or a short reason. st (optional) is filled by the validation.
 */
const char *sparse_apply(const uint8_t *img, uint64_t len, uint64_t limit, const struct sparse_ops *ops,
			 struct sparse_stats *st);
