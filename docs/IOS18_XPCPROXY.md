# xpcproxy SIGTRAP (Foundation `__NSThreadPoisoned`): root cause and fix

Symptom: both xpcproxy instances die ~650 ms after spawn with EXC_BREAKPOINT (kernel line `CRASH xpcproxy[n] sig 5 code 0x600000001 sub <pc>`).
`reason ns 2 code 0x5` is only OS_REASON_SIGNAL / SIGTRAP (no abort_with_payload message), `slide 0x0` is simply "no shared region" (the RAM disk has no cache), `mh` is the main binary xpcproxy.

## Method (all static, from the staged root; no boot needed)
* `sub` = pc (xnu passes the pc as EXC_BREAKPOINT subcode, patch 0043). Both runs have pc & 0x3fff == 0x2e80, i.e. an image offset == 0x...e80 (images are 16 KiB aligned).
* Scan of every `brk` at (vmaddr & 0x3fff) == 0x2e80 in the staged Mach-Os: only a handful of images match. `libsystem_trace 0x6e80` (BUG IN LIBTRACE) was rejected: its only path to `brk` is the local `os_log_fmt_delimit`, whose callers return into libtrace, but the crash lr is in another image.
* Key observation: pc - lr is the same constant (0x7f7de0) in both runs, so pc and lr are in the SAME big image. Foundation has `brk #1` at 0x81ae80 (`__NSThreadPoisoned`) and 0x81ae80 - 0x7f7de0 = 0x230a0, which is the return address after `bl __NSThreadPoisoned`... precisely `-[_NSThreadData setTarget:]` (0x22fec..0x230a0, the `bl` at 0x2309c). Image base = 0x106f130a0 - 0x230a0 = 0x106ef0000 (run 1) and 0x108fd70a0-0x230a0 = 0x108fb4000 (run 2).
* Backtrace, resolved (offsets in Foundation unless noted; every return address is preceded by a `bl`/`blr`):

| bt | address (run 1) | where |
| --- | --- | --- |
| lr | 0x106f130a0 | `-[_NSThreadData setTarget:]` (called `__NSThreadPoisoned`) |
| 0 | 0x106f1a938 | `-[NSThread init]` +0x...a938 (Foundation 0x2a938) |
| 1 | 0x106f08858 | block/func 0x18858 (calls NSThread init) |
| 2 | 0x10279b584 | libdispatch 0x1b584 `_dispatch_client_callout` (`blr x1`) (libdispatch base 0x102780000) |
| 3 | 0x1027849a8 | libdispatch 0x49a8 `dispatch_sync_f` (cas lock + callout) |
| 4 | 0x106f12fe8 | Foundation 0x22fe8 `__NSThreadGet0` |
| 5 | 0x106f5ec58 | Foundation 0x6ec58 `__NSInitializePlatform` |
| 6 | 0x102666058 | outside Foundation (libdyld/initializer chain), 7-9 = further initializer frames |

So: Foundation's image initializer `__NSInitializePlatform` -> `__NSThreadGet0` -> `dispatch_sync_f` -> `-[NSThread init]` -> `-[_NSThreadData setTarget:]` -> check fails -> `__NSThreadPoisoned` (`brk #1`). (Foundation gets pulled in by xpcproxy via libCoreEntitlements -> Foundation/CoreFoundation; dyld runs its initializers.)
The `far 0x...ae70` in the printout is stale/irrelevant for brk (pc-0x10 = the previous `mov` ... not a data fault).

## The failing check
arm64e Foundation protects `_NSThreadData` with a PACGA chain (a 3-step keyed MAC over ivars, modifier = object pointer | 0x2e49<<48), stored with `stlr` at obj+0x20 and verified (`cmp; b.ne -> __NSThreadPoisoned`) in setTarget:, name setters, etc. Original code:

    check: pacga x10,x10,x9 ; pacga x10,x16,x10 ; pacga x10,x11,x10 ; ldar x11,[obj+0x20] ; cmp ; b.ne poisoned
    store: pacga x8,x1,x9   ; pacga x8,x16,x8   ; pacga x8,x9,x8   ; stlr x8,[obj+0x20]

`tools/renegade/pacstrip.py` rewrites each PACGA to `eor Xd,Xn,Xm,ror #k` with `k = 7 + (rd*5 + rn*3 + rm) % 50`, i.e. **k depends on the register numbers of the site**. The check site became `ror #46,#15,#50` and the store site `ror #9,#53,#32`, so the value stored by `-[NSThread init]` can never equal the value recomputed in `setTarget:`: every `_NSThreadData` is "poisoned" on first use. (The feasibility doc said "any deterministic function keeps (b) correct": true only if the function is the same at every site.) Same hazard in the other 326 Foundation + 99 CoreFoundation + 70 JavaScriptCore integrity sites.

## Fix (rootfs side, no kernel change needed)
Make the PACGA replacement independent of the registers. In `tools/renegade/pacstrip.py` (not edited here: another agent owns that file):

    -            k = 7 + (rd * 5 + rn * 3 + rm) % 50
    +            k = 13          # constant: MAC check and MAC store sites use different registers
    (the rm == 31 / MOV case: unchanged; no Foundation integrity site uses an SP modifier)

Verified on a scratch copy: patched pacstrip run on Foundation gives `eor ... ror #13` at all six sites of `setTarget:` (0x23028..0x23080), so check == store. Then rebuild the root (`tools/renegade/mkramdisk-root.sh`) and re-run.

Caveats: with constant k the replacement is `n ^ ror(m,13)`, which is order-insensitive, so the 7 libobjc PACGA hash-loop sites (0x3a9c, 0x7984, 0xb3f8..0xb444, 0x2d2a0) degrade to an XOR hash (still deterministic; only collision quality). If that matters later, special-case libobjc by path to keep the register-dependent k there after checking those sites are not store/verify pairs.

## What may come next
Other places in Foundation/CoreFoundation that hash with PACGA are fixed by the same change. Further failures after this will be a new trap site: use the same method (scan `brk` at the pc page offset, then pc-lr constant-gap trick to find the image).
Scratch artifacts: scratchpad `scan.py` (brk scan by page offset), `match2.py` (bt return-address matching).
