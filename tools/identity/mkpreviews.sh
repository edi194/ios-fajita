#!/bin/bash
# Previews of Enxerto's screens exactly as the phone draws them: builds enxerto/host_test (the same drawing code on
# the host, fake PMIC/USB states) for the board's panel and writes PNGs to tools/identity/out/screens/.
#   tools/identity/mkpreviews.sh [beryllium|sweet]      default beryllium (Poco F1, 1080x2246)
# Needs cc and sips (macOS). The artwork is enxerto/art.h (tools/identity/mkidentity.py).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
board=${1:-beryllium}
enx=$here/../../enxerto
out=$here/out/screens
mkdir -p "$out" "$enx/out/preview"
def=; [ "$board" = beryllium ] && def=-DBOARD_BERYLLIUM
(cd "$enx" && cc -O1 -Wall $def -o out/host_test console.c artdraw.c bootui.c fbui.c charge.c host_test.c && ./out/host_test)
for f in "$enx"/out/preview/*.ppm; do
	sips -s format png "$f" --out "$out/$(basename "${f%.ppm}").png" >/dev/null
done
echo "wrote $(ls "$out" | wc -l | tr -d ' ') previews to $out"
