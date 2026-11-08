"""Unit tests for renegade_platform.py and the Linux gating (no root, no Linux, no Docker needed).

  python3 -I -m unittest discover -s tools/renegade/tests -v          (from the repo root)

What runs where: the command-construction and dry-run tests run anywhere (the Linux backend is driven with
Runner(dry=True): nothing is executed). TestSignerParity needs macOS with codesign and the pinned ldid in research/jb/.
"""
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, RENEGADE)
import renegade_platform as rp  # noqa: E402


def load(name, fn):
    spec = importlib.util.spec_from_file_location(name, os.path.join(RENEGADE, fn))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class TestLinuxCommands(unittest.TestCase):
    def setUp(self):
        self.r = rp.Runner(dry=True)
        self.b = rp.Linux(self.r)

    def test_mkfs_is_case_sensitive_and_not_journaled(self):
        c = rp.Linux.mkfs_cmd('/w/root.img', 'iOSRoot')
        self.assertEqual(c, ['mkfs.hfsplus', '-s', '-v', 'iOSRoot', '/w/root.img'])
        self.assertNotIn('-J', c)

    def test_losetup_and_mount(self):
        self.assertEqual(rp.Linux.losetup_cmd('/i.img'), ['losetup', '--find', '--show', '/i.img'])
        self.assertEqual(rp.Linux.losetup_cmd('/i.img', True), ['losetup', '--find', '--show', '--read-only', '/i.img'])
        self.assertEqual(self.b.mount_cmd('/dev/loop3', '/m'),
                         ['mount', '-t', 'hfsplus', '-o', 'rw,force,nls=utf8', '/dev/loop3', '/m'])
        self.assertEqual(self.b.mount_cmd('/dev/loop3', '/m', readonly=True),
                         ['mount', '-t', 'hfsplus', '-o', 'ro,nls=utf8', '/dev/loop3', '/m'])

    def test_fsck_is_forced_and_read_only(self):
        self.assertEqual(rp.Linux.fsck_cmd('/i.img'), ['fsck.hfsplus', '-f', '-n', '/i.img'])

    def test_apfs_fuse(self):
        os.environ.pop('RENEGADE_APFS_VOLUME', None)
        self.assertEqual(rp.Linux.apfs_fuse_cmd('/d/os.dmg', '/m'), ['apfs-fuse', '-v', '0', '/d/os.dmg', '/m'])
        self.assertEqual(rp.Linux.apfs_fuse_cmd('/d/os.dmg', '/m', 2)[:3], ['apfs-fuse', '-v', '2'])

    def test_ldid_keeps_identifier_flags_entitlements(self):
        flags = 0x2 | 0x2000 | 0x10000 | 0x100                      # adhoc + library-validation + runtime + hard
        c = rp.Linux.ldid_cmd('/x/ldid', '/b/launchd', 'com.apple.xpc.launchd', flags, '/t/ents.plist')
        self.assertEqual(c, ['/x/ldid', '-S/t/ents.plist', '-Icom.apple.xpc.launchd',
                             '-Cadhoc,hard,library-validation,runtime', '-Hsha256', '/b/launchd'])

    def test_ldid_without_entitlements_or_old_signature(self):
        c = rp.Linux.ldid_cmd('ldid', '/b/x')
        self.assertEqual(c, ['ldid', '-S', '-Cadhoc', '-Hsha256', '/b/x'])

    def test_sign_flags_roundtrip_all_options(self):
        allf = sum(bit for bit, _ in rp.CS_FLAG_OPTIONS)
        names = rp.Backend.cs_options(allf)
        self.assertEqual(names, ['host', 'hard', 'kill', 'expires', 'restrict', 'library', 'runtime'])
        c = rp.Linux.ldid_cmd('ldid', '/b/x', 'id', allf)
        self.assertIn('-Cadhoc,host,hard,kill,expires,restrict,library-validation,runtime', c)

    def test_dry_run_flow(self):
        os.environ['RENEGADE_LDID'] = '/fake/ldid'
        try:
            b, r = self.b, self.r
            b.make_image('/w/r.img', '20g')
            b.format_hfsx('/w/r.img')
            dev = b.attach('/w/r.img', '/w/root', readonly=False)
            d = b.attach_ipsw('/w/os.dmg', '/w/src', owners=True)
            b.copy_tree('/w/src', '/w/root', ['usr/standalone/update'])
            b.detach(d)
            b.adhoc_sign('/w/root/sbin/mount', 'com.apple.mount', 0x12002, b'<plist/>')
            b.detach(dev)
            rc, _ = b.fsck('/w/r.img')
        finally:
            os.environ.pop('RENEGADE_LDID')
        self.assertEqual(rc, 0)
        h = r.history
        self.assertEqual(h[0], ['truncate', '-s', str(20 << 30), '/w/r.img'])
        self.assertEqual(h[1], ['mkfs.hfsplus', '-s', '-v', 'iOSRoot', '/w/r.img'])
        self.assertEqual(h[2], ['losetup', '--find', '--show', '/w/r.img'])
        self.assertEqual(h[3][:5], ['mount', '-t', 'hfsplus', '-o', 'rw,force,nls=utf8'])
        self.assertEqual(h[4], ['apfs-fuse', '-v', '0', '/w/os.dmg', '/w/src.apfs'])
        self.assertEqual(h[5], ['mount', '--bind', '/w/src.apfs/root', '/w/src'])     # apfs-fuse shows the volume under root/
        self.assertEqual(h[6][0], 'copytree')
        self.assertTrue(any(c[0] == '/fake/ldid' and '-Icom.apple.mount' in c for c in h))
        self.assertTrue(any(c[0] == 'fsck.hfsplus' for c in h))
        self.assertTrue(any(c[:2] == ['losetup', '-d'] for c in h))
        self.assertFalse(any(c[0] in ('hdiutil', 'newfs_hfs', 'codesign', 'ditto') for c in h))

    def test_dry_run_never_touches_the_disk(self):
        with tempfile.TemporaryDirectory() as t:
            p = os.path.join(t, 'img')
            self.b.make_image(p, '1g')
            self.assertFalse(os.path.exists(p))
            self.b.attach(p, os.path.join(t, 'mnt'), readonly=False)
            self.assertFalse(os.path.exists(os.path.join(t, 'mnt')))

    def test_privileges_checked_unless_dry(self):
        rp.Linux(rp.Runner(dry=True)).need_privileges()                 # no exception
        if os.geteuid() != 0:
            with self.assertRaises(SystemExit):
                rp.Linux(rp.Runner(dry=False)).need_privileges()


