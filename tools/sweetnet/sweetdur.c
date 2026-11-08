/*
 * sweetdur: UFS/HFS durability test for the Poco F1 root (kernel patch 0221).
 *
 *   sweetdur write [-a] [-s] [-F] [-S] DIR COUNT SIZE [SEED]
 *       create COUNT files DIR/dur-NNNNN of SIZE bytes each with a pattern that depends on
 *       (SEED, file index, offset) and a manifest DIR/.sweetdur-manifest. Options:
 *         -a  atomic write like cfprefsd: DIR/.tmp-NNNNN, then rename over the final name
 *         -s  fsync(2) every file       -F  fcntl(F_FULLFSYNC) every file
 *         -S  sync(2) once at the end   (none of these: leave it all to the kernel)
 *   sweetdur verify DIR
 *       read the manifest, check every file (exists, size, contents); distinguishes "all zero"
 *       (data never landed), "wrong size", read errors (EIO/EINVAL) and other mismatches.
 *       Exit status 0 = all good, 1 = damage, 2 = usage / no manifest.
 *   sweetdur stats
 *       print every kern.sweet_ufs.* counter (patch 0221).
 *   sweetdur flush
 *       sysctl kern.sweet_ufs.flush=1 (VFS sync of every mount + SYNCHRONIZE CACHE).
 *
 * Typical durability run (see the test plan): write, then reboot WITHOUT running sync, then
 * verify. The pattern is never all zeros, so a zero-filled file is always a lost write.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define CHUNK 65536

static uint64_t
mix(uint64_t x)
{
	x ^= x >> 33;
	x *= 0xff51afd7ed558ccdull;
	x ^= x >> 33;
	x *= 0xc4ceb9fe1a85ec53ull;
	x ^= x >> 33;
	return x;
}

/* 8 byte word w of file idx; never 0 */
static uint64_t
word(uint64_t seed, uint64_t idx, uint64_t w)
{
	uint64_t v = mix(seed ^ mix(idx * 0x9e3779b97f4a7c15ull + w));
	return v ? v : 1;
}

static void
fill(uint8_t *buf, size_t len, uint64_t seed, uint64_t idx, uint64_t off)
{
	for (size_t i = 0; i < len; i += 8) {
		uint64_t v = word(seed, idx, (off + i) / 8);
		size_t n = len - i < 8 ? len - i : 8;
		memcpy(buf + i, &v, n);
	}
}

static const char *const counters[] = {
	"reads", "read_blocks", "writes", "write_blocks", "flushes", "flush_errors", "errors",
	"cmd_failures", "timeouts", "retries", "is_errors", "resid_nonzero", "strat_reads",
	"strat_writes", "strat_errors", "strat_rmw", "fua_writes", "verify_ok", "verify_bad",
	"verify_io_errors", "syncer_runs", "syncer_errors", "ioctl_syncs", "user_flushes",
	"final_flushes", "final_flush_skipped", NULL
};

static int
get_counter(const char *name, uint64_t *out)
{
	char key[64];
	size_t len = sizeof(*out);
	snprintf(key, sizeof(key), "kern.sweet_ufs.%s", name);
	*out = 0;
	return sysctlbyname(key, out, &len, NULL, 0);
}

static int
get_uint(const char *name, unsigned *out)
{
	char key[64];
	size_t len = sizeof(*out);
	snprintf(key, sizeof(key), "kern.sweet_ufs.%s", name);
	*out = 0;
	return sysctlbyname(key, out, &len, NULL, 0);
}

static void
print_stats(void)
{
	uint64_t v;
	if (get_counter("writes", &v) != 0) {
		printf("kern.sweet_ufs.* missing (kernel without patch 0221)\n");
		return;
	}
	for (int i = 0; counters[i]; i++) {
		get_counter(counters[i], &v);
		printf("kern.sweet_ufs.%s = %llu\n", counters[i], (unsigned long long)v);
	}
	const char *u[] = { "last_cdb", "last_ocs", "last_status", "last_sense", "last_is", "last_hcs",
		            "cfg_verify", "cfg_fua", "cfg_retries", "cfg_syncsecs", NULL };
	for (int i = 0; u[i]; i++) {
		unsigned x;
		get_uint(u[i], &x);
		printf("kern.sweet_ufs.%s = 0x%x\n", u[i], x);
	}
}

