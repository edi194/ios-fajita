# iOS 17/18 userland on the Poco F1 (SDM845, no PAC): feasibility study

Date 2026-10-20. Read-only study: nothing was run on the phone, nothing committed. Raw data and the scanner are in
`research/ios18/` (gitignored): `scan_result.txt`, `hits.txt` (addresses of the rare classes), `img_counts.txt`, `tools/scan.c`, `tools/unk.py`.
The downloaded IPSW pieces (4.8 GB cache + 180 MB extracted dylibs) and the two xnu clones were deleted afterwards.

Tags: **[V]** verified by me in this session (measured, disassembled, or read in source), **[S]** from a source I only searched, not read in full, **[U]** unverified / from memory.

## 1. Verdict

**Technically feasible for the CPU side, very expensive and risky overall. Not a "weekend" port; roughly 5-9 person-months to a SpringBoard on iOS 18, with a cheap 1-3 day proof of concept for a command-line binary.**

- The instruction problem is smaller than feared. In the iOS 18.7.8 arm64e cache (2378 MiB of code, 623.4 M instruction words) only **one class cannot be rewritten 1:1 in 4 bytes: FJCVTZS** (474 sites, JavaScriptCore + WebCore), plus a handful of runtime-gated vector/crypto classes. Everything PAC-related has a same-size ARMv8.0 replacement. [V]
- The hard parts are not instructions: (a) the iOS 18 userland needs a kernel that speaks the xnu-11215 interface (shared cache slide-info v5, arm64e exec/CPU-subtype handling, new Mach traps and sysctls, commpage), (b) iOS 18 on-device daemons assume A12+ hardware services (SEP, AGX, new IOMobileFramebuffer user-client ABI, etc.), and (c) every change is a binary patch of a signed 2.4 GB cache plus ~all system executables, which then need re-signing/CS bypass.
- Even with PAC removed, we would be a "Frankenstein" iOS: the iOS 18 SpringBoard stack is much more demanding of kernel/IOKit behavior than iOS 16, and we only got iOS 16 to the home screen after ~126 patches.

## 2. CPU facts (SDM845 / Kryo 385 = Cortex-A75 + A55)

| Feature | A75/A55 | Evidence |
| --- | --- | --- |
| ARMv8.2-A base | yes | Arm spec for both cores [U from memory; consistent with the repo notes "Kryo 470 = ARMv8.2"] |
| FEAT_DotProd, FEAT_FP16 (fphp/asimdhp), FEAT_RDM, FEAT_LSE atomics, FEAT_DPB (dcpop), CRC32, AES/PMULL/SHA1/SHA2 | yes | Linux hwcap list `fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp` found for an openbenchmarking "Cortex-A75/A55 8-core" entry [S] (search hit, not a Snapdragon 845 dump); consistent with my memory of SD845 cpuinfo [U] |
| FEAT_LRCPC (LDAPR/LDAPRB/LDAPRH) | **yes** (the same hwcap list has `lrcpc`; decoded ID_AA64ISAR1 = 0x...100001 = DPB + LRCPC) | [S] + my decode of the register layout. So the 93,670 LDAPR in the cache run natively. |
| FEAT_LRCPC2 (LDAPUR*/STLUR*, v8.4) | no (no `ilrcpc` hwcap) | [S/U] |
| FEAT_PAuth (PACIA..., RETAB...) | **no** (ID_AA64ISAR1 APA/API = 0) | [S] decode above; I did not read the TRM register tables themselves [U] |
| FEAT_JSCVT (FJCVTZS), FEAT_FCMA (FCMLA/FCADD), v8.3 | **no** | same decode (JSCVT, FCMA bits 0) [S] |
| v8.4+ (flag manip CFINV/RMIF/..., LDAPUR, SB, SSBS, MTE, BF16, I8MM, FP16FML FMLAL, SHA3/SHA512/SM3/SM4) | no | not in the hwcap list [S] |

To close the [S] items: read `ID_AA64ISAR0/1_EL1`, `ID_AA64PFR0_EL1` on the phone (or `/proc/cpuinfo` under Android) - not done (no phone access allowed here). Note the existing repo has no ID-register dump (grepped).

