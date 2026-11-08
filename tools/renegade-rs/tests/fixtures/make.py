#!/usr/bin/env python3
"""Builds the committed test fixtures (macOS: hdiutil, clang). Only our own content goes in.

  python3 tests/fixtures/make.py

hfsplus.simg / hfsx.simg: small HFS+ and case-sensitive HFSX volumes (folders, a hard link, absolute and
relative symlinks, non-ASCII names, a file bigger than one extent of blocks) converted with Renegade's
img2simg.py. pac.o / libpac.dylib: every instruction class pacstrip handles (pac.s; LC_DATA_IN_CODE only means file
offsets in the linked dylib). libfix.dylib / exe: arm64e chained fixups, LC_LOAD_DYLINKER.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.normpath(os.path.join(HERE, '..', '..', '..', 'renegade'))


def tree(root):
    os.makedirs(f'{root}/System/Library/Caches/com.apple.dyld')
    os.makedirs(f'{root}/usr/lib/sub dir')
    os.makedirs(f'{root}/Library/Café')
    with open(f'{root}/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e', 'wb') as f:
        f.write(bytes(range(256)) * 300)
    with open(f'{root}/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.symbols', 'wb') as f:
        f.write(b'symbols')
    with open(f'{root}/usr/lib/hello.txt', 'w') as f:
        f.write('hello from bergamota\n')
    with open(f'{root}/usr/lib/sub dir/big.bin', 'wb') as f:
        f.write(os.urandom(700 * 1024))
    with open(f'{root}/Library/Café/naïve.txt', 'w') as f:
        f.write('unicode\n')
    os.chmod(f'{root}/usr/lib/hello.txt', 0o640)
    os.link(f'{root}/usr/lib/hello.txt', f'{root}/usr/lib/hardlink.txt')
    os.symlink('/usr/lib/hello.txt', f'{root}/usr/lib/abs-link')
    os.symlink('sub dir/big.bin', f'{root}/usr/lib/rel-link')
    os.symlink('../usr/lib', f'{root}/System/lib-link')
    shutil.copy(f'{HERE}/libfix.dylib', f'{root}/usr/lib/libfix.dylib')


def volume(fs, name):
    with tempfile.TemporaryDirectory() as t:
        src = f'{t}/src'
        tree(src)
        raw = f'{t}/vol'
        subprocess.run(['hdiutil', 'create', '-quiet', '-layout', 'NONE', '-fs', fs, '-volname', 'Bergamota', '-format', 'UDTO',
                        '-size', '4m', '-srcfolder', src, raw], check=True)
        raw += '.cdr'
        size = os.path.getsize(raw)
        with open(raw, 'r+b') as f:
            f.truncate(size - size % 4096)
        subprocess.run([sys.executable, '-I', f'{RENEGADE}/img2simg.py', raw, f'{HERE}/{name}'], check=True)


def main():
    subprocess.run(['clang', '-arch', 'arm64e', '-c', f'{HERE}/pac.s', '-o', f'{HERE}/pac.o'], check=True)
    subprocess.run(['clang', '-arch', 'arm64e', '-dynamiclib', f'{HERE}/pac.s', '-o', f'{HERE}/libpac.dylib'], check=True)
    subprocess.run(['clang', '-arch', 'arm64e', '-dynamiclib', '-O1', f'{HERE}/fix.c', '-o', f'{HERE}/libfix.dylib'], check=True)
    subprocess.run(['clang', '-arch', 'arm64e', '-O1', f'{HERE}/exe.c', f'{HERE}/fix.c', '-o', f'{HERE}/exe'], check=True)
    volume('HFS+', 'hfsplus.simg')
    volume('Case-sensitive HFS+', 'hfsx.simg')
    for n in ('pac.o', 'libpac.dylib', 'libfix.dylib', 'exe', 'hfsplus.simg', 'hfsx.simg'):
        print(n, os.path.getsize(f'{HERE}/{n}'))


if __name__ == '__main__':
    main()
