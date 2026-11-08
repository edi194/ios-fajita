# Wi-Fi and Bluetooth on the Poco F1 (SDM845, WCN3990): design and first steps

Date 2026-10-20. Status: research + a draft probe patch; nothing here has run on the phone.
Every claim is tagged **[V]** verified (checked in a file in this repo, in the phone backups, in the
Linux source I fetched, or in the IPSW), **[V-topaz]** verified only as "what ios-topaz does on SM6225",
or **[U]** unverified (from memory or inference, needs a hardware test).

Draft code: `research/wifi-draft/0104-beryllium-wlan-bt.patch` (diff against `research/bt102/xnu`,
`git apply --check` clean, each touched file compiles clean with `tools/xnu-cc.py`, new FAT/ELF code
host-tested against `backup/modem.img` and `backup/bluetooth.img`). Section 7.

## 0. Answers in short

* **Bluetooth does not need the modem.** [V] WCN3990 BT is a UART HCI device; Linux (`hci_qca.c`,
  `qca_regulator_init`) powers it with four regulators and two single-byte "power pulses" sent over the
  UART (0xC0 off at 2400 baud, 0xFC on at 115200 baud, flow control off). No MSS, no QMI, no GPIO
  enable on this board (the beryllium `bluetooth` node has only the four supplies and `max-speed`).
  Firmware (`crbtfw21.tlv`, `crnv21.bin`) is in the `bluetooth` partition [V]. This is the cheap first win.
* **Wi-Fi does need the modem (MPSS).** [V] On SDM845 the WCN3990 WLAN firmware (`wlanmdsp.mbn`) runs
  inside a protection domain of the modem DSP and is reached through QMI service 0x45 (WLFW) over QRTR over
  GLINK-SMEM. Linux `ath10k_snoc`: `wifi@18800000` compatible `qcom,wcn3990-wifi`.
* **MSS boot on SDM845 is MBA + self-authentication, not PAS.** [V] `sdm845_mss` in
  `qcom_q6v5_mss.c`: `need_mem_protection = true`, `need_pas_mem_setup = false`, `has_alt_reset = true`,
  `version = MSS_SDM845`; the live downstream DT node says `qcom,pil-self-auth` and
  `qcom,mem-protect-id = <0x0f>` (VMID 15 = MSS_MSA). So **topaz's PAS SCM calls (init_image /
  mem_setup / auth_and_reset, PAS id 4) do not apply**; the TrustZone work reduces to hyp-assign
  (`qcom_scm_assign_mem`, SCM svc 0x0C cmd 0x16, which topaz already implements for rmtfs/MSA).
* **iOS side:** the stock iPhone10,3 stack is IO80211Family + AppleBCMWLANCore (PCIe Broadcom) for Wi-Fi
  and AppleBluetoothModule + AppleConvergedIPCOLYBTControl for BT [V, kernelcache strings]. None of these
  kexts exist in our source-built XNU, and IO80211Family is closed. The pragmatic route is an Ethernet-like
  `en0` for configd (same trick as `ue0`), not an Apple80211 emulation. Details in section 4.

## 1. Wi-Fi dependency chain on SDM845

Order of operations, with what each layer needs. Register bases are from the live downstream DT
(`dtb/beryllium/live.dts`) and the mainline `sdm845.dtsi` / `sdm845-xiaomi-beryllium-common.dtsi` in
`research/linux-dts`; where the two disagree the beryllium dtsi override wins (it matches the live DT).

### 1.1 Memory map (carve-outs) [V live DT == beryllium dtsi]

| Region | Base | Size | Notes |
|---|---|---|---|
| SMEM | 0x86000000 | 0x200000 | `smem@86000000`, hwlock = TCSR mutex 3 (live DT `hwlocks = <.. 0x03>`) |
| cmd-db | 0x85fe0000 | 0x20000 | RPMh resource addresses |
| MPSS | 0x8e400000 | 0x7800000 | beryllium override (mainline default 0x8e000000 is wrong here) |
| WLAN MSA | 0x8e300000 | 0x100000 | `wlan_msa_mem`, live DT `wlan_fw_region` |
| MBA | 0x96900000 | 0x200000 | `mba_region` |
| rmtfs | allocated by the kernel; beryllium dtsi puts it at 0xf6301000 size 0x200000 | | client id 1, vmid MSS_MSA. Live DT: `qcom,rmtfs_sharedmem` (uio, dynamic) |
| IPA fw / GSI | 0x8c400000 / 0x8c410000 | | only if IPA is brought up (not needed for WLAN) |

The MPSS image in the phone's own `modem` partition is linked at exactly 0x8e400000..0x95c00000
(120 MiB) [V, host test below], so the carve-out and the firmware agree; the hash segment is program
header 1 (paddr 0x95c00000, 0x1ce8 bytes, in `modem.b01`) and the image is flagged RELOCATABLE.
All of this memory is already outside the kernel's RAM map (kernel RAM starts at 0x100000000 + the high
bank, NOTES.md), so we never touch it by accident [V].

### 1.2 MSS (modem DSP) boot, MBA method [V Linux, U on this TZ]

From `qcom_q6v5_mss.c` (sdm845 entry) and the DT:

1. Power domains/rails: CX, MX, MSS (RPMh power domains = RPMh requests, same client as the touch L11C vote
   but different resources: `cx.lvl`, `mx.lvl`, `mss.lvl`) [V].
2. Clocks (GCC, base 0x100000): `gcc_mss_cfg_ahb` 0x8a000, `gcc_mss_q6_memnoc_axi` 0x8a154,
   `gcc_boot_rom_ahb` 0x38004, `gcc_mss_gpll0_div_clk_src` (vote 0x52004 bit 17), `gcc_mss_snoc_axi`
   0x8a150, `gcc_mss_mfab_axis` 0x8a004, `gcc_prng_ahb` 0x34004, plus XO [V gcc-sdm845.c].
3. AOSS QMP message (`qcom,qmp = <&aoss_qmp>`, "mss_restart"-style resets: `AOSS_CC_MSS_RESTART`) and PDC
   sync reset (`PDC_MODEM_SYNC_RESET`, live DT `pdc_sync` 0xb2e0100, restart reg 0xc2b0000) [V names, U sequence].
4. `qcom,halt-regs = <&tcsr_regs_1 0x3000 0x5000 0x4000>` (TCSR 0x1f60000: halt_q6 0x1f63000, halt_modem
   0x1f65000, halt_nc 0x1f64000 in the live DT) [V].
5. QDSP6 block 0x4080000 (0x408 bytes), RMB block 0x4180000 (0x48 bytes) [V]. **Do not read these before
   the MSS is out of reset: it can hang the bus (topaz's note about a register read hanging the bus after
   WLFW applies to WLAN regs; for QDSP6/RMB this is [U] but treated the same).**
