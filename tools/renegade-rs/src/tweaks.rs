//! The tweaks stage (`root_tweaks18.py` as driven by mkroot-full.py's `stage_tweaks`), ported function by function
//! with the same file bytes (plists through [`crate::plist`], which writes what plistlib writes), the same recorded
//! owners and the same printed lines.
//!
//! The tweaks work on an [`Fs`]: a folder on disk ([`DirFs`], what the Python edits: the mounted image), or the
//! in-memory tree of the root build. Owners are recorded, not applied, like Python's `OwnerRecorder` (no sudo): the
//! seal stage writes them into the catalog.
//!
//! Ported: launchd (PanicOnCrash, no-baseband jobs, CommCenter), quiet, containers, launchservices, event_timing,
//! usbnet, netcfg, sweetreboot, sweetmetrics, activation, audio, merge_pref (+ the stage's preference set), the
//! bluetoothd environment, staged apps, add_job. Not yet: ssh (dropbear + host-generated keys), the BlueTool stub,
//! PosterBoard/sweetfp (addlc.py), bgmtl, bglrender, the first-boot job, the jailbreak userland, sweetprefs.

use crate::io::bad;
use crate::plist::{self, Value};
use std::collections::BTreeMap;
use std::io::Result;

pub const MOBILE: u32 = 501;

/// The operations the tweaks need. Paths are relative to the root ("System/Library/xpc/launchd.plist").
pub trait Fs {
    /// os.path.exists (follows symlinks).
    fn exists(&self, p: &str) -> bool;
    fn is_dir(&self, p: &str) -> bool;
    fn read(&self, p: &str) -> Result<Vec<u8>>;
    /// (uid, gid, permission bits) as lstat reports them.
    fn stat(&self, p: &str) -> Result<(u32, u32, u32)>;
    /// Writes a file (created with the default mode, like open(path, 'wb')).
    fn write(&mut self, p: &str, data: &[u8]) -> Result<()>;
    fn makedirs(&mut self, p: &str) -> Result<()>;
    fn chmod(&mut self, p: &str, mode: u32) -> Result<()>;
    /// Recorded for the catalog (OwnerRecorder semantics).
    fn chown(&mut self, p: &str, uid: u32, gid: u32);
    fn remove(&mut self, p: &str) -> Result<()>;
    fn rename(&mut self, from: &str, to: &str) -> Result<()>;
    /// Names in a folder, sorted.
    fn list(&self, p: &str) -> Result<Vec<String>>;
    /// shutil.copy2: data and mode.
    fn copy(&mut self, from: &str, to: &str) -> Result<()>;
    /// Every path under `p` (recursive), sorted.
    fn walk(&self, p: &str) -> Result<Vec<String>>;
    /// os.symlink: `link` becomes a symlink to `target`.
    fn symlink(&mut self, target: &str, link: &str) -> Result<()>;
    /// os.path.islink / os.readlink: the target when `p` is a symlink (not followed).
    fn readlink(&self, p: &str) -> Option<String>;
    /// The recorded owners (relative path -> (uid, gid)).
    fn owners(&self) -> &BTreeMap<String, (u32, u32)>;
}

/// A folder on disk; chowns are recorded (a chown to the owner of the process is not, as OwnerRecorder).
#[cfg(all(unix, not(target_family = "wasm")))]
pub struct DirFs {
    pub root: std::path::PathBuf,
    owners: BTreeMap<String, (u32, u32)>,
    me: (u32, u32),
}

#[cfg(all(unix, not(target_family = "wasm")))]
impl DirFs {
    pub fn new(root: impl Into<std::path::PathBuf>) -> Self {
        // SAFETY: getuid/getgid cannot fail
        let me = unsafe { (libc::getuid(), libc::getgid()) };
        Self { root: root.into(), owners: BTreeMap::new(), me }
    }
    fn p(&self, p: &str) -> std::path::PathBuf {
        self.root.join(p.trim_start_matches('/'))
    }
}

#[cfg(all(unix, not(target_family = "wasm")))]
impl Fs for DirFs {
    fn exists(&self, p: &str) -> bool {
        self.p(p).exists()
    }
    fn is_dir(&self, p: &str) -> bool {
        self.p(p).is_dir()
    }
    fn read(&self, p: &str) -> Result<Vec<u8>> {
        std::fs::read(self.p(p))
    }
    fn stat(&self, p: &str) -> Result<(u32, u32, u32)> {
        use std::os::unix::fs::MetadataExt;
        let m = std::fs::metadata(self.p(p))?;
        Ok((m.uid(), m.gid(), m.mode() & 0o7777))
    }
    fn write(&mut self, p: &str, data: &[u8]) -> Result<()> {
        std::fs::write(self.p(p), data)
    }
    fn makedirs(&mut self, p: &str) -> Result<()> {
        std::fs::create_dir_all(self.p(p))
    }
    fn chmod(&mut self, p: &str, mode: u32) -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(self.p(p), std::fs::Permissions::from_mode(mode))
    }
    fn chown(&mut self, p: &str, uid: u32, gid: u32) {
        if (uid, gid) == self.me {
            return;
        }
        self.owners.insert(p.trim_start_matches('/').to_string(), (uid, gid));
    }
    fn remove(&mut self, p: &str) -> Result<()> {
        std::fs::remove_file(self.p(p))
    }
    fn rename(&mut self, from: &str, to: &str) -> Result<()> {
        std::fs::rename(self.p(from), self.p(to))
    }
    fn list(&self, p: &str) -> Result<Vec<String>> {
        let mut v: Vec<String> = std::fs::read_dir(self.p(p))?.map(|e| e.map(|e| e.file_name().to_string_lossy().into_owned())).collect::<Result<_>>()?;
        v.sort();
        Ok(v)
    }
    fn copy(&mut self, from: &str, to: &str) -> Result<()> {
        std::fs::copy(self.p(from), self.p(to)).map(|_| ())
    }
    fn symlink(&mut self, target: &str, link: &str) -> Result<()> {
        std::os::unix::fs::symlink(target, self.p(link))
    }
    fn readlink(&self, p: &str) -> Option<String> {
        std::fs::read_link(self.p(p)).ok().map(|t| t.to_string_lossy().into_owned())
    }
    fn walk(&self, p: &str) -> Result<Vec<String>> {
        let mut out = Vec::new();
        let mut todo = vec![p.trim_end_matches('/').to_string()];
        while let Some(d) = todo.pop() {
            for n in self.list(&d)? {
                let q = format!("{d}/{n}");
                if std::fs::symlink_metadata(self.p(&q))?.is_dir() {
                    todo.push(q.clone());
                }
                out.push(q);
            }
        }
        out.sort();
        Ok(out)
    }
    fn owners(&self) -> &BTreeMap<String, (u32, u32)> {
        &self.owners
    }
}

