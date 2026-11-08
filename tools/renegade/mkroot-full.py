#!/usr/bin/env python3
"""Renegade root build (`renegade root`): build the FULL iOS root of the Renegade target (targets.py: 26.6.2 iPhone12,1 by default, RENEGADE_TARGET=ios18 for 18.7.8 iPhone11,8) as a flashable HFS+ image for the userdata partition.

  mkroot-full.py [--ipsw-dir DIR] [--out IMG] [--size 20g] [--stages copy,macho,cache,tweaks,seal] [--simg OUT.simg]

macOS: no sudo. Linux: run as root (loop device + mount), IPSW volumes through apfs-fuse; see README.md "Linux".
RENEGADE_DRY_RUN=1 prints the platform commands of the chosen stages and runs nothing. Platform specifics live in
renegade_platform.py. Stages (each one can be re-run on the same image; the image stays in --out between stages):
  copy    attach the IPSW volumes read-only (OS dmg, SystemOS cryptex, AppOS cryptex; decrypt them first with
          tools/renegade/fetch-root.sh), newfs_hfs -s / mkfs.hfsplus -s (case-sensitive, NOT journaled: hfsroot_owners.py
          edits the catalog), mount the image, ditto (Linux: Python copy) OS-cryptex and App-cryptex FIRST and the OS volume on top
          (root files win), layout fixes (cache at /System/Library/Caches/com.apple.dyld, /System/Cryptexes/*
          -> merged view), owner/mode map of everything (lstat of the mounted IPSW volumes, owners on)
  macho   pacstrip + ad-hoc codesign / ldid (entitlements kept) of every Mach-O, in parallel, hard links kept
  cache   tools/renegade/pacstrip_cache.py over the dyld shared cache (code sections, signature page hashes)
  tweaks  the iOS 16 first-boot tweaks (root_tweaks18.py = sweet-root-tweaks.py) + iOS 18 launchd bring-up jobs +
          the Renegade auto-fixes (all ON, opt-outs --no-appreg --no-posterboard --no-bluetooth --no-jb): staged apps
          moved to /Applications, first-boot job that registers them (sweetuicache), PosterBoard + sweetfp.dylib,
          bluetooth (bluetoothd env, BlueTool stub, hcitest). Build the tools first: tools/sweetnet/build.sh
          An existing image gets the same changes in place with `renegade update` (tools/renegade/update.py)
  jb      ON by default (--no-jb / RENEGADE_NO_JB=1 / RENEGADE_JB=0 to skip; inserted before seal when the stages
          list has none): the jailbreak userland, see tools/renegade/jailbreak.py: /private/var/jb (Procursus rootless
          bootstrap, /var stays a symlink), Sileo, the TrollStore payload; the first-boot job runs its post-install
  seal    unmount, hfsroot_owners.py (real owners/modes, the rest root:wheel), fsck_hfs, offline checks,
          img2simg --consume (the raw image is turned into the .simg, see tools/renegade/img2simg.py)
Disk is tight: every stage checks `df` and stops below 5 GiB free.
"""
import argparse
import os
import struct
import shutil
import subprocess
import sys
import time
import unicodedata
from collections import Counter
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import pacstrip  # noqa: E402
import renegade_platform as rplat  # noqa: E402
from targets import T as TARGET  # noqa: E402

MAGICS = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
MIN_FREE = int(os.environ.get('RENEGADE_MIN_FREE_GB', '5')) << 30     # free-space floor kept on the host disk
W = os.path.join(ROOT, TARGET['work'], 'full')             # work dir (mount points, map)


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)


def free_bytes(path=ROOT):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def need_free(what):
    fb = free_bytes()
    log(f'free disk: {fb / 2**30:.1f} GiB ({what})')
    if fb < MIN_FREE:
        sys.exit(f'STOP: only {fb / 2**30:.1f} GiB free (< {MIN_FREE >> 30} GiB) before {what}')


def attach(img, mnt, readonly=True, owners=False):
    """Mount a raw volume image (the HFS root, or an IPSW dmg with attach_ipsw); platform layer: hdiutil / loop+mount."""
    return rplat.attach(img, mnt, readonly=readonly, owners=owners)


def detach(dev):
    rplat.detach(dev)


def find_dmgs(d):
    """OS, SystemOS and AppOS dmgs by BuildManifest path (decrypted names without .aea)."""
    import plistlib
    mf = None
    for c in (os.path.join(d, 'BuildManifest.plist'), os.path.join(os.path.dirname(d), 'BuildManifest.plist')):
        if os.path.exists(c):
            mf = c
            break
    m = plistlib.load(open(mf, 'rb'))['BuildIdentities'][0]['Manifest']
    out = {}
    for key, name in (('OS', 'os'), ('Cryptex1,SystemOS', 'sysos'), ('Cryptex1,AppOS', 'appos')):
        p = m[key]['Info']['Path']
        if p.endswith('.aea'):
            p = p[:-4]
        out[name] = os.path.join(d, p)
    return out


def walk_owners(mnt, table):
    """lstat() of everything under mnt into table[relpath NFD] = (uid, gid, perm bits)."""
    n = 0
    for root, dirs, files in os.walk(mnt):
        rel = os.path.relpath(root, mnt)
        rel = '' if rel == '.' else rel
        for name in dirs + files:
            p = os.path.join(root, name)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            r = (rel + '/' + name) if rel else name
            if '\t' in r or '\n' in r:
                continue
            table[unicodedata.normalize('NFD', r)] = (st.st_uid, st.st_gid, st.st_mode & 0o7777)
            n += 1
    st = os.lstat(mnt)
    table[''] = (st.st_uid, st.st_gid, st.st_mode & 0o7777)
    return n


