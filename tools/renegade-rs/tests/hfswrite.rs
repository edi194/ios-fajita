//! The HFS+ root pieces against the Python Renegade and against macOS:
//! - `owners` (hfsroot_owners.py) and `trim` (hfs_trim.py): byte-identical images;
//! - `mkhfs` (new, no Python equivalent): fsck_hfs clean, mounts, same tree as the source, and the same owners and
//!   modes as the Python way (hdiutil volume + hfsroot_owners.py) with the same owner map. The macOS checks are
//!   skipped elsewhere.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}
fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_renegade-rs"))
}
fn tmpdir() -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("renegade-rs-hfs-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}
fn run(c: &mut Command) -> String {
    let o = c.output().unwrap();
    assert!(o.status.success(), "{c:?} failed: {}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    String::from_utf8_lossy(&o.stdout).into_owned()
}
fn have(tool: &str) -> bool {
    let ok = Command::new("which").arg(tool).output().map(|o| o.status.success()).unwrap_or(false);
    if !ok {
        eprintln!("{tool} not found: skipping");
    }
    ok
}
fn py(script: &str) -> Command {
    let mut c = Command::new("python3");
    c.arg("-I").arg(root().join("../renegade").join(script));
    c
}

/// The fixture volumes expanded to raw images.
fn raw(name: &str, dir: &Path) -> PathBuf {
    let out = dir.join(format!("{name}.raw"));
    run(Command::new(bin()).arg("simg2img").arg(root().join("tests/fixtures").join(format!("{name}.simg"))).arg(&out));
    out
}

const MAP: &str = "usr\t0\t0\t755\nusr/lib\t0\t80\t755\nusr/lib/hello.txt\t501\t501\t600\nusr/lib/hardlink.txt\t0\t0\t4755\nLibrary/Café/naïve.txt\t25\t25\t640\n\t0\t0\t755\n";

#[test]
fn owners_and_trim_are_byte_identical_to_python() {
    if !have("python3") {
        return;
    }
    let d = tmpdir();
    fs::write(d.join("map.tsv"), MAP).unwrap();
    for vol in ["hfsplus", "hfsx"] {
        for args in [vec!["--map", "map.tsv", "--default-root"], vec!["--map", "map.tsv"], vec!["--default-root"]] {
            let a = raw(vol, &d);
            let b = d.join("rs.raw");
            fs::copy(&a, &b).unwrap();
            let p = run(py("hfsroot_owners.py").arg(&a).args(&args).current_dir(&d));
            let r = run(Command::new(bin()).arg("owners").arg(&b).args(&args).current_dir(&d));
            assert_eq!(r, p, "{vol} {args:?}: summary differs");
            assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "{vol} {args:?}: images differ");
            let p = run(py("hfs_trim.py").arg(&a));
            let r = run(Command::new(bin()).arg("trim").arg(&b));
            assert_eq!(r.split(": ").nth(1), p.split(": ").nth(1), "{vol}: trim summary differs");
            assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "{vol}: trimmed images differ");
        }
    }
}

#[test]
fn owner_map_round_trips_like_mkroot_full() {
    let m = renegade::hfsedit::parse_map(MAP).unwrap();
    // mkroot-full.py writes it back sorted; NFD keys
    let text = renegade::hfsedit::format_map(&m);
    let again = renegade::hfsedit::parse_map(&text).unwrap();
    assert_eq!(m, again);
    assert!(text.starts_with("\t0\t0\t755\nLibrary/Cafe\u{301}/nai\u{308}ve.txt\t25\t25\t640\n"), "{text:?}");
}

/// A source tree: the fixture's files plus extra hard links, an empty folder and odd names.
fn source_tree(d: &Path) -> PathBuf {
    let src = d.join("src");
    for sub in ["usr", "System", "Library"] {
        run(Command::new(bin()).args(["hfs"]).arg(root().join("tests/fixtures/hfsx.simg")).args(["getdir", &format!("/{sub}")]).arg(src.join(sub)));
    }
    fs::hard_link(src.join("usr/lib/hello.txt"), src.join("usr/lib/link2.txt")).unwrap();
    fs::hard_link(src.join("usr/lib/hello.txt"), src.join("Library/Café/link3.txt")).unwrap();
    fs::create_dir_all(src.join("empty/deeper/still")).unwrap();
    fs::write(src.join("empty/deeper/Case"), b"upper").unwrap();
    fs::write(src.join("empty/deeper/case"), b"lower").unwrap(); // HFSX is case-sensitive
    fs::write(src.join("usr/lib/\u{2126}hm \u{FB01}le"), b"kept composed").unwrap(); // Ω (U+2126) and the ﬁ ligature
    src
}

