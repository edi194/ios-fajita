#!/bin/bash
# Render the boot mark (bootmark.html, 458x154 on black) with headless Chrome: tools/mksplash.py puts it in the logo
# partition's slots 3, 6 and 8, where the stock image has the Google logo.
#   tools/identity/mkbootmark.sh [OUT.png [NUMERALS]]      default tools/identity/out/bootmark.png 26
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/out/bootmark.png}; n=${2:-26}
chrome=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
prof=$(mktemp -d); trap 'rm -rf "$prof"' EXIT
mkdir -p "$(dirname "$out")"
"$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$prof" \
	--force-device-scale-factor=1 --window-size=458,154 --virtual-time-budget=3000 --screenshot="$out" \
	"file://$here/bootmark.html?n=$n" >/dev/null 2>&1 || true
[ -s "$out" ] || { echo "mkbootmark.sh: Chrome rendered nothing" >&2; exit 1; }
echo "$out"