def write_map(table, path):
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        for k in sorted(table):
            u, g, m = table[k]
            f.write(f'{k}\t{u}\t{g}\t{m:o}\n')


def load_map(path):
    t = {}
    for line in open(path, encoding='utf-8', errors='surrogateescape'):
        k, u, g, m = line.rstrip('\n').split('\t')
        t[k] = (int(u), int(g), int(m, 8))
    return t


# --- stage: copy ----------------------------------------------------------------------------------------------------
def apparent_size(mnt):
    tot = 0
    for r, d, fs in os.walk(mnt):
        for f in fs:
            try:
                st = os.lstat(os.path.join(r, f))
            except OSError:
                continue
            if (st.st_mode & 0o170000) == 0o100000:
                tot += st.st_size
    return tot


EXCLUDE = {
    # path -> why (disk is tight: 5 GiB free floor on the 27 GiB Mac while the 7 GiB OS dmg is still attached)
    'usr/standalone/update': 'OTA update ramdisk firmware, 206 MB',
    'System/Library/NanoTimeKit': 'Apple Watch face resources, 284 MB',
}


def copy_tree(src, dst):
    """ditto (macOS) / Python copy (Linux) of src into dst, minus EXCLUDE. Returns (rc, stderr)."""
    return rplat.copy_tree(src, dst, list(EXCLUDE))


def stage_copy(a, img, rootmnt, dmgs):
    """Per source: owners-on mount (owner map; root-only files are unreadable there), then a noowners mount for
    the copy (every file readable by the user). The cryptexes go in first, the OS volume on top."""
    need_free('copy stage')
    if os.path.exists(JB_OWNERS):
        os.unlink(JB_OWNERS)
    for k, v in dmgs.items():
        if not os.path.exists(v) and k not in (a.skip_sources or '').split(','):
            sys.exit(f'missing {k} dmg {v}: run tools/renegade/fetch-root.sh')
    table = {}
    skip = set(a.skip_sources.split(',')) if a.skip_sources else set()
    if skip:                                     # resume: the image already holds those sources
        if not os.path.ismount(rootmnt):
            attach(img, rootmnt, readonly=False)
    else:
        if os.path.exists(img):
            detach_all(img)
            os.unlink(img)
        rplat.make_image(img, a.size)
        rplat.format_hfsx(img, 'iOSRoot')          # case-sensitive (HFSX), NOT journaled: hfsroot_owners.py edits the catalog
        attach(img, rootmnt, readonly=False)
    log('image mounted at', rootmnt)
    for name in ('appos', 'sysos', 'os'):
        if name in skip:
            continue
        mnt = os.path.join(W, 'src-' + name)
        dev = rplat.attach_ipsw(dmgs[name], mnt, owners=True)
        n = walk_owners(mnt, table)
        size = apparent_size(mnt) - sum(apparent_size(os.path.join(mnt, e)) for e in EXCLUDE
                                        if os.path.isdir(os.path.join(mnt, e)))
        if not rplat.is_linux():
            detach(dev)             # macOS: owners-on mounts hide root-only files, so the copy uses a second, noowners mount
        log(f'owner map: {name} {n} entries, {size / 2**30:.2f} GiB apparent')
        if free_bytes() < size + MIN_FREE:
            sys.exit(f'STOP: copying {name} ({size / 2**30:.1f} GiB) would leave < {MIN_FREE >> 30} GiB free '
                     f'({free_bytes() / 2**30:.1f} GiB free now)')
        if not rplat.is_linux():
            dev = rplat.attach_ipsw(dmgs[name], mnt, owners=False)
        t0 = time.time()
        rc, err = copy_tree(mnt, rootmnt)
        detach(dev)
        lines = [l for l in err.splitlines() if l.strip()]
        # OS-volume symlinks like Frameworks/WebKit.framework -> /System/Cryptexes/OS/... meet the real directory
        # of the merged cryptex: ditto says "Is a directory" and leaves the directory, which is what we want
        real = [l for l in lines if not l.endswith('Is a directory') and not l.endswith('/.file: Permission denied')]
        log(f'ditto {name}: rc={rc} {time.time() - t0:.0f}s, {len(lines)} messages ({len(lines) - len(real)} '
            f'symlink-vs-directory, kept as directories)', '; '.join(real)[:2000])
        if rc and real:
            sys.exit(f'ditto {name} failed')
        prune_after(rootmnt, name)
        if name == 'sysos':                          # give the pruned .symbols blocks back to the host
            subprocess.run(['sync'])
            rplat.detach(rootmnt, check=True)
            run([sys.executable, '-I', os.path.join(HERE, 'hfs_trim.py'), img])
            attach(img, rootmnt, readonly=False)
        if a.delete_sources:
            os.unlink(dmgs[name])
            log('deleted', dmgs[name])
        subprocess.run(['df', '-h', rootmnt, ROOT])
    if skip:
        prev = os.path.join(W, 'owners.tsv')
        old = load_map(prev) if os.path.exists(prev) else {}
        old.update(table)
        table = old
    write_map(table, os.path.join(W, 'owners.tsv'))
    layout_fixes(rootmnt)


def detach_all(img):
    """detach every device that was attached from this image path"""
    rplat.detach_image(img)


