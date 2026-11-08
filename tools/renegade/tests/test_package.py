"""Unit tests for tools/berga-tools/package.py: allowlist, deny list, Mach-O checks, and that the zip it writes installs with
`renegade fetch-tools` logic. Fake Mach-O files; no Xcode, no network.

  python3 -I -m unittest discover -s tools/renegade/tests -v          (from the repo root)
"""
import argparse
import importlib.util
import os
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, RENEGADE)
import berga_tools as bt  # noqa: E402

spec = importlib.util.spec_from_file_location('berga_package', os.path.join(RENEGADE, '..', 'berga-tools', 'package.py'))
pk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pk)


def macho(cputype=pk.CPU_ARM64, sub=2, libs=('/usr/lib/libSystem.B.dylib',)):
    cmds = b''
    for l in libs:
        name = l.encode() + b'\0'
        name += b'\0' * (-(24 + len(name)) % 8)
        cmds += struct.pack('<IIIIII', pk.LC_LOAD_DYLIB, 24 + len(name), 24, 0, 0, 0) + name
    return struct.pack('<8I', 0xFEEDFACF, cputype, 0x80000000 | sub, 2, len(libs), len(cmds), 0, 0) + cmds + b'code'


class TestPackage(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sn, self.gl = os.path.join(self.tmp, 'sweetnet'), os.path.join(self.tmp, 'a', 'b', 'bgl')
        for base, items in ((self.sn, pk.SWEETNET), (self.gl, pk.BGL)):
            for rel, kind in items:
                p = os.path.join(base, *rel.split('/'))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, 'wb') as f:
                    f.write(macho() if kind == 'macho' else b'<plist/>\n')
                os.chmod(p, 0o755 if kind == 'macho' else 0o644)
        self.args = argparse.Namespace(version='3', out=os.path.join(self.tmp, 'out'), sweetnet=self.sn, bgl=self.gl, bgl_commit='b' * 40)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_macho_info(self):
        self.assertEqual(pk.macho_info(macho(sub=2), 'x')[0], ['arm64e'])
        self.assertEqual(pk.macho_info(macho(sub=0), 'x')[0], ['arm64'])
        self.assertEqual(pk.macho_info(macho(libs=('@rpath/libOSMesa.8.dylib', '/usr/lib/libz.1.dylib')), 'x')[1],
                         ['@rpath/libOSMesa.8.dylib', '/usr/lib/libz.1.dylib'])
        with self.assertRaises(ValueError):
            pk.macho_info(macho(cputype=0x01000007), 'x86')
        with self.assertRaises(ValueError):
            pk.macho_info(b'not a macho', 'text')

    def test_build_and_install_roundtrip(self):
        z, digest, m = pk.build(self.args)
        self.assertEqual(m['tag'], 'berga-tools-v3')
        self.assertEqual(open(z + '.sha256').read().split()[0], digest)
        with zipfile.ZipFile(z) as zf:
            names = sorted(zf.namelist())
        self.assertEqual(names, sorted([bt.MANIFEST] + ['sweetnet/' + r for r, _ in pk.SWEETNET] +
                                       ['bergamota-gl/' + r for r, _ in pk.BGL] + ['LICENSES/' + l for l in pk.LICENSES]))
        cache = os.path.join(self.tmp, 'cache')
        d = bt.install_zip(z, cache, digest, log=lambda *_: None)
        self.assertTrue(os.access(os.path.join(d, 'sweetnet', 'sweetreboot'), os.X_OK))
        self.assertFalse(os.access(os.path.join(d, 'sweetnet', 'ios18', 'SweetRun.app', 'Info.plist'), os.X_OK))

    def test_manifest_has_a_sha256_per_file(self):
        a = pk.build(self.args)[2]
        self.assertTrue(all(len(e['sha256']) == 64 for e in a['files']))

    def test_missing_file_refused(self):
        os.unlink(os.path.join(self.gl, 'libOSMesa.8.dylib'))
        with self.assertRaises(SystemExit):
            pk.build(self.args)
        self.assertFalse(os.path.exists(os.path.join(self.args.out, 'berga-tools.zip')))

    def test_non_system_link_refused(self):
        with open(os.path.join(self.sn, 'cscheck'), 'wb') as f:
            f.write(macho(libs=('/opt/homebrew/lib/libfoo.dylib',)))
        with self.assertRaises(SystemExit):
            pk.build(self.args)

    def test_wrong_cpu_refused(self):
        with open(os.path.join(self.sn, 'cscheck'), 'wb') as f:
            f.write(macho(cputype=0x0100000C + 1))
        with self.assertRaises(SystemExit):
            pk.build(self.args)

    def test_deny_names(self):
        for bad in ('sweetnet/a630_zap.mbn', 'bergamota-gl/a630_gmu.bin', 'sweetnet/a630_sqe.fw', 'x/dyld_shared_cache_arm64e',
                    'x/root.dmg', 'x/ios18-root-full.simg', 'x/firmware/foo', 'x/persist.img', 'x/kernelcache.release', 'x/serial.txt'):
            with self.assertRaises(SystemExit, msg=bad):
                pk.check_name(bad)
        for ok in ('sweetnet/ios18/sweetprefs', 'bergamota-gl/libOSMesa.8.dylib', 'LICENSES/NOTICE.txt'):
            pk.check_name(ok)

    def test_stray_files_in_the_input_dirs_are_not_packaged(self):
        with open(os.path.join(self.sn, 'a630_zap.mbn'), 'wb') as f:
            f.write(b'qualcomm')
        with open(os.path.join(self.gl, 'dyld_shared_cache_arm64e'), 'wb') as f:
            f.write(b'apple')
        z = pk.build(self.args)[0]
        with zipfile.ZipFile(z) as zf:
            self.assertFalse([n for n in zf.namelist() if 'zap' in n or 'dyld' in n])

    def test_verify_catches_a_tampered_zip(self):
        z = pk.build(self.args)[0]
        bad = z + '.bad'
        with zipfile.ZipFile(z) as src, zipfile.ZipFile(bad, 'w') as dst:
            for i in src.infolist():
                dst.writestr(i, src.read(i.filename) + (b'!' if i.filename == 'sweetnet/sweetreboot' else b''))
        with self.assertRaises(bt.ToolsError):
            pk.verify(bad, pk.collect(self.sn, self.gl))


if __name__ == '__main__':
    unittest.main()
