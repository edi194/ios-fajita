# iOS 26 port: first image (branch `ios26`)

Why iOS 26 and what was measured: `docs/IOS26_FEASIBILITY.md`. Kernel: `docs/XNU12377_MIGRATION.md`. The Renegade pipeline
(PAC rewrite, root build) is the iOS 18 one (`docs/IOS18_PORT.md`, `tools/renegade/README.md`) with a target profile.

## 1. What was built (2026-10-24, nothing flashed or booted)

| Piece | File (git-ignored) | How |
| --- | --- | --- |
| Kernel | `research/ios26/kernel/kernel.development.sweet` (xnu-12377.121.6, sha256 `d1afbfd8...`) | `USE_KDK=1 tools/xnu-local-build.sh 26.5` |
| ADT, iPhone 11 | `enxerto/out/beryllium-n104-2x.adt` (N104AP / iPhone12,1, 414x896 @2x = 828x1792, sRGB) | `tools/mkadt.py OUT --board beryllium --highmem --display-scale 2 --points 414x896 --identity n104ap` (needs `research/ios26/n104ap.adt`) |
| Root | `research/ios26/ios26-root-full.simg` (17.9 GB sparse, iOS **26.6.2 23G90**, iPhone12,1) | `tools/renegade/fetch-root.sh`, then `RENEGADE_MIN_FREE_GB=10 tools/renegade/mkroot-full.sh --delete-sources --size 24g` |
| Boot image | `research/ios26/enxerto-boot-ios26full.img` | `tools/renegade/mkboot-full.sh` (iOS 18 boot-args, `rd=ufsroot0`, `sweetarm64e=1`) |

**Why 26.6.2, not 26.7.1:** 26.7/26.7.1 exist only as OTAs, where the root is `payloadv2` Apple Archives instead of a disk
image; Renegade's copy stage reads IPSW disk images (and their owners). An OTA path is future work; the kernel is the same.

Root verify stage, all OK: owners (3000-path spot check), no HFS compression, `codesign -v` sample, identity/CS flags of all
2986 re-signed Mach-Os, every boot-task program present, chained fixups of 3792 Mach-Os, no PAC words left, shared cache signatures.
Skipped features (prebuilt tools not in this worktree; `renegade fetch-tools` or `tools/sweetnet/build.sh`): app registration
(`sweetuicache`), default wallpaper, PosterBoard `sweetfp.dylib`, `sweetprefs`, Chlorophyll payload (`research/bgmtl`). In:
dropbear SSH (key-only), USB Ethernet 192.168.7.2, `sweetnetcfg`, `sweetreboot`, jailbreak userland.

**Kernel update (2026-10-25):** develop's iOS 18 work (0233-0250: RTC wall clock, GPU page-table pool, scan-out copy/blit, panel
power and backlight service (`sweetfb_blsvc` stays OFF by default), charger, Bluetooth AKS/HCI/Skywalk) is in `xnu/patches-12377`
(`docs/XNU12377_MIGRATION.md`). The `kernel.development.sweet` above predates it; take the CI kernel and rebuild the boot image with
`tools/renegade/mkboot-full.sh` before the first boot.
**Chlorophyll on 26:** `gpu/metal` branch `ios26`, `IOS26.md`; the image above has no Chlorophyll payload (CPU renderer).

## 2. Renegade changes

* `tools/renegade/targets.py`: one profile per target (device, version, build, dmg names, work dir, ADT target-type, default ADT),
  `RENEGADE_TARGET=ios26` (default) or `ios18`. `fetch-root.sh`, `mkroot-full.py`, `root_tweaks18.py` (build/version,
  event-timing copy only when the ADT claims another device) and `mkboot-full.sh` read it.
* `RENEGADE_MIN_FREE_GB` (default 5): the copy stage refuses to start a volume that would leave less than this free.
* `verify` stage: the content checks (fixup walk, PAC scan, cache) run on a read-only noowners remount; with owners on, root-only
  files (`/private/etc/master.passwd`) were unreadable and the newer fixup walk stopped.
* Disk on the Mac: about 21.6 GB free is needed for the OS copy with a 10 GB floor (OS volume 11.6 GiB apparent).

