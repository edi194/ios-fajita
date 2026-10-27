#!/bin/bash
# Build the in-process Metal device test (Chlorophyll's bgmtl + our console wrapper) for iOS arm64.
#   tools/mk-bgmtl-adddev.sh [OUTDIR]     default: ~/ios-userland/bgmtl
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=${IOS_SDK:-/home/edi194/ios-sdk/iPhoneOS16.5.sdk}
CHL=${CHLOROPHYLL:-/home/edi194/ref/Chlorophyll}
OUT=${1:-/home/edi194/ios-userland/bgmtl}
BG=$HOME/mesa-25.0.7/build-ios/src/gallium/drivers/freedreno/libbgair.dylib
CC="clang --target=arm64-apple-ios16.0 -isysroot $SDK -O1 -fno-objc-arc -Wall -Wno-deprecated-declarations -fuse-ld=lld -L $SDK/usr/lib -lSystem"

mkdir -p "$OUT"
[ -f "$BG" ] || { echo "no libbgair.dylib at $BG (run tools/build-bgair-ios.sh)" >&2; exit 1; }
cp -f "$BG" "$OUT/libbgair.dylib"
cp -f /home/edi194/ios-userland/libdrm.2.dylib "$OUT/libdrm.2.dylib"

$CC -I"$CHL/air" -c "$CHL/src/bgmtl.m" -o "$OUT/bgmtl.o"
$CC -I"$CHL/air" -c "$HERE/metal-probe/bgmtl_adddev_console.m" -o "$OUT/bgmtl_adddev.o"
$CC -o "$OUT/bgmtl-adddev" "$OUT/bgmtl.o" "$OUT/bgmtl_adddev.o" \
    "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib" \
    -framework Foundation -framework Metal -framework IOSurface -Wl,-rpath,@executable_path

ls -la "$OUT/bgmtl-adddev" "$OUT/libbgair.dylib" "$OUT/libdrm.2.dylib"
file "$OUT/bgmtl-adddev"
llvm-objdump --macho --dylibs-used "$OUT/bgmtl-adddev" 2>/dev/null | head -8
