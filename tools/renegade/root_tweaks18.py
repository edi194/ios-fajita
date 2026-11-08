#!/usr/bin/env python3
"""iOS 18 copy of tools/sweet-root-tweaks.py (main checkout), driven by tools/renegade/mkroot-full.py.

Unchanged logic; mkroot-full.py sets BUILD/VERSION/SSH_OUT/NETCFG/REBOOT_TOOL/BLUETOOL_STUB and replaces os.chown
by a recorder (no sudo: owners are applied to the HFS catalog afterwards by hfsroot_owners.py).

Original docstring:

Apply the SWEET bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo sweet-root-tweaks.py MOUNTED_ROOT

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter replaced by its non-cellular job (without it
                  SpringBoard retries it every second and the lock screen never sleeps), vmd
                  removed (Visual Voicemail spins with no baseband)
  containers      /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}
                  (on iOS they live on the data volume)
  migration       LastSystemVersion so DataMigration does not run for an hour
                  on every boot
  audio           VirtualAudio HAL plug-in disabled (mediaserverd crash)
  MediaToolbox    StartRecorderServer=false (camera filter prewarm calls a
                  NULL OpenGL function without a GPU -> mediaserverd crash loop)
  SpringBoard     BKNoWatchdogs (one slow CPU path, no scene-create watchdog
                  kills), no cloud-configuration UI
  Setup           skipped: SetupDone, SetupFinishedAllSteps, SetupVersion 11,
                  mini-buddy flags off
  activation      mobileactivationd data ark seeded; the actual Activated state
                  comes from its Hactivation branch, selected by the /chosen
                  security-status properties in tools/mkadt.py
  sweetreboot     /usr/local/bin/sweetreboot fastboot|recovery|normal (docs/REBOOT_MODE.md)
  bluetooth       sweetbt=1 transport (docs/BT_IOS_TRANSPORT.md): BT_HCI_TRANSPORT
                  in bluetoothd's launchd job, and the BlueTool stub (tools/sweetnet/bluetool-stub.c)
                  as /usr/sbin/BlueTool with the original kept as BlueTool.orig; skipped if the stub
                  is not built. `sweet-root-tweaks.py --bt-plist IN OUT` applies only the launchd part
                  to a copied launchd.plist (tools/sweet-bt-install.sh uses it on the live phone)
  ssh             key-only dropbear on 192.168.7.2:22 + dash (/bin/sh) + toybox
                  from tools/ssh/build.sh, authorized_keys from the Mac user's
                  public key, host keys, launchd job (docs/SSH_OVER_USB.md);
                  skipped if the binaries are not built
"""
import glob, os, plistlib, shutil, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import renegade_platform as rplat
import berga_tools

# What was skipped and why, printed at the end of `renegade root` / `renegade update` (skip_summary()).
SKIPPED = []


def note_skip(feature, reason):
    SKIPPED.append((feature, reason))


def not_built(what='tools/sweetnet/build.sh'):
    """Why a prebuilt on-device binary is missing. They are built with xcrun (a Mac with Xcode); nothing is compiled here."""
    if rplat.is_linux():
        return ('no prebuilt binary (they are built on a Mac with Xcode: %s; Linux installs prebuilt ones: run `renegade fetch-tools` to '
                'download berga-tools.zip, or drop artifacts in research/sweetnet/ or $RENEGADE_SWEETNET)' % what)
    return 'not built (%s; or `renegade fetch-tools` for the prebuilt berga-tools.zip)' % what


def skip_summary():
    """Print the features that were skipped, once per distinct (feature, reason)."""
    seen, rows = set(), []
    for f, r in SKIPPED:
        if (f, r) not in seen:
            seen.add((f, r))
            rows.append((f, r))
    if not rows:
        print('skipped features: none')
        return
    print('skipped features (%d):' % len(rows))
    for f, r in rows:
        print('  - %s: %s' % (f, r))

from targets import T as TARGET  # noqa: E402  (tools/renegade/targets.py, RENEGADE_TARGET)
BUILD, VERSION = TARGET['build'], TARGET['version']
MOBILE = 501