Hint-space behavior: PACIBSP/AUTIBSP/PACIA1716/XPACLRI/BTI/etc. are HINT encodings and execute as NOP when the feature is absent (Arm ARM rule for HINT) [U from memory of the ARM ARM, and consistent with ios-beryllium running its A11-built userland whose binaries contain no such instruction - not tested here]. The non-HINT forms (RETAB, BLRAA, PACIA x,x, ...) are UNDEFINED on A75/A55.

## 3. Instruction census: iOS 18.7.8 (22H352) `dyld_shared_cache_arm64e`, iPhone11,8

Source: `ipsw download ipsw --device iPhone11,8 --version 18.7.8 --dyld --dyld-arch arm64e` (remote extraction, 4.8 GB). The tool offered no 18.x for iPhone12,1 above 18.6; 18.7.8 exists for iPhone11,8. The same single arm64e cache serves A12-A18. 67 cache files, 3861 images, slide-info **v5**. [V]

Method [V]: C scanner over every image's sections flagged as instructions (S_ATTR_PURE/SOME_INSTRUCTIONS), masks checked against `llvm-mc` encodings of every class. Caveat: the cache stores no LC_DATA_IN_CODE (0 ranges found), so literal pools inside `__text` produce false positives for rare classes; I spot-checked every rare class (below). Cross-check [V]: `llvm-objdump` over 17 extracted dylibs (libobjc, libdispatch, libsystem_*, libdyld, libc++/abi, libxpc, Foundation, CoreFoundation, JavaScriptCore, QuartzCore, CoreGraphics, libcorecrypto) with the feature set `+v8.2a,+fullfp16,+dotprod,+rcpc,+lse,+rdm,+crc,+aes,+sha2,-pauth,-jsconv,-complxnum,...`: every "unknown" word was in the table below or was data (string/constant/jump table); the only other real instructions were SVE/SME words in libsystem_platform (runtime-gated, see 3.3).

### 3.1 PAC and other must-rewrite classes

| Class | Count | Same-size ARMv8.0 replacement | Caveat |
| --- | ---: | --- | --- |
| **HINT space (NOP on v8.2, no action)** | | | |
| PACIBSP | 6,687,100 | none needed (NOP) | iOS 18 uses the B key; PACIASP/AUTIASP: 0 |
| AUTIBSP | 2,513,823 | none needed | |
| PACIA1716/PACIB1716 / AUTIA1716 | 20,787 / 1 | none needed | |
| BTI (any) | 146 (data/gated code) | none needed | |
| **Non-HINT PAC** | | | |
| RETAB (RETAA: 0) | 4,535,374 | `RET` (0xD65F03C0) | LR is never signed because PACIBSP is a NOP |
| BRAA/BRAB Xn,Xm | 3,224,095 | `BR Xn` | modifier register ignored |
| BRAAZ/BRABZ | 11,504 | `BR Xn` | |
| BLRAA/BLRAB Xn,Xm | 4,698,327 | `BLR Xn` | |
| BLRAAZ/BLRABZ | 202,223 | `BLR Xn` | |
| LDRAA/LDRAB | 1,617 (1,595 in TextToSpeechMauiSupport, 21 libc++abi, 1 libsystem_m = data) | `LDR Xt,[Xn,#imm]!` | **all 1,313 real ones are pre-index writeback with positive offset <= 255**: fit `LDR` pre-index (simm9, unscaled). Zero fall outside -256..255. Non-writeback LDRAx: 0 real (the 304 "negative" hits are data). So no LDUR/negative-offset problem. [V] Disassembled: `ldraa x9,[x8,#0x20]!` then `blraa x9,x17` in libc++abi. |
| PACIA/PACIB/PACDA/PACDB Xd,Xn | 4,527,350 | `NOP` | no pointer is ever signed, Xd stays a plain pointer |
| PACIZA/.../PACDZB (zero-modifier) | 678,503 | `NOP` | |
| AUTIA/AUTIB/AUTDA/AUTDB Xd,Xn | 3,472,416 | `NOP` | |
| AUTIZA/.../AUTDZB | 24,321 | `NOP` | |
| XPACI/XPACD | 854,671 | `NOP` | pointers are already clean. The compiler's auth-check idiom `autdb x16,x17; mov x17,x16; xpacd x17; cmp x16,x17; b.eq; brk #0xc473` passes when AUT and XPAC are both NOP (disassembled in libobjc). [V] |
| ERETAA/AB | 0 | n/a | kernel only |
| **PACGA** | 502 (Foundation 326, CoreFoundation 99, JavaScriptCore 70, libobjc 7) | `EOR Xd,Xn,Xm` or, for chained hashes, `EOR Xd,Xm,Xn,ROR #k`-style (4 bytes) | PACGA is a keyed MAC used as (a) a running hash over bytes in libobjc (`ldr x10,[x19],#8; pacga x8,x8,x10` loop) and (b) object-integrity tags in Foundation (`pacga` chained then stored to an ivar, verified later by recomputation). Any deterministic function keeps (b) correct; (a) needs a decent mixing function or hash tables degrade/collide. `MOV Xd,#0` would be correct for (b) but a constant hash for (a). Needs per-site review of the 502 sites. [V for the two patterns, U for the other ~490] |