class TestMacCommands(unittest.TestCase):
    """The macOS backend must build exactly the commands the scripts ran before the platform layer existed."""

    def setUp(self):
        self.r = rp.Runner(dry=True)
        self.b = rp.MacOS(self.r)

    def test_attach_commands(self):
        self.b.attach('/i.img', '/m', readonly=False)
        self.b.attach('/os.dmg', '/m2', readonly=True, owners=True)
        self.assertEqual(self.r.history[0], ['hdiutil', 'attach', '-nobrowse', '-mountpoint', '/m',
                                             '-imagekey', 'diskimage-class=CRawDiskImage', '/i.img'])
        self.assertEqual(self.r.history[1], ['hdiutil', 'attach', '-nobrowse', '-mountpoint', '/m2', '-readonly', '-noverify',
                                             '-owners', 'on', '-imagekey', 'diskimage-class=CRawDiskImage', '/os.dmg'])

    def test_format_and_fsck(self):
        self.b.format_hfsx('/i.img')
        self.assertEqual(self.r.history[0], ['hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', '/i.img'])
        self.assertEqual(self.r.history[1], ['newfs_hfs', '-s', '-v', 'iOSRoot', '/dev/rdisk99'])
        self.b.fsck('/i.img')
        self.assertIn(['fsck_hfs', '-fn', '/dev/rdisk99'], self.r.history)

    def test_detach_and_ditto(self):
        self.b.detach('/m')
        self.b.detach('/m', force=True)
        self.assertEqual(self.r.history, [['hdiutil', 'detach', '/m'], ['hdiutil', 'detach', '-force', '/m']])
        self.r.history.clear()
        self.b.copy_tree('/a', '/b')
        self.assertEqual(self.r.history[0], ['ditto', '--nohfsCompression', '--nopreserveHFSCompression', '--noextattr',
                                             '--noqtn', '--norsrc', '--noacl', '/a', '/b'])

    def test_codesign_command_order(self):
        c = self.b.sign_cmd('/b/x', 'com.apple.x', 0x12102, '/t/e.plist')
        self.assertEqual(c, ['codesign', '-f', '-s', '-', '-i', 'com.apple.x', '-o', 'hard,library,runtime',
                             '--entitlements', '/t/e.plist', '/b/x'])
        self.assertEqual(self.b.sign_cmd('/b/x'), ['codesign', '-f', '-s', '-', '/b/x'])


