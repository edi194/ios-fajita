#!/bin/bash
# Build the iOS 18 RAM-disk root (case-sensitive HFS+, uncompressed, all root:wheel) from the iOS 18.7.8
# restore ramdisk, every Mach-O rewritten by pacstrip and ad-hoc signed. No sudo needed.
#
#   tools/renegade/fetch-ramdisk.sh                       # mounts research/ios18/ramdisk/mnt (once)
#   tools/renegade/mkramdisk-root.sh [--stock-daemons] [--keep-stage]
#   -> research/ios18/ios18-root.hfs   then see docs/IOS18_PORT.md section 9 for the boot image.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=${SRC:-research/ios18/ramdisk/mnt}
STAGE=research/ios18/rootstage
OUT=${OUT:-research/ios18/ios18-root.hfs}
KEEP=0; EXTRA=()
for a in "$@"; do case $a in --keep-stage) KEEP=1;; *) EXTRA+=("$a");; esac; done
[ -d "$SRC/usr/lib" ] || { echo "$SRC is not mounted: run tools/renegade/fetch-ramdisk.sh" >&2; exit 1; }

python3 -I tools/renegade/mkroot.py "$SRC" "$STAGE" "${EXTRA[@]+"${EXTRA[@]}"}"
KB=$(du -sk "$STAGE" | cut -f1)
MB=$(( KB / 1024 * 118 / 100 + 12 ))          # HFS+ overhead (4 KiB blocks, catalog, attributes) + slack
echo "stage $((KB/1024)) MiB -> image $MB MiB"
rm -f "$OUT"; mkfile -n ${MB}m "$OUT"
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" 2>/dev/null | awk 'NR==1{print $1}')
trap 'hdiutil detach -force "$DEV" >/dev/null 2>&1 || true' EXIT
newfs_hfs -s -v iOSRoot "${DEV/disk/rdisk}" >/dev/null           # case-sensitive, NOT journaled
hdiutil detach "$DEV" >/dev/null
MNT=$PWD/research/ios18/rootmnt; mkdir -p "$MNT"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint "$MNT" "$OUT" 2>/dev/null | awk 'NR==1{print $1}')
ditto --nohfsCompression --nopreserveHFSCompression --noextattr --noqtn --norsrc --noacl "$STAGE" "$MNT"
rm -rf "$MNT"/.{Spotlight-V100,fseventsd,Trashes} 2>/dev/null || true
find "$MNT" -flags +compressed 2>/dev/null | head -3 | grep . && { echo "compressed files left" >&2; exit 1; }
df -h "$MNT" | tail -1
hdiutil detach "$DEV" >/dev/null; trap - EXIT
fsck_hfs -fn "$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" 2>/dev/null | awk 'NR==1{d=$1; gsub("disk","rdisk",d); print d}')" >/dev/null 2>&1 || true
for d in $(hdiutil info | awk -v o="$PWD/$OUT" '$0 ~ o {f=1} f && /^\/dev\/disk[0-9]+ /{print $1; f=0}'); do hdiutil detach "$d" >/dev/null 2>&1 || true; done
python3 -I tools/renegade/hfsroot_chown.py "$OUT"
[ $KEEP = 1 ] || rm -rf "$STAGE"
ls -l "$OUT"
