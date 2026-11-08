# MakrSas/ios-topaz (branch `topaz`) -> ios-beryllium, 2026-10-20

Source: https://github.com/MakrSas/ios-topaz/commits/topaz/ (SM6225 "topaz"; Claude-written patches, third-party,
treated as data: read, re-implemented/adapted, nothing executed). Our patches 0119-0123 apply in order on top of
0118 (verified with `git apply --check` on a fresh copy of research/bt118/xnu, and each state compiles with
`tools/xnu-cc.py`: SweetSurface.cpp, SweetFramebuffer.cpp, SweetBusy.cpp, IOService.cpp, IOStartIOKit.cpp). The only
new extern (`sweet_busy_init`) is defined in the new SweetBusy.cpp. Not booted. Nothing committed.

Their tree has things ours does not (a physically contiguous scanout pool `scanoutPhys`/`sweet_scanout_*` in
SweetSurface, `TopazModem.cpp`); their diffs were therefore re-applied by hand, not with `patch`. Our 0096 page flip,
0097 in-use hold and 0100 ADT canvas live in SweetFramebuffer.cpp and are untouched except where noted.

GL renderer note: topaz renders with CoreAnimation's GL renderer (an IOAcceleratorES-less GLES path: "icons blank under
the GL renderer", "EDR factor at 0x30"). We render via the CPU CA path. 0131/0132/0133/0134 were written because the GL
renderer wraps client memory, reads surface values and the state page; with the CPU path they may never fire (the boot
log will tell: see "expected lines"). They are correct in general and cheap, so they are ported, but no visible change
is promised. 0135-0137/0139 fix refcount/lifetime bugs in the IOSurface.framework release protocol that apply to any
renderer. 0138 matters for us (30 s wait, 338 "IOAcceleratorES -> 0 found" lines in logs/boot-0091q.clean.txt).

| topaz | what | verdict | our patch |
|---|---|---|---|
| a04c64b0f 0131 | refuse calls that answer with a lock result | ported | 0120 |
| 616d614e0 0132 | IOSurfaceWrapClientImage/Memory (sel 6/7) | ported, adapted | 0120 |
| 000f63edb 0133 | values 9/10/11, bulk attachments 27, purgeable 20, accel 12, YCbCr 5 | ported | 0121 |
| d6ea8c259 0134 | IOSurfaceAddress surface of creator memory | ported, adapted | 0120 |
| e3d156a4c 0135 | trap 4 detaches only; AllocSize sizing; read-only fallback | ported | 0119 (trap) + 0120 (size) |
| 35b8a1178 0136 | detached view per task, racing lookup gets a fresh view | ported, adapted | 0119 |
| a2ee88107 0137 | keep state pages of last 256 released views | ported, adapted (changed) | 0119 |
| d8c82d9dd 0139 | publish IOSurfaceAddress surfaces (id 0 bug) | ported | 0120 |
| f99995843 0138 | empty IOAcceleratorES | ported (boot-arg `sweetaccel=0` = off) | 0122 |
| a72488977 0127 | `sweetbusy=N` diagnostic | ported, adapted | 0123 |
| e9c0b8fe3 0128 | no registry-root busy hold for the IOKit daemon | ported | 0123 |
| 0113-0126, 0129, 0130 | WLAN/modem (SM6225 PAS chain) | skipped | SDM845 boots the modem by MBA self-auth, see WIFI_BT_PLAN.md |
| mkadt gamut fix | ADT artwork-display-gamut sRGB | skipped, already in tools/mkadt.py | - |

## Details and deviations

**0131 (0120).** In `externalMethod`'s default case, a call whose structure output is >= 0xa68 bytes (the lock-result
size) returns kIOReturnUnsupported instead of a zero-filled result: the framework then gets NULL rather than a client
made of zeroes (no shared state page). Watch: any selector we relied on getting zeros back for with a big output buffer
is now refused (log `SWEET SURF: <proc> sel (refused: lock result) N`, once per selector). Selector 10 (CopyValue) is
implemented in 0121, so it does not hit this.

