# ios-fajita — OnePlus 6T (SDM845) port notes

Status: **bring-up scaffold**. The tree is based on
[`dipa-studio/ios-sweet`](https://github.com/dipa-studio/ios-sweet) (SM7150),
because SDM845 is architecturally much closer to sweet than to
[`MakrSas/ios-topaz`](https://github.com/MakrSas/ios-topaz) (SM6225 / ARMv8.0).

Target: OnePlus 6T (`fajita`), Qualcomm SDM845, 4×Cortex-A55 + 4×Cortex-A75,
ARMv8.2-A, 6/8/10 GB RAM, 1080×2340 AMOLED, UFS 2.1, A/B slots.

> Experimental, security-off bring-up. The iOS root goes into `userdata`
> (Android data is erased). Keep `boot_a`/`boot_b` backups and never touch
> `persist`, `modemst*`, `fsg`, `xbl`, `abl`, `tz`.

## Why fajita is easier than topaz

| | topaz (SM6225) | fajita (SDM845) |
|---|---|---|
| CPU | 4×A73 + 4×A53, ARMv8.0 | 4×A55 + 4×A75, **ARMv8.2** |
| 16K pages | Gold only | **both clusters** |
| LSE / LDAC | emulated (patch 0081) | **native** |
| LDAPR / RCpc | emulated | **native** (A75/A55) |
| PAN | off | **available** |
| XNU cores | 4 Gold, hand-off hack | **8 possible**; start with 4×A55 |
| GIC / UFS | different | **same addresses as sweet** |

There is no Gold hand-off and no ARMv8.0 instruction emulation to port. The
`SWEET` XNU machine config (16K pages, GICv3 Group-1 IRQ, ARMv8.2, no PAC) is
reused unchanged.

## Verified hardware constants

Sources: mainline `arch/arm64/boot/dts/qcom/sdm845-oneplus-common.dtsi` +
`sdm845-oneplus-fajita.dts`, downstream LineageOS
`android_kernel_oneplus_sdm845` (`sdm845.dtsi`, `fajita.dtsi`), and
`sdm845-oneplus-fajita` mainline UFS/GIC nodes. Re-check against the phone's
live FDT before trusting anything board-specific.

| Item | Value | Notes |
|---|---|---|
| SoC | SDM845, 4×A55 + 4×A75 | `qcom,kryo385` |
| Little MPIDR | `0x000, 0x100, 0x200, 0x300` | A55, logical cores 0–3 |
| Big MPIDR | `0x400, 0x500, 0x600, 0x700` | A75, logical cores 4–7 |
| Timer PPI | virtual timer INTID **19** | same as sweet |
| GIC | GICD `0x17a00000`, GICR `0x17a60000`, stride `0x20000` | **same as sweet** |
| Splash framebuffer | `0x9d400000`, 36 MiB (`0x02400000`) | `cont_splash_region` in downstream DT |
| Panel | 1080×2340, ARGB8888, stride 4320 | 32 MiB block base `0x9c000000` |
| UFS host | `0x1d84000` (UFSHCI), PHY `0x1d87000` | **same host address as sweet**; UFS 2.1, 2 lanes |
| PS_HOLD | `0x0c264000` | same as sweet |
| IMEM restart reason | **`0x146bf65c`** | SDM845 IMEM base `0x146bf000` + `0x65c` |
| RAM high bank | `0x1_00000000` | use `0xfcc00000` conservatively until live FDT is read |
| Touch | Synaptics RMI4, I²C12 `0xa90000`, addr `0x20` | IRQ GPIO125, reset GPIO99 |
| Touch rails | VDD `PM8998 LDO28` 2.856–3.008 V; VIO 1.8 V via GPIO88 | downstream calls the IC `s3320`; mainline `s3706b` — read RMI4 F01 to identify |
| Volume keys | PM8998 GPIO5 (down), GPIO6 (up) | power via PM8998 PON |
| Panel control | reset GPIO6, VCI GPIO26, POC GPIO25, TE GPIO10 | only needed if ABL splash is not kept alive |
| Boot slots | A/B (`boot_a`, `boot_b`) | `fastboot boot` disabled on OOS 10/11 |

### Corrections to the earlier chat estimate

- The SDM845 MPIDRs are **not** `0x100–0x103` for the big cluster. Both
  clusters use `core << 8`: A55 `0x000–0x300`, A75 `0x400–0x700`. `mkadt.py`
  already used `core << 8`; only the comments/cluster split needed fixing.
- The IMEM restart reason is **`0x146bf65c`**, not sweet's `0x146aa65c`.
- Touch VIO is a **GPIO88-controlled 1.8 V fixed rail**, not a second PMIC LDO;
  VDD is PM8998 LDO28.
- The touch IC is RMI4; downstream says `s3320`, mainline says `s3706b`.
  Treat the protocol as RMI4 F01/F12 and read the chip ID at runtime.
- GIC, UFS host and PS_HOLD are the **same as sweet**, so `shim/shim.c`,
  `shim/ufs.c` and the GIC setup need no address changes.

## What was changed in this tree

- `shim/console.h`, `shim/mmu.h`: framebuffer `0x9d400000`, 1080×2340.
- `shim/shim.c`: IMEM restart reason `0x146bf65c`.
- `shim/build.sh`: `DTB=` and `MKBOOTIMG=` overrides (OnePlus stock DTB,
  AOSP `mkbootimg.py`).
- `tools/mkadt.py`: fajita FB, CPU count/frequencies, `qcom,kryo385`;
  keeps the `sweet-fbcon`/`sweet-ufs` node names and `xiaomi,sweet`
  compatible string because the XNU platform expert matches them.
- `xnu/patches/0010`, `0012`: early framebuffer physical address 0x9d400000,
  height 2340; the bootstrap 32 MiB block stays at 0x9c000000 and the final
  kernel alias adds the 20 MiB FB offset.
- `xnu/patches/0061`: native panel height 2340 (iPhone X 1125×2436
  presentation remains).

Not yet ported: **Synaptics RMI4 touch** (the sweet Goodix driver is left
disabled with `sweettouch=0`), PM8998 keys (`sweetkeys=0`), PM8998 RTC/battery,
and real UFS 2.1 timing/clock differences.

## No full VM: WSL2 + HFS+

The XNU kernel is built on GitHub's `macos-14` runner (`xnu.yml`), not locally.
The shim and the iOS root image need Linux. Stock WSL2 has FUSE and loop
devices but **not HFS+**:

```text
CONFIG_FUSE_FS=y
CONFIG_BLK_DEV_LOOP=y
# CONFIG_HFSPLUS_FS is not set
```

`hfsfuse` is read-only, so it cannot build the root image. Two clean options:

1. **WSL2 + a custom Microsoft WSL kernel with `CONFIG_HFSPLUS_FS=y`**
   (recommended; no full VM). `tools/setup-wsl.sh --wsl-kernel` builds it.
2. A VirtualBox/VMware Ubuntu VM (Windows 11 Home has no Hyper-V).

`tools/setup-wsl.sh` installs `gcc-aarch64-linux-gnu`, `hfsprogs`,
`apfs-fuse`, `rsync`, `img2simg`, `mkbootimg.py`, etc. and can build the WSL
kernel. After `wsl --shutdown`, `grep hfs /proc/filesystems` must show
`hfsplus`.

### First hardware test (no XNU, no root)

Before building the kernel/root, build the shim **without a payload**. It
takes the no-payload path, prints the live FDT memory nodes (base/size) and
runs the read-only UFS probe on the splash screen:

```sh
DTB=dtb/boot_unpacked/dtb shim/build.sh
# flash shim/out/shim-boot.img to boot_b and boot it
```

This answers the two biggest unknowns in one boot: the real RAM map and
whether ABL left the UFS host running. If the screen goes black immediately,
the continuous-splash assumption is wrong.

### Build order

```sh
# 1. XNU (GitHub macOS CI; public repo = free minutes)
gh workflow run xnu.yml -R YOU/ios-fajita --ref main
gh run download RUN_ID -R YOU/ios-fajita -n xnu-kernel -D xnu/out

# 2. iOS root (Linux/WSL; iPhone X 16.7.16 20H392 IPSW)
sudo bash tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 16G
sudo mount -t hfsplus -o loop,force ios16-root.img /mnt/iosroot
sudo python3 tools/sweet-root-tweaks.py /mnt/iosroot
sudo umount /mnt/iosroot
img2simg ios16-root.img ios16-root.simg

# 3. boot image (needs the stock OnePlus/LineageOS boot.img DTB)
python3 tools/unpack_bootv2.py backup/boot_a.img dtb/boot_unpacked
DTB=dtb/boot_unpacked/dtb tools/build-fajita.sh

# 4. flash (A/B; keep the other slot as Android fallback)
fastboot flash boot_b shim/out/shim-boot.img
fastboot set_active b
fastboot -S 512M flash userdata ios16-root.simg
```

Use `fastboot` on Windows, not through WSL USB passthrough. On OOS 10/11
ABL, `fastboot boot` returns `unknown command`; flashing `boot_b` is the
supported path. If the slot is not marked successful, ABL may fall back after
a few boots: `fastboot set_active b` again.

## Open questions (must be answered on the phone)

1. **Does ABL keep the panel scanning out after hand-off?** The mainline
   `simple-framebuffer` at `0x9d400000` strongly suggests yes, but confirm by
   writing a test pattern into the splash region from the shim. If it goes
   black, a real DSI/MDP driver is required — a much larger project.
2. **Live FDT memory nodes** — confirm the high bank size and that no dynamic
   carve-out sits above `0x1_00000000`; widen `HIGH_MEM_SIZE` only after that.
3. **UFS 2.1** — sweet's driver targets UFS 3.0; check link speed/gear,
   clocks/GDSC and whether ABL leaves the host in the expected state.
4. **Touch IC variant** — read RMI4 F01 manufacturing ID; implement F01/F12
   (attention/IRQ, reset, 2D sensing) rather than the Goodix protocol.
5. **ABL boot header** — verify `header_version`, `base`, offsets and page size
   against the stock `boot_a.img`; the current values mirror common Qualcomm
   `boot.img v2` but are not yet confirmed on fajita.
6. **Panel init** — only needed if the continuous splash is not kept; the
   downstream panel is `samsung,s6e3fc2x01` with reset/VCI/POC GPIOs above.

## Next milestones

1. Shim builds and paints a test pattern on the splash framebuffer.
2. XNU kernel artifact + fajita ADT + payload; boot to the early SWEET console.
3. UFS root on `userdata`; launchd; Apple logo; lock screen.
4. PM8998 keys; then RMI4 touch.
5. 8 cores / A75 cluster; RTC, battery, performance.