def load(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def save(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def merge_pref(root, name, values):
    """Merge keys into /var/mobile/Library/Preferences/NAME.plist (mobile, 0600)."""
    path = os.path.join(root, 'private/var/mobile/Library/Preferences', name + '.plist')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, MOBILE, MOBILE, 0o600)
    print('pref', name, sorted(values))


# Jobs that only serve the cellular modem the Poco F1 does not expose: vmd (Visual Voicemail, spins at ~80% of a core with
# no telephony, which costs SpringBoard/backboardd frames). CommCenter is NOT one of them: without it SpringBoard's
# SBTelephonyManager looks up com.apple.commcenter.xpc about once a second, fails, and refreshes the idle timer each time,
# so the lock screen never sleeps and replays its wake sequence (wallpaper zoom, lock glyph, "Swipe up to open") in a loop.
# Both stock CommCenter jobs are replaced by the non-cellular variant (what Wi-Fi-only devices run) without its
# _LimitLoadFromDeviceTree condition; it idles at 0% here.
NO_BASEBAND_JOBS = ('com.apple.CommCenter', 'com.apple.voicemail.vmd')
COMMCENTER_NONCELL = '/System/Library/LaunchDaemons/com.apple.CommCenter-noncellular.plist'


def launchd(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    renamed = 0
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
            renamed += 1
    removed = []
    for sect in plist.values():                 # LaunchDaemons and the per-domain agent sections
        if not isinstance(sect, dict):
            continue
        for k in [k for k, j in sect.items() if isinstance(j, dict) and j.get('Label') in NO_BASEBAND_JOBS]:
            removed.append(sect.pop(k)['Label'])
    cc = os.path.join(root, COMMCENTER_NONCELL.lstrip('/'))
    if os.path.exists(cc):
        job = load(cc)
        job.pop('_LimitLoadFromDeviceTree', None)
        job.pop('_PanicOnCrash', None)
        jobs[COMMCENTER_NONCELL] = job
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, removed (no baseband) {sorted(removed)}, '
          f'CommCenter: {"non-cellular job" if os.path.exists(cc) else "absent (no " + COMMCENTER_NONCELL + ")"}')


BT_LABEL = 'com.apple.bluetoothd'
# H4BC over the POSIX driver on the plain kernel control (no Skywalk channel), at the 3 Mbaud the
# kernel left the controller at. No BT_DEVICE_ADDRESS: bluetoothd (16.7 and 18.7.8 alike) sscanf()s it
# and then zeroes the result (start+0x274 / +0x278 in 18.7.8: STR WZR / STRH WZR right after the sscanf),
# exiting with "Not a valid MAC address (all 00s)" / "No bluetooth on this device"; without it, it reads
# the ADT /arm-io/bluetooth local-mac-address (tools/mkadt.py BT_MAC, IOServiceNameMatching "bluetooth").
BT_ENV = {'BT_HCI_TRANSPORT': 'H4BC:POSIX:com.apple.uart.bluetooth,3000000'}
BT_ENV_REMOVE = ('BT_DEVICE_ADDRESS',)
BLUETOOL_STUB = None        # default: find_sweetnet('bluetool-stub') at call time (tools/sweetnet/build.sh)
HCITEST = None              # same for hcitest
# WCN3990 rampatch + NVM for the kernel BT stage (sweetwlan=2, read from /usr/standalone/firmware/sweet/).
# Qualcomm firmware, never in git: RENEGADE_BT_FW=DIR with crbtfw21.tlv and crnv21.bin (linux-firmware qca/,
# the pair that worked on iOS 16 and 18; the phone's own bluetooth partition has an older pair).
BT_FW_FILES = ('crbtfw21.tlv', 'crnv21.bin')


def bluetoothd_env(plist):
    """Set BT_ENV in every bluetoothd job of a launchd.plist dict; returns the number of jobs."""
    n = 0
    for job in plist['LaunchDaemons'].values():
        if job.get('Label') == BT_LABEL:
            env = job.setdefault('EnvironmentVariables', {})
            env.update(BT_ENV)
            for k in BT_ENV_REMOVE:
                env.pop(k, None)
            n += 1
    return n


def bluetooth(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    n = bluetoothd_env(plist)
    if n == 0:
        print('bluetooth: no', BT_LABEL, 'job in launchd.plist: skipped')
        return
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print('bluetooth: BT_HCI_TRANSPORT set for', BT_LABEL)
    stub_path = BLUETOOL_STUB or find_sweetnet('bluetool-stub')
    if not stub_path or not os.path.exists(stub_path):
        print('bluetooth: BlueTool stub not built (tools/sweetnet/build.sh): BlueTool left alone')
        note_skip('bluetooth BlueTool stub + hcitest', not_built() + '; the bluetoothd launchd environment was still set')
        return
    dst = os.path.join(root, 'usr/sbin/BlueTool')
    orig = dst + '.orig'
    with open(stub_path, 'rb') as f:
        stub = f.read()
    if os.path.exists(dst) and not os.path.exists(orig):
        with open(dst, 'rb') as f:
            if f.read() != stub:
                shutil.copy2(dst, orig)
                os.chown(orig, 0, 0)
                print('bluetooth: original BlueTool kept as BlueTool.orig')
    install_file(stub_path, dst)
    print('bluetooth: /usr/sbin/BlueTool is the stub')
    hci = HCITEST or find_sweetnet('hcitest')
    if hci and os.path.exists(hci):
        install_file(hci, os.path.join(root, 'usr/local/bin/hcitest'))
        print('bluetooth: /usr/local/bin/hcitest installed')
    fw = os.environ.get('RENEGADE_BT_FW')
    if fw:
        for name in BT_FW_FILES:
            install_file(os.path.join(fw, name), os.path.join(root, 'usr/standalone/firmware/sweet', name), 0o644)
        print('bluetooth: WCN3990 firmware from', fw, 'in /usr/standalone/firmware/sweet')
    else:
        print('bluetooth: RENEGADE_BT_FW not set: no WCN3990 firmware in the root (the BT stage will not download)')


def containers(root):
    base = os.path.join(root, 'private/var/containers')
    for sub, uid in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            os.makedirs(d)
            os.chown(d, uid, uid)
            os.chmod(d, 0o755)
            print('mkdir', d)


def launchservices(root):
    # A LaunchServices DB seeded before the extension catalog was readable
    # (pre-0099) keeps every appex ignored and is reused because it is marked
    # seeded: drop it so lsd re-seeds (docs/EXTENSION_POINTS_2.md).
    for p in glob.glob(os.path.join(root, 'private/var/mobile/Containers/Data/InternalDaemon/*/'
                                          'Library/Caches/com.apple.LaunchServices*')):
        os.remove(p)
        print('rm', p)


def usbnet(root):
    """configd network service for the USB Ethernet ue0 (patches 0108-0110).

    Boot 0113: configd saw ue0 through the IOKit stand-ins but saved no
    service (empty preferences.plist / NetworkInterfaces.plist), so the
    NetworkConfigurationOverrides IPv4/DNS never applied: routes existed,
    every DNS lookup failed. An explicit service fixes the address, router
    and DNS servers. Fixed UUIDs keep it idempotent.
    """
    base = os.path.join(root, 'private/var/preferences/SystemConfiguration')
    os.makedirs(base, exist_ok=True)
    svc, nset = '5EE7C0DE-0000-4000-8000-0000000000E0', '5EE7C0DE-0000-4000-8000-0000000005E7'
    path = os.path.join(base, 'preferences.plist')
    prefs = load(path) if os.path.exists(path) else {'__VERSION__': 20191120}
    prefs.setdefault('NetworkServices', {})[svc] = {
        'UserDefinedName': 'USB Ethernet',
        'Interface': {'DeviceName': 'ue0', 'Hardware': 'Ethernet', 'Type': 'Ethernet',
                      'UserDefinedName': 'USB Ethernet'},
        'IPv4': {'ConfigMethod': 'Manual', 'Addresses': ['192.168.7.2'],
                 'SubnetMasks': ['255.255.255.0'], 'Router': '192.168.7.1'},
        'IPv6': {'ConfigMethod': 'Automatic'},
        'DNS': {'ServerAddresses': ['1.1.1.1', '8.8.8.8']},
        'Proxies': {'ExceptionsList': ['*.local', '169.254/16'], 'FTPPassive': 1},
    }
    sets = prefs.setdefault('Sets', {})
    cur = prefs.get('CurrentSet', '').rsplit('/', 1)[-1] or nset
    s = sets.setdefault(cur, {'UserDefinedName': 'Automatic', 'Network': {}})
    net = s.setdefault('Network', {})
    net.setdefault('Service', {})[svc] = {'__LINK__': '/NetworkServices/' + svc}
    order = net.setdefault('Global', {}).setdefault('IPv4', {}).setdefault('ServiceOrder', [])
    if svc not in order:
        order.insert(0, svc)
    net.setdefault('Interface', {})
    prefs['CurrentSet'] = '/Sets/' + cur
    save(path, prefs, 0, 0, 0o644)

    path = os.path.join(base, 'NetworkInterfaces.plist')
    ifs = load(path) if os.path.exists(path) else {'__VERSION__': 20191120}
    lst = [i for i in ifs.get('Interfaces', []) if i.get('BSD Name') != 'ue0']
    lst.append({'BSD Name': 'ue0', 'IOBuiltin': True, 'IOInterfaceNamePrefix': 'ue',
                'IOInterfaceType': 6, 'IOInterfaceUnit': 0,
                'IOMACAddress': bytes.fromhex('02005e77ee02'),
                'SCNetworkInterfaceType': 'Ethernet',
                'SCNetworkInterfaceInfo': {'UserDefinedName': 'USB Ethernet'}})
    ifs['Interfaces'] = lst
    save(path, ifs, 0, 0, 0o644)
    print('usbnet: service', svc, 'ue0 192.168.7.2/24 via 192.168.7.1, DNS 1.1.1.1 8.8.8.8')


SSH_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'research', 'ssh-build', 'out')
DROPBEAR_LABEL = 'org.sweet.dropbear'
DROPBEAR_KEY = '/private/etc/dropbear/dropbear_ed25519_host_key'


def install_file(src, dst, mode=0o755):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + '.new'
    shutil.copyfile(src, tmp)
    os.chown(tmp, 0, 0)
    os.chmod(tmp, mode)
    os.replace(tmp, dst)


def relink(target, link):
    if os.path.islink(link) and os.readlink(link) == target:
        return
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(target, link)


def mac_user_pubkey():
    """The Mac user's public key (ed25519 preferred); never reads private keys."""
    import pwd
    user = os.environ.get('SUDO_USER') or pwd.getpwuid(os.getuid()).pw_name
    ssh = os.path.join(pwd.getpwnam(user).pw_dir, '.ssh')
    cands = [os.path.join(ssh, 'id_ed25519.pub')] + sorted(
        p for p in glob.glob(os.path.join(ssh, '*.pub')) if not p.endswith('-cert.pub'))
    for p in cands:
        if os.path.isfile(p):
            line = open(p).read().strip().splitlines()[0]
            if line.split()[0].startswith(('ssh-', 'ecdsa-', 'sk-')):
                return p, line
    return None, None


def host_exe(out, name):
    """Host-side helper of tools/ssh/build.sh that runs on THIS machine: NAME-mac on macOS, NAME-linux (a prebuilt
    artifact) on Linux. None if absent."""
    p = os.path.join(out, name + ('-linux' if rplat.is_linux() else '-mac'))
    return p if os.path.isfile(p) else None


def toybox_applets(out):
    """Names of the toybox applets (symlinked in /usr/local/bin). Order of preference: the host toybox listing itself
    (what macOS always did), `toybox-applets.txt` next to the binaries, else derived: the CONFIG_X=y lines of
    tools/ssh/toybox.config that also appear as a C string in the iOS binary (identical to the real list on the
    22H352 build: checked against toybox-mac, plus the aliases `[` for test and `nc` for netcat)."""
    import re
    import subprocess
    host = host_exe(out, 'toybox')
    if host:
        return subprocess.run([host], capture_output=True, text=True).stdout.split()
    lst = os.path.join(out, 'toybox-applets.txt')
    if os.path.isfile(lst):
        return open(lst).read().split()
    cfg = os.path.join(HERE, '..', 'ssh', 'toybox.config')
    binary = open(os.path.join(out, 'toybox'), 'rb').read()
    cand = {m.lower() for m in re.findall(r'^CONFIG_([A-Z0-9_]+)=y', open(cfg).read(), re.M)}
    found = {c for c in cand if b'\0' + c.encode() + b'\0' in binary} - {'toybox'}
    if 'test' in found:
        found.add('[')
    if 'netcat' in found:
        found.add('nc')
    return sorted(found)


def host_dropbearkey(out):
    """A dropbearkey that runs here: the host build of tools/ssh/build.sh, or (Linux) the distribution's."""
    host = host_exe(out, 'dropbear')
    if host:
        return host, True
    import shutil as _sh
    return _sh.which('dropbearkey'), False


def ssh(root):
    """Key-only SSH over the USB link (docs/SSH_OVER_USB.md): dropbear, dash
    as /bin/sh, toybox, host keys, authorized_keys, launchd job. Needs the
    binaries from tools/ssh/build.sh in research/ssh-build/out."""
    out = os.path.normpath(SSH_OUT)
    # macOS also needs the host builds (applet list, host keys); Linux needs only the iOS binaries (see toybox_applets)
    need = [os.path.join(out, n) for n in (('dropbear', 'dash', 'toybox') if rplat.is_linux() else
                                           ('dropbear', 'dash', 'toybox', 'dropbear-mac', 'toybox-mac'))]
    missing = [p for p in need if not os.path.isfile(p)]
    if missing:
        print('ssh: skipped, not built (run tools/ssh/build.sh):', ', '.join(os.path.basename(p) for p in missing))
        note_skip('ssh (dropbear, dash, toybox)', not_built('tools/ssh/build.sh') + ': ' + ', '.join(os.path.basename(p) for p in missing))
        return
    keyfile, key = mac_user_pubkey()
    if key is None:
        print('ssh: skipped, no public key (~/.ssh/id_ed25519.pub) for the Mac user')
        return
    bindir = os.path.join(root, 'usr/local/bin')
    install_file(os.path.join(out, 'dropbear'), os.path.join(bindir, 'dropbear'))
    for n in ('dropbearkey', 'scp'):
        relink('dropbear', os.path.join(bindir, n))
    install_file(os.path.join(out, 'toybox'), os.path.join(bindir, 'toybox'))
    import subprocess
    applets = toybox_applets(out)
    n = 0
    for a in applets:
        dst = os.path.join(bindir, a)
        if a != 'toybox' and (not os.path.lexists(dst) or os.path.islink(dst)):
            relink('toybox', os.path.join(bindir, a))
            n += 1
    install_file(os.path.join(out, 'dash'), os.path.join(root, 'bin/sh'))
    print('ssh: /usr/local/bin/{dropbear,dropbearkey,scp,toybox + %d applet links}, /bin/sh = dash' % n)

    # dropbear checks the login shell against /etc/shells
    shells = os.path.join(root, 'private/etc/shells')
    lines = open(shells).read().splitlines() if os.path.exists(shells) else []
    if '/bin/sh' not in lines:
        with open(shells, 'w') as f:
            f.write('\n'.join(lines + ['/bin/sh']) + '\n')
        os.chown(shells, 0, 0)
        os.chmod(shells, 0o644)
        print('ssh: /private/etc/shells += /bin/sh')

    # root's login shell/home must be /bin/sh and /var/root
    passwd = os.path.join(root, 'private/etc/passwd')
    entry = next((l for l in open(passwd).read().splitlines() if l.startswith('root:')), None) \
        if os.path.exists(passwd) else None
    if entry is None or entry.split(':')[-2:] != ['/var/root', '/bin/sh']:
        print('warning: root entry in /private/etc/passwd is not ...:/var/root:/bin/sh:', entry)

    # authorized_keys (public key only), root-owned, strict modes
    d = os.path.join(root, 'private/var/root/.ssh')
    os.makedirs(d, exist_ok=True)
    os.chown(d, 0, 0)
    os.chmod(d, 0o700)
    ak = os.path.join(d, 'authorized_keys')
    have = open(ak).read().splitlines() if os.path.exists(ak) else []
    if key not in have:
        have.append(key)
    with open(ak, 'w') as f:
        f.write('\n'.join(have) + '\n')
    os.chown(ak, 0, 0)
    os.chmod(ak, 0o600)
    print('ssh: authorized_keys <-', keyfile)

    # host keys, generated on the Mac with the same-source dropbearkey; kept if present
    kd = os.path.join(root, 'private/etc/dropbear')
    os.makedirs(kd, exist_ok=True)
    os.chown(kd, 0, 0)
    os.chmod(kd, 0o700)
    import tempfile
    keytool, is_multi = host_dropbearkey(out)
    with tempfile.TemporaryDirectory() as tmp:
        tool = os.path.join(tmp, 'dropbearkey')
        if keytool and is_multi:
            os.symlink(keytool, tool)               # dropbearmulti picks the applet from argv[0]
        elif keytool:
            tool = keytool
        for typ in ('ed25519', 'ecdsa'):
            kf = os.path.join(kd, 'dropbear_%s_host_key' % typ)
            if os.path.exists(kf):
                print('ssh: host key kept', os.path.basename(kf))
                continue
            if not keytool:
                print('ssh: no dropbearkey for the host (Linux: apt install dropbear-bin): host key %s left to dropbear -R, '
                      'which generates it on the phone at the first connection' % typ)
                continue
            subprocess.run([tool, '-t', typ, '-f', kf], check=True, capture_output=True)
            os.chown(kf, 0, 0)
            os.chmod(kf, 0o600)
            print('ssh: host key generated', os.path.basename(kf))

    # launchd job: -s no password logins; '-p 22' listens on IPv4 and IPv6 (the link-local address still answers when
    # configd/IPConfiguration drops the static IPv4); the only network is the USB link. Without a host key generated here
    # (a Linux host with no dropbearkey), -R makes dropbear create its keys in /etc/dropbear on the phone instead
    job = {'Label': DROPBEAR_LABEL,
           'ProgramArguments': ['/usr/local/bin/dropbear', '-F', '-E', '-s', '-p', '22'] +
                               (['-r', DROPBEAR_KEY] if os.path.exists(os.path.join(root, DROPBEAR_KEY.lstrip('/'))) else ['-R']),
           'RunAtLoad': True, 'KeepAlive': True, 'UserName': 'root',
           'StandardErrorPath': '/dev/console'}
    jpath = '/System/Library/LaunchDaemons/%s.plist' % DROPBEAR_LABEL
    os.makedirs(os.path.join(root, os.path.dirname(jpath).lstrip('/')), exist_ok=True)
    save(os.path.join(root, jpath.lstrip('/')), job, 0, 0, 0o644, plistlib.FMT_XML)
    lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lpath)
    plist = load(lpath)
    plist['LaunchDaemons'][jpath] = job
    save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print('ssh: launchd job', DROPBEAR_LABEL, '(port 22 v4+v6, key-only)')


