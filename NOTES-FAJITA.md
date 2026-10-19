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
- `shim/out/shim-boot.img` built (606208 bytes, header v2, 180224-byte
  `Image`, dtb 416041 bytes at `0x1f00000`) with
  `PATH="$HOME/.local/bin:$PATH" bash shim/build.sh`. Header fields match the
  stock image (`kernel 0x8000`, `ramdisk 0x1000000`, `tags 0x100`, 4096).
- Platform-tools are installed at `C:\Users\misia\platform-tools`
  (`adb`/`fastboot` 37.0.1); no phone is connected yet.
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

## Next concrete actions

1. CI: `xnu` run 39283126880 (pushed from `0b8929a`); on success download
   `xnu-kernel` into `xnu/out` and run `tools/build-fajita.sh`.
2. With the phone in fastboot, record `fastboot getvar current-slot` and the
   SoC revision, then (after user confirmation) `fastboot flash boot_b
   shim/out/shim-boot.img` + `fastboot --set-active=b`. Keep `boot_a` as the
   LineageOS fallback.
3. Confirm the diagnostic console prints the live FDT memory nodes and the
   read-only UFS probe.
4. Then `tools/build-fajita.sh` (ADT/payload/shim, `cpus=4`) and the XNU boot.
5. Root image + XNU; boot to the early console; then UFS/launchd/lock screen.
6. PM8998 keys, then the Synaptics RMI4 touch driver.

## Do not assume

- The panel may stop scanning out after ABL hand-off; confirm with a test
  pattern. If it does, a real DSI/MDP driver is required.
- The live FDT memory size/carve-outs must be read from the phone before
  widening `RAM_HIGH_SIZE`.
- UFS 2.1 timing and the Synaptics chip variant (s3320 vs s3706b) need
  on-device confirmation.