/// What the tweaks print (the Python prints the same lines).
pub type Log = Vec<String>;

fn load(fs: &dyn Fs, p: &str) -> Result<Value> {
    plist::parse(&fs.read(p)?)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Fmt {
    Binary,
    Xml,
}

/// root_tweaks18.save: dump, chown (recorded), chmod.
pub fn save(fs: &mut dyn Fs, p: &str, v: &Value, uid: u32, gid: u32, mode: u32, fmt: Fmt) -> Result<()> {
    let b = match fmt {
        Fmt::Binary => plist::to_binary(v),
        Fmt::Xml => plist::to_xml(v)?,
    };
    fs.write(p, &b)?;
    fs.chown(p, uid, gid);
    fs.chmod(p, mode)
}

fn dict_mut<'a>(v: &'a mut Value, what: &str) -> Result<&'a mut BTreeMap<String, Value>> {
    v.as_dict_mut().ok_or_else(|| bad(format!("{what} is not a dict")))
}

/// Python's repr of a sorted list of str: "['a', 'b']".
fn py_list(v: &[String]) -> String {
    format!("[{}]", v.iter().map(|s| format!("'{s}'")).collect::<Vec<_>>().join(", "))
}

pub const LAUNCHD_PLIST: &str = "System/Library/xpc/launchd.plist";
pub const NO_BASEBAND_JOBS: [&str; 2] = ["com.apple.CommCenter", "com.apple.voicemail.vmd"];
pub const COMMCENTER_NONCELL: &str = "/System/Library/LaunchDaemons/com.apple.CommCenter-noncellular.plist";

/// launchd(): _PanicOnCrash -> _PanicOnCrasX, the no-baseband jobs out, CommCenter's non-cellular job in.
pub fn launchd(fs: &mut dyn Fs, log: &mut Log) -> Result<()> {
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = load(fs, LAUNCHD_PLIST)?;
    let mut renamed = 0;
    let root = dict_mut(&mut pl, "launchd.plist")?;
    if let Some(Value::Dict(jobs)) = root.get_mut("LaunchDaemons") {
        for job in jobs.values_mut() {
            if let Value::Dict(j) = job
                && let Some(v) = j.remove("_PanicOnCrash")
            {
                j.insert("_PanicOnCrasX".into(), v);
                renamed += 1;
            }
        }
    }
    let mut removed: Vec<String> = Vec::new();
    for sect in root.values_mut() {
        let Value::Dict(sect) = sect else { continue };
        let gone: Vec<String> = sect
            .iter()
            .filter(|(_, j)| j.get("Label").and_then(Value::as_str).is_some_and(|l| NO_BASEBAND_JOBS.contains(&l)))
            .map(|(k, _)| k.clone())
            .collect();
        for k in gone {
            if let Some(j) = sect.remove(&k) {
                removed.push(j.get("Label").and_then(Value::as_str).unwrap_or_default().to_string());
            }
        }
    }
    let cc = COMMCENTER_NONCELL.trim_start_matches('/');
    let have_cc = fs.exists(cc);
    if have_cc {
        let mut job = load(fs, cc)?;
        if let Value::Dict(j) = &mut job {
            j.remove("_LimitLoadFromDeviceTree");
            j.remove("_PanicOnCrash");
        }
        if let Some(Value::Dict(jobs)) = root.get_mut("LaunchDaemons") {
            jobs.insert(COMMCENTER_NONCELL.into(), job);
        }
    }
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)?;
    removed.sort();
    log.push(format!(
        "launchd.plist: {renamed} _PanicOnCrash renamed, removed (no baseband) {}, CommCenter: {}",
        py_list(&removed),
        if have_cc { "non-cellular job".to_string() } else { format!("absent (no {COMMCENTER_NONCELL})") }
    ));
    Ok(())
}

pub const QUIET_THROTTLE: [(&str, i64); 9] = [
    ("com.apple.replicatord", 60),
    ("com.apple.appprotectiond", 60),
    ("com.apple.passd", 60),
    ("com.apple.icloud.findmydeviced", 60),
    ("com.apple.mobileactivationd", 60),
    ("com.apple.spaceattributiond", 60),
    ("com.apple.fairplayd.H2", 60),
    ("com.apple.PerfPowerServices", 60),
    ("com.apple.webinspectord", 60),
];
pub const QUIET_REMOVE: [&str; 1] = ["com.apple.security.cryptexd"];

/// quiet(): crash-looping jobs out / throttled (SWEET_QUIET=1).
pub fn quiet(fs: &mut dyn Fs, log: &mut Log) -> Result<()> {
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = load(fs, LAUNCHD_PLIST)?;
    let jobs = match dict_mut(&mut pl, "launchd.plist")?.get_mut("LaunchDaemons") {
        Some(Value::Dict(j)) => j,
        _ => return Err(bad("launchd.plist has no LaunchDaemons")),
    };
    let label = |j: &Value| j.get("Label").and_then(Value::as_str).map(str::to_string);
    let gone: Vec<String> = jobs.iter().filter(|(_, j)| label(j).is_some_and(|l| QUIET_REMOVE.contains(&l.as_str()))).map(|(k, _)| k.clone()).collect();
    for k in &gone {
        jobs.remove(k);
    }
    let mut n = 0;
    for j in jobs.values_mut() {
        if let Some(l) = label(j)
            && let Some((_, t)) = QUIET_THROTTLE.iter().find(|(q, _)| *q == l)
            && let Value::Dict(d) = j
        {
            d.insert("ThrottleInterval".into(), Value::Integer(*t as i128));
            n += 1;
        }
    }
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)?;
    log.push(format!("quiet: removed {} job(s) ('com.apple.security.cryptexd',), ThrottleInterval set on {n}", gone.len()));
    Ok(())
}

