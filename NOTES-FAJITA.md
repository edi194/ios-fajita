# ios-fajita — active handoff (2026-10-18)

This tree is based on `dipa-studio/ios-sweet` (main) and is being retargeted
to the **OnePlus 6T (`fajita`, SDM845)**. `PORTING.md` has the verified
hardware table and the plan; this file is the short handoff.

## State

### NEXT SESSION — start here (2026-10-23, after the input milestone)
**iOS 16.7.16 (iPhone X, 20H392) runs on the OnePlus 6T with its GUI, working
touch and working keys** — lock screen appears and responds, on all eight
cores. Reached 2026-10-23 ~12:30.

- **Flashed now**: `boot_a` = `console28-gui.img` (SHA256 `9410d845…400f`),
  kernel `bb2ee166…084b` (CI `39938029165`, patches 0090–0098), cmdline:
  `debug=0xc serial=3 cpus=8 sweetsmp=1 keepsyms=1 -noprogress
  nointr_consio=1 rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1
  wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
  sweetfb_hz=10 sweetecon=1 sweetfb_noconsole=1 sweetlog=1 sweettouch=1
  sweetts=1 sweettouchdelay=20 sweetkeys=1 rpmhrsc=0x179e0000
  rpmhtcs=0x179e0d00`. `tools/build-fajita.sh` now defaults to this.
- **What works**: launchd + the daemon set, backboardd/SpringBoard, lock
  screen and GUI on the panel (10 Hz), 8 cores via PSCI, RMI4 touch with panel
  coordinates, PM8998 keys (power `0x30`, VOL+ `0xe9`, VOL− `0xea`), the
  persistent log and the panic flush.
- **Next candidates, in a sensible order**:
  1. Unlock → home screen: swipe up and see whether SpringBoard renders it;
     PosterBoard has no wallpaper provider on this root (ios-topaz records the
     same), so expect a black wallpaper.
  2. RTC/time: everything runs at `1969-12-31`, so any certificate check
     (TLS, activation) sees an invalid date.
  3. Wi-Fi: the only big feature the reference port has that we do not. It
     needs the modem/WLFW work (ios-topaz patches 0113–0130) ported to SDM845.
  4. GPU: the HackiOS sources are public since 2026-10-22. Their path is not
     Metal: EAGLContext is replaced in-process (eagl.c), OSMesa/freedreno
     draws through a libdrm shim whose ioctls are an IOKit user client, and an
     IOSurface doubles as a dma-buf; the kernel still blits the final frame.
     About 60% of their redwood_adreno.c is family-generic a6xx. For
     SDM845/a630 the SoC-specific parts are: GMU in legacy mode (flat firmware,
     dtcm 0x40000, SPTPRAC enable, HFI v1 payloads, rscc inside the GMU), SMMU
     v2 with 32-bit IOVA, a630_* firmware with all zap segments, and the bases
     GPU 0x5000000, GMU 0x506a000, SMMU 0x5040000, gpucc 0x5090000, cx_misc
     0x509e000, cmd-db 0x85fe0000, zap 0x8c415000, chipid 0x6030001. The Mesa
     patches are SoC-agnostic, but inject.c's dyld-cache addresses are iOS
     16.5's and must be re-derived for 16.7.16. Estimate 3-6 weeks and SoC
     resets on mistakes; the ladder is read-only probe, GMU out of reset, core
     writes a magic word, 2D blit, userspace GL, backboardd GL.
  5. Polish: `product id ""` from F01 (the read offset is probably wrong),
     touch edge calibration (raw maxima seen 1063/2326 vs 1080/2340),
     `sweetfb_hz` tuning, drop the now-unused `sweetts_norail` path.
- **GPU stage 1 is written (patch 0099)**: `bsd/dev/sweet_gpu.c`, boot-arg
  `adreno=1`, maps and *reads* gcc/pll-vote, qfprom, cmd-db, gpucc, SMMU
  IDR0/1/2 + SCR0 + SACR, GMU fw-init/CM3 reset/ITCM, the GPU's first words
  and cx_dbgc/cx_misc. Nothing is written; every block is announced before it
  is read so a hang names it. `console30-gpuprobe.img` carries it.
- **First GPU probe boot froze on its first read (console30, 2026-10-23)**: the
  panel stopped on `SWEET GPU: reading gcc`, i.e. the read of **GCC+0x52000** —
  HackiOS's PLL-vote offset on their SoC, not a register validated here (this
  port already reads GCC+**0x5200c**, the touch driver's vote register, and
  that works). So a read of an unimplemented/halted GCC register hangs the bus
  on SDM845. **Patch 0100** makes the probe per-register: one line announcing
  `read <block> +<offset>`, one line with the value, ordered from registers we
  already touch (`gcc 0x5200c`, `qfprom`, `cmd-db`, `gpucc` GDSCRs/CBCR/RCGR,
  SMMU IDR0/1/2 + SCR0) to the ones that may need a rail/clock first (GMU
  fw-init/CM3, GPU core, cx dbgc/misc). `console31-gpuprobe2.img` carries it.
- **The probe output was lost on the next boot (console31)**: the ring on disk
  was byte-identical to the previous boot (`flush #39`, 4703 lines) — the crash
  happened before the log thread's first flush (~10 s), so nothing of the probe
  reached userdata. **Patch 0101** calls `sweet_log_panic_flush()` right after
  announcing each read, so the last line on disk always names the register
  being touched. `console32-gpuprobe3.img` carries it.
- **GPU stage 1 DONE (console33, 2026-10-23)**: the probe ran to completion and
  the readings are exactly what a powered-down GPU looks like, with every
  address confirmed:
  * `gcc +0x5200c = 0x1bc0000` (wrapper AHB/SE votes; bit 26 not yet set because
    the touch driver votes it later);
  * `qfprom +0x1e8 = 0xce000000` (the a660 speed-bin offset means nothing here;
    take the clock ladder from the dts `qcom,gpu-pwrlevels`);
  * `cmd-db +0x4 = 0xc0330db` — **cmd-db magic, so 0x85fe0000 is right**;
  * `gpucc +0x100c = 0x222001` and `+0x106c = 0x222001` — GX and CX GDSCs are
    collapsed (GPU off);
  * `gpucc +0x1098 = 0x80004220` (CX_GMU CBCR bit31 = halted) and
    `+0x1120 = 0x80000000` (GMU clock root off);
  * `smmu +0x00 = 0x200626` (the SMMU answers), `+0x04/+0x08 = 0` (IDR1/IDR2
    zero — the v2 register layout needs checking when the domain is on),
    `+0x30 = 0x30060000` (SCR0);
  * `gmu +0x501c/+0x5000 = 0` (GMU in reset), `gpu +0 = 0`, `dbgc`, `misc` = 0
    (the core is unclocked: reads return zero instead of hanging).
  So the block bases are right and stage 2 starts with **power**: CX/GX rail
  votes, un-collapse the GDSCs, ungate the GMU/gfx clocks, then the GMU
  legacy-mode bring-up (SPTPRAC, HFI v1, flat `a630_gmu.bin`).
- **Reading the log without filming** (used all night): with the phone in
  fastboot, `fastboot boot <orange-fox-r12-fajita.img>` → poll `adb devices`
  until the state is `recovery` → `tools/sweet-log-pull.sh out.txt` (the last
  1025 blocks of `userdata` = the 4 MiB ring, patch 0047) →
  `adb reboot bootloader`. Recovery image (outside git): OrangeFox R12.0
  unofficial V7 for fajita, 50,008,064 B, SHA256 `61eb9f7a…3d34`.
  TWRP 3.7.0 for fajita does **not** boot on this unit.
- **Kernel rebuild loop**: edit `xnu/patches/NNNN-*.patch` (generate them with
  the `mk-patch-00NN.py` helpers kept in the temp dir), `python3
  tools/check-hunk-counts.py`, push, `gh run watch`, then
  `ADT_GAMUT=P3 CMDLINE="…" tools/build-fajita.sh` and flash the image.
  Cmdline-only changes need no CI. GitHub occasionally throttles artifact
  downloads ("Egress is over the account limit") — retry, or download
  `xnu-kernel` by hand and unzip it into `xnu/out/`.
- **Patches 0087–0098 (all in this kernel)**: 0087 empty `IOAcceleratorES`;
  0088 SweetSurface surfaces of client memory; 0089 `sweetkeysprobe`;
  0090 fajita RMI4 touch branch (`sweetts=1`); 0091 fajita key layout;
  0092 RPMh `ldoa28`; 0093 RPMh bases + TLMM map size + `sweetts_norail`;
  0094 panic visible + panic-time ring flush (`seq 0xffffffff`);
  0095 per-step prints and `sweetts_nogpio/noclk/nose` switches;
  0096 TLMM EAST tile for gpio88/125 + I2C pin mux; 0097 both GENI lengths +
  sequencer dump; 0098 RMI4 reads as two transactions.

- The Windows workspace is now the canonical git repo (local commit `460b7a5`,
  branch `main`, `core.autocrlf=false`). WSL builds it through the symlink
  `~/fajita -> <workspace>`.
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
- Platform-tools are installed at `%USERPROFILE%\platform-tools`
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
- WSL2 Ubuntu is installed (`$USER@host`), the repo is copied to
  `~/ios-fajita`, `apfs-fuse` is built/installed in `~/.local/bin`, and
  `mkbootimg` is installed there from
  `jbeich/platform_system_tools_mkbootimg`.
- **HFS+ unblocked**: `~/WSL2-Linux-Kernel` (`linux-msft-wsl-6.6.y`) was built
  with `CONFIG_HFSPLUS_FS=y` (`make -j2 bzImage`; only the `bzImage` target is
  needed, the full `all` target spends ~20 min on unused AMDGPU modules).
  `arch/x86/boot/bzImage` (16211968 bytes, SHA256 `dcd51c79…f9eec`) is installed
  as `%USERPROFILE%\wsl-hfsplus-bzImage` via `%USERPROFILE%\.wslconfig`
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
- WSL2 Ubuntu (`$USER@host`) now runs the custom 6.6 HFS+ kernel with
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
- **Full dump done** into `%USERPROFILE%\fajita-backup` (outside the repo, no
  git tracking): `partitions\<name>.img` for every `by-name` entry except
  `userdata` (skipped by explicit decision — iOS overwrites it), plus the raw
  firmware LUNs `sdb`/`sdc`/`sdd`/`sde`/`sdf` as `.raw`, plus
  `partition-sizes.txt`. Pipeline is `adb exec-out su -c "dd if=… bs=4M"` into a
  redirect; verified byte-exact against the device on three partitions
  (size + SHA-256 identical for `ssd`, `devinfo`, `persist`).
- **Pitfall (cost real time twice)**: `cmd`-based helper scripts whose text
  contains the non-ASCII repo path (`…\Projekt domyślny`, `ś` = U+015B) get
  mis-decoded and write to a *second* directory. Use ASCII-only paths
  (`%USERPROFILE%\fajita-backup`) or PowerShell `.ps1` files; never inline
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
- Out-of-git reference artifacts now in `%USERPROFILE%\fajita-backup`:
  `live-fdt.dtb` (564079 B, ABL-modified tree from `/sys/firmware/fdt`,
  SHA256 `e52c8d9a99be1ab4d0487e25aeb4ca26a42166694b97501a6b8c790a452833e5`),
  `dt-memory-reg.bin` (raw 32-byte `/memory/reg`, SHA256 `efa1a300…`).
  Kept out of git on purpose (device artifact).
