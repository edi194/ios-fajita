# Migration from xnu-8796 to xnu-11215 (branch `xnu11215`)

Status (phase 1): `xnu-11215.81.4` (macOS 15.3, `apple-oss-distributions/xnu`) builds in CI as
`kernel.development.sweet` (arm64, plain non-PAC, DEVELOPMENT, MACHINE_CONFIG=SWEET) with the series in
`xnu/patches-11215/`. Nothing here has been booted yet.

## 1. Source tag, toolchain, CI

* **Tag.** 11215 only covers macOS 15.0-15.3 / iOS 18.0-18.3 (`distribution-macOS` release.json: macos-150 = 11215.1.10,
  151 = 11215.41.3, 152 = 11215.61.5, 153 = **11215.81.4**). iOS 18.7.x / macOS 15.4+ is **xnu-11417.x**, a later drop. The latest 11215
  tag is used, as asked. dxb (`blacktop/darwin-xnu-build`, pinned `663906528d`) also knows 15.4-15.6 (11417); the same series is the
  starting point for it (expect more conflicts), see section 5.
* **CI** (`.github/workflows/xnu.yml`): `macos_version` input, default `15.3` on this branch (`13.5` stays on `main`). 15.x runs on
  `macos-15` with **Xcode 16.2** (`xcode_version` input overrides), KDK 15.3 (24D60) is downloaded by dxb, `RC_DARWIN_KERNEL_VERSION=24.3.0`.
  dxb applies `patches/15.0/*.sh` then `*.patch` in name order: its own fixes (disable_bti, entitlements, iokit, link_kdk, skywalk;
  `remove_tightbeam` and `link_kdk146` do not apply to .81.4 and are skipped) come first, ours are copied with a `sweet-` prefix.
  A patch of ours that does not apply now **fails the build** (dxb only warned). ccache/host-tool caches work unchanged.
* **Series layout.** `xnu/patches/` = xnu-8796 series (untouched, still used for `macos_version=13.5`). `xnu/patches-11215/` = the 11215
  series. Same numbers and names as the old patches where a patch maps 1:1 (so history can be followed); `0005`, `0082b`, `0102b`, `0170`
  are new slots. Stage scripts (`0019-stage-libpthread.sh` -> libpthread-535, `0026-stage-hfs.sh` -> hfs-677.81.4, `0020-stage-bearssl.sh`)
  fetch pinned commits, gated on `MACOS_VERSION == 15.*`.
* **Local compile check.** `tools/xnu-cc.py` now works on the 11215 log (runner path autodetected, ccache prefix, `-MJ`):
  `gh run view RUN -R ry-diffusion/Bergamota --log > research/run-11215.log`, download the `xnu-buildtree` artifact, then
  `python3 tools/xnu-cc.py research/run-11215.log <buildtree> [files] --per-file` (uses `xcrun -f clang`; syscalls/MIG-generated headers
  are those of the CI run, so files depending on a changed `syscalls.master` only check in CI).

## 2. PAC-less kernel on 11215

* 11215 builds fine as **arm64 (non-e)** for SWEET: `makedefs` keeps `ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64` for SWEET (patch 0004),
  no `__has_feature(ptrauth_calls)`; `libfirehose_kernel` is built arm64 too (workflow sed). The KDK closed libs are arm64e only and not
  linked (SWEET does not use `lib<SOC>.os.a`); `nos_arm_asm`/`nos_arm_pmap` come from `MASTER.arm64.sweet` (0006).
* New in 11215 that needed SWEET handling: `apple_arm64_cpu.h` needs `MPIDR_CORETYPE_*` (in SWEET.h), `ARM64_PROLOG` (BTI landing pad) in
  our asm stubs, two more amcc stubs (`ppl_amcc`, `ppl_ctrr3`), UBSan source verifier skipped (0005), mockfs `kfree_type` typing, Tightbeam
  exports emptied (no exclaves), `CONFIG_CPU_COUNTERS` off instead of the kpc stub, headers split into `*_xnu.h` (vm_kern, vm_shared_region).
