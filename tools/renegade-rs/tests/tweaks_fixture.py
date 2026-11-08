#!/usr/bin/env python3
"""A synthetic iOS root for the tweaks comparison (our own content only), and the Python side of the comparison.

  tweaks_fixture.py make ROOT TOOLS            build the root and two fake tool binaries
  tweaks_fixture.py run ROOT TOOLS [--quiet]   root_tweaks18.py's functions (base() + auto() order, the ported ones)
"""
import datetime, os, plistlib, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RENEGADE = os.path.normpath(os.path.join(HERE, '..', '..', 'renegade'))


def w(root, rel, data, mode=0o644):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)
    os.chmod(p, mode)


def make(root, tools):
    shared = {'SuccessfulExit': False, 'Crashed': True}          # one object in two jobs: a shared ref in the bplist
    jobs = {
        '/System/Library/LaunchDaemons/com.apple.foo.plist': {'Label': 'com.apple.foo', '_PanicOnCrash': True, 'KeepAlive': shared,
                                                              'ProgramArguments': ['/usr/libexec/foo', '-v'], 'Nice': -5, 'Big': 1 << 40},
        '/System/Library/LaunchDaemons/com.apple.bar.plist': {'Label': 'com.apple.bar', 'KeepAlive': shared, 'Ratio': 0.25, 'Zero': 0.0},
        '/System/Library/LaunchDaemons/com.apple.CommCenter.plist': {'Label': 'com.apple.CommCenter', '_PanicOnCrash': True},
        '/System/Library/LaunchDaemons/com.apple.vmd.plist': {'Label': 'com.apple.voicemail.vmd'},
        '/System/Library/LaunchDaemons/com.apple.bluetoothd.plist': {'Label': 'com.apple.bluetoothd',
                                                                     'EnvironmentVariables': {'BT_DEVICE_ADDRESS': '00:11:22:33:44:55', 'X': 'y'}},
        '/System/Library/LaunchDaemons/com.apple.security.cryptexd.plist': {'Label': 'com.apple.security.cryptexd'},
        '/System/Library/LaunchDaemons/com.apple.replicatord.plist': {'Label': 'com.apple.replicatord', 'Data': b'\x00\x01binary',
                                                                      'When': datetime.datetime(2025, 3, 4, 5, 6, 7)},
    }
    launchd = {'LaunchDaemons': jobs, 'Agents': {'vmd': {'Label': 'com.apple.voicemail.vmd'}, 'other': {'Label': 'x'}},
               'Version': 3, 'Name': 'café ☃'}
    w(root, 'System/Library/xpc/launchd.plist', plistlib.dumps(launchd, fmt=plistlib.FMT_BINARY))
    w(root, 'System/Library/LaunchDaemons/com.apple.CommCenter-noncellular.plist', plistlib.dumps(
        {'Label': 'com.apple.CommCenter', '_LimitLoadFromDeviceTree': {'a': 1}, '_PanicOnCrash': True, 'MachServices': {'com.apple.commcenter': True}},
        fmt=plistlib.FMT_BINARY))
    for k in ('Default', 'Touch'):
        w(root, f'System/Library/EventTimingProfiles/N841.{k}.plist', plistlib.dumps({'Profile': k}, fmt=plistlib.FMT_BINARY))
    w(root, 'System/Library/Frameworks/MediaToolbox.framework/A/SubServerConfiguration.plist', plistlib.dumps(
        {'StartRecorderServer': True, 'Servers': [{'Name': 'a & <b>', 'Weight': 1e20, 'Tiny': 1.5e-7, 'Blob': bytes(range(120))}],
         'Empty': {}, 'None': [], 'Date': datetime.datetime(2001, 1, 1)}, fmt=plistlib.FMT_XML))
    w(root, 'Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/Contents/Info.plist', b'plugin')
    w(root, 'private/var/containers/Data/System/AAA/.com.apple.mobile_container_manager.metadata.plist',
      plistlib.dumps({'MCMMetadataIdentifier': 'com.apple.other'}, fmt=plistlib.FMT_BINARY))
    w(root, 'private/var/containers/Data/System/BBB/.com.apple.mobile_container_manager.metadata.plist',
      plistlib.dumps({'MCMMetadataIdentifier': 'com.apple.mobileactivationd'}, fmt=plistlib.FMT_BINARY))
    w(root, 'private/var/mobile/Containers/Data/InternalDaemon/X1/Library/Caches/com.apple.LaunchServices-1234.csstore', b'db')
    w(root, 'private/var/mobile/Containers/Data/InternalDaemon/X1/Library/Caches/keep.me', b'keep')
    w(root, 'private/var/mobile/Library/Preferences/com.apple.springboard.plist',
      plistlib.dumps({'Existing': 'yes', 'BKNoWatchdogs': False}, fmt=plistlib.FMT_BINARY), 0o600)
    w(root, 'private/var/preferences/SystemConfiguration/preferences.plist', plistlib.dumps(
        {'CurrentSet': '/Sets/1111', 'Sets': {'1111': {'UserDefinedName': 'Mine', 'Network': {'Global': {'IPv4': {'ServiceOrder': ['old']}}}}},
         'NetworkServices': {'old': {'UserDefinedName': 'Wi-Fi'}}}, fmt=plistlib.FMT_BINARY))
    w(root, 'Applications/Preferences.app/Preferences', b'settings', 0o755)
    for app in ('Zed.app', 'Alpha.app'):
        w(root, f'private/var/staged_system_apps/{app}/Contents/Info.plist', app.encode())
    w(root, 'private/var/staged_system_apps/README', b'not an app')
    w(root, 'usr/local/share/renegade/register-apps', b'Old.app\n')
    w(tools, 'sweetnetcfg', b'\xcf\xfa\xed\xfe fake netcfg', 0o755)
    w(tools, 'sweetreboot', b'\xcf\xfa\xed\xfe fake reboot', 0o700)


