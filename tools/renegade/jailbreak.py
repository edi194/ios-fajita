#!/usr/bin/env python3
"""Renegade jailbreak userland (`renegade jb`): optional Procursus rootless bootstrap + Sileo + TrollStore for the iOS 18.7.8 root.

  jailbreak.py fetch                      download the pinned components into research/jb/ and verify their SHA-256
  jailbreak.py stage                      unpack them into research/jb/stage/ (+ manifest.tsv with owners/modes)
  jailbreak.py live [--dry-run DIR]       install onto the running phone over SSH (or, with --dry-run, unpack the
                                          install tar into DIR and print the remote commands; touches no device)
  jailbreak.py remove [--dry-run]         undo `live`: unregister the apps, delete /var/jb and the TrollStore app
  jailbreak.py status                     what is installed on the phone (read only)
  (image mode, called by mkroot-full.py stage `jb` and `renegade update`: image_stage(ROOT, OWNERS) copies the stage
   to ROOT/private/var/jb, keeps /var a symlink and writes the owner map for hfsroot_owners.py)

Nothing downloaded is ever executed on the build host except the pinned host ldid (Linux signer, SHA-256 verified): it is only unpacked (zstd -d | tar, ar + xz/zstd in Python). The
phone runs the Procursus tools; plain arm64 binaries run as they are, any arm64e slice goes through pacstrip.py
and is re-signed ad hoc keeping its entitlements (the signatures are ldid-style, which `codesign -d` cannot read:
the entitlement blob is parsed here).

Layout (we control the root, so no /private/preboot symlink dance): /var/jb is a plain directory on the root volume,
Sileo.app is /var/jb/Applications/Sileo.app, TrollStore installs itself (trollstorehelper install-trollstore, the
upstream path) into /var/containers/Bundle/Application/<UUID>/TrollStore.app.
"""
import argparse
import hashlib
import io
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import pacstrip  # noqa: E402
import renegade_platform as rplat  # noqa: E402

CACHE = os.path.join(ROOT, 'research/jb')
STAGE = os.path.join(CACHE, 'stage')
STAGE_ROOT = os.path.join(STAGE, 'root')
MANIFEST = os.path.join(STAGE, 'manifest.tsv')
SHARE = 'var/jb/usr/share/renegade-jb'              # payloads kept on the phone (TrollStore.tar, ldid, scripts)
MIN_MAC_FREE = 10 << 30
MIN_PHONE_FREE_KB = 1 << 20                         # 1 GiB

# Pinned components. Official sources only; the hashes are checked after every download and before every unpack.
PINS = {
    'bootstrap': dict(
        what='Procursus rootless bootstrap (iphoneos-arm64, CF 1900 build of 2024-06-10; apt is pointed at suite 2000)',
        url='https://apt.procurs.us/bootstraps/1900/bootstrap-iphoneos-arm64.tar.zst',
        file='bootstrap-iphoneos-arm64.tar.zst', size=20772810,
        sha256='8354c3aa1ecdad8ebc47d9a76dfca6f830a2b757278068bd33b98bf1d638a9cb',
        licence='Procursus build system 0BSD; the packages inside keep their own licences (GPL-2/3+ coreutils, bash, '
                'dpkg, apt; ISC sudo; BSD, MIT, ...); each package has /var/jb/usr/share/doc/<pkg>/copyright',
        source='https://github.com/ProcursusTeam/Procursus'),
    'sileo': dict(
        what='Sileo 2.5.1 (org.coolstar.sileo, iphoneos-arm64 = rootless)',
        url='https://github.com/Sileo/Sileo/releases/download/2.5.1/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb',
        file='org.coolstar.sileo_2.5.1_iphoneos-arm64.deb', size=2909972,
        # the same SHA-256 is listed in apt.procurs.us/dists/2000/main/binary-iphoneos-arm64/Packages
        sha256='8e3c90e5a7d32f4ca207a0ac30d3cfa8a13dca86a2b4e11cb3f9e5c68d7bc97a',
        licence='BSD-4-Clause (Sileo; bundled libraries listed in Sileo.app/Licenses.plist)',
        source='https://github.com/Sileo/Sileo'),
    'trollstore': dict(
        what='TrollStore 2.1.1 (TrollStore.tar: TrollStore.app with RootHelper trollstorehelper)',
        url='https://github.com/opa334/TrollStore/releases/download/2.1.1/TrollStore.tar',
        file='TrollStore.tar', size=2429438,
        sha256='144dc741d1b74d582c861e6ed504ddced3745724e216e3de79ab7d37b27d0551',
        licence='MIT (Lars Froder / opa334); RootHelper/uicache.m BSD-4-Clause (CoolStar, Procursus Team)',
        source='https://github.com/opa334/TrollStore'),
    'ldid': dict(
        what='ldid v2.1.5-procursus7-new (opa334 fork; the binary TrollStore itself downloads on first launch)',
        url='https://github.com/opa334/ldid/releases/download/v2.1.5-procursus7-new/ldid',
        file='ldid', size=2630205,
        sha256='b6aa4018e7ef3df9ee3fee5889d162649719109521c5a2136ca98a81fccdf52a',
        licence='AGPL-3.0 (source: the repository below; not committed here, fetched at install time)',
        source='https://github.com/opa334/ldid'),
}
LDID_VERSION = 'v2.1.5-procursus7-new'

