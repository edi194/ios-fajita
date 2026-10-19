#pragma once
#include <stdint.h>

/* Read a u32/u64 (cell-size agnostic) property of /chosen. Returns 0 if absent. */
int fdt_chosen_u64(uintptr_t fdt, const char *prop, uint64_t *out);

/*
 * Return the address of the live tree: the pointer ABL passed if it really
 * points at an FDT, otherwise the DTB appended to our own boot image (the
 * stock fajita layout is header v1 with the board DTBs after the kernel
 * blob). 0 when neither is usable.
 */
uintptr_t fdt_locate(uintptr_t given);

/* Print the live /memory@... base/size pairs on the shim console. */
void fdt_print_memory(uintptr_t fdt);