## 3. First boot (needs the user's OK; every flash goes through the Bergamota queue)

**What the flash replaces.** iOS 26 goes into `userdata`, where the iOS 18.7.8 install lives now (flashed 2026-10-20, then used
daily: Wi-Fi/BT pairings, settings, SSH host keys, posters). The iOS 18 root *image* on the Mac was deleted for disk space, so after
the flash iOS 18 only comes back by rebuilding it (`RENEGADE_TARGET=ios18 tools/renegade/fetch-root.sh`, then `mkroot-full.sh`, about
22 GB free during the build) and flashing it again. Its on-phone state is lost unless backed up first.

**Backup before the flash.**

A raw image of `userdata` is about 18 GB. With the Mac's 10 GB floor that needs about 28 GB free; on 2026-10-24 there are 13 GB.
So:

* **(a) State backup, fits now.** Boot iOS 18 (current kernel and boot image). Over SSH, tar the state that a rebuild cannot
  recreate into `research/ios18-state/` on the Mac (git-ignored). A few hundred MB:
  * `/private/var` without `Caches`, `tmp`, `log`, `db/diagnostics`, `db/uuidtext`, `mobile/Library/Caches`
  * `/private/etc/ssh` or dropbear host keys
  * `/private/var/preferences`
  * `/private/var/containers/Shared/SystemGroup/*/Library/Preferences`

  Restoring iOS 18 later means a Renegade rebuild, flashing it, then untarring this.
* **(b) Full image.** Free about 28 GB, or plug in an external disk, and stream `dd` of the userdata block device through `zstd`
  over SSH from iOS 18. Mostly-empty HFS free space compresses well, so expect 8-12 GB. It restores byte for byte through the
  Bergamota queue (`flash-userdata`).

Neither is done yet; the user picks one before the flash is queued.

1. Flash `research/ios26/ios26-root-full.simg` to `userdata` and `fastboot boot` `research/ios26/enxerto-boot-ios26full.img`,
   both via `apps/Bergamota/scripts/bergamota` (never modem/persist/bluetooth/dsp).
2. Checked against orhunnx/beyond2lte-ios (iOS 26 on an Exynos S10+, same rel/xnu-12377 base; read as reference only):
   * **Touch / digitizer events.** Their build 0083 crashed backboardd in the `DigitizerGenerationCount` getter (0xb001b), which
     reads data+0x90 of a 160-byte native digitizer record, while they sent a 104-byte one.
     * Our in-kernel `IOHIDEvent` writes the open-source 104-byte layout with `IOFixed` coordinates.
     * Apple's published IOHIDFamily sources have the same `IOHIDEventData.h` in 2222.80.22 (macOS 15) and 2238.120.5 (macOS 26.5).
     * The userland check (`IOHIDEventCreateData` / `IOHIDEventCreateWithData` on the macOS 27 host) still serializes a digitizer
       child as 0x68 = 104 bytes in `IOFixed`. It parses such bytes into its own in-memory record, and x, y, index and generation
       count read back fine.

     So the wire format we send is still the accepted one; the 160-byte record is userland's in-memory form. Not verified on iOS 26
     itself: watch backboardd for a fault in the digitizer getters on the first boot.
     **Superseded by section 4:** that holds for `IOHIDEventCreateData`, but events queued by a kernel service are read in the
     160-byte layout with one queue element per event.
   * **Identity.** iPhone12,1 is a real product (no iPod-class fallback like their unknown model). `research/ios26/n104ap.adt` comes
     from a real N104 and keeps its buttons node; `/buttons/home-button-type` is not checked yet.
   * **Still to check against theirs:**
     * the ExtensionKit/DataMigrator retry storm (their 0052/0083 `extensions.plist` admission);
     * the sandbox extension token/handle table size (they hit ENOSPC at 256 tokens: Photos/assetsd TCC failures);
     * a MobileGestalt Wi-Fi MAC;
     * development keystore and lock-state behaviour.
3. Expected first problems (iOS 18 -> 26 userland drift): IOSurface / IOMobileFramebuffer user-client layouts (0157/0159 style),
   MobileGestalt answers for iPhone12,1, new launchd boot tasks, AKS selectors. Logs: `tools/sweet-log-pull.sh`, SSH once USB
   networking is up.