# ldid that runs ON THE BUILD HOST (Linux: the ad-hoc signer instead of codesign, renegade_platform.py). opa334's fork
# publishes only the iOS binary above; the official release assets for Linux (and macOS) are the Procursus ldid of the
# same base (ProcursusTeam/ldid v2.1.5-procursus7, 2023-01-18). GitHub publishes no checksums for them: the SHA-256 values
# are pinned from the downloaded assets, so a later change of an asset is caught. Same rules as PINS: cached in the
# git-ignored research/jb/, verified after every download and before every use, never run before it matches.
HOST_LDID_TAG = 'v2.1.5-procursus7'
HOST_LDID = {
    ('linux', 'x86_64'): dict(
        file='ldid_linux_x86_64', size=2956104,
        sha256='4b8862b2fefa2cd7fa8f88cb0310779619aeaa8c72d6aff22f019b470f2fa99a'),
    ('linux', 'aarch64'): dict(
        file='ldid_linux_aarch64', size=2745416,
        sha256='bddd525902f242d4cdf7aa40a7f0c2c85c42ab9440d58664251e8738ef0c565d'),
    # macOS: not used by default (codesign is); here for RENEGADE_SIGNER=ldid comparisons and tests
    ('macos', 'arm64'): dict(
        file='ldid_macosx_arm64', size=2572056,
        sha256='5dff8e6b8d9dc3ff7226276c81e09930865f15381f54cb55b98b196a94c5ca50'),
    ('macos', 'x86_64'): dict(
        file='ldid_macosx_x86_64', size=2824936,
        sha256='9d46e0feedf96e399edfca09872802ba21e729f79c01927ad25ea2b0a35bca23'),
}
HOST_LDID_URL = 'https://github.com/ProcursusTeam/ldid/releases/download/%s/%s'
APT_SUITE = '2000'                                  # Procursus CF suite for iOS 17/18 (dists/2000, rootless iphoneos-arm64)

SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
       '-o', 'UserKnownHostsFile=/Users/zesmoi/.ssh/known_hosts_ios18']
HOST = os.environ.get('SWEET_HOST', 'root@192.168.7.2')
PHONE_PATH = 'PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin; export PATH; '


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def die(msg):
    sys.exit('jb: ' + msg)


def mac_free():
    st = os.statvfs(ROOT)
    return st.f_bavail * st.f_frsize


# --- fetch ----------------------------------------------------------------------------------------------------------
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def cached(name):
    return os.path.join(CACHE, PINS[name]['file'])


def verify(name):
    p, pin = cached(name), PINS[name]
    if not os.path.exists(p):
        return False
    return os.path.getsize(p) == pin['size'] and sha256_file(p) == pin['sha256']


def fetch(names=None):
    os.makedirs(CACHE, exist_ok=True)
    if mac_free() < MIN_MAC_FREE:
        die(f'only {mac_free() / 2**30:.1f} GiB free on the Mac (< 10 GiB)')
    for name in names or PINS:
        pin = PINS[name]
        if verify(name):
            log(f'{name}: cached, sha256 ok')
            continue
        log(f'{name}: downloading {pin["url"]}')
        tmp = cached(name) + '.part'
        req = urllib.request.Request(pin['url'], headers={'User-Agent': 'renegade-jb'})
        with urllib.request.urlopen(req, timeout=60) as r, open(tmp, 'wb') as f:
            shutil.copyfileobj(r, f)
        got = sha256_file(tmp)
        if got != pin['sha256'] or os.path.getsize(tmp) != pin['size']:
            os.unlink(tmp)
            die(f'{name}: SHA-256/size mismatch (got {got}, pinned {pin["sha256"]}): refusing to use it')
        os.replace(tmp, cached(name))
        log(f'{name}: ok {pin["sha256"]}')


def host_ldid_pin():
    import platform as pyplatform
    mach = pyplatform.machine().lower()
    mach = {'amd64': 'x86_64', 'arm64': 'arm64' if rplat.name() == 'macos' else 'aarch64'}.get(mach, mach)
    pin = HOST_LDID.get((rplat.name(), mach))
    if not pin:
        die(f'no pinned ldid for {rplat.name()}/{mach}: set RENEGADE_LDID to an ldid you trust, or build one from '
            'https://github.com/ProcursusTeam/ldid')
    return pin


