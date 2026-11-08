#!/bin/bash
# Re-apply tools/sweet-root-tweaks.py to an existing iOS root image without
# rebuilding it from the IPSW: APFS-clone IN.img to OUT.img (no extra space
# until blocks change), mount the clone's HFS+ with owners, run the tweaks,
# fsck, and write OUT.simg for `fastboot flash userdata`. macOS, needs sudo.
#   sudo tools/sweet-retweak-image.sh IN.img OUT.img
set -euo pipefail
in=$1 out=$2
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d /tmp/retweak.XXXXXX)
dev=
cleanup() {
	umount "$work/root" 2>/dev/null || true
	[[ -n $dev ]] && hdiutil detach -force "$dev" >/dev/null 2>&1 || true
	rmdir "$work/root" "$work" 2>/dev/null || true
}
trap cleanup EXIT

rm -f "$out"
cp -c "$in" "$out"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$out" | awk 'NR==1{print $1}')
mkdir -p "$work/root"
mount -t hfs -o nobrowse "$dev" "$work/root"
mount | grep " on $work/root " | grep -q noowners && { echo "mounted noowners" >&2; exit 1; }
python3 "$here/sweet-root-tweaks.py" "$work/root"
rm -rf "$work/root"/.{Spotlight-V100,fseventsd,Trashes}
umount "$work/root"
fsck_hfs -fy "${dev/disk/rdisk}" || true
fsck_hfs -fn "${dev/disk/rdisk}"
hdiutil detach "$dev" >/dev/null
dev=
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$out"
python3 "$here/img2simg.py" "$out" "${out%.img}.simg"
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "${out%.img}.simg"
ls -l "$out" "${out%.img}.simg"
