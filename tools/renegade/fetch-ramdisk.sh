#!/bin/bash
# Fetch the iOS 18 restore ramdisk of an IPSW (176 MB, plain IMG4 -> APFS, NOT encrypted) and mount it read-only.
# Only this one member is downloaded (HTTP range requests, tools/remotezip.py); the 6.5 GB root dmg is AEA-encrypted
# and not needed: the ramdisk is a complete on-disk userland (dyld, libSystem dylibs, no shared cache, /bin tools).
#
#   tools/renegade/fetch-ramdisk.sh [-u IPSW_URL] [-d WORKDIR]      (default WORKDIR research/ios18/ramdisk)
#   -> prints the mountpoint; then: python3 -I tools/renegade/mkbundle.py <mountpoint> research/ios18poc
#   hdiutil detach <mountpoint> when done (the script leaves it mounted).
set -euo pipefail
cd "$(dirname "$0")/../.."
URL=; WORK=research/ios18/ramdisk
while getopts u:d: o; do case $o in u) URL=$OPTARG;; d) WORK=$OPTARG;; *) exit 2;; esac; done
[ -n "$URL" ] || URL=$(ipsw download ipsw --device iPhone11,8 --version 18.7.8 --urls | tail -1)
mkdir -p "$WORK"
python3 tools/remotezip.py "$URL" BuildManifest.plist "$WORK" >/dev/null
RD=$(python3 -I - "$WORK/BuildManifest.plist" <<'P'
import plistlib, sys
m = plistlib.load(open(sys.argv[1], 'rb'))['BuildIdentities'][0]['Manifest']
print(m['RestoreRamDisk']['Info']['Path'])
P
)
echo "restore ramdisk member: $RD"
python3 tools/remotezip.py "$URL" "$RD" "$WORK" >/dev/null
ipsw img4 im4p extract "$WORK/$RD" -o "$WORK/ramdisk.apfs" >/dev/null
MNT=$PWD/$WORK/mnt
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noverify -imagekey diskimage-class=CRawDiskImage -mountpoint "$MNT" "$WORK/ramdisk.apfs" >/dev/null
echo "mounted read-only at $MNT"
ls "$MNT/usr/lib/dyld" "$MNT/bin"