Total non-HINT PAC instructions that need touching: **about 22.2 M** (3.6 % of all instruction words); hint-space PAC: 9.2 M (NOP, untouched).

Data pointers: see section 4.

### 3.2 Not 1:1 replaceable (need trap-and-emulate or hand patching)

| Class | Count (code, spot-checked) | Where | Notes |
| --- | ---: | --- | --- |
| **FJCVTZS** | 474 (JavaScriptCore 462, WebCore 12) | real, **unconditional** compiled code (`ucvtf d0,w13; fjcvtzs w13,d0`; JSC C++ toInt32 paths) | Needs ~10-20 instruction emulation incl. NZCV (Z=1 if exact). Trap cost ~1 us each; JSC's JIT assembler checks `hw.optional.arm.FEAT_JSCVT` at runtime (string present in cache) so the JIT would use the fallback if our kernel reports 0. The C++ sites are the problem. Alternative: patch the 474 sites with a branch to a nearby island (needs a free register or LR spill; per-site analysis) - cheaper at runtime than a trap. |
| FCADD | 2,454 (libBLAS 2,430, libwebrtc 24) | real code (FFT kernels) | Probably runtime-gated by hw.optional (FEAT_FCMA string is absent from the cache, so gating is by something else) [U]. Emulate by trap (rare) or leave unreached. Accelerate/WebRTC only. |
| FCMLA | 0 real (1 data hit in libsystem_m) | | |
| FMLAL/FMLSL (FP16FML, v8.2 optional, A13+) | 81 in 17 images (libBLAS, libvMisc, RenderBox, ...) | real | not on A75/A55; gated by caps [U]; trap-emulate if reached |
| BFCVT (BF16) | 76 (libBNNS) | real, gated [U] | |
| SHA3/SHA512/SM3/SM4 (EOR3, BCAX, XAR, RAX1, SHA512*) | 925 (libcorecrypto x3, dyld, libMobileGestalt, libsystem_m data) | statically linked corecrypto | gated by cpu feature sysctl/commpage in corecrypto [U]; **must report no SHA3/SHA512 in caps** |
| SB | 6 (dyld, MobileGestalt, corecrypto x3, libplatform) | speculation barrier after RET/B [U] | Never executed architecturally if it follows an unconditional branch; if it does execute it is UNDEFINED on v8.2 [U: unchecked placement] |
| LDAPUR*/STLUR* (v8.4) | 13 hits, all in libsystem_m/AudioCodecs/MFAAuthentication | data (verified libsystem_m: double constants) | 0 confirmed real |
| MTE (ADDG/STG/LDG), SDOT/UDOT, SQRDMLAH in libsystem_m | 4-5 each | data (verified) | A75/A55 do support DotProd and RDM anyway |
| SVE/SME words | ~100 in libsystem_platform | runtime-gated memcpy variants [U] | kernel must not advertise SME/SVE |
| CFINV/AXFLAG/XAFLAG/RMIF/SETF8/16, FRINT32/64, I8MM, WFET/WFIT | 0 | | |
| LDAPR (RCpc, supported by A75/A55) | 93,670 | native | nothing to do |
| LSE atomics | 426,128 | native (v8.1) | nothing to do |