- **XNU payload booted on the phone (2026-10-19 ~20:15).** Staged
  `shim/out/shim-boot.img` (17,043,456 B, SHA256
  `f1243e98eb97d746628bc23c05886b96d28cd887997748687189b0d5bff1a750`) as
  `%USERPROFILE%\fajita-flash\xnu-payload.img`, flashed to `boot_a`,
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
- **Panic region works — first full panic dump read from the panel
  (2026-10-19 21:11).** The stamped image (`markers.img`) panicked and XNU
  printed the complete panic screen: zone map, panicked task/thread, 15-frame
  backtrace, `** Stackshot Succeeded ** Bytes Traced 2171`, the original panic
  string, boot-args, `ECID`, `Kernel version: Darwin Kernel Version 22.6.0`,
  `kernel text base 0xfffffe0007004000`.
  - Panic string: `panic(cpu 0 caller 0xfffffe0007ad1dc4): Console I/O from
    interrupt-disabled context @serial_console.c:168`.
  - Resolved with the Mach-O symtab of the kernel (no llvm-nm needed): caller
    `_console_write.cold.3`, frames `__cnputs` → `___doprnt` →
    `_kernel_bootstrap_thread + 0x36c`.
  - **Cause: our own instrumentation.** `osfmk/console/serial_console.c:168`
    (`console_io_allowed()`) panics on any printf from an interrupt-disabled
    context once `startup_phase >= STARTUP_SUB_EARLY_BOOT`. Stock xnu calls
    `(void) spllo()` only *after* `kernel_startup_initialize_upto(
    STARTUP_SUB_EARLY_BOOT)`, and patch 0082's `early_boot ranks ok` marker sat
    right there — so the kernel was healthy and our print killed it.
  - `handshake structure not initialized` in the dump is
    `osfmk/kdp/output_stages/out_shmem.c:499` (no shared-memory debugger);
    harmless, not a second failure.
  - The earlier marker-less image almost certainly died at the same silence
    point: without `gPanicBase` the panic path could not print anything.
- **Fixes after that panic:** markers moved past `spllo()`, new markers for
  `initialize_screen`, `vm_commpage_init`, `STARTUP_SUB_LOCKDOWN`,
  `machine_lockdown`, `PE_lockdown_iokit`, `bsd_init` (entry, `vfsinit`,
  `vfs_mountroot`), and `nointr_consio=1` is now in the default cmdline
  (`tools/build-fajita.sh`) so early prints can never trip the guard.
  Patch 0082 now has 53 markers over 3 files and still passes
  `tools/check-hunk-counts.py` (all 82 patch files OK) and a `patch -p1
  --dry-run`. CI run **39310272447** (commit `8f03e44`) builds that kernel.
- **Quick A/B image without a new kernel**: `%USERPROFILE%\fajita-flash\
  nointr.img` (17,043,456 B, SHA256
  `ae403bd8bcf31b479de6f54430486b67fa818acbe4c6df9f6a602019577fc2f8`) is the
  previous kernel (`9023f58e…`) with only `nointr_consio=1` added, flashed to
  `boot_a` at 21:22 to see how far the boot gets past `EARLY_BOOT`.
- **That A/B boot went far (photo at 21:26).** Every marker up to
  `PE_init_iokit ok` printed, then the whole sweet platform came up on the
  phone: `SWEET AMFI: built-in interface registered (OWL entitlements)`,
  `calling mac_policy_init for vnguard`, `Security policy loaded: Guarded mode
  policy (vanguard)`, `SWEET: trust caches unavailable (Image4/NPMI not
  installed)`, `SWEET: starting device-tree platform expert`,
  `SWEET: platform expert registered`, `SWEET AKS`, `SWEET WDT`, `SWEET SURF`,
  `SWEET HID: buttons registered`, `SWEET HID: touch registered`,
  `SWEET BATTERY: static fallback`, and finally
  `SWEET FB: AppleCLCD 1080x2340 stride 4320 at 0x9d400000, default surface 1,
  presented as 1125x2436`. So `machine_init`, `kdp_init`, `bootprofile_init`,
  `STARTUP_SUB_SYSCTL`, `PE_init_iokit` and all the emulated drivers run on
  hardware.
  - After the FB present the panel shows the **start of the console ring
    replay** (`size: 1048576`, `Firehose configured: 16 chunks, 8 to pages`,
    `OSLog stream configured`, `OSLog stream verification: 0`,
    `SWEET BF: oslog ranks ok`, `SWEET BF: console_init ok`) and stops there,
    i.e. the next stop is in `spllo()`/`initialize_screen()` right after
    `STARTUP_SUB_EARLY_BOOT` (screen takeover + ring-buffer flush), not in the
    drivers. That image has no markers past `early_boot ranks ok`.
- **CI run 39310272447** (commit `8f03e44`, 6m29s, success): kernel
  17,222,448 B, SHA256
  `2c21c52f99ce83808ae7b77c39cbb947a913f6a591c7b4bb9589322a824e0cef`,
  53 `SWEET BF` strings, markers now past `spllo()` plus `initialize_screen`,
  `vm_commpage_init`, `STARTUP_SUB_LOCKDOWN`, `machine_lockdown`,
  `PE_lockdown_iokit` and `bsd_init` (entry, `vfsinit`, `vfs_mountroot`).
  Image `%USERPROFILE%\fajita-flash\markers2.img` 17,043,456 B, SHA256
  `2000efa676f4e6e4dcb6cf6dab0f66a1ea34a499879320d8551b006b1826e5d5`
  (payload cmdline contains `nointr_consio=1`), flashed to `boot_a` at 21:33.
- **Root cause of the "screen stops updating" after the FB present:
  `sweetfb_noconsole=1`.** Patch 0067 sets `sweet_console_muted = 1` on the
  first GUI swap (AppleCLCD `presented as 1125x2436`), after which `_cnputs`
  only appends to the persistent log and draws nothing (panics still draw).
  So everything after the platform expert was simply invisible, not hung.
  `sweetfb_noconsole=1` was removed from the default cmdline
  (`tools/build-fajita.sh`) for bring-up; the panel is the only console.
  Image `%USERPROFILE%\fajita-flash\nomute.img` 17,043,456 B, SHA256
  `42a0e67e684ced068df6d3927fdb589224dc798c27824b3737e7a6f7d29bea3c`
  (kernel `2c21c52f…`, nointr_consio=1, no sweetfb_noconsole), flashed at
  21:49.
- Marker order on the phone (markers2 photo) is fully consistent with stock
  xnu: `stackshot_init` → `sched_init` → `machine_init` (all four sub-steps) →
  `clock_init` → `task_init` → `thread_init` → `workq_init` → `exception_init`
  → `kernel_thread_create`/`load_context` → `bootstrap_thread` →
  `idle_thread_create` → `sched_startup` → `thread_daemon_init` →
  `thread_call ranks` → `thread_bind` → `mapping_adjust` →
  `clock_service_create` → `device_service_create` → `phys_carveout_init` →
  `kdp_init` → `bootprofile_init` → `sysctl ranks` → `PE_init_iokit` →
  `spllo` → `initialize_screen` → `vm_commpage_init` → `lockdown ranks` →
  `machine_lockdown` → `PE_lockdown_iokit` → platform expert + drivers + FB.
  The `SWEET BF: console_init ok` line at the very bottom is the console ring
  draining late, not a restart.
- **`nomute.img` still froze at the same line** (user photo 21:5x, waited >30 s,
  no panic). So `sweet_console_muted` was *not* the whole story. Observation:
  everything up to the FB present is drawn live by `pexpert/arm/pe_serial.c`
  fbcon (patch 0003, writes straight into the panel at `0x9d400000`), and the
  last line is the *oldest* entry of the console ring — i.e. the drain stalled
  right at its first entry, so the kernel most likely blocks afterwards inside
  `osfmk/console/serial_console.c` (`console_write` → `console_ring_try_empty`)
  or inside `vcputc_options` (`osfmk/console/video_console.c:1255`, takes
  `VCPUTC_LOCK` then `gc_ops.paint_char`) once `AppleCLCD` owns the surface.
  Panics still render, so the panic path bypasses whatever stalls.
- **Fresh reference repo (2026-10-20): `MakrSas/ios-topaz` branch `topaz`**,
  same sweet XNU base but 131 patches and a working panel/GUI. It already hit
  this exact wall and solved it with **`sweetfb_console=1`**
  (`xnu/patches/0120-topaz-console-only.patch`): `AppleCLCD::present()` returns
  early so a GUI swap never overwrites the kernel console; the text console
  keeps drawing directly into the panel. Other patches worth mining later:
  `0097` unified console scanout, `0099` surface-inuse console batch, `0112`
  console log filter, `0129` WLAN station, `0130` PMK/join, `0131` SweetSurface
  lock results.
- **Patch 0083 (`fajita-console-only`, port of topaz 0120)** adds the same
  early return in `AppleCLCD::present()` gated on `sweetfb_console=1`, and the
  boot-arg is now in the default cmdline in `tools/build-fajita.sh`.
  `tools/check-hunk-counts.py` reports all **83** files OK.
- **Patch 0084 (`fajita-panel-console`) — the real console fix.** Reading the
  code showed the panel text is drawn by pexpert's fbcon (`serial_putc_options`
  → `PE_stub_putc`), and that `vcputc_options` (the Apple VC console) draws
  nothing until `vc_initialize` runs, so the visible log is the pexpert one.
  The lock-free bootstrap console in `osfmk/arm64/sweet_early.c` (write-
  combining alias `SWEET_EARLY_FB_VA`, installed straight into the final kernel
  page tables by `arm_vm_init`, inside the reserved region → permanent) is the
  one drawing mechanism on this board that cannot stall: no ring, no VC, no
  locks, no interrupts, no allocation. `arm_init.c` no longer disables it for
  SWEET, and `_cnputs` hands every character to `sweet_early_console_route()`
  when the boot-arg **`sweetecon=1`** is set. `sweetecon=1` is now in the
  default cmdline next to `sweetfb_console=1`. All **84** patch files pass
  `check-hunk-counts.py`, both new patches apply with `patch -p1 --dry-run`.
- **console2 (0083+0084, `sweetecon=1`) booted 2026-10-20 and the panel finally
  shows the whole log** — `%USERPROFILE%\fajita-flash\console2.img`
  (17,043,456 B, SHA256 `174da2d0…9394`, kernel `4051ad2f…ea7d`). The early
  console wraps at 72 rows (newest at the top), so the visible order is
  "newest block" then "older block". Reading it: every marker and driver comes
  up (`AKS`, `WDT`, `SURF`, `HID buttons`, `HID touch`, `BATTERY`,
  `AppleCLCD … presented as 1125x2436`) and then **nothing at all** — no
  `bsd_init enter`. So the kernel (or at least this thread) stops printing
  right there; the console was not the thing hiding output, but the ring
  waiter plausibly *is* the block.
- **Diagnosis for 0085**: `console_write()` reserves console-ring space before
  draining and waits when the ring is full; `console_ring_try_empty()` bails
  when preemption is disabled or when no one drains. The bootstrap thread
  prints `PE_lockdown_iokit ok` and then stalls right before
  `bsd_init enter`, while the IOKit matching thread (started by
  `StartIOKitMatching()` inside `PE_lockdown_iokit`) keeps printing driver
  lines and stops at the FB driver. A ring that fills with no drainer blocks
  both. Patch **0085** therefore makes `sweetecon=1` bypass the ring entirely
  (`console_write` → `_cnputs` directly) and adds markers at
  `vm_set_restrictions`, the end of `AppleCLCD::start`, the arm-io nub
  creation and around `StartIOKitMatching()`. All 85 patch files pass
  `check-hunk-counts.py`.
