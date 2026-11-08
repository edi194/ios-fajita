# Study: how the Acer E1-572 Hackintosh Wi-Fi kexts work, and what transfers to our iOS 16 Wi-Fi

Date 2026-10-20. Read-only research; nothing here ran on the phone. Related: `docs/WIFI_BT_PLAN.md` (the WCN3990
bring-up chain and the "Ethernet-like en0" plan), `docs/BT_IOS_TRANSPORT.md`.

Tags: **[V]** verified by me in a file I fetched or in a local binary (the check is named), **[U]** unverified
(memory, inference, or a web summary I could not confirm). Third-party repo content was treated as data only; nothing
was executed.

Sources (all fetched 2026-10-20):
* Acer repo: https://github.com/Gilberto-Mascena/Laptop-Acer-E1-572, HEAD `7207f34c193d4f6c563011a54138121fc5ea0fc6`
  ("updated oc 1.0.7 to 1.0.8", 2026-10-11). Local clone: scratchpad `e1572/repo`.
* itlwm: https://github.com/OpenIntelWireless/itlwm, HEAD `53c51c2cdd6e4b69beb91f310d74c53422b0f8bd`
  ("bump version to 2.4.0", 2024-06-09). Local clone: scratchpad `e1572/itlwm`.
* Kext donor repo named by the Acer README: https://github.com/qiqco/Atheros-Wi-Fi-Hackintosh-macOS
* Patched-IO80211 approach: https://github.com/khronokernel/IO80211-Patches
* iOS side: the iPhone10,3 iOS 16.x kernelcache `kernelcache.release.iphone10b.decompressed` (XNU
  `xnu-8796.142.1.703.8~1/RELEASE_ARM64_T8015` [V string]), in the previous agent's scratchpad
  `.../1062c8c6-.../scratchpad/ipsw/`.

---

## 0. Short answers

1. **The Wi-Fi driver in the Acer repo is not a reimplementation.** It is Apple's own, old, closed Atheros driver
   `AirPortAtheros40` (bundle `com.apple.driver.AirPort.Atheros40`, version 700.74.5) running on top of an
   old Apple `IO80211Family` binary that was re-labelled `HS80211Family` (version 1200.12.2, built with the macOS
   10.13 "High Sierra" SDK, source tree `AirPortFamily-1406.15.1`). [V Info.plists + binary strings.] The repo ships
   those two Apple binaries with edited Info.plists and loads them with OpenCore `Kernel -> Add`. Card: **Atheros
   AR9565** (README). [V]
   There is **no** itlwm/AirportItlwm in that repo (the "IntelMausi" name in its README list is for Ethernet and is not
   even in `Kernel -> Add`). The wired NIC is a Broadcom BCM57786 (`AppleBCM57XXEthernet`), the BT is `Ath3kBT`. [V]
2. **The thing worth studying as an architecture is therefore two things:** (a) Apple's real
   `IO80211Controller` subclass contract, visible in the `AirPortAtheros40` binary, which has symbols; and
   (b) itlwm's `AirportItlwm`, the open-source clean-room implementation of that same contract (a Wi-Fi driver for
   a chip whose firmware Apple does not know), including its Skywalk variants for macOS 12-14.
3. **For iOS 16 the Wi-Fi stack is Skywalk-era IO80211Family**, the same generation as itlwm's
   `AirportItlwmV2`/Sonoma code (subclasses of `IO80211SkywalkInterface`/`IO80211InfraProtocol`), not the
   `IO80211Interface`/`IOEthernetInterface` generation the Atheros40 binary was built against. Concepts transfer;
   the binary ABI of the old kexts does not.
