# GPU kernel half: Adreno 630 keep-alive and the msm-style IOKit interface (Heartwood, xnu-11215)

Status 2026-10-23: **built (CI) and compile-checked, never run on the phone.** Phase C and D of `METAL_ADRENO630.md`
(kernel GPU user client; A630 bring-up). Everything here is OFF unless the boot-arg `sweetgpu=8` is given; without it the boot
path is byte-for-byte the one of patch 0103 (no `sweetgpu` => `sweet_a630_probe()` returns at once, no service is published).

Evidence tags: **[V]** read in the code/sources this session, **[I]** inferred, **[U]** untested on hardware.

## 1. What was added

Patches in `xnu/patches-11215/`, applied after 0103/0170 (the stage-1..7 bring-up of `GPU_A630_BRINGUP.md`, unchanged):

| Patch | Files | Content |
|---|---|---|
| `0180-beryllium-gpu-a630-firmware-dirs` | `bsd/dev/sweet_a630.c` | Firmware is also looked up in `/usr/local/share/firmware/` (after `/usr/standalone/firmware/sweet/`, then the ADT `/sweet-gpu`). Used by the GMU, SQE and zap loaders. |
| `0181-beryllium-gpu-a630-keepalive-kernel-api` | `bsd/dev/sweet_a630.c` | `sweetgpu=8`: stage 7 + a second CP self-test (256-byte `CP_MEM_WRITE` fill) and, when both pass, **the GPU is kept up** (GMU keep-alive, OOB_GPU held, zap left authenticated, CP ring live, no slumber, no GMU reset). A page-table pool and a GPU address allocator for client buffers in context bank 1; the C interface `sweet_gpu_*` (map/unmap, submit, fence, params). If the self-test fails, stage 8 shuts down exactly like stage 7 and publishes nothing. |
| `0183-beryllium-gpu-a630-sqe-max` | `bsd/dev/sweet_a630.c` | Found on hardware: `SQE_MAX` 0x8000 rejected linux-firmware's 34188-byte `a630_sqe.fw`. SQE window now 0x10000 bytes (phys 0xc000-0x1c000, VA 0x40010000, 0x40020000 left unmapped), scratch moved to phys 0x1c000 / VA 0x40030000; CP block stays 0x20000 bytes. |
| `0184-beryllium-gpu-a630-debug-selector` | `sweet_a630.c`, `SweetAdreno.cpp`, ABI header | After the first hardware run (stage 8 passed, user submissions never ran): selector `0x73` `SWEET_GPU_SEL_DEBUG` (40-word read-only snapshot: GMU power/fence/counter, gpucc GX/CX, SMMU CB1 faults, CP RPTR/WPTR/status/IB1; GPU-core words only when GX is on, so never a hang); the same dump in the kernel log on every wait timeout and first 8 submits (with WPTR readback); submits refuse (no hang, no silent drop) when GX is off and re-assert the AHB fence ALLOW; `PARAM_TIMESTAMP` now reads the GMU always-on counter (Linux does; the CP copy read over AHB did not advance). |
| `0185-beryllium-gpu-a630-4k-gpu-pages-fault-check` | `sweet_a630.c`, `SweetAdreno.cpp` | Found on hardware (8c, SMMU CB1 FSR 0x402 at BO+0x1000): xnu's PAGE_SIZE is 16 KiB, the GPU's page 4 KiB, and BOs were entered with one PTE per 16 KiB. Now one PTE per 4 KiB (each from its own physical address); the table pool uses 4 KiB tables; TLB flush after every map batch; a CB1 translation fault (FSR & 0xc00001fe, bit 10 is a stale status bit and is cleared before submits) is logged, cleared and declares the GPU lost, and `WAIT_FENCE` then fails at once with `kIOReturnIOError` instead of timing out. The context terminates faulting accesses (no CFCFG), so there is no CB_RESUME; the CP itself does not recover from a fault. |
| `0186-beryllium-gpu-a630-power-dcvs-recovery-metrics` | `sweet_a630.c`, `SweetAdreno.cpp` | Power, DCVS, recovery, metrics, UBWC params, BW-table fix: section 11. |
| `0187-beryllium-gpu-adreno-iosurface-import` | `SweetAdreno.cpp`, ABI header | Zero-copy import of client-memory (wrapped) IOSurfaces, idempotent `SURFACE_BO`, planes/flags: section 12. |
| `0188-beryllium-gpu-a630-governor-boost` | `sweet_a630.c` | Governor measures by sampling, interactive boost floor, CP stamps optional: section 12. |
| `0214-beryllium-gpu-sbo-writable-alias` | `SweetAdreno.cpp`, ABI header | ABI minor 2: `SBO_IN_WRITABLE_ALIAS`, a read-write CPU mapping of a client-memory surface BO (the surface's own mappings are read-only): section 12, "ABI minor 2". |
| `0215-beryllium-fb-gpu-copy-invalidate` | `SweetFramebuffer.cpp` | The copy path invalidates a pool surface the GPU wrote (announced by BO_SYNC) before the CPU reads it: `docs/DISPLAY_HW.md` 5.4. |
| `0182-beryllium-gpu-adreno-iokit-user-client` | `iokit/Kernel/arm/SweetAdreno.cpp`, `SweetAdrenoABI.h`, `iokit/conf/files.arm64` | IOService `SweetAdreno630` (published by `sweet_a630.c` after keep-up) and its user client with the msm ioctls as selectors. |

`xnu/gpu-abi/sweet_adreno_abi.h` is the userland-facing copy of the ABI header (byte-identical to `SweetAdrenoABI.h` of 0182).
`tools/gpu-fw-push.sh` copies the firmware over SSH.

What already existed and is reused unchanged (0103, `GPU_A630_BRINGUP.md`): CX GDSC + GMU clocks, RSC/PDC microcode, GMU firmware boot, GPU SMMU
contexts, HFI v1, GX rail through the GMU, SPTPRAC, SQE + ring in a GPU SMMU context, zap shader through TrustZone PAS id 13, `CP_ME_INIT`,
`CP_SET_SECURE_MODE 0`, NOP/MEM_WRITE/CACHE_FLUSH_TS test. 0103 itself was also never run on hardware: **stage 8 inherits all its unproven steps**
(see risks). The incremental path is `sweetgpu=1,2,3,...` one stage per boot, as documented there.

## 2. Boot-args

| Arg | Meaning |
|---|---|
| `sweetgpu=8` | the whole sequence and keep-up (above). `=1..7` unchanged stages of 0103. Only on the beryllium ADT. |
| `sweetgpuwait=SECONDS` | how long the worker waits for `a630_gmu.bin` (default 600). |
| `sweetgpuuc=1` | name the user client class `AGXDeviceUserClient` (the class the real iOS sandbox profiles allow, `GPU_PHASE0_DISCOVERY.md`) instead of `SweetAdrenoUserClient`. The service is not an IOAccelerator, so Metal never opens it. |
| `sweetaccel=0` | (existing, unrelated) the empty `IOAcceleratorES` stub of 0122 is separate from this service and still published by default. |

Add them with `CMDLINE="$(default) sweetgpu=8 ufslogsecs=1"` to `tools/renegade/mkboot-full.sh`.

## 3. Firmware

| File | Source | Status |
|---|---|---|
| `a630_gmu.bin` | linux-firmware `qcom/a630_gmu.bin` (redistributable) | present: `../ios-beryllium/research/gpu-fw/dl/` (32768 bytes) |
| `a630_sqe.fw` | linux-firmware `qcom/a630_sqe.fw` | present, same directory (34188 bytes, version word 0x016ee207 >= 0x190 [V]) |
| `a630_zap.mdt` + `a630_zap.b00 .b01 .b02` | **this phone's** Android `/vendor/firmware` (signed per device) | **not available**: not in `backup/*.img` (vendor.img is an ext4 without them; only boot.img/recovery.img mention the name) |

Never commit them. Copy to the phone's iOS root (SSH up, `root@192.168.7.2`):

```
tools/gpu-fw-push.sh -z /path/to/vendor-firmware     # gmu + sqe from ../ios-beryllium/research/gpu-fw/dl, zap files from -z
tools/gpu-fw-push.sh                                  # gmu + sqe only: stages 3, 4, 5 can run; 6-8 stop at the zap
```

They land in `/usr/local/share/firmware/` (mode 644); the kernel reads them with `vnode_lookup`+`vn_rdwr` once `rootvnode` exists. Without the file system
the same data can be given as ADT `/sweet-gpu` properties (`gmu-firmware`, `sqe-firmware`, `zap-mdt`, `zap-b00..`) with `tools/mkadt.py`.
Getting the zap: `adb root; adb pull /vendor/firmware/a630_zap.mdt` and `a630_zap.b0*` from a running Android on the phone, or from a LineageOS beryllium vendor image
(ROM-matched, ideally the stock-signed one the bootloader chain of this phone expects). The mainline `a630_zap.mbn` is a squashed form; split it first
(`pil-squasher` in reverse), the loader reads mdt + bNN.

**What happens without the zap:** stage 6/7/8 log `a630_zap.mdt missing or invalid`, no CP command beyond `CP_ME_INIT` runs, and stage 8 shuts down like stage 7.
Why it is mandatory [I]: after reset the CP and the GPU memory path are in secure mode; `CP_SET_SECURE_MODE 0` only works with the zap shader running in the secure world
(Linux a6xx_hw_init does the same; without a zap it must write `RBBM_SECVID_TRUST_CNTL`, a secure register, which 0103 deliberately never touches: an XPU violation resets the SoC).
If `SCM PAS INIT_IMAGE` returns non-zero or never returns, see `GPU_A630_BRINGUP.md` risks 2 and 3 (missing crypto/BCM vote is the first suspect).

## 4. Expected live log (UDP 5140, `logs/usb-*.txt`)

Every line starts `SWEET GPU:`. In order for a good run of `sweetgpu=8` (stage lines as in `GPU_A630_BRINGUP.md`, abbreviated):

```
waiting for a630_gmu.bin ...                         (only until the root is mounted and the files exist)
Adreno 630 bring-up, stage 8 (GPU 0x5000000, GMU 0x506a000, gpucc 0x5090000, SMMU 0x5040000)
CX GDSC on: gdscr 0x...  /  GMU RCG 200 MHz ... cfg 0x00000602
GMU memory at 0x...  /  SMMU CB0: SCTLR 0x00c01067 ...
CP memory at 0x...: ring VA 0x40000000, SQE VA 0x40010000, scratch VA 0x40020000
CP memory setup complete: CB1 ASID2 SID0 SMR2
GMU BOOTED (FW_INIT_RESULT ok) after NN us
HFI up: ... / HFI start complete (DCVS, BW, TEST acknowledged)
GX rail on at level 1 (257 MHz) / OOB boot_slumber (boot): acknowledged / SPTPRAC power on: ok / OOB gpu: acknowledged
CP SQE enabled / CP CP_ME_INIT: ring idle (RPTR=WPTR=9)
SCM PAS INIT_IMAGE completed=1 status=0 result=0 ... signed zap authenticated and started
CP CP_SET_SECURE_MODE 0: ring idle
CP NOP test: CP_MEM_WRITE read back 0x5ee70001 ..., timestamp 0x600d0001 ...
CP NOP test PASSED: the CP fetched, executed and wrote back through the GPU SMMU
CP fill test: 0 of 64 words wrong, timestamp 0x600d0002 ...
CP fill test PASSED
KEPT UP: GX on (OOB_GPU held, GMU keep-alive), ring 8192 dwords at RPTR=WPTR=NN, client VA 0x80000000-0x100000000, 256 table pages
stage 8 finished: GPU kept up, publishing SweetAdreno630
SweetAdreno630 published (user client class SweetAdrenoUserClient)
```

Failure signatures: `TIMED OUT` (OOB/GMU), `HFI ... no reply`, `SMMU TLB sync timed out`, `ring did NOT drain` (followed by RPTR/WPTR/CP_HW_FAULT/CP_IRQ and the SMMU context fault registers),
`zap load failed`, `stage 8 self-test did not pass; shutting the GPU down like stage 7`. A phone that freezes with no further UDP lines after a given line was stopped by a bus hang at that access (risks).
After the interface is up: `SWEET GPU: GPU LOST (no completion)` plus a register dump means a submission never completed (no recovery, reboot).
A client test then shows `SweetAdreno630` in `ioreg -l`.

## 5. Kernel-internal interface (`bsd/dev/sweet_a630.c`)

All calls are serialized by the caller (the IOKit side holds one `IOLock`); none is callable before `sweet_gpu_ready()`.
`sweet_gpu_iova_alloc/reserve/free` (first-fit allocator with 1 page unmapped guard, range 0x80000000-0xfffff000), `sweet_gpu_vm_map/unmap` (4 KiB pages, tables from a 1 MiB pool of non-cacheable pages,
`TLBIALL`+sync after unmap), `sweet_gpu_submit` (ring: 2 CCU invalidate events, one `CP_INDIRECT_BUFFER` per IB, `CP_EVENT_WRITE CACHE_FLUSH_TS` writing the sequence number to
`SCRATCH_VA+0x200`, as the tail of Linux `a6xx_submit`), `sweet_gpu_fence_done/last`, `sweet_gpu_param`, `sweet_gpu_mark_lost/report`, `sweet_gpu_cache_sync`.
Static GPU VAs (context bank 1, ASID 2): ring 0x40000000 (32 KiB), SQE 0x40010000 (read-only), scratch 0x40020000. GMU context bank 0 is separate.

## 6. IOKit ABI (`xnu/gpu-abi/sweet_adreno_abi.h`)

Service: `IOServiceMatching("SweetAdreno630")`, `IOServiceOpen(service, mach_task_self(), 0, &conn)`. Properties: `SweetGPUABIVersion` = 1, `SweetGPUChipID` = 0x06030001.
Calls: `IOConnectCallStructMethod(conn, selector, &in, sizeof(in), &out, &outsize)`; the structure is passed in and, where the table says so, back (out size must be >= sizeof).
Selector = Linux `DRM_COMMAND_BASE (0x40) + DRM_MSM_*`, structures are the msm uapi ones, so `drmIoctl(fd, DRM_IOCTL_MSM_*, &arg)` in a libdrm stand-in forwards 1:1.

| Selector | msm ioctl | Struct (in/out) | Behaviour |
|---|---|---|---|
| 0x40 | GET_PARAM | `msm_param` in/out | `pipe` ignored. GPU_ID 630, GMEM_SIZE 0x100000, CHIP_ID 0x06030001, MAX_FREQ 710000000 (runs at 257 MHz), TIMESTAMP (CP_ALWAYS_ON, 19.2 MHz), GMEM_BASE 0x100000, PRIORITIES 1, PP_PGTABLE 0, FAULTS 0, SUSPENDS 0, VA_START 0x80000000, VA_SIZE 0x80000000. Anything else: `kIOReturnUnsupported` (Mesa then uses defaults: HIGHEST_BANK_BIT, UBWC_*, MACROTILE_MODE, SYSPROF...). |
| 0x41 | SET_PARAM | - | `kIOReturnUnsupported` |
| 0x42 | GEM_NEW | `msm_gem_new` in/out | size rounded to 4 KiB, 1 B..256 MiB; flags `SCANOUT`/`GPU_READONLY` kept, cache flags ignored: **every BO is write-combined**; zero-filled; handle >= 1 (4096 per client). The BO is immediately mapped in the GPU address space (always resident). |
| 0x43 | GEM_INFO | `msm_gem_info` in/out | `GET_OFFSET` -> value = handle (use it as `memoryType` of `IOConnectMapMemory64`); `GET_IOVA` -> GPU address; `GET_FLAGS`; `SET_NAME` accepted and ignored; `SET_IOVA` (softpin) moves the BO to a free, 4 KiB-aligned range inside [VA_START, VA_START+VA_SIZE) if it was never submitted. |
| 0x44 / 0x45 | GEM_CPU_PREP / FINI | `msm_gem_cpu_prep` / `msm_gem_cpu_fini` | PREP waits for the last submission that wrote (READ) or used (WRITE) the BO unless `NOSYNC` (then `kIOReturnBusy` if not done). **timeout is relative** `{sec,nsec}`, {0,0} polls (`kIOReturnTimeout`). FINI is a `dsb sy`. |
| 0x46 | GEM_SUBMIT | `msm_gem_submit` in/out | bos/cmds/relocs are user pointers (read in the caller's task). `flags` must be 0 (`NO_IMPLICIT` tolerated); fence fds and syncobjs are not supported (`kIOReturnUnsupported`). cmd types BUF and CTX_RESTORE_BUF run as indirect buffers; PRIMARY unsupported. `submit_offset`/`size` multiples of 4 inside the BO. Relocations are applied to the cmd BO through its kernel alias (`(iova + reloc_offset) shifted, | or`, low 32 bits). Out: `fence` (> 0), `fence_fd = -1`. `presumed` is ignored. Up to 4096 bos, 128 cmds. In-order single ring: no preemption, no priorities. |
| 0x47 | WAIT_FENCE | `msm_wait_fence` | **relative** timeout; `kIOReturnTimeout` when not done; `kIOReturnBadArgument` for a fence never submitted. A wait that asks for 5 s or more (e.g. "infinite") and is still not done after 5 s declares the GPU lost (shorter waits just time out). |
| 0x48 | GEM_MADVISE | `msm_gem_madvise` in/out | `retained` = 1 |
| 0x09 | GEM_CLOSE | `drm_gem_close` | unmaps and frees (waits up to 2 s for the last submission that used it; if the GPU did not finish, the BO is **leaked** on purpose) |
| 0x4a / 0x4b | SUBMITQUEUE_NEW / CLOSE | `msm_submitqueue` / `uint32_t id` | ids 1..63, prio 0 only; queue id is validated, there is one ring and one global fence sequence |
| 0x4c | SUBMITQUEUE_QUERY | - | `kIOReturnUnsupported` |
| 0x70 | (ours) INFO | `sweet_gpu_info` out | abi version, flags (bit0 ready, bit1 lost, bit4 `CAP_SBO_ALIAS` since minor 2: mask with 3), ids, VA range, last fence, `abi_minor` (2). Works also when the GPU is lost. |
| 0x71 | (ours) SURFACE_BO | `sweet_gpu_surface_bo` in/out | enters the pages of an IOSurface (`IOSurfaceGetID`) into the GPU address space and returns a handle + iova + geometry; `handle = 0xffffffff` on input only describes it. Wrapped (client) surfaces are refused. The memory keeps the CPU cache attributes of the surface (the pool of `sweetfb_zc` is cacheable): use `BO_SYNC` after GPU writes before the CPU reads and before the GPU reads CPU-written pixels. |
| 0x72 | (ours) BO_SYNC | `sweet_gpu_bo_sync` | `dc civac` over the kernel alias of a range of the BO. |

Mapping a BO: `IOConnectMapMemory64(conn, handle, mach_task_self(), &addr, &size, kIOMapAnywhere | kIOMapWriteCombineCache)`; unmap with `IOConnectUnmapMemory64`. Always pass `kIOMapWriteCombineCache`: the BO's other aliases
(kernel, GPU PTE `MAIR attr 0` non-cacheable) are non-cacheable, a cacheable client mapping would be incoherent. Error codes are `IOReturn`s: map `kIOReturnNoMemory/NoSpace/NoResources` to `-ENOMEM`,
`kIOReturnBadArgument` to `-EINVAL`, `kIOReturnTimeout` to `-ETIMEDOUT`, `kIOReturnBusy` to `-EBUSY`, `kIOReturnNotReady` to `-ENODEV`, `kIOReturnUnsupported` to `-ENOSYS`.

### Typical winsys sequence (freedreno through a libdrm stand-in)

1. open service, `INFO` (check `abi_version == 1` and `flags & 1`), `GET_PARAM` GPU_ID/CHIP_ID/GMEM_SIZE/MAX_FREQ (and VA_START/VA_SIZE to enable softpin).
2. per buffer: `GEM_NEW` -> `GEM_INFO(GET_IOVA)` (once) -> `GEM_INFO(GET_OFFSET)` + `IOConnectMapMemory64` when the CPU needs it. Softpin (`VA_START` answered): allocate GPU addresses yourself in [VA_START, +VA_SIZE), `SET_IOVA` before the first submit (or simply use the kernel's `GET_IOVA` address; do not mix).
3. submit: `GEM_SUBMIT` with all BOs referenced (every BO stays mapped, so the bos list only drives fence bookkeeping and relocs), `WAIT_FENCE(fence)`; `CPU_PREP` before touching a BO the GPU wrote.
4. render targets: `SURFACE_BO` for the IOSurface behind a CALayer/EAGL drawable, then `BO_SYNC`.

### Differences from Linux msm (userland must know)

* Timeouts are relative durations, not absolute `CLOCK_MONOTONIC`; convert in the stand-in.
* No fence fds, syncobjs, `MSM_SUBMIT_SUDO`, primary command buffers, `SUBMITQUEUE_QUERY`, per-process page tables (PP_PGTABLE 0, one address space for all clients), `MADVISE` is a stub, no GEM_CLOSE-on-fd-close semantics other than user-client close (all BOs of a closed connection are freed).
* No DMA-BUF/PRIME. Sharing between processes goes through IOSurface (`SURFACE_BO`).
* BOs are always write-combined and always GPU-resident; the cache flags are advisory-ignored.
* GPU address space is 32 bit (0x80000000-0xfffff000 for clients); the CP's own buffers live below it.
* Interrupts are not used: waiting polls (spin 2 ms, then 1 ms sleeps).

## 7. Risks and open items

1. **Bus hangs / SoC resets (freeze, no panic).** Any access to a gated GPU/GMU block hangs the bus; the 0103 policy (read GPU registers only with GX on and inside an OOB window) is kept, and stage 8 holds OOB_GPU forever so registers stay accessible.
   A wrong value in the GMU/PDC/RSC setup, an SMMU fault during a GMU DMA, a secure-register access (not done) or an XPU violation resets the phone. Test one stage per boot (`sweetgpu=3`, `4`, `5`, `6`, `7`, `8`) and read `logs/usb-*.txt` after each; the last UDP line before a freeze tells where it stopped.
2. **Nothing of 0103 has run on hardware.** The likeliest walls, in order: no zap shader file; `SCM PAS INIT_IMAGE` (crypto vote); CP fetching the SQE through the SMMU (stream ID 0 / read-only mapping); secure mode not left; UCHE/GBIF config too minimal for real draws (stage 8 only proves CP writes through the SMMU, not the 3D pipeline: HWCG, CP_PROTECT, UBWC config and `RBBM_SECVID_*` are not programmed).
3. **Single tenant, no isolation.** All clients share one GPU address space and one ring; the CP is not protected: an IB can write GPU registers (`CP_REG_WR`), any mapped memory, and could ask for secure mode (a secure access = XPU violation = reset). Only trusted processes (the EAGL bridge, test tools) may get the sandbox right to open the service. The stand-in sandbox must allow `iokit-open` for `SweetAdreno630` (and the user client class `SweetAdrenoUserClient`/`AGXDeviceUserClient`).
4. **GPU hang = reboot.** No hang detection interrupt, no recovery (`GPU LOST`, all further calls fail). BOs referenced by an incomplete submission are leaked, never freed under the GPU.
5. **Frequency.** The GMU runs at the boot level (257 MHz, LOW_SVS); `H2F_MSG_GX_BW_PERF_VOTE` (Linux `a6xx_hfi_set_freq`) is not implemented. `MAX_FREQ` reports the hardware maximum (710 MHz). No bandwidth vote beyond the boot table, no idle slumber: the GPU stays on (power/heat) until reboot.
6. **Cache coherence of BOs** relies on three aliases (kernel, client, GPU) all being non-cacheable and the zeroing being cleaned (`dc civac`) before first use. IOSurface BOs keep the surface's CPU attributes: explicit `BO_SYNC` is required there.
7. **Table pool**: 1 MiB (254 L3 tables of 2 MiB each) bounds how sparse the address space may be; `kIOReturnNoMemory` on map failure. The iova free list holds 512 ranges (a pathological fragmentation loses address space, never corrupts).
8. **HFI message queue is not drained** after start-up: unsolicited GMU messages (errors, debug) would accumulate in the 1024-dword queue; none are expected while idle, but a long run could fill it (the GMU then blocks on its side).
9. **ABI stability**: version 1; the winsys must check `INFO.abi_version`.
10. xnu-11215 API assumptions (`IOBufferMemoryDescriptor` with `kIOMapWriteCombineCache | kIOMemoryKernelUserShared`, `getPhysicalSegment(..., kIOMemoryMapperNone)`, `IOMallocData`) are the ones hackios-xnu-kernel-ext used on 8796 on real hardware and compile on 11215; behaviour on 11215 is untested.

## 8. Images and CI

CI run 39981343180 (branch `gpu-kernel`, artifact `xnu-kernel`, sha256 e9c73847...fedb) built 0180-0182. Boot images (kernel above, ADT `beryllium-hi-3x.adt`, the `tools/renegade/mkboot-full.sh` default cmdline + `ufslogsecs=1`) are in `../ios-beryllium/shim/out/`: `shim-boot-gpu-3.img` (`sweetgpu=3`: GMU boots), `shim-boot-gpu-5.img` (`sweetgpu=5`: HFI, GX rail, first GPU registers; needs only gmu.bin), `shim-boot-gpu-8.img` (`sweetgpu=8`: needs the zap too). Run them in this order, one per boot, with `tools/gpu-fw-push.sh` done first.

## 9. Firmware pull, user-client test, test order

* `tools/gpu-fw-pull.sh` (Mac, phone in OrangeFox with adb root): finds the vendor (or system/modem) partition under `/dev/block/by-name`, mounts it `ro,noload` (never writes a partition), copies
  `a630_zap.mdt`, `a630_zap.b00..` (+ `a630_gmu.bin`, `a630_sqe.fw` if there) into `research/gpu-fw/`, then verifies the mdt (ELF32, each segment's `bNN` exists with the right size) and prints hashes.
  If mounting fails it prints a read-only `dd` fallback. Note `backup/vendor.img` had no a630 files, so the files may be elsewhere on the phone; the script searches vendor, system, modem.
* `gpu/kernel-test/adreno_uc_test.c` (`gpu/kernel-test/build.sh`: arm64e, `renegade strip --sign`): opens `SweetAdreno630` and runs INFO, GET_PARAM (chip id, GMEM, timestamp), error paths, SUBMITQUEUE, GEM_NEW/INFO/map,
  CPU_PREP/FINI, a submit of CP_NOP + CP_MEM_WRITE (+ one through a relocation), WAIT_FENCE (blocking and polled), content check, GEM_CLOSE. Builds clean; **never run**. Exit status = failures.
* Order on the phone (one boot each; read `logs/usb-*.txt` after every boot):
  1. `tools/gpu-fw-pull.sh` in OrangeFox; boot iOS normally; `tools/gpu-fw-push.sh -z research/gpu-fw` (gmu+sqe default to `../ios-beryllium/research/gpu-fw/dl`).
  2. `shim-boot-gpu11215-3.img` (`sweetgpu=3`) -> `GMU BOOTED`.   3. `shim-boot-gpu11215-5.img` -> `HFI start complete`, `OOB gpu: acknowledged`, `slumber acknowledged`.
  4. `shim-boot-gpu11215-8.img` -> `SCM PAS ... signed zap authenticated`, `CP NOP test PASSED`, `CP fill test PASSED`, `KEPT UP`, `SweetAdreno630 published`.
  5. Same boot as 4, over SSH: copy `gpu/kernel-test/out/adreno_uc_test` to the phone and run it (`-v` for numbers); all lines `PASS`, `ALL PASSED`.

## 11. Power, DCVS, recovery, metrics (patch 0186, **built, never run on hardware**)

Boot-args (all optional; with none of the new ones the GPU behaves as before except for the always-on changes listed at the end):

| Arg | Meaning |
|---|---|
| `sweetgpuidle=MS` | PM thread (20 ms poll): when the ring is empty and no submission for MS ms, GX goes to slumber and the GMU is reset (the stage-5 sequence, hardware verified); the next submit wakes it by re-running the bring-up (GMU boot from the kept firmware, HFI, GX rail, SPTPRAC, OOB, CP init + `CP_SET_SECURE_MODE 0`; the zap stays authenticated, as in Linux) in about 100-150 ms. CX and the GMU clocks stay on while slumbering. 0 = never. |
| `sweetgpufreq=gov\|N\|off` | `gov`: governor; `N` (1-7): fixed level; `off` (default): fixed level 1 (257 MHz). Levels: 1 257, 2 342, 3 414, 4 520, 5 596, 6 675, 7 710 MHz (the perf table sent in `H2F_MSG_PERF_TBL`). |
| `sweetgpumax=N` | cap for the governor and for `MAX_FREQ`. |
| `sweetgpuhwcg=1` | hardware clock gating: the 105-register a630 table (`research/metal-a630/lists/a630_hwcg.txt`, Linux `a6xx_catalog.c` data), `RBBM_CLOCK_CNTL` 0x8aa8aa02, GMU CGC regs. Power only. |
| `sweetgpuubwc=1` | program the UBWC/bank registers (UBWC 2.0, highest bank bit 15: RB/TPL1/SP_NC_MODE_CNTL 0x4, UCHE_MODE_CNTL 0x400000, RBBM_NC_MODE_CNTL 0; values from the research notes, not re-derived on hardware). Default off; Mesa assumes hbb 15 either way. |
| `sweetgpurecover=N` | resets allowed after a fault/hang (default 3; 0 = "lost until reboot" as before). |
| `sweetgpuhb=S` | every S seconds one log line with GPU state and the shared clocks (below). |
| `sweetgpubw=linux` | use the fixed Linux BCM addresses of the bandwidth table (see USB). |

**Governor.** Each submission is bracketed by two `CP_REG_TO_MEM` stamps of `CP_ALWAYS_ON` (19.2 MHz) around a `CP_WAIT_FOR_IDLE` (the method hackios used and measured on an A642); busy time = sum of (end - start) of completed submissions, utilisation = busy / window. Window 60 ms; at >= 80% busy: one level up (>= 95%: straight to the cap); < 30% for two windows in a row: one level down; vote = `H2F_MSG_GX_BW_PERF_VOTE` (id 30: ack_type 1, freq index = our perf-table index, bw index 0) acknowledged by the GMU; a failed vote switches the governor off. Caveat: whether the GMU applies index N as the N-th row of the table we send (as Linux's `a6xx_hfi_set_freq` assumes) is **unverified**; there is no register that reports the actual GX clock here, so check the effect by timing a fixed workload per level. Idle slumber and governor combine: slumber only happens at idle; a wake starts at the last level.

**Recovery.** A SMMU fault of the CP's context, a wait that reaches the 5 s cap, or a full ring: `sweet_gpu_recover` halts the SQE, powers GX down through the GMU, resets the GMU and wakes the GPU again; all earlier fences are declared complete (their output is garbage) and clients see an epoch change (`WAIT_FENCE` returns `kIOReturnIOError`). After `sweetgpurecover` resets, or if the wake fails, the GPU is "lost" as before.

**UBWC / bank params.** `GET_PARAM` answers `HIGHEST_BANK_BIT` 15, `UBWC_SWIZZLE` 6, `MACROTILE_MODE` 0 (Linux `qcom_ubwc_config` sdm845), `SUSPENDS` = number of slumbers, `FAULTS` = hangs/faults, `TIMESTAMP` = the GMU always-on counter.

### Metrics: `sysctl kern.sweet_gpu`

Read-only string, one line of space-separated `key=value`, always present (`state=off` when the GPU interface is not up):

```
state=on level=3 mhz=414 max_level=7 freq=gov busy_pct=42 clients=2 pids=123,456 submitted=1030 completed=1030
suspends=2 resumes=2 recoveries=0 hangs=0 idle_ms=2000 hwcg=1 total_ms=91000 res_ms=slumber:61000,L1:0,L2:12000,L3:9000,L4:0,L5:0,L6:0,L7:0
```

* `state`: `on` (GX powered), `slumber` (idle, GX off), `off` (interface never came up), `lost` (reset failed or `sweetgpurecover` used up).
* `level`/`mhz`: current GX level and MHz (0/0 in slumber); `max_level`; `freq` = `gov` or `fixed`.
* `busy_pct`: utilisation of the governor's last 60 ms window (0 unless `freq=gov`; stale while slumbering).
* `clients`/`pids`: open user clients (connections) and the comma-separated pids that own them (`-` if none, cut after 96 bytes).
* `submitted`/`completed`: last submitted / last completed fence number (equal = idle).
* `suspends`/`resumes`/`recoveries`/`hangs`: counters since boot.
* `total_ms` and `res_ms`: milliseconds since the PM thread started, and per state: `slumber`, `L1` .. `L7`. `res_ms` fields are present only after a PM thread exists (any of `sweetgpuidle`, `sweetgpufreq=gov`, `sweetgpuhb`), otherwise all zero. A 30 s rate-limited kernel log line `SWEET GPU: pm: ...` prints the same as percentages.

### Heartbeat line (`sweetgpuhb=S`)

`SWEET GPU: hb: on|slumber level N | GCC usb30 gdscr ... master ... sleep ... utmi ... cfg-noc ... aggre ... ahb2phy ... clkref ... gpll0-vote ... memnoc_gfx ... ddrss_gpu_axi ...` -- the clocks the USB device shares with the GPU, next to the GPU state, so that a USB loss can be timed against GPU activity in the log (the log reaches UFS as well as UDP).

### USB loss (analysis, no hardware access)

The live log `usb-20261022-201239.txt` ends with healthy `SWEET USB: ue0` statistics (cfg 1, link up) and no GPU line near the end (only the first 8 submits are logged, no fault or timeout dump), so the log shows no GPU error before the link disappeared; the log itself travels over USB and stops with it, so the cause is not visible there. What the GPU code touches that USB could share:
1. `GCC 0x52004` (shared APCS clock-branch vote word, also USB/UFS/WLAN): our bits 15/16 were set by read-modify-write on every power-up; 0186 writes only when the bits are missing (no write during wakes).
2. **The bandwidth table sent to the GMU used the Linux a630 BCM addresses, which do not match this phone's cmd-db** (`MC0 0x50000`, `ACV 0x5000c` match; the table's `0x5005c` is not SH0 (`0x5003c` here); its CNOC command `0x50034` is `SH2` here, not CN0 (`0x500a8`); `0x5007c` and `0x5004c` are not in cmd-db at all). The GMU sends those commands to RPMh from the GPU's own TCS with vote 0 ("off", commit only) and the level-1 values `0x60000001`. A write to a different BCM or resource than intended is a candidate to disturb shared buses. 0186 builds the table from cmd-db (`SH0`, `MC0`, `ACV` for DDR, `CN0` for CNOC) and logs the addresses (`SWEET GPU: BW table BCMs: ...`); `sweetgpubw=linux` restores the old one.
3. GPU-side clocks `gcc_gpu_memnoc_gfx`, `gcc_ddrss_gpu_axi`, `gcc_gpu_cfg_ahb`, `snoc_dvm_gfx` are enabled by us and never touched by USB; the GX/CX/MX ARC votes of the GMU (levels from cmd-db) only add to the aggregation.
This is a suspicion list, not a diagnosis: boot with `sweetgpuhb=5` and compare the USB clock words before and after the link goes away.

Always-on changes of 0186 (also without the new boot-args): the CP stamps + `CP_WAIT_FOR_IDLE` per submission, the cmd-db BW table, the conditional GPLL0 vote write, recovery enabled (3 resets), the params above.

## 12. Zero-copy surfaces and the interactive governor (patches 0187/0188; built, untested on hardware)

### ABI minor 1 (for the EAGL/Mesa side)

`INFO.abi_minor` (was `reserved`) is 1. `abi_version` stays 1: everything below is backward compatible.

**`SWEET_GPU_SEL_SURFACE_BO` (0x71)** now accepts every IOSurface, including **client-memory (wrapped) surfaces** made by another process (`IOSurfaceCreate` with an address / `IOSurfaceWrapClientImage|Memory`). Struct `sweet_gpu_surface_bo` grew to 112 bytes; a caller that passes/accepts only the first 48 bytes (`SWEET_GPU_SURFACE_BO_V1_SIZE`) gets the old fields.

* The memory of a wrapped surface is already wired by `IOMemoryDescriptor::prepare()` for the surface's lifetime; the BO holds a reference to the surface, so the pages stay pinned until `GEM_CLOSE` or the connection closes, whatever the owner does. Each 4 KiB granule of each 16 KiB kernel page is entered (as in 0185), starting at the page that contains the pixels; `offset` includes the start delta inside that page.
* **Wrapped surfaces are mapped READ-ONLY into the GPU** (`SBO_READONLY`): use them as sources (textures: icons, glyphs, wallpaper). If the owner dies its address space is torn down and wired pages are freed, so a GPU that could still write there could corrupt memory that was reused; a GPU read of such a page is harmless. Never put a wrapped surface in the write position of a submission (a GPU write to a read-only page is a SMMU fault = recovery). Render into kernel-allocated surfaces (`IOSurfaceCreate` without an address) or Mesa BOs.
* **Idempotent:** the same surface in the same connection returns the same handle and iova (`SBO_EXISTING`), so it can be called every frame; the mapping is made once. The BO lives until `GEM_CLOSE` (or the connection closes): close it when the IOSurface is destroyed or after a cache policy of your choice. A surface whose pages never move (wired) needs no "moved" handling; if the surface is destroyed and the id recycled, the old BO still maps the old pages (we hold the surface) until closed.
* **Cache:** `flags` out has `SBO_CPU_CACHEABLE` when the CPU maps the surface cacheable (wrapped surfaces; the zero-copy low pool). The GPU mapping is non-cacheable, so after CPU writes call `BO_SYNC` on the dirty byte range (or pass `SBO_IN_SYNC` on the `SURFACE_BO` call to clean the whole BO), and after the GPU wrote a cacheable surface `BO_SYNC` before the CPU reads. Surfaces that are not CPU-cacheable need nothing.
* **Layout:** `tiling` = 0 and `ubwc` = 0 always (IOSurfaces here are linear, uncompressed); `bytes_per_row` and `plane[0..2] {offset, stride, width, height}` describe it (single-plane surfaces: plane[0]); `offset` = byte offset of pixel (0,0) from `iova`.
* Describe-only (`handle = 0xffffffff` on input) returns the same fields without mapping.

### ABI minor 2: writable CPU alias of a client-memory surface (patch 0214)

`INFO.abi_minor` = 2; `INFO.flags` gains `SWEET_GPU_INFO_CAP_SBO_ALIAS` (0x10) while the alias is enabled. **Mask `INFO.flags` with 3 for ready/lost** (it was exactly 1 or 2 before). Boot-arg `sweetgpualias=0` turns the alias off (flag not advertised, request refused with `kIOReturnUnsupported`). Service property `SweetGPUABIMinor` = 2. `abi_version` stays 1, everything is backward compatible.

* **Why such a surface is read-only** (nothing to do with `kIOSurfaceIsGlobal` or lock flags, which `SweetSurface.cpp` never looks at): `sweet_surface_use_task_memory` wraps the owner's range as `kIODirectionInOut` and, when `prepare()` refuses (the owner's own mapping is not writable: max_prot read-only, e.g. a read-only remap or file-backed page), again as `kIODirectionOut`. A `kIODirectionOut` descriptor makes a read-only memory entry and `IOMemoryMap` clamps every mapping to it, so both the render server's mapping (`SweetSurfaceRef`, `createMappingInTask`) and the kernel's `kernelMap` are `prot=1 max_prot=1`: no CPU store and no `vm_protect` can change that. The GPU mapping of the BO is read-only for the separate reason above.
* **Request (0217: any surface):** `SWEET_GPU_SEL_SURFACE_BO` (0x71) with the struct at its minor 2 size, `flags = SWEET_GPU_SBO_IN_WRITABLE_ALIAS` (0x2; may be or'ed with `SBO_IN_SYNC` 0x1), a real BO (not `DESCRIBE_ONLY`). Input and output length must both be >= `SWEET_GPU_SURFACE_BO_MINOR2_SIZE` (128), else `kIOReturnBadArgument`. The flag works for every surface: client-memory (wrapped) surfaces get the RW alias described here; kernel surfaces, including the sweetfb low-pool display canvases (BO is GPU-writable, `SBO_CPU_CACHEABLE`, no `SBO_READONLY`), get the ordinary RW mapping with the surface's cache attribute (write-back for the pool, write-combined otherwise). Before 0217 the flag on a non-wrapped surface returned `kIOReturnUnsupported` (userland -ENOSYS), which is why the pool surfaces could not be imported when the flag was set for every call. Calling again for the same surface returns the same BO and the same alias (idempotent). Failures are logged (`SWEET GPU: writable alias of surface ... failed: <step>` with size, offset, bpr, segments).
* **Answer:** `flags |= SBO_ALIAS` (0x10), `alias_addr` = address in the **calling task** of byte 0 of the BO (the start of the first page; pixel (0,0) is at `alias_addr + offset`, `plane[i].offset` likewise), `alias_size` = `size`. The mapping is read-write, user-accessible, cacheable write-back (the attribute of the kernel's own alias of the same pages, so there is no mismatched aliasing).
* **Struct sizes:** minor 0: 48 (`SWEET_GPU_SURFACE_BO_V1_SIZE`), minor 1: 112 (`SWEET_GPU_SURFACE_BO_MINOR1_SIZE`), minor 2: 128 (`SWEET_GPU_SURFACE_BO_MINOR2_SIZE`, `alias_addr` at 112, `alias_size` at 120). The kernel answers with the length of the caller's output buffer rounded down to one of those, so a minor 1 caller keeps getting 112 bytes. `sweet_gpu_surface_bo` has a `_Static_assert` on 128.
* **Lifetime:** the alias is owned by the BO. `GEM_CLOSE` of the handle or the connection closing (`clientClose`) unmaps it (`releaseGem`, before the surface is released), also on the path that leaks a BO the GPU might still read. It is valid only while the BO holds the surface, whose `prepare()` keeps the pages wired. Do not `munmap`/`vm_deallocate` it yourself: the kernel removes that exact range again at close. A BO whose alias request failed is not kept.
* **Safety:** it is a second descriptor over the *physical segments* of the already wired pages (`kIOMemoryTypePhysical64`, `kIODirectionInOut`), the same exposure as the kernel's own CPU alias of the surface; the GPU mapping stays `SBO_READONLY` (never writable, whatever the alias). The owner's page protection is bypassed for this task by design: only the trusted, single-tenant render server should ask. Untested on hardware: the physical-descriptor mapping of managed RAM through the device pager.
* **Cache and `BO_SYNC`:** after storing through the alias call `BO_SYNC` (or `SURFACE_BO` with `SBO_IN_SYNC`) on the written range, before the GPU reads the surface, before CoreAnimation or the display consumes it. `BO_SYNC` is `dc civac` over the kernel alias (`g->kva`); data caches are physically tagged and both mappings are write-back, so it cleans lines dirtied through the alias. A wrapped alias now has its own RW kernel mapping of the same pages (0217), and BO_SYNC cleans through it, so the read-only kernel mapping of the surface is no longer needed (before, a missing one failed the request with `kIOReturnNoMemory`, i.e. ENOMEM). Wrapped surfaces are never pooled, so the 0212 shortcut (BO_SYNC a no-op) never applies to them. A CPU reader through another write-back mapping of the same pages (the owner, CoreAnimation) needs no maintenance.
* **Typical use (black squares in Control Center):** `SURFACE_BO(IN_WRITABLE_ALIAS)` once per surface; render on the GPU into a Mesa BO, wait the fence, copy the pixels into `alias_addr + offset` row by row (`plane[0].stride`), `BO_SYNC`, then let CoreAnimation present.

### Governor (0188)

* **Why 0186's governor never moved:** a log of the 8e image showed `busy 0%` with thousands of submissions (the `99` seen in `pm:` lines is the time share at 257 MHz). The CP timestamp method read as a frozen counter on this hardware (`CP_ALWAYS_ON` also read constant over the CPU), so busy time was always 0 and the governor never raised the level. The per-submission stamps and `CP_WAIT_FOR_IDLE` are now **off by default** (`sweetgpustamps=1` brings them back); this also removes a pipeline drain from every submission.
* **Sampling:** while the governor runs the PM thread wakes every 4 ms and accumulates the time during which the newest submission's fence is not yet written; window 100 ms; `busy_pct` (also in `kern.sweet_gpu`) is measured in every mode (it is only *acted on* with `sweetgpufreq=gov`). Thresholds: >= 95% -> cap, >= 90% -> +2 levels, >= 80% -> +1, < 30% twice in a row -> -1.
* **Interactive boost:** a window with >= 4 submissions (a client drawing frames) sets a floor of `sweetgpuboost=N` (default 3 = 414 MHz; 0 off) for 400 ms after the last such window; the load part never goes below the floor; a wake from slumber starts at the floor. New `kern.sweet_gpu` keys appended before `total_ms`: `boost_level`, `boosted` (0/1), `submits_100ms`. The `pm:` log line prints `submits/100ms` too.
* Still unverified: that the GMU applies perf index N as row N of our table (no register shows the real GX clock); verify by timing a fixed workload per level or by the rise in `res_ms` of higher levels together with a shorter frame time.

## 10. Provenance and licences

* Sequences and register numbers: Linux `drivers/gpu/drm/msm/adreno/{a6xx_gpu.c,a6xx_gmu.c,a6xx_hfi.c}` and generated headers (GPL-2.0): facts only, nothing copied (see `GPU_A630_BRINGUP.md`). `msm_drm.h` structure layouts are the Linux uapi ABI (the UAPI header carries the Linux-syscall-note exception); they are re-declared here with `sweet_` names.
* Interface shape: `hackios-xnu-kernel-ext` (`bsd/dev/redwood_adreno.c`, `iokit/Kernel/RedwoodGPU.cpp`, APSL-2.0, third-party data) read for the design (selectors = msm request numbers, polling, WC buffers, the kernel as the address allocator, gpu-lost handling); no code copied, all of it is rewritten for SDM845/xnu-11215.
* Firmware is Qualcomm proprietary and never committed.
