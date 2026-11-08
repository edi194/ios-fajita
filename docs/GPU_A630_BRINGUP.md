# Adreno 630 bring-up on the Poco F1 (GPU phase 1)

Kernel patch `xnu/patches/0103-beryllium-gpu-a630-bringup.patch` (on top of 0102): `bsd/dev/sweet_a630.c` (stages 1-7), `bsd/dev/sweet_a630_pas.c` (TrustZone PAS zap loader), the hook `sweet_a630_probe()` after `sweet_usb_probe()` in `sweet_ufs.c`, two lines in `bsd/conf/files`, and the 64-bit fix of `pmap_sync_page_attributes_phys` in `osfmk/arm/pmap/pmap.c`.
Off by default: nothing runs unless the boot-arg `sweetgpu=N` is given (N = 1..7, larger is clamped), and only when the ADT root compatible is `xiaomi,beryllium`. Every log line starts with `SWEET GPU:`. See also `GPU_KERNEL.md` (stage 8: keep-up + IOKit user client, xnu-11215 patches 0180-0182).
Status: **compiled (Xcode clang, real objects, all undefined symbols are kernel symbols) and `git apply --check` clean against 0001-0102; not run on hardware.**

## Sources and licences

| Source | Use |
|---|---|
| mxtpasontop/ios-sweet, branch `gpu`, patches 0078-0098 (Adreno 618, same XNU/sweet code base, tested on hardware; repository has no licence file, it is a fork of dipa-studio/ios-sweet) | Structure, stage order, the SMMU/GMU/HFI/GX sequences. Rewritten, not pasted; the cmd-db reader (reserved region, not the sweet locator), the stage numbering, the SDM845 values and everything after "zap" are new. |
| Linux v6.6/v6.8 `drivers/gpu/drm/msm/adreno/{a6xx_gpu.c,a6xx_gmu.c,a6xx_hfi.c,a6xx.xml.h,a6xx_gmu.xml.h}`, `drivers/clk/qcom/{gpucc-sdm845.c,gcc-sdm845.c}` (GPL-2.0) | Register numbers and sequences only (facts); no code copied. Every register number in the patch was checked against `a6xx.xml.h`/`a6xx_gmu.xml.h`. |
| `dtb/beryllium/live.dts` (phone live FDT), `research/linux-dts` sdm845.dtsi | Addresses, SMMU stream IDs, clock/GDSC offsets, OPP levels, cmd-db and zap carve-outs. |

## Register / clock / firmware map (SDM845)

| Block | Value | Source |
|---|---|---|
| GPU core | 0x05000000, 0x40000 (register N at byte N*4) | live DT `qcom,kgsl-3d0@5000000`, chipid 0x06030001 |
| GMU | 0x0506a000, 0x30000; RSCC = GMU+0x23000 | live DT `qcom,gmu`, a6xx_gmu.c |
| GPU PDC cfg / seq | 0x0b280000 / 0x0b480000 (live DT pdc 0xb200000 + 0x80000 / + 0x280000; **0xb290000/0xb490000 are SM7150**) | live DT, sdm845.dtsi `gmu_pdc`, `gmu_pdc_seq` |
| gpucc | 0x05090000, 0x9000; CX GDSCR 0x106c (status/hw ctrl 0x1540), GX GDSCR 0x100c (owned by the GMU), GMU RCG cmd 0x1120 cfg 0x1124, CBCRs ahb 0x1078, cx_gmu 0x1098, cxo 0x109c, gx_gfx3d 0x1054 | gpucc-sdm845.c |
| GMU clock | 200 MHz = GPLL0_OUT_MAIN_DIV (source 6) / 1.5: CFG = 0x602; gcc_gpu_gpll0 + gpll0_div votes GCC+0x52004 bits 15/16; `gpu_cc_cx_gmu_clk` wake/sleep nibbles 0xf (CBCR bits 11:4) | gpucc-sdm845.c, gcc-sdm845.c |
| GCC clocks | cfg_ahb 0x71004, memnoc_gfx 0x7100c (GMU "memnoc"), snoc_dvm 0x71018, **ddrss_gpu_axi 0x44038** (GMU "axi"; 0x4452c on SM7150) | gcc-sdm845.c |
| GPU SMMU | 0x05040000, qcom,smmu-v2, 5 SMRs, CBs at +0x8000; impl-defs from the DT (identical to the A618); streams: gfx3d_user SID 0 (CP), gfx3d_secure 1/2, gmu_user 4, gmu_kernel 5 | live DT; **ATOS disabled (`qcom,disable-atos`)** |
| cmd-db | 0x85fe0000, 0x20000 (reserved-memory, mapped read-only by the driver; `gfx.lvl`, `mx.lvl`, `cx.lvl` ARC tables, BCM addresses logged) | live DT |
| Zap carve-out | 0x8c415000, 0x2000 (`gpu_region`, removed-dma-pool, no-map), PAS id 13, name `a630_zap` | live DT `qcom,kgsl-hyp`, sdm845.dtsi `gpu_mem` |
| GPU frequencies | 0 / 257 / 342 / 414 / 520 / 596 / 675 / 710 MHz, RPMh VLVL 64/128/192/256/320/384/416; boot level 257 MHz; GMU 200 MHz = MIN_SVS (48) | live DT pwrlevels, sdm845.dtsi OPP |