4. **Neither option A nor B is cheap.** A (own IO80211-compatible classes) means re-creating a closed kext's
   userland-visible contract with no symbols on iOS. B (load Apple's IO80211Family from the kernelcache) means
   solving a link problem that is hard on an old-style prelinked A11 kernelcache, plus pulling in
   IONetworkingFamily/IOSkywalkFamily/corecapture/IOReport dependencies. My recommendation (section 5) is to
   keep the existing plan from `WIFI_BT_PLAN.md` (first make WCN3990 pass traffic as a plain `en0`), and treat the
   Apple80211 surface as a later, separately-scoped phase, using Option A and the macOS-with-symbols binaries as the
   map.

---

## 1. What is in the Acer repo

### 1.1 Kexts (EFI/OC/Kexts) vs `config.plist` Kernel -> Add [V, parsed with plistlib]

Both lists agree (25 entries, one disabled):

| Kext | Role |
|---|---|
| Lilu, WhateverGreen, AppleALC, RestrictEvents, RTCMemoryFixup, CpuTscSync, CPUFriend(+DataProvider) | acidanthera helper/patch kexts |
| VirtualSMC, SMCProcessor, SMCBatteryManager, SMCSuperIO | SMC emulation |
| VoodooPS2Controller (+Keyboard/Mouse/Trackpad plugins) | input |
| USBMap | USB port map |
| AppleBCM57XXEthernet | Apple's own Broadcom NIC kext, re-injected |
| **AirPortAtheros40** | **Wi-Fi driver (Apple, old)** |
| **HS80211Family** | **Wi-Fi family (Apple's 10.13 IO80211Family, renamed)** |
| **Ath3kBT** (+ `Ath3kBTInjector`, disabled) | Atheros AR3012/AR9565 Bluetooth firmware loader (not Wi-Fi) |

`Kernel -> Block` holds only a disabled `AppleTyMCEDriver` entry, `Kernel -> Patch` is empty, `boot-args` are
`keepsyms=1 debug=0x100`, `SystemProductName` MacBookAir7,1, SecureBootModel Disabled. [V] So **no kernel patch and
no Block of the stock `IO80211Family`** is used; coexistence of the stock family and `HS80211Family` is not explained
by anything in this repo. [U on how the duplicate class names are tolerated; see 1.3.] A DeviceProperties entry
`PciRoot(0x0)/Pci(0x1C,0x3)/Pci(0x0,0x0)` sets `built-in = 1` (the Wi-Fi card, so macOS treats it as an internal
AirPort). [V]

The README says it targets Catalina and Big Sur and states "Not supported on macOS Monterey". The Atheros kexts
come from the qiqco repo, whose README (Chinese; summary via fetch) says "Big Sur and earlier", lists per-chip builds
(AR9285, AR9462, AR9463, AR9565, AR9485) and says to load HS80211Family before the AirPortAtheros40 build.
[V for the Acer README link text; U for the qiqco text beyond the fetch summary.]

### 1.2 `AirPortAtheros40.kext` [V]

* `Contents/Info.plist`: one personality `AirPort_AtherosNewma40`, `IOProviderClass = IOPCIDevice`, `IOProbeScore 700`,
  `IONameMatch` = `pci168c,32 / 33 / 34 / 37 / 36 / 2a / 1c / 23 / 24` and `pci106b,0086`. (0x168c = Qualcomm
  Atheros; 0x0036 is the AR9565 device id [U for the id-to-chip mapping; the strings below say AR9565 explicitly].)
* `OSBundleLibraries` lists `com.apple.iokit.HS80211Family 600.0` where stock Apple's kext lists
  `com.apple.iokit.IO80211Family`. **That one edited dependency string is the whole "reinjection" trick on the driver
  side.** [V for the HS80211Family dependency; U for what stock listed, from memory.]
* The Mach-O (x86_64 kext bundle, 1.65 MB, keeps its symbol table) is built from Apple's tree
  `AirPortDriverAtheros9388-700.74.5/src/os/darwin/src/AtherosController.cpp` [V string]. It contains the whole
  Atheros AR9300-family HAL (functions `ar9300AniRestart`, `ar9300SolveIqCal`, `Ar9300PAPDSetupSingleTable`, a
  "HAL ABI mismatch" check, an `AR9565` string) statically linked in. [V strings] The chip is driven entirely by host
  code (a mac80211-style "softmac" design: host owns 802.11 state, firmware is only the on-chip bootloader/NVRAM),
  which is *different* from WCN3990 where the chip firmware speaks WMI. [U beyond the HAL strings.]
* Classes (from `nm`): `AirPort_AtherosNewma40` (241 methods), `AtherosNewma40Interface` (37),
  `AtherosNewma40P2PInterface` (43), `AtherosNewma40Timer`, `AtherosNewma40WorkLoop`, `Lock`. [V]
  `AirPort_AtherosNewma40` is a subclass of `IO80211Controller` [V: undefined references to
  `IO80211Controller::IO80211Controller(OSMetaClass const*)`, `IO80211Controller::gMetaClass`, etc.].

### 1.3 `HS80211Family.kext` [V]

* `CFBundleIdentifier com.apple.iokit.HS80211Family`, `CFBundleVersion 1200.12.2`, `DTSDKName macosx10.13internal`,
  `BuildMachineOSBuild 16B2657`, `OSBundleRequired Network-Root`, and a bogus
  `CFBundleGetInfoString "12.0, Copyright (c) 2005-2016 Asly"` (the re-packager's mark). `IOKitPersonalities` is
  empty: it is a pure library kext (no matching of its own).
* The Mach-O (1.16 MB, 3816 symbols kept) is stock Apple code: paths like
  `/BuildRoot/.../AirPortFamily_kexts/AirPortFamily-1406.15.1/HS80211Family/BaseClass/IO80211Interface.cpp` appear in
  its strings, i.e. Apple's own directory was already named `HS80211Family` inside Apple's tree at that version (Apple
  later renamed it to IO80211Family; [U] whether the *directory* name is the original or the packager's edit; I only
  saw the strings). Classes it defines (method counts via `nm`): `IO80211Controller` 132, `IO80211Interface` 186,
  `IO80211VirtualInterface` 155, `IO80211P2PInterface` 56, `IO80211PeerManager`/`AWDLPeerManager`/`AWDLPeer`,
  `IO80211ScanManager`, `IO80211CommandQueue`, `IO80211WorkLoop`, `IO80211FlowQueue*`, `IO80211InterfaceMonitor`,
  `IO80211ControllerMonitor`, `IO80211NetBootNub`, `RSNSupplicant` (59), `LogManager`, ... [V]
* Why the repack exists (as documented by other people, [U], web summaries):
  Mojave 10.14 dropped the Atheros plugin from Apple's family; Catalina 10.15 stopped honouring an injected 10.13
  `AirPortAtheros40` because the *family* ABI (virtual table layout of `IO80211Controller`/`IO80211Interface`) changed;
  the community fix is to ship the 10.13 family alongside the 10.13 driver
  (osxlatitude threads; khronokernel's repo does the same for Broadcom with symbol-renamed families and MinKernel
  gating `16.0.0 / 18.0.0 / 19.0.0 / 20.0.0`). Whether `HS80211Family` has renamed its C++ class symbols the way
  khronokernel's does: the strings `IO80211Controller` and `IO80211Interface` are present unchanged in its cstring
  area, so at least the OSMetaClass registration names are not renamed. [V for the strings; U for how the stock family
  and this one coexist.]
* A single-user forum report says Big Sur refuses to replace a stock prelinked kext ("Refusing new kext") [U].

**Take-away for us:** the Acer setup works because Apple's driver and Apple's family are both *old, matched, and
symbolled*, and the kernel's KPI for them (IOKit, IONetworkingFamily, IOReporter) is still ABI-compatible with macOS
10.13-era binaries. None of that is true for iOS 16.

---

## 2. Architecture of an IO80211 driver (from `AirPortAtheros40`, and from itlwm's clean-room version)

### 2.1 Class graph [V Atheros40 `nm`; V itlwm headers]

```
IOService > IONetworkController > IOEthernetController > IO80211Controller          (family, closed)
                                                          ^ AirPort_AtherosNewma40 (Apple driver)
                                                          ^ AirportItlwm           (itlwm, Monterey and older)
IONetworkInterface > IOEthernetInterface > IO80211Interface                          (family; "primary STA" netif)
IO80211VirtualInterface > IO80211P2PInterface                                       (AWDL, P2P, soft-AP)
 ^ AtherosNewma40Interface / AtherosNewma40P2PInterface                              (driver-side subclasses)
 ^ AirportItlwmInterface (a thin IO80211Interface subclass, itlwm AirportItlwmInterface.cpp, 50 lines)
```

Skywalk generation (macOS 12 "V2" headers in itlwm, macOS 13/14 Sonoma plists; iOS 16 matches it, section 3):

```
IOSkywalkInterface > IOSkywalkNetworkInterface > IOSkywalkEthernetInterface > IO80211SkywalkInterface
                                                                                > IO80211InfraProtocol  (virtual getXXX/setXXX table)
                                                                                > IO80211InfraInterface (iOS name, kernelcache strings)
IO80211Controller (V2: still `: IOEthernetController`, now with createWorkQueue(), getWorkQueue(),
                   IO80211WorkQueue, apple80211SkywalkRequest(), getLogPipes() -> CCPipe/CCStream)
```
[V itlwm `include/Airport/IO80211ControllerV2.h`, `AirportItlwmV2.hpp` lines 42-137,
`AirportItlwmSkywalkInterface.hpp`.]

### 2.2 The control path: Apple80211 ioctls [V]

* Userland (`Apple80211.framework`, wifid, airportd, `ifconfig`-like tools) issues `SIOCSA80211` / `SIOCGA80211` on
  the Wi-Fi netif. The value in the Atheros40 binary is `0x802869c8` (set, `_IOW('i',200,0x28)`) and `0xc02869c9`
  (get, `_IOWR('i',201,0x28)`), matching itlwm `apple80211_ioctl.h` (`2150656456` / `3224398281` for
  `__IO80211_TARGET >= 10.15`; an older pair `2150132168` / `3223873993` with a 0x20-byte struct is also in the header).
  The payload is `struct apple80211req { char ifname[16]; int req_type; int req_val; u32 req_len; void *req_data; }`
  (40 bytes on LP64). [V disassembly of `apple80211Request` in Atheros40 at +0x20788 compares exactly these two
  constants; V header.]
* Family dispatch: `IO80211Controller::apple80211_ioctl()` (family) -> `apple80211_ioctl_get/set()` -> the driver's
  virtual `SInt32 apple80211Request(unsigned int type, int req_number, IO80211Interface*, void* data)`.
  The driver switches on `req_number` (`APPLE80211_IOC_*`, 287 symbols in itlwm's header; e.g. SSID=1, AUTH_TYPE=2,
  CIPHER_KEY=3, CHANNEL=4, TXPOWER=7, RATE=8, BSSID=9, SCAN_REQ=10, SCAN_RESULT=11, CARD_CAPABILITIES=12, STATE=13,
  ...). In the Atheros40 binary this is the large per-selector `getXXX/setXXX` method family: about 150 distinct
  names, e.g. `setSCAN_REQ`, `getSCAN_RESULT`, `setASSOCIATE`, `setDISASSOCIATE`, `setCIPHER_KEY`, `setSSID/getSSID`,
  `getSTATUS_DEV`, `getSUPPORTED_CHANNELS`, `getCARD_CAPABILITIES`, `getRADIO_INFO`, `setPOWER`, `setCOUNTRY_CODE`,
  `getSTA_STATS`, `setVIRTUAL_IF_CREATE/DELETE`, `setP2P_*`, ... [V `nm | c++filt`]. Notice that the Atheros
  driver additionally gates a few selectors (12 `CARD_CAPABILITIES`, 0x57, 0x2b) while the card is asleep
  (string "call allowed during sleep") [V].
* itlwm reproduces this with the macros `IOCTL / IOCTL_GET / IOCTL_SET` in `AirportItlwm.hpp` and the switch in
  `AirportSTAIOCTL.cpp:16` (1531 lines; about 60 selectors really implemented, the rest return
  `kIOReturnUnsupported`). [V]
* In the Skywalk generation the switch moved: the interface object (`AirportItlwmSkywalkInterface :
  IO80211InfraProtocol`) now overrides ~100 typed virtual `getXXX(apple80211_xxx_data*)` / `setXXX(...)` methods and the
  controller sees `apple80211SkywalkRequest(UInt, int, IO80211SkywalkInterface*, void*[, void*])` and
  `apple80211_ioctl(IO80211SkywalkInterface*, unsigned long, void*, bool, bool)`. Most unimplemented ones are
  one-line `return kIOReturnUnsupported`. [V `AirportItlwmSkywalkInterface.hpp`, `AirportItlwmV2.hpp`]

### 2.3 How scan results and link state reach the Apple stack [V itlwm]

* **Scan request**: `setSCAN_REQ` / `setSCAN_REQ_MULTIPLE` (itlwm `AirportSTAIOCTL.cpp:1327,1363`) start the OpenBSD
  bgscan (`ieee80211_begin_cache_bgscan`) and arm a 100 ms `IOTimerEventSource` (`fakeScanDone`,
  `AirportItlwm.cpp:445`). When it fires the driver posts `APPLE80211_M_SCAN_DONE` with
  `IO80211Interface::postMessage()`. Return value 22 (EINVAL) means "busy/not ready".
* **Scan result retrieval** is a *pull iterator*, not a callback: userland calls `getSCAN_RESULT` repeatedly; each call
  returns one `apple80211_scan_result` (BSSID, SSID, channel + flags, RSSI, noise, beacon interval, capability,
  rates, IE blob), `fNextNodeToSend` walks the net80211 node tree, return `5` means "end of list" (then wraps),
  `12` means "no results". (`AirportSTAIOCTL.cpp:1394-1450`.) The struct layout changes at macOS 12 (IE data became
  an inline array instead of a pointer) and at macOS 13 (channel flag encoding). [V `#if __IO80211_TARGET < __MAC_12_0 / 13_0`]
* **Association**: `setASSOCIATE` carries SSID, BSSID, RSN IE, auth types; itlwm stores them and starts the
  net80211 state machine (`associateSSID`, `AirportSTAIOCTL.cpp:1025`). Keys: **`setCIPHER_KEY`** arrives from
  Apple's `RSNSupplicant`/`wpa` code after the 4-way handshake (flag 4 = PTK, 0 = GTK), the driver installs it
  (`setPTK/setGTK`) and posts `APPLE80211_M_RSN_HANDSHAKE_DONE`. Apple's supplicant is used when
  `useAppleRSNSupplicant()` returns true (itlwm: build flag `USE_APPLE_SUPPLICANT`); otherwise the driver runs
  OpenBSD's own supplicant.
* **Link state**: net80211 reaches RUN -> driver `setLinkStatus(kIONetworkLinkActive...)` -> a command-gate action calls
  `IO80211Interface::setLinkState(kIO80211NetworkLinkUp, reason)` (`AirportItlwm.cpp:531-556`), plus
  `postMessage(APPLE80211_M_LINK_CHANGED)` and `APPLE80211_M_ASSOC_DONE / DEAUTH_RECEIVED`.
  `getSTATE`, `getASSOCIATE_RESULT`, `getLINK_CHANGED_EVENT_DATA` give polled copies of the same truth.
* **Data path (pre-Skywalk)**: `IO80211Controller::outputPacket(mbuf_t, void*)` (queue) or `outputStart(...)`
  for TX; `IO80211Interface::inputPacket()` (mbuf) for RX; 802.3<->802.11 conversion in the driver (net80211 `ic_if`
  `if_snd`). **Data path (Skywalk)**: `IO80211SkywalkInterface` + packet pools + `requestPacketTx`; itlwm V2 builds
  an `IOSkywalkEthernetInterface::RegistrationInfo`, calls `initRegistrationInfo`, `attachInterface`,
  `deferBSDAttach(true)` and bridges to the old mbuf path internally. [V `AirportItlwmV2.cpp:184-330`]
* **Power**: `setPowerState`/`powerChange`/`syncPowerState` and `setPOWER`; `getPOWER_DEBUG_INFO`; sleep gating.
  [V Atheros40 symbols; V itlwm `FUNC_IOCTL(POWER,...)`.]

### 2.4 How itlwm was reverse-engineered [V in repo, U on process]

* Headers in `include/Airport/` (`IO80211Controller.h`, `IO80211Interface.h`, `IO80211VirtualInterface.h`,
  `IO80211SkywalkInterface.h`, `IO80211InfraProtocol.h`, `IOSkywalk*.h`, `apple80211_var.h`, `apple80211_ioctl.h`,
  `CC*Pipe.h`) are hand-reconstructed: virtual tables padded with `_RESERVEDxx` slots and `static_assert(offsetof(...))`
  checks against observed layouts (e.g. `apple80211_key` offsets 80/92/100/104/120 in `setCIPHER_KEY`). The
  `apple80211_*.h` come from Apple's old Darwin sources (APSL 1.1 header text in `apple80211_ioctl.h`) and were then
  extended by hand. Lineage per their README: Black80211-Catalina, rpeshkov/black80211, mercurysquad/Voodoo80211.
* Ordering of virtuals matters: they must match the real IO80211Family vtable of each macOS version, hence the
  `__IO80211_TARGET` `#if`s and the separate `Monterey` / `Sonoma` Info.plists and `AirportItlwm` vs `AirportItlwmV2`
  sources (the V2 file is a near copy, 1053 lines each). [V]
* Skywalk-specific hacks that illustrate the fragility: itlwm names its log pipe `AppleBCMWLAN_Datapath` and
  copies Broadcom's `CCPipe`/`CCStream` options to satisfy the family; it sets
  `fNetIf->mExpansionData->fRegistrationInfo` directly by `IOMalloc` + `memcpy`
  (`AirportItlwmV2.cpp:309-315`); the personality uses `IOMatchCategory = WiFiDriver` and the provider class
  `IOPCIEDeviceWrapper` (a small shim they wrote around the PCI device, `IOPCIEDeviceWrapper.cpp`). [V]

### 2.5 itlwm vs AirportItlwm [V]

* `itlwm/` (non-Airport): `IOEthernetController` + an Ethernet-looking `en0`, with a separate `Heliport` GUI to join
  networks; **no** IO80211 involvement. This is the exact idea in `WIFI_BT_PLAN.md` section 4 option 1.
* `AirportItlwm/`: `IO80211Controller` subclass so that macOS's own Wi-Fi menu, airportd, Control Center, etc. work.
* Shared core: `itl80211/` = a port of OpenBSD `net80211` (state machine, node tree, crypto CCMP/TKIP/WEP/BIP,
  rate control RA/MiRA/AMRR, regdomain; headers keep `$OpenBSD: ieee80211_proto.c,v 1.95 ...`) and the
  chip HALs `hal_iwm/iwn/iwx` driven through the abstract `ItlHalService` (`include/HAL/ItlHalService.hpp`).

---

## 3. Mapping to iOS 16 on our XNU

### 3.1 What the iPhone10,3 kernelcache actually has [V unless marked]

* Prelinked, **old-style single Mach-O** kernelcache (`MH_EXECUTE`, `__PRELINK_TEXT`, `__PLK_TEXT_EXEC`,
  `__PRELINK_INFO`, not an `MH_FILESET`), arm64 **non-PAC** (A11 / T8015), XNU 8796 (iOS 16.7.x). `file` and
  `otool -l` segment list.
* Bundles present (from `__PRELINK_INFO` and the previous `sel.plist`): `com.apple.iokit.IO80211Family`,
  `com.apple.iokit.IOSkywalkFamily`, `com.apple.iokit.IONetworkingFamily`, `com.apple.driver.AppleBCMWLANCore`
  (+`...CoreV3`, `...BusInterfacePCIe`), `com.apple.driver.BCMWLANFirmware4357.Hashstore`, `corecapture`,
  `CoreAnalyticsFamily`, `IOTimeSyncFamily`, `IOReportFamily`, `AppleMobileFileIntegrity`, `AppleOLYHAL`, `IOImageLoader`.
  `AppleBCMWLANCore` personality: `IOClass AppleBCMWLANCore`, **`IOMatchCategory WiFiDriver`**,
  `IOProviderClass AppleBCMWLANBusInterfacePCIe` (matches PCIe vendor 0x14e4); its `OSBundleLibraries` include
  `IO80211Family`, `IOSkywalkFamily`, `IONetworkingFamily 1.5.0`, `corecapture`, `CoreAnalyticsFamily`,
  `IOTimeSyncFamily`, `AppleOLYHAL`, `IOImageLoader`.
  (The `AppleBCMWLANCore` prelinked entry is at 0xfffffff005475700, size 0x8299f; the `IO80211Family` entry I located
  has load address 0xfffffff0053fd9c0 with a small `_PrelinkExecutableSize 0x51ac`, which does not look like the whole
  kext: my regex-based parse of the ID/IDREF-serialized plist is not trustworthy for sizes. [U])
* Class-name strings inside the Skywalk-era family (counts in the kernelcache string dump): `IO80211SkywalkInterface`
  (20), `IO80211InfraInterface` (16), `IO80211Controller` (20), `IO80211VirtualInterface` (22),
  `IO80211APSTAInterface`, `IO80211P2PSteeringManager`, `IO80211NAN*` (NAN stack), `IO80211TSNWiFiControlInterface`,
  `IO80211APIUserClient` (12), `IO80211IOUCEventPipe`, `IO80211InterfacePostMessage`, `IO80211LinkRecovery`,
  `IO80211ScanManager` (39), `IO80211PeerManager`, `IO80211AWDLPeerManager`, `IO80211BufferPool`/`IO80211NetworkPacket`.
  Broadcom classes: `AppleBCMWLANSkywalkInterface`, `AppleBCMWLANIO80211APSTAInterface`,
  `AppleBCMWLANPCIeSkywalkPacket`, `AppleBCMWLANNANInterface`, `AppleBCMWLANTimeSyncEngine`. IOSkywalkFamily:
  `IOSkywalkEthernetInterface`, `IOSkywalkLegacyEthernetInterface`, `IOSkywalkNetworkInterface`,
  `IOSkywalkPacketBufferPool`, `IOSkywalkTx/RxSubmissionQueue`, `IOSkywalkNetworkBSDClient`, ...
  The class-name strings sit in `__PRELINK_TEXT` (file offsets 0xfff989..0x1011e03 for the IO80211 ones, i.e. next
  to AppleBCMWLANCore's), so the family really is a prelinked kext and not inside XNU. [V]
* Kernel-side Skywalk (`bsd/skywalk`: nexus, netif, kern pipes, flowswitch) is **in open XNU and already compiled
  into our kernel** ("Skywalk self-tests PASSED" in NOTES.md, `research/bt125/xnu/bsd/skywalk` exists). What is closed
  is **IOSkywalkFamily** (the IOKit objects on top) and everything above it. [V]
* Our kernel has *no* IONetworkingFamily: `0110-sweet-configd-network-interface.patch` defines minimal stand-in
  classes `IONetworkInterface`, `IOEthernetInterface`, `IONetworkStack` (+ a user client) in
  `iokit/Kernel/arm/SweetNetwork.cpp` purely so configd adopts `ue0`. [V patch text] Anything inheriting from
  `IOEthernetController`/`IONetworkController` (all IO80211 classes, and AppleBCMWLAN) therefore has no base class
  today.

### 3.2 What transfers from itlwm / AirPortAtheros40

| Piece | Transfers? | Notes |
|---|---|---|
| The Apple80211 selector set and per-selector semantics (`SSID`, `SCAN_REQ/RESULT`, `ASSOCIATE`, `CIPHER_KEY`, `STATE`, `POWER`, `CHANNEL`, `SUPPORTED_CHANNELS`, `CARD_CAPABILITIES`, `COUNTRY_CODE`, `LINK_CHANGED_EVENT_DATA`...) | **Yes (as a spec)** | Same names in iOS: `apple80211_*` data structs are used by Apple80211.framework on iOS too [U, must be checked in the dyld cache]. itlwm already documents ~60 real implementations and which return values mean "end of scan list" (5), "no results" (12), "busy" (22). |
| Event model: `postMessage(APPLE80211_M_*)` + `setLinkState` + pull-iterator scan results | **Yes** | Same contract in macOS 13/14 Skywalk code. |
| Apple's RSN supplicant doing the 4-way handshake and calling `setCIPHER_KEY` | **Yes, very useful** | If the real family's `RSNSupplicant` is used (option B) or we mimic `useAppleRSNSupplicant() == true` (option A, but then wifid/`airportd`-side or family-side code must exist), we avoid writing WPA2 in the kernel. For WCN3990 the keys go to firmware by WMI. |
| OpenBSD `net80211` (itl80211) | **Maybe, probably not needed** | WCN3990 firmware (ath10k) is a host-managed-mgmt FW (host must build auth/assoc frames over WMI mgmt TX; ath10k relies on mac80211), so a net80211-style state machine is genuinely needed on the host *or* a small purpose-built STA state machine. itl80211 is a ready-made one with CCMP/TKIP in software, but see licensing (4.3). Firmware does CCMP in hardware once keys are installed. [U on how much of ath10k's WMI mgmt path we can drive.] |
| Intel HAL (`hal_iwm/iwn/iwx`) | No | Our HAL is WMI/WLFW over QMI over QRTR over GLINK (see `WIFI_BT_PLAN.md` 1.5). |
| PCI wrapper (`IOPCIEDeviceWrapper`), `IOPCIDevice` power management, MSI | No | SoC WLAN is MMIO + SMMU stream + SNoC, not PCIe. |
| IOKit match: `IOMatchCategory = WiFiDriver` | **Yes** | iOS's own Wi-Fi driver uses the same match category (V above). Also what itlwm Sonoma Info.plist uses. |
| The **header reconstructions** (`IO80211*.h`, `IOSkywalk*.h`) | Partly | They target macOS 12-14 vtable order. iOS 16 = macOS 13 era (XNU 8796 = macOS 13.x), but iOS-only changes (`IO80211InfraInterface` naming, NAN/TSN additions) mean vtable offsets must be re-derived from the iOS kernelcache for Option B. For Option A we define our own classes, so vtable order is irrelevant; only *user-visible behaviour* matters. |
| AirPort UI (menu bar, `airportd`, Network preference pane) | **No** | macOS-only. iOS uses **wifid** (+MobileWiFi, `com.apple.wifid` mach service) -> Apple80211.framework -> IOKit user client on the interface (kernelcache has `IO80211APIUserClient`). How wifid opens the interface on iOS 16 (BSD ioctl on an `AF_INET` socket vs `IOServiceOpen` of `IO80211APIUserClient`) is **[U]; first thing to confirm in the dyld cache.** |
| Atheros40's `AirPort_AtherosNewma40` binary as a driver | **No** | x86_64, old family ABI, matches a different chip, host-driven HAL. Useful only as a *symbol-rich reference* for the old virtual table. |

### 3.3 Option A: our own IO80211-compatible classes inside the kernel [design sketch]

We compile the kernel from source, so no kext loading and no ABI matching are needed; we need to reproduce *behaviour*.

Minimum set to get Settings -> Wi-Fi to list networks and join one, in order:
1. Base classes the family inherits: `IONetworkController` / `IOEthernetController` / `IONetworkInterface` (open
   source in apple-oss-distributions' `IONetworkingFamily` [U on the exact tag; I did not fetch it]) compiled into the
   kernel, replacing the stand-ins in `SweetNetwork.cpp`. Without these nothing named `IO80211*` can be a subclass.
2. `IO80211Controller`-like object publishing `IOMatchCategory WiFiDriver`, `built-in`, `IOMACAddress`, and a
   `IO80211InfraInterface`/`IO80211SkywalkInterface`-like child with BSD name `en0` registered as a real `ifnet`
   (the existing `ue0` code path shows how to publish to configd).
3. The user-visible control channel wifid uses: either the SIOC[GS]A80211 ioctl (add the two ioctl numbers to the
   interface ioctl handler, decode `apple80211req`, dispatch to ~25 getters/setters) or `IO80211APIUserClient`
   external methods. The set that wifid minimally needs (first-boot, scan, join, status): SSID, BSSID, CHANNEL,
   RSSI, NOISE, STATE, PHY_MODE, OP_MODE, SUPPORTED_CHANNELS, COUNTRY_CODE, POWER, CARD_CAPABILITIES, TXPOWER, RATE,
   SCAN_REQ, SCAN_RESULT, ASSOCIATE, DISASSOCIATE, CIPHER_KEY, AUTH_TYPE, RSN_IE, DRIVER_VERSION, HARDWARE_VERSION,
   MCS_INDEX_SET, ASSOCIATION_STATUS, LINK_CHANGED_EVENT_DATA, plus the event postings. [U: derived from itlwm's
   implemented list; the real minimal set must be read off wifid/Apple80211 in the dyld cache.]
4. Event delivery to userland (`postMessage` -> `kev_post_msg` KEV_80211 vendor events, observed in the Atheros40/HS
   strings `kev_post_msg failure`, and/or the `IO80211IOUCEventPipe` in iOS) so wifid hears `SCAN_DONE`, `LINK_CHANGED`.
   [V that the old family posts kernel events; U for iOS 16's path.]
5. Our own WCN3990 driver below it (WMI/WLFW from `WIFI_BT_PLAN.md`), plus a WPA supplicant (either Apple's
   `RSNSupplicant` in userland if wifid/`airportd`-like flow does it - **[U]** - or a kernel/userland mini-supplicant
   + `WMI_VDEV_INSTALL_KEY`).
6. Skywalk: **optional at first.** Apple80211 callers do not require the data path to be Skywalk; a legacy ifnet `en0`
   (as `ue0` is) is enough for IP traffic. The Skywalk Wi-Fi classes are only needed if wifid insists on
   `IO80211SkywalkInterface` semantics (unknown). [U]

Effort driver: not the code volume (itlwm's STA ioctl layer is ~1.5 kLOC) but **ignorance of the iOS 16 wifid
contract**, which has to be recovered by disassembly (no symbols in the iOS kernelcache; wifid/Apple80211 binaries
live in the dyld shared cache/rootfs and are readable). The macOS KDK/system binary of the same era
(`IO80211FamilyV2` on macOS 13/14) keeps more symbols than iOS and is the best map [U that the KDK ships it with
symbols; the HS80211Family sample in this repo does keep 3816 symbols, so the older generation certainly did].

### 3.4 Option B: load Apple's IO80211Family from the iOS kernelcache and write only the driver below it

What it would require, in dependency order (everything here is [U] reasoning unless stated):

1. **Closure of dependencies.** IO80211Family imports IONetworkingFamily (open source), IOSkywalkFamily (closed),
   IOReportFamily, corecapture (`com.apple.driver.corecapture`, closed), CoreAnalyticsFamily, AppleMobileFileIntegrity
   (we have a stand-in `sweet_amfi`), `com.apple.kec.corecrypto` (we already stub with `BearSSL`/own PRNG),
   IOTimeSyncFamily. Every one of these either has to be extracted and loaded too or stubbed with exact symbol
   names. (All named in the `OSBundleLibraries` of `AppleBCMWLANCore` and IO80211Family, [V] for AppleBCMWLANCore's list.)
2. **Linking.** The kernelcache is an old-style prelinked image: the kexts' internal and kernel-facing references are
   already resolved to *stock-kernel virtual addresses*; there is no relocatable form and, being stripped,
   no symbol names for the kernel imports. Our source-built kernel has different addresses for every KPI function
   (and differently laid-out `OSMetaClass`/`IOService` vtables unless built identically). Three ways forward:
   * (i) *re-resolve*: parse the kext's text, find every `bl`/`adrp+ldr/add` target outside the kext, map the stock address
     back to a name using the stock kernel's `__LINKINFO`/exports or by matching function prologues, then re-emit
     against our kernel. Needs a purpose-written tool; fragile; no one has published one that I know of [U].
   * (ii) *make our kernel ABI-identical in the exported set* and place the stock kexts at their own addresses
     (loading the stock `__PLK_TEXT_EXEC` slice at the original VA). Would require our kernel to sit at the stock
     kernel's addresses with the same symbol layout: infeasible for a source rebuild.
   * (iii) *use the stock kernelcache as the base*, and patch it (i.e. abandon source-built XNU for this feature). That
     is a different project.
3. **Kext loader.** XNU contains `OSKext` and can load a boot kernel collection, but our kernel does not call it
   (`NOTES.md`: "none of these kexts exist in our source-built XNU", `iokit/KernelConfigTables.cpp` drives matching of
   compiled-in drivers). We would need to run `OSKext`'s start-up path or hand-register every class (`OSMetaClass`
   constructors in `__mod_init_func`/chained inits, kmod_info/`kmod_start`, personalities into the IOCatalogue) for the
   extracted blobs.
4. **Symbol knowledge for the driver below it.** Even with the family running, our driver must subclass
   `IO80211Controller` (V2/Skywalk iOS generation) with a vtable we only know from AppleBCMWLANCore and itlwm's
   macOS 13/14 headers: iOS 16.7 vs macOS 13.x header drift is likely [U]. A one-slot error is a kernel panic.
5. **Code signing / AMFI / entitlements / sandbox** (family user clients check entitlements for
   `com.apple.wifi.*`; our `sweet_amfi` grants none and 0116 has the sandbox-extension work) - manageable but it is
   work on top of the above.

**Assessment:** B delivers Apple's real RSN supplicant, scan manager, flow queues, AWDL/NAN, peer managers for free, but
it needs (2) and (3) solved first, and (2) has no known solution for an old prelinked cache against a different
kernel binary. Because A11 is non-PAC arm64 (no pointer authentication, [V file says arm64 not arm64e]) the binary
patching itself is simpler than on newer chips, but that does not remove the missing symbol/address problem.
**I would not start B.** If B is ever tried, try it as a *reading-only* exercise first: extract the family as an
isolated Mach-O (e.g. with `ipsw kernel` tooling [U which subcommand]) and check whether its external references can be
named at all.

---

## 4. Concrete next steps

### 4.1 Read-only studies (no phone), in this order

1. **Find how wifid talks to the kernel on iOS 16** (decides everything in 3.3). In the iOS 16 dyld shared cache /
   rootfs: `ipsw dyld str <cache> "IO80211APIUserClient"`, `... "SIOCSA80211"`, `"apple80211_ioctl"`,
   `"Apple80211Open"`, `"com.apple.wifid"`, and disassemble `Apple80211Open` / `Apple80211RawSet` /
   `Apple80211Get` in `/System/Library/PrivateFrameworks/Apple80211.framework` (disassemble with `ipsw dyld disass`
   as in NOTES.md for AppleKeyStore). Record: socket/ioctl vs IOKit user client, interface lookup by name or registry
   property, which selector numbers `wifid`/`MobileWiFi` call at startup. Tag: all [U] today.
2. **Selector inventory.** From `libwifid`/`wifid` and `MobileWiFi`: the list of `APPLE80211_IOC_*` numbers they
   issue, and which of those failing is fatal. Cross-check against `include/Airport/apple80211_ioctl.h` (itlwm, 287
   constants; APSL-licensed header text). Produce a table selector -> struct -> semantics -> "needed to boot Settings"
   (the Option A work list).
3. **Kernelcache anatomy of the iOS family.** With `ipsw`/IDA/REA on `kernelcache.release.iphone10b.decompressed`:
   locate the IO80211Family kext image properly (my regex for its `_PrelinkExecutableSize` looks wrong), dump its
   OSMetaClass table (name, size, parent) to get exact class sizes/parents on iOS 16.7, and find
   `IO80211APIUserClient::externalMethod` and its dispatch table (the user-client selector list, replaces step 1 if
   wifid uses the user client). Also AppleBCMWLANCore's override list of `IO80211Controller` (vtable slots with
   mangled-name recovery from macOS binaries).
4. **Get a symbolled sibling.** Pull the macOS 13.x (matching XNU 8796) `IO80211Family`/`IO80211FamilyV2` kext, from the
   Kernel Debug Kit or from a macOS IPSW's BootKernelExtensions collection (`ipsw kernel` on a macOS fileset
   KC can split kexts). Run `nm | c++filt` and compare class list with step 3: that gives mangled names for the
   iOS vtable slots by position. Compare also against itlwm `include/Airport/IO80211*.h` to see which slot order they
   assumed (they already target Ventura/Sonoma).
5. **Same exercise for `AppleBCMWLANCore`'s `IOMatchCategory WiFiDriver` flow**: what registry properties does
   `IO80211Family` expect from the driver in `start()` (itlwm sets `built-in`, `DriverKitDriver=false`; the Broadcom
   driver sets many more). The iOS kernelcache strings around the `AppleBCMWLANCore` kext and the `setProperty` calls
   in `AirportItlwmV2::start` are the two sources.
6. **Reuse check of OpenBSD net80211 vs a minimal custom STA FSM** against `ath10k` WMI needs (WMI mgmt TX, VDEV
   create/up, peer create, key install, scan): decide where the state machine lives. This is part of
   `WIFI_BT_PLAN.md` phase work, not new research.

### 4.2 Symbols to look up in macOS (they keep symbols; HS80211Family sample in this repo has 3816 of them) [V present, in the sample]

From `HS80211Family` and `AirPortAtheros40` already on disk (scratchpad `e1572/repo/EFI/OC/Kexts/`):
`IO80211Controller::{apple80211_ioctl, apple80211_ioctl_get, apple80211_ioctl_set, attachInterface, attachVirtualInterface,
useAppleRSNSupplicant, outputRaw80211Packet, requestPacketTx, getHardwareAddressForInterface,
dataLinkLayerAttachComplete, requestFlowQueue, releaseFlowQueue}`,
`IO80211Interface::{postMessage, setLinkState, inputEvent, setLinkQualityMetric, shouldRoam, willRoam, apCompare,
attachToDataLinkLayer, configureReport, updateReport, enabledBySystem, poweredOnByUser}`,
`IO80211VirtualInterface::*`, `IO80211ScanManager::*`, `RSNSupplicant::*` (59 methods; shows the key-install handshake
contract), `IO80211ControllerMonitor::*`, `IO80211InterfaceMonitor::*`, the `_RESERVEDIO80211Controller0..15` slots.
For the **Skywalk generation** pull macOS 13/14 `IO80211Family`: `IO80211SkywalkInterface::*`,
`IO80211InfraProtocol::*`, `IO80211InfraInterface::*`, `IO80211APIUserClient::*`, `IO80211WorkQueue::*`.

### 4.3 Code and licence reuse

* **itlwm is GPL-2.0-or-later** (`LICENSE` is GPL v2; every `AirportItlwm/*` and `itl80211/*` file header says GPL v2
  "or (at your option) any later version"; the GitHub page also says GPL-2.0; plus a separate Intel firmware licence file
  `iwlwifi-firmware-license`). [V] **It is not BSD/ISC.** Only the *vendored OpenBSD files* underneath carry BSD/ISC
  notices (`$OpenBSD: ieee80211_proto.c,v 1.95 ...`, copyrights of Onoe, Sam Leffler, Bergamini, each with a 3/4-clause
  BSD or ISC text), wrapped by an added GPL header.
* Our kernel tree is XNU = **APSL 2.0** (plus BSD parts). Copying GPL-2.0 files into it and distributing the kernel
  would make the combined work hard to license cleanly. **Recommendation:** treat itlwm as a *reference for behaviour*
  (read it, re-derive our own struct layouts and flows from `apple80211_ioctl.h` and from our disassembly), do not paste
  GPL code. If we want a net80211, vendor OpenBSD's original files directly from `https://github.com/openbsd/src`
  (`sys/net80211`, ISC/BSD) with their own copyright notices, not itlwm's relicensed copies. [U for each
  file's exact notice: check at vendoring time.]
* `apple80211_ioctl.h` / `apple80211_var.h` in itlwm carry the **Apple Public Source License 1.1** header (Apple Computer,
  2005) [V]: that is compatible with our APSL tree in spirit, but the *added* itlwm-authored structs (all of the
  Skywalk-era `apple80211_*_t` additions) are under itlwm's GPL. Plan to re-derive those from disassembly.
* Attribution to record in any derived file: zxystd (钟先耀) / OpenIntelWireless, OpenBSD, rpeshkov/black80211,
  mercurysquad/Voodoo80211, AppleIntelWiFi/Black80211-Catalina (as in itlwm's README credits). The Apple Atheros kexts in
  the Acer repo are proprietary Apple binaries (APSL does not apply to kexts), so **do not redistribute them**; use
  them only as local analysis input.

### 4.4 Rough effort (one engineer, hardware in hand; excludes the WCN3990 bring-up that `WIFI_BT_PLAN.md` covers)

| Work package | Estimate |
|---|---|
| Studies 4.1 (1-3) with notes (wifid/Apple80211 contract, selector table, class table) | 1-2 weeks |
| Studies 4.1 (4-5) (macOS sibling symbols, property expectations) | about 1 week |
| Prerequisite already in plan: kernel WCN3990 up, scan + join one WPA2 network, ifnet `en0` with traffic | per `WIFI_BT_PLAN.md` section 5 (not re-estimated here) |
| Option A "Apple80211-lite": IONetworkingFamily compiled in, a family-lookalike controller+interface, ~25-30 selectors, scan-result iterator, link/scan events, RSN key path; goal Settings lists networks and joins WPA2-PSK | 4-8 weeks after the above, **high variance** because of the unknown iOS wifid contract and entitlements |
| Option A "full" (P2P/AWDL/NAN stubs, power-save, roaming, all wifid-visited selectors) | months; not recommended before lite works |
| Option B (load Apple family) | I would not estimate it; it is blocked on a linking approach that does not exist (3.4 item 2). A feasibility spike of 1-2 weeks only if step 4.1(3) shows the kext can be separated and named |

**Recommended path:** (1) land the plain `en0` over WLAN as in `WIFI_BT_PLAN.md` option 1; (2) do 4.1(1)-(3) in
parallel, they are phone-free and decide whether option A-lite is a 4-week or a 12-week job; (3) build A-lite on top of the
working driver; (4) revisit B only if A-lite is blocked on closed-family behaviour wifid insists on.

---

## 5. Verification log (what I actually ran)

* `git clone` of both repos; `plistlib` parse of `EFI/OC/config.plist` and both kext Info.plists; `nm`, `c++filt`,
  `strings`, `otool -tvV` on `AirPortAtheros40` and `HS80211Family` (x86_64, symbols present: 841 undefined and 3816
  total in HS80211Family).
* Disassembled `AirPort_AtherosNewma40::apple80211Request` (file offset 0x20788): compares the selector against
  `0xc02869c9` and `0x802869c8` and returns EINVAL (0x16) otherwise. [V]
* Read itlwm `AirportItlwm.hpp`, `AirportSTAIOCTL.cpp`, `AirportItlwm.cpp`, `AirportItlwmV2.cpp/.hpp`,
  `AirportItlwmSkywalkInterface.hpp`, `include/Airport/*`, `include/HAL/ItlHalService.hpp`, both Info.plists, `LICENSE`.
* iOS side: `file`/`ipsw macho info`/`otool -l` on the decompressed iPhone10,3 kernelcache; extracted class-name string
  counts from the previous agent's `k.str`; read `sel.plist` for AppleBCMWLAN personalities. My own regex parse of
  `__PRELINK_INFO` for per-kext sizes was unreliable and is marked [U].
* Not done: no disassembly of iOS `IO80211Family` itself, no look at `wifid`/`Apple80211` in the dyld cache, no fetch of
  apple-oss-distributions `IONetworkingFamily`, no check of macOS 13 KDK symbols. These are the items in 4.1.