/// containers(): the container folders iOS keeps on the data volume.
pub fn containers(fs: &mut dyn Fs, log: &mut Log, root_display: &str) -> Result<()> {
    for (sub, uid) in [("Bundle", 33), ("Data/System", 0), ("Shared/SystemGroup", 0), ("Temp", 0)] {
        let d = format!("private/var/containers/{sub}");
        if !fs.is_dir(&d) {
            fs.makedirs(&d)?;
            fs.chown(&d, uid, uid);
            fs.chmod(&d, 0o755)?;
            log.push(format!("mkdir {root_display}/{d}"));
        }
    }
    Ok(())
}

/// launchservices(): drop a LaunchServices database seeded too early (glob of the InternalDaemon caches).
pub fn launchservices(fs: &mut dyn Fs, log: &mut Log, root_display: &str) -> Result<()> {
    let base = "private/var/mobile/Containers/Data/InternalDaemon";
    if !fs.is_dir(base) {
        return Ok(());
    }
    // glob order: os.listdir order is not sorted in Python; the result set is the same, the lines may differ
    for c in fs.list(base)? {
        let caches = format!("{base}/{c}/Library/Caches");
        if !fs.is_dir(&caches) {
            continue;
        }
        for n in fs.list(&caches)? {
            if n.starts_with("com.apple.LaunchServices") {
                let p = format!("{caches}/{n}");
                fs.remove(&p)?;
                log.push(format!("rm {root_display}/{p}"));
            }
        }
    }
    Ok(())
}

/// event_timing(): the ADT target's event timing profiles when the ADT claims another device than the userland.
pub fn event_timing(fs: &mut dyn Fs, log: &mut Log, root_display: &str, board: &str, adt_target: &str) -> Result<()> {
    if board == adt_target {
        return Ok(());
    }
    let d = "System/Library/EventTimingProfiles";
    for kind in ["Default", "Touch"] {
        let s = format!("{d}/{board}.{kind}.plist");
        let t = format!("{d}/{adt_target}.{kind}.plist");
        if fs.exists(&s) && !fs.exists(&t) {
            fs.copy(&s, &t)?;
            log.push(format!("event timing profile {root_display}/{t}"));
        }
    }
    Ok(())
}

fn s(v: &str) -> Value {
    Value::String(v.into())
}
fn dict(items: Vec<(&str, Value)>) -> Value {
    Value::Dict(items.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}
fn strs(v: &[&str]) -> Value {
    Value::Array(v.iter().map(|x| s(x)).collect())
}

/// usbnet(): configd's USB Ethernet service for ue0 (fixed UUIDs, idempotent).
pub fn usbnet(fs: &mut dyn Fs, log: &mut Log) -> Result<()> {
    let base = "private/var/preferences/SystemConfiguration";
    fs.makedirs(base)?;
    let (svc, nset) = ("5EE7C0DE-0000-4000-8000-0000000000E0", "5EE7C0DE-0000-4000-8000-0000000005E7");
    let path = format!("{base}/preferences.plist");
    let mut prefs = if fs.exists(&path) { load(fs, &path)? } else { dict(vec![("__VERSION__", Value::Integer(20191120))]) };
    let service = dict(vec![
        ("UserDefinedName", s("USB Ethernet")),
        ("Interface", dict(vec![("DeviceName", s("ue0")), ("Hardware", s("Ethernet")), ("Type", s("Ethernet")), ("UserDefinedName", s("USB Ethernet"))])),
        ("IPv4", dict(vec![("ConfigMethod", s("Manual")), ("Addresses", strs(&["192.168.7.2"])), ("SubnetMasks", strs(&["255.255.255.0"])), ("Router", s("192.168.7.1"))])),
        ("IPv6", dict(vec![("ConfigMethod", s("Automatic"))])),
        ("DNS", dict(vec![("ServerAddresses", strs(&["1.1.1.1", "8.8.8.8"]))])),
        ("Proxies", dict(vec![("ExceptionsList", strs(&["*.local", "169.254/16"])), ("FTPPassive", Value::Integer(1))])),
    ]);
    let p = dict_mut(&mut prefs, "preferences.plist")?;
    let entry = |p: &mut BTreeMap<String, Value>, k: &str, default: Value| -> Result<()> {
        p.entry(k.to_string()).or_insert(default);
        Ok(())
    };
    entry(p, "NetworkServices", Value::dict())?;
    dict_mut(p.get_mut("NetworkServices").unwrap(), "NetworkServices")?.insert(svc.into(), service);
    entry(p, "Sets", Value::dict())?;
    let cur = p.get("CurrentSet").and_then(Value::as_str).unwrap_or("").rsplit('/').next().unwrap_or("").to_string();
    let cur = if cur.is_empty() { nset.to_string() } else { cur };
    {
        let sets = dict_mut(p.get_mut("Sets").unwrap(), "Sets")?;
        let set = sets.entry(cur.clone()).or_insert_with(|| dict(vec![("UserDefinedName", s("Automatic")), ("Network", Value::dict())]));
        let set = dict_mut(set, "set")?;
        let net = dict_mut(set.entry("Network".into()).or_insert_with(Value::dict), "Network")?;
        dict_mut(net.entry("Service".into()).or_insert_with(Value::dict), "Service")?.insert(svc.into(), dict(vec![("__LINK__", s(&format!("/NetworkServices/{svc}")))]));
        let global = dict_mut(net.entry("Global".into()).or_insert_with(Value::dict), "Global")?;
        let ipv4 = dict_mut(global.entry("IPv4".into()).or_insert_with(Value::dict), "IPv4")?;
        let order = ipv4.entry("ServiceOrder".into()).or_insert_with(|| Value::Array(vec![]));
        if let Value::Array(a) = order
            && !a.iter().any(|x| x.as_str() == Some(svc))
        {
            a.insert(0, s(svc));
        }
        net.entry("Interface".into()).or_insert_with(Value::dict);
    }
    p.insert("CurrentSet".into(), s(&format!("/Sets/{cur}")));
    save(fs, &path, &prefs, 0, 0, 0o644, Fmt::Binary)?;

    let path = format!("{base}/NetworkInterfaces.plist");
    let mut ifs = if fs.exists(&path) { load(fs, &path)? } else { dict(vec![("__VERSION__", Value::Integer(20191120))]) };
    let d = dict_mut(&mut ifs, "NetworkInterfaces.plist")?;
    let mut lst: Vec<Value> = match d.get("Interfaces") {
        Some(Value::Array(a)) => a.iter().filter(|i| i.get("BSD Name").and_then(Value::as_str) != Some("ue0")).cloned().collect(),
        _ => vec![],
    };
    lst.push(dict(vec![
        ("BSD Name", s("ue0")),
        ("IOBuiltin", Value::Bool(true)),
        ("IOInterfaceNamePrefix", s("ue")),
        ("IOInterfaceType", Value::Integer(6)),
        ("IOInterfaceUnit", Value::Integer(0)),
        ("IOMACAddress", Value::Data(vec![0x02, 0x00, 0x5e, 0x77, 0xee, 0x02])),
        ("SCNetworkInterfaceType", s("Ethernet")),
        ("SCNetworkInterfaceInfo", dict(vec![("UserDefinedName", s("USB Ethernet"))])),
    ]));
    d.insert("Interfaces".into(), Value::Array(lst));
    save(fs, &path, &ifs, 0, 0, 0o644, Fmt::Binary)?;
    log.push(format!("usbnet: service {svc} ue0 192.168.7.2/24 via 192.168.7.1, DNS 1.1.1.1 8.8.8.8"));
    Ok(())
}

/// A launchd job: its plist in /System/Library/LaunchDaemons (XML) and the launchd.plist entry (add_job).
pub fn add_job(fs: &mut dyn Fs, label: &str, job: &Value) -> Result<()> {
    let jpath = format!("System/Library/LaunchDaemons/{label}.plist");
    fs.makedirs("System/Library/LaunchDaemons")?;
    save(fs, &jpath, job, 0, 0, 0o644, Fmt::Xml)?;
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = load(fs, LAUNCHD_PLIST)?;
    let jobs = dict_mut(dict_mut(&mut pl, "launchd.plist")?.entry("LaunchDaemons".into()).or_insert_with(Value::dict), "LaunchDaemons")?;
    jobs.insert(format!("/{jpath}"), job.clone());
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)
}

