# iOS on the OnePlus 6T (`fajita`)

**Apple's iOS 16.7.16 running on a OnePlus 6T.**

This project ports Apple's open-source XNU kernel (the iOS 16 generation) to the OnePlus 6T
(`fajita`, Qualcomm SDM845 / Snapdragon 845, Adreno 630). On top of it runs the **unmodified
iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd,
SpringBoard and the stock apps.

As of **2026-10-25** the phone boots to the **iOS home screen**: unlock works, the
touchscreen and the hardware buttons work, and the GUI is drawn by CoreAnimation's software
renderer. The **GPU bring-up is complete on the kernel side** (power, clocks, firmware,
secure world, command processor, buffers, fences and the msm-compatible IOKit user client
that Mesa needs); the userspace graphics stack is the work in progress.

> Experimental bring-up, not a usable phone OS. Wi-Fi, Bluetooth, the modem, the camera and
> hardware acceleration are not there yet, Apple's security model is mostly switched off,
> and the iOS root lives in the `userdata` partition — so **flashing it erases whatever is
> in `userdata`**.

## What works

| Area | State |
| --- | --- |
| Boot | Stock OnePlus ABL (`fastboot`) → our boot image on `boot_a` → shim → XNU. Header v1 + gzip `Image.gz` + appended DTB; a v2 header or a raw `Image` is rejected by this bootloader |
| CPU | 8 of 8 cores via PSCI, GICv3, timers |
| Storage | Own UFS host driver; the iOS root is a journaled HFS+ volume inside `userdata` |
| iOS userland | Real iPhone X 16.7.16 root filesystem and shared cache; launchd and the system daemons run (hundreds of processes) |
| Display | Kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`) services, presented as an iPhone X panel; CoreAnimation renders in software |
| GUI | backboardd, SpringBoard, lock screen, home screen, Control Center, notification centre, Settings |
| Touch | RMI4 over I²C (`0x20`, SE `0xa90000`) with rail enable; delivered as HID digitizer events |
| Buttons | Power and volume up/down (PM8998 through SPMI, usages `0x30`/`0xe9`/`0xea`) |
| Device identity | iPhone X (`iPhone10,3` / D22) so UIKit picks the gesture UI |
| Logging | Persistent ring buffer in `userdata` plus a panic flush; pulled over OrangeFox (`tools/sweet-log-pull.sh`) |
| GPU (kernel) | Full Adreno 630 bring-up: power, clocks, ARC/PDC, GMU firmware + HFI, SMMU (two contexts), the signed zap through TrustZone, command processor, buffers, fences, keep-alive, msm-compatible IOKit user client |

## What does not work (yet)

- **Hardware acceleration**: the kernel side is done; Mesa/freedreno and Chlorophyll (Metal)
  are not built for this root yet. Rendering is CPU-only, so the UI is slow.
- **Wi-Fi / Bluetooth / modem / camera**: no drivers.
- **Wallpaper (PosterBoard)**: crashes without a working graphics stack; expected to resolve
  with the Metal path.
- **Time**: the clock starts at 1969, so anything checking certificates (TLS, activation)
  sees an invalid date.
- **Apple security**: AMFI, sandbox and code signing are permissive stand-ins. Do not treat
  this as a secure iOS.

## How it boots

1. The bootloader loads `boot_a` with our shim, which sets up a minimal EL2/EL1
   environment and jumps into XNU.
2. The shim passes XNU a payload: the kernel, the ADT (device tree), the boot arguments and
   firmware blobs announced as `sweetfwN=<pa>:<size>` (`a630_gmu.bin`, the GMU memory block,
   the buffer arena, the page-table pool).
3. XNU mounts the HFS+ root from `userdata` and starts `/sbin/launchd`.

## How to do it yourself

### 0. Back up the phone

`userdata` holds the iOS root. Everything else (bootloaders, recovery, modem, `persist`) is
left alone by this project, but keep a backup anyway and read this file to the end first.

### 1. Build the kernel

The kernel is built by GitHub Actions (`.github/workflows/xnu.yml`) from the patch series in
`xnu/patches/`; the artifact is `kernel.development.sweet`. Locally the series applies to the
same base tree:

```bash
python3 tools/check-hunk-counts.py          # sanity: every patch still applies in order
for p in xnu/patches/0*.patch; do patch -p1 -s < "$p"; done
```

### 2. Build the iOS root image

`tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img` builds a 16 GiB HFS+ image from
the iPhone X IPSW (the OS, SystemOS and AppOS disk images), including the shared cache and
the stock apps. `tools/mk-root-with-gpu.sh --in-place IMG` then adds this project's
userspace pieces to an existing image:

- `/usr/local/bin/sweetgputest` and `/usr/local/bin/sweet-iokit-test`
- LaunchDaemons `org.sweet.gputest` and `org.sweet.iokittest` (output on `/dev/console`)
- `/System/Library/Extensions/`, where the Metal driver bundle will live

### 3. Build the boot image

```bash
export CMDLINE="<the cmdline from NOTES-FAJITA.md> adreno=9 zap=1 gpuhold=1"
export ADT_GAMUT=P3
bash tools/build-fajita.sh          # -> shim/out/shim-boot.img
```

`tools/build-fajita.sh` reads the kernel from `xnu/out/kernel.development.sweet`, builds the
ADT (`tools/mkadt.py`), packs the payload (`tools/mkpayload.py`) and wraps it (`shim/build.sh`).

### 4. Flash

```bash
# the iOS root (destructive: this is the userdata partition)
fastboot flash userdata ios16-root-gpu.img

