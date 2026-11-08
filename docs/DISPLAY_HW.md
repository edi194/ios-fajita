# Poco F1 display: backlight fade, MDP hardware scaling, zero-copy scanout (patches 0126, 0127)

Patch `xnu/patches/0126-beryllium-fb-hw-scaler.patch` (diff against `research/bt125/xnu` = 0001-0125 applied; `git apply --check` verified on a fresh copy; the six touched files compile with `tools/xnu-cc.py` and every new extern resolves in the objects). Patch `xnu/patches/0127-beryllium-fb-zero-copy.patch` (diff against `research/bt126/xnu` = 0001-0126 applied; `git apply --check` verified on a fresh copy; `SweetFramebuffer.cpp`, `SweetSurface.cpp/.h` compile with `tools/xnu-cc.py`, new undefined symbols are `gPhysBase`, `gPhysSize`, `clock_interval_to_absolutetime_interval` (kernel) and the three `sweet_lowpool_*` functions (defined in `SweetSurface.cpp`)) replaces the decline of section 3 with a real low-RAM pool. **Neither patch is booted.** Everything is gated by a boot-arg; every log line starts with `SWEET FB:` (SMMU/SPMI helpers: `SWEET SMMU:` / `SWEET SPMI:`). Files: `iokit/Kernel/arm/SweetFramebuffer.cpp` (AppleCLCD), `SweetSurface.cpp/.h`, `bsd/dev/sweet_spmi.c/.h`, `bsd/dev/sweet_smmu.c`.

Sources used: mainline Linux `qcom-wled.c`, `dpu_hw_util.c` (`dpu_hw_setup_scaler3`), `dpu_hw_sspp.c`, `dpu_plane.c` (`_dpu_plane_setup_scaler3`), `spmi-pmic-arb.c` (v5 channel layout, in `research/linux-src`), `docs/TOPAZ_REVIEW.md` section 3/5, and the boot probe in `logs/boot-0116hw.txt`. The Linux DPU/WLED sources are not in the tree; facts were read from upstream and are tagged below where they were not re-checked on hardware.

Boot-arg summary (Poco F1 only; `sweetfb_blfade` default 1, all others default off):

| boot-arg | meaning |
|---|---|
| `sweetfb_blfade=1/0` | WLED backlight ramp on display off/on (default 1); 0 = pixel fallback |
| `sweetfb_hw=1` | VIG0 QSEED3 scales a canvas-sized back buffer (implies `sweetfb_flip=1`; if `sweetfb_scale` is not given, fit = 1) |
| `sweetfb_hwpe=0` | do not write the SSPP pixel-extension registers (diagnostic variant) |
| `sweetfb_zc=1` | zero-copy scanout from the low pool (needs `sweetfb_hw=1`); implies `sweetfb_smmu=1` |
| `sweetfb_lowpool=<MB>` | size of the low pool in MiB (default 252); starts at the default/ADT/`sweetfb_lowpoolbase` base |
| `sweetfb_lowpoolbase=0x...` | base of the low pool (default `0xb0400000`; 32-bit value, 16 KiB aligned) |
| `sweetfb_lowwc=1` | map the pool write-combined instead of write-back cacheable (diagnostic, no cache maintenance; renderer reads uncached = slow) |
| `sweetfb_zcforce=1` | treat the MDP SMMU as bypass although the probe did not say so (risk: an unmapped fetch resets the SoC) |
| `sweetfb_smmu=1/2` | read-only dump of the MDP SMMU streams 0x880/0xc80: 1 = SMR/S2CR/CBAR/CBA2R, 2 = also the context-bank registers |

## 1. Backlight fade (`sweetfb_blfade`)

Power off (`RequestPowerChange(0)`) used to fade pixels: 6 steps, each rewriting the whole 10 MB write-combined framebuffer with volatile read-modify-write (uncached reads), which painted the screen in bands. Now:

- **WLED** = PMI8998, SPMI SID 3 (`pmi8998.dtsi`: `reg = <0xd800>, <0xd900>`; beryllium: `qcom,num-strings = <2>`). Offsets from Linux `qcom-wled.c` (WLED4), verified in the source, not on the phone:
  - control module `0xd800`: `MOD_EN` +0x46 bit 7 (read only here, never written);
  - sink `0xd900`: `BRIGHT(n)` = +0x57 + 0x10*n, 16-bit little endian, max 0xfff (strings 0, 1 -> 0xd957/0xd958 and 0xd967/0xd968); `SYNC` +0x47: write 0x00 then 0x0f (`GENMASK(max_string_count - 1, 0)`, WLED4 = 4 strings) to latch.
- Start (`blInit`): read both brightness words, MOD_EN and SYNC (log). Armed only if brightness is non-zero and MOD_EN bit 7 is set.
- Off: 12 steps, one per vsync tick (about 200 ms), `level = as_found * pos^2 / 144` (gamma-ish), each step = two 2-byte brightness writes + sync toggle. The values "as found" are re-read at the start of each ramp, so whatever is on the panel is what is restored. On: after the latest frame was presented (`fDirty` consumed) the ramp goes back up, the last step writes the exact bytes read earlier (raw 16-bit, including any upper bits).
- Read-back at steps 11, 1, 0 and 12: a write that does not read back, a refused write, or an SPMI timeout aborts the fade: the original bytes are written back (best effort), `fBlOK` is cleared and the screen goes black through the fallback.
- **Fallback** (`blackout`): one `memset` of ABL's framebuffer plus, when page flipping, a flip back to frame 0 (hardware scaler programming is restored; zero-copy holds released). Used for `sweetfb_blfade=0`, sweet, any SPMI problem. No more pixel fade.
- **SPMI write support** (`sweet_spmi_write`, new): pmic-arb v5 read/write channel `0x0c600000 + 0x10000 * APID` (one 4 KiB page mapped per APID, max 4), `CMD +0x00 = (0<<27 EXT_WRITEL) | (addr&0xff)<<4 | (len-1)`, `WDATA0 +0x10`, `STATUS +0x08` (bit0 done, 0x0e error). Refused unless the APID's owner in the ownership table (cfg `+0x700 + 4*APID`) is EE 0 (`qcom,ee = <0>`), with a one-time log `SWEET SPMI: APID n ... owned by EE m: write refused`. Whitelist: SID 3 only, Poco F1 only, addresses 0xd947 (1 byte), 0xd957/0xd967 (1-2 bytes), 0xd958/0xd968 (1 byte). The read whitelist gained SID 3 peripherals 0xd8/0xd9. `sweet_spmi_init` now takes a lock (battery and framebuffer start from different threads).
- Not done on purpose: the panic hook does not touch the WLED (it would need the SPMI lock). A panic while the display is "off" shows the text on a dark panel.

Expected log lines:

```
SWEET FB: WLED brightness string0 0x0xxx string1 0x0xxx, MOD_EN 0x80, SYNC 0x..
SWEET FB: backlight fade armed: 12 steps, power off ramps WLED down, on restores 0x.../0x... exactly
SWEET FB: display off
SWEET FB: backlight ramp down from 0x.../0x...
SWEET FB: backlight off (0x0000/0x0000)
SWEET FB: display on
SWEET FB: backlight restored (0x.../0x...)
```
Failure signatures: `SWEET SPMI: ... write refused`, `SWEET SPMI: write sid=3 addr=... status ...`, `SWEET FB: WLED string n wrote .., reads ..`, `SWEET FB: backlight fade failed at a step; ... pixel fallback`, `SWEET FB: display off: screen black in one step`.

## 2. MDP hardware scaling (`sweetfb_hw=1`)

Boot probe facts (boot 0116hw): ABL scans VIG0 (`SRC0_ADDR` 0x9d400000, stride 0x10e0, size 0x08c60438 = 1080x2246, format 0x000237ff = alpha-enabled 8888, `SRC_OP_MODE` 0x80000000 = PE override), QSEED3 v0x1003 with OP_MODE 0 on VIG0, `CTL0 layer0 0x01000005` (bit 24 = mixer border out), `LM0 out 0x08c60438`.

Decision (`hwSetup`, pure arithmetic): VIG pipe, QSEED3 version 0x1002/0x1003, `fScale` 1 or 2 (crop has nothing to scale), canvas <= 2560 wide, ratios < 4x. Destination rectangle = exactly what the CPU scaler and the touch mapping use: `dstW = logicalW * num/den`, `dstH` likewise, at (`fPadX`, `fPadY`). Fit @2x (750x1624): 1037x2246 at (21,0); fit @3x (1125x2436): 1037x2246 at (21,0).