## 4. Milestone: touch works on iOS 26 (2026-10-25, boot 27)

Boot 27 (ios26 at 9fdfb1c): the lock screen takes taps and swipe-up. Before it, iOS 26 booted to SpringBoard and the lock screen,
the kernel read NT36672A frames and backboardd's event system took our events, but nothing ever reached a window.

**Root cause: the kernel-to-user event format changed.** iOS 26 has two IOHIDEvent serializations:

| path | iOS 26 format |
|---|---|
| `IOHIDEventCreateData` / `CreateWithData` (user space) | legacy: one `IOHIDSystemQueueElement`, then 104-byte `IOFixed` records packed |
| kernel service queue (`IOHIDEventServiceQueue` -> `getLength`/`readBytes`) | 160-byte records (position, pressure, twist, orientation as doubles; generation/will/did at 0x90), **one queue element per event**: parent, then each child with `depth` = 1, parent `eventCount` = total (IOHIDFamily 2238 `withBytes`/`readBytes`) |

Our xnu-12377 `IOHIDEvent` wrote the older queue format: one element, legacy records, children packed.

**Patches** (xnu/patches-12377):

| patch | what |
|---|---|
| 1010 | NT36672A reset pulse before reading params (`sweettouchnvtrst=1`); fixed controller frames and IRQs |
| 1013 | `sweethidlog=1` dumps the first touch events' `createBytes` |
| 1014 | collection `childEventMask` = OR of the fingers' masks (as `IOHIDEventAppendEvent`); harmless, backboardd doesn't read it |
| 1015 | touch events carry `IsBuiltIn` (backboardd forwards it to SpringBoard) |
| 1016 | `sweetdenypath=SUFFIX` makes matching path lookups fail (recovery switch for a crash-looping debug dylib) |
| **1017** | queued digitizer records in the 160-byte double layout; `createBytes` stays legacy |
| **1018** | one `IOHIDSystemQueueElement` per child (depth 1, total in the parent's `eventCount`) |

1017 + 1018 are the fix. 1011/1012 (test: `IsDisplayIntegrated` on events, `Authenticated` service property) are still in; whether
they are needed is not tested.

**How it was found (tools kept in the scratchpad, on the phone in `/var/root`):**
* `logstream`: live unified log on the phone through LoggingSupport's `OSLogEventLiveStream` (iOS has no `log`): formatted
  messages in milliseconds instead of copying `/var/db/diagnostics` to the Mac. `logstream PROC[,PROC] [FILTER]`, `-` = all.
* `hidwire2`/`hidwire3`/`hidparse`/`hidupd`: user-space IOHIDEvent serialization and `BKSHIDEventContainsUpdates` probes. They
  showed the `CreateData` format, which misled the first revert of 1013 (it is not the queue format).
* `bbhook2.dylib`: ObjC tracer weakly linked into a re-signed copy of backboardd (`LC_LOAD_WEAK_DYLIB`, original entitlements),
  forwarding every method of the touch classes through `forwardInvocation:` and logging to `/private/var/mobile/tmp/bbhook.log`
  (the sandbox's writable temp dir). It showed `processEvent` -> `_handleDirectTouchEvent` running, the event backboardd actually
  got (fields shifted, then a hand with no `ChildEvents`), and then the full fix. Lessons:
  * restarting backboardd breaks touch delivery until reboot, and 3-4 restarts in a few minutes make launchd shut the system down
    (on our kernel that ends in the "initproc exited" panic), so the hook is armed from boot (`/usr/libexec/bbhook2.arm`);
  * never hook a selector in both a class and its subclass (an override calling super recursed: stack overflow at boot);
  * recovery: boot with `sweetdenypath=/var/root/bbhook2.dylib` (weak load -> backboardd starts clean), then restore over SSH.
  After boot 27 the arm file is removed and the original backboardd is back on disk (`/usr/libexec/backboardd.orig` kept).

**Next:** drop 1011/1012 if not needed and make `sweettouchnvtrst=1` the default; Wi-Fi (sweet80211, paused); Metal/Chlorophyll.