### 3.3 Binaries outside the cache
Not measured: `/usr/lib/dyld` (the cache also contains a dyld copy at 0x1A9648000: 6 BTI, 1 SB, 144 SHA3 words), launchd, SpringBoard, daemons and apps live in the rootfs/cryptex dmgs (several GB; not downloaded). Expect the same class distribution (everything is arm64e). Fat/arm64 slices exist for almost none of the system binaries in iOS 18 for A12+. [U]

### 3.4 JIT
JavaScriptCore emits PAC instructions at runtime (JIT code uses `pacia`/`blraa`-style sequences under `ENABLE(JIT_CAGE)/CPU(ARM64E)`) [U]. WebContent needs the `dynamic-codesigning` entitlement for JIT; with it off JSC runs the LLInt/C++ interpreter, whose PAC/FJCVTZS are covered by the static rewrite. Plan: disable JIT (`JSC_useJIT=0`/entitlement) in a first stage. Not tested.

## 4. Signed pointers in data (chained fixups, slide info)

- **Dyld shared cache**: slide info is **v5** (header of every data mapping: version 5 [V]). Authenticated pointers are encoded `{runtimeOffset:34, diversity:16, addrDiv, keyIsData, next:11, auth:1}`; they are signed by the **kernel** at map time (`vm_shared_region_slide_page_v5`, xnu-11215.81.4 [V read]). That function is already `#if __has_feature(ptrauth_calls)`-guarded around the signing: without ptrauth it simply writes `(value & 0x3FFFFFFFF) + value_add + slide` for both auth and non-auth entries, i.e. a clean pointer (and high8 only for non-auth). **xnu-8796 has no v5 at all** (v1-v4 only [V grep]) so porting that function (+ validation `vm_shared_region_slide_info_entry_v5`, ~120 lines) is mandatory.
- **Mach-O chained fixups** (`DYLD_CHAINED_PTR_ARM64E` auth rebase/bind) are applied by userland dyld: `ChainedFixupPointerOnDisk::Arm64e::signPointer` etc. end in `__builtin_ptrauth_sign_unauthenticated` = PACIA/PACDA; once those are NOPs the stored value is the clean target [U, code path from memory of dyld4; consistent with the compiler idiom seen]. Requires `/usr/lib/dyld` itself to be rewritten too (it self-rebases before anything else).
- Does anything compare signed vs unsigned or use top bits? Within the 17 libs disassembled, the pattern is always sign/auth then optional `xpac`+`cmp` or `tbnz ...#62` error-bit tests - all pass with consistent NOPs. Absolute guarantee is not possible statically; residue risk: code that inspects the PAC field width (`ptrauth_...` queries are compile-time), kernel-signed thread-state fields (see 5.2), and `__DATA_CONST` objc structures verifying signatures of `isa`/method pointers (all via PAC instructions -> NOP).

## 5. Non-instruction blockers

### 5.1 Kernel interface xnu-8796 -> xnu-11215 (iOS 18.x = xnu-11215.x)
Measured on the two sources [V]:
- BSD syscalls: tables are almost identical. Only new/changed: 535 `objc_bp_assist_cfg_np`, 556/557 coalition policy, plus renames of chdir/fchdir/settid. **No wholesale new syscall set.** (Mach traps: only `exclaves_ctl_trap` is new.)
- **Shared cache slide v5**: missing in 8796 (must port).
- **arm64e exec/grading**: in 8796, `bsd/dev/arm/kern_machdep.c grade_binary`: host `CPU_SUBTYPE_ARM64_V8` accepts only V8/ALL, so an arm64e binary scores 0 and exec fails; our kernel reports `cpu_subtype` from `arm_arch` (V8 for our CPU). Needs: grade arm64e as acceptable, report subtype ARM64E to userland (`hw.cpusubtype`, host_info) so dyld picks the `arm64e` cache/slices. `match_subtype()` in vm_shared_region.c and the `sr_auth_section` allocation already special-case ARM64E. The arm64e ptrauth ABI-version check in exec is under `__has_feature(ptrauth_calls)` and drops out. [V read in the local tree]
- **Sysctls / commpage**: the cache queries `hw.optional.arm.FEAT_{JSCVT,FPAC,LSE,I8MM,FP16,DotProd,SME,SME2,FRINTTS}` and `hw.optional.arm.caps` [V strings]. Kernel must answer these (0 for JSCVT/FPAC/SME/I8MM...). Whether xnu-8796's `kern_mib.c` implements the `arm.FEAT_*` names: [U, not checked; it is derived from the commpage cpu-capabilities words, which changed]. Commpage diff 8796 vs 11215: not completed [U].
- **Exclaves / Secure Kernel (SK)**: `osfmk/kern/exclaves*.c` exists in 11215 (xnu side compiled only for hardware with exclaves; A12/A13 have none). iOS 18 userland tolerates absence on non-exclaves SoCs [U]. kalloc_type/kernel heap changes are kernel-internal, irrelevant for userland.
- Other userland-visible changes likely hit by launchd/libdispatch/libxpc/SpringBoard [U]: new kqueue/workloop flags, proc_info flavors, task/thread policy and coalition calls, `posix_spawn` attributes, `kdebug` strings, `vm_*` flags, `memorystatus` control calls, `csops`/AMFI selectors, `sandbox` MACF calls, `shared_region_map_and_slide_2_np` flags. Each needs a stub that returns plausible values; failures are discovered by running. We already stub many (Sandbox stand-in, AMFI).