Buffers: with the scaler, frames 1 and 2 hold the canvas 1:1, stride `fHwStride = roundup(canvasW*4, 64)` (@2x 3008, @3x 4544; 64-aligned like the IOSurface rows, so the copy is one `memcpy` of `h*stride`), in the splash carve-out spaced by the canvas size: `0x9d400000` (ABL, frame 0), `+10 MiB`, `+21 MiB` (@3x; end +31.6 MiB < +36 MiB). Both are zeroed. `present()` -> `presentCanvas()` copies each layer at its logical rect (no per-pixel math, no `fXMap`).

Register programming (`hwProgram`, once when the first canvas frame is scanned; everything is latched by the CTL flush that `scanAddr` does next; VIG0 = MDP + 0x5000, QSEED3 = VIG0 + 0xa00):

| reg | value | source |
|---|---|---|
| VIG0 +0x00 SRC_SIZE, +0x04 SRC_IMG_SIZE | `(canvasH<<16) | canvasW` | dpu_hw_setup_rects_impl; IMG_SIZE per MDP5 (unverified on SDE, harmless) |
| +0x08 SRC_XY | 0 | |
| +0x0c OUT_SIZE / +0x10 OUT_XY | `(dstH<<16)|dstW` / `(dstY<<16)|dstX` | |
| +0x100/0x104/0x108 PE C0, +0x110/0x114/0x118 C1C2, +0x120/0x124/0x128 C3 | LR = TB = 0, REQ_PIXELS = `(h<<16)|w` of the source | dpu_hw_sspp_setup_pe_config with zero extension; skipped with `sweetfb_hwpe=0` |
| QSEED3 +0x90/0x94/0x98/0x9c PHASE_INIT_Y_H/Y_V/UV_H/UV_V (version 0x1002: +0x0c) | 0 | |
| +0x10/0x14 PHASE_STEP_Y_H/V, +0x18/0x1c UV_H/V | `(src << 21) / dst` per axis (24 bit), same on the UV set (alpha channel) | `_dpu_plane_setup_scaler3` mult_frac(1<<21, src, dst) |
| +0x20 PRELOAD | `4 | 3<<8 | 4<<16 | 3<<24` | DPU_QSEED3_DEFAULT_PRELOAD_H/V |
| +0x40 SRC_SIZE_Y_RGB_A, +0x44 SRC_SIZE_UV, +0x48 DST_SIZE | src, src, dst (`(h<<16)|w`) | |
| +0x04 OP_MODE (last) | BIT0 enable, ~~1<<16 Y/RGB filter bilinear~~ (WRONG, see 0129: bilinear is field 3, so 3<<16), BIT14 non-DX, BIT31 blend_cfg; if SRC_FORMAT bit 8 (alpha, set on ABL's format): BIT10 + alpha filter bilinear (1<<29; 1<<30 on v0x1002) | `dpu_hw_setup_scaler3`; no detail enhancer, no LUT upload (lut_flag 0), dir_en 0 |
| SRC0_ADDR +0x14, YSTRIDE0 +0x24 | back buffer PA, `fHwStride` | |
| LM0 +0x45008 / +0x45010 BORDER_COLOR | 0, only when the fit leaves margins and the boot border colour is non-zero (`border fix`) | `dpu_hw_lm.c` LM_BORDER_COLOR_0/1 (from memory, unverified) |
| CTL0 +0x2018 FLUSH | `VIG0 BIT0 | CTL BIT17` (| `BIT6` LM_0 with the first flush after a border change) | `dpu_hw_ctl.c` |

LM0 `OUT_SIZE` stays 1080x2246; the margins of a fit come from the mixer border (CTL0 layer0 bit 24 is set by ABL).

Panic and off: before anything is written, `flipSetup` records the boot values of every register above (about 32 entries) plus `SRC0_ADDR`/`YSTRIDE0` in a table; `sweet_fb_panic_hook` replays it (plain MMIO, no locks, address/stride last) and flushes (`BIT6` included when the border was changed), so ABL's frame is scanned 1:1 with the scaler off. The blackout path does the same (`scanTo(0)` restores the geometry when the scaler was on). `waitLatch` waits on the exact flush bits of the last flush.

Expected log lines:

```
SWEET MDP: VIG0 img 0x.. xy 0x.. outxy 0x.. pe c0 .. c12 .. c3 ..        (new probe line, boot values)
SWEET MDP: CTL0 layer0 0x01000005 ... LM0 out 0x08c60438 border 0x........ 0x........
SWEET FB: hw scaler: canvas 750x1624 (stride 3008) -> 1037x2246 at 21,0 in the 1080x2246 panel, phase step 0x... , qseed3 v0x1003, PE regs written, border fix no
SWEET FB: page flipping on VIG0: frames 0x9d400000 0x9de00000 0x9e800000 (... bytes each back buffer, 32 restore regs), hardware scaler
SWEET FB: hw scaler programmed: src 750x1624 dst 1037x2246 at 21,0, qseed3 op 0xa0014401 steps 0x.../0x... (alpha)
```
(op = `BIT0|BIT10|BIT14|1<<16|BIT29|BIT31` = 0xa0014401 with alpha, 0x80014001 without.) Declines: `SWEET FB: hw scaler: ... CPU path / CPU scaling`.

Things that can go wrong (and what the log shows): black screen = something in the scaler/PE programming (try `sweetfb_hwpe=0`; compare the probe line's PE regs); picture shifted/garbled = stride or PE; margins not black = border colour; tearing = latch (`did not latch` line). A panic or reboot restores the unscaled boot frame.

## 3. Zero-copy scanout (`sweetfb_zc=1`, requires `sweetfb_hw=1`) - patches 0126 (gate) + 0127 (low pool)

**Why it needs a pool.** All RAM xnu owns is above 4 GiB (`0x1_0000_0000 + 0xfcc00000`, NOTES), `SRC0_ADDR` is a 32-bit register, and the MDP's SMMU streams (`iommus = <&apps_smmu 0x880 0x8>, <&apps_smmu 0xc80 0x8>`, `qcom,iommu-earlymap`) are either in bypass (IOVA = PA) or translated by ABL's context bank (set up for the splash region only). Patch 0126 therefore declined every frame. Patch 0127 gives xnu **a window of the low DDR bank it does not manage**, the "SWEET low pool", and allocates the full-screen IOSurfaces from it. An SMMU remap (context bank for the MDP SIDs, per-frame IOVA window) stays out of scope: switching a scanning stream live is the risky part.

### 3.1 Pool layout and safety analysis of the window

Live DT (`dtb/beryllium/live.dts`): `/memory` = `<0x80000000 0xc0000000>, <0x1_40000000 0xbd4a0000>`, i.e. bank 1 is 0x80000000-0x140000000 (3 GiB, crosses 4 GiB; the part below 4 GiB is the "low bank") and bank 2 starts at 0x1_40000000. xnu's RAM is `0x1_00000000 + 0xfcc00000` (ADT `/chosen dram-base/dram-size`, handed over by `tools/mkpayload.py` -> shim -> `boot_args`).

Every fixed `/reserved-memory` node (reg values; two node names in the DT disagree with their reg, the reg wins):

| range | node | users in our tree |
|---|---|---|
| 0x85700000-0x85d00000 | hyp | - |
| 0x85d00000-0x85f00000 | xbl | - |
| 0x85fc0000-0x85fe0000, 0x85fe0000-0x86000000 | removed, cmd-db | RPMh cmd-db read (`sweet_rpmh.c`) |
| 0x86000000-0x86200000 | smem | planned WiFi/BT work |
| 0x86200000-0x8a900000 | removed (TZ) | - |
| 0x8ab00000-0x8bf00000 | qseecom | - |
| 0x8bf00000-0x8c400000 | camera | - |
| 0x8c400000-0x8c410000, 0x8c410000-0x8c415000 | ips_fw, ipa_gsi | - |
| **0x8c415000-0x8c417000** | gpu zap | `sweet_a630_pas.c` ZAP_REGION_PA (GMU/GPU buffers are ordinary kernel allocations) |
| 0x8c500000-0x8e300000 | adsp | - |
| 0x8e300000-0x8e400000 | wlan_fw | planned WiFi |
| 0x8e400000-0x95c00000 | modem (MPSS) | planned (MPSS 0x8e400000/0x7800000) |
| 0x95c00000-0x96100000, 0x96100000-0x96900000 | video, cdsp | - |
| 0x96900000-0x96b00000 | mba | planned |
| 0x96b00000-0x97f00000, 0x97f00000-0x98000000 | slpi, pil_spss | - |
| **0x9d400000-0x9f800000** | cont_splash (36 MiB) | ABL framebuffer 0x9d400000; flip back buffers at 0x9de00000 and 0x9e800000 (@2x) / 0x9e900000 (@3x), `flipSetup` |
| 0xaf000000-0xb0000000 | ramdump_fb | - |
| 0xb0000000-0xb0400000 | ramoops | nothing in our tree touches it |

Not fixed (no `reg`, Linux places them at its own boot, top-down below 4 GiB, so they exist only while Linux runs): `adsp_region` 16 MiB, `cdsp_region` 4 MiB, `qseecom_ta_region` 16 MiB, `secure_sp_region` 8 MiB, `secure_display_region` 92 MiB, `mem_dump_region` 36 MiB, `linux,cma` 768 MiB (all `reusable`, 940 MiB in total, which would sit roughly in 0xc5400000-0xffffffff, estimate) and the `qcom,rmtfs_sharedmem` (2 MiB with a guard, ~0xfde01000 per NOTES). With Linux gone they are plain unused RAM; TZ/hyp only protect them when a Linux driver asks.

Other users of low memory: the shim image and the Android boot image (kernel offset 0x8000, ramdisk 0x1000000, dtb 0x1f00000 from the DDR base, `shim/build.sh`) sit in the first 32 MiB of DDR (below every region above; the shim maps everything Device except its own image, `shim/mmu.c`), xnu's early boot maps one 32 MiB block at 0x9c000000 (splash), `sweet_smmu.c` identity-maps DRAM for USB (separate context bank). The planned WiFi/BT firmware pool (`docs/WIFI_BT_PLAN.md` 0113: "above 0xb0400000, e.g. 0xe0000000") lies above the window chosen here.

**Default window: 0xb0400000 .. 0xc0000000 = 252 MiB** (16128 pages of 16 KiB). It starts at the end of the last fixed carve-out (ramoops), ends at the 3 GiB mark (leaving the CMA/dynamic pools and the rmtfs area untouched, ~1.1 GiB above it for WiFi/BT) and lies in the same low bank where sweet's xnu ran from 0xb0000000 on hardware. First and last page of the pool are guard pages that are never handed out (a cacheable mapping can be prefetched/speculated into the page next to it; the neighbours are ramoops and CMA RAM, not firmware). Memory is *assumed* free: the DT has no record of TZ/hyp-owned RAM that is not in `/reserved-memory`, so the first touch (the `bzero` of the first pooled surface, early in backboardd's start) is the test; an instant SoC reset there means the window is protected.

**Not part of xnu's RAM**: xnu's RAM is the ADT window `0x1_00000000 + 0xfcc00000`; the pool is below 4 GiB, so the VM never sees its pages, no page-table entries cover it (only the mapping we create) and `pmap_cache_attributes` treats it as I/O unless a mapping says otherwise. Nothing else hands it out: `mkadt.py` places the kernel above 4 GiB (the non-highmem fallback `mem` window 0x9f800000-0xaf000000 ends below the pool, `mkadt.py --lowpool` refuses a pool that overlaps the kernel RAM), `mkpayload.py`/the shim take base and size from the ADT, the ramdisk is inside the kernel's RAM, and the shim's own addresses are all in the first 32 MiB of DDR.

**Configuration** (priority boot-arg > ADT > default): ADT `/arm-io/disp0` property `sweet-lowpool` = `<u64 base, u64 size>` (`tools/mkadt.py ... --lowpool 0xb0400000:0xfc00000`, host-side checks: beryllium only, 16 KiB aligned, inside 0x9f800000-0xfd000000, no overlap with the kernel RAM); `sweetfb_lowpoolbase=0x...`; `sweetfb_lowpool=<MB>`. The kernel validates the result (`sweet_lowpool_validate`) and **refuses the pool, logs the reason and copies frames as before** if: base/size not 16 KiB aligned or under 4 MiB; outside 0x9f800000..0xfd000000 (end of the splash carve-out .. just below rmtfs); overlapping any of the fixed regions in the table above (hard-coded copy of the live DT list); overlapping the splash range passed by `AppleCLCD` (`fPhys + 0x2400000`); overlapping xnu's own RAM (`gPhysBase`, `gPhysSize`). A different window, e.g. `sweetfb_lowpoolbase=0x9f800000 sweetfb_lowpool=240` (the gap between the splash and ramdump_fb; the pre-highmem beryllium layout in `mkadt.py` gave xnu that range as RAM, not verified on the phone) is accepted if it passes.

### 3.2 Allocator and mapping

- **Allocator** (`SweetSurface.cpp`, `sweet_lowpool_alloc/free`): per-page table `until[]` (0 free, ~0 in use, else the time the page may be reused), first fit over runs of pages, serialized by the surface lock, O(pages) per allocation (rare). **Cooling**: a freed block is not reusable for 100 ms (6 vsyncs). A surface is only freed after every client mapping is gone (`SweetSurfaceRef` drops its mappings before its reference) and the framebuffer holds a reference on every surface it scans until a later frame has latched (section 3.4), so the pool block of a released surface cannot be rewritten under the MDP; the cooling covers the one case the reference cannot (`blackout` waits at most 25 ms for the latch).
- **Eligibility** (`sweet_surface_try_pool`, at IOSurface create): pixel format `BGRA` (0x42475241, what backboardd's 1125x2436 surfaces use, `logs/boot-0116hw.txt`), 4 bytes per element, 1x1 elements, no planes, width >= canvas width and height >= canvas height, row stride a multiple of 64 and <= 0xffff (the stride register is 16 bit), offset a multiple of 64. Contiguous by construction; zeroed. Wrapped client memory (`IOSurfaceAddress`) is never pooled. Pool full or not eligible: the normal `IOBufferMemoryDescriptor` as before (`SWEET SURF: low pool full ...` x4, counted).
- **Mapping**: `IOMemoryDescriptor::withPhysicalAddress(pa, allocSize)`, the same mechanism as the splash surface, so the client mapping path (`createMappingInTask(fTask, kIOMapAnywhere | mapCache)`) is untouched; `SweetSurface::kernelAddress` maps with `mapCache` for pooled surfaces. **Cacheable write-back** (`kIOMapCopybackCache`) for the kernel and every client, because the CPU renderer draws into these surfaces and write-combined memory has uncached reads (blending, the whole reason for 0093's cached buffers in ios-topaz); the physical range is not managed (`pa_valid` false), and `pmap_enter_options` for such pages takes the WIMG bits from the mapping (`wimg_bits = (pmap_cache_attributes & ~VM_WIMG_MASK) | (flags & VM_WIMG_MASK)`), so the explicit cache mode wins over the default I/O attribute; the kernel and all clients get the same attribute (one memory object, no mismatched aliases). No other cacheable alias exists (the shim maps everything Device, xnu has no direct map of this range). `sweetfb_lowwc=1` selects write-combined instead (no cache maintenance, slow renderer), the fallback if a write-back device mapping misbehaves on hardware.
- **Cache maintenance** (`sweet_dcache_clean_va`): this build is `__ARM_COHERENT_IO__` (`flush_dcache64`/`clean_dcache64` are bare `dsb sy`), so the framebuffer cleans by hand: `dc cvac` over `offset .. last row` of the canvas, `dsb sy` before and after, then the `SRC0_ADDR`/stride writes and the CTL flush. `cvac` rather than 0126's `sweet_dma_sync_va` (`civac`): the lines stay valid, so CoreAnimation's next partial redraw of the same surface still hits the cache. Performance (**estimates, not measured**): the copy path moves 10.7 MiB through write-combined stores every presented frame (about 1-2 GB/s -> 5-10 ms of one A75 at @3x, 2.2 MiB less at @2x); zero-copy replaces that by cleaning 175k lines (@3x), mostly clean ones (a few ms, a fraction of the traffic), and removes the second buffer.

### 3.3 Present path

`present()` -> `zcPresent` when `fZc`: exactly one enabled layer, the surface looked up by id, `fZcOK` (SMMU streams in bypass, or `sweetfb_zcforce=1`), `pooled`, surface >= canvas, source rect origin (0,0), destination (0,0), size == canvas (the QSEED3 programming is the one of 0126: canvas -> panel rectangle), block long enough and entirely below 4 GiB, 64-byte aligned. Then: clean (cacheable) or `dsb`, `sweet_hold(s, true)` (0099 in-use count, state page +0x18; CoreAnimation will not draw into it), the surface is kept referenced in `fZcHeld[]`, `scanAddr(poolPA + offset, bytesPerRow, true)` (hardware scaler programmed on first use, address/stride, CTL flush) and the copy is skipped. `zcPoll` (every vsync tick, and before a new zero-copy frame) releases older held surfaces once `CTL_FLUSH & fLastFlush` is clear, i.e. the MDP has latched the newest frame (0097/`waitLatch` semantics); if a copied frame replaced the pooled one (`scanTo` clears `fZcFront`) the pooled surface is released after that frame latched too. At most 4 are held; a fifth waits for the latch, else the frame is copied. Anything else takes 0126's copy path.

Everything not zero-copy is unchanged: panic hook (`sweet_fb_panic_hook` restores ABL's frame and scaler registers; pooled memory is not touched), power-off fade (WLED ramp, or `blackout`: `scanTo(0)`, `waitLatch`, `zcReleaseAll`), back-buffer copies, touch mapping.

### 3.4 Logs

```
SWEET SMMU: probe sid 0x880: ...                                     (unchanged, section 3 of 0126)
SWEET FB: MDP SMMU streams 0x880 -> 1, 0xc80 -> 1 (1 bypass, 2 translate, ...)
SWEET SURF: low pool (default|ADT|boot-arg) 0xb0400000..0xc0000000, 252 MiB, 16128 pages, mapped write-back cacheable; BGRA surfaces >= 750x1624 go here
SWEET FB: zero-copy scanout armed: canvas 750x1624 BGRA surfaces live in the low pool and are scanned in place (cacheable: cleaned before every scan)
SWEET SURF: surface 750x1624 bpr N (M bytes) in the low pool at 0x... (n/16128 pages used)     (first 4 only)
SWEET FB: first zero-copy scanout: surface N at 0x... stride N (750x1624 canvas, no copy)
SWEET FB: zero-copy counters: 256 zc frames, 0 copied frames, low pool 912/16128 pages used, 3 surfaces pooled, 0 fell back to normal memory   (every 256 presented frames, and at display off)
SWEET FB: zero-copy declined (first for this reason: surface N): <reason>; such frames are copied              (once per reason)
```
Refusals / fallbacks: `SWEET SURF: low pool 0x... refused: overlaps <name> ...`, `... outside 0x9f800000..0xfd000000`, `SWEET FB: zero-copy off: no usable low pool`, `SWEET FB: zero-copy scanout armed, but the MDP SMMU is NOT verified bypass: low pool not enabled, every frame takes the copy path`, `SWEET SURF: low pool full for N bytes (a/b pages used); this surface takes normal memory`. Decline reasons: no layer in the swap, several layers, MDP SMMU streams not verified as bypass, surface not in the low pool, smaller than the canvas, layer is not the whole canvas, pool block too short/above 4 GiB/unaligned, four earlier frames still waiting for their latch, no kernel mapping. Reading the counters: a healthy GUI shows mostly zc frames; mostly copied frames with "not in the low pool" means the surfaces were not BGRA/64-byte stride/canvas sized (compare the `SWEET SURF: ... create id` lines).

## 4. Test order

1. **Baseline** (current boot-args, e.g. `sweetfb_flip=1 sweetfb_scale=1`): note the MDP probe lines (new `img/xy/pe` and `border` fields are boot values, keep them).
2. **blfade**: add nothing (default 1). Boot, power button: expect the WLED lines, a ~200 ms ramp, no bands; wake: backlight returns to the same level; check the `backlight restored` line shows the same two words as `backlight ramp down from`. Then `sweetfb_blfade=0` once: screen goes black in one step, no bands. Watch for `write refused` / `reads` mismatch lines (EE ownership or hypervisor).
3. **`sweetfb_hw=1` at @2x** (750x1624 ADT, `sweetfb_scale` unset or 1): expect the `hw scaler:` and `programmed` lines, a 1037-wide picture with black bars, cheaper present. Compare the 21 px bars and touch alignment (HID uses the same pad/ratio). On a black screen retry with `sweetfb_hwpe=0`; panic/reboot restores ABL's frame. Also try `sweetfb_scale=2` (stretch).
4. **`sweetfb_hw=1` at @3x** (1125x2436 ADT, e.g. `beryllium-hi-3x.adt`): same checks; this is the 11 MB buffers case (+10/+21 MiB frames, line width 1125 < 2560).
5. **`sweetfb_smmu=1`** (alone, no zero-copy): read the SMR/S2CR lines. Then `sweetfb_smmu=2` only if level 1 was fine and you want the bank registers.
6. **`sweetfb_hw=1 sweetfb_zc=1`**: read the two SMMU lines first. If both streams are bypass, expect the `low pool ...` line (check the window line against the section 3.1 table), `armed`, the first pooled surface, then `first zero-copy scanout` once backboardd presents, and the counters. The picture must be identical to step 3/4 (same bars, same scaling). Only the first frame after the pool is armed is a risk of its own: an instant reset right after `low pool ... go here` (before any `in the low pool at` line) = the window is protected by TZ/hyp (try `sweetfb_lowpoolbase=0x9f800000 sweetfb_lowpool=240` once). A black/garbled picture, a flush that never latches or a hang right after `first zero-copy scanout` = the MDP cannot fetch from the pool (SMMU translating, `sweetfb_zcforce` used, or the stride) -> back to step 3. If the SMMU lines say translate, zero-copy stays off with the `NOT verified bypass` line (that is the expected, safe outcome; `sweetfb_zcforce=1` is a deliberate one-shot experiment).
7. **Variants**: `sweetfb_lowwc=1` (write-combined pool: if the write-back device mapping misbehaves, e.g. panics in the pmap or shows stale rows, the picture still has to be right but the UI will crawl); `sweetfb_lowpool=64` (small pool: watch `low pool full` and the fallback counter; frames must keep flowing through the copy path); toggle the display off and on (counters line at display off, the zero-copy frame comes back after wake); trigger a panic (the console must show, boot frame restored). Tearing / half-drawn frames (ios-topaz saw them when scanning CoreAnimation surfaces in place, even with the 0099 in-use count) would show as rows from the next frame at the top of the screen: if so, capture `SWEET FB: zero-copy counters` and fall back to the copy path (drop `sweetfb_zc`); the next lever is a per-frame "was this surface in use when CA drew" check, not a bigger pool.

Reverts: `sweetfb_hw` / `sweetfb_zc` / `sweetfb_smmu` / `sweetfb_lowpool*` / `sweetfb_zcforce` / `sweetfb_lowwc` are absent by default; `sweetfb_blfade=0` disables the only default-on part. Risks not testable offline: whether the window 0xb0400000-0xc0000000 is free of TZ/hyp protection, write-back mapping of a non-managed range through `IOMemoryDescriptor` (by analysis of `pmap_enter_options`, same path as the write-combined splash mapping), MDP fetch from outside ABL's mapping, half-drawn frames when scanning CoreAnimation's own surfaces, QSEED3 register semantics (bilinear, alpha bits, PE registers), LM border write (BIT6 flush), EE ownership of the WLED APIDs, and the read of the ABL-owned context banks at `sweetfb_smmu=2`.


## 5. Direct scanout at 60 Hz (`sweetfb_direct=1`) - patches 0210, 0211, 0212

**Not booted.** Compile-checked with `tools/xnu-cc.py` against the 11215 CI buildtree. The pieces already existed (0126 VIG0/QSEED3 canvas scaler, 0127 low-pool zero-copy); these patches measure them, make them the default shape of a 60 Hz GPU path and remove the CPU work that is no longer needed.

| boot-arg | meaning |
|---|---|
| `sweetfb_direct=1` (default 0) | implies `sweetfb_hw=1`, page flipping and `sweetfb_zc=1`; a swap is scanned in place as soon as it arrives (below). Any frame that cannot be scanned is copied, per frame, at the `sweetfb_hz` rate. `sweetfb_vsync=1` is ignored (the vsync timer stays at 60 Hz) |
| `sweetfb_hz=60` | 60 = copy (fallback) frames every vsync tick; with `sweetfb_direct=0` this is the copy path at 60 Hz |
| `sweetfb_zcclean=0/1/2/3` | cache clean of a scanned surface: 0 never, 1 always (the default everywhere since 0216, BO_SYNC of scanned GPU surfaces is the full clean+invalidate again), 2 only frames the GPU did not announce through BO_SYNC (0212's old direct default; unsafe, see 5.4b), 3 "tracked": clean unless the frame is a GPU frame and no write-unlock (`IOSurfaceUnlock` without ReadOnly) of the surface came since the last scan |
| `sweetfb_swapsync=0` | direct mode: answer SwapWait at once like before 0216 (kill switch of the honest swap completion, 5.4b) |
| `sweetfb_vsyncalign=0` | direct mode: vsync timer free running at 16667 us with `now` as timestamp like before 0216 (the alignment needs swapsync) |
| `sweetfb_statlog=N` | seconds between `SWEET FB: stats ...` log lines (default 10, 0 = sysctl only) |

### 5.1 Design

1. `swap()` (IOMFB SwapEnd) records the frame as before (holds the surfaces in use, counts `swaps`, counts `coalesced` when it replaces a frame that never reached the panel) and, with `fEarly` (zero-copy armed and the MDP SMMU streams verified bypass), arms `fSwapTimer`.
2. `swapFired` runs on the framebuffer work loop (same loop as the vsync timer, so scan state has one owner and needs no new lock). It takes the pending frame and calls `zcPresent`: one full-canvas layer in a low-pool surface -> `scanAddr` = write `SRC0_ADDR`/`YSTRIDE0` of VIG0, then `CTL0 FLUSH`; the MDP latches both at its next panel vsync. If `zcPresent` declines (several layers, surface not pooled, pool full, SMMU not bypass, 4 frames still waiting for a latch) the frame goes back to pending unless a newer swap arrived, and the vsync tick copies it exactly as before (per frame fallback; nothing about the pipe setup changes for the copy: `scanTo`).
3. No 30 Hz throttle on that path: it runs once per swap, i.e. at the rate backboardd presents (display link = the 16667 us vsync timer). Pending-latch bookkeeping is unchanged: the in-use hold (state page +0x18) and the reference of every scanned surface last until the MDP latched a later frame (`zcPoll`), so CoreAnimation/the GPU render into another surface of its pool and the pool cannot recycle the one on the panel.
4. Surfaces: backboardd's 1125x2436 BGRA IOSurfaces are created by our IOSurface stand-in; `sweet_surface_try_pool` (0127) already puts every canvas-sized BGRA surface with a 64-byte row stride (4544 B at @3x) into the contiguous low pool (below 4 GiB, `SRC0_ADDR` is 32 bit). The GPU blit (patch 0182 SURFACE_BO) maps exactly those pages.
5. Crop/scale: the pipe is programmed once (`hwProgram`) with SRC 1125x2436 -> 1037x2246 at x=21 (`sweetfb_scale=1` fit, aspect kept, black border from the mixer) through the QSEED3 scaler; that is the same rectangle the CPU scaler and touch mapping use, so direct and copy frames are pixel-compatible.

### 5.2 MDP registers (offsets from 0x0ae00000; reimplemented from the Linux sources, not copied; the register names are from `dpu_hw_sspp.c`, `dpu_hw_util.c`, `dpu_hw_ctl.c` of Linux drivers/gpu/drm/msm/disp/dpu1 and the older `mdp5_plane.c`/`mdp5_ctl.c` of disp/mdp5; offsets recalled from those files, not re-checked against hardware)

| register | use | Linux counterpart |
|---|---|---|
| VIG0 `+0x5000`: `SRC_SIZE` 0x00, `SRC_XY` 0x08, `OUT_SIZE` 0x0c, `OUT_XY` 0x10 | once: canvas -> panel rectangle | `dpu_hw_sspp_setup_rects` |
| VIG0 `SRC0_ADDR` 0x14, `SRC_YSTRIDE0` 0x24 | **per frame**: physical address (offset included) and stride of the swapped surface | `dpu_hw_sspp_setup_sourceaddress` (stride in `dpu_hw_sspp_setup_rects`); mdp5 `REG_MDP5_PIPE_SRC0_ADDR`/`SRC_STRIDE_A` |
| VIG0 `PE` 0x100..0x128 | once, zero extension, REQ_PIXELS = source size | `dpu_hw_sspp_setup_pe_config` |
| VIG0 `+0xa00` QSEED3: `OP_MODE` 0x04, `PHASE_STEP_Y_H/V` 0x10/0x14, `PRELOAD` 0x20, `SRC_SIZE_Y_RGB_A` 0x40, `DST_SIZE` 0x48, `PHASE_INIT` 0x90.. | once, bilinear (0129) | `dpu_hw_setup_scaler3`, `_dpu_plane_setup_scaler3` |
| `CTL0 +0x2000`, `FLUSH` +0x18: VIG0 bit 0 | CTL bit 17, per frame, after the address writes | `dpu_hw_ctl_update_pending_flush_sspp`, `dpu_hw_ctl_trigger_flush` |

Flip on vsync: in video mode the timing generator free-runs and the flush bits are consumed at the next frame start, so writing address + FLUSH from the swap path is the flip; the "latched" state is the flush bits reading back 0 (polled, `zcPoll` per tick and `waitLatch` before a buffer is reused, the same polling `sweetfb_vsync` mode used). A vsync interrupt (INTF vsync, `dpu_hw_intr`) is not needed for correctness and not wired. `scan_replaced` counts frames whose address was overwritten before the previous one was latched (never shown).

Pipe choice: VIG0 stays (the only pipe with QSEED3, and ABL already scans it). A DMA pipe cannot scale; it would only be an option for a canvas equal to the panel (the @3x surface is wider, so no).

### 5.3 SMMU and contiguity

Live DT (`dtb/beryllium/live.dts`): mdss `iommus = <&apps_smmu 0x880 0x8>, <&apps_smmu 0xc80 0x8>` (`qcom,iommu-earlymap`, two streams, mask 8). The question is whether ABL left them in bypass or in a translating context bank that only maps the splash region. `sweet_smmu_probe_sid` (read-only SMR/S2CR scan, boot-arg path of 0126/0127) answers it at boot; the result is in the log (`MDP SMMU streams 0x880 -> N, 0xc80 -> N`) and in `kern.sweet_fb` (`smmu=bypass|translate-or-unknown|untested`). Direct scanout only arms when both are bypass (IOVA = PA); otherwise `mode=copy` and every frame is copied (the safe outcome; `sweetfb_zcforce=1` stays a one-shot experiment). A translated MDP would need a context-bank mapping of the pool (per-frame IOVA window): not implemented, switching a live scanning stream is the risky part. Contiguity is by construction (pool block), no IOMMU scatter-gather.

### 5.4 Cache coherence (0212)

* GPU side: the A630 SMMU context (`MAIR0_CB`, PTE attr 0) maps non-cacheable and the GPU's own caches are flushed by the fence/CACHE_FLUSH events of the submit; the GPU writes DRAM without snooping the CPU.
* MDP side: reads DRAM, never the CPU caches.
* So the only CPU cache hazard is a **dirty CPU line** that is evicted later over a GPU-written frame (or a stale line the CPU later reads). 0212 removes that hazard once, at allocation: after the zero fill of a pool surface the whole block is cleaned+invalidated (`dc civac`, one time per surface, ~11 MB).
* BO_SYNC (`SweetAdrenoUserClient::boSync`, 0182: clean+invalidate of the whole surface after every blit, an 11 MB walk per frame) now only counts the GPU write for a pool surface that has already been scanned in place and returns; the first blit of each surface still does the full sync. `sweetfb_zcclean=1` restores the old behaviour.
* The framebuffer's per-frame `dc cvac` over the canvas (0127) is skipped when the GPU wrote the surface since the last scan (`gpuBlits != gpuBlitsSeen`), and still done for frames nobody announced (CPU-drawn CoreAnimation, mode 2). `kern.sweet_fb` shows `cleans` / `clean_skips` / `clean_us`.
* Cost of this choice: a CPU reader of a scanned surface (a screenshot taken through the CPU mapping) can see stale lines. The display path itself does not read through the CPU.

#### Review of the copy path (0215, 2026-10-23)

* **Copy mode reads through the CPU.** `present()` copies `s->kernelAddress()` with `memcpy` (and `presentScaled`/`presentCanvas` read the same way). For a pool surface that mapping is write-back. After 0212 a BO_SYNC of a scanned pool surface is a no-op, so nothing invalidated the lines the CPU still held when a frame the GPU wrote went through the copy path (the fallback taken whenever `zcPresent` declines: several layers, odd rectangle, held-surface limit). That read stale data. 0215 invalidates (`dc civac` over the block, once per announced GPU write: `gpuBlits != gpuBlitsSeen`, counted in `cleans`/`clean_us`) before the copy reads. Surfaces that are not pooled are unchanged: kernel buffers map write-combined (uncached reads, nothing stale) and BO_SYNC for them is still the real clean+invalidate; wrapped surfaces are only read by the GPU.
* **Tearing: not handled, by design of the interface.** The copy path neither latches nor waits for a GPU fence: the kernel does not know which fence wrote a surface (`gpuBlits` only counts BO_SYNC calls that userland makes after its own fence wait), `sweet_hold` (in-use state page) is taken only for scanned-in-place surfaces and not during a copy, and `waitLatch` waits for the *panel* buffer, not for the GPU. A GPU job of the next frame that writes the same surface while the kernel copies it (5-10 ms) shows a torn frame (old and new rows), never black. So tearing explains partial content, not black bars; black bars/squares need a missing write (see below).
* **Open risk, not changed (mode 2 of `sweetfb_zcclean`, default with direct):** the per-frame `dc cvac` of a scanned surface is skipped when the frame had a GPU write. If CoreAnimation also drew CPU pixels into the same surface in that frame (icons, small layers), those lines stay dirty in the cache, the MDP reads DRAM, and they are missing (or are written back over GPU pixels later). Test with `sweetfb_zcclean=1` (always clean): if the black bars go away, this is the cause and the clean must be made range-aware.

### 5.4b Honest swap completion and vsync, tearing in direct mode (0216, 2026-10-23)

**What backboardd waits on** (disassembly of QuartzCore 22H352 in `research/dsc`): `CA::WindowServer::IOMFBDisplay::can_update_(uint)` calls `swap_wait_timeout` -> `IOMobileFramebufferSwapWait(fb, last swap id, 0x80000001)` (selector 6) before it starts a frame. A return of 0 means "that swap is done"; anything else is retried every 100 us until CoreAnimation's own timeout. `FlipBook::swap_completed` is driven from `IOMFBDisplay::collect_frame_info` (frame-info notification, not sent by this driver). Which surface it renders into is chosen by `IOSurfaceIsInUse` = u64 at +0x18 of the surface's shared state page (confirmed for iOS 18: `_IOSurfaceClientIsInUse` loads `[[client+0x70]+0x18] != 0`), the in-use hold this driver already took from SwapEnd until a later frame latched. And its display link is our vsync notification (type 5: counter, timestamp pairs).

**What was wrong:** selector 6 returned 0 at once, so CoreAnimation started frame N+1 the instant it had sent frame N. With the free-running 60 Hz timer, swaps arrived at any phase against the panel; a frame queued behind a frame that had not latched replaced it (`scan_replaced`) and the pool of 3-4 surfaces ran out of free ones (all held), so the renderer was drawing into a surface that was still being scanned or queued.

**Changes (direct mode only; `fSwapSync`):**
* **Depth (0217, `sweetfb_swapdepth=1|2`, default 2):** hardware showed that waiting for swap N itself to latch serialises the pipeline (swap_wait_us 9-13 ms, 2-7 swaps/s): CoreAnimation cannot render N+1 while N waits for its vsync. Depth 2 allows one frame in flight: SwapWait(N) returns 0 as soon as N is the frame queued for the panel and the frame scanned before it (N-1) has latched; depth 1 is the 0216 behaviour. Surface safety does not come from SwapWait but from the in-use holds (state page +0x18, what `IOSurfaceIsInUse` reads when CoreAnimation picks its next target): a scanned surface stays held from SwapEnd until the frame that replaced it has latched, so while N+1 is drawn both N (queued) and N-1 (on the panel) are held. The swap timer now polls the flush bits every 500 us while a frame is queued (`latchWatch`), which releases the older surface within half a millisecond of the vsync and learns the vsync phase without any caller waiting.
* SwapWait waits (polls the CTL flush bits every 250 us, at most 1.5 frames) until the swap is complete: its frame was **latched** (flush bits cleared at the panel vsync) **and** `zcPoll` has already dropped the in-use holds of the frames it replaced; only then does it return 0, else `kIOReturnTimeout`. Swaps that were replaced before they were scanned complete together with the frame that replaced them. Ids never swapped, the display off, copy mode and `sweetfb_swapsync=0` answer 0 at once. When SwapWait sees the latch it kicks the work loop (`swapFired` now begins with `zcPoll`) so the release happens now and not at the next tick.
* Replaced-before-latch frames (`scan_replaced`) were already released only after the newest frame latched (`zcPoll`); unchanged, and with SwapWait they become rare because CoreAnimation no longer sends a second swap before the first latched.
* Present timing: whenever SwapWait watches the flush bits go from set to clear it records that instant as a real panel vsync; `vsyncFired` (the display-link notification) then sends the latest such vsync projected by whole 16667 us periods as the timestamp and re-arms the timer for the next one (`sweetfb_vsyncalign`, default on). The timer thus follows the panel's phase and drift; with no observation in the last second it is free running as before. No vsync interrupt is used.
* New `kern.sweet_fb` keys (appended): `swapsync`, `swap_waits`, `swap_wait_us`, `swap_wait_timeouts`.
* Kill switches: `sweetfb_swapsync=0` (SwapWait answers 0 at once, timer free running), `sweetfb_vsyncalign=0` (only the timer alignment off).
* Not done: the fallback copy of a frame the zero-copy path declined still waits for the next `sweetfb_hz` tick, so SwapWait can time out for such a swap (CoreAnimation retries); in direct mode with a canvas-sized pooled surface this does not occur.

**Black bars, cache clean (supersedes mode 2 of 5.4):** `sweetfb_zcclean` now defaults to 1 (always `dc cvac` the canvas before a scan, and BO_SYNC of a scanned pool surface is the full `civac` again) also in direct mode. Mode 2 skipped the clean for frames with a GPU write, so CPU pixels drawn into the same surface in that frame stayed dirty in the cache while the MDP read DRAM. Cost: one walk of 171k lines at @3x per frame, `zc_us` / `clean_us` / `cleans` in `kern.sweet_fb` give the figure on the phone (not measured here; the 0127 estimate was a few ms of one A75 per frame, mostly clean lines). Mode 3 is the opt-in cheaper variant (needs the CPU writer to unlock the surface).

### 5.4c Review of direct mode with swapdepth=2, flicker and garbage blocks (0220, 2026-10-23)

Review of the 0216/0217 path against the questions of the hardware report (combined2: flicker, noisy RGB blocks in Control Center). No log of that build was available (the newest USB log is a copy-mode boot), so the findings are from the code and the pasted `kern.sweet_fb`; what is still open is listed at the end.

1. **Release while still pending/scanned.** With depth 2 the holds are: the frame on the panel, the frame queued behind it, and every frame replaced before its latch (all held until the newest scan latched, `zcPoll`). The hold of the older ones is dropped only when `CTL_FLUSH & fLastFlush` reads clear. Checked: `zcPoll`/`scanAddr` run on the work loop only, so `fLastFlush` never changes under a poll; SwapWait only reads. Remaining weaknesses: a single glitchy read of the flush register, and no margin between "bits clear" and the last line of the old frame having been fetched. 0220 adds `sweetfb_latchconfirm` (flush must read clear twice, 20 us apart) and `sweetfb_latchguard=US` (default 1000: the older surfaces and `fSwapDone` are released 1 ms after the latch was first seen; a 300 us timer re-polls during the guard). `scan_replaced=52` (2 percent of 2314) is a frame that CoreAnimation sent while the previous one still waited for vsync: depth 2 lets it render N+1 during that wait and a fast frame replaces the queued one; the replaced frame is never shown (judder, not corruption) but the address/flush registers are rewritten around the vsync. 0220 `sweetfb_noreplace` (default 1): `zcPresent` sleeps (200 us steps, 20 ms cap, `replace_waits`/`replace_timeouts` in `kern.sweet_fb`) until the queued frame latched before it writes the next one.
2. **Vsync alignment cannot make the panel show a frame early** (scan-out is only ever the latch of the address we wrote; the timestamps only move when CoreAnimation is told). It could make CoreAnimation miss or double a tick: the timer was armed for the boundary itself and fired early under jitter, which skipped one vsync, and an unfiltered phase observation could jump by a work-loop delay. 0220: the timer fires 500 us after the boundary, timestamps are strictly increasing and never in the future, and phase observations are low-passed (a quarter of the deviation per sample). `sweetfb_vsyncalign=0` still turns it all off.
3. **Uninitialised pool blocks: not the cause in the code.** Every low-pool block is zero-filled and cleaned+invalidated at allocation (`sweet_surface_try_pool`), blocks cool down after free, and only BGRA surfaces of at least the canvas minimum are pooled (the 94x203 CC surfaces in the log are normal memory). `pool_surfaces=15` is the cumulative allocation counter; `pool_used=2058` pages is three live canvases. The garbage patches are small rectangles in Control Center: candidates in order: (a) renderer output (wrong stride/format/tiling of a GPU-rendered blur or snapshot, or alias stores that never reached the surface: wrapped client memory is NOT zeroed by us, it holds whatever the owner's allocator left, which looks exactly like noise where nothing was written); (b) MDP fetch underrun under GPU/DDR load (noisy blocks with hard edges), which `sweetfb_swapdepth`, the latch guard and the clean cannot fix. To separate them: when the garbage is on screen, read the same IOSurface through the CPU (IOSurfaceLock, ReadOnly) and compare: garbage in the surface = renderer/alias side; clean surface, garbage on the panel = display side (then `kern.sweet_gpu` busy/level and the MDP bus bandwidth vote are next).
* Kill switches (all default on): `sweetfb_latchconfirm=0`, `sweetfb_latchguard=0`, `sweetfb_noreplace=0`, `sweetfb_vsyncalign=0`, `sweetfb_swapsync=0`, `sweetfb_swapdepth=1`.

### 5.4d 0220 regression and 0221 (2026-10-24)

**Hardware result of 0220 (combined fa7eefb):** every label drawn twice with an offset, icons/wallpaper missing, Setup Assistant list overdrawn by stacked old frames (`scan_replaced=0`, `replace_waits=445`). That is damage-only rendering on a surface whose content is not what CoreAnimation believes it is. **Cause not proven.** 0221 puts the behaviour back to what worked (4414e2b) and keeps only what is safe:

* `sweetfb_noreplace` (default now **0**), `sweetfb_latchguard` (default now **0**) and the vsync timer smoothing of 0220 (+500 us margin, monotonic stamps, low-passed phase; new switch `sweetfb_vsyncsmooth`, default **0**) are off. `sweetfb_latchconfirm` (flush must read clear twice, 20 us apart) stays on: it only re-reads a register.
* **Real bug fixed in 0216's SwapWait:** it answered a wait that ran out of time with `kIOReturnTimeout`. QuartzCore's ring poll (`IOMFBDisplay::can_update_`, QuartzCore 22H352) compares the answer of `IOMobileFramebufferSwapWait(fb, swap id, 0x80000001)` with `kIOReturnBusy` (0xe00002d5): Busy = still pending, **any other value (0 included) = complete**; it then releases the record's resources and advances its completed-frame counters. A timeout was therefore reported to CoreAnimation as a completed swap. SwapWait now answers `kIOReturnBusy`. (`swap_wait_timeouts` was 0 in the earlier reports, so this was not necessarily what the 0220 run hit, but with `noreplace` the waits are longer and the 25 ms limit is closer.)

**How buffer age and the in-use holds interact with CoreAnimation's surface choice (what the disassembly shows, and what it does not):**
* CoreAnimation keeps a ring of swap records (stride 0x30, in `IOMFBDisplay`). For each pending record `can_update_` polls SwapWait(record id); a completed record releases the objects it kept for that swap and raises the completed-frame counters at +0x438/+0x43c. The buffer it renders into next, and the age it assumes for it, come from its own bookkeeping of what it drew into which buffer: it assumes a buffer holds exactly what CoreAnimation last drew into it and draws only the damage since then.
* `IOSurfaceIsInUse` (state page +0x18, our hold) is read through a helper whose caller I could not find by cross references. So what CoreAnimation does when the surface it wants is in use is not established: it may skip the frame, take another buffer (full redraw or another age), or ignore the flag. Anything that changes when a surface is free (the guard delay) or when a swap counts as complete (noreplace changes when N+1 is scanned and so when SwapWait(N+1) says ready) can change which buffer it picks.
* Ghosting needs the *content* of a buffer to differ from what CoreAnimation drew. Display-side candidates, not distinguishable without a log: (1) a buffer recycled by CoreAnimation while its in-use hold was dropped too early or not yet taken; (2) stale dirty CPU cache lines of a pool surface evicted over GPU-written pixels at an arbitrary time (the pool is write-back, the GPU writes DRAM; timing changes make this appear or vanish); (3) a swap reported complete too early (the Timeout bug above).
* To decide: boot with `sweetfb_latchguard=1000` only, then `sweetfb_noreplace=1` only, and compare `kern.sweet_fb` (`swap_waits`, `swap_wait_timeouts`, `replace_waits`) and the log line `SWEET FB: direct safety: ...`.

### 5.5 `sysctl kern.sweet_fb`

One line, `key=value` words, refreshed about once per second (`sweet_fb v1 mode=off` before the framebuffer exists). Totals since boot plus `_s` rates over the last window (x100 fixed point, e.g. `swaps_s=58.30`):

`mode` (direct | zc | copy: what is armed), `hz`, `flushticks` (vsync ticks per copied frame), `hw`, `flip`, `smmu`, `clean` (never|always|auto), `up_s`, `win_ms`, `swaps`, `swaps_s`, `coalesced`, `coalesced_s` (swaps that replaced an unpresented frame: dropped by the pacing), `zc_frames`, `zc_s`, `copy_frames`, `copy_s`, `scan_replaced`, `scan_replaced_s`, `copy_us` (average CPU time of a copied frame, latch waits excluded), `copy_us_max` (window), `zc_us`, `zc_us_max` (cache clean + register programming of a scanned frame), `clean_us`, `cleans`, `clean_skips`, `latch_waits`, `latch_wait_us`, `latch_timeouts`, `vsync_s`, `pool_used`, `pool_total`, `pool_surfaces`, `pool_fallbacks`. Readers must ignore unknown keys. The same line is logged as `SWEET FB: stats ...` every `sweetfb_statlog` seconds.

### 5.5b On-screen performance HUD (0213)

`sysctl kern.sweet_fb_hud=1` (0 = off, default; boot-arg `sweetfb_hud=1` sets the initial value) draws a small stippled box with outlined white text at the left, below the status bar (y = buffer height / 16), refreshed twice a second. Rows: `DISP` frames/s pushed to the panel (zc + copy) and vsync Hz; `APP` backboardd swaps/s and coalesced/s; `COPY` avg/max copy time (latch waits and the HUD itself excluded); `GPU` MHz, level, busy %, gov|fixed (`sweet_gpu_hud_state`); `CPU` A55/A75 MHz (`sweet_cpufreq_hud_mhz`); `BAT` % and mA, + charging (`sweet_battery_hud`, last value SweetBattery published).

Copy path (`sweetfb_direct=0`, no zero-copy): drawn into the buffer the CPU copy fills (write-combined, so no cache clean, only `dsb sy`): after each copy before `scanTo`, and on the vsync timer into the front buffer when the screen is still. After switching it off a still screen keeps the last box until the next frame.

Zero-copy / direct (`sweetfb_direct=1`): the scanned buffer is the app's IOSurface and is never written. The box is a second hardware layer: a DMA pipe (DMA0, else DMA1) fetches a 1:1 ARGB image from two buffers at the end of the splash carve-out (past the flip buffers, below `fPhys + 0x2400000`), double buffered, updated twice a second and flipped with `SRC0_ADDR` + CTL0 FLUSH (pipe bit | bit 17), latched at vsync like the scan-out. The mixer stage is one above ABL's base pipe (CTL0 LAYER0 field = base value + 1; LM0 blend block `0x20 + 0x18*(value-2)`): FG_ALPHA 0xff, BG_ALPHA 0, OP 0x602 = pixel-alpha coverage blend (box = black at alpha 0xa0, text opaque white with a black outline). Format, unpack pattern, danger/safe/creq LUTs and QOS_CTRL are cloned from the base pipe. Every check or readback failure logs once (`SWEET FB: HUD layer: ...`) and leaves scan-out untouched; `sweetfb_hudlayer=0` disables the layer. The boot value of LAYER0 is in the panic restore table; switching the HUD off restores it and flushes the mixer, so the box vanishes at once. Register layout is from memory of Linux dpu_hw_*; the first boot is the test (look for the `HUD layer:` log line).

### 5.6 What to expect (estimates, not measured)

* Copy path (`sweetfb_direct=0 sweetfb_hz=60`): `copy_us` about 5-10 ms per 10.7 MiB frame through write-combined stores (0127's estimate), i.e. 30-60 percent of one A75 at 60 swaps/s; if the CPU cannot keep up `coalesced_s` grows (frames dropped) and `swaps_s` stays near what backboardd manages.
* Direct (`sweetfb_direct=1`): `copy_frames` near 0, `zc_s` = `swaps_s` up to 60, `zc_us` tens of microseconds on GPU frames (about a dozen MMIO writes and two `dsb`), 2-4 ms only for a frame that needed the clean; `clean_skips` tracks `zc_frames`. `coalesced_s` should be near 0 below 60 swaps/s, `scan_replaced_s` near 0 unless backboardd swaps twice within one panel frame. `latch_waits` should stay near 0.
* Panel: Tianma NT36672A video mode, `timing@0` in the live DT: 1080x2246, 60 fps (`qcom,mdss-dsi-panel-framerate = <0x3c>`), h porch 40/44/20, v porch 15/8/2; the vsync timer period (16667 us) matches it. The software timer and the hardware frame start are not phase locked; with scanning on swap this costs at most one frame of latency drift, never a torn frame (address and flush are latched together).

### 5.7 Test order and risks

1. `sweetfb_direct=0 sweetfb_hz=60` first: confirms the stats (`copy_us`, `coalesced_s`) and the hw scaler path from 0126/0129 at 60 Hz.
2. `sweetfb_direct=1`: read `smmu=` and the `low pool` lines first. `mode=copy` with `smmu=translate-or-unknown` means direct is not possible on this ABL (safe, copy at `sweetfb_hz`).
3. Risks: a wrong pipe setup can blank the screen. The pipe is only ever pointed at memory that passed every `zcPresent` check (pooled, below 4 GiB, 64-byte aligned, block long enough) and the SMMU gate; the panic hook and `blackout` restore ABL's registers and frame exactly as for 0126. Unverified on hardware: the pool window being free of TZ/hyp protection, MDP fetch from the pool, QSEED3 downscale underflow at the ABL's MDP clock (1125 source pixels per 1037 output pixels, 4.2 percent more fetch per line than 1080), write-back mapping of the pool, stale CPU lines in screenshots, and the GPU's own cache flush being complete before the swap (the shim waits for the fence in `st_finish` before BO_SYNC). Reverts: `sweetfb_direct` is off by default; `sweetfb_zcclean=1` restores per-frame maintenance.

## 0129: QSEED3 filter fix (image quality)

Patch `xnu/patches/0129-beryllium-fb-scaler-quality.patch` (diff against `research/bt127/xnu` = 0001-0128; `git apply --check` verified; `SweetFramebuffer.cpp` compiles). Not booted.

**Root cause found by reading Linux (`dpu_hw_sspp.h`, `dpu_hw_util.c`, `dpu_plane.c`, torvalds/linux master):** `_dpu_plane_setup_scaler3` sets `y_rgb_filter_cfg = DPU_SCALE_BIL`, and that `DPU_SCALE_BIL` is the last member of `enum dpu_hw_filter_yuv { DPU_SCALE_2D_4X4, DPU_SCALE_2D_CIR, DPU_SCALE_1D_SEP, DPU_SCALE_BIL }` = **3**, not 1 (`DPU_SCALE_FILTER_BIL` = 1 belongs to the unrelated QSEED2 `enum dpu_hw_filter`). `dpu_hw_setup_scaler3` writes it as `op_mode |= (y_rgb_filter_cfg & 3) << 16`. 0126 wrote `1<<16` = the **circular LUT filter with no coefficient table loaded** (Linux uploads nothing for the default bilinear: `lut_flag = 0`), i.e. the scaler ran on whatever the coefficient RAM held. That matches "blurry and jagged" at both 1.38x up and 0.92x down. The op value at @2x was 0xa0014401; it is now **0xa0034401** (with the alpha format; 0x80034001 without).

Everything else was already Linux-exact and is unchanged: phase init 0 (v0x1003: four `PHASE_INIT_*` regs; v0x1002: packed `PHASE_INIT`), `PHASE_STEP = (src<<21)/dst`, PRELOAD `4|3<<8|4<<16|3<<24` (QSEED3 defaults; 4/2 is QSEED4), SRC_SIZE Y/UV and DST_SIZE, `dir_en` 0 (no BIT4), detail enhancer off (no BIT8), BIT14 for non-DX formats, BIT31 blend_cfg 1, and for alpha formats BIT10 plus alpha filter `DPU_SCALE_ALPHA_BIL` = 1 -> bit29 (bit30 on v0x1002). `uv_filter_cfg` is only used for YUV formats (BIT12, bits 25:24), not written for RGB. Linux has no LUT upload for this path; `_dpu_hw_setup_scaler3_lut` (offsets: filter tables at `QSEED3_COEF_LUT` 0x100 + {0x000, 0x320, 0x500, 0x380, 0x560}, regions of 18/12/12/8 resp. 6/3/3/3 words, `COEF_LUT_CTRL` 0x4c bit0 swap) only runs with lut_flag set, with coefficients that come from userspace/downstream and are not in mainline, so there is nothing to load for bilinear.

Boot-arg `sweetfb_hwfilter` (default 1):

| value | Y/RGB field (bits 17:16) | meaning |
|---|---|---|
| 1 (default) | 3 | bilinear, exactly Linux. Needs no LUT. |
| 0 | 0 | 2D 4x4 (edge directed) with whatever coefficient RAM contains: diagnostic |
| 2 | 2 | 1D separable LUT filter, same caveat: diagnostic |
| 3 | 1 | circular LUT filter = what 0126 did: diagnostic |

There is no real nearest/pixel-repeat mode for RGB in QSEED3 (only the alpha channel has `PIXEL_REP`), and generating a LUT set blind (format of the 60-word tables is not in mainline) was judged riskier than useful; 0, 2, 3 exist to see, with `sweetfb_hwdump=1`, whether the coefficient RAM was populated by ABL. If bilinear at 0.92x still looks soft/aliased, the next step is a real LUT upload (needs coefficients from a downstream sde LUT dump) and/or the detail enhancer.

Logging (once, at first programming): `SWEET FB: qseed3 written (v0x.., hwfilter N = Y/RGB field F ...): SRC_SIZE OUT_SIZE OUT_XY PE ...` and `qseed3 written: PHASE_INIT ... STEP_Y .. STEP_UV .. PRELOAD SRC_Y SRC_UV DST OP (en, filter, non-DX, blend, dir_en 0, DE off, lut_flag 0, alpha)`. With `sweetfb_hwdump=1` additionally `qseed3 readback +0xNN = ...` for 0x00-0x50 and 0x90-0x9c, and `qseed3 lutN @0x...: w0 w1 w2 w3` for the five tables (reads only).

Test: boot with `sweetfb_hw=1 sweetfb_hwdump=1` at @3x; compare `sweetfb_hwfilter=1` (expected: clean, slightly soft downscale) with 3 (0126 look).

## 0130: battery

Patch `xnu/patches/0130-beryllium-battery-ios-capacity.patch`: `CurrentCapacity` is now the percentage and `MaxCapacity` 100 (iOS AppleSmartBattery convention; mAh stay in `AppleRaw*Capacity`/`NominalChargeCapacity`), plus `BatteryData`, `AdapterDetails`, `built-in`, `CapacityEstimated`, time-remaining 65535 and a few more keys.
