#!/bin/bash
# Build Enxerto (the bootloader) and wrap it in an Android boot.img that ABL accepts.
#   BOARD=sweet (default)  boot.img v2 mirroring the stock PixelOS header, DTB in the header
#   BOARD=beryllium        boot.img v1, Image.gz + appended DTB like the Poco F1 ROM (SDM845 ABL)
# Usage: [BOARD=..] [DTB=..] ./build.sh [payload.bin]
set -euo pipefail
cd "$(dirname "$0")"
BOARD=${BOARD:-sweet}
# Linux cross toolchain if present, else the bare-metal one (Homebrew aarch64-elf-gcc on macOS)
if [ -z "${CROSS:-}" ]; then
	if command -v aarch64-linux-gnu-gcc >/dev/null; then CROSS=aarch64-linux-gnu-; else CROSS=aarch64-elf-; fi
fi
CC=${CROSS}gcc
OBJCOPY=${CROSS}objcopy
READELF=${CROSS}readelf
NM=${CROSS}nm
# BOOTLOG=1 shows the log window at the bottom of the branded boot screen (default: logo only; the
# log is recorded and printed on the text screen when the boot fails).
# -fno-tree-loop-distribute-patterns: no libc, so gcc must not turn loops into memcpy/memset calls (the link would fail).
# -fno-tree-switch-conversion -fno-jump-tables: gcc turns switches (and if/else chains) that pick between pointers into
# tables of pointers, which need ABS64 relocations (refused below).
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-tree-loop-distribute-patterns -fno-tree-switch-conversion -fno-jump-tables -Wall -Wextra"
[ "${BOOTLOG:-0}" = 0 ] || CFLAGS="$CFLAGS -DBOOTUI_LOG=1"
# CHARGER=0 compiles the early fast charging out (charger.c, README); default on. Runtime: boot.img cmdline
# bergamota.charger=0 (off) / =keep (leave the programmed ICL/FCC in place at the kernel hand-off).
[ "${CHARGER:-1}" != 0 ] || CFLAGS="$CFLAGS -DENXERTO_CHARGER=0"
# BOOTPAUSE=<ms>: wait that long before jumping to xnu (debug photos of the log).
[ -z "${BOOTPAUSE:-}" ] || CFLAGS="$CFLAGS -DBOOT_PAUSE_MS=${BOOTPAUSE}"
case $BOARD in
sweet)		DTB=${DTB:-../dtb/boot_unpacked/dtb} ;;
beryllium)	DTB=${DTB:-../dtb/beryllium/dtb}; CFLAGS="$CFLAGS -DBOARD_BERYLLIUM" ;;
*)		echo "error: unknown BOARD=$BOARD" >&2; exit 1 ;;
esac
[ -f "$DTB" ] || { echo "error: $DTB missing (stock DTB of the phone, see README)" >&2; exit 1; }
mkdir -p out
# Bergamota fastboot (docs/BERGAMOTA_FASTBOOT.md): runs by itself when there is no payload; BERGAMOTA=1
# forces it even with a payload in the ramdisk (boot.img cmdline flag), BERGAMOTA=0 keeps the old
# diagnostics/loader path.
CMDLINE="console=null"
case ${BERGAMOTA:-} in
1) CMDLINE="$CMDLINE bergamota.fastboot=1" ;;
0) CMDLINE="$CMDLINE bergamota.fastboot=0" ;;
esac
SRCS="start.S enxerto.c console.c artdraw.c bootui.c fbui.c mmu.c fdt.c loader.c ufs.c inflate.c usb_dwc3.c usb_power.c fastboot.c sparse.c storage.c blake2b.c bergamota.c pmic.c charge.c charge_mode.c charger.c"
OBJS=""
for f in $SRCS; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
	OBJS="$OBJS out/${f%.*}.o"
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r ${OBJS//out\/start.o/} | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T enxerto.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	$OBJS -o out/enxerto.elf -lgcc
$OBJCOPY -O binary out/enxerto.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/enxerto.elf | awk '$3=="_end"{print $1}')
python3 -c "import sys; open(sys.argv[1],'r+b').truncate(int(sys.argv[2],16))" out/Image "$size"
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
if [ "$BOARD" = beryllium ]; then
	# Same layout as the ROM's boot.img: header v1, Image.gz with the DTB
	# appended (ABL gunzips the kernel and finds the DTB behind the stream).
	gzip -9 -n -c out/Image | cat - "$DTB" > out/Image.gz-dtb
	mkbootimg --header_version 1 --kernel out/Image.gz-dtb --ramdisk out/ramdisk.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 --os_version 16.0.0 --os_patch_level 2025-06 \
		--cmdline "$CMDLINE" -o out/enxerto-boot.img
else
	mkbootimg --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "$CMDLINE" -o out/enxerto-boot.img
fi
# Charging-screen test image (docs/BERGAMOTA_CHARGE.md): no payload, cmdline forces charging mode, so
# `fastboot boot out/charge-test.img` shows the off-mode charging screen on a phone that is just on.
(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk-empty.bin)
if [ "$BOARD" = beryllium ]; then
	mkbootimg --header_version 1 --kernel out/Image.gz-dtb --ramdisk out/ramdisk-empty.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 --os_version 16.0.0 --os_patch_level 2025-06 \
		--cmdline "console=null bergamota.charge=1" -o out/charge-test.img
fi
# Host render of the console layout and the boot screen (out/host.ppm, out/preview/*.ppm).
mkdir -p out/preview
cc -O1 -Wall $([ "$BOARD" = beryllium ] && echo -DBOARD_BERYLLIUM) $([ "${BOOTLOG:-0}" = 0 ] || echo -DBOOTUI_LOG=1) -o out/host_test console.c artdraw.c bootui.c fbui.c charge.c host_test.c && ./out/host_test
# Host tests of the fastboot protocol, the sparse parser, GPT/allowlist storage and BLAKE2b (fake storage).
cc -O1 -Wall -Wextra -o out/fastboot_test fastboot.c sparse.c storage.c blake2b.c fastboot_test.c && ./out/fastboot_test
# The image Bergamota (the Mac app) boots from ABL with `fastboot boot`: fastboot forced on, empty ramdisk.
if [ "$BOARD" = beryllium ]; then
	mkbootimg --header_version 1 --kernel out/Image.gz-dtb --ramdisk out/ramdisk-empty.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 --os_version 16.0.0 --os_patch_level 2025-06 \
		--cmdline "console=null bergamota.fastboot=1" -o out/bergamota-fastboot.img
	# same image under the name the Mac app looks for first (the flash-capable build)
	cp out/bergamota-fastboot.img out/bergamota-fastboot-flash.img
fi
# IMGSUFFIX=-chg: also keep the images under suffixed names (never overwrites another build's files)
if [ -n "${IMGSUFFIX:-}" ]; then
	for f in enxerto-boot bergamota-fastboot bergamota-fastboot-flash charge-test; do
		[ -f out/$f.img ] && cp out/$f.img out/$f$IMGSUFFIX.img
	done
fi
ls -l out/Image out/enxerto-boot.img $([ -f out/bergamota-fastboot.img ] && echo out/bergamota-fastboot.img) $([ -f out/charge-test.img ] && echo out/charge-test.img)
