# iOS extension point registration: root cause and fix

Status tags: [V] verified (disassembly, file inspection or log line), [U] unverified (inference).
Addresses are dyld shared cache (iPhone X 16.7.16 20H392) VAs. Root inspected read-only from
`research/ipsw-x/ios16-root-20H392-b2.img` (HFS+), log = `logs/boot5/unified.jsonl`.

## TL;DR

The "extension cache" read by `MICopyExtensionCacheEntryWithPlatform` is not an MI file. It is
ExtensionFoundation's `EXExtensionPointCatalog`, which loads `/System/Library/xpc/extensions.plist`
(+ `.sig`) and the `.appexpt` files in `/System/Library/ExtensionKit/ExtensionPoints`.
The plist is in our root and has `com.apple.posterkit.provider`. lsd refuses to use it because
ExtensionFoundation verifies the plist's detached signature through AMFI, and our kernel has no
AMFI MAC policy (`__mac_syscall("AMFI", 0x60, ..)` returns "Policy not found") and no AMFI IOKit
service. The read fails ("Unable to find AMFI"), the catalog is empty, lsd registers no extension
points, so pkd and PosterBoard find none. Nothing is missing from the image layout, and the cryptex
layout is not involved.

## Q1. What is "the extension cache"

- [V] `_MICopyExtensionCacheEntryWithPlatform` (InstalledContentLibrary, 0x1b11e8578) calls
  `-[EXExtensionPointCatalog extensionPointForIdentifier:platform:]` on the global `_sExtensionPointCatalog`,
  then `-SDKDictionary`. A nil result raises `_CreateAndLogError(... "Extension cache does not have an entry for %@")`
  (line 46 = 0x2e, matching the log). `__SetUpExtensionCacheOnce` (0x1b11e8664) creates the catalog with
  `[[EXExtensionPointCatalog alloc] init]` (class soft-linked from ExtensionFoundation).
- [V] `-[EXExtensionPointCatalog init]` (0x193719df4) -> `+[EXEnumerator extensionPointDefinitionEnumerator]` (0x19373e888).
- [V] That method: `cacheURLs = +extensionPointCacheFileURLs` (0x19373e074). If non-empty, `urls = cacheURLs + +extensionPointDefinitionDirectoryURLs`
  and it builds `[EXExtensionPointEnumerator initWithCacheURLs:config:]`. If empty it logs
  "Failed to load or create cache extension/extension point info." and falls back to `+_extensionPointLiveEnumerator` (0x19373ea8c range).
- [V] `-[EXEnumeratorConfig init]` (0x19373dcd8): rootURL = `/`; xpcExtensionsCache = `/System/Library/xpc/launchd.plist`;
  xpcExtensionPointsCache = `/System/Library/xpc/extensions.plist` (ivar order from the objc dump:
  `_xpcExtensionsCache` @0x28, `_xpcExtensionPointsCache` @0x30). `extensionPointCacheFileURLs` returns the extension points cache only if
  `fileExistsAtPath:` is true.
- [V] `extensionPointDefinitionDirectoryURLs` (0x19373e148): `<root>/System/Library/ExtensionKit/ExtensionPoints` (when `_EXDefaults supportExtensionKitConfigPath`),
  plus `AppleInternal/System/Library/ExtensionKit/ExtensionPoints` on internal builds.
- [V] `-[EXExtensionPointEnumerator initWithSDKDictionary:urls:config:]` (0x19373f058): for each URL, a directory is enumerated
  with `+enumerateExtensionPointsInDirectoryAtURL:block:` (plain `.appexpt` plists, no signature). For a file:
  `if ([[_EXDefaults sharedInstance] enforceXPCCacheCodeSigning] && [path hasSuffix:@"System/Library/xpc/extensions.plist"])`
  it uses `+[NSDictionary _EX_dictionaryWithSignedURL:error:]`, otherwise `dictionaryWithContentsOfURL:`.
  On error it logs "Failed to read extension point cache at URL `%@` with error: `%@`" and continues with no entries
  (it does NOT fall back to the live scan, because the cache file existed).
