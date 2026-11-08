#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the OpenGLES shim (arm64e) and the standalone tests against a cross-built Mesa.
#   build.sh [OUT]      OUT defaults to $GPU_EAGL_WORK/out; needs $GPU_EAGL_WORK/build-a64e or build-hw (see mesa/build-mesa.sh)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${GPU_EAGL_WORK:?set GPU_EAGL_WORK to the scratch dir that holds mesa/ and build-a64e/}"
ARCH="${ARCH:-arm64e}"
MESA_SRC="$WORK/mesa"
MESA_BLD="${MESA_BLD:-$WORK/build-${ARCH/arm64e/a64e}}"      # MESA_BLD=$WORK/build-hw: freedreno + softpipe build (mesa/build-mesa.sh with GPU_EAGL_HW=1)
OUT="${1:-$WORK/out-$ARCH}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="xcrun --sdk iphoneos clang -arch $ARCH -miphoneos-version-min=18.0 -isysroot $SDK"
OSMESA="$MESA_BLD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
# Install name of the shim: @rpath for side-by-side tests; set SHIM_INSTALL_NAME=/System/Library/Frameworks/OpenGLES.framework/OpenGLES
# only for an image that really replaces the system library.
SHIM_INSTALL_NAME="${SHIM_INSTALL_NAME:-@rpath/OpenGLES.framework/OpenGLES}"
mkdir -p "$OUT/OpenGLES.framework" "$OUT/obj"
python3 "$HERE/tools/gen_gl_stubs.py" > "$HERE/src/gl_stubs.c"
CF="-O2 -g -fvisibility=hidden -Wall -Wno-deprecated-declarations -I$HERE/src -I$MESA_SRC/include"
for f in gl_stubs gl_resolve gl_unimpl osm macro_ctx macro_slots; do $CC $CF -c "$HERE/src/$f.c" -o "$OUT/obj/$f.o"; done
$CC $CF -fno-objc-arc -fobjc-exceptions ${EAGL_DEFS:-} -c "$HERE/src/eagl.m" -o "$OUT/obj/eagl.o"
EXTRA_OBJ=""
if [[ "${EAGL_DEFS:-}" == *EAGL_INJECT* ]]; then      # injection build: the render server hook
  $CC $CF -fno-objc-arc -c "$HERE/src/ca_server_hook.m" -o "$OUT/obj/ca_server_hook.o"; EXTRA_OBJ="$OUT/obj/ca_server_hook.o"
fi
cp -f "$OSMESA" "$OUT/libOSMesa.8.dylib"
xcrun strip -x "$OUT/libOSMesa.8.dylib"          # keeps the exported OSMesa/glapi symbols
if [ -f "$WORK/drm-standin/libdrm.2.dylib" ]; then      # hardware build: the libdrm stand-in sits next to libOSMesa
  cp -f "$WORK/drm-standin/libdrm.2.dylib" "$OUT/libdrm.2.dylib"
  for rp in $(otool -l "$OUT/libOSMesa.8.dylib" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}'); do install_name_tool -delete_rpath "$rp" "$OUT/libOSMesa.8.dylib" 2>/dev/null || true; done
  install_name_tool -add_rpath @loader_path "$OUT/libOSMesa.8.dylib" 2>/dev/null || true
fi
$CC -dynamiclib -o "$OUT/OpenGLES.framework/OpenGLES" "$OUT"/obj/{gl_stubs,gl_resolve,gl_unimpl,osm,macro_ctx,macro_slots,eagl}.o $EXTRA_OBJ \
    -install_name "$SHIM_INSTALL_NAME" -Wl,-not_for_dyld_shared_cache -compatibility_version 1.0.0 -current_version 1.0.0 \
    -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface \
    "$OUT/libOSMesa.8.dylib" -Wl,-rpath,@loader_path/.. -Wl,-undefined,error
# Tests link the shim by path (never the system framework).
for t in eagl_test; do
  [ -f "$HERE/test/$t.m" ] || continue
  [ -z "${EAGL_DEFS:-}" ] || continue          # injection builds rename the classes: the by-path test does not apply
  $CC -O1 -g -Wno-deprecated-declarations -fno-objc-arc -I$HERE/src "$HERE/test/$t.m" -o "$OUT/$t" \
      "$OUT/OpenGLES.framework/OpenGLES" -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface \
      -Wl,-rpath,@executable_path -Wl,-rpath,@executable_path/..
done
# CoreAnimation test: links the SDK's OpenGLES + QuartzCore; at run time DYLD_FRAMEWORK_PATH must point at a shim built with
# SHIM_INSTALL_NAME=/System/Library/Frameworks/OpenGLES.framework/OpenGLES (see docs/GPU_EAGL.md).
$CC -O1 -g -Wno-deprecated-declarations -fno-objc-arc -I$HERE/src "$HERE/test/eagl_ca_test.m" -o "$OUT/eagl_ca_test" \
    -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface -framework QuartzCore -framework OpenGLES
ls -l "$OUT" "$OUT/OpenGLES.framework"