SSH_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey test@bergamota'


def make_tools(tools):
    """Fake berga-tools: the files the tool-dependent tweaks install (layout of berga-tools.zip)."""
    for rel, data, mode in [
        ('ssh/dropbear', b'\xcf\xfa\xed\xfe dropbear', 0o755),
        ('ssh/dash', b'\xcf\xfa\xed\xfe dash', 0o755),
        ('ssh/toybox', b'\xcf\xfa\xed\xfe toybox\0ls\0cat\0test\0netcat\0uname\0sleep\0ps\0nothere\0', 0o755),
        ('sweetnet/bluetool-stub', b'\xcf\xfa\xed\xfe bluetool stub', 0o755),
        ('sweetnet/hcitest', b'\xcf\xfa\xed\xfe hcitest', 0o755),
        ('sweetnet/ios18/sweetuicache', b'\xcf\xfa\xed\xfe uicache', 0o755),
        ('sweetnet/ios18/sweetposterset', b'\xcf\xfa\xed\xfe posterset', 0o755),
        ('sweetnet/ios18/sweeticonstyle', b'\xcf\xfa\xed\xfe iconstyle', 0o755),
        ('sweetnet/ios18/sweetopen', b'\xcf\xfa\xed\xfe open', 0o755),
        ('sweetnet/ios18/sweetfp.dylib', b'\xcf\xfa\xed\xfe fp', 0o755),
        ('sweetnet/ios18/sweetprefs', b'\xcf\xfa\xed\xfe prefs', 0o755),
        ('sweetnet/ios18/sweetshot', b'\xcf\xfa\xed\xfe shot', 0o755),
        ('sweetnet/ios18/sweettouch', b'\xcf\xfa\xed\xfe touch', 0o755),
        ('sweetnet/ios18/SweetRun.app/SweetRun', b'\xcf\xfa\xed\xfe sweetrun', 0o755),
        ('sweetnet/ios18/SweetRun.app/Info.plist', b'<plist/>', 0o644),
        ('sweetnet/ios18/SweetRun.app/_CodeSignature/CodeResources', b'<plist>res</plist>', 0o644),
        ('bergamota-gl/bgl-launch', b'\xcf\xfa\xed\xfe launch', 0o755),
        ('bergamota-gl/OpenGLES.framework/OpenGLES', b'\xcf\xfa\xed\xfe gles', 0o755),
        ('bergamota-gl/libOSMesa.8.dylib', b'\xcf\xfa\xed\xfe mesa', 0o755),
        ('bergamota-gl/libdrm.2.dylib', b'\xcf\xfa\xed\xfe drm', 0o755),
    ]:
        w(tools, rel, data, mode)
    # the bits of the root these tweaks look at
    return


