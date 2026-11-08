#!/bin/sh
# Renegade first boot (root_tweaks18.firstboot), run by the launchd job org.bergamota.renegade-firstboot.
#  1. APPREG: register /Applications apps listed in /usr/local/share/renegade/register-apps with LaunchServices:
#       /usr/local/bin/sweetuicache /Applications/NAME.app      (one call per app, as root, like the live fix)
#     LaunchServices answers only once lsd is up, so the first app is retried (5 s apart, 10 min at most).
#  2. the jailbreak post-install (/var/jb/usr/share/renegade-jb/postinstall.sh) if the root has one
#  3. WALL: the default wallpaper (a Core Animation poster, no Metal: WALLPAPER_POSTER) and icon style (default, not tinted), once, as mobile:
#     /private/var/tmp/sweetrun.sh is written, `sweetopen com.sweet.run` starts SweetRun.app through FrontBoard (an app
#     lives in the mobile user's launchd domain, where PosterBoard's XPC service is reachable) and the script runs
#     sweetposterset (retried: -2203 while PosterBoard's store has no lock role yet, or the service is not up) and
#     sweeticonstyle. Marker /private/var/db/.renegade-poster-done
#  4. disables itself: marker /private/var/db/.renegade-firstboot-done (after 3 incomplete runs too)
DONE=/private/var/db/.renegade-firstboot-done
TRIES=/private/var/db/.renegade-firstboot-tries
[ -e $DONE ] && exit 0
PATH=/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
exec >>/private/var/log/renegade-firstboot.log 2>&1
n=0
[ -f $TRIES ] && n=$(cat $TRIES)
n=$((n+1))
echo $n >$TRIES
echo "== renegade first boot, run $n: $(date)"
rc=0
APPREG=@APPREG@
UIC=/usr/local/bin/sweetuicache
LIST=/usr/local/share/renegade/register-apps
reg() {
	out=$($UIC "/Applications/$1" 2>&1)
	r=$?
	echo "$out"
	return $r
}
if [ $APPREG = 1 ] && [ -x $UIC ] && [ -s $LIST ]; then
	first=1
	bad=
	while read app; do
		[ -d "/Applications/$app" ] || continue
		if [ $first = 1 ]; then
			first=0
			t=0
			until reg "$app"; do
				t=$((t+1))
				[ $t -ge 120 ] && { bad="$bad $app"; break; }
				sleep 5
			done
			continue
		fi
		reg "$app" || bad="$bad $app"
	done <$LIST
	for app in $bad; do      # one more round for the failures
		reg "$app" || rc=1
	done
	[ $rc = 0 ] && echo "apps registered" || echo "registration incomplete"
fi
WALL=@WALL@
PDONE=/private/var/db/.renegade-poster-done
if [ $WALL = 1 ] && [ ! -e $PDONE ] && [ -d /Applications/SweetRun.app ]; then
	echo "-- default wallpaper and icon style, as mobile via SweetRun"
	T=/private/var/tmp
	t=0
	until reg SweetRun.app; do      # idempotent; lsd may not be up yet when appreg is off
		t=$((t+1))
		[ $t -ge 24 ] && break
		sleep 5
	done
	rm -f $T/sweetrun.log $T/renegade-poster.rc
	cat >$T/sweetrun.sh <<'EOS'
export PATH=/usr/local/bin:/usr/bin:/bin
n=0
ok=1
while [ $n -lt 20 ]; do
	n=$((n+1))
	echo "sweetposterset try $n"
	/usr/local/bin/sweetposterset @WPROV@ @WDESC@ && { ok=0; break; }
	sleep 10
done
echo "sweetposterset rc=$ok"
# the Metal poster could not be selected (Mercury is black without the Metal device): fall back to the Collections poster, which ES renders
if [ $ok != 0 ] && [ "@WPROV@:@WDESC@" != "@WPROV2@:@WDESC2@" ]; then
	n=0
	while [ $n -lt 10 ]; do
		n=$((n+1))
		echo "fallback sweetposterset try $n"
		/usr/local/bin/sweetposterset @WPROV2@ @WDESC2@ && { ok=0; break; }
		sleep 10
	done
	[ $ok = 0 ] && { /usr/local/bin/sweetposterset --cleanup @WPROV2@ @WDESC2@; ok=0; }
else
# "already selected" counts as done (rc 0); drop duplicate Gradient configurations an older tool left behind
[ $ok = 0 ] && /usr/local/bin/sweetposterset --cleanup @WPROV@ @WDESC@
fi
/usr/local/bin/sweeticonstyle default || ok=1
echo $ok >/private/var/tmp/renegade-poster.rc
EOS
	chmod 644 $T/sweetrun.sh
	t=0
	until /usr/local/bin/sweetopen com.sweet.run; do      # works once SpringBoard is up
		t=$((t+1))
		[ $t -ge 120 ] && break
		sleep 5
	done
	t=0
	while [ ! -e $T/renegade-poster.rc ] && [ $t -lt 240 ]; do
		t=$((t+1))
		sleep 5
	done
	cat $T/sweetrun.log
	if [ -e $T/renegade-poster.rc ] && [ "$(cat $T/renegade-poster.rc)" = 0 ]; then
		touch $PDONE
		echo "wallpaper and icon style set"
	else
		rc=1
		echo "wallpaper/icon style not set (retried on the next boot)"
	fi
fi
JBPI=/var/jb/usr/share/renegade-jb/postinstall.sh
if [ -f $JBPI ] && [ ! -e /var/jb/.renegade-jb-done ]; then
	echo "-- jailbreak post-install ($JBPI)"
	/bin/sh $JBPI
	[ -e /var/jb/.renegade-jb-done ] || rc=1
fi
if [ $rc = 0 ] || [ $n -ge 3 ]; then
	touch $DONE
	echo "== done (rc=$rc), first-boot job disabled"
fi
exit 0