def host_ldid(download=True):
    """Path of the pinned, SHA-256-verified ldid for this host (downloaded into research/jb/ on first use).
    download=False (dry run): only returns where it would be."""
    pin = host_ldid_pin()
    path = os.path.join(CACHE, 'ldid-host-' + HOST_LDID_TAG, pin['file'])
    ok = os.path.exists(path) and os.path.getsize(path) == pin['size'] and sha256_file(path) == pin['sha256']
    if ok or not download:
        if ok:
            os.chmod(path, 0o755)
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    url = HOST_LDID_URL % (HOST_LDID_TAG, pin['file'])
    log(f'ldid (host signer): downloading {url}')
    tmp = path + '.part'
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'renegade-jb'})
        with urllib.request.urlopen(req, timeout=60) as r, open(tmp, 'wb') as f:
            shutil.copyfileobj(r, f)
    except OSError as e:
        die(f'cannot download {url}: {e} (offline? download it by hand to {path} or set RENEGADE_LDID)')
    got = sha256_file(tmp)
    if got != pin['sha256'] or os.path.getsize(tmp) != pin['size']:
        os.unlink(tmp)
        die(f'host ldid: SHA-256/size mismatch (got {got}, pinned {pin["sha256"]}): refusing to use it')
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)
    return path


# --- unpack helpers (never execute anything) ------------------------------------------------------------------------
def zstd_stream(path):
    p = subprocess.Popen(['zstd', '-dc', path], stdout=subprocess.PIPE)
    return p


def ar_members(path):
    """[(name, bytes)] of a .deb (ar archive)."""
    b = open(path, 'rb').read()
    if b[:8] != b'!<arch>\n':
        die(f'{path} is not an ar archive')
    off, out = 8, []
    while off + 60 <= len(b):
        name = b[off:off + 16].decode().strip().rstrip('/')
        size = int(b[off + 48:off + 58])
        out.append((name, b[off + 60:off + 60 + size]))
        off += 60 + size + (size & 1)
    return out


def open_tar_member(name, data):
    if name.endswith('.zst'):
        r = subprocess.run(['zstd', '-dc'], input=data, capture_output=True, check=True).stdout
        return tarfile.open(fileobj=io.BytesIO(r), mode='r:')
    return tarfile.open(fileobj=io.BytesIO(data), mode='r:*')


def safe_rel(name):
    n = os.path.normpath(name.lstrip('./')) if name not in ('.', './') else '.'
    if n.startswith('..') or os.path.isabs(n):
        die(f'unsafe path in archive: {name}')
    return n


class Stage:
    """A staging tree on disk plus the intended owner/mode of every path (the Mac user cannot chown)."""

    def __init__(self, root):
        self.root = root
        self.meta = {}                                 # rel -> [uid, gid, mode]

    def extract(self, tf, prefix_ok=None, skip=()):
        done = []
        for m in tf:
            rel = safe_rel(m.name)
            if rel == '.' or any(rel == s or rel.startswith(s + '/') for s in skip):
                continue
            if m.isdev() or m.isfifo():
                continue
            dst = os.path.join(self.root, rel)
            if m.isdir():
                os.makedirs(dst, exist_ok=True)
                os.chmod(dst, 0o755)
            else:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if os.path.lexists(dst):
                    os.unlink(dst)
                if m.issym():
                    os.symlink(m.linkname, dst)
                elif m.islnk():
                    os.link(os.path.join(self.root, safe_rel(m.linkname)), dst)
                else:
                    with open(dst, 'wb') as f:
                        shutil.copyfileobj(tf.extractfile(m), f)
                    os.chmod(dst, 0o755 if m.mode & 0o111 else 0o644)
            self.meta[rel] = [0, 0, m.mode & 0o7777]
            done.append((rel, m))
        return done

    def set_owner(self, rel, uid, gid, mode=None):
        cur = self.meta.get(rel, [0, 0, 0o755])
        self.meta[rel] = [uid, gid, cur[2] if mode is None else mode]

    def write_manifest(self, path):
        with open(path, 'w') as f:
            for rel in sorted(self.meta):
                u, g, m = self.meta[rel]
                f.write(f'{rel}\t{u}\t{g}\t{m:o}\n')


# --- Mach-O: arm64e -> pacstrip, ldid-style entitlements --------------------------------------------------------------
MACHO_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')


