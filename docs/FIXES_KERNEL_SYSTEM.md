# Kernel, display and system fixes (iOS 18 on the Poco F1)

What went wrong, why, and what fixed it, one entry per bug. Each entry has the symptom, the cause, the fix (patch in
`xnu/patches-11215`, or phone-side state) and how to check it. The GPU rendering fixes in Chlorophyll (Metal on the
Adreno 630) are in Chlorophyll's own repository: `gpu/metal/docs/FIXES.md`.

---

## Kernel (`xnu/patches-11215`)

### Every boot started in 1970; coreduetd at ~75 % of a core for the whole boot (0245)

- **Why.** The kernel had no real-time clock: `IOKitInitializeTime` found no `IORTC`, so iOS started at the epoch
  and jumped to 2026 when timed got network time. coreduetd then re-ingested its Biome history (time-windowed
  pipelines seeing 56 years of "new" time) and never finished: 5 min of CPU in 7 min of uptime, the little cores
  pinned, swipes at ~21 fps on the injected-swipe test.
- **Fix.** The PM8998 RTC (SID 0, 0x6048) counts through reboots but the AP cannot set it (TZ-owned; on this phone
  it held ~80 days of seconds). 0245 keeps the offset to Unix time in the RTC alarm data registers (0x6140, only
  while that alarm is disabled, so it cannot wake the phone), publishes `IORTC`, and serves the platform expert's
  get/setGMTTimeOfDay from raw + offset. iOS's own settimeofday stores the offset (first boot), so from the second
  boot the clock is right from launch. coreduetd idles (0 %); the same swipe test went 521 -> 849 frames (~35 fps).

### iOS held at 1 frame/s once the backlight service existed (0243, disabled by 0246)

- **Why.** With 0243's `backlight-control` service published, every boot capped presentation at 0.98-0.99 frames/s,
  touch included (kernel `swaps_s`); boots without it ran 30-55 fps. Bluetooth was ruled out by unloading bluetoothd.
  The exact iOS-side reason is still being investigated.
- **Fix (for now).** 0246 publishes the service only with boot-arg `sweetfb_blsvc=1`. Panel on/off (0242) still
  follows iOS; the brightness slider does not reach the panel yet.

### Frames serialized behind the GPU (0241, and Chlorophyll's "scheduled")

- **Why.** Each frame waited for the previous frame's GPU work twice over: Chlorophyll reported "scheduled" to the render
  server only once the GPU had finished, and the kernel held each swap until the GPU fence passed (0229). Only then was
  the scan-out copied and the swap completed, and only then did CoreAnimation start the next frame. CPU encode (~11 ms)
  and GPU work (~6-8 ms) ran one after the other instead of overlapping.
- **Fix.** Chlorophyll reports "scheduled" at submit again; `bgmtl-bb.defersched` restores the old behaviour. With the
  GPU copy, the kernel no longer holds the swap: the blit is queued behind the frame's GPU work on the same ring. The swap
  completes as soon as the blit is queued, because anything CA submits later runs after the blit has read the surface.
  The frame is scanned once the blit's fence passes (`scanBlitPoll`, 100 ms cap). A newer frame arriving first reuses
  the in-flight buffer, and a CPU fallback waits for the frame's work and for any blit in flight.
- **Result.** Same swipe test, async commits: 28.4 fps (0240b), 29.4 (no deferral), **38.6 (0241)**. The CPU cost
  of the scan-out path is now 18 us per frame. The home screen renders correctly, and no tearing on the panel (checked by
  eye; screenshots read the frame, not the glass).

### ~30 fps cap from the CPU scan-out copy (0240)

- **Why.** 0235 copied every frame on the CPU: about 6.5 ms per frame (memcpy of 11 MB plus a cache clean of the
  source), while the GPU sat 13-17 % busy.
- **Fix.** With `sweetfb_scancopy=2`, the framebuffer's low pool (252 MiB) is mapped into the GPU once, and each frame
  is one 2D-engine blit (`CP_BLIT`) submitted from the kernel. It uses freedreno's linear RGBA8 sequence, with register
  values from Mesa's `a6xx.xml.h` for chip 630 and the CCU switched to sysmem bypass first. The swap completes when the
  blit's fence passes. A CPU draw still dirty in the pool is cleaned first. After 3 failed blits in a row, the next
  120 frames are copied on the CPU and then the GPU is tried again. The first version stayed off for the whole boot
  after a few backboardd restarts.
- **Result.** About 1.3 ms per frame. `kern.sweet_fb` reports `scan_gpu` (1 on, 2 resting), `scan_gpu_copies` and
  `scan_gpu_fallbacks`. Needs 0237 (126 page tables for the pool alone).
- **Then, async commits.** With the GPU copy and the 0229 scan-out gate, `bgmtl-bb.sync` is no longer needed. A/B over
  the same swipe script: sync 20.8 fps, async 28.4, dirty regions 22.7, both 25.0. The phone runs async with full
  redraws; Control Center and the home screen render correctly.

### Control Center without its backdrop, a flat wallpaper, black boxes: big GPU buffers refused (0237)

