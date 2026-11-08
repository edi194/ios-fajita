#!/bin/sh
# Build dropbear + dash + toybox for iOS 16 (arm64) plus macOS test builds,
# sign them ad hoc with tools/ssh/entitlements.plist. See docs/SSH_OVER_USB.md.
# Needs: Xcode (iPhoneOS SDK), gsed (brew install gnu-sed; toybox's build
# scripts do not work with macOS's BSD sed), gpg only for verifying downloads.
# Sources are expected unpacked in research/ssh-build/src/<name>/<name>-<ver>
# (the doc lists the downloads and checksums). Output: research/ssh-build/out/.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(cd "$HERE/../.." && pwd)/research/ssh-build
DB=$W/src/dropbear/dropbear-2026.94
DASH=$W/src/dash/dash-0.5.13.5
TB=$W/src/toybox/toybox-0.8.15
SDK=$(xcrun -sdk iphoneos --show-sdk-path)
ICLANG=$(xcrun -sdk iphoneos --find clang)
IFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$W/build" "$W/out"
rm -rf "$W"/build/*-ios "$W"/build/*-mac "$W"/build/toybox-*

# --- patches (applied to the pristine sources; reversed first if present) ---
if ! grep -q dash_strchrnul "$DASH/src/system.h"; then patch -p1 -d "$DASH" < "$HERE/dash-ios-strchrnul.patch"; fi

# --- dropbear: one multi-call binary (dropbear dropbearkey scp) ---
for t in ios mac; do
  d=$W/build/dropbear-$t; mkdir -p "$d"; cp "$HERE/localoptions.h" "$d/"
  if [ $t = ios ]; then CCV="$ICLANG $IFLAGS"; HOST="--host=aarch64-apple-darwin"; else CCV=clang; HOST=; fi
  (cd "$d" && CC="$CCV" "$DB/configure" $HOST --disable-zlib --disable-lastlog --disable-utmp \
     --disable-utmpx --disable-wtmp --disable-wtmpx --disable-pututline --disable-pututxline \
     --enable-bundled-libtom --disable-pam CFLAGS=-O2 >/dev/null &&
   make PROGRAMS="dropbear dropbearkey scp" MULTI=1 -j"$JOBS" >/dev/null)
done

# --- dash ---
for t in ios mac; do
  d=$W/build/dash-$t; mkdir -p "$d"
  if [ $t = ios ]; then
    (cd "$d" && CC="$ICLANG $IFLAGS" CC_FOR_BUILD=clang ac_cv_func_strchrnul=no "$DASH/configure" \
       --host=aarch64-apple-darwin --without-libedit CFLAGS=-O2 >/dev/null && make -j"$JOBS" >/dev/null)
  else
    (cd "$d" && CC=clang "$DASH/configure" --without-libedit CFLAGS=-O2 >/dev/null && make -j"$JOBS" >/dev/null)
  fi
done

# --- toybox (in-tree build, so one pristine copy per target) ---
for t in ios mac; do
  d=$W/build/toybox-$t; cp -R "$TB" "$d"; cp "$HERE/toybox.config" "$d/.config"
  if [ $t = ios ]; then
    patch -p1 -d "$d" < "$HERE/toybox-ios-sys-disk.patch"
    (cd "$d" && CC="$HERE/ios-cc.sh" HOSTCC=clang SED=gsed make -j"$JOBS" >/dev/null)
  else
    (cd "$d" && CC=clang SED=gsed make -j"$JOBS" >/dev/null)
  fi
done

# --- collect + sign ---
cp "$W/build/dropbear-ios/dropbearmulti" "$W/out/dropbear"
cp "$W/build/dash-ios/src/dash" "$W/out/dash"
cp "$W/build/toybox-ios/toybox" "$W/out/toybox"
cp "$W/build/dropbear-mac/dropbearmulti" "$W/out/dropbear-mac"
cp "$W/build/dash-mac/src/dash" "$W/out/dash-mac"
cp "$W/build/toybox-mac/toybox" "$W/out/toybox-mac"
chmod u+w "$W"/out/*
for f in dropbear dash toybox; do
  codesign --force -s - --entitlements "$HERE/entitlements.plist" "$W/out/$f"
done
ls -l "$W/out"
