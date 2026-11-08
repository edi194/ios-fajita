# Wi-Fi and Bluetooth on iOS 18.7.8 (Heartwood xnu-11215, Poco F1 / WCN3990)

Date 2026-10-24. **Result: Bluetooth works (boot combo9: on, scanning, Settings lists nearby devices); Wi-Fi is blocked (section 3).** What was found on the phone, why Control Center showed Wi-Fi and Bluetooth "Off", what was
fixed, and what still blocks. Background: `docs/WIFI_BT_PLAN.md` (WCN3990 chain), `docs/BT_IOS_TRANSPORT.md`
(how bluetoothd reaches its controller), `docs/WIFI_KEXT_STUDY.md` (IO80211 contract).
Tags: **[V]** seen on the phone or in a file, **[U]** inference.

## 1. State before this work (boot `local-0236.img`, 2026-10-24)

* Kernel: Heartwood xnu-11215 with the whole BT series compiled in (0104 probe, 0117/0118 rails and UART clock,
  0124 firmware download, 0125/0128 in-band sleep, 0132/0133 post-NVM fixes, 0136 `com.apple.uart.bluetooth`
  kernel control) [V strings in the payload]. All of it is off unless `sweetwlan=2 sweetbt=1`, and the boot-args of
  `local-0236.img` had neither [V payload cmdline], so the WCN3990 was never powered.
* ADT: `beryllium-hi-3x-gpufwz.adt` (the GPU-firmware ADT every current image uses) has **no `/arm-io/bluetooth`**:
  `adt-gpufw.py` was run on an ADT made before the rebrand dropped and bt18 restored the node [V].
* Root: `/usr/sbin/BlueTool` is the stub, `BlueTool.orig` kept, `/usr/local/bin/hcitest` present, bluetoothd's
  launchd job has `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000` [V]. No BT firmware under
  `/usr/standalone/firmware/sweet/` (the directory did not exist) [V].
* bluetoothd (unified log): `bluetooth: Unable to match bluetooth service in device tree`, `Not a valid MAC address
  (all 00s)`, `exited due to exit(0), ran for 98ms`, respawned every 10 s by its LaunchEvents [V]. With no
  bluetoothd, Control Center's Bluetooth module shows Off and cannot be turned on.
* wifid never ran: its job has `_LimitLoadToDeviceTree = (wlan, marconi-wifi)` and the ADT has neither node [V
  launchd.plist]. Control Center's Wi-Fi module shows Off.

## 2. Bluetooth

The kernel half had already worked on iOS 16 (logs `usb-20261020-175351.txt`: firmware downloaded at 3 Mbaud, the
kernel control registered, `hcitest` got HCI Reset / Read Local Version (Qualcomm 0x001d) / Read BD_ADDR through
`com.apple.uart.bluetooth`). On iOS 18 three things were missing, plus one new userland blocker.

### 2.1 Fixes

| # | Why it failed | Fix |
|---|---|---|
| 1 | No `/arm-io/bluetooth` in the GPU ADT, so bluetoothd exits 0 ("Unable to match bluetooth service") | `tools/adt-bluetooth.py IN OUT` adds mkadt's `bluetooth_node` (local-mac-address 02:00:5e:77:b0:01, transport-encoding 3, transport-speed 3000000) to any ADT; `beryllium-hi-3x-gpufwz-bt.adt` = gpufwz + node |
| 2 | Boot-args never enabled the BT stage | `sweetwlan=2 sweetbt=1 sweetbtfast=1 sweetbtibs=1 sweetwlandelay=30` (the iOS 16 working set: baud change before the download, Linux IBS bits; stage 30 s after boot instead of 90). The payload cmdline field is 608 bytes; the full line is 601 |
| 3 | No firmware where the stage reads it | `crbtfw21.tlv` (177060 B) + `crnv21.bin` (4587 B), the linux-firmware pair that worked on iOS 16, copied to `/usr/standalone/firmware/sweet/` on the phone (not in git; the root builder should add them, see 2.3) |
| 4 | **Keychain adds fail for everyone**: securityd's `aks_wrap_key` (AppleKeyStore selector 10, inputs {handle 0, class}, 32-byte key in, class + 40-byte wrapped key out) returned `kIOReturnUnsupported` from our stand-in (`SWEET AKS: securityd sel 10 ... -> 0xe00002c7` on every boot). bluetoothd's `readRootKeys` (0x100711600) stores its LE Identity/Encryption roots and Cloud keys as keychain items (service `BluetoothGlobal`, helper 0x10034e594 -> 0x10034bf9c); when a SecItemAdd fails it logs "LeSecurityManager hit a keychain problem" (0x10071204c) and gives up, which is the abort the bt18 notes saw | xnu **0238** `sweet-aks-key-wrap`: selectors 10/11 implemented. "Wrapped" = 8-byte header {'SWAK', class} + the key; unwrap accepts only that header. Not protection (no SEP, no passcode: item keys are readable on disk), but items now round-trip |