- **Symptom.** A while into each boot, full-screen render targets could no longer be allocated: Chlorophyll's log said
  "the GPU driver would not allocate a 1127x2438 ... BGRA8Unorm" (also 1125x2436, 2052x3054). CoreAnimation then drew
  without that layer: Control Center over a sharp home screen, a flat pale wallpaper. Small buffers kept working.
- **Why.** The GPU address window is 2 GiB (0x80000000-0x100000000), but its page tables came from a fixed pool of 256
  4 KiB tables: 2 L2 + 254 L3, each L3 mapping 2 MiB, so at most 508 MiB of the window could ever be mapped. Tables are
  taken on first touch of a 2 MiB region and never returned, and first-fit placement keeps reaching new regions as
  buffers are freed and reallocated. Once the pool was used up, small buffers still landed in regions that had tables,
  but a 10-24 MB target needed a fresh range, `gvm_slot` found no table page, and GEM_NEW failed. Separately, a full
  free list (512 ranges) silently dropped freed ranges, leaking address space.
- **Fix.** 1028 table pages (4 MiB: enough for every 2 MiB of the window) and a 4096-range free list.
  `kern.sweet_gpu` now reports `gvm_tables=used/total` and `gvm_free_ranges`.
- **Check.** `sysctl kern.sweet_gpu`: `gvm_tables` stays below its total; no "would not allocate" lines in
  `bgmtl.log`/traces; Control Center keeps its backdrop after long use.

### Locally built kernels: the GPU never comes up (0236)

- **Why.** clang 21 (Xcode 27) turned a volatile MMIO read loop into a post-indexed `ldr w, [x], #4` on the SMMU context
  banks. An access with writeback has no valid syndrome (ESR.ISV = 0), so the trapping hypervisor cannot emulate it and
  the bring-up stalls. CI's clang 16 used a register offset, so CI kernels worked.
- **Fix.** `gpu_rd`/`gpu_wr` (and the TTBR0 write) are single-instruction asm with a bare base register.
- **Check.** After a local build, scan the driver disassembly for `ldr/str w.., [x..], #` near a `dmb`.
  `SweetFramebuffer`'s plain C MMIO could hit the same thing with a newer compiler.

### Tearing at the bottom of the screen (0235)

- **Why.** CoreAnimation's IOMFBFlipBook keeps one swap in flight and recycles the surface of swap N-1 as soon as swap N
  completes. With swapdepth 1, SwapWait waits for the latch (~10 ms of every frame). With swapdepth 2, CA draws into the
  surface still on the panel, which tears.
- **Fix.** Every frame is copied into one of three framebuffer-owned buffers, which are scanned instead; the swap
  completes when the copy does (`sweetfb_scancopy=1`). Cost: ~6.5 ms per copy, which is what holds the panel at ~30 fps
  today.
- **Check.** `sysctl` stats `scancopy`, `scan_copies`, `scan_copy_us`.

### Black wedges in the lock-screen editor; SMMU faults just past a surface (0234)

- **Why.** The Adreno writes render targets in whole tiles, so on a surface whose height is not a tile multiple it
  writes up to a tile of rows past the end. That ran into the next BO, or faulted on the guard page; three faults and
  the GPU is lost.
- **Fix.** The tails of surface BOs map to one shared, zeroed, writable page.

### A stale frame for a vsync on every wake (0227, 0233)

- **Why.** CA's first swap after the display comes back has no layer, so the copy path scanned the back buffer as it
  was: the last frame drawn, possibly long ago.
- **Fix.** An empty swap means black (0227); only the first per wake is honoured (0233).

### Half-drawn frames scanned out with asynchronous commits (0229)

- **Why.** With async command buffers, the compositor swaps a framebuffer the GPU may still be writing. Apple's display
  waits on the GPU write fence; ours did not.
- **Fix.** A swap is held until the newest submitted fence passes (stats `gpuHolds`, `gpuHoldTimeouts`).

---

## System (phone-side state)

### SpringBoard crashed on Motion access

- **Why.** SpringBoard asked for Core Motion without a TCC grant, and its Info.plist had no `NSMotionUsageDescription`.
- **Fix.** A `kTCCServiceMotion` grant for `com.apple.springboard` in TCC.db (backup in `/private/var/tmp/tcc-backup/`),
  and the key added to SpringBoard's Info.plist (original kept at `/private/var/tmp/SpringBoard-Info.plist.orig`).

### coreduetd at high CPU

- **Why.** The `_DKEvent.Dasd.WidgetView` Biome stream and dasd's widget prediction cache
  (`widgetRefreshBudgets.plist`) kept coreduetd busy.
- **Fix.** Both were backed up to `/private/var/tmp/dasd-widget-backup/` and deleted.

### A dylib replaced in place crashed its users

- **Why.** `cp` over a mapped, signed dylib changes pages under a running process, which fails code-signing
  (CS_INVALID); SpringBoard went into a TCC crash loop.
- **Fix (procedure).** Install to a temp file and `mv` it over the original. The scripts (`bgairpush.sh`, the inject
  deploy) do this.
