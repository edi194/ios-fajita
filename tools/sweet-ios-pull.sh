#!/bin/sh
# Pull files from the iOS root on userdata while the phone runs OrangeFox
# (fastboot boot recovery/ofox/recovery.img; adb root shell). Read-only:
# a static aarch64 hfsdump (research/hfsfuse, built with
#   make OS=Linux CC="zig cc -target aarch64-linux-musl" AR="zig ar" \
#     WITH_UBLIO=none WITH_LZVN=none WITH_LZFSE=none LDFLAGS=-static hfsdump)
# reads the HFS+ volume; nothing is mounted.
#
#   tools/sweet-ios-pull.sh OUTDIR [HFS_PATH...]
#
# Default paths: the unified log stores (/private/var/db/diagnostics and
# uuidtext). Those become OUTDIR/ios.logarchive and, if
# research/macos-UnifiedLogs is built, OUTDIR/unified.jsonl.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: sweet-ios-pull.sh OUTDIR [HFS_PATH...]}
shift
[ $# -gt 0 ] || set -- /private/var/db/diagnostics /private/var/db/uuidtext
hfsdump=${HFSDUMP:-$root/research/hfsfuse/hfsdump}
[ -x "$hfsdump" ] || { echo "no aarch64 hfsdump at $hfsdump" >&2; exit 1; }

dev=$(adb shell 'for d in /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done' | tr -d '\r')
[ -n "$dev" ] || { echo "userdata not found (phone in OrangeFox?)" >&2; exit 1; }
adb push -q "$hfsdump" /tmp/hfsdump
adb push -q "$root/tools/ios-pull-device.sh" /tmp/ios-pull.sh
adb shell "chmod 755 /tmp/hfsdump; rm -rf /tmp/iospull; mkdir -p /tmp/iospull; sh /tmp/ios-pull.sh $dev /tmp/iospull $*; du -sh /tmp/iospull"
mkdir -p "$out"
adb pull -q /tmp/iospull/. "$out/root"
adb shell rm -rf /tmp/iospull
echo "pulled into $out/root" >&2

# Unified log -> .logarchive (+ JSONL via Mandiant's macos-UnifiedLogs)
if [ -d "$out/root/private/var/db/diagnostics" ]; then
	a="$out/ios.logarchive"
	rm -rf "$a"
	mkdir -p "$a"
	cp -R "$out/root/private/var/db/diagnostics/." "$a/"
	[ -d "$out/root/private/var/db/uuidtext" ] && cp -R "$out/root/private/var/db/uuidtext/." "$a/"
	cat > "$a/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>OSArchiveVersion</key><integer>4</integer>
<key>ArchiveIdentifier</key><string>$(uuidgen)</string></dict></plist>
EOF
	it="$root/research/macos-UnifiedLogs/examples/target/release/unifiedlog_iterator"
	if [ -x "$it" ]; then
		"$it" -m log-archive -i "$a" -o "$out/unified.jsonl" >/dev/null 2>&1 || true
		echo "unified log: $(wc -l < "$out/unified.jsonl" | tr -d ' ') entries in $out/unified.jsonl" >&2
	fi
fi
