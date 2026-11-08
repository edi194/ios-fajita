#!/bin/sh
# Pull the Adreno 630 firmware from the phone's Android partitions, READ-ONLY.
#   tools/gpu-fw-pull.sh [-o OUTDIR] [-s SERIAL]
# The phone must be in OrangeFox recovery with adb (root shell). Nothing is ever written to a
# partition: block devices are mounted `ro,noload` (no journal replay) or only read with dd.
# Files go to research/gpu-fw/ (git-ignored):
#   a630_zap.mdt a630_zap.b00 .b01 .b02 ...   (required for sweetgpu=6..8; signed per device)
#   a630_gmu.bin a630_sqe.fw                   (if present; otherwise ../ios-beryllium/research/gpu-fw/dl has them)
# Then:  tools/gpu-fw-push.sh -d research/gpu-fw -z research/gpu-fw   (phone booted into iOS with SSH)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$here/../research/gpu-fw
serial=
while getopts o:s: o; do
	case $o in
	o) out=$OPTARG ;;
	s) serial="-s $OPTARG" ;;
	*) echo "usage: $0 [-o OUTDIR] [-s SERIAL]" >&2; exit 2 ;;
	esac
done
ADB="adb $serial"
sh_() { $ADB shell "$@"; }
mkdir -p "$out"

$ADB get-state >/dev/null 2>&1 || { echo "no adb device (boot OrangeFox, enable adb)" >&2; exit 1; }
case $(sh_ id 2>/dev/null) in *uid=0*) ;; *) echo "adb shell is not root; run 'adb root' or use OrangeFox's shell" >&2; exit 1 ;; esac

MNT=/tmp/gpufw_ro
cleanup() { sh_ "umount $MNT 2>/dev/null; rmdir $MNT 2>/dev/null" >/dev/null 2>&1 || true; }
trap cleanup EXIT
sh_ "mkdir -p $MNT"

# Candidate block devices: vendor, vendor_a/_b, system(_a/_b), then the modem (vfat, /firmware) partition.
byname=
for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/platform/soc/1d84000.ufshc/by-name; do
	if sh_ "[ -d $d ]" >/dev/null 2>&1; then byname=$d; break; fi
done
[ -n "$byname" ] || { echo "no by-name directory under /dev/block" >&2; exit 1; }
echo "partitions in $byname:"; sh_ "ls $byname" | tr '\r\n' '  ' | fold -w 100; echo
found=0
for part in vendor vendor_a vendor_b system system_a modem modem_a; do
	sh_ "[ -e $byname/$part ]" >/dev/null 2>&1 || continue
	dev=$(sh_ "readlink -f $byname/$part" | tr -d '\r')
	for fs in ext4 erofs vfat; do
		if sh_ "mount -t $fs -o ro,noload $dev $MNT 2>/dev/null || mount -t $fs -o ro $dev $MNT 2>/dev/null" >/dev/null 2>&1; then
			echo "== $part ($dev) mounted read-only as $fs"
			list=$(sh_ "find $MNT -maxdepth 4 \\( -name 'a630_*' -o -name 'a630*' \\) 2>/dev/null" | tr -d '\r')
			if [ -n "$list" ]; then
				echo "$list"
				for f in $list; do
					case $(basename "$f") in
					a630_zap.mdt|a630_zap.b[0-9][0-9]|a630_gmu.bin|a630_sqe.fw) $ADB pull "$f" "$out/" >/dev/null && found=$((found + 1)) ;;
					esac
				done
			else
				echo "   no a630* file in $part"
			fi
			sh_ "umount $MNT" >/dev/null 2>&1 || true
			break
		fi
	done
	[ "$found" -gt 0 ] && break
done

if [ ! -f "$out/a630_zap.mdt" ]; then
	cat >&2 <<MSG
a630_zap.mdt not found by mounting. Fallback (still read-only): dump the partition to the Mac and open it there,
  adb exec-out dd if=<block device of vendor> bs=1M > $out/vendor.img     (reads only)
  brew install e2fsprogs; \$(brew --prefix e2fsprogs)/sbin/debugfs -R 'rdump /firmware $out/vfw' $out/vendor.img
(note: ../ios-beryllium/backup/vendor.img had no a630 files; on this phone they may live under /vendor/firmware of the
 *running* ROM image, a dynamic/other partition, or only in a LineageOS beryllium vendor image.)
MSG
	exit 1
fi

# Verify: ELF32 mdt, every loadable segment has its bNN file of the right size, sizes sane, print hashes.
python3 -I - "$out" <<'PY'
import hashlib, os, struct, sys
d = sys.argv[1]
p = os.path.join(d, 'a630_zap.mdt')
b = open(p, 'rb').read()
ok = True
if b[:4] != b'\x7fELF' or b[4] != 1:
    print('FAIL: a630_zap.mdt is not an ELF32'); sys.exit(1)
phoff, = struct.unpack_from('<I', b, 28); phentsize, phnum = struct.unpack_from('<HH', b, 42)
print('a630_zap.mdt: %d bytes, %d program headers' % (len(b), phnum))
for i in range(phnum):
    t, off, va, pa, fsz, msz, fl, al = struct.unpack_from('<8I', b, phoff + i * phentsize)
    f = os.path.join(d, 'a630_zap.b%02d' % i)
    if fsz == 0:
        print('  seg %d: filesz 0 (hash/meta segment)' % i); continue
    if not os.path.exists(f):
        print('  seg %d: filesz %#x  MISSING %s' % (i, fsz, os.path.basename(f))); ok = False; continue
    sz = os.path.getsize(f)
    print('  seg %d: filesz %#x memsz %#x paddr %#x file %d bytes %s' % (i, fsz, msz, pa, sz, 'ok' if sz == fsz else 'SIZE MISMATCH'))
    ok &= sz == fsz
for n in sorted(os.listdir(d)):
    if n.startswith('a630_'):
        h = hashlib.sha256(open(os.path.join(d, n), 'rb').read()).hexdigest()
        print('  %s  %8d  %s' % (h[:16], os.path.getsize(os.path.join(d, n)), n))
g = os.path.join(d, 'a630_gmu.bin')
if os.path.exists(g) and os.path.getsize(g) > 0x8000:
    print('WARN: a630_gmu.bin larger than 0x8000'); ok = False
sys.exit(0 if ok else 1)
PY
echo "done: $out (read-only pull; nothing was written to the phone's partitions)"
