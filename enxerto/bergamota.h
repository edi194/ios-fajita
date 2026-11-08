#pragma once
#include <stdint.h>

/*
 * Bergamota fastboot glue (docs/BERGAMOTA_FASTBOOT.md): USB + protocol + screen + boot/reset.
 *
 * Entry: /chosen bootargs "bergamota.fastboot=1" (boot.img cmdline) forces it, "=0" forbids it;
 * without the flag it runs when the ABL ramdisk holds no SWEETXNU payload.
 */
int bergamota_wanted(uintptr_t dtb);
/* Serve fastboot. Returns only if it could not start (USB init failed, no buffer): the reason. */
const char *bergamota_fastboot(uintptr_t dtb);
