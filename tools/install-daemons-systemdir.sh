#!/bin/bash
# Put the GPU test LaunchDaemons where stock launchd actually looks.
#
# The tools are already in the image at /usr/local/bin and their plists in
# /Library/LaunchDaemons, but three boots showed launchd never loading them. This port carries
# no launchd patches, so it scans /System/Library/LaunchDaemons - write the same two plists
# there.
#
#   sudo tools/install-daemons-systemdir.sh /home/edi194/ipsw-x/ios16-root-gpu.img
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
img=${1:?usage: install-daemons-systemdir.sh IMAGE}
[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m"

for pair in "gputest.plist:org.sweet.gputest.plist" "iokittest.plist:org.sweet.iokittest.plist"; do
	src=$here/tools/${pair%%:*}
	dst=$work/m/System/Library/LaunchDaemons/${pair##*:}
	install -m 0644 -o 0 -g 0 "$src" "$dst"
	ls -l "$dst"
done

sync
umount "$work/m"
echo "image updated: $img"
echo "now: tools/mk-root-with-gpu.sh is NOT needed; sparsify and flash:"
echo "  img2simg '$img' '${img%.img}.simg'"
echo "  fastboot flash userdata '${img%.img}.simg'"
