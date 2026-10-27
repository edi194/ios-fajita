#!/bin/bash
# Copy individual files into a writable HFS+ image (the iOS root).
#
#   sudo tools/install-files-into-image.sh IMAGE DESTDIR FILE [FILE...]
#
# Unlike install-tree-into-image.sh this keeps the files' own names in DESTDIR, which is what the
# Metal test needs (bgmtl-adddev and its two dylibs must sit together: the rpath is @executable_path).
set -euo pipefail
img=${1:?usage: install-files-into-image.sh IMAGE DESTDIR FILE...}
dest=${2:?destination directory}
shift 2
[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }
for f in "$@"; do [[ -f $f ]] || { echo "no such file: $f" >&2; exit 1; }; done

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m" || { echo "mount failed" >&2; exit 1; }

mkdir -p "$work/m$dest"
for f in "$@"; do
	install -m 0755 -o 0 -g 0 "$f" "$work/m$dest/$(basename "$f")"
done
ls -la "$work/m$dest"
echo "note: a Mach-O on the system volume changes the volume's signature - if AMFI refuses one, the"
echo "log will show the program start and nothing after it."
sync
umount "$work/m"
echo "image updated: $img ($dest <- $# file(s))"
