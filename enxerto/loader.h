#pragma once
#include <stdint.h>

/* Boot the SWEETXNU payload found in the ABL ramdisk; returns only on error. */
const char *loader_boot(uintptr_t dtb);
/* Bergamota fastboot hooks: is there a SWEETXNU payload in the ABL ramdisk? */
int loader_has_payload(uintptr_t dtb);
/* Validate a payload at [rd_start, rd_end) without touching anything; NULL when it is safe to boot. */
const char *loader_check(uintptr_t rd_start, uintptr_t rd_end);
/*
 * Boot the payload at [rd_start, rd_end) (the fastboot download). verify=1 runs loader_check first.
 * Returns only on error; USB and the downloaded data must not be needed afterwards.
 */
const char *loader_boot_payload(uintptr_t rd_start, uintptr_t rd_end, int verify);
