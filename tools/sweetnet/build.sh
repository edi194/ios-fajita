#!/bin/sh
# Build and ad-hoc sign the on-device tools for iOS 16 -> research/sweetnet/
# (sweetnetcfg, cscheck, hcitest, bluetool-stub, sweetreboot, sweetdur = UFS durability test, kernel 0221; set TOOLS="hcitest" to build a subset; sweetreboot = reboot-to-fastboot, kernel 0137)
# iOS 18: also research/sweetnet/ios18/{sweetuicache,sweetfp.dylib} (arm64e + pacstrip --sign)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../../research/sweetnet
mkdir -p "$out"
for t in ${TOOLS:-sweetnetcfg cscheck hcitest bluetool-stub sweetreboot sweetdur}; do
	ents=$here/entitlements.plist
	case $t in
	cscheck) frameworks="-framework CoreFoundation -framework Security" ;;
	hcitest|sweetreboot|sweetdur) frameworks="" ;;
	bluetool-stub) frameworks=""; ents=$here/bluetool.entitlements ;;
	*) frameworks="-framework CoreFoundation" ;;
	esac
	xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
		$frameworks "$here/$t.c" -o "$out/$t"
	codesign -s - -f --entitlements "$ents" "$out/$t"
	ls -l "$out/$t"
done
# LaunchServices register tool for sideloaded apps (tools/sweet-install-ipa.sh)
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -fobjc-arc \
	-framework Foundation "$here/sweetuicache.m" -o "$out/sweetuicache"
codesign -s - -f --entitlements "$here/uicache.entitlements" "$out/sweetuicache"

# iOS 18 (Renegade): arm64e builds that the kernel without pointer authentication runs after
# `renegade strip --sign` (pacstrip). Output: research/sweetnet/ios18/ (set IOS18=0 to skip)
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	pacstrip=$here/../renegade/pacstrip.py
	mkdir -p "$out18"
	# sweetprefs: set/read a user default through cfprefsd (installed in /usr/local/bin by root_tweaks18.base())
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation \
		"$here/sweetprefs.c" -o "$out18/sweetprefs"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetprefs"
	python3 -I "$pacstrip" --sign "$out18/sweetprefs"
	# sweetdur: UFS/HFS durability test (kernel patch 0221)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetdur.c" -o "$out18/sweetdur"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetdur"
	python3 -I "$pacstrip" --sign "$out18/sweetdur"
	# sweetuicache: LaunchServices registration, run by the first-boot job (root_tweaks18.firstboot)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc \
		-framework Foundation "$here/sweetuicache.m" -o "$out18/sweetuicache"
	codesign -s - -f --entitlements "$here/uicache.entitlements" "$out18/sweetuicache"
	python3 -I "$pacstrip" --sign "$out18/sweetuicache"
	# sweetfp.dylib: NSURLFileProtectionKey shim, linked into PosterBoard (root_tweaks18.posterboard)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -dynamiclib \
		-install_name /usr/local/lib/sweetfp.dylib -framework Foundation \
		"$here/sweetfp.m" -o "$out18/sweetfp.dylib"
	codesign -s - -f "$out18/sweetfp.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetfp.dylib"
	ls -l "$out18"
fi

