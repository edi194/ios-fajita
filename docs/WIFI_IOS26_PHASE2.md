# Wi-Fi on iOS 26, phase 2: a long-lived WLAN service behind the iOS interface

Plan, written 2026-10-26 after boot 49 (first real scan: 12 networks). No code yet. Patch numbers continue at
**1124** in `xnu/patches-12377`. Background: `docs/WIFI_IOS26.md` (sections 1-4: the iOS side, 5: the chip side).

## 1. Where things stand

Two halves exist, but they are not connected:

| Half | What works | Where |
|------|------------|-------|
| **iOS side** (W1-W3, boots 23-29) | `en0` (Ethernet, Wi-Fi subfamily), the IOKit entries `wifid` matches, the `SIOCGA80211/SIOCSA80211` ioctl dispatcher, kernel events. wifid powers the "radio", scans, and **Settings › Wi-Fi lists the synthetic network "Bergamota-test"** (`sweet80211=2`). Join fails by design (ASSOCIATE -> ENXIO). | `bsd/dev/sweet_80211.c` (1100-1103), `iokit/Kernel/arm/SweetNetwork.cpp` |
| **Chip side** (W4+, boots 30-49) | modem (MBA, MPSS), rmtfs/TFTP/pd-mapper, WLFW to FW READY, SMMU + copy engines, HTC + WMI, HTT setup, **a passive scan that reports real beacons** (12 networks on boot 49). | `bsd/dev/beryllium_wlan.c` (1104-1123) |

The chip side runs as a **120 s test stage**: about 60 s after boot it brings everything up, scans once, then
switches Wi-Fi off, stops the modem and tears down. Phase 2 makes it a service that stays up and feeds the iOS
side, so that Settings shows real networks and, later, joins one.

## 2. Target architecture

```
 Settings / wifid / configd                     (user space, unchanged Apple code)
        |  SIOCGA80211 / SIOCSA80211, KEV_IEEE80211 events, en0 packets
 sweet_80211.c  (iOS side)  ---- backend ops ---->  beryllium_wlan.c  (WLAN service)
   power / scan / scan results / join / leave        modem + IPC services (rmtfs, TFTP, pd-mapper)
   tx (802.3 mbuf) / rx -> ifnet_input               WLFW, CE, HTC, WMI, HTT
   link and scan events -> kev_post_msg               one service thread, state machine
```

* **Backend ops** (a small struct of function pointers that `sweet_80211.c` calls, replacing the null and fake
  backends): `power(on)`, `scan(params)`, `scan_result(i)`, `join(bss, security)`, `leave()`, `tx(mbuf)`, plus
  callbacks the service calls back: `scan_done`, `link(up/down)`, `rx(mbuf)`. The fake backend stays for tests.
* **One service thread** owns the chip (as the test stage does today). It no longer has a hold time or a
  teardown: it runs until shutdown. Requests from `sweet_80211.c` (ioctl context) are queued to it; replies
  and events come back through the callbacks. Nothing in the ioctl path touches hardware directly.
* **Polling, then interrupts.** Today everything is polled every 1 ms, which is fine for 120 s but burns a
  core forever. The service polls fast only while something is in flight (a WMI command, a scan, traffic) and
  backs off to ~20-50 ms when idle; interrupts (GLINK/SMP2P doorbell from the modem, CE interrupts SPI 414-425)
  replace polling in a later step.
* **Boot-args.** The field is full (603-606 of 607 bytes). Phase 2 folds the Wi-Fi gates into one
  (`sweetwlan=5` = the whole service: MSS, MPSS, rmtfs, TFTP, pd-mapper, WLFW, CE, WMI, HTT, RF clock), which
  frees about 100 bytes. The step-by-step gates stay available under `sweetwlan=4`.

## 3. Milestones (each: patch(es), harness test, independent review, one boot with the user's OK)

### WL1. Long-lived service (1124)
`sweetwlan=5`: the boot 49 sequence without the hold and without the teardown; Wi-Fi left on (mode mission)
after WMI READY and the HTT setup; the service thread keeps rmtfs/TFTP/QRTR/GLINK alive and idles with adaptive
polling. A status line every 60 s (scan count, WMI/HTT counters, CPU use of the thread) and on demand through a
sysctl. Folded boot-args.
**Boot test:** phone stays up for 10+ minutes with the service running, no panic, modem still answering (a
periodic WMI ECHO round trip), the thread's CPU share in `top` is small.

### WL2. Real networks in Settings (1125)
`sweet_80211.c` gets the WCN3990 backend (`sweet80211=3`):
* POWER on/off -> keep the firmware up, mark the radio on/off (WLAN_MODE off/on later, once on/off is proven
  safe to repeat).
