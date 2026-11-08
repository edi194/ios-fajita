# Bergamota fastboot (Enxerto speaks fastboot itself)

Files: `enxerto/usb_power.c` (cold-boot power-up), `enxerto/usb_dwc3.c` (polled DWC3 device driver), `enxerto/fastboot.c` (protocol core, host-testable),
`enxerto/bergamota.c` (glue: screen, buffer, boot, reset, storage callbacks), `enxerto/fastboot_test.c` (host tests, run from `build.sh`).
Flashing (section "Flashing" below): `enxerto/ufs.c` (UFS host driver: read, write, UNMAP, SYNCHRONIZE CACHE, pipelined, cache maintenance), `enxerto/storage.c` (GPT + HARD ALLOWLIST +
write/fill/erase/hash over a block device, host-testable), `enxerto/sparse.c` (Android sparse parser), `enxerto/blake2b.c` (per-block hash), `enxerto/cache.h` (dc cvac/civac/ivac helpers),
`mmu_off_ret` in `start.S` (leave the cached window); host side `tools/bergamota-flash.py` and its test `tools/test_bergamota_flash.py`.
Hooks: `enxerto.c` (usb_power_up + entry), `loader.c` (`loader_check`, `loader_boot_payload`, `loader_has_payload`), `fdt.c` (`fdt_chosen_prop`), `build.sh`.
Status: compiles; the protocol, sparse, GPT/allowlist, hash and delta-tool end-to-end tests pass on the host. **None of it has run on hardware** (the UFS write / hash path least of all: see "Hardware test plan").

## Entry
`usb_power_up()` runs on every boot (no-op when GDSC + clocks are on). Then fastboot starts when
- the boot.img cmdline has `bergamota.fastboot=1` (`BERGAMOTA=1 enxerto/build.sh` adds it), or
- the flag is absent and the ABL ramdisk holds no SWEETXNU payload (plain `build.sh`).

`bergamota.fastboot=0` (`BERGAMOTA=0`) keeps the old loader/diagnostics path. If fastboot cannot start (USB init error, no buffer) the reason is
shown for 30 s and the old path continues (a payload in the ramdisk still boots). `bergamota.smmu=0` skips the SMMU step (debug).

## Controller bring-up (copy of what finally worked in xnu: sweet_usb.c `sweetusbfix=7` + sweet_smmu.c)
MMU off, Device memory, polled, event interrupt masked. After `fastboot boot`, ABL leaves GDSC/clocks on but the QUSB2 PHY powered down
(PWR_CTRL1 0x23, POWER_DOWN set); every earlier xnu attempt that only "took over the halted core" timed out in SETEPCONFIG (NOTES).
1. Check GCC USB30_PRIM GDSCR bit31 and CBCRs (master, cfg-noc) before touching DWC3 (a gated block hangs the bus); best-effort enable otherwise.
2. QSCRATCH GENERAL_CFG: PIPE clock from UTMI clock (dwc3_qcom_select_utmi_clk).
3. QUSB2 PWR_CTRL1: clear POWER_DOWN, set CLAMP_N_EN (0x22), wait 250 us and PLL_STATUS lock.
4. Linux core soft reset (GCTL.CORESOFTRESET + both PHYSOFTRST, 100 ms), DCTL.CSFTRST, then restore ABL's GCTL with RAMCLKSEL = 0.
5. HS quirks (GUCTL1 bit17, DCTL INITU1/2ENA = 0, GUSB2PHYCFG SUSPHY/ENBLSLPM = 0), GUCTL1 bit26.
6. apps_smmu (0x15000000): stream 0x740 (DT `iommus = <&apps_smmu 0x740 0>`) -> a stage-1 context bank that identity-maps DRAM
   0x80000000..0x27fffffff (Normal NC), exactly as sweet_smmu.c. Under the Qualcomm hypervisor an unmapped stream faults and the first DMA resets the SoC.
   An existing exact SMR is retargeted, otherwise a free one is used; the originals are restored by `usb_dwc3_stop()`.
