#!/usr/bin/env python3
"""Renegade platform layer: every operation that differs between macOS and Linux goes through this module.

(Not called `platform.py`: that would shadow the standard library module of the same name for every script that puts
tools/renegade on sys.path.)

                       macOS (the original flow, unchanged)      Linux (needs root, see tools/renegade/README.md)
  create image         mkfile -n SIZE                            truncate (sparse file)
  format               hdiutil attach -nomount + newfs_hfs -s    mkfs.hfsplus -s -v NAME IMG   (case-sensitive, NOT journaled)
  attach read-write    hdiutil attach (user, no sudo)            losetup --find --show + mount -t hfsplus -o rw,force
  attach read-only     hdiutil attach -readonly                  losetup --read-only + mount -t hfsplus -o ro
  IPSW volumes (APFS)  hdiutil attach -readonly (raw dmg)        apfs-fuse (read-only FUSE)
  detach               hdiutil detach [-force]                   umount + losetup -d (fusermount -u for FUSE)
  fsck                 fsck_hfs -fn /dev/rdiskN                  fsck.hfsplus -f -n IMG
  tree copy            ditto                                     Python copy (modes, owners, symlinks, hard links)
  ad-hoc signing       codesign -f -s -                          ldid -S (pinned, SHA-256 verified, see jailbreak.py)
  punch holes          fcntl F_PUNCHHOLE (APFS)                  fallocate(PUNCH_HOLE | KEEP_SIZE)
  owners               recorded, applied to the catalog later    chown for real (root), recorded for the catalog pass too

Selection: sys.platform, or RENEGADE_PLATFORM=macos|linux (to build the command lines of the other backend).
Dry run: RENEGADE_DRY_RUN=1 prints every command the backend would run and executes nothing (loop devices, mounts and
the signer are faked); `python3 tools/renegade/renegade_platform.py --plan [macos|linux]` prints the commands of a whole
image build. The command construction is unit-tested in tools/renegade/tests/test_platform.py.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))

# CodeDirectory flag bits that are signing "options" (codesign -o NAME, ldid -C NAME-ish), kept across a re-sign
CS_FLAG_OPTIONS = ((0x1, 'host'), (0x100, 'hard'), (0x200, 'kill'), (0x400, 'expires'), (0x800, 'restrict'),
                   (0x2000, 'library'), (0x10000, 'runtime'))
# ldid -C spells library-validation out; the others are the same words
LDID_FLAG_NAMES = {'library': 'library-validation'}

APT_HINTS = {
    'mkfs.hfsplus': 'hfsprogs', 'fsck.hfsplus': 'hfsprogs', 'losetup': 'mount (util-linux)', 'mount': 'mount (util-linux)',
    'umount': 'mount (util-linux)', 'findmnt': 'mount (util-linux)', 'zstd': 'zstd',
    'apfs-fuse': 'apfs-fuse (not in the Debian/Ubuntu archives: build https://github.com/sgan81/apfs-fuse, see README)',
    'ipsw': 'ipsw (https://github.com/blacktop/ipsw/releases, .deb or tarball)',
}


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def detect():
    p = (os.environ.get('RENEGADE_PLATFORM') or '').lower()
    if p in ('macos', 'darwin', 'mac'):
        return 'macos'
    if p == 'linux':
        return 'linux'
    if p:
        sys.exit(f'RENEGADE_PLATFORM={p!r}: use macos or linux')
    if sys.platform == 'darwin':
        return 'macos'
    if sys.platform.startswith('linux'):
        return 'linux'
    sys.exit(f'Renegade supports macOS and Linux, not {sys.platform}')


def parse_size(s):
    """'20g' / '512m' / '1048576' -> bytes (mkfile's suffixes: b, k, m, g)."""
    m = re.fullmatch(r'(\d+)([bkmg]?)', str(s).strip().lower())
    if not m:
        sys.exit(f'bad size {s!r}')
    return int(m.group(1)) * {'': 1, 'b': 512, 'k': 1 << 10, 'm': 1 << 20, 'g': 1 << 30}[m.group(2)]


class Runner:
    """subprocess.run with a dry-run mode and a history (what the unit tests read)."""

    def __init__(self, dry=None, echo=False):
        self.dry = (os.environ.get('RENEGADE_DRY_RUN') == '1') if dry is None else dry
        self.echo = echo
        self.history = []

    def run(self, cmd, check=True, fake='', **kw):
        cmd = [str(c) for c in cmd]
        self.history.append(cmd)
        if self.dry:
            print('[dry-run] ' + shlex.join(cmd), flush=True)
            return subprocess.CompletedProcess(cmd, 0, stdout=fake, stderr='')
        if self.echo:
            print('+ ' + shlex.join(cmd), flush=True)
        kw.setdefault('capture_output', True)
        kw.setdefault('text', True)
        return subprocess.run(cmd, check=check, **kw)


class Backend:
    name = '?'
    real_owners = False
    fsck_tool = '?'

    def __init__(self, runner=None):
        self.runner = runner or Runner()

    @property
    def dry(self):
        return self.runner.dry

    def run(self, cmd, **kw):
        return self.runner.run(cmd, **kw)

    # -- shared -------------------------------------------------------------------------------------------------------
    def detach_retry(self, target):
        """detach with retries, then force (a mount that is still busy for a moment after the last write)."""
        for i in range(4):
            r = self.detach(target)
            if r.returncode == 0:
                return
            time.sleep(0 if self.dry else 2 + 3 * i)
        r = self.detach(target, force=True)
        if r.returncode:
            sys.exit('detach failed: ' + r.stderr)

    @staticmethod
    def cs_options(flags):
        return [n for bit, n in CS_FLAG_OPTIONS if flags & bit]


# ======================================================================================================================
class MacOS(Backend):
    name = 'macos'
    fsck_tool = 'fsck_hfs'

    def check_tools(self, *roles):
        pass

    def need_privileges(self):
        pass

    def make_image(self, path, size):
        self.run(['mkfile', '-n', size, path])

    def attach_raw(self, img):
        """Attach the raw image without mounting; returns /dev/diskN."""
        r = self.run(['hdiutil', 'attach', '-nomount', '-imagekey', 'diskimage-class=CRawDiskImage', img],
                     fake='/dev/disk99 Dry_Run\n')
        return r.stdout.split()[0]

    def format_hfsx(self, img, label='iOSRoot'):
        d = self.attach_raw(img)
        try:
            self.run(['newfs_hfs', '-s', '-v', label, d.replace('/disk', '/rdisk')])
        finally:
            self.detach(d)

    def attach(self, img, mnt, readonly=True, owners=False):
        if not self.dry:
            os.makedirs(mnt, exist_ok=True)
        cmd = ['hdiutil', 'attach', '-nobrowse', '-mountpoint', mnt]
        if readonly:
            cmd += ['-readonly', '-noverify']
        if owners:
            cmd += ['-owners', 'on']
        # the decrypted IPSW dmgs and the HFS image are raw volumes: CRawDiskImage
        cmd += ['-imagekey', 'diskimage-class=CRawDiskImage']
        return self.run(cmd + [img], fake='/dev/disk99 Dry_Run\n').stdout.split()[0]

    def attach_ipsw(self, dmg, mnt, owners=False):
        return self.attach(dmg, mnt, readonly=True, owners=owners)

    def detach(self, target, force=False, check=False):
        cmd = ['hdiutil', 'detach'] + (['-force'] if force else []) + [target]
        return self.run(cmd, check=check)

    def detach_image(self, img):
        """Detach every device that was attached from this image (a killed earlier run leaves them)."""
        out = self.run(['hdiutil', 'info']).stdout
        dev, found = None, False
        want = os.path.realpath(img)
        for line in out.splitlines():
            if line.startswith('image-path'):
                p = line.split(':', 1)[1].strip()
                found = os.path.realpath(p) == want or os.path.abspath(img) in line
            elif line.startswith('/dev/disk') and found and dev is None:
                dev = line.split()[0]
            elif line.startswith('====='):
                if found and dev:
                    self.detach(dev)
                dev, found = None, False
        if found and dev:
            self.detach(dev)

    def fsck(self, img):
        d = self.attach_raw(img)
        try:
            r = self.run(['fsck_hfs', '-fn', d.replace('/disk', '/rdisk')], check=False)
        finally:
            self.detach(d)
        return r.returncode, r.stdout + r.stderr

    # ditto, the original copy; EXCLUDE dirs on the way are made by hand
    DITTO = ['ditto', '--nohfsCompression', '--nopreserveHFSCompression', '--noextattr', '--noqtn', '--norsrc', '--noacl']

    def copy_tree(self, src, dst, exclude=(), rel=''):
        ex = [e for e in exclude if e == rel or e.startswith(rel + '/')] if rel else list(exclude)
        if not ex:
            r = self.run(self.DITTO + [src, dst], check=False)
            return r.returncode, r.stderr
        err, rc = '', 0
        os.makedirs(dst, exist_ok=True)
        shutil.copymode(src, dst)
        for n in sorted(os.listdir(src)):
            crel = (rel + '/' + n) if rel else n
            if crel in exclude:
                continue
            s2, d2 = os.path.join(src, n), os.path.join(dst, n)
            if os.path.islink(s2):                      # ditto would FOLLOW a symlink given as the source
                if os.path.lexists(d2):
                    os.unlink(d2)
                os.symlink(os.readlink(s2), d2)
                continue
            if os.path.isdir(s2):
                r, e = self.copy_tree(s2, d2, exclude, crel)
            else:
                x = self.run(self.DITTO + [s2, d2], check=False)
                r, e = x.returncode, x.stderr
            rc |= r
            err += e
        return rc, err

    def read_entitlements(self, path):
        """XML entitlements of a signed binary (bytes) or None."""
        r = self.run(['codesign', '-d', '--entitlements', '-', '--xml', path], check=False, text=False)
        out = r.stdout if isinstance(r.stdout, bytes) else (r.stdout or '').encode()
        return out if r.returncode == 0 and out.strip().startswith(b'<?xml') else None

    def sign_cmd(self, path, ident=None, flags=None, ents_file=None):
        cmd = ['codesign', '-f', '-s', '-']
        if ident:
            cmd += ['-i', ident]
        opts = self.cs_options(flags or 0)
        if opts:
            cmd += ['-o', ','.join(opts)]
        if ents_file:
            cmd += ['--entitlements', ents_file]
        return cmd + [path]

    def adhoc_sign(self, path, ident=None, flags=None, entitlements=None, retries=3):
        """Ad-hoc signature with the given identifier, CS options and entitlements (XML bytes).
        RENEGADE_SIGNER=ldid signs with the pinned ldid instead (tests: compare it with codesign on this Mac)."""
        if os.environ.get('RENEGADE_SIGNER') == 'ldid':
            return Linux.adhoc_sign(self, path, ident, flags, entitlements, retries)
        tmpdir = tempfile.mkdtemp(prefix='renegade-ents-')      # outside any bundle: codesign would seal it as a resource
        ents_file = None
        try:
            if entitlements:
                ents_file = os.path.join(tmpdir, 'ents.plist')
                with open(ents_file, 'wb') as f:
                    f.write(entitlements)
            cmd = self.sign_cmd(path, ident, flags, ents_file)
            for _ in range(retries):                # codesign sometimes fails under parallel load; the file is unchanged then
                r = self.run(cmd, check=False)
                if r.returncode == 0:
                    return
            raise SystemExit(f'codesign failed for {path}: {r.stderr.strip()}')
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def prepare_signer(self):
        if os.environ.get('RENEGADE_SIGNER') == 'ldid':
            Linux.ldid(self)

    def verify_signature(self, path):
        """(ok, 'resource' if only the bundle resource seal is invalid, else message) or None if not supported here."""
        r = self.run(['codesign', '-v', path], check=False)
        return r.returncode == 0, ('resource' if 'resource' in r.stderr else r.stderr.strip())

    def find_compressed(self, root):
        r = self.run(['find', root, '-flags', '+compressed', '-print', '-quit'], check=False)
        return r.stdout.strip()

    def punch_hole(self, fd, off, length):
        import fcntl
        import struct
        # struct fpunchhole { u32 fp_flags; u32 reserved; off_t fp_offset; off_t fp_length; }
        fcntl.fcntl(fd, 99, struct.pack('<IIqq', 0, 0, off, length))           # F_PUNCHHOLE

    def birthtime(self, st):
        return st.st_birthtime


# ======================================================================================================================
class Linux(Backend):
    name = 'linux'
    real_owners = True
    fsck_tool = 'fsck.hfsplus'
    MOUNT_OPTS = 'nls=utf8'                 # file names are stored decomposed (NFD) like macOS: the driver's default
    FUSE_WAIT = 60

    def need_privileges(self):
        if not self.dry and os.geteuid() != 0:
            sys.exit('Renegade on Linux mounts the HFS+ root with a loop device and mount(8): run it as root '
                     '(sudo -E tools/renegade/renegade ...). See tools/renegade/README.md, "Linux".')

    def check_tools(self, *roles):
        """Fail early with the package to install. roles: image (losetup/mount), format, fsck, ipsw (apfs-fuse), zstd."""
        need = {'image': ('losetup', 'mount', 'umount'), 'format': ('mkfs.hfsplus',), 'fsck': ('fsck.hfsplus',),
                'ipsw': ('apfs-fuse',), 'zstd': ('zstd',)}
        missing = [t for r in roles for t in need[r] if not shutil.which(t) and not self.dry]
        if missing:
            sys.exit('missing on this Linux host:\n  ' + '\n  '.join(f'{t}: {APT_HINTS.get(t, t)}' for t in sorted(set(missing))))
        if 'image' in roles and not self.dry:
            self.ensure_hfsplus_module()

    def ensure_hfsplus_module(self):
        try:
            if 'hfsplus' in open('/proc/filesystems').read():
                return
        except OSError:
            pass
        subprocess.run(['modprobe', 'hfsplus'], capture_output=True)
        try:
            if 'hfsplus' in open('/proc/filesystems').read():
                return
        except OSError:
            pass
        sys.exit('this kernel has no hfsplus driver (modprobe hfsplus failed): a container shares the host kernel, '
                 'so load the module on the host or use a distribution kernel that ships it')

    # -- command construction (pure; the unit tests call these) ------------------------------------------------------------
    @staticmethod
    def mkfs_cmd(img, label='iOSRoot'):
        # -s case-sensitive (HFSX); no -J: NOT journaled, which hfsroot_owners.py needs
        return ['mkfs.hfsplus', '-s', '-v', label, img]

    @staticmethod
    def losetup_cmd(img, readonly=False):
        return ['losetup', '--find', '--show'] + (['--read-only'] if readonly else []) + [img]

    def mount_cmd(self, dev, mnt, readonly=False):
        opts = ('ro,' if readonly else 'rw,force,') + self.MOUNT_OPTS
        return ['mount', '-t', 'hfsplus', '-o', opts, dev, mnt]

    @staticmethod
    def fsck_cmd(img):
        # -f check even if the volume says clean, -n read only (same as fsck_hfs -fn on macOS)
        return ['fsck.hfsplus', '-f', '-n', img]

    @staticmethod
    def apfs_fuse_cmd(dmg, mnt, volume=None):
        return ['apfs-fuse', '-v', str(volume if volume is not None else os.environ.get('RENEGADE_APFS_VOLUME', '0')),
                dmg, mnt]

    # -- operations ---------------------------------------------------------------------------------------------------
    def make_image(self, path, size):
        if self.dry:
            self.runner.history.append(['truncate', '-s', str(parse_size(size)), path])
            print(f'[dry-run] truncate -s {parse_size(size)} {shlex.quote(path)}', flush=True)
            return
        with open(path, 'wb') as f:
            f.truncate(parse_size(size))

    def format_hfsx(self, img, label='iOSRoot'):
        self.run(self.mkfs_cmd(img, label))

    def attach_raw(self, img, readonly=False):
        return self.run(self.losetup_cmd(img, readonly), fake='/dev/loop99\n').stdout.strip()

    def attach(self, img, mnt, readonly=True, owners=False):
        if not self.dry:
            os.makedirs(mnt, exist_ok=True)
        dev = self.attach_raw(img, readonly)
        r = self.run(self.mount_cmd(dev, mnt, readonly), check=False)
        if r.returncode:
            self.run(['losetup', '-d', dev], check=False)
            raise SystemExit(f'mount of {img} failed: {(r.stderr or r.stdout).strip()}\n'
                             '(a journaled or dirty volume needs `fsck.hfsplus -f` first; the kernel needs the hfsplus module)')
        return dev

    def attach_ipsw(self, dmg, mnt, owners=False):
        """The IPSW volumes are APFS: apfs-fuse, read-only. As root every file is readable and the real owners show,
        so one mount serves both the owner map and the copy. apfs-fuse shows the volume under root/ (next to
        private-dir/), so it mounts at MNT.apfs and MNT is a bind mount of MNT.apfs/root: MNT is the volume root."""
        fmnt = mnt.rstrip('/') + '.apfs'
        if not self.dry:
            os.makedirs(mnt, exist_ok=True)
            os.makedirs(fmnt, exist_ok=True)
        if ',' in dmg:
            # apfs-fuse hands the device path to FUSE inside a comma-separated -o list (fsname=...), so a comma in it
            # ("22H352__iPhone11,8") splits the option: give it a comma-free symlink next to the mount point
            link = os.path.join(os.path.dirname(os.path.abspath(mnt)), 'dmg-' + os.path.basename(dmg).replace(',', '_'))
            if not self.dry:
                if os.path.islink(link) or os.path.exists(link):
                    os.remove(link)
                os.symlink(os.path.abspath(dmg), link)
            dmg = link
        r = self.run(self.apfs_fuse_cmd(dmg, fmnt), fake='', check=False)
        if r.returncode and not self.dry:
            # apfs-fuse says nothing without -d: run it again with debug output so the reason shows
            mounted = [l for l in open('/proc/mounts').read().splitlines() if f' {fmnt} ' in l or f' {mnt} ' in l]
            d = self.run(['apfs-fuse', '-d', '1'] + self.apfs_fuse_cmd(dmg, fmnt)[1:], check=False, capture_output=True, text=True)
            if d.returncode == 0:
                pass                                   # the retry mounted it
            else:
                tail = '\n'.join(((d.stderr or '') + (d.stdout or '')).strip().splitlines()[-15:])
                raise SystemExit(f'apfs-fuse could not mount {dmg} at {fmnt} (exit {r.returncode}).\n'
                                 + (f'{fmnt} or {mnt} is still mounted from an earlier run: `umount -l {mnt}; umount -l {fmnt}` '
                                    '(or fusermount3 -u) and retry.\n' if mounted else '')
                                 + f'apfs-fuse -d 1 says:\n{tail}\n'
                                 'Check: /dev/fuse exists (modprobe fuse, package fuse3); a current apfs-fuse from git master; '
                                 'RENEGADE_APFS_VOLUME=N if the container has several volumes.')
        if not self.dry:
            t0 = time.time()
            while not os.path.ismount(fmnt):
                if time.time() - t0 > self.FUSE_WAIT:
                    raise SystemExit(f'apfs-fuse did not mount {dmg} at {fmnt} within {self.FUSE_WAIT}s')
                time.sleep(0.5)
        src = os.path.join(fmnt, 'root')
        if not self.dry and not os.path.isdir(src):
            src = fmnt                                 # an apfs-fuse that shows the volume at the top
        r = self.run(['mount', '--bind', src, mnt], check=False)
        if r.returncode and not self.dry:
            self.run(['umount', fmnt], check=False)
            raise SystemExit(f'bind mount of {src} at {mnt} failed: {(r.stderr or r.stdout).strip()}')
        return 'fuse:' + mnt

    def _mounts_of(self, dev):
        r = self.run(['findmnt', '-rn', '-S', dev, '-o', 'TARGET'], check=False)
        return [l for l in r.stdout.splitlines() if l]

    def detach(self, target, force=False, check=False):
        """target: a mount point, /dev/loopN, or 'fuse:MNT' (apfs-fuse). umount, then free the loop device."""
        last = subprocess.CompletedProcess([], 0, '', '')
        if target.startswith('fuse:'):
            mnt = target[5:]
            fmnt = mnt.rstrip('/') + '.apfs'
            self.run(['umount'] + (['-l'] if force else []) + [mnt], check=False)        # the bind mount of .apfs/root
            last = self.run(['umount'] + (['-l'] if force else []) + [fmnt], check=False)
            if last.returncode and shutil.which('fusermount3'):
                last = self.run(['fusermount3', '-u'] + (['-z'] if force else []) + [fmnt], check=False)
        else:
            if target.startswith('/dev/'):
                dev, mounts = target, self._mounts_of(target)
            else:
                mounts = [target]
                src = self.run(['findmnt', '-n', '-o', 'SOURCE', target], check=False, fake='/dev/loop99\n').stdout.strip()
                dev = src if src.startswith('/dev/loop') else None
            for m in mounts:
                last = self.run(['umount'] + (['-l'] if force else []) + [m], check=False)
                if last.returncode:
                    break
            if last.returncode == 0 and dev and dev.startswith('/dev/loop'):
                last = self.run(['losetup', '-d', dev], check=False)
        if check and last.returncode:
            raise subprocess.CalledProcessError(last.returncode, last.args, last.stdout, last.stderr)
        return last

    def detach_image(self, img):
        r = self.run(['losetup', '-j', img, '-O', 'NAME', '--noheadings'], check=False)
        for dev in r.stdout.split():
            self.detach(dev)

    def fsck(self, img):
        r = self.run(self.fsck_cmd(img), check=False)
        return r.returncode, r.stdout + r.stderr

    def copy_tree(self, src, dst, exclude=(), rel=''):
        """Copy src into dst like ditto does for our purposes: directories (mode), regular files, symlinks and hard links;
        owners and modes are kept (root); no xattrs, ACLs, BSD flags or compression (the source is read through FUSE,
        which hands out decompressed data). Files already in dst are replaced. A symlink in src whose name is a real
        directory in dst is skipped (the OS volume's /System/Library/... -> cryptex symlinks meet the merged directory,
        which is what we want). Returns (rc, stderr text) like the ditto wrapper."""
        if self.dry:
            self.runner.history.append(['copytree', src, dst] + [f'--exclude={e}' for e in exclude])
            print(f'[dry-run] copytree {shlex.quote(src)} {shlex.quote(dst)} --exclude {" ".join(exclude)}', flush=True)
            return 0, ''
        return py_copy_tree(src, dst, exclude, chown=os.geteuid() == 0)

    def read_entitlements(self, path):
        import pacstrip
        return pacstrip.entitlements_xml(path)          # parsed from the signature blob (works for Apple and ldid signatures)

    @staticmethod
    def ldid_cmd(ldid, path, ident=None, flags=None, ents_file=None):
        """ldid ad-hoc signing: -S[ents] pseudo-signs, -I identifier, -C flags (adhoc is always set: codesign sets it too,
        and without it the CodeDirectory is not an ad-hoc one), -Hsha256 (codesign's ad-hoc signature has one sha256
        CodeDirectory; ldid's default adds a sha1 one as well)."""
        cmd = [ldid, '-S' + (ents_file or '')]
        if ident:
            cmd.append('-I' + ident)
        names = ['adhoc'] + [LDID_FLAG_NAMES.get(n, n) for n in Backend.cs_options(flags or 0)]
        cmd.append('-C' + ','.join(names))
        cmd.append('-Hsha256')
        return cmd + [path]

    def ldid(self):
        if os.environ.get('RENEGADE_LDID'):
            return os.environ['RENEGADE_LDID']
        sys.path.insert(0, HERE)
        import jailbreak
        return jailbreak.host_ldid(download=not self.dry)

    def adhoc_sign(self, path, ident=None, flags=None, entitlements=None, retries=3):
        tmpdir = tempfile.mkdtemp(prefix='renegade-ents-')
        ents_file = None
        try:
            if entitlements:
                ents_file = os.path.join(tmpdir, 'ents.plist')
                with open(ents_file, 'wb') as f:
                    f.write(entitlements)
            cmd = Linux.ldid_cmd(Linux.ldid(self), path, ident, flags, ents_file)
            for _ in range(retries):
                r = self.run(cmd, check=False)
                if r.returncode == 0:
                    return
            raise SystemExit(f'ldid failed for {path}: {(r.stderr or r.stdout).strip()}')
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def prepare_signer(self):
        """Resolve (download + verify) the signer once, in the parent, before parallel workers need it."""
        self.ldid()

    def verify_signature(self, path):
        return None                 # no codesign -v on Linux: the identity/flags check of pacstrip.sign() still runs

    def find_compressed(self, root):
        return None                 # not checkable; apfs-fuse reads decompressed and copy_tree writes plain files

    def punch_hole(self, fd, off, length):
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        fn = getattr(libc, 'fallocate64', None) or libc.fallocate
        fn.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]
        # FALLOC_FL_KEEP_SIZE (1) | FALLOC_FL_PUNCH_HOLE (2)
        if fn(fd, 3, off, length) != 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e))

    def birthtime(self, st):
        return getattr(st, 'st_birthtime', st.st_ctime)         # os.stat has no btime on Linux: ctime is a superset