### 5.2 PAC interface in the user/kernel boundary
`arm_thread_state64` has signed `pc/lr/sp/fp` fields and `__opaque_flags`; arm64e userland (libsystem_kernel, pthread, libunwind, exception handlers, crash reporter) sets them via ptrauth macros. With NOP PACs they become plain values; the non-PAC kernel's `thread_set_state` / sigreturn / exception paths (all `HAS_APPLE_PAC` guarded, which our build leaves out) then see plain values and flag bits (NO_PTRAUTH / IB_SIGNED_LR) that they ignore. Likely fine; untested [U].

### 5.3 Code signing of the modified cache
The cache and each binary are code-signed (cache has its own signature). Rewriting breaks page hashes. Our AMFI/csops stand-ins and `launchd_unsecure_cache` already bypass trust for iOS 16; need confirmation that the shared-region pager does not hash-validate the cache pages (or re-sign the cache with a fresh blob). Cache layout is preserved (4-byte for 4-byte), which keeps all offsets, patch tables, PrebuiltLoader sets and objc optimization tables valid. [U]

### 5.4 Device assumptions
- iPhone11,8/12,1 are A12/A13: **no DCP** (display coprocessor appears from A14) [U], so IOMobileFramebuffer/AppleCLCD stays in-kernel as today, but the iOS 18 user client ABI (IOMFB selectors, swap/surface formats) and QuartzCore/backboardd in 18 differ from 16. Our CPU-rendered path (no AGX) needs QuartzCore's CPU renderer choices to still exist [U].
- SEP/AKS/keybag, AppleKeyStore, `mobilekeybagd`, MobileGestalt keys (device identity must be a plausible iPhone with arm64e), AMFI trust caches, cryptex mounting (iOS 18 `libcryptex` / SystemOS+AppOS) - all re-stubbed; every one of our iOS 16 stubs must be re-validated against iOS 18 expectations.
- Sensors, camera, audio, baseband: absent/stubbed as today.

### 5.5 Our 126 patches
130 patch files touching 161 files (345 hunks). 71 of the files exist in xnu-8796; **61 of those differ in xnu-11215** (or are gone) [V]. Biggest groups: iokit/Kernel 45 (our drivers, mostly new files = no conflict), libkern/crypto 19 (new files), osfmk/arm64 16, bsd/dev 15, bsd/kern 12, bsd/vfs 7, pexpert 6. Rough split: about 60% are new files that port with a header-API fix-up, 40% are hunks into core files (pmap/arm64 startup, pexpert, kern_exec, vfs, mach_loader, config) that must be hand-rebased, because 8796 -> 11215 spans macOS 13 -> 15 (kalloc_type, new IPC/ports, exclaves, pmap/trustcache changes). Estimated 3-5 weeks for the rebase alone, with the kernel build/CI loop. Alternative: stay on xnu-8796 and backport only slide-v5 + arm64e grading + sysctls/commpage + the few syscalls (cheaper, ~1-2 weeks, more probable to work first).

