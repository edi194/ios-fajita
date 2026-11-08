/*
 * Compact DEFLATE decoder in the style of Mark Adler's puff.c (zlib license: the structure, canonical Huffman
 * count/symbol tables and the bit-at-a-time decode loop follow puff). Freestanding, writes through a volatile
 * byte pointer so it is safe on Device memory. Host test: shim/inflate_test.c (compares against zlib).
 */
#include <stdint.h>
#include "inflate.h"

#define MAXBITS		15
#define MAXLCODES	286
#define MAXDCODES	30
#define MAXCODES	(MAXLCODES + MAXDCODES)
#define FIXLCODES	288

struct state {
	volatile uint8_t *out;
	uint64_t outlen, outcnt, next_progress;
	const uint8_t *in;
	uint64_t inlen, incnt;
	uint32_t bitbuf;
	int bitcnt;
	void (*progress)(uint64_t);
};

struct huffman {
	int16_t count[MAXBITS + 1];
	int16_t symbol[MAXCODES + 2];
};

static int bits(struct state *s, int need)
{
	uint32_t val = s->bitbuf;
	while (s->bitcnt < need) {
		if (s->incnt >= s->inlen)
			return -1;
		val |= (uint32_t)s->in[s->incnt++] << s->bitcnt;
		s->bitcnt += 8;
	}
	s->bitbuf = val >> need;
	s->bitcnt -= need;
	return (int)(val & ((1UL << need) - 1));
}

static int decode(struct state *s, const struct huffman *h)
{
	int code = 0, first = 0, index = 0;
	for (int len = 1; len <= MAXBITS; len++) {
		int b = bits(s, 1);
		if (b < 0)
			return -1;
		code |= b;
		int count = h->count[len];
		if (code - count < first)
			return h->symbol[index + (code - first)];
		index += count;
		first += count;
		first <<= 1;
		code <<= 1;
	}
	return -2;
}

static int construct(struct huffman *h, const int16_t *length, int n)
{
	int16_t offs[MAXBITS + 1];
	for (int len = 0; len <= MAXBITS; len++)
		h->count[len] = 0;
	for (int symbol = 0; symbol < n; symbol++)
		h->count[length[symbol]]++;
	if (h->count[0] == n)
		return 0;
	int left = 1;
	for (int len = 1; len <= MAXBITS; len++) {
		left <<= 1;
		left -= h->count[len];
		if (left < 0)
			return left;
	}
	offs[1] = 0;
	for (int len = 1; len < MAXBITS; len++)
		offs[len + 1] = offs[len] + h->count[len];
	for (int symbol = 0; symbol < n; symbol++)
		if (length[symbol] != 0)
			h->symbol[offs[length[symbol]]++] = symbol;
	return left;
}

