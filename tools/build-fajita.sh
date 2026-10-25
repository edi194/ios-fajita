#!/usr/bin/env bash
# Build the fajita ADT + payload + shim boot image from an XNU CI artifact.
#
#   XNU_KERNEL=xnu/out/kernel.development.sweet DTB=dtb/boot_unpacked/dtb \
#       tools/build-fajita.sh
#
# The stock OnePlus/LineageOS boot.img DTB is required. The boot image header
# fields in shim/build.sh still need to be verified against that stock image.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC1091
. tools/fajita.env

XNU_KERNEL=${XNU_KERNEL:-xnu/out/kernel.development.sweet}
# fajita2 = SDM845 v2.1, the SoC revision this unit reports (qcom,msm-id
# 0x141/0x20001). fajita0 is v2 and fajita1 is v1.
DTB=${DTB:-dtb/boot_unpacked/fajita2.dtb}
ADT=${ADT:-shim/out/fajita.adt}
PAYLOAD=${PAYLOAD:-shim/out/payload.bin}
# Single CPU for now: the boot used to stop right after "vm_set_restrictions ok"
# because kperf_init_early() -> ml_wait_max_cpus() waited for ml_set_max_cpus()
# and SweetCPU never started (patch 0086 fixes the match). cpus=1 + sweetsmp=0
# keep the PSCI CPU_ON and the SGI self-test out of the way until the boot
# reaches userland; raise both once the root mount works.
# nointr_consio=1: console_io_allowed() (osfmk/console/serial_console.c) panics
# on any printf from an interrupt-disabled context once startup_phase reaches
# STARTUP_SUB_EARLY_BOOT. Early bring-up prints a lot from such contexts, and
# the guard is what made the stamped kernel panic in kernel_bootstrap_thread
# right before stock xnu calls spllo().
# sweetfb_noconsole is deliberately NOT set: it mutes the framebuffer console
# from the first GUI swap on (patch 0067), which hides everything after
# AppleCLCD presents (BSD init, root mount). The panel is the only console.
# sweetfb_console=1 (patch 0083, from ios-topaz 0120) goes further and skips
# the GUI surface copy in AppleCLCD::present(), so the panel keeps the kernel
# text console instead of being overwritten by a swap.
# sweetecon=1 (patch 0084) draws every console character with the lock-free
# bootstrap console (osfmk/arm64/sweet_early.c, write-combining panel alias):
# no console ring, no VC/AppleCLCD drawing, no locks, no interrupts. This is
# what makes the panel log survive whatever stalls the normal console path.
# The persistent log (patch 0047, sweetlog, on by default) keeps the whole
# console stream in a 4 MiB ring in the last 1025 blocks of userdata; read it
# without filming: fastboot boot <recovery.img> -> adb wait-for-device ->
# tools/sweet-log-pull.sh out.txt -> adb reboot bootloader.
#
# Defaults below are the usable configuration reached on 2026-10-23: eight
# cores, the D22 identity, GUI on the panel (sweetfb_noconsole mutes the console
# at the first swap), RMI4 touch and the PM8998 keys. Diagnostic switches for
# the touch bring-up: sweetfb_console=1 (keep the console on the panel instead
# of the GUI), sweetts_nogpio/noclk/nose/norail=1, sweettouchdelay=<s>.
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=8 sweetsmp=1 keepsyms=1 -noprogress nointr_consio=1 rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=10 sweetecon=1 sweetfb_noconsole=1 sweetlog=1 sweettouch=1 sweetts=1 sweettouchdelay=20 sweetkeys=1 rpmhrsc=0x179e0000 rpmhtcs=0x179e0d00"}