# the kernel/boot image
fastboot flash boot_a shim-boot.img
fastboot reboot
```

On Windows the fastboot from platform-tools is the one that works with this bootloader; a
`fastboot` inside WSL is usually that same Windows binary, so pass it Windows-style paths.

### 5. Read the log

The panel is the first console, and the ring in `userdata` keeps the whole boot:

```bash
tools/sweet-log-pull.sh            # boots OrangeFox, pulls the ring to fajita-logs/
tools/sweet-log.py fajita-logs/<newest>.txt --grep GPU
```

After a hard hang, a photo of the panel is authoritative — the ring can be stale if the
panic happened during a flush.

## The GPU

The bring-up follows the ladder of HackiOS (`oosexgang`) and Bergamota (`ry-diffusion`), which
runs the same SDM845/Adreno 630. Boot arguments select how far it goes: `adreno=1..9`,
`zap=1` (the secure-world step), `gpuhold=1` (keep the GPU up after the self-tests).

| Stage | What it proves |
| --- | --- |
| 1–2 | block probes, CX/GX power domains, GPU clocks |
| 3 | GMU firmware (`0xbabeface` handshake), HFI v1, SMMU contexts |
| 5 | GX rail through the GMU OOB path, SPTPRAC, the core answering (`RBBM_STATUS`) and then giving the rail back |
| 6 | the signed **zap** through SCM/PAS id 13 (TrustZone authenticates it) |
| 7 | command processor: `hw_init`, `CP_ME_INIT`, out of secure mode, and a NOP + `CP_MEM_WRITE` + `CACHE_FLUSH_TS` submission whose result is read back |
| 8 | keep-alive, a 1 GiB client address space with page tables on demand, submit as "command buffer + fence", buffers, and the **IOKit user client** a userspace driver opens |

Everything above is verified in the boot log on the device, with the GPU held up and iOS
running normally. The per-patch history, every register number and the traps are in
[`NOTES-FAJITA.md`](NOTES-FAJITA.md).

**Next**: `tools/sweet-iokit-test.c` exercises the ABI from userspace today; after that comes
`gpu/freedreno-sweet`-style libdrm stand-in, Mesa/freedreno, then Chlorophyll and the
`IOAcceleratorES`/`MetalPluginName` step that lets CoreAnimation use it.

### A userland toolchain without macOS

There is no Xcode here and none is needed:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git ~/ios-sdk
cd ~/ios-sdk && git sparse-checkout set iPhoneOS16.5.sdk

clang --target=arm64-apple-ios16.0 -isysroot ~/ios-sdk/iPhoneOS16.5.sdk -fuse-ld=lld -O2 \
      -L~/ios-sdk/iPhoneOS16.5.sdk/usr/lib -Wl,-adhoc_codesign -o tool tool.c \
      -framework IOKit -framework CoreFoundation -lSystem
```

That produces a normal dynamic arm64 Mach-O with `LC_LOAD_DYLIB` entries, which is what the
graphics stack needs.

## Repository layout

```
xnu/patches/            the kernel patch series (apply in order)
shim/                   the small loader the bootloader jumps to
tools/                  build, image, log and userspace helpers
dtb/                    the device trees dumped from the phone
shim/out/, xnu/out/     build products (not committed)
NOTES-FAJITA.md         the working handoff: state, registers, traps, next steps
PORTING.md              hardware notes and the bring-up plan
```

## Credits

- [ios-sweet](https://github.com/dipa-studio/ios-sweet) — the iOS 16 / XNU base this fork
  started from; `docs/IOS16_README.md` keeps that history.
- HackiOS (`oosexgang`) — the Adreno bring-up ladder the GPU work follows.
- [Bergamota](https://github.com/ry-diffusion/Bergamota) and
  [Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) — the SDM845/Adreno 630 kernel
  bring-up, the msm-compatible IOKit user client, and the AIR→NIR→ir3 Metal driver.
- [theos/sdks](https://github.com/theos/sdks) — the iOS SDK used to build userland tools.
- Apple's open-source releases (XNU, IOHIDFamily, libpthread, hfs), BearSSL, and OrangeFox
  Recovery. iOS itself is Apple's and is not distributed here.
