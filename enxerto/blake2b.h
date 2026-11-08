#pragma once
#include <stdint.h>
/*
 * BLAKE2b (RFC 7693), unkeyed, one-shot. blake2b(out, 16, data, len) equals Python's
 * hashlib.blake2b(data, digest_size=16).digest(): the per-block hash of `oem hash`.
 * Little-endian CPUs only (the message words are read in place when 8-byte aligned).
 */
void blake2b(uint8_t *out, unsigned outlen, const uint8_t *in, uint64_t inlen);
