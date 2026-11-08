# Review of MakrSas/ios-topaz patches 0080-0126 for the Poco F1 (SDM845)

Review date 2026-10-19/20. Source: https://github.com/MakrSas/ios-topaz (Redmi Note 12 4G, SM6225, ~268 stars, **no LICENSE file**; the patches are a port of ios-sweet plus topaz-woa). Third-party content was treated as untrusted data; nothing was executed. Patch text was read from `xnu/patches/0080-0126`.

Tags: **[verified]** = checked against our live DT (`dtb/beryllium/live.dts`), `research/linux-dts` sdm845.dtsi, or the mainline Linux DPU sources (`dpu_4_0_sdm845.h`, `dpu_hw_sspp.c`, `dpu_hw_util.c`, `dpu_hw_ctl.c`, `dpu_hw_intf.c`, `qcom-wled.c`); **[unverified]** = needs a read on the phone.

## 0. What topaz actually reports (important caveat)

There are **no fps or latency numbers anywhere** in topaz's README, NOTES.md (that file is just sweet's inherited log) or commit messages. Their README still says "low frame rate (the CPU copies frames to the panel)". The only measured/observed effects are qualitative, from commit messages:

| Observation | Source commit |
|---|---|
| Boot FB mapped Device (VM_WIMG_IO): console and boot logo "crawl down the panel"; WCOMB fixes it | 0095 |
| Fading the uncached boot FB in place crawls; do it in cached memory and flip whole frames | 0096 |
| Pointing the MDP straight at the CoreAnimation IOSurface shows half-drawn frames (CA starts the next frame in the same surface); copy into a cached back buffer and flip instead | 0102 |
| Composing multi-layer frames into the *scanned* (uncached) FB shows every frame drawn top-down | 0103 |
| Making `flush_dcache`/`clean_dcache` real globally "slowed the whole kernel to a crawl" (XNU calls them on every pmap/IOMD path) -> keep them no-ops, add scoped `sweet_dcache_clean/flush` for display/DSI buffers only | 0101 -> 0107 -> 0111 |
| Publishing an AppleARMBacklight service makes CoreBrightness run digital dimming (a colour filter over every frame) and "the UI dropped to under 1 fps" with the CPU renderer | 0110 |
| CoreBrightness ramps brightness in many small synchronous steps; waiting for the DSI inside setProperties stalled backboardd rendering | 0107 |
| "MDP crop via SRC_XY gave a black screen" (dropped); cropping by pointing SRC0_ADDR at `base + oy*stride + ox*4` (16-byte aligned) works | commit log, 0114 |
| Gold cluster max cpufreq via cpufreq-hw PERF_STATE | 0094 (we already have the equivalent) |

So the useful content is the **architecture and the pitfalls**, not performance data. Final topaz render path (0102/0103) is: CoreAnimation renders (CPU) into cached, default-mapped, physically contiguous IOSurfaces below 4 GiB -> kernel memcpy (cached to cached) into one of two cached contiguous back buffers -> `dc cvac` the buffer -> write VIG0 SRC0_ADDR/YSTRIDE0 -> CTL_FLUSH (latched at the next vsync). Console text takes the same path (shadow frame -> back buffer -> flip). Panic switches the MDP back to the console frame (0097 hook).

## 1. Rendering patches, one by one

