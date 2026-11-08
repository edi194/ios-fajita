//! `renegade-rs strip --sign` against `pacstrip.py --sign` (macOS `codesign`): byte-identical binaries and
//! bundle seals. Needs macOS with codesign and python3; each test is skipped (with a message) without them.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}
fn fixture(n: &str) -> PathBuf {
    root().join("tests/fixtures").join(n)
}

fn have_codesign() -> bool {
    let ok = cfg!(target_os = "macos")
        && Command::new("python3").arg("--version").output().map(|o| o.status.success()).unwrap_or(false)
        && Path::new("/usr/bin/codesign").exists();
    if !ok {
        eprintln!("macOS codesign or python3 not found: skipping the comparison with pacstrip.py --sign");
    }
    ok
}

fn tmpdir() -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("renegade-rs-cs-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

fn run(c: &mut Command) {
    let o = c.output().unwrap();
    assert!(o.status.success(), "{c:?} failed: {}", String::from_utf8_lossy(&o.stderr));
}

fn py_sign(f: &Path) {
    run(Command::new("python3").arg("-I").arg(root().join("../renegade/pacstrip.py")).arg("--sign").arg(f));
}

fn rs_sign(f: &Path) {
    run(Command::new(env!("CARGO_BIN_EXE_renegade-rs")).arg("strip").arg("--sign").arg(f));
}

fn codesign(f: &Path, args: &[&str]) {
    run(Command::new("codesign").args(["-f", "-s", "-"]).args(args).arg(f));
}

/// Every file and symlink under `d`, relative paths with their contents (a symlink as "-> target").
fn tree(d: &Path) -> Vec<(String, Vec<u8>)> {
    fn walk(base: &Path, d: &Path, out: &mut Vec<(String, Vec<u8>)>) {
        let mut es: Vec<_> = fs::read_dir(d).unwrap().map(|e| e.unwrap().path()).collect();
        es.sort();
        for p in es {
            let rel = p.strip_prefix(base).unwrap().to_string_lossy().into_owned();
            let m = fs::symlink_metadata(&p).unwrap();
            if m.file_type().is_symlink() {
                out.push((rel, format!("-> {}", fs::read_link(&p).unwrap().display()).into_bytes()));
            } else if m.is_dir() {
                walk(base, &p, out);
            } else {
                out.push((rel, fs::read(&p).unwrap()));
            }
        }
    }
    let mut v = Vec::new();
    walk(d, d, &mut v);
    v
}

fn assert_same_tree(a: &Path, b: &Path) {
    let (ta, tb) = (tree(a), tree(b));
    let names = |t: &[(String, Vec<u8>)]| t.iter().map(|x| x.0.clone()).collect::<Vec<_>>();
    assert_eq!(names(&ta), names(&tb), "file lists differ");
    for ((p, x), (_, y)) in ta.iter().zip(&tb) {
        assert!(x == y, "{p} differs between pacstrip.py --sign and renegade-rs strip --sign");
    }
}

/// Signs a copy of `src` with both tools (after `prep` signs it the way the input should be) and compares.
fn compare(name: &str, src: &Path, prep: &dyn Fn(&Path)) {
    let d = tmpdir();
    let (a, b) = (d.join(format!("py-{name}")), d.join(format!("rs-{name}")));
    fs::copy(src, &a).unwrap();
    prep(&a);
    fs::copy(&a, &b).unwrap();
    py_sign(&a);
    rs_sign(&b);
    assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "{name}: re-signed bytes differ");
}

const ENTS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>com.example.renegade</string>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.security.exception.mach-lookup.global-name</key>
	<array>
		<string>com.apple.a</string>
		<string>com.apple.b</string>
	</array>
	<key>com.apple.developer.nested</key>
	<dict>
		<key>count</key>
		<integer>300</integer>
		<key>off</key>
		<false/>
	</dict>
	<key>platform-application</key>
	<true/>
</dict>
</plist>
"#;

#[test]
fn linker_signed_binaries() {
    if !have_codesign() {
        return;
    }
    for f in ["exe", "libpac.dylib", "libfix.dylib"] {
        compare(f, &fixture(f), &|_| {});
    }
}