- [V] `+[NSDictionary(ExtensionKitAdditions) _EX_dictionaryWithSignedURL:error:]` (0x193735400 range): requires entitlement
  `com.apple.private.amfi.can-check-trust-cache` on the calling process (lsd has it; without it the code logs
  "Unable to check trust cache due to missing entitlement" and reads the plist unsigned), loads `<file>.sig` as a detached signature
  (`SecStaticCodeCreateWithPath`, `SecCodeSetDetachedSignature`, `SecStaticCodeCheckValidity`), takes the CDHash (`kSecCodeInfoUnique`),
  then `IOServiceGetMatchingService("AppleMobileFileIntegrity")` -> `IOServiceOpen` -> `IOConnectCallMethod(sel 6, 1 scalar, cdhash)` ("cdhash: %@ is trusted").
  No service gives NSError(EXExtensionKitErrorDomain, 12, "Unable to find AMFI") (string @0x193753c69, builder at 0x193735d40).
- [V] `-[_EXDefaults enforceXPCCacheCodeSigning]` block (0x193741a9c) calls `amfi_interface_query_bootarg_state(&state)`
  (= `__sandbox_ms("AMFI", 0x60, &state)`, implemented at 0x19b96fd7c in FrontBoardServices; the same stub is statically linked in several images).
  Success sets `codeSigningEnforcementIsDisabled = (state & 0x86) != 0`. Failure logs "amfi_interface_query_bootarg_state returned error %s"
  and leaves enforcement ON (static default 0).
- [V] Log: lsd `amfi_interface_query_bootarg_state returned error Policy not found` (00:02:50.566) immediately followed by
  `Failed to read extension point cache at URL <private> ... Code=12 "Unable to find AMFI"` (6 occurrences in boot5, all lsd).
  lsd's own `-[MIDaemonConfiguration codeSigningEnforcementIsDisabled]_block_invoke` logs the same amfi error 3 times.
- [V] Who generates it: not generated on device in the normal path. `extensions.plist` + `.sig` ship in the OS image (mtime Apr 30 00:13, same as
  the rest of the OS dmg content; `launchd.plist` next to it is ours, modified Oct 19, so its `.sig` no longer matches). The on-device alternative is
  the live scan `+_extensionPointLiveEnumerator`: `EXFrameworkScanner initWithSourceURL:/` -> `combinedExtensionSDK` (merge of every framework
  Info.plist `NSExtensionSDK`) + the directory URLs, which is exactly what the shipped plist is a snapshot of (see Q2: 138 of 139 ids identical).
  The build-time tool that wrote the plist: [U] not identified. It is not run by restore (the file is in the OS dmg itself).
- [V] No MI/installd file is involved: strings `ExtensionCache` in InstalledContentLibrary are only `MICopyExtensionCacheEntryWithPlatform`,
  `allowsAppExtensionsNotInExtensionCache` and `_SetUpExtensionCacheOnce`. Searching the DSC for `/private/preboot/Cryptexes` style paths in this
  code path found nothing: the catalog root is hard-coded `/`.

## Q2. Where definitions live; poster point; our image

- [V] Poster provider id: `com.apple.posterkit.provider`, declared in `/System/Library/PrivateFrameworks/PosterKit.framework/Info.plist`
  under `NSExtensionSDK` (`EXExtensionPointConfiguration` {EXExtensionPointIsPublic=false, EXPresentsUserInterface, EXRequiresSceneHosting,
  EXRequiredEntitlements com.apple.runningboard.posterkit.host}, `NSExtension` {NSExtensionPointIdentifier, NSExtensionPrincipalClassProhibited}).
  It is also in `/System/Library/xpc/extensions.plist`:
  `"com.apple.posterkit.provider" => { "/System/Library/PrivateFrameworks/PosterKit.framework" => {...} }`. Both present in our root. [V]