class TestPyCopyTree(unittest.TestCase):
    def test_copy(self):
        with tempfile.TemporaryDirectory() as t:
            s, d = os.path.join(t, 's'), os.path.join(t, 'd')
            os.makedirs(os.path.join(s, 'a/b'))
            os.makedirs(os.path.join(s, 'skip/me'))
            os.makedirs(os.path.join(s, 'cry/lib'))
            os.makedirs(os.path.join(d, 'cry/real'))                    # merged cryptex directory already in dst
            open(os.path.join(s, 'a/b/f'), 'w').write('x')
            os.chmod(os.path.join(s, 'a/b/f'), 0o4755)
            os.link(os.path.join(s, 'a/b/f'), os.path.join(s, 'a/hard'))
            os.symlink('b/f', os.path.join(s, 'a/sym'))
            os.symlink('/System/Cryptexes/OS/lib', os.path.join(s, 'cry/real'))
            open(os.path.join(s, 'skip/me/x'), 'w').write('no')
            os.makedirs(os.path.join(d, 'a/b'))
            open(os.path.join(d, 'a/b/f'), 'w').write('old')            # replaced
            rc, err = rp.py_copy_tree(s, d, ['skip'], chown=False)
            self.assertEqual(open(os.path.join(d, 'a/b/f')).read(), 'x')
            self.assertEqual(os.stat(os.path.join(d, 'a/b/f')).st_mode & 0o7777, 0o4755)
            self.assertEqual(os.stat(os.path.join(d, 'a/b/f')).st_ino, os.stat(os.path.join(d, 'a/hard')).st_ino)
            self.assertEqual(os.readlink(os.path.join(d, 'a/sym')), 'b/f')
            self.assertFalse(os.path.exists(os.path.join(d, 'skip')))
            self.assertTrue(os.path.isdir(os.path.join(d, 'cry/real')) and not os.path.islink(os.path.join(d, 'cry/real')))
            self.assertTrue(os.path.isdir(os.path.join(d, 'cry/lib')))
            self.assertEqual(rc, 1)
            self.assertTrue(err.strip().endswith('Is a directory'))     # the message mkroot-full.py already tolerates