def macho_slices(path):
    """[(cpusubtype & 0xff)] of every arm64 slice, or None if path is not a Mach-O."""
    with open(path, 'rb') as f:
        head = f.read(4096)
    if head[:4] not in MACHO_MAGIC:
        return None
    out = []
    if head[:4] == b'\xcf\xfa\xed\xfe':
        ct, cs = struct.unpack_from('<ii', head, 4)
        if ct == pacstrip.CPU_TYPE_ARM64:
            out.append(cs & 0xff)
    else:
        n = struct.unpack_from('>I', head, 4)[0]
        for i in range(min(n, 8)):
            ct, cs = struct.unpack_from('>ii', head, 8 + 20 * i)
            if ct == pacstrip.CPU_TYPE_ARM64:
                out.append(cs & 0xff)
    return out


code_signature_blobs = pacstrip.code_signature_blobs
entitlements_xml = pacstrip.entitlements_xml


def strip_signature(path):
    """Drop LC_CODE_SIGNATURE of a thin Mach-O whose signature is the tail of the file (macOS codesign cannot replace
    the ldid-style signatures: 'internal error in Code Signing subsystem')."""
    b = bytearray(open(path, 'rb').read())
    if b[:4] != b'\xcf\xfa\xed\xfe':
        die(f'{path}: only thin Mach-O files are supported for signature stripping')
    ncmds, sizeofcmds = struct.unpack_from('<II', b, 16)
    off, cs, link = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, off)
        if cmd == pacstrip.LC_CODE_SIGNATURE:
            cs = (off, size, *struct.unpack_from('<II', b, off + 8))
        elif cmd == pacstrip.LC_SEGMENT_64 and bytes(b[off + 8:off + 18]) == b'__LINKEDIT\0\0\0\0\0\0'[:10]:
            link = off
        off += size
    if cs is None:
        return
    coff, csize, dataoff, datasize = cs
    # anything after the signature (TrollStore's CoreTrust trick appends data) goes away with it
    end = 32 + sizeofcmds
    b[coff:end - csize] = b[coff + csize:end]
    b[end - csize:end] = b'\0' * csize
    struct.pack_into('<II', b, 16, ncmds - 1, sizeofcmds - csize)
    if link is not None:
        # __LINKEDIT: vmsize (offset 32), fileoff (40), filesize (48) in the segment command
        link = link if link < coff else link - csize
        fileoff = struct.unpack_from('<Q', b, link + 40)[0]
        struct.pack_into('<Q', b, link + 48, dataoff - fileoff)
        struct.pack_into('<Q', b, link + 32, (dataoff - fileoff + 0x3fff) & ~0x3fff)
    open(path, 'wb').write(bytes(b[:dataoff]))


def resign(path, ident=None):
    """Ad-hoc re-sign keeping identifier, CS options and entitlements (codesign, or ldid on Linux)."""
    old = pacstrip.cs_identity(path)
    ents = entitlements_xml(path)
    strip_signature(path)
    if ents:
        plistlib.loads(ents)                          # must parse
    os.chmod(path, os.stat(path).st_mode | 0o200)
    try:
        rplat.adhoc_sign(path, ident or (old[0] if old else None), old[2] if old else None, ents, retries=1)
    except SystemExit as e:
        die(str(e))
    got = entitlements_xml(path)
    if ents and (got is None or plistlib.loads(got) != plistlib.loads(ents)):
        die(f'entitlements changed by re-sign of {path}')


def process_macho(stage, rel_paths, force_sign=(), idents=None):
    """arm64e slices -> pacstrip rewrite + re-sign; paths in force_sign are re-signed ad hoc even if plain arm64."""
    seen_inodes, stats = {}, Counter()
    for rel in rel_paths:
        p = os.path.join(stage.root, rel)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        sl = macho_slices(p)
        if sl is None:
            continue
        st = os.stat(p)
        if st.st_nlink > 1:
            if st.st_ino in seen_inodes:
                continue
            seen_inodes[st.st_ino] = rel
        want_pac = any(s == pacstrip.CPU_SUBTYPE_ARM64E for s in sl)
        if not want_pac and rel not in force_sign:
            stats['arm64 as is'] += 1
            continue
        if want_pac:
            buf = bytearray(open(p, 'rb').read())
            counts, fj = Counter(), []
            for base in pacstrip.slices(buf):
                pacstrip.process_slice(buf, base, True, False, os.path.basename(p), counts, fj)
            os.chmod(p, os.stat(p).st_mode | 0o200)
            open(p, 'wb').write(buf)
            stats['arm64e pacstrip'] += 1
        resign(p, (idents or {}).get(rel))
        stats['re-signed ad hoc'] += 1
    return stats