# ----------------------------------------------------------------------------------------------------------------------
def py_copy_tree(src, dst, exclude=(), chown=True):
    """Pure Python ditto stand-in (see Linux.copy_tree). exclude: paths relative to src. Returns (rc, errors)."""
    errs = []
    inode_copy = {}
    ex = set(exclude)
    src = os.path.abspath(src)

    def copy_meta(s, d, st):
        try:
            if chown:
                os.lchown(d, st.st_uid, st.st_gid)
            if not os.path.islink(d):
                os.chmod(d, st.st_mode & 0o7777)
                os.utime(d, ns=(st.st_atime_ns, st.st_mtime_ns))
        except OSError as e:
            errs.append(f'{d}: {e.strerror}\n')

    def walk(s, d, rel):
        try:
            os.makedirs(d, exist_ok=True)
            names = sorted(os.listdir(s))
        except OSError as e:
            errs.append(f'{s}: {e.strerror}\n')
            return
        for n in names:
            crel = (rel + '/' + n) if rel else n
            if crel in ex:
                continue
            s2, d2 = os.path.join(s, n), os.path.join(d, n)
            try:
                st = os.lstat(s2)
                mode = st.st_mode & 0o170000
                if mode == 0o040000:
                    if os.path.islink(d2) or (os.path.lexists(d2) and not os.path.isdir(d2)):
                        os.unlink(d2)
                    walk(s2, d2, crel)
                    copy_meta(s2, d2, st)
                elif mode == 0o120000:
                    if os.path.isdir(d2) and not os.path.islink(d2):
                        errs.append(f'{d2}: Is a directory\n')      # kept as the directory, like ditto
                        continue
                    if os.path.lexists(d2):
                        os.unlink(d2)
                    os.symlink(os.readlink(s2), d2)
                    copy_meta(s2, d2, st)
                elif mode == 0o100000:
                    key = (st.st_dev, st.st_ino)
                    if os.path.lexists(d2):
                        if os.path.isdir(d2) and not os.path.islink(d2):
                            errs.append(f'{d2}: Is a directory\n')
                            continue
                        os.unlink(d2)
                    if st.st_nlink > 1 and key in inode_copy:
                        os.link(inode_copy[key], d2)
                        continue
                    shutil.copyfile(s2, d2, follow_symlinks=False)
                    copy_meta(s2, d2, st)
                    if st.st_nlink > 1:
                        inode_copy[key] = d2
                # sockets, fifos and devices are not part of an IPSW root
            except OSError as e:
                errs.append(f'{s2}: {e.strerror}\n')

    walk(src, dst, '')
    try:
        st = os.lstat(src)
        copy_meta(src, dst, st)
    except OSError:
        pass
    return (1 if errs else 0), ''.join(errs)


