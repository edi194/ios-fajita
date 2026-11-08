# Wi-Fi on iOS 26.6.2 (xnu-12377, Poco F1 / WCN3990)

Branch `wlan26` (off `ios26`). Patch numbers **1100-1199** in `xnu/patches-12377` are this work's; the iOS 26
port uses 1000-1099. iOS 18 background: `docs/WIFI_BT_IOS18.md` section 3 (the two missing drivers) and
`docs/WIFI_BT_PLAN.md` (the chip sequence). This file re-scopes the iOS half for iOS 26; the chip half is unchanged.

## 1. What iOS 26 expects (reverse-engineered 2026-10-25)

Sources: iPhone12,1 23G90 kernelcache (`ipsw download --kernel`), `/usr/sbin/wifid` and the
LaunchDaemons from the phone, and IO80211 / CoreWiFi / MobileWiFi / WiFiPolicy extracted from the iOS 26
shared cache (`research/ios26/dsc-fix`). Nothing Apple is committed; addresses below are IO80211.framework 1565.3
and wifid in 23G90.

### 1.1 The driver is no longer a kext

The iPhone12,1 kernelcache has **no IO80211Family and no AppleBCMWLAN kext**. Wi-Fi is the DriverKit
extension `/System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext` (user space), launched over
PCIe (`AppleBCMWLANBusInterfacePCIe` in the kernel only does PCIe power and dext crash recovery). The kernel
side of the data path is IOSkywalkFamily (`IOUserNetworkWLAN`, `AppleBCMWLANSkywalkInterface`), also closed.

For us this means there is **no closed kernel family to imitate any more**. What user space needs is a short,
fully identifiable list of IOKit properties, one BSD interface, two ioctls and one kernel-event class, all
of which xnu-12377 (open source) can provide.

### 1.2 How wifid finds a Wi-Fi device

* launchd starts wifid only if the device tree has a node named `wlan`, `marconi-wifi`, `centauri-alpha` or
  `centauri-alpha-protium` (`com.apple.wifid.plist` `_LimitLoadToDeviceTree`). Real N104 has `/arm-io/wlan`
  (`device_type = 'wlan'`, `local-mac-address`, many `wlan.*` tunables); our N104 ADT has none, so wifid
  never runs (confirmed: no wifid in `ps` on the iOS 26 boot).
* `WiFiManagerScheduleWithQueue` (wifid `sub_100079D04`) registers IOKit notifications on constant
  dictionaries; **no class name is involved**:
  1. `{IOPropertyExistsMatch: "WiFiHardwareHealthy"}`;
  2. `{IOPropertyMatch: {IO80211InterfaceRole: "Infrastructure"}}`. Its callback runs `WiFiDeviceCreate`
     (`sub_10005EF34`), which reads `IOInterfaceName` (falls back to `IOInterfaceNamePrefix` +
     `IOInterfaceUnit`) and needs an IOService-plane parent;
  3. `IOServiceNameMatching("AppleWLANDriver")` matched/terminated: driver-available events;
  4. `IOServiceNameMatching("AppleSunriseHALDevice")`, IOPMPowerSource, IOUSBDevice and IOPort entries
     (optional).
* `wifiFirmwareLoader` only launches on `IONameMatch AppleBCMWLANCoreFirmwareLoader`; we never publish that.

### 1.3 How the IO80211 framework talks to the driver

`Apple80211BindToInterfaceWithService` (IO80211 `0x25d441180`):

1. `IOServiceOpen` on the matched service, then struct method 0 with an `apple80211req`-style buffer
   (`SIOCGA80211` marker `0xc02869c9`, type 43 `DRIVER_VERSION`, 15408 bytes), methods 1
   (`useIOUCWhenPossible`) and 7 (`isDKSupported`). This is the DriverKit user client.
2. **If `IOServiceOpen` fails, it falls back to the ioctl path** ("Falling back to IOCTL path"): the
   interface must be in `_getIfListCopy` (getifaddrs, then `SIOCGIFMEDIA` with `(ifm_current & 0xe0) == 0x80`
   = IFM_IEEE80211, or `SIOCGIFTYPE` with type 6 / subfamily 3 = Ethernet/Wi-Fi). It must also pass
   `_isInfraInterface`: an IOKit service matching `{IOPropertyMatch: {IOInterfaceName: <ifname>}}` with
   `IO80211InterfaceRole = "Infrastructure"`. Then `SIOCGIFFLAGS` and `SIOCGA80211` type 12
   (`CARD_CAPABILITIES`) on a socket must succeed.
3. From then on every get/set is `ioctl(s, SIOCGA80211 / SIOCSA80211, struct apple80211req)` (40 bytes:
   `char ifname[16]; u32 type; u32 val; u32 len; u64 data`), the classic Apple80211 API. In xnu-12377 an unknown
   socket ioctl whose buffer starts with an interface name reaches that interface's `if_ioctl`
   (`bsd/net/if.c` `ifioctl` default case → `pru_control` → `ifnet_ioctl`), so no xnu change is needed
   to receive them.
4. Events: `Apple80211EventMonitoringInit2` tries the user client's async pipe, then falls back to a
   `PF_SYSTEM / SOCK_RAW / SYSPROTO_EVENT` socket with `SIOCSKEVFILT {vendor 1 (Apple), class 6
   (KEV_IEEE80211_CLASS), subclass 1}`. The kernel posts `APPLE80211_M_*` messages with `kev_post_msg`.

The ioctl type numbering is the framework's own name table (578 entries, in type order; e.g. 1 SSID,
10 SCAN_REQ, 11 SCAN_RESULT, 12 CARD_CAPABILITIES, 13 STATE, 19 POWER, 20 ASSOCIATE, 43 DRIVER_VERSION,
86 SCAN_REQ_MULTIPLE). It matches the old public `apple80211_ioctl.h` for the low numbers.

## 2. The smallest path to association

Two halves, as on iOS 18, but the iOS half is now much smaller and **testable without the chip**:

| Half | What | Size |
|------|------|------|
| A. iOS side | in-kernel `sweet80211` stand-in: `en0` (Ethernet, subfamily Wi-Fi), the IOKit entries of 1.2, the ioctl dispatcher of 1.3, kernel events; plus an ADT `/arm-io/wlan` node | days for "Wi-Fi On, empty list"; then grows with each ioctl wifid needs |
| B. Chip side | WCN3990: MSS/MBA boot, QMI WLFW, CE/HTC/WMI/HTT (ath10k-snoc class), host MLME (auth/assoc), WPA2 4-way handshake, 802.3 data path | 3-4 weeks to a scan (WIFI_BT_PLAN.md P3-P5), more to WPA2 traffic |

Half A no longer needs a 4-8 week Apple80211-lite family. The interface between the halves is an internal
backend struct (`power`, `scan`, `join`, `tx`) so A can be built and booted against a null backend now.

Not chosen:
* **Running Apple's dext** (driverkitd + IOUserServer are in xnu): the dext drives a Broadcom PCIe chip
  through IOSkywalkFamily, which we don't have; nothing of it applies to a Qualcomm SNOC chip.
* **Ethernet-only interface first** (IP over Wi-Fi with our own CLI, wifid not running): it skips Control
  Center/Settings entirely, and the ioctl stand-in costs about the same once the chip half exists. It
  remains a debugging aid (`ifconfig en0` + a test tool) during half B.

## 3. Steps

* **W1 (now): null-backend stand-in, patch 1100** `sweet80211=1` (off by default):
  * `en0` via `ifnet_allocate_extended` (IFNET_FAMILY_ETHERNET, IFNET_SUBFAMILY_WIFI), MAC from the ADT
    `wlan` node or a fixed locally-administered address; output drops packets; `SIOCGIFMEDIA` reports
    IFM_IEEE80211.
  * IOKit: controller `AppleWLANDriver` (name) with `WiFiHardwareHealthy`; child interface with
    `IOInterfaceName en0`, `IOInterfaceNamePrefix en`, `IOInterfaceUnit 0`, `BSD Name en0`,
    `IO80211InterfaceRole Infrastructure`. No user client, so IO80211 takes the ioctl path.
  * ioctls: answers CARD_CAPABILITIES, DRIVER_VERSION, HARDWARE_VERSION, POWER get/set, STATE, OP_MODE,
    PHY_MODE, SUPPORTED_CHANNELS, LOCALE, COUNTRY_CODE, SSID/BSSID (not associated), SCAN_REQ (posts SCAN_DONE)
    and SCAN_RESULT (none); every other type returns EOPNOTSUPP and is logged once as
    `SWEET 80211: get/set type N len L` so the first boot lists what wifid really needs.
  * `tools/adt-wlan.py` adds `/arm-io/wlan`, which is what launchd checks.
  * Goal: wifid stays up, Control Center shows Wi-Fi, and switching it on posts POWER and a scan with no
    networks. The phone boot needs the iOS 26 session (it owns the phone and the flashes).
* **W2:** iterate on the logged ioctls until Settings › Wi-Fi shows "On" and scans.
* **W3:** a fake backend (`sweet80211=2`) that returns one synthetic BSS in SCAN_RESULT, to fix the
  scan-result struct layout and Settings' list before any radio exists.
* **W4+ (half B):** WIFI_BT_PLAN.md P0-P5 forward-ported to xnu-12377: read-only probes, then the gated MSS
  boot (user present, first TZ-mediated step), QMI WLFW, WMI scan → feeds SCAN_RESULT. Then MLME + WPA2 +
  data path → ASSOCIATE.

Rules for every step: never write modem/persist/bluetooth/dsp; firmware stays out of git; flashes only
through the Bergamota queue, and only with the user's OK.

## 4. Log

* 2026-10-25: re-scope (this file). Kernelcache/dext finding, wifid matching dictionaries, IO80211 ioctl
  fallback and event socket confirmed by disassembly. No phone changes.
