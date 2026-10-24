#!/bin/bash
# Build (or extend) the iOS root image with the SWEET GPU additions, then print the
# one flash command. Needs root: apfs-fuse and the loop mount that mkiosroot.sh uses.
#
#   sudo tools/mk-root-with-gpu.sh                 # build a fresh image from the IPSWs
#   sudo tools/mk-root-with-gpu.sh --in-place IMG  # add the files to an existing image
#
# What goes in:
#   /usr/local/bin/sweetgputest      the first userspace client of /dev/sweetgpu
#   /Library/LaunchDaemons/org.sweet.gputest.plist   runs it once at boot
#   /System/Library/Extensions/      directory prepared for the Metal bundle (B')
#
# The tool is built here (aarch64-linux-gnu-gcc + tools/mkinit.py), so the image always
# carries the current one.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
IPSW=${IPSW:-$HOME/ipsw-x}
OS_DMG=${OS_DMG:-$IPSW/087-86698-044.dmg}
SYS_DMG=${SYS_DMG:-$IPSW/087-86593-047.dmg}
APP_DMG=${APP_DMG:-$IPSW/087-86715-047.dmg}
OUT=${OUT:-$IPSW/ios16-root-20H392-gpu.img}

[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

echo "== building the tool"
aarch64-linux-gnu-gcc -c "$here/tools/sweet-gputest.S" -o "$work/gputest.o"
python3 "$here/tools/mkinit.py" "$work/gputest.o" "$work/sweetgputest"

if [[ ${1:-} == --in-place ]]; then
	img=$2
	[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
	echo "== extending $img in place"
else
	img=$OUT
	[[ ! -e $img ]] || { echo "refusing to overwrite $img (use --in-place)" >&2; exit 1; }
	echo "== building $img from the IPSWs (this takes a while)"
	"$here/tools/mkiosroot.sh" "$OS_DMG" "$SYS_DMG" "$APP_DMG" "$img"
fi

echo "== adding the GPU files"
mount -o loop,force "$img" "$work/mnt"
install -d "$work/mnt/usr/local/bin" "$work/mnt/System/Library/Extensions"
install -m 0755 -o root -g wheel "$work/sweetgputest" "$work/mnt/usr/local/bin/sweetgputest"
install -m 0644 -o root -g wheel "$here/tools/gputest.plist" \
	"$work/mnt/Library/LaunchDaemons/org.sweet.gputest.plist"
umount "$work/mnt"

echo
echo "image ready: $img ($(stat -c%s "$img") bytes)"
echo "flash it (destructive, the iOS root lives there):"
echo "  fastboot flash userdata '$img'"
echo "then boot boot_a as usual; the tool reports through /dev/console."
