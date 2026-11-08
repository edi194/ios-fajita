#!/bin/sh
# Copy pictures to the phone's camera roll over SSH (USB Ethernet).
#   tools/sweet-push-photo.sh IMAGE...
# Converts each to JPEG (sips) as DCIM/100APPLE/IMG_NNNN.JPG, owned by mobile.
# assetsd imports camera-roll files when it builds/scans the library; a file
# pushed while it runs may need a reboot or a Photos relaunch to appear.
set -eu
host=${SWEET_HOST:-root@192.168.7.2}
dir=/private/var/mobile/Media/DCIM/100APPLE
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
n=$(ssh "$host" "mkdir -p $dir; ls $dir | sed -n 's/^IMG_\([0-9]*\)\..*/\1/p' | sort -n | tail -1")
n=${n:-0}
for f in "$@"; do
	n=$((10#$n + 1))
	name=$(printf 'IMG_%04d.JPG' "$n")
	sips -s format jpeg "$f" --out "$tmp/$name" >/dev/null
	scp -O "$tmp/$name" "$host:$dir/$name" >/dev/null
	echo "$f -> $dir/$name"
done
ssh "$host" "chown -R 501:501 /private/var/mobile/Media/DCIM"
