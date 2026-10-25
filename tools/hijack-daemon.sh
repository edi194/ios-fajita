#!/bin/bash
# Point a stock RunAtLoad LaunchDaemon at one of our tools.
#
# Why: stock launchd on this port ignored both /Library/LaunchDaemons and
# /System/Library/LaunchDaemons/org.sweet.* (four boots, never a 'sweetgpu opened' line even with
# 0160 logging it), while its own RunAtLoad jobs certainly start. The first attempt hijacked
# com.apple.BlueTool, which turned out to be an on-demand Mach service without RunAtLoad - so
# launchd never ran it. This one keeps the stock keys (Label, RunAtLoad, ProcessType,
# EnablePressuredExit) and only swaps ProgramArguments.
#
#   sudo tools/hijack-daemon.sh IMAGE com.apple.DumpPanic /usr/local/bin/sweetgputest
set -euo pipefail

img=${1:?usage: hijack-daemon.sh IMAGE LABEL PROGRAM}
label=${2:?label}
prog=${3:?program}

[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m"

d=$work/m/System/Library/LaunchDaemons
plist=$d/$label.plist
[[ -f $plist ]] || { echo "no $label.plist" >&2; exit 1; }
[[ -f $plist.orig ]] || cp -p "$plist" "$plist.orig"

cat > "$work/hijack.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$prog</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>EnablePressuredExit</key>
	<false/>
	<key>StandardOutPath</key>
	<string>/dev/console</string>
	<key>StandardErrorPath</key>
	<string>/dev/console</string>
</dict>
</plist>
PLIST

install -m 0644 -o 0 -g 0 "$work/hijack.plist" "$plist"
ls -l "$plist"
sync
umount "$work/m"
echo "image updated: $img ($label -> $prog, original kept as .orig)"
