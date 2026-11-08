# Enxerto

The Bergamota Project's bootloader (*enxerto*, Portuguese for "graft": the piece that joins iOS onto the Poco F1). Bare-metal C and assembly, packed as an Android boot.img that the stock Qualcomm ABL accepts, either flashed to `boot` or sent with `fastboot boot`.

- **Boot**: maps RAM with the MMU and D-cache on, inflates the Heartwood payload (`tools/mkpayload.py --compress`) behind a Bergamota logo and progress bar, cleans the caches and jumps to XNU with the Apple Device Tree. The log stays hidden unless the boot fails (`BOOTLOG=1` shows it).
- **Bergamota fastboot** (`docs/BERGAMOTA_FASTBOOT.md`): its own USB (DWC3) fastboot, serial `bergamota0001`, ~1 GiB downloads, entered with `sweetreboot bergamota` or when there is no payload. It also **flashes** `userdata`, `boot` and `logo` (and nothing else: hard allowlist) with its own UFS write path, raw or Android sparse images, plus `oem hash` for delta flashing (`tools/bergamota-flash.py`).
- **Early fast charging** (`charger.c`): ABL leaves the PMI8998 charger on its slow defaults, so Enxerto runs the kernel's `sweetcharger=2` control (`xnu/patches-11215/0201`) itself: ICL by APSD result (DCP 2000 mA, CDP 1500 mA, QC2/QC3 1500 mA, OCP treated as DCP: Rp 3.0 A from Type-C status gives 2000 mA, else 1800 mA; float 1000 mA; SDP untouched), FCC 2000 mA, float voltage never raised (clamped to 4395 mV only if it reads 0 or higher), JEITA/termination/AICL never written, hot/cold/fault bits or unplug put the registers back. Programmed at start, re-checked every ~5 s in the Bergamota fastboot and charging loops, `fastboot getvar bergamota-charger` (and `bergamota-charger-raw`) read it, the fastboot screen shows e.g. "charging 1500 mA CDP 37%". Before the jump to the kernel the programmed ICL/FCC are given back so the kernel's 0201 snapshots the registers as ABL left them (it restores to that snapshot on unplug / APSD change). Off: `CHARGER=0 build.sh`, or boot.img cmdline `bergamota.charger=0`; `bergamota.charger=keep` skips the give-back at hand-off.
- **Off-mode charging** (`docs/BERGAMOTA_CHARGE.md`): with `androidboot.mode=charger` it shows the battery from the PMI8998 fuel gauge. Volume Down enters fastboot.

```sh
BOARD=beryllium enxerto/build.sh [payload.bin]   # -> enxerto/out/enxerto-boot.img, bergamota-fastboot.img (what the Mac app boots with `fastboot boot`), charge-test.img, out/preview/*.ppm
```

`build.sh` also runs the host tests: it renders every screen to `out/preview/` and checks the fastboot state machine. Images built before the rename are called `shim/out/shim-boot-*.img`, and Bergamota still lists them.