- **console3 (0085) booted 2026-10-20** — `console3.img` (SHA256 `3716cb62…a10c`,
  kernel `1dcf35a7…152d6`). The panel now shows the whole ordering explicitly:
  `startIOServiceMatching enter` → `ok` → `PE_lockdown_iokit ok` →
  `vm_set_restrictions ok` → `SWEET PE: creating arm-io nubs` → drivers →
  `SWEET FB: start done` → **nothing**. So the ring was not the blocker (the
  log is complete and synchronous now) and the bootstrap thread stops between
  `vm_set_restrictions()` and `bsd_init()`.
- **Root cause found for that stop (patch 0086)**: the only call between those
  two prints is `kperf_init_early()`, which starts with
  `ml_wait_max_cpus()`. That sleeps until `ml_set_max_cpus()` runs, and the
  only SWEET caller is `SweetCPU::startAll()`. `SweetCPU` matched
  `qcom,kryo470` (sweet/SM7150) while the fajita ADT declares the truth,
  `qcom,kryo385` (SDM845) — so **no CPU nub ever matched**, `ml_set_max_cpus()`
  never ran and the wait was forever. 0086 matches `qcom,kryo385`, logs every
  CPU nub (start / skipped / phys mismatch) and adds **`sweetsmp=0`**, which
  publishes the boot CPU and calls `ml_set_max_cpus()` without PSCI `CPU_ON`
  or the SGI self-test, so an untested GIC/PSCI path cannot hold the boot.
  `tools/build-fajita.sh` now boots with `cpus=1 sweetsmp=0` until userland
  runs. All 86 patch files pass `check-hunk-counts.py`.
- **console4 (0086) booted 2026-10-20 and reached `vfs_mountroot`** —
  `console4.img` (17,043,456 B, SHA256 `ea08f4a8…c761`, kernel
  `befef99b…8632`). The panel shows `BSD root: ufsroot0, major 1, minor 0` →
  `SWEET BF: bsd_init: vfs_mountroot enter` → `hfs_ValidateHFSPIusVolumeHeader:
  unknown Volume Signature : 681b` → `hfs_mountfs returned error=22` →
  `cannot mount root, errno = 19, mount(2..7) failed`, then
  `SWEET UFS: "userdata" on LUN 0: first block 0x186f40, 112640 MiB,
  read-write, DMA at 0x104c38000` (the persistent-log writer opened the
  partition and put its ring at the last 4100 KiB, `block 0x1d68afa`).
  So `kperf_init_early()`/`ml_wait_max_cpus()` was the last kernel-side
  blocker: the boot now runs the whole BSD init up to the root mount. HFS+
  rejects `userdata` because it still holds Android ext4 — the expected state
  before flashing the iOS root.