- [V] Three sources feed the catalog: (1) `NSExtensionSDK` dictionaries in framework Info.plists (scanned by EXFrameworkScanner or pre-aggregated into
  `/System/Library/xpc/extensions.plist`); (2) `.appexpt` plists (not bundles; single-key `{identifier: definition}`) in
  `/System/Library/ExtensionKit/ExtensionPoints`; (3) AppleInternal dir (absent).
- [V] Our root has exactly 6 appexpt files (DeviceAccess, Safari content-blocker, Safari web-extension, 3 authentication-services). That is
  what the OS dmg ships, not a truncation. They are the only ExtensionKit-style definitions; poster is NOT an appexpt.
- [V] Compared root vs cryptexes: `/private/preboot/Cryptexes/{OS,App}/System/Library/` contains no `ExtensionKit` and no `xpc` directory, so
  nothing is shadowed and nothing the hard-link loop would have missed. Cryptex frameworks (WebKit, SafariServices, AuthenticationServices,
  MobileSafari*) are in the cryptex only; the catalog reads `/`, so an extension point declared only in a cryptex framework would be missed by
  the live scan [U for impact]; the cache and the 6 appexpt already cover Safari/AuthServices.
- [V] Cache vs live scan of root frameworks (python plistlib over `System/Library/{Frameworks,PrivateFrameworks}/*/Info.plist`):
  cache has 138 ids, scan finds 139; every cache id is found by the scan; only `com.apple.contacts.donation` is scan-only.

## Q3. Does a real device have something we lack / rebuild attempts

- [V] No missing file. The cache and `.sig` are present and the CDHash validation step before the AMFI call passed in lsd (the error is only at
  the AMFI lookup, after SecStaticCodeCheckValidity; no "Failed to set detached signature"/"Failed to verify code directory" lines).
  On a real device the same code succeeds because AMFI exists and the cdhash is in the OS static trust cache (restored from the IPSW trust cache). Restore does not create this file.
- [V] No rebuild exists for lsd: after the failed signed read there is no fallback (the file existed, so `_extensionPointLiveEnumerator` is skipped).
  lsd did not retry; it logged the failure 6 times in boot5 (first 00:02:50.566) and then every appex overlay lookup failed
  (`MICopyExtensionCacheEntryWithPlatform: 46 ... no entry for com.apple.message-payload-provider / widgetkit-extension / intents-service / storekit.*`, etc.).
- [V] lsd registers system apps itself on boot ("inspect System / registering app bundle" from 00:01:21; MI overlay errors start 00:02:51). pkd
  (`Final plugin count: 0` x110, `could not create extension point record ... -10814` x100) and PosterBoard (`extension point not found for query` x30) start at 00:01:21.
- [U] Causal chain lsd-empty-catalog -> no LS extension-point records -> pkd -10814 / PosterBoard "not found" (PosterBoard and pkd themselves are not entitled, so they
  would read the plist unsigned fine; they most likely depend on LaunchServices data that lsd populated from its empty catalog).
- [U] LaunchServices csstore persisted in userdata (`/private/var/containers/Data/System/*/Library/Caches/com.apple.LaunchServices-*.csstore`,
  `/private/var/mobile/Library/Caches/com.apple.LaunchServices-*`) might keep records built with the empty catalog; if images are reused without reflash, delete them.
- Related existing project note: `launchd_cache_loader` hit the same "Unable to find AMFI" on launchd.plist; worked around with boot-arg
  `launchd_unsecure_cache=1` (NOTES.md). ExtensionFoundation has no equivalent boot-arg; its switch is the AMFI query above.

## Q4. Proposed fix

