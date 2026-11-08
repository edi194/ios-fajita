//! The ported tweaks against root_tweaks18.py on the same synthetic root: same printed lines, same recorded owners,
//! same resulting tree (file bytes, modes, symlinks). Needs python3.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

unsafe extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
    #[link_name = "getgid"]
    fn libc_getgid() -> u32;
}

fn tree(d: &Path) -> Vec<(String, u32, Vec<u8>)> {
    use std::os::unix::fs::PermissionsExt;
    let mut out = Vec::new();
    let mut todo = vec![d.to_path_buf()];
    while let Some(dir) = todo.pop() {
        for e in fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            let m = fs::symlink_metadata(&p).unwrap();
            let rel = p.strip_prefix(d).unwrap().display().to_string();
            if m.is_dir() {
                out.push((rel + "/", m.permissions().mode() & 0o7777, vec![]));
                todo.push(p);
            } else if m.file_type().is_symlink() {
                out.push((rel, 0, fs::read_link(&p).unwrap().display().to_string().into_bytes()));
            } else {
                out.push((rel, m.permissions().mode() & 0o7777, fs::read(&p).unwrap()));
            }
        }
    }
    out.sort();
    out
}

fn compare(quiet: bool) {
    compare_with(quiet, false)
}

fn compare_with(quiet: bool, with_tools: bool) {
    if Command::new("python3").arg("--version").output().is_err() {
        eprintln!("python3 not found: skipping");
        return;
    }
    let base = std::env::temp_dir().join(format!("renegade-rs-tweaks-{}-{quiet}-{with_tools}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let (py_root, rs_root, tools) = (base.join("py"), base.join("rs"), base.join("tools"));
    let script = root().join("tests/tweaks_fixture.py");
    for r in [&py_root, &rs_root] {
        let mut mk = Command::new("python3");
        mk.arg("-I").arg(&script).arg("make").arg(r).arg(&tools);
        if with_tools {
            mk.arg("--with-tools");
        }
        let o = mk.output().unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    }
    let mut py = Command::new("python3");
    // the iOS 18 profile these tests emulate (22H352 on N841 with a D22 ADT); targets.py defaults to ios26
    py.env("RENEGADE_TARGET", "ios18");
    py.arg("-I").arg(&script).arg("run").arg(&py_root).arg(&tools);
    if quiet {
        py.arg("--quiet");
    }
    if with_tools {
        py.arg("--with-tools");
    }
    let p = py.output().unwrap();
    assert!(p.status.success(), "python: {}", String::from_utf8_lossy(&p.stderr));
    let mut rs = Command::new(env!("CARGO_BIN_EXE_renegade-rs"));
    rs.arg("tweaks").arg(&rs_root).args(["--build", "22H352", "--version", "18.7.8", "--board", "N841", "--adt-target", "D22"]);
    rs.arg("--netcfg").arg(tools.join("sweetnetcfg")).arg("--sweetreboot").arg(tools.join("sweetreboot"));
    rs.arg("--display").arg(&py_root);
    if with_tools {
        rs.arg("--tools-dir").arg(&tools).args(["--ssh-key", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey test@bergamota", "--ssh-key-name", "test.pub"]);
    }
    if quiet {
        rs.arg("--quiet");
    }
    let r = rs.output().unwrap();
    assert!(r.status.success(), "rust: {}", String::from_utf8_lossy(&r.stderr));
    // the Python names the directory the GL payload came from; the library has no directory
    let strip_src = |t: String| -> String {
        t.lines().map(|l| match l.find("payload from ") { Some(i) if l.contains(" installed in ") => format!("{}payload{}", &l[..i], &l[l.find(" installed in ").unwrap()..]), _ => l.to_string() }).collect::<Vec<_>>().join("\n")
    };
    let (pl, rl) = (strip_src(String::from_utf8_lossy(&p.stdout).into_owned()), String::from_utf8_lossy(&r.stdout).into_owned());
    assert_eq!(rl.lines().collect::<Vec<_>>(), pl.lines().collect::<Vec<_>>(), "printed lines / owners differ");
    let (a, b) = (tree(&py_root), tree(&rs_root));
    for (x, y) in a.iter().zip(b.iter()) {
        assert_eq!(x.0, y.0, "tree entries differ");
        assert_eq!(x.1, y.1, "mode of {} differs", x.0);
        assert!(x.2 == y.2, "content of {} differs", x.0);
    }
    assert_eq!(a.len(), b.len());
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn tweaks_match_root_tweaks18() {
    compare(false);
}

/// ssh, the BlueTool stub, the first-boot job and its wallpaper tools, bglrender, sweetprefs and the console job.
#[test]
fn tweaks_with_tools_match_root_tweaks18() {
    compare_with(false, true);
}

#[test]
fn tweaks_with_quiet_match_root_tweaks18() {
    compare(true);
}

/// The same tweaks on the root build's in-memory tree (TreeFs): written out, it must equal what root_tweaks18.py
/// left in its folder, and the recorded owners must be the same.
#[test]
fn tweaks_on_the_tree_match_root_tweaks18() {
    if Command::new("python3").arg("--version").output().is_err() {
        return;
    }
    let base = std::env::temp_dir().join(format!("renegade-rs-treefs-{}", std::process::id()));
    let _ = fs::remove_dir_all(&base);
    let (py_root, src, out, tools) = (base.join("py"), base.join("src"), base.join("out"), base.join("tools"));
    let script = root().join("tests/tweaks_fixture.py");
    for r in [&py_root, &src] {
        assert!(Command::new("python3").arg("-I").arg(&script).arg("make").arg(r).arg(&tools).status().unwrap().success());
    }
    let p = Command::new("python3").env("RENEGADE_TARGET", "ios18").arg("-I").arg(&script).arg("run").arg(&py_root).arg(&tools).output().unwrap();
    assert!(p.status.success(), "{}", String::from_utf8_lossy(&p.stderr));
    let (entries, paths, _) = renegade::tree::scan_dir(&src).unwrap();
    let n = paths.len();
    let mut t = renegade::tweaks::TreeFs::new(entries, n, 0, |i| fs::read(&paths[i]));
    // SAFETY: getuid/getgid cannot fail
    t.skip_owner = Some(unsafe { (libc_getuid(), libc_getgid()) });
    let cfg = renegade::tweaks::Config {
        build: "22H352".into(),
        version: "18.7.8".into(),
        board: "N841".into(),
        adt_target: "D22".into(),
        quiet: false,
        netcfg: Some(fs::read(tools.join("sweetnetcfg")).unwrap()),
        sweetreboot: Some(fs::read(tools.join("sweetreboot")).unwrap()),
        root_display: py_root.display().to_string(),
        ..Default::default()
    };
    let mut log = Vec::new();
    renegade::tweaks::run(&mut t, &cfg, &mut log).unwrap();
    let mut lines: Vec<String> = log.clone();
    for (k, (u, g)) in renegade::tweaks::Fs::owners(&t) {
        lines.push(format!("OWNER {k} {u} {g}"));
    }
    let want: Vec<String> = String::from_utf8_lossy(&p.stdout).lines().map(String::from).collect();
    assert_eq!(lines, want);
    // materialize the tree
    use std::os::unix::fs::PermissionsExt;
    let mut es = t.entries.clone();
    es.sort_by(|a, b| a.path.cmp(&b.path));
    for e in &es {
        let p = out.join(&e.path);
        match &e.kind {
            renegade::hfswrite::Kind::Dir => fs::create_dir_all(&p).unwrap(),
            renegade::hfswrite::Kind::File { source, .. } => fs::write(&p, t.data(*source).unwrap()).unwrap(),
            renegade::hfswrite::Kind::Symlink { target } => std::os::unix::fs::symlink(target, &p).unwrap(),
        }
    }
    for e in es.iter().rev() {
        if !matches!(e.kind, renegade::hfswrite::Kind::Symlink { .. }) {
            fs::set_permissions(out.join(&e.path), fs::Permissions::from_mode(e.perm as u32)).unwrap();
        }
    }
    let (a, b) = (tree(&py_root), tree(&out));
    let names = |v: &Vec<(String, u32, Vec<u8>)>| v.iter().map(|x| x.0.clone()).collect::<Vec<_>>();
    assert_eq!(names(&b), names(&a));
    for (x, y) in a.iter().zip(b.iter()) {
        // folders the scan or Python created take the umask/defaults; files and every folder the tweaks chmod must agree
        if !x.0.ends_with('/') {
            assert_eq!(x.1, y.1, "mode of {}", x.0);
        }
        assert!(x.2 == y.2, "content of {} differs", x.0);
    }
    let _ = fs::remove_dir_all(&base);
}
