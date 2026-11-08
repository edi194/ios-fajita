# Metal + CoreAnimation GPU acceleration on the Adreno 630 (Poco F1, iOS 18.7.8, SDM845)

Status: research and design, 2026-10-23. Nothing here was run on the phone. Evidence tags: **[V]** read in our own 22H352 binaries or in the cited
source this session; **[I]** inferred; **[M]** from memory, not re-checked. Third-party content was treated as data and nothing from it was built or run.
Names: the bootloader is Enxerto (`enxerto/`), the patcher Renegade (`tools/renegade`), our kernel Heartwood.

Supporting material (all under `research/metal-a630/`): `ios18-metal-findings.md` (iOS 18 evidence with addresses), `a6xx-kernel-and-userspace.md`
(what a minimal A630 kernel driver and Turnip/freedreno submission do, from Linux/Mesa), `snapintosh-notes.md` (licences, kext/bundle/air2ir3
architecture), `lists/` (class/method/selector lists), `tools/` (offline scripts), `hackios-xnu-kernel-ext/` (clone of the user-suggested repo, section (f)).
Older related docs: `GPU_A630_BRINGUP.md` (stages 1-7 of patch 0103), `GPU_RESEARCH.md`, `GPU_PHASE0_DISCOVERY.md` (iOS 16 discovery analysis).

## 0. Summary

1. **iOS 18 CoreAnimation does not need a Metal device.** QuartzCore 22H352 still contains a CPU rasterizer and the render server falls back
   Metal -> OpenGL ES (EAGLContext) -> software. A missing `MTLDevice` is therefore **not** by itself the reason for the black screen.
2. **Do not register a half-implemented Metal device ("null Metal device" as a phase 0).** CA tries Metal first; a non-nil device that cannot do a
   render pass makes CA stay on the Metal path and draw nothing. Either no device (today, software path) or a complete one.
3. **Recommended first GPU phase: OpenGL ES for the render server, not Metal.** iOS 18 QuartzCore still drives an `EAGLContext` with the same private
   selectors as iOS 16, so a replacement EAGL library over Mesa freedreno (userland) + an msm-DRM-shaped kernel client (our driver) gives CA GPU compositing without
   a Metal driver. A project on the same XNU (xnu-8796, Adreno 642L) has demonstrated this on hardware (section (f)). Metal for apps is a later, much larger phase.
4. The kernel bring-up (power/GMU/HFI/SMMU/zap/CP) is common to both routes and is the real critical path; patch 0103 already reaches GX on and
   needs only the zap shader files for stage 6.

## (a) Can iOS 18 CoreAnimation render without a Metal device?

**Yes, in principle: there is a software renderer, and it is what runs when both Metal and GLES are unavailable.** Evidence (details and
addresses in `research/metal-a630/ios18-metal-findings.md` section 3):

* **[V]** Strings in QuartzCore: `sw renderer doesn't support tiling`, `image is too large for software renderer, ignoring`, `SW renderer invalid destination
  format %c%c%c%c`; code at QuartzCore+0x21cd6c accepts the destination fourcc `BGRA` (our IOMFB surfaces are BGRA), `A008/L008/L555/L565`.
* **[V]** The lazy software-renderer constructor at 0x1849d11b0 allocates the renderer state and logs `CoreAnimation: Software renderer! Simulating crash!`
  and `CoreAnimation: Failed to initialize Metal or OpenGLES contexts!`, then **returns the renderer**: it is a diagnostic log, not an abort.
* **[V]** Metal is obtained with `MTLCreateSystemDefaultDevice` (4 call sites; `MTLCopyAllDevices` unused). `CAMetalLayer nextDrawable` with a nil device
  returns nil with a log line; there is no assertion.
* **[V]** backboardd has no Metal code of its own; it renders only through QuartzCore.
* **[V by observation, iOS 16]** NOTES: iOS 16.7.16 on this phone already renders the whole UI (lock screen, Safari pages) through the software path with no
  MTLDevice (`IOAcceleratorES` -> 0 services).
* **[V]** Metal discovery on 22H352 is unchanged: `IOServiceMatching("IOAcceleratorES")`, property `MetalPluginName`
  (+ optional `MetalPluginClassName`), bundle from `/System/Library/Extensions/<name>.bundle`, `[[cls alloc] initWithAcceleratorPort:svc]`. No service
  -> no device -> CA falls back.

**Consequence for the black screen.** backboardd presents frames (3000+ swaps), so the render loop runs; most likely it runs on the software renderer and the
cause is elsewhere. Candidates, ordered by how cheaply they can be checked (none verified):
1. The swapped IOSurface is not black but the panel copy is: count non-zero pixels of the surface in `SweetFramebuffer` swap (kernel side, no userland change),
   and compare with the panel memory.
2. The surface is black because nothing is committed: SpringBoard's root layer is empty/black (lock screen/wallpaper come from PosterBoard extensions, wallpaper
   `IOSurface`/Metal-backed layers `CAMetalLayer` with nil device draw nothing). Check which processes are alive (PosterBoard, SpringBoard UI services) and their
   crash logs; a black but functioning render server is the expected picture when the wallpaper layer can only be drawn by Metal.
3. The software renderer produces black for a format/colour-space reason (display colour space, `CA_DISPLAY_COLOR_SPACE`-style defaults, alpha 0 background). Dump the
   surface in a non-BGRA-assuming way (alpha channel!).
4. The IOMFB swap structure on iOS 18 carries several layers (detached/clone layers) while our swap path composites only layer 0.
Useful switches seen in QuartzCore (names only, gating unknown, maybe internal-build only; try via backboardd `EnvironmentVariables` in launchd.plist):
`CA_PRINT_TREE`, `CA_PRINT_FRAME_INFO`, `CA_DUMP_FRAMEBUFFERS`, `CA_DUMP_SURFACES`, `CA_ALWAYS_RENDER`, `CA_DISABLE_DETACHED`. There is no `CA_FORCE_SOFTWARE`.

