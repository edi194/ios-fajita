#pragma once
/*
 * Data cache maintenance by VA to the point of coherency, for DMA with devices that are NOT cache
 * coherent (the SDM845 UFS host and USB controller have no dma-coherent in the live DT).
 *
 *   dc_clean(a, n)  CPU wrote, device will READ the memory:  push dirty lines out (dc cvac)
 *   dc_flush(a, n)  device will WRITE the memory:           clean+invalidate (dc civac) BEFORE the DMA,
 *                   so a dirty line can never be evicted over the data the device delivers
 *   dc_inval(a, n)  device WROTE the memory, CPU reads it:  discard stale lines (dc ivac) AFTER the DMA
 *
 * Always call them with the exact rule above, whatever the current MMU state: with the MMU off they
 * only drop stale lines ABL left behind (harmless), with Normal write-back mappings (the cached window
 * of mmu.c) they are what makes DMA correct. dc_inval on a line that holds CPU data not yet cleaned
 * LOSES that data, so only use it on ranges that were flushed first and are not written by the CPU
 * in the meantime (whole cache lines: callers keep DMA buffers 64-byte aligned).
 */
#include <stdint.h>

static inline uint64_t dc_line(void)
{
	uint64_t ctr;
	__asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
	return 4UL << ((ctr >> 16) & 0xf);
}

static inline void dc_clean(const void *a, uint64_t n)
{
	uint64_t line = dc_line();
	uintptr_t s = (uintptr_t)a & ~(line - 1), e = (uintptr_t)a + n;
	__asm__ volatile("dsb sy" ::: "memory");
	for (; s < e; s += line)
		__asm__ volatile("dc cvac, %0" : : "r"(s) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static inline void dc_flush(const void *a, uint64_t n)
{
	uint64_t line = dc_line();
	uintptr_t s = (uintptr_t)a & ~(line - 1), e = (uintptr_t)a + n;
	__asm__ volatile("dsb sy" ::: "memory");
	for (; s < e; s += line)
		__asm__ volatile("dc civac, %0" : : "r"(s) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}

static inline void dc_inval(const void *a, uint64_t n)
{
	uint64_t line = dc_line();
	uintptr_t s = (uintptr_t)a & ~(line - 1), e = (uintptr_t)a + n;
	__asm__ volatile("dsb sy" ::: "memory");
	for (; s < e; s += line)
		__asm__ volatile("dc ivac, %0" : : "r"(s) : "memory");
	__asm__ volatile("dsb sy" ::: "memory");
}
