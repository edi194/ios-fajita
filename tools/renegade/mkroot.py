#!/usr/bin/env python3
"""Stage the iOS 18 restore ramdisk as a bootable root (stage 1b, docs/IOS18_PORT.md section 9).

  mkroot.py RAMDISK_MOUNT STAGEDIR [--stock-daemons] [--keep-standalone] [--keep-all] [--no-strip]

1. copies the ramdisk into STAGEDIR (uncompressed: the kernel has no decmpfs, no xattrs/quarantine),
2. drops what a RAM-disk boot does not need (/usr/standalone firmware blobs, /usr/local restore tools,
   Filesystems bundles) and, unless --stock-daemons, every stock LaunchDaemon (restored_external, camera
   daemons, ... would only fight over USB and spam the log),
3. adds two bring-up jobs that print to /dev/console once launchd runs (expr 6*7 and cat /etc/master.passwd),
4. runs pacstrip.py --sign over every Mach-O (dyld, launchd, dylibs, frameworks, tools).
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACSTRIP = os.path.join(HERE, 'pacstrip.py')
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}

JOB = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/dev/console</string>
<key>StandardErrorPath</key><string>/dev/console</string>
<key>EnvironmentVariables</key><dict><key>OS_ACTIVITY_DT_MODE</key><string>YES</string></dict>
</dict></plist>
'''


def closure(stage, seeds):
    sys.path.insert(0, HERE)
    from mkbundle import deps
    keep, todo = set(), list(seeds)
    while todo:
        f = todo.pop()
        if not os.path.exists(f) or os.path.realpath(f) in keep:
            continue
        keep.add(os.path.realpath(f))
        for d, weak in deps(f):
            todo.append(os.path.join(stage, d.lstrip('/')))
    return keep


def job(label, *args):
    return JOB.format(label=label, args=''.join(f'<string>{a}</string>' for a in args))


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    flags = {x for x in sys.argv[1:] if x.startswith('--')}
    if len(a) != 2:
        sys.exit(__doc__)
    src, stage = a
    if os.path.exists(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    subprocess.run(['ditto', '--nohfsCompression', '--nopreserveHFSCompression', '--noextattr', '--noqtn', '--norsrc',
                    '--noacl', src, stage], check=True)
    drop = ['usr/local', 'System/Library/Filesystems']
    if '--keep-standalone' not in flags:
        drop.append('usr/standalone')
    for d in drop:
        shutil.rmtree(os.path.join(stage, d), ignore_errors=True)
    ld = os.path.join(stage, 'System/Library/LaunchDaemons')
    if '--stock-daemons' not in flags:
        for f in os.listdir(ld):
            os.unlink(os.path.join(ld, f))
    os.chmod(ld, 0o755)
    for name, args in (('expr', ('/bin/expr', '6', '*', '7')), ('passwd', ('/bin/cat', '/etc/master.passwd'))):
        p = os.path.join(ld, f'org.sweet.ios18.{name}.plist')
        open(p, 'w').write(job(f'org.sweet.ios18.{name}', *args))
        os.chmod(p, 0o644)

    machos = []
    if '--keep-all' not in flags:
        # every Mach-O not reachable from launchd, dyld, xpcproxy and /bin/* is dead weight in a RAM disk;
        # launchd starts every job through the /usr/libexec/xpcproxy trampoline (exec, not linked: boot 0139
        # got 'Could not spawn process /usr/libexec/xpcproxy: 2' for every job)
        keep = closure(stage, [os.path.join(stage, 'sbin/launchd'), os.path.join(stage, 'usr/lib/dyld'),
                               os.path.join(stage, 'usr/libexec/xpcproxy')] +
                       [os.path.join(stage, 'bin', b) for b in os.listdir(os.path.join(stage, 'bin'))])
        removed = 0
        for root, dirs, files in os.walk(stage):
            for f in files:
                p = os.path.join(root, f)
                if os.path.islink(p) or not os.path.isfile(p) or os.path.realpath(p) in keep:
                    continue
                with open(p, 'rb') as fh:
                    if fh.read(4) in MAGICS:
                        os.unlink(p)
                        removed += 1
        print(f'pruned {removed} Mach-O files outside the launchd/dyld//bin closure ({len(keep)} kept)')
    for root, dirs, files in os.walk(stage):
        for f in files:
            p = os.path.join(root, f)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            with open(p, 'rb') as fh:
                if fh.read(4) in MAGICS:
                    machos.append(p)
    if '--no-strip' not in flags:
        # local symbols are ~25% of every dylib and nothing at run time needs them (dyld uses the export trie and
        # the chained-fixup import names); the payload has to be small (docs/IOS18_PORT.md section 11)
        import struct
        before = after = 0
        for p in machos:
            with open(p, 'rb') as fh:
                hdr = fh.read(16)
            if struct.unpack_from('<I', hdr, 12)[0] != 6:       # MH_DYLIB only; dyld/launchd/tools stay intact
                continue
            before += os.path.getsize(p)
            os.chmod(p, os.stat(p).st_mode | 0o200)
            r = subprocess.run(['xcrun', 'strip', '-x', '-no_code_signature_warning', p], capture_output=True, text=True)
            if r.returncode:
                print(f'strip failed for {p}: {r.stderr.strip()}', file=sys.stderr)
            after += os.path.getsize(p)
        print(f'strip -x on dylibs: {before >> 20} MiB -> {after >> 20} MiB')
    print(f'{len(machos)} Mach-O files to rewrite')
    bad = 0
    for p in machos:
        os.chmod(p, os.stat(p).st_mode | 0o200)
        r = subprocess.run([sys.executable, '-I', PACSTRIP, '--sign', p], capture_output=True, text=True)
        if r.returncode:
            bad += 1
            print(f'FAILED {p}: {r.stdout}{r.stderr}', file=sys.stderr)
    if bad:
        sys.exit(f'{bad} files failed')
    print('stage ready:', stage)


if __name__ == '__main__':
    main()
