/* Android sparse image parser, see sparse.h. */
#include "sparse.h"

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint32_t le16(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8;
}

int sparse_is(const uint8_t *img, uint64_t len)
{
	return len >= 4 && le32(img) == SPARSE_MAGIC;
}

/* pass 0: validate (and count), pass 1: apply. Same walk, so what was validated is what runs. */
static const char *walk(const uint8_t *img, uint64_t len, uint64_t limit, const struct sparse_ops *ops,
			struct sparse_stats *st, int pass)
{
	uint32_t fhs, chs, bs, total_blks, nchunks;
	uint64_t pos, blk = 0;

	if (len < 28 || le32(img) != SPARSE_MAGIC)
		return "not a sparse image";
	if (le16(img + 4) != 1)
		return "unsupported sparse major version";
	fhs = le16(img + 8);
	chs = le16(img + 10);
	bs = le32(img + 12);
	total_blks = le32(img + 16);
	nchunks = le32(img + 20);
	if (fhs < 28 || chs < 12 || fhs > len)
		return "bad sparse header sizes";
	if (!bs || (bs & 4095) || bs > (64u << 20))
		return "sparse block size must be a multiple of 4096";
	if (limit && (uint64_t)total_blks * bs > limit)
		return "sparse image is larger than the partition";
	if (!pass) {
		st->total = (uint64_t)total_blks * bs;
		st->raw = st->fill = st->skip = 0;
		st->blk_sz = bs;
		st->chunks = nchunks;
	}
	pos = fhs;
	for (uint32_t i = 0; i < nchunks; i++) {
		uint32_t type, csz, tsz;
		uint64_t bytes, dpos;

		if (pos + chs > len)
			return "sparse image truncated (chunk header)";
		type = le16(img + pos);
		csz = le32(img + pos + 4);
		tsz = le32(img + pos + 8);
		bytes = (uint64_t)csz * bs;
		if (tsz < chs || pos + tsz > len)
			return "sparse image truncated (chunk)";
		dpos = pos + chs;
		if (blk + csz > total_blks)
			return "sparse chunks exceed the image size";
		switch (type) {
		case SPARSE_RAW:
			if ((uint64_t)tsz != chs + bytes)
				return "bad RAW chunk size";
			if (pass) {
				const char *e = ops->raw(ops->ctx, blk * bs, img + dpos, bytes);
				if (e)
					return e;
			} else {
				st->raw += bytes;
			}
			break;
		case SPARSE_FILL:
			if (tsz != chs + 4)
				return "bad FILL chunk size";
			if (pass) {
				const char *e = ops->fill(ops->ctx, blk * bs, bytes, le32(img + dpos));
				if (e)
					return e;
			} else {
				st->fill += bytes;
			}
			break;
		case SPARSE_SKIP:
			if (tsz != chs)
				return "bad DONT_CARE chunk size";
			if (!pass)
				st->skip += bytes;
			break;
		case SPARSE_CRC:
			if (tsz != chs + 4 || csz)
				return "bad CRC32 chunk size";
			break;
		default:
			return "unknown sparse chunk type";
		}
		blk += csz;
		pos += tsz;
	}
	return 0;
}

const char *sparse_apply(const uint8_t *img, uint64_t len, uint64_t limit, const struct sparse_ops *ops,
			 struct sparse_stats *st)
{
	struct sparse_stats local;
	const char *e = walk(img, len, limit, ops, st ? st : &local, 0);

	if (e || !ops)
		return e;
	return walk(img, len, limit, ops, st ? st : &local, 1);
}
