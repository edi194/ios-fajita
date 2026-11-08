#!/usr/bin/env python3
"""Build the minimal Apple Device Tree that the SWEET xnu needs to boot.

Only what the early boot path actually reads (see NOTES.md); every MMIO
address comes from the sweet live FDT. Usage:  mkadt.py OUT.adt [--dump] [--qemu] [--highmem] [--board sweet|beryllium] [--display-scale 3|2] [--points WxH] [--lowpool BASE:SIZE]
"""
import hashlib, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402

# Kernel-managed RAM: above every Qualcomm XPU carve-out (see NOTES.md)
PHYS_BASE = 0xb0000000
MEM_SIZE = 0x4d000000
# --highmem (phone only): the whole upper DDR bank. The live FDT memory node is
# <0x80000000 2G>, <0x1_00000000 0xfcc00000>; every fixed reserved-memory
# carve-out is in the low bank and the dynamic pools are limited below 4G.
HIGH_PHYS_BASE = 0x100000000
HIGH_MEM_SIZE = 0xfcc00000
# /arm-io children are relative to this; it must not be 0 (serial_init bails)
SOC_BASE = 0x01000000

GICD, GICD_SIZE = 0x17a00000, 0x10000
GICR, GICR_SIZE = 0x17a60000, 0x100000
FB, FB_SIZE = 0x9c000000, 0x1700000
SWEET_ECID = 0x5357454554000001  # 'SWEET' + 1, synthetic
FB_W, FB_H, FB_STRIDE = 1080, 2400, 1080 * 4
# Internal UFS host (ufshc@1d84000 "ufs_mem"); QEMU virt has none
UFS, UFS_SIZE = 0x01d84000, 0x3000
TIMEBASE = 19200000
VTIMER_INTID = 19
# QEMU virt (-M virt,gic-version=3 -cpu cortex-a76): GICD/GICR and the generic timer's CNTFRQ
QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE = 0x08000000, 0x080a0000, 62500000
QEMU_VTIMER_INTID = 27

# Per-board differences; GIC, UFS, timer and the SoC window are the same on
# SM7150 (sweet) and SDM845 (beryllium, Poco F1).
# Synthetic locally administered Bluetooth address (not the phone's): /chosen
# mac-address-bluetooth0 and /arm-io/bluetooth local-mac-address, and what the
# kernel writes into the WCN3990 with the QCA set-BD_ADDR vendor command.
BT_MAC = bytes([0x02, 0x00, 0x5e, 0x77, 0xb0, 0x01])

BOARDS = {
    'sweet': dict(
        fb=(0x9c000000, 0x1700000), fb_wh=(1080, 2400),
        compat=['xiaomi,sweet', 'qcom,sm7150'],
        # 0-5 Cortex-A55, 6-7 Cortex-A76
        cpu_compat='qcom,kryo470', big_from=6, freqs=(1804800000, 2304000000)),
    'beryllium': dict(
        # cont_splash_mem@9d400000, simple-framebuffer 1080x2246 (mainline beryllium-common)
        fb=(0x9d400000, 0x2400000), fb_wh=(1080, 2246),
        # 'xiaomi,sweet' stays: SweetPlatformExpert matches it
        compat=['xiaomi,beryllium', 'xiaomi,sweet', 'qcom,sdm845'],
        # 0-3 Kryo 385 Silver (A55), 4-7 Gold (A75)
        cpu_compat='qcom,kryo385', big_from=4, freqs=(1766400000, 2803200000),
        # Without --highmem: low bank between cont_splash (ends 0x9f800000)
        # and ramoops@b0000000. --highmem: same window as sweet; the live
        # FDT memory is <0x80000000 3G>, <0x1_40000000 0xbd4a0000> and every
        # fixed carve-out ends below 0xb0400000.
        mem=(0x9f800000, 0x0f800000),
        # MobileGestalt's Wi-Fi address: /chosen mac-address-wifi0 (set by
        # iBoot on real devices), else ADT sdio/wlan/marconi-wifi nodes,
        # else it WAITS for an IONetworkController and times out, once per
        # question -> lsd's first-boot database seed takes ages (boot 2).
        # Synthetic locally administered addresses, not the phone's.
        chosen_extra=[
            ('mac-address-wifi0', bytes([0x02, 0x00, 0x5e, 0x77, 0xe0, 0x01])),
            ('mac-address-bluetooth0', BT_MAC),
        ],
        # /arm-io/bluetooth for bluetoothd/BlueTool (docs/BT_IOS_TRANSPORT.md 3.2). Sweet has no
        # Bluetooth driver: the node is beryllium only.
        bluetooth=True),
}