| Patch | What it does | Applies to SDM845 / needs change | Conflicts with our 0090 / 0091 | Benefit estimate |
|---|---|---|---|---|
| **0092 direct-mdp-scanout** | `ml_io_map` VIG0 `0x05e05000` and CTL0 `0x05e02000`; saves boot `SRC0_ADDR` (+0x14) and `YSTRIDE0` (+0x24); `scanFrom(pa,stride)` writes them, `dsb`, `CTL_FLUSH`(+0x18)=`0x20001` (VIG0 bit0 + CTL bit17). IOSurfaces from a pool are scanned directly (no copy). | Mechanism is generic DPU. Bases change (section 3). Pool at 0xb0000000 is irrelevant (see 0093). | `directPresent` handles one full-screen layer and crops by address; it cannot scale -> bypasses 0091. | The `scanFrom` primitive is the key piece (HIGH). Direct scan of CA surfaces itself was abandoned by topaz (0102). |
| **0093 scanout-contiguous-ram** | The 0xb0000000 raw physical window maps as Device -> memcpy/bzero alignment faults; switch to `IOBufferMemoryDescriptor::inTaskWithPhysicalMask(0xfffff000, physContiguous)`, default-cached kernel map, require pa+size < 4 GiB (MDP address regs are 32-bit, display SMMU bypassed). Needs xnu to own RAM below 4 GiB (topaz added `mkadt --midmem`). | **Constraint for us:** all xnu RAM is >= 0x1_0000_0000 (NOTES: `kernel RAM = 0x100000000 + 0xfcc00000`), so a <4 GiB physical-mask allocation will fail. Options in section 4. | none | Enabler, not a gain by itself. |
| **0095 wcomb-console-fb** | `video_console.c`: `#elif defined(ARM64_BOARD_CONFIG_SWEET) flags = VM_WIMG_WCOMB` instead of `VM_WIMG_IO` for the boot FB. | Directly applicable, 4 lines. Our tree has no `VM_WIMG_WCOMB` hit in 0082-0095 -> early console still draws into Device memory. | none | Console/boot text no longer crawls (only matters when console is visible: bring-up, panics). Cheap. |
| **0096 smooth-fade** | On display-off, fade the last frame in cached memory (30 steps) and flip whole frames instead of fading the uncached FB. | Our panel is LCD+WLED: fading in software is not needed if we ramp WLED / blank. | uses flip machinery | Low. Skip (or reuse back-buffer helper later). |
| **0097 unified-console-scanout** | Console draws into a cached contiguous shadow frame (hooks `gc_ops` paint/clear/scroll, flush per row), `sweet_console_show_hook` makes the MDP show the console frame in a panic. | Console part optional. **The panic hook is mandatory once we flip away from the ABL FB**: otherwise panic text drawn into the boot FB is not visible. | needed with any flip | Correctness for panics. |
| **0098 intf1-refresh-diag** | Maps INTF_1 (`0x05e6b800`), enables FRAME_LINE_COUNT (+0x0a8), logs INTF_FRAME_COUNT (+0x0ac) / LINE_COUNT (+0x0b0) every 5 s, prints timing regs. | INTF_1 = DSI0 on SDM845 too: `0x0ae6b800` [verified]. Offsets are the common DPU ones [verified in `dpu_hw_intf.c`]. | none | Gives ground truth panel refresh and a poll-able vsync/flip-complete counter. Cheap, worth porting. |
| **0099 surface-inuse-console-batch** | `IOSurfaceClientIsInUse` (iOS 16.7 userland) reads a u64 at +0x18 of the per-surface shared state page; the kernel increments it from SwapEnd until one vsync after the surface was replaced on screen, so CoreAnimation does not render into an on-screen surface. Also batches console cache cleaning per vsync. | Userland is the same iPhone X 16.7.16 root, so portable as is (our `SweetSurface` state page is the same 0046 layout). | Helps the copy path as well: our 30 Hz timer copy can currently read a surface CA already restarted rendering into. | Medium. Removes a source of half-drawn frames in the existing CPU path; essential if we ever scan an IOSurface directly. (topaz still saw half-drawn frames after 0099 and went to copy-and-flip, so do not rely on it alone.) |
| **0100 double-buffer-kernel-frames** | Two cached contiguous 1080x2400 frames `fFlip[2]`; build in back buffer, `dc cvac`, flip. | Port the idea; frame size becomes 1080x2246 (`fRowBytes*fHeight`). | replaces our "copy straight into the live FB" | **High**: eliminates tearing/top-down wipe that writing into the scanned framebuffer produces. |
| **0101 real-dcache-flush** | Real `dc civac`/`dc cvac` loops for `flush_dcache`/`clean_dcache` under `ARM64_BOARD_CONFIG_SWEET`. | **Superseded by 0107/0111; do not port this one** (global change, crawl). | - | - |
| **0102 copy-and-flip** | Final topaz design: iOS frames are memcpy'd (cached) into the back buffer, then flipped; console copied under the putc lock. | Core of the recommended design. | replaces CPU nearest-neighbour into WC FB | High (see section 5). |
| **0103 copy-path-back-buffer** | Same for multi-layer frames (dims, apps): compose into back buffer, flip once. Removes the `fBootStride == fRowBytes` restriction. | Our `present()` already loops layers; redirect `dst` to the back buffer (also for `presentScaled`). | direct fit with 0091 | High (same reason as 0100). |
| **0107 local-dcache-clean** | `sweet_dcache_clean(addr,len)` (CTR_EL0 DminLine, `dc cvac`, dsb sy) used only for display/DSI buffers; `flush_dcache`/`clean_dcache` stay no-ops. Brightness work moved to a thread_call. | Port the helper. | - | Required correctness helper. |
| **0111 real-dcache-ops** | Final form: `sweet_dcache_clean` (cvac) and `sweet_dcache_flush` (civac) both implemented in `osfmk/arm/caches.c`, no global change. | Port 0111 (the cleaned-up version of 0107). | - | See section 6 (shared-code correctness). |
| **0114 iphonex-canvas-aligned** | Present iPhone X canvas 1125x2436 again; panel window x rounded down to a multiple of 4 pixels (`& ~3`) so `SRC0_ADDR` is 16-byte aligned (MDP fetch requirement); same rounding in SweetHID touch mapping. | Alignment rule applies to us for crop mode (`sweetfb_scale=0`): `fOffX = ((1125-1080)/2) & ~3 = 20`. Irrelevant for HW scaling when the source is the whole surface (SRC0 = surface base, 16-byte aligned if the surface is). | touch mapping must stay in sync with 0091 | Small; only for crop mode. |

