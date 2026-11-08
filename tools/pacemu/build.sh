#!/bin/bash
# Build pactest as arm64e WITHOUT pacstrip (it must trap into the kernel PAC emulation, xnu patch 1019),
# ad-hoc signed with the usual entitlements.
#   tools/pacemu/build.sh [OUTDIR]       default: tools/pacemu/out
# Copy to the phone: scp -O tools/pacemu/out/pactest root@192.168.7.2:/var/root/pactest
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT"
xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=18.0 -isysroot "$SDK" -O1 -g -Wall -Wextra \
    "$HERE/pactest.c" "$HERE/pactest_asm.S" -o "$OUT/pactest"
codesign -f -s - --entitlements "$HERE/entitlements.plist" "$OUT/pactest"
# must still contain PAC code (no `renegade strip`): show the census
python3 -I "$HERE/../renegade/pacstrip.py" --scan "$OUT/pactest"
ls -l "$OUT/pactest"