# --- dpkg database emulation (Sileo is unpacked here, not by dpkg) ----------------------------------------------------
def register_deb(stage, deb, files):
    """Write the dpkg database entries `dpkg -i` would: status stanza, info/<pkg>.{list,md5sums,postinst,...}."""
    members = dict(ar_members(deb))
    ctl_name = next(n for n in members if n.startswith('control.tar'))
    ctl = open_tar_member(ctl_name, members[ctl_name])
    control = ctl.extractfile('./control').read().decode().rstrip('\n')
    pkg = next(l.split(': ', 1)[1] for l in control.split('\n') if l.startswith('Package: '))
    info = os.path.join(stage.root, 'var/jb/Library/dpkg/info')
    os.makedirs(info, exist_ok=True)
    size_kb = sum(m.size for _, m in files if m.isreg()) // 1024
    lines = control.split('\n')
    lines.insert(1, 'Status: install ok installed')
    lines.insert(2, f'Installed-Size: {size_kb}')
    status = os.path.join(stage.root, 'var/jb/Library/dpkg/status')
    cur = open(status).read()
    if f'\nPackage: {pkg}\n' in '\n' + cur:
        cur = ''.join(s + '\n\n' for s in cur.split('\n\n') if s.strip() and not s.startswith(f'Package: {pkg}\n'))
    open(status, 'w').write(cur.rstrip('\n') + '\n\n' + '\n'.join(lines) + '\n\n')
    # .list: every path (dirs first), absolute, "/." for the root
    paths, md5 = ['/.'], []
    for rel, m in files:
        paths.append('/' + rel)
        if m.isreg():
            md5.append(f'{hashlib.md5(open(os.path.join(stage.root, rel), "rb").read()).hexdigest()}  {rel}')
    open(os.path.join(info, pkg + '.list'), 'w').write('\n'.join(paths) + '\n')
    open(os.path.join(info, pkg + '.md5sums'), 'w').write('\n'.join(md5) + '\n')
    for m in ctl.getmembers():
        n = os.path.basename(m.name)
        if n in ('postinst', 'prerm', 'postrm', 'preinst', 'triggers', 'conffiles') and m.isreg():
            dst = os.path.join(info, f'{pkg}.{n}')
            open(dst, 'wb').write(ctl.extractfile(m).read())
            os.chmod(dst, 0o755 if n.endswith(('inst', 'rm')) else 0o644)
            stage.meta[os.path.relpath(dst, stage.root)] = [0, 0, 0o755 if n.endswith(('inst', 'rm')) else 0o644]
    for ext in ('list', 'md5sums'):
        stage.meta[f'var/jb/Library/dpkg/info/{pkg}.{ext}'] = [0, 0, 0o644]
    return pkg


# --- on-device scripts ----------------------------------------------------------------------------------------------
POSTINSTALL = r'''#!/bin/sh
# Renegade jb: finish the install ON THE PHONE (live mode: run over SSH; image mode: run once by the first-boot
# LaunchDaemon). Idempotent. System /bin/sh, absolute paths only: nothing here relies on /var/jb being in PATH.
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
JB=/var/jb
SHARE=$JB/usr/share/renegade-jb
LOG=$SHARE/postinstall.log
exec >>"$LOG" 2>&1
echo "== postinstall $(date)"
set -x
# 1. the part of Procursus' prep_bootstrap.sh that makes sense non-interactively (no terminal-password prompt, the
#    login shells of the Mac-less phone stay as they are)
[ -x $JB/usr/libexec/firmware ] && $JB/usr/libexec/firmware
$JB/usr/sbin/pwd_mkdb -p $JB/etc/master.passwd >/dev/null 2>&1
for p in debianutils apt dash zsh bash vi; do
	[ -x $JB/Library/dpkg/info/$p.postinst ] && $JB/Library/dpkg/info/$p.postinst configure 999999
done
# apt source: the rootless Procursus suite for iOS 17/18
mkdir -p $JB/etc/apt/sources.list.d
cat >$JB/etc/apt/sources.list.d/procursus.sources <<EOF
Types: deb
URIs: https://apt.procurs.us/
Suites: @SUITE@
Components: main
EOF
# 2. LaunchServices registration of Sileo (System app, like every other app of this root)
[ -x /usr/local/bin/sweetuicache ] && /usr/local/bin/sweetuicache $JB/Applications/Sileo.app
# 3. TrollStore: the upstream installer (trollstorehelper install-trollstore, as root), then ldid
if ! ls /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper >/dev/null 2>&1; then
	T=/var/tmp/renegade-jb-ts
	rm -rf $T; mkdir -p $T && /usr/local/bin/tar xf $SHARE/TrollStore.tar -C $T
	chmod 755 $T/TrollStore.app/trollstorehelper
	$T/TrollStore.app/trollstorehelper install-trollstore $SHARE/TrollStore.tar
	rm -rf $T
fi
H=$(ls /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper 2>/dev/null | head -1)
[ -n "$H" ] && [ -f $SHARE/ldid ] && $H install-ldid $SHARE/ldid @LDID_VERSION@
touch $JB/.renegade-jb-done
echo "== postinstall done"
'''


def versions_text():
    return ''.join(f'{n}\t{p["sha256"]}\t{p["url"]}\n' for n, p in PINS.items())


