# freedreno on SweetAdreno630 (winsys for the Heartwood kernel ABI)

Status: `sweet_drm.c` compiles (arm64e) and is **linked into a Mesa 25.0.7 freedreno build** (see `docs/GPU_EAGL.md`, phase E); never run against the GPU yet. Kernel side: `docs/GPU_KERNEL.md`.

## Approach: a libdrm stand-in, no Mesa source change

Mesa's freedreno `msm` backend (Mesa 25.0.x: `src/freedreno/drm/msm/*.c`, 34 call sites) only needs `drmCommandWriteRead/Write`, `drmIoctl(GEM_CLOSE)`,
`drmGetVersion`, `drmOpenWithType`, `drmGetCap` and `mmap(fd, bo offset)`. The kernel interface was made of exactly those requests
(selector = `0x40 + DRM_MSM_*`, Linux structure layouts), so `sweet_drm.c` implements them over `IOConnectCallStructMethod` and interposes `mmap`/`munmap` for
its fds (dups of `/dev/null`) with `IOConnectMapMemory64(memoryType = BO handle, kIOMapWriteCombineCache)`.
It reports DRM version msm 1.3 on purpose (no softpin: Mesa would pick its own GPU addresses; the kernel assigns them and the backend reads them with `GEM_INFO(GET_IOVA)`
and patches relocations, which the kernel also supports). Absolute `CLOCK_MONOTONIC` timeouts are converted to the kernel's relative ones. `SWEET_DRM_TRACE=1` logs failing requests.

## Use

1. `gpu/freedreno-sweet/build.sh` -> `out/libdrm.2.dylib` (install name `/usr/local/lib/libdrm.2.dylib`).
2. Configure Mesa with the msm kmd and a libdrm of API >= 2.4.1xx (headers `xf86drm.h`, `drm.h`, `msm_drm.h` from the libdrm source; link the stand-in instead of the real library):
   `-Dgallium-drivers=freedreno -Dfreedreno-kmds=msm -Dvulkan-drivers=` plus whatever frontend the EAGL bridge uses.
3. Put the dylib where Mesa's loader finds it; the kernel must be booted with `sweetgpu=8` (`SweetAdreno630` published) and the process allowed to open it (sandbox, see GPU_KERNEL.md risks).
4. First test without Mesa: `gpu/kernel-test/adreno_uc_test`.

## Open points (coordinate with ../ios-beryllium-gpu-eagl)

* Their Mesa 25.0.7 build (scratchpad `gpu-eagl/build-a64e`) is OSMesa/software; a hardware path needs a frontend that can use a pipe driver with our winsys
  (EGL surfaceless/gbm-less platform or a Gallium frontend of their own) and render targets as IOSurface BOs (`SWEET_GPU_SEL_SURFACE_BO`, then `BO_SYNC`): `fd_bo_from_dmabuf` is
  `ENOSYS` here, so import has to go through a small Mesa-side hook that calls `SURFACE_BO` and wraps the returned handle/iova (`fd_bo_from_handle`-like).
* PRIME is a stub (`-ENOSYS`). `drmGetCap` reports no syncobj, so freedreno gallium keeps its own fence handling.

## Turnip (Vulkan), 2026-10-26: Chlorophyll `docs/TURNIP.md`

Mesa's Turnip runs over this stand-in on the phone (Chlorophyll branch `turnip`). For it the stand-in also has:
* **Binary syncobjs emulated on the kernel's fences** (`drmSyncobjCreate/Destroy/Reset/Signal/Wait`). The kernel has one ring and one
  global fence sequence, so a syncobj is unsignaled, signaled or pending on fence F.
  * A submit's `MSM_SUBMIT_SYNCOBJ_OUT` syncobjs become pending on its fence.
  * `SYNCOBJ_IN` syncobjs only have to be submitted already, because the ring is in order.
  * Both are taken off the request before it reaches the kernel, which refuses syncobjs.
  * A submit with no command is answered with the last submitted fence and never sent.
  * Timelines, transfers and sync-file fds stay `-ENOSYS`. Turnip emulates timelines on binary syncobjs.
  * `drmGetCap` still says no syncobj, so Gallium never uses any of this.
* **Device enumeration:** `drmGetDevices2` / `drmGetDevice2` / `drmFreeDevice(s)` / `drmDevicesEqual` describe one platform device
  whose render node is `/dev/null`.
* If dyld interposing is not honoured on the PAC-less runtime, patch `fd_bo_map_os_mmap` (`freedreno_bo.c`) to call `IOConnectMapMemory64` directly.
