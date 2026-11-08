#!/usr/bin/env python3
"""Add /arm-io/wlan to an existing Apple Device Tree (iOS 26 Wi-Fi stand-in, docs/WIFI_IOS26.md).

  adt-wlan.py IN.adt OUT.adt

launchd only starts wifid when the device tree has a node named `wlan` (com.apple.wifid.plist
_LimitLoadToDeviceTree: wlan, marconi-wifi, centauri-alpha, centauri-alpha-protium). Stock
N104AP has /arm-io/wlan (device_type 'wlan', local-mac-address, Broadcom wlan.* tunables); this
adds only the identity part. The kernel stand-in (boot-arg sweet80211, bsd/dev/sweet_80211.c)
takes its MAC from local-mac-address, which is copied from /chosen mac-address-wifi0 when present
so MobileGestalt's Wi-Fi address and en0 agree. An existing /arm-io/wlan is replaced; the
phandle is one above the highest in the tree.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402
import mkadt  # noqa: E402

DEFAULT_MAC = bytes([0x02, 0x00, 0x5e, 0x77, 0xe0, 0x01])


def walk(n):
    yield n
    for c in n.children:
        yield from walk(c)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    root, _ = adt.parse(adt.load(sys.argv[1]))
    armio = next((c for c in root.children if c.name == 'arm-io'), None)
    if armio is None:
        raise SystemExit('%s: no /arm-io' % sys.argv[1])
    chosen = next((c for c in root.children if c.name == 'chosen'), None)
    mac = chosen.prop('mac-address-wifi0') if chosen is not None else None
    if not mac or len(mac) != 6:
        mac = DEFAULT_MAC
    armio.children = [c for c in armio.children if c.name != 'wlan']
    top = max(struct.unpack('<I', n.prop('AAPL,phandle'))[0] for n in walk(root) if n.prop('AAPL,phandle'))
    armio.children.append(mkadt.node('wlan', [
        ('AAPL,phandle', mkadt.u32(top + 1)),
        ('device_type', mkadt.cstr('wlan')),
        ('compatible', mkadt.cstr('wlan,wcn3990')),
        ('local-mac-address', bytes(mac)),
    ]))
    open(sys.argv[2], 'wb').write(adt.serialize(root))
    print('%s: /arm-io/wlan (phandle %d, local-mac-address %s)' %
          (sys.argv[2], top + 1, ':'.join('%02x' % b for b in mac)))


if __name__ == '__main__':
    main()