# --- stage ----------------------------------------------------------------------------------------------------------
def stage_build():
    fetch()
    for n in PINS:                                     # verify again right before unpacking
        if not verify(n):
            die(f'{n}: cached file does not match the pinned SHA-256')
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE_ROOT)
    st = Stage(STAGE_ROOT)
    # 1. Procursus bootstrap (tar paths are ./var/jb/...). prep_bootstrap.sh is interactive: replaced by POSTINSTALL.
    log('unpacking the Procursus bootstrap')
    z = zstd_stream(cached('bootstrap'))
    with tarfile.open(fileobj=z.stdout, mode='r|') as tf:
        st.extract(tf, skip=['var/jb/prep_bootstrap.sh'])
    if z.wait():
        die('zstd failed')
    # 2. Sileo (the .deb is unpacked here and registered in the dpkg database)
    log('unpacking Sileo')
    members = dict(ar_members(cached('sileo')))
    dn = next(n for n in members if n.startswith('data.tar'))
    files = st.extract(open_tar_member(dn, members[dn]))
    pkg = register_deb(st, cached('sileo'), [(r, m) for r, m in files])
    log(f'registered {pkg} in the dpkg database')
    sileo = 'var/jb/Applications/Sileo.app'
    st.set_owner(sileo + '/giveMeRoot', 0, 0, 0o4755)           # Sileo runs apt/dpkg through this setuid-root helper
    os.chmod(os.path.join(STAGE_ROOT, sileo, 'giveMeRoot'), 0o755)
    # mobile owns its home inside the jb root
    st.set_owner('var/jb/var/mobile', 501, 501, 0o755)
    # 3. TrollStore: rebuild the tar with the Mach-Os re-signed ad hoc (the upstream signatures rely on a CoreTrust bug;
    #    this kernel accepts ad hoc with any entitlements), keep the entitlements
    log('preparing TrollStore')
    ts = Stage(os.path.join(STAGE, 'ts'))
    os.makedirs(ts.root)
    ts.extract(tarfile.open(cached('trollstore')))
    tsm = process_macho(ts, sorted(ts.meta), force_sign={r for r in ts.meta if r.startswith('TrollStore.app/')},
                        # the upstream signatures carry a borrowed App Store identifier (CoreTrust trick)
                        idents={'TrollStore.app/TrollStore': 'com.opa334.TrollStore',
                                'TrollStore.app/trollstorehelper': 'com.opa334.trollstorehelper',
                                'TrollStore.app/PersistenceHelper': 'com.opa334.TrollStorePersistenceHelper'})
    log('TrollStore Mach-Os:', dict(tsm))
    share = os.path.join(STAGE_ROOT, SHARE)
    os.makedirs(share)
    write_tar(ts, os.path.join(share, 'TrollStore.tar'))
    shutil.copy(cached('ldid'), os.path.join(share, 'ldid'))
    open(os.path.join(share, 'postinstall.sh'), 'w').write(
        POSTINSTALL.replace('@SUITE@', APT_SUITE).replace('@LDID_VERSION@', LDID_VERSION))
    open(os.path.join(share, 'VERSIONS'), 'w').write(versions_text())
    for n, mode in (('TrollStore.tar', 0o644), ('ldid', 0o644), ('postinstall.sh', 0o755), ('VERSIONS', 0o644)):
        st.meta[f'{SHARE}/{n}'] = [0, 0, mode]
        os.chmod(os.path.join(share, n), mode)
    st.meta[SHARE] = [0, 0, 0o755]
    # 4. everything else: Procursus arm64e (none today) and Sileo's binaries
    stats = process_macho(st, sorted(st.meta))
    log('Mach-O:', dict(stats))
    st.write_manifest(MANIFEST)
    log(f'staged {len(st.meta)} paths in {STAGE_ROOT}; owners/modes in {MANIFEST}')
    return st


def load_manifest():
    if not os.path.exists(MANIFEST):
        stage_build()
    t = {}
    for line in open(MANIFEST):
        k, u, g, m = line.rstrip('\n').split('\t')
        t[k] = [int(u), int(g), int(m, 8)]
    return t


def arcname(rel, image):
    """Name of a stage path inside the tar. Image mode (a mounted root volume, not the running phone): /var is a
    symlink to private/var on the root, so /var/jb is written as private/var/jb and the `var` symlink is never
    touched (extracting a `var` directory entry or a path through a replaced symlink is what once broke it)."""
    return 'private/' + rel if image else rel