### 2.2 Boots

* `bt-0236.img` = `local-0236.img`'s kernel (`ios-beryllium-combined/xnu/out-0236local`) + `beryllium-hi-3x-gpufwz-bt.adt`
  + the cmdline above (fixes 1-3, not 4). Queued 2026-10-24 20:51 UTC; Bergamota's automatic reboot went back to
  iOS instead of fastboot, `bergamota reboot bergamota` reached Bergamota fastboot, flashed and verified 21:01:59 UTC.
  Result [V]:
  * Kernel: firmware downloaded at 3 Mbaud (patch + 19 NVM segments acknowledged), HCI Reset ok, QCA patch version
    0x0002, Read Local Version HCI 9 / Qualcomm 0x001d, BD_ADDR set to 02:00:5e:77:b0:01 with 0xfc14,
    `kernel control com.apple.uart.bluetooth registered: 0`, `transport up` 65 s after boot.
  * `/arm-io/bluetooth` is in IODeviceTree and IOService (IOPlatformDevice).
  * bluetoothd (run by hand with `OS_ACTIVITY_DT_MODE=YES`): `bluetooth: Got local-mac-address: 02:00:5e:77:b0:01`,
    `Searching for transport: "H4BC"` / driver `POSIX`, then `Failed to add attributes to keychain for device Identity
    Root with result -25291` (errSecNotAvailable), `Failed to set new identity root!`, `Bluetooth error - restarting
    { reason=130 }`. The kernel log shows `SWEET AKS: securityd sel 10 ... -> 0xe00002c7` at the same time. It never
    reaches the transport open, so fix 4 (0238) is the next step, as predicted from the disassembly.
