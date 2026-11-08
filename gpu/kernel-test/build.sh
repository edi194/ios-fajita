#!/bin/bash
# Build adreno_uc_test as arm64e, then strip PAC + ad-hoc sign it with renegade (runs on the PAC-less Kryo 385).
#   gpu/kernel-test/build.sh [OUTDIR]       default: gpu/kernel-test/out
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot "$SDK" -O1 -g -Wall -Wextra -Wno-unused-parameter \
    "$HERE/adreno_uc_test.c" -o "$OUT/adreno_uc_test.arm64e" -framework IOKit -framework CoreFoundation -framework IOSurface
"$HERE/../../tools/renegade/renegade" strip --sign -o "$OUT/adreno_uc_test" "$OUT/adreno_uc_test.arm64e"
chmod +x "$OUT/adreno_uc_test"
ls -l "$OUT/adreno_uc_test"