## 6. Effort estimate

| Work item | Person-months |
| --- | ---: |
| Cache/binary rewriter (parse cache + Mach-O, apply the table in 3.1, island/fix-up infra, re-sign or CS bypass), incl. rewriting dyld, launchd and ~1000 on-disk executables | 1.0-1.5 |
| FJCVTZS/FCADD/etc. emulation (EL1 undef handler + decoder, or per-site islands) | 0.5-1.0 |
| PACGA per-site review (502 sites) | 0.3 |
| Kernel: slide v5, arm64e grade/cpusubtype, sysctls/commpage, missing syscalls/traps (staying on 8796) | 0.5-1.0 |
| Kernel rebase to 11215 (instead of backporting) | +1.0-1.5 |
| Userland bring-up of iOS 18 (launchd, configd, SpringBoard stack, MobileGestalt/AMFI/IOMFB/IOSurface/HID user-client ABI changes, every previous stub revisited) | 2.5-5.0 |
| Debug tail (Safari/WebKit with JIT off, crash loops, performance of trapped instructions) | 1.0-2.0 |
| **Total (backport route)** | **~5-9** |

Biggest risks: (1) iOS 18 services needing kernel/IOKit behavior we do not have (unknown count; each is a day to a week to find, since logs are hard to get); (2) trap-based emulation performance in WebKit (JS number conversions are everywhere); (3) hidden PAC dependence in data (signed objc/Swift metadata, Foundation PACGA integrity fields) not visible in a static census; (4) code-signature enforcement on a modified cache; (5) no ID-register dump yet to settle the CPU feature table; (6) iOS 18.x security checks (trust caches, DER entitlements in amfid/sandbox) being stricter than iOS 16.

## 7. Cheapest proof of concept (1-3 days, no kernel rebuild beyond one grade patch)

Goal: run one rewritten iOS 18 arm64e command-line binary against rewritten iOS 18 dylibs on the **current** kernel.
1. Take a tiny iOS 18 arm64e tool (e.g. `/usr/bin/true` or `/bin/echo` from the OS dmg, or build a hello world with Xcode `-arch arm64e`).
2. Write the rewriter (skeleton: `research/ios18/tools/scan.c` already enumerates code sections and decodes every class): apply table 3.1 to the tool, libSystem pieces (libsystem_c/kernel/pthread/platform/malloc/dyld/libdyld/libc++/libc++abi/libobjc + their dependencies) as **standalone dylibs extracted from the cache** (`ipsw dyld extract --slide`), and `/usr/lib/dyld`. Skip the cache: have dyld load a flat directory of dylibs (`DYLD_ROOT_PATH`/`DYLD_LIBRARY_PATH` with `DYLD_SHARED_REGION=avoid`); dyld 18 still supports that on internal/unsecure configs [U].
3. Kernel: one patch so `grade_binary` accepts `CPU_SUBTYPE_ARM64E` (and report the host as arm64e for the process or run with `arm64e_preview_abi`-style tolerant path). Chained-fixup binaries need no slide v5 because the cache is avoided.
4. Run `echo hi` via ssh. Success criteria: dyld starts, relocates auth pointers with NOP signing, libSystem initializes, prints. Expected first failures: `sysctl` / commpage fields, PACGA in libobjc init, FJCVTZS not hit.
5. Stage 2 PoC: add slide-v5 support and run the same tool using the real (rewritten) cache.

## 8. Reproduction
`cd research/ios18; DUMP="PACGA;FJCVTZS" tools/scan <dir-with-cache-files> hits.txt img_counts.txt > scan_result.txt` (clang -O2 tools/scan.c; 10 s for the whole cache). Cache source: `ipsw download ipsw --device iPhone11,8 --version 18.7.8 --dyld --dyld-arch arm64e`.

Sources: Arm/Linux hwcap listing for Cortex-A75/A55 (openbenchmarking.org entry "ARMv8 Cortex-A75 8-Core" via search), ID_AA64ISAR1_EL1 layout (df.lth.se Arm sysreg page), apple-oss-distributions/xnu tags xnu-8796.141.3 and xnu-11215.81.4 (cloned and diffed), the repo's own `xnu/patches`, and the measured iOS 18.7.8 cache.
