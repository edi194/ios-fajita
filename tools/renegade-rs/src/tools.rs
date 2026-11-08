//! The tweaks that install prebuilt on-device tools (root_tweaks18.py): SSH over USB (dropbear, dash, toybox), the
//! BlueTool stub, the first-boot job (app registration, default wallpaper), PosterBoard's file-protection
//! shim, the GL renderer for backboardd, and the small helper tools. The tools come from `berga-tools.zip`
//! (tools/berga-tools/package.py): [`Tools`] reads the files these tweaks use out of that zip and checks each
//! against the zip's own manifest.
//!
//! Every feature skips itself, with a line in the log, when its tool is not in the bundle, as the Python build does.

use crate::io::{bad, Src};
use crate::plist::{self, Value};
use crate::tweaks::{add_job, save, Config, Fmt, Fs, Log, LAUNCHD_PLIST, REGISTER_LIST};
use crate::zip::Zip;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Result;

pub const BLUETOOL_STUB: &str = "sweetnet/bluetool-stub";
const HCITEST: &str = "sweetnet/hcitest";
const DROPBEAR_LABEL: &str = "org.sweet.dropbear";
const DROPBEAR_KEY: &str = "/private/etc/dropbear/dropbear_ed25519_host_key";
const FIRSTBOOT_LABEL: &str = "org.bergamota.renegade-firstboot";
const FIRSTBOOT_SH: &str = "usr/local/libexec/renegade-firstboot.sh";
const FIRSTBOOT_SCRIPT: &str = include_str!("../data/firstboot.sh");
const WALLPAPER_COLLECTIONS: &str = "com.apple.WallpaperKit.CollectionsPoster:5010";
const SWEETFP_PATH: &str = "/usr/local/lib/sweetfp.dylib";
const POSTER_BIN: &str = "Applications/PosterBoard.app/PosterBoard";
const BGL_FILES: [&str; 4] = ["bgl-launch", "OpenGLES.framework/OpenGLES", "libOSMesa.8.dylib", "libdrm.2.dylib"];
const BGL_DIR: &str = "usr/local/lib/bergamota-gl";
const BGL_LAUNCH: &str = "/usr/local/lib/bergamota-gl/bgl-launch";
const BACKBOARDD_LABEL: &str = "com.apple.backboardd";
const BACKBOARDD_PATH: &str = "/usr/libexec/backboardd";
const TOYBOX_CONFIG: &str = include_str!("../../ssh/toybox.config");

/// The files of berga-tools.zip the tweaks use, by their path in the zip ("ssh/dropbear", "sweetnet/hcitest", ...).
#[derive(Default, Clone)]
pub struct Tools {
    files: BTreeMap<String, Vec<u8>>,
}

impl Tools {
    /// Reads the bundle, keeping `ssh/`, `sweetnet/` and `bergamota-gl/` and checking each file's SHA-256 against
    /// `berga-tools.json`. A file the manifest does not list, or lists differently, is an error.
    pub fn from_zip(src: Src) -> Result<Self> {
        let zip = Zip::open(src)?;
        let m = zip.find("berga-tools.json").ok_or_else(|| bad("not a berga-tools bundle (no berga-tools.json)"))?;
        let manifest = zip.read_all(m)?;
        let manifest = String::from_utf8_lossy(&manifest).into_owned();
        let mut sums: BTreeMap<String, String> = BTreeMap::new();
        // {"path": "...", "sha256": "...", ...} objects, one per file
        for chunk in manifest.split("\"path\"").skip(1) {
            let path = chunk.split('"').nth(1).unwrap_or("").to_string();
            if let Some(h) = chunk.split("\"sha256\"").nth(1).and_then(|r| r.split('"').nth(1)) {
                sums.insert(path, h.to_string());
            }
        }
        let mut files = BTreeMap::new();
        for e in &zip.entries {
            if !(e.name.starts_with("ssh/") || e.name.starts_with("sweetnet/") || e.name.starts_with("bergamota-gl/")) || e.name.ends_with('/') {
                continue;
            }
            let data = zip.read_all(e)?;
            let want = sums.get(&e.name).ok_or_else(|| bad(format!("{}: not in berga-tools.json", e.name)))?;
            let got: String = Sha256::digest(&data).iter().map(|b| format!("{b:02x}")).collect();
            if &got != want {
                return Err(bad(format!("{}: SHA-256 does not match berga-tools.json", e.name)));
            }
            files.insert(e.name.clone(), data);
        }
        Ok(Tools { files })
    }