[[ -f "$XNU_KERNEL" ]] || { echo "missing XNU kernel: $XNU_KERNEL" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing stock DTB: $DTB (unpack the OnePlus boot.img first)" >&2; exit 1; }

mkdir -p shim/out
python3 tools/mkadt.py "$ADT" --highmem
# Firmware the drivers want before there is a root travels in the payload, not
# in git: mkpayload.py --blob announces each file as sweetfwN=<pa>:<size>.
BLOB_ARGS=()
for f in ${GPU_FW:-$HOME/gpu-fw/a630_gmu.bin}; do
	[[ -f "$f" ]] && BLOB_ARGS+=(--blob "$f")
done
# A second blob: 64 KiB of zeroes, the memory the GMU reaches through the GPU
# SMMU (page tables, dummy, HFI, dump, log). Nothing of it is committed.
GMEM_BLOB=${GMEM_BLOB:-$HOME/gpu-fw/gmem.bin}
SQE_FW=${SQE_FW:-$HOME/gpu-fw/a630_sqe.fw}
ZAP_MDT=${ZAP_MDT:-$HOME/gpu-fw/a630_zap.mdt}
ZAP_SEG=${ZAP_SEG:-$HOME/gpu-fw/a630_zap.b02}
# 160 KiB, rebuilt every time so it cannot go stale:
#   +0x00000 GMU firmware block (64 KiB)
#   +0x10000 CP block: L1, L2, L3, ring (0x14000), SQE (0x1c000), scratch (0x24000)
#   +0x25000 zap metadata (.mdt), +0x27000 its loadable segment (b02)
mkdir -p "$(dirname "$GMEM_BLOB")"
dd if=/dev/zero of="$GMEM_BLOB" bs=1024 count=208 status=none
# The SQE microcode, without its four-byte header (Linux loads from byte 4).
if [[ -f "$SQE_FW" ]]; then
	tail -c +5 "$SQE_FW" | dd of="$GMEM_BLOB" bs=1024 seek=112 conv=notrunc status=none
	echo "gmem: $(stat -c%s "$SQE_FW") bytes of sqe microcode at +0x1c000"
else
	echo "gmem: WARNING no $SQE_FW - the CP will not be able to fetch" >&2
fi
# The zap: only the .mdt and the single loadable segment (a630_zap.b02) are used.
if [[ -f "$ZAP_MDT" && -f "$ZAP_SEG" ]]; then
	dd if="$ZAP_MDT" of="$GMEM_BLOB" bs=4 seek=$((0x25000 / 4)) conv=notrunc status=none
	dd if="$ZAP_SEG" of="$GMEM_BLOB" bs=4 seek=$((0x27000 / 4)) conv=notrunc status=none
	echo "gmem: zap mdt $(stat -c%s "$ZAP_MDT") + segment $(stat -c%s "$ZAP_SEG") at +0x25000"
else
	echo "gmem: WARNING no zap files - stage 7c will report them missing" >&2
fi
BLOB_ARGS+=(--blob "$GMEM_BLOB")
# A third blob: the buffer arena the ABI hands out (sweetfw2). kmem_alloc_contig is
# unusable for GPU memory here: this port keeps pages below gPhysBase on its free
# lists and any pmap call on one panics (console80).
ARENA_BLOB=${ARENA_BLOB:-$HOME/gpu-fw/arena.bin}
if [[ ! -f "$ARENA_BLOB" || $(stat -c%s "$ARENA_BLOB" 2>/dev/null || echo 0) -ne 1048576 ]]; then
	mkdir -p "$(dirname "$ARENA_BLOB")"
	dd if=/dev/zero of="$ARENA_BLOB" bs=1024 count=1024 status=none
fi
BLOB_ARGS+=(--blob "$ARENA_BLOB")
# A fourth blob: the GPU page-table pool (stage 8f). 64 L3 tables of 4 KiB, each covering
# a 2 MiB chunk of client address space.
PTE_BLOB=${PTE_BLOB:-$HOME/gpu-fw/pte.bin}
if [[ ! -f "$PTE_BLOB" || $(stat -c%s "$PTE_BLOB" 2>/dev/null || echo 0) -ne 262144 ]]; then
	mkdir -p "$(dirname "$PTE_BLOB")"
	dd if=/dev/zero of="$PTE_BLOB" bs=1024 count=256 status=none
fi
BLOB_ARGS+=(--blob "$PTE_BLOB")
python3 tools/mkpayload.py "$XNU_KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE" "${BLOB_ARGS[@]}"
# shim/build.sh cds into shim/, so hand it absolute paths. SHIM_HDR=1 is the
# stock fajita layout (header v1, gzipped Image.gz-dtb): a v2 header with a dtb
# section and a raw Image does not boot on this ABL.
SHIM_HDR=1 DTB=$(realpath "$DTB") shim/build.sh "$(realpath "$PAYLOAD")"

echo "built: shim/out/shim-boot.img"
