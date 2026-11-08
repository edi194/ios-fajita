#!/bin/sh
# Copy the Adreno 630 firmware onto the phone's iOS root over SSH (never committed to git).
#   tools/gpu-fw-push.sh [-d FWDIR] [-z ZAPDIR]
# FWDIR  holds a630_gmu.bin and a630_sqe.fw (linux-firmware qcom/, redistributable); default
#        ../ios-beryllium/research/gpu-fw/dl next to this repository.
# ZAPDIR holds the phone's own signed zap shader from its Android /vendor/firmware:
#        a630_zap.mdt + a630_zap.b00 .b01 .b02 ... (not in any backup image; docs/GPU_KERNEL.md).
# Files go to /usr/local/share/firmware/ (the kernel also looks in /usr/standalone/firmware/sweet/).
# Needs the phone booted with SSH up (docs/NOTES.md, root@192.168.7.2); SWEET_HOST overrides.
set -eu
host=${SWEET_HOST:-root@192.168.7.2}
here=$(cd "$(dirname "$0")" && pwd)
fwdir=$here/../../ios-beryllium/research/gpu-fw/dl
zapdir=
while getopts d:z: o; do
	case $o in
	d) fwdir=$OPTARG ;;
	z) zapdir=$OPTARG ;;
	*) echo "usage: $0 [-d FWDIR] [-z ZAPDIR]" >&2; exit 2 ;;
	esac
done
dest=/usr/local/share/firmware
ssh "$host" "mkdir -p $dest"
push() {
	[ -f "$1" ] || { echo "missing $1" >&2; return 1; }
	ssh "$host" "cat > $dest/$(basename "$1") && chmod 644 $dest/$(basename "$1")" < "$1"
	echo "pushed $(basename "$1") ($(wc -c < "$1") bytes)"
}
push "$fwdir/a630_gmu.bin"
push "$fwdir/a630_sqe.fw"
if [ -n "$zapdir" ]; then
	for f in "$zapdir"/a630_zap.mdt "$zapdir"/a630_zap.b[0-9][0-9]; do
		push "$f"
	done
else
	echo "no -z ZAPDIR: stages 6-8 will stop at the zap shader (stages 3-5 work without it)" >&2
fi
ssh "$host" "sync; ls -l $dest"
