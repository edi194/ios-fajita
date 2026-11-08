#pragma once
#include <stdint.h>

#include "board.h"

struct mmu_info {
	uint64_t img_lo, img_hi, ttbr;
	uint64_t sctlr_before, sctlr_after;
	int n_l3;
};

struct mmu_range {
	uint64_t lo, hi;	/* physical, [lo, hi) */
};

int mmu_enable(struct mmu_info *info);
/*
 * Like mmu_enable, plus Normal write-back for each extra range (rounded out to
 * 16K pages; whole 32MB blocks when a range covers them). Only pass memory
 * that is ours (payload, kernel destination): see the XPU note in mmu.c.
 */
int mmu_enable_ranges(struct mmu_info *info, const struct mmu_range *r, int n);
/*
 * Leave the MMU and caches and jump: clean+invalidate every range to PoC
 * (also the image, so the stack is in memory), turn off M/C/I, invalidate the
 * ranges again (lines refilled speculatively before the switch), the TLBs and
 * the I-cache, then branch to entry with x0 = arg. Uses no memory after the
 * first clean. Also fine to call with the MMU already off. start.S.
 */
void __attribute__((noreturn)) mmu_off_jump(uint64_t entry, uint64_t arg, const struct mmu_range r[3]);
/*
 * Leave the MMU/D-cache and RETURN to the caller (the counterpart of mmu_enable_ranges for a temporary
 * cached window): same cleaning as mmu_off_jump over the three ranges (pass the image, and the extra
 * ranges rounded like mmu_enable_ranges does). start.S.
 */
void mmu_off_ret(const struct mmu_range r[3]);
uint64_t mmu_probe(uintptr_t va);
