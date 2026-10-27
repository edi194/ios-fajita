#!/bin/bash
# Copy a directory tree into a writable HFS+ image (the iOS root), the way
# replace-daemon-binary.sh installs one file.
#
#   sudo tools/install-tree-into-image.sh IMAGE SRCDIR /System/Library/Extensions
#
# SRCDIR is copied *into* DESTDIR keeping its own name (cp -R semantics).
set -euo pipefail
img=${1:?usage: install-tree-into-image.sh IMAGE SRCDIR DESTDIR}
src=${2:?source directory}
dest=${3:?destination directory inside the image}

[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ -d $src ]] || { echo "no such source dir: $src" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m" || { echo "mount failed" >&2; exit 1; }

mkdir -p "$work/m$dest"
rm -rf "$work/m$dest/$(basename "$src")"
cp -R "$src" "$work/m$dest/"
chown -R 0:0 "$work/m$dest/$(basename "$src")"
find "$work/m$dest/$(basename "$src")" -type d -exec chmod 0755 {} +
find "$work/m$dest/$(basename "$src")" -type f -exec chmod 0644 {} +
# Mach-O files get the exec bit (dlopen does not need it, execve would), everything else stays 0644
find "$work/m$dest/$(basename "$src")" -type f -print0 | while IFS= read -r -d '' f; do
	if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
		chmod 0755 "$f"
	fi
done
ls -la "$work/m$dest/$(basename "$src")"
echo "note: a Mach-O on the system volume changes the volume's signature - if AMFI refuses it, the"
echo "log will show nothing after the service is published."
sync
umount "$work/m"
echo "image updated: $img ($dest/$(basename "$src"))"