* **arm64e userland** (iOS 18): unchanged strategy: binaries are rewritten offline to contain no PAC instruction (`tools/renegade/pacstrip.py`),
  the kernel accepts arm64e only with boot-arg `sweetarm64e=1` (0131: `grade_binary`, `ptrauth_disabled=1`, AMFI dyld policy op 0x5a),
  the dyld pager leaves auth pointers unsigned (0135, now also covers 11215's new `DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE` fixup), shared-region
  slide v5 is native and leaves auth pointers unsigned without PAC, FJCVTZS is emulated (0141, Kryo 385 has no JSCVT).
  Whether 11215 + this scheme is enough for iOS 18.7 dyld is untested (see risks).

## 3. Triage

Legend: **A** boot-critical (platform, console, storage, root, AMFI/sandbox/AKS stand-ins, PAC-less userland support), **A-diag** boot-time
diagnostics kept in the same pass, **B** device drivers (display, touch, keys, battery, USB, BT/WLAN, GPU, IOSurface/HID), **C** obsolete in
11215. "ported" = in `xnu/patches-11215/`. Everything except C is ported; the split decides what to suspect first on a bad boot.

| Patch(es) | Summary | Cat | 11215 |
|---|---|---|---|
| 0001 | drop removed `-enable-trivial-auto-var-init...` flag (new clang) | C | flag gone upstream |
| 0002 | backport `UIO_STACKBUF` | C | in 11215 |
| 0003 | framebuffer "serial" console (`sweet-fbcon` ADT node) | A | ported, pe_serial rewritten around it |
| 0004 | SWEET machine config, GIC group-1 IRQs, SWEET.h | A | ported (SUPPORTED list, MPIDR defs) |
| 0005 | pmap `reserved10` clash | C | fixed upstream; slot reused for UBSan verifier skip |
| 0006-0008 | MASTER.arm64.sweet, Apple-internal header stubs, closed-lib gap fillers (amcc stubs, caches_asm, pmap, ml_enable_monitor) | A | ported; MASTER regenerated from 11215's MacOSX config (0021/0026/0037/0057 option changes folded in); kpc stub dropped |
| 0009 | drop Apple-SoC-only exports (+ empty Tightbeam exports) | A | ported |
| 0010-0012 | early framebuffer debug marks, physmap padding, keep console after TTBR0 switch | A | ported |
| 0013, 0014 | kmem RNG / kernel HMAC-DRBG without corecrypto kext | A | ported (11215 `entropy.c` needs no change: SHA512 goes through 0033) |
| 0015 | trust-cache runtime unavailable | A | ported (SPTM/PPL chain) |
| 0016-0018 | device-tree platform expert, vtimer IRQ, boot CPU driver | A | ported |
| 0019 | built-in libpthread kext (stage script) | A | ported with libpthread-535 |
| 0020, 0023, 0027, 0032, 0033 | BearSSL AES/SHA2/MD5/SHA1/SHA512 for libkern | A | ported |
| 0021, 0022, 0024 | mockfs ramdisk root (rd=md0 / QEMU) | A | ported (mockfs `kfree_type` fix is needed on 11215) |
| 0025, 0035, 0036, 0099 | built-in AMFI: entitlements, platform binaries, CS_SIGNED, named policy | A | ported |
| 0050, 0064, 0116, 0136 | Sandbox stand-in policy, PRIV_WORK_INTERVAL, extensions, container-expected | A | ported |
| 0026, 0031, 0041, 0052, 0155 | built-in HFS+ (hfs-677.81.4), rw root, link notes, rename swap, inconsistent-site log | A | ported |
| 0028-0030, 0034, 0069, 0102 | UFS root device, writes, DMA >4G, faster, review fixes (+0102b rest) | A | ported (`kmem_alloc_contig` needs `vm_kern_xnu.h`, 0170) |
| 0029, 0037, 0057 | unsealed root volume; bindfs / no ext resolver config | A | ported (0037 folded into 0006) |
| 0038, 0040, 0045 | AppleKeyStore, IOWatchdog stand-ins | A | ported |
| 0039 | coredump default off | A | ported |
| 0059, 0082 | iPhone identity (hw.model etc.); Poco F1 board selection/early console | A | ported (0082's keys/touch/HID part = 0082b, B) |
| 0065, 0078 | SMP via PSCI, 8 cores | A | ported |
| 0070 | `pid_hibernate` syscall for SpringBoard | A | ported (moved to kern_proc.c) |
| 0131, 0135, 0141, 0156 | iOS 18: arm64e exec, dyld pager no-PAC, FJCVTZS emulation, service-port check without filter | A | ported |
| 0042-0044, 0047, 0083, 0105 | exec log, console crash log, persistent console log in UFS, root trace, log sync | A-diag | ported |
| 0144-0147, 0148-0153 | syscall/Mach error tracers, exec env, MCM race delay, process sampler ports, launchd kevent trace, EINVAL sites | A-diag | ported |
| 0048, 0049, 0051, 0053-0055, 0066, 0080 | /dev/null tee, IOKit trace, crash heap strings, sampler, net trace | A-diag | ported |
| 0058, 0060-0063, 0071, 0082b, 0085-0088, 0101, 0111-0114, 0161 | HID event services, keys/touch (Goodix/NT36672A) drivers | B | ported |
| 0062, 0092, 0095, 0130 | RPMh/SPMI, battery | B | ported |
| 0072-0077, 0081, 0084, 0087, 0089, 0094, 0098, 0107-0110, 0158 | USB device, ECM, live log, SMMU, configd interface, BPF tap | B | ported |
| 0046, 0056, 0067, 0068, 0079, 0090, 0091, 0096, 0097, 0100, 0119-0123, 0126, 0127, 0129, 0157, 0159, 0160 | SweetFramebuffer / IOSurface / IOMFB stand-in, MDP page flip, scaler, accelerator stub, IOKit quiesce | B | ported |
| 0093 | cpufreq max | B | ported |
| 0103 | Adreno A630 bring-up | B | ported |
| 0104, 0117, 0118, 0124, 0125, 0128, 0132, 0133 | WLAN/BT | B | ported |
| 0106 | LaunchServices DB reset boot-arg | B (userland workaround) | ported |
| 0138 | `mach_ports_lookup3`/`register3` layout (iOS 18) | C | native in 11215 (`_kernelrpc_mach_ports_*3`) |
| 0139 | `exclaves_ctl_trap` (trap 88) | C | native (`exclaves.c` is built unconditionally; verify the non-exclaves return value) |
| 0140 | shared-region slide v5 | C | native (`vm_shared_region_slide_page_v5`) |
| 0142 | `hw.optional.arm.caps`, FEAT_SME... sysctls | C | native |
| 0143 | `kern.exclaves_status/boot_stage`, osenvironment | C | native (non-exclaves path returns NOT_SUPPORTED) |
| 0154 | watchport count 128 | C | native (`TASK_MAX_WATCHPORT_COUNT 128`) |
| 0137, 0140 | from main: `kern.sweet_reboot_mode` / boot-arg `sweetreboot` (PS_HOLD reset, PON reason, IMEM restart_reason -> fastboot/recovery), Bergamota variant | B | ported (not in the full2/full3 images) |
| 0136b | `beryllium-bt-hci-kctl` (main): Bluetooth HCI control socket for bluetoothd | B | ported (`0136-beryllium-bt-hci-kctl`) |
| 0173 | new: UFS DMA cache maintenance (clean+invalidate by VA around every command) is now the default (`ufsdmasync=0` disables). Suspect for the full3 corruption (foreign data in freshly written files, EIO on writes): the SDM845 UFS host has no `dma-coherent` in the live DT, and until now the driver relied on a bare `dsb` (`__ARM_COHERENT_IO__` turns flush/clean_dcache64 into `dsb sy`), i.e. on stale bounce-buffer lines. Also adds boot-arg `ufsselftest=N` (MiB, needs `ufsrw=1`): write/read-back/compare in the reserved area just before the log ring, refuses unless it is clear of the HFS volume header's end; 3 passes incl. dirtied-cache reads | A | new |
| 0172 | new: xnu-11215 `console_write()`/`console_write_unbuffered()` return early when `disableConsoleOutput` (8796 checked only in `_cnputs`), so once the graphics console took over printf/IOLog never reached our persistent-log ring (0047) or the UDP live log (0077); both now tee before the early return, and `kprintf()` (`serial_putc_crlf`) is teed too | A-diag | new |
| 0171 | new: SweetCPU for 11215: `processor_start` from a kext is a no-op returning KERN_FAILURE (hardware boot 1 panicked `processor_start failed: 5`); `ml_processor_register()` now calls `processor_boot()` itself, so secondaries are registered only after the boot CPU, startAll just waits, boot-CPU `initCPU` waits for its self-IPI and calls `ml_cpu_up()` like AppleARMSMP | A | new |
| 0170 | new: `vm_kern_xnu.h` / `vm_map_internal.h` includes for driver files | - | new |

## 4. Boot image

`enxerto/out/shim-boot-xnu11215-p1.img` (git-ignored): Enxerto `BOARD=beryllium`, ADT `enxerto/out/beryllium-hi-3x.adt` (`tools/mkadt.py --board beryllium
--highmem --display-scale 3`, needs `research/ipsw-x/d22ap.adt`), kernel from CI, boot-args of `tools/renegade/mkboot-full.sh`. Phase-1 image
was made from the first green run (series without the drivers); rebuild with `tools/renegade/mkboot-full.sh KERNEL ADT OUT`.

## 5. Risks / open items

* iOS 18.7 userland expects xnu-11417 behaviour (newer MIG/syscall/sysctl set, e.g. `kern.exclaves_*`, hw caps); 11215.81.4 may lack some.
  Moving to dxb 15.4-15.6 is the next experiment.
* First-boot: `kern.osenvironment` blocks until `sysctl_unblock_osenvironment()` runs (platform-expert path of 11215; check on a hang),
  new `/chosen` expectations in `arm_init`/`pe_init`, `SERIAL_*` enum renumbering, `entropy`/`bootseed` HKDF path now via `cchkdf` from the
  corecrypto kext library (link succeeded, runtime unverified), BTI landing pads `bti c` on a core without BTI (hint NOPs, fine), the
  arm64e `sweetarm64e` path was only verified to compile.
* Driver patches were compile-checked locally and in one CI run; behavior on 11215 (IOKit/IOUserClient/kmem API changes) is untested.
