# csops, entitlements and the assetsd / tccd abort

Question: why can iOS daemons not read another process's code-signing identity and
entitlements under our XNU port, and does that explain
`assetsd requires TCCPhotosService access`?

Tags: **[verified]** = seen in a phone log, a disassembly or a host test in this investigation;
**[unverified]** = deduced, not yet seen running on the phone.

## Result in one paragraph

The premise was wrong. **Identity and entitlement lookups through csops work** on the phone
(tccd names assetsd `com.apple.assetsd` and grants it Photos through
`com.apple.private.tcc.allow`). What fails is the step *after* the grant: tccd issues a
sandbox extension for the service and our built-in "Sandbox" MAC policy answered that call
(`__mac_syscall("Sandbox", 5, ...)`) with ENOENT. tccd then replies
`kTCCErrorDomain 6 "server error: Failed to issue Sandbox Extension for kTCCServicePhotos"`,
`tcc_authorization_preflight(kTCCServicePhotos)` fails inside assetsd and PLPrivacy turns
that into the exception. That also explains why a hand-written TCC.db row changed nothing:
the grant was already happening, the reply failed. Fix: **patch 0116** (sandbox
extensions). Patch 0115 closes a real but different csops gap (DER entitlements for
XML-only signatures) and adds tracing; it is not what stops assetsd.

## Evidence for the root cause

Source: `logs/ios-0113/ios.logarchive` (unified log pulled from the phone, boot
`D7F046...`), parsed with `research/macos-UnifiedLogs/.../unifiedlog_iterator`.

1. [verified] tccd identifies and grants assetsd:
   `Granting TCCDProcess: identifier=com.apple.assetsd, pid=253 ... access to kTCCServicePhotos via entitlement 'com.apple.private.tcc.allow'`, `AUTHREQ_RESULT: authValue=2, authReason=11`.
   3432 grants of that kind in the archive (all boots), no failed identification.
2. [verified] The same tccd also resolves assetsd's *peers* by audit token (check-by-audit-token):
   `requestor: ...assetsd... is checking access for accessor ...PhotosReliveWidget` and
   `...PhotosPosterProvider`, both granted. So SecTaskCreateWithAuditToken, signing identifier,
   entitlement arrays (`kTCCServicePhotos` inside an array) and `check-by-audit-token` all work.
3. [verified] Right after the grant: `Failed to issue Sandbox Extension for kTCCServicePhotos from Resp:{... assetsd ...}`,
   then in assetsd `Created Error: Error Domain=kTCCErrorDomain Code=6 "server error: Failed to issue Sandbox Extension ..."`,
   `tcc_authorization_preflight(kTCCServicePhotos) fails: ...Code=6`, then
   `*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'assetsd requires TCCPhotosService access'`
   (pid 253, boot D7F046, 73302776452 .. 73302909022 ns; launchd then logs `exited due to SIGABRT | sent by assetsd[253]` and respawns it
   "because incomplete work"/"semaphore" every few seconds: 38 aborts in the archive).
4. [verified] The kernel log has `SWEET Sandbox: tccd op 5` (first use of op 5 by tccd) in every
   boot, immediately before the first `Failed to issue sandbox extension` (e.g. boot 6E570A
   `170400554587` then `...554893`). Failure counts in the archive: AddressBook 2691, Photos 112,
   MediaLibrary 17, Microphone 5, Camera 5 - every service that gets an extension.
5. [verified] tccd calls `sandbox_extension_issue_generic(class, 0)` (and `_issue_file` for
   paths): `tccd` imports; `libsystem_sandbox`'s `_sandbox_extension_issue_generic` ->
   `__sandbox_extension_issue` -> `__sandbox_ms("Sandbox", 5, args)`; NULL (failure) when the
   syscall fails. `sweet_sandbox_syscall` returned ENOENT for ops 4, 5, 6 and 0x43 (patch 0050 and later).
6. [verified] assetsd's check (`assetsd+0x16280`): `[[PLPrivacy sharedInstance] photosAccessAllowedWithScope:7]`,
   throws when the result is non-zero. PLPrivacy (PhotoLibraryServicesCore `0x19b1886d8`,
   `_resolvePreflightStatusForScope:` `0x19b18898c`) calls `tcc_authorization_preflight(kTCCServicePhotos)`
   and takes its result as the authorization; an error reply is not "allowed".
