#!/bin/sh
# Sideload an IPA onto the phone over SSH as a system app.
#   tools/sweet-install-ipa.sh App.ipa          install (or reinstall)
#   tools/sweet-install-ipa.sh -u App.app       uninstall by bundle folder name
# The app must be decrypted (no FairPlay: App Store downloads won't run) and
# contain an arm64 or arm64e slice. arm64e code (iOS 26) gets its pointer-
# authentication instructions rewritten to plain ARMv8.0 ones by Renegade's
# pacstrip, as the system itself is (this CPU has no PAuth; the kernel's PAC
# emulation, xnu patch 1019, would also run them, but at ~1 us per instruction).
# Every Mach-O in the bundle is then re-signed ad-hoc keeping its own
# entitlements (our kernel accepts ad-hoc signatures), copied to /Applications
# and registered with LaunchServices by research/sweetnet/sweetuicache
# (tools/sweetnet/sweetuicache.m).
set -eu
host=${SWEET_HOST:-root@192.168.7.2}
here=$(cd "$(dirname "$0")" && pwd)
uic=$here/../research/sweetnet/sweetuicache

if [ "${1:-}" = -u ]; then
	app=$(basename "$2")
	ssh "$host" "/usr/local/bin/sweetuicache -u /Applications/$app; rm -rf /Applications/$app"
	exit 0
fi
ipa=$1
[ -x "$uic" ] || { echo "build sweetuicache first (see tools/sweetnet)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$ipa" -d "$tmp"
app=$(ls -d "$tmp"/Payload/*.app | head -1)
[ -d "$app" ] || { echo "no Payload/*.app in $ipa" >&2; exit 1; }
name=$(basename "$app")

# Every Mach-O of the bundle (executables, dylibs, frameworks, extensions).
machos=$tmp/machos.txt
find "$app" -type f | while read -r f; do
	case $(od -An -tx1 -N4 "$f" | tr -d ' \n') in
	cffaedfe|cafebabe|cafebabf) echo "$f" ;;
	esac
done > "$machos"

# FairPlay-encrypted code can neither run here nor be rewritten (pacstrip would corrupt it).
while read -r f; do
	if otool -l "$f" | grep -A4 LC_ENCRYPTION_INFO | grep -q 'cryptid 1'; then
		echo "$name: ${f#"$app"/} is FairPlay-encrypted (App Store download): it will not run; use a decrypted IPA" >&2
		exit 1
	fi
done < "$machos"

# arm64e: PAC instructions -> plain ARMv8.0 (same 4-byte rewrite as the system's; no-op for arm64 code).
tr '\n' '\0' < "$machos" | xargs -0 python3 -I "$here/renegade/pacstrip.py" > "$tmp/pacstrip.txt"
grep -v ': no PAC code$' "$tmp/pacstrip.txt" || true

# Re-sign inside-out: nested bundles/dylibs first, the app last, each with its
# own entitlements (if any).
rm -rf "$app/_CodeSignature" "$app/embedded.mobileprovision"
find "$app" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.appex' -o -name '*.app' \) | while read -r b; do
	ents=$tmp/ents.plist
	if codesign -d --entitlements :- "$b" > "$ents" 2>/dev/null && [ -s "$ents" ]; then
		codesign -f -s - --entitlements "$ents" "$b" >/dev/null 2>&1 || codesign -f -s - "$b" >/dev/null
	else
		codesign -f -s - "$b" >/dev/null
	fi
done
echo "re-signed $name"

ssh "$host" "mkdir -p /usr/local/bin; rm -rf /Applications/$name"
scp -O "$uic" "$host:/usr/local/bin/sweetuicache" >/dev/null
(cd "$tmp/Payload" && tar cf - "$name") | ssh "$host" "cd /Applications && tar xf - && chown -R 0:80 /Applications/$name && chmod -R u+rwX,go+rX /Applications/$name && chmod 755 /usr/local/bin/sweetuicache"
ssh "$host" "/usr/local/bin/sweetuicache /Applications/$name"