BOOT_MANIFEST_HASH = hashlib.sha384(b'sweet boot manifest').digest()

# The iOS userland is the iPhone X (iPhone10,3 / D22AP) IPSW. MobileGestalt
# derives product type, device class, home-button-less UI, artwork etc. from
# the root identity and /product of the real D22AP device tree. That tree is
# an Apple artifact (kept out of git): extract it from the IPSW with
#   tools/remotezip.py URL DeviceTree.d22ap.im4p DIR
#   ipsw img4 im4p extract DIR/Firmware/all_flash/DeviceTree.d22ap.im4p -o d22ap.adt
D22AP_ADT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ipsw-x/d22ap.adt')

# --identity: which real iPhone the ADT claims to be (root compatible/model = hw.model/hw.machine, /product
# from that device's own tree). d22ap = iPhone X, the iOS 16/18 images. n104ap = iPhone 11 (A13), the oldest
# identity iOS 26 supports (docs/IOS26_FEASIBILITY.md); its tree comes from the 26.7.1 OTA:
#   ipsw extract -r --dtree -o DIR <OTA URL>; ipsw img4 im4p extract DIR/.../DeviceTree.n104ap.im4p -o n104ap.adt
IDENTITIES = {
    'd22ap': dict(target='D22AP', machine='iPhone10,3', target_type='D22', adt=D22AP_ADT),
    'n104ap': dict(target='N104AP', machine='iPhone12,1', target_type='N104',
                   adt=os.path.join(os.path.dirname(os.path.abspath(__file__)), '../research/ios26/n104ap.adt')),
}