def prune_after(root, name):
    """Things that are dead weight on the phone (disk is tight, and so is the flash)."""
    if name == 'sysos':
        # 870 MB of local symbols for symbolication; dyld does not read it
        for f in os.listdir(os.path.join(root, 'System/Library/Caches/com.apple.dyld')):
            if f.endswith('.symbols'):
                os.unlink(os.path.join(root, 'System/Library/Caches/com.apple.dyld', f))
                log('removed cache', f)
    if name == 'os':
        shutil.rmtree(os.path.join(root, 'usr/standalone/update'), ignore_errors=True)   # OTA ramdisk firmware, 206 MB


def layout_fixes(root):
    for junk in ('.Spotlight-V100', '.fseventsd', '.Trashes', '.DocumentRevisions-V100', '.TemporaryItems'):
        shutil.rmtree(os.path.join(root, junk), ignore_errors=True)
    # The OS volume's /System/Cryptexes/{OS,App} point at ../../private/preboot/Cryptexes/{OS,App}, the mount
    # points of the cryptexes. The kernel has no cryptex mounting and the cryptex files are merged into the
    # root instead, so those two names become symlinks to / (cryptex path /System/Library/X == root path
    # /System/Library/X): /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld is the real cache dir.
    cr = os.path.join(root, 'private/preboot/Cryptexes')
    os.makedirs(cr, exist_ok=True)
    for n in ('OS', 'App'):
        p = os.path.join(cr, n)
        if os.path.lexists(p):
            os.unlink(p)
        os.symlink('../../..', p)
    dyld = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    assert os.path.exists(os.path.join(dyld, 'dyld_shared_cache_arm64e')), 'no dyld cache in the root'
    log('layout: cache at /System/Library/Caches/com.apple.dyld,', len(os.listdir(dyld)), 'files; cryptex mount points -> /')


