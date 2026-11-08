#pragma once
#include <stdint.h>

/*
 * Early fast charging while Enxerto / Bergamota fastboot run (ABL leaves the PMI8998 SMB2 charger at its
 * slow power-on defaults). A port of the kernel's sweetcharger=2 control (xnu/patches-11215/0201,
 * bsd/dev/sweet_charger.c), same registers, same limits, same safety gates:
 *
 *   ICL by APSD result  DCP 2000 mA, CDP 1500 mA, QC2/QC3 1500 mA (no 9 V negotiation),
 *                       AICL off -> at most 1500 mA; SDP / float / OCP / unknown: hardware limit stays
 *   FCC                 2000 mA (CHARGER_FCC_MA)
 *   FV                  never raised; written (4395 mV) only when it reads 0 or above 4395 mV
 *   never touched       JEITA, termination, AICL, HVDCP, type-C, watchdog, OTG
 *   hold + give back    hot / cold / soft-limit / battery-OV / safety-timer bits, unplug, new APSD result
 *
 * Switches: build.sh CHARGER=0 (-DENXERTO_CHARGER=0) compiles everything out; boot.img cmdline
 * "bergamota.charger=0" turns it off, "=keep" leaves the programmed ICL/FCC in place at the kernel
 * hand-off (default: they are restored first, see charger_handoff). Nothing here writes anything
 * outside the seven registers of pmic_chg_write.
 */

/* Read-detect, then apply once. dtb: /chosen bootargs for the switch (0 = defaults). 0 = running, <0 = off/unsupported. */
int enxerto_charger_init(uintptr_t dtb);
/* Re-check (re-plug, new APSD result, temperature) and refresh the cached state; at most every 5 s unless force. */
void enxerto_charger_tick(int force);
/* Right before the jump to the kernel: give the kernel's 0201 the registers as it expects to find them. */
void enxerto_charger_handoff(void);

/* "applied CDP 1500/2000mA 4395mV FAST 37%" (getvar bergamota-charger), <= 40 characters */
void enxerto_charger_status(char *buf, unsigned n);
/* "st=02/00 apsd=04 je=1f aicl=1 w=3/0" raw bits for debugging (getvar bergamota-charger-raw) */
void enxerto_charger_raw(char *buf, unsigned n);
/* "charging 1500 mA CDP 37%" for the fastboot screen, "" when there is nothing to say */
void enxerto_charger_line(char *buf, unsigned n);