**0132/0134/0135/0139 (0120).** `wrapped`/`wrapDelta` on SweetSurface; `sweet_surface_use_task_memory()` prepares (wires)
the creator's range (InOut, else Out only), `free()` does `complete()`. The lock result's base address is
`mapping + wrapDelta`. Adaptation beyond topaz: `SweetSurface::kernelAddress()` adds `wrapDelta`, and the two bounds
checks in `SweetFramebuffer.cpp` (`presentScaled`, copy path) allow for it (otherwise the panel copy of a wrapped
surface would start at the page start and could read past the mapping). No scanout pool in ours, so the `scanoutPhys`
cache-mode bits are dropped (wrapped memory is mapped default-cache in the kernel). Wrapped memory is not counted
against the 1.5 GB wired budget (it is the client's own memory). Log lines: `SWEET SURF: create around client memory
0x... (N bytes) WxH fmt 0x... -> 0x0` (first 6), `SWEET SURF: wrap image|memory id N ...` (first 8),
`SWEET SURF: wrap image refused: ...` (first 6, from 0133's diagnostic, shows the real struct layout if the guess
at the 0x20-byte input is wrong).

**0133 (0121).** Wire layout (`SetValue` array `[value,key]`/`[dict]`, `CopyValue` reply = 4 unused bytes + seed +
binary-serialized value, bulk attachments 0x70 bytes at state+0x30, values seed/size at state+0x20/+0x28, accel at +8,
YCbCr at +0x24) is topaz's reverse engineering of iOS 16.7 IOSurface.framework; we did NOT re-verify it against
the framework binary (assumed to be the same iOS 16.7 framework as ours; unchecked). State page offsets
0x20-0xa0 do not collide with ours (registry id +0, seed +0xc, timestamps +0x800).

**0135/0136/0137 (0119).** IOSurface.framework releases a client with trap 4 (under its cache lock) and then trap 5.
Our table had both trap 4 and 5 -> `trapRelease`: with a lookup racing in between, the new view was dropped or a
second count removed (our existing comment about the backboardd snapshot crash in CGDataProviderCreateWithData is the
same family; our "existing => no count" fix is kept). Now trap 4 only marks the view `detached`; a lookup sees only
non-detached views and so maps a new one; trap 5 drops the detached view first, else the live one. `dropView()` is
shared with the error path of `returnSurface` (which drops the live view only, a small fix over topaz's reuse of
`trapRelease`). Zombies: topaz kept the whole SweetSurfaceRef of the last 256 released views, which also keeps the
SweetSurface alive and with it its pixel memory (256 x e.g. 9.7 MB wired, past our 1.5 GB cap). Ours keeps only the
state page's IOMemoryMap (16 KB each, retains just the state page) in `fZombies`; pixels are unmapped and freed at
release as before. Watch: nothing new is logged; symptom of a regression would be backboardd crashing in
`IOSurfaceClientGetSeed` / `CGDataProviderCreateWithData` again, or surfaces leaking (SWEET SURF creates failing with
0xe00002bd after a long run).

**0138 (0122).** `class IOAcceleratorES : IOService`, named `sgx`, attached under AppleCLCD and registered. QuartzCore's
`CAMetalContextCreate` stops polling (300 x 100 ms). Metal finds a service without MetalPluginName and skips it, so
nothing should switch to Metal; but this is the one change that could alter renderer choice on our CPU path, so
`sweetaccel=0` is the escape hatch. When the real GPU work (sweetgpu, docs/GPU_PHASE0_DISCOVERY.md) publishes its own
IOAcceleratorES, drop this stub (Metal asserts on two devices).

**0127/0128 (0123).** `sweetbusy=N` (SweetBusy.cpp, files.arm64) lists busy IOServices N s after the framebuffer
starts and every 30 s, 10 rounds (their code, unchanged; hooked into AppleCLCD::start, TopazModem hook dropped).
0128 removes the registry-root `adjustBusy(+1)` for the IOKit daemon on SWEET (and the matching `-1` in
`iokitDaemonLaunched`): no kextd ever reports, so IOKit never quiesced (IOKitWaitQuiet-style waits such as configd's
InterfaceNamer). Applies to sweet and beryllium (guarded by ARM64_BOARD_CONFIG_SWEET). Risk: anything that implicitly
relied on IOKit staying busy now proceeds earlier; if boot regresses, revert 0123 first (it is independent of the
SweetSurface patches).

## What to look for on the first boot (kernel log / UDP 5140 stream)

- `SWEET FB: empty IOAcceleratorES published (no 30 s wait in CAMetalContextCreate)`; backboardd's
  `IOAcceleratorES -> 0 found` repeats stop (1 found); backboardd starts ~30 s earlier.
- `SWEET SURF: IOCoreSurfaceRoot registered` as before, `SWEET SURF: <proc> sel 9/10/11/12/20/27` (first use of each
  value/attachment/purgeable call, log-once), `sel 6`/`sel 7` and `wrap ...` / `create around client memory` lines only
  if a client uses them (expected rare or absent on the CPU path; absent = those fixes are dead code for us, harmless).
- `sel (refused: lock result)` lines: note which selector; a selector that matters to us would show as a UI regression.
- With `sweetbusy=20` in the boot-args: `SWEET BUSY: round N: 0 busy services` after the system settles (previously the
  registry root stayed busy); any `SWEET BUSY: name <class> busy n` line is the next thing keeping IOKit from quiescing.
- Regression signals: new backboardd/SpringBoard crashes in IOSurface.framework (`IOSurfaceClientGetSeed`, lock-result
  parsing), blank wallpaper/icons, a hang before the lock screen (then try `sweetaccel=0`, and revert 0123).