    pub fn from_files(files: BTreeMap<String, Vec<u8>>) -> Self {
        Tools { files }
    }

    pub fn get(&self, name: &str) -> Option<&[u8]> {
        self.files.get(name).map(Vec::as_slice)
    }

    fn under(&self, prefix: &str) -> Vec<(&str, &[u8])> {
        self.files.iter().filter_map(|(k, v)| k.strip_prefix(prefix).map(|r| (r, v.as_slice()))).collect()
    }
}

/// install_file(): root:wheel and the mode; like the Python (which chowns its `.new` temporary before the rename) the owner
/// is recorded for `dst.new`: the entry is harmless, the new file's owner is root:wheel by default.
fn install(fs: &mut dyn Fs, data: &[u8], dst: &str, mode: u32) -> Result<()> {
    if let Some((dir, _)) = dst.rsplit_once('/') {
        fs.makedirs(dir)?;
    }
    fs.write(dst, data)?;
    fs.chown(&format!("{dst}.new"), 0, 0);
    fs.chmod(dst, mode)
}

fn s(v: &str) -> Value {
    Value::String(v.to_string())
}

fn dict(items: Vec<(&str, Value)>) -> Value {
    Value::Dict(items.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// relink(): a symlink `link` -> `target`, replacing what is there unless it already is that link.
fn relink(fs: &mut dyn Fs, target: &str, link: &str) -> Result<()> {
    if fs.readlink(link).as_deref() == Some(target) {
        return Ok(());
    }
    if fs.exists(link) || fs.readlink(link).is_some() {
        fs.remove(link)?;
    }
    fs.symlink(target, link)
}

/// toybox_applets(): the CONFIG_X=y lines of tools/ssh/toybox.config that also appear as a C string in the binary
/// (plus `[` for test and `nc` for netcat), sorted.
fn toybox_applets(binary: &[u8]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for l in TOYBOX_CONFIG.lines() {
        let Some(name) = l.strip_prefix("CONFIG_").and_then(|r| r.strip_suffix("=y")) else { continue };
        if name.is_empty() || !name.bytes().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_') {
            continue;
        }
        let name = name.to_lowercase();
        let mut needle = vec![0u8];
        needle.extend_from_slice(name.as_bytes());
        needle.push(0);
        if name != "toybox" && binary.windows(needle.len()).any(|w| w == needle.as_slice()) && !found.contains(&name) {
            found.push(name);
        }
    }
    if found.iter().any(|n| n == "test") {
        found.push("[".into());
    }
    if found.iter().any(|n| n == "netcat") {
        found.push("nc".into());
    }
    found.sort();
    found
}

/// ssh(): key-only SSH over the USB link (dropbear, dash as /bin/sh, toybox, authorized_keys, launchd job).
fn ssh(fs: &mut dyn Fs, log: &mut Log, t: &Tools, key: Option<&str>, name: Option<&str>) -> Result<()> {
    let (Some(dropbear), Some(dash), Some(toybox)) = (t.get("ssh/dropbear"), t.get("ssh/dash"), t.get("ssh/toybox")) else {
        log.push("ssh: skipped, not built (run tools/ssh/build.sh): dropbear, dash, toybox".into());
        return Ok(());
    };
    let Some(key) = key.map(str::trim).filter(|k| !k.is_empty()) else {
        log.push("ssh: skipped, no public key (~/.ssh/id_ed25519.pub) for the Mac user".into());
        return Ok(());
    };
    let first = key.lines().next().unwrap_or("");
    if !["ssh-", "ecdsa-", "sk-"].iter().any(|p| first.starts_with(p)) {
        return Err(bad("the SSH public key must be one line starting with ssh-, ecdsa- or sk-"));
    }
    let bindir = "usr/local/bin";
    install(fs, dropbear, &format!("{bindir}/dropbear"), 0o755)?;
    for n in ["dropbearkey", "scp"] {
        relink(fs, "dropbear", &format!("{bindir}/{n}"))?;
    }
    install(fs, toybox, &format!("{bindir}/toybox"), 0o755)?;
    let mut n = 0;
    for a in toybox_applets(toybox) {
        let dst = format!("{bindir}/{a}");
        if a != "toybox" && (!fs.exists(&dst) && fs.readlink(&dst).is_none() || fs.readlink(&dst).is_some()) {
            relink(fs, "toybox", &dst)?;
            n += 1;
        }
    }
    install(fs, dash, "bin/sh", 0o755)?;
    log.push(format!("ssh: /usr/local/bin/{{dropbear,dropbearkey,scp,toybox + {n} applet links}}, /bin/sh = dash"));

    // dropbear checks the login shell against /etc/shells
    let shells = "private/etc/shells";
    let text = if fs.exists(shells) { String::from_utf8_lossy(&fs.read(shells)?).into_owned() } else { String::new() };
    let mut lines: Vec<&str> = text.lines().collect();
    if !lines.contains(&"/bin/sh") {
        lines.push("/bin/sh");
        fs.write(shells, format!("{}\n", lines.join("\n")).as_bytes())?;
        fs.chown(shells, 0, 0);
        fs.chmod(shells, 0o644)?;
        log.push("ssh: /private/etc/shells += /bin/sh".into());
    }
    // root's login shell/home must be /bin/sh and /var/root
    let passwd = "private/etc/passwd";
    let entry = if fs.exists(passwd) { String::from_utf8_lossy(&fs.read(passwd)?).lines().find(|l| l.starts_with("root:")).map(String::from) } else { None };
    let ok = entry.as_ref().is_some_and(|e| e.split(':').rev().take(2).collect::<Vec<_>>() == ["/bin/sh", "/var/root"]);
    if !ok {
        log.push(format!("warning: root entry in /private/etc/passwd is not ...:/var/root:/bin/sh: {}", entry.map(|e| format!("'{e}'")).unwrap_or("None".into())));
    }
    // authorized_keys (public key only), root-owned, strict modes
    let d = "private/var/root/.ssh";
    fs.makedirs(d)?;
    fs.chown(d, 0, 0);
    fs.chmod(d, 0o700)?;
    let ak = format!("{d}/authorized_keys");
    let mut have: Vec<String> = if fs.exists(&ak) { String::from_utf8_lossy(&fs.read(&ak)?).lines().map(String::from).collect() } else { vec![] };
    if !have.iter().any(|l| l == first) {
        have.push(first.to_string());
    }
    fs.write(&ak, format!("{}\n", have.join("\n")).as_bytes())?;
    fs.chown(&ak, 0, 0);
    fs.chmod(&ak, 0o600)?;
    log.push(format!("ssh: authorized_keys <- {}", name.unwrap_or("the public key you gave")));
    // host keys: dropbear -R makes them on the phone at the first connection (a browser has no dropbearkey)
    let kd = "private/etc/dropbear";
    fs.makedirs(kd)?;
    fs.chown(kd, 0, 0);
    fs.chmod(kd, 0o700)?;
    for typ in ["ed25519", "ecdsa"] {
        log.push(format!("ssh: no dropbearkey for the host (Linux: apt install dropbear-bin): host key {typ} left to dropbear -R, which generates it on the phone at the first connection"));
    }
    let job = dict(vec![
        ("Label", s(DROPBEAR_LABEL)),
        ("ProgramArguments", Value::Array(["/usr/local/bin/dropbear", "-F", "-E", "-s", "-p", "22", "-R"].iter().map(|x| s(x)).collect())),
        ("RunAtLoad", Value::Bool(true)),
        ("KeepAlive", Value::Bool(true)),
        ("UserName", s("root")),
        ("StandardErrorPath", s("/dev/console")),
    ]);
    let _ = DROPBEAR_KEY;
    add_job(fs, DROPBEAR_LABEL, &job)?;
    log.push(format!("ssh: launchd job {DROPBEAR_LABEL} (port 22 v4+v6, key-only)"));
    Ok(())
}

/// bluetooth(): the BlueTool stub as /usr/sbin/BlueTool (the original kept as BlueTool.orig) and hcitest.
fn bluetooth_stub(fs: &mut dyn Fs, log: &mut Log, t: &Tools) -> Result<()> {
    let Some(stub) = t.get(BLUETOOL_STUB) else { return Ok(()) };
    if !fs.exists(LAUNCHD_PLIST) {
        return Ok(());
    }
    let dst = "usr/sbin/BlueTool";
    let orig = format!("{dst}.orig");
    if fs.exists(dst) && !fs.exists(&orig) && fs.read(dst)? != stub {
        fs.copy(dst, &orig)?;
        fs.chown(&orig, 0, 0);
        log.push("bluetooth: original BlueTool kept as BlueTool.orig".into());
    }
    install(fs, stub, dst, 0o755)?;
    log.push("bluetooth: /usr/sbin/BlueTool is the stub".into());
    if let Some(h) = t.get(HCITEST) {
        install(fs, h, "usr/local/bin/hcitest", 0o755)?;
        log.push("bluetooth: /usr/local/bin/hcitest installed".into());
    }
    log.push("bluetooth: RENEGADE_BT_FW not set: no WCN3990 firmware in the root (the BT stage will not download)".into());
    Ok(())
}

/// The load command addlc.py appends: LC_LOAD_DYLIB for `path` in the slack before the first section.
pub fn add_load_dylib(d: &mut [u8], path: &str) -> Result<()> {
    use crate::bytes::{u32le, u64le};
    if d.len() < 32 || u32le(d, 0) != 0xFEED_FACF {
        return Err(bad("thin 64-bit Mach-O only"));
    }
    let (ncmds, scmds) = (u32le(d, 16) as usize, u32le(d, 20) as usize);
    let (mut off, mut lowest) = (32usize, u64::MAX);
    for _ in 0..ncmds {
        let (cmd, sz) = (u32le(d, off), u32le(d, off + 4) as usize);
        if cmd == 0x19 {
            let nsects = u32le(d, off + 64) as usize;
            for k in 0..nsects {
                let so = off + 72 + k * 80;
                let soff = u32le(d, so + 48) as u64;
                if soff != 0 {
                    lowest = lowest.min(soff);
                }
            }
            let _ = u64le;
        }
        off += sz;
    }
    let mut nm = path.as_bytes().to_vec();
    nm.push(0);
    let cmdsz = (24 + nm.len() + 7) & !7;
    let end = 32 + scmds;
    if (end + cmdsz) as u64 > lowest {
        return Err(bad(format!("no slack for a new load command ({} free, {cmdsz} needed)", lowest.saturating_sub(end as u64))));
    }
    let mut lc = Vec::new();
    for v in [0xCu32, cmdsz as u32, 24, 2, 0x10000, 0x10000] {
        lc.extend_from_slice(&v.to_le_bytes());
    }
    lc.extend_from_slice(&nm);
    lc.resize(cmdsz, 0);
    d[end..end + cmdsz].copy_from_slice(&lc);
    d[16..20].copy_from_slice(&((ncmds + 1) as u32).to_le_bytes());
    d[20..24].copy_from_slice(&((scmds + cmdsz) as u32).to_le_bytes());
    Ok(())
}

/// True if the thin 64-bit Mach-O has a load command naming `dylib` (LOAD/WEAK/REEXPORT).
pub fn has_dylib(d: &[u8], dylib: &str) -> bool {
    use crate::bytes::u32le;
    if d.len() < 32 || u32le(d, 0) != 0xFEED_FACF {
        return false;
    }
    let mut off = 32usize;
    for _ in 0..u32le(d, 16) {
        let (cmd, sz) = (u32le(d, off), u32le(d, off + 4) as usize);
        if matches!(cmd, 0xC | 0x8000_0018 | 0x1F | 0x8000_001F) {
            let no = u32le(d, off + 8) as usize;
            let nm = &d[off + no..off + sz];
            let z = nm.iter().position(|&c| c == 0).unwrap_or(nm.len());
            if &nm[..z] == dylib.as_bytes() {
                return true;
            }
        }
        off += sz;
        if off + 8 > d.len() {
            break;
        }
    }
    false
}

/// posterboard(): sweetfp.dylib into /usr/local/lib and an extra LC_LOAD_DYLIB in PosterBoard (stripped and re-signed
/// ad hoc, keeping identifier, flags and entitlements).
fn posterboard(fs: &mut dyn Fs, log: &mut Log, t: &Tools) -> Result<()> {
    if !fs.exists(POSTER_BIN) {
        log.push(format!("posterboard: no {POSTER_BIN} in the image: skipped"));
        return Ok(());
    }
    let Some(dylib) = t.get("sweetnet/ios18/sweetfp.dylib") else {
        log.push("posterboard: sweetfp.dylib not built (tools/sweetnet/build.sh): skipped, PosterBoard left alone".into());
        return Ok(());
    };
    install(fs, dylib, SWEETFP_PATH.trim_start_matches('/'), 0o755)?;
    log.push(format!("posterboard: {SWEETFP_PATH} installed"));
    let bin = fs.read(POSTER_BIN)?;
    if has_dylib(&bin, SWEETFP_PATH) {
        log.push(format!("posterboard: PosterBoard already links {SWEETFP_PATH}"));
        return Ok(());
    }
    let (_, _, mode) = fs.stat(POSTER_BIN)?;
    let before = crate::codesign::identity(&bin).ok_or_else(|| bad("PosterBoard has no code signature to keep"))?;
    // the macho stage strips the files of the IPSW, not the ones the tweaks write: strip it first, as the Python order does
    let mut d = bin;
    crate::pacstrip::strip(&mut d, &crate::pacstrip::Options { write: true, ..Default::default() })?;
    add_load_dylib(&mut d, SWEETFP_PATH)?;
    let signed = crate::codesign::resign(&d, None, None)?;
    let after = crate::codesign::identity(&signed).ok_or_else(|| bad("posterboard: the re-sign lost the signature"))?;
    if after.ident != before.ident {
        return Err(bad("posterboard: the identifier changed by the re-sign: PosterBoard left alone"));
    }
    if !has_dylib(&signed, SWEETFP_PATH) {
        return Err(bad("posterboard: LC_LOAD_DYLIB missing after addlc"));
    }
    install(fs, &signed, POSTER_BIN, mode)?;
    log.push(format!("posterboard: PosterBoard links {SWEETFP_PATH} (re-signed ad hoc as {})", before.ident));
    Ok(())
}

/// firstboot(): the first-boot job (app registration with sweetuicache, default wallpaper and icon style).
fn firstboot(fs: &mut dyn Fs, log: &mut Log, t: &Tools) -> Result<()> {
    if !fs.exists("bin/sh") {
        log.push("firstboot: /bin/sh missing (the ssh tweak installs dash): skipped".into());
        return Ok(());
    }
    let (mut appreg, mut wallpaper) = (true, true);
    match t.get("sweetnet/ios18/sweetuicache") {
        Some(u) => install(fs, u, "usr/local/bin/sweetuicache", 0o755)?,
        None => {
            log.push("firstboot: sweetuicache not built (tools/sweetnet/build.sh): app registration skipped".into());
            appreg = false;
            wallpaper = false;
        }
    }
    if wallpaper {
        let names = ["sweetposterset", "sweeticonstyle", "sweetopen"];
        let have: Vec<Option<&[u8]>> = names.iter().map(|n| t.get(&format!("sweetnet/ios18/{n}"))).collect();
        let app = t.under("sweetnet/ios18/SweetRun.app/");
        if have.iter().any(Option::is_none) || app.is_empty() {
            log.push("firstboot: sweetposterset/sweeticonstyle/sweetopen/SweetRun.app not built (tools/sweetnet/build.sh): default wallpaper and icon style skipped".into());
            wallpaper = false;
        } else {
            for (n, d) in names.iter().zip(have) {
                install(fs, d.unwrap(), &format!("usr/local/bin/{n}"), 0o755)?;
            }
            let dir = "Applications/SweetRun.app";
            fs.makedirs(dir)?;
            fs.chown(dir, 0, 0);
            for (rel, data) in app {
                let p = format!("{dir}/{rel}");
                if let Some((parent, _)) = p.rsplit_once('/')
                    && !fs.is_dir(parent)
                {
                    fs.makedirs(parent)?;
                    fs.chown(parent, 0, 0);
                }
                fs.write(&p, data)?;
                fs.chown(&p, 0, 0);
                fs.chmod(&p, if rel == "SweetRun" { 0o755 } else { 0o644 })?;
            }
            log.push("firstboot: sweetposterset, sweeticonstyle, sweetopen, /Applications/SweetRun.app installed".into());
        }
    }
    let (wp, wd) = WALLPAPER_COLLECTIONS.split_once(':').unwrap();
    let script = FIRSTBOOT_SCRIPT
        .replace("@APPREG@", if appreg { "1" } else { "0" })
        .replace("@WALL@", if wallpaper { "1" } else { "0" })
        .replace("@WPROV@", wp)
        .replace("@WDESC@", wd)
        .replace("@WPROV2@", wp)
        .replace("@WDESC2@", wd);
    if let Some((dir, _)) = FIRSTBOOT_SH.rsplit_once('/') {
        fs.makedirs(dir)?;
    }
    fs.write(FIRSTBOOT_SH, script.as_bytes())?;
    fs.chown(FIRSTBOOT_SH, 0, 0);
    fs.chmod(FIRSTBOOT_SH, 0o755)?;
    log.push(format!("firstboot: wallpaper poster {WALLPAPER_COLLECTIONS} (no Metal device)"));
    let job = dict(vec![
        ("Label", s(FIRSTBOOT_LABEL)),
        ("ProgramArguments", Value::Array(vec![s("/bin/sh"), s(&format!("/{FIRSTBOOT_SH}"))])),
        ("RunAtLoad", Value::Bool(true)),
        ("UserName", s("root")),
        ("StandardErrorPath", s("/dev/console")),
        ("EnvironmentVariables", dict(vec![("PATH", s("/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"))])),
    ]);
    add_job(fs, FIRSTBOOT_LABEL, &job)?;
    let n = if fs.exists(REGISTER_LIST) { String::from_utf8_lossy(&fs.read(REGISTER_LIST)?).split('\n').filter(|l| !l.is_empty()).count() } else { 0 };
    log.push(format!(
        "firstboot: job {FIRSTBOOT_LABEL} ({n} apps to register, appreg {}, wallpaper {}, jailbreak post-install off)",
        if appreg { "on" } else { "off" },
        if wallpaper { "on" } else { "off" }
    ));
    Ok(())
}

/// bglrender(): the GL renderer payload and backboardd's job starting bgl-launch (inert without the boot-arg).
fn bglrender(fs: &mut dyn Fs, log: &mut Log, t: &Tools) -> Result<()> {
    if !BGL_FILES.iter().all(|f| t.get(&format!("bergamota-gl/{f}")).is_some()) {
        log.push("bglrender: payload not built (gpu/eagl/make-payload.sh): backboardd job left alone".into());
        return Ok(());
    }
    let dst = BGL_DIR;
    for d in [dst.to_string(), format!("{dst}/OpenGLES.framework")] {
        fs.makedirs(&d)?;
        fs.chown(&d, 0, 0);
        fs.chmod(&d, 0o755)?;
    }
    // the launcher goes last: a job pointing at a missing launcher would not start backboardd at all
    for f in BGL_FILES[1..].iter().chain(BGL_FILES[..1].iter()) {
        install(fs, t.get(&format!("bergamota-gl/{f}")).unwrap(), &format!("{dst}/{f}"), 0o755)?;
    }
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = plist::parse(&fs.read(LAUNCHD_PLIST)?)?;
    let mut n = 0;
    if let Some(Value::Dict(jobs)) = pl.as_dict_mut().and_then(|d| d.get_mut("LaunchDaemons")) {
        for job in jobs.values_mut() {
            if job.get("Label").and_then(Value::as_str) != Some(BACKBOARDD_LABEL) {
                continue;
            }
            if let Value::Dict(j) = job
                && let Some(Value::Array(pa)) = j.get_mut("ProgramArguments")
            {
                match pa.first().and_then(Value::as_str) {
                    Some(BACKBOARDD_PATH) => {
                        pa[0] = s(BGL_LAUNCH);
                        n += 1;
                    }
                    Some(BGL_LAUNCH) => n += 1,
                    _ => {}
                }
            }
        }
    }
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)?;
    log.push(format!("bglrender: payload installed in /{BGL_DIR}; backboardd job -> {BGL_LAUNCH} ({n} entr{}; inert without boot-arg bglrender=1|soft)", if n == 1 { "y" } else { "ies" }));
    Ok(())
}

