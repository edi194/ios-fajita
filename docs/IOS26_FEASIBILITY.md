# iOS 26 userland on the Poco F1 (SDM845, no PAC): feasibility study

Date 2026-10-24. Read-only study: nothing was run on the phone. Branch `ios26`. Raw data in `research/ios26/` (gitignored):
`scan_result.txt` (instruction census), `hits_by_image.txt`, `scan.c` (the iOS 18 scanner, unchanged), `apply12377.txt`
(patch dry run), `n104ap.adt` (iPhone12,1 device tree). The 5.8 GB shared cache was deleted after the scan.

Model: `docs/IOS18_FEASIBILITY.md`. Tags as there: **[V]** verified in this session, **[S]** from a source I only searched,
**[U]** unverified.

## 1. Verdict

**Feasible, and much cheaper than 16 -> 18 was.** iOS 26 is the same kind of target as iOS 18 for this phone; the work is a
forward port of Heartwood to xnu-12377 plus a re-run of the Renegade root pipeline on a new identity, not a new research project.

| Question | Answer |
| --- | --- |
| xnu source for iOS 26 | **xnu-12377.x**. Published tags: 12377.1.9, .41.6, .61.12, .81.4, .101.15, **.121.6** (= macOS/iOS 26.5, newest) [V `git ls-remote`]. The 26.7.1 kernel itself is xnu-12377.162.13 (source not published). Target: **xnu-12377.121.6**, the same "a few minors behind" gap as 11215.81.4 under iOS 18.7.8, which works. |
| SPTM / TXM / exclaves | **Not needed.** A13 (T8030) has none of them on iOS 26. The iPhone12,1 26.7.1 BuildManifest has no `Ap,SPTM`, `Ap,TXM` or ExclaveOS component [V], and its kernelcache (`RELEASE_ARM64_T8030`) has the `__PPLTEXT/__PPLDATA` segments of a PPL kernel [V]. So iOS 26 userland must run without them on A13. The classic (non-SPTM) pmap `osfmk/arm/pmap` is still in xnu-12377 and still used by M1/A14 configs [V], so the SWEET config keeps building on it. The iOS 27 blocker does not apply here. |
| Device identity | iOS 26 dropped A12 (our iOS 18 userland is iPhone11,8 = XR, A12). Lowest supported: A13. **Use iPhone12,1 (iPhone 11, N104AP, T8030)**: same 828x1792 @2x LCD class and Face ID/no-Home-button layout as the XR, so the display/HID choices of the iOS 18 port carry over. Alternative iPhone12,8 (SE 2nd gen, D79AP, Home button, 750x1334). The N104AP device tree is fetched (`research/ios26/n104ap.adt`: `compatible N104AP, iPhone12,1, AppleARM`) [V]; `tools/mkadt.py` needs it as the `/product` source the way it uses `d22ap.adt` today. |
| Newest 26.x | **26.7.1 (23H30)**, released 2026-09-28, but **OTA only** (gdmf lists 26.7 and 26.7.1 for 89-95 devices incl. iPhone12,1; ipsw.me has no 26.7 IPSW) [V]. Newest IPSW: **26.6.2 (23G90)**. A full ("Long") OTA exists for iPhone12,1: `iOS2671Long`, 7.6 GB, `updates.cdn-apple.com/2026FallFCS/.../7f095e030b02ac5fedc8415d8b1a752bd9733a8d.zip` [V]; `ipsw extract -r` pulls the kernelcache, device tree and the arm64e cache out of it remotely [V]. So 26.7.1 is usable; the root build has to read an OTA instead of an IPSW. |

## 2. Instruction census: iOS 26.7.1 (23H30) `dyld_shared_cache_arm64e`, iPhone12,1

Same scanner and method as the iOS 18 study (section 3 there). 84 cache files, 4305 images, 783.3 M instruction words
(2987 MiB; iOS 18.7.8: 623.4 M) [V]. **The worry was that dropping A12 lets Apple compile for ARMv8.4 (A13) and use LRCPC2 /
flag-manipulation / FHM everywhere. It did not:** LDAPUR/STLUR 15 (libsystem_m data constants, as in 18), CFINV/RMIF/SETF 0.

