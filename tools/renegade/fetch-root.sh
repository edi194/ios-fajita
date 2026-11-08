#!/bin/bash
# Download the root dmg + SystemOS + AppOS cryptex dmgs of the Renegade target (tools/renegade/targets.py,
# RENEGADE_TARGET: ios26 = 26.6.2 iPhone12,1, about 9.3 GB; ios18 = 18.7.8 iPhone11,8, about 8.3 GB) and decrypt the AEA ones.
# Set FETCH_WITH_IPSW=1 for ipsw's own (RAM-hungry) partial download. Needs ~20 GB free (the .aea files are deleted
# after decryption). Output: research/<target>/ipsw/<build>__<device>/*.dmg
set -euo pipefail
cd "$(dirname "$0")/../.."
tg() { python3 -I tools/renegade/targets.py "$1"; }
DEVICE=$(tg device) VERSION=$(tg version) DMGS=$(tg dmgs)
O=$(tg ipsw_dir); D=$(dirname "$O"); mkdir -p "$O"
URL=$(ipsw download ipsw --device "$DEVICE" --version "$VERSION" --urls | tail -1)
if [ "${FETCH_WITH_IPSW:-0}" = 1 ]; then
	# ipsw's own partial download: faster, but it can use several GB of RAM (killed on an 8 GB Linux host)
	PAT=$(for m in $DMGS; do printf '%s|' "${m%%.dmg*}"; done)
	ipsw download ipsw --device "$DEVICE" --version "$VERSION" --pattern "^(${PAT%|})\.dmg(\.aea)?$" --flat -y -o "$D"
	for m in $DMGS; do [ -e "$D/$m" ] && mv "$D/$m" "$O/"; done
else
	# default: tools/remotezip.py streams each member to disk in 64 MiB HTTP ranges (little RAM), resumes a partial
	# download when run again, and checks the zip CRC-32 before the file gets its final name
	for m in $DMGS; do
		python3 tools/remotezip.py "$URL" "=$m" "$O"
	done
fi
python3 tools/remotezip.py "$URL" BuildManifest.plist "$D" >/dev/null
for a in "$O"/*.aea; do [ -e "$a" ] || continue; ipsw fw aea "$a" -o "$O" && rm -f "$a"; done
ls -l "$O"
