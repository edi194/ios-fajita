# Building Chlorophyll's userspace for this port (Linux, no Mac)

`tools/build-bgair-ios.sh` produces `libbgair.dylib` - the AIR -> NIR -> ir3 device half - from
Linux with our clang + the iPhoneOS 16.5 SDK. It was learned by iterating on the real build; every
item below is a failure that had to be fixed, not a preference.

## Prerequisites

```
pip install --user --break-system-packages meson ninja mako pyyaml    # PEP 668 blocks plain pip
clang / ld64.lld  (Ubuntu clang 22 works)
~/ios-sdk/iPhoneOS16.5.sdk
network (Mesa 25.0.7 and libdrm 2.4.124 are cloned)
```

## What upstream assumes, and what this port needs instead

Chlorophyll's `build-ios.sh` is macOS-oriented (`xcrun`, `brew --prefix bison`, arm64e + `renegade`
signing) and its Mesa submodule is not in our checkout. We cross-build from Linux, so:

- **Mesa 25.0.7 + Bergamota's `bergamota-mesa-25.0.7.patch` + Chlorophyll's 7 patches** (`air-frontend`,
  `air-ir3`, `ir3-*`, `fd-bo-*`) are applied to a fresh Mesa.
- **`src/compiler/air/`** is symlinked from `Chlorophyll/air/` (their `air.patch` adds `subdir('air')`).
- **`libdrm` headers are cloned separately** - `Chlorophyll/libdrm` is an empty submodule here.
  The `.pc` points at the real 2.4.124 headers and at our `libdrm.2.dylib` stand-in.
- **`zlib.pc`** points at the iOS SDK stub (`-lz` + `-isysroot`); without it Mesa links the Linux
  `libz.so` into an arm64 Mach-O (`unhandled file type`, then `undefined symbol: gzopen`).

## The three Meson edits (Mesa has no "msm without KMS on Darwin")

1. `meson.build`: `dep_libdrm` is `null_dep` unless `system_has_kms_drm`, so add
   `or freedreno_kmds.length() > 0` - otherwise the libdrm include dirs never reach freedreno and
   `xf86drm.h` is not found (and `-DHAVE_LIBDRM` is missing).
2. `src/freedreno/meson.build`: `subdir('drm')` only runs with KMS - same extension, otherwise
   `libfreedreno_drm` is undefined.
3. `src/freedreno/drm/meson.build`: `link_with : [libvdrm]` is unconditional upstream, but `libvdrm`
   only exists with the virtio kmd - make it conditional.

Deliberately **not** done: making `system_has_kms_drm` true globally. That drags in `virtio/vdrm`
(needs `xf86drm.h` paths we do not want) and other KMS-only targets.

## The cross file (the part that bit hardest)

- `cpp_args` must repeat `--target=arm64-apple-ios16.0` and `-isysroot`. With only `c_args`, every
  C++ object is compiled for the build machine; the symptom is a C-only header (or `u_endian.h`)
  failing in a `.cpp` file.
- `-DHAVE_STRUCT_TIMESPEC`, `-DHAVE_DLADDR`, `-DHAVE_DLFCN_H`, `-DHAVE_FUNC_ATTRIBUTE_PACKED`:
  meson's checks link test programs, which fails in a cross build, and the consequences are subtle -
  `ENUM_PACKED` becomes empty (so `enum mesa_prim` is 4 bytes and `u_prim.c`'s static assert fires)
  and `struct timespec` is redefined.
- `-Wno-c++11-narrowing`: clang 22 rejects narrowing that Apple clang 16 (what Mesa 25.0.7 was
  built with) accepts.
- `objc`/`objcpp` must be listed: Mesa's top-level meson asks for an ObjC compiler.

## Result

```
ls -l build-ios/src/gallium/drivers/freedreno/libbgair.dylib     # ~9.9 MB, Mach-O arm64
llvm-objdump --macho --dylibs-used …  # libSystem.B, libz.1, @rpath/libdrm.2.dylib
```

`Chlorophyll/src/bgmtl.m` (the `_MTLDevice` subclass) also compiles against the 16.5 SDK:

```
clang --target=arm64-apple-ios16.0 -isysroot $SDK -O1 -fno-objc-arc -I Chlorophyll/air \
    -c Chlorophyll/src/bgmtl.m -o bgmtl.o
```