- **iOS ROOT FLASHED 2026-10-20 and the iOS 16 userland boots from it.** With
  the user's explicit approval `fastboot flash userdata
  %USERPROFILE%\fajita-root\ios16-root.img.simg` wrote 16 sparse chunks
  (12,145,480,060 B, SHA256 `8ce89bcd…055b`) in 378 s; `userdata` no longer has
  Android data (GPT, bootloaders, recovery, modem, persist untouched; LineageOS
  slot `b` still there but with an empty data set).
  Boot `console4`/`console5` (same kernel `befef99b…`, `console5` adds
  `sweetlog=0`): `bsd_init` → `vfs_mountroot` → HFS+ accepted →
  `GetMasterBlock: Error 16 opening /dev/ufsroot0` (EBUSY, harmless) →
  **`/dev/ufsroot0 on / (hfs, local, journaled, noatime)`** (read-write) →
  bindfs on `/private/preboot/5CBE3601…/usr/standalone/firmware` fails ENOENT
  (not required, harmless) → `data-protection`/`sepctl` ("No SEP present",
  expected) → `finish-obliteration`/`mobile_obliterator` → **launchd starts the
  whole daemon set**: `assetsd`, `suggestd`, `fairplayd.H2`, `medialibraryd`,
  `peopled`, `blomd`, `duetexpertd`, `fileproviderd`, `symptomsd`, `spindump`,
  `bluetoothd`, `nesessionmanager`, … with `SWEET AKS` answering selectors
  0/7/17/35 and the sandbox denying `symptomsd` privilege 1002.
  `sweetlog=0` did **not** change anything: `mount_hfs` was simply slow, not
  deadlocked, so the persistent disk log is not implicated (keep it off during
  bring-up anyway).
  Boot speed: the panel is drawn one character at a time, and every daemon
  prints `exec …`/`SWEET AKS …`, so the sampler's 120 s cadence (`SMP ---
  sample N`, patch 0054) is the clock to read progress by; a boot to the
  daemon phase takes >10 min on the panel. The dyld "not in trust cache"
  flood only happens for the first process that maps the shared caches.
  Next wall to expect: first daemon crash (`_PanicOnCrasX` is already applied
  in the image), `watchdogd`, `backboardd`/WindowServer, then SpringBoard.
- **SMP WORKS on fajita (console7, 2026-10-20)**: `cpus=4 sweetsmp=1` — PSCI
  `CPU_ON` and the SGI1 self-test both work on this ABL/TrustZone, so the four
  A55 cores come up. The boot to SpringBoard now takes ~3.5 min instead of
  10+ min on one core. `sweetsmp=0`/`cpus=1` remains the fallback.
- **GUI presents on the panel (console6)**: dropping `sweetfb_console=1` and
  adding `sweetfb_noconsole=1` makes `AppleCLCD::present()` copy the client
  surface and mute the console at the first swap (patch 0067/0083). On the
  panel: the iBoot Apple-logo splash shows through (the console had been
  painting over it), then a dim-out and a black frame — i.e. real presents,
  not a dead display. `console8.img` (SHA256 `24fc3ad7…219e`) is the same but
  with SMP, to see the UI.
- **SpringBoard reaches its root scene (console7, with console on)**:
  `This is SpringBoard`, `FBScene - com.apple.springboard`,
  `FBSceneManager: Added SBStartupTransitionToLockOut`,
  `State changed from 'Initial' to 'Working'`, `SBApp: becoming to root
  scene`, CoreAnimation matrices (`matr1x(0.17 0 0 0.17 …)`), then
  `Crash SpringBoard[… ] Reason no 2 code 0x6` → ReportCrash → `exec
  SpringBoard` relaunch, with `SWEET AKS: SpringBoard sel 8/35/7/17 → 0x0`.
  `backboardd[56]` and `SpringBoard[261]` show in the sampler on their
  mach_msg wait loops. `fairplayd.H2` and `bluetoothd` crash-loop forever —
  ios-topaz records the same ("no hardware"); not a blocker.
  The device clock is unset (`1969-12-31`), so anything checking certificate
  dates (TLS, activation servers) will see an invalid time until a real RTC
  source exists.
- **Black frames after the Apple splash are expected at this stage.** With the
  GUI allowed to present (`sweetfb_noconsole=1`), the panel shows the iBoot
  splash uncovered by the muting console, a janky dim and then black: the
  surfaces backboardd hands us are empty because our `SweetSurface` is the old
  ios-sweet one — 884 lines with **no client-image/client-memory wrapping at
  all** (`use_task_memory`, `client_address`, `IOSurfaceAddress` are absent).
  `ios-topaz` is a different phone (Redmi Note 12 4G, `topaz`/`tapas`, SM6225)
  and its tree has diverged, so 0132–0139 do not apply as patches: only 0131
  does (`patch -p1 --dry-run`), 0132–0139 fail 1–5 hunks each. The work is to
  reimplement what those patches do, in this order: wrap client images/memory
  (0132), keep values + bulk attachments + purgeability (0133), client-address
  surfaces (0134), detach semantics/zombie state (0135–0137), publish the
  client-address surfaces (0139) — plus `IOAcceleratorES` (below).
- **Patch 0087 (2026-10-20): empty `IOAcceleratorES`** — ported idea of
  ios-topaz 0138. QuartzCore's `CAMetalContextCreate` polls
  `IOServiceMatching("IOAcceleratorES")` 300 times 100 ms apart before it goes
  on, i.e. 30 s at every backboardd start, which on the panel looks like a
  dead black screen. `AppleCLCD::start()` now publishes an `IOAcceleratorES`
  with no `MetalPluginName`/`MetalPluginClassName` (Metal finds it, passes it
  over, renderers unchanged); `sweetaccel=0` disables it. All 87 patch files
  pass `check-hunk-counts.py`.
- **Patch 0088 (2026-10-20): `SweetSurface` makes surfaces of the client's own
  memory.** This is the actual reason the panel is black after the splash. The
  iOS 16 CoreAnimation GL renderer does not ask for fresh buffers — it wraps
  memory it already owns (`IOSurfaceWrapClientImage`/`Memory`, and
  `IOSurfaceAddress` in the create dictionary); our old ios-sweet
  `SweetSurface` only ever allocated its own wired buffer, so every surface it
  returned was empty. Ported the behaviour of ios-topaz 0132 + 0134 + 0139:
  selectors 6/7, `IOSurfaceAddress` in `create()`, publishing those surfaces
  (unpublished they had id 0 and the framework treated several as one),
  `wrapDelta` in the returned base address, prepared-range lifetime via
  `memory->complete()`, default cache mode for wrapped memory. All 88 patch
  files pass `check-hunk-counts.py`.
  Still missing from that series: values/bulk attachments/purgeability (0133),
  detach semantics and zombie state pages (0135–0137) — likely needed for
  animations and for icons that survive a view release.
- **console9/console10 on the phone (2026-10-20)**: both still show many log
  lines, the iBoot splash, then a *janky* jump to black. `0088` is in
  `console10` (kernel `8519d6d5…c4ccc`), so the client-memory path is compiled
  in, but with the console muted at the first swap the panel gives no further
  information. `console11.img` (same kernel, `sweetfb_console=1`, `sweetfb_hz=10`)
  keeps the kernel console on the panel so the `SWEET SURF: wrap …`,
  `create around client memory …` and later boot lines can be filmed.
  On the jank: there is no GPU driver, so CoreAnimation composites the
  1080×2340 layer tree on the CPU (4×A55), while `present()` memcpys a whole
  10 MB frame at `sweetfb_hz` (30 Hz ≈ 300 MB/s) with no vsync and with UFS
  polled I/O competing — 10 Hz is the sensible bring-up rate.
- **Console log over adb WORKS (2026-10-22) — no more filming.** Patch 0047
  writes the whole console stream into the last 4100 KiB of `userdata`;
  `tools/sweet-log-pull.sh` (+ `tools/sweet-log.py`) read those 1025 blocks from
  a recovery with adb and decode the `SWEETLOG` header/ring. Working recipe:
  `fastboot boot <orange-fox-r12-fajita.img>`
  (OrangeFox R12.0 unofficial V7 for fajita, 50,008,064 B, SHA256
  `61eb9f7a…3d34`; TWRP 3.7.0 for fajita did **not** boot) → `adb
  wait-for-device` → pull → `adb reboot bootloader`. First pull: 489,641 bytes
  / 6977 lines. The recovery image is kept outside git.
- **What the first full log says (console12)**: `backboardd` opens AppleCLCD,
  gets `display on`, creates two 1125×2436 BGRA surfaces
  (`SWEET SURF: backboardd create id 2/3 … size 11239424 keys 11`) and swaps
  them (`SWEET FB: swap 2/3 …`), so presenting works and `IOAcceleratorES`
  (0087) is found. The blocker is userland: SpringBoard aborts in
  `-[_UIScreenComplexBoundingPathUtilities _loadBitmapForScreen:type:]`
  (`_UIScreenComplexBoundingPathUtilities.m:326`) with
  `NSInternalInconsistencyException: Failed to load bounding path bitmap data
  from the asset manager for asset name:
  BoundingPathBitmap-1125x2436-375x812-3.00x`, then relaunches forever
  (pids 235, 239, 242, 245 …). `PosterBoard` then SIGTRAPs too.
- **The asset is present**: `UIKitCore.framework/BoundingPathData.bundle/`
  `Assets.car` is 101,768 B, starts with `BOMStore` (uncompressed) and contains
  exactly that rendition name (checked on the mounted image). So this is not a
  missing file — the *selection* fails.
- **No `/product` node**: the log shows `IOKIT SpringBoard: path
  IODeviceTree:/product -> none`; `research/ipsw-x/d22ap.adt` is not in this
  tree, so mkadt emitted no `/product` at all. CoreUI/CoreThemeDefinition pick
  compiled artwork from a catalog by exactly those properties. `tools/mkadt.py`
  now falls back to the full 61-property **D22 identity** published by the
  HackiOS release (`xnuloader/identity.h`, generated from the real
  `DeviceTree.d22ap.im4p`): `graphics-featureset-class APPLE4`,
  `graphics-featureset-fallbacks APPLE3:APPLE3v1:APPLE2:APPLE1:GLES2,0`,
  `artwork-device-idiom phone`, `artwork-scale-factor 3`,
  `artwork-display-gamut P3`, `artwork-device-subtype 0x984`,
  `oled-display`, `thin-bezel`, `ui-background-quality 100`, `product-name
  "iPhone X"`. `ADT_GAMUT=P3|sRGB` selects the gamut (the real phone says P3;
  our framebuffer is sRGB 8-bit, so sRGB is the fallback).
- **Reference repos (hackios-xnu-kernel / -userland, snapshot 2026-10-22)**:
  POCO X5 Pro (`redwood`, SM7325) + QEMU, XNU `xnu-8796.121.2` built on Linux
  with clang+theos, iOS 16.5 (20F66) iPhone X userland, same D22 identity
  (`xnuloader/mkidentity.py`). They never hit the bounding-path abort, but two
  of our suspects are exonerated by their code: their Sandbox stand-in has **no
  vnode/file hooks at all** (nothing can block a framework reading another
  bundle) and their SpringBoard reaches lock screen and home screen with the
  Metal device array deliberately emptied in backboardd. Their general lesson
  matches our case: Apple's code aborts when a file it expects is absent, and
  CoreUI selects artwork by device capability, not just by size.
- **SMP raised to all eight cores**: `cpus=8 sweetsmp=1` (A55 MPIDR
  0x000–0x300 + A75 0x400–0x700); `console14.img` (SHA256 `ad9efb57…369c`) and
  the sRGB twin `console15-srgb.img` (`d08a5c87…4973`) are built.
- **LOCK SCREEN (console14, 2026-10-22)**: with the D22 `/product` identity the
  panel shows the iOS lock screen — `CRASH SpringBoard: 0`,
  `Terminating app: 0`, `SWEET CPU: 8/8 CPUs initialized (SGI1 verified)` and
  all eight cores came up through PSCI (`cpu=0..7 … came alive; SGI1 OK`).
  So the bounding-path abort was entirely the missing device identity.
- **Keys: power works, volume does not yet.** With `sweetkeys=1` the log shows
  `SWEET KEYS: arb=0x50000000 apids=512 pon-apid=172 gpio4-apid=261` and
  `key=0 down=1 pon=0x1` → `SWEET HID: key 0x30 down (1 clients)`, i.e. the
  PON power key is read through the SPMI arbiter and delivered as HID. The
  volume keys read `gpio4:c110=0`: the driver uses PPID `0x4c1` (PM6150L SID 4
  GPIO4), which answers on fajita but is not PM8998. Fajita's SPMI arbiter has
  the *same* addresses as sweet's (`core 0xc440000`, `obsrvr 0xe600000`,
  `cnfg 0xc40a000`, PM8998 at USID 0, GPIO `pinctrl@c000`), so only the
  peripheral number is missing. **Patch 0089** adds `sweetkeysprobe=1`, which
  scans slave 0–4 × GPIO peripherals 0xc0–0xd6 read-only, prints every
  candidate that answers (status/subtype/enable/mode) and then logs status
  changes, so one boot with the volume keys pressed names the register.
- **Volume keys resolved (probe boot, 2026-10-22)**: `sweetkeysprobe=1` answered
  `ppid=0x0c4` and `ppid=0x0c5` (slave 0, peripherals 0xc4/0xc5 = PM8998
  GPIO5/GPIO6), both `subtype=0x10 en=0x80 mode=0` (input, enabled) and
  `status=0x1` released / `0` pressed. So **GPIO5 = volume down, GPIO6 =
  volume up**. **Patch 0091** detects that pair and uses the fajita layout
  (power = PON bit0, volume up = 0x00c5 bit0, volume down = 0x00c4 bit0) while
  leaving the sweet path alone; HID usages 0/1/2 already existed.
- **Touch port written (patch 0090)**: a fajita branch in `sweet_touch.c`
  (`sweetts=1`, still gated by `sweettouch=1`): GCC vote `0x5200c`
  bits 20/21/26, RCG `0x184d8` (XO/1), CBCR `0x184d4` poll, a gpio helper with
  an explicit TLMM block (NORTH `0x03900000` for ATTN 125 / reset 99, SOUTH
  `0x03d00000` for the gpio88 1.8 V switch — sweet only knew NORTH), RPMh
  `ldoa28` at 3.008 V, reset pulse + 200 ms settle, then RMI4 over the existing
  GENI transport: 1-byte page-0 addressing with a repeated start, PDT scan down
  from `0xE9` (F34/F01/F12), F01 reset + `0x84` + product id, a 10 ms poll of
  the F01 IRQ byte and an 88-byte F12 2D report (10 objects × 8 bytes) mapped
  to 1080×2340 with `sweetts_xraw`/`sweetts_yraw` overrides and raw maxima in
  the log. The research behind the numbers is in
  `docs/fajita-touch-rmi4-spec.md`.
- **First touch boot froze the SoC (console20-input, 2026-10-22)**: the phone
  went to a crashdump 25 s in, exactly when the touch thread woke
  (`SWEET TS: fajita RMI4, starting in 25 s` is the last touch line, the ring
  ends on a key event and holds a single flush, so the freeze was hard). Two
  real bugs, both fixed by **patch 0093**:
  * the RPMh helper hard-codes sweet's apps RSC `0x18220000` / TCS `0x18220d00`;
    SDM845 has `0x179e0000` / `0x179e0d00` (vendor dts `mailbox@179e0000`), so
    the rail vote addressed a wrong TCS. Now boot args `rpmhrsc=`/`rpmhtcs=`;
  * sweet maps `0x5b000` of TLMM (pins up to 90), but fajita's reset is gpio99
    (offset `0x63000`) and ATTN gpio125 (`0x7d000`) — outside that mapping.
    The fajita path now maps `0x80000` of TLMM NORTH and SOUTH.
  `sweetts_norail=1` skips the rail vote, used for the first isolated test.
- **Keys confirmed on hardware**: `SWEET KEYS: fajita layout, vol-up apid=190
  vol-down apid=189`, `fajita keys ready`, and a volume-down press produced
  `SWEET HID: key 0xea down/up` (the HID service had no client yet that early,
  which is expected).
- **Touch hang bisected (2026-10-22)**: with `sweettouch=1` the SoC froze at
  37–49 s with `flush #1` and no panic — a hard hang, not a panic. Isolating
  the keys (`sweetkeys=0`, touch only) still hung, and **with
  `sweettouchdelay=300` the same kernel survived** (2847 log lines, reached the
  daemon loop). So the delay works and the hang is inside the touch hardware
  bring-up, before its first post-delay printf (the MMIO mapping or the three
  GPIO writes). Patch **0095** prints before/after every step and adds
  `sweetts_nogpio=1`, `sweetts_noclk=1`, `sweetts_nose=1` so one kernel can
  bisect with boot args. Patch **0094** (panic-visible + panic-time ring flush,
  header seq `0xffffffff`) is in the same build for the next real panic.
- **Bisect result (2026-10-23 morning)**: `console24-nogpio` (GPIO writes
  skipped) **survived** — 2835 log lines, flush #21, reached the daemon loop —
  and the touch code ran all the way to the I2C probe: `maps …` →
  `ldoa28 vote -> 0 (skipped)` → `gcc vote=0x5bc0000 cbcr=0x4220` →
  `SWEET TOUCH: se7 fw=0x300 proto=3 status=0 tx=0x20102964 rx=0x20104900` →
  packing ok → `probe xfer addr=0x20 read len=6 stretch=1 err=5 irq=0 seen=0
  tx=0 rx=0 status=0`. The SE is clocked and reachable; the transfer never
  starts because the pins were never muxed (the whole GPIO step had been
  skipped, since it was the hang).
- **Root cause of the GPIO hang**: mainline `pinctrl-sdm845.c` puts **gpio88
  (VIO) and gpio125 (ATTN) in the EAST tile (0x03500000)**, and only gpio99
  (reset) plus the I2C pins 49/50 (qup12) in NORTH; the register is
  `tile + 0x1000*pin`. Writing pins 88/125 into the SOUTH/NORTH slots hit
  unimplemented addresses and froze the SoC. Patch **0096** maps EAST, muxes
  49/50 to qup12 and uses the right tiles: gpio88 `0x03558000`,
  gpio125 `0x0357d000`, gpio99 `0x03963000`, gpio49 `0x03931000`,
  gpio50 `0x03932000`.
- **Next boot (`console25-touch3`)**: GPIO + I2C mux fixed and the rail voted
  with the fajita RPMh bases (`rpmhrsc=0x179e0000 rpmhtcs=0x179e0d00`, no
  `sweetts_norail`). Success looks like `PDT 0xe9 fn=0x34`, `PDT 0xe3 fn=0x1`,
  `PDT 0xdd fn=0x12`, `product id "…"` and then `raw max x=… y=…`.
- **console25-touch3 (2026-10-23): everything works except the transfer.**
  The boot survived (2640 lines, SpringBoard running) and the log shows the
  whole bring-up:
  `SWEET RPMH: rsc=0x179e0000 tcs=0x179e0d00 … cmd-db … ldoa28 addr=0x42100
  slave=4` → `TCS0 ACTIVE 3008 mV mode=7 enable=1` → `TCS0 done=1` →
  `ldoa28 vote -> 0` (rail really voted), then
  `gpio49/50 qup12 mux` → `gpio88 high (EAST)` → `gpio125 input (EAST)` →
  `reset sequence done` (no hang, so the EAST addresses are right), then
  `gcc vote=0x5bc0000 cbcr=0x4220` and
  `SWEET TOUCH: se7 fw=0x300 proto=3 tx=0x20102964 rx=0x20104900 ios=0x3`
  (the SE sees the bus), but
  `probe xfer addr=0x20 read len=6 stretch=1 err=5 irq=0 seen=0 tx=0 rx=0
  status=0` — the command never starts.
  **Patch 0097** writes both `SE_I2C_TX_TRANS_LEN` and `SE_I2C_RX_TRANS_LEN`
  for every command (mainline does; ours wrote only one, so the first RMI4
  read ran with a stale TX_LEN) and dumps M_CMD0, TX/RX_LEN, STATUS, IRQ,
  IRQ_EN, OUTPUT_CTRL, CGC and DMA_MODE around the first six commands.
  `console26-touch4` is that kernel with keys enabled again.