* 2026-10-25: **W1 written, not booted.** `xnu/patches-12377/1100-sweet-80211-wifi-standin.patch`:
  `bsd/dev/sweet_80211.c` (en0, ioctl dispatcher, kernel events, null backend; started from
  `sweet_ufs.c` next to `beryllium_wlan_init`), `IO80211Controller` / `IO80211Interface` and
  `sweet_net_publish_wlan()` in `iokit/Kernel/arm/SweetNetwork.cpp` (after 0110). Compile-checked with
  `tools/xnu-cc.py` against the iOS 26 CI log (objects link only against existing kernel exports);
  the full 12377 series + 1100 applies to pristine xnu-12377.121.6 and gives the checked files byte for
  byte. `tools/adt-wlan.py` adds `/arm-io/wlan` (tested on `enxerto/out/beryllium-n104-2x.adt`:
  phandle 24, MAC 02:00:5e:77:e0:01 from `/chosen mac-address-wifi0`).
  * To test: kernel with 1100 + ADT from `adt-wlan.py` + boot-arg `sweet80211=1`. Expect the console lines
    `SWEET 80211: en0 ... up` and `IOKit interface en0 published`, wifid running, then one
    `SWEET 80211: get/set type N` line per ioctl type wifid uses; `SWEET NET: wifid opened
    IO80211Controller user client: 0x...` shows the IOServiceOpen refusal that selects the ioctl path.
  * CI run 40191362682 (wlan26 012ed29 = ios26 fb82624 + 1100): success, kernel sha256 `31e6c9c3...`;
    **superseded, do not boot**: it carries the old 1013 (touch events in a layout iOS 26 doesn't read).
    wlan26 is merged into ios26 (bd41a75); the iOS 26 session builds boot 23 from the ios26 tip with 1100,
    `enxerto/out/beryllium-n104-2x-wlan.adt` and `sweet80211=1`.
  * Side effect of the ADT node alone (without 1100): wifid starts and waits for a device; harmless.
* 2026-10-25: **boot 23 (iOS 26 session, ios26 tip with 1100, `beryllium-n104-2x-wlan.adt`, `sweet80211=1`):
  wifid starts and stays up (pid 47) and binds to en0 over the ioctl path.** `IOServiceOpen` on
  IO80211Interface (type 0) and IO80211Controller (type 1) returns 0xe00002c7 (unsupported) for wifid and
  configd as intended. wifid reads CARD_CAPABILITIES and POWER, then sets POWER on ("radio on", event 1
  posted). 37 types in all, no SCAN_REQ yet (nothing asked for a scan; Settings › Wi-Fi was not opened).
  Sizes wifid uses (len 0 = value in req_val):

  | dir | type | name | len | 1100 answer |
  |-----|------|------|-----|-------------|
  | get | 12 | CARD_CAPABILITIES | 21 | 0 (version + 17 zero capability bytes) |
  | get/set | 19 | POWER | 24 | 0 |
  | get | 13 / 14 / 15 | STATE / PHY_MODE / OP_MODE | 8 / 12 / 0 | 0 |
  | get | 51 | COUNTRY_CODE | **3** | 0, but 1100 sent a versioned struct: wifid read `01 00 00` |
  | get | 1 / 9 / 4 / 8 / 16 / 17 | SSID / BSSID / CHANNEL / RATE / RSSI / NOISE | 32 / 6 / 16 / 0 / 52 / 52 | ENXIO (not associated) |
  | get | 2, 5, 57, 70, 96, 97, 103, 106, 115, 207, 254, 423 | AUTH_TYPE, POWERSAVE, MCS, WOW_ENABLED, VIRTUAL_IF_ROLE/PARENT, CURRENT_NETWORK, RSSI_BOUNDS, AWDL_SYNC_PARAMS, AWDL_AF_TX_MODE, BTCOEX_PROFILE, WCL_LEAVE_NETWORK | various | EOPNOTSUPP (102) |
  | set | 25, 469, 473, 481, 483, 485, 490, 512, 564, 572, 575, 582 | HOST_AP_MODE, BATTERY_POWERSAVE_CONFIG, WCL_CONFIG_BGSCAN, APP_REPORT, BYPASS_TX_POWER_CAP, FACETIME_WIFICALLING_PARAMS, WCL_LIMITED_AGGREGATION, SYSTEM_STATE, ACCESSORY_STATE, NAN_CCA, NB_RANGING_SESSION, (582) | various | EOPNOTSUPP (102) |

  Also `ioctl 0xc0206944 not handled` = SIOCGIFDEVMTU.
* 2026-10-25: **1101** (`1101-sweet-80211-boot23-fixes.patch`, compile-checked, not booted): COUNTRY_CODE as
  bare char[3] (get and set), SIOCGIFDEVMTU (1500), unknown *set* types accepted and ignored (still logged
  once). Unknown gets stay EOPNOTSUPP. Next test: open Settings › Wi-Fi and look for SCAN_REQ (10) or
  SCAN_REQ_MULTIPLE (86), `event 10`, and what the screen shows.
* 2026-10-25: **1102** (W3, compile-checked, not booted): `sweet80211=2` returns one synthetic open network,
  "Bergamota-test" (BSSID 02:00:5e:77:e0:aa, channel 6, RSSI -52), per scan. Layout from IO80211
  `Apple80211Scan` / `_addScanResultToList`: SCAN_REQ is a 5528-byte set; after the SCAN_DONE event the
  framework gets type 11 into a 2272-byte buffer until the get fails with EIO (or 0xe0820446). One result is
  the classic `apple80211_scan_result`: version @0, channel {version, number, flags} @4, unk/noise/snr/rssi
  int16 @16-22, beacon interval @24, capability @26 (bit 0 ESS, 0x10 privacy), BSSID @28, rate count @34,
  rates u32[15] (Mb/s) @36, SSID length @96, SSID @97, age @132, flags @136, IE length @138, IEs @140
  (2048), u64 @2256. A privacy bit makes the framework parse WPA/RSN IEs; the fake network is open.
  Joining it fails (ASSOCIATE -> ENXIO). With `sweet80211=1` nothing changes.
* 2026-10-25: boot 24/25 (`sweet80211=2`, 1101 + 1102): wifid up, optional sets now accepted (new: 470, 482,
  560), COUNTRY_CODE fine. Still no SCAN_REQ: touch does not work yet, so nobody can open Settings ›
  Wi-Fi. Added `tools/sweetnet/sweetwifi.c` (`sweetwifi info | power on|off | scan`; built by
  `tools/sweetnet/build.sh` into `research/sweetnet/ios18/`, arm64e + pacstrip, runs on iOS 26). It calls the
  framework's own Apple80211Open/BindToInterface/Scan over SSH, which tests the scan path (kernel stand-in
  plus IO80211's result parser) without wifid or the UI.
* 2026-10-25: **paused** by the user (focus on touch). Next step when resumed: `sweetwifi info` / `scan` on a `sweet80211=2` boot.
* 2026-10-25: **resumed** (user). Touch works on iOS 26 (boot 27, tag ios26-touch-works); the iOS 26 session runs `sweetwifi` steps 1-4 and opens Settings › Wi-Fi on boot 28 (`sweet80211=2`).
* 2026-10-25: **boot 27 (ios26 with 1100-1102, `sweet80211=2`): the scan path works end to end.**
  `sweetwifi info`: bind en0 0, power 1, COUNTRY_CODE "BR", STATE 0, OP_MODE 1 (STA), SSID/BSSID -3903 (not
  associated). `sweetwifi scan`: `Apple80211Scan -> 0`, one result, parsed by IO80211 into SSID_STR
  "Bergamota-test", BSSID 2:0:5e:77:e0:aa, CHANNEL 6, CHANNEL_FLAGS 138, CHANNEL_WIDTH 20, PHY_MODE 8 (11g), RSSI
  -52, NOISE -92, SNR 40, RATES 1..54, CAPABILITIES 1, AP_MODE 2, IE (29 bytes). Kernel log: set type 10 (len
  5528), event 10, get type 11 (len 2272) -> result then EIO; a second event 10 shows that another client
  (wifid) also scanned. New set type 571 (len 8) accepted. Still open: what Settings › Wi-Fi shows (asked).
* 2026-10-25: **Settings › Wi-Fi showed "No networks" (boot 28, user)**. The iOS 26 session's log stream of wifid and
  Preferences shows why: on opening the page, Settings asks wifid for the hardware channel list (CoreWiFi
  "GET HW SUPP CHANNELS", `queryHardwareSupportedChannelsWithRequestParams`). wifid sends ioctl type **254**, named
  `APPLE80211_IOC_HW_SUPPORTED_CHANNELS` by IO80211 itself (len 4824). 1100 refused it, so Settings logged "device
  scan channels are nil" and "scanning did finish ... results=0" without ever requesting a scan.
  **1103** (compile-checked, not booted) answers 254 with the SUPPORTED_CHANNELS list. The IO80211 parser
  (CopyValue, 0x25d42b428) reads `{u32 version; u32 count @4; {version, channel @12, flags @16} x count}`,
  12-byte stride, into SUP_CHANNEL / SUP_CHANNEL_FLAGS.
  **Correction: type numbers.** The names in the boot 23 table came from string order. The framework's real
  index table (`gAppleIoucIndexToString`, 587 entries, `convertApple80211IOCTLToString`) has empty slots at 0,
  114 and 353 (CARD_SPECIFIC is -1). Names are right for 1-113 (everything the stand-in implements), one off
  for 114-352 (e.g. 254 = HW_SUPPORTED_CHANNELS, not BTCOEX_PROFILE) and two off from 353 up.
* 2026-10-25: **MILESTONE, boot 29 (ios26 2ba2989 with 1100-1103, `sweet80211=2`): Settings › Wi-Fi lists
  "Bergamota-test" (user-confirmed).** The iOS half (W1-W3) is complete: wifid, CoreWiFi and Settings accept the
  in-kernel stand-in, power the radio, scan and show results. What remains is the chip half (W4+): a real WCN3990
  backend behind `s8_get/s8_set` (power, scan results from WMI, then join/WPA2/data). Joining the synthetic
  network fails by design (ASSOCIATE -> ENXIO).

## 5. Chip half (W4+): read-only probes first

Started 2026-10-25 (user: "start the chip half with the read-only sweetwlan probes on xnu-12377").
`bsd/dev/beryllium_wlan.c` (0104 and the BT patches, forward-ported in patches-12377) already carries P0 and P1 of
`docs/WIFI_BT_PLAN.md` unchanged:

* `sweetwlan=1`: GCC clock branches (SE and MSS), S6 DFS table, TLMM gpio45-48, SE6 protocol/FIFO (only when its
  clocks are on), cmd-db addresses of the WCN3990 rails, SMEM table + apps<->modem items, TCSR mutex, apps SMMU
  SMR/S2CR for stream 0x40 / 0x740. RMB (0x4180000) and QDSP6 (0x4080000) are deliberately not read.
* `sweetwlan=3`: the stage-1 probe, then a read-only inventory: sizes and first bytes of modemst1/2, fsg, fsc,
  persist, dsp; FAT16 walk of `modem` (mba.mbn, wlanmdsp.mbn, qdsp6m.qdb, bdwlan.*, bdf_*, modem.mdt segment
  table vs the MPSS carve-out 0x8e400000..0x95c00000, MBA vs 0x96900000 + 2 MiB) and of `bluetooth`.

Reviewed for iOS 26: no writes, no SCM call, no MSS reset. Stage 3's partition reads take `sweet_ufs_lock` (the
root's own I/O lock), issue READ(10) only and restore the root LUN afterwards. **One boot with
`sweetwlan=3 sweetwlandelay=30` covers P0 and P1**; it can keep `sweet80211=2`. Output: `SWEET WLAN:` lines in the
console log / sweetlog. Stage 2 (Bluetooth power-up) is the only stage that writes registers and is not part of
this step.

What the output decides: whether MSS clocks/GDSC and the SMMU stream for WLAN (0x40) are left set up by the
bootloader (they were not on iOS 16: "WLAN sid 0x40 unmapped"), whether SMEM has the modem items, and whether the
phone's own `modem` partition holds an MBA/MPSS pair that fits the carve-outs. That fixes the inputs of P3
(MBA load, the first TZ-mediated step, run only with the user present).

### 5.1 Boot 30: `sweetwlan=3` result (2026-10-25, 74 lines, no crash)

| Area | Observed | Meaning for P3+ |
|------|----------|-----------------|
| MSS clocks | `mss cfg_ahb` on, `mss mfab_axis` on, `q6_memnoc_axi` and `snoc_axi` **off**; GPLL0 div vote bit17 set | modem is cold (expected: Linux q6v5-mss turns the AXI branches on itself) |
| SE6 (BT UART) | clocks gated, registers not read; TLMM gpio45-48 at func 0 | as on iOS 16; only stage 2 configures them |
| Rails | cmd-db: smpa4 0x40600, ldoa5 0x40f00, ldoa7 0x41300, ldoa17 0x40c00, ldoa23 0x41e00, ldoa25 0x42000 | RPMh addresses for the WCN3990 votes resolve |
| SMEM | `$TOC` v1, 15 entries; seen: global, 0<->5, 2<->3, 7<->8, 1<->8 | **incomplete: probe bug**, see below |
| apps SMMU | 76 SMRs / 45 CBs; **sid 0x40 (WLAN) has no SMR**; 0x740 -> SMR6, CB3 | we must map WLAN's stream ourselves (bypass or our own context bank) before the CE rings |
| EFS | modemst1, modemst2 (LUN 5) and fsg (LUN 4) 8 MiB each, non-zero; fsc, persist, dsp start with zeros | rmtfs can serve the real EFS (reads; writes dropped by rule) |
| `modem` FAT16 | `image/mba.mbn` 238304 B (fits the 2 MiB carve-out at 0x96900000); `modem.mdt` 30 phdrs, 28 loadable segments spanning **exactly** 0x8e400000..0x95c00000 (120 MiB carve-out), relocatable, hash segment 7400 B; `wlanmdsp.mbn` 3645892 B; `qdsp6m.qdb`; 29 `bdwlan.*`, 5 `bdf_*` | the phone's own MBA/MPSS fit the Linux beryllium carve-outs; WLAN firmware and board data are present (the modem fetches wlanmdsp.mbn through the QRTR TFTP service we host) |
| `bluetooth` FAT16 | crbtfw21.tlv **222988 B**, crnv21.bin 4591 B (+ the 2.0/1.1 variants) | the phone ships a newer BT rampatch than linux-firmware's 177060 B one we install; worth trying for BT later |

**Probe bug, fixed in 1104** (compile-checked): `wl_dump_smem` stepped the partition table by 32 bytes, but Linux
`struct smem_ptable_entry` is 48 bytes, so it read only real entries 0, 2, 4, 6 and 8 (printed as 0, 3, 6, 9, 12)
and skipped every odd one, which is where apps<->modem (hosts 0<->1) normally is. It also read
`offset_free_uncached` of a partition header at +16 instead of +12. "No apps<->modem partition" is therefore NOT
a finding yet. Next probe boot (same `sweetwlan=3`) with 1104 lists all 15 entries and the apps<->modem items.

Next after that: write P2/P3 for xnu-12377: the MSS power/clock/reset sequence (q6v5-mss sdm845: AOSS/PDC reset,
halt registers, the AXI branches above), the MBA load into 0x96900000 and the RMB handshake, as one gated patch
that stops at "MBA alive" and is run only with the user present (the first TZ-mediated step).

### 5.2 P3: MSS power-up and MBA boot (patches 1105 + 1106, compile-checked, NOT run)

Written 2026-10-25 against Linux v6.6 `qcom_q6v5_mss.c` (`sdm845_mss`: has_alt_reset, need_mem_protection, proxy
power domains cx/mx/mss, proxy clocks xo/prng, reset clocks iface/snoc_axi, active clocks bus/mem/gpll0_mss/mnoc_axi)
and `qcom_q6v5.c` (`qcom,qmp` load_state). Stage `sweetwlan=4` runs only when **`sweetmss=1`** is set as well:

1. `mba.mbn` (the phone's own, 238304 bytes) from the `modem` FAT16 partition (read-only).
2. AOSS QMP (0xc300000; doorbell apss_shared 0x17990000 +12 bit 0): link/channel handshake, then
   `{class: image, res: load_state, name: modem, val: on}`.
3. RPMh ARC votes cx.lvl, mx.lvl, mss.lvl at their highest level (1105: `sweet_rpmh_arc_vote`, active set, allow-list
   of those three; the VRM path for the BT rails is unchanged).
4. Checks that cfg_ahb, prng, boot_rom and mfab_axis are on (boot 30: they are); enables snoc_axi (BRANCH_HALT, polled).
5. Alt reset deassert: PDC modem sync reset (0xb2e0100 bit 9) asserted, `RMB_MBA_ALT_RESET`=1, AOSS MSS restart pulse
   (0xc2b0000 1 -> 0, 300 us each), `RMB_MBA_ALT_RESET`=0, PDC released. Then q6_memnoc_axi (BRANCH_VOTED, not polled).
6. MBA copied into its carve-out 0x96900000 (write-combined mapping) while the kernel still owns it, then two SCM
   hyp-assigns, HLOS -> MSS_MSA (RW): MPSS 0x8e400000+0x7800000, MBA 0x96900000+0x200000
   (SMC 0x42000c16, arginfo 0x1117, args 3..6 in an indirect buffer).
7. `RMB_MBA_IMAGE` = MBA address; QDSP6SS sleep clock on, `BOOT_CORE_START`=1, `BOOT_CMD`=1, wait `RMB_MBA_MSS_STATUS`
   bit 0 (10 ms), `RMB_PBL_STATUS` (1 s, 1 = success), `RMB_MBA_STATUS` (5 s, 1/2 = XPU unlocked = **"MBA ALIVE"**).
8. Teardown (always, unless `sweetmsskeep=1` and alive), in `q6v5_mba_reclaim` order: halt the q6/modem/nc AXI ports
   (TCSR 0x1f63000/0x1f65000/0x1f64000), alt reset assert, clocks off, hyp-assign both carve-outs back to HLOS (RWX),
   ARC votes to level 0, QMP load_state off. A carve-out that could not be reclaimed is reported and never touched.

Log lines: `SWEET MSS:` (+ `SWEET RPMH:` for the votes). Expected outcomes, in order of increasing progress: QMP not
acked; an ARC lookup/vote failure; an SCM hyp-assign error (TZ/hypervisor policy); boot FSM timeout; PBL status
other than 1; MBA status 0 (MBA did not start); `MBA ALIVE`.

Hazards (WIFI_BT_PLAN.md section 5, P3 = high): the first TZ/hypervisor-mediated action; the QHEE hypervisor may
treat an unexpected request or an SMMU fault as fatal and reset the SoC. A reset is recoverable (the phone reboots
to fastboot / Android bootloader as usual); nothing is written to storage. Run it **only with the user present**,
with `sweetwlandelay` long enough for the persistent log to be up, and read the log before any second attempt.

**Independent review (2026-10-25, against the Linux v6.6 sources) and fixes now in 1105/1106:**
* *Could reset the SoC:* the teardown voted cx.lvl/mx.lvl to level 0. An apps-DRV vote replaces ABL's vote, and
  Linux clamps rpmhpd to the top level before sync_state (`rpmhpd_aggregate_corner`). Fixed: `sweet_rpmh_arc_vote`
  refuses an off vote for cx/mx; only mss.lvl goes back to 0.
* *Could reset the SoC:* the write-combined MBA window stayed mapped after the carve-out went to the modem (Linux
  `memunmap`s before the assign). Fixed: `ml_io_unmap` right after the copy.
* *Wrong result:* the active clock gpll0_mss (GCC vote 0x52004 bit 17, clear on boot 30) and the proxy prng vote
  (bit 13, also clear) were not voted, and mnoc_axi's enable was not set. Fixed: set if clear, cleared in teardown.
* *Wrong result, rare:* an interrupted SMC was re-issued with the returned registers. Linux re-issues with x0 = 1,
  the original x1..x5, x6 = returned token, x7 = 0. Fixed in `ms_scm_call` (the GPU loader `sweet_a630_pas.c`
  has the same pattern; reported to its owner, not changed here).
* Minor: `out` initialised before printing, snoc enable cleared on failure too, QMP link-timeout path closes only
  the link.
* Checked and correct per the review: SCM function ID / arginfo / register vs indirect arguments / buffer layout /
  VMIDs and permissions; QMP offsets, handshake, doorbell and message; the boot order; the alt reset in both
  directions; the QDSP6 sequence; BRANCH_VOTED vs BRANCH_HALT; every physical address including the beryllium
  carve-outs; the teardown order; the ARC cmd-db parsing; the unchanged VRM path.

### 5.3 Boot 32-noinject: first P3 run (2026-10-25, user present)

ios26 + 0251 + 1104-1106, `sweetwlan=4 sweetmss=1 sweetwlandelay=60 sweet80211=2`. The probe ran to the end. With
1104 the SMEM table is complete: 14 partitions, including **apps<->modem (entry 10, offset 0xb9000, size 0x7c000)**,
empty (free-uncached 0x20, a cold modem), so boot 30's "no apps<->modem partition" was the probe bug. Then the
stage-4 banner was the **last line**: no SWEET MSS/RPMH line after it, no panic text, and the USB console went
silent (11:27 local). **The user confirms a hard freeze (no reboot).** Not retried; recovered with a boot without stage 4.

Reading: the next line would have followed reading `mba.mbn` (step 2), and no MSS/AOSS/RPMh register is touched
before that. But the USB console and the persistent log are buffered (the log was last flushed at the banner), so a
hard freeze can swallow the lines of the following steps: QMP open (first AOSS message-RAM access) and the RPMh
ARC votes are as likely. No SCM call was reached (each logs and flushes before it runs).

**1107** (compile-checked): every stage-4 step now logs `step N: ...`, flushes the persistent log and waits
1.5 s for the USB console *before* running, so the last `step N` line names the step that stopped the phone;
`sweetmssstep=N` stops cleanly before step N+1 (teardown runs) for bisection. Steps: 1 map MMIO, 2 read mba.mbn,
3 QMP open + load_state, 4 ARC votes, 5 clocks/alt reset, 6 MBA copy, 7 SCM hyp-assign, 8 QDSP6 boot.

A freeze rather than a reset points to a bus access that never completed (a block that is unclocked, unpowered or
protected without an error response), not a watchdog or an XPU/SMMU fatal error. First suspect is step 3, the first
new hardware access (AOSS QMP message RAM 0xc300000 and the apss_shared doorbell); then step 4 (RPMh TCS). Less likely:
step 2's UFS reads (they run under the root's I/O lock, so a hung read would also stop the root, but the console
thread does not use that lock). The 1107 trace run decides it in one boot.

### 5.4 Boot 34: traced re-run (1107, user present): freeze in the MBA copy

Steps 1-5 completed: mba.mbn read (238304 B); QMP magic 0x4d41494c v1, mcore mailbox 0x128+0x2d8, `load_state on`
consumed; ARC votes cx.lvl (0x30000, 8 levels, hlvl 7 = vlvl 384), mx.lvl (0x30010, 5 levels, hlvl 4), mss.lvl
(0x30060, 8 levels, hlvl 7); snoc_axi on, alt reset deassert, GCC vote 0x1619d7b -> 0x163bd7b, mfab CBCR 0x1. The
last line is **`step 6: copy MBA into its carve-out`** (printed, flushed, 1.5 s wait, then the copy): the CPU hung
writing the MBA carve-out 0x96900000 (write-combined mapping). User: "the phone is stuck now" (freeze, no reboot).

The carve-out addresses are right: the live DT's node names are stale (`modem_region@0x8e000000`,
`mba_region@0x96500000`) but their `reg` values are 0x8e400000+0x7800000 and 0x96900000+0x200000, both
removed-dma-pool, and the phone's own Android kernel (pil-q6v55-mss, `qcom,pil-mba-mem`) copies the MBA into that
region. What differs from Linux is the **order**: Linux copies the MBA in `q6v5_load()`, which runs before
`q6v5_start()` powers or releases anything; 1106/1107 copied it after step 5 had taken the MSS out of reset with its
bus clocks on.

**1108** (compile-checked): the copy is step 3, right after reading mba.mbn and before any MSS power, QMP, vote,
clock or reset (Linux order), and logs `MBA copied`. Steps now: 1 map, 2 read, 3 copy, 4 QMP, 5 ARC, 6 clocks + alt
reset, 7 SCM assign, 8 QDSP6 boot. Proposed next run: **`sweetmssstep=3`** first. It touches no modem hardware
(only the DDR write), so it isolates the question: a freeze means the normal world cannot write that carve-out from
xnu at all (mapping attributes / hypervisor stage-2); `MBA copied` means the order was the problem, and the full
stage can be tried next.
* 2026-10-25: **paused** by the user (GPU Metal / PosterBoard first). Next when resumed: the copy-only run (`sweetmssstep=3`) with 1108.
* 2026-10-25: **resumed** (side session of the GPU session, user present for each boot).

