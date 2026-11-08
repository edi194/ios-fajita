#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the payload that the Renegade root tweak "bglrender" installs into /usr/local/lib/bergamota-gl/ of the iOS root:
#   bgl-launch                     launchd job target of backboardd (execs the real one, injects the shim only with bglrender=1|soft)
#   OpenGLES.framework/OpenGLES    injection build of the shim (patches the real EAGLContext/EAGLSharegroup at load)
#   libOSMesa.8.dylib              Mesa 25.0.7: freedreno (a6xx) + softpipe, GLES 1/2/3 (rpath @loader_path)
#   libdrm.2.dylib                 the libdrm stand-in over SweetAdreno630
# All arm64e, PAC-stripped and ad-hoc signed (renegade strip --sign). Output: research/bergamota-gl/ (git-ignored) + MANIFEST.
#   GPU_EAGL_WORK=<scratch with mesa/ and build-hw/> gpu/eagl/make-payload.sh [OUTDIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${GPU_EAGL_WORK:?set GPU_EAGL_WORK}"
OUT="${1:-$REPO/research/bergamota-gl}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TMP="$WORK/payload-build"
rm -rf "$TMP" "$OUT"; mkdir -p "$TMP" "$OUT/OpenGLES.framework"
EAGL_DEFS=-DEAGL_INJECT MESA_BLD="$WORK/build-hw" "$HERE/build.sh" "$TMP/inj" >/dev/null
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot "$SDK" -O2 -Wall -Wextra "$HERE/launch/bgl-launch.c" -o "$TMP/bgl-launch"
cp "$TMP/bgl-launch" "$OUT/bgl-launch"
cp "$TMP/inj/OpenGLES.framework/OpenGLES" "$OUT/OpenGLES.framework/OpenGLES"
cp "$TMP/inj/libOSMesa.8.dylib" "$TMP/inj/libdrm.2.dylib" "$OUT/"
for f in bgl-launch OpenGLES.framework/OpenGLES libOSMesa.8.dylib libdrm.2.dylib; do
  python3 -I "$REPO/tools/renegade/pacstrip.py" --sign "$OUT/$f" >/dev/null
done
(cd "$OUT" && shasum -a 256 bgl-launch OpenGLES.framework/OpenGLES libOSMesa.8.dylib libdrm.2.dylib > MANIFEST.sha256 && cat MANIFEST.sha256 && ls -l bgl-launch OpenGLES.framework/OpenGLES libOSMesa.8.dylib libdrm.2.dylib)