static int codes(struct state *s, const struct huffman *lencode, const struct huffman *distcode)
{
	static const int16_t lens[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
					 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
	static const int16_t lext[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
					 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
	static const int16_t dists[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
					  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
					  8193, 12289, 16385, 24577};
	static const int16_t dext[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
					 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
	int symbol;
	do {
		symbol = decode(s, lencode);
		if (symbol < 0)
			return symbol;
		if (symbol < 256) {
			if (s->outcnt == s->outlen)
				return -10;
			s->out[s->outcnt++] = (uint8_t)symbol;
		} else if (symbol > 256) {
			symbol -= 257;
			if (symbol >= 29)
				return -11;
			int e = bits(s, lext[symbol]);
			if (e < 0)
				return -1;
			int len = lens[symbol] + e;
			symbol = decode(s, distcode);
			if (symbol < 0)
				return symbol;
			if (symbol >= 30)
				return -12;
			e = bits(s, dext[symbol]);
			if (e < 0)
				return -1;
			uint64_t dist = dists[symbol] + e;
			if (dist > s->outcnt)
				return -13;
			if (s->outcnt + len > s->outlen)
				return -10;
			while (len--) {
				s->out[s->outcnt] = s->out[s->outcnt - dist];
				s->outcnt++;
			}
		}
		if (s->progress && s->outcnt >= s->next_progress) {
			s->progress(s->outcnt);
			s->next_progress = s->outcnt + (1UL << 20);
		}
	} while (symbol != 256);
	return 0;
}

static int stored(struct state *s)
{
	s->bitbuf = 0;
	s->bitcnt = 0;
	if (s->incnt + 4 > s->inlen)
		return -1;
	unsigned len = s->in[s->incnt++];
	len |= (unsigned)s->in[s->incnt++] << 8;
	unsigned nlen = s->in[s->incnt++];
	nlen |= (unsigned)s->in[s->incnt++] << 8;
	if (len != (~nlen & 0xffff))
		return -14;
	if (s->incnt + len > s->inlen)
		return -1;
	if (s->outcnt + len > s->outlen)
		return -10;
	while (len--)
		s->out[s->outcnt++] = s->in[s->incnt++];
	return 0;
}

static int fixed(struct state *s)
{
	struct huffman lencode, distcode;
	int16_t lengths[FIXLCODES];
	int symbol;
	for (symbol = 0; symbol < 144; symbol++)
		lengths[symbol] = 8;
	for (; symbol < 256; symbol++)
		lengths[symbol] = 9;
	for (; symbol < 280; symbol++)
		lengths[symbol] = 7;
	for (; symbol < FIXLCODES; symbol++)
		lengths[symbol] = 8;
	construct(&lencode, lengths, FIXLCODES);
	for (symbol = 0; symbol < MAXDCODES; symbol++)
		lengths[symbol] = 5;
	construct(&distcode, lengths, MAXDCODES);
	return codes(s, &lencode, &distcode);
}

static int dynamic(struct state *s)
{
	static const int16_t order[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
	int16_t lengths[MAXCODES];
	struct huffman lencode, distcode;
	int nlen = bits(s, 5), ndist = bits(s, 5), ncode = bits(s, 4);
	if (nlen < 0 || ndist < 0 || ncode < 0)
		return -1;
	nlen += 257;
	ndist += 1;
	ncode += 4;
	if (nlen > MAXLCODES || ndist > MAXDCODES)
		return -15;
	int index;
	for (index = 0; index < ncode; index++) {
		int b = bits(s, 3);
		if (b < 0)
			return -1;
		lengths[order[index]] = (int16_t)b;
	}
	for (; index < 19; index++)
		lengths[order[index]] = 0;
	if (construct(&lencode, lengths, 19) != 0)
		return -16;
	index = 0;
	while (index < nlen + ndist) {
		int symbol = decode(s, &lencode);
		if (symbol < 0)
			return symbol;
		if (symbol < 16) {
			lengths[index++] = (int16_t)symbol;
		} else {
			int len = 0, rep;
			if (symbol == 16) {
				if (index == 0)
					return -17;
				len = lengths[index - 1];
				rep = bits(s, 2);
				if (rep < 0)
					return -1;
				rep += 3;
			} else if (symbol == 17) {
				rep = bits(s, 3);
				if (rep < 0)
					return -1;
				rep += 3;
			} else {
				rep = bits(s, 7);
				if (rep < 0)
					return -1;
				rep += 11;
			}
			if (index + rep > nlen + ndist)
				return -18;
			while (rep--)
				lengths[index++] = (int16_t)len;
		}
	}
	if (lengths[256] == 0)
		return -19;
	int err = construct(&lencode, lengths, nlen);
	if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1]))
		return -20;
	err = construct(&distcode, lengths + nlen, ndist);
	if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1]))
		return -21;
	return codes(s, &lencode, &distcode);
}

int inflate_raw(const uint8_t *in, uint64_t inlen, volatile uint8_t *out, uint64_t *outlen,
		void (*progress)(uint64_t))
{
	struct state s;
	s.out = out;
	s.outlen = *outlen;
	s.outcnt = 0;
	s.in = in;
	s.inlen = inlen;
	s.incnt = 0;
	s.bitbuf = 0;
	s.bitcnt = 0;
	s.progress = progress;
	s.next_progress = 1UL << 20;
	int last, err = 0;
	do {
		last = bits(&s, 1);
		int type = bits(&s, 2);
		if (last < 0 || type < 0)
			return -1;
		err = type == 0 ? stored(&s) : type == 1 ? fixed(&s) : type == 2 ? dynamic(&s) : -3;
		if (err)
			break;
	} while (!last);
	*outlen = s.outcnt;
	return err;
}
