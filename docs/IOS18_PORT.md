# iOS 18 port: stage 1 (one arm64e command-line tool with iOS 18's own dyld and libSystem)

Branch `ios18`. Background and instruction counts: `docs/IOS18_FEASIBILITY.md`. This document is the "what was done / how to run / how to read a failure / what comes next" for the first proof of concept.

Status: everything below was verified **statically** on the Mac (rewriter output disassembled, signatures checked, kernel patch compiled and applied to the bt130 tree). **Nothing has been run on the phone** (not allowed in this session): the run-time statements are predictions, tagged [U].

## 1. What the PoC is

`/var/root/ios18poc/bin/expr 6 '*' 7` on the iOS 16.7.16 userland of the Poco F1, over SSH, where `expr` is the real iOS 18.7.8 (22H352) arm64e binary, launched by the **iOS 18 `/usr/lib/dyld`**, which loads **iOS 18's libSystem and its 115 dependencies from disk** (no shared cache), all statically rewritten to ARMv8.0 (no PAC), on the current xnu-8796 kernel plus patch 0131. Success = prints `42`, exit status 0.

### Where the iOS 18 binaries come from (the finding that made this cheap)
* The IPSW's root dmg (6.5 GB) is AEA-encrypted: not downloaded (limit 6 GB).
* The **restore ramdisk** (`094-32147-020.dmg`, 176 MB, IMG4 -> plain APFS, not encrypted, extracted by `ipsw img4 im4p extract`, mounted with `hdiutil attach -imagekey diskimage-class=CRawDiskImage`) is a complete on-disk iOS 18 userland: `/usr/lib/dyld`, `/usr/lib/libSystem.B.dylib` plus all of `/usr/lib/system/*.dylib`, libobjc, libc++, libswiftCore, CoreFoundation, Foundation, ... (103+ dylibs, **real chained fixups, no dyld shared cache**), and tools `/bin/{cat,expr,ln,mkdir,mv,rm}`, `/usr/bin/sed`. All thin arm64e (cpusubtype `0x80000002`, PAC ABI version 0).
* So there is no need for the cache: the ramdisk dylibs are the "flat directory of dylibs".
* Dylibs extracted from the shared cache (`ipsw dyld extract`) were tested and are **not loadable**: no rebase/bind info (LC_DYLD_CHAINED_FIXUPS absent), cross-image pointers are already resolved to cache addresses. That route would need a fixup reconstructor. Not used.
* The dyld inside the cache (0x1a9648000) is not usable as a file either (segments packed at unaligned cache addresses, ADRPs depend on that layout).

Note the dependency closure is bigger than "libSystem": libSystem -> libdispatch -> libobjc -> **libswiftCore -> CoreFoundation/Foundation -> ICU, Security, Network, ...** (116 dylibs, 143 MB with the tools). That is the real iOS 18 link graph; weak dependencies (libRosetta, libobjc-env) are absent on disk and skipped.

## 2. Decisions

| Question | Choice | Why |
| --- | --- | --- |
| How does iOS 18 dyld avoid the cache? | **It does not need a switch.** `DYLD_SHARED_REGION=avoid` exists only for the simulator in dyld-1286 (`DyldProcessConfig.cpp`: "only support DYLD_SHARED_REGION=avoid on simulator"). On a device dyld asks the kernel's shared region (`__shared_region_check_np`), validates the magic (`dyld_v1  arm64e`) and, if nothing compatible is there, runs without a cache (loads from disk). Our region holds the iOS 16 arm64 cache; its magic differs, so dyld reports "existing shared cache in memory is not compatible" and goes cache-less. | read from dyld-1286.10 source (`SharedCacheRuntime.cpp: reuseExistingCache`) [V read, U run] |
| How are the dylibs found? | **`DYLD_LIBRARY_PATH=/var/root/ios18poc/lib`** for dylibs and **`DYLD_FRAMEWORK_PATH=/var/root/ios18poc/Frameworks`** for frameworks (dyld does not apply DYLD_LIBRARY_PATH to `X.framework/X` install names: first run failed on CoreFoundation; `mkbundle.py` now lays frameworks out as `Frameworks/X.framework/...`, weak dependencies are included when the ramdisk has them, missing ones are reported; 0 hard dependencies are missing)  + kernel `LC_LOAD_DYLINKER` of each tool rewritten to `/var/root/ios18poc/dyld` (load commands repacked into header slack by `pacstrip.py --dylinker`). | Simplest: no install-name edits (the load commands have no room for longer paths), nothing outside `/var/root/ios18poc`. A chroot would need a chroot binary (toybox build has none) and /dev. |
| Why does that need the kernel? | dyld asks `amfi_check_dyld_policy_self` = `__sandbox_ms("AMFI", 0x5a, &{input, &output})` (disassembled in 22H352 dyld at 0x287c8). Our "AMFI" policy answered ENOPOLICY = "restricted": **no DYLD_\* env vars, no `@` paths, no DYLD_PRINT_\***. 0131 answers op 0x5a with all `AMFI_DYLD_OUTPUT_ALLOW_*` bits (0x3ff), only for arm64e processes and only with `sweetarm64e=1`. | `docs/EXTENSION_POINTS_2.md` already recorded the ENOPOLICY behaviour. |
| arm64e kept, or cpusubtype changed to arm64? | **Keep arm64e** and patch the kernel. `pacstrip.py --subtype arm64` exists as an experiment but is not recommended. | (1) Chained fixups: the format is selected by `dyld_chained_starts_in_image.pointer_format` inside the file, so an arm64 subtype would not break auth-fixup parsing; that part is neutral. (2) But an arm64-subtype process shares the iOS 16 shared region; iOS 18 dyld would then try to adopt the iOS 16 cache. (3) dyld's arch grading: arm64e dyld + arm64 main executable = "keys off", which accepts the arm64e dylibs, so it can work, yet it silently differs from the real configuration and from what stage 2 (arm64e cache) needs. (4) The kernel patch is 40 lines and gated. (5) The AMFI answer is needed in any case. |
| Resign | ad hoc, `codesign -f -s -` with the original entitlements re-applied (as `tools/sweet-install-ipa.sh` does). The kernel's AMFI stand-in (0025/0036) validates the blob structure only. | [U] depends on the stand-in accepting every page hash set |

## 3. What is in the branch

| File | Purpose |
| --- | --- |
| `tools/renegade/pacstrip.py` | The rewriter. 4 bytes for 4 bytes, only executable sections, LC_DATA_IN_CODE skipped, fat arm64 slices handled. Table in its docstring (same as feasibility 3.1): RETAA/B -> `ret`; BR/BLR(AA/AB, Z or register) -> `br/blr Xn`; LDRAA/B -> `ldr` (pre-index/offset, `ldur` for small negatives); PACI*/PACD*/AUTI*/AUTD*/XPAC* -> `nop`; PACGA -> `eor Xd,Xn,Xm,ror #k` (k depends on the registers, `mov Xd,Xn` when the modifier is SP); hint space untouched; FJCVTZS counted and printed (file offsets), left alone. `--scan` counts only, `--sign` re-signs, `--dylinker PATH` rewrites LC_LOAD_DYLINKER. Pure Python, no dependencies, ~1 s per large dylib. |
| `tools/renegade/fetch-ramdisk.sh` | Downloads only the restore ramdisk member of the IPSW (range requests via `tools/remotezip.py`), extracts IMG4, mounts it read-only. |
| `tools/renegade/mkbundle.py` | Dependency closure of the chosen tools -> `research/ios18poc/{dyld,lib/,bin/,MANIFEST.txt}`; runs pacstrip + codesign on every Mach-O. |
| `tools/renegade/run-poc.sh` | Pushes the bundle (tar over SSH, skipped when unchanged) and runs the tool with the dyld diagnostics. |
| `xnu/patches/0131-ios18-arm64e-exec.patch` | Kernel patch (below). Applies on top of 0001-0130 (checked with `patch -p1` and `git apply --check` on `research/bt130/xnu`; the three files compile with `tools/xnu-cc.py`). |