NETCFG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'research', 'sweetnet', 'sweetnetcfg')
NETCFG_LABEL = 'org.sweet.netcfg'


def netcfg(root):
    """sweetnetcfg (tools/sweetnet) at boot: publishes ue0's IPv4 + DNS state
    in configd's dynamic store, which IPConfiguration never does for ue0, so
    IPMonitor installs the default route via the Mac and the DNS servers.
    Relaunched until it succeeds (configd may not be up yet)."""
    if not os.path.exists(NETCFG):
        print('netcfg: skipped, build it first (tools/sweetnet/build.sh)')
        note_skip('netcfg (sweetnetcfg + launchd job)', not_built())
        return
    dst = os.path.join(root, 'usr/local/bin/sweetnetcfg')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(NETCFG, dst)
    os.chown(dst, 0, 0)
    os.chmod(dst, 0o755)
    job = {'Label': NETCFG_LABEL, 'ProgramArguments': ['/usr/local/bin/sweetnetcfg'],
           'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 5,
           'UserName': 'root', 'StandardErrorPath': '/dev/console'}
    jpath = '/System/Library/LaunchDaemons/%s.plist' % NETCFG_LABEL
    os.makedirs(os.path.join(root, os.path.dirname(jpath).lstrip('/')), exist_ok=True)
    save(os.path.join(root, jpath.lstrip('/')), job, 0, 0, 0o644, plistlib.FMT_XML)
    lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lpath)
    plist = load(lpath)
    plist['LaunchDaemons'][jpath] = job
    save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print('netcfg: /usr/local/bin/sweetnetcfg + launchd job', NETCFG_LABEL)


REBOOT_TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'research', 'sweetnet', 'sweetreboot')


def sweetreboot(root):
    """sweetreboot fastboot|recovery|normal (tools/sweetnet/sweetreboot.c, needs
    kernel patch 0137): sets kern.sweet_reboot_mode and reboots. No launchd job."""
    if not os.path.exists(REBOOT_TOOL):
        print('sweetreboot: skipped, build it first (tools/sweetnet/build.sh)')
        note_skip('sweetreboot', not_built())
        return
    dst = os.path.join(root, 'usr/local/bin/sweetreboot')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(REBOOT_TOOL, dst)
    os.chown(dst, 0, 0)
    os.chmod(dst, 0o755)
    print('sweetreboot: /usr/local/bin/sweetreboot')


def sweetmetrics(root):
    """/usr/local/bin/sweetmetrics: the live-metrics JSON Bergamota polls over SSH (docs/BERGAMOTA_METRICS.md,
    tools/sweetnet/sweetmetrics.c, arm64e + pacstrip --sign, tools/sweetnet/build.sh). Read-only tool, no job. Skipped
    with a message when it is not built; RENEGADE_NO_METRICS=1 skips it."""
    if os.environ.get('RENEGADE_NO_METRICS') == '1':
        print('sweetmetrics: skipped (RENEGADE_NO_METRICS=1)')
        note_skip('sweetmetrics', 'RENEGADE_NO_METRICS=1')
        return
    src = find_sweetnet('ios18/sweetmetrics')
    if not src:
        print('sweetmetrics: not built (tools/sweetnet/build.sh): skipped')
        note_skip('sweetmetrics', not_built())
        return
    install_file(src, os.path.join(root, 'usr/local/bin/sweetmetrics'))
    print('sweetmetrics: /usr/local/bin/sweetmetrics')


