#!/bin/bash
# macOS version of tools/mkiosroot.sh: one case-sensitive journaled HFS+
# image with an iOS OS root plus its cryptexes, for the userdata partition
# (rd=ufsroot0). Same layout and SWEET additions as mkiosroot.sh.
#
#   sudo tools/mkiosroot-macos.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]   (SIZE default 16g)
#
# macOS mounts the IPSW's APFS images itself (hdiutil); ditto
# --nohfsCompression --nopreserveHFSCompression writes every file uncompressed (the SWEET kernel has no
# decmpfs/LZBITMAP) and, as root, keeps owners, modes and symlinks. OUT.img is
# a raw volume (no partition map), flashable with
#   fastboot -S 512M flash userdata OUT.img
set -euo pipefail

[[ $# -ge 4 ]] || { sed -n '2,12p' "$0"; exit 2; }
[[ $(id -u) == 0 ]] || { echo "run as root (sudo): owners must be preserved" >&2; exit 1; }
abs() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
os=$(abs "$1") sysos=$(abs "$2") appos=$(abs "$3") out=$4 size=${5:-16g}
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }

work=$(mktemp -d /tmp/mkiosroot.XXXXXX)
devs=()
done_ok=0
cleanup() {
	for d in "${devs[@]}"; do
		hdiutil detach -force "$d" >/dev/null 2>&1 || true
	done
	rmdir "$work"/* "$work" 2>/dev/null || true
	# A half-built image is useless: remove it so a rerun can start over.
	[[ $done_ok == 1 || ! -e $out ]] || { rm -f "$out"; echo "removed incomplete $out" >&2; }
}
trap cleanup EXIT

# Attach an IPSW image read-only at $work/NAME, with owners (image mounts
# default to noowners: every file would look like the mounting user). The OS image is UDIF; the
# cryptexes are raw APFS containers, which hdiutil only takes as raw disks.
apfs_mount() {
	local img=$1 name=$2 dev
	mkdir "$work/$name"
	if hdiutil imageinfo "$img" >/dev/null 2>&1; then
		dev=$(hdiutil attach -readonly -nobrowse -noverify -owners on -mountpoint "$work/$name" "$img" | awk 'NR==1{print $1}')
	else
		dev=$(hdiutil attach -readonly -nobrowse -noverify -owners on -imagekey diskimage-class=CRawDiskImage \
			-mountpoint "$work/$name" "$img" | awk 'NR==1{print $1}')
	fi
	devs+=("$dev")
	[[ -d $work/$name/System || -d $work/$name/usr ]] || { echo "$img: nothing mounted at $work/$name" >&2; exit 1; }
	echo "mounted $img ($dev)"
}
apfs_mount "$os" os
apfs_mount "$sysos" sysos
apfs_mount "$appos" appos

# Raw image -> case-sensitive journaled HFS+ (newfs_hfs -s -J), mounted with owners.
mkfile -n "$size" "$out"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$out" | awk 'NR==1{print $1}')
devs=("$dev" "${devs[@]}")
newfs_hfs -s -J -v iOSRoot "${dev/disk/rdisk}"
mkdir "$work/root"
mount -t hfs "$dev" "$work/root"
# A root mount_hfs honours owners (no noowners); show the options to be sure.
mount | grep " on $work/root " || true
mount | grep " on $work/root " | grep -q noowners && { echo "root volume mounted noowners" >&2; exit 1; }

copy() {
	echo "copying ${1#"$work/"} -> /${2#"$work/root"}"
	mkdir -p "$2"
	ditto --nohfsCompression --nopreserveHFSCompression "$1" "$2"
}
copy "$work/os" "$work/root"
copy "$work/sysos" "$work/root/private/preboot/Cryptexes/OS"
copy "$work/appos" "$work/root/private/preboot/Cryptexes/App"
# hdiutil mounts carry Spotlight/fsevents bookkeeping that is not iOS
rm -rf "$work/root"/.{Spotlight-V100,fseventsd,Trashes} "$work/root/private/preboot/Cryptexes"/*/.{Spotlight-V100,fseventsd,Trashes}

# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
for f in "$work/root/$dsc"/*; do
	ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
done

# dyld does not search the cryptexes at ignition level 1: hard-link every
# cryptex file without a counterpart in the OS root (libobjc-trampolines, ...).
for c in OS App; do
	(cd "$work/root/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $work/root/$f && ! -L $work/root/$f ]]; then
			mkdir -p "$work/root/$(dirname "$f")"
			src="$work/root/private/preboot/Cryptexes/$c/$f"
			if [[ -L $src ]]; then cp -P "$src" "$work/root/$f"; else ln "$src" "$work/root/$f"; fi
			echo "linked $c:/$f"
		fi
	done
done

# logd's log stores (owner _logd 272, .migrated markers), as in mkiosroot.sh.
db="$work/root/private/var/db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done

# System keybag for the built-in AppleKeyStore (no passcode).
install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
	> "$work/root/private/var/keybags/systembag.kb"
chmod 0600 "$work/root/private/var/keybags/systembag.kb"

# The SWEET kernel has no decmpfs: one compressed file (launchd!) is fatal.
ncomp=$(find "$work/root" -flags +compressed 2>/dev/null | wc -l | tr -d ' ')
[[ $ncomp == 0 ]] || { echo "error: $ncomp files are still HFS-compressed" >&2; exit 1; }

# Bring-up tweaks (Setup skip, activation, launchd jobs, ...).
python3 "$(dirname "$0")/sweet-root-tweaks.py" "$work/root"

df -h "$work/root"
umount "$work/root"
fsck_hfs -fy "${dev/disk/rdisk}" || true
fsck_hfs -fn "${dev/disk/rdisk}"
done_ok=1
echo "done: $out"
