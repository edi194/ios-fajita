#!/usr/bin/env python3
"""Renegade in-place update (`renegade update`): apply the root tweaks of root_tweaks18.py to a FINISHED root image,
without the IPSW dmgs (deleted, and the Mac has no room for them).

  update.py IMAGE.simg [--no-appreg] [--no-posterboard] [--no-bluetooth] [--no-jb] [--no-wallpaper] [--no-bglrender] [--force-jb] [--mnt DIR]
  update.py IMAGE.img                      resume: the raw image a failed run left behind (see below)

Steps (every one checks `df` first and stops below 5 GiB free on the volume of the image):
  0 preflight   (simg only, read only, via hfsx.py) the files the tweaks touch exist; features whose prebuilt on-device
                tools are missing (tools/sweetnet/build.sh needs a Mac; always the case on Linux) are skipped with a
                message and listed in a summary at the end, not failed; the jailbreak payload is downloaded, verified and staged (it needs the network)
  1 simg2img    simg2img.py --consume: IMAGE.simg -> IMAGE.img (a sparse raw image; the simg is eaten while it is
                written, so the disk use stays flat; the simg no longer exists afterwards)
  2 attach      macOS: hdiutil attach, read-write, no sudo. Linux (root): losetup + mount -t hfsplus -o rw,force. Mounted at --mnt
  3 tweaks      the idempotent original tweaks (root_tweaks18.base(): launchd.plist, containers, event timing profiles,
                usbnet, netcfg, sweetreboot, ssh/dropbear job, audio, activation, prefs, logd dirs), then staged apps -> /Applications (+ the register list), bluetooth (bluetoothd env, BlueTool stub, hcitest),
                PosterBoard + sweetfp.dylib, the first-boot job (sweetuicache registration, default wallpaper/icon style via
                SweetRun, jailbreak post-install),
                /private/var/jb (Procursus, Sileo, TrollStore). All idempotent: a second run changes nothing.
                The paths that are new (HFS creation date after the start) or that got an owner on purpose are collected
                into an owner map; /System/Library/xpc/launchd.plist is put back to 0:0 (an old build left 501:20)
  4 seal        sync + detach, hfs_trim.py, hfsroot_owners.py with that map (only those paths: nothing else changes,
                no --default-root), fsck_hfs -fn (Linux: fsck.hfsplus -f -n)
  5 img2simg    img2simg.py --consume: IMAGE.img -> IMAGE.simg (the raw image is eaten while the simg is written)

A failure after step 1 leaves the raw IMAGE.img next to the (now missing) simg, detached and consistent as far as the
HFS+ driver got: fix the cause and run `renegade update IMAGE.img`, which starts at step 2 (the tweaks are idempotent)
and writes IMAGE.simg at the end. Do not delete the .img: the simg was consumed to make it.
"""
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import renegade_platform as rplat  # noqa: E402
MIN_FREE = 5 << 30


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def load(name, fn):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, fn))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def is_simg(path):
    """True if path is a live Android sparse image (a consumed one is zeroed: simg2img --consume leaves the shell)."""
    try:
        with open(path, 'rb') as f:
            return f.read(4) == b'\x3a\xff\x26\xed'
    except OSError:
        return False


