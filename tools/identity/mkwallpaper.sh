#!/bin/bash
# Render the Bergamota wallpaper (wallpaper.html) to a PNG with headless Chrome, like mkidentity.py renders the rest of
# the identity (the fonts and the portrait load from this directory).
#   tools/identity/mkwallpaper.sh OUT.png [W H [NUMERALS]]      default 1125 2436 26 (the panel as iOS 26 is presented)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: mkwallpaper.sh OUT.png [W H [NUMERALS]]}"
W="${2:-1125}"; H="${3:-2436}"; N="${4:-26}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROF="$(mktemp -d)"; trap 'rm -rf "$PROF"' EXIT
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$PROF" \
  --force-device-scale-factor=1 --window-size="$W,$H" --virtual-time-budget=4000 --screenshot="$OUT" \
  "file://$HERE/wallpaper.html?w=$W&h=$H&n=$N" >/dev/null 2>&1
[ -s "$OUT" ] || { echo "chrome produced no $OUT" >&2; exit 1; }
echo "$OUT ($W x $H)"