| Class | iOS 26.7.1 | iOS 18.7.8 | Handling |
| --- | ---: | ---: | --- |
| PACIBSP / AUTIBSP (hint) | 8.38 M / 3.28 M | 6.69 M / 2.51 M | NOP, untouched |
| RETAB | 5.56 M | 4.54 M | `pacstrip` -> RET |
| BRAA/BRAB, BRAAZ/BRABZ | 3.92 M, 12.9 k | 3.22 M, 11.5 k | -> BR |
| BLRAA/BLRAB, BLRAAZ/BLRABZ | 6.51 M, 249 k | 4.70 M, 202 k | -> BLR |
| PAC*/AUT* reg, zero-mod, XPAC | 5.93 M, 4.97 M, 0.90 M, 1.46 M | 4.53 M, 3.47 M, 0.70 M, 0.85 M | -> NOP |
| LDRAA/LDRAB | 1650 (1344 pre-index wb, 305 neg no-wb fit LDUR, **1 neg no-wb < -256**) | 1617 | -> LDR/LDUR; the one out-of-range site needs a look |
| PACGA | 687 (Foundation 332, CoreGraphics 212, CF 99, JSC 35, libobjc 7, trace 2) | 502 | `pacstrip` EOR mix; CoreGraphics is new, needs the same per-site check |
| **FJCVTZS** | 535 (JSC 523, WebCore 12) | 474 | trap emulation, patch 0141 (exists) |
| FCADD / FCMLA | 16239 / 9038 (libBLAS, libSparseBLAS, VectorKit 4, ShazamKit 4) | 2454 / 0 | Accelerate complex kernels; assumed runtime-gated as in 18 [U] |
| **MTE** (STG/LDG/ADDG...) | 3859 (JSC 3542, libBNNS 157, libsystem_malloc 110, QuartzCore 21, dyld 10, ...) | ~5 (data) | **new**: iOS 26 Memory Integrity Enforcement for A19. Must be gated by `hw.optional.arm.FEAT_MTE*`/commpage caps, because the same cache runs on A13 which has no MTE either [U, inferred]. Kernel must keep reporting no MTE. |
| SHA3/SHA512, FMLAL, BFCVT, SMMLA | 1389, 95, 133, 168 (AV1SW encoder) | 925, 81, 76, 0 | gated by caps, as in 18 [U] |
| SB | 6 | 6 | same as 18 |
| LDAPR, LSE | 133 k, 782 k | 94 k, 426 k | native on Kryo 385 |

Conclusion: `tools/renegade/pacstrip.py` and patch 0141 cover iOS 26 as they are; the only new class, MTE, is the A19-only
path that A13 devices never take. To verify on the phone: `hw.optional.arm.FEAT_MTE*` = 0 and no SIGILL in JavaScriptCore/malloc.

## 3. Kernel: xnu-11215.81.4 -> xnu-12377.121.6

* **Userland interface delta is small** [V diff of the two trees]: BSD syscalls add only 67 `oslog_coproc_reg`, 68
  `oslog_coproc`, 164 `funmount`; Mach traps add only 63 `mach_vm_reclaim_update_kernel_accounting_trap`. Compare 8796 -> 11215.
* **Patch dry run** (`research/ios26/apply12377.txt`): dxb's `patches/26.0` then our 197 `.patch` files of `xnu/patches-11215` with
  `git apply`, in dxb's order: **164 apply cleanly, 33 fail**; with `--reject` the failures leave **21 `.rej` files, ~30 hunks**
  (MakeInc.def machine-config list, kern_exec 0153 EINVAL sites, sleh FJCVTZS hook, vm_dyld_pager arm64e-nopac, arm_vm_init early
  console, prng, start.s, pe_serial, sched_prim AMP steering, exports, ...). Control run on 11215.81.4: 194/197 (the 3 misses
  need the `.sh` hfs/libpthread staging that the dry run did not execute). The three `.sh` staging scripts pin libpthread-535 /
  hfs for 11215 and refuse non-15.x; they need the 26.5-paired versions. Compile-level API drift (kalloc, IOKit, pmap) is unknown
  until the first CI build.
* **Build**: blacktop/darwin-xnu-build at the pinned `663906528d` (= current HEAD) already supports 26.0-26.5 with
  `patches/26.0` and downloads KDK 26.5 (25F71) itself [V read build.sh]. Needs a macOS 26-era runner/Xcode 26.x
  (dxb's own CI: `macos-latest`, Xcode 26.1). Two of dxb's own 26.0 patches (`link_kdk`, `remove_applefeatures_include`) do not
  apply to 121.6 and are skipped with a warning by dxb [V]; check they are not needed.
* The local build path (sccache, `BOUND_CHECKS=0`) is not written down in this repo (no `BOUND_CHECKS` anywhere in the
  worktrees) [V grep]; it has to be recorded when it is set up for 12377.

## 4. Userland risks (beyond 18)

* Root pipeline (`tools/renegade`): fetches the 22H352 iPhone11,8 IPSW dmgs. 26.7.1 needs the OTA path (`ipsw ota extract` /
  `ipsw extract -r`, AEA keys via `--fcs-keys`); 26.6.2 would keep the IPSW path. [U]
* Every iOS 18 stub (IOSurface layout 0157/0159, MCM/usermanagerd, AKS selectors, IOMFB, HID) has to be re-validated against
  26: two OS releases of user-client ABI drift. Expect the same "boot, read the log, patch" loop as 18, but shorter.
* iOS 26's Liquid Glass compositor is heavier; on the CPU path it may be slow, with Chlorophyll (Metal) it is the main
  consumer. Rendering stays in `gpu/metal`, outside this branch.
* iPhone12,1 MobileGestalt/activation keys, Face ID absence (same as XR today), A13-specific daemons (U1 chip: `nearbyd`) to
  disable.

## 5. Estimate

| Work item | Time |
| --- | --- |
| Rebase the 33 failing patches, new `.sh` staging (libpthread/hfs for 26.5), CI on 12377, first green build | 1-2 weeks |
| Compile-level API fixes found by the build | 0.5-1 week |
| ADT for iPhone12,1 (`mkadt.py --identity n104ap`), boot to launchd on the iOS 18 root (kernel check) | days |
| Renegade root for 26.7.1 (OTA input, iPhone12,1), boot loop to SpringBoard | 3-6 weeks |
