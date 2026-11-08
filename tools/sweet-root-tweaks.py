#!/usr/bin/env python3
"""Apply the SWEET bring-up changes to an iOS root made by tools/mkiosroot.sh.

  sudo sweet-root-tweaks.py MOUNTED_ROOT

MOUNTED_ROOT is the HFS+ image mounted read-write (Linux: run
`fsck.hfsplus -fy` on the image, then `mount -t hfsplus -o loop,force`).
Run as root (it writes root/mobile owned files). Idempotent. This is what
turned the plain mkiosroot.sh output into the images that reach the home
screen (image versions v8-v14 in NOTES.md):

  launchd.plist   _PanicOnCrash -> _PanicOnCrasX (a crashing daemon must not
                  panic the system); CommCenter jobs removed (no baseband: it
                  crash-loops and Setup blocks on its CoreTelephony XPC)
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
  ssh             key-only dropbear on 192.168.7.2:22 + dash (/bin/sh) + toybox
                  from tools/ssh/build.sh, authorized_keys from the Mac user's
                  public key, host keys, launchd job (docs/SSH_OVER_USB.md);
                  skipped if the binaries are not built
"""
import glob, os, plistlib, shutil, sys

BUILD, VERSION = '20H392', '16.7.16'
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
    data = load(path) if os.path.exists(path) else {}
    data.update(values)
    save(path, data, MOBILE, MOBILE, 0o600)
    print('pref', name, sorted(values))


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
    removed = [k for k, j in jobs.items() if j.get('Label') == 'com.apple.CommCenter']
    for k in removed:
        del jobs[k]
    save(path, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)
    print(f'launchd.plist: {renamed} _PanicOnCrash renamed, {len(removed)} CommCenter jobs removed')


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


def ssh(root):
    """Key-only SSH over the USB link (docs/SSH_OVER_USB.md): dropbear, dash
    as /bin/sh, toybox, host keys, authorized_keys, launchd job. Needs the
    binaries from tools/ssh/build.sh in research/ssh-build/out."""
    out = os.path.normpath(SSH_OUT)
    need = [os.path.join(out, n) for n in ('dropbear', 'dash', 'toybox', 'dropbear-mac', 'toybox-mac')]
    missing = [p for p in need if not os.path.isfile(p)]
    if missing:
        print('ssh: skipped, not built (run tools/ssh/build.sh):', ', '.join(os.path.basename(p) for p in missing))
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
    applets = subprocess.run([os.path.join(out, 'toybox-mac')], capture_output=True, text=True).stdout.split()
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
    with tempfile.TemporaryDirectory() as tmp:
        tool = os.path.join(tmp, 'dropbearkey')
        os.symlink(os.path.join(out, 'dropbear-mac'), tool)
        for typ in ('ed25519', 'ecdsa'):
            kf = os.path.join(kd, 'dropbear_%s_host_key' % typ)
            if os.path.exists(kf):
                print('ssh: host key kept', os.path.basename(kf))
                continue
            subprocess.run([tool, '-t', typ, '-f', kf], check=True, capture_output=True)
            os.chown(kf, 0, 0)
            os.chmod(kf, 0o600)
            print('ssh: host key generated', os.path.basename(kf))

    # launchd job: -s no password logins, bound to the USB link address
    job = {'Label': DROPBEAR_LABEL,
           'ProgramArguments': ['/usr/local/bin/dropbear', '-F', '-E', '-s', '-p', '192.168.7.2:22',
                                '-r', DROPBEAR_KEY],
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
    print('ssh: launchd job', DROPBEAR_LABEL, '(192.168.7.2:22, key-only)')


NETCFG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'research', 'sweetnet', 'sweetnetcfg')
NETCFG_LABEL = 'org.sweet.netcfg'


def netcfg(root):
    """sweetnetcfg (tools/sweetnet) at boot: publishes ue0's IPv4 + DNS state
    in configd's dynamic store, which IPConfiguration never does for ue0, so
    IPMonitor installs the default route via the Mac and the DNS servers.
    Relaunched until it succeeds (configd may not be up yet)."""
    if not os.path.exists(NETCFG):
        print('netcfg: skipped, build it first (tools/sweetnet/build.sh)')
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


def main():
    if len(sys.argv) != 2 or not os.path.isdir(os.path.join(sys.argv[1], 'System/Library/xpc')):
        sys.exit(__doc__)
    root = sys.argv[1]
    launchd(root)
    containers(root)
    launchservices(root)
    usbnet(root)
    netcfg(root)
    ssh(root)
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


if __name__ == '__main__':
    main()