fn attach(img: &Path, mnt: Option<&Path>) -> String {
    let mut c = Command::new("hdiutil");
    c.args(["attach", "-imagekey", "diskimage-class=CRawDiskImage"]);
    match mnt {
        Some(m) => c.args(["-readonly", "-nobrowse", "-owners", "on", "-mountpoint"]).arg(m),
        None => c.arg("-nomount"),
    };
    let out = run(c.arg(img));
    out.split_whitespace().next().unwrap().to_string()
}

fn detach(dev: &str) {
    let _ = Command::new("hdiutil").args(["detach", "-quiet", dev]).status();
}

#[test]
fn mkhfs_volume_passes_fsck_and_mounts_as_the_source() {
    if !have("fsck_hfs") || !have("hdiutil") {
        return;
    }
    let d = tmpdir();
    let src = source_tree(&d);
    let img = d.join("out.img");
    run(Command::new(bin()).arg("mkhfs").arg(&src).arg(&img).args(["--date", "1700000000"]));
    let dev = attach(&img, None);
    let o = Command::new("fsck_hfs").args(["-fn", &dev]).output().unwrap();
    detach(&dev);
    let text = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && text.contains("appears to be OK"), "fsck_hfs:\n{text}");
    let mnt = d.join("mnt");
    fs::create_dir_all(&mnt).unwrap();
    attach(&img, Some(&mnt));
    let diff = Command::new("diff").args(["-r", "--no-dereference"]).arg(&src).arg(&mnt).output().unwrap();
    use std::os::unix::fs::MetadataExt;
    let ino = |p: &str| fs::metadata(mnt.join(p)).unwrap().ino();
    let nlink = fs::metadata(mnt.join("usr/lib/hello.txt")).unwrap().nlink();
    let same_inode = ino("usr/lib/hello.txt") == ino("usr/lib/link2.txt") && ino("usr/lib/hello.txt") == ino("Library/Café/link3.txt");
    let modes: Vec<(u32, u32)> = ["usr/lib/hello.txt", "usr/lib/sub dir/big.bin", "usr/lib"]
        .iter()
        .map(|p| (fs::symlink_metadata(src.join(p)).unwrap().mode(), fs::symlink_metadata(mnt.join(p)).unwrap().mode()))
        .collect();
    detach(mnt.to_str().unwrap());
    assert!(diff.status.success(), "diff -r:\n{}", String::from_utf8_lossy(&diff.stdout));
    assert!(same_inode && nlink == 3, "hard links: same inode {same_inode}, link count {nlink}");
    for (a, b) in modes {
        assert_eq!(a & 0o177777, b & 0o177777);
    }
}

/// uid, gid, mode and size of every path, read with hfsx.py (the Python reader) from an image.
fn ownership(img_simg: &Path, paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .map(|p| {
            let out = run(py("hfsx.py").arg(img_simg).args(["stat", p]));
            format!("{p}: {}", out.lines().nth(1).unwrap_or("(folder)"))
        })
        .collect()
}

#[test]
fn mkhfs_owners_match_the_python_way() {
    if !have("python3") || !have("hdiutil") {
        return;
    }
    let d = tmpdir();
    let src = source_tree(&d);
    // all links of one file get the same entry, as in a real build (they come from one lstat): with conflicting
    // entries hfsroot_owners.py's result depends on the catalog order of the links, i.e. on the CNIDs the copy
    // happened to assign, which no other writer can reproduce
    let map = MAP.replace("usr/lib/hardlink.txt\t0\t0\t4755", "usr/lib/hardlink.txt\t501\t501\t600")
        + "usr/lib/link2.txt\t501\t501\t600\nLibrary/Café/link3.txt\t501\t501\t600\n";
    fs::write(d.join("map.tsv"), map).unwrap();
    // Python: hdiutil (newfs_hfs + copy) -> hfsroot_owners.py --map --default-root -> img2simg.py
    let pyraw = d.join("py.cdr");
    run(Command::new("hdiutil").args(["create", "-quiet", "-layout", "NONE", "-fs", "Case-sensitive HFS+", "-volname", "iOSRoot", "-format", "UDTO", "-size", "8m", "-srcfolder"]).arg(&src).arg(d.join("py")));
    let size = fs::metadata(&pyraw).unwrap().len();
    fs::OpenOptions::new().write(true).open(&pyraw).unwrap().set_len(size - size % 4096).unwrap();
    run(py("hfsroot_owners.py").arg(&pyraw).args(["--map", "map.tsv", "--default-root"]).current_dir(&d));
    let pysimg = d.join("py.simg");
    run(py("img2simg.py").arg(&pyraw).arg(&pysimg));
    // Rust: mkhfs --map --default-root -> img2simg
    let rsraw = d.join("rs.img");
    run(Command::new(bin()).arg("mkhfs").arg(&src).arg(&rsraw).args(["--map", "map.tsv", "--default-root"]).current_dir(&d));
    let rssimg = d.join("rs.simg");
    run(Command::new(bin()).arg("img2simg").arg(&rsraw).arg(&rssimg));
    let mut paths = vec!["/".to_string()];
    let find = run(py("hfsx.py").arg(&pysimg).args(["find", ""]));
    paths.extend(find.lines().filter(|l| !l.contains('\0') && !l.contains("HFS+ Private")).map(String::from));
    assert!(paths.len() > 20, "{paths:?}");
    assert_eq!(ownership(&rssimg, &paths), ownership(&pysimg, &paths));
}