/// A file from the tool build into the root (copy2 or install_file: root:wheel, the given mode).
pub(crate) fn install(fs: &mut dyn Fs, data: &[u8], dst: &str, mode: u32) -> Result<()> {
    if let Some((dir, _)) = dst.rsplit_once('/') {
        fs.makedirs(dir)?;
    }
    fs.write(dst, data)?;
    fs.chown(dst, 0, 0);
    fs.chmod(dst, mode)
}

pub const NETCFG_LABEL: &str = "org.sweet.netcfg";

/// netcfg(): /usr/local/bin/sweetnetcfg (from the tool build) and its launchd job. `tool`: None = not built.
pub fn netcfg(fs: &mut dyn Fs, log: &mut Log, tool: Option<&[u8]>) -> Result<()> {
    let Some(tool) = tool else {
        log.push("netcfg: skipped, build it first (tools/sweetnet/build.sh)".into());
        return Ok(());
    };
    install(fs, tool, "usr/local/bin/sweetnetcfg", 0o755)?;
    let job = dict(vec![
        ("Label", s(NETCFG_LABEL)),
        ("ProgramArguments", strs(&["/usr/local/bin/sweetnetcfg"])),
        ("RunAtLoad", Value::Bool(true)),
        ("KeepAlive", dict(vec![("SuccessfulExit", Value::Bool(false))])),
        ("ThrottleInterval", Value::Integer(5)),
        ("UserName", s("root")),
        ("StandardErrorPath", s("/dev/console")),
    ]);
    add_job(fs, NETCFG_LABEL, &job)?;
    log.push(format!("netcfg: /usr/local/bin/sweetnetcfg + launchd job {NETCFG_LABEL}"));
    Ok(())
}

/// sweetreboot(): /usr/local/bin/sweetreboot (no job).
pub fn sweetreboot(fs: &mut dyn Fs, log: &mut Log, tool: Option<&[u8]>) -> Result<()> {
    let Some(tool) = tool else {
        log.push("sweetreboot: skipped, build it first (tools/sweetnet/build.sh)".into());
        return Ok(());
    };
    install(fs, tool, "usr/local/bin/sweetreboot", 0o755)?;
    log.push("sweetreboot: /usr/local/bin/sweetreboot".into());
    Ok(())
}

/// sweetmetrics(): /usr/local/bin/sweetmetrics (no job).
pub fn sweetmetrics(fs: &mut dyn Fs, log: &mut Log, tool: Option<&[u8]>) -> Result<()> {
    let Some(tool) = tool else {
        log.push("sweetmetrics: not built (tools/sweetnet/build.sh): skipped".into());
        return Ok(());
    };
    install(fs, tool, "usr/local/bin/sweetmetrics", 0o755)?;
    log.push("sweetmetrics: /usr/local/bin/sweetmetrics".into());
    Ok(())
}

/// The container of `identifier` among private/var/containers/KIND/* (by its metadata plist).
fn find_container(fs: &dyn Fs, kind: &str, identifier: &str) -> Result<Option<String>> {
    let base = format!("private/var/containers/{kind}");
    if !fs.is_dir(&base) {
        return Ok(None);
    }
    for c in fs.list(&base)? {
        let meta = format!("{base}/{c}/.com.apple.mobile_container_manager.metadata.plist");
        if fs.exists(&meta) && load(fs, &meta)?.get("MCMMetadataIdentifier").and_then(Value::as_str) == Some(identifier) {
            return Ok(Some(format!("{base}/{c}")));
        }
    }
    Ok(None)
}

