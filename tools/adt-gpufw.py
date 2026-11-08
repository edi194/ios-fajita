#!/usr/bin/env python3
"""Add the Adreno 630 firmware to an Apple Device Tree as a /sweet-gpu node.

  adt-gpufw.py IN.adt OUT.adt --fw DIR [--zap DIR]

Heartwood's GPU bring-up (sweetgpu=N, patches 0103/0180-0185) loads its firmware from the ADT
node /sweet-gpu before the root filesystem exists, so nothing has to be written to the iOS root:
  gmu-firmware  DIR/a630_gmu.bin   (linux-firmware qcom/a630_gmu.bin)
  sqe-firmware  DIR/a630_sqe.fw    (linux-firmware qcom/a630_sqe.fw)
  zap-mdt, zap-b00..zap-bNN        ZAPDIR/a630_zap.mdt + .bNN (signed for the phone, e.g. split from
                                   sdm845-mainline firmware-xiaomi-beryllium a630_zap.mbn with
                                   tools/zap-split.py)
The firmware is Qualcomm's: keep it and the resulting ADT out of git.
"""
import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adt  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('inp'); ap.add_argument('out')
    ap.add_argument('--fw', required=True, help='directory with a630_gmu.bin and a630_sqe.fw')
    ap.add_argument('--zap', help='directory with a630_zap.mdt and a630_zap.bNN')
    a = ap.parse_args()
    root, _ = adt.parse(adt.load(a.inp))
    root.children = [c for c in root.children if c.name != 'sweet-gpu']
    n = adt.Node()
    n.props.append(('name', 0, b'sweet-gpu\0'))
    n.props.append(('gmu-firmware', 0, open(os.path.join(a.fw, 'a630_gmu.bin'), 'rb').read()))
    n.props.append(('sqe-firmware', 0, open(os.path.join(a.fw, 'a630_sqe.fw'), 'rb').read()))
    if a.zap:
        n.props.append(('zap-mdt', 0, open(os.path.join(a.zap, 'a630_zap.mdt'), 'rb').read()))
        for f in sorted(glob.glob(os.path.join(a.zap, 'a630_zap.b[0-9][0-9]'))):
            n.props.append(('zap-' + f[-3:], 0, open(f, 'rb').read()))
    root.children.append(n)
    open(a.out, 'wb').write(adt.serialize(root))
    print('%s: /sweet-gpu with %s' % (a.out, ', '.join('%s (%d)' % (p, len(v)) for p, _, v in n.props[1:])))


if __name__ == '__main__':
    main()