- **console26-touch4 (2026-10-23): keys confirmed, touch reads were rejected
  before any hardware access.** Keys deliver HID `0xe9` (VOL+), `0xea` (VOL−)
  and `0x30` (power). The touch debug dump never printed, which pointed at
  `touch_msg_run()`: it returns `EIO` for a **combined** transfer
  (`(nt && nr)`), and `rmi_read()` issued the RMI4 register byte and the read
  as one command — so every read failed with `err=5` and no register was ever
  touched. **Patch 0098** reads in two transactions (write the register byte,
  then read), which is what `touch_read()` does for sweet's controllers; RMI4
  keeps the pointer between transactions.
  `console27-touch5` is that kernel (keys on).
- **iOS root image built (2026-10-20)**: `~/ipsw-x/ios16-root-20H392.img`
  17,179,869,184 B (16 GiB, case-sensitive journaled HFS+, 12 GiB used,
  SHA256 `4d424a63…643b`) and `.simg` 12,145,480,060 B (flash this one with
  `fastboot -S 512M flash userdata …simg`), built by `tools/mkiosroot.sh` and
  `tools/sweet-root-tweaks.py`
  (launchd `_PanicOnCrash`→`_PanicOnCrasX`, CommCenter jobs removed,
  `/private/var/containers/*`, logd stores as `_logd` 272, keybag,
  dyld cache hard links, VirtualAudio disabled, `StartRecorderServer` off,
  migration/SpringBoard/Setup prefs). Two host bugs fixed in
  `tools/mkiosroot.sh`: coreutils here rejects numeric `install -o/-g`
  ("invalid user: 272") → `mkdir`/`chown`/`chmod`; and the fresh-journaled-volume
  "volume header needs minor repair" from `fsck.hfsplus -n` is now tolerated.
  Nothing flashed yet (destructive step needs explicit user confirmation).
- **iOS userland source downloaded (2026-10-20)**: `tools/remotezip.py` pulled
  only the needed members of the iPhone X 20H392 IPSW
  (`iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw`) into `~/ipsw-x`:
  `087-86698-044.dmg` (OS rootfs, 4,730,814,044 B, SHA256 `80f426d5…2483`),
  `087-86593-047.dmg` (Cryptex SystemOS, 2,743,074,816 B, `9cd738f3…6849`),
  `087-86715-047.dmg` (Cryptex AppOS, 10,485,760 B, `391f2df3…4608`), plus
  BuildManifest, root_hashes, trustcaches and the OS mtree; all CRC-32 OK.
  Nothing of this is in git.
  (gzip 6990 + fajita2 DTB 415955), `ramdisk_size = 16610976` (the payload),
  payload `phys_base=0x100000000` `mem_size=0x17c7a0000` (5.945 GiB), with
  `pram` and `embedded-panic-log-size` present in the ADT.

## Next concrete actions

1. Flash the new kernel and read the panel: image
   `%USERPROFILE%\fajita-flash\console1.img` (17,043,456 B, SHA256
   `8e24059c…5c5e`, kernel `7f27332a…30df`, patches ≤0083) and
   `console2.img` (patches ≤0084, `sweetecon=1` in the cmdline). Flash with
   `fastboot flash boot_a <img>` then `fastboot reboot`; the phone must be
   power-cycled (Vol- + Power) into fastboot first, it stays in the frozen XNU
   state otherwise. Slot `a` stays the test slot, `boot_b` is LineageOS.
2. Expected next stop once the log is visible again: `bsd_init` →
   `vfsinit ok` → `vfs_mountroot` → `IOFindBSDRoot` waiting for an
   `Apple_HFS` media (`userdata` still holds Android ext4). On sweet that wait
   is silent, not a panic, so a boot that "ends" right after `BSD root` is
   progress. Then flash the iOS root image (destructive → confirm with the
   user first).
3. Then: `rd=ufsroot0` root mount, `/sbin/launchd`, PM8998 keys, Synaptics
   RMI4 touch, and eventually the port of the later ios-topaz patches
   (console scanout, WLAN, MDP/DSI).
4. Return to Android with the bootloader menu (slot `b`) when the phone is
   needed; the local `fastboot` cannot `set_active`.

## Do not assume

- The panel may stop scanning out after ABL hand-off; confirm with a test
  pattern. If it does, a real DSI/MDP driver is required. (The shim's own
  console *does* render on the panel, so the framebuffer survives hand-off.)
- The live FDT memory map is now measured (see above) — do not re-guess it, but
  do re-check it if the unit is ever swapped for a different RAM SKU.
- UFS 2.1 timing and the Synaptics chip variant (s3320 vs s3706b) need
  on-device confirmation.

### GPU stage 2 — assets ready (2026-10-23)

- **Firmware extracted** from the partition dump (`vendor_a.img`, ext4
  `/firmware/`) into `~/gpu-fw/` on the build host: `a630_gmu.bin` 32,768 B,
  `a630_sqe.fw` 32,136 B, `a630_zap.b00` 148 B, `.b01` 6,536 B, `.b02`
  1,968 B, `.elf` 14,256 B, `.mdt` 6,684 B. Keep them out of git; a100 KB
  total is small enough to embed in the kernel for bring-up (no VFS
  dependency) if that is simpler than loading from the iOS root.
- **Stage-2 order**: CX/GX rail votes, un-collapse the GDSCs (`SWEET GPU`
  showed GX/CX `0x222001`) and ungate the GMU/gfx clocks (`0x80004220`,
  `0x80000000`), then GMU **legacy** mode: flat image to `GMU+0x0c00` (no
  block headers, `dtcm_base 0x40000`), **SPTPRAC enable**, **HFI v1**
  payloads, then zap through SCM (`PAS_GPU 13`) with all b0x segments, then
  the 3D core: CP/RBBM init, 32 KiB ring, `a630_sqe.fw`.