### 5.5 Boot 35-wlan: copy-only run (1108, `sweetmssstep=3`): freeze in the copy, modem untouched

**Kernel.** The handoff said 1108 was in `research/ios26/kernel-local/kernel.development.sweet`; it was not (that
kernel, 11:37, is the 1107 build that boot 33/33b also run: no `MBA copied` string). Built fresh from this branch
(ios26 22ce835 series = boot 33b's kernel + 1108, the only kernel patch since): `USE_KDK=1
XNU_LOCAL_DIR=<worktree>/research/xnu-local tools/xnu-local-build.sh 26.5` (~25 min), kernel sha256 `57a4fdb0...`.

**Image** `shim/out/enxerto-boot-ios26full-boot35-wlan.img` (sha256 `99819ceb...`), built without mkboot-full.sh so
that only the kernel and the stage-4 boot-args differ from boot 33b: boot 33's ADT taken out of its payload
(`/chosen` etc. unchanged; re-packing the 1107 kernel + that ADT + boot 33's cmdline with `tools/mkpayload.py`
reproduces boot 33's payload byte for byte), and the boot.img re-packed with boot 33's own Enxerto kernel blob
(`mkbootimg --header_version 1 ... --cmdline console=null`, which reproduces enxerto-boot-ios26full-boot33.img byte for
byte). Boot-args = boot 34's (boot 33's with `sweetwlan=4 sweetmss=1` and `sweetwlandelay=60`) plus
`sweetmssstep=3`; `sweetgpu=8`, the GPU-firmware ADT and everything else as in boot 33b.

**Result (16:14 UTC boot, user present):** probe stages 1/3 as on boot 32 (SMEM 14 partitions, apps<->modem empty,
sid 0x40 no SMR), then

```
SWEET MSS: step 1: map MMIO (no access)
SWEET MSS: step 2: read mba.mbn from the modem partition
SWEET MSS: mba.mbn 238304 bytes read from the modem partition
SWEET MSS: step 3: copy MBA into its carve-out (before any MSS power: Linux q6v5_load order)
```

and ~100 more console lines from other processes (they fit in step 3's 1.5 s pause), the last `exec
ReportSystemMemory`; then the USB console stopped, ping and SSH timed out, the user confirmed a freeze (no reboot).
No `MBA copied`, no `stopping before step 4`. Recovered with boot 33b (16:17 UTC, user OK; iOS up 16:18:31).
Console excerpt: `research/ios26/logs-wlan/boot35-wlan-usb.txt` (main checkout, not in git).

**Reading.** Nothing of the modem was touched before the copy (no QMP, no vote, no clock, no reset, no SCM), so the
order was not the cause: the normal world stops as soon as xnu touches the MBA carve-out 0x96900000 through
`ml_io_map_wcomb`. Two things are open, and boot 35 cannot tell them apart:
1. *Freeze or invisible panic.* All these images carry `sweetfb_noconsole=1`, which keeps panics off the screen
   (NOTES), and panics never reach the USB console (no `panic(cpu` in the whole live log). A data abort in the copy
   (e.g. a stage-2 / XPU abort reflected to EL1) would look exactly like this.
2. *Where it stops:* the mapping, the first read, the first write, or part-way through the 59 pages (part of the
   2 MiB protected).
Linux on this phone (Android's pil-q6v55-mss, mainline `q6v5_load`) writes the same region from EL1 after the same
ABL, so plain HLOS access is allowed in principle; what differs is how xnu maps/accesses it, or a state the Android
boot path sets up first. Also seen on this boot, not caused by the copy (the copy never ran): `hfs_mark_inconsistent:
Runtime corruption detected on iOSRoot` (hfs_cnode.c:946, pid 382) several times, most likely left by boot 34's
hard freeze; fsck is forced on the next mount.

**1109** (`1109-beryllium-mss-mba-copy-probe.patch`, built locally, not run): step 3 probes the carve-out one access
at a time, each line flushed with a pause first: `3a` mapped (VA printed), `3b` word 0 read, `3c` word 0 written and
read back, `3d` the copy in 64 KiB pieces. Proposed next run: boot 35-wlan's boot-args **without
`sweetfb_noconsole=1`** (a panic then shows on screen: photograph it), same `sweetmssstep=3`. If `3b` is the last
line, the region cannot even be read (stage-2/XPU: look at what Android does before pil, e.g. a hyp-assign back to
HLOS); if it panics, the panic text names the fault; if `3d` stops part-way, the protected part starts there.
  Prepared, not booted: `shim/out/enxerto-boot-ios26full-boot36-wlan.img` (sha256 `30b5c30e...`; kernel = the 1108
  build + 1109 via `xnu-local-build.sh --remake`, sha256 `2bc47ff2...`, boot 33's ADT and Enxerto blob, boot 35-wlan's
  boot-args minus `sweetfb_noconsole=1`). The GPU session has the phone (boot 33b, backboardd test); boot 36 waits for
  it to free the phone and for the user's OK.

### 5.6 Boot 36-wlan: 1109 probe with panics on screen: the copy works, the unmap panics

GPU session handed the phone over at 16:55Z; user OK; `sweetreboot fastboot` over SSH (the queue's own reboot did not
reach fastboot), boot sent 17:00:28Z. Image `enxerto-boot-ios26full-boot36-wlan.img` (1109, boot 35-wlan's args
without `sweetfb_noconsole=1`). Console:

```
SWEET MSS: step 3: copy MBA into its carve-out (before any MSS power: Linux q6v5_load order)
SWEET MSS: 3a: MBA carve-out 0x96900000+0x200000 mapped write-combined at 0xfffffec032cbc000; next: read word 0
SWEET MSS: 3b: word 0 reads 0; next: write word 0
SWEET MSS: 3c: word 0 written, reads back 0x464c457f (want 0x464c457f); next: copy in 64 KiB pieces
SWEET MSS: 3d: copy 0+0x10000
SWEET MSS: 3d: copy 0x10000+0x10000
SWEET MSS: 3d: copy 0x20000+0x10000
SWEET MSS: 3d: copy 0x30000+0xa2e0
```

then the USB console stopped. The screen (user photo, IMG_3982) showed the panic this time:
`vm_map_delete(...): Attempting to remove permanent VM map entry ... [0xfffffec032cbc000:...] @vm_map.c` (address as
printed by 3a). **The carve-out is readable and writable and the whole MBA was copied; the panic is the `ml_io_unmap`
after the copy.** In xnu-12377 `ml_io_map_wcomb()` = `io_map(..., unmappable=false)`, which allocates the kernel VA
with `KMA_PERMANENT`, and `ml_io_unmap()` = `pmap_remove` + `kmem_free`, which refuses a permanent entry. Boots 34 and
35 hit the same panic; `sweetfb_noconsole=1` hid it, and panics never reach the USB console, so they looked like
freezes. The 1106-1108 "copy order" theory was wrong; the copy was never the problem.

**1110** (`1110-beryllium-mss-mba-window-unmappable.patch`): the MBA window comes from
`ml_io_map_unmappable(MSS_MBA_PA, MSS_MBA_SIZE, VM_WIMG_WCOMB)` (non-permanent, write-combined), the one io mapping
xnu lets `ml_io_unmap` remove. No other sweet code calls `ml_io_unmap`. The 1109 probe lines stay (about 5 s of pauses).
Lesson for every stage-4 test: keep panics visible (no `sweetfb_noconsole=1`).

Prepared, not booted (kernel = 1110 remake, sha256 `263851eb...`; boot 33's ADT and Enxerto blob; boot 36-wlan's args):
`enxerto-boot-ios26full-boot37-wlan-copy.img` (`sweetmssstep=3`: expect `MBA copied`, `stopping before step 4`, an
empty teardown) and `enxerto-boot-ios26full-boot37-wlan-full.img` (no `sweetmssstep`: the whole stage 4, steps 4-6 as
on boot 34, then the first SCM hyp-assign (step 7) and the QDSP6 boot (step 8), teardown; a SoC reset in step 7/8 is
possible and recoverable).

### 5.7 Boot 37-wlan-full: **MBA ALIVE** (1110, whole stage 4, user present)

**2026-10-25 17:09:44Z, `enxerto-boot-ios26full-boot37-wlan-full.img`** (1110 kernel; boot 36-wlan's args without
`sweetmssstep`). Every step completed, the phone stayed up (iOS and SSH fine afterwards):

| Step | Result |
|------|--------|
| 2 mba.mbn | 238304 B |
| 3 copy | 3a mapped (non-permanent VA 0xfffffecf5c100000), word 0 read 0 / write ok, 4 pieces, **`MBA copied to 0x96900000`**: 1110 fixed the unmap |
| 4 QMP | magic `LIAM` v1, mailbox 0x128+0x2d8, `load_state on` consumed |
| 5 ARC | cx.lvl hlvl 7, mx.lvl hlvl 4, mss.lvl hlvl 7: each TCS0 done, cmd-status 0x10101 |
| 6 clocks/reset | GCC vote 0x1619d7b -> 0x163bd7b, mfab_axis CBCR 0x1 |
| 7 SCM | hyp-assign MPSS 0x8e400000+0x7800000 and MBA 0x96900000+0x200000 HLOS(3) -> MSS_MSA(15) RW: `completed=1 status=0 result=0` both: **the first TrustZone/hypervisor calls work** |
| 8 QDSP6 | **PBL status 0x1 after 65 ms, MBA status 0x1 after 0 ms (XPU unlocked): `MBA ALIVE`** |
| teardown | AXI q6/modem/nc already idle, alt reset asserted, clocks off; hyp-assign MBA and MPSS back to HLOS RWX `status=0` both; mss.lvl -> 0, cx/mx off votes refused by design (kept at top); QMP `load_state off` consumed |

Console: `research/ios26/logs-wlan/boot37-wlan-full-usb.txt` (main checkout, not in git).

**Next (P4, not written): MPSS load and boot**, Linux `q6v5_mpss_load()` order, from the state "MBA alive" (so
`sweetmsskeep=1` semantics, i.e. no teardown in between):
1. `modem.mdt` from the `modem` FAT16 partition: ELF header + program headers + hash segment (7400 B). Copy the
   metadata into a physically contiguous, DMA-able buffer the modem may read (Linux: `dma_alloc_attrs` +
   hyp-assign of that buffer to MSS for the auth call), write its address to `RMB_PMI_META_DATA_REG`, then
   `RMB_MBA_COMMAND_REG = RMB_CMD_META_DATA_READY` and wait for `RMB_MBA_STATUS_REG == RMB_MBA_META_DATA_AUTH_SUCCESS`
   (3). The metadata buffer must sit below 4 GiB and outside xnu's RAM (xnu RAM starts at 0x1_00000000), e.g. a free
   slice of the low bank.
2. Each loadable segment `modem.bNN` (28 of them) copied into the MPSS carve-out at its relocated address: the carve-out
   currently belongs to MSS after step 7, so Linux hyp-assigns it back to HLOS (`q6v5_xfer_mem_ownership(...,
   false, ...)`) for the copy, then to MSS again; after each segment (or once) write `RMB_PMI_CODE_START_REG` /
   `RMB_PMI_CODE_LENGTH_REG` (running length) and `RMB_MBA_COMMAND_REG = RMB_CMD_LOAD_READY`, then wait
   `RMB_MBA_STATUS_REG == RMB_MBA_AUTH_COMPLETE` (5) (10 s).
3. Then the modem runs: wait for the `ready` SMP2P bit (inbound smp2p from the modem, item 435 in SMEM), handover
   (proxy votes released), then rmtfs (EFS reads), QRTR over GLINK/SMEM, TFTP for `wlanmdsp.mbn`, then WLFW (QMI) to
   bring up the WCN3990.
Each step again one boot per user OK, panics visible, same 1.5 s step trace.

### 5.8 P4 written: MPSS load and start (1111, built, NOT run)

`1111-beryllium-mpss-load.patch`, from "MBA alive", only with **`sweetmpss=1`** (`sweetmpsshold=N`, default 15 s, the
watch time; `sweetmsskeep=1` leaves a modem that reported ready running). Linux v6.6 `q6v5_mpss_load()` /
`q6v5_mpss_init_image()` / `qcom_mdt_read_metadata()` order, steps traced like 1-8:

| Step | What | Linux |
|------|------|-------|
| 9 | read `image/modem.mdt`; metadata = ELF header segment (ph0 `p_filesz`) + hash segment (packed after the header, inside the .mdt, or its `.bNN` file) | qcom_mdt_read_metadata |
| 10 | `RMB_PMI_CODE_LENGTH = 0`; metadata copied to the fixed low slice **0xe0000000** (RMB_PMI_META_DATA is 32-bit, xnu RAM is above 4 GiB; unmapped before the assign), hyp-assign HLOS -> MSS, `META_DATA_READY`, wait status 3 (1 s), assign back | q6v5_mpss_init_image |
| 11 | MPSS reclaim (HLOS) then shared (HLOS RWX + MSS RW); each valid segment (PT_LOAD, not hash, memsz != 0) into its own 16K-aligned write-combined window from `modem.bNN` in 1 MiB pieces, tail zeroed; first segment sets `CODE_START` (= 0x8e400000, relocatable) + `LOAD_READY`, every segment the cumulative `CODE_LENGTH`; MBA status < 0 = auth failure | q6v5_mpss_load loop |
| 12 | MPSS to MSS only, wait `AUTH_COMPLETE` (4, 10 s): `MPSS AUTHENTICATED` | q6v5_mpss_load end |
| 13 | poll the modem's SMP2P item **435** (inbound; `qcom,smem = <435>, <428>` is [inbound, outbound]) in the apps<->modem SMEM partition every 100 ms for `sweetmpsshold` s, print every entry change; `slave-kernel` bit 1 = `MPSS READY` (then the MBA region goes back to HLOS like q6v5_start), bit 0 = fatal (crash reason = SMEM item 421 in the global partition) | qcom_q6v5_wait_for_start |

Teardown after a load: like Linux, the MPSS carve-out is *not* reclaimed (only possible with an MBA running); it stays
with the modem until the next reboot. The running modem is stopped the crash-path way (AXI halt + reset), since no
SMP2P stop handshake exists here. `ms_assign` became `ms_assign_list` (several source/destination VMIDs) plus
`ms_xfer` = `q6v5_xfer_mem_ownership`; step 7's MPSS assign goes through it (same SCM call as boot 37).

Independent review against the fetched Linux v6.6 sources (qcom_q6v5_mss.c, qcom_q6v5.c, mdt_loader.c, qcom_scm.c,
smp2p.c, smem.c, sdm845.dtsi): order, register values, SCM layout, ownership flags and SMEM/SMP2P layouts match.
Fixed from it: the inbound item is 435, not 428 (checked in smp2p.c: `SMP2P_INBOUND 0`); a fatal bit now means "not
running" even after ready; crash reason from the global partition only. **Open, by choice:** nothing allocates the
apps-side outbound SMP2P item 428 or rings the modem's doorbell (Linux `qcom_smp2p_alloc_outbound_item`); if the modem
waits for it, step 13 shows no `slave-kernel` entry and that is the next patch (it writes the shared SMEM allocator
under the TCSR hwlock).

Image `shim/out/enxerto-boot-ios26full-boot38-wlan-mpss.img` (sha256 `505957b7...`, kernel `657e6e16...` = boot 33b's
kernel + 1108-1111): boot 33's ADT/Enxerto, boot 33's args without `sweetfb_noconsole=1`, plus `sweetwlan=4 sweetmss=1
sweetmpss=1 sweetmpsshold=20`. The GPU session has no kernel/boot-arg change pending (combined-image rule), so this is
the only change. Not booted; needs the phone free and the user's OK. Expected risks: an MBA rejection (status < 0) is
harmless; a modem that runs may stay with its carve-out until reboot; the forced halt of a running modem is Linux's
crash path.

### 5.9 Boot 38-wlan-mpss: **MPSS AUTHENTICATED and running**; no SMP2P entries yet

**2026-10-25 17:44:14Z** (user OK, user present; also the GPU session's luma test via a userdata env file, no image
change), `enxerto-boot-ios26full-boot38-wlan-mpss.img` (1111). Steps 1-8 as boot 37 (PBL 0x1 after 67 ms, MBA 0x1).
Then:

| Step | Result |
|------|--------|
| 9 | `modem.mdt` 8412 B, 30 program headers, hash ph1: metadata 1012 + 7400 = 8412 B (hash packed after the ELF header) |
| 10 | metadata 0xe0000000+0x3000 HLOS -> MSS (status 0); **MBA status 3 after 7 ms (header authenticated)**; assigned back (status 0) |
| 11 | MPSS reclaim MSS -> HLOS and share HLOS+MSS (status 0 both); 28 segments ph2..ph29 (`modem.b02`..`b29`; ph14/19/29 memory only) in **918 ms**, code length 0x77300f1, MBA status 3 throughout (no error) |
| 12 | MPSS HLOS+MSS -> MSS (status 0); **MBA status 4 after 0 ms: `MPSS AUTHENTICATED`** |
| 13 | first poll: **SMP2P item 435 exists** at SMEM +0xb9030 (apps<->modem partition): magic ok, version 1, features 0x1, pid 1->0, **0 of 16 entries valid**; no entry appeared in 20 s (no `slave-kernel`, so no ready/fatal bit) |
| teardown | AXI q6 idle, **AXI modem halt ack 0 idle 0** (the modem port was busy: the MPSS was running), nc idle; MBA back to HLOS (status 0); MPSS left with the modem (owners 0x8000) until reboot as designed; mss.lvl 0, cx/mx kept; QMP `load_state off` consumed |

The phone stayed up (SSH fine afterwards). Console: `research/ios26/logs-wlan/boot38-wlan-mpss-usb.txt` (main
checkout, not in git). Also on this boot (not modem-related): `hfs_mark_inconsistent` on iOSRoot keeps appearing
(hfs_cnode.c:946, pid 582); the root volume needs an fsck.

**Reading:** the modem firmware booted far enough to create its SMP2P outbound item, so the MBA -> MPSS hand-over
works. It adds its entries ("slave-kernel" with the ready bit) only after SMP2P negotiation, and the apps side has
neither its own outbound item (428) nor ever rang the modem's doorbell. **Next (1112):** Linux
`qcom_smp2p_alloc_outbound_item` + `qcom_smp2p_kick`: allocate item 428 in the apps<->modem partition under the SMEM
hwlock (TCSR mutex 3; `qcom_smem_alloc` private-partition path: new entry at `offset_free_uncached`, canary 0xa5a5,
size/padding, then advance the free offset), header magic/local 0/remote 1/total 16/features, `version = 1` after a
barrier, add the "master-kernel" entry (stop bit for a clean stop later), then the doorbell: apss_shared 0x17990000
+12, bit 14 (`mboxes = <&apss_shared 14>`). Then poll 435 again for "slave-kernel" ready. First write into shared
SMEM: gated, traced, one boot with the user present.

### 5.10 1112: apps-side SMP2P (outbound item 428, doorbell, negotiation, clean stop): built, NOT run

`1112-beryllium-mpss-smp2p-outbound.patch`, still only with `sweetmpss=1`. New **step 9** (before the modem.mdt
work, so the item exists before the MPSS starts, as Linux's smp2p probe does at boot); the old 9-13 are now 10-14.

* **SMEM allocation** (`qcom_smem_alloc` -> `qcom_smem_alloc_private`, the first write into shared SMEM): TCSR mutex
  3 (0x1f43000; write 1, read back 1, unlock = 0; 1 s timeout), apps<->modem partition, walk the uncached list
  (canary 0xa5a5; an existing 428 is reused only if it is at least 340 bytes; the walk must end exactly at
  `offset_free_uncached`), new entry `{0xa5a5 | 428 << 16, 344, padding_data 4, padding_hdr 0}` below
  `offset_free_cached`, then the free offset advances. Nothing prints while the hwlock is held.
* **Outbound item** (`qcom_smp2p_alloc_outbound_item` + probe): zeroed, magic `$SMP`, features SSR_ACK, local pid 0,
  remote pid 1, total 16; `version = 1` written last; doorbell; entries `master-kernel` (bit 0 = stop) and `ipa` in
  DT order; doorbell again. Doorbell = `qcom,sdm845-apss-shared` +12, `BIT(14)` (`mboxes = <&apss_shared 14>`).
* **Step 14** now negotiates on every 100 ms poll (`qcom_smp2p_negotiate`: equal versions, `features &= in`) and
  acknowledges restart-done (bit 0 of the inbound flags -> bit 1 of ours, plus a doorbell), like the interrupt handler.
* **Clean stop** (`qcom_q6v5_request_stop`), only after ready: set stop (master-kernel bit 0), doorbell, wait up to
  5 s for stop-ack (slave-kernel bit 3), clear, doorbell; then the AXI halt/reset teardown as before. At the end
  `valid_entries = 0` (smp2p unwind).

Second independent review against the fetched Linux v6.6 sources (smem.c, smp2p.c, qcom_hwspinlock.c,
qcom_q6v5.c, qcom-apcs-ipc-mailbox.c, sdm845.dtsi): no must-fix; its three should-fix points (no printf under the
hwlock, size check on reuse and the walk-end check, unwind of valid_entries) are applied.

Image `shim/out/enxerto-boot-ios26full-boot39-wlan-smp2p.img` (sha256 `c23f2e45...`, kernel `37d1bab0...` = boot 33b's
kernel + 1108-1112): boot 38's args with `sweetmpsshold=30`. The GPU side needs nothing in the image. Not booted:
needs the user's OK; afterwards tell the GPU session when iOS is up (backboardd trace).

### 5.11 Boot 39-wlan-smp2p: **MPSS READY** and a clean stop (1112, user present)

**2026-10-25 18:23:20Z** (user OK, given here; also the GPU session's glass test, no image change),
`enxerto-boot-ios26full-boot39-wlan-smp2p.img`. Steps 1-8 as before (MBA ALIVE). Then:

| Step | Result |
|------|--------|
| 9 | SMEM item 428 allocated at +0xb9030 (340 B), free-uncached 0x20 -> 0x188 (the partition's first entry); header + `master-kernel` + `ipa`, doorbell bit 14 twice |
| 10-11 | modem.mdt as boot 38; metadata **status 3 after 6 ms** |
| 12-13 | segments as boot 38; MPSS to MSS (status 0); **MBA status 4: `MPSS AUTHENTICATED`** |
| 14 | modem item **435 at +0xb9198, 2/16 entries** at the first poll; **negotiated (version 1, features 0x1 = SSR ack)**; entries `smp2p` = 0 and **`slave-kernel` = 0x2 after 11 ms: `MPSS READY`**; MBA region back to HLOS (status 0); no further change in 30 s (no handover bit 2, no fatal) |
| teardown | **stop request: stop-ack after 20 ms (slave-kernel 0xa = ready + stop-ack)**; AXI q6 idle, modem `halt ack 0 idle 0` (as boot 38), nc idle; MPSS left with the modem until reboot; mss.lvl 0, cx/mx kept; QMP `load_state off` consumed; `valid_entries` cleared |

No panic, phone up (SSH fine). Console: `research/ios26/logs-wlan/boot39-wlan-smp2p-usb.txt` (main checkout, not in
git). **The modem firmware runs on iOS 26 and talks SMP2P with the kernel: the MSS half of W4 is done.**

Notes: the modem did not raise "handover" (bit 2) in 30 s. In Linux that releases the proxy votes after the modem has
its own; it may come later or depend on services we do not run yet (rmtfs, QRTR). The modem AXI port still does not
ack the halt after a clean stop; Linux only logs that too.

**Next (W5), in Linux's order, each again gated and one boot per user OK:**
1. **rmtfs** (`qcom,rmtfs-mem`, 2 MiB shared memory + the rmtfs QMI service that serves modemst1/modemst2/fsg/fsc
   reads; writes dropped by rule). Without it the modem cannot read its EFS (calibration, NV) and will not bring up
   WLAN.
2. **QRTR over GLINK/SMEM** (the IPC router the modem uses for every QMI service; GLINK SMEM transport = SMEM items
   478/479/480 FIFOs + the same doorbell).
3. **TFTP/QMI service for `wlanmdsp.mbn`** and the board file, then **WLFW** (QMI service 0x45: capability, BDF
   download, mode on) to bring up the WCN3990 WLAN core; the copy engine rings and the SMMU stream 0x40 come after.

### 5.12 W5 / 1113: rmtfs for the running modem (QRTR over GLINK over SMEM): built, NOT run

The modem reaches rmtfs as QMI service 14 over QRTR, which runs on the GLINK channel "IPCRTR" over SMEM, so the
"rmtfs step" is four layers in one patch (`1113-beryllium-mpss-rmtfs-qrtr-glink.patch`), gated by **`sweetrmtfs=1`**
on top of `sweetmpss=1`. With the gate, step 14 waits only for ready (5 s, like `qcom_q6v5_wait_for_start`), then
**step 15** (Linux starts the GLINK subdevice after the remoteproc started) and a polled service loop for
`sweetmpsshold` seconds:

* **rmtfs buffer** (`rmtfs_mem.c`): 0xf6301000 + 2 MiB (mainline beryllium `rmtfs_mem`), hyp-assigned HLOS -> HLOS
  RW + MSS RW, kernel window write-combined; assigned back to HLOS RW in the teardown. The 16 KiB-page window also
  covers 4 KiB before and 12 KiB after the buffer: plain RAM outside every fixed carve-out and never assigned, so it
  stays HLOS-owned (review note, kept as is).
* **GLINK SMEM** (`qcom_glink_smem.c`): we allocate the descriptor (item 478, 32 B: tx tail/head, rx tail/head) and
  our TX FIFO (479, 16 KiB, its real item size is used), the modem's FIFO is item 480; head aligned to 8, 16-byte TX
  reserve, doorbell apss_shared +12 bit 12.
* **GLINK native** (`qcom_glink_native.c`): VERSION/VERSION_ACK with feature INTENT_REUSE; the modem opens
  "IPCRTR" -> OPEN_ACK with its id, our OPEN (lcid 1), wait for its OPEN_ACK, then 5 x 1 KiB reusable intents;
  TX_DATA/CONT into our intents, RX_DONE_W_REUSE; RX_INTENT_REQ answered with a one-shot intent + ack; our TX uses
  the smallest free modem intent, else the packet waits in a small queue and one RX_INTENT_REQ goes out (no nested
  waiting). Other channels the modem opens are only logged (Linux acks them only when a driver binds).
* **QRTR** (`af_qrtr.c`, `ns.c`): v1 header out, v1 and v2 in; local node 1; on the modem's HELLO: our HELLO +
  NEW_SERVER {service 14, instance field 1 (= instance 0 << 8 | version 1), node 1, port 0x4000} (fallback: sent 3 s
  after the channel opened if no HELLO came); RESUME_TX for confirm_rx; every modem NEW_SERVER/DEL_SERVER is logged
  (it shows what the modem wants next, e.g. TFTP for wlanmdsp.mbn).
* **rmtfs server** (linux-msm/rmtfs): OPEN `/boot/modem_fs1|fs2|fsc|fsg` -> modemst1/modemst2/fsc/fsg (caller id =
  table index), ALLOC_BUFF -> 0xf6301000, RW_IOVEC (sectors of 512 B <-> absolute buffer addresses), CLOSE,
  GET_DEV_ERROR (status 0). **Reads come from UFS; the first write to a partition makes a RAM copy of it (rmtfs -o) and
  every later read/write of that partition uses the copy: storage is never written.**

Third independent review against the downloaded Linux v6.6 + linux-msm/rmtfs sources: no must-fix; applied: queued TX
instead of a nested wait, QRTR v2 parsing, item 479's own size, 64 modem-intent slots, an overflow-safe chunk bound
and no delivery of dropped payloads, RESUME_TX node from the header.

Image `shim/out/enxerto-boot-ios26full-boot40-wlan-rmtfs.img` (sha256 `7e520fd4...`, kernel `5df7052c...` = boot 33b's
kernel + 1108-1113): boot 39's args with `sweetrmtfs=1 sweetmpsshold=60`. GPU: the dock-glass change (Chlorophyll
4a64d87) is userland only and rides along; tell the GPU session once the home screen is up. Not booted: needs the
user's OK.

### 5.13 Boot 40-wlan-rmtfs: **rmtfs served over QRTR/GLINK, the modem read its EFS and booted fully**

**2026-10-25 18:52Z** (user OK, given here; also the GPU session's dock-glass check, userland only),
`enxerto-boot-ios26full-boot40-wlan-rmtfs.img` (1113, `sweetrmtfs=1 sweetmpsshold=60`). Steps 1-14 as boot 39 (MPSS
READY after 11 ms). Step 15 and the 60 s service loop:

* rmtfs buffer 0xf6301000+0x200000 HLOS -> HLOS RW + MSS RW (status 0).
* **GLINK**: our descriptor +0xb9300, our TX FIFO +0xbd340 (16 KiB), the modem's FIFO (item 480) at +0xb9330 (16 KiB);
  modem VERSION 1 features 0x7 -> acked with 0x1, our VERSION acked with 0x1. The modem opened `glink_ssr`, `IPCRTR`,
  `SSM_RTR_MODEM_APPS`, later `apr_voice_svc`, `apr_apps2`, `LOOPBACK_CTL_MPSS`, `DS`, `DATA1`-`DATA4`, `DATA11` (only
  IPCRTR is served); **IPCRTR open both ways**, 5 x 1 KiB intents; three 52-byte intent requests granted.
* **QRTR**: HELLO from node 0 -> our HELLO + NEW_SERVER rmtfs (14, instance 1, 1:0x4000). The modem then announced
  **~40 QMI services** (in order): 0x42, 0x2b, 0xf, 0xe4, 0xffe4, 0x15, 0x18, 0x17, 0x16, 0x24, 0x31, 0x36, 0x11,
  0x4a, 0x1002, 0x22, 0x29, 0x37, 0x9, 0x32, 0x3, 0xc, 0xa, 0x1, 0x4, 0x1a, 0x7, 0x8, 0x1d, 0x2f, 0xb, 0x2a, 0x2, 0x5,
  0x30, 0x44, 0x10, 0x21, 0x12, 0x47 (WDS 1, DMS 2, NAS 3, QOS 4, ..., UIM 0xb, LOC 0x10, ...). **No WLFW (0x45)**
  and no data to an unknown port (the modem never asked for a TFTP server: none was announced).
* **rmtfs**: open `/boot/modem_fs1` -> modemst1 (caller 0, 8 MiB), `/boot/modem_fs2` -> modemst2 (1), `/boot/modem_fsg`
  -> fsg (3), `/boot/modem_fsc` -> fsc (2, 256 KiB); `/boot/modem_fsg_oem_1` and `_oem_2` rejected (unknown to upstream
  rmtfs as well); alloc 2 MiB -> 0xf6301000; **reads**: modemst1 sector 1, modemst2 sector 1, modemst2 4094 sectors
  from 2 (2 MiB) - all ok. **No writes** in 60 s.
* SMP2P `slave-kernel` 0x2 (ready, 11 ms) -> **0x6 at 2083 ms: handover** (boot 39, without rmtfs, never got it).
* Summary line: 61 packets in, 13 out; rmtfs 3 reads (2 MiB), 0 writes. Stop request: **stop-ack after 190 ms**
  (`slave-kernel` 0xe); rmtfs buffer back to HLOS RW (status 0); MPSS left with the modem until reboot; no panic, phone
  up, iOS/backboardd/SpringBoard fine throughout.

Console: `research/ios26/logs-wlan/boot40-wlan-rmtfs-usb.txt` (main checkout, not in git).

**Reading:** the IPC stack (GLINK SMEM, QRTR, QMI) works end to end on iOS 26, the modem has its EFS and runs its full
service set. Two things are missing for Wi-Fi:
1. **TFTP server** (`tqftpserv`, QRTR service 4096 version 1): the modem's WLAN PD loads `wlanmdsp.mbn` (and reads
   board data) through it; until one is announced the modem never asks. Serve `/readonly/firmware/image/*` from the
   phone's `modem` partition (read-only), log every request path.
2. Then **WLFW** (QMI service 0x45) should appear; next comes the WLFW client (indication register, host capability,
   BDF download from `bdwlan.*`, WLAN mode on) to bring up the WCN3990 core.

### 5.14 1114: TFTP over QRTR for the modem's WLAN firmware (read-only): built, NOT run

`1114-beryllium-mpss-tftp.patch`, gate **`sweettftp=1`** (on top of `sweetrmtfs=1`), a kernel copy of linux-msm
`tqftpserv`:
* **Service**: QRTR service 4096 version 1 (instance field 1) at 1:0x4001, announced with rmtfs after the modem's
  HELLO. RRQ/WRQ arrive there; every transfer runs on its own port (`qrtr_open(0)` + `connect()`), errors before a
  session come from a fresh port.
* **Protocol**: RFC 1350 + tqftpserv's options (blksize 8-65464, timeoutms, tsize, wsize, rsize, seek; unknown ones
  ignored), OACK in tqftpserv's order echoing the values; the reader uses tqftpserv's exact arithmetic (window of
  wsize blocks per ACK, `rsize % blksize` cut of the last block, close once `last * blksize > rsize`; without rsize
  only block 1, as tqftpserv), ERROR 9 "end of transfer" closes; the window is sent as fast as the GLINK TX queue
  takes it (no dropped blocks); DEL_CLIENT/BYE end that client's transfers; 8 slots, the oldest is evicted.
* **Paths** (`translate.c`): `/readonly/firmware/image/X`, `/readonly/vendor/firmware_mnt/image/X`,
  `/readonly/vendor/firmware/X` and `/readonly/firmware/modem_prX` -> the phone's **`modem` partition `image/...`,
  read-only** (8.3 names only, the FAT reader's limit); `/readwrite/X` -> **RAM files** (8 x 256 KiB, read back by later
  RRQs, dropped at teardown). sanitize_path (no empty component, no `..`). **Storage is never written.**
* GLINK TX now sends messages over 8 KiB in TX_DATA + TX_DATA_CONT chunks into one modem intent
  (`__qcom_glink_send`), a failed chunk fails the send; queued packets are heap copies.

Fourth independent review against the downloaded tqftpserv + GLINK sources: no must-fix; applied: window pumping
instead of a burst into a 32-entry queue, failed-chunk handling, writer tsize/timeoutms echoed, the modem_pr prefix,
case-insensitive mode, slot eviction, 32-bit option checks and a separate seek flag, name length/8.3 checks.

Image `shim/out/enxerto-boot-ios26full-boot41-wlan-tftp.img` (sha256 `09a90d2c...`, kernel `401c6c26...` = boot 33b's
kernel + 1108-1114): boot 40's args plus `sweettftp=1`. Expected: the modem's WLAN PD asks for `wlanmdsp.mbn`
(3645892 B in the modem partition), then WLFW (QMI service 0x45) appears among the modem's services. Not booted: needs
the user's OK.
* 2026-10-25 19:44-19:48Z: **boot 41 did not reach the Wi-Fi stage (twice)**, user OK given here. 1st send (19:44:14) went
  to Bergamota fastboot; iOS shut down ("Rebooting to device recovery environment") and the phone ended in ABL
  fastboot without our kernel running. Retry from ABL (19:46:54): our kernel booted, but ~25 s in a shell ran
  `toybox` + `sweetreboot` (bootloader) and launchd rebooted, before stage 4 (`sweetwlandelay=60`). Not the GPU
  session's inject (it only writes bgmtl-bb.off); its guess: the Bergamota app's auto-reboot (SSH `sync; sweetreboot`
  when an item is still waiting and iOS is up). The user then reported an "initproc" panic on the boot that started
  19:47:44, possibly the GPU session's Apple6 env (BGMTL_FAMILY=6) crash-looping backboardd; the GPU session is
  recovering with boot 39 and removing the env. **Boot 41 is on hold** until the GPU session reports; rerun it as a
  Wi-Fi-only test with nothing else queued.

### 5.15 Boot 41-wlan-tftp (Wi-Fi only, after the recovery): **TFTP works**; no wlanmdsp.mbn request yet

**2026-10-25 20:50Z** (user OK given here; exactly one queue item, the app's auto-reboot delivered it; userdata had
been reflashed by the GPU session 20:32-20:40Z), `enxerto-boot-ios26full-boot41-wlan-tftp.img` (1114). Stages 1-14 and
rmtfs exactly as boot 40 (MPSS READY 11 ms, handover 2082 ms, modemst2 2 MiB read, ~40 QMI services, no 0x45). TFTP
(service 4096 announced with rmtfs after the modem's HELLO), every request:

| Request | Result |
|---------|--------|
| WRQ `/readwrite/server_check.txt` (blksize 7680, wsize 10) | 5 bytes, kept in RAM: the modem's server check passed |
| RRQ `/readwrite/ota_firewall/ruleset` (x2) | not found (as on Linux without it) |
| RRQ `/readwrite/mcfg.tmp`, WRQ (1 byte), RRQ (stat: ERROR 9 end of transfer), WRQ (512, then DEL_CLIENT before any data) | the modem's mcfg scratch file, RAM only |
| RRQ `/readonly/firmware/image/modem_pr/mcfg/configs/mcfg_hw/mbn_hw.dig` (stat, then rsize 32) | **32 bytes served** from the modem partition |
| RRQ `.../mcfg_sw/mbn_sw.dig` (stat, then rsize 32) | **32 bytes served** |

60 s: 92 packets in, 31 out; stop-ack 190 ms; rmtfs buffer back; no panic, phone up (SSH fine). Console:
`research/ios26/logs-wlan/boot41-wlan-tftp-usb.txt` (main checkout, not in git). The 19:44/19:47Z attempts failed
because two boot-41 items were queued (the Bergamota app's auto-reboot cut the first boot short) and the GPU session's
Apple6 test crash-looped backboardd (initproc panic): queue exactly one item.

**Reading:** the TFTP server works with the modem's real client (stat via tsize + ERROR 9, rsize reads, windowed
writes). The modem does not ask for `wlanmdsp.mbn`: on Linux the WLAN protection domain (`msm/modem/wlan_pd`) is only
started once the AP answers the modem's **service-locator** queries: `pd-mapper` (QMI SERVREG_LOCATOR, service 0x40)
tells the modem which PDs exist (`wlan/fw` -> `msm/modem/wlan_pd`, instance 74). The modem already offers
SERVREG_NOTIFIER (0x42). **Next (1115): a kernel pd-mapper** (service 0x40 v1, GET_DOMAIN_LIST answering from the
beryllium/sdm845 JSON of linux-msm/pd-mapper); then the WLAN PD should load `wlanmdsp.mbn` over this TFTP server and
WLFW (0x45) should appear.

### 5.16 1115: kernel pd-mapper (SERVREG_LOCATOR) for the WLAN protection domain: built, NOT run

`1115-beryllium-mpss-pd-mapper.patch`, gate **`sweetpdm=1`** (on top of `sweetrmtfs=1`, normally with `sweettftp=1`),
a copy of Linux v6.12 `drivers/soc/qcom/qcom_pd_mapper.c`:
* **Service**: QMI SERVREG_LOCATOR, QRTR service 0x40, instance field 0x101 (`qmi_add_server`: version 0x101 |
  instance 0 << 8) at 1:0x4002, announced with rmtfs/TFTP after the modem's HELLO.
* **GET_DOMAIN_LIST (0x21)**: service name (TLV 1), optional offset (TLV 0x10) -> result, total_domains (0x10),
  db_rev_count 1 (0x11), domain list (0x12: u8 count, entries {u8 name length, name, u32 instance, u8 0, u32 0}),
  TLVs in `servreg_get_domain_list_resp_ei` order; an unknown service gets total 0 and no list, as in Linux.
  **PFR (0x24)**: logged and answered with success. Every request is logged.
* **Table**: `sdm845_domains`: msm/adsp/audio_pd (74, avs/audio), msm/adsp/root_pd (74), msm/cdsp/root_pd (76),
  msm/modem/root_pd (180), **msm/modem/wlan_pd (180, kernel/elf_loader + wlan/fw)**, msm/slpi/root_pd (90),
  msm/slpi/sensor_pd (90); every domain also serves `tms/servreg`. (Correction to 5.15: the modem PDs are instance
  180; 74 is the ADSP.)
* A NEW_SERVER for service 0x45 is logged as `WLFW is up`; the 1115 summary line counts pd-mapper requests and
  says whether WLFW appeared.

Checked: a userspace harness around `pdm_rx` (wlan/fw, tms/servreg with offsets 0/5, an unknown service,
kernel/elf_loader), and a fifth independent review that decoded the responses against Linux `qmi_encdec.c`: no
defects (harmless differences: malformed requests get MALFORMED_MSG instead of being dropped).

Image `shim/out/enxerto-boot-ios26full-boot42-wlan-pdm.img` (sha256 `626043b5...`, kernel `76b6c142...` = boot 33b's
kernel + 1108-1115; same recipe that rebuilds boot 41's image byte for byte): boot 41's args plus `sweetpdm=1`, and
`sweetmpsshold=90` (was 60) so `wlanmdsp.mbn` (3645892 B) has time to load. Expected: GET_DOMAIN_LIST requests
(e.g. `wlan/fw`, `tms/servreg`), then TFTP RRQ for `wlanmdsp.mbn`, then `WLFW is up` (service 0x45). Not booted:
needs the user's OK; queue exactly one item.

### 5.17 Boot 42-wlan-pdm (combined with a GPU log test): **WLFW is up**; then my raw-disk read froze the phone

**2026-10-26 ~11:41Z** (the user approved "Combine (boot 42)" to the GPU session, which queued the single item;
nothing in the image for the GPU side). MBA ALIVE (PBL 0x1 after 65 ms), metadata status 3, 28 segments in 1 s,
MPSS up, rmtfs (modemst 2 MiB read), TFTP (server check, mcfg configs as boot 41), then the 90 s summary:

```
SWEET IPC: 90 s: glink versioned, IPCRTR open, qrtr hello seen; 155 packets in, 523 out; rmtfs 3 reads (2097152 bytes),
0 writes kept in RAM (0 bytes); pd-mapper 7 requests; WLFW up
```

**The modem asked the pd-mapper 7 times and then offered WLFW (QMI service 0x45): the WLAN protection domain runs.**
Clean stop (stop-ack 190 ms, rmtfs buffer back, QMP load_state off), no panic. Packets out went from 31 (boot 41) to
523, consistent with a large TFTP read (`wlanmdsp.mbn`), but the USB console **dropped most kernel lines** of this
stage (userspace was very busy: of ~40 "modem offers" lines only 2 arrived; no pd-mapper request line, no `WLFW is up`
line, no wlanmdsp line). Console: `research/ios26/logs-wlan/boot42-wlan-pdm-usb.txt` (main checkout, not in git).

**Bug found:** TFTP transfer ports started at 0x4002 = the pd-mapper's port. The modem's server-check upload
(`/readwrite/server_check.txt`, port 0x4002) went to the pd-mapper (`unknown request 0x6801` = TFTP DATA) and stayed
0 bytes; the modem carried on anyway. Fixed in 1116.

**Then I froze the phone (~11:47Z).** To read the full log I ran read-only `dd` on `/dev/rufsroot0` over SSH (binary
search for the device end, probes up to 64 GiB, past the end of userdata). Right after, SSH, ping and the USB console
stopped (last lines `exec sh` / `exec toybox`, no panic text) and the screen would not wake. Nothing was written. The
user handed recovery to the GPU session. **Lesson: never read the raw root device (`/dev/rufsroot0`, `/dev/ufsroot0`)
on the running phone**; read the console ring only from recovery (`tools/sweet-log-pull.sh`), and make the kernel
re-print what matters (1116).

**1116** (`1116-beryllium-mpss-tftp-ports-events.patch`): TFTP transfer ports from 0x4010 (clear of the fixed
server ports 0x4000-0x4002); the stage keeps its key events (services offered/removed, pd-mapper requests and
answers, PFRs, every TFTP transfer with its byte count) in a 1.5 KiB record and prints it again in 160-character
`SWEET IPC: events N:` lines after the summary, with a flush and 50 ms between lines. Built (no new warnings), NOT
run: image `shim/out/enxerto-boot-ios26full-boot43-wlan-events.img` (sha256 `fc9b6240...`, kernel `37794f3f...`).
Next boot (43) = 1116 with boot
42's args, to see which domains the modem asked for, whether `wlanmdsp.mbn` came over TFTP, and WLFW; then the WLFW
client (capabilities, BDF from `bdwlan.*`, mode on).

### 5.18 Boot 43-wlan-events (1116, run by the GPU session with the user's OK): **wlanmdsp.mbn loaded over TFTP, WLFW up**

Boot 43 ran at 11:57Z (recovery after the boot 42 freeze), 13:10Z and 14:01Z, each combined with GPU work. The
end-of-stage event replay (`SWEET IPC: events N:`) is in the USB console twice so far, with identical results:

* **pd-mapper requests** (5): `tms/pddump_disabled` (0 domains), `tms/pdr_enabled` (0), `avs/audio`
  (msm/adsp/audio_pd/74, twice), **`kernel/elf_loader` -> msm/modem/wlan_pd/180**. No `wlan/fw` or `tms/servreg` query,
  and no PFR.
* **TFTP**: `/readwrite/server_check.txt` 5 bytes (fixed by 1116's ports), then **RRQ
  `/readonly/vendor/firmware_mnt/image/wlanmdsp.mbn`**: two size checks ("end of transfer"), then **3645892 bytes
  served** from the modem partition; mcfg as before.
* **Services**: ~45 offered, including 0x42 SERVREG_NOTIFIER (instance 180), then after wlanmdsp: 0x10, 0x33,
  **0x45 WLFW at 0:0x48**, 0x21, 0x12.
* 90 s, 156 packets in, 525 out; clean stop (stop-ack 190 ms), no panic.

The 1.5 KiB event record filled up just before the end (its last line is cut in the mcfg entries); nothing after
WLFW was lost. **The chip half is done up to WLFW.** Next (1117): the WLFW client, ath10k `qmi.c` order:
IND_REGISTER, CAP (chip/board/soc ids, firmware version), MSA info/ready if needed, BDF download (`bdwlan.*` for
the board id, from the modem partition, read-only), WLAN config (CE/service tables of `ath10k/snoc`), mode ON; then
the copy engine/SNOC data path.

### 5.19 1117: WLFW client up to FW READY (`sweetwlfw=1`): built, NOT run

`1117-beryllium-wlfw-client.patch`, gate **`sweetwlfw=1`** (on top of rmtfs/TFTP/pd-mapper), the host side of WLFW
in mainline ath10k `qmi.c` order (beryllium sets `qcom,snoc-host-cap-skip-quirk`, so no HOST_CAP):
1. At step 15: the WCN3990 rails of the beryllium `&wifi` node voted on in ath10k's vreg order (ldoa5 0.8 V, ldoa7
   1.8 V, ldoa17 1.304 V, ldoa25 3.3 V, ldoa23 3.3 V; never voted off, as in the Bluetooth stage); a failed vote
   disables the client. No RF_CLK2 vote (Bluetooth works without one; to revisit if the chip does not come up).
2. NEW_SERVER 0x45 -> **IND_REGISTER** (fw_ready, msa_ready, client id 0x4b4e454c) from our port 1:0x4003; a
   FW_READY bit in fw_status ends the sequence (firmware already up).
3. **MSA_INFO** (0x8e300000, 1 MiB, the beryllium `wlan_msa_mem`); each returned region (at most 2, checked inside
   the carve-out without overflow) is hyp-assigned after ath10k's 20 ms pause: HLOS -> MSS_MSA + WLAN (0x18) +
   WLAN_CE (0x19) RW (no WLAN_CE when secure). `ms_assign_list` now takes up to 3 VMIDs.
4. **MSA_READY**, **CAP** (chip id/family, board id, soc id, firmware version + timestamp, build id, all logged).
5. On the MSA_READY indication: board data from the modem partition, read-only, by the cnss names present there
   (`bdwlan.bNN` for board id < 0xff, `bdwlan.NNN`, else/fallback `bdwlan.bin`), sent as **BDF_DOWNLOAD** segments
   of 6144 bytes (file_id 0, total size, seg id, end on the last; a failure on the end segment is tolerated as ath10k
   does for the BDF CRC check), then **CAL_REPORT** (no calibration ids).
6. Wait for the **FW_READY** indication: `wlfw: FW READY indication: the WLAN firmware runs`. **Stops there**:
   WLAN_CFG (CE tables) and mode ON come with the copy engines (next step).
* 30 s per response/indication (ATH10K_QMI_TIMEOUT), then the client stops. Only the WLFW server's node/port is
  accepted on 0x4003. A DEL_SERVER resets the client (MSA back to HLOS, board data freed), as ath10k's server exit.
* Teardown (after the modem stop): MSA regions back to HLOS (MSS_MSA + WLAN + WLAN_CE -> HLOS RW).
* The summary adds `wlfw client: <state>; chip .. board .. soc .. fw .., <bdf> N bytes in M segments`; the event
  record (now 3 KiB) has every step.

Checked: a userspace harness ran the client through a scripted exchange (wire bytes of every request, region
parse, assign arguments, 4 BDF segments for a 19152-byte file, end-segment tolerance, FW READY, server
leave/re-arrive, a foreign sender). Sixth independent review against ath10k `qmi.c`, `qmi_wlfw_v01.c`,
`qmi_encdec.c` and `qcom_scm_assign_mem`: wire formats and assign layout correct; applied its fixes (wrap-safe MSA
range check, reset on server exit, sender check, late FW_READY no longer drops a pending response, rail failure
stops the client, 30 s timeouts).

Image `shim/out/enxerto-boot-ios26full-boot44-wlan-wlfw.img` (sha256 `98d496e7...`, kernel `2c70cd94...` = boot 33b's
kernel + 1108-1117): boot 43's args plus `sweetwlfw=1`, hold 120 s (was 90). Expected: CAP values (board id ->
which `bdwlan.*`), BDF accepted, **FW READY**. Not booted: needs the user's OK; one queue item, or combined with a
GPU boot through the GPU session.

### 5.20 Boot 44-wlan-wlfw (1117, combined with a GPU boot): **WLAN firmware READY**

**2026-10-26 14:44:30Z** (user OK "combine it with the GPU session's next boot"; queued by the GPU session as the
only item). The boot that ran is the GPU session's recovery variant
`shim/out/enxerto-boot-ios26full-boot44-wlan-wlfw-notrace.img`: same kernel, `sweethidlog=1` removed (608-byte
boot-args field) and `sweetdenypath=bgmtl.trace` added; every Wi-Fi arg unchanged. Two earlier attempts with this
kernel (14:34Z, 14:40:47Z) ended in initproc panics from the GPU session's trace code **before stage 4 started** (no
`wlfw` rails line in the console): not Wi-Fi related. Modem, rmtfs, TFTP (`wlanmdsp.mbn` 3645892 B), pd-mapper as boot 43; then the WLFW client:

```
wlfw: WCN3990 rails voted on: ldoa5=0 ldoa7=0 ldoa17=0 ldoa25=0 ldoa23=0
wlfw: ind-register result 0 error 0, fw_status 0
wlfw: msa region 0: 0x8e300000 + 0x4000 secure 1
wlfw: msa region 1: 0x8e304000 + 0xfc000 secure 0
hyp-assign wlan msa 0x8e300000+0x4000 vmid 3 -> 15 perm 6 + 24 perm 6: status=0
hyp-assign wlan msa 0x8e304000+0xfc000 vmid 3 -> 15 perm 6 + 24 perm 6 + 25 perm 6: status=0
wlfw: MSA ready indication
wlfw: msa-ready result 0 error 0
wlfw: chip_id 0x30214 chip_family 0x4001 board_id 0xff soc_id 0x40030001 fw_version 0x20090216
      "2019-12-18 08:15" "QC_IMAGE_VERSION_STRING=WLAN.HL.2.0.c3-00534-QCAHLSWMTPLZ-1"
wlfw: board id 0xff -> bdwlan.bin (26328 bytes) from the modem partition
wlfw: board data sent in 5 segments          (end segment accepted: result 0, no CRC complaint)
wlfw: cal-report result 0 error 0; waiting for FW READY
wlfw: FW READY indication: the WLAN firmware runs
```

Summary `wlfw client: FW READY; chip 0x30214 board 0xff soc 0x40030001 fw 0x20090216, bdwlan.bin 26328 bytes in
5 segments`. Teardown: stop-ack 190 ms, both MSA regions back to HLOS (status 0), rmtfs buffer back, no panic.
The MSA_READY indication arrived before the MSA_READY response (handled). No RF_CLK2 vote was needed.
Console: `research/ios26/logs-wlan/boot44-wlan-wlfw-usb.txt` (main checkout, not in git).

**The WLFW control path is done: the WCN3990 firmware runs with the phone's own board data.** Next (1118): the
data path of ath10k `snoc.c`: WLAN SMMU context for stream 0x40/0x41 (identity map of a DMA pool below 4 GiB), copy
engine rings at membase 0x18800000 + 0x240000 (CE0..CE11, `target_ce_config_wlan` / `target_service_to_ce_map_wlan`
and shadow registers of `snoc.c`), WLAN_CFG with those tables, mode ON (mission), then HTC ready over CE (polled):
the first message from the chip itself.

### 5.21 1118: copy engines, WLAN_CFG, mode ON, wait for HTC READY (`sweetce=1`): built, NOT run

`1118-beryllium-wlan-copy-engines.patch`, gate **`sweetce=1`** (needs `sweetwlfw=1`); after FW READY, in the order
of ath10k `snoc.c` `ath10k_snoc_hif_power_up()` + `hif_start()`:
1. **apps SMMU**: WLAN streams 0x40 and 0x41 (`iommus = <&apps_smmu 0x40 0x1>`) to the shared identity-mapping
   context bank of `sweet_smmu.c` (exact SMRs; an unmatched stream faults and resets the SoC once the chip DMAs).
2. **DMA pool**: the fixed slice **0xe0100000, 1 MiB** (below 4 GiB, outside xnu RAM, after the MPSS metadata at
   0xe0000000), mapped Normal-NC, IOVA == PA; RRI at +0, CE0/CE3/CE1/CE2 rings at +0x1000..+0x4000, rx buffers
   (2 KiB) at +0x10000 (CE1, 32) and +0x20000 (CE2, 64). **Never reuse this slice**: if mode off is not confirmed
   the CE may still hold addresses in it.
3. **WLAN_CFG** (QMI 0x23): `target_ce_config_wlan` (12), `target_service_to_ce_map_wlan` (21 entries, terminator
   included as ath10k sends it), `target_shadow_reg_cfg_map` (12); then **WLAN_MODE mission** (0x22, mode 0,
   hw_debug 0).
4. Only after the mode-ON response (CE block powered, as in Linux): membase 0x18800000 mapped, a flushed log line
   and 200 ms pause before the **first CE register access**, RRI address (0x24c004/8) + CTRL1 UPD bit 19 on all 12
   CEs, source rings CE0 (16) / CE3 (32) and destination rings CE1 (32) / CE2 (64) per `wcn3990_ce_regs` (base
   lo/hi with the 5-bit high mask, size, dmax, byte swap off, watermarks low 0 / high n), free slots of CE1/CE2
   filled with buffers (`CE_RING_DELTA`). CE4..CE11 host rings are not set up (the target uses them only after
   HTC connect); host ring sizes are smaller than ath10k's.
5. **Polled** (no CE interrupts): destination descriptors with nbytes != 0 (volatile read + `dmb ld`), each
   message logged (first 8, 32 bytes hex), the slot re-posted at once; endpoint 0 message 1 = **HTC READY**
   (credits, credit size, endpoints, HTC version) -> state `HTC READY`. Nothing is sent on the rings yet.
6. End of the service loop (modem still up): **WLAN_MODE off** (4) whenever mission mode was requested, confirmed
   or not, waiting up to 3 s; skipped if the modem died. Teardown unmaps only the pool; the SMMU bank and the
   register mapping stay.

Checked: the harness drove WLFW -> FW READY -> WLAN_CFG (559 bytes: TLV 0x11 241 B / 12, 0x12 253 B / 21, 0x13
49 B / 12) -> mode -> CE setup on simulated registers -> a fake HTC READY in CE2 slot 0 -> repost -> mode off.
Seventh independent review against `snoc.c`, `ce.c`, `hw.c`, `htc.h` and the wlfw tables: wire formats, tables,
register offsets/bitfields and order all match; no defect that could plausibly hurt the phone; applied its fixes
(mode off also when mission mode was only requested, free-slot count for rx posting, descriptor read barrier, HTC
READY only while waiting, state kept after mode off). Residual risk as in Linux: the first CE register access.

Image `shim/out/enxerto-boot-ios26full-boot45-wlan-ce.img` (sha256 `27712142...`, kernel `2e658e59...` = boot 33b's
kernel + 1108-1118), built from the boot-args that ran boot 44 (the GPU session's `-notrace` variant: no
`sweethidlog`, `sweetdenypath=bgmtl.trace`) plus `sweetce=1`, minus `sweetbtfast=1 sweetbtibs=1` (ignored outside
the Bluetooth stage; needed to stay within the 607 usable bytes of the 608-byte boot-args field, which
`mkpayload.py` truncates silently). Expected: SMMU map 0/0, wlan-cfg 0/0, mode mission 0/0, CE rings, **HTC READY**,
mode off confirmed. Not booted: needs the user's OK; run it with the user present (first CE access).

### 5.22 Boot 45-wlan-ce (1118, combined with a GPU boot, user present): **HTC READY: the WCN3990 talks to the host**

**2026-10-26, sent 15:34:01Z, iOS up 15:35:25Z** (the app's auto-reboot failed on a host key, the GPU session
sent the phone to fastboot over SSH; user OK "combine it with the GPU session's next boot ... I'll be by the phone"; queued by the
GPU session as the only item). Everything up to FW READY as boot 44, then:

```
SWEET SMMU: sid 0x40 -> smr 7 s2cr 0x3 (translate)          (the shared identity bank, context bank 3, as USB)
SWEET SMMU: sid 0x41 -> smr 8 s2cr 0x3 (translate)
wce: wlan-cfg result 0 error 0
wce: wlan-mode mission result 0 error 0
wce: mode on: first access to the CE registers at 0x18a40000          (no freeze)
wce: CE0 source ring 16 entries at 0xe0101000: sw 0 wr 0, ctrl1 0x80800
wce: CE3 source ring 32 entries at 0xe0102000: sw 0 wr 0, ctrl1 0x80800
wce: CE1 destination ring 32 entries at 0xe0103000: sw 0 wr 31, ctrl1 0x80800
wce: CE2 destination ring 64 entries at 0xe0104000: sw 0 wr 63, ctrl1 0x80800
wce: CE2 message 20 bytes: 00 00 0c 00 00 00 00 00 01 00 02 00 88 08 16 00 01 00 00 00
wce: HTC READY: 2 credits of 2184 bytes, 22 endpoints, HTC version 1
wce: wlan-mode off result 0 error 0 / mode off confirmed
```

The chip DMA'd its first HTC message through the SMMU into our CE2 ring (endpoint 0, READY extended: 2 credits of
2184 bytes, max 22 endpoints, HTC 2.1). No SMMU fault, no freeze. The destination rings read back CTRL1 0x80800
too (the reset value carries dmax 0x800). The modem wrote modemst1 once during this boot (`rmtfs write caller 0:
4096 sectors`, 2 MiB): kept in the RAM copy, storage untouched. Clean stop (stop-ack 190 ms), MSA regions and the
rmtfs buffer back to HLOS (status 0), no panic. Console: `research/ios26/logs-wlan/boot45-wlan-ce-usb.txt` (main
checkout, not in git).

**The data path works.** Next (1119): HTC and WMI, ath10k `htc.c` / `wmi-tlv.c`: HTC connect RSVD_CTRL is implicit;
send CONNECT_SERVICE for WMI_CONTROL (0x100) on CE0, read the response (endpoint, max message size), SETUP_COMPLETE_EX;
then the target's WMI SERVICE_READY event on CE2 (the firmware's capabilities: PHY, bands, MAC address, services)
and WMI INIT -> READY event. The source ring write index goes through the shadow register (0x32000 for CE0, 0x3200c
for CE3) as ath10k does for WCN3990.

### 5.23 1119: HTC connect + WMI service ready / init / ready (`sweetwmi=1`): built, NOT run

`1119-beryllium-wlan-htc-wmi.patch`, gate **`sweetwmi=1`** (needs `sweetce=1`), after HTC READY in the order of
ath10k `core.c` `ath10k_core_start()`:
1. **HTC connect HTT_DATA_MSG** (0x300, flags DISABLE_CREDIT_FLOW_CTRL) then **WMI_CONTROL** (0x100, RECV_ALLOC 1:
   WCN3990 has `use_fw_tx_credits = false`, so one transmit credit) on endpoint 0 / CE0; responses (endpoint,
   max message size) on CE2. pktlog is not connected (its service is IN-only in `snoc.c`, as ath10k finds).
2. **SETUP_COMPLETE_EX** (snoc: flags 0, 20 bytes).
3. **WMI SERVICE_READY** (event 0x1, WMI TLV): ABI check (0x01000000 / "QCA_" "ML"), capabilities logged
   (fw build, PHY, RF chains, HT/VHT caps, tx power, regdomain, 2/5 GHz channel range), the raw service bitmap
   logged and decoded exactly as `wmi_tlv_svc_map()` (legacy packing below the TLV length, extended above it);
   host memory requests (`num_unit_info` peers/vdevs as ath10k: 34 / 5 units) placed in the pool from +1 MiB,
   4 KiB aligned; the pool is now **4 MiB (0xe0100000..0xe0500000)**, zeroed before use.
4. **SERVICE_AVAILABLE** (0x3, up to 300 ms): tx-ack-rssi (174) and extended-address (179) bits.
5. **WMI INIT** (cmd 0x1) on CE3 (meta data = endpoint << 4, HTC NEED_CREDIT_UPDATE, shadow write index 0x3200c):
   INIT_CMD TLV (ABI + chunk count), RESOURCE_CONFIG (the 44 values of `ath10k_wmi_tlv_op_gen_init` for WCN3990:
   4 vdevs, 33 peers, 66 tids, native-wifi decap, 1056 MSDU descriptors, 22 WoW filters, ...), HOST_MEMORY_CHUNK
   array.
6. **WMI READY** (0x2): status and **MAC address** -> state `WMI READY`. Then mode off at the end as before.
HTC trailers (4-byte record headers) are parsed for WMI credit reports; HTT messages on CE1 are only logged.

Checked: the harness simulated the target (READY, both connect responses with a credit trailer, a SERVICE_READY
with one memory request, SERVICE_AVAILABLE, READY): connect requests, setup complete, INIT (TLVs 74/75/18/76,
resource config values) and the READY parse as expected. Eighth independent review: no phone-safety defect;
applied its fixes (service bitmap decoded with ath10k's packing instead of a flat map, 4-byte HTC trailer record
headers, the memory-request count cross-checked and capped at 16, HTC/WMI state reset when the WLFW server leaves).

Image `shim/out/enxerto-boot-ios26full-boot46-wlan-wmi.img` (sha256 `2747296b...`, kernel `ea12055c...` = boot 33b's
kernel + 1108-1119): boot 45's args plus `sweetwmi=1` (592 bytes). Expected: both HTC connects, SERVICE_READY with
the firmware's capabilities, INIT, **WMI READY with the chip's MAC**, mode off confirmed. Not booted: needs the
user's OK.

### 5.24 Boot 46-wlan-wmi (1119, combined with a GPU boot, user present): **WMI READY**

**2026-10-26, sent 16:27:28Z** (user OK in both sessions; one queue item after a logo-partition flash by the GPU
session). Up to HTC READY as boot 45, then:

```
wmi: HTC connect 0x300 -> status 0 endpoint 1 max message 2000        (HTT)
wmi: HTC connect 0x100 -> status 0 endpoint 2 max message 2040        (WMI)
wmi: HTC setup complete sent; waiting for WMI SERVICE_READY
wmi: SERVICE_AVAILABLE: tx ack rssi 0, extended address 0             (arrives before SERVICE_READY)
wmi: service bitmap 128 bytes: 0000000d 00000007 0000000d 00000003 0000000f 00000009 0000000b 0000000f ...
wmi: SERVICE_READY fw_build 0x20090216 abi 0x1000000/757 ns 0x5f414351 0x4c4d, phy_cap 0x3, 2 rf chains,
     ht_cap 0x381b vht_cap 0x739139fa, tx power 63..63, 0 memory requests; regdomain 0x809c,
     2 GHz 2312-2732, 5 GHz 4912-6100
wmi: event 0x4009 (956 bytes)                                          (not handled; logged)
wmi: INIT (220 bytes, 0 memory chunks, rx reorder offload on, tx ack rssi off)
wmi: READY status 0, MAC 00:00:00:00:00:00: WMI is up
wce: mode off confirmed
```

Then stop-ack 190 ms, teardown done, no panic. The service bitmap is 128 bytes, so ath10k's 4-services-per-word
packing (review fix) was needed; RX_FULL_REORDER is on. The firmware asks for no host memory. The **zero MAC is
expected**: ath10k takes the MAC from the device (`device_get_mac_address`, DT `local-mac-address`) and only falls
back to the firmware's when that is zero; the host then sets it with WMI PDEV_SET_BASE_MACADDR. The 16-byte EP0
message after READY is a credit report only (trailer record `01 04 00 01` + `02 01 f8 07`: endpoint 2 gets its
credit back after INIT), logged as "HTC control message 1025 (0 bytes)": to be skipped quietly (next patch).
Console: `research/ios26/logs-wlan/boot46-wlan-wmi-usb.txt` (main checkout, not in git).

**The WCN3990 is up as an ath10k WMI-TLV target.** Next (1120): what ath10k does after READY in `core_start` and
`ath10k_core_register`/`mac.c` up to a scan: PDEV_SET_BASE_MACADDR (a MAC: the ADT's `local-mac-address` of the
wlan node, or a fixed locally administered one), HTT version request and HTT RX ring setup on CE4/CE1, PDEV params,
VDEV create (station), START_SCAN on 2.4/5 GHz, and the SCAN and MGMT_RX events (beacons -> SSIDs logged).

### 5.25 1120: first scan, passive only (`sweetscan=1`): built, NOT run

`1120-beryllium-wlan-first-scan.patch`, gate **`sweetscan=1`** (needs `sweetwmi=1`). What ath10k (`core.c`
`ath10k_core_start` -> `mac.c` `ath10k_start`, `add_interface`, `hw_scan`) sends for a station before scanning,
reduced to the commands that matter (reference extracted from Linux v6.12 into the session notes):
1. **HTT VERSION_REQ** (4 bytes, type 0) on a new **CE4** source ring (16 entries, dmax 256, pool +0x5000, buffers
   +0x58000, shadow write index 0x32010, initialised only with `sweetscan=1`); VERSION_CONF (type 0, minor, major)
   on CE1, waited for 3 s (scan results come over WMI either way). HTT frag-desc / RX ring / aggr config are not
   sent: management frames come over WMI MGMT_RX ("firmware is guaranteed to report all essential management
   frames via WMI", wmi.c); they are the first thing to add if no beacons arrive.
2. WMI commands **one at a time**: the WMI endpoint's single credit is now tracked (taken by each send, returned by
   the HTC trailer credit reports, capped at 1). In order: PDEV_SET_PARAM tx/rx chain mask 3 (2 RF chains);
   **SCAN_CHAN_LIST** of 26 channels (2.4 GHz 1-13; 5 GHz 36-64, 52-64 flagged DFS; 149-165: regdomain 0x809c =
   CN), **every channel PASSIVE**, mode 11G/11A + ALLOW_HT/VHT, 20 dBm caps; **PDEV_SET_REGDOMAIN** 0x52 (APL1),
   CTL 2 GHz 0x30 / 5 GHz 0x10, as ath10k derives from 0x809c; **VDEV_CREATE** vdev 0 station with the ADT's
   `arm-io/wlan local-mac-address` **02:00:5e:77:e0:01** (ath10k never sends PDEV_SET_BASE_MACADDR for WMI-TLV;
   the READY MAC is zero); VDEV_SET_PARAM tx_encap native wifi; **START_SCAN** passive (scan_ctrl_flags 0x31: the
   TLV firmware's inverted FILTER_PROBE_REQ, no SSIDs, broadcast BSSID, dwell 150 ms passive, max 20 s).
3. **RF: listen only.** Passive scan flag, no SSIDs, PASSIVE on every channel (ath10k notes the firmware probes DFS
   channels actively otherwise), the vdev is never started or up, no peer: nothing is transmitted.
4. SCAN_EVENT (tag 36: STARTED, FOREIGN_CHANNEL visits, COMPLETED with reason, START_FAILED) and **MGMT_RX** (tag 44
   header: channel, SNR -> dBm, status; tag 17: the 802.11 frame): beacons/probe responses (CRC/decrypt/key-miss
   frames dropped), BSSID + channel + RSSI + SSID (non-printables as `?`), each BSS logged once (48 max) and listed
   again at the end of the stage (`scan summary`). Then WLAN_MODE off as before.
Also: an endpoint-0 message that is only a credit trailer is no longer logged as a control message.

Checked: the harness drove HTT version -> the seven WMI commands one credit at a time -> STARTED -> a beacon ->
COMPLETED -> summary (it caught a SCAN_EVENT length check that would have dropped every event). Ninth independent
review: ids, tags, struct layouts, param ids (TLV maps), regdomain, scan flags and HTT format match Linux, RF
listen-only confirmed, no blocking defect; applied its fixes (scan events only with `sweetscan=1`, credit capped
at 1, per-step timeout). The SSIDs seen on the phone's console are not copied into these docs.

Image `shim/out/enxerto-boot-ios26full-boot47-wlan-scan.img` (sha256 `471a50c2...`, kernel `bb2120ab...` = boot 33b's
kernel + 1108-1120): boot 46's args plus `sweetscan=1` (**604 bytes of 607**: little room left in the boot-args
field). Expected: HTT version, the seven commands, scan STARTED, channel visits, beacons from nearby networks,
COMPLETED, summary, mode off. Not booted: needs the user's OK.

### 5.26 Boot 47-wlan-scan (1120, user present): **the scan runs, but no beacons arrive**

**2026-10-26 19:14:39Z** (user OK "combine it with the GPU session's next boot"; the phone was in Bergamota
fastboot with an empty queue, so this session queued it as the only item; iOS up ~19:15Z). Up to WMI READY as
boot 46, then:

```
scan: HTT version request sent / HTT version 3.73
scan: pdev tx chain mask 3, rx chain mask 3, channel list (26, all passive, 744 B), regdomain 0x52,
      vdev 0 create (station), vdev tx encap native wifi, start scan (passive) (236 B)   (one credit each)
scan: STARTED (scan id 0xa000)
scan: COMPLETED reason 0 after 26 channel visits: 0 beacons/probe responses, 0 BSS
scan summary: htt 3.73, completed, 78 events, 26 channel visits, 0 beacons/probe responses, 0 BSS
wce: mode off confirmed
```

Every command was accepted (credit returned each time), the firmware ran the whole passive scan (26 foreign
channel visits, CHAN_INFO 0x4002 events during it), and reported COMPLETED reason 0, but **no MGMT_RX event** came.
Clean stop, no panic. Console: `research/ios26/logs-wlan/boot47-wlan-scan-usb.txt` (main checkout, not in git).

Repeated on the GPU session's boot 47 variant (`-60hz-gpu7`: `sweetfb_hz=60 sweetgpufreq=7`, same kernel and
Wi-Fi args, ~19:27Z): identical, STARTED -> COMPLETED reason 0 after 26 channel visits, 0 beacons.

**Open question: is the radio receiving at all, or does the firmware keep the frames?** Next (1121), in order of
cheapness:
1. Parse **CHAN_INFO** (tag 38, 13 u32: noise floor, rx_clear_count, cycle_count, rx_frame_count, ...): non-zero
   `rx_frame_count` / a sane noise floor = the RF works and frames are filtered before the host.
2. Do the rest of **ath10k_htt_setup** (frag-desc bank, HTT RX ring with buffers, aggr config): ath10k never scans
   without it, and the firmware may not deliver management frames to a host whose HTT RX path is unconfigured.
3. The **RF_CLK2** reference-clock vote (`cxo_ref_clk_pin`, RPMh "rfclka2") that ath10k makes at probe and this
   driver skips: Bluetooth works without it, but the WLAN RF may not.

### 5.27 1121: the radio's own counters during the scan: built, NOT run

`1121-beryllium-wlan-scan-radio-counters.patch` (no new gate: part of `sweetscan=1`), **diagnostics only, no new
command to the chip**:
* **CHAN_INFO** (WMI 0x4002, tag 38, 13 u32) parsed for every channel visit: freq, flags (COMPLETE / PRE_COMPLETE),
  error, **noise floor**, rx_clear_count, cycle_count, **rx_frame_count**, my_bss_rx_cycle_count, tx_frame_cnt,
  mac_clk; the first 64 logged (`scan: chan_info ...`), the COMPLETE ones summed and kept per channel.
* Every WMI event id seen from the scan setup on is **tallied**; unknown ones are logged (first 32).
* `scan summary radio:` (CHAN_INFO count, total rx/tx frames, HTT message count), `scan summary chan N MHz:` per
  channel (rx_frames, noise floor, rx_clear, cycles) and `scan summary event 0x.... x N` at the end of the stage.
Reading: rx_frames > 0 with a noise floor around -95..-100 dBm = the RF hears frames that the firmware does not
pass up (-> the HTT RX setup / host filters); rx_frames 0 with a flat or absurd noise floor = the RF path itself
(-> the RF_CLK2 vote, rails, antenna switch).

Checked: a small harness ran CHAN_INFO PRE_COMPLETE / COMPLETE / short TLVs through the parser and the summary;
built with no new warnings; `1121` applies onto 1120 and reproduces the built source.

**Images from develop from now on:** develop (with ios26) is merged into this branch (2252d2e, then local develop
1122401 -> eb5ce4c). **1122** (`1122-beryllium-wlan-rf-clock.patch`, beryllium_wlan.c + sweet_rpmh.c): with **`sweetrfclk=1`** the
WCN3990 reference clock is voted on right after the rails, as `ath10k_hw_power_on()` enables `cxo_ref_clk_pin`
(beryllium `&wifi` clocks = `RPMH_RF_CLK2`): `sweet_rpmh_rfclk_enable("rfclka2")` sends clk-rpmh's VRM enable
(value 1 at the cmd-db address + 4, active set, never voted off; only "rfclka2" is accepted). Off by default.
Suggested by the GPU session after it checked boot 47's board data and rail votes (both fine): without the
reference the synthesizer cannot lock, the firmware still visits every channel and hears nothing.

Two images on the same kernel (1120 + 1121 + 1122, sha256 `20424c77...`), both on **develop's Enxerto**:
* `shim/out/enxerto-boot-ios26full-boot48-wlan-radio.img` (sha256 `208cade2...`): the GPU baseline args of
  `...-boot47-60hz-boost7b-enxdev.img` unchanged (606 bytes), no RF clock vote: boot 47 again + the counters.
* `shim/out/enxerto-boot-ios26full-boot48r-wlan-rfclk.img` (sha256 `a88a0c80...`): the same with `sweetrfclk=1`
  instead of `sweetgpuboost=7` (603 bytes; the GPU work moved to its own session).
Run 48r first: beacons there = the RF clock was missing; else 48 vs 48r counters tell RF-deaf from filtered.
The baseline args are those of `...-boot47-60hz-boost7b-enxdev.img` (60 Hz, no `-v`/`keepsyms`,
`sweetgpufreq=gov sweetgpuboost=7`, `cpus=8 -noprogress`, every Wi-Fi arg incl. `sweetscan=1`); the recipe
reproduces that `-enxdev` image byte for byte with the 1120 kernel, so only the kernel (and in 48r one arg)
differs. The first boot 48 build (kernel 1121 alone, `11b9d29c...`) is superseded by the one above. Neither image
is booted: each needs the user's OK.

### 5.28 Boot 48r-wlan-rfclk (1121 + 1122, `sweetrfclk=1`, user present): **the radio hears traffic; no frame reaches the host**

**2026-10-26 ~20:27Z** (user OK "boot 48r-wlan-rfclk now (one queue item)"; queued by this session, the Turnip
session told). First boot of a Wi-Fi image on develop's Enxerto. `SWEET RPMH: RF clock rfclka2 enable at 0x4c404`,
`wlfw: RF reference clock rfclka2 -> 0`; then as boot 47: HTT 3.73, all commands accepted, scan STARTED ->
COMPLETED reason 0 after 26 channel visits, **0 beacons, no MGMT_RX event** (event tally: SCAN 0x3001 x 78,
CHAN_INFO 0x4002 x 27, nothing else). Mode off confirmed, stop-ack 190 ms, clean teardown.

**CHAN_INFO counters (one per visit, flags 0; the last entry is an all-zero COMPLETE marker, so the per-channel
"COMPLETE" totals of the summary stay empty: the per-visit lines are the data).** Per ~150 ms dwell at mac_clk
120 MHz (`cycles` ~18.0 M):

| band | noise floor | rx_clear / cycles | rx_frame / cycles |
|------|-------------|-------------------|-------------------|
| 2.4 GHz ch 1-13 | -118 dBm | 15-61 % busy | 1-55 % (ch 1: 9.67 M / 17.7 M) |
| 5 GHz 36-64 (52-64 DFS) | -106 dBm | 0.1-3 % | 0.1-3 % |
| 5 GHz 149-165 | -108..-110 dBm | 0-1 % (157/165: 0) | 0-1 % |

**Reading:** the RF path works (with the reference clock voted): the receiver is busy decoding frames on every
2.4 GHz channel and most 5 GHz ones, nothing is transmitted (tx 0), but the firmware hands **no** management frame
to the host. So the zero beacons of boots 47/48r are a **delivery** problem, not RF. (Whether `rfclka2` is needed
at all would take boot 48 without the vote; it is harmless, so it stays on from now on.) Console:
`research/ios26/logs-wlan/boot48r-wlan-rfclk-usb.txt` (main checkout, not in git).

**Next (1123):** the rest of `ath10k_htt_setup()` that ath10k always completes before scanning: HTT
FRAG_DESC_BANK_CFG (64-bit), the **HTT RX ring** (RX_RING_CFG 64-bit, buffers posted, the fw index shadow word) and
AGGR_CFG, on CE4; the firmware's receive dispatch may need a configured host RX path before it delivers anything,
including the WMI management frames. Second suspect: the vdev filter (ath10k's mac80211 path sets the rx filter
through vdev/pdev params when the interface is up).

### 5.29 1123: the rest of the HTT setup (frag-desc bank, RX ring, aggr): built, NOT run

`1123-beryllium-wlan-htt-setup.patch` (part of `sweetscan=1`, no new gate: ath10k always does it before scanning).
After the HTT VERSION_CONF (and only then, as `ath10k_htt_setup()`; and only with an HTT endpoint), on CE4,
the 64-bit WCN3990 variants of `htt_tx.c`:
* **FRAG_DESC_BANK_CFG** (64 B): info 0, 1 bank of 1056 x 72-byte `htt_msdu_ext_desc_64` at pool +4 MiB, bank ids
  0..1055, q_state 0 with record size 1 (no PEER_FLOW_CONTROL).
* The **HTT RX ring** (`ath10k_htt_rx_ring_refill`): 2048 le64 addresses at pool +4 MiB + 128 KiB, **2047 buffers**
  of 2 KiB posted from pool +8 MiB (attention words zero: the pool is zeroed), the alloc-index word = 2047.
* **RX_RING_CFG** (48 B): fw-index word and ring addresses, 2048 entries, 2048-byte buffers, all 16 rx flags
  (0xffff incl. MGMT_RX), init index 2047, the `htt_rx_desc_v2` offsets 74/90/27/37/4/26/7/12/1/2 (computed by
  compiling Linux's `rx_desc.h`: a 360-byte descriptor).
* **AGGR_CFG** v2 `05 40 03 00` (A-MPDU 64, A-MSDU 3).
* HTT T2H messages are tallied by type (`0x100xx` in the event list of the summary). Buffers are not recycled
  (2047 is plenty for one scan).
The DMA pool grows to **12 MiB (0xe0100000..0xe0d00000)**, still outside xnu RAM and every reserved-memory region
of the beryllium DT, identity-mapped by the apps SMMU; host-memory chunks stay below +4 MiB.

Checked: a harness dumped the three messages (frag 64 B, ring 48 B, aggr 4 B) and the ring contents; the
eleventh independent review matched every byte and the order against v6.12 (`htt_tx.c`, `htt.h`, `htt_rx.c`,
`core.c`), found no DMA outside the pool; applied its fix (no HTT setup without VERSION_CONF / HTT endpoint).

Image `shim/out/enxerto-boot-ios26full-boot49-wlan-htt.img` (kernel 1120-1123): boot 48r's args unchanged
(develop's Enxerto, `sweetrfclk=1`, 603 bytes). Expected: "HTT setup sent", then beacons as MGMT_RX (or HTT RX
indications in the tally) during the scan. Not booted: needs the user's OK.

### 5.30 Boot 49-wlan-htt (1123, user present): **FIRST WI-FI SCAN RESULTS: 12 networks**

**2026-10-26 ~20:41Z** (user OK "boot 49-wlan-htt now (one queue item)"; queued by this session, the Turnip
session told). Develop's Enxerto, `sweetrfclk=1`. Up to WMI READY as before, then:

```
scan: HTT version request sent / HTT version 3.73
scan: HTT setup sent: frag bank 1056 x 72 at 0xe0500000, RX ring 2048 (2047 posted) at 0xe0520000, aggr 64/3
scan: (chain masks, channel list, regdomain, vdev, encap: all accepted)
scan: STARTED (scan id 0xa000)
scan: bss 0 ..  bss 11  (BSSID, MHz, dBm, SSID per network)
scan: COMPLETED reason 0 after 26 channel visits: 13 beacons/probe responses, 12 BSS
scan summary event 0x7001 x 13 (MGMT_RX), 0x3001 x 78, 0x4002 x 27, HTT 0x10000 (version conf) x 1
wce: mode off confirmed; stop-ack 190 ms; teardown done
```

**The WCN3990 hears and reports real networks on iOS 26.** 12 BSS: 8 on 2.4 GHz (2412-2462 MHz) and 4 on 5 GHz
(5180, 5300 MHz), -41 to -93 dBm, 2 with hidden SSIDs; all through WMI MGMT_RX, passive (nothing transmitted).
The missing piece of boots 47/48r was the **host RX path**: with the HTT frag bank, RX ring and RX_RING_CFG in place
the firmware passes management frames up (over WMI); no HTT RX indication was needed for the scan. The neighbours'
SSIDs/BSSIDs are in the console only (`research/ios26/logs-wlan/boot49-wlan-htt-usb.txt`, main checkout, not in
git), not in these docs. The RF clock vote stays on (boot 48 without it was never needed).

**Next:** make it usable from iOS. The kernel side needs a long-lived WLAN service instead of a 120 s test stage
(keep the modem and the WLAN firmware up, scan on request, then association: VDEV_START/UP, peer, keys,
HTT TX/RX data path with RX_IN_ORD_PADDR_IND handling and buffer recycling), and an iOS-facing interface
(an IO80211 / Skywalk netif driver or a simpler userspace bridge) so the Settings app and `wifid` can see networks.

## 6. Phase 2 (plan: docs/WIFI_IOS26_PHASE2.md)

### 6.1 WL1 / 1124: the long-lived WLAN service (`sweetwlan=5`): built, NOT run

`1124-beryllium-wlan-service.patch`:
* **`sweetwlan=5`** = the service: every Wi-Fi gate (`sweetmss`, `sweetmsskeep`, `sweetmpss`, `sweetrmtfs`,
  `sweettftp`, `sweetpdm`, `sweetwlfw`, `sweetce`, `sweetwmi`, `sweetscan`, `sweetrfclk`) defaults to **on**
  (`wl_gate()`; the boot-arg still overrides, e.g. `sweetscan=0`); `sweetwlan=4` is unchanged (gates default off).
* **No hold time, no teardown**: `ms_ipc_run(0)` runs until the modem reports fatal (then the old teardown).
  The startup sequence is boot 49's (WLFW, CE, HTC/WMI, HTT setup, one passive scan, summary once); Wi-Fi stays
  in mission mode afterwards.
* **Adaptive polling**: 1 ms while anything moves (GLINK packets, HTC messages, a pending WMI command, a TFTP
  transfer, a scan, the GLINK TX queue) and for 200 ms after; 20 ms when idle. `wl_sleep` blocks the thread
  (`assert_wait_deadline`), so idle costs ~50 wakeups/s.
* **Status every 60 s**: `SWEET WLAN svc: up N s, state, loops (busy), glink in/out, wmi events, credit,
  echo ok/sent (last rtt, skipped), rmtfs reads/writes, modem up/FATAL`, and a **WMI ECHO** (cmd 0x1d001,
  tag 149; reply event 0x1d001, tag 54, ids/tags checked in Linux's `wmi-tlv.h`) each time to show the firmware
  still answers; an unanswered ECHO with no WMI credit back is logged as "WMI commands are blocked".
* Boot-args folded: the 11 Wi-Fi args are replaced by `sweetwlan=5` (`sweetwlandelay=60` stays).

Checked: built with no new warnings; review (twelfth): `sweetwlan=4` unchanged, no spin, no wedge from a lost
ECHO, wire format right; applied its diagnostics (credit and skipped ECHOs in the status line).

Image `shim/out/enxerto-boot-ios26full-boot50-wlan-svc.img` (kernel 1120-1124): develop's Enxerto, the GPU
baseline args of the `-enxdev` image with the 11 Wi-Fi args replaced by `sweetwlan=5` (**484 bytes**, 122 free;
`sweetgpuboost=7` back). Test: the phone stays up 10+ minutes, the status line every minute with ECHOs answered,
the service thread's CPU small in `top`. Not booted: needs the user's OK.

**Boot 50-wlan-svc (2026-10-26 ~20:58Z, user OK, user present): WL1 works.** The service came up as boot 49
(startup passive scan: 10 networks, summary printed once) and **stayed up**: status lines every 60 s for 10+
minutes with **every WMI ECHO answered** (9/9 at 600 s, round trip 20-22 ms), the WMI credit back each time,
the modem up, rmtfs 3 reads / 1 write (kept in RAM). Polling: ~3040 loops/min, of which ~176 busy (the ECHO
and the 100 ms SMP2P polls), so the thread sleeps 20 ms almost all the time (~50 wakeups/s). No panic.
Console: `research/ios26/logs-wlan/boot50-wlan-svc-usb.txt` (main checkout, not in git).

### 6.2 WL2 / 1125: real networks for wifid and Settings (`sweet80211=3`): built, NOT run

`1125-beryllium-wlan-scan-backend.patch` (beryllium_wlan.c, sweet_80211.c, new `bsd/dev/sweet_wlan.h`):
* **Interface** (`sweet_wlan.h`): `sweet_wlan_scan_request()`, `sweet_wlan_bss_get(i, &bss)` (BSSID, MHz, RSSI,
  noise, beacon interval, capability, raw SSID, the frame's IEs up to 1 KiB) and the callback
  `sweet80211_scan_done()`.
* **Service side**: the MGMT_RX list becomes a **BSS cache** (48 networks, IEs in a 48 KiB buffer, whole elements
  only, latest RSSI) behind a mutex. A scan request sets a flag; the service thread starts a new passive
  START_SCAN (new scan id) once the previous scan is done and the WMI credit is back; on COMPLETED it calls the
  callback. Request flag, notice flag and state change under the same lock; a scan that fails, or a modem that
  goes down, still completes the pending request (no results) so wifid never waits forever. Only the first scan
  logs every network.
* **iOS side** (`sweet80211=3`): SCAN_REQ / SCAN_REQ_MULTIPLE -> the service (before the service is up: the old
  immediate completion with no networks); SCAN_DONE posted from the callback; SCAN_RESULT walks the cache into
  the `apple80211_scan_result` layout boot 29 proved (channel number and band flags from MHz, RSSI/noise/SNR,
  beacon interval, capability incl. the privacy bit, BSSID, rates from IEs 1 and 50 without membership
  selectors, SSID, the IEs so the framework sees WPA2/RSN, HT/VHT, WPS). DRIVER_VERSION says
  "WCN3990 scan backend". POWER is still a flag (no firmware action). Joining still fails (ENXIO).
Checked: built clean; thirteenth review: no overflow/leak/layout defect; applied its fixes (the scan-done
handshake under the lock, pending notices delivered on failure and modem death, liveness check, rate selectors
skipped, IEs cut at element boundaries). Known minor: a client enumerating results while another client's new
scan starts may see a shorter list.

Image `shim/out/enxerto-boot-ios26full-boot51-wlan-settings.img` (kernel 1120-1125): boot 50's args with
`sweet80211=3` instead of 2. Test (user): Settings › Wi-Fi lists the real nearby networks (lock icons on secured
ones) and refreshes; `sweetwifi scan` over SSH lists them too. Not booted: needs the user's OK.

**Boot 51-wlan-settings (2026-10-26 ~21:10Z, user OK, user present): MILESTONE, Settings › Wi-Fi lists the real
nearby networks (user-confirmed: the names on the screen are the neighbours' networks the chip hears).** wifid powered
the radio, read the capabilities, country and channel list as on boot 29; the service came up and ran its startup scan
(9 networks). When the user opened Settings › Wi-Fi, wifid sent SCAN_REQ (type 10, 5528 bytes); the service ran a passive
scan (scan id 0xa001, 26 channels, 9 networks), posted SCAN_DONE (event 10) and wifid read the results (type 11). Settings
keeps rescanning while the page is open: scan ids 0xa002..0xa006 within a minute, 9-13 networks each, every one completed
and reported. No panic; the service stayed up. Console: `research/ios26/logs-wlan/boot51-wlan-settings-usb.txt` (main
checkout, not in git; the networks' names stay out of these docs).

**WL1 and WL2 are done.** Next is WL3 (join an open network, IP traffic), the first step that transmits: decisions D1
and D3 of docs/WIFI_IOS26_PHASE2.md (the user's OK to transmit; an open test network the user controls).

### 6.3 WL3+WL4 / 1126-1127: join a WPA2-Personal network (`sweet80211=3`): built, NOT run

The user chose to skip the open-network step ("go directly to WPA2"; transmitting is OK, decision D1). Two research
passes fixed the contract on both sides before any code:

**What iOS sends (IO80211 1565.3 from the iOS 26.6.2 shared cache; wifid itself is not on disk).**
* `CARD_CAPABILITIES` (12) is a **bare 21-byte bit map**, not `{version, bits}`. A join needs byte 0 bit 3 (AES-CCM) and
  byte 1 bit 6 (WPA2), otherwise IO80211 fails locally with -3903 before calling the driver. SAE (byte 9 bit 3) must
  stay clear: with it, WPA2-PSK joins carry the passphrase instead of the PMK.
* `ASSOCIATE` (20) is a 908-byte set: version 1 @0, mode 2 @4, auth lower 1 @8 / upper 8 (WPA2-PSK) @0xc, SSID length
  @0x10 + SSID @0x14, BSSID @0x34 (normally zero: the driver picks the BSS), key {version 1, length 32, cipher 6 = PMK}
  @0x3c with the **PMK** @0x4c (IO80211 runs PBKDF2 in the wifid process), the RSN element for the association request
  (length u16 @0xd0, bytes @0xd2), flags @0x1d3, flags2 @0x1fc (4 = PSK).
* **The 4-way handshake is the driver's job**: IO80211 does no EAPOL I/O and sets no keys.
* The sync join polls `ASSOCIATE_RESULT` (21, value in `req_val`) every 20 ms for 8 s: 0 running, 1 success, other =
  failure code (25 BSS not found, 27/29 no auth/assoc response, 22 supplicant timeout, 30 EAPOL failure, ...). After a
  failed join it sends `DISASSOCIATE` (22).
* Events: SSID_CHANGED 2, BSSID_CHANGED 3, LINK_CHANGED 4 (32 bytes: down flag @0, rssi @4, snr @8, noise @10, reason @20),
  ASSOC_DONE 9 ({u32 status}), RSN_HANDSHAKE_DONE 20, DEAUTH_RECEIVED 34. `CURRENT_NETWORK` is type **103** (a scan
  result for the current BSS), not 115.
* Open question: whether wifid uses the async join API, which wants a >= 460-byte ASSOC_DONE that `kev_post_msg`
  cannot carry. The image assumes the sync API (GET 21); the boot log will show which.

**What the chip needs (ath10k + mac80211 v6.12, WCN3990 TLV/SNOC branches).** VDEV_START (0x5003, VDEV_START_RESP) ->
STA_POWERSAVE_MODE 0, beacon interval, management rate -> PEER_CREATE (0x6001; done when HTT PEER_MAP arrives; the peer
must exist before the first frame) -> open-system authentication and the association request by WMI MGMT_TX_SEND by
reference (0x7008, tag 422; completion 0x7006 or bundled 0x7007), or HTT TX_FRM type MGMT without service 76 ->
PEER_ASSOC (0x6005: legacy + HT rates, never an HT peer without HT rates: firmware assert) + SMPS -> VDEV_UP (0x5005) ->
EAPOL over the data path -> VDEV_INSTALL_KEY (0x5009, CCM = 4; done on HTT SEC_IND) pairwise, PEER_SET_PARAM authorize,
group. Data: HTT TX_FRM with a 72-byte ext descriptor per msdu id in the frag bank and two CE4 gather descriptors
(28-byte HTC+HTT header, then a 50-byte prefetch of the frame); TX_COMPL_IND frees ids; RX arrives as
RX_IN_ORD_PADDR_IND (0x12) pointing at RX ring buffers (payload at +360, native wifi), which are posted again at once.

**1126** (`bsd/dev/sweet_wpa.c/.h`, `bsd/dev/sweet_wlan_frames.c/.h`, conf/files):
* `sweet_wpa`: EAPOL-Key messages 1-4 and the group-key handshake for AKM PSK / key descriptor version 2 (PTK =
  PRF-384, HMAC-SHA1-128 MIC, RFC 3394 unwrap of the GTK KDE, replay counter set only by MIC-checked frames, AP RSN
  element byte-compared in message 3, message 4 re-sent if the AP retries 3), on the kernel's SHA-1 and AES.
* `sweet_wlan_frames`: authentication, association request (mac80211's IE order: SSID, rates without basic bits, RSN,
  HT capabilities HT20 2x2, WMM info), association response, deauthentication, Ethernet II <-> native wifi.
* Mac harnesses (scratchpad `wpa/test_wpa.c`, `wpa/test_frames.c`): the 802.11 PRF-512 and PSK test vectors, RFC 3394,
  a full 4-way handshake + group rekey + bad-MIC / replay / wrong-RSN-element cases against an authenticator built on
  CommonCrypto, and the frame layouts: all pass.

**1127** (beryllium_wlan.c, sweet_80211.c, sweet_wlan.h):
* Service: a station state machine (stop-scan, vdev-start, peer, auth, assoc, up, 4-way, keys, CONNECTED, teardown) run
  by the service thread; WMI commands queued behind the one credit; auth/assoc retried 3 x 200 ms; a 7.5 s join
  watchdog; EAPOL message 1 held until PEER_ASSOC / VDEV_UP are through; teardown in steps (deauth out, VDEV_DOWN +
  PEER_DELETE, PEER_UNMAP, VDEV_STOP / VDEV_STOPPED); scans are answered from the cache while a join runs or the
  station is associated; CE4 host ring 64 entries; status line every 30 s while connected.
* iOS side: the capability bitmap, ASSOCIATE (logged without the key), GET 21, STATE RUN, SSID / BSSID / CHANNEL / RSSI /
  NOISE / RATE / TXPOWER / AUTH_TYPE / CURRENT_NETWORK while associated, the link events above, `IFM_ACTIVE`,
  `IFF_RUNNING` and KEV_DL_LINK_ON/OFF for configd, en0 output queued to the service and received frames to `ifnet_input`.
* Review (fourteenth): fixed a build break, stale per-join state (could have reported a link without keys), a
  join-after-leave race that dropped the join, the KEV_DL payload offset (24, not 28), result-before-link ordering,
  no abort when the service fails, missing timeouts, msdu ids leaked over a teardown, one management buffer reused
  while queued, DEAUTH_RECEIVED on our own leave, our own broadcasts echoed back by the AP.
* Not done yet: TKIP groups (mixed WPA/WPA2 APs are refused by IO80211 because TKIP is not advertised), PMF / WPA3,
  roaming, power save, 40 MHz, interrupts instead of polling.

Image `shim/out/enxerto-boot-ios26full-boot52-wlan-wpa2.img` (kernel 1127, boot 51's args). Test (user): Settings ›
Wi-Fi, tap the home WPA2 network, enter the password; expected: it joins within a few seconds and gets an address by
DHCP; then over SSH `ping` the gateway. The console shows each step (`SWEET WLAN sta:` and `SWEET 80211:` lines, the
ASSOCIATE layout, the RSN element; never the key). Not booted: needs the user's OK.

**Boot 52-wlan-wpa2 (2026-10-26 ~22:25Z, user OK, user present): FIRST TRANSMISSIONS, authenticated and associated to
the user's WPA2 AP in 26 ms; the 4-way handshake did not complete; then the WLAN firmware asserted.** wifid's ASSOCIATE
matched the decoded layout exactly (908 bytes, auth 1/8, key length 32 cipher 6 = PMK, a 22-byte RSN element CCMP/CCMP/PSK
caps 0, flags2 4; BSSID zero), so the sync API and the capability bitmap are right. The service picked the strongest BSS
of that SSID (2412 MHz, -60 dBm, HT, WMM), management TX went by WMI reference (service 76 present): VDEV_START ok, two
HTT PEER_MAPs, authentication acked + response 0, association request acked + response 0 (aid 21, 12 rates, HT, WMM),
PEER_ASSOC (flags 0x1007, 11NG HT20, 12 legacy + 16 HT rates, nss 2), VDEV_UP, PEER_ASSOC_CONF (0x6006) at 31 ms. EAPOL
message 1 arrived (clear, 99 bytes) and the supplicant answered, but the AP sent message 1 three times and then a
deauthentication (reason 2) at 3 s: **message 2 never reached it**. Result 30 reported to wifid. The teardown then sent
VDEV_DOWN and the firmware asserted: `wlan_vdev.c:_wlan_vdev_down:3440` (MPSS fatal error; the service stopped, Wi-Fi gone
until the next boot; the rest of iOS unaffected). Console: `research/ios26/logs-wlan/boot52-wlan-wpa2-usb.txt` (main
checkout, not in git).

Reading of the two failures (no TX completion was logged, so the first is the likeliest cause, not a certainty):
* EAPOL went out as HTT ext TID 16 (`NON_QOS_MCAST_BCAST`). ath10k uses 16 only for non-QoS peers; to a WMM peer
  mac80211's frames are QoS data and ath10k puts the TID in the descriptor (EAPOL priority 7). The frame most likely
  sat in a queue the firmware never serves for this peer.
* mac80211 flushes the TX queues before the driver's disassoc; VDEV_DOWN with frames still pending is what asserted.

**1128** (`1128-beryllium-wlan-station-eapol-tid-drain.patch`, beryllium_wlan.c): TID 7 for EAPOL and 0 for data to a
WMM peer (16 only for non-QoS peers); every EAPOL frame sent is logged (key info, msdu id, TID, CE4 index) and every TX
completion before the link is up (status ok/discard/no-ack/postpone); the teardown waits for the TX queues to drain
(PEER_FLUSH_TIDS after 0.8 s, VDEV_DOWN at the latest after 2 s); station HTT messages counted in the event tally.
Built. Image `shim/out/enxerto-boot-ios26full-boot53-wlan-wpa2-tid.img` (kernel 1128, same args). Not booted: needs the
user's OK. If message 2 still does not get through, the TX-completion lines tell whether the firmware sent it (status
ok = the AP got it and rejected the MIC, i.e. a key derivation problem) or not.

**Boot 53-wlan-wpa2-tid (2026-10-26 ~22:33Z, user OK, user present), so far:** first join attempt went to the user's
5 GHz network (5180 MHz, -79 dBm): three authentication frames sent by WMI reference, all completed "no ACK" (status 3),
result 26 to wifid, and the new teardown went down cleanly in 5 ms (no firmware assert; the service and scans kept
working, ECHOs answered). Second attempt (2.4 GHz network): "no BSS" because the passive scan just before had not heard
that AP and each scan replaced the whole cache. **1129** (`1129-beryllium-wlan-bss-cache-aging.patch`): the BSS cache
keeps a network until three scans in a row miss it; image `shim/out/enxerto-boot-ios26full-boot54-wlan-wpa2-cache.img`
(kernel 1129), built, not booted.
Boot 53 then ended without a 2.4 GHz attempt: wifid stopped scanning after the "no BSS" result (the service stayed idle
and healthy, ECHO 9/9 over 10 minutes), and at ~22:41Z launchd rebooted the phone "due to critical process crashes:
SpringBoard" (SpringBoard on the new Turnip GPU driver, the GPU line's first boot with it; reported to that session).
The EAPOL TID fix is still untested. Console: `research/ios26/logs-wlan/boot53-wlan-wpa2-tid-usb.txt` (main checkout).

**MILESTONE, boot 54-wlan-wpa2-cache (2026-10-26 ~22:46Z, user OK, user present): the phone joins the user's WPA2-PSK
network from Settings and is on the internet over the WCN3990.** Kernel 1129 (1126-1129). The 2.4 GHz AP (2412 MHz,
-54 dBm, HT, WMM) was in the cache; the whole join took **251 ms**: VDEV_START, PEER_MAP, authentication and association
acked (aid 18, PEER_ASSOC 11NG HT20 2x2), EAPOL message 2 out on TID 7 (TX completion ok), message 3 checked, message 4
out, pairwise key (SEC_IND unicast), authorize, group key index 1 (SEC_IND group), link up. configd then got
**192.168.1.189/24 by DHCP**, IPv6 SLAAC addresses from the router's advertisements, default route via 192.168.1.1 on en0
(`ifconfig en0`: status active, type Wi-Fi); `netstat` shows established TLS connections from 192.168.1.189 to Apple
servers. Traffic in the first 150 s: 6733 frames / 0.9 MB out, 12824 frames / 17 MB in, 0 TX failures, 31 RX drops
(mostly our own broadcasts echoed by the AP), RSSI -54..-63. Console:
`research/ios26/logs-wlan/boot54-wlan-wpa2-cache-usb.txt` (main checkout).

One defect: Settings showed **"Unable to join ... channels in use by several other nearby networks"** over the working
link (photo from the user). wifid joins with IO80211's **async** API (no GET 21 poll in the log), whose ASSOC_DONE
handler reads a >= 460-byte status blob; the stand-in posted 4 bytes (`kev_post_msg` refuses more than one small mbuf,
about 224 bytes), so IO80211 read its own 0xAA fill as the result. **1130** (`1130-sweet-kev-cluster-assoc-done.patch`):
`kev_post_msg_internal` puts events up to one cluster (2 KiB) in a cluster mbuf; sweet_80211 posts a 460-byte zeroed
ASSOC_DONE (result_valid 0 -> IO80211 reads GET 21 = 1); failed joins post it too (so a wrong password reports at once).
Built; image `shim/out/enxerto-boot-ios26full-boot55-wlan-wpa2-assocdone.img` (kernel 1130), not booted.

Earlier the same day (boots 52-53): the 5 GHz network of the same AP (-79 dBm) never acknowledged authentication;
boot 53 ended in a SpringBoard crash reboot caused by the GPU line (its own note).