/// sweetprefs_tool(): sweetprefs, sweetshot and sweettouch in /usr/local/bin.
fn sweetprefs_tools(fs: &mut dyn Fs, log: &mut Log, t: &Tools) -> Result<()> {
    match t.get("sweetnet/ios18/sweetprefs") {
        None => log.push("sweetprefs: not built (tools/sweetnet/build.sh): skipped".into()),
        Some(d) => {
            install(fs, d, "usr/local/bin/sweetprefs", 0o755)?;
            log.push("sweetprefs: /usr/local/bin/sweetprefs installed".into());
            for n in ["sweetshot", "sweettouch"] {
                if let Some(d) = t.get(&format!("sweetnet/ios18/{n}")) {
                    install(fs, d, &format!("usr/local/bin/{n}"), 0o755)?;
                    log.push(format!("{n}: /usr/local/bin/{n} installed"));
                }
            }
        }
    }
    Ok(())
}

const JOB_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array>{args}</array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/dev/console</string>
<key>StandardErrorPath</key><string>/dev/console</string>
<key>EnvironmentVariables</key><dict><key>OS_ACTIVITY_DT_MODE</key><string>YES</string></dict>
</dict></plist>
"#;

/// The console job of mkroot-full.py: shows at once whether launchd runs jobs (needs /bin/sh, dash from the ssh tweak).
fn console_job(fs: &mut dyn Fs, log: &mut Log) -> Result<()> {
    if !fs.exists("bin/sh") {
        return Ok(());
    }
    let label = "org.sweet.ios18.hello";
    let jpath = format!("System/Library/LaunchDaemons/{label}.plist");
    let args = ["/bin/sh", "-c", "echo \"SWEET iOS18 full root: launchd runs jobs, 6*7=$((6*7))\"; /usr/local/bin/toybox uname -a; /usr/local/bin/toybox cat /etc/master.passwd"];
    let xml = JOB_XML.replace("{label}", label).replace("{args}", &args.iter().map(|a| format!("<string>{a}</string>")).collect::<String>());
    fs.makedirs("System/Library/LaunchDaemons")?;
    fs.write(&jpath, xml.as_bytes())?;
    fs.chmod(&jpath, 0o644)?;
    let (uid, gid, mode) = fs.stat(LAUNCHD_PLIST)?;
    let mut pl = plist::parse(&fs.read(LAUNCHD_PLIST)?)?;
    let job = plist::parse(xml.as_bytes())?;
    if let Some(Value::Dict(jobs)) = pl.as_dict_mut().and_then(|d| d.get_mut("LaunchDaemons")) {
        jobs.insert(format!("/{jpath}"), job);
    }
    save(fs, LAUNCHD_PLIST, &pl, uid, gid, mode, Fmt::Binary)?;
    log.push(format!("bring-up job {label}"));
    Ok(())
}