7. Our event buffer (4 KiB in the image), DEVTEN = reset/disconnect/connect-done, DEVSPD = HS, ep0 config, DALEPENA, SETUP TRB.
8. QSCRATCH VBUS override (HS_PHY_CTRL bits 20/28, SS_PHY_CTRL bit 24), then DCTL.RUN_STOP.
Control transfers follow Linux ep0.c (status stage on XferNotReady). Descriptors: VID 0x18d1 PID 0x4ee0, bcdUSB 2.00, one interface class 0xff/0x42/0x03,
bulk IN 0x81 and OUT 0x01, 512 B (high speed), strings "Bergamota" / "Bergamota fastboot" / serial "bergamota0001", device qualifier answered, others STALLed.
Bus reset/disconnect ends all transfers, returns ep0 to SETUP and tells the protocol layer (`FB_LINK_LOST`, which forgets any download).

## DMA, memory and caches
- TRBs, event buffer, setup/command/response buffers: static arrays in the Enxerto image, aligned to 4 KiB at run time (the image is linked at 0). Same memory xnu's
  DMA used (kernel DRAM, inside the SMMU identity map), far from the kernel destination.
- USB runs with the MMU off, so CPU accesses are Device and the USB driver needs no maintenance beyond one hazard: dirty lines ABL may have left in memory we DMA into:
  before every download slice the target range is cleaned+invalidated (`dc civac`), after it invalidated (`dc ivac`). UFS and the cached window (below) do their own maintenance (cache.h).
- The cached MMU only comes up inside `loader_boot_payload` (via `mmu_enable_ranges`, which invalidates the payload range again), after `usb_dwc3_stop()` has halted
  the core, zeroed GEVNTADR/emptied the event buffer (nothing may DMA into the image later), restored QSCRATCH and the SMMU entries.