# First-boot wallpaper/icon style and the mobile-domain runner (root_tweaks18.firstboot, iOS 18, arm64e + pacstrip)
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	pacstrip=$here/../renegade/pacstrip.py
	b18() { # name source entitlements [extra clang args]
		n=$1; src=$2; ents=$3; shift 3
		xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -framework Foundation "$@" \
			"$here/$src" -o "$out18/$n"
		codesign -s - -f --entitlements "$here/$ents" "$out18/$n"
		python3 -I "$pacstrip" --sign "$out18/$n"
	}
	# sweetmetrics: Bergamota live metrics (docs/BERGAMOTA_METRICS.md), plain C, root_tweaks18.sweetmetrics
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation -framework IOKit \
		"$here/sweetmetrics.c" -o "$out18/sweetmetrics"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetmetrics"
	python3 -I "$pacstrip" --sign "$out18/sweetmetrics"
	b18 sweetposterset sweetposterset.m posterset.entitlements
	# a picture as the lock and home wallpaper through PosterBoard's Photos poster (tools/identity/mkwallpaper.sh)
	b18 sweetwallpaper sweetwallpaper.m posterset.entitlements
	# iOS 26: the Bergamota picture as the legacy wallpaper, drawn by PosterBoard's LegacyPoster (no HEIC, no Photos pipeline)
	b18 sweetlegacywall sweetlegacywall.m posterset.entitlements -framework UIKit
	# iOS 26: PosterBoard on the HFS root without data protection (file protection, purgeable, the empty StandBy role)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -dynamiclib \
		-install_name /usr/local/lib/sweetpb26.dylib -framework Foundation "$here/sweetpb26.m" -o "$out18/sweetpb26.dylib"
	codesign -s - -f "$out18/sweetpb26.dylib"
	python3 -I "$pacstrip" --sign "$out18/sweetpb26.dylib"
	b18 sweeticonstyle sweeticonstyle.m iconstyle.entitlements -framework UIKit
	b18 sweetopen sweetopen.m uicache.entitlements
	# remote testing over SSH: screenshot of the panel (PNG) and synthetic touch/buttons
	b18 sweetshot sweetshot.m touch.entitlements -framework CoreGraphics -framework ImageIO -framework IOSurface \
		-framework QuartzCore
	# a CPU profile of one process over SSH (running threads only, frame-pointer stacks, aggregated on the phone)
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall "$here/sweetsample.c" -o "$out18/sweetsample"
	codesign -s - -f --entitlements "$here/sample.entitlements" "$out18/sweetsample"
	python3 -I "$pacstrip" --sign "$out18/sweetsample"
	# Wi-Fi over SSH (iOS 26 stand-in, docs/WIFI_IOS26.md): Apple80211 info/power/scan without wifid or the UI
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation \
		"$here/sweetwifi.c" -o "$out18/sweetwifi"
	codesign -s - -f --entitlements "$here/wifi.entitlements" "$out18/sweetwifi"
	python3 -I "$pacstrip" --sign "$out18/sweetwifi"
	# the unified log over SSH (no `log` tool on iOS)
	b18 sweetlog sweetlog.m log.entitlements -framework OSLog
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall -framework CoreFoundation -framework IOKit \
		"$here/sweettouch.c" -o "$out18/sweettouch"
	codesign -s - -f --entitlements "$here/touch.entitlements" "$out18/sweettouch"
	python3 -I "$pacstrip" --sign "$out18/sweettouch"
	# SweetRun.app: runs /private/var/tmp/sweetrun.sh as mobile in the user's launchd domain (an app started by FrontBoard)
	app=$out18/SweetRun.app
	rm -rf "$app"; mkdir -p "$app"
	cp "$here/sweetrun-app/Info.plist" "$app/Info.plist"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -fobjc-arc -framework UIKit -framework Foundation \
		"$here/sweetrun-app/sweetrun.m" -o "$app/SweetRun"
	codesign -s - -f --entitlements "$here/sweetrun-app/run.entitlements" "$app"
	python3 -I "$pacstrip" --sign "$app/SweetRun"
	codesign -s - -f --entitlements "$here/sweetrun-app/run.entitlements" "$app"      # seal the bundle again
	ls -l "$out18"
fi

# sweetmetrics (Bergamota live metrics, docs/BERGAMOTA_METRICS.md): iOS 18, arm64e, then `renegade strip --sign`
# (pacstrip) so the kernel without pointer authentication runs it. Output: research/sweetnet/ios18/sweetmetrics
if [ "${IOS18:-1}" = 1 ]; then
	out18=$out/ios18
	mkdir -p "$out18"
	xcrun -sdk iphoneos clang -arch arm64e -mios-version-min=18.0 -O2 -Wall \
		-framework CoreFoundation -framework IOKit "$here/sweetmetrics.c" -o "$out18/sweetmetrics"
	codesign -s - -f --entitlements "$here/entitlements.plist" "$out18/sweetmetrics"
	"$here/../renegade/renegade" strip --sign "$out18/sweetmetrics"
	ls -l "$out18/sweetmetrics"
fi
