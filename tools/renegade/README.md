# Renegade

The Bergamota Project's patcher. iOS 18 ships every system binary as **arm64e** (pointer authentication), but the Poco F1's Snapdragon 845 is ARMv8.2 without PAuth. Renegade rewrites the code so it runs anyway, then builds the flashable root image around it. `renegade help` lists the commands.

| Command | Tool | What |
| --- | --- | --- |
| `renegade strip IN [OUT]` / `scan` | `pacstrip.py` | Rewrites one Mach-O 4 bytes for 4 bytes (RETAA→RET, BRAA→BR, LDRAA→LDR, PAC/AUT/XPAC→NOP, PACGA→EOR ROR #13). `--sign` re-signs ad hoc, keeping the identifier, flags and entitlements |
| `renegade cache DIR` | `pacstrip_cache.py` | Does the same over the dyld shared cache (main + sub-caches) and refreshes the CodeDirectory page hashes |
| `renegade fips DIR --patch` | `fips_rehmac.py` | Recomputes corecrypto's FIPS POST HMAC over the rewritten `__text` |
| `renegade fetch` | `fetch-root.sh` | Downloads and decrypts the 22H352 iPhone11,8 root and cryptex dmgs |
| `renegade fetch-tools` | `berga_tools.py` | Downloads `berga-tools.zip` (the prebuilt on-device binaries) from the newest `berga-tools-vN` GitHub release (`--tag`, `--zip FILE`, `--status`), verifies SHA-256 and the manifest, unpacks it into `~/.cache/bergamota/berga-tools`. Python stdlib only |
| `renegade root` | `mkroot-full.py` | Full root image: stages `copy, macho, cache, tweaks, seal`. macOS: no sudo (owners are set in the HFS+ catalog by `hfsroot_owners.py`); Linux: root, see Platforms |
| `renegade boot` | `mkboot-full.sh` | Enxerto boot image for the root on `userdata` |
| `renegade jb fetch\|stage\|live\|remove\|status` | `jailbreak.py` | Jailbreak userland (below); `mkroot-full.py` stage `jb`, on by default (`--no-jb`) |
| `renegade update SIMG` | `update.py` | Applies the root auto-fixes to a finished image in place, no IPSW needed (below) |
| `renegade hfs SIMG …` | `hfsx.py` | Reads the sparse root image in place: `ls`, `cat`, `get`, `find`, `dsc` |
| `renegade sparse IN OUT` | `img2simg.py` / `simg2img.py` | Converts between raw and Android sparse images, with `--consume` for tight disks |

`root_tweaks18.py` holds the first-boot changes to the root (Setup skip, activation, SSH, staged system apps, ...). `dsctools/` symbolicates and disassembles the rewritten shared cache. The kernel half lives in Heartwood: patch 0131 (`sweetarm64e=1`) loads arm64e binaries, and 0141 emulates FJCVTZS, which has no 1:1 rewrite. Details and history are in `docs/IOS18_PORT.md`.

## Platforms (macOS and Linux)

Everything that differs between the two hosts lives in `renegade_platform.py` (not `platform.py`: that would shadow the standard library module). The image tools (`hfsx`, `hfsroot_owners`, `simg2img`, `img2simg`, `pacstrip`, `pacstrip_cache`, `fips_rehmac`, `jailbreak`) are Python and run on both. Hole punching (`hfs_trim`, `--consume`) uses `F_PUNCHHOLE` on macOS and `fallocate(PUNCH_HOLE)` on Linux (ext4, xfs, btrfs, tmpfs; if the filesystem cannot punch holes, a warning is printed and `--consume` keeps both files on disk until it ends).

| Operation | macOS | Linux (root) |
| --- | --- | --- |
| Create the image | `mkfile -n` | sparse file |
| Format: HFSX, case-sensitive, not journaled | `hdiutil attach -nomount` + `newfs_hfs -s` | `mkfs.hfsplus -s -v iOSRoot` (hfsprogs; no `-J`) |
| Attach and mount read-write | `hdiutil attach`, no sudo | `losetup --find --show` + `mount -t hfsplus -o rw,force,nls=utf8` |
| Read the IPSW volumes (APFS) | `hdiutil attach -readonly` (two mounts: owners on for the map, off for the copy) | `apfs-fuse` (read-only FUSE; as root one mount shows the real owners and every file) |
| Copy into the root | `ditto` | Python copy (modes, owners, symlinks, hard links; no xattrs, ACLs or compression) |
| Owners | recorded, applied to the HFS+ catalog offline by `hfsroot_owners.py` | `chown` for real (root; the hfsplus driver stores owners) **and** recorded, so the offline catalog pass runs on the same table |
| fsck | `fsck_hfs -fn` | `fsck.hfsplus -f -n` |
| Ad-hoc signing (identifier, CS options and entitlements kept) | `codesign -f -s -` | `ldid -S -I -C -Hsha256`, pinned and SHA-256 verified (`jailbreak.py`: `HOST_LDID`) |
| Unmount | `hdiutil detach` | `umount` + `losetup -d` (`umount` / `fusermount3 -u` for apfs-fuse) |
| `verify` stage | also `codesign -v` of a sample and the HFS-compression check | those two checks are skipped (the identity/CS-flag check of every re-signed Mach-O still runs) |
| Download and decrypt the IPSW | `ipsw` (blacktop) | `ipsw` (Linux build) |
| On-device tools (`sweetnet`, `ssh`, GPU payload) | built with `xcrun` | **never built**; installed only if prebuilt artifacts exist |

**Unjournaled volume.** The image is formatted without a journal. That is what lets `hfsroot_owners.py` edit the catalog offline (it asserts the journaled bit is clear), and it is also what makes a read-write mount with the Linux hfsplus driver safe: the driver mounts journaled volumes read-only unless forced, and `force` is only there for the "not cleanly unmounted" flag of an image that came from macOS. Do not use `force` on a journaled volume.

**Feature gating (any host).** Features that install a prebuilt on-device binary switch themselves off when the binary is missing, with a message at the point of the skip and a summary at the end of `renegade root` / `renegade update`; they never fail the run. Binaries are looked for in `research/sweetnet/` (also `ios18/`), the main checkout's, `$RENEGADE_SWEETNET`, `research/ssh-build/out/`, `research/bergamota-gl/` / `$RENEGADE_BGL`. Last of all, the cache of `renegade fetch-tools` (`<cache>/<tag>/sweetnet` and `<cache>/<tag>/bergamota-gl`; `$RENEGADE_TOOLS_CACHE`, `$RENEGADE_BERGA_TOOLS`): a local build always wins. On Linux nothing is compiled, so these are skipped unless `renegade fetch-tools` was run or a prebuilt artifact was dropped into those directories. `tools/berga-tools/package.sh` makes the zip.

| Part | Needs | Without it |
| --- | --- | --- |
| launchd edits (`_PanicOnCrash`, CommCenter), containers, event timing, usbnet plists, audio, activation | nothing | always done |
| Preferences (Setup skipped, migration, `SBShowBatteryPercentage`, ...) | nothing | always done |
| Bluetooth `BT_HCI_TRANSPORT` in bluetoothd's job | nothing | always done |
| Bluetooth BlueTool stub, `hcitest` | `bluetool-stub`, `hcitest` (xcrun) | skipped |
| Jailbreak userland (Procursus, Sileo, TrollStore: prebuilt debs, re-signed with ldid on Linux), `/var/jb` | network, `zstd` | done |
| dropbear SSH job | prebuilt `dropbear`, `dash`, `toybox` in `research/ssh-build/out/`; Linux also wants `dropbearkey` (`dropbear-bin`) or a `dropbear-linux` artifact for the host key | skipped with a message |
| `sweetnetcfg`, `sweetreboot` | xcrun | skipped |
| App registration (`appreg`: `sweetuicache`) | xcrun | skipped; the staged apps are still moved to `/Applications`, which is what lsd's own seeding of a fresh LaunchServices database picks up (unverified on the device); an image whose database is already seeded does not register them |
| PosterBoard `sweetfp.dylib` | xcrun | skipped, PosterBoard left alone |
| Default wallpaper and icon style (`sweetposterset`, `sweeticonstyle`, `sweetopen`, `SweetRun.app`) | xcrun, and `sweetuicache` | skipped |
| `sweetmetrics`, `sweetprefs` tools | xcrun | skipped |
| `bglrender` payload | `gpu/eagl/make-payload.sh` (Mac) | skipped, backboardd untouched |
| First-boot job | `/bin/sh` in the root (dash from the ssh step) | the job is still installed without `sweetuicache`, for the jailbreak post-install; skipped only if `/bin/sh` is missing |

### Linux

Run as **root**: the image is mounted with a loop device and `mount(8)`, and apfs-fuse needs to read root-only files. `sudo -E tools/renegade/renegade root` (the research directory then holds root-owned files: `sudo chown -R "$USER" research` afterwards). `renegade update --check` reads the image with `hfsx.py` and needs no root. The kernel needs the `hfsplus` module (`modprobe hfsplus`; a container shares the host kernel).

```sh
# Debian / Ubuntu
sudo apt install python3 curl hfsprogs util-linux zstd dropbear-bin  # dropbear-bin: host keys for the ssh step (optional)
# ipsw (download + AEA decryption): the .deb or tarball of https://github.com/blacktop/ipsw/releases (linux_x86_64 / linux_arm64)
# apfs-fuse is not packaged in Debian/Ubuntu: build it (https://github.com/sgan81/apfs-fuse, read its README for the packages)
sudo apt install cmake g++ git libfuse3-dev libbz2-dev zlib1g-dev libattr1-dev fuse3
git clone --recursive https://github.com/sgan81/apfs-fuse && cmake -S apfs-fuse -B apfs-fuse/build && make -C apfs-fuse/build -j && sudo install apfs-fuse/build/apfs-fuse /usr/local/bin/
```

`ldid` needs no package: the pinned `ProcursusTeam/ldid` release (`v2.1.5-procursus7`, `ldid_linux_x86_64` / `ldid_linux_aarch64`) is downloaded into `research/jb/ldid-host-v2.1.5-procursus7/` and checked against the SHA-256 in `jailbreak.py` before it is ever run (`RENEGADE_LDID=/path` uses another build). opa334's fork, which `jailbreak.py` pins for the phone, publishes only the iOS binary; the Procursus ldid is the same code base.

`RENEGADE_APFS_VOLUME=N` picks the APFS volume of the OS dmg (default 0). `RENEGADE_DRY_RUN=1 tools/renegade/renegade root ...` (also `update`) prints the commands of the platform layer and runs nothing; `RENEGADE_PLATFORM=linux` on a Mac builds the Linux command lines (`renegade platform --plan linux`). `renegade test` runs the unit tests (command construction of both backends, the dry-run flow, the tree copy, the feature gating, and on macOS codesign-vs-ldid parity).

Signing differences to know about: `ldid` writes a CodeDirectory version 2.4 (codesign: 2.5 with the exec-segment fields), adds a default requirements blob and no "Runtime Version". On a sample (thin arm64 and arm64e) the identifier, the CS flags (adhoc, hard, library-validation, runtime), the hash type (sha256 only) and the entitlements are identical to codesign's, and `codesign -v` accepts the result.

**Not verified on a real Linux host or on the device** (there was no Linux machine): the `mkfs.hfsplus`, `mount -t hfsplus`, `fsck.hfsplus` and `apfs-fuse` command lines, `hfsroot_owners.py`/`hfs_trim.py` on an hfsprogs-formatted volume, `apfs-fuse` on the real IPSW dmgs (volume index, sealed-snapshot volumes), and whether the iOS kernel accepts a volume that the Linux hfsplus driver wrote.

## Jailbreak userland

On by default in `renegade root` and `renegade update` (opt out with `--no-jb` / `RENEGADE_NO_JB=1`): `renegade jb` stages a rootless Procursus userland, Sileo and TrollStore. Nothing downloaded is executed on the Mac (only unpacked), no third-party binary is committed (downloads are cached in the git-ignored `research/jb/`), and every download is checked against the SHA-256 pinned in `jailbreak.py`.

| Component | Pinned version | SHA-256 | Licence | Source |
| --- | --- | --- | --- | --- |
| Procursus rootless bootstrap | `bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst` (2024-06-10) | `8354c3aa1ecdad8ebc47d9a76dfca6f830a2b757278068bd33b98bf1d638a9cb` | Procursus 0BSD; packages keep their own (GPL-2/3+, ISC, BSD, MIT), see `/var/jb/usr/share/doc/*/copyright` | https://apt.procurs.us/bootstraps/1900/ , https://github.com/ProcursusTeam/Procursus |
| Sileo | 2.5.1 `org.coolstar.sileo_2.5.1_iphoneos-arm64.deb` | `8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a` (same as in the Procursus `Packages`) | BSD-4-Clause | https://github.com/Sileo/Sileo (there is no `Sileo-Team/Sileo`) |
| TrollStore | 2.1.1 `TrollStore.tar` | `144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551` | MIT; `RootHelper/uicache.m` BSD-4-Clause | https://github.com/opa334/TrollStore |
| ldid (for TrollStore's signing) | v2.1.5-procursus7-new | `b6aa4018e7ef3df9ee3fee5889d162649719109521c5a2136ca98a81fccdf52a` | AGPL-3.0 | https://github.com/opa334/ldid |

Commands: `renegade jb fetch` (download + verify), `stage` (unpack into `research/jb/stage/` with `manifest.tsv` = owner/mode of every path), `live [--dry-run DIR] [--reinstall]` (install over SSH, or only unpack the install tar into DIR), `remove`, `status`. `live` and `remove` write to the device and need `RENEGADE_JB_LIVE_OK=1`. In the image build the `jb` stage is added before `seal` whenever `tweaks` runs (or give it explicitly: `--stages copy,macho,cache,tweaks,jb,seal,verify,simg`).

* **Layout.** The root is ours, so `/var/jb` is a plain directory on the root volume (no `/private/preboot/<hash>/jb-XXXX` symlink). In image mode it is written to `/private/var/jb`; `/var` stays the symlink to `private/var` (`image_stage` checks this before and after the copy and writes owner entries for `var/jb` only, never for `var`). Sileo is `/var/jb/Applications/Sileo.app`, registered with `/usr/local/bin/sweetuicache`; its `giveMeRoot` helper is setuid root. Sileo is entered in the dpkg database by `jailbreak.py` (what `dpkg -i` would write). apt points at `https://apt.procurs.us/ 2000 main` (the rootless suite for iOS 17/18).
* **Mach-O.** The Procursus, Sileo and TrollStore binaries are plain arm64 and run as they are; any arm64e slice goes through `pacstrip` and is re-signed ad hoc. The upstream signatures are ldid-style (macOS `codesign` cannot read or replace them), so the entitlement blob is parsed by `jailbreak.py`, the signature is cut off and the binary is signed ad hoc again with the same entitlements. TrollStore's three Mach-Os are re-signed this way, because its upstream signatures rely on the CoreTrust bug and carry a borrowed App Store identifier; this kernel accepts ad hoc.
* **TrollStore.** Installed the upstream way, on the phone, by `trollstorehelper install-trollstore` run as root over SSH (no persona spawn needed from our side), which creates the app container and registers the app; then `install-ldid` so TrollStore can sign IPAs. `/var/jb/usr/share/renegade-jb/postinstall.sh` does the on-device part (Procursus `prep_bootstrap.sh` minus the password prompt, Sileo and TrollStore registration) and is run by `live` over SSH, or, in image builds, by the first-boot job `org.bergamota.renegade-firstboot` (below), which runs it once after the apps are registered.
* **Remove.** `renegade jb remove` unregisters Sileo, runs `trollstorehelper uninstall-trollstore` and deletes `/var/jb`. Apps installed through TrollStore stay (they are user data).


## Root auto-fixes (what was done by hand on the phone, baked into the image)

`root_tweaks18.auto()` runs in the `tweaks` stage of `renegade root` and in `renegade update`. Every fix is on by default, has an opt-out, and skips itself when its prebuilt binary is missing (`--no-appreg`, `--no-posterboard`, `--no-bluetooth`, `--no-jb`, `--no-wallpaper`, or `RENEGADE_NO_<NAME>=1`). The on-device tools come from `tools/sweetnet/build.sh` (needs a Mac with Xcode; output in `research/sweetnet/`, iOS 18 builds in `research/sweetnet/ios18/` are arm64e and go through `pacstrip --sign`). If they are not built (always on Linux), the features that need them are skipped automatically and listed at the end; see Platforms.

| Fix | Function | What it does |
| --- | --- | --- |
| App registration | `staged_apps()`, `firstboot()` | Moves `/private/var/staged_system_apps/*.app` to `/Applications` (names kept in `/usr/local/share/renegade/register-apps`), installs `/usr/local/bin/sweetuicache` and the first-boot LaunchDaemon `org.bergamota.renegade-firstboot` (plist in `/System/Library/LaunchDaemons` plus the `launchd.plist` cache entry, like the dropbear job). The job runs `/usr/local/libexec/renegade-firstboot.sh` with `/bin/sh` (dash from the ssh tweak): `sweetuicache /Applications/NAME.app` per listed app, as root (the invocation of `tools/sweet-install-ipa.sh`; there is no other documented one), retrying the first app for up to 10 minutes because registration works only once lsd is up. It then runs the jailbreak post-install if `/var/jb` has one and disables itself with `/private/var/db/.renegade-firstboot-done` (also after 3 incomplete runs). Log: `/private/var/log/renegade-firstboot.log` |
| PosterBoard | `posterboard()` | Installs `/usr/local/lib/sweetfp.dylib` (`tools/sweetnet/sweetfp.m`: keeps NSURLFileProtectionKey in an xattr, since HFS+ has no protection classes and PosterBoard's store migration "from 59 to 61" fails otherwise), adds an `LC_LOAD_DYLIB` to `/Applications/PosterBoard.app/PosterBoard` with `tools/sweetnet/addlc.py` and re-signs it ad hoc keeping identifier `com.apple.PosterBoard`, flags and all entitlements (checked after the signing). The binary is only touched after the dylib is installed |
| Bluetooth | `bluetooth()` | `BT_HCI_TRANSPORT` in bluetoothd's launchd job, the BlueTool stub as `/usr/sbin/BlueTool` (original kept as `BlueTool.orig`), `/usr/local/bin/hcitest`. The ADT half (`/arm-io/bluetooth`, `tools/mkadt.py`) belongs to the boot image |
| Jailbreak | `jailbreak_userland()` | See the section above |

`renegade update` and the build record owners without sudo: `OwnerRecorder` replaces `os.chown`, and ignores the owner of the process, because the image is mounted `noowners` and every file shows as 501:20 (an older build wrote `launchd.plist` as 501:20 that way; `update` puts it back to 0:0).

**`sweetmetrics`** (`sweetmetrics()`, always, `RENEGADE_NO_METRICS=1` skips; also in `renegade update`): installs `/usr/local/bin/sweetmetrics` (`tools/sweetnet/sweetmetrics.c`, arm64e + `pacstrip --sign`, from `research/sweetnet/ios18/`), the read-only live-metrics JSON that Bergamota polls over SSH (`docs/BERGAMOTA_METRICS.md`). Skipped with a message when not built.

**Default wallpaper and icon style (`wallpaper`, `--no-wallpaper`).** Not written offline: the first-boot job sets them through the services once, as `mobile`. It installs `sweetposterset`, `sweeticonstyle`, `sweetopen` (`/usr/local/bin`) and `/Applications/SweetRun.app` (all `tools/sweetnet`, arm64e + `pacstrip --sign`, entitlements in `posterset.entitlements`, `iconstyle.entitlements` with `com.apple.sharesheet.allow-custom-view`, `sweetrun-app/run.entitlements`). After the app registration the job registers SweetRun, writes `/private/var/tmp/sweetrun.sh`, starts it with `sweetopen com.sweet.run` (retried until SpringBoard is up; the app runs in the mobile user's launchd domain, where PosterBoard's service is reachable) and waits for `/private/var/tmp/renegade-poster.rc`. The script runs `sweetposterset com.apple.GradientPoster.GradientPosterExtension darkBlue.preset1` (Gradient, no Metal; creates it and selects it as the lock poster, the home screen follows) up to 20 times 10 s apart, which also covers the `-2203` refusal while PosterBoard's store has no lock role yet, then `sweeticonstyle default` (not tinted). On success the job writes `/private/var/db/.renegade-poster-done`; otherwise it retries on the next boot (3 runs at most). If `-2203` never goes away, delete PosterBoard's data store folder while PosterBoard is not running; it regenerates. Tools that are re-signed on the device need new file names. `sweetposterset` is idempotent: it fetches the lock-role configurations and the selected poster first, answers "already selected" (exit 0) when that is the Gradient/darkBlue.preset1 poster, reuses an existing configuration of that provider/descriptor and creates one only if there is none, and decides success by fetching the selected poster again, not from the completion. The completion signatures were read from the 22H352 dyld cache: update-to-selected and delete complete with the NSError alone (the old `(id,id)` block read a stale register, which printed an os_log object), create and fetch with (result, NSError). `sweetposterset --cleanup PROVIDER DESCRIPTOR` deletes the other configurations of that provider/descriptor and keeps the selected one; the first-boot script runs it after a success. Not covered: `sweetwallpaper` (photo wallpaper) and `ps2.m`, which stay in the scratchpad.

## `renegade update`

```
tools/sweetnet/build.sh                              # optional, Mac only: sweetuicache, sweetfp.dylib, BlueTool stub, hcitest (skipped when missing)
renegade update research/ios18/ios18-root-full.simg [--no-jb] [--no-appreg] [--no-posterboard] [--no-bluetooth] [--check]
```

`simg2img --consume` (the simg is eaten while the raw image is written) -> `hdiutil attach` read-write, no sudo (Linux: loop device + `mount -t hfsplus`, root) -> the tweak functions (idempotent) -> detach -> `hfs_trim` -> `hfsroot_owners` for the new paths only (everything created since the start, plus the paths chowned on purpose) -> `fsck_hfs -fn` (Linux: `fsck.hfsplus -f -n`) -> `img2simg --consume` back to the `.simg`. Every step checks `df` and stops below 5 GiB free; the preflight (read only, via `hfsx.py`) checks the files the tweaks need, the built tools and, for the jailbreak payload, downloads and stages it before anything is consumed. `--check` stops after the preflight.

If it fails after the simg was consumed, the raw `IMAGE.img` is left next to the zeroed `IMAGE.simg` shell, detached. Fix the cause and run `renegade update IMAGE.img`: it starts at the attach step and writes `IMAGE.simg` at the end. Do not delete the `.img`.

**cryptexd (opt-in fallback).** `--disable-cryptexd` / `RENEGADE_DISABLE_CRYPTEXD=1` (off by default, in `renegade root` and `renegade update`) removes the `com.apple.security.cryptexd` job from the `launchd.plist` cache and moves `/System/Library/LaunchDaemons/com.apple.security.cryptexd.plist` to `*.renegade-disabled`. The real fix is stubbing the trap itself (branch `cryptexd`).
