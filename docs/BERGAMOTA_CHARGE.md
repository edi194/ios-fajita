# Off-mode charging screen (Enxerto)

Files: `enxerto/charge_mode.c` (detection, loop, keys, backlight, fastboot hook), `enxerto/charge.c` (screen, host-testable), `enxerto/pmic.c` (polled SPMI),
hook in `enxerto.c` (`charge_wanted` runs before `usb_power_up`), `fdt_cmdline_opt` in `fdt.c`. Status: builds, host previews rendered; **nothing has run on hardware.**

## How ABL triggers it (evidence)
Decompressing the LZMA FV of `backup/abl_a.img` (Poco F1 ABL) shows, next to each other in the cmdline builder: `PON Reason is %d cold_boot:%d charger path: %d`,
` androidboot.mode=`, ` androidboot.mode=charger`, ` androidboot.alarmboot=true`, and the fastboot `oem off-mode-charge` / `oem enable-charger-screen` handlers.
So on a power-on by USB (PON reason USB_CHG, no power key) ABL boots the normal boot partition with `androidboot.mode=charger` appended to the cmdline,
which ends up in the DTB `/chosen/bootargs` that ABL passes in x0. Not found in ABL: `androidboot.bootreason`. (Static strings only; the exact branch conditions were not disassembled.)
Detection = whole word `androidboot.mode=charger` in `/chosen/bootargs`. `bergamota.charge=1` forces it (test), `bergamota.charge=0` forbids it (put it in the boot.img cmdline
to opt out; ABL appends its flag after ours). PM8998 `PON_REASON1` (0x808, bit4 USB_CHG) is read for the on-screen diagnostics only, NOT as a trigger: it keeps the last cold
power-on reason, so a warm reboot from iOS would be misdetected. Normal boots: one cmdline scan, no PMIC/USB/display access.

## Behaviour
- Screen (Bergamota identity, `tools/identity/IDENTITY.md`): wordmark, a state pill (CHARGING leaf green, CHARGED, NOT CHARGING, LOW BATTERY red when <=15 % and not charging, BATTERY when there are no readings), the state of charge as giant white Archivo numerals behind Newton (`--` when unavailable; the small `%` is dropped only at 100), and on the ink panel below his coat `Charging | 4.12 V | 1.1 A` / `Charged` / `Not charging` / `Battery info unavailable`, a 20-segment bar (5 % each), the notice line, key hints `Vol - fastboot  hold Power start iOS` and the diag lines. Polled every 5 s, only changed regions are redrawn.
- Keys (PM8998 PON INT_RT_STS 0x810, SID 0, polled every 40 ms, two equal samples): bit0 KPDPWR (Power), bit1 RESIN (Volume Down), as in the kernel's SWEET KEYS.
  Power short = blank/wake toggle; Power hold 2 s = leave charging mode, the normal flow in `enxerto_main` continues (iOS payload, or Bergamota fastboot if none).
  Volume Down = `usb_power_up()` + `bergamota_fastboot()` (USB is only started now; if fastboot cannot start/ends, the charging screen returns with a red notice). While the screen is dark, any key only wakes it.
- Idle 20 s: WLED brightness ramps to 0 (quadratic, 5 steps) and the value found is restored on wake. If WLED cannot be read/written/read back (APID not EE0-owned, MOD_EN off) the panel is blanked with black pixels and the UI is redrawn on wake. If WLED is enabled but at 0 when we start, it is lit at 0x7ff.
- If the arbiter lookup fails: screen shows `--%` / "Battery info unavailable", keys are then unreadable too: the screen stays on with the notice "hold Power 10 s to restart".

## PMIC access (port of xnu/patches 0062/0092/0095/0126/0137)
Arbiter v5 core 0x0c440000 (ver check 0x5..0x6, APID count), owner cfg 0x0c40a000, EE0 observer 0x0e600000 (read: CMD (1<<27)|(addr&0xff)<<4, STATUS +8, RDATA +0x18), write channel 0x0c600000+0x10000*APID.
Reads (allow-listed peripherals): SID2 PMI8998 FG MSOC 0x4009 (rescaled as the kernel), VBAT 0x41a0 (x122070/1e6 mV), IBAT 0x41a2 (488.281 uA/bit, + = discharging), SCHG USBIN plug RT 0x1310 bit4, charger state 0x1006[2:0] (1-4 charging, 5 terminate), APSD 0x1308; SID0 PON 0x808/0x810.
The ONLY writes: SID3 WLED brightness 0xd957/0xd967 and sink SYNC 0xd947 (same whitelist as the kernel backlight fade), refused unless EE0 owns the APID, read back after writing, originals restored on mismatch. No SCHG/FG/PON write exists in the code.

## Test
`BOARD=beryllium enxerto/build.sh` builds `enxerto/out/charge-test.img` (empty ramdisk, cmdline `console=null bergamota.charge=1`) next to `enxerto-boot.img`. Run through the Bergamota queue (`fastboot boot enxerto/out/charge-test.img`)
with the cable in: expect the charging screen with real numbers and the diag lines (`msoc`, `chg`, `usbin`, `apsd`, `pon`, `wled`). Check: 20 s idle blanks, Power wakes, Volume Down starts fastboot (host sees VID 18d1:4ee0),
Power hold 2 s falls through to the normal flow. Real ABL path: power the phone off, plug a charger (no key) and see whether the boot.img with the real Enxerto shows it (`androidboot.mode=charger`);
with a payload in the ramdisk, hold Power 2 s to start iOS. Host previews: `tools/identity/mkpreviews.sh` -> `tools/identity/out/screens/charge-*.png` (15 %, 62 %, 100 %, 8 % not charging, unavailable, update+notice).

## Risks
- Hypervisor/XPU may fault MMU-off access to the SPMI regions from Enxerto (the kernel does the same reads after ABL, so likely fine); a fault shows the Enxerto panic screen.
- ABL may not light the panel in its charger path, so the screen could be dark; we only set WLED if the driver is enabled (MOD_EN). DSI/panel bring-up is not attempted.
- PON key bits and charger registers are from the kernel code, unverified in this context; WLED write ownership (EE0) is known good in the kernel, not yet from Enxerto.
- Image size grew; mkbootimg layout unchanged. USB PHY supplies are still not touched by `usb_power_up` (cold-boot fastboot from charger mode is best effort, as documented in BERGAMOTA_FASTBOOT.md).
