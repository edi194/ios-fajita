#pragma once
#include <stdint.h>

/*
 * Raw DEFLATE (RFC 1951) decoder for the loader: no libc, no allocation, byte accesses only (the MMU is off,
 * so memory is Device-nGnRnE and every access must be naturally aligned; bytes always are).
 * Returns 0 on success, a negative error otherwise. *outlen is the capacity on entry and the decoded size on exit.
 * progress(done_bytes) is called about every 1 MiB of output (may be NULL).
 */
int inflate_raw(const uint8_t *in, uint64_t inlen, volatile uint8_t *out, uint64_t *outlen,
		void (*progress)(uint64_t));
