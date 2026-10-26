#!/bin/bash
# Undo the daemon-binary replacements in the iOS root image (restore the .orig copies).
#
#   sudo tools/restore-daemons.sh IMAGE
set -euo pipefail

img=${1:?usage: restore-daemons.sh IMAGE}
[[ -f $img ]] || { echo "no such image: $img" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "needs root (sudo)" >&2; exit 1; }

work=$(mktemp -d)
trap 'umount "$work/m" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/m"
mount -o loop,force "$img" "$work/m"

restored=0
while IFS= read -r orig; do
	[[ -f $orig ]] || continue
	dst=${orig%.orig}
	cp -p "$orig" "$dst"
	rm -f "$orig"
	echo "restored ${dst#$work/m}"
	restored=$((restored + 1))
done < <(find "$work/m" -name '*.plist.orig' -o -name '*.orig' 2>/dev/null | sort)

sync
umount "$work/m"
echo "restored $restored file(s) in $img"