#[test]
fn identifier_options_and_entitlements_are_kept() {
    if !have_codesign() {
        return;
    }
    let d = tmpdir();
    let ents = d.join("ents.xml");
    fs::write(&ents, ENTS).unwrap();
    let e = ents.to_str().unwrap().to_string();
    compare("exe-ents", &fixture("exe"), &|p| codesign(p, &["-i", "com.example.renegade", "--entitlements", &e]));
    // hardened runtime: a 0x20500 CodeDirectory, the size codesign reserves is estimated from a 0x20400 one
    compare("exe-runtime", &fixture("exe"), &|p| {
        codesign(p, &["-i", "com.example.runtime", "-o", "runtime,library", "--entitlements", &e])
    });
    // a codesign-signed dylib with a long identifier: the new signature is smaller than the old space
    compare("lib-long-ident", &fixture("libpac.dylib"), &|p| codesign(p, &["-i", &"x".repeat(200)]));
}

#[test]
fn fat_binary() {
    if !have_codesign() {
        return;
    }
    let d = tmpdir();
    let (a, b, fat) = (d.join("a"), d.join("b"), d.join("fat"));
    // two slices: the fixture (arm64e) and the same code built for arm64
    let ok = Command::new("clang")
        .args(["-arch", "arm64", "-dynamiclib", "-o"])
        .arg(&b)
        .arg(fixture("pac.s"))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("clang cannot build arm64: skipping the fat binary test");
        return;
    }
    fs::copy(fixture("libpac.dylib"), &a).unwrap();
    run(Command::new("lipo").arg("-create").arg(&a).arg(&b).arg("-output").arg(&fat));
    compare("fat", &fat, &|p| codesign(p, &["-i", "com.example.fat"]));
}

/// A bundle: Info.plist, localised and Base.lproj resources, a locversion.plist (omitted), a .DS_Store (omitted
/// from files2), a symlink, a nested app extension (sealed first, hashed as plain files).
fn make_bundle(d: &Path, exe_key: bool) -> PathBuf {
    let b = d.join("Demo.app");
    fs::create_dir_all(b.join("en.lproj")).unwrap();
    fs::create_dir_all(b.join("Base.lproj")).unwrap();
    fs::create_dir_all(b.join("PlugIns/Ext.appex")).unwrap();
    let info = |id: &str, exe: &str| {
        let key = if exe_key { format!("\t<key>CFBundleExecutable</key>\n\t<string>{exe}</string>\n") } else { String::new() };
        format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n{key}\t<key>CFBundleIdentifier</key>\n\t<string>{id}</string>\n</dict>\n</plist>\n")
    };
    fs::write(b.join("Info.plist"), info("com.example.demo", "Demo")).unwrap();
    fs::write(b.join("PkgInfo"), "APPL????").unwrap();
    fs::write(b.join("en.lproj/Localizable.strings"), "\"a\" = \"b\";\n").unwrap();
    fs::write(b.join("en.lproj/locversion.plist"), "x").unwrap();
    fs::write(b.join("Base.lproj/Main.strings"), "base").unwrap();
    fs::write(b.join(".DS_Store"), "ds").unwrap();
    fs::write(b.join("data & <stuff>.txt"), "escaped").unwrap();
    std::os::unix::fs::symlink("en.lproj/Localizable.strings", b.join("link")).unwrap();
    fs::copy(fixture("exe"), b.join("Demo")).unwrap();
    let x = b.join("PlugIns/Ext.appex");
    fs::write(x.join("Info.plist"), info("com.example.demo.ext", "Ext")).unwrap();
    fs::copy(fixture("exe"), x.join("Ext")).unwrap();
    fs::write(x.join("res.bin"), [1u8, 2, 3]).unwrap();
    b
}

#[test]
fn bundles_are_sealed_like_codesign() {
    if !have_codesign() {
        return;
    }
    // without CFBundleExecutable, codesign takes the executable named after the bundle folder
    for exe_key in [true, false] {
        let d = tmpdir();
        let (a, b) = (make_bundle(&d.join("py"), exe_key), make_bundle(&d.join("rs"), exe_key));
        for (bundle, sign) in [(&a, py_sign as fn(&Path)), (&b, rs_sign as fn(&Path))] {
            // codesign-signed inputs, as on the image: nested code first, then the bundle
            codesign(&bundle.join("PlugIns/Ext.appex/Ext"), &["-i", "com.example.demo.ext"]);
            codesign(&bundle.join("Demo"), &["-i", "com.example.demo"]);
            sign(&bundle.join("PlugIns/Ext.appex/Ext"));
            sign(&bundle.join("Demo"));
        }
        assert!(b.join("_CodeSignature/CodeResources").exists());
        assert_same_tree(&a, &b);
    }
}
