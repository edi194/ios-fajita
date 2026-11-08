#!/bin/bash
# Build the full iOS 18.7.8 root image: see docs/IOS18_PORT.md section 12. No sudo.
#   tools/renegade/fetch-root.sh        # (once) download + decrypt the three dmgs
#   tools/renegade/mkroot-full.sh [mkroot-full.py options, e.g. --delete-sources --size 20g --stages copy,macho,...]
# -> research/ios18/ios18-root-full.simg (the raw image is consumed while the simg is written)
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 -I tools/renegade/mkroot-full.py "$@"