/// activation(): mobileactivationd's data ark (Activated).
pub fn activation(fs: &mut dyn Fs, log: &mut Log, root_display: &str, build: &str, version: &str) -> Result<()> {
    let Some(c) = find_container(fs, "Data/System", "com.apple.mobileactivationd")? else {
        log.push("warning: no mobileactivationd system container in the image; skipped data ark".into());
        return Ok(());
    };
    let d = format!("{c}/Library/internal");
    fs.makedirs(&d)?;
    fs.chown(&d, MOBILE, MOBILE);
    fs.chmod(&d, 0o755)?;
    let ark = dict(vec![
        ("-ActivationState", s("Activated")),
        ("-BrickState", Value::Bool(false)),
        ("-BuildVersion", s(build)),
        ("-ProductVersion", s(version)),
        ("-DataMigrationCompleted", Value::Bool(true)),
        ("-PreSydroDataMigrationCompleted", Value::Bool(true)),
    ]);
    save(fs, &format!("{d}/data_ark.plist"), &ark, MOBILE, MOBILE, 0o600, Fmt::Binary)?;
    log.push(format!("data ark {root_display}/{d}"));
    Ok(())
}

/// audio(): VirtualAudio HAL plug-in disabled, MediaToolbox's recorder server off.
pub fn audio(fs: &mut dyn Fs, log: &mut Log) -> Result<()> {
    let src = "Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin";
    let dst_dir = "Library/Audio/Plug-Ins/HAL.disabled";
    if fs.exists(src) {
        fs.makedirs(dst_dir)?;
        fs.rename(src, &format!("{dst_dir}/VirtualAudio.plugin"))?;
        log.push("VirtualAudio.plugin disabled".into());
    }
    let fw = "System/Library/Frameworks/MediaToolbox.framework";
    if fs.is_dir(fw) {
        for sub in fs.list(fw)? {
            let conf = format!("{fw}/{sub}/SubServerConfiguration.plist");
            if !fs.exists(&conf) {
                continue;
            }
            let (uid, gid, mode) = fs.stat(&conf)?;
            let mut data = load(fs, &conf)?;
            dict_mut(&mut data, "SubServerConfiguration")?.insert("StartRecorderServer".into(), Value::Bool(false));
            save(fs, &conf, &data, uid, gid, mode, Fmt::Xml)?;
            log.push(format!("StartRecorderServer off {conf}"));
        }
    }
    Ok(())
}

/// merge_pref(): keys merged into /var/mobile/Library/Preferences/NAME.plist (mobile, 0600).
pub fn merge_pref(fs: &mut dyn Fs, log: &mut Log, name: &str, values: Vec<(&str, Value)>) -> Result<()> {
    let dir = "private/var/mobile/Library/Preferences";
    let path = format!("{dir}/{name}.plist");
    fs.makedirs(dir)?;
    let mut data = if fs.exists(&path) { load(fs, &path)? } else { Value::dict() };
    let mut keys: Vec<String> = values.iter().map(|(k, _)| k.to_string()).collect();
    let d = dict_mut(&mut data, name)?;
    for (k, v) in values {
        d.insert(k.into(), v);
    }
    save(fs, &path, &data, MOBILE, MOBILE, 0o600, Fmt::Binary)?;
    keys.sort();
    log.push(format!("pref {name} {}", py_list(&keys)));
    Ok(())
}

/// The preferences mkroot-full.py's stage_tweaks merges (migration, springboard, purplebuddy, ...), in its order.
pub fn stage_prefs(fs: &mut dyn Fs, log: &mut Log, build: &str) -> Result<()> {
    merge_pref(fs, log, "com.apple.migration", vec![("LastSystemVersion", s(build)), ("DMUserDataDisposition", dict(vec![("SyntheticDidUpgrade", Value::Bool(false)), ("buildVersion", s(build))]))])?;
    merge_pref(
        fs,
        log,
        "com.apple.springboard",
        vec![
            ("BKNoWatchdogs", Value::Bool(true)),
            ("FBLaunchWatchdogExceptions", dict(vec![("com.apple.purplebuddy", Value::Real(100.0))])),
            ("MCForceShowCloudConfigurationUI", Value::Bool(false)),
            ("SBShowBatteryPercentage", Value::Bool(true)),
        ],
    )?;
    merge_pref(fs, log, "com.apple.purplebuddy", vec![("SetupDone", Value::Bool(true)), ("SetupFinishedAllSteps", Value::Bool(true)), ("SetupVersion", Value::Integer(11)), ("daemonizeNeedsToRun", Value::Bool(false))])?;
    let minibuddy = ["ShouldRunDiagnosticsMiniBuddy", "ShouldRunHSA2MiniBuddy", "ShouldRunKeychainSyncMiniBuddy", "ShouldRunMesaMiniBuddy", "ShouldRunPaymentMiniBuddy", "ShouldRunStandardMiniBuddy", "SilentICDPUpgrade"];
    merge_pref(fs, log, "com.apple.purplebuddy.notbackedup", minibuddy.iter().map(|k| (*k, Value::Bool(false))).collect())?;
    merge_pref(fs, log, "com.apple.managedconfiguration.notbackedup", vec![("LockdownActivationIndicatesCloudConfigurationAvailable", Value::Bool(false))])
}

pub const BT_LABEL: &str = "com.apple.bluetoothd";

/// bluetoothd_env(): BT_HCI_TRANSPORT in every bluetoothd job; returns the number of jobs.
pub fn bluetoothd_env(pl: &mut Value) -> usize {
    let mut n = 0;
    if let Some(Value::Dict(jobs)) = pl.as_dict_mut().and_then(|d| d.get_mut("LaunchDaemons")) {
        for job in jobs.values_mut() {
            if job.get("Label").and_then(Value::as_str) == Some(BT_LABEL)
                && let Value::Dict(j) = job
            {
                let env = j.entry("EnvironmentVariables".into()).or_insert_with(Value::dict);
                if let Value::Dict(e) = env {
                    e.insert("BT_HCI_TRANSPORT".into(), s("H4BC:POSIX:com.apple.uart.bluetooth,3000000"));
                    e.remove("BT_DEVICE_ADDRESS");
                }
                n += 1;
            }
        }
    }
    n
}