6. Load `mba.mbn` (238304 bytes in our partition [V]) into the MBA carve-out, hyp-assign it to MSS_MSA,
   write its address to `RMB_MBA_IMAGE_REG` (0x00), release the Q6 reset, wait for `RMB_PBL_STATUS` = 1 and
   `RMB_MBA_STATUS` = XPU_UNLOCKED (1) [V Linux].
7. Metadata: ELF header + program headers + hash segment (`modem.mdt` is 8412 bytes with the hash in
   `modem.b01`, so it is "split") into a DMA buffer, hyp-assign HLOS->MSS_MSA, write phys to
   `RMB_PMI_META_DATA_REG` (0x10), command `RMB_CMD_META_DATA_READY` (1), wait status 3
   (META_DATA_AUTH_SUCCESS), take the buffer back [V Linux].
8. MPSS segments: hyp-assign the whole 0x7800000 region to HLOS+MSS_MSA, copy `modem.bNN` files to their
   `p_paddr`, tell the MBA the code start/length (`RMB_PMI_CODE_START/LENGTH`), command `LOAD_READY` (2),
   wait status 4 (AUTH_COMPLETE, 10 s timeout), then the modem raises SMP2P "ready" [V Linux].
9. TZ/SCM needs on SDM845: **only hyp-assign** (`qcom_scm_assign_mem` -> SCM svc 0x0C cmd 0x16; topaz's
   `scm_assign_to_modem()` is that call) [V Linux + V-topaz]. No `pas_init_image`. Whether this phone's TZ
   uses the SMCCC encoding `0x42000000 | svc<<8 | cmd` that topaz uses [V-topaz on SM6225] or legacy SCM
   calling convention: mainline sdm845 uses SMCCC; **[U]** until the first SMC returns.
10. The phone's QHEE hypervisor sits above this: MPSS/MBA registers and XPU regions are protected, and
    unmatched SMMU streams reset the SoC (forks survey A1, [V-topaz/anonbeat1]). Keep every step
    gated and logged; first boot of the modem is the riskiest step of the whole project.

### 1.3 SMEM, SMP2P, GLINK, QRTR [V Linux dtsi, V-topaz logic]

* SMEM at 0x86000000, table ("$TOC") at `base + size - 0x1000`, partitions "$PRT" (host 0<->1 = apps<->modem)
  with the Linux `smem_private_entry` layout; allocation under TCSR mutex 3 (`0x1f40000 + 3*0x1000`),
  owner id 1 (HLOS) [V Linux layout; topaz uses the same layout and TCSR stride 0x1000].
* SMP2P: SMEM items 435 (modem->apps, "slave-kernel": bit0 fatal, bit1 ready, bit2 handover, bit3
  stop-ack, bit7 shutdown-ack) and 428 (apps->modem, "master-kernel") [V dtsi `qcom,smem = <435>, <428>`
  for smp2p-mpss]. Extra entry "ipa" on the same items must be answered (valid + "AP IPA power off") or the
  modem starves [V-topaz]. Doorbell: apcs_shared (0x17990000) mailbox bit 14 -> IPC register
  0x1799000c bit 14 (live DT qmp node uses 0x1799000c) [V reg, U that bit 14 is SMP2P: dtsi says
  `mboxes = <&apss_shared 14>` for smp2p-mpss, so V].
* GLINK-over-SMEM: edge "mpss", remote pid 1, IRQ SPI 449 (dtsi) / live 0x1c1 = 449 [V], doorbell bit 12
  (`mboxes = <&apss_shared 12>` [V]). SMEM items 478 (descriptor), 479/480 (FIFOs) [V-topaz on SM6225; the
  item numbers are SoC-independent in Linux's `qcom_glink_smem` (`qcom,glink-smem` uses `smem_alloc` of
  478 + 479/480) -> [U] for SDM845 until probed]. Channel "IPCRTR" carries QRTR (live DT
  `qcom,modem_qrtr` channels "IPCRTR"; intents 0x800x5, 0x2000x3, 0x4400x2) [V].
* QRTR: node ids: apps = 1 [V-topaz]; control port 0xfffffffe; services announced with NEW_SERVER.

### 1.4 Host services the modem expects [V-topaz, V Linux userspace daemons]

The Linux userspace trio is replaced in the kernel by topaz (0121):
* **pd-mapper** (QMI servreg-locator 0x40 v0x101): maps "wlan/fw" to `msm/modem/wlan_pd`.
* **tqftpserv** (QRTR service 4096): serves `/readonly/firmware/image/...` (here: `wlanmdsp.mbn`, a
  3645892-byte file in `modem:image/` [V]) and swallows `/readwrite/...` in RAM.
* **rmtfs** (QMI service 14): the modem's EFS from `modemst1`, `modemst2`, `fsc`, `fsg`
  (`/boot/modem_fs1`, `modem_fs2`, `modem_fsc`, `modem_fsg`), through a shared buffer that is
  hyp-assigned to MSS_MSA (+ HLOS, +NAV 0x2b in topaz) [V-topaz]. All four partitions exist in
  `backup/` (modemst1/2 8 MiB, fsg 8 MiB, fsc 256 KiB) [V]. **Rule: reads only. Writes must be dropped
  (topaz counts and drops them); a modem that cannot write its EFS may starve `modem_cfg`; that is
  acceptable, bricking the IMEI/calibration (modemst/fsg/fsc are NV storage) is not.**
* There is no modem-side need for the SIM/IPA/data path for WLAN, but the PD restart handling (topaz 0124)
  matters: the WLAN PD can come up after pd-mapper answers and restart once.

### 1.5 WLFW QMI handshake and WLAN data path [V Linux ath10k, V-topaz]

ath10k `qmi.c` order (topaz 0122 mirrors it): `ind_register` -> `host_cap` -> `msa_info` (+ hyp-assign the
MSA region 0x8e300000 to the WLAN VMIDs 0x18/0x19 = WLAN / WLAN_CE) -> `msa_ready` -> `cap` -> MSA_READY
indication -> board data (BDF) download -> `cal_report` -> FW_READY indication -> `wlan_cfg` (CE layout)
-> `wlan_mode` mission.
Differences that matter on SDM845:
* beryllium sets `qcom,snoc-host-cap-skip-quirk` [V dtsi]: **the host_cap message is skipped** (SDM845 modem
  firmware rejects it). Topaz sends it.
* Board data: ath10k loads `board-2.bin` keyed by `qcom,calibration-variant = "xiaomi_beryllium"` [V dtsi];
  the phone also carries stock BDFs in `modem:image/` (`bdwlan.*` 29 files, `bdf_*.bin` 5 files [V host
  test]). The topaz-style fallback chain (`bdwlan.bNN` / `bdwlan.NNN`) is the simpler first try, with the
  board id from the `cap` response.
* Copy engines: WCN3990 `ce0_base_address = 0x00240000` [V ath10k hw.c] relative to the WLAN membase, which
  is **0x18800000 (size 0x800000)** here [V dtsi `reg-names = "membase"`, live DT `qcom,icnss@18800000`]; so
  CE0 = 0x18a40000. Topaz's constants `0xC800000 + 0x240000` and shadow regs at `+0x32000` translate by
  swapping the base [V-topaz offsets; shadow offset U].