def make_root_for_tools(root):
    w(root, 'usr/sbin/BlueTool', b'\xcf\xfa\xed\xfe the real BlueTool', 0o755)
    w(root, 'private/etc/shells', b'/bin/bash\n/bin/zsh\n')
    w(root, 'private/etc/passwd', b'root:*:0:0:System Administrator:/var/root:/bin/sh\nmobile:*:501:501:Mobile User:/var/mobile:/bin/sh\n')
    import plistlib as pl
    p = os.path.join(root, 'System/Library/xpc/launchd.plist')
    d = pl.loads(open(p, 'rb').read())
    d['LaunchDaemons']['/System/Library/LaunchDaemons/com.apple.backboardd.plist'] = {'Label': 'com.apple.backboardd', 'ProgramArguments': ['/usr/libexec/backboardd']}
    open(p, 'wb').write(pl.dumps(d, fmt=pl.FMT_BINARY))


def run(root, tools, quiet, with_tools=False):
    sys.path.insert(0, RENEGADE)
    import root_tweaks18 as rt
    rt.BUILD, rt.VERSION = '22H352', '18.7.8'
    rt.NETCFG = os.path.join(tools, 'sweetnetcfg')
    rt.REBOOT_TOOL = os.path.join(tools, 'sweetreboot')
    rt.BLUETOOL_STUB = '/nonexistent/bluetool-stub'
    rt.SWEETNET_DIRS = []
    if with_tools:
        rt.BLUETOOL_STUB = None
        rt.SWEETNET_DIRS = [os.path.join(tools, 'sweetnet')]
        rt.BGL_DIRS = [os.path.join(tools, 'bergamota-gl')]
        rt.SSH_OUT = os.path.join(tools, 'ssh')
        rt.mac_user_pubkey = lambda: ('test.pub', SSH_KEY)
        os.environ['RENEGADE_NO_BGMTL'] = '1'
        rt.rplat.is_linux = lambda: True        # only the iOS binaries are needed (and no host dropbearkey)
        rt.rplat.real_owners = lambda: False
    rec = rt.OwnerRecorder()
    rec.install()
    rt.launchd(root)
    if quiet:
        rt.quiet(root)
    rt.containers(root)
    rt.launchservices(root)
    rt.event_timing(root)          # develop: N841 -> D22 (the ios18 case)
    rt.usbnet(root)
    rt.netcfg(root)
    rt.sweetreboot(root)
    if with_tools:
        rt.ssh(root)
    rt.audio(root)
    rt.activation(root)
    rt.prefs(root)
    rt.iosroot_dirs(root)
    rt.staged_apps(root)
    rt.bluetooth(root)
    if with_tools:
        rt.posterboard(root)
        rt.firstboot(root, appreg=True, jb=False, wallpaper=True, metal=False)
        rt.bglrender(root)
        rt.sweetprefs_tool(root)
        console_job(rt, root)
    for p, (u, g) in sorted(rec.owners.items()):
        print(f'OWNER {os.path.relpath(p, root)} {u} {g}')


def console_job(rt, root):
    """The console job of mkroot-full.py's stage_tweaks."""
    import plistlib
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
        print('bring-up job', label)
    rt.save(lpath, plist, st.st_uid, st.st_gid, st.st_mode & 0o7777)


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


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2], sys.argv[3])
        if '--with-tools' in sys.argv:
            make_tools(sys.argv[3])
            make_root_for_tools(sys.argv[2])
    else:
        run(sys.argv[2], sys.argv[3], '--quiet' in sys.argv, '--with-tools' in sys.argv)
