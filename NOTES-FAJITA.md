# ios-fajita — active handoff (2026-10-18)

This tree is based on `dipa-studio/ios-sweet` (main) and is being retargeted
to the **OnePlus 6T (`fajita`, SDM845)**. `PORTING.md` has the verified
hardware table and the plan; this file is the short handoff.

## State

- The Windows workspace is now the canonical git repo (local commit `460b7a5`,
  branch `main`, `core.autocrlf=false`). WSL builds it through the symlink
  `~/fajita -> /mnt/c/Users/misia/Documents/Projekt domyślny`.
- Stock boot image source: LineageOS 22.2 `20261013` fajita `boot.img`
  (64 MiB, SHA256 `560ca6fe0d869a152caaac14e7837a94bbcb2721640bfefcf502db445c28b770`).
  It is header v1 (no `dtb` section); the DTBs are appended to the kernel.
  `tools/extract-dtb.py` extracts them: `fajita0` = SDM845 **v2**
  (`msm-id 0x141 0x20000`, `board-id 0`), `fajita1` = v1, `fajita2` = v2.1.
  The first hardware image uses `fajita0` as `dtb/boot_unpacked/dtb`.
- **Diagnostic (no-payload) shim — WORKS ON THE PHONE**: the bootable image is
  `shim/out/shim-diag-v1gz.img` 434176 bytes, header **v1**, kernel =
  `Image.gz` (6994 B gz -> 180224 B raw) with the DTB appended after the gzip
  stream at `0x2b52`, empty cpio ramdisk 97 B, fajita DTB 416041 B. Built with
  `SHIM_HDR=1 bash shim/build.sh`. The header-v2 / raw-`Image` variants
  (`shim-diag-boot.img` 606208 B, `shim-diag-v1.img`) are **rejected by ABL**
  (phone drops back to fastboot ~20 s after reboot, `slot-successful:a: no`).
  Both stock images start with `1f 8b` at the kernel offset, i.e. the bootloader
  requires the `Image.gz-dtb` form. `tools/build-fajita.sh` now forces
  `SHIM_HDR=1`.
- **Payload (XNU) image kept as** `shim/out/xnu-boot.img` 17,215,488 bytes
  (that is the old `shim/out/shim-boot.img` name, which `build.sh` overwrites).
- **XNU kernel built green** by CI run **39286480811** (job 118174218235,
  7m06s; commit `f5c6ce8`). `kernel.development.sweet` 17,206,064 bytes,
  SHA256 `3640ff15067b66df6f7e0d56606eb04b2b6ce8254504060e43c2f4d9dae33131`
  (matches the artifact `SHA256SUMS`), copied to `xnu/out/`.
- **Full payload boot image built**: `shim/out/shim-boot.img` 17,215,488 bytes,
  SHA256 `10937d52fd37b1a4a3f6e36ed70328bbea59f6de7ce8d1ed7b7fd14974195571`
  (`tools/build-fajita.sh`; payload 16,610,784 bytes, ADT 9920 bytes, cmdline
  `debug=0xc serial=3 cpus=4 … refresh`). `mkadt.py` warns
  `research/ipsw-x/d22ap.adt missing, no /product node` — the iPhone X
  `/product` subtree comes from the D22AP IPSW and is needed for the iOS
  identity (patch 0059) once the root image is built; harmless for now.
- `tools/build-fajita.sh` bug fixed: `shim/build.sh` `cd`s into `shim/`, so
  the payload and DTB must be passed as absolute paths (`realpath`).
- Platform-tools are installed at `C:\Users\misia\platform-tools`
  (`adb`/`fastboot` 37.0.1). The connected OnePlus 6T is now reachable over
  both `adb` and `fastboot` (see the bring-up log below).
- Public repo: **https://github.com/edi194/ios-fajita** (`gh` logged in as
  `edi194`, needs the `workflow` scope to push `.github/workflows/`).
  First CI run: `xnu` **39283126880** (push of `c947ded`, 2026-10-19).