/// The launchd part of bluetooth() (the BlueTool stub, hcitest and firmware are not ported yet).
pub fn bluetooth_env(fs: &mut dyn Fs, log: &mut Log, stub_available: bool) -> Result<()> {
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = load(fs, LAUNCHD_PLIST)?;
    if bluetoothd_env(&mut pl) == 0 {
        log.push(format!("bluetooth: no {BT_LABEL} job in launchd.plist: skipped"));
        return Ok(());
    }
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)?;
    log.push(format!("bluetooth: BT_HCI_TRANSPORT set for {BT_LABEL}"));
    if !stub_available {
        log.push("bluetooth: BlueTool stub not built (tools/sweetnet/build.sh): BlueTool left alone".into());
    }
    Ok(())
}

/// iosroot_dirs(): logd's stores (owned by _logd 272) and the system keybag of the built-in AppleKeyStore.
pub fn iosroot_dirs(fs: &mut dyn Fs) -> Result<()> {
    for d in ["private/var/db/diagnostics", "private/var/db/uuidtext", "private/var/db/diagnostics/timesync"] {
        fs.makedirs(d)?;
        fs.chown(d, 272, 272);
        let m = format!("{d}/.migrated");
        if !fs.exists(&m) {
            fs.write(&m, b"")?;
        }
        fs.chmod(&m, 0o644)?;
        fs.chown(&m, 272, 272);
    }
    fs.chmod("private/var/db/diagnostics", 0o751)?;
    fs.makedirs("private/var/keybags")?;
    fs.chmod("private/var/keybags", 0o700)?;
    let kf = "private/var/keybags/systembag.kb";
    if !fs.exists(kf) {
        fs.write(kf, b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>\n")?;
    }
    fs.chmod(kf, 0o600)
}

/// Inputs of the tweaks that are not in the root: the target and the prebuilt tools (None = not built).
#[derive(Default)]
pub struct Config {
    pub build: String,
    pub version: String,
    pub board: String,
    pub adt_target: String,
    pub quiet: bool,
    pub netcfg: Option<Vec<u8>>,
    pub sweetreboot: Option<Vec<u8>>,
    /// How paths are shown in messages (Python prints absolute paths under the root it was given).
    pub root_display: String,
    /// The prebuilt on-device tools (berga-tools.zip); None: every feature that installs one is skipped.
    pub tools: Option<crate::tools::Tools>,
    /// The public key SSH logs in with (one `ssh-ed25519 AAAA...` line); without it the ssh tweak is skipped.
    pub ssh_key: Option<String>,
    /// Where the key came from, for the log line (default: "the public key you gave").
    pub ssh_key_name: Option<String>,
}

/// The ported part of root_tweaks18.base() + auto(), in their order (ssh, sweetprefs, PosterBoard, bgmtl, the
/// first-boot job and bglrender are not ported yet).
pub fn run(fs: &mut dyn Fs, cfg: &Config, log: &mut Log) -> Result<()> {
    let r = cfg.root_display.as_str();
    launchd(fs, log)?;
    if cfg.quiet {
        quiet(fs, log)?;
    }
    containers(fs, log, r)?;
    launchservices(fs, log, r)?;
    event_timing(fs, log, r, &cfg.board, &cfg.adt_target)?;
    usbnet(fs, log)?;
    netcfg(fs, log, cfg.netcfg.as_deref())?;
    sweetreboot(fs, log, cfg.sweetreboot.as_deref())?;
    crate::tools::run_ssh(fs, cfg, log)?;
    audio(fs, log)?;
    activation(fs, log, r, &cfg.build, &cfg.version)?;
    stage_prefs(fs, log, &cfg.build)?;
    iosroot_dirs(fs)?;
    staged_apps(fs, log)?;
    bluetooth_env(fs, log, cfg.tools.as_ref().is_some_and(|t| t.get(crate::tools::BLUETOOL_STUB).is_some()))?;
    crate::tools::run_rest(fs, cfg, log)
}

pub const REGISTER_LIST: &str = "usr/local/share/renegade/register-apps";

/// staged_apps(): the removable apps from /private/var/staged_system_apps into /Applications (root:wheel) and
/// their names in the first-boot registration list.
pub fn staged_apps(fs: &mut dyn Fs, log: &mut Log) -> Result<Vec<String>> {
    let src = "private/var/staged_system_apps";
    let mut moved = Vec::new();
    if fs.is_dir(src) {
        for name in fs.list(src)? {
            let to = format!("Applications/{name}");
            if !name.ends_with(".app") || fs.exists(&to) {
                continue;
            }
            fs.rename(&format!("{src}/{name}"), &to)?;
            for p in fs.walk(&to)? {
                fs.chown(&p, 0, 0);
            }
            fs.chown(&to, 0, 0);
            log.push(format!("staged app -> {name}"));
            moved.push(name);
        }
    }
    if !moved.is_empty() {
        let have: Vec<String> = if fs.exists(REGISTER_LIST) { String::from_utf8_lossy(&fs.read(REGISTER_LIST)?).split('\n').map(String::from).collect() } else { vec![] };
        let mut all: Vec<String> = have.into_iter().chain(moved.iter().cloned()).filter(|n| !n.is_empty()).collect();
        all.sort();
        all.dedup();
        let dir = REGISTER_LIST.rsplit_once('/').unwrap().0;
        fs.makedirs(dir)?;
        fs.write(REGISTER_LIST, format!("{}\n", all.join("\n")).as_bytes())?;
        fs.chown(REGISTER_LIST, 0, 0);
        fs.chmod(REGISTER_LIST, 0o644)?;
    }
    Ok(moved)
}

/// The root build's tree as an [`Fs`]: the scanned entries, file contents from their source (read on demand) or
/// from the overlay the tweaks wrote. New files get 0644, new folders 0755, owner 0:0 until the owner map says
/// otherwise; recorded chowns come back from [`Fs::owners`].
pub struct TreeFs<'a> {
    pub entries: Vec<crate::hfswrite::Entry>,
    index: std::collections::HashMap<String, usize>,
    /// Contents written by the tweaks, by overlay number (an entry's `source` minus `base`).
    pub overlay: Vec<Vec<u8>>,
    /// Sources below `base` are the caller's (the scanned files).
    pub base: usize,
    read_source: Box<dyn Fn(usize) -> Result<Vec<u8>> + 'a>,
    /// Reads the first bytes of a scanned file without reading the whole of it (set by callers with big files).
    #[allow(clippy::type_complexity)]
    peek_source: Option<Box<dyn Fn(usize, usize) -> Result<Vec<u8>> + 'a>>,
    /// Entry indices in path order (built on the first walk, kept up to date by the pushes, dropped by removals).
    sorted: std::cell::RefCell<Option<Vec<usize>>>,
    owners: BTreeMap<String, (u32, u32)>,
    now: u32,
    /// OwnerRecorder's rule: a chown to the user who owns the scanned files (the image is mounted noowners in
    /// Python, so code that rewrites a file passes that pair on without meaning it) is not recorded.
    pub skip_owner: Option<(u32, u32)>,
}

