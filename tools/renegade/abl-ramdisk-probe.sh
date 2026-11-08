#!/bin/bash
# Find ABL's real ramdisk limit: build boot images whose payload carries an UNCOMPRESSED zero RAM disk of N MiB.
# Enxerto prints "INITRD lo=... hi=..." on the red screen before it copies anything (photograph it), then boots
# xnu (which will not find a root: ignore). A black screen = ABL did not start Enxerto with that size.
#
#   tools/renegade/abl-ramdisk-probe.sh KERNEL ADT [MiB ...]        default sizes: 40 56 72 88
#   -> enxerto/out/enxerto-boot-probeNN.img (run from the main checkout, which has dtb/ and enxerto/out/)
# Evidence so far (NOTES 2026-10-14): a 15.8 MB payload was placed at 0x846F0000-0x855FE3E0, i.e. its end rounded
# to 0x85600000 and its start = 0x85600000 - size rounded up to 64 KiB. If that holds, a payload of N MiB starts at
# 0x85600000 - size: a payload of 86 MiB reaches the DDR base 0x80000000; 206 MiB (the first iOS 18 boot) cannot work.
set -euo pipefail
cd "$(dirname "$0")/../.."
K=$1; ADT=$2; shift 2
SIZES=${*:-40 56 72 88}
for n in $SIZES; do
	head -c $((n * 1048576)) /dev/zero > /tmp/probe-rd-$n.bin
	python3 tools/mkpayload.py "$K" "$ADT" enxerto/out/payload-probe$n.bin --ramdisk /tmp/probe-rd-$n.bin \
		--cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -noprogress rd=md0" | grep -E "^size|ramdisk"
	BOARD=beryllium enxerto/build.sh enxerto/out/payload-probe$n.bin >/dev/null
	cp enxerto/out/enxerto-boot.img enxerto/out/enxerto-boot-probe$n.img
	rm -f /tmp/probe-rd-$n.bin
	sz=$(stat -f %z enxerto/out/payload-probe$n.bin)
	echo "enxerto/out/enxerto-boot-probe$n.img: payload $((sz / 1048576)) MiB, expected INITRD lo = $(printf '0x%X' $((0x85600000 - ((sz + 0xffff) & ~0xffff)))) if the formula holds"
done