static int
cmd_flush(void)
{
	int one = 1;
	if (sysctlbyname("kern.sweet_ufs.flush", NULL, NULL, &one, sizeof(one)) != 0) {
		perror("sysctl kern.sweet_ufs.flush");
		return 1;
	}
	printf("flushed\n");
	return 0;
}

static int
cmd_write(int argc, char **argv)
{
	int atomic = 0, fsyncs = 0, full = 0, sync_end = 0, i = 0;
	for (; i < argc && argv[i][0] == '-'; i++) {
		for (const char *o = argv[i] + 1; *o; o++) {
			switch (*o) {
			case 'a': atomic = 1; break;
			case 's': fsyncs = 1; break;
			case 'F': full = 1; break;
			case 'S': sync_end = 1; break;
			default: return 2;
			}
		}
	}
	if (argc - i < 3) {
		return 2;
	}
	const char *dir = argv[i];
	long count = atol(argv[i + 1]);
	long size = atol(argv[i + 2]);
	uint64_t seed = argc - i > 3 ? strtoull(argv[i + 3], NULL, 0) : (uint64_t)time(NULL);
	if (count <= 0 || size <= 0) {
		return 2;
	}
	mkdir(dir, 0755);
	uint64_t w0 = 0, w1 = 0;
	get_counter("write_blocks", &w0);
	uint8_t *buf = malloc(CHUNK);
	int bad = 0;
	for (long n = 0; n < count; n++) {
		char path[1024], tmp[1024];
		snprintf(path, sizeof(path), "%s/dur-%05ld", dir, n);
		snprintf(tmp, sizeof(tmp), "%s/.tmp-%05ld", dir, n);
		const char *target = atomic ? tmp : path;
		int fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			fprintf(stderr, "open %s: %s\n", target, strerror(errno));
			bad++;
			continue;
		}
		for (long off = 0; off < size; off += CHUNK) {
			size_t len = size - off < CHUNK ? (size_t)(size - off) : CHUNK;
			fill(buf, len, seed, (uint64_t)n, (uint64_t)off);
			if (write(fd, buf, len) != (ssize_t)len) {
				fprintf(stderr, "write %s @%ld: %s\n", target, off, strerror(errno));
				bad++;
				break;
			}
		}
		if (fsyncs && fsync(fd) != 0) {
			fprintf(stderr, "fsync %s: %s\n", target, strerror(errno));
			bad++;
		}
		if (full && fcntl(fd, F_FULLFSYNC) != 0) {
			fprintf(stderr, "F_FULLFSYNC %s: %s\n", target, strerror(errno));
			bad++;
		}
		close(fd);
		if (atomic && rename(tmp, path) != 0) {
			fprintf(stderr, "rename %s: %s\n", tmp, strerror(errno));
			bad++;
		}
	}
	char mpath[1024];
	snprintf(mpath, sizeof(mpath), "%s/.sweetdur-manifest", dir);
	FILE *m = fopen(mpath, "w");
	if (!m) {
		perror("manifest");
		return 1;
	}
	fprintf(m, "%ld %ld %llu\n", count, size, (unsigned long long)seed);
	if (fsyncs || full) {
		fflush(m);
		fsync(fileno(m));
	}
	fclose(m);
	if (sync_end) {
		sync();
	}
	get_counter("write_blocks", &w1);
	printf("wrote %ld files x %ld bytes, seed %llu, atomic %d fsync %d fullfsync %d sync %d, %d errors; "
	    "device blocks written %llu\n", count, size, (unsigned long long)seed, atomic, fsyncs, full,
	    sync_end, bad, (unsigned long long)(w1 - w0));
	printf("NOT durable until the kernel syncer (<= ufssyncsecs) or sync/fsync ran; now reboot and run: sweetdur verify %s\n", dir);
	return bad ? 1 : 0;
}