def d22ap_product(path=D22AP_ADT):
    """/product properties of the real device tree (D22AP or --identity), without the syscfg
    placeholders iBoot would fill in (flag bit set) and the node bookkeeping."""
    if not os.path.exists(path):
        print(f'warning: {path} missing, no /product node', file=sys.stderr)
        return None
    root, _ = adt.parse(open(path, 'rb').read())
    for c in root.children:
        if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
            return [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
    raise SystemExit(f'{path}: no /product node')

u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
cstr = lambda s: s.encode() + b'\0'


def node(name, props=(), children=()):
    n = adt.Node()
    n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
    n.children = list(children)
    return n


# SWEET low pool for zero-copy scanout (kernel boot-arg sweetfb_zc=1, docs/DISPLAY_HW.md
# section 3): a window of the low DDR bank that the kernel does not manage. The kernel
# has the same default built in (0xb0400000 + 252 MiB) and validates whatever it is given
# against the live reserved-memory regions; --lowpool BASE:SIZE (hex) writes
# /arm-io/disp0 "sweet-lowpool" = <u64 base, u64 size> to override it.
LOWPOOL_MIN, LOWPOOL_MAX = 0x9f800000, 0xfd000000


def parse_lowpool(text):
    base, size = (int(v, 0) for v in text.split(':'))
    return base, size


def bluetooth_node(ph):
    """Stock D22AP: /arm-io/uart1/bluetooth (compatible bluetooth,n88). bluetoothd finds it by
    IOServiceNameMatching("bluetooth") and reads local-mac-address, transport-encoding and
    transport-speed from the registry entry; BlueTool does the same. Our transport is the
    kernel control socket com.apple.uart.bluetooth (bsd/dev/beryllium_bt_hci.c).
    transport-encoding 3 = H4BC, the stock iPhone X value and the path the BT_HCI_TRANSPORT
    override (H4BC:POSIX:com.apple.uart.bluetooth,3000000) selects anyway; 1 = plain H4.
    No function-* properties: they are consumed by the AppleBluetooth BTReset kext, which this
    kernel does not have (the kernel owns power and reset); without function-power_enable no
    /dev/btpoweroff exists and BlueTool's power/reset commands are no-ops."""
    return node('bluetooth', [
        ph(),
        ('device_type', cstr('bluetooth')),
        ('compatible', cstr('bluetooth,wcn3990')),
        ('local-mac-address', BT_MAC),
        ('transport-encoding', u32(3)),
        ('transport-speed', u32(3000000)),
        ('vendor-id', u32(0x05ac)),
        ('product-id', u32(0x12a0)),
    ])


def build(seed=None, qemu=False, highmem=False, board='sweet', display_scale=3, points=(375, 812), lowpool=None,
          identity='d22ap'):
    ident = IDENTITIES[identity]
    """qemu=True: same tree, but with QEMU virt's GIC addresses and CNTFRQ (tools/qemu-sweet.py)."""
    b = BOARDS[board]
    phys_base, mem_size = (HIGH_PHYS_BASE, HIGH_MEM_SIZE) if highmem else (PHYS_BASE, MEM_SIZE)
    if board != 'sweet' and not qemu:
        if not highmem:
            phys_base, mem_size = b['mem']
    fb, fb_size = b['fb']
    fb_w, fb_h = b['fb_wh']
    if lowpool is not None:
        lp_base, lp_size = lowpool
        if board != 'beryllium' or qemu:
            raise SystemExit('--lowpool: Poco F1 only (--board beryllium, not --qemu)')
        if lp_base < LOWPOOL_MIN or lp_base + lp_size > LOWPOOL_MAX or lp_base & 0x3fff or lp_size & 0x3fff:
            raise SystemExit(f'--lowpool {lp_base:#x}:{lp_size:#x}: must be 16K aligned inside {LOWPOOL_MIN:#x}..{LOWPOOL_MAX:#x}')
        if lp_base < phys_base + mem_size and phys_base < lp_base + lp_size:
            raise SystemExit(f'--lowpool {lp_base:#x}:{lp_size:#x} overlaps the kernel RAM {phys_base:#x}+{mem_size:#x}')
    gicd, gicr, timebase = (QEMU_GICD, QEMU_GICR, QEMU_TIMEBASE) if qemu else (GICD, GICR, TIMEBASE)
    # 256 bytes: xnu-12377 asks the bootloader for 4 * SHA-512 (prng_random.c, panics "Expected 256 seed bytes from
    # bootloader, but got 64"); older kernels copy only the 64 they ask for (PE_get_random_seed clamps)
    seed = seed if seed is not None else os.urandom(256)
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(phys_base)),
        ('dram-size', u64(mem_size)),
        ('random-seed', seed),
        # xnu-12377 asserts iBoot wrote this (ml_unsafe_kernel_text, machine_routines.c). 1 = kernel text treated as
        # read-only, which is xnu-11215's default (pmap_ppl_disable FALSE without -unsafe_kernel_text); older kernels ignore it
        ('kernel-ctrr-to-be-enabled', u32(1)),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr('enxerto')),
        ('system-firmware-version', cstr('enxerto')),
        # iBoot's SHA-384 of the boot manifest; /sbin/mount -P 1 exits unless
        # it exists (bind mounts /private/preboot/<hex>/usr/standalone/firmware,
        # tolerating a missing directory). Fixed stand-in value.
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        # libimg4 (cryptexd) aborts "failed to get crypto algorithm" without
        # it; real A11+ device trees say sha2-384.
        ('crypto-hash-method', cstr('sha2-384')),
        # MobileGestalt's screen class: display-scale (u32, default 0) comes
        # from /chosen, the pixel size from IOMobileFramebuffer. Scale 0 makes
        # SpringBoard's FBSDisplayMode "infxinf@0x" invalid. 1080x2400 @3x =
        # 360x800 points (like iPhone X class devices).
        ('display-scale', u32(display_scale)),
        # XNU derives IOPlatformUUID (gethostuuid) from these on arm; without
        # them CFPreferences cannot use kCFPreferencesCurrentHost (no ByHost
        # files), so e.g. DataMigration never records LastSystemVersion and
        # migrates on every boot. Synthetic ECID (not the phone's); chip-id
        # of the A11 that the iPhone X userland expects.
        ('unique-chip-id', struct.pack('<Q', SWEET_ECID)),
        ('chip-id', u32(0x8015)),
        # Security status as on a dev-fused, undemoted board (tuple 0,0,1,1):
        # MobileGestalt reads these from /chosen, and mobileactivationd's
        # DeviceType then takes its native "Hactivation" branch (state
        # Activated without an activation record; no SEP, no baseband here).
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ] + b.get('chosen_extra', []), [node('memory-map', [ph()]),
        # Local boot policy (kern_csr.c): SIP relaxed like `csrutil disable`
        # (lp-sip0: untrusted kexts, unrestricted FS, task_for_pid, kernel
        # debugger, dtrace, nvram), lp-sip1: unauthenticated (unsealed) root.
        # The iOS shared cache is in no trust cache, so dyld can only map it
        # with CSR_ALLOW_UNRESTRICTED_FS (vm_unix.c shared region checks).
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    # SWEET SMP: all eight cores in physical-core order (sweet: 0-5 Cortex-A55,
    # 6-7 Cortex-A76; beryllium: 0-3 A55, 4-7 A75), one homogeneous cluster. The kernel defaults to one
    # and uses cpus=N to select an initial prefix (N <= 8).
    # QEMU retains its original single-CPU tree: its MPIDRs differ from sweet.
    cpu_nodes = []
    for core in range(1 if qemu else 8):
        cpu_nodes.append(node(f'cpu{core}', [
            ph(),
            ('device_type', cstr('cpu')),
            # SweetCPU matches IONameMatch 'qcom,kryo470': keep it after the real core name
            ('compatible', cstr(b['cpu_compat']) + (cstr('qcom,kryo470') if b['cpu_compat'] != 'qcom,kryo470' else b'') + cstr('ARM,v8')),
            ('reg', u32(core << 8)),  # actual MPIDR Aff1:Aff0, NOT logical ID
            ('cpu-id', u32(core)),   # descriptive: XNU assigns IDs by DT order
            ('cluster-id', u32(0)),  # descriptive; see ml_parse_cpu_topology
            ('cluster-type', u32(0)),  # homogeneous CLUSTER_TYPE_SMP, not AMP
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(core)),
            ('l2-cache-id', u32(core)),  # distinct per-core L2 nodes in live FDT
            ('l3-cache-id', u32(0)),     # shared L3
            ('state', cstr('running' if core == 0 else 'stopped')),
            ('timebase-frequency', u32(timebase)),
            ('clock-frequency', u32(b['freqs'][core >= b['big_from']])),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(timebase)),
            ('fixed-frequency', u32(timebase)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)),
                         ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(QEMU_VTIMER_INTID if qemu else VTIMER_INTID)),
        ('reg', u64(gicd - SOC_BASE, GICD_SIZE, gicr - SOC_BASE, GICR_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic] + ([bluetooth_node(ph)] if b.get('bluetooth') and not qemu else []) + [
        # No hardware: watchdogd checks IODeviceTree:/arm-io/wdt for no-pmu and
        # otherwise crashes trying to set the PMU boot stage (customer builds
        # ignore the -wdt_no_pmu boot-arg).
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        # Main display: IOMobileFramebuffer.framework counts /arm-io children
        # with this device_type and reads the canvas size from the node
        # (the presented iPhone X size, see SweetFramebuffer.cpp);
        # the kernel's AppleCLCD matches the compatible string.
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            # iPhone X: 375x812 points; @3x = 1125x2436, @2x = 750x1624
            # (2.25x fewer pixels for the CPU renderer; the kernel scales
            # the canvas onto the panel, patch 0100).
            # --points 414x896 (iPhone XR/11 geometry): UIKit has no status bar
            # visual provider for 375x812 at @2x, which no iPhone has, and shows
            # a red "rdar:45025538" banner instead; 414x896 @2x is a real one.
            ('canvas-width', u32(points[0] * display_scale)),
            ('canvas-height', u32(points[1] * display_scale)),
        ] + ([('sweet-lowpool', u64(lp_base, lp_size))] if lowpool is not None else []))])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(fb, fb_size)),
        ('width', u32(fb_w)),
        ('height', u32(fb_h)),
        ('stride', u32(fb_w * 4)),
    ])

    # bsd/dev/sweet_ufs.c: the UFS host ABL leaves running (absolute physical reg).
    ufs = node('sweet-ufs', [
        ph(),
        ('compatible', cstr('qcom,ufshc')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])

    # pmap_compute_max_asids requires the node even when no overrides are set.
    # An absent pmap-max-asids property selects XNU's own MAX_ASIDS default.
    # No effaceable storage: keybagd then reads /private/var/keybags/systembag.kb
    # as a plain plist instead of decrypting it with the effaceable key.
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])

    # MobileGestalt HomeButtonType = IODeviceTree:/buttons home-button-type
    # (D22AP: 2, no Home button; absent = 0 = Home-button device).
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product_props = d22ap_product(ident['adt'])
    # Our framebuffer is sRGB 8-bit. With the iPhone X's 'P3' MobileGestalt says
    # HasExtendedColorDisplay and WebKit renders page tiles into 10-bit surfaces
    # ('w30r', 'b3a8') this kernel does not provide: Safari pages stay blank.
    # (Found by MakrSas/ios-topaz, commit 3eacb48f7.)
    if product_props:
        product_props = [(k, cstr('sRGB') if k == 'artwork-display-gamut' else v) for k, v in product_props]
    product = [node('product', [ph()] + product_props)] if product_props else []

    # Identity of the iPhone whose userland runs here: compatible[0] is
    # hw.model/hw.target (D22AP / N104AP), model is hw.machine/hw.product
    # (iPhone10,3 / iPhone12,1). 'xiaomi,sweet' stays for SweetPlatformExpert matching.
    return node('device-tree', [
        ph(),
        ('compatible', cstr(ident['target']) + cstr(ident['machine']) + b''.join(cstr(c) for c in b['compat']) + cstr('AppleARM')),
        ('model', cstr(ident['machine'])),
        ('target-type', cstr(ident['target_type'])),
        ('target-sub-type', cstr(ident['target'])),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + product + ([] if qemu else [ufs]))


if __name__ == '__main__':
    board = sys.argv[sys.argv.index('--board') + 1] if '--board' in sys.argv else 'sweet'
    scale = int(sys.argv[sys.argv.index('--display-scale') + 1]) if '--display-scale' in sys.argv else 3
    points = tuple(int(v) for v in sys.argv[sys.argv.index('--points') + 1].split('x')) if '--points' in sys.argv else (375, 812)
    lowpool = parse_lowpool(sys.argv[sys.argv.index('--lowpool') + 1]) if '--lowpool' in sys.argv else None
    identity = sys.argv[sys.argv.index('--identity') + 1] if '--identity' in sys.argv else 'd22ap'
    root = build(qemu='--qemu' in sys.argv, highmem='--highmem' in sys.argv, board=board, display_scale=scale, points=points,
                 lowpool=lowpool, identity=identity)
    blob = adt.serialize(root)
    open(sys.argv[1], 'wb').write(blob)
    if '--dump' in sys.argv:
        adt.dump(adt.parse(blob)[0])
    print(f'{sys.argv[1]}: {len(blob)} bytes', file=sys.stderr)
