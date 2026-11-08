#pragma once
#include <stdint.h>

/*
 * Off-mode charging mode (docs/BERGAMOTA_CHARGE.md).
 * charge_wanted: ABL passed "androidboot.mode=charger" in /chosen bootargs (its charger path),
 *   or the test flag "bergamota.charge=1"; "bergamota.charge=0" forbids it.
 * charge_run: show the charging screen and poll battery/keys. Returns when the user holds Power
 *   (~2 s) = continue with the normal boot flow. Volume Down enters Bergamota fastboot (and
 *   returns here if that could not start). Never returns otherwise.
 */
int charge_wanted(uintptr_t dtb);
void charge_run(uintptr_t dtb);