Preferred (kernel, 1 small patch; mirrors `xnu/patches/0050-sweet-sandbox-policy.patch`): add a built-in MAC policy with `mpc_name = "AMFI"`
(the existing one is "SWEET AMFI", which `__mac_syscall("AMFI", ...)` does not match) whose `mpo_policy_syscall` handles call `0x60` by
`copyout`-ing a 64-bit state with bits in mask 0x86 set (e.g. `0x86`) to `arg` and returning 0; all other calls ENOENT (log first use like 0050).
Effects: `_EXDefaults enforceXPCCacheCodeSigning` -> NO, so lsd reads `extensions.plist` with plain `dictionaryWithContentsOfURL:`; lsd/installd
`codeSigningEnforcementIsDisabled` also becomes true (MI skips signature checks, which is desirable here). [V for the ExtensionFoundation effect;
U for other consumers of op 0x60, and which bit names 0x86 map to].
No rootfs change needed. The AMFI IOKit service (`AppleMobileFileIntegrity` user client sel 6) is NOT required on this path.

Rootfs-only alternative (no kernel change), in `tools/sweet-root-tweaks.py` after the launchd.plist edit:

```python
for n in ('extensions.plist', 'extensions.plist.sig'):
    p = os.path.join(root, 'System/Library/xpc', n)
    if os.path.exists(p): os.remove(p)
```

Then `extensionPointCacheFileURLs` is empty (`fileExistsAtPath` false), every process logs "Failed to load or create cache extension/extension point info."
and uses `_extensionPointLiveEnumerator` (EXFrameworkScanner over `/System/Library/{Frameworks,PrivateFrameworks}` + the 6 appexpt), with no signature check
at all. It reproduces the shipped contents (139 vs 138 ids). Costs: a framework scan per process that builds the catalog (slower first launches) [U for magnitude];
no other binary in the root references `xpc/extensions.plist` (grep of usr/libexec, usr/sbin, sbin, usr/lib/*.dylib and the DSC: only ExtensionFoundation) [V].
Anything declared only inside the cryptexes is not scanned (root `/`), but the cache is also missing it, so no regression.

Do not bother with: copying/linking cryptex ExtensionPoints (none exist), recreating `.appexpt` files for poster (it is an `NSExtensionSDK` entry, not an appexpt),
or re-signing `extensions.plist` (the trust is a CDHash lookup inside AMFI, not a signature we can mint).

After either fix: reflash a fresh userdata or remove LaunchServices csstores/`/var/installd/Library/MobileInstallation` caches so lsd re-registers all
system bundles with a working catalog [U], then expect lsd to stop logging `Failed to read extension point cache` and pkd to report non-zero plugin count;
PosterBoard should find `com.apple.posterkit.provider` (the poster provider appexes themselves live in the OS image, e.g. GradientPoster/EmojiPoster/UnityPoster/PridePoster frameworks are present) [U].

## Artifacts consulted

- Root: `/System/Library/xpc/{extensions.plist,extensions.plist.sig,launchd.plist}`, `/System/Library/ExtensionKit/ExtensionPoints/*.appexpt`,
  `/System/Library/PrivateFrameworks/PosterKit.framework/Info.plist`, `/private/preboot/Cryptexes/{OS,App}/System/Library/`.
- DSC symbols: `_MICopyExtensionCacheEntryWithPlatform`, `__SetUpExtensionCacheOnce`, `-[EXExtensionPointCatalog init]`, `+[EXEnumerator extensionPointDefinitionEnumerator]`,
  `+[EXEnumerator extensionPointCacheFileURLs]`, `+[EXEnumerator extensionPointDefinitionDirectoryURLs]`, `-[EXEnumeratorConfig init]`,
  `-[EXExtensionPointEnumerator initWithSDKDictionary:urls:config:]`, `+[NSDictionary(ExtensionKitAdditions) _EX_dictionaryWithSignedURL:error:]`,
  `___41-[_EXDefaults enforceXPCCacheCodeSigning]_block_invoke`, `_amfi_interface_query_bootarg_state`.
