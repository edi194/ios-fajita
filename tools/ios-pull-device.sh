#!/system/bin/sh
# Runs on the phone in OrangeFox (pushed by tools/sweet-ios-pull.sh).
# Copies HFS+ paths of the iOS root out of a block device with hfsdump
# (read-only), recursively, into OUT on the recovery's tmpfs.
#   ios-pull-device.sh DEV OUT PATH...
dev=$1 out=$2
shift 2
H=${HFSDUMP_BIN:-/tmp/hfsdump}

pull() {
	t=$($H "$dev" stat "$1" 2>/dev/null | sed -n 's/^type: //p')
	case $t in
	folder)
		mkdir -p "$out$1"
		$H "$dev" read "$1" 2>/dev/null | while IFS= read -r n; do
			[ -n "$n" ] && pull "$1/$n"
		done
		;;
	file)
		mkdir -p "$out${1%/*}"
		$H "$dev" read "$1" > "$out$1" 2>/dev/null
		;;
	*)
		echo "skip $1 (${t:-missing})" >&2
		;;
	esac
}

for p; do
	pull "$p"
done
