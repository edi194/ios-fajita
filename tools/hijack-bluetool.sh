#!/bin/bash
# Hijack a stock LaunchDaemon so launchd runs our tool.
#
# Stock launchd on this port ignores /Library/LaunchDaemons and /System/Library/LaunchDaemons/org.sweet.*
# (three boots, no 'sweetgpu opened' line), but it certainly starts its own jobs. This points
# com.apple.BlueTool - the Bluetooth helper, useless here since there is no BT driver - at the
# GPU test tool, keeping the stock label so any bookkeeping still matches. The original plist is
# kept in the image as com.apple.BlueTool.plist.orig.
#
#   sudo tools/hijack-bluetool.sh IMAGE
set -euo pipefail

img=${1:?usage: hijack-bluetool.sh IMAGE}
[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m"

d=$work/m/System/Library/LaunchDaemons
[[ -f $d/com.apple.BlueTool.plist ]] || { echo "no com.apple.BlueTool.plist" >&2; exit 1; }
[[ -f $d/com.apple.BlueTool.plist.orig ]] || cp -p "$d/com.apple.BlueTool.plist" "$d/com.apple.BlueTool.plist.orig"

cat > "$work/hijack.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.apple.BlueTool</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/sweetgputest</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/dev/console</string>
	<key>StandardErrorPath</key>
	<string>/dev/console</string>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST

install -m 0644 -o 0 -g 0 "$work/hijack.plist" "$d/com.apple.BlueTool.plist"
ls -l "$d/com.apple.BlueTool.plist"
sync
umount "$work/m"
echo "image updated: $img (com.apple.BlueTool -> /usr/local/bin/sweetgputest)"