## 2. Backlight / DSI patches (0104, 0105, 0106, 0110)

- Topaz's panel is AMOLED with DCS brightness (`0x51`, DBV 1..0x7ff, 500 nits), DCS `0x28/0x29`, DSI0 command DMA through `ml_io_map(0x05e94000)` (CTRL +0x004, DMA_BASE +0x048, DMA_LEN +0x04c, TRIG_CTRL +0x084, DMA_TRIG +0x090, INT_CTRL +0x110, DMA_CTRL +0x03c bit26 = low power).
- **Poco F1 does not use this.** Our panel `dsi_tianma_fhd_nt36672a_video_display` has `qcom,mdss-dsi-bl-pmic-control-type = "bl_ctrl_wled"` (live.dts line ~21021), bl range 1..0xfff [verified]. Backlight is **PMI8998 WLED** (`qcom,pmi8998-spmi-wled`, `reg = <0xd800 0x100 0xd900 0x100>`, interrupts on SPMI SID 3, `qcom,string-cfg = <3>`) [verified]. Per mainline `qcom-wled.c` (WLED4): ctrl module enable `0xd800+0x46` bit7; per-string brightness is a 16-bit LE value (max 0xFFF) at `0xd900 + 0x57 + 0x10*n` (n = enabled strings) [verified in Linux source, not on the phone]. We already have SPMI access from the battery patches; the DSI DMA code in 0104/0106 should **not** be ported (sending DCS while the video-mode INTF runs is risky, not needed).
- **0105 AppleARMBacklight** is the useful piece and is portable verbatim in structure: CoreBrightness `-[CBDisplayContaineriOS findBacklight]` matches `{IOPropertyMatch: {backlight-control: true}}` and needs a class conforming to AppleARMBacklight; it then sets `brightness-nits` on the service and `IOMFBBrightnessLevel` (16.16 nits) on the framebuffer. Our `setProperties` would map nits -> WLED 0x1..0xFFF (clamp at 0.4 % = 16, per the Linux WLED4 low limit).
- **0110 (opt-in)**: publish the service only with a boot-arg (topaz `sweetbl=1`). Reason: with a backlight service present CoreBrightness enables digital dimming over every frame, which the software renderer cannot afford (<1 fps). Same applies to us; keep it opt-in until we can afford it. **0107's thread_call decoupling** (record level, apply from a thread call) applies to SPMI writes too.
- **0106 display on/off**: AMOLED-specific. For us: on RequestPowerChange off -> WLED level 0 (+ optionally MOD_EN off), on -> restore.
- Priority: low-medium (a working brightness slider is nice but does not affect smoothness; keep disabled by default).

