/* Host test: cc -O2 -o out/inflate_test inflate.c inflate_test.c -lz && out/inflate_test FILE... */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "inflate.h"

static void prog(uint64_t n) { fprintf(stderr, "  progress %llu MiB\n", (unsigned long long)(n >> 20)); }

int main(int argc, char **argv)
{
	int bad = 0;
	for (int a = 1; a < argc; a++) {
		FILE *f = fopen(argv[a], "rb");
		if (!f) { perror(argv[a]); return 2; }
		fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
		unsigned char *src = malloc(n ? n : 1);
		if (fread(src, 1, n, f) != (size_t)n) return 2;
		fclose(f);
		for (int level = 0; level <= 9; level += (level == 0 ? 1 : (level < 6 ? 5 : 3))) {
			uLongf cap = compressBound(n);
			unsigned char *z = malloc(cap);
			z_stream zs; memset(&zs, 0, sizeof zs);
			deflateInit2(&zs, level, Z_DEFLATED, -15, 9, level == 1 ? Z_FIXED : Z_DEFAULT_STRATEGY);
			zs.next_in = src; zs.avail_in = n; zs.next_out = z; zs.avail_out = cap;
			deflate(&zs, Z_FINISH);
			uint64_t zl = zs.total_out; deflateEnd(&zs);
			unsigned char *out = malloc(n + 16);
			uint64_t ol = n + 16;
			int rc = inflate_raw(z, zl, out, &ol, n > (16 << 20) ? prog : NULL);
			int ok = rc == 0 && ol == (uint64_t)n && memcmp(out, src, n) == 0;
			printf("%s level %d: %ld -> %llu, %s (rc %d)\n", argv[a], level, n, (unsigned long long)zl, ok ? "OK" : "MISMATCH", rc);
			bad += !ok;
			free(z); free(out);
		}
		free(src);
	}
	return bad != 0;
}