static int
cmd_verify(const char *dir)
{
	char mpath[1024];
	snprintf(mpath, sizeof(mpath), "%s/.sweetdur-manifest", dir);
	FILE *m = fopen(mpath, "r");
	long count, size;
	unsigned long long seed;
	if (!m || fscanf(m, "%ld %ld %llu", &count, &size, &seed) != 3) {
		fprintf(stderr, "no readable manifest %s (%s)\n", mpath, strerror(errno));
		return 2;
	}
	fclose(m);
	uint8_t *buf = malloc(CHUNK), *want = malloc(CHUNK);
	long ok = 0, missing = 0, wrongsize = 0, zero = 0, partial_zero = 0, mismatch = 0, ioerr = 0;
	for (long n = 0; n < count; n++) {
		char path[1024];
		snprintf(path, sizeof(path), "%s/dur-%05ld", dir, n);
		int fd = open(path, O_RDONLY);
		if (fd < 0) {
			if (errno == ENOENT) {
				missing++;
			} else {
				ioerr++;
			}
			printf("%s: open: %s\n", path, strerror(errno));
			continue;
		}
		struct stat st;
		if (fstat(fd, &st) != 0 || st.st_size != size) {
			wrongsize++;
			printf("%s: size %lld, want %ld\n", path, fd >= 0 ? (long long)st.st_size : -1LL, size);
			close(fd);
			continue;
		}
		long nonzero = 0, bad_at = -1;
		int err = 0;
		for (long off = 0; off < size && !err; off += CHUNK) {
			size_t len = size - off < CHUNK ? (size_t)(size - off) : CHUNK;
			ssize_t r = pread(fd, buf, len, off);
			if (r != (ssize_t)len) {
				printf("%s: read @%ld: %s\n", path, off, r < 0 ? strerror(errno) : "short");
				err = 1;
				break;
			}
			fill(want, len, seed, (uint64_t)n, (uint64_t)off);
			for (size_t i = 0; i < len; i++) {
				if (buf[i]) {
					nonzero++;
				}
			}
			if (bad_at < 0 && memcmp(buf, want, len) != 0) {
				size_t i = 0;
				while (buf[i] == want[i]) {
					i++;
				}
				bad_at = off + (long)i;
			}
		}
		close(fd);
		if (err) {
			ioerr++;
		} else if (bad_at < 0) {
			ok++;
		} else if (nonzero == 0) {
			zero++;
			printf("%s: ALL ZERO (size ok)\n", path);
		} else {
			mismatch++;
			printf("%s: contents differ from byte %ld (%ld nonzero bytes)%s\n", path, bad_at, nonzero,
			    "");
			(void)partial_zero;
		}
	}
	printf("verify %s: %ld files, ok %ld, all-zero %ld, mismatch %ld, wrong size %ld, missing %ld, io errors %ld\n",
	    dir, count, ok, zero, mismatch, wrongsize, missing, ioerr);
	return ok == count ? 0 : 1;
}

int
main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "stats")) {
		print_stats();
		return 0;
	}
	if (argc >= 2 && !strcmp(argv[1], "flush")) {
		return cmd_flush();
	}
	if (argc >= 3 && !strcmp(argv[1], "verify")) {
		return cmd_verify(argv[2]);
	}
	if (argc >= 2 && !strcmp(argv[1], "write")) {
		int r = cmd_write(argc - 2, argv + 2);
		if (r != 2) {
			return r;
		}
	}
	fprintf(stderr, "usage: sweetdur write [-a] [-s] [-F] [-S] DIR COUNT SIZE [SEED] | verify DIR | stats | flush\n");
	return 2;
}