### Kernel patch 0131 (everything behind boot-arg `sweetarm64e=1`, keyed on the CPU subtype being arm64e)
1. `bsd/dev/arm/kern_machdep.c grade_binary()`: host `CPU_SUBTYPE_ARM64_V8` accepts `CPU_SUBTYPE_ARM64E` (grade 8, below a real arm64 slice, so iOS 16 fat binaries still pick their arm64 slice; also applies to dyld itself and dylib grading in `mach_loader`). Without the boot-arg: unchanged (arm64e grades 0, exec fails as before).
2. `bsd/kern/kern_exec.c`: `sweet_arm64e_enabled()` / `sweet_proc_is_arm64e()` helpers; apple string `ptrauth_disabled=1` for arm64e execs (what a ptrauth kernel passes when JOP keys are off; dyld's `getMainArchs` reads it). That code is `#if __has_feature(ptrauth_calls)` in xnu, so it did not exist in our build.
3. `bsd/kern/sweet_amfi.c`: "AMFI" policy op 0x5a (dyld policy) as described above.
4. **Not changed** and why: `hw.optional.arm.FEAT_*` already exist in xnu-8796 and answer from the ID registers (`gARM_FEAT_PAuth/PAuth2/FPAC/JSCVT/SHA3/SHA512/FCMA/I8MM/BF16 = 0` on this CPU); the iOS 18-only names (`FEAT_SME`, `FEAT_SME2`, ...) return ENOENT, which callers treat as 0 [U]. `hw.cpusubtype` stays arm64 v8 (reporting arm64e would change the shared-region and fat grading for iOS 16 processes; not needed for the PoC). Shared region: `exec` uses one region for all subtypes (`cpu_subtype = 0` outside the ptrauth block), so the arm64e process sees the iOS 16 cache mapped and ignores it (section 2, row 1).

## 4. Build, boot, run (commands)

```sh
# 0. bundle (once; needs ipsw, Xcode command-line tools; ~180 MB download, 143 MB result)
cd /Users/zesmoi/git/iAndroid/ios-beryllium-ios18
tools/renegade/fetch-ramdisk.sh                     # prints the mountpoint research/ios18/ramdisk/mnt
python3 -I tools/renegade/mkbundle.py research/ios18/ramdisk/mnt research/ios18poc
diskutil eject research/ios18/ramdisk/mnt && rm -f research/ios18/ramdisk/094-* research/ios18/ramdisk/ramdisk.apfs

# 1. kernel with 0131: CI builds branches only by dispatch
git push -u origin ios18                         # you review first
gh workflow run xnu.yml --ref ios18 -R ry-diffusion/Bergamota
gh run list -R ry-diffusion/Bergamota --branch ios18 -L 1      # note the run id, then
gh run download <ID> -R ry-diffusion/Bergamota -n xnu-kernel -D xnu/out-0131

# 2. boot image: same ADT, payload and cmdline as your current image, plus sweetarm64e=1
python3 tools/mkpayload.py xnu/out-0131/kernel.development.sweet shim/out/<current>.adt shim/out/payload-0131.bin \
    --cmdline "<your current cmdline> sweetarm64e=1"
BOARD=beryllium shim/build.sh shim/out/payload-0131.bin && cp shim/out/shim-boot.img shim/out/shim-boot-0131.img
fastboot boot shim/out/shim-boot-0131.img        # then wait for ssh root@192.168.7.2

# 3. run
tools/renegade/run-poc.sh                           # expr 6 '*' 7 with DYLD_PRINT_* diagnostics
tools/renegade/run-poc.sh --quiet -- cat /etc/hosts
```
(The artifact name `xnu-kernel` and the `kernel.development.sweet` file name are from NOTES.md's workflow; use whatever your last `gh run download` used. The worktree has no `shim/out`; either run step 2 in the main checkout with the downloaded kernel, or copy the ADT/payload tools' inputs.)

The cmdline of your current image is in the command that produced `shim/out/shim-boot-0126x3.img` (not recorded in the repo as text; `fastboot`-boot images embed it in the ramdisk payload header: `python3 tools/unpack_bootv2.py` or `unpack_bootimg` shows it).

## 5. Expected output [U]

`run-poc.sh` first prints `uname`, `kern.bootargs` (warns when `sweetarm64e=1` is missing), then the tool output, then an exit status. With the diagnostics on (stderr, `DYLD_PRINT_TO_STDERR=1`) expect, in this order:
1. `dyld[PID]: ...` environment dump (`DYLD_PRINT_ENV`), proving the AMFI answer worked (if the env vars were ignored nothing at all is printed, see 6.2).
2. `DYLD_PRINT_SEARCHING` lines like `  found: "/var/root/ios18poc/lib/libSystem.B.dylib"` (the `DYLD_LIBRARY_PATH` override of `/usr/lib/libSystem.B.dylib`) and an "existing shared cache in memory is not compatible" / "no cache" style line.
3. `DYLD_PRINT_LIBRARIES`/`SEGMENTS` for ~116 images, then `DYLD_PRINT_INITIALIZERS`.
4. `42` and `== exit status 0`.

Cost: loading 116 dylibs without prebuilt loaders: seconds.

## 6. Reading a failure

| Symptom | Meaning / next step |
| --- | --- |
| `Bad CPU type in executable` / `exec format error` (ssh prints errno 86 or 8) | `grade_binary` refused: boot-arg `sweetarm64e=1` missing, or the old kernel is running. `run-poc.sh` prints the boot-args. |
| `Killed: 9` with no dyld output, instantly | Code signature/AMFI. Kernel log (`SWEET AMFI:`, `cs_invalid_page`, `CS_KILLED`): the ad-hoc blob was refused. Try `pacstrip.py --sign` again on that file, check `codesign -v`. |
| `dyld: Library not loaded: /usr/lib/libSystem.B.dylib` (or any `/usr/lib/...`), and with DYLD_PRINT_SEARCHING `Note: DYLD_*_PATH env vars disabled by AMFI` | The 0x5a answer did not reach dyld. Check the kernel log for `SWEET AMFI: expr __mac_syscall("AMFI", 0x5a)` (the existing 0099 code prints each op once); confirm `sweet_proc_is_arm64e` (the process must exec as arm64e). Struct layout assumption: `{u64 input; u64 *output}` at the third argument. |
| `Library not loaded ... (no such file)` for one specific dylib | The dependency was not in the bundle (`MANIFEST.txt` lists what is) or it is a leaf-name clash; mkbundle asserts uniqueness. |
| Signal 4 (SIGILL, exit 132) | A word the rewriter does not cover. Get the PC (kernel log/`ReportCrash`), subtract the slide, `python3 -I tools/renegade/pacstrip.py --scan FILE` and `llvm-objdump -d --mattr=-pauth` around the offset. Known candidates: FJCVTZS (not rewritten), SHA3/SHA512 words in corecrypto and dyld (must be gated by `hw.optional.arm.FEAT_SHA3/SHA512` = 0, which this kernel reports), SB, SVE/SME words in libsystem_platform (gated). |
| Signal 11/10 early, no dyld lines | dyld's `rebaseSelf`/startup: `__DATA_CONST` `mprotect`, `__TPRO_CONST` segment (kernel 8796 ignores the TPRO flag, dyld uses `vm_protect` fallbacks), first syscalls. Run with `DYLD_PRINT_SEGMENTS`; if even that prints nothing the fault is before config. Check the kernel's exception report for the PC and offset in `dyld`. |
| `dyld: ... PAC failure` / `brk #0xc47x` | A pointer was authenticated against a signature that does not exist: an AUT* we turned into NOP is followed by a check we did not expect, or an instruction encoding was missed. The brk immediates are `0xc470`-`0xc473` (key-specific); find the site and its class. |
| Hang | Syscall that blocks (kdebug/`kdp` or `__shared_region_*`), check `kern.bootargs`, `sample`/`spindump` are not in the iOS 16 root; use the kernel log (`tools/sweet-usbnet.sh`). |
| Output but wrong values | PACGA replacement collisions (Foundation/libobjc hashes) or similar; compare with a clean `expr` run of the same operands. |

Collect on failure: `research/ios18/last-run.txt` (written by the script), the UDP kernel log, and the PC/offsets.

## 7. Stage 2 plan: whole rewritten shared cache + slide info v5

Goal: stop using the ramdisk dylibs; run iOS 18's own 4.8 GB `dyld_shared_cache_arm64e` (67 files, 3861 images, slide-info v5), i.e. the prerequisite for launchd/SpringBoard.
1. **2a, no kernel work: private cache.** `DYLD_SHARED_REGION=private DYLD_SHARED_CACHE_DIR=<dir>` is honoured when `AMFI_DYLD_OUTPUT_ALLOW_CUSTOM_SHARED_CACHE` (0x4) is granted (already part of 0x3ff). dyld maps the files itself and applies v5 slide info in userland (`SharedCacheRuntime.cpp rebaseDataPages`, v5 case), signing pointers with PAC instructions that are NOPs after the rewrite. dyld-in-cache restart is disabled in this mode (`DYLD_SHARED_REGION` set), good. Needs: a `pacstrip.py cache DIR` mode: walk every subcache file, map each image's executable sections to file offsets through the mapping tables (`dyld_cache_mapping_info`, subcache entries), rewrite them with the same table, and **fix the code signature of each cache file** (dyld registers it with `F_ADDFILESIGS_RETURN` and checks it covers the file; recompute the CodeDirectory page hashes in place). The cache has no data-in-code info: the false-positive risk is the 1,595 LDRAx "hits" in TextToSpeechMauiSupport and a few others (data); whitelist LDRAA/LDRAB to images known to contain real ones (libc++abi) and spot-check the other classes (done for the feasibility study).
2. **2b, kernel: slide info v5.** Port `vm_shared_region_slide_page_v5` and `vm_shared_region_slide_info_entry_v5` (about 120 lines, xnu-11215.81.4 `osfmk/vm/vm_shared_region.c`; the signing parts are `#if __has_feature(ptrauth_calls)` so on our kernel it just writes `(value & 0x3FFFFFFFF) + value_add + slide`), accept `shared_region_map_and_slide_2_np` with v5 `dyld_cache_slide_info5` (xnu-8796 knows v1-v4) and the new `__map_with_linking_np` call (dyld falls back to in-process linking if it fails, so a stub returning an error is enough at first). Then the system-wide cache works and the on-disk dyld restarts into the cache's own dyld (UUID check in `dyldMain.cpp`), also part of the later userland.
3. FJCVTZS: 474 sites in JavaScriptCore/WebCore. Either an EL1 undefined-instruction emulator (decode `0x1e7e0000|Rn<<5|Rd`, ~15 instructions incl. NZCV Z) or per-site islands; JavaScriptCore's JIT checks `hw.optional.arm.FEAT_JSCVT`, so the JIT already avoids it.
4. launchd and the rest: rewrite `/sbin/launchd` and every executable the same way (the rewriter already handles a Mach-O executable and re-signs), then userland bring-up as in feasibility section 5.
5. Rebase vs backport: stay on xnu-8796 plus 0131 plus the v5 port; revisit if iOS 18 daemons need newer syscalls.

## 8a. First on-device run and the Bus error (patch 0134)
First run (kernel with 0131): dyld honoured the AMFI answer (`DYLD_PRINT_*` output), resolved all 117 images (after the frameworks fix), ran libSystem's initializer and died with `Bus error: 10`, `far` in libdispatch `__AUTH_CONST`. Diagnosis (from `research/ios18/last-run.txt`):
* **No VA overlap**: all 674 distinct segment ranges listed by `DYLD_PRINT_SEGMENTS` were checked, the only "overlap" is `__PAGEZERO` vs the first `__TEXT`. (MobileSystemServices `__AUTH_CONST+0x4e0` has the same offset as libdispatch's by coincidence of the page offset, not the VA.)
* The log line before every data segment is `Setting up kernel page-in linking for <image>`: iOS 18 dyld defaults to `pageInLinkingMode = 2` (not changeable without an internal install: `DYLD_PAGEIN_LINKING=0` is honoured only if `internalInstall()`), so data segments with chained fixups are mapped through `map_with_linking_np` (xnu-8796 has it, `bsd/vm/vm_unix.c`) and the fixups are applied **by the kernel's dyld pager at page-in** (`osfmk/vm/vm_dyld_pager.c fixup_page`).
* That pager handled `DYLD_CHAINED_PTR_ARM64E`, `_USERLAND` and `_USERLAND24` only under `#if defined(HAS_APPLE_PAC)`, which our build does not define. For every arm64e image it printed `unknown pointer_format` (kernel log) and returned `KERN_FAILURE`; the first touch of such a page (here libdispatch `__AUTH_CONST+0x4e0`, `pc` = libdispatch `__TEXT+0x3cc08` right after libSystem's initializer started) is `KERN_MEMORY_ERROR` = SIGBUS code 0x10000000a. Not a rewriter problem.
* **Fix: `xnu/patches/0135-ios18-dyld-pager-arm64e-nopac.patch`**: build `fixupPageAuth64` always and, without PAC, make `signPointer()` the identity (pointers stay unsigned, which is what the rewritten code expects: the AUTx instructions are NOPs). Auth and non-auth rebases/binds are walked exactly as in the PAC build (stride 8, 24-bit ordinals, offset- or vmaddr-based targets). Compiles with `tools/xnu-cc.py`; applies on bt130. It needs a new kernel (CI) but no other change: same bundle, same `tools/renegade/run-poc.sh`. Only arm64e images use these pointer formats, so arm64 processes are unaffected.
* If it still faults, the kernel log now says why: `fixupPageAuth64(): ...` lines.

## 8. Limits of what was verified here
* Rewriter: counted over the whole bundle; re-disassembled with `llvm-objdump` (PAuth on): zero remaining PAC instructions outside hint space in dyld, libobjc, libc++abi, libsystem_c, expr; with PAuth off the only undecodable words are SHA3 (dyld, gated) and data. Signed bundle passes `codesign -v`.
* Not verified: any execution; the AMFI struct layout (read from disassembly); that the kernel's AMFI stand-in accepts the new ad-hoc blobs; behaviour of the iOS 18 libs on this kernel after dyld (syscalls/sysctls/commpage), expected to need more patches (feasibility 5.1).
* Sources: iOS 18.7.8 22H352 IPSW (iPhone11,8), dyld-1286.10 source (`apple-oss-distributions/dyld`), xnu bt130 tree.


## 9. Stage 1b: boot the iOS 18 restore ramdisk itself as the root (launchd 18 as PID 1)

"For fun" version of the bring-up: no phone filesystem, no iOS 16: the kernel mounts the rewritten iOS 18.7.8 restore ramdisk as the root (`rd=md0`) and runs **its** `/sbin/launchd` (arm64e, rewritten, signed) as PID 1 with **its** `/usr/lib/dyld` and libs at their native paths (no DYLD_* env needed: the paths exist; dyld finds no cache and loads from disk).

### Image
* APFS: our xnu-8796 has no APFS (closed kext), so `tools/renegade/mkramdisk-root.sh` converts: stage (`tools/renegade/mkroot.py`: ditto without compression/xattrs, prune, pacstrip --sign of every Mach-O) -> case-sensitive **unjournaled** HFS+ (`newfs_hfs -s`, the kernel's built-in hfs, same as the iOS 16 root) built **without sudo**: attached as a user raw image, populated with ditto, then `tools/renegade/hfsroot_chown.py` sets owner/group of every catalog record to 0:0 in place (the unprivileged Mac user cannot chown; the catalog B-tree leaf walk is 60 lines).
* Pruned: `/usr/standalone` (49 MB firmware), `/usr/local` (restore tools), `Filesystems`, every Mach-O not reachable from `launchd`, `dyld` and `/bin/*` (183 files) -> 125 Mach-O files, **185 MB** image (the ramdisk's ~140 MB of APFS data inflates because decmpfs-compressed files are written uncompressed; the kernel has no decmpfs). Whole boot payload with an existing kernel: **201 MB** (`mkpayload` checked), the ABL fastboot limit is 768 MiB (NOTES).
* Stock LaunchDaemons (restored_external, camera, driverkitd, ...) are removed (`--stock-daemons` keeps them): they would fight over USB and crash-loop. Two jobs are added that print to the console: `org.sweet.ios18.expr` (`/bin/expr 6 * 7` -> `42`) and `org.sweet.ios18.passwd` (`/bin/cat /etc/master.passwd`).

### Build and boot
```sh
cd /Users/zesmoi/git/iAndroid/ios-beryllium-ios18
tools/renegade/fetch-ramdisk.sh                  # mounts research/ios18/ramdisk/mnt
tools/renegade/mkramdisk-root.sh                 # -> research/ios18/ios18-root.hfs (about 1 minute, no sudo)
# kernel: 0131 + 0133 (hw.targettype) + 0134 (dyld pager) must be in the CI build
python3 tools/mkpayload.py xnu/out-NNNN/kernel.development.sweet shim/out/beryllium-hi-3x.adt shim/out/payload-ios18rd.bin \
    --ramdisk research/ios18/ios18-root.hfs --compress \
    --cmdline "debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=md0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1"
BOARD=beryllium shim/build.sh shim/out/payload-ios18rd.bin && cp shim/out/shim-boot.img shim/out/shim-boot-ios18rd.img
tools/sweet-usbnet.sh logs/live-ios18rd.txt &          # kernel log over USB (sweetusb=2)
fastboot boot shim/out/shim-boot-ios18rd.img
```
Differences from the usual cmdline: `rd=md0` instead of `rd=ufsroot0`, no `ufsrw=1 rootrw=1` (userdata is not touched at all), no Wi-Fi/BT/net/sample options; `launchd_disable_all_timeouts=1` is a launchd 18 boot-arg (string in the binary) so slow first launches are not killed. `shim/out/beryllium-hi-3x.adt` is the @3x ADT; use whichever your last image used (the cmdline above is the last image's, `payload-ios18.bin`, minus the changes listed). `sweetarm64e=1` is mandatory.

### What to expect [U], and how to read the log
1. Usual kernel boot, then `BSD root: md0`, `hfs: mounted iOSRoot on device ...`, `SWEET: root volume is not authenticated ...; continuing unsealed`, `load_init_program: /sbin/launchd`.
2. No exec error if grading works (`Bad CPU type` / panic `initproc failed to start` with exec error 86 = boot-arg missing).
3. launchd 18 starts (dyld loads libSystem etc. from `/usr/lib`): first signs on the console are `launchd[1]` lines (it prints to `/dev/console`), then the two jobs print `42` and the passwd file. That would be the whole success criterion: iOS 18 PID 1 runs jobs.
4. Failure modes and where they show: **panic `initproc exited`/`unexpected SIGKILL of launchd`** with namespace/code: 9/0xe = platform check (alien binary, boot-arg `unentitled_ios_sim_launch=1` is in the cmdline), 2/0xa SIGBUS = the pager fixup (should be fixed by 0134; kernel log has `fixupPageAuth64()` or `dyld_pager` lines), 2/0x4 SIGILL = an instruction class the rewriter does not cover (find the pc offset in the Mach-O, `pacstrip.py --scan`), 2/0xb SIGSEGV; code-signing kills (`CS_KILLED`, `cs_invalid_page`) mean an ad-hoc blob was refused. launchd asserts print the message on the console: known one that is handled: `sysctl hw.targettype was not set` (0133 adds the sysctl); likely next ones: `kern.*`/`hw.*` sysctls that do not exist in xnu-8796, `host_set_special_port`/`task_set_exception_ports` policy calls, `sandbox_init` and AMFI selectors other than 0x5a/0x60 (the "SWEET AMFI: ... __mac_syscall("AMFI", 0x..)" lines list every new op once), coalition/memorystatus/`proc_info` flavours, `reboot3`. The panic string and the last 20 kernel log lines are what to send back.
5. launchd 18 in a restore ramdisk wants `/System/Library/LaunchDaemons` plists only; there is no `xpcproxy`, `launchctl`, `logd` etc. in this ramdisk, so `xpc` services that launchd normally spawns for itself may report errors; they are expected noise.

## 10. Sandbox / AMFI stand-in vs. iOS 18 libSystem initializers (patch 0136)

Third on-device run: after the pager fix, `running initializer ... libSystem.B.dylib`, then `Abort trap 6`, kernel reason `_container_init(): sandbox_get_container_expected() failed: -1` (namespace 18 code 2).
* `_sandbox_get_container_expected(bool *a, bool *b)` (libsystem_sandbox, **byte-identical logic in iOS 16.7 and 18.7**): `__sandbox_ms("Sandbox", 0x43, args)` with `args = { u64 *out_a, u64 *out_b }`, both slots zeroed by the caller; returns -1 if the syscall fails, else `*a = (out_a != 0)`, `*b = (out_b != 0)`.
* `_container_init` (libsystem_containermanager, iOS 18): call fails -> abort; `a == 0` -> "no container expected", done. Our stand-in answered ENOENT -> abort.
* iOS 16's `_container_init` calls the function only behind an earlier condition, and its failure branch is also a `brk` (abort); so ENOENT never hurt it, and the new answer (success, both outputs 0 = "no container expected") is what it would expect too. Op 4 (`sandbox_container_path_for_pid/audit_token`) keeps ENOENT: `__sandbox_in_a_container` is `(ret == 0)`, so -1 means "not in a container", correct.
* `xnu/patches/0136-sweet-sandbox-container-expected.patch` (diff vs main bt133 + 0131 + 0135; compiles): op 0x43 copies in the two pointers and writes 0 to each non-NULL one. The "first time op seen" log now covers ops up to 255 (the old `< 64` test hid every op above 0x3f, including 0x43).

Look-ahead (static scan of all 117 bundle images for `__sandbox_ms` call sites with policy "AMFI"/"Sandbox", `/private/tmp/.../ops.py`-style: adrp/add string, `mov w1,#op`, `bl`):
* **Sandbox**: ops 0-0x1e, 0x34/0x35/0x3d-0x4f, 0x53, 0x103-0x107 occur, all inside libsystem_sandbox's API functions. The stand-in returns 0 without writing outputs for everything except 4 (ENOENT), 5/6 (extension issue/consume, implemented), 0x43 (fixed). Zero-without-output is harmless for the API at init: `sandbox_check` (2) = allowed, `sandbox_enable_state_flag` (0x41) = true, `rootless_check_trusted` family = trusted; `sandbox_reference_retain_by_audit_token` (0x1c) yields -1 and only matters for later (sandboxed helper) code. Nothing else in libSystem's initializer path returns a value that is then aborted on.
* **AMFI ("AMFI" policy)**: 0x5a (dyld policy: dyld and libsystem_trace; answered for arm64e since 0131), 0x60 (bootarg state; answered by 0099), and ENOPOLICY for the rest: 0x5b dyld policy for pid (libsystem_trace), 0x5f cdhash in trust cache (Security, AppleMobileFileIntegrity: "not trusted", fine), 0x61-0x64 local-signing keys, 0x65/0x69 load/unload trust cache (dyld, trace), 0x66 launch-constraint match (libxpc `__xpc_connection_token_satisfies_lwcr`, Security: ENOPOLICY = constraint not satisfied: **likely next problem for launchd/xpcproxy launch constraints**, not touched without evidence), 0x68 restricted-execution-mode status (libxpc returns `ret == 0`, so ENOPOLICY = "not restricted": correct). None is called by libSystem's own initializer chain in a way that aborts on failure; the per-op "SWEET AMFI: ... __mac_syscall("AMFI", 0x..)" log lists what a run really uses.


## 11. Black screen on the first stage 1b boot: ABL's ramdisk budget (shim inflate, `--compress`)

First boot of `shim-boot-ios18rd.img` (206 MB payload): fastboot OK, "Booting OKAY", then a **black** screen, no console, no USB log. The shim's first act is `con_clear(RED)`, so a black screen means ABL never started the shim: it failed while placing the boot.img ramdisk.
* **Where ABL puts the ramdisk** (evidence: NOTES 2026-10-14, a 15.8 MB payload: `initrd 0x846F0000-0x855FE3E0`; header says ramdisk address 0x01000000, which ABL does not honour): `lo = 0x85600000 - size rounded up to 64 KiB` (0xF0E3E0 -> 0xF10000; 0x85600000 - 0xF10000 = 0x846F0000, exact). 0x85600000 is the top of the usable low DDR below the hyp/xbl/cmd-db/smem carve-outs (`dtb/beryllium/live.dts`: hyp 0x85700000, xbl 0x85d00000, cmd-db 0x85fe0000, smem 0x86000000, removed 0x86200000-0x8a900000, ...). One data point, but it fits to the byte.
* So the ramdisk must fit between the DDR base 0x80000000 (ABL's kernel is at 0x80008000, tags at 0x80000100, then our 0.4 MB shim) and 0x85600000: **86 MiB theoretical maximum**; a 206 MB payload would start at 0x78800000, below the DDR: ABL cannot place it. The shim's own copy to 0x1_00000000+ is not the problem (the upper bank has no carve-outs; the shim checks the overlap anyway).
* **Safe size**: stay below about 56 MiB (start >= 0x82000000, well above ABL's low structures). Proven so far: 15.8 MiB. Not proven: anything above. `tools/renegade/abl-ramdisk-probe.sh KERNEL ADT [MiB...]` builds images with an uncompressed zero ramdisk of 40/56/72/88 MiB; boot them (photograph the `INITRD lo=` line, black = over the limit) to measure the real limit.

Fix in this branch:
* `mkroot.py` now runs `strip -x` on the dylibs (not on dyld/launchd/tools): symbol tables were 25% of the data (145 MiB of dylibs -> 122 MiB; verified: all 118 Mach-O files still pass `codesign -v`, chained fixups untouched). Root image 185 MiB -> **158 MiB** (`research/ios18/ios18-root.hfs`; about 30 MiB of it is free HFS space).
* `tools/mkpayload.py --compress` writes payload **version 2**: every segment >= 1 MiB is raw DEFLATE (zlib level 9) with a fifth u64 (`raw_size`) in the segment table; kernel segments shrink too (16.7 -> 7 MiB). The shim (`shim/loader.c`) accepts v1 and v2 and inflates into place with `shim/inflate.c`, a freestanding puff-style decoder using byte accesses only (MMU off = Device memory). Verified on the host against zlib (`shim/inflate_test.c`: stored, fixed and dynamic blocks, levels 0-9, 1 byte, empty, random, a 35 MB Mach-O); the shim cross-builds with `build.sh` (no absolute relocations) and a v2 payload decodes bit-exactly (ramdisk compared with the source image).
* Result: **payload 50.7 MiB** (ramdisk 165.7 MiB -> 44.1 MiB, gzip-9 ratio 3.8) instead of 206 MB, so ABL places it at about 0x82590000. Ready image (kernel = `xnu/out-ios18`, i.e. without 0136; rebuild the payload with the newer kernel using the commands in section 9): `research/ios18/shim-boot-ios18rd-z.img`.
* Cost: the shim now spends time inflating 165 MiB into Device memory with byte accesses: expect tens of seconds (no caches), shown on the red screen as `INFLATE in=... out=...` and `INFLATE MiB=...` every 32 MiB. A hang there for up to ~2 minutes is not a crash.
* If the screen is still black with the compressed image: run the probe images; if even 40 MiB is black the ramdisk placement theory is wrong and the next suspects are ABL's kernel-image handling (Image.gz-dtb is unchanged since the 17 MB images) and fastboot buffer placement.

## Milestone 2026-10-20 ~18:27: iOS 18 userland runs jobs under its own launchd

RAM-disk root (`shim/out/shim-boot-ios18-pacga.img` in the main checkout), kernel `xnu/out-0139`
(0131 + 0135 + 0136 + 0138 + 0139), `sweetarm64e=1`, shim with the cached inflate: iOS 18.7.8 launchd
bootstraps, spawns `org.sweet.ios18.expr` and `org.sweet.ios18.passwd` through xpcproxy, and both exit 0
(`42` and iOS 18's /etc/master.passwd on the console). The steps that got here, in order:
ABL ramdisk budget (`--compress`, inflate) -> 0138 mach_ports_lookup3 reply layout (MIG -300) ->
0139 exclaves_ctl_trap KERN_NOT_SUPPORTED (SIGSYS in launchd's exclaves-boot) -> keep /usr/libexec/xpcproxy
in the pruned root -> pacstrip PACGA with a constant rotation (Foundation _NSThreadData MAC, brk in
__NSThreadPoisoned; docs/IOS18_XPCPROXY.md). Next: the full system on userdata (tools/renegade/*full*).


## 12. Full iOS 18.7.8 root on userdata (`tools/renegade/mkroot-full.py`)

Goal: the whole iOS 18 system (SpringBoard, daemons, default wallpapers) as an HFS+ image for the `userdata` partition,
flashed like the iOS 16 image (`fastboot -S 512M flash userdata X.simg`) and booted with `rd=ufsroot0 ufsrw=1 rootrw=1`.
Nothing here was flashed or booted (not allowed in this session): everything below was verified offline.

### Source files
IPSW iPhone11,8 18.7.8 (22H352): root `094-31934-020.dmg.aea` (6.6 GB), SystemOS cryptex `094-32062-020.dmg.aea` (1.7 GB),
AppOS cryptex `094-32850-020.dmg` (plain). Fetched with `ipsw download ipsw --device iPhone11,8 --version 18.7.8 --pattern
'^094-(31934|32062|32850)-020\.dmg(\.aea)?$' --flat` (about 8.3 GB, ~25 min) and decrypted with `ipsw fw aea X.dmg.aea -o DIR`
(the fcs-key is fetched from wkms-public.apple.com; 4-15 s each). Decrypted they are raw APFS (OS 7.0 GB, SystemOS 4.3 GB,
apparent file size of the OS volume 11.4 GiB because decmpfs files are written uncompressed). The AEA files are deleted after
decryption and each dmg after it was copied (27 GB Mac).

### Layout decisions
* **Merged root, no cryptex mounting.** SystemOS and AppOS are ditto-ed into `/` first, the OS volume on top. The 42 symlinks
  of the OS volume that point into `/System/Cryptexes/{OS,App}/...` (WebKit.framework, Safari bundles, ...) meet the real
  directories of the merge and are dropped (ditto: "Is a directory"; the script counts them); `/etc /var /tmp` stay symlinks
  (ditto would follow them as a source argument: `copy_tree` recreates symlinks itself).
* `/System/Cryptexes/{OS,App}` -> `../../private/preboot/Cryptexes/{OS,App}` (as shipped) and those two are symlinks to `../../..`
  (= `/`): `/System/Cryptexes/OS/System/Library/...` resolves into the merged root.
* **dyld cache stays at `/System/Library/Caches/com.apple.dyld/`** (its place in the SystemOS cryptex). dyld 18 contains
  libignition (strings: `System/Library/Caches/com.apple.dyld/`, `no shared cache in cryptex`, `cryptex prefix`,
  `/System/Cryptexes/OS`, `ignition_level` stages). With `ignition_level=1` (boot-arg, already in the cmdline) it looks in the root
  at that path only (same as iOS 16, see NOTES), so no hard links or second copy are needed. 67 files: `dyld_shared_cache_arm64e`
  + `.01 .. .66` (`.35.dylddata`, `.36.dyldreadonly`, `.37.dyldlinkedit`, ...) + `.atlas`; `.symbols` (870 MB, symbolication only)
  is not copied.
* Not copied (disk): `usr/standalone/update` (OTA ramdisk firmware, 206 MB), `System/Library/NanoTimeKit` (Apple Watch faces,
  284 MB). Everything else is there: `/Library/Wallpaper/{Collections,DefaultWallpapers~iphone.plist}`, `PosterBoard*.framework`,
  `PreinstalledAssetsV2`, `staged_system_apps` (Home.app, Music.app, ... see risks).

### Build
```sh
cd /Users/zesmoi/git/iAndroid/ios-beryllium-ios18
tools/renegade/mkroot-full.sh [--delete-sources]     # copy,macho,cache,tweaks,seal,verify,simg (needs the decrypted dmgs in research/ios18/ipsw/22H352__iPhone11,8/)
```
Stages of `mkroot-full.py` (`--stages a,b,c`, re-runnable on the same image): `copy` (owner map by lstat of an owners-on mount of each
source, copy from a noowners mount because root-only files such as `/etc/master.passwd` are unreadable otherwise; newfs_hfs -s,
unjournaled), `macho` (pacstrip + `codesign -f -s -` with the entitlements re-applied of EVERY Mach-O, in parallel,
hard links by inode), `cache` (`pacstrip_cache.py`), `tweaks` (below), `seal` (`hfs_trim.py`, `hfsroot_owners.py`, `fsck_hfs`), `verify`,
`simg` (`img2simg.py --consume`). Helper tools: `hfsroot_owners.py` (catalog editor: real owner/group/permission bits from the map
for every record, hard links through their `iNode<N>` file, everything else root:wheel; follows the extents-overflow file),
`hfs_trim.py` (F_PUNCHHOLE over HFS-free blocks: the image is a sparse file and HFS frees blocks that the host keeps; 4.9 GiB were
given back after the copy+rewrite), `img2simg.py` (`--consume` punches 16 MiB holes behind the reader so RAW+SIMG never exist
together; needed because raw 15 GiB + simg 15 GiB does not fit the disk).

### PAC rewrite
* Standalone Mach-Os: unchanged `pacstrip.py` (the NEW PACGA rule from commit 7d52748, `EOR ... ROR #13`, is used; nothing was
  stripped before that rule existed). ~3060 Mach-O files outside the cache, 2927 rewritten and re-signed.
* **dyld shared cache: `tools/renegade/pacstrip_cache.py CACHE_DIR`** rewrites every file in place. Parses the main header
  (image table, sub-cache array with suffixes), the mapping table of each of the 67 files (addresses are global), finds the
  Mach-O header of each of the 3861 images + dyld-in-cache through the mappings and rewrites only the executable SECTIONS
  (10,320 sections, 2378 MiB of code) with `pacstrip.rewrite_word`. 4 KiB pages that changed are collected per file and the **CodeDirectory
  page hashes (SHA-256, 16 KiB pages, version 0x20400) are recomputed in place** (no size change; `--verify-sig` checks every page hash of
  every file: on the pristine cache 258,805/258,805 correct, after the rewrite 0 wrong). Runtime: 38 s for the scan, ~45 s for the
  rewrite with 8-10 processes (the per-word Python loop is fast enough; no C needed).
  Result on the real cache: AUTDA 3.4 M, BLRAA 4.7 M, BRAA 3.2 M, RETAB 4.5 M, PACIA 2.2 M, PACDA 2.1 M, PACIAZ 678 k, XPACD 831 k, PACDB 272 k,
  PACGA 502 ... ; **re-scan finds no rewritable PAC word left**. Left alone: **FJCVTZS 474** (JavaScriptCore/WebCore) and
  one unencodable LDRAB; LDRAA/LDRAB-looking words only inside images of a whitelist (libc++abi, libobjc, libdispatch, libsystem_*, dyld, ...:
  22 rewritten); `TextToSpeechMauiSupport` has 1595 LDRAA-looking words that are data (not touched, as the study predicted).
  r-x mapping bytes outside image sections (stubs islands do not exist here) were scanned too: only random data matches.
* Not done: slide info v5 and the kernel side of the cache (below).

### First-boot tweaks (`root_tweaks18.py` = `sweet-root-tweaks.py`, owners recorded instead of chown)
`launchd.plist` (`/System/Library/xpc/launchd.plist`, still the job cache in 18.7.8, 628 jobs): 9 `_PanicOnCrash` renamed, 2 CommCenter jobs removed;
`/private/var/containers/{Bundle(33),Data/System,Shared/SystemGroup,Temp}`; configd USB Ethernet service ue0 (192.168.7.2/24); sweetnetcfg job,
sweetreboot, **dropbear + dash (/bin/sh) + toybox with your public key (key-only ssh on 192.168.7.2:22, job `org.sweet.dropbear`)** from the
main checkout's `research/ssh-build/out` and `research/sweetnet` (iOS 16 arm64 builds, untested under iOS 18 dyld); VirtualAudio plugin
disabled, `StartRecorderServer=false`; preferences: Setup skipped (purplebuddy), `LastSystemVersion=22H352`, SpringBoard `BKNoWatchdogs`;
logd directories (owner 272) and the system keybag as in `mkiosroot-macos.sh`; bring-up job `org.sweet.ios18.hello` (console: "launchd runs
jobs, 6*7=42", `toybox uname -a`, master.passwd). Bluetooth stub (iOS 16 bluetoothd specific), mobileactivationd data ark (no container yet) and
the LaunchServices cache removal are not applied. The stock RAM-disk removals of `mkroot.py` do not apply (a full OS has no restored_external);
no extra "USB" daemon removal was done beyond CommCenter.

### Boot image
`tools/renegade/mkboot-full.sh [KERNEL] [ADT] [OUT]` (defaults `xnu/out-0139/kernel.development.sweet`, `../ios-beryllium/shim/out/beryllium-hi-3x.adt`)
-> `research/ios18/shim-boot-ios18full.img` (17.3 MB, payload checked against the unpacked ramdisk). Cmdline = the RAM-disk cmdline of section 9 with
`rd=md0` replaced by `rd=ufsroot0` and `ufsrw=1 rootrw=1` added:
```
debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetfb_hw=1 sweetarm64e=1 launchd_disable_all_timeouts=1
```
Flash/boot (NOT done): `fastboot -S 512M flash userdata research/ios18/ios18-root-full.simg`, re-enter fastboot by hand after the flash (ABL hangs,
NOTES), then `fastboot boot research/ios18/shim-boot-ios18full.img`. iOS 16 comes back with `fastboot -S 512M flash userdata research/ipsw-x/ios16-root-20H392-b3.simg`
(main checkout, untouched) and its old boot image.

### Risks (what the phone will show first)
1. **Kernel: dyld shared cache with slide info v5 and `map_with_linking_np`.** The RAM-disk boot has no cache. xnu-8796 knows slide info v1-v4 only;
   the branch has no v5 patch (docs section 7 step 2b: `vm_shared_region_slide_page_v5`, `shared_region_map_and_slide_2_np`). Expect the first process
   (launchd's dyld) to fail mapping the cache (kernel log `shared_region`/`slide`): this is the next kernel patch, the image is ready for it. Also
   the shared region's trust/SIP checks that iOS 16 needed patches for (NOTES 0031r) apply to the arm64e cache files too.
2. FJCVTZS (474 sites in the cache, JavaScriptCore) are left: SIGILL if executed; JSC checks `FEAT_JSCVT`.
3. The cache signature is ad hoc-recomputed (page hashes only); prebuilt loader sets inside the cache (programs) hold the old cdhashes of the OS
   executables, dyld may reject them and build loaders itself (slower, not fatal).
4. Entitlements of `/private/var/staged_system_apps/Home.app/Home` and `Music.app/Music` were lost: the first codesign in the parallel pass failed, the manual
   re-sign did not re-apply them (the OS dmg was already deleted). They are installed to the data volume at first boot only; SpringBoard does not need them.
   One bundle (`SpringBoardDiagnosticExtension.appex`) reports an invalid bundle resource seal with `codesign -v` (the kernel stand-in does not check resources).
5. dropbear/toybox/dash are iOS 16 arm64 (non-e) builds: whether iOS 18 dyld accepts non-e executables against the arm64e cache is untested; ssh may not come up.
6. Unjournaled HFS+ (like the RAM-disk root): power loss mid-boot needs fsck (the kernel mounts dirty unjournaled root rw, see NOTES).
7. Case-sensitive volume (as iOS 16 here); owners/modes come from the IPSW (appos/sysos owner map was lost with their dmgs: root:wheel, modes kept).

### Result of the first build (2026-10-20)
* `research/ios18/ios18-root-full.simg` 15,978,818,944 bytes (15.2 GiB; 5,242,880 blocks = a 20 GiB HFSX volume `iOSRoot`, 35,718 chunks, structure
  checked, volume header `HX`), SHA256 `290ef23f...4713` (`research/ios18/SHA256SUMS-full`). `fsck_hfs -fn`: OK. 422,679 catalog records, 414,346 with the IPSW's
  owner/mode, 19,985 hard-link records, 0 HFS-compressed files, 15 GiB used / 4.8 GiB free inside.
* `research/ios18/shim-boot-ios18full.img` 17,256,448 bytes (kernel xnu/out-0139, beryllium-hi-3x.adt), SHA256 `ac40023f...1228`.
* Offline checks (all passed): launchd, dyld, SpringBoard, xpcproxy, launchd.plist, 5 wallpaper collections, PosterBoard, SystemVersion present; all 3068 Mach-Os outside the
  cache re-scanned: 0 PAC words left; codesign -v on 150 random ones OK; cache: 258 k page hashes valid, re-scan 0 rewritable words; owner spot check of 3000 paths OK.
* Time: download ~27 min (8.3 GB), decrypt 20 s, copy ~6 min, macho 5 min (3 000 files, 8 cores), cache 45 s, seal+verify 4 min, simg 2 min.
* The raw image no longer exists (consumed into the .simg); to modify the root afterwards rebuild (tools/renegade/fetch-root.sh again, ~35 min) or write a simg->raw
  converter. Mounting the result on the Mac needs that conversion; the checks above were done on the raw image before it was consumed.


### Rebuild 2 (2026-10-20): signing identifier kept (boot panic "code signing identity mismatch ... observed=mount-5555... expected=com.apple.mount")
* **Cause:** `pacstrip.sign()` ran `codesign -f -s -` without `-i`, so every re-signed binary got `name-<cdhash prefix>`. launchd 18's boot tasks compare the csops identity with `com.apple.<leaf of Program>` (or the task's `CSIdentityOverride`, e.g. `com.apple.seputil` for init_data_protection, `com.apple.xpc.roleaccountd`).
* **Fix (`tools/renegade/pacstrip.py`, used by the RAM-disk root too):** `cs_identity()` parses the CodeDirectory of the first arm64 slice (identifier, team id, flags) BEFORE signing; `sign()` passes `-i <identifier>`, `-o host,hard,kill,expires,restrict,library,runtime` for those bits of the old flags, re-applies the entitlements (as before), retries codesign up to 3 times (the Home/Music failure of build 1 was a transient one, now retried and any remaining failure aborts the build), and afterwards re-parses the new signature and raises on a different identifier/team id or lost CS flag. `mkroot-full.py` records every old identity in `research/ios18/full/identities.tsv`, aborts on any failed Mach-O, and the `verify` stage re-checks all of them.
* **Result:** 2929 Mach-Os re-signed, 0 failures; verify: identifier, team id (empty, ad hoc) and CS options unchanged on all 2928 present (the 2929th, VirtualAudio, is moved to `Library/Audio/Plug-Ins/HAL.disabled` by a tweak). Original flags in these binaries are just `0x2 (adhoc)`, so the options list is normally empty.
* **Boot-task audit (embedded plist in `/sbin/launchd`, 37 entries, `Boot` dict; extracted by `boot_task_audit()`):** every boot task with a program path that exists in the root has identifier == `com.apple.<leaf>` or its CSIdentityOverride (mount-phase-1/2 /sbin/mount, fsck, fsck-safe, keybagd, dirs_cleaner, cc_fips_test, tzinit, init_data_protection (override), nvram, sysstatuscheck, mobile_obliterator, finish_demo_restore, xpcroleaccountd (override), init_featureflags, prng_seedctl, launchd_cache_loader, MSUEarlyBootTask, auearlyboot, FinishRestoreFromBackup). Absent from the iPhone OS volume (as on a stock iPhone): `HorizonSetup` (restore only), `darwinos-boot-task`, `realitycoprocessorloaderd`, `cvcalibration_postfactoryfix`, `wakeboardctl` (pre-reboot only). Block-type tasks with no Program (select-boot-mode, commit-boot-mode, init-with-data-volume, exclaves-boot, ...) run inside launchd.
* **Platform binary (kernel):** `xnu/patches/0035/0036` (`sweet_amfi_vnode_check_signature`) set CS_SIGNED and CS_PLATFORM_BINARY for every signed vnode on MNT_ROOTFS (= our ufsroot0), regardless of signer; csops CS_OPS_STATUS therefore passes launchd's "is not a platform binary" check (it did for iOS 16, and in this boot the mount task got past that check, the failure was the identity one). `CS_PLATFORM_PATH` is not set and nothing in launchd's boot-task code uses it (strings: only "platform binary", "unexpected exec of non-platform binary", csops). Likely next checks, no change proposed without evidence: AMFI selector 0x66 (launch-constraint match; ENOPOLICY = "not satisfied") and 0x5f (cdhash in trust cache: "not trusted") for xpcproxy/launchd-spawned services; if launchd 18 starts rejecting services for constraints, answer 0x66 with "satisfied" for platform binaries (a 10-line change in `sweet_amfi.c`).
* **Other things that may trip launchd next:** (a) `SystemRoots` in launchd's plist lists `/System/Library` AND `/System/Cryptexes/{OS,App}/System/Library` AND `/private/preboot/Cryptexes/...`; in our merged root the last four are symlinks to `/`, so if launchd scans directories (and not only the `launchd.plist` cache with `launchd_unsecure_cache=1`) every daemon plist is seen 2-3 times (duplicate-label errors); if so, make the two Cryptexes symlinks real empty directories instead. (b) `launchd_cache_loader` (RequireRun, RequireSuccess) needs the AMFI/cache path that worked on iOS 16. (c) `fsck -qL` on the unjournaled HFS root (RequireRun), `init_data_protection`, `tzinit`, `keybagd --init` (systembag.kb present), `cc_fips_test` (FIPS self test, needs the corecrypto path to run without PAC), `mobile_obliterator --init`. (d) the 5 rewritten-LDRAx/FJCVTZS notes of the first build still apply.
* **Outputs:** `research/ios18/ios18-root-full.simg` 15,989,491,072 bytes (5,242,880 blocks, structure checked), SHA256 `27a2acec...cb47` (`research/ios18/SHA256SUMS-full`); the boot image `shim-boot-ios18full.img` is unchanged. Same excludes as before (usr/standalone/update, NanoTimeKit; PreinstalledAssetsV2 is included again). fsck_hfs clean, all verify checks passed; build took about 1 h (download 20 min, copy 12 min, macho 6 min, seal/verify 8 min, simg 2 min); the old simg was deleted first.

### mount-phase-2 (analysis; root NOT changed)
`mount -P 2` (22H352 `/sbin/mount`) processes fstab entries of pass 2 and then always `execv("/System/Library/Filesystems/apfs.fs/apfs_boot_util", "2")` (mount+0x3a08..0x3a10: `cmp w22,#2; b.ne exit; bl`). `apfs_boot_util 2` mounts Log/iDiags/Data volumes by role, deletes Data snapshots and grafts ExclaveOS; on the phone it aborts at "ExclaveOS graft" because of missing kernel sysctls (`hw.osenvironment`, exclaves status), not because of the root. A root-side workaround exists (`mkroot-full.py --patch-mount-phase2`: one word, `b.ne` -> `b` at mount+0x3a0c, re-signed as com.apple.mount) but is OFF by default and not in the current image. Other boot tasks with APFS/data-volume strings (no change needed yet, all non-fatal or AllowCrash): keybagd (AllowCrash), usermanagerd --init (AllowCrash, "missing disknode for the booted user"), MSUEarlyBootTask (AllowCrash), finish_demo_restore (RequireSuccess; looks up the APFS demo volume, expected to skip without a demo staging folder: unverified), fsck (skips the OS container as on iOS 16).

### cc_fips_test: corecrypto FIPS POST integrity HMAC (fix in `tools/renegade/fips_rehmac.py`)
Boot symptom: `cc_fips_test` (RequireSuccess) runs the POST KATs (all PASSED) but `FIPS_POST failed!` -> panic. Cause: `fipspost_post_integrity`
(libcorecrypto, 22H352) calls `fipspost_get_hmac(mh, out, 0)` = HMAC-SHA256(key = one 0x00 byte, first `__TEXT,__text` section of the image, read
at `mh + section.offset`) and `cc_cmp_safe`s it with the 32 bytes of `__TEXT,__fips_hmacs` (on mismatch it logs `MAC generated:` / `In variable:` and
returns -0x4a). pacstrip_cache rewrites `__text`, so the stored value was stale. Verified: on the pristine macOS 27 cache libcorecrypto the
same computation MATCHES the stored value; on our cache all 3 variants (libcorecrypto, _trace, _noasm) mismatched. `fips_rehmac.py CACHE_DIR [--patch]`
recomputes and stores the HMAC and refreshes the CodeDirectory page hashes of the sub-cache file; mkroot-full.py runs it right after pacstrip_cache.
No other Mach-O in the root has a `__fips_hmacs` section. Applied to the existing image (simg -> raw -> patch -> fsck -> simg), 0 wrong page hashes.
Not verifiable offline: whether further POST steps fail (photo lacks `fipspost_post_ffdh` in the PASSED list; scrolled-off lines unknown).
Fallback (not needed): `fips_mode` boot-arg only selects/forces-fail POST variants (bit 0x10 flips the computed MAC), there is no skip switch.

## Boot logo: why iOS 18 shows no Apple logo phase (2026-10-23)

backboardd draws the boot Apple logo itself (`BKBootUIPresenter` -> `BKBootUIOverlayVendor` -> `BKDisplayRenderOverlayAppleLogo`, ProgressUI `apple-logo-n84@2x~iphone.png`, unified log category `BootUI`) on iOS 16 and 18 alike, and our display path does present it. It stays up only until SpringBoard dismisses it (`Dismissing boot logo (pid)` / `First boot is finished`, 0.2-2 s after backboardd starts on 18; on 16 SpringBoard sat minutes in LaunchServices, which is why the logo seemed to last). On a real phone iBoot draws the long logo; here that phase (kernel + launchd, minutes before backboardd) showed the Enxerto Bergamota screen. `tools/mkapplelogo.py` (run by `mkboot-full.sh`, git-ignored `enxerto/applelogo.h`, `APPLE_LOGO=0` to skip) turns that screen into the Apple logo at "STARTING IOS", read from the iOS root at image build time.
