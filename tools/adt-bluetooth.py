#!/usr/bin/env python3
"""Add /arm-io/bluetooth (tools/mkadt.py bluetooth_node) to an existing Apple Device Tree.

  adt-bluetooth.py IN.adt OUT.adt

For ADTs that were not made by the current mkadt.py, e.g. beryllium-hi-3x-gpufwz.adt (GPU
firmware added by adt-gpufw.py): bluetoothd and BlueTool only start when a registry entry named
`bluetooth` with local-mac-address exists (docs/BT_IOS_TRANSPORT.md 2.1, docs/WIFI_BT_IOS18.md).
An existing /arm-io/bluetooth is replaced. The phandle is one above the highest in the tree.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402
import mkadt  # noqa: E402


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
    armio.children = [c for c in armio.children if c.name != 'bluetooth']
    top = max(struct.unpack('<I', n.prop('AAPL,phandle'))[0] for n in walk(root) if n.prop('AAPL,phandle'))
    armio.children.append(mkadt.bluetooth_node(lambda: ('AAPL,phandle', mkadt.u32(top + 1))))
    open(sys.argv[2], 'wb').write(adt.serialize(root))
    print('%s: /arm-io/bluetooth (phandle %d, local-mac-address %s)' %
          (sys.argv[2], top + 1, ':'.join('%02x' % b for b in mkadt.BT_MAC)))


if __name__ == '__main__':
    main()
