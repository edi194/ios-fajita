# SSH over the USB link

Key-only SSH into the phone at `192.168.7.2` over the USB CDC-ECM link, using standard upstream
software built for iOS 16 (arm64): **dropbear** (SSH server, `dropbearkey`, `scp`), **dash**
(`/bin/sh`; stock iOS has no shell) and **toybox** (coreutils-style commands). Nothing here is
custom network code. The binaries are built on the Mac (`tools/ssh/build.sh`) and copied into the
root image by `tools/sweet-root-tweaks.py`.

## Versions and checksums

Sources live in `research/ssh-build/dl/<name>/` (gitignored) and are unpacked to
`research/ssh-build/src/<name>/`.

| Tool | Version | Source | SHA-256 of the tarball | Verification |
| --- | --- | --- | --- | --- |
| dropbear | 2026.94 | matt.ucc.asn.au/dropbear/releases/ | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` | GPG detached signature good (key F734 7EF2 EE2E 07A2 6762 8CA9 4493 1494 F29C 6773, "Dropbear SSH Release Signing", from `dropbear-key-2015.asc` on the same site; the key itself is not independently certified) and the hash matches the signed `SHA256SUM.asc` |
| dash | 0.5.13.5 | gondor.apana.org.au/~herbert/dash/files/ | `40090101a2a491f13e901d3d48e90414f26634628b9bfff35ff540363c227a7d` (SHA-512 `ae326c11...c94dd`) | SHA-512 matches the published `.sha512sum` (its PGP signature was not checked: no key) |
| toybox | 0.8.15 (2026-10-06) | landley.net/toybox/downloads/ | `44e2bab43dfe2c171743297631ce558c6d9ed38b87a66fd751cef617574b375e` | none published: the hash is what was downloaded (trust on first use) |

## What is built and how

```sh
brew install gnu-sed          # toybox's build scripts do not work with macOS's BSD sed
tools/ssh/build.sh            # iOS builds + macOS test builds, signed; output in research/ssh-build/out/
```

`build.sh` configures each tool twice, once for `arm64-apple-ios16.0` (iPhoneOS SDK, `-miphoneos-version-min=16.0`,
`minos 16.0`) and once for the Mac, from the same configuration. Files in `tools/ssh/`: `localoptions.h`,
`entitlements.plist`, `toybox.config`, `ios-cc.sh`, the two patches, `build.sh`.

### dropbear (multi-call: `dropbear`, `dropbearkey`, `scp`)

Configured with `--disable-zlib --disable-lastlog --disable-utmp --disable-utmpx --disable-wtmp
--disable-wtmpx --disable-pututline --disable-pututxline --disable-pam --enable-bundled-libtom`, built with
`make PROGRAMS="dropbear dropbearkey scp" MULTI=1`. **No source patch was needed.** `tools/ssh/localoptions.h`:

- `DROPBEAR_SVR_PASSWORD_AUTH 0` (and `-s` on the command line), `DROPBEAR_SVR_PUBKEY_AUTH 1`
- `DROPBEAR_ED25519 1`, `DROPBEAR_ECDSA 1`
- `DROPBEAR_X11FWD 0`, `DROPBEAR_SVR_AGENTFWD 0`, `DROPBEAR_CLI_AGENTFWD 0`, no SFTP server, no PAM, no MOTD
- `DROPBEAR_SVR_DROP_PRIVS 0` (needs `setresgid`, missing on Darwin) which in turn forces
  `DROPBEAR_SVR_LOCALSTREAMFWD 0` / `REMOTESTREAMFWD 0` (unix-socket forwarding; TCP forwarding stays)
- `DEFAULT_PATH` / `DEFAULT_ROOT_PATH` = `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`

Login shell: dropbear has no shell override option. It uses root's `pw_shell` from `/etc/passwd`, and
`getusershell()` must find it in `/etc/shells` (iOS may not ship that file, so the install step adds `/bin/sh`).
Default port is 22 (the launchd job passes `192.168.7.2:22` explicitly).

### dash (`/bin/sh`)

Cross-compiled with `CC_FOR_BUILD=clang` for the host helper programs (mkinit, mknodes, ...), `--without-libedit`.
**Patch `tools/ssh/dash-ios-strchrnul.patch`**: the iOS 27 SDK declares `strchrnul()` as iOS 18.4+, so dash would
have linked a symbol iOS 16 does not have. With `ac_cv_func_strchrnul=no` dash uses its own copy, renamed to
`dash_strchrnul` to avoid clashing with the SDK declaration.

### toybox

Starts from `make macos_defconfig` plus `dd diff tr sync gzip gunzip printenv` (136 applets in the final build;
`tools/ssh/toybox.config` is the final `.config`). All requested commands are in except **`ps`**:
`ps`, `pgrep`, `pkill`, `top`, `uptime` need Linux `/proc` and `sysinfo()`, do not compile on Darwin, and were
dropped (`readahead` too: no `posix_fadvise`). `kill`, `killall5`, `who`, `w`, `df`, `du` are present. List with
`toybox`. **Patch `tools/ssh/toybox-ios-sys-disk.patch`**: the iPhoneOS SDK has no `<sys/disk.h>`; the two
`DKIOC*` ioctl numbers are defined inline (same values as macOS). The macOS build needs no patch.
Toybox is licensed 0BSD, dash BSD, dropbear MIT-style.

### Signing and entitlements

Each iOS binary is signed ad hoc with `codesign --force -s - --entitlements tools/ssh/entitlements.plist`.
The XNU AMFI stand-in treats every code-signed binary on the root volume as a platform binary and grants the
entitlements in its signature. Entitlements:

| Key | Why |
| --- | --- |
| `platform-application` | Marks the binary as a platform application so the platform-binary checks pass |
| `com.apple.private.security.no-container` | No app container is created or applied to the process |
| `com.apple.private.security.no-sandbox` | No sandbox profile: needed to read `/var/root/.ssh`, open ptys, exec shells, and let toybox touch the whole filesystem |
| `com.apple.private.skip-library-validation` | Library validation is skipped, so signed-by-us binaries may load system dylibs regardless of team ID |

Verify: `file research/ssh-build/out/{dropbear,dash,toybox}` (Mach-O 64-bit executable arm64) and
`codesign -dvv --entitlements - research/ssh-build/out/dropbear` (adhoc, four keys listed).
**Not run on the phone** (no phone access in this task): whether iOS 16 accepts these signatures at exec is
untested on hardware.

## Install into the root image

`tools/sweet-root-tweaks.py` has an `ssh(root)` step (idempotent, skipped with a message if the binaries are not
built or the Mac has no public key). It:

- copies `dropbear` and `toybox` to `<root>/usr/local/bin`, symlinks `dropbearkey`, `scp` -> `dropbear` and each
  toybox applet -> `toybox`; copies dash to `<root>/bin/sh`
- adds `/bin/sh` to `<root>/private/etc/shells` if missing
- writes `<root>/private/var/root/.ssh/authorized_keys` (0600, dir 0700, root) from the Mac user's
  `~/.ssh/id_ed25519.pub` (else the first other `*.pub`, never a private key; uses `SUDO_USER`'s home)
- generates host keys (ed25519 and ecdsa) with the macOS build of the same dropbear into
  `<root>/private/etc/dropbear/` (0600; existing keys are kept so the fingerprint stays stable)
- installs the launchd job `org.sweet.dropbear` as `<root>/System/Library/LaunchDaemons/org.sweet.dropbear.plist`
  and in `launchd.plist` `LaunchDaemons` under the same path key: `/usr/local/bin/dropbear -F -E -s -p
  192.168.7.2:22 -r /private/etc/dropbear/dropbear_ed25519_host_key`, `RunAtLoad`, `KeepAlive`, user root, stderr
  to `/dev/console`. (The ecdsa key is generated but only used if you add a second `-r`.)
- warns if root's `/private/etc/passwd` entry is not `...:/var/root:/bin/sh` (stock iPhone iOS has
  `root:*:0:0:System Administrator:/var/root:/bin/sh`; **not checked** in the image here, the root image was not
  mounted for this task. `*` as password is fine for key auth.)

Rebuild the root image with it (mounted root, as in `tools/mkiosroot-macos.sh`; the usual flow):

```sh
brew install gnu-sed && tools/ssh/build.sh
sudo tools/mkiosroot-macos.sh OS.dmg SystemOS.dmg AppOS.dmg ios16-root.img 20g   # it runs sweet-root-tweaks.py
# or on an existing mounted root:  sudo tools/sweet-root-tweaks.py /Volumes/<mounted root>
python3 tools/img2simg.py ios16-root.img ios16-root.simg && fastboot -S 512M flash userdata ios16-root.simg
```

Order matters: `build.sh` first (the install step reads `research/ssh-build/out/`), and `sudo` keeps the root
ownership (sshd-style checks on `.ssh` need root-owned, non-group-writable files).

## Usage

The Mac side of the link is `tools/sweet-usbnet.sh` (192.168.7.1/24):

```sh
ssh root@192.168.7.2            # first connection asks to trust the host key
scp file root@192.168.7.2:/var/root/
ssh root@192.168.7.2 'ls /var/root'
```

If the Mac has several keys, add `-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes`. Fingerprints of the host keys:
`ssh-keygen -lf <root>/private/etc/dropbear/dropbear_ed25519_host_key.pub`.

Boot timing: launchd may start dropbear before `ue0` has 192.168.7.2 (the address is set by the kernel when the
USB gadget enumerates, which can be later). `bind()` then fails, dropbear exits and `KeepAlive` restarts it
(launchd throttles to about every 10 s) until the address exists. Look for `Failed listening on ...` on the console.

## Security model

- Public-key only: `-s` and `DROPBEAR_SVR_PASSWORD_AUTH 0`; the only authorised key is the Mac user's public key.
  Root login is allowed (root is the only account that matters on this phone).
- Reachable only on 192.168.7.2:22, i.e. the USB Ethernet link to the machine that is plugged in; not bound to
  `0.0.0.0`. Anyone who can get onto that link (a host that has 192.168.7.1) can attempt auth but cannot log in
  without the private key. If the phone later gets other interfaces (Wi-Fi), they are not exposed by this job.
- Runs unsandboxed as root with platform-binary status; the machine holding the key has full control of the phone.
  There is no iOS security model left to protect on this port (AMFI is a stand-in, no SEP), so this is acceptable
  for a bring-up phone but is not hardening.
- No agent/X11/unix-socket forwarding; TCP forwarding is still enabled (disable with `-j -k` in the job if wanted).

## Tested

On macOS (arm64), with the macOS builds from the same sources and `localoptions.h`:

- dropbear: server on `127.0.0.1:2222` with a test ed25519 host key (`-s -F -E -r KEY -D DIR`), authorized key in
  `DIR/authorized_keys`: `ssh -i` with the matching key runs a command; a different key gets
  `Permission denied (publickey)`; the server offers only `publickey` (no password method). The test key and logs
  are in `research/ssh-build/test/` (throwaway). `dropbearkey` generated ed25519 and ecdsa keys.
- dash: `dash -c 'echo ok'` and a script on stdin with a for loop.
- toybox: `ls cp mv ln sed grep find wc tar stat date df du which env head tail chmod chown kill sleep touch rm`.
- The install step against a fake root directory (as non-root, chown stubbed): files, links, modes, shells,
  authorized_keys, host keys, both plists (`plutil -lint`), second run idempotent.

Not tested: anything on iOS or the phone (exec of the signed binaries, the `getusershell`/`/etc/shells` behaviour
on the real image, `openpty` and `/dev/ttys*` under our kernel, pty-based login, binding 192.168.7.2 at boot, `scp`
on the device); the dash `strchrnul` patch path (the macOS dash uses libc's); toybox `ps`/`top` (dropped).
The iOS builds were checked for `minos 16.0` and for undefined symbols that need a newer OS (none left after the
two patches); that is static analysis only.
