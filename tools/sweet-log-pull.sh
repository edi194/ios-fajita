#!/bin/sh
# Read the SWEET kernel console log (patch 0047) from a phone that is booted
# into a recovery with adb (TWRP). The kernel keeps a 4 MiB ring in the last
# 1025 blocks of userdata, past the HFS+ volume, so this only reads.
#
#   fastboot boot twrp.img          # temporary, nothing is written
#   adb wait-for-device
#   tools/sweet-log-pull.sh out.txt
#   adb reboot bootloader           # back to fastboot, then boot the kernel
#
# Requires sweetlog=1 in the kernel command line (the default in
# tools/build-fajita.sh).
set -eu
out=${1:?usage: sweet-log-pull.sh OUT.txt}
here=$(dirname "$0")

dev=$(adb shell 'for d in /dev/block/by-name/userdata \
    /dev/block/bootdevice/by-name/userdata /dev/block/sda*/userdata; do
    [ -e "$d" ] && readlink -f "$d" && break; done' 2>/dev/null | tr -d '\r')
[ -n "$dev" ] || { echo "userdata block device not found (is the phone in recovery?)" >&2; exit 1; }

bytes=$(adb shell blockdev --getsize64 "$dev" 2>/dev/null | tr -d '\r')
[ -n "$bytes" ] || { echo "cannot size $dev" >&2; exit 1; }
# 1025 blocks: one header block + 4 MiB of ring (SWEET_LOG_BLOCKS).
skip=$((bytes / 4096 - 1025))
echo "$dev: $bytes bytes, reading blocks $skip..$((skip + 1024))" >&2
adb exec-out "dd if=$dev bs=4096 skip=$skip count=1025 2>/dev/null" > "$out.bin"
python3 "$here/sweet-log.py" "$out.bin" "$out"
rm -f "$out.bin"
