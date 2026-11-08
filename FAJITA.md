# fajita on Bergamota — port log

This branch is a clean restart of the OnePlus 6T (`fajita`, SDM845) port on top of
[Bergamota](https://github.com/ry-diffusion/Bergamota) `develop` (imported as one root commit, so the history of
the earlier port is not carried over). The earlier work (iOS 16.7.16, XNU 8796, Metal/Chlorophyll) stays on
`main` in this repository.

## What is done

| step | state |
|---|---|
| Bergamota `develop` imported as the branch root | `70c0cde` |
| `enxerto` board for fajita (`BOARD=fajita`) | `a7b0042` — framebuffer `0x9d400000` (the stock DTB's `cont_splash_region`, 36 MiB), panel 1080×2340, SDM845 `restart_reason` |
| `tools/mkadt.py --board fajita` | `a7b0042` — same RAM window, GIC and CPU arrangement as beryllium, `oneplus,fajita` compatible, 1080×2340 |
| Heartwood kernel (xnu-11215) built from this branch | CI run `42495065818`, `xnu/out-heartwood/kernel.development.sweet`, 18 986 696 B |
| Enxerto booting on the phone | `fastboot boot enxerto/out/enxerto-boot.img` → Bergamota boot screen, `DWC3 GSNPSID 0x5533300a`, enumerates as `18d1:4ee0` |
| Heartwood booting on fajita | `fastboot boot heartwood-fajita.img` → **SWEET EARLY 1…20** on the panel (arm_vm_init, pmap_bootstrap, serial_init, fbcon mapping, `kprintf startup complete`) then the expected panic below |

## Exactly how the last boot was produced

```sh
gh workflow run xnu.yml --ref brg-port -f macos_version=15.3 -f kernel_config=DEVELOPMENT
gh run download <run> -n xnu-kernel -D xnu/out-heartwood

python3 tools/mkadt.py enxerto/out-fajita.adt --board fajita --highmem --display-scale 3 --points 360x780

CMDLINE="debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=md0 sweetfb_hz=30 sweetfb_vsync=1 \
sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetarm64e=1"
python3 tools/mkpayload.py xnu/out-heartwood/kernel.development.sweet enxerto/out-fajita.adt \
    enxerto/out/payload-fajita.bin --cmdline "$CMDLINE"

BOARD=fajita DTB=$PWD/dtb/fajita/dtb ./enxerto/build.sh $PWD/enxerto/out/payload-fajita.bin
fastboot boot enxerto/out/enxerto-boot.img        # temporary; nothing is flashed
```

`dtb/fajita/dtb` is the phone's own stock DTB (`fajita2`, msm-id 0x141/0x20001), extracted on `main` and kept out
of git.

## The panic that is expected

```
SWEET EARLY PANIC: IOfindBSDRoot: specified root memory device, md0, has not been configured @IOKitBSDInit.cpp:856
```

`rd=md0` was chosen on purpose: without a ramdisk it stops here instead of touching `userdata`, which still holds
the iOS 16.7.16 root used by `main`. Everything before that line is the validation we wanted — the panel, the
framebuffer console, early pmap and the ADT all work on fajita.

## Next

1. **The iOS 18 root** (this is what SpringBoard needs): `tools/renegade/renegade fetch` (downloads and decrypts
   the iOS 18.7.8 iPhone11,8 root dmgs, ~8 GB), then `renegade root`, then `renegade boot` for the full boot
   image. Linux needs `ipsw` and `apfs-fuse`; see `tools/renegade/README.md`.
2. **Fajita drivers** in Heartwood: touch is RMI4 on this phone (the port on `main` has a working RMI4 driver),
   Bergamota's beryllium uses Novatek NT36672A; the panel timings are the 6T's own; keys are PM8998/SMPI as on
   `main`.
3. **GPU**: Bergamota's path is EAGL → Mesa freedreno → Turnip (`gpu/eagl`, `docs/GPU_EAGL.md`), not Metal. The
   a630 work on `main` (GMU/SMMU/CP/zap, buffer memory, PTEs) is the reference for that driver.