* 12 CE interrupts: SPI 414..425 (dtsi) = live DT 0x19e..0x1a9 = 414..425 [V]. Polling is enough for the
  first milestone (topaz polls).
* **SMMU:** the WLAN DMA stream is `iommus = <&apps_smmu 0x0040 0x1>` [V dtsi and live DT `0x2f 0x40 0x01`],
  apps_smmu at 0x15000000, 0x80000 [V]. Topaz used an identity context bank for stream 0x1A0; here SID
  0x40 mask 1 (0x40 and 0x41). The reusable parts are `sweet_smmu.c` plus anonbeat1's trick of re-pointing an
  *existing* matching SMR instead of adding a second one [V survey]. The live DT also says
  `qcom,iommu-dma-addr-pool = <0xa0000000 0x10000000>` and `qcom,iommu-dma = "bypass"`, i.e. Android
  maps WLAN buffers in an IOVA pool; an identity map of our DMA pool is the simple equivalent.
* HTC (ready, connect `HTC_SVC_WMI_CONTROL` 0x0100 and `HTT_DATA` 0x0300, setup-complete), WMI TLV
  (service ready -> init -> ready), HTT setup (version, frag bank, rx ring, aggr; without the rx ring no
  beacon reaches the firmware [V-topaz 0125]) are protocol-level and **identical** to topaz because both
  are ath10k WCN3990-family snoc targets [V-topaz, V ath10k].

## 2. What carries over from topaz (patches 0113-0126) and what changes

Source: https://github.com/MakrSas/ios-topaz (no LICENSE: port by re-implementation with attribution, do
not paste; I only read the patches and describe them). Reuse estimate 60-70 % of the logic.

| Topaz | Carries over | Changes for SDM845 |
|---|---|---|
| 0113 PAS boot | SMEM walk, SMP2P out/in items 428/435, "ipa" answer, `smc()` wrapper with INTERRUPTED resume, pool allocator, mapping rules (WC mapping for modem-shared memory, below 0xF0000000 for TZ/modem) | **Replace PAS with MBA/RMB flow** (1.2). SMEM base 0x86000000, TCSR mutex 0x1f40000, APCS IPC 0x1799000c, MPSS 0x8e400000/0x7800000, MBA 0x96900000. Pool must sit in memory the kernel does not use and the MSS may be given: use a carve-out below 4 GiB, **[U] which RAM is free** (kernel starts at 0x100000000, so 0x80000000..0xf0000000 outside the reserved list is available; pick above 0xb0400000 [V, NOTES: fixed carve-outs end below 0xb0400000] e.g. 0xe0000000 as topaz did). |
| 0115 firmware from modem_a | read-only partition access through `sweet_ufs` | Partition is `modem` (no A/B suffix) [V GPT names in backup]; topaz hardcodes file extents from a host script (`fwtable_all.py`). **We do not need that: our draft reads FAT16 directly** (bytes/sector 4096, 4 sectors/cluster, 12283 clusters; 8.3 names) [V host test]. Already in the patch (`sweet_ufs_read_part`). |
| 0116/0117 split hash | hash segment from its own `.bNN` | Same layout here (hash = ph1, in `modem.b01`, 0x1ce8 bytes) [V]. |
| 0118 GLINK + QRTR | whole FIFO/intent engine, QRTR HELLO/NEW_SERVER | GLINK doorbell bit 12, SMEM items [U 478-480], remote pid 1, SPI 449 if interrupts are used. |
| 0121 host services | pd-mapper, tftp, rmtfs state machines, QMI TLV helpers, hyp-assign | Paths: `/readonly/firmware/image/<x>` -> `modem:image/<x>`; rmtfs from `modemst1/2`, `fsc`, `fsg` (same names as topaz uses [V]). The rmtfs shared region lives in our pool. |
| 0122 WLFW | the sequence (above) | skip `host_cap` (quirk), MSA 0x8e300000, board data from `bdwlan.*`/`bdf_*.bin` or Linux board-2.bin. |
| 0123 scan | CE, HTC, WMI TLV | CE base 0x18a40000, SMMU SID 0x40/0x41, 4 vdevs/33 peers resource config is SoC-independent for WCN3990. |
| 0124/0125/0126 | restart handling, HTT rx ring, scan API | none |

What does not carry over: any 0080-0091 SM6225 board code, the HyperOS firmware tables, the 0x4AB00000 carve-out.

## 3. Bluetooth path (independent of the modem) [V]

* **Controller:** WCN3990 (`qcom,wcn3990-bt`), HCI over UART, `max-speed = <3200000>` (the Linux operating
  speed is 3000000 for QCA_WCN3990 in `hci_qca.c`).
