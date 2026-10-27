#!/bin/bash
# Build the C1 Metal probe bundle: SweetMetalProbe.bundle (Info.plist + a Mach-O executable whose
# principal class subclasses _MTLDevice at runtime and logs/declines in -initWithAcceleratorPort:).
#
#   tools/mk-metal-probe.sh [OUTDIR]        default: ~/ios-userland/SweetMetalProbe.bundle
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=${IOS_SDK:-/home/edi194/ios-sdk/iPhoneOS16.5.sdk}
OUT=${1:-/home/edi194/ios-userland/SweetMetalProbe.bundle}

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$HERE/metal-probe/Info.plist" "$OUT/Info.plist"

clang --target=arm64-apple-ios16.0 -isysroot "$SDK" -O2 -fno-objc-arc \
    -dynamiclib -install_name /System/Library/Extensions/SweetMetalProbe.bundle/SweetMetalProbe \
    -fuse-ld=lld -L "$SDK/usr/lib" -lSystem -framework Foundation \
    "$HERE/metal-probe/sweet_metal_probe.m" -o "$OUT/SweetMetalProbe"

chmod 0755 "$OUT/SweetMetalProbe"
file "$OUT/SweetMetalProbe"
ls -la "$OUT"