## 3. SDM845 MDP/DPU (MDSS 4.0) register map

Downstream (live.dts `qcom,mdss_mdp@ae00000`) offsets are relative to MDSS `0x0ae00000`; mainline Linux catalog offsets are relative to MDP `0x0ae01000`; both agree. Topaz's `0x05e0xxxx` addresses are the same convention (MDSS base 0x05e00000 + downstream offset), so only the base changes.

| Block | SDM845 physical | Topaz (SM6225) | Tag |
|---|---|---|---|
| MDSS / MDP regs | 0x0ae00000 / MDP 0x0ae01000 | 0x05e00000 / 0x05e01000 | verified |
| CTL_0 (CTL_LAYER LM0 at +0x00, CTL_FLUSH +0x18, CTL_START +0x1c) | **0x0ae02000** (CTL_1 0x0ae02200 ...) | 0x05e02000 | verified (dt `qcom,sde-ctl-off 0x2000`, Linux `ctl_0 0x1000`) |
| SSPP VIG0 | **0x0ae05000** (VIG1 0x0ae07000, VIG2 0x0ae09000, VIG3 0x0ae0b000) | 0x05e05000 | verified |
| SSPP DMA0..3 | 0x0ae25000, 0x0ae27000, 0x0ae29000, 0x0ae2b000 (no scaler) | n/a | verified |
| LM_0 (LM_OUT_SIZE +0x04, BORDER_COLOR +0x08) | 0x0ae45000 (LM_1 0x0ae46000, LM_2 0x0ae47000) | - | verified |
| QSEED3 scaler of VIG pipes | SSPP + **0xa00**, len 0xa0 (CSC at +0x1a00); QSEED3 v1.3 | (VIG has QSEED3-lite on sm6115) | verified (dt `qcom,sde-vig-qseed-off`, Linux `dpu_vig_sblk_qseed3_1_3`) |
| INTF_1 = DSI0 (INTF_0/3 are DP) | **0x0ae6b800** (INTF_2 = DSI1 0x0ae6c000) | 0x05e6b800 | verified (`qcom,sde-intf-type = dp,dsi,dsi,dp`) |
| DSI0 controller | 0x0ae94000 (size 0x400) | 0x05e94000 | verified |
| Splash region | `cont_splash_region@9d400000`, size 0x2400000 (36 MiB) | 0x5c000000 | verified |

SSPP register offsets (same on topaz, verified in `dpu_hw_sspp.c`): SRC_SIZE +0x00, SRC_IMG_SIZE +0x04, SRC_XY +0x08, OUT_SIZE +0x0c, OUT_XY +0x10, **SRC0_ADDR +0x14**, SRC_YSTRIDE0 +0x24, SRC_FORMAT +0x30, SRC_UNPACK_PATTERN +0x34, SRC_OP_MODE +0x38 (bit31 = pixel-extension override), SW_PIX_EXT_* +0x100..+0x128, multirect rect1 at +0x160..+0x18c. Rect0/solo use SRC0_ADDR (+0x14), so topaz's two registers are valid. CTL_FLUSH bits (verified in `dpu_hw_ctl.c`): VIG0 = BIT(0), VIG1 = BIT(1), VIG2 = BIT(2), VIG3 = BIT(18), CTL = BIT(17) -> topaz's `0x20001` is right for VIG0.