* **UART:** `&uart6` = `serial@898000` = QUP wrap0 **SE6**, compatible `qcom,geni-uart`, IRQ SPI 607,
  4-pin (CTS gpio45, RFR gpio46, TX gpio47, RX gpio48, function `qup6` = mux 1, EAST tile at TLMM
  0x3500000) [V dtsi + pinctrl-sdm845.c]. Live DT (downstream): `qcom,qup_uart@0x898000`
  `qcom,msm-geni-serial-hs`, `status = "ok"` [V]. (Note: SE6 of **wrap0** at 0x898000 is not the touch
  controller's "SE6" in NOTES.md, which is wrap1 SE6 at 0xa98000 = I2C14.)
* **Clocks (GCC):** wrap0 m_ahb CBCR 0x17004 (vote 0x5200c bit 6), s_ahb 0x17008 (bit 7), S6 branch 0x17750
  (bit 16), S6 RCG 0x17754. On SDM845 the SE root clocks are **DFS-capable** (hardware 0116hw: DFS off, plain RCG, programmed by 0118, section 7b) (mainline registers them with
  `qcom_cc_register_rcg_dfs`); our touch driver already depends on this (reads RCG+0x14 and level cfg at
  +0x1c) [V code]. The draft reads the DFS table and picks a level/divider per baud (14.7456 MHz
  levels give exact 115200 and 2400 baud) [U until the table is dumped; the probe stage does that].
* **Power:** `vddio` = `vreg_s4a_1p8` (fixed, always on: do not vote), `vddxo` = `ldoa7` 1.8 V, `vddrf` =
  `ldoa17` 1.304 V, `vddch0` = `ldoa25` 3.3 V (3.300-3.312) [V dtsi]. RPMh VRM resource names in cmd-db:
  `ldoaN`/`smpaN` (PM8998 "a") [U, the probe prints the lookups]. The RPMh client we already have
  (`sweet_rpmh.c`, ACTIVE TCS vote of ENABLE/VOLTAGE/MODE) generalises: SDM845 apps RSC drv2 at
  0x179e0000, tcs offset 0xd00, ACTIVE 2 [V dtsi + NOTES]; cmd-db at 0x85fe0000 [V]. Same VRM register offsets
  (voltage 0, enable 4, mode 8) and PMIC4 LDO HPM = 7 [U for PMIC4, V for the offsets in Linux
  rpmh-regulator].
* **Bring-up protocol** (`hci_qca.c` `qca_regulator_init` + `qca_send_power_pulse`, `btqca.h`): rails on;
  UART 2400 baud, HW flow control off, send 0xC0 ("power off" forces boot mode); UART 115200, flow off, send
  0xFC ("power on"), wait 100 ms; reopen port with flow control. Then `qca_setup`: HCI vendor
  `0xFC00` param `0x19` (EDL_PATCH_VER_REQ) returns product id / patch / rom version / soc id; firmware
  `crbtfw%02x.tlv` + `crnv%02x.bin` chosen from the rom version; download in TLV segments over `0xFC00`
  commands; change baud with a vendor command; set BD address (`0xFC14`).
* **Firmware location:** partition `bluetooth` (FAT16, 1 MiB image in `backup/bluetooth.img`) contains
  `image/crbtfw21.tlv` (222988 bytes), `crnv21.bin` (4591), `crbtfw20.tlv`, `crnv20.bin`,
  `crbtfw11.tlv`, `crnv11.bin`, `apbtfw10/11.tlv`, `apnv10/11.bin` [V host test]. `crbtfw21`/`crnv21` are
  the ones the WCN3990 rom 2.1 uses [U which rom version this unit has: stage 2 reads it].
  BT/WLAN MAC addresses are in `persist` under `wlan_bt/` (`bt.mac`, `wlan.mac`) [V listing only]; this
  document does not reproduce values. iOS already gets a synthetic `mac-address-bluetooth0` in the ADT [V NOTES].
* **ch1tmdgus/ios-v60** (LG V60, SM8250, QCA6390 BT) is a *template for diagnostics only*: guarded SE6 UART
  clock bring-up, FIFO loopback, RPMh supplies, QCA HCI version query [V survey doc]. Different chip: QCA6390
  needs a `bt_en`/`sw_ctrl` GPIO and no power pulses; WCN3990 is the reverse. I did not fetch its commits
  7f4d96f24, 2adc1cc5c, 74c6aa95d beyond the survey's description; fetch them before extending the UART code.
* **UART-level facts used in the draft** [V qcom-geni-se.c / qcom_geni_serial.c]: protocol id in
  `GENI_FW_REVISION_RO` (0x68) bits 15:8 = 2 for UART; polled FIFO TX = write `SE_UART_TX_TRANS_LEN` (0x270),
  `SE_GENI_M_CMD0` (0x600) = `1 << 27`, words into 0x700, wait M_IRQ_STATUS (0x610) CMD_DONE; RX = `S_CMD0`
  (0x630) `1 << 27`, read 0x780 with the word count / last-valid-bytes in 0x804; stale count 160 at 0x294;
  baud = SE clock / (32 * divider) with divider in `GENI_SER_M/S_CLK_CFG` (0x48/0x4c) bits 15:4 and the DFS
  level in `SE_GENI_CLK_SEL` (0x7c); CTS ignore bit = bit 1 of `SE_UART_TX_TRANS_CFG` (0x25c).
  The SE must already have the UART protocol firmware: on SDM845 the QUP firmware (partition `qupfw`) is loaded
  by the boot chain, mainline relies on that; the probe/stage 2 check the protocol id and **stop** otherwise
  [U that ABL leaves SE6 loaded: the touch SE (wrap1 SE6) was "GSI-only" when we found it, so SE ownership
  differs per engine].

## 4. The iOS side

What I could verify:
* The iPhone10,3 kernelcache contains `com.apple.iokit.IO80211Family`, `AppleBCMWLANCore` /
  `AppleBCMWLANCoreV3` / `AppleBCMWLANBusInterfacePCIe` (match on a PCIe `wlan` node), `BCMWLANFirmware4357`,
  `AppleBluetooth`, `AppleBluetoothModule`, `AppleConvergedIPCOLYBTControl`, `AppleBluetoothDebug(Service)`
  [V strings of the IPSW kernelcache]. The dyld shared cache references `Apple80211`, `IO80211Controller`,
  `IO80211SkywalkInterface`, `IO80211InterfaceInfo`, `com.apple.wifid` [V strings]. iOS 16 Wi-Fi is a
  Skywalk interface: wifid/MobileWiFi -> Apple80211 ioctl/IOKit user client on the 802.11 interface
  (en0). bluetoothd already starts in our boots [V NOTES: "bluetoothd ... run"].
* configd/MobileGestalt wait for an `IONetworkController` for the Wi-Fi address, and the earlier fix was a
  synthetic ADT `/chosen mac-address-wifi0` [V NOTES]. So **the Wi-Fi address is already answered; what is
  missing is an actual interface.**
* The kexts above are not loaded by our kernel (it is source-built XNU with the sweet drivers compiled in) and
  IO80211Family is not in the open XNU source [V repo layout]. We cannot "just load" Apple's driver stack:
  AppleBCMWLAN speaks PCIe to a Broadcom chip.

Options (smallest first):
1. **Ethernet-like `en0` over WLAN (recommended path to "internet").** Kernel brings up the WCN3990 (section 1),
   joins one configured network with an in-kernel WPA2-PSK supplicant (or open network for the very first
   test), and exposes an ifnet `en0` (IFT_ETHER, 802.3 framing converted to 802.11 data frames) plus the
   `IONetworkInterface`/`IOEthernetController` stand-ins from the `ue0` plan (anonbeat1 0092: IOKit objects
   with `IOBuiltin`, `BSD Name`, `IOInterfaceNamePrefix`, controller `IOMACAddress`, `SelfNamed` under a
   bus) so configd's `SCNetworkInterface` sees it [V survey D1 + NOTES; unproven on hardware]. iOS then
   shows "no Wi-Fi UI" but traffic works. Cost: supplicant (4-way handshake, AES-CCM in WCN3990 firmware via
   WMI key install: the firmware does the crypto when keys are installed through `WMI_VDEV_INSTALL_KEY`),
   auth/assoc over WMI mgmt TX, DHCP is iOS's. **[U]**: WMI mgmt TX path and key install are not in topaz
   (it is receive/scan only).
2. **Scan-only Wi-Fi list (cheap demo).** Topaz 0126's `scan + BSS list` API plus a *private* tool would show
   networks, but Settings -> Wi-Fi will not show them without the Apple80211 interface (option 3).
3. **Apple80211 emulation** so Settings -> Wi-Fi lists networks: implement an IO80211-family-compatible
   interface exposing the Apple80211 ioctl selectors wifid uses (SCAN_REQ/SCAN_RESULT, SSID, BSSID, CHANNEL,
   RSSI, STATE, ASSOCIATE, POWER, SUPPORTED_CHANNELS, ...; hundreds of selectors) and the Skywalk
   `IO80211SkywalkInterface` handshake. No source exists; the selector list would have to be derived by
   disassembling wifid/`Apple80211.framework`/MobileWiFi from the dyld cache [U: effort and feasibility].
   Not worth starting before option 1 works.
4. **Bluetooth in iOS:** bluetoothd expects the BT stack from `AppleBluetoothModule`/`AppleConvergedIPCOLYBTControl`
   (Olympus = Broadcom-style PCIe/UART "converged IPC" transport) which publishes an HCI transport object.
   A stand-in must provide an `IOService` in the same matching classes with the transport user-client
   semantics bluetoothd uses (opaque, [U]). Alternatives: run `bluetoothd` against a replacement transport
   through the BlueZ-like path does not exist on iOS. Realistically BT inside iOS is a **later, uncertain**
   milestone; the useful BT result near-term is "chip is up and answers HCI from the kernel" (stage 2), which
   proves rails/UART/firmware and gives a platform for a custom transport once the bluetoothd side is reversed.

## 5. Phased plan, effort, hazards

| Phase | Deliverable | Effort | Risk |
|---|---|---|---|
| P0 | `sweetwlan=1` probe on the phone (read-only). Resolves every [U] about clocks, DFS table, SE6 protocol, cmd-db names, SMEM/SMP2P state, SMMU SID 0x40 | 0.5 day to run, patch exists | low: reads only; guarded SE6 reads |
| P1 | `sweetwlan=3` read-only inventory (modem + bluetooth FAT, MDT vs carve-outs, EFS partitions readable) | 0.5 day | low; READ(10) only, restores root LUN state |
| P2 | `sweetwlan=2` Bluetooth: rails + UART + pulses + HCI Reset + version. Then firmware download (TLV, ~0.5 k lines), baud change, BD address from persist read-only | P2a 1-2 days, P2b 2-3 days | medium: RPMh active-set votes (rail on) and UART pins; wrong rail = chip damage unlikely at the listed voltages |
| P3 | MSS groundwork: free pool, hyp-assign, MBA load + RMB handshake **without** MPSS (stop at "MBA alive", read PBL/MBA status) | 3-5 days | **high**: first TZ/hypervisor-mediated action; run only with a persistent log and recovery path |
| P4 | MPSS auth+load, SMP2P ready, GLINK/QRTR, pd-mapper/tftp/rmtfs (reads only), WLFW to mission | 8-12 days (porting topaz 0113-0124 with the changes of section 2) | high: modem firmware faults, WDOG/SSR loops, SMMU faults reset the SoC |
| P5 | WLAN radio: SMMU context, CE, HTC, WMI, HTT, passive scan (= topaz 0123/0125/0126) | 5-7 days | medium-high |
| P6 | Join/auth/data path (WMI mgmt TX, key install, ifnet en0, IOKit stand-ins) | 3-4 weeks | medium; large design surface |
| P7 | Apple80211 UI emulation and iOS BT transport | open ended (weeks) | unknown |

Hazards, explicitly:
* **Never write modem-related partitions.** `modem`, `modemst1`, `modemst2`, `fsg`, `fsc`, `persist`,
  `bluetooth`, `dsp`, `qupfw`, `tz`, `hyp`, `xbl`, `aop`: this code only issues READ(10). The UFS write path
  stays gated by `ufsrw=1` and the root partition bounds; the new reader cannot reach it [V in patch].
  The rmtfs service in P4 must drop writes (topaz does) and the buffer must never be flushed to the EFS partitions.
* **Do not reset or restart the modem repeatedly**; a cold start per boot only (topaz refuses to touch a
  modem whose SMP2P item 435 already exists; the probe prints whether it does).
* **Rails:** only the five allow-listed LDOs (`ldoa5/7/17/23/25`) can be voted by the new helper; s4a is never
  voted; stage 2 restores them off afterwards (`sweetwlankeep=1` leaves them).
* **RPMh:** the existing client quarantines a TCS after an uncertain transaction; do not remove that.
* **Possible hangs:** reading QDSP6/RMB before reset (not done), reading WLAN membase 0x18800000 before WLFW
  mission mode (topaz: "a register read hangs the bus"), SE6 registers with gated clocks (guarded in the
  probe), apps_smmu global faults on DMA without a context bank (hypervisor resets the SoC), TZ calls that
  never return INTERRUPTED loops (cap the resume loop as topaz does, 100000).
* **Cache coherency:** 0102's `sweet_dma_sync_va()` must wrap CPU writes/reads of every buffer the modem or
  WCN3990 DMA touches unless the mapping is Normal-NC (topaz maps modem-shared memory write-combined).
* **Bricking:** none of the steps writes flash. The worst realistic outcome is a SoC reset (watchdog) or a
  hang that needs Power+VolDown; recover with the usual `fastboot boot`. A persistent log keeps the trail.

## 6. Verified facts worth keeping (probe results to date)

Host test of the draft's FAT16/ELF code on `backup/modem.img` [V]:
* FAT16, 4096 bytes/sector, 4 sectors/cluster, 12283 clusters. `image/mba.mbn` 238304 B, `image/modem.mdt`
  8412 B, `image/wlanmdsp.mbn` 3645892 B, 29 `bdwlan.*`, 5 `bdf_*.bin`, `qdsp6m.qdb` present.
* `modem.mdt`: 30 program headers; entry 0x8e400000; 28 loadable segments spanning 0x8e400000..0x95c00000;
  hash segment ph1 at 0x95c00000 (7400 bytes), RELOCATABLE flag set; last segment ph29 is a 0xce3000-byte
  zero-fill (BSS) at 0x94f1d000. This matches the 0x7800000 MPSS carve-out exactly.
* `mba.mbn` is an ELF (`7f 45 4c 46`) and fits the 2 MiB MBA carve-out.
* `bluetooth.img`: FAT16 mounts; `crbtfw21.tlv` 222988 B, `crnv21.bin` 4591 B.
* `persist` (ext4) holds `wlan_bt/{wlan.mac,bt.mac}` and a `bluetooth/` dir; `dsp.img` is ext4 (`adsp`, `cdsp`).
* The firmware in the partitions is dated 2020-11/12 (MIUI-era), the running ROM is Android 16 custom: the
  modem partition is the Android ROM's actual firmware, so it is the right one for this phone's EFS.

## 7. The draft patch (research/wifi-draft/0104-beryllium-wlan-bt.patch)

Base `research/bt102/xnu`; `git apply --check` clean; `xnu-cc.py` clean for `bsd/dev/beryllium_wlan.c`,
`sweet_ufs.c`, `sweet_rpmh.c`; object files define the new symbols and reference only existing ones.
Default behaviour is unchanged: without `sweetwlan=` nothing is mapped, logged or started, and the hook does
nothing on the sweet board.

| Boot-arg | Stage |
|---|---|
| `sweetwlan=1` | probe: GCC CBCRs (SE clocks, MSS clocks), S6 DFS table, TLMM gpio45-48, SE6 firmware protocol/FIFO params (only if its clocks are on), cmd-db lookups for `smpa4 ldoa5 ldoa7 ldoa17 ldoa23 ldoa25`, SMEM table + apps<->modem item list, TCSR mutex 3, apps_smmu SMR/S2CR for SID 0x40 and 0x740 |
| `sweetwlan=2` | probe + Bluetooth: clocks, pins, RPMh rails, polled UART, power pulses, HCI Reset, Read Local Version, QCA version request, power-off pulse; rails are never voted off (0118) |
| `sweetwlan=3` | probe + read-only inventory: partitions, FAT16 walk, MDT table vs carve-outs |
| `sweetwlandelay=S` | seconds to wait (default 90) |
| `sweetwlankeep=1` | obsolete since 0118 (rails always stay on) |
| `sweetwlanskippll=1` | 0118: do not stop when GPLL0 decodes off 600/300 MHz |

Code changes: `bsd/dev/sweet_rpmh.c` (board-selected SDM845 RSC/cmd-db, `sweet_rpmh_lookup`,
`sweet_rpmh_vreg_set` with an allow list, ENABLE-only disable), `bsd/dev/sweet_ufs.c`
(`sweet_ufs_part_size`, `sweet_ufs_read_part`, hook), new `bsd/dev/beryllium_wlan.c`, `bsd/conf/files`.

Known weaknesses of the draft (all [U], by design for a first run):
* RPMh: the existing client assumes cmd-db version 1 and the PMIC LDO HPM mode 7; the SDM845 values are not
  confirmed (the probe's lookups print `version`/`magic` first).
* UART: assumes the DFS table has a level giving 14.7456 MHz (it should, `ftbl_gcc_qupv3_wrap0_s0_clk_src`),
  RX uses stale-timeout flushing, TX is limited to `4*(depth-2)` bytes (no firmware download yet).
* Stage 2 sends the vendor read-version before any firmware: Linux does the same before patch download.
* No interrupts anywhere (polled), no timeouts longer than 1 s per HCI command.

## 7b. Patch 0118: the stage programs the S6 RCG itself (xnu/patches/0118-beryllium-bt-uart-clock.patch)

Base `research/bt117/xnu` (0001-0117); `git apply --check` clean on a fresh copy; `xnu-cc.py` clean for
`bsd/dev/beryllium_wlan.c` with a real object (no new undefined symbols). Not run on the phone.
Boot 0116hw (sweetwlan=2) showed the three rail votes completing, the GCC 0x5200c votes bringing wrap0
m_ahb/s_ahb/s6 on, then the abort: S6 RCG cmd=0x80000000 cfg=0x100000 (XO, HW_CLK_CTRL set), DFS-ENABLE
0x8020 (bit 0 clear = DFS off), all 8 DFS levels zero, TLMM gpio45-48 still function 0.

What changed (all inside `sweetwlan=2`, every line logged with `SWEET WLAN:`):

1. **GPLL0 check** (`wl_gpll0_check`): the ftbl rates assume GPLL0 600 MHz / GPLL0_OUT_EVEN 300 MHz. Reads
   PLL_MODE 0x0 (lock bit 31), L 0x4, FRAC 0x38, USER_CTL 0xc (post-div [11:8]: 0/1/3/7 = /1/2/4/8; Fabia
   regs from clk-alpha-pll.c [U: offsets from memory, the raw values are printed]). Stops when unlocked or
   off by more than 0.1 %. `sweetwlanskippll=1` skips the rate check (not the lock check).
2. **S6 RCG, non-DFS path** (`wl_rcg_*`, RCG 0x17754: CMD +0, CFG +4, M +8, N +0xc, D +0x10, DFS +0x14).
   Following clk-rcg2.c `__clk_rcg2_configure` / `update_config`: M = m, N = ~(n-m), D = ~n (16 bit), CFG =
   src<<8 | hid | dual-edge (2<<12) when n and m != n (HW_CLK_CTRL bit 20 cleared like Linux), each written with
   read-back, then CMD |= UPDATE and polled until the bit clears. Table = `ftbl_gcc_qupv3_wrap0_s0_clk_src`
   from `research/linux-src/gcc-sdm845.c` (hid = 2*div-1; sources XO 0, GPLL0_OUT_MAIN 1, GPLL0_OUT_EVEN 6).
   The original CFG/M/N/D are saved before the first write and restored (plus UPDATE) on every exit path.
   If DFS-ENABLE bit 0 is ever set the stage stops (the old DFS-level path is gone).
3. **Baud selection** (`wl_pick_row`, as `get_clk_cfg` in qcom_geni_serial.c): first row with
   `rate % (baud * oversampling) == 0`, GENI divider = rate / (baud * os); SER_CLK_CFG = div<<4 | SER_CLK_EN
   written to SE_M_CLK_CFG and SE_S_CLK_CFG with read-back, SE_CLK_SEL = 0. The RCG is re-programmed only when
   the row changes (2400 and 115200 share the 7.3728 MHz row). One source rate cannot give all bauds exactly,
   so the root is retuned per baud (RX stopped first, as set_termios does). SE6 clock registers are saved and
   restored too. With os = 32: 2400 -> 7.3728 MHz / 96, 115200 -> 7.3728 MHz / 2, 3000000 -> 96 MHz / 1,
   **3200000 (beryllium dtsi `max-speed`, the WCN3990 operating baud) -> 102.4 MHz / 1**, all exact. The
   oversampling is 16 instead of 32 when the QUP wrapper0 HW version (0x8c0004) is >= 2.5 (Linux rule);
   the version is read and printed (SDM845 value not yet known [U]; the baud plan prints the result).
   The stage still only runs 2400 and 115200; changing to the operating baud needs the QCA vendor command
   and firmware download, not done here.
4. **TLMM** (`wl_pins_uart`): gpio45-48 -> function 1 (`qup6`, pinctrl-sdm845.c), pulls/drive from mainline
   `qup_uart6_4pin` (what beryllium.dtsi selects): CTS pull-down, RFR and TX bias-disable, RX pull-up, 2 mA.
   The phone's downstream DT (`qupv3_se6_4uart_pins`) differs slightly: ctsrx and TX/RTS pulls (cts+rx none,
   rts pull-down, tx pull-up), also 2 mA; mainline was chosen because that is what Linux runs on this phone.
   Only bits [8:0] are modified (OE bit 9 kept), read back, and the original ctl words restored on exit.
5. **GENI init vs Linux** (qcom-geni-se.c / qcom_geni_serial.c): reviewed `geni_se_init`/`io_init`/
   `io_set_mode`/`config_packing`/set_termios register by register (CGC 0x7f, DMA general 0xf, OUTPUT_CTRL 0x7f,
   FORCE_DEFAULT, packing 8 bit x 4, BYTE_GRAN 0, RX stale 160, RX WM 2, RFR WM depth-2, word/stop/parity,
   TX_TRANS_CFG CTS-mask for flow off, UART_START_TX/READ opcodes, FIFO depth fields) - all matched except:
   SE_IRQ_EN was OR-ed with 0xf (also enabling DMA TX/RX irqs); `geni_se_io_set_mode` sets only GENI_M/S and
   clears DMA_TX/RX, now done; SE_CLK_SEL was set to a DFS level, now 0; RX polling never acked S_IRQ status
   or re-armed the read command after S_CMD_DONE, now done as in `qcom_geni_serial_isr`.
6. **Rails are never voted off**: the `sweetwlankeep=0` off path and the final "rails off" are removed
   (the qca_power_off 2400-baud pulse is still sent, rails stay on). Bail-outs after the rail votes end with
   the same restore sequence (SE clk regs, RCG, pins, clock votes) and "rails left on".

Expected log lines on a good run (order):
```
SWEET WLAN: GPLL0 mode 0x... (lock 1) L 31 frac 0x4000 user-ctl 0x... -> main 600000000 Hz, even (post-div 2) 300000000 Hz
SWEET WLAN: GPLL0 600 MHz / GPLL0_OUT_EVEN 300 MHz confirmed
SWEET WLAN: S6 RCG saved: cmd 0x... cfg 0x100000 m ... n ... d ...
SWEET WLAN: TLMM gpio45 (CTS): was 0x... -> func 1 pull 1 drive 2 mA   (x4)
SWEET WLAN: write TLMM+0x2d000 <- 0x..., read back 0x... (mask 0x1ff) ok
SWEET WLAN: QUP wrapper0 HW version 0x... -> UART oversampling 32|16
SWEET WLAN: baud plan 2400 / 115200 / 3000000 / 3200000: ftbl row ... exact
SWEET WLAN: rail ldoa7 1800 mV -> 0 (x3)
SWEET WLAN: S6 RCG -> 7372800 Hz: src 6 hid 1 m 384 n 15625 cfg 0x2601
SWEET WLAN: write GCC+0x1775c <- 0x00000180 ... ok / +0x17760 <- 0x0000c476 / +0x17764 <- 0x0000c2f6 / +0x17758 <- ... ok
SWEET WLAN: RCG CMD 0x... -> UPDATE set ..., cleared after N polls
SWEET WLAN: UART 2400 baud: S6 root 7372800 Hz (ftbl row 0), GENI divider 96, oversampling 32
SWEET WLAN: UART 115200 baud: ... GENI divider 2 ...
SWEET WLAN: after power-on pulse: N stray RX bytes / HCI Reset event / Read Local Version / QCA patch version
SWEET WLAN: rails left on (3 of 3 voted by this stage)
SWEET WLAN: restoring the original S6 RCG config ... S6 RCG restore ok
SWEET WLAN: write TLMM(restore)+... ; SWEET WLAN: bluetooth stage done
```
Failure lines (all end in the restore sequence, never a rail-off): `GPLL0 is not locked`, `GPLL0 is not 600 MHz /
even 300 MHz`, `S6 RCG is in DFS mode`, `MISMATCH` on any read-back, `RCG UPDATE did not clear`,
`S6 branch went off after the RCG update`, `UART pin mux did not read back`.
If no HCI event comes back after the pulse, check first that `UART 115200 baud` shows divider 2 and that the
TX pin func reads 1; the likely next suspects are the WCN3990 needing its SW_CTRL/other GPIO and the power
pulse timing.

## 7c. Patch 0130: WCN3990 rampatch + NVM download, baud change (xnu/patches/0130-beryllium-bt-firmware.patch)

Base `research/bt118/xnu` (0001-0118); `git apply --check` clean on a fresh copy, `xnu-cc.py` clean for
`bsd/dev/beryllium_wlan.c` (object built; the new undefined symbols `sweet_a630_fw_get` / `sweet_a630_fw_put` are
defined in `bsd/dev/sweet_a630.c`). Not run on the phone. Only `beryllium_wlan.c` changes; the files are read
with the GPU's vnode reader (`sweet_a630_fw_get(NULL, name, ...)` from `/usr/standalone/firmware/sweet/`, 256 KiB
limit), so the stage (about 90 s after boot) needs the root fs.