impl<'a> TreeFs<'a> {
    pub fn new(entries: Vec<crate::hfswrite::Entry>, base: usize, now: u32, read_source: impl Fn(usize) -> Result<Vec<u8>> + 'a) -> Self {
        let index = entries.iter().enumerate().map(|(i, e)| (e.path.clone(), i)).collect();
        Self { entries, index, overlay: Vec::new(), base, read_source: Box::new(read_source), peek_source: None, sorted: Default::default(), owners: BTreeMap::new(), now, skip_owner: None }
    }

    /// Call after an entry was pushed.
    fn note_push(&mut self) {
        let i = self.entries.len() - 1;
        if let Some(v) = self.sorted.get_mut() {
            let path = &self.entries[i].path;
            let pos = v.partition_point(|&j| self.entries[j].path < *path);
            v.insert(pos, i);
        }
    }

    fn reindex(&mut self) {
        *self.sorted.get_mut() = None;
        self.index = self.entries.iter().enumerate().map(|(i, e)| (e.path.clone(), i)).collect();
    }

    fn norm(p: &str) -> String {
        p.trim_start_matches('/').trim_end_matches('/').to_string()
    }

    /// The path with every symlink resolved (relative and absolute targets), as os.path.exists would follow.
    fn resolve(&self, p: &str) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        let mut todo: Vec<String> = Self::norm(p).split('/').filter(|s| !s.is_empty()).map(String::from).rev().collect();
        let mut hops = 0;
        while let Some(c) = todo.pop() {
            match c.as_str() {
                "." => continue,
                ".." => {
                    parts.pop();
                    continue;
                }
                _ => {}
            }
            parts.push(c);
            let cur = parts.join("/");
            let e = &self.entries[*self.index.get(&cur)?];
            if let crate::hfswrite::Kind::Symlink { target } = &e.kind {
                hops += 1;
                if hops > 32 {
                    return None;
                }
                parts.pop();
                if target.starts_with('/') {
                    parts.clear();
                }
                for t in target.split('/').filter(|s| !s.is_empty()).rev() {
                    todo.push(t.to_string());
                }
            }
        }
        Some(parts.join("/"))
    }

    fn entry(&self, p: &str) -> Option<&crate::hfswrite::Entry> {
        self.resolve(p).and_then(|r| self.index.get(&r).map(|&i| &self.entries[i]))
    }

    fn entry_mut(&mut self, p: &str) -> Result<&mut crate::hfswrite::Entry> {
        let r = self.resolve(p).ok_or_else(|| bad(format!("{p}: no such file")))?;
        let i = *self.index.get(&r).ok_or_else(|| bad(format!("{p}: no such file")))?;
        Ok(&mut self.entries[i])
    }

    /// The kind of the entry at a path (symlinks in the path followed, the last one not).
    pub fn kind_of(&self, p: &str) -> Option<crate::hfswrite::Kind> {
        let p = Self::norm(p);
        let (dir, name) = p.rsplit_once('/').unwrap_or(("", p.as_str()));
        let dir = self.resolve(dir)?;
        let full = if dir.is_empty() { name.to_string() } else { format!("{dir}/{name}") };
        self.index.get(&full).map(|&i| self.entries[i].kind.clone())
    }

    /// A reader of the first `n` bytes of a scanned file (the data of an overlay file is in memory anyway).
    pub fn set_peek(&mut self, f: impl Fn(usize, usize) -> Result<Vec<u8>> + 'a) {
        self.peek_source = Some(Box::new(f));
    }

    /// The first `n` bytes (fewer for a shorter file) of a file entry.
    pub fn head(&self, source: usize, n: usize) -> Result<Vec<u8>> {
        if source >= self.base {
            return Ok(self.overlay[source - self.base][..n.min(self.overlay[source - self.base].len())].to_vec());
        }
        match &self.peek_source {
            Some(f) => f(source, n),
            None => Ok((self.read_source)(source)?.into_iter().take(n).collect()),
        }
    }

    /// The content of a file entry.
    pub fn data(&self, source: usize) -> Result<Vec<u8>> {
        if source >= self.base { Ok(self.overlay[source - self.base].clone()) } else { (self.read_source)(source) }
    }
}

