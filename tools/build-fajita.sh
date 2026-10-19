#!/usr/bin/env bash
# Build the fajita ADT + payload + shim boot image from an XNU CI artifact.
#
#   XNU_KERNEL=xnu/out/kernel.development.sweet DTB=dtb/boot_unpacked/dtb \
#       tools/build-fajita.sh
#
# The stock OnePlus/LineageOS boot.img DTB is required. The boot image header
# fields in shim/build.sh still need to be verified against that stock image.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC1091
. tools/fajita.env

XNU_KERNEL=${XNU_KERNEL:-xnu/out/kernel.development.sweet}
DTB=${DTB:-dtb/boot_unpacked/dtb}
ADT=${ADT:-shim/out/fajita.adt}
PAYLOAD=${PAYLOAD:-shim/out/payload.bin}
# Start on the A55 cluster only. Add cpus=8 once the early boot is stable.
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweettouch=0 sweetkeys=0"}

[[ -f "$XNU_KERNEL" ]] || { echo "missing XNU kernel: $XNU_KERNEL" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing stock DTB: $DTB (unpack the OnePlus boot.img first)" >&2; exit 1; }

mkdir -p shim/out
python3 tools/mkadt.py "$ADT" --highmem
python3 tools/mkpayload.py "$XNU_KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE"
# shim/build.sh cds into shim/, so hand it absolute paths.
DTB=$(realpath "$DTB") shim/build.sh "$(realpath "$PAYLOAD")"

echo "built: shim/out/shim-boot.img"