Gate: `sweetwlan=2`; `sweetbtfw=1` (default) downloads when the files exist, `sweetbtfw=0` stops after the
version queries (the 0118 behaviour). Other boot-args: `sweetbtbaud` (default 3000000; 3200000 also has an exact
S6 rate and a QCA code), `sweetbtfast=1` (Linux order: baud change first, download at the operating speed;
default 0: download at 115200, about 20 s), `sweetbtibs=1` (Linux NVM edits, see below), `sweetbtpoweroff=1`
(send the 2400 baud 0xC0 power-off pulse at the end; default: the controller stays powered). Rails are still
never voted off.

Protocol (btqca.c / hci_qca.c, WCN3990 path), H4 over the UART:

1. Version: vendor 0xFC00 `{0x19}` (EDL_PATCH_VER_REQ). The reply is vendor event 0xff `{cresp 0, rtype 2,
   product_id le32, patch_ver le16, rom_ver le16, soc_id le32}`. Boot 0118g4 raw `ff 0e 00 02 0a 00 00 00 01 00 01
   02 14 02 01 40` decodes to product 0x0000000a, patch 0x0001, rom 0x0201, soc_id 0x40010214. As in Linux
   `soc_ver = (soc_id << 16) | rom_ver` = 0x02140201 and `rom_ver = ((soc_ver & 0xf00) >> 4) | (soc_ver & 0xf)` =
   0x21, so the names are `qca/crbtfw21.tlv` and `qca/crnv21.bin` (`crnv%02xu.bin` only for soc_id 0x40014320, the
   WCN3991), identical to Android's. If a different name were computed the stage logs it and falls back to those two.