**What would make CA draw if the SW path really draws nothing:** the only GPU-less lever is not registering a Metal device (today). A real fix needs either (b1) the GLES
route or (b2) a complete Metal device. A `null`/CPU Metal device is not a shortcut (point 2 of the summary): it would need the full MTLDevice/queue/pipeline/texture
plumbing (Apple's A12 driver is 59 classes, ~1,300 methods; `lists/ios18-agxmetala12-classes-methods.txt`) plus a CPU rasterizer for CA's Metal shaders.

## (b) Architecture

### b0. Layers

```
backboardd/SpringBoard (QuartzCore render server)
   |-- Metal route:  Metal.framework -> <our>Metal.bundle (_MTLDevice subclass: IOGPUMetalDevice-derived) -> IOGPU.framework -> IOConnect* -> kernel IOGPU-compatible service
   |-- GLES route:   EAGLContext replacement dylib (libredwood-gl style) -> Mesa gallium freedreno (a6xx) -> msm-DRM-shaped IOKit user client
   `-- software:     CA::OGL SW rasterizer (works today)
kernel (Heartwood, xnu-8796 now / xnu-11215 later): A630 driver  = power/GMU/HFI | SMMU CB + IOVA allocator | zap via PAS | CP ring/SQE | irq + fences | BO manager
                                                  + IOKit face: service named for the route (IOAcceleratorES, MetalPluginName) + user client
display: SweetFramebuffer (AppleCLCD stand-in): IOSurface swap -> panel (unchanged; separable from the renderer)
```

### b1. Kernel part

* **a6xx bring-up** (common to all routes): reimplement from the facts in `a6xx-kernel-and-userspace.md` (Linux is GPL-2.0: do not copy code). Patch 0103 has stages
  1-7 (CX GDSC, GMU RCG, GMU firmware boot, HFI v1 ACKs, GX via OOB, PAS zap, CP). Hardware state reached on the phone: GMU boots, HFI up, GX on, RBBM_STATUS readable;
  stage 6 waits for the zap files. New findings of this study that change plan details: a630 uses **VBIF** (not GBIF), has no `hw_apriv`, no preemption; RPTR
  shadow goes through `CP_WHERE_AM_I` (needs SQE >= 0x190, local file is 0x207); `RBBM_SECVID_TSB_*` writes are safe before the zap and only `RBBM_SECVID_TRUST_CNTL`
  (0xf400) must be avoided; the GPU SMMU walker must use 4 KiB granules even though iOS userland pages are 16 KiB; a single global pagetable avoids the
  `qcom_scm_set_gpu_smmu_aperture` call and `CP_SMMU_TABLE_UPDATE`; the a630 GMU does no bus scaling so the CPU must vote DDR bandwidth.
* **IOKit face** for the Metal route: an `IOAcceleratorES`-matching IOService (class derived from an `IOAcceleratorES` stand-in; closed IOGPUFamily headers do not exist
  for xnu-8796 or 11215, so we declare the class ourselves) publishing `MetalPluginName` (+ `MetalPluginClassName`), a user client answering IOServiceOpen type `1|(opts<<16)`
  and selectors 6, 2 (0x218 B out), 0 (0x40 B out), 4 (0x20 B out) exactly as `-[IOGPUMetalDevice initWithAcceleratorPort:options:]` demands (verified at
  0x21c1ce608 on 22H352; table in `ios18-metal-findings.md` section 2), then queue/buffer/fence/event selectors (sels 7..55 and traps 0..6, listed in
  `lists/ios18-iogpu-iokit-callsites.txt`) plus shared-memory command-buffer segments (`IOGPUMetalCommandBufferStorage`, `IOGPUMetalDeviceShmem`) and kernel command
  lists (`eIOGPUSegmentListShmemHeaderTypeKernelCommandList`). **Open item: the A12 kernel half (`IOGPUDeviceUserClient` dispatch table, event-machine layout)
  lives in the iOS 18 kernelcache and was not decoded here**; Snapintosh's table is macOS 27 (type 5, different selector numbers) and cannot be reused as is.
* **Memory:** BOs = wired `IOBufferMemoryDescriptor`s mapped into the GPU SMMU context (patch 0103 stage 7 already has page-table code); IOSurface-backed textures need
  `IOSurface` memory entered into the same context (hackios does this: `surfaceBuffer()`, section (f)). Non-coherent: CPU cache maintenance on submit.
* **Fences/interrupts:** CP timestamp (`CACHE_FLUSH_TS` to a memptr) + condvar; GPU/GMU/HFI IRQs through our GIC; polling is an acceptable first step (hackios polls 5x/ms).
* **Security/sandbox:** our MAC stand-ins permit `IOServiceOpen`; keep the Apple class names (`AGXDeviceUserClient`, `IOGPUDeviceUserClient`) to stay compatible with real
  profiles if sandboxing is ever tightened.

### b2. User part, Metal route (phase 4+)

* **Bundle:** our own `<Name>.bundle` (arm64e, built with the same ad-hoc signing Renegade applies), principal class a subclass of `IOGPUMetalDevice` (preferably) or `_MTLDevice`,
  loaded via the service's `MetalPluginName`. Apple's `AGXMetalA12` cannot be reused: it emits A12 GPU ISA (`AGXCompilerCore`), and its principal class is a deliberate dead end
  (`AGXPrincipalDevice` returns nil; the kernel sets `MetalPluginClassName=AGXA12Device`).
* **Classes to provide** (derived from `lists/ios18-agxmetala12-classes.txt`, which is Apple's own implementation list): Device, CommandQueue, CommandBuffer, Render/Compute/Blit
  encoders, RenderPipeline, ComputePipeline, DepthStencilState, Sampler, Buffer, Texture(+Layout), Heap, Library/Function plumbing from `Metal.framework` (generic), Event/Fence,
  IndirectArgumentEncoder; ICB, ray tracing, mesh, sparse heaps, residency sets, counters are skippable at first (Snapintosh refuses the same set: argument buffers, visible function
  tables, imageblocks, read_write textures; it compiles 32,125/32,136 WindowServer functions, and 18/18 CoreAnimation pipelines, on macOS).
* **What CoreAnimation actually uses** (the minimum viable device): the 18 CA pipelines (`QuartzCore default.metallib`, 1 vertex + 1 fragment each, blend/sampling/filters), IOSurface-backed
  textures (`newTextureWithDescriptor:iosurface:plane:`), render passes with load/store, shared events (render server <-> clients), memoryless/tile attachments (can be disabled
  by device report: `CA_DISABLE_TILE_SHADERS`/`CA_DISABLE_INPLACE_SHADERS` exist as CA switches), and `featureProfile`-style capability reports (Snapintosh's "device-report tuning"
  list is the best map; it is macOS-WindowServer oriented, SpringBoard/backboardd on iOS differ).
* **Shader path:** Apple's `MTLCompiler` produces AIR for the device; air2ir3 (AIR -> LLVM -> NIR -> ir3) compiles it; on iOS the compiler service for the device path must return AIR
  without invoking `AGXCompilerCore`; Snapintosh uses a pass-through plugin trick that exists for the simulator (iOS 18 equivalent unverified, open question). Our pipeline: reuse the MIT front end
  with `--chip` set to the a630 id (Mesa `0x06030001` [M]) and re-derive the binding ABI for a6xx (UBO limits, no preamble push on early a6xx, bindless layout; they are a8xx values today).
* **Alternative to avoid a Metal driver for CA:** the GLES route below; CA's GLES renderer needs only the EAGL selectors plus a GLES 3 implementation.

### b3. User part, GLES route (phase 2-3, recommended first)

* iOS 18 QuartzCore still calls `-[EAGLContext getMacroContextPrivate]`, `attachImage:toCoreSurface:invertedRender:`, `texImageIOSurface:...plane:invert:` and `CAEAGLLayer` [V]. A replacement
  `EAGLContext` implementation injected into backboardd (DYLD interpose/DYLD_INSERT, as the other project's `libredwood-gl` does for 16.5) over Mesa (gallium freedreno or the OSMesa-style
  software fallback for testing) turns CA's GLES renderer into GPU rendering with IOSurface textures. No `_MTLDevice`, no AIR, no IOGPU selectors.
* Kernel face: an **msm-DRM-compatible IOKit user client** (selectors = DRM ioctl numbers: GET_PARAM, GEM_NEW/INFO/CPU_PREP, GEM_SUBMIT, WAIT_FENCE, SUBMITQUEUE_*) so that stock freedreno works through a
  small libdrm shim. This is the smallest userspace/kernel contract that exists for a6xx.
* Unverified on iOS 18: whether CA enables the GLES renderer without `CA_ENABLE_OGL` (string present, usage not decoded), whether the GLES shader table/limits CA expects (the other project
  patches ninety function slots on 16.5) are the same on 22H352, and arm64e/PAC handling of an injected dylib under our platform-binary rules.

### b4. Reuse and licences

| Source | Use | Licence (exact) |
|---|---|---|
| Mesa freedreno: `src/freedreno/{ir3,fdl,vulkan(Turnip),registers,computerator}` | ir3 compiler, a6xx register DB, packet builders, UBWC/layout, kernel-backend interface | MIT (per-file SPDX read) |
| Mesa core `src/compiler/nir`, `src/util` | needed by ir3/air2ir3 | MIT overall; a few vendored util files carry other licences [M]: check per file |
| Linux `drivers/gpu/drm/msm/adreno/*`, `qcom_scm.c`, `mdt_loader.c`, `arm-smmu-qcom.c`, DTs | reference for sequences | GPL-2.0(-only): reimplement from facts, do not copy; `msm_kgsl.h` is GPL-2.0 WITH Linux-syscall-note |
| Linux registers/adreno/*.xml | register DB | MIT |
| Snapintosh umbrella | design reference | MIT **with GPL-2.0 components** (`compat/adreno-ib-tables.h` GPL-2.0-only; QEMU patch GPL-2.0-or-later) |
| SnapAdreno, SnapMetal, air2ir3 | kext skeleton, Metal plug-in structure, AIR->ir3 | MIT (every file); a kext built with the umbrella's table is GPL-2.0; Mesa patches inside air2ir3 keep Mesa's MIT notices |
| UniXNU (NativeAdreno/Turnip patch) | see `GPU_RESEARCH.md` | BSD-2-Clause-Patent (per that doc) |
| hackios-xnu-kernel | design/behaviour reference | APSL 2.0 (repo LICENSE and README "derivative of XNU, APSL 2.0"), see section (f) |
| hackios-xnu-userland (EAGL bridge, AIR->NIR) | design reference | MIT (LICENSE, 2026 OOSEX GANG); Mesa 25.0.7 with their patches fetched at build time |
| Firmware (`a630_gmu.bin`, `a630_sqe.fw`) | linux-firmware `qcom/` | redistributable under `LICENSE.qcom`; the zap image is the phone's own signed file (do not redistribute) |

Reuse by effort/benefit: air2ir3 front end **high** (chip-independent), Mesa ir3 **high**, plug-in class layout **high** as a template (Apple's real list is in our dumps), Snapintosh kext
skeleton **medium** (macOS 27 offsets), Snapintosh PM4 builder **low** (a8xx), Snapintosh/hypervisor-side code **none** (no EL2 monitor on Poco F1).

## (c) Phased plan

"Pre/post migration" refers to the planned move from xnu-8796 to xnu-11215 (section (e)). Efforts are for one developer with the phone; ranges, not promises.

| Phase | Deliverable | Gate | Effort | Needs kernel |
|---|---|---|---|---|
| 0 | **Explain the black screen on the software path.** Count non-zero surface pixels in the swap path, log layer count/formats per swap, check SpringBoard/PosterBoard liveness and crash logs, try `CA_PRINT_TREE`/`CA_DUMP_FRAMEBUFFERS` via launchd env. Keep `IOAcceleratorES` stub empty (no `MetalPluginName`). | a visible frame on the panel from the software renderer | 1-5 days | either (8796 now) |
| 0b | Optional probe: publish `MetalPluginName` with a bundle whose `initWithAcceleratorPort:` logs and **returns nil** (per `GPU_PHASE0_DISCOVERY.md` checklist; gives per-process open/discovery logs; also tests dlopen of an unsigned plug-in) | log shows backboardd/SpringBoard calling it, rendering unchanged | 2-4 days | either (8796 now) |
| 1 | **A630 power + CP ring + clear/blit.** Finish 0103: zap via PAS id 13, SQE, ring, `CP_ME_INIT`, secure-mode exit, fence write; then a PM4 solid fill and a 2D blit into an IOSurface shown by SweetFramebuffer. Requires `a630_zap.*` from the phone's `/vendor/firmware`. | CP timestamp advances; filled buffer shows on the panel; no SMMU faults | 3-8 weeks (the largest unknown is zap/secure CP on SDM845 without JTAG) | either; design for 11215's IOMapper/DMA interfaces from the start |
| 2 | **msm-DRM-shaped user client + Mesa freedreno on iOS** (compute test first, then GLES 3 triangle into an IOSurface) | `gl_test`-style triangle drawn by the Adreno; IOSurface texture sharing works | 4-8 weeks | either |
| 3 | **EAGL replacement for CA (GLES route)** in backboardd: GPU compositing for the render server; keep the software renderer as fallback on device-lost | SpringBoard drawn by the GPU; measurable speed-up vs software | 6-12 weeks (the other project spent a long time on CA's GLES shader slots/`vblur`/groups on 16.5) | either |
| 4 | **Complete Metal device skeleton** (nil-safe, fully functional or not registered): IOGPU-compatible user client, `IOGPUMetalDevice` subclass bundle, buffers/textures/fences/events/queues; compute path via air2ir3+ir3 first (blit/compute), then render passes | `MTLCreateSystemDefaultDevice` returns the device in a test app; 18 CA pipelines compile to a630 | 3-6 months | needs the A12 IOGPU kernel ABI decoded from the kernelcache; best on 11215 |
| 5 | CoreAnimation uses Metal (drop the GLES route or keep as fallback), cross-process shared events, drawables, memory pressure/reset, apps' Metal | SpringBoard/apps rendered by Metal | 3-6+ months, high risk | after migration preferred |

Which can start before the migration: 0, 0b, 1, 2, 3 all work on 8796 (they use IOKit user clients and our own drivers only). Phase 4/5 should target the final kernel to avoid redoing the IOKit
class work; the data-structure work (resource lists, command-buffer segments, shader pipeline, AIR) is kernel-independent and can proceed in userland before.

## (e) xnu-11215 migration: what changes for the GPU plan

(Public source `apple-oss-distributions/xnu`, tags xnu-11215.1.10 .. 11215.81.4; listing checked by `gh api`; the rest [M]/[I].)

* **IOKit plumbing we depend on is still public**: `iokit/Kernel/{IOMapper,IODMACommand,IOMemoryDescriptor,IOUserClient,IOUserServer}.cpp` exist in 11215. IOGPUFamily/IOAccelerator are
  closed in both generations: no headers either way, so the stand-in classes are ours regardless. `IOUserClient` in 11215 has the `IOUserClient2022` dispatch (`externalMethod` with
  `IOExternalMethodDispatch2022`) and the user-client filter hooks; our own user client can stay on `IOExternalMethodDispatch` (old style) and iOS 18's IOGPU.framework only sees selectors.
* **IOMapper**: the right abstraction for the GPU SMMU context bank (an `IOMapper` for the Poco F1 GPU SMMU lets `IODMACommand` produce GPU IOVAs). It is in 8796 as well; design the kernel
  GPU memory manager behind a thin mapper layer so it does not change with the kernel.
* **Exclaves**: the 11215 tree contains `osfmk/kern/exclaves*.c` and `osfmk/arm64/sptm/`; both compile away unless the config enables them (we are a non-SPTM, non-exclave config, like iOS 16's PPL-less
  build). The `mount -P 2` ExclaveOS graft issue in `IOS18_PORT.md` already comes from the userland side of this. No GPU consequence [I].
* **PPL/SPTM**: GPU page tables belong to the SMMU, not the CPU pmap, so PPL/SPTM do not affect an Adreno driver; wired buffers and `pmap_sync_page_attributes_phys`-type cache maintenance
  need to be re-checked on the new pmap (patch 0083 of the other 778G/618 projects fixed a 32-bit truncation in that call on 8796 [from `GPU_RESEARCH.md`]).
* **8796-only assumptions in what was drafted**: patch 0103's `vn_rdwr` firmware loader and `IORegistryEntry` hooks, `xnu/patches` for IOSurface (0046), the iOS-16 selector numbering in
  `GPU_PHASE0_DISCOVERY.md` (the open sequence is identical on 22H352, but the later selector map was not re-derived), Snapintosh notes written for "xnu-8796" in section 7 of snapintosh-notes.md, UniXNU
  references. The IOGPU contract numbers in this document are from the iOS **18** userland, which is the target regardless of kernel version.
* **Dependence on the migration**: none of phases 0-3. Phases 4-5 should be built against the kernel that will ship; decoding the iOS 18 kernelcache IOGPUFamily (which is built for the 11215-generation
  kernel) is easier to validate against 11215 headers than 8796.

## (f) Review of `oosexgang/hackios-xnu-kernel` (user-suggested)

Fetched read-only (`research/hackios-xnu-kernel-ext/repo`, 47 MB, shallow clone; nothing built or run; companion repo `hackios-xnu-userland` read via the GitHub API only).

* **What it is:** "HackiOS" boots **xnu-8796.121.2 (iOS 16.5)** with the **unmodified iOS 16.5 userland** on a **POCO X5 Pro ("redwood", Snapdragon 778G, SC7280-family)** and QEMU. Our kernel generation and approach are the same (their
  README: lock screen, home screen, apps, Wi-Fi, sound, camera work; "Metal for apps in progress").
* **Licence:** kernel repo `LICENSE` = **Apple Public Source License 2.0** (GitHub: NOASSERTION), README: "derivative work of XNU, APSL 2.0"; new files carry no per-file header, so treat them as APSL-2.0 covered
  code (copyleft-ish file-level, compatible with our own xnu-derived patches, but copying needs the APSL notices). Userland repo: **MIT** (2026 OOSEX GANG), Mesa fetched at build time.
* **Relevant content (high):**
  * `xnu/files/bsd/dev/redwood_adreno.c` (4,125 lines): step-by-step in-kernel bring-up of an **Adreno 642L (a6xx GMU-based, same generation as ours)** under Qualcomm's hypervisor: CX GDSC, GMU
    clocks, SMMU contexts, TrustZone PAS zap authentication, GMU firmware + HFI, GX power through the GMU, SQE, ring, first PM4 commands (22 numbered steps, `adreno=N` boot-args), recovery and
    stop. This is the same sequence as our patch 0103 stages and ends past our current wall (zap + CP), done on real hardware. Different SoC (SC7280-family addresses, different gpucc/GCC/SMMU),
    so a reference for ordering and pitfalls, not a drop-in.
  * `xnu/files/iokit/Kernel/RedwoodGPU.cpp` (1,295 lines): an IOService + IOUserClient that exposes **the Linux msm DRM ioctl numbers as selectors** (GET_PARAM, GEM_NEW/INFO/CPU_PREP/SUBMIT, WAIT_FENCE,
    SUBMITQUEUE_*) so that stock Mesa freedreno works through a libdrm stand-in (`tools/mesa/redwood-drm` in the userland repo), plus an IOSurface-backed buffer request; buffers are wired memory in the 3D SMMU
    context, write-combined. Interrupts are not used (polling), no per-client isolation, fences polled. Exactly the contract proposed in b3.
  * Userland (companion repo): `userland/src/eagl.c` (`libredwood-gl.dylib`): an **EAGLContext replacement over Mesa** that CoreAnimation's render server uses
    (`CA::WindowServer::EAGLServer::renderer()` tries Metal, then GLES, then `Server::sw_renderer()`), answering the same selectors we verified in iOS 18 QuartzCore (`getMacroContextPrivate`,
    `attachImage:toCoreSurface:invertedRender:`, `texImageIOSurface:...invert:`); `inject.c` hooks the renderer choice; they patch CA's GLES shader table for functions its GLES renderer lacks.
    `docs/air.md` documents an **AIR -> NIR** frontend (321/456 system metallib modules compile through ir3; 30 verified executing on the phone's Adreno) and notes that the Metal device object graph and kernel
    submission ABI are **not started** there either (AGXMetalA11 = 53 classes/1,158 methods + IOGPU 711 in iOS 16.5).
  * `MiniIOMobileFramebuffer.cpp`, `MiniIOSurface.*`: IOMFB/IOSurface stand-ins (like our SweetFramebuffer/SweetSurface).
* **Not relevant:** loader/UEFI, Wi-Fi (ath11k port on a Linux compat layer), audio, camera, APFS, GIC/PSCI/CPU-freq for a different SoC, QEMU scripts.
* **Fit with xnu-11215:** all code targets xnu-8796.121.2 (`BCM2837` config as base) and iOS 16.5; the driver files are plain kernel C/IOKit using stable KPIs, so they port to 11215 with the same effort as
  our own patches. Nothing in it addresses 11215 or iOS 18 (their QuartzCore/EAGL slot offsets are iOS 16.5 addresses, e.g. `VT_EAGL_SERVER`, `CA_SHADER_TABLE`: they must be re-derived on 22H352).
* **Verdict: useful, as a design proof and cross-check, not as code to merge.** It demonstrates on hardware, under XNU 8796, the exact route recommended here (a6xx bring-up in kernel + msm-DRM client + EAGL
  bridge over freedreno for CoreAnimation), shows what breaks (shader slots, blur, IOSurface sharing, hypervisor limits) and what the zap/PAS step needs. Risks: APSL licence on copied code; different SoC
  (hypervisor-restricted EL1; SDM845 on Poco F1 has the same TZ/zap requirement but our patches 0103 show a different register map); the claim "Adreno drawing the whole UI" was not re-verified by us.

## (h) Metal track, first two spikes (2026-10-23, `gpu/metal/`, branch `metal`)

Rule kept throughout: **no Metal device is ever registered.** Nothing calls `MTLAddDevice`, nothing publishes `MetalPluginName`, the probes are standalone test tools run from `/var/root/metal-test`, and each ends with `MTLCopyAllDevices` returning 0 devices in its own process. Evidence tags as above: [V] measured this session.

### h1. What the two reference projects are, and what we take

**hackios `metal` branches** (kernel `hackios-xnu-kernel` @ c2ddff4, userland `hackios-xnu-userland` @ 29eef72). The kernel `metal` branch holds almost no Metal: it is `main` renamed, plus an `IOAcceleratorES` stub whose `setProperties()` can set `MetalPluginName` (boot-arg gated) and an msm-ioctl user client like ours. The Metal work is in the userland branch (MIT, "OOSEX GANG"; AIR files carry SPDX MIT "Darwin on redwood contributors"): `hkmetal.m` (an `_MTLDevice` subclass with queue, command buffer, compute and render encoders over Mesa), an own AIR bitcode reader and AIR -> NIR frontend inside Mesa 25.0.7 (~12k lines) plus `air_metal.c` (~7k lines: Metal call -> Gallium state), and three ir3 fixes. Measured on iOS 16.5 / Adreno 642L only; their docs (`metal.md`) are not in the repo, so headline claims (321/456 system shaders, "30 run on the Adreno") were not re-verifiable. Blit, heaps, events, resolve are missing in their driver; CoreAnimation does **not** render through it (they hide Metal from CA). Verdict: **adopt the userland design and the frontend** (done, below), keep the kernel branch as a design reference only (APSL; its one useful idea is the runtime `setProperties` switch for a kill-switchable `MetalPluginName`).

**UniXNU** (xnu-10063, iPadOS 17.7.11, SM8550/Adreno 740, BSD-2-Clause-Patent umbrella, MIT drivers). The only project whose docs claim CoreAnimation compositing through a native Metal device. Its stack is the opposite of ours: kernel A740-only, Apple's own IOGPUFamily kept, `IOAcceleratorES` subclass + `MetalPluginName`, QuartzCore's `default.metallib` run through AIR -> SPIR-V (metal2vulkan) -> Turnip, with a slow cold start (77-103 pipelines in 40-43 s) and per-process devices because Metal-only layers (wallpaper, icons, widgets) go black when only backboardd has a device. Nothing for a6xx, nothing for iOS 18. We take ideas, not code: the per-process allow-list, `BoImport` (pin a task's pages as a BO: the zero-copy IOSurface path we lack), the sandbox-grant property, the Turnip darwin KMD as a map of which msm features Turnip needs, and the observation that the render server's framebuffer format must be forced to plain BGRA when CA takes Metal.

### h2. Spike 1: AIR -> NIR -> ir3 (chip 0x06030001) on the Mac [V]

Built in a **separate** Mesa tree (`git clone --shared` of the gpu-eagl tree plus its patch plus the hackios frontend, `gpu/metal/build-host.sh`, host binaries `air2nir` and `ir3_compiler`; the gpu-eagl tree and build dirs are untouched). Corpus runner: `gpu/metal/tools/corpus.py` (our own; theirs was not run). Input: `/System/Library/Frameworks/QuartzCore.framework/default.metallib` of 22H352, read from the root image (`tools/extract-metallibs.sh`). It is a fat wrapper: slice 0 is the AIR container (`MTLB`, 178 functions: 119 fragment, 41 vertex, 18 kernel; the iOS 16.5 library had 141), slice 1 is a Mach-O of precompiled A12 GPU code (useless here).

| QuartzCore default.metallib (22H352) | functions | read | NIR (validated) | ir3 a630 |
|---|---|---|---|---|
| as ported, unmodified frontend | 178 | 178 | 115 (64.6%) | 115 |
| with the iOS 18 inline-sampler fix | 178 | 178 | 163 (91.6%) | 163 (100% of translated) |
| plus function-constant folding (h5), constants = 0 | 178 | 178 | **165 (92.7%)** | **165 (100% of translated)** |
| fragment / vertex / kernel (last row) | 119 / 41 / 18 | | 119 / 41 / 5 | 119 / 41 / 5 |

Failure class of the 13 left: **13 tile kernels** (`tile_downsample_*`, `tile_simd_blur_*`, `tile_average_luma*`: input `air.imageblock`, Apple tile memory; needs an emulation, not a translation). Before function-constant folding (h5) two more failed, `fixed_frag_lph_cph/cpf`, the ubershader pair (`air.get_null_texture_2d` behind function-constant branches); they now translate for the all-zero specialisation, see h5 for the specialisations that still fail. The one frontend change: iOS 18 AIR writes an inline sampler's state as `[2 x i64]` (two-word form), the frontend read a single i64 and failed 50 fragment shaders; word 0 is the old state word, word 1 carries a LOD bias (always 0 in QuartzCore, refused by name otherwise). 28 translated functions carry translation caveats printed by the frontend (24 framebuffer-fetch shaders: layered targets need `air.render_target_array_index`; 4 run-time pointer selects; 2 raster-order groups need `blend_coherent`; vertex attributes gated by function constants). All results are with function constants = 0; a second run with every constant = 1 gives the same counts. `ir3` accepted every translated module; nothing says they compute correctly (that is spike 2).

Other libraries QuartzCore's neighbours use (same tool): AppleMetalGLRenderer (Apple's GLES-on-Metal) 274/274, SiriUICore 27/32, PencilKit 31/34, MediaCoreUI 11/12, SpriteKit 19/19 (2 ir3 failures: `load_point_coord` needs the driver's point-sprite lowering), MetalFX 21/36, RenderBox 15/61 (vector function constants, `air.visible` library functions), CoreUI has no entry points. Whole system (193 libraries, 11,793 entry points): 7,988 translate (67.7%) and 7,946 compile after folding (6,686 / 6,639 before it; the +1,302 had no regressions), top classes: pointer stores, pointers at computed offsets passed to callees, `air.position_in_patch` (tessellation), phis of structs, ray tracing, simdgroup ops; 41 MLCompute kernels fail ir3 validation with "invalid src bit size: 1". Summaries and per-function JSON: `gpu/metal/results/`. Tools and numbers for 16.5 (141 -> 135 there) are consistent with this.

The three hackios ir3 patches (round-to-nearest on int->float `cov`, shift-split of negative offsets, sub-dword SSBO) are applied in the host build and in the iOS build used by spike 2. They change ir3 for everything in that tree, including the GLES path; they have **not** been applied to the gpu-eagl tree and should be considered for it (the rounding one fixes `uint -> float` for GLSL too).

### h3. Spike 2: `BGMTLDevice` on the phone [V]

`gpu/metal/src/bgmtl.m`: `BGMTLDevice : _MTLDevice` (declared in source: the SDK exports the class; `MTLDeviceSPI` and `MTLDevice` added with `class_addProtocol`), `BGMTLCommandQueue : _MTLCommandQueue`, `BGMTLCommandBuffer : _MTLCommandBuffer`, compute and blit encoders on `_MTLCommandEncoder`, `BGMTLBuffer : _MTLResource` (msm GEM through Mesa's freedreno winsys and our libdrm stand-in), `BGMTLComputePipeline : _MTLComputePipelineState`. Compute goes through `libbgair.dylib`, an iOS arm64e build of `air_metal.c` over Mesa freedreno (a6xx) in `build-ios` of the same separate tree (`build-ios.sh`, `build-probe.sh`). Test kernels (`test/bg_kernels.metal`) are compiled on the Mac with Apple's Metal toolchain to AIR.

iOS 18.7.8 facts measured with `mtl_introspect` (read-only): `_MTLDevice` has 598 methods and 50 ivars (16.5: 36 ivars), `MTLDeviceSPI` requires 376 methods (16.5: 337), `_MTLResource` now derives from `_MTLAllocation`, `_MTLBuffer` and `_MTLTexture` do not exist as classes, and the init selectors hackios used (`initWithDevice:descriptor:`, `initWithQueue:retainedReferences:synchronousDebugMode:`, `initWithCommandBuffer:`, `initWithDevice:pipelineStateDescriptor:`) all exist. Subclassing, queue/command buffer/encoder base initialisers, `newLibraryWithData:` and `newFunctionWithName:` on a device with no compiler all work; `-[_MTLFunction bitcodeData]` returns exactly the container's module (3712 bytes for `bg_add`).

On the Adreno 630 (`FD630`, kernel state `on`, `hangs=0` before and after): `bgair_test` (libbgair alone) and `bgmtl_probe` (full chain) pass **12/12 checks with bit-exact results**: `bg_add` (4 buffers + `setBytes`, 1024 and then 20 x 65,536 elements), `bg_copy` as the GPU blit, `bg_groupsum` (threadgroup ids), a CPU blit encoder (copy/fill on the shared write-combined buffers), and a garbage-bitcode pipeline refused with an `NSError`. The same sources run on softpipe on the phone and on the Mac (reference). Logs: `gpu/metal/results/spike2-*`. Per-dispatch latency 3-7 ms warm (first one 130-160 ms: compile).

Blockers and caveats found: (1) the phone rebooted several times during the session (other work); on two boots the kernel reported `state=lost` before any of our processes opened the GPU (`hangs=4`, `submitted=80`), `IOServiceOpen` then returns `kIOReturnBadArgument`; we stopped and waited, nothing of ours was running. (2) `/var/root` contents did not always survive a reboot; large scp transfers over the USB link dropped, so libbgair is stripped (9.4 MB). (3) A command buffer takes a queue semaphore slot in the base class and our commit does not return it: tests keep under 64 buffers per queue. (4) Completeness: against iOS 18's protocols BGMTLDevice leaves 15 `MTLDevice` and 15 `MTLDeviceSPI` required methods unanswered (textures, IOSurface buffers/textures, samplers, depth-stencil, heaps, fences, indirect command buffers, FP configs), the command buffer 5 (render/parallel/resource-state encoders, event waits), the buffer 5; 357 of the 376 SPI methods are inherited from `_MTLDevice` and not individually audited (abstract stubs there abort). `gpu/metal/results/spike2-completeness-gap.txt`.

### h5. Function-constant folding, textures, samplers and render passes, CoreAnimation shaders in a test process [V]

**Folding** (`air_to_nir.c`, "Bergamota" blocks). A small constant evaluator over the AIR itself: integer constants, function-constant loads, `air.is_function_constant_defined`, `normalize_function_constant_predicate`, program-scope globals as left by the module's `air.static_init` functions (executed abstractly, with field-level tracking for the config struct they fill through constant getelementptrs), and the integer instructions over them. A conditional branch or switch whose condition evaluates is the unconditional branch it is; only the taken successor is reachable; a phi ignores the edge never taken; a pointer `select` with a known condition is its chosen side. Also: `air.get_null_texture_*` / `is_null_texture_*` (a pointer naming nothing), and poison/undef aggregates are built to their nested depth (`insertvalue [2 x Image] poison, i8 %x, 0, 4` used to fail with "an aggregate index out of its value"). Result: QuartzCore 163 -> 165 of 178; system wide 6,686 -> 7,988 translated, zero regressions (`results/*fcfold*`, `all-system-metallibs-summary.*`). The ubershader still fails for specialisations that make its generic path live (`fc_generic=1`, or an image count with a non-trivial layout): "a call passing a pointer at a computed offset as argument N" (a callee specialised per call site cannot take a pointer plus a run-time offset; needs the offset as a parameter) and sampling a null texture on a path the constants cannot decide. `AIR_FC_SET="name=value,..."` and `AIR_FC_FILL=n` choose a specialisation for the corpus tools; Metal's real constants come from the pipeline.

**Textures, samplers, render passes** over the msm client (`gpu/metal/src/bgmtl.m`: `BGMTLTexture`, `BGMTLSampler`, `BGMTLRenderPipeline`, `BGMTLRenderEncoder`, textures/samplers in compute and fragment stages, vertex descriptor and blend state passed through to libbgair; no depth/stencil state object yet, no heaps, events or IOSurface-backed textures). `bgmtl_render_probe` (own MSL shaders, analytic expectations), on the Adreno 630 **16/16 checks exact**: `read`/`sample`/`write` of 2D textures in kernels (RGBA32Float, RGBA8Unorm, nearest sampler), a coloured triangle (3,664 checked pixels), a textured quad with API and inline (`constexpr`) samplers (4,096 pixels each), linear filtering with `level(0)`, clamp and a constant-buffer offset into RGBA32Float against a CPU bilinear (worst error 1.4e-3, the fixed-point filter weights), a texture at slot 3. softpipe agrees on all but the slot-3 case, which it gets wrong (all values): softpipe mis-samples a texture bound at an index other than 0 (even with the sampler bound at every index), so it is not a usable reference for CoreAnimation's shaders, which all use `texture(3)`; this is a limit of the reference, the GPU result is the one that matches the CPU.

**CoreAnimation's own shaders**, `bgmtl_ca_probe` with the QuartzCore slice of the phone's root image: every fragment function (119) built as a render pipeline through the Metal API with a generated vertex stage: **115 built**, 4 refused by name (`edr_clamp`, `rim_outline`: they store to `[[depth]]` and the test pipeline has no depth attachment). Of the 115, 112 were drawn once each on the Adreno 630 (32x32 BGRA8, deterministic pattern inputs: 256 KB buffers, 8x8 textures of the kind each module declares through `rwa_module_textures`): **112 of 112 completed, no GPU hang, `hangs=0` throughout**; 3 shaders with loops (`brim_jump_lph`, `simple_rim_lpf/lph`) were deliberately not run because a data-dependent loop would be the one way to lose the GPU (one ring, no recovery, reboot). Checks that passed: 22 shaders left the clear colour untouched where they write only other attachments (expected), and the half/float pairs agree exactly for 35 of 54 pairs (the 19 others differ by more than fp16 rounding on random inputs that saturate; not yet analysed). The softpipe differential gives 4 of 5 texture-less shaders identical (`stroke_arc` differs) and is meaningless for the 52 textured ones (softpipe limit above); 45 fragment functions crash softpipe's compiler (`f2f16`, i.e. the half variants), which is why the Adreno is the only device that can run them. What this does **not** show: that those 112 images are *correct*. There is no independent reference for CoreAnimation's inputs yet; real vertex stages (41 vertex functions with their vertex descriptors, `std_vert*`) were not exercised, and nothing was drawn with CoreAnimation's own pipeline state (blend, depth) or through a `CAMetalLayer`.

### h7. Mac-side follow-ups (reference, pointer offsets, vertex stage, IOSurface path)

* **softpipe as a reference.** nir_to_tgsi has one unit for a texture and its sampler, so CoreAnimation's `texture(3)` with `sampler(0)` sampled view 0 (nothing). libbgair now rewrites the unit and binds the paired sampler at the texture's index for a software screen (`air_shader_info.tex_sampler`). Half-precision shaders (`_lph`) are not comparable on softpipe (no 16-bit values) and 45 of them crash its compiler. On the comparable subset (float precision, writes colour 0, no framebuffer fetch: 37 shaders, with identical inputs and a clamp-to-edge sampler) softpipe on the Mac against the Adreno 630 run from phone: **29 identical, 1 within 3/255, 1 within 10/255, 6 further apart** (`axial_shading_frag_lpf`, `downsample_blur_4_frag_lpf`, `image_rect_blit_frag_lpf`, `stroke_arc_frag_lpf`, `brim_jump_lpf`, `read_surf_frag`). `read_surf_frag` fetches texel (x,y) from an 8x8 texture over a 32x32 target: out-of-range fetches give 0 on the Adreno and the clamped edge texel on softpipe, so the GPU is right. The others need the GPU's float outputs (phone time) to be told apart. `tools/ca-compare.py`, `test/bgair_sweep.c` (Mac harness), `results/spike3-ca-*`.
* **Pointer plus run-time offset into a callee** is passed as an extra 32-bit parameter (`ptr_offset_arg`): +263 entry points translate (8,251 of 11,793, 70%; ir3 8,208), no regressions. The ubershader's generic path still stops at "argument 0 is not a texture": a live path samples a texture the pipeline may not bind (a null texture chosen at run time); it needs a bound dummy texture for "no texture here", not more folding.

### h6. Next steps toward a device complete enough for CoreAnimation

1. A trustworthy reference for CA shaders: either teach softpipe's NIR path to split texture and sampler indices (or lower them in libbgair for the software screen), or compare against a CPU evaluation of the NIR (the frontend's `--eval` folding already does it for buffer-only shaders, extend it to texture fetches over small known textures).
2. Real vertex stages: pair `std_vert*`, `image_rect_blit_*`, `buffer_image_blit_*` with their fragments using the vertex descriptors the AIR reports (`--interface`), draw geometry with known buffers, check pixels (the shapes of buffers are readable from the AIR; `image_rect_blit_vert` was decoded: ImageRect {float2 x4, uint flags, uint} per instance, uniforms, mvp).
3. Remaining frontend gaps by value for CA: pointer plus computed offset into a callee (ubershader generic path), tile kernels (13, `air.imageblock`: emulate on a texture array), vector function constants and library stitching (RenderBox), `[[depth]]` shaders (needs the depth/stencil state object).
4. Missing device surface: depth-stencil state, heaps (stubs that are true), fences and shared events, IOSurface buffers/textures through the kernel's `SWEET_GPU_SEL_SURFACE_BO` (`newTextureWithDescriptor:iosurface:plane:` is what a `CAMetalLayer` drawable is), drawables, the 15+15+5 unanswered protocol methods listed in h3, a command-buffer queue-slot return at commit.
5. Only when a render pass of CA's own pipelines is pixel-correct against a reference: boot-arg-gated, kill-switchable publication (a `setProperties`-style switch), a per-process allow-list, and the GL route as the fallback. Until then the rule stands: no device, or a complete one.

## (i) First use: PosterBoard only (2026-10-23; static analysis of the 22H352 root, Mac-side work; nothing run on the phone)

Decision (with the user): backboardd and the CoreAnimation render server stay on the ES renderer. `BGMTLDevice` is injected into the **poster processes only**; they render into IOSurface-backed drawables that the ES render server composites as ordinary layer contents. No registration in any system process before an approved test with a dead-man.

### i1. Who issues Metal work for posters [V: Info.plists, `otool -L`, `.metallib` files and string tables of the cache images; no process was observed]

**Process model.** `/Applications/PosterBoard.app` (`com.apple.PosterBoard`; LaunchAngel `/System/Library/LaunchAngels/com.apple.PosterBoard.plist`: `ProcessType App`, `RunAtLoad false`, `KeepAlive false`, user `mobile`, RunningBoard managed, mach service `com.apple.posterboardservices.services`) hosts the posters. Every poster is an ExtensionKit/PlugIn extension of point **`com.apple.posterkit.provider`**, a separate process per extension, spawned by RunningBoard/ExtensionKit on demand (no launchd label is stored in the root; the process is named by its executable). Roles are the `PRSupportedRoles` of each Info.plist (`LockScreen`, `Ambient`, `IncomingCall`).

| Extension (executable, bundle id) | roles | Metal use, from its own binary/frameworks | own `.metallib` |
|---|---|---|---|
| `MercuryPosterExtension` (`com.apple.MercuryPoster`, "Collections", `/System/Library/ExtensionKit/Extensions/`) | LockScreen | links Metal + MetalKit directly | yes (22 fns, 5 translate) |
| `Unity2025Poster` ("Unity Rhythm", ExtensionKit) | - | Metal + MetalKit; framework `WatchFacesWallpaperSupport`: `CAMetalLayer`, `newCommandQueue`, `newDefaultLibrary` | yes (2/2) |
| `PridePosterExtension` (ExtensionKit) | - | Metal + MetalKit + MPS, `WatchFacesWallpaperSupport` | yes (12/17) |
| `KaleidoscopePoster` (`com.apple.WatchFacesWallpaperSupport.KaleidoscopePoster`, in `WatchFacesWallpaperSupport.framework/PlugIns`) | - | Metal; same framework | yes (6/6) |
| `AegirPoster` (`com.apple.NanoUniverse.AegirProxyApp.AegirPoster`), `ExtragalacticPoster`, `RhizomePoster` | - | Metal (Aegir) / the same `WatchFacesWallpaperSupport` Metal view | via the framework |
| `MonogramPosterExtension` (`com.apple.ContactsUI.MonogramPosterExtension`) | IncomingCall | Metal + MetalKit + MPS, `MonogramPoster.framework` | yes (6/6) |
| `WeatherPoster` (`com.apple.weather.poster`, in `Weather.app/PlugIns`) | LockScreen | Metal + VFX; `WeatherUI` `WeatherVFXView` (`VFXView` over Metal) | `WeatherUI`: default + `ForegroundEffectShaders` (28/31) |
| `AvatarPosterExtension` (`com.apple.AvatarUI.AvatarPosterExtension`) | IncomingCall | `AvatarKit`: `SCNRenderer`, `newCommandQueue`, `default.metallib` | AvatarKit 311 of 955 translate (`air.position_in_patch` tessellation 427, pointer stores 205) |
| `PhotosPosterProvider` (`com.apple.PhotosUIPrivate.PhotosPosterProvider`), `AmbientPhotoFramePosterProvider` | LockScreen, IncomingCall / Ambient | `PhotosUICore`: `MTLCreateSystemDefaultDevice`, `MTKView`, VFX story views; `NeutrinoCore` `NUMetalRenderer`/Metal compute (`NUComputeKernel`) for the photo pipeline | PhotosUICore, NeutrinoCore 2/2 each; VFX 402/571 |
| `ClockPosterExtension` (Ambient), `GradientPosterExtension` ("Color"), `EmojiPosterExtension`, `CollectionsPoster` (`com.apple.WallpaperKit.CollectionsPoster`), `LegacyPoster`, `InfographPoster`, `UnityPosterExtension` | various | no Metal strings in their frameworks: Core Animation / SwiftUI. SwiftUI-based ones (Clock, Emoji) may reach `RenderBox` (Metal, `newDefaultLibraryWithBundle`, 16/61 translate) for effects | RenderBox only |

**Processes that are not extensions but issue Metal work for posters.** (1) `PosterBoard` itself: `PosterBoard.framework` uses `+[CARenderer rendererWithMTLTexture:options:]` (snapshots into IOSurfaces: `createSnapshotUsingIOSurface:...`, `setBackgroundGPUPriority:`). (2) `SBRendererService.xpc` (`com.apple.springboard.SBRendererService`, XPC `ServiceType Application`, `/System/Library/PrivateFrameworks/PaperBoardUI.framework/XPCServices/`): links PosterKit, PosterBoardServices, QuartzCore, CoreImage; `PaperBoardUI` holds an `<MTLDevice>` and `<MTLCommandQueue>`, `contextWithMTLCommandQueue:options:` (CIContext) and `rendererWithMTLTexture:options:`: the wallpaper/poster treatment and snapshot renderer. (3) `SpringBoard`: `SBFCARendererImpl` in `SpringBoardFoundation` (`renderTreatedWallpaperImage:`, `renderMaterialImage:`, system-aperture fill) uses `rendererWithMTLTexture:options:`. (4) The render server, `backboardd`, only composites. **Consequence:** (1)-(3) take a Metal device only if `MTLCreateSystemDefaultDevice` gives one; they run without one today (their fallback is not known statically). They are *not* injection targets in this design, and the first test must show that leaving them device-less is what we want. Injecting only the extensions keeps the CA/ES path of everything else unchanged.

### i2. In-process registration design

A dylib `bgmtl-poster.dylib` (+ `libbgair.dylib`, `libdrm.2.dylib` beside it in `/usr/local/lib/bgmtl/`), linked into each target appex executable as an extra `LC_LOAD_DYLIB` exactly like Renegade's `posterboard` tweak does for `sweetfp.dylib` (`tools/sweetnet/addlc.py`, ad-hoc re-sign keeping entitlements, the dylib installed first so no binary ever names a missing library). It must be per appex executable: the posters' frameworks are in the dyld cache and cannot be touched. Constructor, in order:
1. **Gate**: process allow-list (executable path), a file switch (`/var/mobile/Library/bgmtl/allow`) and boot-arg, kill-switch file or `bgmtl=0` -> do nothing; **dead-man in the process**: a launch marker written at load and cleared after 20 s alive; two unclean exits in a row disable the dylib for that process until the file is re-armed.
2. **GPU state**: `SWEET_GPU_SEL_INFO`, `flags & 3` (ready/lost; works on ABI minor 1 and 2): lost or not ready -> no device. Any failure after this point also leaves the process device-less, never half-registered.
3. **Create** `BGMTLDevice` (opens its own `SweetAdreno630` connection; the sandbox of an extension must admit `iokit-open` for the user-client class: `sweetgpuuc=1` publishes `AGXDeviceUserClient`, which the stock profiles name; unverified for these extensions).
4. **Register in this process only**: preferred, the private `MTLAddDevice(id)` that Metal's own discovery calls (so `MTLCreateSystemDefaultDevice` and `MTLCopyAllDevices` answer ours here and nowhere else; no IOKit property is published; `IOAcceleratorES` keeps no `MetalPluginName`). Not yet measured on iOS 18: `MTLAddDevice` asserts conformance to `MTLDevice` and `MTLDeviceSPI` (done) and reads `featureProfile`, `maxBufferLength`, `supportsVertexAmplificationCount:`, then fills ~64 limits and 42 feature queries from `featureProfile` (hackios, 16.5: only profiles 0, 1 and 4-9 survive; MPS asks `supportsFamily:` from Apple8 down to Apple2, so profile 1 is the floor). The first test should be a throw-away tool doing exactly this call. Fallback if it asserts or leaks state: interpose `MTLCreateSystemDefaultDevice`/`MTLCopyAllDevices`/`MTLCopyAllDevicesWithObserver` through `__DATA,__interpose` of the dylib (dyld applies interposing to cache images through the patch table).
5. Honest `-supportsFamily:`/limits so that MPS/MetalKit/SceneKit/VFX do not take paths the device cannot serve; unsupported features answer refusal by name, not a crash.

**What CAMetalLayer needs** [V statically, hackios 16.5 measurements; iOS 18 not run]: `layer.device = ours`; `nextDrawable` makes an IOSurface and sends the device exactly one message, `-newTextureWithDescriptor:iosurface:plane:`, and the texture must *be* that memory (done: kernel `SURFACE_BO` import, linear, no UBWC, `rwa_texture_from_surface`); the pass writes it; `presentDrawable:` must run after the GPU work is complete and its pixels visible (done in the test device: present after the fence, clean+invalidate of the kernel alias via `BO_SYNC`, `rwa_texture_flush_surface`), and the present itself goes through CA's own client path (`CAMetalDrawable present` -> `CAImageQueue`, IOSurface id to the render server, no device involvement). The ES render server then draws that surface as the layer's contents. Drawable surfaces must be BGRA8 (plain 8-bit; UniXNU needed the render server's own format flags cleared, which does not apply here because backboardd never sees Metal). Real swapchains: CA allocates 2-3 drawables per layer; the kernel imports each ID once (idempotent) and the BO handle must be released with the texture.

### i3. Pieces, in the order the posters need them

1. **IOSurface textures + CAMetalLayer drawables**: implemented in the test device (this commit), probe `test/bgmtl_layer_probe.m` written, **not run**.
2. **Real vertex stages**: a QuartzCore vertex shader (`std_vert0_lpf`) with a `[[stage_in]]` vertex descriptor, buffers at 2 and 3, paired with our fragment stage, draws exactly on softpipe through libbgair (`test/bgair_vertex_test.c`, 3,664/3,664 pixels); the same on the Adreno is pending phone time. The extensions use their own shaders: the translatable share of their libraries is above (Mercury 5/22 is the weak one: arrays "where a number belongs", pointers where a number belongs; Pride 12/17, Weather 28/31, Kaleidoscope, Monogram, Unity2025 complete).
3. **Command buffer/queue completeness** that MetalKit and the posters' own code call: shared events and fences (true stubs), `MTLCaptureScope`-free paths, depth/stencil state (not yet: `newDepthStencilStateWithDescriptor:` is unanswered; Mercury/Unity-style 3D need it), indirect/argument buffers (frontend has argument buffers), heaps (stubs that are true), the 15+15+5 unanswered protocol methods of h3, `MTKView` (needs `CAMetalLayer` path above + `MTLCommandQueue` presentation).
4. **Frontend gaps per extension**: Mercury arrays/pointers (check `air_to_nir` "an array where a number belongs"), AvatarKit tessellation (`position_in_patch`, 427: Memoji poster, IncomingCall only), VFX argument buffers (`globals`, 52) for Weather/Photos, RenderBox vector function constants (25) for SwiftUI effects.
5. **Reference for correctness**: softpipe is now usable for float shaders (h5/h7); 29 of the 37 comparable CoreAnimation fragment shaders are bit-identical to the Adreno (h7); the poster libraries' shaders are not yet swept.

Order by value: drawables first (nothing else renders to a layer without them), then the vertex-stage run on the Adreno, then depth/stencil, then the per-extension gaps starting with the extensions with complete libraries (Kaleidoscope, Monogram, Unity2025, Weather, Pride) rather than Mercury.

### i4. The stock default wallpaper of a fresh iPhone11,8 on 18.7.8, and what it means for the plan [V statically]

* **What it is.** `/Library/Wallpaper/DefaultWallpapers~iphone.plist` has no `iPhone11,8` entry, so `WKDefaultWallpaperManager` (WallpaperKit) answers its `default`: collection `62879BFA-F700-4384-83E1-7AD1CC0D0817` = **"iOS 17"** (`/Library/Wallpaper/Collections/iOS_17~iphone.wallpaperCollection`, `com.apple.wallpaper.iOS17`), wallpaper identifier **7565** (`7565.iOS_17-414w-896h@2x~iphone.wallpaper`, type `LayeredAnimation`, `appearanceAware`, prominent colour `#FFAE4E` / dark `#FF5F85`).
* **Which poster provider.** PosterBoard's `PBFInitialPosterHelper` ("Setting up default wallpaper(s)"; `shouldInstallCollectionsPosterAsDefaultLockScreenWallpaper`, `shouldInstallHeroPosterAsDefaultLockScreenWallpaper`, a hardwired fallback string `com.apple.WallpaperKit.CollectionsPoster:5010`) installs the **Collections poster, `com.apple.WallpaperKit.CollectionsPoster`** (`WallpaperKit.framework/PlugIns/CollectionsPoster.appex`, role LockScreen); provider and descriptor are written `provider:descriptor`, and the descriptor of a Collections poster is the wallpaper identifier (`5010` is Bokeh/Multicolored), so the stock default is `com.apple.WallpaperKit.CollectionsPoster` / `7565` (not verified on a running PosterBoard; the Hero-poster branch of the helper is the other candidate for a fresh install and was not decoded). It is **not** `MercuryPoster` (also titled "Collections"): that one is `experimental2024` / `UnderDevelopment` and its shaders are SDF "fluidity" Metal.
* **Does it use Metal.** No. The wallpaper is two Core Animation packages (`...Background...ca`: 5 CALayers, 25 CGImages, 264 spring animations; `...Floating...ca`: 13 CALayers, 126 CGImages, 672 spring animations; HEIC assets, 11 MB) and `CollectionsPoster` / `WallpaperKit` contain no Metal strings. **There are no shaders to translate**: 0 of 0. It renders as ordinary layers through the render server, i.e. on the ES path today, and needs no device injection at all.
* **How it is selected.** `tools/sweetnet/sweetposterset COM.APPLE.WALLPAPERKIT.COLLECTIONSPOSTER DESCRIPTOR` through SweetRun in the mobile domain, as Renegade's `wallpaper` feature already does for the Gradient poster: `sweetposterset com.apple.WallpaperKit.CollectionsPoster 7565` (descriptor spelling to be confirmed from `fetchPosterConfigurationsForRole:` once on the phone). Renegade currently picks Gradient "no Metal"; whether the Collections poster works unchanged on the ES renderer has not been tried, and should be the first experiment because it needs no Metal work.
* **Consequence for the injection plan.** The stock default is **not** a Metal target. The first Metal target should be a poster whose own library translates completely and whose frameworks use Metal directly: `KaleidoscopePoster` (6/6), `Unity2025Poster` (2/2) or `MonogramPosterExtension` (6/6; IncomingCall role only); Weather (28/31 plus VFX) comes after. Restoring the stock default and proving Metal injection are therefore two independent tasks.

## (j) Mercury first, then the render server (plan of 2026-10-23)

### j1. Mercury (the stock iOS 18 wallpaper) is the first Metal target
Read back from the phone (fetch only): the selected lock configuration after the user chose the stock iOS 18 wallpaper is `com.apple.MercuryPoster` / descriptor **`fluidity.two`** (other Mercury configurations: `fluidity.one`, `fluidity.dynamic`; the Collections provider offers the descriptors `7365`, `5010`, `400`; `7565`, the iOS 17 wallpaper, is not a descriptor of it, which is why creating it failed with -2218). Selecting it without a Metal device gave a black screen and `MercuryPosterExtension` relaunching repeatedly. The user approved injecting `BGMTLDevice` into `MercuryPosterExtension.appex` only.

*Translation of Mercury's library* (`/System/Library/ExtensionKit/Extensions/MercuryPosterExtension.appex/default.metallib`, 22 functions): **all 22 translate and compile for a630** (was 5): `fluidity::` (the `fluidity.*` posters: sdf/plain vertex and fragment), `pro24Main*`, `post*`, the nine `tori::*` stages and the four `shippou::*::compute` kernels. Closed on the way: `air.sincos`/`fast_sincos` with an out-pointer, aggregates (arrays, `metal::matrix`) passed and returned by value as one parameter per leaf, aggregate phis (one register per leaf), undef aggregate leaves, varying packing (scalars past the 12th share vec4 slots; ir3 has 32 output slots and `tori` returns 55 members), and function-pointer tables (`[4 x ptr]` locals filled with function addresses and called through a run-time index: every entry is called and the results selected by the index). Nothing has been run on the GPU yet: translation and ir3 compilation only. System wide the same changes give +156 translations over the 163-of-178 QuartzCore baseline's corpus with no regressions (8,407 of 11,793 entry points translate; 8,364 compile).

*What Mercury asks of Metal* (selectors in its binary): `newCommandQueue*`, `newDefaultLibrary`/`newLibraryWith*`, `newFunctionWithName:`, `newRenderPipelineStateWithDescriptor:error:`, compute pipelines, `newBufferWith*`, `newTextureWithDescriptor:`, `newSamplerStateWithDescriptor:`, **`newDepthStencilStateWithDescriptor:`** (it has `depthState`/`depthTexture`: **not implemented yet**), `commandBufferWithDescriptor:`, `commandBufferWithUnretainedReferences`, `addCompletedHandler:`, `addPresentedHandler:`, `drawPrimitives`/`drawIndexedPrimitives`, `dispatchThreadgroups`, `getBytes:`, `CAMetalLayer` drawables (done, h5/i), MetalKit texture loading (`MTKTextureLoader`: textures and `replaceRegion`, possibly blit mipmap generation). Entitlement of note: `com.apple.QuartzCore.secure-mode`. The extension has no `com.apple.security.app-sandbox` entitlement; whether its profile admits `iokit-open` of our GPU user client is unknown until the first live run (the dylib stays device-less if the open fails).

*Injection dylib* `gpu/metal/inject/bgmtl_inject.m` -> `bgmtl-inject.dylib` (built, not installed anywhere): allow-list by bundle id (`com.apple.MercuryPoster`), inert unless `/private/var/tmp/bgmtl.arm` exists, kill switch `/private/var/tmp/bgmtl.off`, in-process dead-man (two unclean launches write `bgmtl.off`; 15 s alive resets), GPU state gate (`flags & 3`), refuses to register a device that cannot reach the GPU, registers with `MTLAddDevice` in that process only, watchdog thread: kernel state LOST or 3 failed command buffers -> `bgmtl.off` and `_exit(0)`. Linked into the extension executable like `sweetfp.dylib` (`addlc.py`, ad-hoc re-sign keeping entitlements). Renegade feature `bgmtl`: off by default (rebrand worktree).

### j2. After Mercury: the render server on BGMTLDevice (long term; the ES renderer stays the default and the fallback throughout)
(a) *Map the choice* (static, Mac): how QuartzCore in backboardd picks `CA::OGL::` Metal vs OpenGL ES (`h`/a: Metal first via `MTLCreateSystemDefaultDevice`; which `MTLDevice` features and `supportsFamily:` it checks; what it needs from IOSurface, IOMobileFramebuffer and the display path; the 13 `air.imageblock` tile kernels and their non-tile fallbacks).
(b) *Offscreen first, in a test process*: `+[CARenderer rendererWithMTLTexture:options:]` on our device renders a layer tree into an IOSurface texture; compare with the ES renderer's output of the same tree (the CPU/ES comparison infrastructure of this document).
(c) *Close the gaps*: depth/stencil state, blend states beyond the corpus, the tile kernels, the ubershader generic path (null textures chosen at run time), function-pointer tables, remaining protocol methods.
(d) *Only then* a backboardd switch: boot-arg or marker gated, dead-man protected injection (like the `bglrender` launcher), automatic fall back to ES. **No backboardd injection without the owner's approval and a dead-man.**

## (d) Risks

1. **Zap shader / secure CP** (largest): without a signed `a630_zap` accepted by TZ the CP stays secure and no GPU use is possible on this phone; SMC convention on SDM845 (probe both SMC32/64); files come from the phone's Android vendor partition.
2. **GMU/HFI/SMMU debugging without JTAG**; silent resets from bad accesses (the 778G project reports hypervisor kills "a quarter of a minute later"); the GPU SMMU must be 4 KiB granule while iOS is 16 KiB.
3. **CoreAnimation's reaction to a non-nil Metal device** (hang/black/crash if any required selector or pipeline is missing; UniXNU saw frozen SpringBoard). Mitigation: nil-or-complete rule; software fallback on device-lost; test with a detached process first.
4. **iOS 18 IOGPU kernel ABI is unknown** (A12 `IOGPUDeviceUserClient` dispatch table and event-machine layout, selector semantics beyond sizes). Mitigation: decode the 22H352 kernelcache IOGPUFamily and the AGX kext; keep GLES route as the first GPU payoff.
5. **GLES route on iOS 18 untested**: gating (`CA_ENABLE_OGL`), CA GLES shader coverage, vibrancy/blur effects, performance of GLES-over-Mesa for the whole UI, arm64e injection. Fallback to software remains available.
6. **Compiler availability for Metal**: the device-path `MTLCompiler` returns A12 code unless a pass-through is possible; air2ir3 is a8xx-tuned (binding ABI, limits) and its C API is at version 2; LLVM version of iOS 18's AIR vs the 22 it parses is unverified.
7. **Licensing posture**: Linux GPL-2.0 sources are references only; Snapintosh umbrella carries a GPL-2.0-only table; hackios code is APSL-2.0.
8. **Performance**: a630 has GMEM tiling and UBWC; first versions will be sysmem/linear only (Snapintosh and the 642L project do the same) and DDR bandwidth voting is the CPU's job on a630.
9. **Kernel migration** may change IOKit behaviours subtly (IOMapper/IODMACommand semantics, user-client filters); keep GPU memory/mapper code behind a small layer.
10. **Disk/CI**: shaders, Mesa and LLVM builds are large; plan builds on the Mac/CI, not on the phone.

## Appendix: reproduction of the iOS 18 findings

`python3 tools/renegade/hfsx.py research/ios18/ios18-root-full.simg dsc $SCRATCH/dsc` (4 GB, delete afterwards), a venv with `capstone`, then
`DSC_DIR=$SCRATCH/dsc python3 research/metal-a630/tools/objc_classlist.py AGXMetalA12.bundle/AGXMetalA12 --methods` and
`... tools/iokit_selectors.py IOGPU.framework/IOGPU`. Outputs are in `research/metal-a630/lists/`.

### Mercury live probe, 2026-10-23 (kernel 473d1e1)

- Program-scope constant tables (`constant [6 x <2 x float>] [...]` in postVertex's fixed quad) were placed in scratch and never initialised, so every vertex read zeros and nothing was drawn. The frontend now stores the initializer bytes into scratch at entry (`init_scratch_globals`). With it, Mercury's fluidity, pro24 and post pairs draw on the Adreno; fluidity::sdf still shows no coverage with the probe's synthetic uniforms (unexplained).
- `filter::bicubic` samplers are now accepted and sampled as linear. This is an approximation (Apple's exact bicubic kernel is not attested); pro24 needs it to run at all.
- SpringBoard crashes at 17:11-17:14 are BSSqlite (BaseBoardUI) with no poster or Mercury frames; no crash report exists for MercuryPosterExtension or PosterBoard.
- The kernel's Sandbox policy (patch 0050) accepts every check, so Mercury can open SweetAdreno630.

### Mercury offline findings, 2026-10-23

- fluidity::sdfFragmentShader writes `[[color(1)]]` (`air.render_target 1`), and fluidity::fragmentShader writes color(0) and color(1). The probe attached only color(0), which is why the sdf pass drew "nothing": it was not broken. The probe now attaches a second target (not yet re-run on the phone).
- Loop pipelines: every loop exit in tori::{one..five}::torusFragment (12 each) and shippou::{one..four}::compute (17 each) compares a loop-carried counter against a value built from constants (tori: -0.5 stepping +0.2 until 0.5, about 6 iterations). A heuristic NIR scan found no non-constant bound. The counter increments were not scanned, so this is still a heuristic. softpipe cannot be the reference for them: the fragments need f16 (`f2f16`) and the vertex stages use scratch, which softpipe's nir_to_tgsi refuses.
- Renegade `bgmtl()` was run against a fake root (os.chown stubbed, no sudo): the dylibs and the patched MercuryPosterExtension come out byte-identical to the files on the test phone, a second run is a no-op, and RENEGADE_BGMTL_ARM=1 writes bgmtl.arm.

### j2 (a) first findings, 2026-10-23: renderer selection in iOS 18.7.8 QuartzCore (static, strings only so far)

- QuartzCore carries `CA_ENABLE_OGL` (environment), `CoreAnimation: Failed to initialize Metal or OpenGLES contexts!`, `kCARendererMetalCommandQueue`, `CA_METAL_IMAGE`, `CA_INCLUDE_METAL_IN_FRAMELIFETIME`, `CAEnableMetalWhippet`, and `CoreAnimation: disabling OpenGL extension %s`. The wording says the default renderer is Metal and OpenGL ES is the opt-in, so the ES renderer of this port is reached through `CA_ENABLE_OGL` and a Metal switch means leaving it unset in backboardd with a registered MTLDevice. Which of the two the server picks when both are available, and what it asks the device for (supportsFamily: calls, the pixel formats and IOSurface paths), is still to be decoded from the code that reads these strings.
- Next in (a): decode the reader of `CA_ENABLE_OGL`, the device requirements (`supportsFamily:`, feature queries), and the server-side CAMetalLayer/IOMobileFramebuffer present path. (b) needs a test-process CARenderer rendererWithMTLTexture harness; (c) imageblock tile kernels need non-tile fallbacks.


### j2 (a) device requirements and renderer wiring (static, iOS 18.7.8 QuartzCore, 2026-10-23)

What QuartzCore sends to an MTLDevice/queue/encoder (selector strings of the binary; the Metal path has no GL fallback inside CoreAnimation, `CA_ENABLE_OGL` only turns the ES path on):

- **Device**: `supportsFamily:`, `supportsTileShaders`, `supportsRasterOrderGroups`, `supportsMemorylessRenderTargets`, `supportsSIMDGroup`, `supportsSIMDReduction`, `supportsSIMDShuffleAndFill`, `supportsExtendedColors`, `supportsColorSpaces`, `registryID`, `newLibraryWithURL:error:`, `newBinaryArchiveWithDescriptor:error:`, `newFunctionWithDescriptor:error:`, `newRenderPipelineStateWithDescriptor:[options:reflection:]error:`, `newRenderPipelineStateWithTileDescriptor:options:reflection:error:`, `newComputePipelineStateWithFunction:error:`, `newDepthStencilStateWithDescriptor:`, `newSamplerStateWithDescriptor:`, `newBufferWithLength:options:`, `newBufferWithBytesNoCopy:length:options:deallocator:`, `newTextureWithDescriptor:`, `newTextureWithDescriptor:iosurface:plane:`, `newTextureWithBytesNoCopy:length:descriptor:deallocator:`, `newLinearTextureWithDescriptor:offset:bytesPerRow:bytesPerImage:` (texture over a buffer), `newTextureViewWithPixelFormat:[textureType:levels:slices:[swizzle:]]` (texture views, with swizzle), `newHeapWithDescriptor:`, `newTextureLayoutWithDescriptor:isHeapOrBufferBacked:` (SPI), `newSharedEventWithHandle:`, `newCaptureScopeWithCommandQueue:`, `setPurgeableState:`, `makeAliasable`.
- **Command buffer / encoders**: `renderCommandEncoderWithDescriptor:`, `computeCommandEncoderWithDispatchType:`, `blitCommandEncoder`, `addScheduledHandler:`, `addCompletedHandler:`, `waitUntilScheduled/Completed`, `presentDrawable:` variants.
- **Where the device comes from**: CARenderer/CAMetalLayer ask `MTLCreateSystemDefaultDevice` / `MTLCopyAllDevices`, so an in-process `MTLAddDevice` (MTLCopyAllDevices first: the registration asserts on a missing `_deviceArray`) serves both. CAMetalLayer server side needs `newTextureWithDescriptor:iosurface:plane:` (done) and a texture whose memory is the layer's IOSurface (done, linear).
- **The server object** that owns the renderer is built by the function at 0x1848cee40 (the Render server context: it reads `CA_ENABLE_OGL` once and then builds the GPU context through `0x18476d7c4`/`0x18488eff4`); the Metal/OGL choice itself is inside objc-message stubs whose symbols the shared-cache extraction does not keep, so the choice is best observed than decoded: the offscreen probe (below) logs every selector BGMTLDevice is asked and cannot answer.
- **Status of these in BGMTL**: implemented: buffers, textures (incl. iosurface), samplers, depth/stencil, compute and render pipelines, queue/command buffer/render/compute/blit encoders, shared-memory texture blits; answered zero and logged by the protocol fallback (`forwardInvocation:`): any other MTLDevice/MTLDeviceSPI selector; missing and needed: texture views (`newTextureViewWithPixelFormat:...`), linear textures from buffers, heaps, shared events, binary archives, `newFunctionWithDescriptor:`, tile pipelines and `dispatchThreadsPerTile:`, capture scopes. `supportsFamily:` is currently answered by `_MTLDevice`'s tables from `featureProfile` 1; the families CoreAnimation asks for have to be read off the first live run's log.

### j2 (b) offscreen CARenderer harness

`gpu/metal/test/bgmtl_carenderer_probe.m` (built into the probe set, not yet run on the phone): registers BGMTLDevice in the test process, makes a 256x256 BGRA texture, draws six scenes (translucent solid layers, an image, text, a rounded clip, a mask, a blur filter) through `+[CARenderer rendererWithMTLTexture:options:]` and compares with `-[CALayer renderInContext:]` (CoreAnimation's CPU renderer) by mean absolute channel difference, writing `sceneN.ppm`/`refN.ppm`. The ES renderer's output is not the comparison because it needs the ES bridge in the same process; the CPU renderer is the ground truth for solids, images, text, clips and masks, and the blur scene is judged by eye. Run: `bgmtl_carenderer_probe OUTDIR [scene]`, one scene per process when a scene aborts.

### j2 (c) gaps

1. **Tile kernels (13 of QuartzCore's 178 entry points; every other one translates and compiles).** `tile_downsample_{1,2,4,8}`, `tile_simd_blur_{5,7,11,15,19,23,27}`, `tile_average_luma[_quad]` take `air.imageblock` (layout `implicit`: `ColorData { half4 color [[color(0)]] }`), load pixels with `air.load.implicit_imageblock.v4f16(slot, pos, sample, 0)` and store with `air.store.implicit_imageblock`, and use `thread_position_in_threadgroup`, `thread_position_in_grid`, `threadgroup_position_in_grid`, `threads_per_threadgroup`, quad/simd shuffles, `simd_sum` and `get_simdgroup_size`. A non-tile fallback, designed here and not yet built:
   - the frontend maps `implicit_imageblock` loads/stores to texel reads/writes on the colour attachment texture of that slot at `tile_origin + pos` (a hidden uniform: `tile_origin = workgroup_id * tile_size`, `tile_size` taken from the render pass's tileWidth/tileHeight), as storage-image accesses of a compute dispatch;
   - the tile pipeline becomes a compute pipeline, `dispatchThreadsPerTile:` a compute dispatch with one workgroup per tile of the pass (the threadgroup is threadsPerTile; downsample uses `grid_pos = tile*tpt + group_pos`, so both ids derive from the workgroup id);
   - the colour attachment must be created with ShaderRead|ShaderWrite (the render target of a pass that uses tile kernels), linear and not UBWC;
   - stores into the imageblock are in place per tile with no cross-tile reads (checked in the dumps: reads stay inside the tile), so a barrier-free per-tile compute has the same result; simd/quad ops assume Apple's 32-wide simdgroup while the a630 wave is 64 wide, so `tile_simd_blur_*` and `tile_average_luma*` must be re-expressed through threadgroup memory (shuffle-and-fill-down and simd_sum over 32 lanes) rather than mapped to hardware subgroup ops.
2. **Blend states**: plumbed (`rwa_color_blend` filled from every colour attachment); no dedicated test yet. Add a P10 blend probe (src-alpha over a known destination) with the next phone run.
3. **Ubershader generic path** (`fixed_*` shaders with run-time pointer offsets): translates since the function-constant fold; the remaining case is a pointer chosen at run time between two argument-buffer sets, which still reports a named error.

### j2 (d) backboardd switch (designed, NOT armed, nothing built)

Principles: ES stays the default and the fallback; Metal needs three independent opt-ins and any one fault returns to ES without a person.

- **Gate (all must hold, checked by the dylib constructor in backboardd only)**: `/private/var/tmp/bgmtl-bb.arm` exists; `/private/var/tmp/bgmtl-bb.off` does not; the boot-arg `bgmtlbb=0` is not set; a pre-flight marker `/private/var/tmp/bgmtl-bb.ok` written by the offscreen CARenderer probe (a pass of the six scenes with no refused scene) is newer than the dylib; `bgmtl_gpu_state()==1`. Any file missing or lost (userdata may lose data, see the UFS investigation) means ES: the default is the absence of files.
- **What it does when open**: leaves `CA_ENABLE_OGL` unset for this launch, registers BGMTLDevice with the same sequence as Mercury (`MTLCopyAllDevices`, then `MTLAddDevice`) before QuartzCore creates the server context, and disables the ES bridge in the same process for this launch (the two paths exclude each other).
- **Dead-man**: stricter than Mercury's, because a backboardd crash loop blanks the whole UI: one unclean launch (state file `unclean>=1`) returns this and every later launch to ES and writes `bgmtl-bb.off`; the counter resets only after 30 s of presented frames. The in-process watchdog (1 Hz) trips on: GPU state lost or hangs>0 from the kernel; three failed command buffers; no completed present for 5 s while a drawable was requested; an unimplemented-selector log burst. A trip writes `bgmtl-bb.off` and `_exit(0)`s: launchd relaunches backboardd, which now comes up in ES mode.
- **Recovery without the phone's shell**: the kill switch is a file, so a Renegade first-boot rule can remove the arm file after N boots without a clean marker (`bgmtl-bb.clean`), and `bgmtlbb=0` in the boot-args overrides every file.
- **Rollout order**: (1) the CARenderer probe passes in a test process, (2) the tile fallback is in, (3) blend/ubershader gaps closed, (4) a supervised run with the user watching, SSH open and `bgmtl-bb.off` ready, (5) only then a Renegade option (default off) that writes the arm file.

### Mercury flicker analysis, 2026-10-23 (Mac only; found by reading the present and pass code while the phone was on hold)

Symptom: heavy flicker and a steady ~10 swaps/s while idle with Metal Mercury.

Defects found in BGMTL's render pass handling (fixed in the tree, NOT installed on the phone):
1. **One clear colour for every attachment.** The pass's clear was taken from attachment 0 only, passed to the first draw and applied by Gallium to all bound colour buffers. Mercury's fluidity pass writes colour(0) and colour(1): an attachment-0 clear destroyed a loaded attachment 1 (accumulated state) every frame, and a clear of attachment 1 never happened. Plausible cause of a picture that jumps between frames.
2. **A pass that draws nothing never cleared.** The clear lived inside the first draw and `rwa_render_draw` refuses a draw of no vertices; a clear-only pass was lost and the drawable (one of three rotating IOSurfaces) kept the picture from three frames earlier, which then got presented: flicker at the frame rate.
Fix: the pass's load actions are one piece of work of their own at the start of the pass (`BG_WORK_CLEAR` -> new `rwa_render_clear`), each attachment to its own colour, loaded ones untouched, depth/stencil likewise.

Other candidates, ranked, not yet confirmed:
- **Frame time**: `commit` is synchronous and the GPU sits at 257 MHz (level 1), so a heavy fluidity frame may take around 100 ms; the "10 swaps/s" could be the loop's real rate. Check with the new per-present log (below): commit ms per frame.
- **Presenting after the fence is correct, but flush covers only draws** (compute and blit writes into a drawable were not flushed); now draws and clears.
- **Drawable reuse while backboardd still samples it**: the ES compositor may copy a presented surface at its own time while the next frame of the same pool entry is being written. Not visible from this side; the log records the surface size and the commit gap.
- A black frame between passes shows as `mean texel value 0.0` in the new log.

Diagnostics added for the next supervised run: every present logs `present: N presents, D draws, C clears, up to A attachments, WxH, mean texel value V, commit X ms, at T s` to bgmtl.log (first 120, then every 30th, and every black one, tagged BLACK). Built into the inject dylib; not installed.