- **Download buffer: 0xb8000000, 1 GiB (to 0xf8000000)**, trimmed at run time around the Enxerto image, the DTB and the ABL initrd. The LAST 4 MiB of it are the storage
  scratch area (`STOR_SCRATCH`: two 2 MiB halves for hashing, read-back and the fill bounce); `max-download-size` is the rest (0x3fc00000) and at least 4 KiB of scratch follow it (a raw image's last block is padded in place).
  Derivation: live DT `memory` = 0x80000000..0x1fd4a0000; every fixed reserved region ends below 0xb0400000 (ramoops 0xb0000000+4 MiB, ramdump_fb 0xaf000000);
  mkadt.py validates its pools inside 0x9f800000..0xfd000000; the real payloads use phys_base 0x100000000, mem_size 0xfcc00000 (the whole upper bank), so the buffer must be
  in the low bank (loader refuses a payload overlapping `[phys_base, +mem_size)`); ABL's own USB event buffer sat at 0xfdfc8000, so stay below 0xfd000000.
  It overlaps xnu's default zero-copy low pool (0xb0400000 + 252 MiB), which xnu only uses after the buffer is dead.
- Bulk OUT: one TRB per transfer of up to 8 MiB straight into the buffer (rounded to 512), the next one queued on completion; the screen is redrawn while a transfer runs.

## Protocol (fastboot.c)
`getvar:` version 0.4, version-bootloader **bergamota-2** (was bergamota-1 before flashing existed), product beryllium, serialno, secure no, unlocked yes, max-download-size
(buffer minus the 4 MiB scratch: 0x3fc00000 with the full buffer), is-userspace no, bergamota 1, **bergamota-flash 1** (the flash commands below exist), **verify** on/off,
**slot-count 0** (the Poco F1 is not A/B), **usb-speed** high/super/full, `getvar:all` (INFO lines + OKAY),
**`partition-size:<p>`** (`0x<hex bytes>`), **`partition-type:<p>`** (`raw`), `has-slot:<p>` / `is-logical:<p>` (`no`): only for userdata, boot, logo, FAIL for any other name.
`download:<hex>` (DATA, bulk data, OKAY; > max or 0 -> FAIL). `boot`: the download must be an Android boot.img
(v0-v4: take the ramdisk) whose ramdisk is a SWEETXNU payload, or a raw SWEETXNU payload; `loader_check` validates the header, every file range and every destination
(inside `[phys_base, +mem_size)`) **before** OKAY is sent, then `loader_boot_payload(start, end, 1)` runs with the buffer instead of the ABL initrd (it shows the branded boot screen).
`reboot` (restart reason 0x77665501, PSCI SYSTEM_RESET, PS_HOLD fallback), `reboot-bootloader` (IMEM 0x146bf65c = 0x77665500: ABL fastboot), `continue` (= reboot); unchanged.
Everything else (`format`, `set_active`, `flashing`, logical-partition and snapshot commands, unknown `oem` ...) answers FAIL. Link loss drops the session state (download, staged data).
If the loader fails after OKAY the error is shown on the boot screen and the phone resets into ABL fastboot after 20 s.
Layout (Bergamota identity, `tools/identity/IDENTITY.md`, `enxerto/fbui.c`): wordmark, a leaf green FASTBOOT pill, the giant white iOS numerals behind Newton, whose coat dissolves in halftone into an ink panel holding the status, detail, progress bar, charge line, diagnostics and the key hint; on a failed boot the panel grows up over the portrait with the log tail. Host previews: `tools/identity/mkpreviews.sh`.
Screen: USB state, buffer, last command/reply, download MiB, event/setup counters, DWC3/GCTL/QUSB2/SMMU diagnostics (for the first hardware run); during storage commands
**FLASHING USERDATA 37%** with `<MiB done> / <MiB total> MiB  <MB/s>  total <MiB> MiB written`, **READING USERDATA** while hashing, **ERASING USERDATA**, and after the command
`wrote userdata 512 MiB 187 MB/s (verified)`; while receiving `RECEIVING 45%` with the USB MB/s.

## Flashing (storage.c, ufs.c, sparse.c)
### The allowlist (hard, two layers)
Only the partitions **`userdata`, `boot`, `logo`** can be flashed, erased, hashed, or have their size queried. Any other name (modem, persist, bluetooth, dsp, abl, xbl, `boot_a`,
`userdata_b`, anything) fails with `partition not allowed (only userdata, boot, logo)`:
1. `fastboot.c` (`fb_part_allowed`) checks the name before it calls any storage callback;
2. `storage.c` only ever records those three names from the GPTs (the partition table holds nothing else, so nothing else is reachable), `stor_find` refuses other names again,
   and every write/fill/erase/hash takes a pointer into that table (a forged or copied struct is refused) with a bounds check on the range.
The GPT itself is never written: a partition must lie inside `[first_usable_lba, last_usable_lba]` of its LUN's GPT header (refused otherwise), which excludes the primary and backup
GPT copies. A name that occurs twice (in two LUNs) is refused as ambiguous; an A/B layout (`boot_a`/`boot_b`, no `boot`) simply offers no `boot`.
GPT discovery (`stor_scan`, lazily on the first storage command, `oem gpt` re-scans): LUN 0..7, READ CAPACITY, GPT header at LBA 1 (4096-byte blocks) validated (signature,
header CRC32, entry size 128, entries CRC32); a LUN with an invalid GPT is ignored entirely. The Poco F1 is not A/B: `userdata`, `boot`, `logo` are expected in LUN 0 (userdata
at block 0x2b8c00, 109643 MiB per the xnu driver log); `oem gpt` shows what was really found (INFO lines `lun N gpt ok <MiB>` and `<name> lun N lba <hex> <MiB>`).

### Commands
- `flash:<p>` after `download:` of a **raw image** (padded in place to a 4096 multiple with zeros; larger than the partition -> FAIL) or an **Android sparse image** (RAW, FILL,
  DONT_CARE, CRC32 chunks; CRC32 ignored; block size a multiple of 4096). A sparse piece is fully validated before the first write (header, every chunk size, chunk total <=
  total_blks, expanded size <= partition) and then applied in order. DONT_CARE is not written (fastboot meaning). **Images bigger than the buffer:** `fastboot -S 512M flash`
  sends independent sparse pieces, each with chunk offsets counted from block 0 of the partition (leading DONT_CARE); each piece is flashed as soon as it has arrived, so the total
  is unbounded (a piece is at most `max-download-size`; a raw image over the limit is converted to such pieces by the fastboot client).
  One `INFO sparse: write N MiB` line comes before the writes. After the last write `SYNCHRONIZE CACHE` flushes the device cache (OKAY means the data is on flash).
- `erase:<p>`: UNMAP of the whole partition; if the device refuses UNMAP the partition is zeroed by writes when it is at most 1 GiB, else FAIL.
- `oem hash:<p>:<offset>:<length>:<blocksize>` (hex; offset a multiple of 4096; length 0 = to the end of the partition; blocksize a power of two, 4 KiB..2 MiB): reads the range from UFS,
  hashes every block with **BLAKE2b, 16-byte digest** (`hashlib.blake2b(block, digest_size=16)`; the last block may be shorter) and **stages the table (16 bytes per block, in order)
  at the start of the download buffer** (a previously downloaded image is lost). Answer `OKAYn=<hex blocks>`. Read-only.
- `upload`: `DATA<hex8 len>`, the staged bytes on the bulk IN endpoint, `OKAY` (the standard command behind `fastboot get_staged FILE`). So the host runs
  `fastboot oem hash:userdata:0:40000000:10000` then `fastboot get_staged out.bin` (1 GiB at 64 KiB blocks = 16384 hashes = 256 KiB).
- `oem verify:1|0` (also `getvar verify`): after every write the range is read back from UFS and compared; a mismatch fails the command (`read-back verify FAILED`). Persists until reboot.
- `oem gpt`: INFO lines with the LUNs and the allowlisted partitions found.
- `oem selftest:<p>`: read-only test of the UFS read path with **dirty CPU caches** (the kernel-side corruption scenario): inside a cached window both scratch halves are filled with patterns,
  the same 2 MiB (at the start, about a third and about two thirds of the partition) is read into both, the halves must be equal and must not hold the old pattern. `OKAYselftest passed` or a FAIL.
- `oem ufsq:<1..8>`: commands kept in flight on UFS (default 8); `oem ufsq:1` turns pipelining off, a debugging knob if the multi-slot path misbehaves on hardware.
- `reboot`, `reboot-bootloader`, `continue`: as before.

### UFS driver (ufs.c) and DMA cache maintenance
The SDM845 UFS host is **not cache coherent** (no `dma-coherent`; the kernel side had silent file corruption from exactly this, patch 0173 in docs/XNU11215_MIGRATION.md). The UFS node has
no `iommus`, so DMA addresses are physical (the buffer is below 4 GiB). Rules implemented in `cache.h`/`ufs.c`, applied per command, correct with the MMU off and on:

| memory | before the doorbell | after completion |
|---|---|---|
| write data (device reads) | `dc cvac` (clean) | - |
| read data (device writes) | `dc civac` (flush: no dirty line can be evicted over the data) | `dc ivac` (invalidate) |
| request descriptor, command UPIU, PRDT (device reads) | `dc cvac` | - |
| response UPIU, descriptor status (device writes) | cleared by the CPU, then `dc cvac` | `dc ivac` before reading |

All static descriptor memory is flushed once in `ufs_init` before the first store, and only even request-list slots are used (one 32-byte UTRD per 64-byte line: maintenance on one slot
can never touch a neighbour the host is updating). Commands are 256 KiB (one PRDT entry), 8 in flight, READ(10)/WRITE(10) with 4096-byte blocks, polled; unit attention is retried; a command
that does not complete in 10 s is aborted via UTRLCLR. UNMAP and SYNCHRONIZE CACHE exist besides. The list base is taken over only after verifying the readback (as in the old probe), and
no doorbell is rung unless the host uses our list. CPU-side rule: before the CPU writes (uncached) into memory that DMA will later read, the range is flushed once so a stale dirty ABL line
cannot be evicted over it (`oem hash` flushes the table area first; the storage scratch is flushed at the first storage command).

### The cached window (why hashing is fast)
With the MMU off every CPU access to RAM is Device-nGnRnE (about 80 MB/s for loads): fine for DMA, hopeless for BLAKE2b or a compare over GBs. So `storage.c` asks the platform for a
**cached window** around hash and read-back verify: `mmu_enable_ranges` maps the scratch area (and, for verify, the downloaded image) Normal write-back (the mapping the loader already
uses), the work runs, then `mmu_off_ret` (start.S, modelled on `mmu_off_jump`) cleans+invalidates the image and the ranges to the PoC, clears SCTLR.M/C and invalidates again.
USB is never polled inside a window (the USB driver assumes MMU off); the window is closed on every error path. If `mmu_enable_ranges` fails the work still runs, uncached and slow.

### Verification options
(1) the host tool re-hashes the phone after a flash and compares it with the image (default, `--no-verify` skips); (2) `oem verify:1` / `--device-verify`: Enxerto reads every write
back and compares it (slower; catches DMA/cache problems at the source). Both read through the same UFS read path, so use (2) once on hardware before trusting (1).

### Delta flashing and the host tool (tools/bergamota-flash.py)
`python3 tools/bergamota-flash.py [-s bergamota0001] flash userdata IMAGE` (delta by default for userdata, full for boot/logo; `--full`, `--delta`, `--no-verify`, `--device-verify`, `--block`, `--keep-delta`, `--dry-run`):
1. `getvar version-bootloader` (must be `bergamota-*`), `getvar bergamota-flash` = 1, `partition-size:<p>`;
2. the phone hashes its partition (`oem hash` + `get_staged`, 1 GiB slices) while the Mac hashes IMAGE (raw or sparse, streamed through a bounded thread pool; uniform FILL/DONT_CARE regions are hashed once) with the same BLAKE2b-128 per 64 KiB block;
3. blocks that differ are written as a sparse image (4096-byte blocks; RAW chunks of at most 64 MiB, FILL for uniform blocks such as zeros, DONT_CARE for the rest) to a temp file;
4. `fastboot -s SERIAL -S 512M flash PART delta.simg`;
5. the phone is hashed again and compared. Output lines for the Mac app: `PROGRESS <phase> <done> <total>` (hash-phone, hash-image, send, verify), `DELTA <changed> <image>`, `RESULT OK|FAIL ...`.

`hash PART [--length N]` is the read-only probe (size, MB/s, all-zero block count, digest of the table), `info` prints version, usb-speed and partition sizes.
A sparse INPUT's DONT_CARE counts as zeros in delta mode (the result is the expanded image); with `--full` the file goes to fastboot unchanged (DONT_CARE = not written).
`tools/test_bergamota_flash.py` runs the tool against a fake device (a file as the partition).

## Speed
- **USB**: Bergamota fastboot enumerates as USB 2.0 high speed only (bcdUSB 2.00, DCFG.DEVSPD = HS, no QMP PHY, no SS descriptors): 480 Mbit/s raw, in practice 35-40 MB/s
  (ABL's fastboot moved the 15 GB iOS root in about 7 minutes = 36 MB/s over the same kind of link). `getvar usb-speed` and the tool's `info` report what was negotiated;
  **it has not been measured with Enxerto's driver yet** (the first hardware flash shows `RECEIVING ... MB/s` on the phone and fastboot's own timings).
- **SuperSpeed plan (not done, not needed for delta flashing)**: needs the QMP USB3 PHY (SDM845 combo PHY: resets via GCC USB3_PHY_PRIM_BCR / USB3_DP_PHY_PRIM_BCR, the ~100-register `sdm845_qmp_usb3` init
  table of mainline phy-qcom-qmp-combo, PLL lock wait, the PIPE clock gate/mux from GCC), GUSB3PIPECTL setup, DCFG.DEVSPD = SS, a BOS + SS device descriptor, SS endpoint companion descriptors with
  1024-byte bulk packets and LTSSM/link-state handling in the event loop (the SMMU/DMA part is already done). Estimate 2-4 days including hardware iteration; the payoff is about 10x raw throughput
  (300+ MB/s, then UFS write at ~200 MB/s becomes the limit): a full 15 GB flash in about 90 s instead of 7 minutes. With delta flashing (typically tens of MB changed between builds) USB speed matters little, so it is optional.
- **UFS/hash**: UFS read is expected at 0.7-1.1 GB/s (HS-G3 x2), UFS write ~200-250 MB/s sequential. BLAKE2b-128 in scalar C on an A75 with the cached window is expected at 0.5-0.7 GB/s, so
  hashing 15 GB of userdata takes about 25-30 s (the Mac hashes the image at about 1 GB/s in parallel). If that proves too slow the per-block hash can become a CRC32 pair (ARMv8 `crc32x`, same value as
  `zlib.crc32`) without changing the protocol shape. Without the cached window (mmu_enable_ranges failure) the CPU reads at Device speed (about 80 MB/s): 15 GB would take minutes.

## Hardware test plan (nothing below has been run)
Build: `BOARD=beryllium DTB=.../dtb/beryllium/dtb enxerto/build.sh` -> `enxerto/out/bergamota-fastboot.img`, copied to `shim/out/bergamota-fastboot-flash.img`.
1. From ABL fastboot: `fastboot boot bergamota-fastboot-flash.img`. Expect the Bergamota screen, serial `bergamota0001`.
2. Read-only: `fastboot -s bergamota0001 getvar version-bootloader` (`bergamota-2`), `getvar bergamota-flash` (1), `getvar usb-speed`, `getvar partition-size:userdata` (about 109643 MiB),
   `getvar partition-size:logo`, `fastboot oem gpt` (INFO lines), `fastboot oem selftest:userdata` (dirty-cache read test), `python3 tools/bergamota-flash.py hash userdata --length 0x10000000`
   (256 MiB: MB/s, all-zero count, digest); run it twice, the digest must be identical. If a read errors or hangs, `fastboot oem ufsq:1` and retry (no pipelining).
3. `fastboot oem verify:1`, flash `logo` (small): `python3 tools/bergamota-flash.py flash logo splash.img` (full + hash verify), reboot to see the splash.
4. Delta flash of userdata with `--device-verify` for the first one, then without.

## Cold boot (`usb_power.c`)
On a power-on without fastboot, ABL leaves USB off. `usb_power_up()`: if GDSC/clocks are on, nothing. Otherwise: cfg-noc/aggre/ahb2phy branches, CLKREF_EN, clear GDSC SW_COLLAPSE,
master RCG 66.67 MHz (GPLL0/9; DT core-clk-rate-hs), mock-UTMI/aux RCGs 19.2 MHz (XO), branches, BCR pulses (USB30_PRIM 0xf000, AHB2PHY 0x6a000, QUSB2PHY 0x12000),
the QUSB2 init sequence from live.dts ending with PWR_CTRL1 = 0x22, then reads GSNPSID. Not handled: PHY supplies (vdda18/vdda33/vdd via PMIC/RPMh), the efuse tune correction,
PIPE/QMP SuperSpeed (port is USB 2.0). The GCC offsets of cfg-noc (0x0502c) and aggre are copied from sweet_usb.c (checked on beryllium by the xnu probe only in the "already on" case);
voted-clock enable registers are not used. Treat as best effort.