**Which pipe does ABL use? [unverified].** I could not determine it offline (no register dump; the live DT only describes the kernel's view). Mixer 0 (LM_0 0x0ae45000) -> INTF_1 is the primary path; VIG0 is the usual first pipe for Qualcomm ABL/UEFI splash and is what topaz saw, but on SDM845 it may be a DMA pipe. Step 0 of any port is a read-only probe at boot (topaz did exactly this with `fBootSrc`):
1. read `SRC0_ADDR` (+0x14), `YSTRIDE0` (+0x24), SRC_SIZE, OUT_SIZE, SRC_FORMAT of all 8 SSPPs (0x0ae05000/07000/09000/0b000/25000/27000/29000/2b000); the one whose SRC0_ADDR is 0x9d400000 (stride 4320 = 1080*4) is ABL's pipe; also dump CTL0 `+0x00..+0x10` (layer->stage mux), LM0 `+0x04` (expect (2246<<16)+1080);
2. read QSEED3 HW_VERSION (`pipe+0xa00+0x00`) and OP_MODE (+0x04) (expect 0 = scaler off);
3. read INTF_1 `0x0ae6b800`: timing, FRAME_COUNT (+0x0ac) twice 1 s apart (expect +60);
4. read apps_smmu S2CR for stream IDs 0x880/0xc80 (the MDSS iommus in sdm845.dtsi) using the existing `sweet_smmu.c`; topaz relied on the display SMMU being bypassed and that the MDP can fetch any physical address below 4 GiB. On SDM845 that is **unverified** (USB needed an explicit context bank in our 0094). If the MDSS SIDs fault for non-splash addresses, keep both buffers inside `cont_splash_region`.

## 4. Where to put the buffers on Poco F1

All xnu-managed RAM is above 4 GiB, but MDP `SRC0_ADDR` is 32-bit. Options, cheapest first:
1. **Use the splash carve-out [verified region, assumed free after handoff]**: `0x9d400000 + 0x2400000`. One 1080x2246x4 frame = 9,703,680 B (0x940800). Three frames fit: ABL FB at 0x9d400000, back buffers at 0x9de00000 and 0x9e800000 (end 0x9f140800 < 0x9f800000). Map them Normal-NC (the same `kIOMapWriteCombineCache` mapping we already use for the ABL FB; no cache maintenance, only `dsb`). Cost: the copy writes WC instead of cached, but there is no per-pixel gather/volatile store pattern any more, and no `dc cvac`. This needs **no RAM-layout change** and is the recommended first step.
2. Make xnu own a cacheable window below 4 GiB (what topaz's `mkadt --midmem` does): beryllium's low bank 0x80000000-0xffffffff is full of carve-outs; the only plausible window is just above them (rmtfs ~0xfde01000...). Gains cached memcpy + `dc cvac` (faster stores), costs an ADT/shim change and risk. Defer.
3. Keep surfaces anywhere and rely on an MDSS SMMU context bank (like sweet_smmu.c for USB). Large change; not needed.

## 5. Hardware scaling 1125x2436 -> 1037x2246 on SDM845

**Feasible in principle, new work (topaz does not scale; its 0094 crop attempt even went black).** SDM845 VIG pipes have QSEED3 v1.3 at `SSPP+0xa00` [verified]; DMA pipes have no scaler. Mainline Linux scales on SDM845 with **bilinear filter and `lut_flag = 0` (no coefficient LUT upload)** (`_dpu_plane_setup_scaler3`: `y_rgb_filter_cfg = DPU_SCALE_BIL`, `lut_flag = 0`, `blend_cfg = 1`, preload 4/3), so no Qualcomm LUT tables are needed. Proposed programming for VIG0 (all `[unverified on hardware]`, derived from `dpu_hw_sspp.c`/`dpu_hw_util.c`/`dpu_plane.c`):

| Reg (VIG0 = 0x0ae05000) | Value |
|---|---|
| +0x00 SRC_SIZE, +0x04 SRC_IMG_SIZE | height<<16 + width = `(2436<<16) + 1125` |
| +0x08 SRC_XY | 0 |
| +0x0c OUT_SIZE | `(2246<<16)+1037` (stretch mode: width 1080) |
| +0x10 OUT_XY | `21` (y=0) (fit; `(1080-1037)/2`) |
| +0x14 SRC0_ADDR / +0x24 YSTRIDE0 | back-buffer PA (16-byte aligned) / 4500 |
| +0x38 SRC_OP_MODE | `|= BIT(31)` PE override, with +0x100/+0x104/+0x108 (and C3 +0x120..) per `dpu_hw_sspp_setup_pe_config` (ext pixels = 0 left/top; `REQ_PIXELS = (h<<16)|w`) |
| QSEED3 +0xa04 OP_MODE | OR of: `BIT(0)` enable, `(1<<16)` bilinear Y/RGB, `BIT(31)` blend, `BIT(14)` (non-DX format); plus `BIT(10)` and alpha filter `(1<<29)` only if SRC_FORMAT has alpha |
| +0xa10 PHASE_STEP_Y_H, +0xa14 PHASE_STEP_Y_V | `(1<<21)*src/dst`: W `(1125<<21)/1037`, H `(2436<<21)/2246` (both ~1.0848 * 2^21); same values to +0xa18/+0xa1c |
| +0xa90/+0xa94 PHASE_INIT_Y_H/V (qseed3 != 0x1002) | 0 (upstream default) |
| +0xa20 PRELOAD | `4 + (3<<8) + (4<<16) + (3<<24)` |
| +0xa40 SRC_SIZE_Y_RGB_A, +0xa48 DST_SIZE | `(2436<<16)+1125`, `(2246<<16)+1037` |
| then | `dsb sy`; `CTL0+0x18 = 0x20001` (VIG0 | CTL) |

Notes and risks:
- The mixer output (LM0 OUT_SIZE = 1080x2246 from ABL) must not change; bars come from the mixer border color/background (ABL's value; for fit mode verify they are black, otherwise write LM0 BORDER_COLOR at LM+0x08, **unverified**, or keep a black margin by also keeping the CPU clear once as we do today).
- Downscale ratio 1.085, line width 1125 << 2560 limit (`qcom,sde-sspp-linewidth 0xa00`): well inside QSEED3 limits; MDP core clock 300-430 MHz is ample; ~11 MB/frame read at 60 Hz is trivial for bandwidth.
- Quality: bilinear (maybe slightly softer than nearest). A one-pixel-accurate touch map should keep using 0091's formulas (pad 21, ratio 2246/2436); expected deviation < 1 px.
- Failure mode: topaz's SRC_XY experiment gave a black screen. Gate behind `sweetfb_hw=1`, save/restore the whole SSPP+QSEED3 register set (boot values) for fallback and for the panic hook, and keep the CPU path (0091) as default fallback.
- The scaler needs a scan source in <4 GiB (section 4), so the HW-scale path is still "memcpy 1125x2436 IOSurface -> low buffer -> flip". The memcpy is a straight linear copy (~11 MB) instead of 2.3 M gathered pixel stores, i.e. the CPU cost drops from per-pixel gather to a streaming copy.

## 6. Correctness bug in shared (sweet) code that topaz found

`__ARM_COHERENT_IO__` is defined for the SWEET build (`pexpert/pexpert/arm64/apple_arm64_common.h:36`), so in `osfmk/arm/caches.c` `flush_dcache`, `clean_dcache` (and the `*64` variants built on them) are **dsb-only no-ops**. Upstream sweet and our tree call them as if they were real for DMA masters that read DRAM behind the CPU caches:
- `0028`/`0069` UFS (`flush_dcache64`/`clean_dcache64(su.dma_pa+off, len, TRUE)` on `kmem_alloc_contig` memory),
- `0073` USB device DMA, and our `0094-beryllium-usb-guctl1-smmu.patch:167` (`flush_dcache64(l1_pa, L1_SIZE, TRUE)` after writing SMMU level-1 page-table entries that the SMMU walker fetches).
All of these buffers are ordinary cacheable (kmem_alloc_contig). They apparently work (UFS root boots) because small DMA windows happen to be evicted/coherent in practice or the masters are I/O coherent, but nothing guarantees it; the SMMU L1 table in particular has to be visible to a non-snooping walker **[unverified: could be a latent USB-on-beryllium problem]**. Topaz's answer (0111) is the right shape: leave the global no-ops (making them real slowed the whole kernel), add `sweet_dcache_clean` (`dc cvac`) / `sweet_dcache_flush` (`dc civac`) in `osfmk/arm/caches.c`, and call them explicitly from the drivers. Recommend porting 0111 and switching the three call sites above to it (and invalidating before CPU reads of device-written DMA buffers with `sweet_dcache_flush`).

## 7. cpufreq (0094) and console filter (0112)

- **0094**: sets the Gold cluster to the top LUT entry via cpufreq-hw (`freq-domain1 @0xf523000`, LUT +0x110/32 B rows, PERF_STATE +0x920). We already do this for both clusters (our 0093-beryllium-cpufreq-max). Only interesting detail: they walk the LUT until the entry repeats and compute kHz from `src/lval` (19.2 MHz * lval) instead of hardcoding; and a later commit makes the shim set it early and drops the 8 s speed-probe wait. **Nothing to port.**
- **0112 console log filter** (`sweetlog=WORD,WORD`): collects console output by line and draws only lines containing a listed word (panics always drawn, everything still goes to the log ring). 50 lines in `osfmk/console/serial_console.c`. **Cheap, port** if we keep any visible console during bring-up (each console line is drawn and scrolled by the CPU in the ABL FB, which is costly); pairs with 0095. Low priority since `sweetfb_noconsole=1` already exists.

## 8. Modem / Wi-Fi chain (0113-0126), future reference only

Port of MakrSas/topaz-woa to XNU, ~4.5k lines, mostly in `iokit/Kernel/arm/TopazModem.cpp`:
0113 modem DSP (MPSS) boot through TrustZone PAS (init_image/mem_setup/auth_and_reset, SCM calls `0x42000000 | svc<<8 | cmd`), SMEM (`0x46000000`) + SMP2P handshake, IPA power query; 0115 read modem firmware read-only from the `modem_a` FAT16 partition via the sweet UFS driver (extends `sweet_ufs.c` to read other GPT partitions read-only); 0117 hash segment; 0118 GLINK-over-SMEM (items 478/479/480) + QRTR (IPCRTR, HELLO, service list); 0121 host services the modem requires (pd-mapper QMI 0x40, tqftpserv tftp for `/readonly/firmware/image/...`, rmtfs QMI 14 EFS from modemst1/2, fsc, fsg; hyp_assign SCM 0x0C/0x16); 0122 WLFW QMI (0x45) to mission mode (ath10k qmi.c sequence); 0123 apps-SMMU identity context bank for the WLAN stream, copy engines, HTC, WMI TLV, passive scan; 0124 PD restart; 0125 HTT rx ring setup (without it no beacons are received); 0126 kernel API (scan on request, BSS list with IEs). 0119/0120: logging, `sweetfb_console=1` flag.

For beryllium: same architecture (SDM845 + WCN3990 is exactly the ath10k-snoc chip family topaz's code follows; the comments say "WCN3990: 64-bit descriptors"). What changes: all SoC constants (SMEM 0x86000000 [dt], TCSR mutex, APCS GLINK doorbell bit, mpss/pil carve-outs, WLAN MSA region, CE/WCN base 0x18800000, WLAN SMMU stream id, SCM proc id/PAS), modem firmware location (stock `modem` partition of MIUI/LineageOS), `wlanmdsp.mbn`/board data names. Reuse estimate 60-70 % (QMI/QRTR/GLINK/WMI/HTT/HTC logic), plus our `sweet_smmu.c` for the SMMU context. Constraints: no LICENSE in the repo (ask the author / credit before copying code), written against HyperOS firmware tables (`fwtable_all.py` generated extents are device-specific), and it assumes modem started cold and polled. No dependency on rendering; schedule after the display work.

Skipped as out of scope: 0080-0091 (SM6225 CPU topology, ARMv8.0 no-LSE/no-PAN, FT5452 touch, battery gauge; Poco F1 is ARMv8.2 with our own NT36672A/PM8998/PMI8998 code).

## 9. Ranked porting list

| # | Item | Why | Effort | Risk |
|---|---|---|---|---|
| 1 | **Read-only probe patch** (section 3 steps 1-4: SSPP SRC0_ADDR/format/size of all 8 pipes, CTL0, LM0, QSEED3 version, INTF_1 frame counter, SMMU S2CR 0x880/0xc80) | Turns every "unverified" below into verified, zero behaviour change | ~60 lines | none |
| 2 | **Back-buffer + flip** (0100/0102/0103 + 0092 `scanFrom` + 0097 panic hook): copy/compose into a back buffer, then `SRC0_ADDR`/`YSTRIDE0` + `CTL0 +0x18 = 0x20001`; restore boot values (ABL FB) in panic and on power-off. Buffers: `cont_splash_region` frames 2,3 mapped WC (section 4) | Fixes tearing/top-down drawing that writing straight into the live FB causes; no cache maintenance in the WC variant; orthogonal to 0090 (vsync timer just paces flips) | ~150 lines | medium (pipe unverified; keep CPU-into-boot-FB fallback via boot-arg) |
| 3 | **MDP hardware fit-scaling** via QSEED3 (section 5), on top of #2 | Replaces the per-pixel nearest-neighbour gather with a linear copy + free HW downscale; keeps `sweetfb_scale` modes | ~120 lines | medium-high (black screen if misconfigured); gate `sweetfb_hw=1` |
| 4 | **0099 IOSurface in-use hold** (u64 at state page +0x18) | Stops CA drawing into a surface while we copy/scan it; fixes half-drawn frames in the current path too | ~50 lines | low |
| 5 | **0111 scoped `sweet_dcache_clean/flush`** and use it at the UFS/USB/SMMU DMA call sites (section 6) | Latent coherency bug in shared code | ~40 lines | low (do not make the global ops real) |
| 6 | **0095 WC boot FB** for `ARM64_BOARD_CONFIG_SWEET` | Console/boot text no longer crawls | 4 lines | none |
| 7 | **0098 INTF_1 frame counter** as a real vsync/flip-complete reference (and log) | Know when a flip latched; verify the 60 Hz panel | ~25 lines | none |
| 8 | **0112 sweetlog filter** | Debug convenience | ~50 lines | none |
| 9 | **0105/0110 AppleARMBacklight + WLED via SPMI** (opt-in boot-arg, thread_call for the SPMI writes) | Working brightness slider; **must stay off by default** (digital dimming costs <1 fps with software rendering) | ~120 lines | medium |
| 10 | Wi-Fi/modem chain 0113-0126 | Long-term networking | thousands of lines | high effort, license unclear |
| - | **Do not port**: 0101 (global real flush), 0104/0106 DSI DCS brightness/on-off (AMOLED), 0096 software fade, direct IOSurface scanout as the default (0092 alone; topaz abandoned it), console shadow (0097 text hooks) unless we show the console permanently | | | |

## 10. Recommendation for the rendering path (with fit-scaling)

1. Do #1 first and read the numbers; it decides the pipe (VIG0 vs other), shows whether QSEED3 is idle, and tells us if the MDSS SMMU lets the MDP fetch outside the splash region.
2. Adopt topaz's final structure, adapted to our constraints: **IOSurface (cached, CA-rendered) -> kernel linear copy into a back buffer inside `cont_splash_region` (WC, no cache ops) -> flip by SRC0_ADDR/YSTRIDE0 + CTL_FLUSH at the vsync tick**. Keep the ABL FB as frame 0, shown at boot, in panics and as the CPU-fallback target.
3. Then let the **MDP downscale in hardware** (VIG0 QSEED3 bilinear, `sweetfb_hw=1`): the copy source becomes the unscaled 1125x2436 surface, `OUT_SIZE`/`OUT_XY` produce the 1037x2246 fit (or stretch/crop by changing OUT_SIZE/SRC_XY), and 0091's CPU nearest-neighbour stays as the fallback and as the definition of the touch mapping. If QSEED3 turns out unusable (LUT needed, black screen), the fallback is the topaz path as is: scaled-in-CPU into the back buffer, then flip.
4. Do not expect fps miracles from any of this: topaz's published state is still "low frame rate" and CoreAnimation's CPU rendering dominates. The wins here are tear-free frames, a cheaper per-frame copy (so `sweetfb_hz` can rise and 0090's vsync-at-copy-rate can follow it), and no wasted CPU on scaling. The next big step for smoothness is the GPU (topaz plans an Adreno driver; see our `docs/GPU_RESEARCH.md`), plus keeping CoreBrightness digital dimming off.
