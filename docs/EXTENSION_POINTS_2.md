# LaunchServices extension points, "app bundle unit" and the persisted LS database

Tags: [V] verified (disassembly, log line, file inspection), [U] unverified (inference).
Addresses are dyld shared cache VAs (iPhone X 16.7.16 20H392), image CoreServices unless noted.
Logs: `logs/boot6/unified.jsonl` (9 boots; file order = chronological: 6E570A, B0281F, 5E359B, 811BD4, E51EC3,
9FD876, CA50DE, 24C6CC, A3D22D). "A3D22D" = newest boot, lsd pid 100, uptime 04:06. Root inspected read-only
through the existing mount of `research/ipsw-x/ios16-root-20H392-b2.img` (not detached, not mine).

## TL;DR

1. "Failed to fetch app bundle unit: 0 for extension point" is a **benign, hard-wired log**. `_LSDatabaseClean`
   registers every catalog extension point with bundle unit 0 (there is no declaring app bundle), so
   `_LSBundleGet(db, 0)` is always NULL, the error is logged, and registration continues and succeeds. It is not
   a missing framework record, path, persona or AMFI problem. [V]
2. The csstore is **not** "never written". It is written (timer, 1 s coalesced) and, from boot 811BD4 on, it is
   **loaded** by lsd. The "csstore does not exist" error appears only in the three oldest boots. [V]