7. [unverified] After 0116 assetsd gets past this check. It may hit the next problem (nothing
   else was visible in the log because it dies here).

## How userland asks the kernel (iOS 16.7.x dyld shared cache)

All [verified] by disassembly of the cache in `research/dsc` unless noted.

| Caller | csops op | Notes |
|---|---|---|
| `SecTaskLoadEntitlements` (behind `SecTaskCopyValueForEntitlement`, `SecTaskCopyValuesForEntitlements`) | `csops_task(task, 0x10 = CS_OPS_DER_ENTITLEMENTS_BLOB, buf, 8)`, on ERANGE reads the big-endian length at `buf+4`, `malloc`, repeats with the full length; blob+8 goes to `CEManagedContextFromCFData`. Only on a failure other than ERANGE: `CS_OPS_STATUS` (4 bytes) for a log line. | **DER only. The XML blob (op 7) is never requested.** A call that returns 0 without data is "this process has no entitlements" (dictionary NULL, no error). |
| `SecTaskCopySigningIdentifier` | `SecTaskCopyIdentifier(task, 0xb)` = `CS_OPS_IDENTITY` | blob with 8-byte header, string at +8 |
| `SecTaskCreateWithAuditToken` | none | copies the token; `csops_task` later uses `csops_audittoken` |
| libxpc `xpc_copy_entitlement_for_token` | `_xpc_copy_entitlements(token, ..., 0x10)` -> `_xpc_copy_entitlements_data` -> `_xpc_get_csops_blob` -> `xpc_create_from_ce_der` | DER only, same ERANGE protocol [csops call inside `_xpc_get_csops_blob` not traced] |
| tccd (direct imports) | `csops_audittoken(CS_OPS_STATUS, 4)`, `csops(pid, CS_OPS_PIDOFFSET = 6, 8)` | plus the SecTask calls above, `sandbox_extension_issue_generic/_file`, `sandbox_check_by_audit_token`, `sandbox_init` |
| `PLPrivacy` / assetsd | none (XPC to tccd via `tcc_authorization_preflight`) | |

Not used on this path: `CS_OPS_TEAMID`, `CS_OPS_CDHASH`, `CS_OPS_VALIDATION_CATEGORY`,
`CS_OPS_ENTITLEMENTS_BLOB` (the last one is requested by older tools and by `codesign`/`amfid`
style code only). `csops_audittoken` checks `token.val[5] == pid` and `token.val[7] == pidversion`
(ESRCH otherwise).

## Trace through our kernel (bsd/kern/kern_proc.c `csops_internal`, kern_cs.c, ubc_subr.c)

1. `csops_audittoken`: `proc_find`, audit token pid and pidversion compared; `mac_proc_check_get_cs_info`
   (no policy denies). Works [verified: tccd resolves peers by token].
2. All get-ops go through `csproc_get_blob(p)`: needs `p_textvp`, **`CS_SIGNED` in the proc flags**
   (set by `sweet_amfi_vnode_check_signature`, patch 0036) and `ubc_cs_blob_get(p_textvp, -1, -1, p_textoff)`.
3. `CS_OPS_STATUS`: proc flags + `CS_ENFORCEMENT` + `CS_PLATFORM_BINARY` (from the SWEET AMFI policy
   marking every root-filesystem binary) [verified earlier: 0x26000001 in QEMU, launchd is satisfied].
