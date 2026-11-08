# Bergamota web

The website at **https://bergamota.zesmoi.com.br**: a landing page at `/` and the browser flasher at `/flash/`.
Svelte 5 + Vite, served as static assets by a Cloudflare Worker. Everything runs on the visitor's computer:
the site never hosts or receives Apple files (IPSW contents, shared caches, kernelcaches) or Qualcomm firmware.

## The flasher

Chrome or Edge on a desktop computer talks fastboot to the Poco F1 over **WebUSB**
(`src/lib/fastboot.ts`). Two paths:

- **Patch IPSW + flash** (the default): pick Apple's IPSW, patch it into a root image in the browser, flash it.
  The IPSW step checks the file against Renegade's profiles (`src/lib/profiles.ts`: ios26 = iOS 26.6.2 23G90
  for iPhone12,1, ios18 = iOS 18.7.8 22H352 for iPhone11,8). The patch step runs Renegade (Rust, compiled to
  WebAssembly: `tools/renegade-wasm`, built into `src/patcher/renegade.wasm` by `npm run build:wasm`) in a Web
  Worker: it reads the IPSW with `FileReaderSync` (never loaded whole), decrypts and reads the APFS images,
  and writes the sparse `userdata` image into the browser's private storage (OPFS, about 18 GB; the step checks
  `navigator.storage.estimate()` first). The image then goes through the same checks and flashing as the
  second path. The only network request is `/api/fcs-key` (`worker/index.ts`): the IPSW's disk images are
  AEA-encrypted for a private key Apple publishes on its CDN without CORS headers, so the Worker fetches that
  one file (URL pattern allowlisted) for the page. The root gets an SSH server when the page has the tools
  bundle (`public/tools/berga-tools.zip`, `scripts/fetch-tools.sh` downloads the newest `berga-tools-vN` release)
  and the user pastes an SSH public key; without them the root builds but has no SSH.
- **Flash an image**: an iOS root (`.simg` or `.img`, onto `userdata`), Enxerto's `boot.img` (onto `boot`) or a
  splash (onto `logo`).

Safety, enforced in code and covered by tests:

- Only `userdata`, `boot` and `logo` can be written. `FastbootDevice` refuses every other partition and every
  command except `getvar`, `download`, `flash:<allowed>`, `reboot` and `reboot-bootloader` (no erase, format,
  oem, flashing unlock, set_active...). Modem, persist, bluetooth, dsp and the bootloaders are unreachable.
- The phone must report `product` = `beryllium`; ABL must be unlocked; Bergamota fastboot must have
  `bergamota-flash` = 1.
- The image is validated before anything is sent (sparse chunk table fully checked, boot needs the `ANDROID!`
  header and 1-64 MiB, logo 1-32 MiB, a root at least 64 MiB, and the expanded size must fit
  `partition-size:<p>`), and the user types the partition name to confirm.

Large images are **streamed**: `src/lib/sparse.ts` reads only the sparse chunk table, splits the image into
pieces of at most 512 MiB (the size the Mac app uses for ABL; the phone's `max-download-size` when smaller;
selectable in Advanced), each a complete sparse image with leading/trailing DONT_CARE like libsparse's resparse,
and produces each piece's bytes from `File.slice()` reads in 1 MiB buffers. An 18 GB root costs a few MB of
memory. Raw images larger than a piece become sparse pieces too (last block zero-padded); small images go as is.

Linux needs a udev rule for the fastboot device; Windows needs the WinUSB driver (Google USB driver or Zadig).
The Connect step shows both.

Prior art: [fastboot.js](https://github.com/kdrag0n/fastboot.js) (Danny Lin, MIT) and GrapheneOS's
[web installer](https://github.com/GrapheneOS/grapheneos.org) (MIT). The code here is a fresh implementation.

## Develop

```sh
npm install
npm test          # node --test: sparse splitting round trips, end-to-end flash into a fake phone, allowlist
npm run check     # svelte-check
npm run dev       # Vite on http://localhost:5173 (dev only: window.__session drives the flow with test/helpers.ts FakePhone)
npm run build:wasm # tools/renegade-wasm -> src/patcher/renegade.wasm (needs rustup + the wasm32-unknown-unknown target)
npm run build     # build:wasm, then Vite -> dist/ (the wasm build is also part of `npm run dev` and `deploy`)
npx wrangler dev  # serve dist/ like production (headers, 404, /flash -> /flash/) on http://localhost:8787
```

`public/_headers` sets the CSP (fonts and images only from this origin, `wasm-unsafe-eval` for the WASM patcher) and `Permissions-Policy: usb=(self)`.

## Deploy

`wrangler.jsonc` binds the Worker to the custom domain `bergamota.zesmoi.com.br` (Cloudflare creates the DNS
record on the first deploy). `npm run deploy` builds and deploys; it needs `wrangler login` on an account that
owns the `zesmoi.com.br` zone.

## Identity

Isaac Newton, after Godfrey Kneller's 1689 portrait (public domain), cut out and printed as a black-and-white
halftone, on a lime halftone ground with the iOS version in giant white numerals tucked behind him.
`DESIGN.md` has the system; `public/img/newton.webp` is the cutout.
