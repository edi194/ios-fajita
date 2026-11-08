#!/bin/sh
# Build (macOS + Xcode) and package the prebuilt on-device binaries -> research/berga-tools-out/berga-tools.zip (+ .sha256)
#   tools/berga-tools/package.sh                 build tools/sweetnet, then package it with the GL payload
#   BUILD=0 tools/berga-tools/package.sh         package what is already in research/sweetnet
#   RENEGADE_BGL=/path/to/bergamota-gl ...       the payload dir from gpu/eagl/make-payload.sh (gpu-eagl branch), default research/bergamota-gl
#   BERGA_TOOLS_VERSION=2 ...                    the number N of the tag berga-tools-vN (default 1)
# Extra arguments go to package.py (--out, --sweetnet, --bgl, --bgl-commit). Needs: python3; Xcode for the build step only.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$here/../..
if [ "${BUILD:-1}" = 1 ]; then
	[ "$(uname -s)" = Darwin ] && command -v xcrun >/dev/null || { echo "package.sh: building needs a Mac with Xcode (BUILD=0 packages existing binaries)" >&2; exit 1; }
	sh "$repo/tools/sweetnet/build.sh"
fi
exec python3 -I "$here/package.py" "$@"
