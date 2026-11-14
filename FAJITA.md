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

## Chlorophyll in backboardd: the UI runs on the Adreno 630 (2026-11-10)

The a630 bring-up was already passing, but nothing opened the GPU user client. The missing half was not the
board and not the kernel: on iOS 18 the Renegade `bgmtl` tweak only links the inject into
`MercuryPosterExtension`, while the *UI* path is backboardd, and upstream does that by hand. Reproduced here:

1. `/usr/libexec/backboardd` gets an extra `LC_LOAD_DYLIB /usr/local/lib/bgmtl/bgmtl-inject.dylib`
   (`tools/sweetnet/addlc.py` + `pacstrip.py --sign`; entitlements and identifier kept, original saved as
   `backboardd.orig`). backboardd has slack for one more load command.
2. `/private/var/tmp/bgmtl-bb.arm` arms the backboardd path.
3. The **environment** gate matters: the `bgmtl-dylibs-20261025` release does **not** know
   `bgmtl-bb.direct` (that file is a later `develop` addition), so its constructor returns silently unless
   `BGMTL_BB` is in the environment. Set it in the job itself
   (`EnvironmentVariables = {BGMTL_BB: 1}` in the launchd.plist cache entry for `com.apple.backboardd`), the
   same way upstream passes `BT_HCI_TRANSPORT` to bluetoothd. Without it there is **no log at all**, which is
   why the earlier attempts looked like a GPU problem.

Their own log (`/private/var/tmp/bgmtl.log`) after this boot:

```
[60] backboardd: devices before registration: 0
[60] backboardd: Chlorophyll device registered (kernel ABI minor 2)
[60] UNIMPLEMENTED (answered zero): setCompletionQueue:
[60] backboardd: first command buffer completed
[60] backboardd: healthy (10 s after the first completed command buffer, no failure)
```

So Chlorophyll (Metal -> Mesa freedreno -> ir3 -> Adreno 630) is the system compositor on fajita.
`bgmtl-bb.state` says `alive=1` for that boot and no kill switch was written.

### Wallpaper

The wallpaper was never a Mercury problem: the image had **no** `/usr/local/bin/sweetposterset`,
`/usr/local/bin/sweetopen`, `/Applications/SweetRun.app` and no `/bin/sh` (dash comes from the ssh tweak), so
Renegade's first-boot job never existed and **no poster was ever selected** - the previous "wallpaper" was
the system's built-in default. Now installed: dash as `/bin/sh`, the three poster tools, `SweetRun.app`,
`sweetuicache`, `/usr/local/libexec/renegade-firstboot.sh` and the job `org.bergamota.renegade-firstboot`
(`/bin/sh <script>`, RunAtLoad, UserName root), which registers apps and selects the poster as mobile through
SweetRun: `com.apple.MercuryPoster:fluidity.two` (the iOS 18 default) because a Metal device exists now.

### Tooling added: reading the iOS root without a driver

OrangeFox's kernel has no hfsplus, so the phone's root cannot be mounted in recovery. `~/src/remote-hfs.py`
(not in git, like the other private tooling) implements `ls`/`cat`/`stat` on `/dev/block/sda17` through
`adb exec-out dd` at 1 MiB granularity and feeds `tools/renegade/hfsx.py`; the catalog costs ~240 MiB of
reads (a couple of minutes). This is how `bgmtl.log`, `bgmtl-bb.state`, the crash-log directory and the
launchd cache were read while the phone was in recovery.

### Why there was no wallpaper: PosterBoard refuses to create its store on an HFS root

The poster tools were only half of it. `sweetposterset` answered every call with

```
fetch selected failed: Error Domain=com.apple.PosterBoard.generalErrorDomain Code=0
"Data store could not be created for an unknown reason which evades explanation."
```

which is their own documented iOS 18 HFS problem (`tools/sweetnet/sweetfp.m`): the HFS+ root has no data
protection classes, so `setResourceValue:forKey:NSURLFileProtectionKey` succeeds but reading it back returns
nil; PosterBoard's `pbf_URLIsReachableAndConformToResourceValues:` then fails, the 59 -> 61 migration fails
("Failed to migrate to Version 61 from 59") and **no wallpaper store exists** - hence no poster, no wallpaper,
and the SpringBoard "Customize" crash in `PaperBoardUI`.

The fix is their `sweetfp.dylib` (keeps the protection class in an xattr so the validation is consistent),
linked into a re-signed `/Applications/PosterBoard.app/PosterBoard`: the Renegade `posterboard` feature, which
this image had skipped because `research/sweetnet` was empty. Installed now with
`RENEGADE_SWEETNET=<berga-tools cache>/sweetnet` (48 entitlements kept, identifier unchanged).

The poster itself is set by the `org.bergamota.renegade-firstboot` job. Two dead ends worth recording:
`sweetuicache`/the app-registration step blocked the job for the whole boot (so the wallpaper step never
ran), and `sweetopen com.sweet.run` returned 3 on every attempt even though `SweetRun` does get exec'd and
proceeds to the poster step (its `posix_spawn` of `/bin/sh` produces no log, path unexplained). Running
`sweetposterset` straight from the root job does reach PosterBoard - the store error above is PosterBoard's
own, not a client privilege problem - so the job now calls the tool directly.

## Display identity and the MDP hardware scaler (2026-11-12)

What works on the 6T now: iOS 18.7.8 userland, SpringBoard, touch, GPU compositing through Chlorophyll,
wallpaper, 60 Hz, and the **hardware scaler**: patch 0258 lets `sweetfb_hw=1` and MDP page flipping through on
fajita (`sweetts=1`), and the log confirms