class TestGating(unittest.TestCase):
    """Linux without prebuilt binaries: features are skipped (never failed) and listed."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ['RENEGADE_PLATFORM'] = 'linux'
        os.environ['RENEGADE_SWEETNET'] = self.tmp                      # empty: nothing prebuilt
        rp.set_backend(None)
        self.rt = load('root_tweaks18_t', 'root_tweaks18.py')
        self.rt.SWEETNET_DIRS[:] = [self.tmp]                           # the checkout's and the main checkout's dirs too
        self.rt.BGL_DIRS[:] = [self.tmp]

    def tearDown(self):
        os.environ.pop('RENEGADE_PLATFORM', None)
        os.environ.pop('RENEGADE_SWEETNET', None)
        rp.set_backend(None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_gaps(self):
        feats = {f: True for f in self.rt.FEATURES}
        gaps = self.rt.tool_gaps(feats)
        self.assertEqual(set(gaps), {'appreg', 'wallpaper', 'posterboard', 'bglrender'})
        self.assertNotIn('jb', gaps)
        self.assertNotIn('bluetooth', gaps)                            # the launchd env part is plain plist data
        self.assertIn('Linux', ' '.join(gaps.values()) + ' ' + self.rt.not_built())

    def test_present_artifact_is_used(self):
        os.makedirs(os.path.join(self.tmp, 'ios18'))
        open(os.path.join(self.tmp, 'ios18', 'sweetuicache'), 'w').write('x')
        gaps = self.rt.tool_gaps({'appreg': True, 'wallpaper': False, 'posterboard': False, 'bglrender': False})
        self.assertEqual(gaps, {})

    def test_tweaks_skip_instead_of_failing(self):
        root = os.path.join(self.tmp, 'root')
        os.makedirs(os.path.join(root, 'System/Library/xpc'))
        os.makedirs(os.path.join(root, 'private/var/mobile'))
        os.makedirs(os.path.join(root, 'bin'))
        open(os.path.join(root, 'bin/sh'), 'w').write('sh')
        lp = os.path.join(root, 'System/Library/xpc/launchd.plist')
        plistlib.dump({'LaunchDaemons': {'/a': {'Label': 'com.apple.bluetoothd'}}}, open(lp, 'wb'), fmt=plistlib.FMT_BINARY)
        self.rt.NETCFG = os.path.join(self.tmp, 'nope')
        self.rt.REBOOT_TOOL = os.path.join(self.tmp, 'nope')
        import io
        import contextlib
        saved = os.chown, os.lchown
        self.rt.OwnerRecorder().install()                               # no root here: chown is only recorded
        self.addCleanup(lambda: (setattr(os, 'chown', saved[0]), setattr(os, 'lchown', saved[1])))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.rt.bluetooth(root)
            self.rt.sweetmetrics(root)
            self.rt.sweetprefs_tool(root)
            self.rt.netcfg(root)
            self.rt.sweetreboot(root)
            self.rt.posterboard(root)
            self.rt.bglrender(root)
            self.rt.firstboot(root, appreg=True, jb=True, wallpaper=True)
            self.rt.skip_summary()
        text = out.getvalue()
        feats = [f for f, _ in self.rt.SKIPPED]
        for want in ('bluetooth BlueTool stub + hcitest', 'sweetmetrics', 'sweetprefs tool', 'bglrender',
                     'appreg (sweetuicache)', 'wallpaper + icon style'):
            self.assertIn(want, feats)
        self.assertIn('skipped features', text)
        # bluetoothd's environment was still written; the first-boot job exists (jailbreak post-install) without sweetuicache
        env = plistlib.load(open(lp, 'rb'))['LaunchDaemons']['/a']['EnvironmentVariables']
        self.assertIn('BT_HCI_TRANSPORT', env)
        script = open(os.path.join(root, self.rt.FIRSTBOOT_SH)).read()
        self.assertIn('APPREG=0', script)
        self.assertIn('WALL=0', script)


class TestOwnerRecorder(unittest.TestCase):
    def test_real_mode_applies_and_records(self):
        rt = load('root_tweaks18_o', 'root_tweaks18.py')
        calls = []
        saved = os.chown, os.lchown
        try:
            rec = rt.OwnerRecorder()
            rec.real = True
            rec._chown = lambda p, u, g, **kw: calls.append(('chown', p, u, g))
            rec._lchown = lambda p, u, g: calls.append(('lchown', p, u, g))
            rec.install()
            os.chown('/x/a', 0, 0)
            os.lchown('/x/b', 501, 501)
        finally:
            os.chown, os.lchown = saved
        self.assertEqual(calls, [('chown', '/x/a', 0, 0), ('lchown', '/x/b', 501, 501)])
        self.assertEqual(rec.owners, {'/x/a': (0, 0), '/x/b': (501, 501)})

    def test_mac_mode_only_records(self):
        rt = load('root_tweaks18_o2', 'root_tweaks18.py')
        saved = os.chown, os.lchown
        try:
            rec = rt.OwnerRecorder()
            rec.real = False
            rec.install()
            os.chown('/definitely/not/there', 7, 7)                     # would raise if it were applied
            os.lchown('/definitely/not/there2', os.getuid(), os.getgid())  # the owner of the process is ignored
        finally:
            os.chown, os.lchown = saved
        self.assertEqual(rec.owners, {'/definitely/not/there': (7, 7)})


class TestMisc(unittest.TestCase):
    def test_parse_size(self):
        self.assertEqual(rp.parse_size('20g'), 20 << 30)
        self.assertEqual(rp.parse_size('512m'), 512 << 20)
        self.assertEqual(rp.parse_size('4096'), 4096)

    def test_toybox_applet_fallback_matches_real_list(self):
        rt = load('root_tweaks18_t2', 'root_tweaks18.py')
        out = tempfile.mkdtemp()
        try:
            names = ['cat', 'ls', 'test', 'netcat', 'sleep', 'touch']
            blob = b'\0' + b'\0'.join(n.encode() for n in names) + b'\0'
            open(os.path.join(out, 'toybox'), 'wb').write(blob)
            os.environ['RENEGADE_PLATFORM'] = 'linux'
            rp.set_backend(None)
            got = rt.toybox_applets(out)
        finally:
            os.environ.pop('RENEGADE_PLATFORM', None)
            rp.set_backend(None)
            shutil.rmtree(out)
        for n in ('cat', 'ls', 'test', '[', 'netcat', 'nc', 'sleep', 'touch'):
            self.assertIn(n, got)
        self.assertNotIn('toybox', got)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codesign') and shutil.which('clang'), 'macOS only')
class TestSignerParity(unittest.TestCase):
    """codesign vs the pinned ldid on a sample binary: identifier, CS flags and entitlements must match."""

    def entitlements(self, p):
        out = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', p], capture_output=True).stdout
        return plistlib.loads(out)

    def test_parity(self):
        sys.path.insert(0, RENEGADE)
        jb = load('jailbreak_t', 'jailbreak.py')
        try:
            ldid = jb.host_ldid(download=False)
        except SystemExit:
            self.skipTest('no pinned host ldid for this machine')
        if not os.path.exists(ldid):
            self.skipTest('pinned ldid not downloaded (python3 tools/renegade/jailbreak.py fetch on Linux, or see README)')
        pacstrip = load('pacstrip_t', 'pacstrip.py')
        with tempfile.TemporaryDirectory() as t:
            src = os.path.join(t, 'a.c')
            open(src, 'w').write('int main(void){return 0;}\n')
            ents = os.path.join(t, 'e.plist')
            plistlib.dump({'com.apple.private.foo': True, 'com.apple.private.bar': ['x', 'y'], 'get-task-allow': True},
                          open(ents, 'wb'), fmt=plistlib.FMT_XML)
            for arch in ('arm64', 'arm64e'):
                base = os.path.join(t, 'bin-' + arch)
                subprocess.run(['clang', '-arch', arch, '-o', base, src], check=True, capture_output=True)
                subprocess.run(['codesign', '-f', '-s', '-', '-i', 'com.apple.sample-' + arch, '-o', 'runtime,library,hard',
                                '--entitlements', ents, base], check=True, capture_output=True)
                res = {}
                for signer in ('codesign', 'ldid'):
                    p = os.path.join(t, f'{arch}-{signer}')
                    shutil.copy(base, p)
                    env = dict(os.environ, RENEGADE_SIGNER='ldid', RENEGADE_LDID=ldid) if signer == 'ldid' else dict(os.environ)
                    code = ('import sys; sys.path.insert(0, %r); import pacstrip; pacstrip.sign(%r)' % (RENEGADE, p))
                    subprocess.run([sys.executable, '-I', '-c', code], check=True, env=env, capture_output=True)
                    res[signer] = (pacstrip.cs_identity(p), self.entitlements(p))
                    self.assertEqual(subprocess.run(['codesign', '-v', p], capture_output=True).returncode, 0)
                self.assertEqual(res['codesign'][0], res['ldid'][0])     # (identifier, team, flags)
                self.assertEqual(res['codesign'][1], res['ldid'][1])     # entitlements, as plists
                self.assertEqual(res['ldid'][0][0], 'com.apple.sample-' + arch)


if __name__ == '__main__':
    unittest.main()
