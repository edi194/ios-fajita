# fajita on Bergamota — port log

This branch is a clean restart of the OnePlus 6T (`fajita`, SDM845) port on top of
[Bergamota](https://github.com/ry-diffusion/Bergamota) `develop` (imported as one root commit, so the history of
the earlier port is not carried over). The earlier work (iOS 16.7.16, XNU 8796, Metal/Chlorophyll) stays on
`main` in this repository.

## What is done

| step | state |
|---|---|
| Bergamota `develop` imported as the branch root | `70c0cde` |
| `enxerto` board for fajita (`BOARD=fajita`) | `a7b0042` — framebuffer `0x9d400000` (the stock DTB's `cont_splash_region`, 36 MiB), panel 1080×2340, SDM845 `restart_reason` |
| `tools/mkadt.py --board fajita` | `a7b0042` — same RAM window, GIC and CPU arrangement as beryllium, `oneplus,fajita` compatible, 1080×2340 |
| Heartwood kernel (xnu-11215) built from this branch | CI run `42495065818`, `xnu/out-heartwood/kernel.development.sweet`, 18 986 696 B |
| Enxerto booting on the phone | `fastboot boot enxerto/out/enxerto-boot.img` → Bergamota boot screen, `DWC3 GSNPSID 0x5533300a`, enumerates as `18d1:4ee0` |
| Heartwood booting on fajita | `fastboot boot heartwood-fajita.img` → **SWEET EARLY 1…20** on the panel (arm_vm_init, pmap_bootstrap, serial_init, fbcon mapping, `kprintf startup complete`) then the expected panic below |

## Exactly how the last boot was produced

```sh
gh workflow run xnu.yml --ref brg-port -f macos_version=15.3 -f kernel_config=DEVELOPMENT
gh run download <run> -n xnu-kernel -D xnu/out-heartwood

python3 tools/mkadt.py enxerto/out-fajita.adt --board fajita --highmem --display-scale 3 --points 360x780

CMDLINE="debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=md0 sweetfb_hz=30 sweetfb_vsync=1 \
sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetarm64e=1"
python3 tools/mkpayload.py xnu/out-heartwood/kernel.development.sweet enxerto/out-fajita.adt \
    enxerto/out/payload-fajita.bin --cmdline "$CMDLINE"

BOARD=fajita DTB=$PWD/dtb/fajita/dtb ./enxerto/build.sh $PWD/enxerto/out/payload-fajita.bin
fastboot boot enxerto/out/enxerto-boot.img        # temporary; nothing is flashed
```

`dtb/fajita/dtb` is the phone's own stock DTB (`fajita2`, msm-id 0x141/0x20001), extracted on `main` and kept out
of git.

## The panic that is expected

```
SWEET EARLY PANIC: IOfindBSDRoot: specified root memory device, md0, has not been configured @IOKitBSDInit.cpp:856
```

`rd=md0` was chosen on purpose: without a ramdisk it stops here instead of touching `userdata`, which still holds
the iOS 16.7.16 root used by `main`. Everything before that line is the validation we wanted — the panel, the
framebuffer console, early pmap and the ADT all work on fajita.

## Next

1. **The iOS 18 root** (this is what SpringBoard needs): `tools/renegade/renegade fetch` (downloads and decrypts
   the iOS 18.7.8 iPhone11,8 root dmgs, ~8 GB), then `renegade root`, then `renegade boot` for the full boot
   image. Linux needs `ipsw` and `apfs-fuse`; see `tools/renegade/README.md`.
2. **Fajita drivers** in Heartwood: touch is RMI4 on this phone (the port on `main` has a working RMI4 driver),
   Bergamota's beryllium uses Novatek NT36672A; the panel timings are the 6T's own; keys are PM8998/SMPI as on
   `main`.
3. **GPU**: Bergamota's path is EAGL → Mesa freedreno → Turnip (`gpu/eagl`, `docs/GPU_EAGL.md`), not Metal. The
   a630 work on `main` (GMU/SMMU/CP/zap, buffer memory, PTEs) is the reference for that driver.

## Milestone: iOS 18.7.8 boots to the lock screen on the OnePlus 6T

2026-11-08 ~19:10. The iOS 18.7.8 (22H352) root was built with Renegade (`renegade fetch` for iPhone11,8,
`renegade root`, then `renegade sparse`), flashed into `userdata` (16 sparse chunks, 824 s, through Bergamota
fastboot) and booted with the Heartwood kernel from this branch plus the fajita ADT:

```
fastboot boot ios18-fajita-full.img      # rd=ufsroot0, ufsrw=1, rootrw=1, sweetarm64e=1
```

Result: **lock screen with the clock**, and the power key wakes it. The screen going black after a while is
the display timeout, not a crash: the kernel has no touch driver for this phone yet, so nothing counts as
input.

What that proves on fajita: UFS + HFS+ mounting of the 20 GB iOS root, XNU 11215 userland (arm64e rewritten
by Renegade) running launchd, backboardd and SpringBoard on the panel, PM8998 keys.

### Next: touch (RMI4), then GPU

Our RMI4 driver for this phone lives in `main` (`bsd/dev/sweet_touch.c`, the `rmi_*` block plus
`fajita_clocks` and `touch_fajita_thread`). Bergamota's own `sweet_touch.c` has the same lineage but diverged:
it carries `touch_msg()` (one I2C transfer), `touch_report()` (HID), `touch_thread()`, and per-device starters
(`touch_focaltech`, `touch_goodix`, `touch_novatek`, `touch_beryllium_start`) selected by `st.kind`.

So the port is: add the RMI4 block to their file, map `touch_msg_run(addr, tx, nt, rx, nr, stretch)` onto their
`touch_msg(...)`, report through their `touch_report()`, and add a `TOUCH_RMI4` kind plus a fajita starter that
programs the panel clocks (RPMh LDOA28 + GCC) the way `fajita_clocks()` does.

After touch: the key map for this phone (power already works), auto-lock off for testing, then the GPU path
(`gpu/eagl`, Mesa freedreno, Turnip) — the point of the whole exercise.

## Milestone: iOS 18.7.8 with working touch on the OnePlus 6T

2026-11-09. The lock screen, then the home screen (SpringBoard loading widget extensions), with a finger
that moves the cursor:

```
SWEET TS: raw max x=1016 y=2321 irq=0     <- real coordinates from the RMI4 frame reader
SWEET FB: stats ... mode=copy hz=30 ... swaps=359 swaps_s=9.70 copy_frames=270
```

The display is still CPU-composited (`mode=copy`, `hw=0`): the GPU path is the next piece of work.

### What the touch port needed (the whole chain, for the next session)

1. **0252-fajita-rmi4-touch.patch** - the RMI4 driver itself, grafted onto Bergamota's `sweet_touch.c`
   behind `sweetts=1`: FJ_* constants (QUPv3 SE12 at 0xa90000, I2C 0x20, ATTN gpio125 and reset gpio99,
   the VIO enable on gpio88 in the east TLMM tile), `touch_gpio_at()` because the existing `touch_gpio()`
   only ever programs the north tile, the PDT/F01/F12 code and a thread that runs after
   `sweettouchdelay` seconds.
2. **0254-rpmh-ldoa28.patch** - `sweet_rpmh_vreg_enable()` only accepted `ldoc11` (the Poco's rail) and
   returned EINVAL for `ldoa28`, so the touch rail was never voted and the controller NAKed every
   transfer (`probe xfer addr=0x20 err=6`, `PDT read 0xe9 failed`).
3. **0255-rpmh-fajita-bases.patch** - with the rail vote actually happening the machine died before the
   log thread's first flush: `sweet_rpmh.c` programmed the *SM7150* RSC/TCS bases (0x18220000/0x18220d00)
   because only `sweet_board_beryllium()` selects the SDM845 ones. SDM845 - both phones - keeps them at
   0x179e0000/0x179e0d00, and a TCS write at the wrong base hangs the bus. `sweetts=1` now selects the
   SDM845 branch as well.

### Reading the log is what made this possible

Bergamota keeps the 4 MiB console ring at the end of `userdata` and ships `tools/sweet-log-pull.sh` +
`tools/sweet-log.py`. Pulling it from OrangeFox shows every `printf` of the kernel - including the touch
driver's - without filming the screen, which is what the panel console stopped being once SpringBoard
took the framebuffer.

## Next: the GPU

Bergamota's path is EAGL -> Mesa freedreno -> Turnip (`gpu/eagl/`, `docs/GPU_EAGL.md`), not Metal. The
framebuffer currently copies every frame on the CPU (`mode=copy`); the goal is their `bglrender` payload
drawing through the Adreno 630, which is what the a6xx work on `main` (GMU/SMMU/CP/zap, buffer memory,
PTEs) is the reference for.

## Milestone: the Adreno 630 comes up on the 6T (Bergamota's driver, stage 8 passed)

2026-11-09 ~20:30, after `0256` opened the probe gate for this board (`sweetts=1`), with the firmware in
`/usr/local/share/firmware` of the root:

```
GMU firmware 32768 bytes, 0 words differ on readback; CM3_FW_INIT_RESULT 0xbabeface; version 0x10070000 1.7
CX GDSC on (0xf8228000), gx/gx_gmu/gx_gfx3d clocks on
zap: SCM PAS 13 INIT_IMAGE, MEM_SETUP, AUTH_AND_RESET all result 0 -> "signed zap authenticated and started"
CP configured, SQE enabled, CP_ME_INIT ring idle
CP NOP test PASSED (CP_MEM_WRITE read back, CACHE_FLUSH_TS timestamp)
CP fill test PASSED (64 of 64 words)
KEPT UP: GX on (OOB_GPU held, GMU keep-alive), ring 8192 dwords, client VA 0x80000000-0x100000000, 1028 table pages
SweetAdreno630 published (user client class SweetAdrenoUserClient)
```

So GMU, the GX rail, the GPU SMMU, the signed zap through TrustZone, the CP and the ring all work on this
phone with Bergamota's own driver - the first time their stage 8 has run on hardware, and it ran here.

The display is still CPU-composited (`SWEET FB: mode=copy hw=0`): the GPU is up but nothing draws through it
yet. That is their userspace half - EAGL -> Mesa freedreno -> Turnip, the `bglrender` payload that comes
with `berga-tools.zip` and is enabled by the boot-arg `bglrender=1`.

### Boot image that produced it

`enxerto/out/enxerto-boot.img` from `tools/mkpayload.py` + `enxerto/build.sh BOARD=fajita` with

```
... sweetts=1 sweettouch=1 sweettouchdelay=5 sweetgpu=8
```

and the fajita ADT (iPhone X identity, 1080x2340 1:1, `sweetfb_scale=1`).

## The userspace GL half: it starts, and stops where theirs stops

With the root tweaks applied (`renegade update`, bglrender payload from `berga-tools-v3` installed into
`/usr/local/lib/bergamota-gl`, backboardd's job pointed at `bgl-launch`) and `bglrender=1` on the command
line:

```
exec bgl-launch                        <- the launcher runs
SWEET GPU: KEPT UP ... SweetAdreno630 published
SWEET ADRENO count: 0                  <- nothing ever opened the GPU user client
SWEET FB: stats ... mode=copy hw=0     <- still CPU-composited
```

That is exactly the state their own notes describe for the same payload on the Poco F1: "backboardd
restarted as backboardd.real with the shim injected ... BUT: (1) the GPU service had 0 clients, (2) the
shim logged no screen creation, (3) the UI had no blur" (`docs/GPU_EAGL.md`). So the kernel half is done on
this phone and the remaining gap is upstream's open problem in the EAGL shim, not a fajita port defect.

Their newest GPU release is not EAGL but **Chlorophyll/bgmtl** (`bgmtl-dylibs-20261025`), and that tweak
installs the three dylibs into **Mercury** (PosterBoard's wallpaper renderer) with `/private/var/tmp/
bgmtl.arm`; it is the wallpaper, not the UI, that would render through BGMtlDevice.

### Where this leaves the port

Working on the 6T with Bergamota's stack: iOS 18.7.8 userland to SpringBoard, touch, keys, CPU-composited
display, the full a630 bring-up (GMU, SMMU, zap, CP, self-tests, keep-up, user client published), and a
readable kernel log from the UFS ring. The UI still draws on the CPU, for the same reason it does on the
Poco F1.

### Reading the shim's own log (needed to go further)

`bgl-launch` writes `/private/var/tmp/bgl-backboardd.log` and honours `bgldebug=1` (plus
`SWEET_GPU_DEBUG=1`, `EAGL_SHIM_DEBUG=1`). That file is inside the flashed `userdata`, so reading it needs
a shell on the running system (their SSH-over-USB needs a CDC-ECM host; Windows has no driver for it and
WSL's kernel here has no `vhci_hcd`, so usbipd cannot help). Two ways out: attach the phone's USB to a
Linux host, or make the launcher print to the kernel log.

## bgmtl (Chlorophyll) on the 6T: the same wall

The `bgmtl-dylibs-20261025` release installed cleanly (`renegade update`: dylibs in `/usr/local/lib/bgmtl`,
`MercuryPosterExtension` re-signed ad hoc with `LC_LOAD_DYLIB bgmtl-inject.dylib`, `/private/var/tmp/
bgmtl.arm` written) and the phone boots with `sweetgpu=8` and no `bglrender`. Result: **no wallpaper** and,
in the kernel log,

```
SWEET ADRENO count: 0                  <- the GPU user client is never opened
SWEET FB: stats ... mode=copy hw=0     <- still CPU-composited
SWEET FB: empty IOAcceleratorES published (no 30 s wait in CAMetalContextCreate)
```

The last line is the important one: the port publishes an *empty* `IOAcceleratorES`, so CoreAnimation sees no
Metal device and renders on the CPU; the shims are supposed to bypass that by opening `SweetAdreno630`
directly, and they do not. That is the same "0 clients" state as their EAGL attempt, so both of their
userspace GPU paths stop at the same place on this phone.

### What this means for the next session

The kernel is no longer the problem. What is missing is visibility into the userland shim: its logs go to
`/private/var/tmp/bgl-backboardd.log` and the unified log, both inside the flashed `userdata`, and there is
no shell on the running system (their SSH rides CDC-ECM, which Windows has no driver for; this WSL kernel
has no `vhci_hcd`, so usbipd cannot attach it either). Cheapest ways to get that channel, in order:

1. a `bgl-launch` replacement that also writes its own stdout to `/dev/klog` (tiny C, signed with their
   `tools/renegade/pacstrip.py`), so the shim's first lines land in the ring we already read;
2. attach the phone's USB to a Linux host and use their `sweet-usbnet.sh`;
3. compare our `main` branch's `bgmtl` bundle (which reached 5-6 submits with fence timeouts on our own
   kernel ABI) against their kernel's ABI: the difference will name the call that opens the device.

## ABI comparison: the shim matches by name, and the name is published

Read from their own sources and binaries rather than guessed:

* `libdrm.2.dylib` (their stand-in, from `berga-tools-v3`) opens the device with
  `IOServiceMatching("SweetAdreno630")` + `IOServiceOpen(svc, mach_task_self(), 0, &g_conn)`, then reads
  `INFO.abi_minor`; every failing call prints `sweet_drm: selector %#x -> %#x` to its own stderr.
* `bgmtl-inject.dylib` prints `BGMTLDevice registered in this process (kernel ABI minor %u)` once it is in.
* `iokit/Kernel/arm/SweetAdreno.cpp` (patch 0182) publishes exactly that name with
  `attach(platform)` + `registerService()` and logs `SWEET GPU: SweetAdreno630 published`.

So the two ends agree on the name, and the kernel log shows no selector call at all - which means the shim
never gets a connection (matching or open fails) or never runs its screen path. Their own GPU_EAGL notes
record the same on the Poco ("0 clients", "no screen creation"), so this is where upstream stopped.

A kernel-side registry self-check (`IOServiceGetMatchingService` right after publishing) would separate the
two, but it needs IOKit headers this C file does not include; the patch was written, failed to compile
(`io_service_t`/`OSDictionary` unknown) and is parked at `~/src/0257.parked` rather than left in the tree.

### Next, in order of cost

1. From the shim side: a `bgl-launch` that also mirrors its stderr to `/dev/klog`, so the first
   `sweet_drm: ...` line lands in the ring we can read. The payload is prebuilt, but a replacement launcher
   is ~50 lines of C plus `pacstrip --sign`.
2. From the kernel side: do the registry check in C++ (`SweetAdreno.cpp`, where IOKit types are natural) and
   log both the match and `start()`/`newUserClient()`.
3. Compare with `main`'s Metal path: there the same userland did reach the user client (selectors, submits,
   fences), so its opening sequence against our ABI is the reference for what theirs is missing.