* `bt-0238ci.img` = CI run 40132191870 kernel (develop 3f7dfdf + 0238) + same ADT and cmdline, flashed 21:10 UTC.
  Result [V]: `SWEET AKS: securityd sel 10 ... -> 0x0` (74x) and `sel 11 ... -> 0x0` (254x): keychain works;
  bluetoothd finds its keychain items, asks the BlueTool stub ("BlueTool finished running boot script" / "init
  script"), connects to `com.apple.uart.bluetooth` (termios 3000000, cflag 0x38b00) and runs the HCI init: Reset,
  Read Local Version/Commands/Features/BD_ADDR, LE features, event masks, Write SSP/LE Host Supported, LE buffer
  size, data length, PHY, ... every command in the trace answered with status 0. Then
  `OI_HCICMD_WriteDefaultErroneousDataReporting (status=628)`, `HCI initialization failed`, `Bluetooth error -
  restarting { reason=108 }`; launchd respawns it (11 connects in ~5 min). Also seen, not fatal: `Unable to turn on
  BT)_WAKE signal` (no /dev/btwake), TCC "Unable to construct an identity" (root run), WiFiManager lookup failures.
* Fix 5, xnu **0239** `bt-hci-compat`: a Command Complete with status 0x01 (Unknown HCI Command) for a standard
  (non-vendor) opcode is rewritten to success in the kernel, and every rewrite / other error status is logged
  (`SWEET BT: compat: opcode ...`), so one boot lists all missing commands. `sweetbtcompat=0` turns it off.
  [U] that 0x0c5b is answered with 0x01 (the 64-line trace budget ended before it); the log line settles it.
  The phone was handed back to the GPU session (local-0240-gpublit) after this boot.
* `bt-0239ci.img` (built, **not flashed**: the phone is charging): CI run 40133752064 = develop 5692744 (0237 GPU
  page tables, 0240 GPU scan-out copy) + 0238 + 0239, ADT gpufwz-bt, boot-args of local-0240 (`sweetfb_scancopy=2`)
  + the BT set. What to look for: `SWEET BT: compat: opcode ...` lines, then whether bluetoothd logs `Bluetooth
  server started` with the stack up (`fStackStarted:1`) and stays running; then the Control Center toggle.

### 2.3 Still to do for Bluetooth

* Root builder: done in root_tweaks18 `bluetooth()`: `RENEGADE_BT_FW=DIR` (a directory with the linux-firmware
  `crbtfw21.tlv`/`crnv21.bin`; Qualcomm firmware, never in git) installs them in `/usr/standalone/firmware/sweet/`.
* After the transport is up: watch bluetoothd for the BlueTool XPC result, the HCI init sequence in the `SWEET BT:`
  trace (`sweetbtlog`, 64 lines), and Apple vendor commands the Qualcomm controller rejects (docs/BT_IOS_TRANSPORT.md 3.3).

## 3. Wi-Fi: blocker

> iOS 26 re-scope (2026-10-25): docs/WIFI_IOS26.md. On iOS 26 the iOS half no longer needs an IO80211Family
> stand-in; an in-kernel interface with the right IOKit properties and the Apple80211 ioctls is enough.

There is no Wi-Fi driver of any kind yet, at either end:

1. **Chip side.** On SDM845 the WCN3990 WLAN firmware (`wlanmdsp.mbn`) runs inside the modem DSP (MSS). Nothing
   of that chain exists in Heartwood: MSS boot by MBA self-authentication (RMB registers, hyp-assign SCM calls),
   SMEM/SMP2P, GLINK + QRTR, the three host services the modem expects (pd-mapper, tftp, rmtfs with writes dropped),
   the WLFW QMI handshake (MSA, board data, cal, mission mode), then copy engines / HTC / WMI / HTT, the apps SMMU
   context for SID 0x40, and a scan API. `docs/WIFI_BT_PLAN.md` sections 1, 2 and 5 (phases P3-P5) have the exact
   sequence and what ios-topaz (SM6225, patches 0113-0126) contributes; the estimate there is 3-4 weeks to a scan,
   and phase P3 (first TZ/hypervisor-mediated MSS action) is the riskiest step of the whole project (SoC resets on
   an unmatched SMMU stream or a bad XPU access). Nothing of P3 onwards has been written or run.
2. **iOS side.** wifid only starts when the ADT has a `wlan` or `marconi-wifi` node, and then talks to an
   IO80211Family (Skywalk-era) interface through Apple80211 ioctls. Our kernel has no IO80211Family (closed source,
   not loadable from the iPhone10,3 kernelcache: `docs/WIFI_KEXT_STUDY.md` 3.4) and no stand-in. Adding only the
   ADT node would start wifid with nothing to drive, and Control Center would still show Wi-Fi unavailable.
   An "Apple80211-lite" stand-in is estimated at 4-8 weeks after a working chip driver (`WIFI_KEXT_STUDY.md` 4.4).

Neither half is a signing or hardware-access problem: the modem firmware in the phone's `modem` partition is the
phone's own signed image and is loaded by the modem's MBA, not by us, and the registers are reachable. The blocker
is the size of the two missing drivers. **Next step:** phase P0/P1 of `WIFI_BT_PLAN.md` on xnu-11215 (`sweetwlan=1`
and `=3`, read-only probe and modem-partition inventory; 0104 already carries them), then P3 (MBA load, stop at
"MBA alive") as its own gated patch, with the user present for the first run.

### 2.4 Boot combo-0240b-bt0239 (GPU session's local kernel: 0237 + 0240 + 0238 + 0239, 2026-10-24)

[V] Transport up, `compat ... on`, bluetoothd connects 6 times; **no** `compat:` rewrite and no error status: the
controller answered every command it got. The first session ends after `0x0c31` (Set Controller To Host Flow
Control, ok) and the client disconnects: 0x0c5b was **never sent**. The "status=628" is the OI stack refusing it
itself: bluetoothd logged the Supported Commands mask, octet 18 = 0x83, bit 3 (Write Default Erroneous Data
Reporting) clear. The earlier [U] guess (controller answers 0x01) was wrong.

Fix, 0239 reworked (compile-checked with `tools/xnu-cc.py` on the run 40133752064 build tree): a small table
`bt_local_cmds` {opcode, mask octet, bit}; the kernel sets those bits in the Read Local Supported Commands reply
(0x1002) and answers the commands itself with Command Complete / success, without sending them to the WCN3990
(`SWEET BT: compat: opcode 0x0c5b answered by the kernel`). The unknown-command rewrite and the error-status log
stay, so the next missing command shows up in one boot either way.

### 2.5 Boot combo2-0240b-bt0239v2 (0237 + 0240 + 0238 + 0239 v2, 2026-10-24)

[V] `compat: supported commands octet 18 0x83 -> 0x8b`, `opcode 0x0c5b answered by the kernel`, and the whole
standard HCI init passes (0x0c5b, 0x0c7a, 0x080f, 0x0c16/18/1c/1e/26/2a/2c/3c all status 0). Next come Broadcom
vendor commands from bluetoothd's `Stack/vsc/bcm/bcm_vsc.c`, which the WCN3990 answers with Command Complete status
0x01: 0xfce9, 0xfce2 (x3), 0xfd48, 0xfd47; also LE 0x2007 (Read Advertising Channel Tx Power) status 0x0c (Command
Disallowed). The client disconnects right after the last 0xfce2. bluetoothd now **crashes** (SIGABRT, "Application
Triggered Fault", ~10 s after launch, crash reports in `.../osanalytics/DiagnosticReports/bluetoothd-*.ips`):
thread `com.apple.bluetooth.root`, Stack_Init (0x1001491c4) -> stack init (0x1001bf5e0) -> fatal handler -> abort.
launchd respawns it.

Fix, 0239 v3: `sweetbtcompat=2` (default) also turns 0x01 answers to vendor (OGF 0x3f) commands into success. The
reply then carries no return parameters; `_BCM_SubOpcodeChecker` (0x100035580, used for 0xfce9/0xfd23) returns true
on an empty reply, so at least those pass. [U] whether every one of them tolerates an empty reply.
Not done: the unified log of this boot (`sweetlog` returns nothing after the clock jump), so the stack's own
"restarting { reason=... }" line for this failure was not read; the crash report has no reason string.

### 2.6 Boot combo5-0243-bt0239v3 (develop through 0243 + 0238 + 0239 v3, 2026-10-24)

[V] 0xfce9, 0xfce2, 0xfd48 now answered as success (empty), bluetoothd still crashes (6 connects), a different
abort: `abort()` from the bcm_vsc.c assert helper (0x10018b54c) in `_BCM_CreateMultiAdvInstParser` (0x1001eb574,
bcm_vsc.c:827 "ByteStream_NumReadBytesAvail(*pBs) >= 1"): 0xfd48 is `_BCM_CreateMultipleAdvInstance` (OCF 0x148)
and its success reply must carry the instance byte. What the other vendor commands are (static, IDA):
0xfce2 = `_BCM_OlympicRSSIThreshold` (sub-opcoded writes, generic status-only parser 0x100085e74), 0xfce9 (and
0xfd23) checked by `_BCM_SubOpcodeChecker` (first reply byte = sub-opcode), 0xfd47 =
`_BCM_EnableExtendedDuplicateFilter` (generic parser).

Fix, 0239 v4 (compile-checked): a rewritten success carries 16 parameter bytes: the command's first parameter byte
(remembered per opcode on TX), then zeros. That satisfies the sub-opcode checker, gives 0xfd48 an instance byte and is
ignored by the generic parser. LE 0x2007 (Command Disallowed) is answered the same way (Tx power 0 dBm).

### 2.7 Boot combo6-0244-bt0239v4 (develop through 0244 + 0238 + 0239 v4, 2026-10-24): the stack starts

[V] No crash reports any more. Kernel: rewritten successes for 0xfce2, 0xfce9 (sub-opcodes 0 and 3), 0xfd48, 0xfd47,
0xfd4e, 0xfd1b; LE 0x2007 still Command Disallowed (its reply has a parameter byte, so the `len == 7` rule did not
apply; harmless). bluetoothd, run by hand while the launchd copy was paused with SIGSTOP (no launchctl on this
root; script in the session notes): `Stack did start`, `Power state change - {powerstate: 1}`, `Update Dynamic Store
with state On`, `Starting passive scan (300.00ms/30.00ms) with duplicate filter enabled`; it identifies the chip as
"BCM_4357" from its own table. About 20 s later: `BD_VSC_LE_META_ENA_FEATURES timedout waiting for controller`,
`Notifying BT Firmware Crashed`, `Bluetooth error - restarting { reason=3602 }`. 0xfce9 sub-opcode 1 (LE Meta
Enable Features, `_BCM_LEMetaEnableFeatures`, generic parser) is the one vendor command the WCN3990 does not
answer at all. launchd's copies live 15-60 s each for the same reason.

Fix, 0239 v5 (compile-checked): a command watchdog. A command sent to the controller with no Command Complete /
Status within 800 ms is answered by the kernel with success (first parameter byte + zeros) and logged
(`SWEET BT: compat: opcode ... not answered by the controller within 800 ms`).

### 2.8 Boot combo7 (0239 v5, 2026-10-24): correction to 2.7, sub-opcode byte

[V] The watchdog never fired: the controller answers every command, 0xfce9 sub-opcode 1 included (28 rewrites with
first byte 0x01). bluetoothd (hand run, 60 s) still: `Stack did start`, power state 1, then `BD_VSC_LE_META_ENA_FEATURES
timedout waiting for controller`, reason 3602. So 2.7's "the WCN3990 never answers it" was wrong. What times out is
bluetoothd's synchronous wait (0x100028dfc: 15 s semaphore signalled by the VSC completion 0x10003695c), and the
completion never runs because `_BCM_SubOpcodeChecker` matches 0xfce9/0xfd23 replies to their pending command by the
first reply byte = sub-opcode. 0239 took that byte from a small per-opcode table whose lookup returned the *first*
(oldest) 0xfce9 entry, e.g. 0x32 instead of 0x01, so the reply was never matched.

Fix, 0239 v6 (compile-checked): the sub-opcode byte comes from the command in flight (the watchdog's record of the
last transmitted command), and the table keeps one entry per opcode (newest wins).

### 2.9 Boot combo8 (0239 v6, 2026-10-24): LE scan parameters disallowed

[V] The v6 fix worked: `BD_VSC_LE_META_ENA_FEATURES` now completes (`fEnabledFeatures: 151027`), no timeout, no
watchdog. bluetoothd (hand run): `Stack did start`, power state 1, `Starting passive scan (300.00ms/30.00ms)`, a second
scan start after the vendor scan setup, then `Could not start LE scan (leScanParamsLPCoreCb): STATUS 712`, `Scan stopped
improperly with result 712 -- restart`, `restarting { reason=712 }`. Kernel: LE Set Scan Parameters (0x200b) answered
with status 0x0c (Command Disallowed) once per session, right before each disconnect: the spec forbids changing scan
parameters while scanning, which bluetoothd does (Broadcom firmware tolerates it). 712 = the stack's 700 + HCI status 0x0c.

Fix, 0239 v7 (compile-checked): Command Disallowed for LE 0x2006/0x2007/0x200a/0x200b/0x200c is answered as success,
return parameters kept (the running scan/advertising keeps its old parameters).

### 2.10 Boot combo9 (0239 v7, 2026-10-24): BLUETOOTH WORKS

[V] One client connect for the whole boot: bluetoothd (pid 253) stays up (> 2 min, checked several times), log
`Power state changed. PowerState:1 managerState:5` (PoweredOn), `Scan start`, `BLE advertiser activated`. Kernel:
0x200b/0x200c (28/55x) and 0x2007 (1x) Command Disallowed answered as success, vendor commands rewritten as before,
watchdog never fired. **User-checked on the phone: Settings -> Bluetooth shows nearby devices.**

### 2.11 Everything Bluetooth needs on iOS 18 (summary)

| Piece | Where |
|---|---|
| `/arm-io/bluetooth` ADT node (local-mac-address, transport-encoding 3, transport-speed 3000000) | `tools/adt-bluetooth.py` on the GPU ADT -> `beryllium-hi-3x-gpufwz-bt.adt` |
| Boot-args `sweetwlan=2 sweetbt=1 sweetbtfast=1 sweetbtibs=1 sweetwlandelay=30` | boot image cmdline (601 of 608 bytes with the current set) |
| WCN3990 firmware `crbtfw21.tlv` / `crnv21.bin` (linux-firmware) in `/usr/standalone/firmware/sweet/` | root: `RENEGADE_BT_FW=DIR` (root_tweaks18 `bluetooth()`); on this phone copied by hand |
| bluetoothd `BT_HCI_TRANSPORT=H4BC:POSIX:com.apple.uart.bluetooth,3000000`, BlueTool stub | root (already in renegade root, bt18) |
| Kernel transport, firmware download, IBS: 0104-0136 | xnu/patches-11215 |
| Keychain: AKS key wrap/unwrap | **0238** |
| HCI compat for Apple's Broadcom-assuming stack | **0239** (v7): 0x0c5b listed + answered locally; 0x01 Unknown Command -> success (+ sub-opcode/param byte and zero padding for vendor replies); LE Command Disallowed -> success; 800 ms command watchdog |

Open points: classic pairing/connections and audio not tested; the vendor features answered as "success" do
nothing (Apple's LE offloads, multi-advertising instances); `/dev/btwake` absent (logged, harmless); the 64-line
HCI trace budget (`sweetbtlog`) is too small to see a whole session.

### 2.12 "Connect" drops at once: Skywalk privileges (0250)

[V] Boot combo9, connecting a device from Settings: bluetoothd dies every time and then on every start (it reconnects
the device), 11 crashes `SIGSEGV KERN_INVALID_ADDRESS at 0x0` on queue `com.apple.bluetooth.media` in
`os_channel_get_fd` <- 0x1005395a4 (AudioSkywalkPipe start) <- 0x1003239e8 (audio device publish: "Device supports
Skywalk Path"). The audio pipe constructor (0x100539b10) registers a user-pipe nexus "com.apple.bluetooth.AudioPipe"
and opens a channel on it without checking errors; the kernel had logged `SK[5]: __nexus_register bluetoothd:
nxprov_create: 1` = EPERM: `PRIV_SKYWALK_REGISTER_USER_PIPE` is checked with priv_check_cred, and our Sandbox
stand-in (sweet_amfi.c) grants only PRIV_WORK_INTERVAL (its denial log is capped at 64 entries, so this one was never
printed).

Fix, xnu **0250** `sweet-sandbox-skywalk-privileges` (compile-checked, applies on the series): the Skywalk privileges
12000-12011 are granted to a process holding the matching `com.apple.private.skywalk.*` entitlement
(IOCurrentTaskHasEntitlement), as AMFI does. bluetoothd has register-user-pipe. [U] whether the audio path then works
end to end (A2DP over the WCN3990, the audio HAL side of the channel).