def write_tar(st, out_path_or_fileobj, only=None, image=False):
    """Deterministic tar of a Stage (owners/modes from st.meta; hard links kept). image=True: see arcname()."""
    close = isinstance(out_path_or_fileobj, str)
    tf = tarfile.open(out_path_or_fileobj, 'w' if close else 'w|', format=tarfile.GNU_FORMAT) if close else \
        tarfile.open(fileobj=out_path_or_fileobj, mode='w|', format=tarfile.GNU_FORMAT)
    seen = {}
    for rel in sorted(st.meta):
        # NEVER emit an entry for /var (a symlink on the phone: extracting a `var` directory entry over it breaks the
        # system, this locked SSH out once) or for anything else outside /var/jb and Library/LaunchDaemons
        if rel != 'var/jb' and not rel.startswith('var/jb/') and not rel.startswith('Library/LaunchDaemons/'):
            continue
        p = os.path.join(st.root, rel)
        s = os.lstat(p)
        ti = tarfile.TarInfo(arcname(rel, image))
        ti.uid, ti.gid, ti.mode = st.meta[rel]
        ti.uname = ti.gname = ''
        ti.mtime = 1700000000
        if os.path.islink(p):
            ti.type, ti.linkname = tarfile.SYMTYPE, os.readlink(p)
            tf.addfile(ti)
        elif os.path.isdir(p):
            ti.type = tarfile.DIRTYPE
            tf.addfile(ti)
        elif s.st_nlink > 1 and s.st_ino in seen:
            ti.type, ti.linkname = tarfile.LNKTYPE, arcname(seen[s.st_ino], image)
            tf.addfile(ti)
        else:
            seen[s.st_ino] = rel
            ti.size = s.st_size
            with open(p, 'rb') as f:
                tf.addfile(ti, f)
    tf.close()


# --- live / dry-run ---------------------------------------------------------------------------------------------------
def ssh(cmd, **kw):
    return subprocess.run(SSH + [HOST, PHONE_PATH + cmd], **kw)


def phone_free_kb():
    r = ssh('df -k /var', capture_output=True, text=True)
    try:
        return int(r.stdout.strip().split('\n')[-1].split()[3])
    except (ValueError, IndexError):
        die('cannot read free space on the phone: ' + r.stdout + r.stderr)