* SCAN_REQ -> WMI START_SCAN on the requested channels (default: all of the regdomain's), then SCAN_DONE
  event when the firmware reports COMPLETED.
* SCAN_RESULT -> the cached BSS list built from MGMT_RX: BSSID, channel, RSSI/noise, beacon interval,
  capability, supported rates, SSID and **the full IE list** (so iOS sees WPA2/RSN, WPS, 802.11n/ac).
  The `apple80211_scan_result` layout is the one boot 29 proved with the fake network.
* COUNTRY_CODE set from wifid -> PDEV_SET_REGDOMAIN and SCAN_CHAN_LIST for that country (today: fixed CN
  from the board's EEPROM value).
**Boot test (user):** Settings › Wi-Fi lists the real nearby networks with signal bars and lock icons, and
refreshes them. Joining still fails cleanly.

### WL3. Join an open network, IP traffic (merged into WL4: 1126-1127, see docs/WIFI_IOS26.md 6.3)
The largest step. What ath10k + mac80211 do for a station, done in the service:
* **Host MLME:** authentication (open system) and association request frames built in the kernel, sent with
  WMI management TX; responses taken from MGMT_RX; timeouts and retries.
* **Firmware state:** VDEV_START on the AP's channel, PEER_CREATE (the AP), PEER_ASSOC (rates, HT/VHT caps
  from the association response), VDEV_UP (AID, BSSID).
* **Data path:** HTT TX (MSDU descriptors in the frag bank, CE4 sends, TX completions), HTT RX (in-order
  indications, buffer recycling: the RX ring is fill-once today), 802.3 <-> 802.11/native-wifi conversion,
  `ifnet_input` / `if_output` on `en0`.
* **iOS side:** ASSOCIATE handled, SSID/BSSID/CHANNEL/RSSI/STATE answered while associated, link events
  (ASSOC_DONE, LINK_CHANGED) so configd runs DHCP.
**Boot test (user):** join an **open test network** (for example the user's own phone hotspot without a
password), get an IP address, `ping` the gateway over SSH. **This step transmits** (authentication,
association, data), see decision D1.

### WL4. WPA2-Personal (1129-1130)
In classic Apple80211 the key arrives with ASSOCIATE (`apple80211_assoc_data.ad_key`) and the 4-way handshake
is the driver's job (with Broadcom it runs in the firmware); **to be confirmed for iOS 26** by logging the
ASSOCIATE request wifid sends in WL3 (its layout, and whether it carries the PMK or the passphrase). The WCN3990
firmware expects the host to run the handshake (ath10k relies on wpa_supplicant). So a **minimal in-kernel 4-way handshake for WPA2-PSK (CCMP)**: EAPOL-Key frames 1-4 over the
data path, PTK derivation (PRF-SHA1), MIC (HMAC-SHA1), GTK unwrap (AES key wrap), using xnu's corecrypto, then
WMI VDEV_INSTALL_KEY (pairwise + group). Group-key rekeys handled. WPA3/SAE and enterprise are out of scope.
**Boot test (user):** join the user's home WPA2 network from Settings, browse in Safari.

### WL5. Living with it (1131+)
Interrupts instead of polling; power save (firmware PS when idle, Wi-Fi off from Control Center ->
WLAN_MODE off and back on); modem / WLAN PD crash recovery (SSR: SMP2P fatal bit and PDR notifications, then
a clean restart of the service); background scans and roaming events; disconnect / reconnect; 5 GHz DFS rules;
suspend/resume once the rest of iOS sleeps.

## 4. Decisions for the user

* **D1. Transmitting.** Every boot so far only listened. From WL3 on, the phone transmits (auth/assoc, data).
  Active scanning (probe requests, faster and needed for hidden networks) is a separate yes/no; the plan uses
  passive scans until the user says otherwise.
* **D2. Where the WPA2 handshake runs.** In the kernel (recommended: iOS gives the PMK to the driver, so
  nothing in user space needs to change), or a user-space helper (wpa_supplicant-like) talking to the kernel.
* **D3. Test networks.** WL3 needs an open network the user controls (phone hotspot or a spare router). WL4
  uses the user's own WPA2 network; its passphrase never leaves the phone (wifid derives the PMK).
* **D4. Merging and pushing.** Every milestone is fast-forwarded into develop locally as now; pushing stays
  the user's call.

## 5. Risks

* **CPU and battery** while the service polls (mitigated in WL1, solved in WL5).
* **Modem stability over hours**: so far it ran 2 minutes at a time. EFS writes stay in RAM (rmtfs read-only
  policy), so a long-lived modem accumulates them there; they are lost at reboot by design.
* **Firmware asserts** on wrong WMI/HTT sequences in the join path (ath10k comments list several: empty HT rate
  sets, keepalive intervals over 0xffff). Each step is reviewed against ath10k before it boots.
* **DMA:** all Wi-Fi DMA stays in the 12 MiB pool at 0xe0100000 (outside xnu RAM, identity-mapped). The data
  path needs more buffers; the pool grows within the same free region (nothing is reserved between 0x9f800000
  and 0xf6301000), never into xnu RAM.
* **Unchanged rules:** modem/persist/bluetooth/dsp are never written; firmware stays out of git; every flash
  and boot goes through the Bergamota queue with the user's OK; no raw-device reads on a running phone.

## 6. Rough size

WL1 1-2 days, WL2 2-3 days, WL3 1-2 weeks, WL4 3-5 days, WL5 open-ended. WL1 + WL2 give a visible result
(real networks in Settings) without transmitting anything.
