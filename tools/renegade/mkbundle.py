#!/usr/bin/env python3
"""Build the iOS 18 proof-of-concept bundle from an iOS 18 restore-ramdisk root.

  mkbundle.py RAMDISK_ROOT OUTDIR [--bin NAME ...] [--install-dir /var/root/ios18poc]

The restore ramdisk of an iOS 18 IPSW (IMG4 -> APFS) is a complete on-disk userland: /usr/lib/dyld, a flat
set of libSystem dylibs WITHOUT a shared cache, and a few command-line tools (/bin/cat, /bin/expr, ...), all
arm64e. This script copies the dependency closure of the chosen tools into

  OUTDIR/dyld               the iOS 18 dyld (kernel-loaded dynamic linker)
  OUTDIR/lib/*.dylib        flat directory of the dylibs (DYLD_LIBRARY_PATH; leaf names are unique)
  OUTDIR/Frameworks/X.framework/...  the frameworks (DYLD_FRAMEWORK_PATH)
  OUTDIR/bin/NAME           the tools; LC_LOAD_DYLINKER rewritten to <install-dir>/dyld

rewrites every Mach-O with pacstrip.py and re-signs it ad hoc (entitlements kept).
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACSTRIP = os.path.join(HERE, 'pacstrip.py')
LC_LOAD_DYLIB, LC_LOAD_WEAK, LC_REEXPORT, LC_LAZY, LC_UPWARD = 0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023


def deps(path):
    b = open(path, 'rb').read()
    ncmds = struct.unpack_from('<I', b, 16)[0]
    off, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd in (LC_LOAD_DYLIB, LC_REEXPORT, LC_LAZY, LC_UPWARD, LC_LOAD_WEAK):
            s = struct.unpack_from('<I', b, off + 8)[0]
            out.append((b[off + s:off + size].split(b'\0')[0].decode(), cmd == LC_LOAD_WEAK))
        off += size
    return out


def bundle_path(install_name):
    """lib/<leaf> for dylibs (DYLD_LIBRARY_PATH); Frameworks/<X.framework/...> for frameworks (DYLD_FRAMEWORK_PATH
    matches the part of the install name starting at the .framework component; DYLD_LIBRARY_PATH is not applied to
    framework paths)."""
    parts = install_name.split('/')
    for i in range(len(parts) - 1, -1, -1):
        if parts[i].endswith('.framework'):
            return 'Frameworks/' + '/'.join(parts[i:])
    return 'lib/' + parts[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root')
    ap.add_argument('out')
    ap.add_argument('--bin', action='append', default=None)
    ap.add_argument('--install-dir', default='/var/root/ios18poc')
    ap.add_argument('--no-sign', action='store_true')
    a = ap.parse_args()
    bins = a.bin or ['expr', 'cat', 'mkdir', 'ln']
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    os.makedirs(a.out + '/bin')
    os.makedirs(a.out + '/lib')
    os.makedirs(a.out + '/Frameworks')

    todo, seen, libs = [os.path.join(a.root, 'bin', b) for b in bins], set(), {}
    while todo:
        f = todo.pop()
        for d, weak in deps(f):
            if d in seen:
                continue
            seen.add(d)
            src = os.path.join(a.root, d.lstrip('/'))
            if not os.path.exists(src):
                print(f'{"weak (optional)" if weak else "MISSING"}: {d} (needed by {os.path.basename(f)}) is not in the ramdisk',
                      file=sys.stderr)
                continue
            rel = bundle_path(d)
            assert rel not in libs, f'path clash: {d} vs {libs[rel]}'
            libs[rel] = d
            todo.append(src)
    print(f'{len(bins)} tools, {len(libs)} dylibs/frameworks')

    files = []
    shutil.copy(os.path.join(a.root, 'usr/lib/dyld'), a.out + '/dyld')
    files.append((a.out + '/dyld', []))
    for rel, d in libs.items():
        dst = os.path.join(a.out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(a.root, d.lstrip('/')), dst)
        files.append((dst, []))
    for b in bins:
        shutil.copy(os.path.join(a.root, 'bin', b), a.out + '/bin/' + b)
        files.append((a.out + '/bin/' + b, ['--dylinker', a.install_dir + '/dyld']))
    for p, extra in files:
        os.chmod(p, 0o755)
        cmd = [sys.executable, '-I', PACSTRIP] + extra + ([] if a.no_sign else ['--sign']) + [p]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f'{p}: {r.stdout}{r.stderr}')
    with open(a.out + '/MANIFEST.txt', 'w') as f:
        for rel, d in sorted(libs.items()):
            f.write(f'{rel}  <- {d}\n')
    print('bundle written to', a.out)


if __name__ == '__main__':
    main()