def find_container(root, kind, identifier):
    for meta in glob.glob(os.path.join(root, 'private/var/containers', kind, '*',
                                       '.com.apple.mobile_container_manager.metadata.plist')):
        if load(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def activation(root):
    c = find_container(root, 'Data/System', 'com.apple.mobileactivationd')
    if c is None:
        print('warning: no mobileactivationd system container in the image; skipped data ark')
        return
    d = os.path.join(c, 'Library/internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    os.chmod(d, 0o755)
    save(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('data ark', d)


def audio(root):
    src = os.path.join(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin')
    dst_dir = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled')
    if os.path.exists(src):
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(src, dst_dir)
        print('VirtualAudio.plugin disabled')
    for conf in glob.glob(os.path.join(root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        st = os.stat(conf)
        data = load(conf)
        data['StartRecorderServer'] = False
        save(conf, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, plistlib.FMT_XML)
        print('StartRecorderServer off', os.path.relpath(conf, root))


# Daemons that only crash-loop or quit at once on this bring-up while containermanagerd refuses every container lookup
# (NOTES.md 2026-10-21): 18 respawns each in the 224536 boot log, every crash = ReportCrash
# + corpse (448 `SWEET AKS: ReportCrash` lines, "Too many corpses being created"), 1022 xpcproxy spawns in total. Off by
# default (SWEET_QUIET=1 or --quiet turns it on): the point is less CPU competing with dropbear/backboardd while debugging.
QUIET_THROTTLE = {      # label -> ThrottleInterval seconds (default 10, replicatord 3, lsd 1)
    'com.apple.replicatord': 60, 'com.apple.appprotectiond': 60, 'com.apple.passd': 60,
    'com.apple.icloud.findmydeviced': 60, 'com.apple.mobileactivationd': 60,
    'com.apple.spaceattributiond': 60, 'com.apple.fairplayd.H2': 60, 'com.apple.PerfPowerServices': 60,
    'com.apple.webinspectord': 60,
}
QUIET_REMOVE = ('com.apple.security.cryptexd',)     # libimage4 panics 'failed to get manifest properties' (no ADT /chosen/manifest-properties); fixed by tools/mkpayload.py add_img4_nodes (rebuild the boot image), so removing the job is no longer needed


def quiet(root):
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    gone = [k for k, j in jobs.items() if j.get('Label') in QUIET_REMOVE]
    for k in gone:
        del jobs[k]
    n = 0
    for j in jobs.values():
        if j.get('Label') in QUIET_THROTTLE:
            j['ThrottleInterval'] = QUIET_THROTTLE[j['Label']]
            n += 1
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'quiet: removed {len(gone)} job(s) {QUIET_REMOVE}, ThrottleInterval set on {n}')


REGISTER_LIST = 'usr/local/share/renegade/register-apps'


def write_file(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)
    os.chown(path, 0, 0)
    os.chmod(path, mode)


def staged_apps(root):
    # The removable built-in apps (Safari, Photos, Messages, Camera, ...) ship in
    # /private/var/staged_system_apps; iOS installs them during first-boot setup, which our
    # boot never runs, so SpringBoard only showed Settings. Moving them into /Applications
    # (root:wheel) lets lsd see them; the first-boot job (firstboot()) then registers them with
    # LaunchServices (done by hand on the phone 2026-10-23: 39 apps, all registered).
    # Their names are kept in /usr/local/share/renegade/register-apps for that job.
    src = os.path.join(root, 'private/var/staged_system_apps')
    dst = os.path.join(root, 'Applications')
    moved = []
    if os.path.isdir(src):
        for name in sorted(os.listdir(src)):
            if not name.endswith('.app') or os.path.exists(os.path.join(dst, name)):
                continue
            os.rename(os.path.join(src, name), os.path.join(dst, name))
            for d, dirs, files in os.walk(os.path.join(dst, name)):
                for n in dirs + files:
                    os.lchown(os.path.join(d, n), 0, 0)
            os.lchown(os.path.join(dst, name), 0, 0)
            moved.append(name)
            print('staged app ->', name)
    if moved:
        lst = os.path.join(root, REGISTER_LIST)
        have = open(lst).read().split('\n') if os.path.exists(lst) else []
        write_file(lst, '\n'.join(sorted({n for n in have + moved if n})) + '\n')
    return moved


def event_timing(root):
    # UIKit looks up /System/Library/EventTimingProfiles/<target>.Default.plist with the ADT
    # target-type, which on ios18 (D22, iPhone X) is not the device the userland is for (N841 profiles only):
    # 'Misconfigured Device: Default Event Timing Profile is missing'. On ios26 both are N104: nothing to do.
    d = os.path.join(root, 'System/Library/EventTimingProfiles')
    if TARGET['board'] == TARGET['adt_target']:
        return
    for kind in ('Default', 'Touch'):
        s = os.path.join(d, '%s.%s.plist' % (TARGET['board'], kind))
        t = os.path.join(d, '%s.%s.plist' % (TARGET['adt_target'], kind))
        if os.path.exists(s) and not os.path.exists(t):
            shutil.copy2(s, t)
            print('event timing profile', t)


# ---------------------------------------------------------------------------------------------------------------
# Renegade auto-fixes (2026-10-23): what was done by hand on the live phone, baked into the root.
#
#   appreg       staged_apps() + firstboot(): first-boot job registering the apps with LaunchServices (sweetuicache)
#   posterboard  posterboard(): sweetfp.dylib linked into PosterBoard (NSURLFileProtectionKey on HFS+)
#   bluetooth    bluetooth(): BT_HCI_TRANSPORT in bluetoothd's job, BlueTool stub, hcitest
#   jb           jailbreak_userland() + firstboot(): Procursus rootless, Sileo, TrollStore (jailbreak.py)
#   wallpaper    firstboot(): the default lock poster (WALLPAPER_POSTER) + default (not tinted) icon style, once, as mobile
#   bglrender    bglrender(): the Bergamota GL renderer payload (EAGL shim over Mesa freedreno/softpipe) in /usr/local/lib/bergamota-gl and
#                backboardd's launchd job pointed at its launcher; INERT unless the kernel boot-args contain bglrender=1|soft
#
# All ON by default. Opt out with RENEGADE_NO_<FEATURE>=1 (FEATURE = APPREG, POSTERBOARD, BLUETOOTH, JB, WALLPAPER, BGLRENDER) or the
# --no-<feature> flags of `renegade root` and `renegade update`, which set the same variables.
# ON by default for this build: bgmtl() (the Bergamota Metal device linked into MercuryPosterExtension only) and its arming file, and with them the
# Mercury wallpaper; opt out with RENEGADE_NO_BGMTL=1 (or RENEGADE_BGMTL=0), ship it inert with RENEGADE_BGMTL_ARM=0. RENEGADE_BGMTL_DIR = the three
# dylibs (default research/bgmtl); without them the feature is skipped with a note and the wallpaper stays Collections 5010.
# Kill switch on the device: /private/var/tmp/bgmtl.off; the in-process dead-man writes it after two unclean launches.
# RENEGADE_DISABLE_CRYPTEXD=1 / --disable-cryptexd, cryptexd(): fallback that removes the
# crash-looping cryptexd job.
# Every function is idempotent: `renegade update` runs them again on a finished image.
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
# The default lock poster, provider:descriptor, read back from the phone's PosterBoard (sweetposterset --descriptors/--list, 2026-10-23):
# the Collections provider (com.apple.WallpaperKit.CollectionsPoster) offers the descriptors 7365 (Stripe), 5010 (Bokeh, multicolored: also
# PosterBoard's own hardwired default, `CollectionsPoster:5010`) and 400. The stock iOS 18 wallpaper is com.apple.MercuryPoster:fluidity.two,
# which needs a Metal device the ES-only render path does not have (the extension crash-loops, black screen), so it is NOT the default here.
# Collections poster 7565 (the iOS 17 wallpaper) is not a descriptor of the provider (create fails with -2218). Override: RENEGADE_WALLPAPER_POSTER=provider:descriptor
WALLPAPER_COLLECTIONS = 'com.apple.WallpaperKit.CollectionsPoster:5010'
# The stock iOS 18 wallpaper is Mercury's "fluidity" poster (Metal): provider com.apple.MercuryPoster, descriptor fluidity.two as read back from
# PosterBoard after the user picked "iOS 18" in Settings (other descriptors of the provider: fluidity.one, fluidity.dynamic). Without a Metal
# device it is black, so it is only selected when the bgmtl feature installed the Metal device; otherwise WALLPAPER_COLLECTIONS.
WALLPAPER_MERCURY = 'com.apple.MercuryPoster:fluidity.two'
def wallpaper_poster(metal):
    return os.environ.get('RENEGADE_WALLPAPER_POSTER') or (WALLPAPER_MERCURY if metal else WALLPAPER_COLLECTIONS)
WALLPAPER_POSTER = WALLPAPER_COLLECTIONS   # kept for readers of the old name: the poster used when there is no Metal device
FEATURES = ('appreg', 'posterboard', 'bluetooth', 'jb', 'wallpaper', 'bglrender')
SWEETNET_DIRS = [os.environ.get('RENEGADE_SWEETNET'),
                 os.path.join(REPO, 'research/sweetnet'),
                 os.path.join(REPO, '..', 'ios-beryllium', 'research/sweetnet'),
                 berga_tools.search_dirs()[0]]          # last: local builds win over the berga-tools cache (renegade fetch-tools)


def enabled(feature):
    if feature == 'jb' and os.environ.get('RENEGADE_JB') == '0':
        return False
    return os.environ.get('RENEGADE_NO_' + feature.upper()) != '1'


def find_sweetnet(rel):
    """First existing research/sweetnet/REL (tools/sweetnet/build.sh output) of: $RENEGADE_SWEETNET, this
    checkout, the main checkout."""
    for d in SWEETNET_DIRS:
        if d and os.path.exists(os.path.join(d, rel)):
            return os.path.abspath(os.path.join(d, rel))
    return None


UICACHE = None              # default: find_sweetnet('ios18/sweetuicache') (arm64e, pacstrip --sign)
SWEETFP = None              # default: find_sweetnet('ios18/sweetfp.dylib')
ADDLC = os.path.join(HERE, '..', 'sweetnet', 'addlc.py')
SWEETFP_PATH = '/usr/local/lib/sweetfp.dylib'
POSTER_BIN = 'Applications/PosterBoard.app/PosterBoard'


class OwnerRecorder:
    """Stand-in for os.chown/os.lchown while building WITHOUT root (mkroot-full.py, update.py): the owners are written
    into the HFS+ catalog afterwards by hfsroot_owners.py. `rec.install()` patches the os module of this process.
    On Linux as root (mounted with the hfsplus driver, which stores owners) the chown is also applied, and every owner is
    recorded, so the offline catalog pass (hfsroot_owners.py) sees the same table as on macOS.
    A chown to the owner of the process is not recorded: the image is mounted noowners, so every file shows up as the
    mounting user (501:20), and code that rewrites a file in place passes that pair on (`save(path, ..., st.st_uid,
    st.st_gid, ...)`) without meaning it; recording it gave /System/Library/xpc/launchd.plist the owner 501:20."""

    def __init__(self):
        self.owners = {}
        self.real = rplat.real_owners()
        self._chown, self._lchown = os.chown, os.lchown

    def _record(self, path, uid, gid):
        if (uid, gid) == (os.getuid(), os.getgid()) and not self.real:
            return
        self.owners[os.path.abspath(path)] = (uid, gid)

    def __call__(self, path, uid, gid, **kw):
        self._record(path, uid, gid)

    def chown(self, path, uid, gid, **kw):
        if self.real:                       # Linux as root: the owner is set for real AND kept for the catalog pass
            self._chown(path, uid, gid, **kw)
        self._record(path, uid, gid)

    def lchown(self, path, uid, gid):
        if self.real:
            self._lchown(path, uid, gid)
        self._record(path, uid, gid)

    def install(self):
        os.chown = self.chown
        os.lchown = self.lchown


def add_job(root, label, job):
    """A LaunchDaemon: its plist in /System/Library/LaunchDaemons plus the entry in the launchd.plist cache that
    launchd 18 actually reads (same as the dropbear and netcfg jobs)."""
    jpath = '/System/Library/LaunchDaemons/%s.plist' % label
    os.makedirs(os.path.join(root, os.path.dirname(jpath).lstrip('/')), exist_ok=True)
    save(os.path.join(root, jpath.lstrip('/')), job, 0, 0, 0o644, plistlib.FMT_XML)
    lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lpath)
    plist = load(lpath)
    plist['LaunchDaemons'][jpath] = job
    save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)


def macho_has_dylib(path, dylib):
    """True if the thin 64-bit Mach-O at path has a load command naming dylib (LOAD/WEAK/REEXPORT)."""
    import struct
    with open(path, 'rb') as f:
        d = f.read(1 << 16)
    magic, _cpu, _sub, _ft, ncmds, _sz = struct.unpack_from('<6I', d, 0)
    if magic != 0xfeedfacf:
        raise ValueError('%s: not a thin 64-bit Mach-O' % path)
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd in (0xc, 0x18 | 0x80000000, 0x1f, 0x8000001f):
            nm = d[off + struct.unpack_from('<I', d, off + 8)[0]:off + size].split(b'\0')[0].decode()
            if nm == dylib:
                return True
        off += size
    return False


def entitlements_of(path):
    out = rplat.read_entitlements(path)
    return plistlib.loads(out) if out else None


def posterboard(root):
    """PosterBoard fix (live 2026-10-23): the HFS+ root has no data-protection classes, so PosterBoard's check of
    NSURLFileProtectionKey on its data store fails ("Failed to migrate to Version 61 from 59", no wallpaper store).
    sweetfp.dylib (tools/sweetnet/sweetfp.m: arm64e, pacstrip --sign) keeps the class in an xattr; it is linked into
    /Applications/PosterBoard.app/PosterBoard as an extra LC_LOAD_DYLIB (tools/sweetnet/addlc.py: dyld ignores
    DYLD_INSERT_LIBRARIES for platform binaries) and the binary is re-signed ad hoc, keeping its identifier, flags
    and entitlements."""
    import subprocess, tempfile
    sys.path.insert(0, HERE)
    import pacstrip
    binp = os.path.join(root, POSTER_BIN)
    if not os.path.exists(binp):
        print('posterboard: no', POSTER_BIN, 'in the image: skipped')
        return
    dylib = SWEETFP or find_sweetnet('ios18/sweetfp.dylib')
    if not dylib:
        print('posterboard: sweetfp.dylib not built (tools/sweetnet/build.sh): skipped, PosterBoard left alone')
        note_skip('posterboard sweetfp', not_built() + '; PosterBoard left alone')
        return
    install_file(dylib, os.path.join(root, SWEETFP_PATH.lstrip('/')), 0o755)    # first: the binary must never name a missing dylib
    print('posterboard:', SWEETFP_PATH, 'installed')
    if macho_has_dylib(binp, SWEETFP_PATH):
        print('posterboard: PosterBoard already links', SWEETFP_PATH)
        return
    mode = os.stat(binp).st_mode & 0o7777
    tmpd = tempfile.mkdtemp(prefix='renegade-posterboard-')
    try:
        tmp = os.path.join(tmpd, 'PosterBoard')
        shutil.copyfile(binp, tmp)
        os.chmod(tmp, 0o755)
        ents, ident = entitlements_of(tmp), pacstrip.cs_identity(tmp)
        subprocess.run([sys.executable, '-I', ADDLC, tmp, SWEETFP_PATH], check=True)
        pacstrip.sign(tmp)
        if entitlements_of(tmp) != ents or pacstrip.cs_identity(tmp)[:2] != ident[:2]:
            sys.exit('posterboard: entitlements or identifier changed by the re-sign: PosterBoard left alone')
        if not macho_has_dylib(tmp, SWEETFP_PATH):
            sys.exit('posterboard: LC_LOAD_DYLIB missing after addlc.py')
        install_file(tmp, binp, mode)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    print('posterboard: PosterBoard links', SWEETFP_PATH, '(re-signed ad hoc as %s, %d entitlements kept)' % (
        ident[0], len(ents or {})))


# ---------------------------------------------------------------------------------------------------------------
# bgmtl (ON by default for this build, see the feature list above): the Bergamota Metal device for the stock iOS 18 wallpaper poster ONLY.
# gpu/metal/inject (branch metal): bgmtl-inject.dylib + libbgair.dylib + libdrm.2.dylib (arm64e, pacstrip --sign) go to /usr/local/lib/bgmtl and
# the dylib is linked into MercuryPosterExtension.appex's executable as an extra LC_LOAD_DYLIB (like sweetfp.dylib into PosterBoard), the binary
# re-signed ad hoc keeping identifier and entitlements. The dylib is INERT until /private/var/tmp/bgmtl.arm exists, honours the kill switch
# /private/var/tmp/bgmtl.off and carries its own dead-man (see gpu/metal/inject/bgmtl_inject.m); no other process is touched.
# Build output directory: RENEGADE_BGMTL_DIR (default research/bgmtl). Undo: delete the three files and restore the extension binary.
BGMTL_DIR_DEFAULT = os.path.join(REPO, 'research/bgmtl')
BGMTL_LIB_DIR = '/usr/local/lib/bgmtl'
BGMTL_INJECT = BGMTL_LIB_DIR + '/bgmtl-inject.dylib'
MERCURY_BIN = 'System/Library/ExtensionKit/Extensions/MercuryPosterExtension.appex/MercuryPosterExtension'


def bgmtl_arm(root):
    if os.environ.get('RENEGADE_BGMTL_ARM') != '0':          # ON by default (the user's decision: the image ships Metal Mercury); RENEGADE_BGMTL_ARM=0 leaves it inert
        arm = os.path.join(root, 'private/var/tmp/bgmtl.arm')
        os.makedirs(os.path.dirname(arm), exist_ok=True)
        with open(arm, 'w') as f:
            f.write('armed by renegade bgmtl (RENEGADE_BGMTL_ARM=0 to ship it inert)\n')
        print('bgmtl: /private/var/tmp/bgmtl.arm written: Mercury renders through BGMTLDevice at boot (dead-man and kill switch bgmtl.off apply)')


def bgmtl(root):
    import subprocess, tempfile
    sys.path.insert(0, HERE)
    import pacstrip
    binp = os.path.join(root, MERCURY_BIN)
    if not os.path.exists(binp):
        print('bgmtl: no', MERCURY_BIN, 'in the image: skipped')
        return False
    src = os.environ.get('RENEGADE_BGMTL_DIR') or BGMTL_DIR_DEFAULT
    names = ('bgmtl-inject.dylib', 'libbgair.dylib', 'libdrm.2.dylib')
    if not all(os.path.exists(os.path.join(src, n)) for n in names):
        print('bgmtl: %s not built (gpu/metal/build-probe.sh; copy the three dylibs there): skipped, Mercury left alone' % src)
        note_skip('bgmtl', 'bgmtl dylibs not found in ' + src + '; MercuryPosterExtension left alone')
        return False
    for n in names:                                        # first: the binary must never name a missing dylib
        # signed exactly as the ones on the test phone were (`pacstrip --sign`: PAC stripped, ad hoc), whatever state they were built in
        sd = tempfile.mkdtemp(prefix='renegade-bgmtl-lib-')
        try:
            tmpl = os.path.join(sd, n)
            shutil.copyfile(os.path.join(src, n), tmpl)
            subprocess.run([sys.executable, '-I', os.path.join(HERE, 'pacstrip.py'), '--sign', tmpl], check=True, stdout=subprocess.DEVNULL)
            install_file(tmpl, os.path.join(root, BGMTL_LIB_DIR.lstrip('/'), n), 0o755)
        finally:
            shutil.rmtree(sd, ignore_errors=True)
    print('bgmtl: dylibs installed in', BGMTL_LIB_DIR)
    if macho_has_dylib(binp, BGMTL_INJECT):
        print('bgmtl: MercuryPosterExtension already links', BGMTL_INJECT)
        bgmtl_arm(root)
        return True
    mode = os.stat(binp).st_mode & 0o7777
    tmpd = tempfile.mkdtemp(prefix='renegade-bgmtl-')
    try:
        tmp = os.path.join(tmpd, 'MercuryPosterExtension')
        shutil.copyfile(binp, tmp)
        os.chmod(tmp, 0o755)
        ents, ident = entitlements_of(tmp), pacstrip.cs_identity(tmp)
        subprocess.run([sys.executable, '-I', ADDLC, tmp, BGMTL_INJECT], check=True)
        pacstrip.sign(tmp)
        if entitlements_of(tmp) != ents or pacstrip.cs_identity(tmp)[:2] != ident[:2]:
            sys.exit('bgmtl: entitlements or identifier changed by the re-sign: MercuryPosterExtension left alone')
        if not macho_has_dylib(tmp, BGMTL_INJECT):
            sys.exit('bgmtl: LC_LOAD_DYLIB missing after addlc.py')
        install_file(tmp, binp, mode)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    print('bgmtl: MercuryPosterExtension links %s (re-signed ad hoc as %s, %d entitlements kept); inert until /private/var/tmp/bgmtl.arm exists' % (
        BGMTL_INJECT, ident[0], len(ents or {})))
    bgmtl_arm(root)
    return True


FIRSTBOOT_LABEL = 'org.bergamota.renegade-firstboot'
FIRSTBOOT_SH = 'usr/local/libexec/renegade-firstboot.sh'
FIRSTBOOT_DONE = 'private/var/db/.renegade-firstboot-done'
FIRSTBOOT_SCRIPT = r'''#!/bin/sh
# Renegade first boot (root_tweaks18.firstboot), run by the launchd job org.bergamota.renegade-firstboot.
#  1. APPREG: register /Applications apps listed in /usr/local/share/renegade/register-apps with LaunchServices:
#       /usr/local/bin/sweetuicache /Applications/NAME.app      (one call per app, as root, like the live fix)
#     LaunchServices answers only once lsd is up, so the first app is retried (5 s apart, 10 min at most).
#  2. the jailbreak post-install (/var/jb/usr/share/renegade-jb/postinstall.sh) if the root has one
#  3. WALL: the default wallpaper (a Core Animation poster, no Metal: WALLPAPER_POSTER) and icon style (default, not tinted), once, as mobile:
#     /private/var/tmp/sweetrun.sh is written, `sweetopen com.sweet.run` starts SweetRun.app through FrontBoard (an app
#     lives in the mobile user's launchd domain, where PosterBoard's XPC service is reachable) and the script runs
#     sweetposterset (retried: -2203 while PosterBoard's store has no lock role yet, or the service is not up) and
#     sweeticonstyle. Marker /private/var/db/.renegade-poster-done
#  4. disables itself: marker /private/var/db/.renegade-firstboot-done (after 3 incomplete runs too)
DONE=/private/var/db/.renegade-firstboot-done
TRIES=/private/var/db/.renegade-firstboot-tries
[ -e $DONE ] && exit 0
PATH=/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
exec >>/private/var/log/renegade-firstboot.log 2>&1
n=0
[ -f $TRIES ] && n=$(cat $TRIES)
n=$((n+1))
echo $n >$TRIES
echo "== renegade first boot, run $n: $(date)"
rc=0
APPREG=@APPREG@
UIC=/usr/local/bin/sweetuicache
LIST=/usr/local/share/renegade/register-apps
reg() {
	out=$($UIC "/Applications/$1" 2>&1)
	r=$?
	echo "$out"
	return $r
}
if [ $APPREG = 1 ] && [ -x $UIC ] && [ -s $LIST ]; then
	first=1
	bad=
	while read app; do
		[ -d "/Applications/$app" ] || continue
		if [ $first = 1 ]; then
			first=0
			t=0
			until reg "$app"; do
				t=$((t+1))
				[ $t -ge 120 ] && { bad="$bad $app"; break; }
				sleep 5
			done
			continue
		fi
		reg "$app" || bad="$bad $app"
	done <$LIST
	for app in $bad; do      # one more round for the failures
		reg "$app" || rc=1
	done
	[ $rc = 0 ] && echo "apps registered" || echo "registration incomplete"
fi
WALL=@WALL@
PDONE=/private/var/db/.renegade-poster-done
if [ $WALL = 1 ] && [ ! -e $PDONE ] && [ -d /Applications/SweetRun.app ]; then
	echo "-- default wallpaper and icon style, as mobile via SweetRun"
	T=/private/var/tmp
	t=0
	until reg SweetRun.app; do      # idempotent; lsd may not be up yet when appreg is off
		t=$((t+1))
		[ $t -ge 24 ] && break
		sleep 5
	done
	rm -f $T/sweetrun.log $T/renegade-poster.rc
	cat >$T/sweetrun.sh <<'EOS'
export PATH=/usr/local/bin:/usr/bin:/bin
n=0
ok=1
while [ $n -lt 20 ]; do
	n=$((n+1))
	echo "sweetposterset try $n"
	/usr/local/bin/sweetposterset @WPROV@ @WDESC@ && { ok=0; break; }
	sleep 10
done
echo "sweetposterset rc=$ok"
# the Metal poster could not be selected (Mercury is black without the Metal device): fall back to the Collections poster, which ES renders
if [ $ok != 0 ] && [ "@WPROV@:@WDESC@" != "@WPROV2@:@WDESC2@" ]; then
	n=0
	while [ $n -lt 10 ]; do
		n=$((n+1))
		echo "fallback sweetposterset try $n"
		/usr/local/bin/sweetposterset @WPROV2@ @WDESC2@ && { ok=0; break; }
		sleep 10
	done
	[ $ok = 0 ] && { /usr/local/bin/sweetposterset --cleanup @WPROV2@ @WDESC2@; ok=0; }
else
# "already selected" counts as done (rc 0); drop duplicate Gradient configurations an older tool left behind
[ $ok = 0 ] && /usr/local/bin/sweetposterset --cleanup @WPROV@ @WDESC@
fi
/usr/local/bin/sweeticonstyle default || ok=1
echo $ok >/private/var/tmp/renegade-poster.rc
EOS
	chmod 644 $T/sweetrun.sh
	t=0
	until /usr/local/bin/sweetopen com.sweet.run; do      # works once SpringBoard is up
		t=$((t+1))
		[ $t -ge 120 ] && break
		sleep 5
	done
	t=0
	while [ ! -e $T/renegade-poster.rc ] && [ $t -lt 240 ]; do
		t=$((t+1))
		sleep 5
	done
	cat $T/sweetrun.log
	if [ -e $T/renegade-poster.rc ] && [ "$(cat $T/renegade-poster.rc)" = 0 ]; then
		touch $PDONE
		echo "wallpaper and icon style set"
	else
		rc=1
		echo "wallpaper/icon style not set (retried on the next boot)"
	fi
fi
JBPI=/var/jb/usr/share/renegade-jb/postinstall.sh
if [ -f $JBPI ] && [ ! -e /var/jb/.renegade-jb-done ]; then
	echo "-- jailbreak post-install ($JBPI)"
	/bin/sh $JBPI
	[ -e /var/jb/.renegade-jb-done ] || rc=1
fi
if [ $rc = 0 ] || [ $n -ge 3 ]; then
	touch $DONE
	echo "== done (rc=$rc), first-boot job disabled"
fi
exit 0
'''


def firstboot(root, appreg=True, jb=True, wallpaper=True, metal=False):
    """First-boot job: app registration with sweetuicache and, when the root has /var/jb, the jailbreak post-install
    (Sileo and TrollStore registration). Runs from the launchd.plist cache, needs /bin/sh (dash, ssh tweak). Disables
    itself with /private/var/db/.renegade-firstboot-done. Also installs /usr/local/bin/sweetuicache (arm64e,
    pacstrip --sign, tools/sweetnet/build.sh)."""
    if not appreg and not jb and not wallpaper:
        print('firstboot: appreg, jb and wallpaper are all off: no job')
        return
    if not os.path.exists(os.path.join(root, 'bin/sh')):
        print('firstboot: /bin/sh missing (the ssh tweak installs dash): skipped')
        note_skip('first-boot job (app registration, wallpaper, jailbreak post-install)',
                  '/bin/sh missing in the root: dash comes from the ssh tweak, which needs prebuilt dropbear/dash/toybox')
        return
    uic = UICACHE or find_sweetnet('ios18/sweetuicache')
    if uic:
        install_file(uic, os.path.join(root, 'usr/local/bin/sweetuicache'))
    else:
        # No sweetuicache (xcrun-built): the job still runs, for the jailbreak post-install. The apps were moved into
        # /Applications offline by staged_apps(); lsd registers system apps itself when it seeds a fresh LaunchServices
        # database (fresh userdata), but an already-seeded database does not learn about them without sweetuicache.
        print('firstboot: sweetuicache not built (tools/sweetnet/build.sh): app registration skipped')
        if appreg:
            note_skip('appreg (sweetuicache)', not_built() + '; the apps are still moved to /Applications and lsd registers them '
                      'itself when it seeds a fresh LaunchServices database (fresh userdata); an already-seeded database does not')
        if wallpaper:
            note_skip('wallpaper + icon style', 'needs sweetuicache to register SweetRun at first boot: ' + not_built())
        appreg = wallpaper = False
        if not jb:
            print('firstboot: nothing left for the job to do: no job')
            return
    if wallpaper:
        wall = [find_sweetnet('ios18/' + n) for n in ('sweetposterset', 'sweeticonstyle', 'sweetopen', 'SweetRun.app')]
        if not all(wall):
            print('firstboot: sweetposterset/sweeticonstyle/sweetopen/SweetRun.app not built (tools/sweetnet/build.sh): '
                  'default wallpaper and icon style skipped')
            note_skip('wallpaper tools (sweetposterset, sweeticonstyle, sweetopen, SweetRun.app)', not_built())
            wallpaper = False
        else:
            for n, src in zip(('sweetposterset', 'sweeticonstyle', 'sweetopen'), wall):
                install_file(src, os.path.join(root, 'usr/local/bin', n))
            app = os.path.join(root, 'Applications/SweetRun.app')
            if os.path.exists(app):
                shutil.rmtree(app)
            shutil.copytree(wall[3], app, symlinks=True)
            for d, dirs, files in os.walk(app):
                for n in dirs + files:
                    os.lchown(os.path.join(d, n), 0, 0)
            os.lchown(app, 0, 0)
            print('firstboot: sweetposterset, sweeticonstyle, sweetopen, /Applications/SweetRun.app installed')
    write_file(os.path.join(root, FIRSTBOOT_SH), FIRSTBOOT_SCRIPT.replace('@APPREG@', '1' if appreg else '0')
               .replace('@WALL@', '1' if wallpaper else '0')
               .replace('@WPROV@', wallpaper_poster(metal).split(':', 1)[0]).replace('@WDESC@', wallpaper_poster(metal).split(':', 1)[1])
               .replace('@WPROV2@', WALLPAPER_COLLECTIONS.split(':', 1)[0]).replace('@WDESC2@', WALLPAPER_COLLECTIONS.split(':', 1)[1]), 0o755)
    print('firstboot: wallpaper poster', wallpaper_poster(metal), '(Metal device installed)' if metal else '(no Metal device)')
    add_job(root, FIRSTBOOT_LABEL, {
        'Label': FIRSTBOOT_LABEL, 'ProgramArguments': ['/bin/sh', '/' + FIRSTBOOT_SH],
        'RunAtLoad': True, 'UserName': 'root', 'StandardErrorPath': '/dev/console',
        'EnvironmentVariables': {'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}})
    reg = os.path.join(root, REGISTER_LIST)
    n = len([l for l in open(reg).read().split('\n') if l]) if os.path.exists(reg) else 0
    print('firstboot: job %s (%d apps to register, appreg %s, wallpaper %s, jailbreak post-install %s)' % (
        FIRSTBOOT_LABEL, n, 'on' if appreg else 'off', 'on' if wallpaper else 'off', 'if present' if jb else 'off'))


def jailbreak_userland(root, owners_out, force=False, prestaged=False):
    """Procursus rootless + Sileo + TrollStore into /private/var/jb (jailbreak.py image_stage); /var stays the
    symlink to private/var. Skipped when the pinned versions are already installed (force: reinstall)."""
    sys.path.insert(0, HERE)
    import jailbreak
    inst = os.path.join(root, 'private/var/jb/usr/share/renegade-jb/VERSIONS')
    if not force and os.path.exists(inst) and open(inst).read() == jailbreak.versions_text():
        print('jailbreak: /var/jb already at the pinned versions: skipped (force to reinstall)')
        return 0
    if not prestaged:
        jailbreak.fetch()
        jailbreak.stage_build()
    n = jailbreak.image_stage(root, owners_out)
    print('jailbreak: %d paths in /private/var/jb, first-boot post-install by the %s job' % (n, FIRSTBOOT_LABEL))
    return n


CRYPTEXD_LABEL = 'com.apple.security.cryptexd'


def cryptexd(root):
    """OPT-IN fallback (RENEGADE_DISABLE_CRYPTEXD=1 / --disable-cryptexd): cryptexd cannot personalize or graft cryptexes
    without Apple's secure boot and traps (sig 5) in a respawn loop; Renegade has already merged the cryptex contents
    into the root. Removes its job from the launchd.plist cache (the one launchd 18 reads) and moves
    /System/Library/LaunchDaemons/com.apple.security.cryptexd.plist to cryptexd.plist.renegade-disabled. The real fix
    (stubbing the trap) lives on the cryptexd branch; this is only the fallback."""
    path = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(path)
    plist = load(path)
    jobs = plist['LaunchDaemons']
    gone = [k for k, j in jobs.items() if j.get('Label') == CRYPTEXD_LABEL]
    for k in gone:
        del jobs[k]
    if gone:
        save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    jp = os.path.join(root, 'System/Library/LaunchDaemons/%s.plist' % CRYPTEXD_LABEL)
    moved = os.path.exists(jp)
    if moved:
        os.replace(jp, jp + '.renegade-disabled')
        os.chown(jp + '.renegade-disabled', 0, 0)
    print('cryptexd: %d launchd.plist job(s) removed, LaunchDaemons plist %s' % (
        len(gone), 'moved aside' if moved else 'not present (already disabled)'))


BGL_DIRS = [os.environ.get('RENEGADE_BGL'),
            os.path.join(REPO, 'research/bergamota-gl'),
            os.path.join(REPO, '..', 'ios-beryllium', 'research/bergamota-gl'),
            os.path.join(REPO, '..', 'ios-beryllium-gpu-eagl', 'research/bergamota-gl'),
            berga_tools.search_dirs()[1]]               # last: the berga-tools cache (renegade fetch-tools)
BGL_FILES = ('bgl-launch', 'OpenGLES.framework/OpenGLES', 'libOSMesa.8.dylib', 'libdrm.2.dylib')
BGL_DIR = 'usr/local/lib/bergamota-gl'
BGL_LAUNCH = '/usr/local/lib/bergamota-gl/bgl-launch'
BACKBOARDD_LABEL, BACKBOARDD_PATH = 'com.apple.backboardd', '/usr/libexec/backboardd'


def find_bgl():
    """The payload directory built by gpu/eagl/make-payload.sh (ios-beryllium gpu-eagl branch): $RENEGADE_BGL, this checkout,
    the main checkout or the gpu-eagl worktree; None when it is incomplete."""
    for d in BGL_DIRS:
        if d and all(os.path.isfile(os.path.join(d, f)) for f in BGL_FILES):
            return os.path.abspath(d)
    return None


def bglrender(root):
    """The Bergamota GL renderer for backboardd (docs/GPU_EAGL.md in the gpu-eagl branch). Installs the payload under
    /usr/local/lib/bergamota-gl and makes backboardd's job (the launchd.plist cache entry that launchd 18 reads; the per-job
    plist stays as it is) start bgl-launch, which execs the real /usr/libexec/backboardd and injects the shim ONLY when
    the kernel boot-args contain bglrender=1 (GPU if the kernel has one, else softpipe) or bglrender=soft (softpipe);
    without the boot-arg, or on any doubt (missing/unreadable file, three starts in a minute in one boot, state not writable),
    it execs plain backboardd: the system then behaves as without this tweak. Skipped (job untouched) when the payload is not built."""
    src = find_bgl()
    if not src:
        print('bglrender: payload not built (gpu/eagl/make-payload.sh): backboardd job left alone')
        note_skip('bglrender', 'no prebuilt payload (gpu/eagl/make-payload.sh, needs a Mac; or a CI artifact in research/bergamota-gl/ '
                  'or $RENEGADE_BGL, or `renegade fetch-tools`); backboardd job left alone')
        return
    dst = os.path.join(root, BGL_DIR)
    for d in (dst, os.path.join(dst, 'OpenGLES.framework')):
        os.makedirs(d, exist_ok=True)
        os.chown(d, 0, 0)
        os.chmod(d, 0o755)
    # the launcher goes last: a job pointing at a missing launcher would not start backboardd at all
    for f in BGL_FILES[1:] + BGL_FILES[:1]:
        install_file(os.path.join(src, f), os.path.join(dst, f))
    n = 0
    lpath = os.path.join(root, 'System/Library/xpc/launchd.plist')
    st = os.stat(lpath)
    plist = load(lpath)
    # Only the launchd.plist cache is edited (launchd 18 reads that, not the per-job plist; editing the latter in place would also
    # need an owner-map entry for no gain).
    for job in [j for j in plist['LaunchDaemons'].values() if j.get('Label') == BACKBOARDD_LABEL]:
        pa = job.get('ProgramArguments')
        if pa and pa[0] == BACKBOARDD_PATH:
            pa[0] = BGL_LAUNCH
            n += 1
        elif pa and pa[0] == BGL_LAUNCH:
            n += 1
    save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print('bglrender: payload from %s installed in /%s; backboardd job -> %s (%d entr%s; inert without boot-arg bglrender=1|soft)' % (
        src, BGL_DIR, BGL_LAUNCH, n, 'y' if n == 1 else 'ies'))


def tool_gaps(feats):
    """Features of `feats` (name -> bool) that cannot run because the prebuilt binaries they install are missing
    (always the case on Linux without CI artifacts). Returns {feature: reason} and records each in the skip summary;
    callers switch those features off instead of failing."""
    gaps = {}
    if not (UICACHE or find_sweetnet('ios18/sweetuicache')):
        if feats.get('appreg'):
            gaps['appreg'] = ('sweetuicache ' + not_built() + '; the apps are still moved to /Applications and lsd registers them '
                              'itself when it seeds a fresh LaunchServices database (fresh userdata); an already-seeded one does not')
        if feats.get('wallpaper'):
            gaps['wallpaper'] = 'needs sweetuicache (registers SweetRun at first boot): ' + not_built()
    if feats.get('wallpaper') and 'wallpaper' not in gaps and not all(
            find_sweetnet('ios18/' + n) for n in ('sweetposterset', 'sweeticonstyle', 'sweetopen', 'SweetRun.app')):
        gaps['wallpaper'] = 'sweetposterset/sweeticonstyle/sweetopen/SweetRun.app ' + not_built()
    if feats.get('posterboard') and not (SWEETFP or find_sweetnet('ios18/sweetfp.dylib')):
        gaps['posterboard'] = 'sweetfp.dylib ' + not_built() + '; PosterBoard is left alone'
    if feats.get('bglrender') and not find_bgl():
        gaps['bglrender'] = ('payload: no prebuilt bergamota-gl (gpu/eagl/make-payload.sh needs a Mac; or a CI artifact in '
                             'research/bergamota-gl/ or $RENEGADE_BGL, or `renegade fetch-tools`)')
    for f, r in gaps.items():
        note_skip(f, r)
    return gaps


def ssh_out():
    """Where dropbear/dash/toybox are: tools/ssh/build.sh output in this checkout or the main one, else the berga-tools
    cache (renegade fetch-tools, berga-tools-v2 and later), else the default path (the ssh tweak then reports them missing)."""
    main = os.path.join(REPO, '..', 'ios-beryllium')
    for d in (os.path.join(REPO, 'research/ssh-build/out'), os.path.join(main, 'research/ssh-build/out'), berga_tools.ssh_dir()):
        if d and os.path.isfile(os.path.join(d, 'dash')):
            return d
    return SSH_OUT


def configure_paths():
    """Tool locations for the build and for `renegade update`: this checkout first, then the main checkout."""
    global SSH_OUT, NETCFG, REBOOT_TOOL
    SSH_OUT = ssh_out()
    NETCFG = find_sweetnet('sweetnetcfg') or NETCFG
    REBOOT_TOOL = find_sweetnet('sweetreboot') or REBOOT_TOOL


def iosroot_dirs(root):
    """logd stores and the system keybag of the built-in AppleKeyStore (same as tools/mkiosroot-macos.sh)."""
    for d in ('private/var/db/diagnostics', 'private/var/db/uuidtext', 'private/var/db/diagnostics/timesync'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
        os.chown(os.path.join(root, d), 272, 272)
        m = os.path.join(root, d, '.migrated')
        open(m, 'a').close()
        os.chmod(m, 0o644)
        os.chown(m, 272, 272)
    os.chmod(os.path.join(root, 'private/var/db/diagnostics'), 0o751)
    kb = os.path.join(root, 'private/var/keybags')
    os.makedirs(kb, exist_ok=True)
    os.chmod(kb, 0o700)
    kf = os.path.join(kb, 'systembag.kb')
    if not os.path.exists(kf):
        with open(kf, 'w') as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                    '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n')
    os.chmod(kf, 0o600)


def prefs(root):
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD, 'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    merge_pref(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True, 'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False,
        'SBShowBatteryPercentage': True})        # status-bar battery percentage (live: sweetprefs mobile com.apple.springboard SBShowBatteryPercentage bool 1)
    merge_pref(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11, 'daemonizeNeedsToRun': False})
    merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
        k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy',
                           'ShouldRunMesaMiniBuddy', 'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                           'SilentICDPUpgrade')})
    merge_pref(root, 'com.apple.managedconfiguration.notbackedup',
               {'LockdownActivationIndicatesCloudConfigurationAvailable': False})


def sweetprefs_tool(root):
    """/usr/local/bin/sweetprefs (tools/sweetnet/sweetprefs.c, arm64e + pacstrip): set/read a user default through cfprefsd."""
    src = find_sweetnet('ios18/sweetprefs')
    if not src:
        print('sweetprefs: not built (tools/sweetnet/build.sh): skipped')
        note_skip('sweetprefs tool', not_built() + '; the preferences themselves (battery %, ...) are written as plists')
        return
    install_file(src, os.path.join(root, 'usr/local/bin/sweetprefs'))
    print('sweetprefs: /usr/local/bin/sweetprefs installed')
    # remote testing over SSH (tools/sweetnet/sweetshot.m, sweettouch.c): screenshot of the scanned frame, synthetic touch/buttons
    for n in ('sweetshot', 'sweettouch'):
        t = find_sweetnet('ios18/' + n)
        if t:
            install_file(t, os.path.join(root, 'usr/local/bin', n))
            print('%s: /usr/local/bin/%s installed' % (n, n))
        else:
            note_skip(n + ' tool', not_built())


def base(root):
    """Everything of the original tweaks stage that is idempotent and not an auto-fix, in build order: what `renegade
    update` runs before auto(), so an image built before a tweak existed (event_timing was only in main()) gets it.
    Skipped on purpose: patch_mount_phase2 (opt-in), the console bring-up job (informational), the quiet() set
    (opt-in: SWEET_QUIET=1 is honoured here too)."""
    configure_paths()
    launchd(root)
    if os.environ.get('SWEET_QUIET') == '1':
        quiet(root)
    containers(root)
    launchservices(root)
    event_timing(root)
    usbnet(root)
    netcfg(root)
    sweetreboot(root)
    ssh(root)
    audio(root)
    activation(root)
    prefs(root)
    sweetprefs_tool(root)
    iosroot_dirs(root)


def auto(root):
    """The Renegade auto-fixes, in build order (the jb payload is copied by jailbreak_userland, it needs a staging
    step with downloads and an owner map)."""
    staged_apps(root)
    if enabled('bluetooth'):
        bluetooth(root)
    if enabled('posterboard'):
        posterboard(root)
    # Metal Mercury ships by default (RENEGADE_NO_BGMTL=1 / RENEGADE_BGMTL=0 opts out). It goes in FIRST: the dylibs and bgmtl.arm are in the image
    # before the first-boot job can select the Mercury wallpaper, and so before PosterBoard ever launches Mercury. The wallpaper follows the outcome.
    metal = False
    if os.environ.get('RENEGADE_NO_BGMTL') != '1' and os.environ.get('RENEGADE_BGMTL') != '0':
        metal = bgmtl(root)
    firstboot(root, appreg=enabled('appreg'), jb=enabled('jb'), wallpaper=enabled('wallpaper'), metal=metal)
    if enabled('bglrender'):
        bglrender(root)
    if os.environ.get('RENEGADE_DISABLE_CRYPTEXD') == '1':      # opt-in, off by default
        cryptexd(root)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--bt-plist':
        plist = load(sys.argv[2])
        if bluetoothd_env(plist) == 0:
            sys.exit('no %s job in %s' % (BT_LABEL, sys.argv[2]))
        with open(sys.argv[3], 'wb') as f:
            plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
        print('%s: %s environment %s' % (sys.argv[3], BT_LABEL, BT_ENV))
        return
    if len(sys.argv) != 2 or not os.path.isdir(os.path.join(sys.argv[1], 'System/Library/xpc')):
        sys.exit(__doc__)
    root = sys.argv[1]
    launchd(root)
    if os.environ.get('SWEET_QUIET') == '1':
        quiet(root)
    containers(root)
    launchservices(root)
    event_timing(root)
    usbnet(root)
    netcfg(root)
    sweetreboot(root)
    sweetmetrics(root)
    ssh(root)
    auto(root)        # staged apps, bluetooth, PosterBoard, first-boot job (opt-outs: RENEGADE_NO_*)
    activation(root)
    audio(root)
    merge_pref(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMUserDataDisposition': {'SyntheticDidUpgrade': False, 'buildVersion': BUILD}})
    merge_pref(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False})
    merge_pref(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
        'daemonizeNeedsToRun': False})
    merge_pref(root, 'com.apple.purplebuddy.notbackedup', {
        k: False for k in ('ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy',
                           'ShouldRunKeychainSyncMiniBuddy', 'ShouldRunMesaMiniBuddy',
                           'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
                           'SilentICDPUpgrade')})
    merge_pref(root, 'com.apple.managedconfiguration.notbackedup', {
        'LockdownActivationIndicatesCloudConfigurationAvailable': False})
    skip_summary()


if __name__ == '__main__':
    main()
