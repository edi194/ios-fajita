#!/bin/bash
# The Bergamota app icon as an Icon Composer document (macOS 26 / Xcode 26+): renders the layers of
# apps/Bergamota/Bergamota/Bergamota.icon from tools/identity (icon-layers.html through headless Chrome, the halftone
# ground as SVG) and, with ictool, tools/identity/icon-512.png (README, web) and the six renditions in
# tools/identity/out/icon-*.png. The composition itself (groups, fills per appearance, shadows) is the bundle's
# icon.json, edited by hand or in Icon Composer; this script never rewrites it.
#   tools/identity/mkicon.sh [CHROME]
# Layers, front to back: Newton (halftone cutout), Numerals (white "26"; lime in Dark), the ground's dots (hidden in
# Tinted) and a Dark-only background (leaf green gradient). The lime ground is the document fill (Default only).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
chrome=${1:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}
ictool=${ICTOOL:-/Applications/Icon Composer.app/Contents/Executables/ictool}
icon=$here/../../apps/Bergamota/Bergamota/Bergamota.icon
assets=$icon/Assets
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$assets" "$here/out"
for layer in newton numerals; do
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$tmp/prof" \
		--force-device-scale-factor=1 --default-background-color=00000000 --window-size=1024,1024 --virtual-time-budget=3000 \
		--screenshot="$tmp/$layer.png" "file://$here/icon-layers.html?layer=$layer" >/dev/null 2>&1 || true
	[ -s "$tmp/$layer.png" ] || { echo "mkicon.sh: Chrome rendered no $layer layer" >&2; exit 1; }
done
cp "$tmp/newton.png" "$assets/Newton.png"
cp "$tmp/numerals.png" "$assets/Numerals.png"
# the ground's halftone: 40 x 40 dots (the identity's 7 px grid at the icon's scale); Icon Composer recolours it
python3 -I - "$assets" <<'EOF'
import sys
n = 40
g = 1024 / n
dots = ''.join('<circle cx="%.2f" cy="%.2f" r="%.2f"/>' % ((i + .5) * g, (j + .5) * g, g * .17) for j in range(n) for i in range(n))
svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">%s</svg>\n'
open(sys.argv[1] + '/Dots.svg', 'w').write(svg % ('<g fill="#c6dc72">' + dots + '</g>'))
# full bleed; the colour does not matter, the Dark fill replaces it (Icon Composer guide, section 5)
open(sys.argv[1] + '/Background.svg', 'w').write(svg % '<rect width="1024" height="1024" fill="#000000"/>')
EOF
if [ -x "$ictool" ]; then
	"$ictool" "$icon" --export-image --output-file "$here/icon-512.png" --platform macOS --rendition Default \
		--width 512 --height 512 --scale 1 >/dev/null
	for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
		"$ictool" "$icon" --export-image --output-file "$here/out/icon-$r.png" --platform macOS --rendition $r \
			--width 512 --height 512 --scale 1 >/dev/null
	done
	echo "wrote $assets, $here/icon-512.png and $here/out/icon-*.png"
else
	echo "wrote $assets (no ictool: icon-512.png not updated)"
fi