#[test]
fn root_build_from_a_folder() {
    if !have("python3") {
        return;
    }
    let d = tmpdir();
    let src = source_tree(&d);
    fs::create_dir_all(src.join(".fseventsd")).unwrap();
    fs::write(src.join(".fseventsd/junk"), b"x").unwrap();
    fs::create_dir_all(src.join("usr/standalone/update")).unwrap();
    fs::write(src.join("usr/standalone/update/ramdisk"), b"ota").unwrap();
    fs::copy(root().join("tests/fixtures/libpac.dylib"), src.join("usr/lib/libpac.dylib")).unwrap();
    // a bundle: its main executable is re-signed with the bundle sealed (CodeResources written into the image)
    let app = src.join("Applications/Demo.app");
    fs::create_dir_all(app.join("en.lproj")).unwrap();
    fs::write(app.join("Info.plist"), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>Demo</string>\n</dict>\n</plist>\n").unwrap();
    fs::write(app.join("en.lproj/Localizable.strings"), "x").unwrap();
    fs::copy(root().join("tests/fixtures/libpac.dylib"), app.join("Demo")).unwrap();
    let py_app = d.join("py/Demo.app");
    fs::create_dir_all(py_app.parent().unwrap()).unwrap();
    run(Command::new("cp").arg("-R").arg(&app).arg(&py_app));
    fs::write(d.join("map.tsv"), "usr/lib/libpac.dylib\t0\t0\t755\nusr\t0\t0\t755\n").unwrap();
    let simg = d.join("root.simg");
    run(Command::new(bin()).arg("root").arg(&src).arg(&simg).args(["--no-tweaks", "--map", "map.tsv", "--date", "1700000000"]).current_dir(&d));
    assert!(!d.join("root.img").exists(), "raw image consumed");
    let ls = |p: &str| run(py("hfsx.py").arg(&simg).args(["ls", p]));
    assert!(!ls("/").contains(".fseventsd"));
    assert!(!ls("/System/Library/Caches/com.apple.dyld").contains(".symbols"));
    assert!(!ls("/usr").contains("standalone") || !ls("/usr/standalone").contains("update"));
    let cryptex = run(py("hfsx.py").arg(&simg).args(["stat", "/private/preboot/Cryptexes/OS"]));
    assert!(cryptex.contains("mode 120"), "{cryptex}");
    // the Mach-Os in the image are pacstrip.py --sign's rewrite of the originals (macOS codesign; elsewhere
    // pacstrip.py signs with ldid, so only the signature's presence is checked)
    let cat = |p: &str| Command::new("python3").arg("-I").arg(root().join("../renegade/hfsx.py")).arg(&simg).args(["cat", p]).output().unwrap().stdout;
    if cfg!(target_os = "macos") && have("codesign") {
        let want = d.join("want.dylib");
        run(py("pacstrip.py").arg("--sign").arg(root().join("tests/fixtures/libpac.dylib")).arg("-o").arg(&want));
        assert!(cat("/usr/lib/libpac.dylib") == fs::read(&want).unwrap(), "re-signed Mach-O differs from pacstrip.py --sign's");
        run(py("pacstrip.py").arg("--sign").arg(py_app.join("Demo")));
        assert!(cat("/Applications/Demo.app/Demo") == fs::read(py_app.join("Demo")).unwrap(), "bundle executable differs");
        let cr = cat("/Applications/Demo.app/_CodeSignature/CodeResources");
        assert!(cr == fs::read(py_app.join("_CodeSignature/CodeResources")).unwrap(), "CodeResources differs");
    } else {
        assert!(renegade::codesign::identity(&cat("/usr/lib/libpac.dylib")).is_some());
    }
    let st = run(py("hfsx.py").arg(&simg).args(["stat", "/usr/lib/libpac.dylib"]));
    assert!(st.contains("uid,gid (0, 0) mode 100755"), "{st}");
    let st = run(py("hfsx.py").arg(&simg).args(["stat", "/usr/lib/hello.txt"]));
    assert!(st.contains("uid,gid (0, 0)"), "unmapped paths become root:wheel: {st}");
    if have("fsck_hfs") && have("hdiutil") {
        let raw = d.join("check.img");
        run(Command::new(bin()).arg("simg2img").arg(&simg).arg(&raw));
        let dev = attach(&raw, None);
        let o = Command::new("fsck_hfs").args(["-fn", &dev]).output().unwrap();
        detach(&dev);
        assert!(String::from_utf8_lossy(&o.stdout).contains("appears to be OK"), "{}", String::from_utf8_lossy(&o.stdout));
    }
}

#[test]
fn root_build_with_tweaks_matches_root_tweaks18() {
    if !have("python3") {
        return;
    }
    let d = tmpdir();
    let (src, py_root, tools) = (d.join("src"), d.join("py"), d.join("tools"));
    let script = root().join("tests/tweaks_fixture.py");
    for r in [&src, &py_root] {
        run(Command::new("python3").arg("-I").arg(&script).arg("make").arg(r).arg(&tools));
        fs::create_dir_all(r.join("System/Library/Caches/com.apple.dyld")).unwrap();
        fs::write(r.join("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"), b"cache").unwrap();
    }
    run(Command::new("python3").arg("-I").arg(&script).arg("run").arg(&py_root).arg(&tools));
    let simg = d.join("root.simg");
    run(Command::new(bin()).arg("root").arg(&src).arg(&simg).args(["--build", "22H352", "--version", "18.7.8", "--board", "N841", "--adt-target", "D22"])
        .arg("--netcfg").arg(tools.join("sweetnetcfg")).arg("--sweetreboot").arg(tools.join("sweetreboot")));
    let cat = |p: &str| Command::new("python3").arg("-I").arg(root().join("../renegade/hfsx.py")).arg(&simg).args(["cat", p]).output().unwrap().stdout;
    for p in [
        "System/Library/xpc/launchd.plist",
        "System/Library/LaunchDaemons/org.sweet.netcfg.plist",
        "private/var/preferences/SystemConfiguration/preferences.plist",
        "private/var/preferences/SystemConfiguration/NetworkInterfaces.plist",
        "private/var/mobile/Library/Preferences/com.apple.springboard.plist",
        "System/Library/Frameworks/MediaToolbox.framework/A/SubServerConfiguration.plist",
        "usr/local/share/renegade/register-apps",
        "private/var/keybags/systembag.kb",
    ] {
        assert!(cat(&format!("/{p}")) == fs::read(py_root.join(p)).unwrap(), "{p} in the image differs from root_tweaks18.py's");
    }
    let stat = |p: &str| run(py("hfsx.py").arg(&simg).args(["stat", p]));
    assert!(stat("/private/var/mobile/Library/Preferences/com.apple.springboard.plist").contains("uid,gid (501, 501) mode 100600"));
    assert!(stat("/Applications/Zed.app/Contents/Info.plist").contains("uid,gid (0, 0)"));
    assert!(stat("/private/var/db/diagnostics/.migrated").contains("uid,gid (272, 272) mode 100644"));
    assert!(stat("/usr/local/bin/sweetreboot").contains("uid,gid (0, 0) mode 100755"));
    if have("fsck_hfs") && have("hdiutil") {
        let raw = d.join("check.img");
        run(Command::new(bin()).arg("simg2img").arg(&simg).arg(&raw));
        let dev = attach(&raw, None);
        let o = Command::new("fsck_hfs").args(["-fn", &dev]).output().unwrap();
        detach(&dev);
        assert!(String::from_utf8_lossy(&o.stdout).contains("appears to be OK"), "{}", String::from_utf8_lossy(&o.stdout));
    }
}