- **Build loop decision**: every GPU step needs a kernel rebuild + flash +
  log pull (~15 min through CI, plus GitHub's artifact egress limits). A
  Linux-native clang build (HackiOS does xnu-8796 with stock clang + theos +
  the iPhoneOS SDK, ~45 s) would make the rest of this work several times
  faster; Docker-OSX is not an option on this host (no `/dev/kvm` in WSL2,
  4.8 GiB RAM).

### Local XNU build on Linux — state (2026-10-23)

Attempted because every GPU iteration costs ~15 min through CI. Progress:

- **Toolchain ready**: `apt` packages (clang 21.1.8, lld, make, flex/bison, m4,
  autoconf, uuid-dev, fakeroot, rsync, zip, libxml2-dev, libtinfo6), **theos**
  in `~/theos` with the Linux toolchain (`toolchain/linux/iphone/bin`: clang,
  ld64, checksyms...) and `sdks/iPhoneOS16.5.sdk` (271 MB, sparse clone);
  `THEOS=~/theos` is in `~/.bashrc`. The theos installer needed
  `libxml2` → `libxml2-dev libxml2-utils` (Ubuntu 25.10 renamed the package).
- **HackiOS harness fetched**: `~/hackios-xnu-kernel` (46 MB). Its
  `xnu-deps/setup.sh --stage1` works after the theos install: builds `mig`
  (bootstrap_cmds port), `unifdef`, `tcsh`, downloads the macOS 13.3 SDK for
  the DriverKit headers and builds the `iPhoneOS16.5.xnu.sdk` overlay
  (`xnu-deps/sdk`).
- **Build-system port applied** to `~/xnu-local` (= `xnu-135` + patches
  0082–0102) from `redwood.patch`: `Makefile` (sysctl → nproc),
  `makedefs/MakeInc.cmd` (MEMORY_SIZE from /proc/meminfo), `MakeInc.top`,
  `SETUP/config/doconf`, `bsd/conf/Makefile.arm64`,
  `tools/lldbmacros/core/syntax_checker.py`. The only rejected hunk is their
  BCM2837 `+pan` flag (SoC-specific, not needed).
- **Build now reaches the `bsd` component** and stops on two things:
  1. the staged source trees are missing — run
     `xnu/patches/0019-stage-libpthread.sh`, `0020-stage-bearssl.sh`,
     `0026-stage-hfs.sh` in the tree before building (the CI does this through
     blacktop's `build.sh`);
  2. clang 21.1.8 rejects `__builtin_xnu_types_compatible` (`__is_same`) from
     their `xnu-deps/hostinc/xnu_clang_compat.h` as used by `IOLib.h` in C++
     (their build was tested with clang 22.1) — needs either clang 22 or a
     compat tweak.
- Command used (from `~/hackios-xnu-kernel`):
  `source ./xnu-env.sh; export XNU_SRC=~/xnu-local; cd $XNU_SRC; make -j6 -k
  SDKROOT=iphoneos ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=SWEET
  KERNEL_CONFIGS=DEVELOPMENT ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64
  BUILD_WERROR=0 BUILD_LTO=0 DO_CTFMERGE=0 HOST_CC="clang -include
  $XNUDEPS/hostinc/hostcompat.h -I$XNUDEPS/hostinc ..." HOST_FLEX=flex
  HOST_BISON=bison HOST_GM4=m4 CC=xnu-clang CXX=xnu-clang++ LOGCOLORS=n`.
- Verdict: 2–4 focused hours from a working local kernel build. Until then CI
  stays the build path, and the GPU work should be batched to make each CI run
  count.

### GPU stage 2a written (patch 0103, 2026-10-23)

Ports the first *writes* of HackiOS `bsd/dev/redwood_adreno.c`
(`step_gpucc`/`step_cx_power`) using the addresses stage 1 confirmed:

- `GCC+0x71004` (`gcc_gpu_cfg_ahb_clk`) enabled and polled for un-halt — the
  same offset on SDM845 (checked against mainline `gcc-sdm845.c`: 0x71004,
  memnoc 0x7100c, snoc_dvm 0x71018);
- `gpu_cx_gdsc` (`gpucc+0x106c`): clear `SW_COLLAPSE`, poll `GDSC_POWER_ON`
  unless the switch is under hardware control. Safe here because the CX rail
  is up while the SoC runs; the GX half, the clocks and the GMU are next.
- `adreno=2` = stage 1 reads + 2a; every write flushes the console ring first,
  so a hang still names the step on disk. `console34-gpu2a.img` carries it.

The rest of the ladder, from their driver (for the next patches):
GX GDSC (`0x100c`) + gfx3d clock, GMU clock root (`0x1120`) and
`CX_GMU_CBCR`/`GX_GMU_CBCR`/`AHB`/`CXO` ungating, GMU power-up with the flat
`a630_gmu.bin` (legacy mode: ITCM at `GMU+0x0c00`, `dtcm 0x40000`), **SPTPRAC**
enable, **HFI v1** tables, zap through SCM (`PAS_GPU 13`, all b0x segments),
then CP/RBBM init with `a630_sqe.fw` and a 32 KiB ring.

### Local build handed to a subagent (2026-10-23)

Blocked on Apple-private headers that only Xcode's SDK has
(`AppleKeyStore/AppleKeyStoreFSServices.h` for `bsd/sweet_hfs`, plus
`cp_handle_vnop`/`io_params`/`CP_*_ACCESS`), and on the SHA-256 asm
(`processor not supported`). A subagent continues in `/home/edi194/xnu-clean`
(stub the private headers or compile the CONFIG_PROTECT paths out, fix the
assembler flags) while the main line continues on CI. Everything else about
the local build works: theos + clang 22 + SDK overlays, the HackiOS harness
(mig/unifdef/tcsh/iig), the build-system patches, and all 103 project patches
applying to a clean xnu-8796.141.3.

### Local build: compiles, does not boot (2026-10-23 evening)

The Linux kernel builds in ~130 s with the hackios harness and identical
`SFLAGS` (see `~/xnu-clean/LOCAL-LINUX-BUILD.md`), but on the phone it stops at
the **`sweet early 5`** marker: the shim jumps in and the kernel dies inside the
bootstrap console/VM setup, so the local binary is not usable as-is (likely the
link layout: the local build is stripped, has the `libcc_kext` stand-in and the
harness' firehose/pthread archives). Its size is 15,753,496 B vs the CI's
~16.6 MB payload, another sign that the linking differs. **CI remains the build
path**; fixing the local one is its own task (compare `__TEXT`/`__DATA` segment
layout and the entry point against the CI kernel with `llvm-otool`/`nm`).

### ios-topaz "metal" branch (checked 2026-10-23)

`oosexgang/hackios-xnu-kernel` branch `metal` (kernel `c2ddff4`, userland
`29eef72`) is **not** a new GPU path: 16 commits about one kernel for every
phone with the same SoC blocks (`hackios.patch`, `HK*` instead of `Redwood*`),
dual boot with a boot menu, a boot guard, bundles, an installer and the thermal
service. The GPU driver differs from `main` by 48 lines (renames), `HKGPU.cpp`
by 140 (renames). Two new screenshots, `docs/adreno-springboard.png` and
`docs/gpu-first-frame.png`, confirm their Adreno path reaches SpringBoard, so
porting `redwood_adreno.c` to a630 is still the right approach.

### GPU stage 2a WORKS on hardware (console36, 2026-10-23)

The first write to the GPU block succeeded and the phone booted to SpringBoard:

```
SWEET GPU: gcc +0x71004 = 0x1                 (gpu_cfg_ahb already running)
SWEET GPU: gpucc +0x106c = 0x222001           (gpu_cx_gdsc collapsed)
SWEET GPU: gpucc +0x1540 = 0x5ff4             (cx_hw_ctrl)
SWEET GPU: write gpucc +0x106c = 0x222000     (clear SW_COLLAPSE)
SWEET GPU: cx_gdscr = 0xf8222000 cx_hw_ctrl = 0x80001fe0 -> ON
```

GX stayed collapsed (0x222001), as expected. `adreno=2` is therefore safe on
this device and stage 2b (patch 0105, `adreno=3`) enables the clock branches:
GCC `gpu_memnoc_gfx`/`gpu_snoc_dvm_gfx`/`ddrss_gpu_axi` and gpucc
`cb`/`cxo`/`ahb`/`hub_aon`/`hub_cx_int`/`cx_gmu`/`smmu vote`, each read back
with its halt bit. The PLL vote (`GCC+0x52000` froze the bus in 0099, so it
needs the exact SDM845 register) and the GMU/hub RCGs are the next step.

### GPU stage 2c: what SDM845 actually has (console38, 2026-10-23)

```
SWEET GPU: gcc pll vote +0x52000 = 0x11          (GPLL0 bit 0 and GPLL4 bit 4: already on)
SWEET GPU: gmu_clk_src +0x1124 = 0x602           (source 6 = GPLL0/1.5 -> 200 MHz: taken)
SWEET GPU: hub_clk_src +0x1180 = 0               (not taken: the register does not exist here)
SWEET GPU: gpucc cb / hub_aon / hub_cx_int = 0   (same: no such branches on this chip)
```

**HackiOS' driver is for an a660 (SM8250), not SDM845.** `gpucc-sdm845.c` has
only `gpu_cc_cxo_clk`, `gpu_cc_cx_gmu_clk`, `gpu_cc_gmu_clk_src` and
`gpu_cc_pll1`; there is no `hub_clk_src`, `cb`, `hub_aon` or `hub_cx_int`, which
is why those reads stay 0 and why `GCC+0x52000` bit 16 does nothing (there the
register enables GPLL0 in bit 0 and GPLL4 in bit 4, and reads `0x11` = both
already on). For a630 the clock work is done: CX GDSC on, `gmu_clk_src` 200 MHz
from GPLL0/1.5, `cx_gmu`/`cxo`/`ahb` and the GCC memory clocks on. The GMU
answered the read at `gmu+0x501c` before any of this, so its AHB was already up.

Also: the four SpringBoard crashes seen in console37 did not come back in
console38 (0 crashes, same userland), so they were a startup race, not the GPU
clocks.

### GMU register offsets: settled (2026-10-23)

The GMU's registers are indexed in **words from the GMU base** `0x506a000`, so
the byte offset is `4 * n` - exactly HackiOS' `GMU_WORD(n)`, and it is right for
a630 too. Proof: the older generated Linux header
(`WSL2-Linux-Kernel/drivers/gpu/drm/msm/adreno/a6xx_gmu.xml.h`) has ITCM
`0x0c00`, DTCM `0x1c00`, SYSRESET `0x5000`, FW_INIT_RESULT `0x501c`,
HFI_CTRL_STATUS `0x5180`, and every entry of the newer
`registers/adreno/a6xx_gmu.xml` is that number plus `0x1a800` - the newer file
counts from the GPU base (`0x5000000`) instead of the GMU base. Byte offsets
used from now on: ITCM `0x3000`, DTCM `0x7000` (versions at `0xafe0`),
SYSRESET `0x14000`, BOOT_CONFIG `0x14004`, FW_INIT_RESULT `0x14070`,
SPTPRAC status `0x14340`, HFI status `0x14600`, HFI init `0x14618`,
HOST2GMU_INTR_SET `0x14650`, AHB_FENCE_CTRL `0x24c40`.

### a630 GMU: what Linux does (for the next steps)

`a6xx_gmu.c` marks a630 `gmu->legacy = true` ("manual SPTPRAC control"). The
firmware is **flat** and the legacy path writes all 32 KB with one bulk write at
`GMU_CM3_ITCM_START` (16 KB of code, then the 16 KB of data that follows it -
DTCM `0x7000` lies inside that window). Start sequence: read
`DTCM_START + 0xff8` (firmware version; ours reads 0, so the mask is
`0xffffffff` and the expected `FW_INIT_RESULT` is **`0xbabeface`**),
`SYSRESET=1`, `PWR_COL_CP_RESP=0`, `SYSRESET=0`, then poll `FW_INIT_RESULT`.
Before that `a6xx_gmu_fw_start` needs `a6xx_rpmh_start` (the GMU's RSCC/RPMh
interface; the GMU also has the `gmu_pdc` block at `0xb280000`), the HFI table
iova, the log iova and `AHB_FENCE_RANGE_0`, `CM3_CFG=0x4052`, the chipid at
`HFI_SFR_ADDR` and the log at `PWR_COL_CP_MSG`. Those buffers need an address
space the GMU can reach - the GPU SMMU (bypass or a context) or physical
addresses.

### Firmware transport (patch 0107)

`tools/mkpayload.py --blob FILE` appends files as extra payload segments and
appends `sweetfwN=<pa>:<size>` to the command line, so `a630_gmu.bin` travels in
the boot image and never enters git (`tools/build-fajita.sh` passes
`${GPU_FW:-$HOME/gpu-fw/a630_gmu.bin}`). Stage 3a (`adreno=5`) reads the GMU's
registers with the offsets above, maps the blob, writes it into the ITCM window
and reads it back word by word.

### GPU stage 3a WORKS: the GMU takes the firmware (console40, 2026-10-23)

```
SWEET GPU: gmu sysreset +0x14000 = 0x1        (held in reset by the boot loader)
SWEET GPU: gmu sptprac +0x14340 = 0xd4        (GX without power and clock)
SWEET GPU: gmu itcm[0] +0x3000  = 0xa00414be  (code memory answers)
SWEET GPU: firmware blob 0x8000 bytes at 0x1024d0000
SWEET GPU: firmware sum 0xe19e48be, first words 0x43f80 0x9 0xf3804805 0x48058808
SWEET GPU: 0 of 8192 words differ, versions 0 0 0
```

All 32 KB of `a630_gmu.bin` went through the GMU's ITCM window and read back word
for word: the payload transport (`sweetfw0=<pa>:<size>`) and the write path work.
The version block reads 0 because the firmware fills it once it runs, so
`FW_INIT_RESULT` has to become `0xbabeface` (the old mask).

### The GPU's SMMU: hypervisor-owned (console40/41, 2026-10-23)

```
scr0 0x200626 (bits 1,2,5,9,10,21)   idr0 0x48016605 (5 stream matches)
idr1 0x20008005 (32 contexts)        smr[0..4] = 0     s2cr[0..4] = 0x200ff (FAULT)
```

Writing those S2CR entries to bypass **froze the phone** (0111): every write was
dropped, the reads still said `0x200ff`, and the access after the fifth never
came back. The vendor device tree has `qcom,hyp_secure_alloc` on the SMMU and
`sCR0` bit 21 is QCOM's hypervisor bit, so the stream table is virtualised; the
vendor's kgsl reaches it through SCM. **Do not write SMR/S2CR from this port**
(patch 0112 leaves the SMMU alone).

From the same device tree: the SMMU is `qcom,kgsl-smmu-v2` at `0x5040000` with
`qcom,micro-mmu-control 0x6000`, context banks at `qcom,gpu-offset 0x48000` (not
`0x8000`, so the earlier CB reads were of nothing), streams **0 = gfx3d_user,
1/2 = gfx3d_secure, 4 = gmu_user**. The GMU's clocks are gpucc
`gmu_clk`/`cxo_clk` plus gcc `axi_clk`/`memnoc_clk`.

### Where the GMU's memory lives (patch 0110)

`HFI_QTBL_ADDR` is a 32-bit register and every address the kernel has is above
4 GB (the ADT starts at `0x100000000`), so the HFI table and the log go into the
low bank: the live FDT has `/memory` at `0x80000000+0x100000000` with every
reserved-memory carve-out below `0xac800000`, so `0xb0000000` is plain DRAM that
XNU never declares. It is mapped with `ml_io_map`, so the GMU sees the writes
without cache maintenance. HFI: table header (6 words) + two queue headers (12
words each) at `+0`, queues at `+0x1000`/`+0x2000` (a630 legacy: 2 queues,
response queue type 4). Log: `+0x8000`, four pages.

0110 writes what `a6xx_gmu_fw_start`/`a6xx_gmu_power_config` write (HFI SFR chipid
`0x06030100`, table info/address, log address, caches and bus, boot config `2`,
AHB fence range `0x80000000|(0xa<<18)|0xa0`, `CM3_CFG 0x4052`), releases the reset
(`SYSRESET 1`, `PWR_COL_CP_RESP 0`, `SYSRESET 0`) and polls `FW_INIT_RESULT` for
`0xbabeface`. The RPMh interface (`RPMH_CTRL 0xf11`) is left disabled on purpose:
without the PDC/RSCC handshake first the firmware could wait forever for votes
nobody answers.

### GPU, 2026-10-23 evening: what is settled and what is not

**Diagnostics that matter**

* The panel console keeps the whole boot's text; the ring in userdata does not.
  After a crash, photograph the panel: in several boots the ring on disk was
  older than the panel because the panic happened *during* a ring flush (the
  panic flush then waits for the same lock). `tools/sweet-log-pull.sh` is still
  the way to get the ring, but the photo is authoritative.
* OrangeFox is also a Linux with the real memory map: `cat /proc/iomem` there
  says System RAM is `80000000-856fffff`, `85d00000-85dfffff`,
  `85f00000-85fbffff`, `8c417000-8c4fffff` and **`97d00000-27c89ffff`** - one
  contiguous range across the 4 GB boundary. Battery and thermal were checked
  too (100%, 4.38 V, GPU 35 C) and are not the problem.

**Settled**

* Stage 2a (CX GDSC) is required: without it the GMU block reads 0 and hangs
  (`adreno=8` proved it).
* The GMU takes the firmware: 32 KB through the ITCM window, read back word for
  word in console40 and sampled in later boots (`0 of 3 words differ`).
* The GPU's SMMU is the hypervisor's: `qcom,hyp_secure_alloc`, `sCR0` bit 21,
  S2CR writes dropped and the fifth access froze the phone. **Never write
  SMR/S2CR** (0112). Its registers cannot even be read reliably (0113): the
  device tree marks it `qcom,retention`.
* SDM845 has no `hub_clk_src`, `cb`, `hub_aon` or `hub_cx_int` (those are a660
  clocks; HackiOS' driver is for an a660). Writing those gpucc offsets is what
  0116 stopped.
* GMU registers are word-indexed from the GMU base: byte offset = 4 x the
  vendor's number (HackiOS' `GMU_WORD`). The newer Linux xml adds `0x1a800`
  because it counts from the GPU base.
* The low bank at `0xb0000000` is readable from XNU (console50) but a read of it
  *after* the GPU power-on and firmware load froze the boot (console49), so the
  scratch is prepared first now (0120).
* Log flushes from the GPU probe are gone (0117): they were polled UFS writes in
  the first second of boot, and one of them is where console47 died.

**Not settled / next**

* `adreno=7` now: 2a power, 2b/2c clocks (valid ones only), 3a firmware,
  3d HFI table + reset. The last run died right after the stage 3d banner, which
  turned out to be the scratch access, not the reset. With 0120 the reset
  sequence should finally run: `GENERAL_7=1`, HFI SFR/QTBL, log address, caches,
  boot config, fence range, `CM3_CFG 0x4052`, then `SYSRESET 1`,
  `PWR_COL_CP_RESP 0`, `SYSRESET 0` and a poll for `FW_INIT_RESULT ==
  0xbabeface`.
* If the firmware does not start, the two candidates are the RPMh interface
  (`RPMH_CTRL 0xf11`, deliberately still off) and the SMMU (the GMU's stream 4
  has no match and every S2CR is FAULT, so its own memory accesses may be
  refused). The latter would need the hypervisor's cooperation - the vendor's
  kgsl goes through SCM - and there is no known call for it here.

### *** GPU STAGE 3 WORKS: the GMU firmware runs on fajita (console54, 2026-10-24) ***

```
SWEET GPU: hfi address 0x60100000, log address 0x60300000 (unmapped until the SMMU stage)
SWEET GPU: write gmu tcm retention +0x14730 = 0x1
SWEET GPU: write gmu hfi sfr +0x14608 = 0x6030100
SWEET GPU: write gmu hfi qtbl info +0x14610 = 0x1
SWEET GPU: write gmu hfi qtbl addr +0x14614 = 0x60100000
SWEET GPU: write gmu log address +0x14400 = 0x60300000
SWEET GPU: write gmu inter-frame ctrl +0x14300 = 0x9c40400
SWEET GPU: write gmu rpmh ctrl +0x143a0 = 0xf11
SWEET GPU: write gmu fence range +0x24c44 = 0x802800a0
SWEET GPU: write gmu cm3 cfg +0x140b4 = 0x4052
SWEET GPU: write gmu wfi config +0x14008 = 0
SWEET GPU: write gmu sysreset +0x14000 = 0x1
SWEET GPU: write gmu sysreset +0x14000 = 0
SWEET GPU: fw_init 0xbabeface (THE GMU FIRMWARE RUNS)
SWEET GPU: stage 3d done
```

The phone booted to SpringBoard afterwards (3114 log lines, touch and keys fine),
so the GMU runs beside iOS with no side effects. `adreno=7` is the level.

**What made it work: Bergamota.** `ry-diffusion/Bergamota` is iOS 18 on the Poco
F1 - the same SDM845 and the same Adreno 630 - and its `docs/GPU_A630_BRINGUP.md`
plus `xnu/patches-11215/0103-beryllium-gpu-a630-bringup.patch` are the same
ladder done for this exact chip. Their stage 3 boots the firmware **with the SMMU
untouched**: the firmware does not touch RAM while it boots, so `HFI_QTBL_ADDR`
and the log address are the GPU addresses KGSL hands out (`0x60100000`,
`0x60300000`) that nothing maps yet - and `FW_INIT_RESULT` still comes back
`0xbabeface`. That removes the low-bank scratch question from this stage
entirely (the scratch attempts in 0110-0122 are history).

The three registers that were missing here, from their sequence:
`GMU_CX_GMU_WFI_CONFIG` (0x5002 -> byte 0x14008) = 0, `PWR_COL_INTER_FRAME_CTRL`
(0x50c0 -> 0x14300) = `0x9c40400`, and `RPMH_CTRL` (0x50e8 -> 0x143a0) |= `0xf11`
(interface + LLC/DDR/MX/CX/GFX votes).

### Next: the SMMU + HFI stage (Bergamota's stage 4)

Their `smmu_impl_init()` is the piece our 0111/0112 were missing: the GPU's SMMU
needs **qsmmuv2_device_reset** before anything sticks - the DT's
`attach-impl-defs` written while the micro-MMU is halted (`0x6000`, HALT_REQ bit
2, IDLE bit 3). Our `dtb/fajita2.dts` has the same twelve pairs as theirs
(`0x6000 0x2378`, `0x6060 0x1055`, `0x678c 0x8`, `0x6794 0x28`, `0x6800 0x6`,
`0x6900 0x3ff`, `0x6924 0x204`, `0x6928 0x11000`, `0x6930 0x800`,
`0x6960 0xffffffff`, `0x6b64 0x1a5551`, `0x6b68 0x9a82a382`), plus
`qcom,disable-atos` and `qcom,use-3-lvl-tables`.

Then, in their order: context bank 0 at `0x8000` (CBAR/CBA2R in GR1 = 0x800,
`CBAR_S1_BYPASS_S2`, TCR/TCR2/MAIR0 `0x0004ff44`/ACTLR `0x70000000`/SCTLR
`0x00c01067`), **exact SMRs (mask 0)** for stream IDs 5 (gmu_kernel) and 4
(gmu_user), and a 64 KiB non-cacheable block holding the 4 KiB page tables, the
dummy page, the HFI table (0x5000 bytes), the dump and the log, mapped at GPU
addresses `0x60000000`/`0x60100000`/`0x60200000`/`0x60300000`.

Their finding that matters: **masked SMRs do not stick, exact ones do** (from the
A618 work, patch 0083), and `smmu_write_sme` writes S2CR first, then SMR, then
reads both back with `sGFSR`.

### Bergamota: what its repo and its A618 ancestor say (checked 2026-10-24)

**Nothing new on the kernel side.** Their last twenty commits are userspace work -
"Metal Mercury" (`bgmtl`, a Metal device dylib linked into
`MercuryPosterExtension`, installed by default since `aed199a7`), the charger and
wallpapers. The kernel GPU series is from 2026-10-23: `0103` (bring-up, stages
1-7), `0180-0186` (firmware dirs, keepalive API, IOKit user client, SQE max,
debug selector, 4 KiB page fault check, DCVS/recovery), `0187-0188`
(IOSurface import, governor), `0210-0212` (stats, scan-out, GPU cache policy).
That they are now writing a Metal backend is the useful part: **their GPU path
(stages 4-8) is proven end to end on beryllium.**

**Why our SMR/S2CR writes looked "dropped".** From their A618 ancestor
(`mxtpasontop/ios-sweet`, branch `gpu`, patches 0083-0085):

* `0083`: a VALID SMR with a non-zero mask (id 4, mask 1) **reads back 0**;
  their guess at the time: "the GMU's first RAM accesses as unmatched streams";
  the phone reset without a panic.
* `0084`: all five SMRs keep the ID/MASK values written **without** VALID, and
  `MICRO_MMU_CTRL` reads `0x2378`, `sCR0` `0x00200626` after resume - so the
  register block is writable.
* `0085`: **exact SMRs (mask 0) stick** (`SMR0 0x80000005`, `SMR1 0x80000004`,
  `S2CR 0x300`, sGFSR 0 before and after).

Their `smmu_write_sme(idx, s2cr, smr)` writes **S2CR first, then SMR**, and
checks both plus `sGFSR`. Our 3e test wrote S2CR0 while SMR0 was invalid, which is
why it read back unchanged: **an S2CR entry has no effect until the SMR beside it
is VALID**. The next attempt must write the pair.

**GMU reset hygiene.** Their `gpu_gmu_boot()` refuses to load unless
`CM3_SYSRESET == 1` ("GMU core not held in reset; not booted") and every stage
except the "keep up" one ends with `gpu_gmu_reset()` - `SYSRESET = 1`, 10 ms. Our
console54 left the GMU running, console55 then found `SYSRESET` 0, loaded the
firmware into a running core (fw_init 0), and in console56 the write of
`SYSRESET = 1` did not take either. **A cold boot is needed to get a clean GMU**,
and our probe should put it back into reset when it is done.

**Their stage 4 recipe (for the HFI step), verbatim facts**

* Memory: 64 KiB from `kmem_alloc_contig(kernel_map, &kva, size, PAGE_MASK, 0, 0,
  KMA_DATA|KMA_ZERO|KMA_PERMANENT, VM_KERN_MEMORY_IOKIT)`, checked physically
  contiguous with `pmap_find_phys`, then every page switched to
  `VM_WIMG_WCOMB` with `pmap_set_cache_attributes` (and `dc civac` before and
  after). Their note: **`ml_io_map` on managed RAM panics**
  (`pmap_panic_dev_wimg_on_managed`), "device memory types on managed RAM are
  refused by the pmap".
* Layout: `L1 0x0000`, `L2 0x1000`, `L3A 0x2000` (0x60000000-0x601fffff),
  `L3B 0x3000` (0x60200000-0x603fffff), `dummy 0x4000`, `HFI 0x5000`
  (0x5000 bytes), `dump 0xa000` (0x4000), `log 0xe000`. GPU addresses:
  dummy 0x60000000, HFI 0x60100000, dump 0x60200000, log 0x60300000 (KGSL's
  uncached kernel slots, one 1 MiB each).
* Tables: 4 KiB granule, 512-entry tables of 8-byte descriptors, levels indexed
  by VA[31:30], VA[29:21], VA[20:12]; `PTE_TABLE = 3`, page descriptor
  `0xE43 | pa` (AF, SH_OS, AP unpriv, nG, MAIR attr 0 = non-cacheable, and
  `1<<7` for the read-only SQE page); `TCR = (2<<12)|(1<<23)|32`,
  `TCR2 = 1|(7<<15)|(1<<4)`, `MAIR0 = 0x0004ff44`, `ACTLR = 0x70000000`,
  `SCTLR = 0x00c01067`, `CBAR = (1<<16)|(3<<8)|(0xf<<12)` stage 1 with stage 2
  bypassed, `CBA2R = 1` (64-bit TTBR0).
* Stream table: `SMR0 = VALID | 5` (gmu_kernel), `SMR1 = VALID | 4` (gmu_user),
  `S2CR = (3<<8) | cb` (translation, context `cb`); CP later gets `SMR2 =
  VALID | 0` and context 1. After the pairs: `TLBIALLNSNH`, `sTLBGSYNC`,
  poll `sTLBGSTATUS`. It refuses to boot the GMU if the SMRs do not read back.
* HFI table: header 6 dwords `{0, 54, 6, 12, 4, 4}` (size = 6 + 4*12 dwords,
  qhdr0_offset 6, queue header 12 dwords, four queues), then four queue headers
  with `start_addr = HFI_VA + 0xe0 + 0x1000*i`, `size = 1024` dwords, rx/tx
  watermark 1, rx_request 1; queues CMD (idx 0, pri 10, status 1), MSG
  (idx 4), DBG (idx 5), DSP (idx 1, disabled). Legacy v1 ids.
* Handshake: `HFI_QTBL_ADDR = 0x60100000`, `HFI_QTBL_INFO = 1` **before**
  releasing `SYSRESET`; after the boot `HFI_CTRL_INIT = 1`, poll
  `HFI_CTRL_STATUS` for 1 (100 ms), read `HFI_VERSION_INFO` and reject
  `(ver >> 28) >= 2` (that would be HFI v2); then `H2F_MSG_INIT` (5 dwords:
  header, 0, dump VA 0x60200000, dump size 0x4000, `GMU_COLD_BOOT` = 1),
  `H2F_MSG_FW_VER` (1, wants 1.10 = `0x100a0000`), `H2F_MSG_PERF_TBL` (4),
  `H2F_MSG_BW_VOTE_TBL` (3), `H2F_MSG_TEST` (5). Send = dwords at the queue's
  write index, bump `QH_WRITE_INDEX`, then `HOST2GMU_INTR_SET = 1`; receive =
  poll `GMU2HOST_INTR_INFO & 1`, clear it, read the MSG queue; ACK is
  `MSG_TYPE == 2`, `ack[2]` must be 0.

### *** GMU runs AND the SMMU is programmable (console59, adreno=9, 2026-10-24) ***

```
stage 2a: cx_gdscr 0xf8222000 -> ON
stage 3a: gmu sysreset = 0x1, firmware 0 of 3 words differ
stage 3d: fw_init 0xbabeface (THE GMU FIRMWARE RUNS)
stage 3e: smmu micro-mmu ctrl 0x2378 -> halt (0x237c, idle=1) -> resume
          smmu smr0 0x80000005 after writing 0x80000005: EXACT SMR STICKS
          (the stream table is writable), sgfsr 0
          gmu sysreset at the end 0x1
```

SpringBoard runs afterwards. `adreno=9` is the level: 2a power, 2b/2c clocks,
3a firmware, 3d GMU boot, 3e SMMU impl-defs + stream-table test, and the GMU put
back into reset at the end.

**Two bugs of ours were hiding all of this** (both found from console58's photo):

1. 0115's "leave the block alone" gate was `if (level >= 8)`, so every
   `adreno=9` boot from console55 to console58 skipped stages 2a-2c and ran with
   the **GPU block unpowered**. That is why SYSRESET and SPTPRAC read 0, why S2CR
   writes looked "dropped", why the micro-MMU read a stale 0x2378 and why 0128's
   GDSC fallback fired. None of those runs said anything about the SMMU. Fixed in
   0129 (`level == 8`).
2. The stream-table test wrote S2CR alone. An S2CR entry is only honoured once the
   SMR beside it is VALID (their 0084/0085: exact SMRs stick, masked ones read
   back 0). 0127 writes the pair.

So: **exact SMRs stick, the SMMU takes programming, and the GMU boots
repeatably** - the two blockers of the last few hours were ours, not the
hardware's.

### Next: stage 4 (the HFI handshake)

Everything needed is in the recipe above (see "Their stage 4 recipe"): a 64 KiB
physically contiguous block switched to `VM_WIMG_WCOMB` (`kmem_alloc_contig` +
`pmap_find_phys` + `pmap_set_cache_attributes`; **never `ml_io_map` on managed
RAM**), L1/L2/L3A/L3B 4 KiB tables, `TCR = (2<<12)|(1<<23)|32`,
`MAIR0 = 0x0004ff44`, `SCTLR = 0x00c01067`, `CBAR = (1<<16)|(3<<8)|(0xf<<12)`,
`CBA2R = 1`, SMR0 = VALID|5 (gmu_kernel), SMR1 = VALID|4 (gmu_user), S2CR =
`(3<<8)|cb`, `TLBIALLNSNH` + `sTLBGSYNC`, then the 4-queue HFI table at
`0x60100000`, `HFI_CTRL_INIT = 1`, poll `HFI_CTRL_STATUS == 1`, reject
`HFI_VERSION_INFO >> 28 >= 2`, then `H2F_MSG_INIT` (dump VA 0x60200000, size
0x4000, GMU_COLD_BOOT), `FW_VER` (wants 1.10), `PERF_TBL`, `BW_VOTE_TBL`, `TEST`.

### *** GPU STAGE 4 WORKS: the GMU talks HFI through our SMMU (console61, 2026-10-24) ***

```
SWEET GPU: gmu memory at 0x1024d8000 -> 0xfffffe3ccbd68000
SWEET GPU: tables at 0x1024d8000: l1[1]=0x1024d9003 l2[256]=0x1024da003 l2[257]=0x1024db003
SWEET GPU: hfi table at 0x60100000: size 54 words, 4 queues at +0x601000e0/+0x601010e0
SWEET GPU: smmu micro-mmu ctrl 0x2378, halting / idle=1 ctrl 0x237c / resumed: ctrl 0x2378 scr0 0x200626
SWEET GPU: cb0 sctlr 0xc01067 tcr 0x802020 tcr2 0x38011 ttbr0 0x10001024d8000 mair0 0x4ff44
SWEET GPU: smr0 sid 5: wrote 0x300/0x80000005 read 0x300/0x80000005 sGFSR 0
SWEET GPU: smr1 sid 4: wrote 0x300/0x80000004 read 0x300/0x80000004 sGFSR 0
SWEET GPU: smmu routes sid 5 and 4 through context 0 (sTLBGSTATUS 0)
SWEET GPU: write gmu hfi ctrl init +0x14618 = 0x1
SWEET GPU: hfi ctrl status 0x1 (THE HFI QUEUES ARE UP), version info 0
SWEET GPU: write gmu host2gmu intr +0x14650 = 0x1
SWEET GPU: gmu2host intr info 0x1 (the GMU answered)
SWEET GPU: hfi reply[0] 0x2047e  (id 126, dw 4, type 2 = ACK), reply[2] 0 (error 0), reply[3] 0xe550e55
```

`0x0002047e` is the same INIT ACK Bergamota's A618 log shows. The GMU booted,
read our HFI table **through the page tables we built** (stream IDs 5 and 4 ->
context 0), and ACKed `H2F_MSG_INIT`. Then it was put back into reset and iOS booted
normally. `adreno=9` is the level.

**Two bugs of ours stood between console59 and this** (both visible in the logs):

* `uint32_t gmem_pa = (uint32_t)gm_pa64` truncated the blob's address to 32 bits,
  so every PTE and TTBR0 pointed at 0x24d8000 instead of 0x1024d8000 and the GMU's
  first access reset the phone (0131: keep it 64-bit, the SMMU takes 40-bit
  output addresses and a 64-bit TTBR0).
* nothing else - CB0, the SMR/S2CR pairs and the HFI table all worked first time.

### What is left (Bergamota's stages 5-8)

1. The rest of the HFI messages: `H2F_MSG_FW_VER` (wants 1.10 = `0x100a0000`),
   `PERF_TBL`, `BW_VOTE_TBL`, `TEST` - our queue code already sends one message;
   each needs its ACK checked the same way.
2. GX rail on: `a6xx_gmu_gfx_rail_on` (boot OOB at 257 MHz), SPTPRAC on, then the
   GPU core registers become readable (RBBM_STATUS, CP_ALWAYS_ON). Requires the
   `gx_gdsc` sequence and its `core_root_clk`.
3. The CP: `CP_ME_INIT`, ring and SQE in a second SMMU context (SID 0), the zap
   shader through SCM PAS id 13, then a NOP + CACHE_FLUSH_TS test.
4. Only then the 3D pipeline (shaders, UBWC, RBBM_SECVID) and a Metal/OpenGL
   backend - Bergamota is at that point now (bgmtl).

### HFI works in both directions (console63, 2026-10-24)

```
hfi ctrl status 0x1 (THE HFI QUEUES ARE UP), version info 0
hfi fw version: reply 0x12047e (id 126, 4 words, type 2), request 0x1, error 0, data 0x10070000
hfi test:       reply 0x22047e (id 126, 4 words, type 2), request 0x5, error 0, data 0xe550e55
gmu sysreset at the end 0x1
```

**The GMU firmware is 1.7** and speaks HFI v1 (`0x10070000`; the driver asked for
1.10). Both the version exchange and the TEST message came back ACKed with the
right echoed request id and `error 0`, so the queue mechanics (write index, read
index, HOST2GMU/GMU2HOST interrupts) work in both directions.

Gotcha for the next messages: the ACK's own id is 126; the message it answers is
in `ack[1] & 0xff`, and the ACK is four dwords, so the read index has to start at
4 after the hand-read INIT acknowledgement (0133). The verdict must compare the
echoed request id, not the reply id (0134).

Next: `PERF_TBL` and `BW_VOTE_TBL` need the DCVS table from the cmd-db and
Linux's fixed a630 bandwidth table; then the GX rail (`gfx_rail_on` + SPTPRAC)
and the first GPU-core register reads; then the CP (ring, SQE in a second SMMU
context for SID 0, the zap through SCM PAS 13, a NOP + CACHE_FLUSH_TS test).

### console64: the whole GPU probe runs on every boot (2026-10-24)

```
hfi ctrl status 0x1 (THE HFI QUEUES ARE UP), version info 0
hfi fw version: reply 0x12047e, request 0x1, error 0, data 0x10070000
hfi firmware version exchange ok
hfi test: reply 0x22047e, request 0x5, error 0
hfi test ok
gmu sysreset at the end 0x1
```

(The line prints "firmware 16.7" because it shifts `0x10070000` byte-wise; the
value is the HFI version 1.7. Cosmetic, one line to fix when convenient.)

iOS boots normally afterwards with the full probe: CX GDSC, clocks, firmware,
GMU boot, SMMU context and streams, HFI INIT/FW_VER/TEST, GMU back in reset. This
is the state to build on - `adreno=9` is the switch.
