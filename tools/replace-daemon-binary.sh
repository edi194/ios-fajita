#!/bin/bash
# Replace a stock binary that launchd certainly execs with one of our tools.
#
# launchd on this port does not source its jobs from /System/Library/LaunchDaemons (our plists
# were ignored and `exec DumpPanic` still appeared after we replaced DumpPanic's plist), so the
# plist route is a dead end. What launchd does do is exec the stock binaries: this swaps
# /usr/libexec/DumpPanic for the GPU test tool, keeping the path, mode and owner, and keeps the
# original next to it as .orig. DumpPanic only inspects panic records at boot.
#
#   sudo tools/replace-daemon-binary.sh IMAGE /usr/libexec/DumpPanic /home/.../sweetgputest
set -euo pipefail

img=${1:?usage: replace-daemon-binary.sh IMAGE PATH-INSIDE-IMAGE TOOL}
inside=${2:?path inside the image}
tool=${3:?tool binary}

[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ -f $tool ]] || { echo "no such tool: $tool" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m"

target=$work/m$inside
[[ -f $target ]] || { echo "no $inside in the image" >&2; exit 1; }
[[ -f $target.orig ]] || cp -p "$target" "$target.orig"

install -m 0755 -o 0 -g 0 "$tool" "$target"
ls -l "$target"
echo "note: a Mach-O on the system volume changes the volume's signature - if AMFI refuses it, the"
echo "log will show the exec and nothing after it."

sync
umount "$work/m"
echo "image updated: $img ($inside <- $tool)"