# --- stage: macho ---------------------------------------------------------------------------------------------------
def macho_filetype(buf):
    """filetype of a thin Mach-O, or of the first slice of a fat one (None if neither)."""
    import struct
    if buf[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        return struct.unpack_from('<I', buf, 12)[0]
    if buf[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf') and len(buf) >= 32:
        off = struct.unpack_from('>I', buf, 16)[0] if buf[3] == 0xbe else struct.unpack_from('>Q', buf, 16)[0]
        if off + 16 <= len(buf):
            return struct.unpack_from('<I', buf, off + 12)[0]
    return None


def macho_worker(path):
    try:
        with open(path, 'rb') as f:
            if f.read(4) not in MAGICS:
                return path, None, None
        buf = bytearray(open(path, 'rb').read())
        if rplat.is_linux() and macho_filetype(buf) == 0xb:
            # MH_KEXT_BUNDLE: ldid cannot sign it ("Unsupported Mach-O type"), and the kernel never loads kexts
            # from the root (its drivers are built in), so it stays exactly as Apple shipped it
            return path, 'kext', None
        orig = bytes(buf)
        counts, fj = Counter(), []
        for base in pacstrip.slices(buf):
            pacstrip.process_slice(buf, base, True, False, os.path.basename(path), counts, fj)
        if bytes(buf) == orig:
            return path, 'clean', dict(counts)
        os.chmod(path, os.stat(path).st_mode | 0o200)
        with open(path, 'wb') as f:
            f.write(buf)
        old = pacstrip.sign(path)              # keeps identifier/entitlements/options, verifies identity after
        counts = dict(counts)
        counts['__ident'] = old
        return path, 'rewritten', counts
    except BaseException as e:             # report, keep going
        return path, 'FAILED: ' + str(e)[:300], None


def stage_macho(a, root):
    need_free('macho stage')
    skip_prefix = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    rplat.prepare_signer()                   # Linux: fetch/verify the pinned ldid once, before the pool starts
    inode_first, links, files = {}, [], []
    for r, dirs, fs in os.walk(root):
        if r.startswith(skip_prefix):
            dirs[:] = []
            continue
        for f in fs:
            p = os.path.join(r, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not (st.st_mode & 0o170000) == 0o100000 or st.st_size < 32:
                continue
            key = (st.st_dev, st.st_ino)
            if key in inode_first:
                links.append((inode_first[key], p))
                continue
            inode_first[key] = p
            files.append(p)
    log(f'{len(files)} regular files ({len(links)} extra hard links) to inspect')
    t0 = time.time()
    stats, failed = Counter(), []
    totals = Counter()
    rewritten = set()
    idents = {}
    with Pool(a.jobs) as pool:
        for i, (p, status, counts) in enumerate(pool.imap_unordered(macho_worker, files, chunksize=16)):
            if status is None:
                continue
            stats[status.split(':')[0]] += 1
            if status.startswith('FAILED'):
                failed.append((p, status))
            elif status == 'rewritten':
                rewritten.add(p)
                ident = counts.pop('__ident', None)
                idents[p] = ident
                totals.update(counts)
            if i % 20000 == 0:
                log(f'  {i}/{len(files)} {dict(stats)}')
    # hard links: codesign may have replaced the inode, re-link
    relinked = 0
    for first, other in links:
        if first in rewritten:
            os.unlink(other)
            os.link(first, other)
            relinked += 1
    log(f'macho: {dict(stats)}, {relinked} hard links re-linked, {time.time() - t0:.0f}s')
    log('rewritten classes:', ', '.join(f'{k}={v}' for k, v in sorted(totals.items())))
    for p, s in failed[:40]:
        log('  ', p, s)
    with open(os.path.join(W, 'identities.tsv'), 'w') as f:        # identifier/team/flags BEFORE the re-sign
        for p, i in sorted(idents.items()):
            if i:
                f.write(f'{os.path.relpath(p, root)}\t{i[0]}\t{i[1]}\t{i[2]:x}\n')
    log(f'{len(idents)} re-signed Mach-Os, identities recorded ({sum(1 for i in idents.values() if not i)} were unsigned)')
    if failed:
        open(os.path.join(W, 'macho-failed.txt'), 'w').write('\n'.join(f'{p}\t{s}' for p, s in failed))
        sys.exit(f'{len(failed)} Mach-O files failed ({W}/macho-failed.txt): the build must not continue')


# --- stage: cache ---------------------------------------------------------------------------------------------------
def stage_cache(a, root):
    need_free('cache stage')
    d = os.path.join(root, 'System/Library/Caches/com.apple.dyld')
    # --stubs: iOS 26 caches keep cross-image stubs in __TEXT_STUBS sub-caches outside every image section, ending
    # in BRAA x16, x17 (first iOS 26 boot: launchd SIGILL there); iOS 18's islands were plain adrp/add/br
    run([sys.executable, '-I', os.path.join(HERE, 'pacstrip_cache.py'), d, '--jobs', str(a.jobs), '--stubs'])
    run([sys.executable, '-I', os.path.join(HERE, 'fips_rehmac.py'), d, '--patch'])   # corecrypto FIPS POST integrity HMAC



# --- stage: tweaks --------------------------------------------------------------------------------------------------
MAIN_CHECKOUT = os.path.abspath(os.path.join(ROOT, '..', 'ios-beryllium'))
OWNER_EXTRA = os.path.join(W, 'owners-extra.tsv')
JOB = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/dev/console</string>
<key>StandardErrorPath</key><string>/dev/console</string>
<key>EnvironmentVariables</key><dict><key>OS_ACTIVITY_DT_MODE</key><string>YES</string></dict>
</dict></plist>
"""


def stage_tweaks(a, root):
    import importlib.util
    import plistlib
    spec = importlib.util.spec_from_file_location('root_tweaks18', os.path.join(HERE, 'root_tweaks18.py'))
    rt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rt)
    rt.SSH_OUT = rt.ssh_out()          # this checkout, the main checkout, then the berga-tools cache
    rt.NETCFG = rt.find_sweetnet('sweetnetcfg') or os.path.join(MAIN_CHECKOUT, 'research/sweetnet/sweetnetcfg')
    rt.REBOOT_TOOL = rt.find_sweetnet('sweetreboot') or os.path.join(MAIN_CHECKOUT, 'research/sweetnet/sweetreboot')
    # BlueTool stub, hcitest, ios18/sweetuicache and ios18/sweetfp.dylib: rt.find_sweetnet() (this checkout's
    # research/sweetnet first, then the main checkout's; tools/sweetnet/build.sh)
    gaps = rt.tool_gaps({f: rt.enabled(f) for f in rt.FEATURES})      # prebuilt binaries missing: skip, do not fail
    for f_, why in gaps.items():
        os.environ['RENEGADE_NO_' + f_.upper()] = '1'
        log(f'feature {f_} skipped automatically: {why}')
    rec = rt.OwnerRecorder()                       # no sudo on macOS: owners are written into the HFS catalog at seal time
    chowned = rec.owners
    rec.install()                                  # rt.os is the os module: only this process is affected
    try:
        log('--- launchd.plist (PanicOnCrash, CommCenter), containers, usbnet, netcfg, sweetreboot, ssh, bluetooth')
        rt.launchd(root)
        if os.environ.get('SWEET_QUIET') == '1':       # root_tweaks18.quiet(): crash-looping daemons off/throttled
            rt.quiet(root)
        rt.containers(root)
        chowned[os.path.join(root, 'private/var/containers/Bundle')] = (33, 33)
        rt.event_timing(root)       # <ADT target>.{Default,Touch}.plist when the ADT claims another device (ios18: D22 from N841)
        rt.usbnet(root)
        rt.netcfg(root)
        rt.sweetreboot(root)
        rt.ssh(root)
        # Renegade auto-fixes, each with an opt-out (RENEGADE_NO_APPREG/POSTERBOARD/BLUETOOTH/JB, --no-* flags):
        # staged apps -> /Applications, bluetooth (BT_HCI_TRANSPORT, BlueTool stub, hcitest), PosterBoard + sweetfp.dylib,
        # first-boot job (sweetuicache registration, jailbreak post-install)
        rt.auto(root)
        rt.audio(root)
        rt.merge_pref(root, 'com.apple.migration', {
            'LastSystemVersion': rt.BUILD, 'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': rt.BUILD}})
        rt.merge_pref(root, 'com.apple.springboard', {
            'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
            'MCForceShowCloudConfigurationUI': False, 'SBShowBatteryPercentage': True})
        rt.sweetprefs_tool(root)
        rt.merge_pref(root, 'com.apple.purplebuddy', {
            'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11, 'daemonizeNeedsToRun': False})
        rt.merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
            k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy',
                               'ShouldRunMesaMiniBuddy', 'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                               'SilentICDPUpgrade')})
        rt.merge_pref(root, 'com.apple.managedconfiguration.notbackedup',
                      {'LockdownActivationIndicatesCloudConfigurationAvailable': False})

        # a console job that shows at once whether launchd 18 runs jobs (the full OS has no /bin/expr or /bin/cat:
        # /bin/sh is the dash from the ssh tweak, toybox the rest)
        lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
        st = os.stat(lpath)
        plist = rt.load(lpath)
        label = 'org.sweet.ios18.hello'
        jpath = f'/System/Library/LaunchDaemons/{label}.plist'
        if os.path.exists(os.path.join(root, 'bin/sh')):
            args = ('/bin/sh', '-c', 'echo "SWEET iOS18 full root: launchd runs jobs, 6*7=$((6*7))"; '
                    '/usr/local/bin/toybox uname -a; /usr/local/bin/toybox cat /etc/master.passwd')
            xml = JOB.format(label=label, args=''.join(f'<string>{x}</string>' for x in args))
            open(os.path.join(root, jpath.lstrip('/')), 'w').write(xml)
            os.chmod(os.path.join(root, jpath.lstrip('/')), 0o644)
            plist['LaunchDaemons'][jpath] = plistlib.loads(xml.encode())
            log('bring-up job', label)
        rt.save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    finally:
        pass
    if a.patch_mount_phase2:                       # OFF by default: the real cause is kernel-side (exclaves status, hw.osenvironment)
        patch_mount_phase2(root)
    # logd stores and the system keybag of the built-in AppleKeyStore (same as tools/mkiosroot-macos.sh)
    for d in ('private/var/db/diagnostics', 'private/var/db/uuidtext', 'private/var/db/diagnostics/timesync'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
        chowned[os.path.join(root, d)] = (272, 272)
        m = os.path.join(root, d, '.migrated')
        open(m, 'a').close()
        os.chmod(m, 0o644)
        chowned[m] = (272, 272)
    os.chmod(os.path.join(root, 'private/var/db/diagnostics'), 0o751)
    kb = os.path.join(root, 'private/var/keybags')
    os.makedirs(kb, exist_ok=True)
    os.chmod(kb, 0o700)
    kf = os.path.join(kb, 'systembag.kb')
    open(kf, 'w').write('<?xml version="1.0" encoding="UTF-8"?>\n'
                        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                        '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n')
    os.chmod(kf, 0o600)
    # wallpapers (task: defaults present)
    for w in ('Library/Wallpaper', 'System/Library/PrivateFrameworks/PosterBoard.framework'):
        log('present:', w, os.path.isdir(os.path.join(root, w)))
    prev = {}
    if os.path.exists(OWNER_EXTRA):                  # idempotent re-runs keep the earlier overrides
        prev = {os.path.join(root, k): v[:2] for k, v in load_map(OWNER_EXTRA).items()}
    prev.update(chowned)
    chowned = prev
    with open(OWNER_EXTRA, 'w') as f:
        for p, (u, g) in sorted(chowned.items()):
            if not os.path.lexists(p):
                continue
            rel = os.path.relpath(p, root)
            if rel.startswith('..') or '\t' in rel:
                continue
            f.write(f'{unicodedata.normalize("NFD", rel)}\t{u}\t{g}\t{os.lstat(p).st_mode & 0o7777:o}\n')
    log(f'{len(chowned)} owner overrides in {OWNER_EXTRA}')
    rt.skip_summary()


# --- stage: jb (optional) -------------------------------------------------------------------------------------------
JB_OWNERS = os.path.join(W, 'owners-jb.tsv')


def stage_jb(a, root):
    need_free('jb stage')
    import importlib.util
    spec = importlib.util.spec_from_file_location('root_tweaks18', os.path.join(HERE, 'root_tweaks18.py'))
    rt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rt)
    n = rt.jailbreak_userland(root, JB_OWNERS, force=True)
    log(f'jailbreak userland: {n} paths staged into the image (/private/var/jb), owners in {JB_OWNERS}')


def patch_mount_phase2(root):
    """`mount -P 2` (boot task mount-phase-2) ends, after the fstab entries of pass 2, in
    execv("/System/Library/Filesystems/apfs.fs/apfs_boot_util", "2") (mount+0x3a08: `cmp w22,#2; b.ne exit; bl apfs_boot_util`).
    apfs_boot_util mounts the Log/iDiags/Data volumes by role, deletes Data snapshots, grafts ExclaveOS: it aborts (SIGABRT)
    on a root that is one HFS+ volume. Phase 1 takes the `b.ne` to exit(0); make phase 2 take the same exit
    (b.ne -> b at mount+0x3a0c). Same program, same identity com.apple.mount (re-signed with the old identifier)."""
    p = os.path.join(root, 'sbin/mount')
    b = bytearray(open(p, 'rb').read())
    assert struct.unpack_from('<I', b, 0)[0] == 0xFEEDFACF, 'sbin/mount is not a thin Mach-O'
    off = 0x3a0c
    new = 0x140000AF                                 # b +0x2bc
    cur = struct.unpack_from('<I', b, off)[0]
    exp = 0x54000001 | (0xAF << 5)                   # b.ne +0x2bc (-> mount+0x3cc8: exit(w21))
    if cur == new:
        log('mount-phase-2 patch already applied')
        return
    assert cur == exp, f'unexpected word {cur:#x} at mount+{off:#x} (expected b.ne {exp:#x}): another mount build?'
    assert struct.unpack_from('<I', b, 0x3a08)[0] == 0x71000ADF, 'cmp w22,#2 not at mount+0x3a08'
    struct.pack_into('<I', b, off, new)
    os.chmod(p, os.stat(p).st_mode | 0o200)
    with open(p, 'wb') as f:
        f.write(b)
    pacstrip.sign(p)
    log('patched /sbin/mount: mount -P 2 no longer execs apfs_boot_util (b.ne -> b at +0x3a0c), re-signed as', pacstrip.cs_identity(p)[0])


# --- stages: seal / verify / simg -----------------------------------------------------------------------------------
def stage_seal(a, img, rootmnt):
    """Unmount, apply the owner map to the catalog, fsck."""
    if os.path.ismount(rootmnt):
        subprocess.run(['sync'])
        r = rplat.detach(rootmnt)
        if r.returncode:
            sys.exit('detach failed: ' + r.stderr)
    run([sys.executable, '-I', os.path.join(HERE, 'hfs_trim.py'), img])        # give freed blocks back to the host
    table = load_map(os.path.join(W, 'owners.tsv'))
    if os.path.exists(OWNER_EXTRA):
        table.update(load_map(OWNER_EXTRA))
    if os.path.exists(JB_OWNERS):                     # written by stage jb, removed by stage copy
        table.update(load_map(JB_OWNERS))
    merged = os.path.join(W, 'owners-final.tsv')
    write_map(table, merged)
    run([sys.executable, '-I', os.path.join(HERE, 'hfsroot_owners.py'), img, '--map', merged, '--default-root'])
    rc, text = rplat.fsck(img)
    log(rplat.fsck_tool(), '-fn rc=' if not rplat.is_linux() else '-f -n rc=', rc, text.strip()[-600:])
    if rc:
        sys.exit(rplat.fsck_tool() + ' reports errors')


def stage_verify(a, img, rootmnt):
    import random
    dev = attach(img, rootmnt, readonly=True, owners=True)
    ok = True
    try:
        def chk(c, msg):
            nonlocal ok
            log(('OK   ' if c else 'FAIL ') + msg)
            ok = ok and c
        R = rootmnt
        for p in ('sbin/launchd', 'usr/lib/dyld', 'System/Library/CoreServices/SpringBoard.app/SpringBoard',
                  'usr/libexec/xpcproxy', 'System/Library/xpc/launchd.plist', 'Library/Wallpaper/Collections',
                  'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e', 'bin/sh',
                  'System/Library/CoreServices/SystemVersion.plist'):
            chk(os.path.exists(os.path.join(R, p)), 'exists /' + p)
        n = len(os.listdir(os.path.join(R, 'Library/Wallpaper/Collections')))
        chk(n > 0, f'Library/Wallpaper/Collections has {n} entries')
        pb = os.path.join(R, 'System/Library/PrivateFrameworks/PosterBoard.framework')
        chk(os.path.isdir(pb), 'PosterBoard.framework present')
        cd = os.path.join(R, 'System/Library/Caches/com.apple.dyld')
        files = os.listdir(cd)
        chk(len(files) == 67 - 0 or len(files) >= 66, f'{len(files)} files in the cache dir (no .symbols)')
        st = os.lstat(os.path.join(R, 'sbin/launchd'))
        chk(st.st_uid == 0 and st.st_gid == 0, f'launchd owner {st.st_uid}:{st.st_gid}')
        for rel in ('private/var/mobile', 'private/var/db/diagnostics', 'private/var/keybags/systembag.kb'):
            p = os.path.join(R, rel)
            if os.path.exists(p):
                s2 = os.lstat(p)
                log(f'     /{rel}: {s2.st_uid}:{s2.st_gid} {s2.st_mode & 0o7777:o}')
        # owner map spot check
        table = load_map(os.path.join(W, 'owners-final.tsv'))
        keys = random.Random(1).sample(sorted(table), 3000)
        bad = 0
        for k in keys:
            try:
                s2 = os.lstat(os.path.join(R, k))
            except OSError:
                continue
            if (s2.st_uid, s2.st_gid) != table[k][:2]:
                bad += 1
        chk(bad == 0, f'owner spot check of 3000 paths: {bad} mismatches')
        # compressed files would be fatal (no decmpfs in the kernel)
        comp = rplat.find_compressed(R)
        if comp is None:
            log('SKIP no HFS-compressed files check (macOS only: Linux copies plain files, apfs-fuse reads decompressed data)')
        else:
            chk(not comp, 'no HFS-compressed files')
        # signatures of a sample of rewritten Mach-Os
        machos = []
        for sub in ('sbin', 'usr/libexec', 'usr/sbin', 'System/Library/CoreServices/SpringBoard.app'):
            for r_, d_, f_ in os.walk(os.path.join(R, sub)):
                for f in f_:
                    p = os.path.join(r_, f)
                    if os.path.isfile(p) and not os.path.islink(p):
                        with open(p, 'rb') as fh:
                            if fh.read(4) in MAGICS:
                                machos.append(p)
        sample = random.Random(2).sample(machos, min(150, len(machos)))
        badsig, resonly, nver = [], [], 0
        for p in sample:
            v = rplat.verify_signature(p)
            if v is None:
                break
            nver += 1
            if not v[0]:
                # bundle resource seals (CodeResources) are not checked by the kernel stand-in; page hashes are
                (resonly if v[1] == 'resource' else badsig).append(p)
        if nver:
            chk(not badsig, f'codesign -v on {len(sample)} of {len(machos)} Mach-Os: {len(badsig)} bad {badsig[:3]}, '
                            f'{len(resonly)} only with an invalid bundle resource seal')
        else:
            log('SKIP codesign -v of a sample (macOS only; the identity/CS-flag check below still runs on every re-signed Mach-O)')
        # every re-signed Mach-O: identifier, team id and CS options as before the re-sign
        idf = os.path.join(W, 'identities.tsv')
        if os.path.exists(idf):
            n = bad = 0
            badl = []
            for line in open(idf):
                rel, ident, team, fl = line.rstrip('\n').split('\t')
                p = os.path.join(R, rel)
                if not os.path.exists(p):               # moved by a tweak (VirtualAudio.plugin -> HAL.disabled)
                    continue
                new = pacstrip.cs_identity(p)
                if new and new[0].startswith('bluetool-stub-'):     # replaced on purpose by the bluetooth tweak
                    continue
                n += 1
                lost = (int(fl, 16) & ~new[2]) & ~pacstrip.CS_FLAG_IGNORED if new else 1
                if not new or new[0] != ident or new[1] != team or lost:
                    bad += 1
                    badl.append((rel, ident, new))
            chk(bad == 0, f'identity (identifier/team/CS flags) unchanged on all {n} re-signed Mach-Os, {bad} mismatches {badl[:3]}')
        boot_task_audit(R, chk)
        if not rplat.is_linux():
            # the owners-on mount hides root-only files (0600 root: /private/etc/master.passwd, ...) from this user;
            # the content checks below read every file, so they run on a read-only noowners mount
            detach(dev)
            dev = attach(img, rootmnt, readonly=True, owners=False)
        # every Mach-O's chained fixups against its own bytes, as the kernel's dyld pager walks them at page-in: a file that
        # was damaged on its way into the image panics the phone at boot ("fixupPageAuth64(): chain ... out of range")
        import fixupcheck
        nfx = 0
        badfx = []
        for name, data in fixupcheck.walk_dir(R, '/'):
            nfx += 1
            badfx += fixupcheck.check_bytes(data, name)
        chk(not badfx, f'chained fixups of {nfx} Mach-Os walk inside their pages: {len(badfx)} problems {badfx[:3]}')
        # no PAC left in a sample (+ every launchd/dyld/SpringBoard)
        left = Counter()
        for p in sample + [os.path.join(R, 'sbin/launchd'), os.path.join(R, 'usr/lib/dyld')]:
            buf = bytearray(open(p, 'rb').read())
            counts, fj = Counter(), []
            for base in pacstrip.slices(buf):
                pacstrip.process_slice(buf, base, False, False, p, counts, fj)
            for k, v in counts.items():
                if not k.startswith(('FJCVTZS', 'ERETA')):
                    left[k] += v
        chk(not left, f'non-HINT PAC words left in the Mach-O sample (as the rewriter classifies them): {dict(left)}')
        r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'pacstrip_cache.py'), cd, '--scan', '--verify-sig'],
                           capture_output=True, text=True)
        log(r.stdout[-1800:])
        chk(r.returncode == 0 and 'SIGNATURE MISMATCH' not in r.stdout, 'cache: signatures valid, re-scan finds nothing to rewrite')
        subprocess.run(['df', '-h', rootmnt])
    finally:
        detach(dev)
    if not ok:
        sys.exit('verification FAILED')


def boot_task_audit(R, chk):
    """launchd 18 boot tasks: program present, signing identifier = com.apple.<leaf> or CSIdentityOverride."""
    import plistlib
    b = open(os.path.join(R, 'sbin/launchd'), 'rb').read()
    i = b.find(b'<key>mount-phase-1</key>')
    bt = plistlib.loads(b[b.rfind(b'<?xml', 0, i):b.find(b'</plist>', i) + 8])['Boot']
    missing, mism, optional = [], [], []
    for name, t in sorted(bt.items()):
        prog = t.get('Program') or (t.get('ProgramArguments') or [None])[0]
        if not prog or not prog.startswith('/'):
            continue
        p = os.path.join(R, prog.lstrip('/'))
        if not os.path.exists(p):
            # device/restore specific tasks (HorizonSetup, darwinos-boot-task, visionOS loaders) are absent from the
            # iPhone OS volume too; only RequireRun tasks outside restore must exist
            (missing if t.get('RequireRun') and not t.get('PerformInRestore') else optional).append(f'{name}:{prog}')
            continue
        idn = pacstrip.cs_identity(p)
        exp = t.get('CSIdentityOverride') or 'com.apple.' + os.path.basename(prog)
        if idn is None or idn[0] != exp:
            mism.append(f'{name}: {prog} id={idn and idn[0]} expected={exp}')
    log(f'boot tasks with a program path: {sum(1 for t in bt.values() if t.get("Program"))}, missing in the root: {missing}; absent as on a stock iPhone image: {optional}')
    for m in mism:
        log('     identity differs from the launchd rule (informational): ' + m)
    chk(not missing, 'every boot-task program exists in the root')


def stage_simg(a, img, rootmnt):
    out = a.simg or os.path.splitext(img)[0] + '.simg'
    need_free('simg')
    cmd = [sys.executable, '-I', os.path.join(HERE, 'img2simg.py'), img, out]
    if not a.keep_raw:
        cmd.append('--consume')
    run(cmd)
    log('wrote', out, os.path.getsize(out), 'bytes', '(raw image consumed)' if not a.keep_raw else '')


def dry_plan(a, img, rootmnt, dmgs, stages):
    """RENEGADE_DRY_RUN=1: print what the platform layer would run for these stages (nothing is executed or created)."""
    b = rplat.backend()
    print(f'# dry run, backend: {b.name}; stages: {",".join(stages)}')
    for s in stages:
        print(f'## stage {s}')
        if s == 'copy':
            b.make_image(img, a.size)
            b.format_hfsx(img, 'iOSRoot')
            h = b.attach(img, rootmnt, readonly=False)
            for name in ('appos', 'sysos', 'os'):
                mnt = os.path.join(W, 'src-' + name)
                d = b.attach_ipsw(dmgs[name], mnt, owners=True)
                if not rplat.is_linux():
                    b.detach(d)
                    d = b.attach_ipsw(dmgs[name], mnt, owners=False)
                b.copy_tree(mnt, rootmnt, list(EXCLUDE))
                b.detach(d)
            print('python3 -I hfs_trim.py', img, '  # punch the free blocks')
        elif s == 'macho':
            print('# for every rewritten Mach-O (pacstrip, then the ad-hoc re-sign keeping identifier, flags, entitlements):')
            b.adhoc_sign('/ROOT/path/to/macho', 'IDENTIFIER', 0x12002, b'<entitlements xml>')
        elif s == 'cache':
            print('python3 -I pacstrip_cache.py DYLD_DIR; python3 -I fips_rehmac.py DYLD_DIR --patch   # pure Python')
        elif s in ('tweaks', 'jb'):
            print('# plist/file edits in the mounted root (root_tweaks18.py), jailbreak payload; prebuilt-binary features skip by themselves')
        elif s == 'seal':
            b.detach(rootmnt)
            print('python3 -I hfs_trim.py', img)
            print('python3 -I hfsroot_owners.py', img, '--map owners-final.tsv --default-root   # pure Python, offline catalog edit')
            b.fsck(img)
        elif s == 'verify':
            b.attach(img, rootmnt, readonly=True, owners=True)
            b.detach(rootmnt)
        elif s == 'simg':
            print('python3 -I img2simg.py', img, a.simg or os.path.splitext(img)[0] + '.simg', '' if a.keep_raw else '--consume')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--ipsw-dir', default=os.path.join(ROOT, TARGET['ipsw_dir']))
    ap.add_argument('--out', default=os.path.join(ROOT, TARGET['root_img']))
    ap.add_argument('--size', default='20g')
    ap.add_argument('--stages', default='copy,macho,cache,tweaks,seal,verify,simg')
    ap.add_argument('--simg', default=None)
    ap.add_argument('--delete-sources', action='store_true', help='delete each IPSW dmg after it was copied (tight disk)')
    ap.add_argument('--skip-sources', default='', help='copy stage resume: sources already in the image (appos,sysos)')
    ap.add_argument('--patch-mount-phase2', action='store_true', help='tweaks: make mount -P 2 skip apfs_boot_util (not needed, see docs)')
    ap.add_argument('--keep-raw', action='store_true', help='simg stage: do not punch holes into the raw image')
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    for f_, what in (('appreg', 'first-boot LaunchServices registration of the staged apps (sweetuicache)'),
                     ('posterboard', 'sweetfp.dylib + the LC_LOAD_DYLIB in PosterBoard'),
                     ('bluetooth', 'bluetoothd env, BlueTool stub, hcitest'),
                     ('jb', 'jailbreak userland (Procursus rootless, Sileo, TrollStore)'),
                     ('wallpaper', 'default Gradient wallpaper and icon style at first boot'),
                     ('bglrender', 'Bergamota GL renderer payload + backboardd launcher (inert without boot-arg bglrender=1|soft)')):
        ap.add_argument('--no-' + f_, action='store_true', help='opt out: ' + what + ' (same as RENEGADE_NO_' + f_.upper() + '=1)')
    ap.add_argument('--disable-cryptexd', action='store_true', help='OPT-IN fallback: remove the crash-looping cryptexd job (same as RENEGADE_DISABLE_CRYPTEXD=1)')
    a = ap.parse_args()
    if a.disable_cryptexd:
        os.environ['RENEGADE_DISABLE_CRYPTEXD'] = '1'
    for f_ in ('appreg', 'posterboard', 'bluetooth', 'jb', 'wallpaper', 'bglrender'):
        if getattr(a, 'no_' + f_):
            os.environ['RENEGADE_NO_' + f_.upper()] = '1'
    stages_ = a.stages.split(',')
    rplat.need_privileges()
    roles = ['image', 'fsck'] if any(x in stages_ for x in ('copy', 'macho', 'cache', 'tweaks', 'jb', 'seal', 'verify')) else []
    if 'copy' in stages_:
        roles += ['format', 'ipsw']
    if 'jb' in stages_ or 'tweaks' in stages_:
        roles.append('zstd')
    rplat.check_tools(*roles)
    os.makedirs(W, exist_ok=True)
    rootmnt = os.path.join(W, 'root')
    # the jailbreak userland is part of the default build now (opt out: --no-jb / RENEGADE_NO_JB=1 / RENEGADE_JB=0)
    if (os.environ.get('RENEGADE_NO_JB') != '1' and os.environ.get('RENEGADE_JB') != '0' and 'jb' not in a.stages.split(',')
            and ('tweaks' in a.stages.split(',') or os.environ.get('RENEGADE_JB') == '1')):
        st = a.stages.split(',')
        a.stages = ','.join(st[:st.index('seal')] + ['jb'] + st[st.index('seal'):]) if 'seal' in st else a.stages + ',jb'
    stages = a.stages.split(',')
    dmgs = find_dmgs(a.ipsw_dir)
    if rplat.backend().dry:
        dry_plan(a, a.out, rootmnt, dmgs, stages)
        return
    if 'copy' not in stages and stages[0] in ('macho', 'cache', 'tweaks', 'jb') and not os.path.ismount(rootmnt):
        attach(a.out, rootmnt, readonly=False)
    for s in stages:
        t0 = time.time()
        log('=== stage', s)
        if s == 'copy':
            stage_copy(a, a.out, rootmnt, dmgs)
        elif s == 'macho':
            stage_macho(a, rootmnt)
        elif s == 'cache':
            stage_cache(a, rootmnt)
        elif s == 'tweaks':
            stage_tweaks(a, rootmnt)
        elif s == 'jb':
            stage_jb(a, rootmnt)
        elif s == 'seal':
            stage_seal(a, a.out, rootmnt)
        elif s == 'verify':
            stage_verify(a, a.out, rootmnt)
        elif s == 'simg':
            stage_simg(a, a.out, rootmnt)
        else:
            sys.exit('unknown stage ' + s)
        log(f'=== stage {s} done in {time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
