#!/bin/sh
# Downloads the newest berga-tools bundle (the prebuilt on-device tools: SSH server, first-boot helpers, GL
# renderer; built from this repository by tools/berga-tools/package.sh, never anything from Apple or Qualcomm)
# from the GitHub release into public/tools/, where the flasher page fetches it at /tools/berga-tools.zip.
#   scripts/fetch-tools.sh [TAG]        default: the newest berga-tools-vN release
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../public/tools"
repo=ry-diffusion/Bergamota
tag=${1:-$(gh release list -R "$repo" --limit 50 --json tagName -q '[.[] | select(.tagName | startswith("berga-tools-v"))] | map(.tagName) | sort_by(ltrimstr("berga-tools-v") | tonumber) | last')}
mkdir -p "$out"
gh release download "$tag" -R "$repo" -p berga-tools.zip -p berga-tools.zip.sha256 -D "$out" --clobber
(cd "$out" && shasum -a 256 -c berga-tools.zip.sha256)
echo "berga-tools $tag -> $out/berga-tools.zip"