3. That is the actual reason pkd/PosterBoard are still empty: the persisted LS DB was seeded in boot 5E359B while
   the extension catalog was unreadable (AMFI), when the seeder **dropped all 418 appex bundles** ("Ignoring app
   extension ... due to validation issue(s)"). Because the stored DB is flagged seeded+complete, lsd never re-seeds
   (no `LSDatabaseBuilder: Seeding database` in any boot after 5E359B), so patch 0099 only re-registers the
   extension point *definitions* each start; plugin (appex) records stay absent. pkd: `Candidate plugin count from
   LaunchServices: 0`; PosterBoard: `Extensions updated; Received 0 extensions`. [V for facts, U for the exact
   stored-header state]
4. "Extension point (null) not in the binding map" = the identifier string is not yet interned in the DB string
   table, so the lookup key is unit 0 and `%@` prints (null). Benign, two per registration (266 = 2 x 133). [V]
5. **Fix**: make lsd rebuild the LS DB: reflash a fresh userdata (b2.img has an empty `Library/Caches` in the LS
   container, verified) or delete the csstore in the live root. No kernel/rootfs-layout change is needed.
   launchd's `__mac_syscall("AMFI", 0x5a)` does not matter here. [V/U, details in Q4]

## Q1. "Failed to fetch app bundle unit: N for extension point: X"

### Where it is logged [V]
- Format string `"Failed to fetch app bundle unit: %llu for extension point: %@"` @0x181d5ce93, used in
  `__LSRegisterExtensionPoint.cold.1` (xref 0x181d231e0), called from `_LSRegisterExtensionPoint` (0x181ce1134).
- In `_LSRegisterExtensionPoint(db, unit=w1, identifier, platform, SDK dict, declaringURL)`:
  1. logs `"Registering extension point: %@ platform: %u declaring framework: %@ SDK: %@"` (0x181ce1224) [matches the
     130x lines];
  2. does `_LSExtensionPointAdd(db, record)` (0x181ce1688), i.e. the record is already stored;
  3. `_LSBundleGet(db, unit)` (0x181ce169c). If it returns NULL (cbz at 0x181ce16b0) it goes to 0x181ce16e8, logs
     the error (log type 0x10 = Error) via cold.1 (0x181ce1b0c..1b18) and falls through to 0x181ce1708/0x181ce1710
     with `w28 = 0` (success). If it returns a bundle it appends the extension point id to the bundle's list
     (`_CSArrayAppendValue`, or `_CSStoreWriteToUnit` at offset 0x1d0 of the bundle record).
  So "app bundle unit" = the LS CSStore unit id of a *bundle record* that declares the extension point; the log is
  emitted whenever that record does not exist.
- Why N is always 0: `_LSDatabaseClean` (0x181c8802c) enumerates `+[EXEnumerator extensionPointDefinitionEnumerator]`
  (xref "Registering extension points" @0x181d56915 / "Done reregistering extension points" @0x181d569d4) and for each
  point calls `_LSRegisterFrameworkExtensionPointIfNecessary(db, 0, id, platform, SDK, url)` (0x181c88378, `mov w1,#0`).
  `_LSRegisterFrameworkExtensionPointIfNecessary` (0x181ce1c50) returns immediately (-10814) if unit != 0 or url == NULL,
  checks `_LSExtensionPointFindWithIdentifier` for an existing, same-or-newer-version entry, and otherwise calls
  `_LSRegisterExtensionPoint(db, 0, ...)` (0x181ce1d70/0x181ce1d84). Unit is the constant 0 -> `_LSBundleGet(db,0)` is
  NULL -> message. Log: A3D22D has 133 `Registering extension point` and 133 `Failed to fetch app bundle unit: 0`,
  strictly alternating, followed by `Done reregistering extension points`; the older boots show 6 + 6 (only the 6
  `.appexpt` points, because the signed catalog was unreadable). [V]
- Benign consequence: the extension point record exists (`_LSExtensionPointAdd` ran) but is not linked to a declaring
  bundle record. Anything that looks the point up by identifier (pkd's "extension point record", `_LSExtensionPointFindWith*`)
  still finds it. [V for code path; U that a real device prints the same 130 lines, since the code path is
  unconditional I expect so.]

### How framework / app bundle records are normally registered (seeding) [V from logs + code]
- On first start (no store) lsd runs `-[LSDatabaseBuilder createAndSeedLocalDatabase:]` (0x181c8df3c): it calls
  `_LSDatabaseCreateFromPersistentStore`; if the DB `isSeeded` AND `isSeedingComplete` it only commits and returns;
  otherwise it logs `LSDatabaseBuilder: Seeding database with UID: 501, EUID 501` (@0x181d57081), posts
  `com.apple.LaunchServices.DatabaseSeedingStart`, sets seeded, and seeds asynchronously (then
  `DatabaseSeedingComplete`, `setSeedingComplete:`). Also `-[_LSDatabase cryptexContentChanged]` ->
  `_LSServer_LSEnumerateAndRegisterAllCryptexContent`.
- The seed itself is MobileInstallation's `MILaunchServicesDatabaseGatherer` running **inside lsd** (thread
  "16AFEF000" in boot 5E359B). Its scanner logs, in order (boot 5E359B, 01:21.625-01:21.827):
  `_scanAppsDirectory: Scanned 140 apps in /Applications`, `17 in /System/Library/CoreServices`, `32 in
  /System/Library/AppPlaceholders`, `_scanFrameworkDirectory: Scanned 32 items in /System/Library/Frameworks`,
  `152 items in /System/Library/PrivateFrameworks`, then the cryptex dirs (`Scanned 0 apps in
  /private/preboot/Cryptexes/App`, `.../Cryptexes/OS/System/Library/PrivateFrameworks`, `.../Frameworks`).
  So frameworks ARE scanned from `/System/Library/...` (no path mismatch); the cryptex directories are scanned
  separately and are 0 apps by design.
- Extension point definitions come from the EXEnumerator (signed catalog + `.appexpt`), at DB creation
  (`_LSDatabaseClean`, i.e. every lsd start), **before** apps/frameworks are seeded. Ordering does not matter because
  they never use a bundle unit (see above).
- Appex bundles are the part that depends on the catalog: `-[MIPluginKitBundle overlaidInfoPlistWithError:]` ->
  `MICopyExtensionCacheEntryWithPlatform` (previous doc). If the extension point is unknown the gatherer logs
  `Ignoring app extension at <path> due to validation issue(s)` and **does not register the appex**.

### Why it "fails for us": it does not; the observed breakage is the stale DB [V/U]
Checked and ruled out: path mismatch (frameworks scanned under /System, cryptex dirs scanned and empty), persona
(`personaid = 200 SYSTEM_PROXY`, container queries all `success`), signature/AMFI (no AMFI call inside
`_LSRegisterExtensionPoint`/`_LSBundleGet`; no second AMFI message in lsd after the first catalog read in A3D22D;
A3D22D has no `amfi_interface_query_bootarg_state` error at all), ordering (see above).

## Q2. The csstore

- Store path (from the log's `NSFilePath`, boots 6E570A/B0281F/5E359B): 
  `/private/var/mobile/Containers/Data/InternalDaemon/3ED48A87-B795-429E-9BCB-E3502EA1A6EC/Library/Caches/com.apple.LaunchServices-4035-v2.csstore`
  (format `"%s-%03llu-v2.csstore"` @0x181d3efbc with prefix com.apple.LaunchServices, schema 4035). Recovery files in the
  same dir: `com.apple.LaunchServices.syncInterrupted` / `.error`. The directory exists in the image and is empty and
  writable-by-design (b2.img: `InternalDaemon/3ED48A87-.../Library/{Caches,Preferences}`, empty; the root IS the
  userdata partition, so the live copy lives on the phone). [V]
- Save mechanics [V]: `_LSArmSaveTimer*` -> `_LSArmSaveTimerWithTimeout` (0x181c8ac18; server only, not in a sync
  bubble) coalesces a dispatch after `-[_LSDefaults databaseSaveInterval]` (0x181c96130 = `fmov d0,#1.0`, 1 s). Its block
  (0x181c8cde4) posts the Darwin `ApplicationsChanged` etc. notifications, `_LSDatabaseCommit`, `_CSStoreValidate`,
  `_CSStoreWriteToURL` (0x181c8d3fc), `_LSDatabaseSentinelFlush`, then logs `_LSSessionSave: saved database for
  session %@`; failures log `Failed to save database to %@: %@` / `error saving database for session`. It is therefore
  timer based (any DB modification), not at clean shutdown, and not gated on seeding completing.
- Evidence it IS written and read back [V]:
  - `_LSSessionSave: saved database for session` x2 in boot 5E359B (01:21.892 and 01:21.950), right after the seed
    scan finished (01:21.827). No `Failed to save` / `error saving` in any boot.
  - `_CSStoreCreateWithURL failed ... no such file` occurs exactly 3 times in the whole 8.9 GB file: boots 6E570A,
    B0281F, 5E359B (the three oldest). None in the six later boots, incl. A3D22D. In those boots the first
    `_LSDatabaseCreateFromPersistentStoreIgnoringRecoveryFile` (0x181c87458) succeeds (a failure would log
    `_LSCreateStoreWithFileContents Failed`).
  - A3D22D: `Registering CoreTypes bundle` -> `Registering extension points` take 140 us (vs ~230 ms +
    `Built bundle record for app` in 6E570A when the DB is empty), no `LSDatabaseBuilder: Seeding`, no
    `MIFilesystemScanner`/gatherer lines at all; SpringBoard knows `com.apple.PosterBoard` as an SBApplication.
  - The first two boots with the missing store (6E570A, B0281F) end ~14 s after lsd start with the seed still running
    (per-app `begin inspect System` every 100 ms) so no save line is in the log window [U].
- So "rebuilt from scratch every boot" is true only for the first three boots; the premise does not hold for the
  boot A3D22D being analysed. [V]
- Why a persisted DB is reused: `-[_LSDatabase isSeeded]` (0x181c012f4) compares the header's seeded system version /
  build version / model code with the running system (`GetCurrentBuildVersion`, `GetCurrentModelCode`,
  `_LSGetCurrentSystemVersion`); `-[_LSDatabase isSeedingComplete]` (0x181c15cb4) tests header flag bit 1
  (`setSeedingComplete:` 0x181c86a20). Same OS build, same device => reuse. [V code; U that the stored header is
  "complete" - inferred from the absence of re-seeding]

## Q3. "Extension point (null) not in the binding map, scanning all extension points" [V]
- Format @0x181d59541, logged in `_LSExtensionPointFindWithStringID` (0x181bfdf74, log call 0x181bfe094). It first walks the
  DB binding map (`_LSDatabaseEnumeratingBindingMap`) for the string unit; if no entry (state +0x18 == 0) it logs and
  falls back to `_CSStoreEnumerateUnits` over all extension point units.
- `%@` is `_CSStringCopyCFString(store, stringUnit)` (0x181bfe058). The string unit comes from
  `_LSExtensionPointFindWithIdentifier` (0x181c046b4) which calls `_LSDatabaseGetStringForCFString(db, id, create=0)`
  (0x181c046ec): when the identifier string is not (yet) in the DB's string table it returns unit 0, which prints
  `(null)`. It therefore means "this identifier has not been registered in this DB yet"; harmless. It fires twice per
  new registration (lookup in `_LSRegisterFrameworkExtensionPointIfNecessary` + inside the register path):
  266 = 2 x 133 in A3D22D, 12 = 2 x 6 in the old boots. All 133 were "(null)" in A3D22D, i.e. the stored DB has no
  extension point strings at all (so extension points are rebuilt every start, consistent with "re-registering";
  [U] whether the load path drops them or the store was saved before they existed).

## Q4. Fix proposal

Primary (no code): **force a LaunchServices re-seed now that the catalog is readable.**
- Evidence it is needed: A3D22D loads a persisted DB seeded in boot 5E359B where 418 appexes were ignored
  (`Ignoring app extension` x418, `Failed to fetch extension cache entry` x414, 190 `Registered bundle status`)
  and where only the 6 `.appexpt` points existed; lsd now never seeds again, pkd count 0, PosterBoard 0 extensions,
  and its crash (`NSInvalidArgumentException ... initWithObjects:forKeys:count: attempt to insert nil object from
  objects[1]`, PosterBoard pid 234, 04:08.28; preceded by `_stateLock_setupSwitcherConfigurationForFirstTime`
  failure) follows from zero extensions [U that nothing else is missing].
- Option A (cleanest): reflash userdata with a fresh image (b2.img/`mkiosroot-macos.sh` output has an empty LS
  `Caches`), boot with kernel 0099. lsd will log `_CSStoreCreateWithURL failed`, `LSDatabaseBuilder: Seeding database`
  and the gatherer will register appexes against the working catalog.
- Option B (no reflash): delete on the phone
  `/private/var/mobile/Containers/Data/InternalDaemon/3ED48A87-B795-429E-9BCB-E3502EA1A6EC/Library/Caches/com.apple.LaunchServices*`
  (store, `.csstore` writer logs, `*.error`/`*.syncInterrupted`) and reboot.
- Make it repeatable in `tools/sweet-root-tweaks.py` (for roots that were already booted), idempotent, e.g. in `main()`
  after `containers(root)`:

  ```python
  for p in glob.glob(os.path.join(root, 'private/var/mobile/Containers/Data/InternalDaemon/*/Library/Caches/'
                                       'com.apple.LaunchServices*')):
      os.remove(p)   # stale LS DB seeded while the extension catalog was unreadable (patch 0099 fixes that)
  ```
- Expected after re-seed [U]: `Ignoring app extension` ~0, pkd `Candidate plugin count` > 0, PosterBoard
  `Received N extensions`. If appexes are still ignored, check that lsd's gatherer thread (not only its main thread)
  gets the catalog: the same `amfi_interface_query_bootarg_state` must succeed there (it printed the error 2x/boot in
  5E359B: once in the lsd main thread for the catalog and once in `-[MIDaemonConfiguration
  codeSigningEnforcementIsDisabled]`; both are answered by 0099).

No kernel change is required for this symptom. The "Failed to fetch app bundle unit" and "(null) not in the binding
map" lines will remain after the fix; ignore them.

### launchd `__mac_syscall("AMFI", 0x5a)`
- 0x5a is `amfi_check_dyld_policy_self(input_flags, &output_flags)` (libamfi stub, e.g. 0x1a466cc0c in dyld,
  0x19c9cae54 in libsystem_trace; the op table: 0x5a dyld policy, 0x5f cdhash_in_trustcache, 0x60 query_bootarg_state,
  0x61/0x62 local-signing keys, 0x64 authorize_local_signing, 0x65 load_trust_cache). [V]
- dyld's `SyscallDelegate::amfiFlags` (0x1a463f3c0) uses the output only if the call returned 0, else it uses 0
  (`csel x0, x8, xzr, eq`). ENOPOLICY therefore gives "all AMFI dyld permissions denied" (no DYLD_* env, restricted
  mode), which is the safe default and has no connection to LaunchServices, ExtensionFoundation or pkd. [V]
  Optional cosmetic follow-up: answer 0x5a with 0 and an output of 0 (or the allow bits) in the "AMFI" policy if
  DYLD_* debugging env vars are wanted later.

## Not verified / limits
- I could not read the phone's userdata (not touched); the presence of the csstore on the phone is inferred from
  the logs listed in Q2, not from a file listing.
- Whether a real device prints the 130 "Failed to fetch app bundle unit: 0" lines: only the code path is verified.
- That re-seeding will register the appexes: depends on the catalog also being readable inside the gatherer's
  `MICopyExtensionCacheEntryWithPlatform` (same EXEnumerator + same AMFI query as the one that now works in lsd's
  main thread; A3D22D has no `Extension cache does not have an entry` line, but also no gatherer run).
- Boot ordering by file position; uptimes in the archive are relative (1970 timestamps), no wall clock.