- **Patch series dry-run** against the exact CI source (`xnu-8796.141.3`
  from Apple's `macos-135/release.json`) with `tools` from
  `blacktop/darwin-xnu-build`: 0001–0081 apply. `0012` failed because its
  context still said "Redmi Note 10 Pro" while `0010` now writes "OnePlus 6T
  (fajita)"; fixed. `0031`/`0041` only fail locally because
  `0026-stage-hfs.sh` (which CI runs first) copies `bsd/sweet_hfs/core/*`.
  Because `build.sh` silently **skips** a patch that fails `git apply
  --check`, always re-check this after editing a patch.
- **First CI run failed** (run 39283126880, job failed in ~3.5 min):
  `unifdef: pexpert/pexpert/arm64/SWEET.h: Premature EOF (#if line 13 depth 1)`
  → the file had no closing `#endif`. Root cause: patch 0004 declared its
  SWEET.h hunk as `@@ -0,0 +1,75 @@` while the body has **76** lines, so
  `git apply` dropped the final `#endif` and still reported "applied cleanly".
  Fixed to `+1,76`. New `tools/check-hunk-counts.py` validates every hunk
  header against its body (all 81 files pass) and runs as the first CI step;
  a new `Fail on skipped project patches` step fails the build if any
  `patches/0NNN-*` is skipped.
- Shim + ADT constants retargeted to fajita:
  - FB `0x9d400000`, 36 MiB, 1080×2340, stride 4320. `shim/mmu.c` maps the
    32 MiB block at `0x9c000000` that contains it (the FB is not block-aligned).
  - IMEM restart reason `0x146bf65c` (SDM845), PS_HOLD `0xc264000`.
  - GIC (`0x17a00000`/`0x17a60000`) and UFS host (`0x1d84000`) are unchanged
    from sweet.
  - `mkadt.py`: A55/A75 MPIDR `core << 8`, `qcom,kryo385`, A55 1.7664 GHz /
    A75 2.8032 GHz, fajita FB; keeps `sweet-fbcon`/`sweet-ufs`/`xiaomi,sweet`
    names for the XNU platform-expert/driver matches.
  - XNU early FB patches 0010/0012 use `0x9d400000` + height 2340; the
    bootstrap 32 MiB block stays `0x9c000000` and the kernel alias adds the
    20 MiB offset. Patch 0061 uses native height 2340.
- WSL2 Ubuntu is installed (`edi194@WHEATLEY`), the repo is copied to
  `~/ios-fajita`, `apfs-fuse` is built/installed in `~/.local/bin`, and
  `mkbootimg` is installed there from
  `jbeich/platform_system_tools_mkbootimg`.
- **HFS+ unblocked**: `~/WSL2-Linux-Kernel` (`linux-msft-wsl-6.6.y`) was built
  with `CONFIG_HFSPLUS_FS=y` (`make -j2 bzImage`; only the `bzImage` target is
  needed, the full `all` target spends ~20 min on unused AMDGPU modules).
  `arch/x86/boot/bzImage` (16211968 bytes, SHA256 `dcd51c79…f9eec`) is installed
  as `C:\Users\misia\wsl-hfsplus-bzImage` via `C:\Users\misia\.wslconfig`
  (`kernel=`, `memory=5GB`, `processors=6`, `swap=4GB`). WSL now reports
  `6.6.123.2-microsoft-standard-WSL2+`, 4.9 GiB RAM, 6 CPUs and `hfsplus` in
  `/proc/filesystems`. Verified round-trip: `mkfs.hfsplus` -> loop mount ->
  write files/dirs -> `fsck.hfsplus -n` "appears to be OK". GCC 15 needed one
  patch: `tools/lib/bpf/libbpf.c` `char *next_path` -> `const char *`.
- No shim/ADT build or phone test yet (only the host-side `mkadt.py` test:
  9920-byte ADT with `dram 0x1_00000000/0xfcc00000`, FB `0x9d400000`,
  1080x2340, CPU MPIDR `0x000..0x700`).

## Environment

- Windows 11 Home, Ryzen 5 4500U (6c/6t), 7.4 GB RAM, 355 GB free on C:.
- WSL2 Ubuntu (`edi194@WHEATLEY`) now runs the custom 6.6 HFS+ kernel with
  4.9 GiB RAM and 6 CPUs (`.wslconfig`); local builds can use `-j4`.
- Kernel builds on GitHub `macos-14` via `xnu.yml`; no local macOS needed.
- The Linux side (shim + iOS root) needs HFS+; the custom WSL kernel provides
  it (`hfsplus` in `/proc/filesystems`).
- `apfs-fuse` needed two GCC15/CMake4 fixes, already in
  `tools/setup-wsl.sh`: `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` and an
  `#include <cstdint>` in `ApfsLib/PList.h`.
- The old `aosp-mirror` mkbootimg URL is 404; the correct mirror is
  `jbeich/platform_system_tools_mkbootimg`.

## Phone bring-up log (2026-10-19)

Observations, all from the live unit (serial intentionally not recorded here):

- Windows driver: the unit is a plain WinUSB device covered by Google's VIP/PID
  list. In Android it enumerates as `USB\VID_18D1&PID_4EE7` ("OnePlus 6T",
  status OK) and `adb devices` shows it as `device`; in the bootloader the
  fastboot interface is covered as well (`fastboot devices` lists it). The
  earlier `VID_18D1&PID_D00D` / Code 28 state was a transient pre-boot mode.
- `fastboot getvar all`: `unlocked:yes`, `Device critical unlocked:false`,
  `Verity mode:true`, `current-slot:b`, `slot-successful:a/b=yes`,
  `hw-revision:20001`, `variant:SDM UFS`, `product:sdm845`,
  `boot_a`/`boot_b` = 0x4000000 (64 MiB), `dtbo` = 8 MiB, `vbmeta` = 0x10000,
  `userdata` = 0x1B800BB000 (≈110 GiB, ext4), erase/logical block size 0x1000,
  `parallel-download-flash:yes`.
- **The bootloader has no partition read-back**: `fastboot fetch` fails with
  `Unable to get max-fetch-size. Device does not support fetch command.` A dump
  therefore has to come from Android (root) or recovery, not from fastboot.
- Android on the unit: LineageOS 22.2 / Android 15 **userdebug**
  (`lineage_fajita-userdebug 15 BP1A.250505.005 00a2ebac75`), booted from slot
  `b`, `ro.debuggable=1`, verified boot state `orange`, and **Magisk is
  installed** — `su -c id` returns `uid=0(root)`, so raw partition reads work
  over `adb` with no extra flashing. (`adb root` itself is refused by the
  setting; use `su -c`.)
- **Full dump done** into `C:\Users\misia\fajita-backup` (outside the repo, no
  git tracking): `partitions\<name>.img` for every `by-name` entry except
  `userdata` (skipped by explicit decision — iOS overwrites it), plus the raw
  firmware LUNs `sdb`/`sdc`/`sdd`/`sde`/`sdf` as `.raw`, plus
  `partition-sizes.txt`. Pipeline is `adb exec-out su -c "dd if=… bs=4M"` into a
  redirect; verified byte-exact against the device on three partitions
  (size + SHA-256 identical for `ssd`, `devinfo`, `persist`).
- **Pitfall (cost real time twice)**: `cmd`-based helper scripts whose text
  contains the non-ASCII repo path (`…\Projekt domyślny`, `ś` = U+015B) get
  mis-decoded and write to a *second* directory. Use ASCII-only paths
  (`C:\Users\misia\fajita-backup`) or PowerShell `.ps1` files; never inline
  PowerShell with `$_` through this shell either — it is echoed, not executed.
- Slot plan (user-approved): flash the diagnostic shim to **`boot_a`** and
  `fastboot --set-active=a`, leaving the working LineageOS `boot_b` untouched as
  the fallback. Return path: `fastboot --set-active=b`. Note this differs from
  the older plan (which assumed `a` was the active slot); `b` is active now, so
  `a` is the safe test slot.
- **First hardware boot of our code: SUCCESS (2026-10-19 ~19:57).** Flashed
  `shim/out/shim-diag-v1gz.img` to `boot_a`, `--set-active=a`,
  `fastboot reboot`. The phone left fastboot and never enumerated on USB (the
  shim has no USB driver) — console is the AMOLED framebuffer. The photographed
  screen showed, in order:
  - `SHIM  fajita milestone 4: xnu loader`
  - `DTB abl 00000000853FD000` / `DTB used 00000000853FD000` → **ABL passes a
    live FDT in x0**; `fdt_locate()` accepted it without scanning.
  - `INITRD lo=855FE000` (the empty ramdisk from `/chosen`) and
    `LOADER no SWEETXNU payload`.
  - `FDT live memory nodes` with two `MEM base`/`MEM size` pairs.
  - The milestone-5 UFS probe: `ver=00000210` (UFS 2.1), TUR/CAP/READ all
    `rc=00000000 ocs/st=00000000`, GPT entries read, `userdata ... fs ext4`,
    `UFS probe done, reset in ~3 min`.
  Conclusion: the SDM845 UFS host at `0x1d84000`, the GPT parser and the
  read-only path all work on fajita.
- **Live memory, measured (authoritative, from Android `/sys/firmware/fdt` and
  `/proc/device-tree/memory/reg` on slot `b`)**:
  - `memory` reg = `<0x0 0x80000000 0x1 0x00000000>`,
    `<0x1 0x80000000 0x0 0xfc8a0000>` → 2..6 GiB and 6..9.946 GiB,
    7.946 GiB total (8 GB unit, `MemTotal` 7824600 kB).
  - Every `reserved-memory` child is below `0xac800000`, so
    **`0x100000000` + `0x17c8a0000` (5.946 GiB) is clean RAM for XNU**.
    `tools/fajita.env` and `mkadt.py --highmem` now use exactly that.
  - The raw vendor DTBs in `dtb/boot_unpacked/` have a placeholder
    `memory { reg = <0 0 0 0>; }`; only the ABL-patched live tree has the real
    values, which is why the shim reads the live tree.
- **SoC revision is v2.1**, not v2: live `qcom,msm-id = 0x141 0x20001`, model
  `Qualcomm Technologies, Inc. SDM845 v2.1 MTP PVT/MP`, `qcom,board-id =
  0x8 0x0 0x4971 0x29`. The matching DTB is therefore **`fajita2.dtb`**
  (fajita0 = v2/0x20000, fajita1 = v1). Defaults changed in `shim/build.sh` and
  `tools/build-fajita.sh`.
- **Pitfall: the shim's self-reset is unreliable.** `reset()` writes the IMEM
  restart reason `0x77665500` and calls PSCI SYSTEM_RESET, but after the
  ~3 min diagnostic the unit did not reappear in fastboot for >5.5 min (a
  15 s poller saw nothing); it was reachable in fastboot when polled later.
  Plan for manual power-cycling instead of trusting the self-reset.
- Out-of-git reference artifacts now in `C:\Users\misia\fajita-backup`:
  `live-fdt.dtb` (564079 B, ABL-modified tree from `/sys/firmware/fdt`,
  SHA256 `e52c8d9a99be1ab4d0487e25aeb4ca26a42166694b97501a6b8c790a452833e5`),
  `dt-memory-reg.bin` (raw 32-byte `/memory/reg`, SHA256 `efa1a300…`).
  Kept out of git on purpose (device artifact).
- **XNU payload booted on the phone (2026-10-19 ~20:15).** Staged
  `shim/out/shim-boot.img` (17,043,456 B, SHA256
  `f1243e98eb97d746628bc23c05886b96d28cd887997748687189b0d5bff1a750`) as
  `C:\Users\misia\fajita-flash\xnu-payload.img`, flashed to `boot_a`,
  `--set-active=a`, `fastboot reboot`. The phone never reappeared on USB (no
  USB driver in the kernel yet), so the AMOLED panel is the only console.
  Observations from a photo (`IMG_0747`-era, screen text drawn rotated 90°):
  - the shim loaded the payload and jumped; the XNU log rendered on the panel:
    `serial: requested … configuring debugging over serial`,
    `Log queues configured: slot count …`,
    `vm_page_bootstrap`/zone-map lines (`zone: map zone=0xffffffe3021c2000 -
    0xffffffe3b8be3000` …), `Long range …`, pmap lines;
  - the last clearly readable line is
    `debug_log_init: Error!! gPanicBase is still not initialized`
    (`osfmk/kern/debug.c:473`), reached from `kdp_init()`
    (`osfmk/kern/startup.c:655`) — i.e. the kernel is inside
    `kernel_bootstrap_thread`, past `vm_mem_bootstrap`, `console_init`,
    `sched_init`, `machine_init`, `clock_init`, `task_init`, `thread_init`,
    `workq_init`, `kernel_thread_create`/`load_context`, `idle_thread_create`,
    `sched_startup`, `thread_daemon_init`, `mapping_adjust`,
    `clock_service_create`, `device_service_create` and `phys_carveout_init`.
    Next steps after that point are `kdp_init` tail, `bootprofile_init`,
    `STARTUP_SUB_SYSCTL`, `PE_init_iokit`, `STARTUP_SUB_EARLY_BOOT` — the hang
    is in that window.
  - **No panic buffer**: `gPanicBase == 0` because the ADT has neither a
    `pram { reg = <phys size>; }` node nor `/chosen/embedded-panic-log-size`
    (see `pexpert/arm/pe_init.c:check_for_panic_log`). Consequences: no panic
    log/crc, and `debug_log_init()` bails. Add a panic region (a few MiB of
    DRAM *outside* the ADT dram range, e.g. the top of the high bank, with
    `dram-size` reduced by the same amount) before the next debugging boot.
  - The XNU fbcon draws sideways on fajita (readable only with the phone held
    sideways); worth fixing so photos are legible.
- **QEMU cannot run this ADT on this host**: phys_base 4 GiB + 5.946 GiB needs
  a ~10 GiB guest and `qemu-system-aarch64` fails with `cannot set up guest
  memory 'mach-virt.ram': Cannot allocate memory` (host 7.4 GB, WSL 4.9 GiB).
  Use a lowmem/`0xfcc00000` ADT for QEMU A/B tests instead.
- **Photos: apply the EXIF orientation.** Phone photos arrive as
  `IMG_*.jpeg` with EXIF orientation 6 (stored 4032x3024, rotate 90 deg CW).
  Read them raw and the console text looks rotated by 90 deg, which made the
  first reading ambiguous. Convert first, e.g. PowerShell
  `[System.Drawing.Image]::FromFile($src)` + `RotateFlip(Rotate90FlipNone)`
  + `Save($dst, Png)` (no PIL/ImageMagick in WSL). After rotating, the
  `IMG_0748` screen showed the sweet IOKit bring-up (`SWEET AMFI`,
  `SWEET platform expert registered`, `SWEET AKS`, `SWEET WDT`, `SWEET SURF`,
  `SWEET HID`, `SWEET BATTERY`,
  `SWEET FB: AppleCLCD 1080x2340 stride 4320 at 0x9d400000 ... presented as
  1125x2436`) and still ended on the `debug_log_init` line, but the screen can
  contain text from more than one boot (the console never clears), so the
  ordering is not trustworthy. Hence patch 0082 markers below.
- **Panic region added host-side** (`tools/mkadt.py`): `PANIC_LOG_SIZE =
  0x100000` is carved from the TOP of the ADT dram range
  (`dram-size` 0x17c8a0000 -> 0x17c7a0000, `/pram reg =
  <0x27c7a0000 0x100000>`) and `/chosen/embedded-panic-log-size = 0x100000`
  is emitted, so `pe_init.c:check_for_panic_log()` maps it and
  `debug_log_init()` no longer bails out. `--dram-size=0x...` was added as an
  override for A/B tests (the panic region is carved either way); the `--qemu`
  tree is unchanged (no pram).
- **CI run 39304781321** (commit `aa55ae1`, 7m34s, success): patch 0082 was
  really applied (`Applying patch: .../0082-sweet-boot-phase-markers.patch`,
  the skipped-patch guard passed). Kernel `kernel.development.sweet`
  17,206,064 B, SHA256
  `9023f58e339e4cbbd589b5cb779f77efa6eb02e624e3aba9f73f9048eec7e5ac`
  (the previous one, `3640ff15...`, is kept as
  `xnu/out/kernel.development.sweet.prev`). 44 `SWEET BF:` strings are in the
  binary. Patch 0082 prints markers around `kernel_bootstrap`,
  `kernel_bootstrap_thread` (`kdp_init`, `PE_init_iokit`,
  `STARTUP_SUB_SYSCTL`/`EARLY_BOOT`, ...) and inside `machine_init`
  (`clock_config`, `pmap_map_globals`, `ml_lockdown_init`), so the last
  `SWEET BF:` line on screen names the exact stage of the stall.
- **Image ready to flash** (built from that kernel + panic ADT):
  `shim/out/shim-boot.img` 17,043,456 B, SHA256
  `f5ebdc07d14b019e60adeecf8ecca27c22a5a1b6d0e17cd991bad113f4bf0edd`,
  staged as `C:\Users\misia\fajita-flash\markers.img`. Verified: header v1,
  `kernel_size=422945` (gzip 6990 + fajita2 DTB 415955), `ramdisk_size =
  16610976` (payload), payload `phys_base=0x100000000`
  `mem_size=0x17c7a0000` (5.945 GiB), `pram` and
  `embedded-panic-log-size` present in the ADT.

## Next concrete actions

1. Get a **readable panel log** (the text is drawn rotated): photo with the phone
   held sideways, whole screen plus a close-up of the final lines. That pins the
   exact last message before the stall (candidates: `kdp_init` tail,
   `bootprofile_init`, `STARTUP_SUB_SYSCTL`, `PE_init_iokit`,
   `STARTUP_SUB_EARLY_BOOT`).
2. Add a **panic region** to `tools/mkadt.py`: a `pram` node
   (`reg = <phys size>`) plus `/chosen/embedded-panic-log-size`, placed in DRAM
   just above the end of the ADT `dram-size` (reduce `dram-size` by the same
   amount so xnu never allocates it). This makes panics readable and stops the
   `debug_log_init` bail-out.
3. If the log is still ambiguous, add temporary markers around `kdp_init`,
   `bootprofile_init`, `PE_init_iokit` and `kernel_startup_initialize_upto
   (STARTUP_SUB_SYSCTL/EARLY_BOOT)` (new patch 0082, keep hunk counts valid and
   re-check every patch applies), rebuild via CI, reflash.
4. Fix the fbcon orientation on fajita (patches 0010/0012 draw sideways on a
   1080x2340 panel) so the console is photographable.
5. Return to Android with `fastboot --set-active=b` whenever the phone is
   needed; `boot_b` is untouched LineageOS.
6. Then: root image + early console, UFS/launchd/lock screen, PM8998 keys,
   Synaptics RMI4 touch.

## Do not assume

- The panel may stop scanning out after ABL hand-off; confirm with a test
  pattern. If it does, a real DSI/MDP driver is required. (The shim's own
  console *does* render on the panel, so the framebuffer survives hand-off.)
- The live FDT memory map is now measured (see above) — do not re-guess it, but
  do re-check it if the unit is ever swapped for a different RAM SKU.
- UFS 2.1 timing and the Synaptics chip variant (s3320 vs s3706b) need
  on-device confirmation.
