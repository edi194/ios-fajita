#!/bin/bash
# Build the real Metal plugin bundle: SweetBGMTL.bundle, whose principal class is Chlorophyll's BGMTLDevice
# (a _MTLDevice subclass that opens our kernel GPU through libbgair). This is what `MetalPluginName` should
# point at once the in-process test (bgmtl-adddev) works.
#
#   tools/mk-bgmtl-bundle.sh [OUTDIR]      default: ~/ios-userland/SweetBGMTL.bundle
#
# The bundle executable depends on /usr/local/lib/libbgair.dylib and /usr/local/lib/libdrm.2.dylib by
# absolute path: dyld's @rpath expansion is refused by AMFI on this image ("security policy does not allow
# @ path expansion"), which is why those dylibs live in /usr/local/lib.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK=${IOS_SDK:-/home/edi194/ios-sdk/iPhoneOS16.5.sdk}
CHL=${CHLOROPHYLL:-/home/edi194/ref/Chlorophyll}
OUT=${1:-/home/edi194/ios-userland/SweetBGMTL.bundle}
BG=$HOME/mesa-25.0.7/build-ios/src/gallium/drivers/freedreno/libbgair.dylib
CC="clang --target=arm64-apple-ios16.0 -isysroot $SDK -O1 -fno-objc-arc -Wall -Wno-deprecated-declarations -fuse-ld=lld -L $SDK/usr/lib -lSystem"

[ -f "$BG" ] || { echo "no libbgair.dylib at $BG (run tools/build-bgair-ios.sh)" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.sweet.SweetBGMTL</string>
	<key>CFBundleName</key>
	<string>SweetBGMTL</string>
	<key>CFBundleExecutable</key>
	<string>SweetBGMTL</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>NSPrincipalClass</key>
	<string>BGMTLDevice</string>
</dict>
</plist>
PLIST

$CC -I"$CHL/air" -dynamiclib \
    -install_name /System/Library/Extensions/SweetBGMTL.bundle/SweetBGMTL \
    "$CHL/src/bgmtl.m" \
    "$BG" /home/edi194/ios-userland/libdrm.2.dylib \
    -framework Foundation -framework Metal -framework IOSurface \
    -o "$OUT/SweetBGMTL"

chmod 0755 "$OUT/SweetBGMTL"
file "$OUT/SweetBGMTL"
echo
echo "===== dependencies (must not be @rpath) ====="
llvm-objdump --macho --dylibs-used "$OUT/SweetBGMTL" 2>/dev/null
ls -la "$OUT"