4. `CS_OPS_IDENTITY`: `cs_identity_get` -> `csblob_get_identity` (the code directory identifier;
   assetsd's is `com.apple.assetsd`) [verified: tccd prints it].
5. `CS_OPS_DER_ENTITLEMENTS_BLOB` (the one that matters): requires `CS_VALID | CS_DEBUGGED` in the proc
   flags, then `csblob_get_der_entitlements(blob)`: returns `blob->csb_der_entitlements_blob` after
   re-hashing it against special slot -7 of the code directory.
   - 4K-page signatures are converted to multilevel hashes on our 16K kernel
     (`ubc_cs_convert_to_multilevel_hash`). That conversion sets `csb_entitlements_blob = NULL`
     (the XML blob, the reason entitlements are attached in the MAC hook, NOTES patch 0035) but
     **keeps the DER blob** (`blob->csb_der_entitlements_blob = der_entitlements`, ubc_subr.c ~3854) and
     re-validates the new blob with it. iOS 16 system binaries carry both slots: special slots of
     assetsd, tccd and launchd all show -5 (XML) and -7 (DER) non-zero [verified with
     `sigdump.py`-style parsing of the Mach-O signatures extracted from the IPSW root dmg].
     So for platform binaries the DER comes straight from the signature and needs no AMFI.
   - If the signature has **no** DER slot (`csblob_get_der_entitlements` returns 0 with
     `start == NULL`), XNU falls back to `amfi->OSEntitlements_get_transmuted(osent, &blob)`. Our
     stand-in returned `false`, the op then did `goto out` with error 0 and nothing copied, which
     SecTask reads as "no entitlements". This is the real csops gap. It affects binaries signed
     with XML entitlements only (e.g. `ldid -S`/old tools, our `tools/mkinit.py` test signatures); it
     does not affect the stock iOS 16 binaries. -> patch 0115.
   - A signature with a DER slot but no XML slot attaches no `SweetEntitlements` object (the attach
     hook parses XML), so kernel-side entitlement queries (`IOTaskHasEntitlement`) deny
     everything for it. Not handled [unverified, not seen on the stock image].
6. `CS_OPS_ENTITLEMENTS_BLOB`: served from `SweetEntitlements::xml` (the copy made in the hook),
   independent of the NULLed `csb_entitlements_blob`. Fine.

## What changed

### 0115-sweet-csops-entitlements.patch (csops; apply on bt114)

- `SweetEntitlements.cpp`: DER encoder (`sweet_der_build`) producing the CoreEntitlements layout
  codesign emits: header `0xfade7172` + `[APPLICATION 16] { INTEGER 1, [CONTEXT 16] { SEQUENCE { UTF8String key, value }* } }`,
  value = BOOLEAN / UTF8String / INTEGER / OCTET STRING / SEQUENCE (array) / nested `[CONTEXT 16]`
  dictionary, keys sorted bytewise. Built lazily from the parsed XML and cached in the object
  (`OSCompareAndSwapPtr`). `sweet_entitlements_get_der()`.
  [verified on the host] The kernel encoder source, compiled with mocked OS* classes
  (a throwaway harness, not kept in the tree), reproduces byte for byte the real DER slots of
  assetsd (3718 B), tccd (780 B) and launchd (1097 B) from their XML entitlements, plus
  edge cases (lengths 0x7f/0x80/0xff/0x100/0x10000, negative and 64-bit integers, empty
  dict/array, nested dict, unsorted input).
- `sweet_amfi.c`: `OSEntitlements_get_transmuted` now returns that blob, so
  `CS_OPS_DER_ENTITLEMENTS_BLOB` works for XML-only signatures. The signature's own DER slot
  is still preferred (it is checked first in `csops_internal`).
- `kern_proc.c`: `csops_internal` is now a thin wrapper around `csops_internal_impl` and calls
  `sweet_csops_trace()` (SWEET builds only). No behaviour change.
- Boot-arg **`sweetcsopslog=1`**: logs, per op, the first 6 successful and the first 6 failing
  csops calls (`csops`, `csops_audittoken`):
  `SWEET CSOPS: caller[pid] DER_ENTITLEMENTS_BLOB(16) -> target[pid] usize 8 token errno 34 csflags 0x... blob 1 der-slot 1 os-ent 1`.
  STATUS lines include the returned flags, IDENTITY the identifier.
- Compile-checked with `tools/xnu-cc.py` (3 files, real objects emitted, new externs all defined:
  `copyinstr`, `csblob_get_der_entitlements_unsafe`, `proc_getcsflags`, `sweet_entitlements_get_der`, ...).

### 0116-sweet-sandbox-extensions.patch (the assetsd fix; apply after 0115 or alone)

- `sweet_sandbox_syscall` op 5 (extension issue) now parses the seven-word argument block
  `{ name, type, target, flags, out buffer(0x800), -, - }` and copies out an opaque token
  `SWEET-<serial>;<type>;<name>`; op 6 (consume) copies out a non-zero handle; op 7 (release)
  already returned 0. Ops 4 and 0x43 (container paths) still fail with ENOENT.
- The first 8 issues log `SWEET Sandbox: <proc> issued extension type N '<class or path>'`.
- Nothing is enforced (there is no sandbox), tokens only have to exist so the callers' plumbing
  works. Side effect: every tccd client (Contacts, Camera, Microphone, MediaLibrary, ...) stops
  getting the kTCCErrorDomain 6 error after a grant.

Apply order: `git apply xnu/patches/0115-...` then `0116-...` on a fresh `research/bt114/xnu`
(both checked with `git apply --check`; the pair applied in order produces the tree the
objects above were compiled from).

## Phone test (nothing here was run on the phone)

Tool: `tools/sweetnet/cscheck.c` -> `research/sweetnet/cscheck` (iOS 16 arm64, ad-hoc signed with
`tools/sweetnet/entitlements.plist`; `sh tools/sweetnet/build.sh`, or `TOOLS=cscheck sh ...`).
Host-tested on macOS (csops, audit token search, SecTask calls, DER walker all behave).

```
scp research/sweetnet/cscheck root@192.168.7.2:/var/root/
ssh root@192.168.7.2
chmod +x /var/root/cscheck
/var/root/cscheck -l | head                       # pids and names
```

1. Before/after sanity of identity + DER (kernel 0114 and later; expected to be healthy already):

   ```
   /var/root/cscheck -t -k com.apple.frontboard.launchapplications tccd
   /var/root/cscheck -v 1          # launchd: identity 'com.apple.xpc.launchd'
   ```

   Expect `STATUS ... VALID ... SIGNED PLATFORM_BINARY`, `IDENTITY 'com.apple.tccd'`,
   `ENTITLEMENTS_BLOB (XML): data`, `DER_ENTITLEMENTS_BLOB: data` with a key list, and the
   `SecTask (audit token)` lines returning the identifier and the entitlement. If those pass,
   csops is not the problem (what the log already says).

2. assetsd (it respawns every few seconds while it aborts, so catch it in a loop; `-t` searches
   the pid version for a few seconds worst case, so use the plain form in the loop and `-t` once):

   ```
   for i in 1 2 3 4 5 6 7 8 9 10; do /var/root/cscheck -k com.apple.private.tcc.allow assetsd && break; sleep 0.3; done
   ```

   Expect `IDENTITY 'com.apple.assetsd'`, DER `com.apple.private.tcc.allow = ["kTCCServicePhotos", "kTCCServiceAddressBook"]`
   and `com.apple.private.tcc.manager.check-by-audit-token` present. This is the "before" proof that identity
   and entitlements are readable while assetsd still aborts (kernel 0114).

3. XML-only signature (exercises 0115): only a binary whose signature has no DER slot hits the new
   code, and no stock iOS 16 binary is like that (modern `codesign` also writes DER). Not planned on
   the phone; the encoder itself is covered by the host test above. If wanted: boot QEMU with an init
   signed by `tools/mkinit.py OBJ OUT ENTS.plist` (XML slot only) and run `cscheck -k <key> self`;
   before 0115 it prints `DER_ENTITLEMENTS_BLOB: success, no data (SecTask sees NO entitlements)` and
   the SecTask lines `(null)`, after it `data` with the keys. [unverified, not run]

4. The actual assetsd fix (0116), after flashing a kernel with 0115+0116:
   - `ssh root@192.168.7.2 'killall assetsd'` (or reboot), then watch that it stays up:
     `for i in 1 2 3 4 5; do pgrep -x assetsd; sleep 5; done` (same pid each time).
   - Kernel log: `SWEET Sandbox: tccd issued extension type 3 'com.apple.tcc.kTCCServicePhotos'`.
   - Unified log (pull as usual): no more `Failed to issue sandbox extension`, no
     `Created Error: ... Code=6`, no `exited due to SIGABRT | sent by assetsd`.
   - With `sweetcsopslog=1` in the boot-args: `SWEET CSOPS:` lines for tccd's calls
     (`STATUS`, `PIDOFFSET`) and SecTask's (`DER_ENTITLEMENTS_BLOB` with `usize 8` then the full
     size, `IDENTITY`); expect no `errno` other than 34 (ERANGE, the length probe) for the DER op.

## Open points

- [unverified] assetsd may fail on something else once the TCC reply is fine.
- [unverified] Consumers of extension tokens that validate the token format (none found in tccd /
  libTCC; `sandbox_extension_consume` only compares against `"invalid"`).
- DER-only signatures give no kernel-side entitlements (see above); would need a DER -> OSDictionary
  decoder if such binaries show up.
- The brute-force pid-version search in `cscheck -t` is a workaround for not being able to read
  another process's audit token from userland; fresh boots have small pid versions.
