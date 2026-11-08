# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS SwiftUI app (no web views). The deployment target may be raised to macOS 26 (user, 2026-10-26) so Liquid Glass and the macOS 26 SwiftUI APIs can be used directly; only the user's Mac runs it.

## Users

- **The project's owner, on their own Mac**, while porting iOS 26 to a Poco F1 (SDM845). They watch the phone's state, queue boots, flash partitions, read the kernel log and check metrics, often for hours while the phone reboots in cycles.
- **Agents (Claude sessions) through the CLI** `scripts/bergamota` and the file inbox (`~/Library/Application Support/Bergamota/inbox/`). They enqueue boots, builds and flashes; the app executes them and shows what they are doing. The human mostly watches and approves.

## Product Purpose

The single control panel between the Mac and the phone: know at a glance what state the phone is in (offline, ABL fastboot, Bergamota fastboot, OrangeFox, iOS booting, iOS up), and get exactly one correct action through (one `fastboot boot` per fastboot appearance, typed-confirmation flashes of only `userdata`, `boot`, `logo`). Success = the user never has to guess the phone's state, never sends a second boot into a hung ABL, never flashes the wrong partition.

## Positioning

It drives a phone that runs a bootloader (Enxerto, "Bergamota fastboot") and a kernel written in this repository: it knows the project's own states (Bergamota vs ABL fastboot, the BERG reboot reason, sweetreboot, sweetmetrics, the UDP 5140 kernel console) and the project's safety rules. No generic device tool knows these.

## Operating Context

- Sections: Dashboard (state, detection, Mac side, fastboot actions, performance metrics, iOS device card), Live Log (UDP 5140 kernel console, 300k-line ring, tag filters SWEET USB/GPU/WLAN/FB/CRASH, record/save), CI (`gh run list` of xnu.yml, kernel download), Boot Queue (Queue / Images / Build / Flash tabs), Apps (IPA sideloading), Media (photos/files to the phone), Settings.
- Control Plane: a separate large-type window (Shift+Cmd+C) with banner, tiles, metrics strip, queue, CI, log tail and big action buttons. The user does not currently use it on a second display.
- The activity banner (BUILDING, WAITING FOR FASTBOOT, SENDING, BOOTING, iOS UP, FLASHING n%, PANIC, ...) is how a state change is noticed.
- Long sessions next to a terminal and Xcode; actions are mostly started by agents, so the app's job is to make what is happening legible and to gate the dangerous parts.

## Capabilities and Constraints

- Not sandboxed; runs fastboot, adb, ssh, gh, python3. Ad-hoc signed. No third-party packages.
- Safety rules the UI must keep visible and enforced: one boot per fastboot appearance, never auto-retried; Send now only with confirmation; flashing only userdata/boot/logo, behind typing the partition name; 64 MiB warning for ABL boots; auto-reboot to fastboot is a visible state.
- Every state and string the app shows today is product truth (titles, hints, commands shown in confirmations); the redesign changes presentation, not behaviour or the file-based API (`status.json`, inbox kinds).
- Terminology: ABL fastboot (Qualcomm) vs Bergamota fastboot (Enxerto's, the main flash route); Enxerto = the bootloader; Renegade = the root builder; Heartwood = the kernel.

## Brand Commitments

- The approved Bergamota identity (`tools/identity/IDENTITY.md`, approved 2026-10-24) is binding for the app (user, 2026-10-26: "Yes, fully"): Isaac Newton halftone portrait as the logo, lime #d7e98a halftone ground, white giant numerals, ink #161616, paper #f4f3ec, leaf green #1a5933 for actions, Archivo (heavy, expanded) for display, JetBrains Mono for data. Fonts and the portrait master are in `tools/identity/`.
- The app icon is the Icon Composer `Bergamota.icon` (Newton in front of a white "26").
- The phone-side screens (Enxerto fastboot/charging, logo partition) use the same identity: lime stage, ink console panel, leaf/ink/alert pills.

## Evidence on Hand

- Real live data: phone states, queue items, kernel log lines, CI runs, metrics (CPU clusters, Adreno 630, battery). Nothing to invent; screenshots use real or clearly synthetic sample states.
- Identity assets: `tools/identity/newton-halftone.png`, `fonts/archivo.woff2`, `fonts/jetbrains-mono.woff2`, `icon-512.png`, previews under `tools/identity/out/`.

## Product Principles

1. State first: the phone's state and what the app is doing right now are readable from across the desk.
2. Danger is gated and loud; routine is quiet.
3. Agents act, the human watches: every automatic action leaves a visible trace (who queued what, what was sent, when).
4. Never hide the command: what will run is shown before it runs.