2. Rampatch (TLV type 1): the whole file including its 4-byte `tlv_type_hdr` is sent in segments of 243 bytes
   (`MAX_SIZE_PER_TLV_SEGMENT`) as vendor 0xFC00 `{0x1e (EDL_PATCH_TLV_REQ), len, data}`: 918 segments, the last one
   157 bytes. The patch header (`tlv_type_patch`, offsets from the file start: total_size @4, data_length @8,
   format @12, signature @13, **download_mode @14**, product @16, rom_build @18, patch_version @20, entry @24)
   gives the download mode: crbtfw21.tlv has 3 (QCA_SKIP_EVT_VSE_CC), rom_build 0x0201, patch_version 2, entry
   0x209e4. Mode 3: no segment is acknowledged except the last (or any short one: "the last segment is always
   acked"), which gets the vendor event `{cresp 0, rtype 4 (EDL_TVL_DNLD_RES_EVT), result}`, result 0 = ok. The
   stage does not wait for the intermediate segments (the controller's RTS holds the stream back; TX slack
   0.5 s), drains events between segments and aborts on a non-zero Command Complete status or TLV result. Mode 1
   waits for a Command Complete per segment, modes 0/2 for the vendor event. 10 s timeout on the last segment.
3. 10 ms, then the NVM (its TLV type byte is 4 here, Linux does not check it) the same way with mode 0: every
   segment is acknowledged by the vendor event (19 segments).
   NVM edits (`qca_tlv_check_data`): HCI transport tag 17: `data[0] |= 0x80` (software in-band sleep, IBS) and
   `data[1]` = baud code (enum qca_baudrate: 115200 = 0, 921600 = 10, 3000000 = 0x0e, 3200000 = 0x11); deep-sleep
   tag 27: `data[0] |= 1`. Linux does that because it implements IBS; we do not, and a controller that sleeps needs
   the 0xfd/0xfc/0xfe wake protocol, so by default the stage **clears** 0x80 on tag 17 and the sleep bit on tag 27
   (`sweetbtibs=1` restores the Linux bits). The baud tag is the speed in effect during the download (115200 by
   default, the operating speed with `sweetbtfast=1`).
   Finding on the Android crnv21.bin: its entries (`{id, len, reserve1, reserve2, data[len]}`) start at file
   offset 8, not 4, because there is one more header word (0x000dfb02) after `type_len`; Linux's walker, which
   starts at offset 4, would not find tags 17/27 in this file. The stage tries both start offsets and takes the
   one with a consistent tag chain (44 tags, ids ascending, ending at offset 3587; tag 17 at 43 with data 82 01
   11 08 04 14 28 02 15, tag 27 at 133 with data 01). An unrecognised layout is sent unmodified.
   [U] what the rest of the file after offset 3587 is.
4. HCI Reset (3 s timeout), then the QCA version is read again (patch_ver should now be 2).
5. Baud change (`qca_set_speed`): flow control off, vendor 0xFC48 with one byte (qca_baudrate) at the old speed,
   not waited for; 10 ms; host UART switched (S6 root 96 MHz / 1 for 3000000, 102.4 MHz / 1 for 3200000); flow
   control on; the controller's vendor event for 0xFC48 (Linux drops it) is logged if it arrives within 100 ms;
   verified with HCI Read Local Version at the new rate (manufacturer 0x001d expected).
6. HCI Read BD_ADDR (0x1009), logged most significant byte first. `qca_check_bdaddr` / `qca_set_bdaddr` skipped,
   `qca_disable_soc_logging` (WCN3991 and later) not applicable.

Expected log lines on a good run (after the existing 0118 lines):
```
SWEET WLAN: BT fw QCA patch version (...): product ID 0x0000000a, patch version 0x0001, ROM version 0x0201, SoC ID 0x40010214 -> soc_ver 0x02140201, rom_ver 0x21
SWEET WLAN: BT fw: btqca.c names for WCN3990 soc_ver 0x02140201: qca/crbtfw21.tlv, qca/crnv21.bin (same as the Android files)
SWEET WLAN: BT fw: loaded crbtfw21.tlv (222988 bytes) / loaded crnv21.bin (4591 bytes)
SWEET WLAN: BT fw patch: TLV type 1 length 222984 (file 222988), ... download_mode 3, product 0x000a, rom_build 0x0201, patch_version 0x0002, entry 0x209e4
SWEET WLAN: BT fw NVM: TLV type 4 length 4587 (file 4591) / tags start at offset 8 ... / 44 tags ... HCI tag 17 at 43, deep sleep tag 27 at 133
SWEET WLAN: BT fw NVM: HCI tag: data[0] 0x82 -> 0x02 (IBS off), data[1] (baud) 0x01 -> 0x00 / deep sleep tag: data[0] 0x01 -> 0 (deep sleep off)
SWEET WLAN: BT fw patch: 222988 bytes in 918 segments of 243, download_mode 3 (only the last segment is acknowledged)
SWEET WLAN: BT fw patch: segment 92/918 (10%), 22356/222988 bytes   ... every 10 % ... (100%)
SWEET WLAN: BT fw patch: download complete, last segment acknowledged (0 command complete, 0 other events along the way)
SWEET WLAN: BT fw NVM: 4591 bytes in 19 segments of 243, download_mode 0 (vendor event per segment) ... download complete
SWEET WLAN: HCI Reset event after download: 0e 04 01 03 0c 00
SWEET WLAN: BT fw QCA version after download: ... patch version 0x0002 ...
SWEET WLAN: BT fw: EDL_SET_BAUDRATE_CMD 0xfc48 code 0xe (3000000 baud), host 115200 -> 3000000 baud
SWEET WLAN: UART 3000000 baud: S6 root 96000000 Hz (ftbl row ...), GENI divider 1, oversampling 32
SWEET WLAN: HCI Read Local Version (at new baud): HCI version ... manufacturer 0x001d ...
SWEET WLAN: BT fw: controller answers at 3000000 baud
SWEET WLAN: BT fw BD_ADDR xx:xx:xx:xx:xx:xx
SWEET WLAN: BT fw setup complete (patch + NVM downloaded, controller up at the operating baud)
SWEET WLAN: BT controller left powered (no power-off pulse; sweetbtpoweroff=1 sends it)
```
Failure lines: `BT fw patch|NVM: segment N/M: no vendor event | TLV with invalid response or error status | TX
failed`, `download FAILED after N/M segments`, `HCI Reset after download: no event`, `controller does not answer
at N baud`, `firmware files not available: no download`. Every failure ends in the normal restore sequence
(clocks, RCG, pins); rails stay on. Likely first-boot problems: no vendor event after the last patch segment
(try `sweetbtfast=1`, or the NVM baud tag semantics: Android's file carries code 1 where Linux's table says 57600,
so the tag may not mean what the table says [U]); no answer after the baud change (try `sweetbtbaud=3200000`).

## 8. Sources

* ios-topaz patches 0113-0126 (`gh api repos/MakrSas/ios-topaz/contents/xnu/patches/...`), read 2026-10-20 [V].
* docs/TOPAZ_REVIEW.md section 8, docs/FORKS_SURVEY.md sections A1, C, D1 [V repo].
* Linux (torvalds/linux master fetched 2026-10-20): `drivers/remoteproc/qcom_q6v5_mss.c`,
  `drivers/bluetooth/hci_qca.c`, `btqca.c/.h`, `drivers/net/wireless/ath/ath10k/{snoc,qmi,hw,ce}.c`,
  `drivers/soc/qcom/qcom-geni-se.c`, `include/linux/soc/qcom/geni-se.h`, `drivers/tty/serial/qcom_geni_serial.c`,
  `drivers/pinctrl/qcom/pinctrl-sdm845.c`; repo copies: `research/linux-src/gcc-sdm845.c`,
  `research/linux-dts/.../sdm845.dtsi`, `sdm845-xiaomi-beryllium-common.dtsi`.
* Live downstream DT `dtb/beryllium/live.dts` (qcom,mss@4080000, qcom,icnss@18800000, qup_uart@898000,
  qcom,glink, reserved-memory).
* Backups `backup/{modem,bluetooth,dsp,persist,modemst1,modemst2,fsg,fsc}.img` (listed with `7zz l`, no content
  copied) and the IPSW kernelcache / dyld cache strings (`ipsw kernel dec`, `strings`).
* Not fetched: ch1tmdgus/ios-v60 commits (described via the survey only).