# ----------------------------------------------------------------------------------------------------------------------
_backend = None


def backend():
    global _backend
    if _backend is None:
        _backend = {'macos': MacOS, 'linux': Linux}[detect()]()
    return _backend


def set_backend(b):
    """Tests: install a backend (e.g. Linux(Runner(dry=True))) for the module-level functions."""
    global _backend
    _backend = b


def name():
    return backend().name


def is_linux():
    return backend().name == 'linux'


def real_owners():
    """True when chown really changes the owner on the mounted root (Linux as root): scan_new() then trusts lstat()."""
    return backend().real_owners and (backend().dry or os.geteuid() == 0)


def _delegate(n):
    def f(*a, **kw):
        return getattr(backend(), n)(*a, **kw)
    f.__name__ = n
    return f


for _n in ('need_privileges', 'check_tools', 'make_image', 'format_hfsx', 'attach_raw', 'attach', 'attach_ipsw', 'detach',
           'detach_retry', 'detach_image', 'fsck', 'copy_tree', 'read_entitlements', 'adhoc_sign', 'prepare_signer', 'verify_signature',
           'find_compressed', 'punch_hole', 'birthtime'):
    globals()[_n] = _delegate(_n)


def fsck_tool():
    return backend().fsck_tool


def punch_hole_safe(fd, off, length, _state={'warned': False}):
    """punch_hole that degrades to a no-op (once-only warning) where the filesystem cannot punch holes."""
    try:
        backend().punch_hole(fd, off, length)
        return True
    except OSError as e:
        if not is_linux():
            raise                       # macOS: APFS punches holes; an error is a real error
        if not _state['warned']:
            _state['warned'] = True
            print(f'warning: cannot punch holes here ({e}): --consume keeps both files on disk until it ends',
                  file=sys.stderr, flush=True)
        return False


def plan(which):
    """Print the commands of an image build for one backend (dry run), without touching anything."""
    r = Runner(dry=True)
    b = {'macos': MacOS, 'linux': Linux}[which](r)
    img, mnt, dmg, sm = '/work/ios18-root-full.img', '/work/root', '/work/ipsw/os.dmg', '/work/src-os'
    print(f'# backend: {which}')
    b.make_image(img, '20g')
    b.format_hfsx(img)
    h = b.attach(img, mnt, readonly=False)
    d = b.attach_ipsw(dmg, sm, owners=True)
    if which == 'linux':
        b.copy_tree(sm, mnt, ['usr/standalone/update', 'System/Library/NanoTimeKit'])
    else:
        print('[dry-run] ditto --nohfsCompression ... SRC DST   (per directory, minus the excluded paths)')
    b.detach(d)
    b.adhoc_sign('/work/root/sbin/mount', 'com.apple.mount', 0x12002, b'<?xml version="1.0"?><plist/>')
    b.detach(h)
    b.fsck(img)


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == '--plan':
        os.environ.setdefault('RENEGADE_LDID', '/path/to/ldid')
        plan(sys.argv[2] if len(sys.argv) > 2 else detect())
    else:
        print(__doc__)
