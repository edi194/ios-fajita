# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Svelte 5 + Vite (user's choice, 2026-10-24), TypeScript, multi-page build (`/` landing, `/flash` flasher); python3 for dev and preview tooling (user). Served as static assets by a Cloudflare Worker on bergamota.zesmoi.com.br. Later phases add a Rust/WASM core (Renegade) that runs in the browser.

## Users

People with a Xiaomi Poco F1 (`beryllium`) and an unlocked bootloader who want to put Bergamota (Apple's iOS userland on that phone) on it, including people without a Mac (Linux and Windows users could not complete the Mac-only flow). The flasher has two modes (user's request): a **simple** mode that walks a person through the steps and hides fastboot detail, and an **advanced** mode for people who know fastboot and want the device variables, partition choice, chunk sizes and a protocol log.

## Product Purpose

Bergamota boots the unmodified iOS 18/26 userland of an iPhone on a Poco F1: Enxerto (bootloader, `boot` partition), Heartwood (patched XNU kernel), and Renegade (rewrites every arm64e Mach-O and the shared cache to run without pointer authentication and builds an HFS+ root image that goes into `userdata`). The website lets a visitor understand the project (landing page at `/`) and flash the phone from Chrome/Edge over WebUSB (`/flash`), and later build the root image from their own IPSW entirely in the browser.

Default path (user): patch the IPSW in the browser, then flash. Success for the flasher: a person picks their image, the page finds the phone in fastboot, shows exactly what will be written where, gets one explicit confirmation, streams the image (up to ~18 GB sparse) without loading it into memory, and finishes with a reboot.

## Positioning

The only way to run iOS's real userland on a non-Apple phone, and an open-source project that documents every step. The web tools run 100% locally: no Apple files and no Qualcomm firmware ever touch the server; the user supplies them.

## Operating Context

- Desktop Chrome or Edge (WebUSB). Phone connected by USB in ABL fastboot (Power + Volume Down) or Bergamota fastboot (Enxerto's own, USB id 18d1:4ee0).
- Linux needs a udev rule for the fastboot device; Windows needs the WinUSB driver bound to it.
- Root images are Android sparse images (`.simg`), 11-18 GB; boot images are Android `boot.img` (<= 64 MiB); logo images <= 32 MiB.
- A flash takes minutes (ABL measured ~36 MB/s): the page must stay readable and honest during a long wait.

## Capabilities and Constraints

- Writes only `userdata` (iOS root), `boot` (Enxerto) and `logo` (splash). Never modem, persist, bluetooth, dsp, bootloaders or anything else; no erase, format or arbitrary oem commands.
- The device must identify as product `beryllium`.
- Streams the image from a user-picked file or the browser's private storage (OPFS); never reads a whole image into memory.
- Never hosts or bundles Apple files (IPSW contents, shared caches, kernelcaches) or Qualcomm firmware.
- Delta flashing (Bergamota fastboot `oem hash`) exists in the Mac tool; the web flasher does full flashes first. Undecided: whether to add delta later.

## Brand Commitments

- Name: **Bergamota**. Parts named after the bergamot tree: Enxerto (graft), Heartwood (kernel), Renegade (patcher), Bergamota (control plane).
- Identity (user, 2026-10-24): Isaac Newton after Godfrey Kneller's 1689 portrait (public domain) as a black-and-white halftone cutout, the portrait as the logo (the way IDA uses Ada Lovelace). Lime halftone ground #d7e98a, giant white iOS-version numerals behind the figure, leaf green #1a5933 for actions. No colour overlay on the figure (tried and rejected).
- The user rejected AI-generated imagery ("too artificial"): real public-domain sources only.
- Voice: plain, factual, technical without hype; it says what works and what does not.

## Evidence on Hand

- Real status (README): iOS 18.7.8 boots to SpringBoard and the home screen on all 8 cores; iOS 26 also boots; CPU rendering (GPU work in progress); USB networking with SSH; touch, buttons, battery work. Not working: Wi-Fi, cellular, audio, camera, sensors, SEP/Face ID, GPU acceleration (in progress).
- Screens: `docs/assets/enxerto-boot.png`, `enxerto-fastboot.png`, `enxerto-charge.png`.
- No user counts, testimonials, press or benchmarks beyond the README's measurements: do not invent any.

## Product Principles

1. Nothing is written without the person seeing what, where and how big, and saying yes.
2. Local only: the user's files never leave their machine.
3. Honest status: show what works and what does not, in the project's own words.
4. Simple by default, everything available in advanced.

## Accessibility & Inclusion

Keyboard-operable flow, visible focus, progress announced to assistive tech (live region), reduced-motion respected. Copy in English first.
