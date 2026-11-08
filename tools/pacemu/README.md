# pacemu: kernel PAC emulation (xnu patch 1019) checks and test tool

`xnu/patches-12377/1019-sweet-pac-emulation.patch` makes Heartwood emulate the non-HINT
pointer-authentication instructions for 64-bit EL0 threads when `sweetarm64e=1`: RETAA/RETAB, BRA*,
BLRA*, LDRAA/LDRAB, PAC*/AUT*/XPAC* and PACGA, with exactly the semantics of Renegade's static
rewrite (`tools/renegade/pacstrip.py`). It is a safety net behind pacstrip: code that was not
stripped (a new tool, an app, JIT code) runs instead of dying with SIGILL, at about one trap per
instruction. The decoder and executor are `osfmk/arm64/sweet_pacemu.h` inside the patch.

| File | What |
| --- | --- |
| `check.py` | host checks (needs Xcode): unit tests, every form in `forms.s` assembled with `clang -arch arm64e`, ~22k fuzzed words against `llvm-objdump`, every emulated word against its pacstrip rewrite |
| `pacemu_test.c` | the C side of `check.py`; `bench` mode = software cost per trap |
| `pactest.c`, `pactest_asm.S` | device test, arm64e and **not** stripped: PASS/FAIL per class, then `PROF` lines (ns per emulated instruction vs a getppid syscall) |
| `build.sh` | builds `out/pactest` (arm64e, ad-hoc signed with `entitlements.plist`, no `renegade strip`) |

```bash
python3 tools/pacemu/check.py
```

```bash
tools/pacemu/build.sh
```

On the phone (needs a kernel with 1019 and `sweetarm64e=1`): copy `out/pactest` to `/var/root/pactest` and run
it. The kernel log shows `SWEET: emulating <class> ... in <process>[pid] (N so far)` for the first four
traps of each class and at every power of two from 1024: that is the list of binaries worth stripping.

`pactest` also runs on an Apple-silicon Mac as a plain arm64 build (`clang -arch arm64 -march=armv8.3-a
pactest.c pactest_asm.S`); there it only checks the asm (control flow, LR, loads), because macOS keeps
PAC keys off in arm64 processes (PACGA is then skipped).
