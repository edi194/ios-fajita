# ios-fajita — active handoff (2026-10-18)

This tree is based on `dipa-studio/ios-sweet` (main) and is being retargeted
to the **OnePlus 6T (`fajita`, SDM845)**. `PORTING.md` has the verified
hardware table and the plan; this file is the short handoff.

## State

- Source copied into this workspace (no `.git` yet).
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
- `~/WSL2-Linux-Kernel` is cloned; the `CONFIG_HFSPLUS_FS=y` build is running.
- No shim/ADT build or phone test yet (only the host-side `mkadt.py` test:
  9920-byte ADT with `dram 0x1_00000000/0xfcc00000`, FB `0x9d400000`,
  1080x2340, CPU MPIDR `0x000..0x700`).

## Environment

- Windows 11 Home, Ryzen 5 4500U (6c/6t), 7.4 GB RAM, 355 GB free on C:.
- WSL2 Ubuntu is installed; WSL currently has 3.5 GiB RAM, so the kernel build
  uses `-j2`. Set `memory=5GB` in `.wslconfig` and `wsl --shutdown` before
  raising `JOBS`.
- Kernel builds on GitHub `macos-14` via `xnu.yml`; no local macOS needed.
- The Linux side (shim + iOS root) needs HFS+; stock WSL2 has no
  `CONFIG_HFSPLUS_FS`. The custom kernel is building.
- `apfs-fuse` needed two GCC15/CMake4 fixes, already in
  `tools/setup-wsl.sh`: `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` and an
  `#include <cstdint>` in `ApfsLib/PList.h`.
- The old `aosp-mirror` mkbootimg URL is 404; the correct mirror is
  `jbeich/platform_system_tools_mkbootimg`.

## Next concrete actions

1. Finish the WSL kernel build, copy `arch/x86/boot/bzImage` to
   `C:\Users\misia\wsl-hfsplus-bzImage`, add the `[wsl2]` entry to
   `C:\Users\misia\.wslconfig`, `wsl --shutdown`, then verify
   `grep hfs /proc/filesystems` shows `hfsplus`.
2. Put this tree in WSL ext4 (not `/mnt/c`), `git init`/commit, install
   `gh` if needed, fork the repo on GitHub (public for free macOS minutes),
   run `xnu.yml`.
3. Unpack the OnePlus/LineageOS `boot_a.img` with
   `tools/unpack_bootv2.py`; check the boot header fields against
   `shim/build.sh`.
4. Build the no-payload diagnostic shim first (`shim/build.sh`) and flash it
   to `boot_b`: it prints live FDT memory nodes + the read-only UFS probe.
5. Then `tools/build-fajita.sh` (ADT/payload/shim, `cpus=4`) and the XNU boot.
6. Root image + XNU; boot to the early console; then UFS/launchd/lock screen.
7. PM8998 keys, then the Synaptics RMI4 touch driver.

## Do not assume

- The panel may stop scanning out after ABL hand-off; confirm with a test
  pattern. If it does, a real DSI/MDP driver is required.
- The live FDT memory size/carve-outs must be read from the phone before
  widening `RAM_HIGH_SIZE`.
- UFS 2.1 timing and the Synaptics chip variant (s3320 vs s3706b) need
  on-device confirmation.
