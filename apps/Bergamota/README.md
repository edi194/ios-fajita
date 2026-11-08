# Bergamota

A native macOS (26+) SwiftUI control panel for the iOS-on-Poco-F1 project: phone status, live kernel log, CI runs, and a boot queue that schedules `fastboot boot` (and, behind a typed confirmation, flashes of userdata, boot and logo, through Bergamota fastboot with ABL fastboot as the fallback).
No third-party packages. The app is **not sandboxed** (it runs `fastboot`, `adb`, `ssh`, `gh` and `python3`) and is ad-hoc signed ("Sign to Run Locally").

## Build

```sh
open apps/Bergamota/Bergamota.xcodeproj          # then Run in Xcode
# or
cd apps/Bergamota && xcodebuild -scheme Bergamota -configuration Debug build
```

The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen && xcodegen generate`); both `project.yml` and the generated `Bergamota.xcodeproj` are committed. The app icon is an Icon Composer document, `Bergamota/Bergamota.icon` (macOS 26 Liquid Glass: Default, Dark, Clear and Tinted; Xcode also writes a legacy `Bergamota.icns` for older macOS). Its layers are rendered by `tools/identity/mkicon.sh` from the Bergamota identity (`tools/identity/IDENTITY.md`); the composition is the bundle's `icon.json` (edit it in Icon Composer or by hand, then check the six renditions the script writes to `tools/identity/out/`).

## Usage

Look: the Bergamota identity (`tools/identity/IDENTITY.md`): paper work area (ink in dark appearance), Archivo for page titles and state words, JetBrains Mono for values and logs (both bundled from `tools/identity/fonts`, loaded through CoreText), leaf green for primary actions, alert red for anything that writes the phone. The design record is `DESIGN.md`; product facts `PRODUCT.md`.

**Phone rail** (the window's inspector column, toolbar button *Phone*): on every page, a lime halftone stage with the phone's state, what the app is doing right now (the activity banner text, with progress), Newton, and at his feet the ink console with the queue's next three items, Start/Stop and Send now. A state change steps the word in and leaves an ink mark under it until you next bring the window forward.

Sidebar sections:

- **Dashboard**: polls every 2 s and shows one of fastboot (`fastboot devices`), OrangeFox/recovery (`adb devices`), iOS (USB Ethernet MAC `02:00:5e:77:ee:01` up in `ifconfig -a`, ping of the phone IP, TCP 22 open), Android (adb `device`), or offline. When iOS is up it SSHes as `root@192.168.7.2` (`BatchMode=yes`, `ConnectTimeout=3`, your normal `known_hosts`) every ~10 s for `uname -a`, `kern.boottime` and `/usr/local/bin/sweetps` (battery %, charging, power source). It also shows the Mac's `net.inet.ip.forwarding` (read only; enable NAT with `tools/sweet-mac-nat.sh`). While iOS is up the iOS card has a **Reboot to ABL fastboot** and **Reboot to Bergamota fastboot** buttons (confirmation dialogs): it runs `/usr/local/bin/sweetreboot fastboot` over SSH (see *Reboot to fastboot* below).
- **Live Log**: listens on UDP 5140 for the phone's kernel console (same stream as `tools/sweet-usbnet.sh`; quit that script first, only one listener can bind). Ring buffer of 300k lines, UI updates batched every 100 ms, search box, filter chips (SWEET USB / GPU / WLAN / FB / CRASH), follow/pause, copy. "Record to logs/" appends every incoming line to `logs/usb-<timestamp>.txt` in the repo; "Save buffer" dumps the whole buffer there.
- **CI**: `gh run list` for `xnu.yml` on `main`, `ios18`, `ci-cache` (status, branch, sha, age, duration). "Download kernel" runs `gh run download <id> -n xnu-kernel -D xnu/out-<branch>-<id>` in the repo (needs `gh auth login`).
- **Boot Queue**
  - *Build*: pick a kernel (`xnu/out-*/kernel.development.sweet`), an ADT (`enxerto/out/*.adt` or the older `shim/out/*.adt`, default `beryllium-hi-3x.adt`), a cmdline (presets in `~/Library/Application Support/Bergamota/presets.json`, seeded with "default @3x", "bluetooth test", "ios18 poc") and an image name. It runs `tools/mkpayload.py`, then `BOARD=beryllium ./build.sh` in `enxerto/`, then copies `enxerto/out/enxerto-boot.img` to `enxerto/out/enxerto-boot-<name>.img` (`shim/` names in a pre-rebrand checkout), streaming the output.
  - *Images*: lists `enxerto/out/*.img` and `shim/out/*.img`; add any to the queue.
  - *Queue*: press **Start** to arm. When the phone is in fastboot (seen on two consecutive polls) the app sends exactly **one** `fastboot boot <img>`, records the result and time, and will not send again until the phone has left fastboot (a failed send leaves ABL hung; re-enter fastboot yourself, there is never an automatic retry). After a send the next item re-arms as soon as the phone is seen outside fastboot for one poll, or when the fastboot device re-enumerates on USB (best-effort `ioreg -p IOUSB` registry id/sessionID/locationID change), because a bad image can leave ABL sitting in fastboot. The first pending item also has a **Send now** button (only while the phone is in fastboot, with a confirmation: sending again after a hung ABL can hang it further, so press it only after re-entering fastboot). Images over 64 MiB get a yellow warning (only when the target is ABL fastboot, see below) ("large boot image: ABL may not start it") in the queue, the image list and after a build; they are not blocked. Optional toggle (off by default): when the phone is in OrangeFox, run `adb reboot bootloader` once first. The queue disarms itself when it is empty. Optional notifications when a boot is sent and when iOS comes up. **Auto-reboot into fastboot** (Settings, default on): see below; the queue header shows a green "auto-reboot to fastboot on" badge and its current state (or an orange "manual fastboot needed" badge).
- **Settings** (also Cmd+,): repo path (default `/Users/zesmoi/git/iAndroid/ios-beryllium`), phone IP, GitHub repo, and tool paths (`fastboot`, `adb`, `gh`, `python3`, `ssh`; empty means resolve via `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`).

## Design preview

`Bergamota.app/Contents/MacOS/Bergamota -designPreview ios|bergamota|offline [-designSection performance] [-designAppearance light|dark] [-designSnapshot DIR]` runs the interface on sample states, isolated from the real app (no polling, no UDP listener, no inbox, a temporary queue file), so it can run next to the real Bergamota. `-designSnapshot` writes each window to DIR as PNG and quits (the glass sidebar does not draw in those; use `screencapture -l` for a full capture).

## Live device metrics

While iOS is up the app runs `/usr/local/bin/sweetmetrics` over SSH every ~2 s (its own loop, never on the main thread) and shows it on the **Performance** page (sidebar) (CPU clusters with frequency bar, load and mode, GPU state/MHz/busy, a renderer badge that reflects whether backboardd really holds the GPU user client, battery draw) and a compact strip in the Control Plane, with ~2 minute sparklines (CPU kHz per cluster, GPU MHz, battery mA). Values the kernel does not expose yet show as unknown. The values are in `status.json` `phone.metrics`; `scripts/bergamota metrics [--json]` prints them. Contract, sources and what waits on the kernel: `docs/BERGAMOTA_METRICS.md`. The tool comes from `tools/sweetnet/build.sh` and Renegade installs it into the root. Parser tests: `apps/Bergamota/Tests/run-metrics-tests.sh`.

## Activity banner and Control Plane

The **activity banner** text heads the phone rail on every page (and fills the top of the Control Plane): BUILDING <name>, WAITING FOR FASTBOOT, SENDING <label>, BOOTING <label> with elapsed time (right after a send the phone vanishes from USB while the shim/kernel boots, so Offline is not shown; ends when iOS is up or after 5 minutes, and says STILL IN FASTBOOT if the phone is still in fastboot 20 s after the send), iOS UP, IN ORANGEFOX, OFFLINE, INSTALLING <app>, UPLOADING <n> FILES. Kernel log hints: the last `SWEET` line while booting, and a `panic(` line turns it into a red PANIC.

**Control Plane** (toolbar button, Window > Control Plane, Shift+Cmd+C, or Settings > "Open at launch" / `--args -openControlPlane YES`): a separate dark, large-type window for a second display with the banner, phone state, battery, last boot result, the queue (with Send now), the latest CI run per branch, a filterable 15-line live-log tail and quick buttons (Reboot to fastboot when available, Send now, Stop). Its *Display* menu moves it to another screen and can make it full screen; the window frame, screen and full-screen choice are remembered.

## Apps (sideloading) and Media

- **Apps**: drop or pick an `.ipa` to run `tools/sweet-install-ipa.sh` (unzip, reject FairPlay-encrypted binaries, ad-hoc re-sign, copy to /Applications over SSH, register) with live output. The installed list (`ls /Applications` over SSH) marks sideloaded apps (recorded in `~/Library/Application Support/Bergamota/sideloaded.json`), third-party guesses (no `com.apple.` in Info.plist) and system apps; Uninstall (`sweet-install-ipa.sh -u`) is offered only for the first two.
- **Media**: drop images/videos/files. Camera Roll mode sends images through `tools/sweet-push-photo.sh` (JPEG into DCIM/100APPLE) and videos as `VID_*` into DCIM/100APPLE; "Phone folder" mode (default `/private/var/mobile/Media/Downloads`) and any other file use `scp`. Folders are limited to `/private/var/mobile/`, `/var/mobile/`, `/private/var/tmp/`, `/tmp/`. Photos may need a relaunch or reboot to show new pictures.
- All SSH goes through `root@<phone IP>` with `BatchMode=yes`, `ConnectTimeout=3` and `UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts_ios26` (each root image has its own host key; the repo scripts run with ssh/scp wrappers that add them), and every action is disabled with a message unless iOS is up.
- Inbox kinds: `{"kind":"install_ipa","path":"/abs/App.ipa"}` and `{"kind":"upload","paths":["/abs/a.png"],"dest":"photos"|"/private/var/mobile/Media/Downloads"}`. CLI: `scripts/bergamota install IPA`, `scripts/bergamota upload [--dest photos|/folder] FILE...`. `status.json` has an `activity` entry with the banner text.

## Remote control (file-based API, no network)

Bergamota watches `~/Library/Application Support/Bergamota/inbox/` for `*.json` requests (polled every second), processes them and moves each to `inbox/done/` (with a `result` field) or `inbox/failed/` (with an `error` field). Kinds:

```json
{"kind":"enqueue","image":"enxerto/out/x.img","label":"...","arm":true}
{"kind":"build","name":"N","kernel":"xnu/out-.../kernel.development.sweet","adt":"enxerto/out/beryllium-hi-3x.adt","preset":"default @3x","enqueue":true,"arm":true}
{"kind":"build","name":"N","kernel":"...","adt":"...","cmdline":"debug=0xc ..."}
{"kind":"orangefox_reboot","enabled":true}
{"kind":"send_now"}
{"kind":"reboot","to":"fastboot"}          // or "bergamota" / "recovery"; only while iOS is up
{"kind":"enter_bergamota"}                // ABL fastboot -> Bergamota fastboot
{"kind":"stop"}
```

Paths are absolute or repo-relative; images and ADTs must live under `enxerto/out/` (or `shim/out/`) (`.img` / `.adt`), kernels under `xnu/`. `"arm": true` only arms the queue when Settings > "Allow remote requests to start the queue" is on (default on; the Boot Queue header shows a "remote control on" badge). Otherwise items are added and you press Start. The one-`fastboot boot`-per-fastboot-appearance rule applies unchanged. `send_now` sends the next pending item immediately; it is refused unless the phone is in fastboot and remote start is allowed.

`status.json` (same folder) is rewritten atomically on every state change and at least every 5 s: `phone` (state, `ios` battery/charging/kernel/uptime when known), `queue` (armed, `autoRebootToFastboot`, `autoRebootStatus`, items with `state` pending|waiting|sent|failed, `sentAt`, `result`, `needsManualFastboot`), `liveLog` (listening, `savingTo`), `build`.

CLI (`scripts/bergamota`, bash + python3):

```sh
scripts/bergamota enqueue enxerto/out/enxerto-boot-0160.img [--label L] [--no-arm] [--wait]
scripts/bergamota build --name N --kernel K --adt A (--preset P | --cmdline C) [--no-enqueue] [--no-arm] [--wait]
scripts/bergamota orangefox on|off
scripts/bergamota reboot fastboot|bergamota|recovery [--wait]
scripts/bergamota enter-bergamota [--wait]
scripts/bergamota stop
scripts/bergamota status
```

## Flashing (userdata, boot, logo): Bergamota fastboot first

The app otherwise never flashes. The only partitions it can write are **`userdata`** (the iOS root), **`boot`** (Enxerto's boot.img) and **`logo`** (splash): a hard allowlist in code (`UserdataFlash.partitions`, enforced in both argument builders), repeated inside Enxerto itself. There is no free partition field; `erase`/`format` are never run by the app.

**Main route: Bergamota fastboot** (Enxerto writes the phone's UFS itself, see `docs/BERGAMOTA_FASTBOOT.md`). The app runs `python3 tools/bergamota-flash.py -s bergamota0001 --fastboot <fastboot> flash <partition> <image> --delta|--full` (python3 stdlib only; `UserdataFlash.bergamotaFlashArguments`). Userdata defaults to **delta**: the tool reads per-block hashes of the phone's real contents, hashes the new image (raw or sparse, streamed), builds a sparse image with only the changed blocks and sends it with `fastboot -S 512M flash`, then verifies by hashing the phone again. boot and logo are always sent in full. The script is found at Settings > Boot queue > `tools/bergamota-flash.py` (empty = `tools/` of the repo path, then sibling worktrees); missing = Bergamota flashing is unavailable and ABL is used.

**Fallback: ABL fastboot** (`fastboot -s <serial> -S 512M flash <partition> <img>`, `UserdataFlash.flashArguments`), used when the route is `abl`, or `auto` and Bergamota fastboot cannot be reached or the tool is missing (the fallback is written in the item/flash output).

How the route is chosen (setting **Flash route**, per-item/request `via`, CLI `--via`): `auto` (default) = Bergamota fastboot with ABL fallback; `abl` = ABL only; `bergamota` = Bergamota fastboot or fail. Phone already in Bergamota fastboot: flash there. Phone in ABL fastboot: the app runs the existing "Enter Bergamota fastboot" (`fastboot boot bergamota-fastboot-flash.img`, searched next to the configured Bergamota image, in `shim/out/` and `enxerto/out/`; otherwise the configured image), waits up to 60 s for the re-enumeration and flashes there; if that fails, `auto` flashes through ABL. Phone in iOS with a flash item queued: the auto-reboot uses `sweetreboot bergamota` (ABL fastboot only if that fails and the route is not `bergamota`). `then boot` items boot from the same Bergamota fastboot session.

Guards:

- Image: an existing `.img`/`.simg` (userdata at least 64 MiB; boot is an Android boot image of 1-64 MiB; logo 1-32 MiB). Picker, drop, path field or presets.
- Explicit confirmation per flash: Boot Queue > **Flash** tab or Control Plane **Flash userdata** (any fastboot kind); a sheet says it replaces the iOS install, shows name, size, SHA-256, route and mode (both changeable there) and enables the button only after you type the partition name (`userdata`). The CLI/inbox adds `confirm` itself / requires it.
- One flash, no retries. The activity banner shows the phases `READING THE PHONE`, `COMPARING WITH THE PHONE`, `FLASHING USERDATA n%` (MB/s and ETA over the delta bytes) and `VERIFYING`, fed by the tool's `PROGRESS`/`DELTA`/`RESULT` lines (ABL route: `Sending sparse n/m` as before), then `FLASHED` or `FAILED`. While flashing the queue sends nothing and auto-reboot is not started. After a manual flash the queue stays latched until the phone leaves fastboot.
- Queue items may carry a flash: `flash userdata X, then boot Y` flashes first, then exactly one `fastboot boot` (a failed flash skips the boot). The boot image is optional. Stored in `queue.json` (`userdataImage`, `flashPartition`, `flashVia`, `flashMode`).
- Inbox: `{"kind":"flash_userdata","path":"<img>","partition":"userdata","then_boot":"enxerto/out/x.img","mode":"delta|full","via":"auto|abl|bergamota","label":"...","confirm":"userdata","arm":true}`. `confirm` must equal the partition, `mode`/`via` are validated and optional (defaults from Settings), otherwise the request is rejected (`inbox/failed`, `lastRequest`). It only enqueues. CLI: `scripts/bergamota flash-userdata IMG [--partition userdata|boot|logo] [--then-boot BOOTIMG] [--full|--delta] [--via abl|bergamota] [--label L] [--no-arm] [--wait]`.
- `status.json` `flash`: `active`, `file`, `partition`, `route` (`bergamota`/`abl`), `mode` (`delta`/`full`), `phase`, `phaseDoneBytes`, `phaseTotalBytes`, `deltaBytes`, `imageBytes`, `progress`, `last`; queue items carry `flashUserdata`, `flashPartition`, `flashVia`, `flashMode`.

## Reboot to fastboot

Needs the Poco F1 kernel with patch 0137 and `/usr/local/bin/sweetreboot` on the phone (new root images get it from `tools/sweet-root-tweaks.py`; for a running phone, `scp research/sweetnet/sweetreboot root@192.168.7.2:/usr/local/bin/sweetreboot`, built by `tools/sweetnet/build.sh`; details in `docs/REBOOT_MODE.md`). The button and the `reboot` inbox request run `ssh root@<phone> /usr/local/bin/sweetreboot fastboot|recovery`; the SSH connection dies with the phone, so success is judged by the tool's "next reboot mode" line.

**Auto-reboot** (Settings > Boot queue > "Auto-reboot iOS into fastboot when a queued image is waiting", default **on**): applies only when the queue is armed, the next item is pending, the phone has been in iOS for at least 30 s, and at most once per queue item. 90 s after the command, if the phone is not in fastboot, the item is marked **needs manual fastboot** (shown in the queue header and on the item, `needsManualFastboot` in status.json) and auto-rebooting pauses until fastboot is seen, the queue is re-armed (Start) or the toggle is cycled. A missing `sweetreboot` on the phone gives the same state at once. Once in fastboot, the usual one-`fastboot boot`-per-appearance rule takes over.

## ABL fastboot vs Bergamota fastboot

The phone can be in two different fastboots, and the app tells them apart (state **ABL FASTBOOT**, orange, bolt icon vs. **BERGAMOTA FASTBOOT**, lime green, leaf icon; banner, Dashboard, Control Plane tile and `status.json` `phone.state` = `fastboot` / `bergamota-fastboot`, plus `phone.fastbootKind` = `abl` / `bergamota`).

| | ABL fastboot | Bergamota fastboot |
|---|---|---|
| What it is | Qualcomm ABL (bootloader) | Enxerto, our bootloader, speaks fastboot itself |
| Serial (`fastboot devices`) | the phone's real serial (e.g. `9ce49433`) | `bergamota0001` |
| `getvar version-bootloader` | ABL's own version | `bergamota-1` (`getvar bergamota` = 1) |
| Max download | ~64 MiB images are unreliable (large-image warning) | ~1 GiB (no warning) |
| `fastboot boot` | yes | yes |
| flash (`userdata`, `boot`, `logo` only) | yes (fallback route) | **yes, the main route** (own UFS driver, delta hashing via `oem hash`) |

How the app tells them apart: serial starting with `bergamota`, or (once per appearance, read-only) `getvar version-bootloader` starting with `bergamota`.

Getting into each:

- **ABL fastboot**: hold Power + Volume Down, or from iOS **Reboot to ABL fastboot** (`sweetreboot fastboot`).
- **Bergamota fastboot from ABL**: **Enter Bergamota fastboot** (Dashboard card, Control Plane; only shown in ABL fastboot) runs `fastboot -s <serial> boot <bergamota-fastboot.img>`. The image path is in Settings > Boot queue (default `/Users/zesmoi/git/iAndroid/ios-beryllium-ios18/enxerto/out/bergamota-fastboot.img`); a missing file gives a message and nothing runs.
- **Bergamota fastboot from iOS**: **Reboot to Bergamota fastboot** (`sweetreboot bergamota` over SSH; kernel patch 0140 writes IMEM `restart_reason` = `BERG` and PON reason 0 so ABL boots the shim, which enters its fastboot; see `docs/REBOOT_MODE.md`).

The queue sends one `fastboot boot` per fastboot appearance to either kind. Settings > Boot queue > **Prefer Bergamota fastboot for the auto-reboot** (default on) makes the auto-reboot of queued boots use `sweetreboot bergamota`; if the phone's `sweetreboot` does not list `bergamota` (checked over SSH while iOS is up) it is not tried, and if it fails (old kernel/tool) the app falls back to `sweetreboot fastboot` (ABL). The 64 MiB large-image warning is shown only when the target is ABL fastboot (the phone is in ABL fastboot, or the target is not known to be Bergamota). Flashing (Boot Queue > Flash, Control Plane) is offered in both fastboots.

Inbox kinds: `{"kind":"reboot","to":"bergamota"}` (iOS up) and `{"kind":"enter_bergamota"}` (ABL fastboot). CLI: `scripts/bergamota reboot bergamota [--wait]`, `scripts/bergamota enter-bergamota [--wait]`.

## Notes

- **Local Network permission.** Without it macOS hides every MAC address from the app (`ifconfig` shows `02:00:00:00:00:00`) and blocks connections to the phone ("No route to host"). Bergamota declares `NSLocalNetworkUsageDescription` so macOS asks on first run; allow it under System Settings > Privacy & Security > Local Network. Until then the USB Ethernet interface is found by subnet (the Mac side `192.168.7.1`) and the Dashboard shows a warning. A debug trace of each detection change is written to `~/Library/Logs/Bergamota.log`.
- The live log is saved automatically to `logs/usb-<timestamp>.txt` (Settings > Live log; turning Record off in the Live Log pauses it until the next launch).
- The phone has no `sysctl`, so uptime is shown only if `ps -o etime= -p 1` is sane; the Dashboard also shows when Bergamota first saw iOS up.

The app only ever runs `fastboot devices`, `fastboot boot`, the confirmed flashes above (`fastboot flash` of userdata/boot/logo directly, or through `tools/bergamota-flash.py`, which also sends Bergamota fastboot's read-only `oem hash`/`getvar`/`upload` commands), plus `adb devices`, (opt-in) `adb reboot bootloader` `fastboot boot` of the Bergamota fastboot image (Enter Bergamota fastboot) and, over SSH, `sweetreboot fastboot|bergamota|recovery` (button, inbox request, auto-reboot). It never writes any other partition, and the app itself never erases or formats.
