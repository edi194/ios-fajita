#!/usr/bin/env python3
"""Renegade target profiles: which iOS build the root is made from. RENEGADE_TARGET selects one (default ios26).
  python3 tools/renegade/targets.py [KEY]     prints the current profile, or one value (for the shell scripts)

ios26  iOS 26.6.2 (23G90) for iPhone12,1 (iPhone 11, N104AP): docs/IOS26_FEASIBILITY.md. 26.7.1 is OTA-only
       (payloadv2 archives, no disk images), so the first root is built from the newest IPSW.
       Boot it with an ADT made by `tools/mkadt.py --identity n104ap` (same target-type, N104).
ios18  iOS 18.7.8 (22H352) for iPhone11,8 (iPhone XR, N841AP), booted with the iPhone X ADT (D22AP).
"""
import os
import sys

TARGETS = {
    'ios26': dict(
        device='iPhone12,1', version='26.6.2', build='23G90',
        # OS root, SystemOS cryptex (AEA-encrypted) and AppOS cryptex, as in the BuildManifest
        dmgs=('094-95954-090.dmg.aea', '094-97202-092.dmg.aea', '094-96441-094.dmg'),
        work='research/ios26',
        board='N104',        # EventTimingProfiles/<board>.*.plist shipped in the root
        adt_target='N104',   # ADT target-type the kernel reports (mkadt --identity n104ap)
        adt='enxerto/out/beryllium-n104-2x.adt'),
    'ios18': dict(
        device='iPhone11,8', version='18.7.8', build='22H352',
        dmgs=('094-31934-020.dmg.aea', '094-32062-020.dmg.aea', '094-32850-020.dmg'),
        work='research/ios18',
        board='N841',
        adt_target='D22',
        adt='../ios-beryllium/shim/out/beryllium-hi-3x.adt'),
}

NAME = os.environ.get('RENEGADE_TARGET', 'ios26')
if NAME not in TARGETS:
    sys.exit(f'RENEGADE_TARGET={NAME}: unknown (have {", ".join(TARGETS)})')
T = dict(TARGETS[NAME], name=NAME)
T['ipsw_dir'] = os.path.join(T['work'], 'ipsw', f"{T['build']}__{T['device']}")
T['root_img'] = os.path.join(T['work'], f"{NAME}-root-full.img")

if __name__ == '__main__':
    if len(sys.argv) > 1:
        v = T[sys.argv[1]]
        print(' '.join(v) if isinstance(v, tuple) else v)
    else:
        for k, v in T.items():
            print(f'{k}={" ".join(v) if isinstance(v, tuple) else v}')