```
hw scaler: canvas 1125x2436 (stride 4544) -> 1080x2338 at 0,1, qseed3 v0x1003, PE regs written
page flipping on VIG0: frames 0x9d400000 0x9de00000 0x9e900000 (11069184 bytes each back buffer, 30 restore regs)
presented as 1125x2436
```

so the canvas is scaled down by QSEED3 instead of by `presentScaled` (the software downscale is broken: at
`sweetfb_scale=1|2` the frame lands in a narrow centred strip, at `scancopy=1` the layout looks wrong).

### The red rdar:45025538 bar is still there

Every configuration tried keeps UIKit's fallback status bar ("No status bar visual provider for screen"):

| ADT identity | canvas | scan-out | UI size | rdar |
|---|---|---|---|---|
| iPhone X (D22AP) | 1125x2436 | software (strip/"iPad") | wrong | gone once, later back |
| iPhone X (D22AP) | 1125x2436 | QSEED3 (0258) | correct | present |
| iPhone 13 mini (D16AP, real tree) | 1080x2340 | copy | correct | present |
| iPhone 13 mini (D16AP) | 1125x2436 | QSEED3 | correct | present |

The bar therefore is not the canvas geometry alone. `Settings > About` hangs in all of them, which points at
MobileGestalt: SpringBoard cannot build its status bar from a MobileGestalt that never answers. mkadt does
filter the flagged syscfg placeholders out of /product, so the unresolved-`syscfg/...` theory is not what
`/product` carries, and the next probe should be MobileGestalt itself (which DT node or root file it waits on).

### Tooling

* the real iPhone 13 mini device tree is in the tree now: fetched with `tools/remotezip.py` straight out of
  the 18.6.2 IPSW (`DeviceTree.d16ap.im4p`, 49 KB), IM4P-extracted and bvx2-decompressed with the `lzfse` pip
  module (243 KB), then added to `mkadt.py` as identity `d16ap` (kept out of git like the other Apple files);
* `sweetshot` + a launchd job (`org.bergamota.shot`) take a frame 60 s and 90 s after boot, because the volume
  buttons do not work yet. The first file it wrote was zero-filled, so the screenshot pipeline still needs work
  (the sysctl format is documented in patch 0224: 'SHOT' magic + w/h/bpr + BGRA).

### Unified log on the phone (works) and what it said about the status bar

`sweetlog <seconds> [words...]` now runs from the launchd job `org.bergamota.shot` (installed with
`/usr/local/bin/sweetshot` and `/bin/toybox` + `sleep`), which writes `/private/var/tmp/uni-boot.txt`
(everything, 90 s) and `uni-mg.txt` (filtered: MobileGestalt/SpringBoard/statusbar/UIKit/About). The job's
`sh -c` argument must be **one** string with no surrounding quotes: the first version passed the whole command
quoted, the shell looked for a program named `"sleep 40; ..."` and wrote nothing.

What the log shows:

* SpringBoard sets the status bar up normally: `Using SBNotchedStatusBarProximityBacklightPolicy`,
  `SBStatusBarSettings ... style = UIStatusBarStyleLightContent`, `SBHomeScreenStatusBar`;
* the string `45025538` never appears, and neither does any "no visual provider" message - the radar text and
  the red background are drawn silently (the interesting UIKit lines are `<private>`);
* MobileGestalt fast-path calls succeed in the first 90 s (no errors, no timeouts in that window).

So the red bar is not a plain "provider missing" case as their iOS 16 notes describe, and the logs do not name
the decision. The screenshot job also fired too early (40 s = still Enxerto's boot logo, which is why the first
"shot.png" was the BERGAMOTA splash): the frame has to be taken at 150 s and later.

Given the effort already spent, the red bar stays open as cosmetic (the layout, wallpaper, dock, 60 Hz and the
hardware scaler all work); the functional gaps in the review (USB data, fuel gauge, volume buttons, RTC) come
from the `sweet_board_beryllium()` gating and are the next real work.

## The red status bar: everything tried on hardware (2026-11-14)

UIKit draws its fallback ("No status bar visual provider for screen ... Please see rdar://45025538",
found in the dyld shared cache) and `Settings > About` shows an empty model/regulatory model in every
configuration, so MobileGestalt is not giving UIKit a complete product. What was tested on the phone:

| test | result |
|---|---|
| canvas 1080x2340 / 1125x2436 (360 / 375 pt) | bar |
| real tree of the iPhone X (D22AP) | bar |
| real tree of the iPhone 13 mini (D16AP) | bar |
| real tree of the iPhone 11 Pro (D421AP) | bar (and this identity does not always boot) |
| `/chosen/display-corner-radius = 44` | bar |
| `debug-enabled=0`, `certificate-production-status=1` (retail) | bar, and iOS goes to Setup (activation) |
| ADT **without** `/product` | bar |
| the iOS 16 `fajita.adt` verbatim | no bar known, but it lacks iOS 18 keys (unique-chip-id, chip-id, boot-manifest-hash, crypto-hash-method) and the screen stays black |
| `/product` filled with model-number/regulatory-model/region (A2160, D42AP) | SpringBoard stops presenting (`swaps=0`), black screen |

The unified log (`sweetlog` from the launchd job) shows MobileGestalt answering normally (`fast-path`, 255
answers) and SpringBoard setting up a notched status bar, but the provider message itself never appears in
either the unified log or SpringBoard's stderr - so the decision inputs cannot be read from the device.

Observations that matter for whoever picks this up: the ADT from the working iOS 16 builds has **no**
`/product` node at all, while every ADT for iOS 18 does; About showing an empty model points at the
syscfg-filled `/product` properties (model-number, regulatory-model-number, model-config), which iBoot fills
on a real device and which mkadt drops because they are flagged placeholders. A kernel-side
`IOPlatformSerialNumber` (like `unique-chip-id` -> IOPlatformUUID) is the other candidate nobody has tested.