### Firmware files

| File | Where |
|---|---|
| `a630_gmu.bin` (<= 0x8000 bytes, raw legacy image loaded at ITCM) | iOS root `/usr/standalone/firmware/sweet/` or ADT `/sweet-gpu gmu-firmware` |
| `a630_sqe.fw` (first 4 bytes are a header; version word must be >= 0x190 or patched, logged) | `.../a630_sqe.fw` or ADT `sqe-firmware` |
| `a630_zap.mdt` + `a630_zap.b00`, `.b01`, `.b02`... (split form; `bNN` = program header index NN) | `.../a630_zap.mdt`, `.../a630_zap.bNN` or ADT `zap-mdt`, `zap-b00`..`zap-b15` |

The loader (`sweet_a630_fw_get`) tries the ADT property first, then `vnode_lookup` + `vn_rdwr` on the file (only once `rootvnode` exists). For stages >= 3 a kernel thread polls every 2 s for `a630_gmu.bin` (boot-arg `sweetgpuwait=SECONDS`, default 600; progress line every minute), then waits 3 s and starts. Stages 1-2 need no firmware and run inline.

### Getting the firmware (not in `backup/`)

`backup/vendor.img` was searched: it is an ext4 whose directory entries contain no `a630*`/`a6xx` names (it holds app/product data, not the ROM's `/vendor`), and none of the other 78 images contains the files (only `boot.img`/`recovery.img` mention the string `a630_zap`). Extract from a running Android on the phone (userdebug ROM, `adb root` works; not done by this work):

```
adb root
adb pull /vendor/firmware/a630_gmu.bin /vendor/firmware/a630_sqe.fw .
adb pull /vendor/firmware/a630_zap.mdt .      # plus a630_zap.b00 .b01 .b02 (ls /vendor/firmware/a630_zap.*)
```

or from a LineageOS beryllium vendor image / the vendor partition mounted read-only in recovery (`/dev/block/mapper/vendor`, `ls /vendor/firmware`). `a630_sqe.fw` and `a630_gmu.bin` also exist in linux-firmware `qcom/` (LICENSE.qcom, redistributable); the zap is signed per device and must come from this phone's vendor image (mainline calls it `qcom/sdm845/Xiaomi/beryllium/a630_zap.mbn`; a single `.mbn` is not read by this loader, split it into mdt + bNN with `pil-squasher` in reverse, or use the downstream files). Put the files into the iOS root before the test:

```
sudo mkdir -p /Volumes/<mounted root>/usr/standalone/firmware/sweet
sudo cp a630_gmu.bin a630_sqe.fw a630_zap.mdt a630_zap.b* /Volumes/<mounted root>/usr/standalone/firmware/sweet/
```

(`tools/mkiosroot-macos.sh` builds the image; copy after `hdiutil attach` with ownership on, as noted in NOTES.md.) ADT alternative: add the properties to a `/sweet-gpu` node with `tools/mkadt.py` (not changed by this work); with them the stages start immediately, without waiting for the root.

## What each stage does

| `sweetgpu=` | Stage | Notes |
|---|---|---|
| 1 | Read-only probe: GCC GPU clocks, gpucc GDSCs and CBCRs; GMU registers only if CX GDSC + cfg_ahb/cxo/cx_gmu are on (a gated block would hang) | ABL leaves the GPU off on SM7150; expect the same here |
| 2 | Power CX GDSC (SW_COLLAPSE off, wait on 0x1540), vote gpll0/gpll0_div, GMU RCG 200 MHz, enable ahb/cxo/cx_gmu/memnoc/ddrss_axi; GMU registers; read-only GPU SMMU dump (SMRs/CBs); ITCM/DTCM write/readback with the GMU held in reset | no RPMh vote (CPUs/UFS/USB already hold CX) |
| 3 | Firmware: GENERAL_7=1, RSC+PDC microcode (cmd-db ARC addresses), RSC wake (new vs A618, non-fatal), raw firmware into ITCM, boot config/fences/chip id (0x06030100), power config, SYSRESET release; wait `FW_INIT_RESULT` (0xbabeface, or 0x100 under mask 0x1ff for newer firmware); GMU back into reset | SMMU untouched: the GMU cannot reach RAM, global faults are logged |
| 4 | 64 KiB WCOMB block for dummy/HFI/dump/log + page tables; GPU SMMU context bank 0, exact SMRs for SIDs 5 and 4 (read back; aborts if they do not stick); HFI v1 queue table; boot; `HFI_CTRL_INIT`, INIT, FW_VER, PERF_TBL (DCVS from cmd-db), BW_VOTE_TBL (Linux a630 fixed table), TEST; GMU back into reset | |
| 5 | 4 + `a6xx_gmu_gfx_rail_on` (boot OOB at 257 MHz), SPTPRAC on, HFI, `oob_gpu`, read GX GDSC/GPU core registers (`RBBM_STATUS`, `CP_ALWAYS_ON`), SPTPRAC off, slumber | first access to GPU core registers |
| 6 | 5 + zap while GX is on: PAS INIT_IMAGE (metadata in contiguous WCOMB memory), MEM_SETUP(0x8c415000, size), copy segments to the carve-out through `ml_io_map`, AUTH_AND_RESET, SHUTDOWN | no crypto/BCM vote (see Changes) |
| 7 | 5 + CP in Linux order: AHB fence ALLOW, SP clock, ~25 `hw_init` writes (64-bit address modes, VBIF, UCHE, ROQ, ring/SQE base), SMMU CB1 + SMR2 (SID 0) with a software-walked table (SQE read-only), `CP_SQE_CNTL=1`, `CP_ME_INIT`; zap load; `CP_SET_SECURE_MODE 0`; NOP + `CP_MEM_WRITE` + `CP_EVENT_WRITE CACHE_FLUSH_TS`; poll RPTR and read back both values from the scratch buffer; zap shutdown, slumber | never claims more than it read back |

Failure policy: every stage returns early; after GX has been voted on, a failed HFI start powers GX down again; if a PAS call did not return, GX/GMU are left as they are until reset (no frees, no new calls); the GMU is always put back into reset at the end.

## Boot-args and expected logs

Add to the shim cmdline (`tools/mkpayload.py ... --cmdline '<existing args> sweetgpu=N ufslogsecs=1'`); read the log with `tools/sweet-log-pull.sh` in recovery after Power+VolDown (see NOTES.md). Always read `ufslogsecs=1` logs of the previous stage before booting the next one.

| Test | Boot-arg | Expected lines |
|---|---|---|
| 1 | `sweetgpu=1` | `SWEET GPU: Adreno 630 bring-up, stage 1 ...`, `GDSC cx 0x... (off ...) gx 0x... (off)`, `CX domain unpowered or unclocked; GMU not read` (or the GMU dump if ABL left it on) |
| 2 | `sweetgpu=2` | `CX GDSC on: gdscr 0xf8...`, `GMU RCG 200 MHz: ... cfg 0x00000602`, `enable cx_gmu ... CBCR 0x00000001` (clock on = bit 31 clear), `SMMU sCR0 ... 5 SMRs`, `ITCM write/readback ok`, `DTCM write/readback ok`, `stage 2 complete` |
| 3 | `sweetgpu=3` + `a630_gmu.bin` | `PDC mx.lvl address 0x30010 (as Linux a630)`, `GMU firmware N bytes loaded, 0 words differ`, `GMU BOOTED (FW_INIT_RESULT ok) after NN us`, `stage 3 complete: GMU firmware boots` |
| 4 | `sweetgpu=4` | `GMU memory at 0x1....`, `SMR0 (GMU) wrote ... reads ...` (equal), `SMMU CB0: SCTLR 0x00c01067`, `HFI up: ... HFI version 0x00000000`, `HFI H2F_MSG_INIT: ACK ... error 0`, `GMU firmware version 0x...`, `HFI start complete (DCVS, BW, TEST acknowledged)` |
| 5 | `sweetgpu=5` | `GX rail on at level 1 (257 MHz)`, `OOB boot_slumber (boot): acknowledged`, `SPTPRAC power on: ok`, `OOB gpu: acknowledged`, `GDSC cx ... gx 0x... (on)`, `RBBM_STATUS 0x...`, `slumber acknowledged: RPMH_POWER_STATE 0xf (slumber)` |
| 6 | `sweetgpu=6` | `zap phdr ...`, `SCM PAS INIT_IMAGE completed=1 status=0 result=0`, MEM_SETUP and AUTH_AND_RESET same, `signed zap authenticated and started`, `zap shutdown complete` |
| 7 | `sweetgpu=7` | `CP before configuration: SQE_CNTL 0 ...`, `CP SQE enabled`, `CP CP_ME_INIT: ring idle (RPTR=WPTR=9)`, zap lines, `CP CP_SET_SECURE_MODE 0: ring idle`, `CP NOP test: CP_MEM_WRITE read back 0x5ee70001 ..., timestamp 0x600d0001`, `CP NOP test PASSED` |

Useful extras: `sweetgpuwait=N` (seconds to wait for the firmware). Test in order; after each stage check the log shows the expected arg and no `TIMED OUT`.

## What carried over from the A618 series and what changed

Carried over unchanged in structure: GDSC/RCG/CBCR sequence, GMU ITCM load and `0xbabeface` handshake, the PDC/RSC microcode words, the GMU stream IDs and SMR/CB scheme (exact SMRs, CB0 for the GMU; the 0083 finding that masked SMRs do not stick), static 3-level page tables in a WCOMB block, VA layout (dummy/HFI/dump/log at 0x6000_0000 + 1 MiB steps), the 4-queue legacy HFI table and v1 message set, the GX-through-GMU path (`HFI_USE_REG`: vote indices in DTCM, OOB bits 22/30 and 16/24), SPTPRAC enable/disable, slumber, SCM SMC64 convention with continuation token, cmd-db ARC parsing, the fixed `0xa7a5...` microcode words.

Changed for SDM845 / a630:

* GCC `ddrss_gpu_axi` 0x44038 (not 0x4452c); GMU PDC at 0xb280000/0xb480000 (not 0xb29/0xb49); no QFPROM speed bin (one DT pwrlevel table: 257-710 MHz); GX VLVLs from the sdm845 OPP table.
* PDC TCS1 cmd2 / TCS3 cmd2 address = `gfx.lvl` from cmd-db (Linux a630: 0x30080, A618: 0x30090) and TCS3 cmd1 data 3 (A618: 2). The log prints whether cmd-db equals the Linux constant.
* Chip id for `HFI_SFR_ADDR` 0x06030100 (A618 0x06018000). `GMU_FW_VERSION` request 1.10 as Linux.
* BW table: Linux's fixed a630 "off" table (3 DDR + 3 CNOC BCM commands) instead of A618's empty one; the log lists the cmd-db addresses of MC0/ACV/SH0/CN* next to it.
* Fence range0 0x802800a0 (Linux non-a7xx; A618 downstream used 0x80a008a0); slumber writes only the option (no GX vote index), as Linux.
* New: RSC wake before the GMU load (Linux `a6xx_rpmh_start`; the A618 flow never reached it and booted without), `CM3` start mask/result selection by DTCM word 0xff8.
* **Zap**: no crypto/BCM bandwidth vote (A618 needed `sweetscm=2..4`, six BCM commands). The beryllium kgsl-hyp node has no bus/clock properties and mainline `qcom,scm-sdm845` has none; this is the biggest assumption (see risks). Image goes to the DT reserved region 0x8c415000 like Linux (A618 used a fresh 1 MiB allocation), segments are parsed from the .mdt program headers instead of the a615 layout.
* **Stage 7 order follows Linux** (CP_ME_INIT before the zap, `CP_SET_SECURE_MODE 0` after), not the A618 session's "zap before CP", which never got past an illegal-instruction fault (their 0097/0098 saw `CP_IRQ 0x80` after writing `SQE_CNTL=3` cold; this driver never writes `SQE_CNTL` except 0 -> 1).
* Cache handling: `sweet_dma_sync_va` (dc civac, from 0102's `sweet_board.h`) around the WCOMB switch and for polled scratch memory; the pmap 64-bit bug fix is included in this patch (the same panic as the A618 0082 would occur: kernel RAM is above 4 GiB here too).
* Not ported (not needed for a power-up/NOP test): HWCG tables, CP_PROTECT, UBWC config, RBBM_SECVID_* writes (secure registers, an XPU violation would reset the SoC), interrupts, per-process page tables, preemption, `CP_WHERE_AM_I`.

## Risks and open questions

1. **SoC hangs/resets.** Any access to a gated block hangs the bus: stage 1/2 read GPU CC only when `gcc_gpu_cfg_ahb` is on, the GMU only with CX + clocks on, GPU core registers only when the GX GDSC is on **and** `gx_gfx3d` runs, and the CP only inside the OOB window. A wrong GMU/PDC value or an SMMU fault during a GMU DMA reset the phone without a panic on A618 (0083: unrouted SMRs). Stage 4 refuses to boot the GMU unless the SMRs read back valid; stage 3 boots with the SMMU untouched on purpose (the firmware does not touch RAM then).
2. **TrustZone/XPU.** AUTH_AND_RESET with a wrong or unsigned zap, a wrong carve-out, or a PAS call that never returns can lock the GPU until reset; a secure-register write by us (deliberately avoided) would reset the SoC. If a PAS call does not return, the driver stops all further calls.
3. **No crypto vote.** If INIT_IMAGE returns non-zero or hangs, the A618 `sweetscm=3` BCM vote (CE0, SN11, SN0, SH0, MC0, ACV; this phone's route 125 -> 512 has the same six BCMs but agg-ports 1/1/1/4/4 for the last three vs sweet's 2/2) is the first thing to add. Not implemented; `sweet_rpmh.c` is hard-coded to the SM7150 RSC address (0x18220000) and would need the SDM845 DRV2 0x179e0000 first.
4. **Fixed BW table** and the **PDC addresses** come from Linux; the log shows cmd-db's view. If `MC0`/`ACV` are not at 0x50000/0x5000c, stop at stage 4 and recompute.
5. **GMU firmware version.** Mainline works with linux-firmware's blobs; the vendor `a630_gmu.bin` may be older/newer (version printed after H2F_MSG_FW_VER, error != 0 aborts). Newer GMU firmware that needs HFI v2 is refused (`HFI v2 firmware`).
6. **CP execution is unproven even on A618.** The A618 work stopped at ring/SQE configuration. Stage 7 may fail at: the SMMU CB/stream setup (`gfx3d_user` could be used by the hypervisor), SQE fetch (read-only mapping, AP[2]), secure-mode behaviour before the zap, UCHE/GBIF configuration being too minimal, or `CACHE_FLUSH_TS` needing more state than `CP_MEM_WRITE`. The log prints RPTR, WPTR, `CP_HW_FAULT`, `CP_INTERRUPT_STATUS`, `RBBM_STATUS`, `CP_STATUS_1`, SMMU CB1 FSR/FAR and sGFSR on any failure.
7. **Firmware wait.** With stage >= 3 and no firmware the GPU stays off and the boot is unaffected except for one kernel thread that polls the root every 2 s (until `sweetgpuwait`).
8. Concurrency: stage >= 3 runs on a thread while iOS userland starts; the GMU/GPU stay idle after the test (GMU in reset, GPU in slumber), so nothing else touches them, but CPU load during the thread's loops is low and `delay()` polls are bounded (<= 100 ms each).
9. After a reboot the GPU SMMU state is whatever ABL leaves; the driver does not undo its SMR/CB programming (the SMMU is kernel-owned and nothing else uses it), so run one stage per boot.
10. The untested ADT path: `/sweet-gpu` properties must come from `tools/mkadt.py` (not modified here).

## Test commands (nothing in this work touches the phone)

```
# patch check (done): git apply --check on a copy of research/bt102/xnu
# per stage, on the PC (adapt the usual image build):
python3 tools/mkpayload.py <kernel> <adt> <payload.bin> --cmdline '<current boot-args> sweetgpu=1 ufslogsecs=1'
BOARD=beryllium shim/build.sh <payload.bin>
fastboot boot shim/out/shim-boot-0103-s1.img        # then Power+VolDown, recovery, tools/sweet-log-pull.sh logs/gpu-s1.txt
grep 'SWEET GPU' logs/gpu-s1.txt
```