def live(a):
    st = Stage(STAGE_ROOT)
    st.meta = load_manifest()
    cmds = [
        'mkdir -p /var/jb',
        '/usr/local/bin/tar xf - -C /          # <- the install tar (written below)',
        '/bin/sh /var/jb/usr/share/renegade-jb/postinstall.sh',
        'cat /var/jb/usr/share/renegade-jb/postinstall.log | tail -40',
    ]
    if a.dry_run:
        d = os.path.abspath(a.dry_run)
        if os.path.exists(d) and os.listdir(d):
            die(f'{d} is not empty')
        os.makedirs(d, exist_ok=True)
        buf = io.BytesIO()
        write_tar(st, buf)
        buf.seek(0)
        with tarfile.open(fileobj=buf, mode='r:') as tf:
            tf.extractall(d, filter='fully_trusted')
        log(f'DRY RUN: unpacked the install tar into {d}; no connection to the phone was made. Remote steps:')
        for c in cmds:
            print('   ssh phone:', c)
        return
    if os.environ.get('RENEGADE_JB_LIVE_OK') != '1':
        die('live install is disabled until the kernel is declared safe for userdata writes: '
            'set RENEGADE_JB_LIVE_OK=1 to override (or use --dry-run DIR)')
    if ssh('true').returncode:
        die('phone not reachable over SSH')
    free = phone_free_kb()
    if free < MIN_PHONE_FREE_KB:
        die(f'only {free // 1024} MiB free on the phone (< 1 GiB)')
    if ssh('[ -e /var/jb ]').returncode == 0 and not a.reinstall:
        die('/var/jb exists: `renegade jb remove` first, or pass --reinstall')
    if a.reinstall:
        remove(argparse.Namespace(dry_run=False))
    log('streaming the install tar')
    p = subprocess.Popen(SSH + [HOST, PHONE_PATH + 'mkdir -p /var/jb && /usr/local/bin/tar xf - -C / 2>&1'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=False)
    write_tar(st, p.stdin)
    p.stdin.close()
    out = p.stdout.read().decode(errors='replace')
    if 'Input/output error' in out:
        die('EIO while extracting on the phone: aborting (nothing else is touched)\n' + out[-500:])
    if p.wait():
        die('extracting on the phone failed: ' + out[-500:])
    verify_phone(st)
    log('post-install on the phone (log: /var/jb/usr/share/renegade-jb/postinstall.log)')
    r = ssh('/bin/sh /var/jb/usr/share/renegade-jb/postinstall.sh; tail -60 /var/jb/usr/share/renegade-jb/postinstall.log')
    sys.exit(r.returncode)


def verify_phone(st, rounds=3):
    """sha256 of every regular file on the phone against the stage; re-push what differs (abort on EIO)."""
    sums = {}
    for rel in st.meta:
        p = os.path.join(st.root, rel)
        if os.path.isfile(p) and not os.path.islink(p):
            sums[rel] = sha256_file(p)
    for rnd in range(rounds):
        lst = ''.join(f'{h}  /{rel}\n' for rel, h in sorted(sums.items()))
        r = ssh('/usr/local/bin/sha256sum -c - 2>&1 | /usr/local/bin/grep -v ": OK$"', input=lst, capture_output=True, text=True)
        if 'Input/output error' in r.stdout + r.stderr:
            die('EIO on the phone while verifying: aborting')
        bad = sorted({l.split(': ')[0].lstrip('/') for l in r.stdout.splitlines() if ': ' in l})
        if not bad:
            log(f'verified {len(sums)} files by sha256 on the phone')
            return
        log(f'{len(bad)} files differ (round {rnd + 1}), re-pushing: {bad[:5]}')
        sub = Stage(st.root)
        sub.meta = {k: st.meta[k] for k in bad if k in st.meta}
        p = subprocess.Popen(SSH + [HOST, PHONE_PATH + '/usr/local/bin/tar xf - -C / 2>&1'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE)
        write_tar(sub, p.stdin)
        p.stdin.close()
        o = p.stdout.read().decode(errors='replace')
        if 'Input/output error' in o:
            die('EIO while re-pushing: aborting')
        p.wait()
    die('files still differ after re-pushing; stopping')


REMOVE = r'''
S=/usr/local/bin/sweetuicache
[ -x $S ] && $S -u /var/jb/Applications/Sileo.app
H=$(ls /var/containers/Bundle/Application/*/TrollStore.app/trollstorehelper 2>/dev/null | head -1)
[ -n "$H" ] && $H uninstall-trollstore
rm -rf /var/jb /var/tmp/renegade-jb-ts
echo removed
'''


def remove(a):
    if a.dry_run:
        print('would run on the phone:' + REMOVE)
        return
    if os.environ.get('RENEGADE_JB_LIVE_OK') != '1':
        die('device writes are disabled (RENEGADE_JB_LIVE_OK=1 to override)')
    r = ssh(REMOVE)
    log('TrollStore-installed apps (if any) stay: they are user data; remove them in TrollStore first')
    sys.exit(r.returncode)


def status(a):
    r = ssh('ls -ld /var/jb /var/jb/Applications/Sileo.app 2>&1; ls -d /var/containers/Bundle/Application/*/TrollStore.app 2>&1; '
            '/var/jb/usr/bin/dpkg -l 2>/dev/null | /usr/bin/head -5')
    sys.exit(r.returncode)


def image_stage(root, owners_out):
    """mkroot-full.py stage `jb` / `renegade update`: copy the stage into the mounted root volume at /private/var/jb
    (/var is a symlink to private/var there and stays one) and write the owner map for hfsroot_owners.py.
    The first-boot work (Sileo/TrollStore registration, TrollStore install) is done by the first-boot job of
    root_tweaks18.firstboot(), which runs postinstall.sh."""
    st = Stage(STAGE_ROOT)
    st.meta = load_manifest()
    var = os.path.join(root, 'var')
    if not os.path.islink(var):
        die(f'{var} is not a symlink: this is not an iOS root volume')
    target = os.readlink(var)
    buf = io.BytesIO()
    write_tar(st, buf, image=True)
    buf.seek(0)
    with tarfile.open(fileobj=buf, mode='r:') as tf:
        tf.extractall(root, filter='fully_trusted')    # owners are not applied (no root): the map below does it
    if not os.path.islink(var) or os.readlink(var) != target:
        die('/var is no longer the symlink it was: aborting')
    if not os.path.isdir(os.path.join(root, 'private/var/jb')):
        die('private/var/jb missing after the copy')
    import unicodedata
    n = 0
    with open(owners_out, 'w', encoding='utf-8') as f:
        for rel in sorted(st.meta):
            if rel != 'var/jb' and not rel.startswith('var/jb/'):
                continue                               # never an owner entry for /var or other parents
            u, g, m = st.meta[rel]
            f.write(f'{unicodedata.normalize("NFD", arcname(rel, True))}\t{u}\t{g}\t{m:o}\n')
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('fetch')
    sub.add_parser('stage')
    s = sub.add_parser('live')
    s.add_argument('--dry-run', metavar='DIR')
    s.add_argument('--reinstall', action='store_true')
    s = sub.add_parser('remove')
    s.add_argument('--dry-run', action='store_true')
    sub.add_parser('status')
    a = ap.parse_args()
    if a.cmd == 'fetch':
        fetch()
        if rplat.name() == 'linux':
            host_ldid()
    elif a.cmd == 'stage':
        stage_build()
    elif a.cmd == 'live':
        live(a)
    elif a.cmd == 'remove':
        remove(a)
    else:
        status(a)


if __name__ == '__main__':
    main()