/// The ssh tweak (runs right after sweetreboot).
pub fn run_ssh(fs: &mut dyn Fs, cfg: &Config, log: &mut Log) -> Result<()> {
    match &cfg.tools {
        Some(t) => ssh(fs, log, t, cfg.ssh_key.as_deref(), cfg.ssh_key_name.as_deref()),
        None => Ok(()),
    }
}

/// The other tool-dependent tweaks (after the staged apps and bluetoothd's environment), in root_tweaks18's order.
pub fn run_rest(fs: &mut dyn Fs, cfg: &Config, log: &mut Log) -> Result<()> {
    let Some(t) = &cfg.tools else { return Ok(()) };
    bluetooth_stub(fs, log, t)?;
    posterboard(fs, log, t)?;
    firstboot(fs, log, t)?;
    bglrender(fs, log, t)?;
    sweetprefs_tools(fs, log, t)?;
    console_job(fs, log)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A thin Mach-O header with one segment and one section whose data starts at `sect_off`.
    fn macho(sect_off: u32) -> Vec<u8> {
        let mut d = vec![0u8; 0x1000];
        d[0..4].copy_from_slice(&0xFEED_FACFu32.to_le_bytes());
        d[16..20].copy_from_slice(&1u32.to_le_bytes());
        d[20..24].copy_from_slice(&(72u32 + 80).to_le_bytes());
        d[32..36].copy_from_slice(&0x19u32.to_le_bytes());
        d[36..40].copy_from_slice(&(72u32 + 80).to_le_bytes());
        d[32 + 64..32 + 68].copy_from_slice(&1u32.to_le_bytes());
        d[32 + 72 + 48..32 + 72 + 52].copy_from_slice(&sect_off.to_le_bytes());
        d
    }

    #[test]
    fn adds_a_load_command_in_the_slack_like_addlc_py() {
        let mut d = macho(0x400);
        assert!(!has_dylib(&d, SWEETFP_PATH));
        add_load_dylib(&mut d, SWEETFP_PATH).unwrap();
        assert!(has_dylib(&d, SWEETFP_PATH));
        assert_eq!(u32::from_le_bytes(d[16..20].try_into().unwrap()), 2);
        let want = (24 + SWEETFP_PATH.len() + 1 + 7) & !7;
        assert_eq!(u32::from_le_bytes(d[20..24].try_into().unwrap()) as usize, 72 + 80 + want);
        // struct.pack('<IIIIII', 0xc, cmdsz, 24, 2, 0x10000, 0x10000) + name
        let at = 32 + 72 + 80;
        assert_eq!(&d[at..at + 4], &0xCu32.to_le_bytes());
        assert_eq!(&d[at + 24..at + 24 + SWEETFP_PATH.len()], SWEETFP_PATH.as_bytes());
        // no slack: refused, nothing changed
        let mut tight = macho(32 + 152 + 8);
        assert!(add_load_dylib(&mut tight, SWEETFP_PATH).is_err());
    }
}
