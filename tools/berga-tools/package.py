#!/usr/bin/env python3
"""Collect the prebuilt on-device binaries into berga-tools.zip (+ berga-tools.zip.sha256). Standard library only.

  package.py [--version N] [--out DIR] [--sweetnet DIR] [--bgl DIR] [--ssh DIR] [--bgl-commit SHA]

Inputs (nothing is built here; tools/berga-tools/package.sh runs tools/sweetnet/build.sh first):
  --sweetnet  research/sweetnet     build.sh output
  --bgl       research/bergamota-gl the gpu-eagl branch's gpu/eagl/make-payload.sh output ($RENEGADE_BGL, or the gpu-eagl worktree)
  --ssh       research/ssh-build/out tools/ssh/build.sh output (this checkout, else the main checkout)
Layout of the zip (what `renegade fetch-tools` extracts, and root_tweaks18.py searches):
  berga-tools.json   manifest: version, tag, commit, per-file sha256/size/arch
  sweetnet/...       same relative paths as research/sweetnet
  bergamota-gl/...   same relative paths as research/bergamota-gl
  ssh/...            dropbear, dash, toybox (iOS builds only) from research/ssh-build/out
  LICENSES/...       NOTICE.txt, Mesa-MIT.txt, libdrm-MIT.txt

Only the files in the ALLOWLIST below can go in. Everything is checked before the zip is written (a Mach-O of the right CPU,
linking only system libraries by path, no name that looks like firmware, an image or a dump) and the finished zip is read back
and checked against its own manifest and the allowlist. Any failure: exit 1, no zip left behind.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools', 'renegade'))
import berga_tools  # noqa: E402

# (zip prefix, kind) -> relative paths. kind: 'macho' must be a Mach-O, 'data' a plain file (Info.plist, CodeResources).
SWEETNET = [
    ('bluetool-stub', 'macho'), ('cscheck', 'macho'), ('hcitest', 'macho'), ('sweetnetcfg', 'macho'),
    ('sweetreboot', 'macho'), ('sweetuicache', 'macho'),
    ('ios18/sweetprefs', 'macho'), ('ios18/sweetuicache', 'macho'), ('ios18/sweetfp.dylib', 'macho'),
    ('ios18/sweetmetrics', 'macho'), ('ios18/sweetposterset', 'macho'), ('ios18/sweeticonstyle', 'macho'),
    ('ios18/sweetopen', 'macho'), ('ios18/sweetshot', 'macho'), ('ios18/sweettouch', 'macho'),
    ('ios18/sweetsample', 'macho'), ('ios18/sweetlog', 'macho'),
    ('ios18/SweetRun.app/SweetRun', 'macho'), ('ios18/SweetRun.app/Info.plist', 'data'),
    ('ios18/SweetRun.app/_CodeSignature/CodeResources', 'data'),
]
BGL = [('bgl-launch', 'macho'), ('OpenGLES.framework/OpenGLES', 'macho'), ('libOSMesa.8.dylib', 'macho'),
       ('libdrm.2.dylib', 'macho')]
# third-party, unmodified apart from tools/ssh/*.patch: dropbear 2026.94, dash 0.5.13.5, toybox 0.8.15 (licenses below)
SSH = [('dropbear', 'macho'), ('dash', 'macho'), ('toybox', 'macho')]
LICENSES = ['NOTICE.txt', 'Mesa-MIT.txt', 'libdrm-MIT.txt', 'dropbear-LICENSE.txt', 'dash-COPYING.txt', 'toybox-LICENSE.txt']
# Names that mean "not ours": Qualcomm GPU/vendor firmware, images, caches, dumps. Checked on every path that goes in.
DENY = re.compile(r'(zap|gmu|sqe|\.mbn|\.fw$|\.elf$|\.bin$|\.mdt|a6\d\d|dyld_shared_cache|\.dsc|\.ipsw|\.dmg|\.img|\.simg|\.dtb|'
                  r'\.adt|\.im4p|\.aea|persist|modemst|fsg|serial|\.kc$|kernelcache|firmware)', re.I)
SYSTEM_PREFIXES = ('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/', '@executable_path/')
ZIP_TIME = (2026, 1, 1, 0, 0, 0)

CPU_ARM64 = 0x0100000C
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB = 0xC, 0x80000018, 0x8000001F, 0x80000023
LC_ID_DYLIB, LC_LC_SEGMENT_64 = 0xD, 0x19


def die(msg):
    sys.exit('package.py: ' + msg)


def macho_info(data, name):
    """([archs], [linked dylib paths]) of a thin or fat Mach-O (64-bit arm64/arm64e only), or a ValueError."""
    magic = struct.unpack('>I', data[:4])[0]
    slices = []
    if magic == 0xCAFEBABE:
        n = struct.unpack('>I', data[4:8])[0]
        for i in range(n):
            _, _, off, size, _ = struct.unpack('>5I', data[8 + 20 * i:28 + 20 * i])
            slices.append(data[off:off + size])
    elif struct.unpack('<I', data[:4])[0] == 0xFEEDFACF:
        slices.append(data)
    else:
        raise ValueError('%s is not a 64-bit Mach-O' % name)
    archs, libs = [], []
    for s in slices:
        _, cputype, cpusub, _, ncmds, _, _, _ = struct.unpack('<8I', s[:32])
        if cputype != CPU_ARM64:
            raise ValueError('%s: cputype %#x is not arm64' % (name, cputype))
        sub = cpusub & 0xFF
        if sub not in (0, 2):
            raise ValueError('%s: arm64 subtype %d is neither arm64 nor arm64e' % (name, sub))
        archs.append('arm64e' if sub == 2 else 'arm64')
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack('<II', s[off:off + 8])
            if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB):
                nameoff = struct.unpack('<I', s[off + 8:off + 12])[0]
                libs.append(s[off + nameoff:off + size].split(b'\0')[0].decode())
            off += size
    return sorted(set(archs)), libs


def check_name(rel):
    if DENY.search(rel):
        die('%s: the name looks like firmware, an image or a dump; refused' % rel)
    berga_tools.safe_rel(rel)


def collect(sweetnet, bgl, ssh):
    """[(zip path, source path, role, arch(s) or 'data', [libs])] for every allowlisted file; dies on anything unexpected."""
    out = []
    for prefix, base, items in (('sweetnet', sweetnet, SWEETNET), ('bergamota-gl', bgl, BGL), ('ssh', ssh, SSH)):
        if not base or not os.path.isdir(base):
            die('%s directory not found: %s' % (prefix, base))
        for rel, kind in items:
            zp = prefix + '/' + rel
            check_name(zp)
            src = os.path.join(base, *rel.split('/'))
            if not os.path.isfile(src) or os.path.islink(src):
                die('missing (or a symlink): %s' % src)
            data = open(src, 'rb').read()
            if kind == 'macho':
                try:
                    archs, libs = macho_info(data, zp)
                except (ValueError, struct.error) as e:
                    die(str(e))
                bad = [l for l in libs if not l.startswith(SYSTEM_PREFIXES)]
                if bad:
                    die('%s links %s: only system libraries by path and @rpath/@loader_path are allowed' % (zp, bad))
                out.append((zp, src, prefix, '+'.join(archs), libs))
            else:
                if b'\0' in data[:512] and not zp.endswith('CodeResources'):
                    die('%s is not a text file' % zp)
                out.append((zp, src, prefix, 'data', []))
    for l in LICENSES:
        zp = 'LICENSES/' + l
        out.append((zp, os.path.join(HERE, 'LICENSES', l), 'license', 'data', []))
        if not os.path.isfile(out[-1][1]):
            die('missing ' + out[-1][1])
    return out


def git(*a, cwd=REPO):
    try:
        return subprocess.run(['git', '-C', cwd] + list(a), capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def build(args):
    items = collect(args.sweetnet, args.bgl, args.ssh)
    commit = git('rev-parse', 'HEAD')
    dirty = bool(git('status', '--porcelain', '--untracked-files=no'))
    bgl_commit = args.bgl_commit or git('rev-parse', 'HEAD', cwd=os.path.abspath(os.path.join(args.bgl, '..', '..')))
    files = []
    for zp, src, role, arch, libs in items:
        data = open(src, 'rb').read()
        e = {'path': zp, 'sha256': sha256(data), 'size': len(data), 'arch': arch, 'role': role}
        if libs:
            e['links'] = libs
        files.append(e)
    files.sort(key=lambda e: e['path'])
    manifest = {
        'schema': 1, 'name': 'berga-tools', 'version': str(args.version), 'tag': 'berga-tools-v%s' % args.version,
        'repo': 'ry-diffusion/Bergamota', 'commit': commit, 'dirty': dirty,
        'bergamota_gl_source_commit': bgl_commit,
        'built_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'built_with': (subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], capture_output=True,
                                      text=True).stdout.strip() or None) if sys.platform == 'darwin' else None,
        'files': files,
    }
    os.makedirs(args.out, exist_ok=True)
    zpath = os.path.join(args.out, berga_tools.ASSET)
    tmp = zpath + '.tmp'
    try:
        with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            def add(name, data, mode):
                zi = zipfile.ZipInfo(name, ZIP_TIME)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = (0o100000 | mode) << 16
                zf.writestr(zi, data)
            add(berga_tools.MANIFEST, (json.dumps(manifest, indent=1) + '\n').encode(), 0o644)
            for zp, src, role, arch, libs in sorted(items):
                st = os.stat(src)
                add(zp, open(src, 'rb').read(), 0o755 if (st.st_mode & 0o111) else 0o644)
        verify(tmp, items)
        os.replace(tmp, zpath)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    digest = berga_tools.sha256_file(zpath)
    with open(zpath + '.sha256', 'w') as f:
        f.write('%s  %s\n' % (digest, berga_tools.ASSET))
    return zpath, digest, manifest


def verify(zpath, items):
    """Read the finished zip back: manifest vs contents (renegade's own check), the allowlist, the deny list, no Apple/Qualcomm
    looking names, and again that every Mach-O is arm64/arm64e."""
    allowed = {zp for zp, *_ in items} | {berga_tools.MANIFEST}
    with zipfile.ZipFile(zpath) as zf:
        bad = zf.testzip()
        if bad:
            die('corrupt member ' + bad)
        names = {i.filename for i in zf.infolist() if not i.is_dir()}
        if names != allowed:
            die('zip contents differ from the allowlist: extra %s, missing %s' % (sorted(names - allowed), sorted(allowed - names)))
        for n in names:
            check_name(n)
        manifest = berga_tools.read_manifest(zf)
        berga_tools.verify_zip(zf, manifest)
        for i in zf.infolist():
            data = zf.read(i.filename)
            if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                macho_info(data, i.filename)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--version', default=os.environ.get('BERGA_TOOLS_VERSION', '1'))
    ap.add_argument('--out', default=os.path.join(REPO, 'research', 'berga-tools-out'))
    ap.add_argument('--sweetnet', default=os.path.join(REPO, 'research', 'sweetnet'))
    ap.add_argument('--bgl', default=os.environ.get('RENEGADE_BGL') or os.path.join(REPO, 'research', 'bergamota-gl'))
    ap.add_argument('--ssh', default=next((d for d in (os.path.join(REPO, 'research', 'ssh-build', 'out'),
                                                       os.path.join(REPO, '..', 'ios-beryllium', 'research', 'ssh-build', 'out'))
                                            if os.path.isdir(d)), None))
    ap.add_argument('--bgl-commit', help='commit of the gpu-eagl checkout the payload was built from (default: HEAD of the checkout '
                                         'two levels above --bgl)')
    args = ap.parse_args()
    if not re.fullmatch(r'\d+', str(args.version)):
        die('--version must be a number (the tag is berga-tools-vN)')
    zpath, digest, m = build(args)
    print('%s  %s' % (digest, zpath))
    print('commit %s%s, gpu-eagl %s' % (m['commit'], ' (DIRTY)' if m['dirty'] else '', m['bergamota_gl_source_commit']))
    print('%-58s %10s  %s' % ('file', 'bytes', 'arch'))
    for e in m['files']:
        print('%-58s %10d  %s' % (e['path'], e['size'], e['arch']))
    print('zip: %d bytes, %d files + manifest' % (os.path.getsize(zpath), len(m['files'])))


if __name__ == '__main__':
    main()