def free_gib(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 2**30


def need_free(path, what):
    f = free_gib(path)
    log(f'free disk: {f:.1f} GiB ({what})')
    if f < MIN_FREE / 2**30:
        sys.exit(f'STOP: only {f:.1f} GiB free (< 5 GiB) before {what}')


def py(script, *args):
    subprocess.run([sys.executable, '-I', os.path.join(HERE, script), *args], check=True)


def detach(mnt_or_dev):
    rplat.detach_retry(mnt_or_dev)


def detach_leftovers(raw):
    """A previous run that was killed can leave the raw image attached."""
    rplat.detach_image(raw)


def preflight(simg, rt, feats):
    """Read-only checks on the simg (hfsx.py) and the tool/payload preparation: nothing is consumed yet."""
    import hfsx
    problems = []
    log('preflight: reading', simg)
    v = hfsx.Vol(hfsx.Simg(simg))

    def have(p):
        e = v.lookup(p)
        return e is not None and e[0] in (1, 2)
    for p in ('/System/Library/xpc/launchd.plist', '/private/var', '/Applications'):
        if not have(p):
            problems.append('missing in the image: ' + p)
    if (feats['appreg'] or feats['jb'] or feats['wallpaper']) and not have('/bin/sh'):
        problems.append('missing in the image: /bin/sh (dash; the first-boot job needs it)')
    ve = v.lookup('/var', follow=False)
    if not ve or ve[0] != 2 or not v.read_file(*ve).decode().startswith('private/var'):
        problems.append('/var is not a symlink to private/var in the image')
    if feats['posterboard'] and not have('/' + rt.POSTER_BIN):
        problems.append('missing in the image: /' + rt.POSTER_BIN)
    if feats['bluetooth'] and not have('/usr/sbin/BlueTool'):
        problems.append('missing in the image: /usr/sbin/BlueTool')
    jb_installed = False
    if feats['jb']:
        e = v.lookup('/private/var/jb/usr/share/renegade-jb/VERSIONS')
        if e and e[0] == 2:
            sys.path.insert(0, HERE)
            import jailbreak
            jb_installed = v.read_file(*e).decode() == jailbreak.versions_text()
    staged = v.lookup('/private/var/staged_system_apps')
    n_staged = len([n for n in v.children.get(staged[1], {}) if n.endswith('.app')]) if staged and staged[0] == 1 else 0
    log(f'preflight: {n_staged} app(s) still in /private/var/staged_system_apps, jailbreak payload '
        + ('already current' if jb_installed else 'to install' if feats['jb'] else 'off'))
    return problems, jb_installed


def check_tools(rt, feats):
    """Features whose prebuilt on-device binaries are missing are switched off (and listed in the summary) instead of
    failing the preflight; on Linux that is the normal case. Returns the problems that really stop the update."""
    for f_, why in rt.tool_gaps(feats).items():
        feats[f_] = False
        os.environ['RENEGADE_NO_' + f_.upper()] = '1'
        log(f'preflight: feature {f_} skipped automatically: {why}')
    return []


def scan_new(mnt, t0, rec):
    """Owner map for `hfsroot_owners.py --map`: every path created since t0 (HFS creation date; a file replaced by a new
    inode counts as new) plus the paths that were chowned on purpose, as rel -> (uid, gid, mode)."""
    table = {}
    n = 0
    stack = [mnt]
    while stack:
        d = stack.pop()
        rel_d = os.path.relpath(d, mnt)
        try:
            it = list(os.scandir(d))
        except OSError:
            continue
        for e in it:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            n += 1
            rel = e.name if rel_d == '.' else rel_d + '/' + e.name
            if '\t' in rel or '\n' in rel:
                continue
            if rplat.birthtime(st) >= t0 - 1:
                # macOS mounts noowners (every file shows 501:20): default root. Linux owners are real: trust lstat
                uid, gid = rec.owners.get(e.path, (st.st_uid, st.st_gid) if rplat.real_owners() else (0, 0))
                table[unicodedata.normalize('NFD', rel)] = (uid, gid, st.st_mode & 0o7777)
            if e.is_dir(follow_symlinks=False):
                stack.append(e.path)
    for p, (uid, gid) in rec.owners.items():
        if os.path.lexists(p) and p.startswith(mnt + '/'):
            rel = unicodedata.normalize('NFD', os.path.relpath(p, mnt))
            table[rel] = (uid, gid, os.lstat(p).st_mode & 0o7777)
    return table, n


def write_map(table, path):
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        for k in sorted(table):
            u, g, m = table[k]
            f.write(f'{k}\t{u}\t{g}\t{m:o}\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('image', help='root image: IMAGE.simg (full run) or IMAGE.img (resume after a failure)')
    for f_, what in (('appreg', 'first-boot LaunchServices registration of the staged apps'),
                     ('posterboard', 'sweetfp.dylib + the LC_LOAD_DYLIB in PosterBoard'),
                     ('bluetooth', 'bluetoothd env, BlueTool stub, hcitest'),
                     ('jb', 'jailbreak userland (Procursus rootless, Sileo, TrollStore)'),
                     ('wallpaper', 'default Gradient wallpaper and icon style at first boot'),
                     ('bglrender', 'Bergamota GL renderer payload + backboardd launcher (inert without boot-arg bglrender=1|soft)')):
        ap.add_argument('--no-' + f_, action='store_true', help='skip: ' + what)
    ap.add_argument('--disable-cryptexd', action='store_true', help='OPT-IN fallback: remove the crash-looping cryptexd job (same as RENEGADE_DISABLE_CRYPTEXD=1)')
    ap.add_argument('--force-jb', action='store_true', help='reinstall /private/var/jb even when it is at the pinned versions')
    ap.add_argument('--mnt', help='mount point (default: IMAGE.mnt next to the image)')
    ap.add_argument('--check', action='store_true', help='preflight only (read only), consume nothing')
    a = ap.parse_args()
    if a.disable_cryptexd:
        os.environ['RENEGADE_DISABLE_CRYPTEXD'] = '1'
    rt_features = ('appreg', 'posterboard', 'bluetooth', 'jb', 'wallpaper', 'bglrender')
    for f_ in rt_features:
        if getattr(a, 'no_' + f_):
            os.environ['RENEGADE_NO_' + f_.upper()] = '1'
    rt = load('root_tweaks18', 'root_tweaks18.py')
    feats = {f_: rt.enabled(f_) for f_ in rt.FEATURES}

    path = os.path.abspath(a.image)
    base, ext = os.path.splitext(path)
    if ext == '.simg':
        simg, raw, resume = path, base + '.img', False
    elif ext == '.img':
        simg, raw, resume = base + '.simg', path, True
    else:
        sys.exit('IMAGE must end in .simg (full run) or .img (resume)')
    d = os.path.dirname(path)
    mnt = os.path.abspath(a.mnt) if a.mnt else base + '.mnt'
    if not resume:
        if not os.path.exists(simg):
            sys.exit(f'{simg} not found')
        if not is_simg(simg):
            sys.exit(f'{simg} is not a sparse image (already consumed by a failed run? then resume with the raw image)')
        if os.path.exists(raw):
            # The simg is intact, so no run consumed it (that case is the check above). A raw image older than the simg is the
            # work copy `renegade root` leaves next to the simg it wrote: replaced. A newer one may hold edits of a run that
            # stopped before the expansion: kept, the user decides.
            if os.path.getmtime(raw) > os.path.getmtime(simg):
                sys.exit(f'{raw} is newer than {simg}: it may hold the edits of an interrupted run. Resume with '
                         f'`renegade update {raw}` (after moving the simg away), or delete it to start from the simg')
            log(f'{raw}: older than the simg (the work copy `renegade root` leaves behind): replaced')
            os.unlink(raw)
    else:
        if not os.path.exists(raw):
            sys.exit(f'{raw} not found')
        if is_simg(simg):
            sys.exit(f'{simg} is a valid sparse image: refusing to overwrite it (move it away first)')
        if os.path.exists(simg):
            os.unlink(simg)                  # the zeroed shell simg2img --consume left
    log(f'update: {"resume from raw " + raw if resume else simg}; features: ' + ', '.join(
        f'{k}={"on" if v else "off"}' for k, v in feats.items()))
    if not a.check:                      # --check only reads the simg (hfsx.py): no root needed on Linux
        rplat.need_privileges()
        rplat.check_tools('image', 'fsck', *(('zstd',) if feats.get('jb') else ()))
    need_free(d, 'start')

    # --- 0 preflight --------------------------------------------------------------------------------------------
    problems = check_tools(rt, feats)
    jb_installed = False
    if not resume:
        p2, jb_installed = preflight(simg, rt, feats)
        problems += p2
    if problems:
        sys.exit('preflight failed, nothing was touched:\n  ' + '\n  '.join(problems))
    jb_prestaged = False
    if feats['jb'] and (a.force_jb or not jb_installed) and not a.check:
        sys.path.insert(0, HERE)
        import jailbreak
        log('preflight: fetch and stage the jailbreak payload (network, SHA-256 pinned)')
        jailbreak.fetch()
        jailbreak.stage_build()
        jb_prestaged = True
    if a.check:
        rt.skip_summary()
        log('preflight OK (--check: nothing consumed)')
        return

    if rplat.backend().dry:              # RENEGADE_DRY_RUN=1: show the platform commands, run nothing
        b = rplat.backend()
        print(f'# dry run, backend: {b.name}')
        print('python3 -I simg2img.py', simg, raw, '--consume' if not resume else '  # (resume: skipped)')
        h = b.attach(raw, mnt, readonly=False)
        print('# tweaks: plist/file edits in the mounted root (root_tweaks18.py); features without prebuilt binaries skip')
        b.detach_retry(mnt)
        print('python3 -I hfs_trim.py', raw)
        print('python3 -I hfsroot_owners.py', raw, '--map', raw + '.owners.tsv')
        b.fsck(raw)
        print('python3 -I img2simg.py', raw, simg, '--consume')
        rt.skip_summary()
        return
    step = 'simg2img'
    try:
        # --- 1 simg2img -----------------------------------------------------------------------------------------
        if not resume:
            need_free(d, 'simg2img --consume')
            t0 = time.time()
            py('simg2img.py', simg, raw, '--consume')
            log(f'1 simg2img done in {time.time() - t0:.0f}s: {raw} ({os.path.getsize(raw) / 2**30:.1f} GiB apparent)')
        # --- 2 attach -------------------------------------------------------------------------------------------
        step = 'attach'
        need_free(d, 'attach')
        detach_leftovers(raw)
        os.makedirs(mnt, exist_ok=True)
        mk = load('mkroot_full', 'mkroot-full.py')
        dev = mk.attach(raw, mnt, readonly=False)
        log('2 attached', dev, 'at', mnt)
        # --- 3 tweaks -------------------------------------------------------------------------------------------
        step = 'tweaks'
        need_free(d, 'tweaks')
        t_start = time.time()
        rec = rt.OwnerRecorder()
        rec.install()
        jb_owners = os.path.join(tempfile.gettempdir(), f'renegade-update-jb-{os.getpid()}.tsv')
        rt.base(mnt)                # the idempotent part of the original tweaks stage (event timing profiles, ...)
        rt.staged_apps(mnt)
        rt.sweetmetrics(mnt)
        if feats['bluetooth']:
            rt.bluetooth(mnt)
        if feats['posterboard']:
            rt.posterboard(mnt)
        if feats['bglrender']:
            rt.bglrender(mnt)
        # Metal Mercury, as in a full build (root_tweaks18.auto): the dylibs and bgmtl.arm go in before the first-boot job
        # picks the wallpaper, which follows the outcome. RENEGADE_NO_BGMTL=1 / RENEGADE_BGMTL=0 opts out.
        metal = False
        if os.environ.get('RENEGADE_NO_BGMTL') != '1' and os.environ.get('RENEGADE_BGMTL') != '0':
            metal = rt.bgmtl(mnt)
        rt.firstboot(mnt, appreg=feats['appreg'], jb=feats['jb'], wallpaper=feats['wallpaper'], metal=metal)
        if os.environ.get('RENEGADE_DISABLE_CRYPTEXD') == '1':
            rt.cryptexd(mnt)
        jb_table = {}
        if feats['jb']:
            rt.jailbreak_userland(mnt, jb_owners, force=a.force_jb, prestaged=jb_prestaged)
            if os.path.exists(jb_owners):
                for line in open(jb_owners, encoding='utf-8'):
                    k, u, g, m = line.rstrip('\n').split('\t')
                    jb_table[k] = (int(u), int(g), int(m, 8))
        need_free(d, 'owner scan')
        table, n = scan_new(mnt, t_start, rec)
        table.update(jb_table)
        lp = os.path.join(mnt, 'System/Library/xpc/launchd.plist')
        table['System/Library/xpc/launchd.plist'] = (0, 0, os.lstat(lp).st_mode & 0o7777)
        omap = raw + '.owners.tsv'
        write_map(table, omap)
        log(f'3 tweaks done: {len(table)} paths in the owner map {omap} ({n} paths scanned)')
        # --- 4 seal ---------------------------------------------------------------------------------------------
        step = 'seal'
        subprocess.run(['sync'])
        detach(mnt)
        dev = None
        py('hfs_trim.py', raw)
        need_free(d, 'hfsroot_owners')
        py('hfsroot_owners.py', raw, '--map', omap)
        rc, text = rplat.fsck(raw)
        log('4', rplat.fsck_tool(), '-fn rc=' if not rplat.is_linux() else '-f -n rc=', rc, text.strip()[-400:])
        if rc:
            raise SystemExit(rplat.fsck_tool() + ' reports errors')
        # --- 5 img2simg -----------------------------------------------------------------------------------------
        step = 'img2simg'
        need_free(d, 'img2simg --consume')
        t0 = time.time()
        py('img2simg.py', raw, simg, '--consume')
        log(f'5 img2simg done in {time.time() - t0:.0f}s: {simg} {os.path.getsize(simg)} bytes (raw image consumed)')
        if os.path.exists(raw):
            if os.stat(raw).st_blocks == 0:
                os.unlink(raw)               # nothing left on disk of it: only the apparent size
            else:
                log(f'note: {raw} still has data blocks; delete it once {simg} is checked')
        for f in (omap, jb_owners):
            if os.path.exists(f):
                os.unlink(f)
        try:
            os.rmdir(mnt)
        except OSError:
            pass
        rt.skip_summary()
        log('update complete')
    except BaseException as e:           # SystemExit, KeyboardInterrupt, CalledProcessError, ...
        log(f'FAILED in step "{step}": {e!r}')
        if step in ('attach', 'tweaks', 'seal') and os.path.ismount(mnt):
            subprocess.run(['sync'])
            rplat.detach(mnt)
        if not os.path.ismount(mnt):
            try:
                os.rmdir(mnt)
            except OSError:
                pass
        if os.path.exists(raw) and not is_simg(simg):
            log(f'the raw image {raw} is kept (the simg was consumed): fix the cause, then run `renegade update {raw}`')
        raise


if __name__ == '__main__':
    main()