impl Fs for TreeFs<'_> {
    fn exists(&self, p: &str) -> bool {
        Self::norm(p).is_empty() || self.entry(p).is_some()
    }
    fn is_dir(&self, p: &str) -> bool {
        Self::norm(p).is_empty() || self.entry(p).is_some_and(|e| e.kind == crate::hfswrite::Kind::Dir)
    }
    fn read(&self, p: &str) -> Result<Vec<u8>> {
        match self.entry(p).map(|e| e.kind.clone()) {
            Some(crate::hfswrite::Kind::File { source, .. }) => self.data(source),
            _ => Err(bad(format!("{p}: not a file"))),
        }
    }
    fn stat(&self, p: &str) -> Result<(u32, u32, u32)> {
        let e = self.entry(p).ok_or_else(|| bad(format!("{p}: no such file")))?;
        Ok((e.uid, e.gid, e.perm as u32))
    }
    fn write(&mut self, p: &str, data: &[u8]) -> Result<()> {
        let source = self.base + self.overlay.len();
        self.overlay.push(data.to_vec());
        let len = data.len() as u64;
        let path = self.resolve(p).unwrap_or_else(|| Self::norm(p));
        match self.index.get(&path) {
            Some(&i) => {
                let e = &mut self.entries[i];
                e.kind = crate::hfswrite::Kind::File { len, source };
                e.link_group = None; // a rewritten file is a new file (open(..., 'wb') truncates in place; the tweaks never write a hard-linked file)
            }
            None => {
                let parent = path.rsplit_once('/').map(|x| x.0).unwrap_or("");
                if !self.is_dir(parent) {
                    return Err(bad(format!("{p}: parent folder missing")));
                }
                self.entries.push(crate::hfswrite::Entry { path: path.clone(), kind: crate::hfswrite::Kind::File { len, source }, uid: 0, gid: 0, perm: 0o644, mtime: self.now, link_group: None });
                self.note_push();
                self.index.insert(path, self.entries.len() - 1);
            }
        }
        Ok(())
    }
    fn makedirs(&mut self, p: &str) -> Result<()> {
        let mut cur = String::new();
        for c in Self::norm(p).split('/').filter(|s| !s.is_empty()) {
            cur = if cur.is_empty() { c.to_string() } else { format!("{cur}/{c}") };
            if let Some(r) = self.resolve(&cur) {
                cur = r;
                continue;
            }
            self.entries.push(crate::hfswrite::Entry { path: cur.clone(), kind: crate::hfswrite::Kind::Dir, uid: 0, gid: 0, perm: 0o755, mtime: self.now, link_group: None });
            self.note_push();
            self.index.insert(cur.clone(), self.entries.len() - 1);
        }
        Ok(())
    }
    fn chmod(&mut self, p: &str, mode: u32) -> Result<()> {
        self.entry_mut(p)?.perm = (mode & 0o7777) as u16;
        Ok(())
    }
    fn chown(&mut self, p: &str, uid: u32, gid: u32) {
        if Some((uid, gid)) == self.skip_owner {
            return;
        }
        let key = self.resolve(p).unwrap_or_else(|| Self::norm(p));
        self.owners.insert(key, (uid, gid));
    }
    fn remove(&mut self, p: &str) -> Result<()> {
        let path = Self::norm(p);
        let i = *self.index.get(&path).ok_or_else(|| bad(format!("{p}: no such file")))?;
        self.entries.remove(i);
        self.reindex();
        Ok(())
    }
    fn rename(&mut self, from: &str, to: &str) -> Result<()> {
        let (from, to) = (Self::norm(from), Self::norm(to));
        if !self.index.contains_key(&from) {
            return Err(bad(format!("{from}: no such file")));
        }
        let pre = format!("{from}/");
        for e in self.entries.iter_mut() {
            if e.path == from {
                e.path = to.clone();
            } else if let Some(rest) = e.path.strip_prefix(&pre) {
                e.path = format!("{to}/{rest}");
            }
        }
        let moved: Vec<(String, (u32, u32))> = self.owners.iter().filter(|(k, _)| *k == &from || k.starts_with(&pre)).map(|(k, v)| (k.clone(), *v)).collect();
        for (k, v) in moved {
            self.owners.remove(&k);
            self.owners.insert(format!("{to}{}", &k[from.len()..]), v);
        }
        self.reindex();
        Ok(())
    }
    fn list(&self, p: &str) -> Result<Vec<String>> {
        let dir = self.resolve(p).unwrap_or_default();
        let pre = if dir.is_empty() { String::new() } else { format!("{dir}/") };
        let mut v: Vec<String> = self.entries.iter().filter_map(|e| e.path.strip_prefix(&pre).filter(|r| !r.is_empty() && !r.contains('/')).map(String::from)).collect();
        v.sort();
        Ok(v)
    }
    fn copy(&mut self, from: &str, to: &str) -> Result<()> {
        let data = self.read(from)?;
        let (_, _, mode) = self.stat(from)?;
        self.write(to, &data)?;
        self.chmod(to, mode)
    }
    fn symlink(&mut self, target: &str, link: &str) -> Result<()> {
        let path = Self::norm(link);
        if self.index.contains_key(&path) {
            return Err(bad(format!("{link}: file exists")));
        }
        let parent = path.rsplit_once('/').map(|x| x.0).unwrap_or("");
        if !self.is_dir(parent) {
            return Err(bad(format!("{link}: parent folder missing")));
        }
        self.entries.push(crate::hfswrite::Entry { path: path.clone(), kind: crate::hfswrite::Kind::Symlink { target: target.to_string() }, uid: 0, gid: 0, perm: 0o755, mtime: self.now, link_group: None });
        self.note_push();
        self.index.insert(path, self.entries.len() - 1);
        Ok(())
    }
    fn readlink(&self, p: &str) -> Option<String> {
        match self.index.get(&Self::norm(p)).map(|&i| &self.entries[i].kind) {
            Some(crate::hfswrite::Kind::Symlink { target }) => Some(target.clone()),
            _ => None,
        }
    }
    fn walk(&self, p: &str) -> Result<Vec<String>> {
        let dir = Self::norm(p);
        let pre = format!("{dir}/");
        let mut sorted = self.sorted.borrow_mut();
        let idx = sorted.get_or_insert_with(|| {
            let mut v: Vec<usize> = (0..self.entries.len()).collect();
            v.sort_by(|&a, &b| self.entries[a].path.cmp(&self.entries[b].path));
            v
        });
        let start = idx.partition_point(|&j| self.entries[j].path.as_str() < pre.as_str());
        Ok(idx[start..].iter().map(|&j| &self.entries[j].path).take_while(|q| q.starts_with(&pre)).cloned().collect())
    }
    fn owners(&self) -> &BTreeMap<String, (u32, u32)> {
        &self.owners
    }
}
