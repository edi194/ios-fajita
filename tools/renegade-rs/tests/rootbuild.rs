//! The whole root build on a synthetic IPSW (macOS: hdiutil makes the three APFS images; our own content only):
//! zip -> APFS volumes merged (the OS volume on top) -> layout fixes -> tweaks -> Mach-O strip + re-sign ->
//! dyld cache stage -> sparse HFSX image, read back with the HFS reader.

#![cfg(target_os = "macos")]

use renegade::hfs::{Volume, FILE};
use renegade::io::FileAt;
use renegade::sparse::Sparse;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;

fn here() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn run(c: &mut Command) -> bool {
    c.output().map(|o| o.status.success()).unwrap_or(false)
}

/// A raw APFS container holding `populate`'s files (hdiutil), or None where hdiutil is missing.
fn make_apfs(work: &Path, tag: &str, populate: &dyn Fn(&Path)) -> Option<PathBuf> {
    let img = work.join(format!("{tag}.dmg"));
    if !run(Command::new("hdiutil").args(["create", "-size", "48m", "-layout", "NONE", "-fs", "APFS", "-volname", tag, "-type", "UDIF"]).arg(&img)) {
        return None;
    }
    let mnt = work.join(format!("mnt-{tag}"));
    fs::create_dir_all(&mnt).ok()?;
    if !run(Command::new("hdiutil").args(["attach", "-nobrowse", "-noverify", "-mountpoint"]).arg(&mnt).arg(&img)) {
        return None;
    }
    populate(&mnt);
    let _ = Command::new("sync").status();
    for _ in 0..10 {
        if run(Command::new("hdiutil").args(["detach"]).arg(&mnt)) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    if fs::read(&img).ok()?.get(32..36) != Some(b"NXSB") {
        let cdr = work.join(format!("{tag}.cdr"));
        if !run(Command::new("hdiutil").args(["convert", "-format", "UDTO", "-o"]).arg(&cdr).arg(&img)) {
            return None;
        }
        fs::rename(&cdr, &img).ok()?;
    }
    Some(img)
}

/// The smallest cache file the stage accepts: a header and no images, mappings or sub-caches.
fn fake_cache() -> Vec<u8> {
    let mut h = vec![0u8; 0x4000];
    h[..16].copy_from_slice(b"dyld_v1  arm64e\0");
    h[0x10..0x14].copy_from_slice(&0x200u32.to_le_bytes()); // mapping offset
    h[0x1C0..0x1C4].copy_from_slice(&0x300u32.to_le_bytes()); // images offset
    h
}

#[test]
fn synthetic_ipsw_builds_a_root() {
    if !run(Command::new("hdiutil").arg("help")) || !run(Command::new("python3").arg("--version")) {
        eprintln!("hdiutil or python3 missing: skipped");
        return;
    }
    let work = std::env::temp_dir().join(format!("renegade-rs-rootbuild-{}", std::process::id()));
    let _ = fs::remove_dir_all(&work);
    fs::create_dir_all(&work).unwrap();
    let fixtures = here().join("tests/fixtures");
    let tools = work.join("tools");
    let os = make_apfs(&work, "OS", &|m| {
        let o = Command::new("python3").arg("-I").arg(here().join("tests/tweaks_fixture.py")).arg("make").arg(m).arg(&tools).output().unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        fs::create_dir_all(m.join("usr/lib")).unwrap();
        fs::create_dir_all(m.join("private/etc")).unwrap();
        fs::write(m.join("private/etc/shells"), "/bin/bash\n").unwrap();
        fs::write(m.join("private/etc/passwd"), "root:*:0:0:System Administrator:/var/root:/bin/sh\n").unwrap();
        fs::copy(fixtures.join("libpac.dylib"), m.join("usr/lib/libpac.dylib")).unwrap();
        fs::write(m.join("usr/lib/both.txt"), "from the OS volume").unwrap();
        fs::write(m.join("usr/lib/hello.txt"), "hello").unwrap();
        fs::write(m.join("usr/lib/co:lon.txt"), "colon").unwrap();
        fs::hard_link(m.join("usr/lib/hello.txt"), m.join("usr/lib/hard.txt")).unwrap();
        std::os::unix::fs::symlink("/usr/lib/hello.txt", m.join("usr/lib/abs-link")).unwrap();
        let big: Vec<u8> = (0..3_000_000u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
        fs::write(m.join("usr/lib/big.bin"), &big).unwrap();
        // the cryptex mount points of the OS volume
        fs::create_dir_all(m.join("System/Cryptexes")).unwrap();
        std::os::unix::fs::symlink("../../private/preboot/Cryptexes/OS", m.join("System/Cryptexes/OS")).unwrap();
    });
    let sys = make_apfs(&work, "SYS", &|m| {
        fs::create_dir_all(m.join("System/Library/Caches/com.apple.dyld")).unwrap();
        fs::write(m.join("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"), fake_cache()).unwrap();
        fs::write(m.join("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.symbols"), b"symbols").unwrap();
    });
    let app = make_apfs(&work, "APP", &|m| {
        fs::create_dir_all(m.join("usr/lib")).unwrap();
        fs::write(m.join("usr/lib/both.txt"), "from the AppOS cryptex").unwrap();
        fs::write(m.join("usr/lib/only-app.txt"), "app").unwrap();
    });
    let (Some(os), Some(sys), Some(app)) = (os, sys, app) else {
        eprintln!("hdiutil could not make the images: skipped");
        let _ = fs::remove_dir_all(&work);
        return;
    };
    // the IPSW: a stored zip with the manifest and the three images
    let manifest = work.join("BuildManifest.plist");
    fs::write(
        &manifest,
        r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>ProductVersion</key><string>18.7.8</string><key>ProductBuildVersion</key><string>22H352</string>
<key>SupportedProductTypes</key><array><string>iPhone11,8</string></array>
<key>BuildIdentities</key><array><dict><key>Manifest</key><dict>
<key>OS</key><dict><key>Info</key><dict><key>Path</key><string>os.dmg</string></dict></dict>
<key>Cryptex1,SystemOS</key><dict><key>Info</key><dict><key>Path</key><string>sys.dmg</string></dict></dict>
<key>Cryptex1,AppOS</key><dict><key>Info</key><dict><key>Path</key><string>app.dmg</string></dict></dict>
</dict></dict></array></dict></plist>"#,
    )
    .unwrap();
    let ipsw = work.join("test.ipsw");
    let zipper = "import sys,zipfile\nz=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_STORED)\nfor a in sys.argv[2:]:\n    n,p=a.split('=',1)\n    z.write(p,n)\nz.close()\n";
    assert!(run(Command::new("python3").args(["-I", "-c", zipper]).arg(&ipsw).arg(format!("BuildManifest.plist={}", manifest.display())).arg(format!("os.dmg={}", os.display())).arg(format!("sys.dmg={}", sys.display())).arg(format!("app.dmg={}", app.display()))));

    if let Some(keep) = std::env::var_os("RENEGADE_KEEP_SYNTH_IPSW") {
        fs::copy(&ipsw, keep).unwrap(); // for the browser tests (apps/web/test/wasm.test.ts)
    }
    let ip = renegade::ipsw::Ipsw::open(Rc::new(FileAt::open(&ipsw).unwrap())).unwrap();
    assert_eq!((ip.manifest.device.as_str(), ip.manifest.build.as_str()), ("iPhone11,8", "22H352"));
    let mut cfg = renegade::rootbuild::Config { now: 1_700_000_000, volume_size: Some(64 << 20), ..Default::default() };
    let mut log = Vec::new();
    let (out, sum) = renegade::rootbuild::build(&ip, &mut cfg, Cursor::new(Vec::new()), &mut |e| {
        if let renegade::rootbuild::Event::Log(l) = e {
            log.push(l.to_string());
        }
    })
    .unwrap();
    eprintln!("{}", log.join("\n"));
    assert!(sum.machos >= 1 && sum.signed >= 1, "{sum:?}");
    // read the image back
    let simg = out.into_inner();
    let img_path = work.join("root.simg");
    fs::write(&img_path, &simg).unwrap();
    let v = Volume::open(Sparse::open(FileAt::open(&img_path).unwrap()).unwrap()).unwrap();
    let read = |p: &str| {
        let e = v.lookup(p, false).unwrap().unwrap_or_else(|| panic!("{p} is not in the image"));
        assert_eq!(e.rt, FILE, "{p}");
        v.read_file(e).unwrap()
    };
    assert_eq!(read("usr/lib/both.txt"), b"from the OS volume", "the OS volume goes on top of the cryptexes");
    assert_eq!(read("usr/lib/only-app.txt"), b"app");
    assert_eq!(read("usr/lib/hard.txt"), b"hello");
    assert!(v.lookup("usr/lib/abs-link", false).unwrap().is_some());
    assert!(v.lookup("private/preboot/Cryptexes/OS", false).unwrap().is_some(), "cryptex mount points");
    assert!(v.lookup("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.symbols", false).unwrap().is_none(), ".symbols is dropped");
    assert!(v.lookup("Applications/Zed.app", false).unwrap().is_some(), "staged apps moved to /Applications (tweaks)");
    // the Mach-O was rewritten and re-signed: a scan finds no PAC left, and it has a signature
    let mut lib = read("usr/lib/libpac.dylib");
    let rep = renegade::pacstrip::strip(&mut lib, &renegade::pacstrip::Options { write: false, ..Default::default() }).unwrap();
    // what pacstrip only reports (FJCVTZS, unencodable LDRA words) stays; nothing it would rewrite is left
    assert!(rep.counts.keys().all(|k| k.contains("(left)") || k.contains("unencodable")), "PAC left: {:?}", rep.counts);
    assert!(renegade::codesign::identity(&lib).is_some(), "re-signed");
    let big = read("usr/lib/big.bin");
    assert_eq!(big.len(), 3_000_000);
    // fsck_hfs is happy with the volume
    let raw = work.join("root.img");
    {
        use std::io::{Seek, SeekFrom, Write};
        let sp = Sparse::open(FileAt::open(&img_path).unwrap()).unwrap();
        let mut f = fs::File::create(&raw).unwrap();
        renegade::sparse::simg2img(&sp, |off, b| {
            f.seek(SeekFrom::Start(off))?;
            f.write_all(b)
        })
        .unwrap();
    }
    let o = Command::new("hdiutil").args(["attach", "-nomount", "-noverify", "-readonly"]).arg(&raw).output().unwrap();
    if o.status.success() {
        let dev = String::from_utf8_lossy(&o.stdout).split_whitespace().next().unwrap().to_string();
        let f = Command::new("fsck_hfs").args(["-fn", &dev.replace("/dev/disk", "/dev/rdisk")]).output().unwrap();
        // names with a colon go through the catalog's colon/slash swap and read back as they were
        let mnt = work.join("mnt-root");
        fs::create_dir_all(&mnt).unwrap();
        let _ = Command::new("hdiutil").args(["detach", &dev]).output();
        let o = Command::new("hdiutil").args(["attach", "-readonly", "-nobrowse", "-noverify", "-mountpoint"]).arg(&mnt).arg(&raw).output().unwrap();
        if o.status.success() {
            let got = fs::read(mnt.join("usr/lib/co:lon.txt"));
            let _ = Command::new("hdiutil").args(["detach"]).arg(&mnt).output();
            assert_eq!(got.unwrap(), b"colon");
        } else {
            eprintln!("could not mount the image read-only: {}", String::from_utf8_lossy(&o.stderr));
        }
        let text = format!("{}{}", String::from_utf8_lossy(&f.stdout), String::from_utf8_lossy(&f.stderr));
        assert!(f.status.success() && text.contains("appears to be OK"), "fsck_hfs:\n{text}");
    }
    // the same IPSW with a tools bundle and an SSH key: the SSH server, its key and the first-boot job are in the image
    let tools_zip = work.join("berga-tools.zip");
    let mk = "import sys,zipfile,hashlib,json\nz=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_DEFLATED)\nfiles=[]\nfor n,d in [('ssh/dropbear',b'db\\0'),('ssh/dash',b'sh'),('ssh/toybox',b'tb\\0ls\\0cat\\0'),('sweetnet/sweetnetcfg',b'cfg'),('sweetnet/ios18/sweetuicache',b'uic')]:\n    z.writestr(n,d); files.append({'path':n,'sha256':hashlib.sha256(d).hexdigest()})\nz.writestr('berga-tools.json',json.dumps({'files':files}))\nz.close()\n";
    assert!(run(Command::new("python3").args(["-I", "-c", mk]).arg(&tools_zip)));
    let mut cfg = renegade::rootbuild::Config { now: 1_700_000_000, volume_size: Some(64 << 20), ..Default::default() };
    cfg.tools = Some(renegade::tools::Tools::from_zip(Rc::new(FileAt::open(&tools_zip).unwrap())).unwrap());
    cfg.ssh_key = Some("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey me@laptop".into());
    let (out2, _) = renegade::rootbuild::build(&ip, &mut cfg, Cursor::new(Vec::new()), &mut |_| {}).unwrap();
    let img2 = work.join("root2.simg");
    fs::write(&img2, out2.into_inner()).unwrap();
    let v2 = Volume::open(Sparse::open(FileAt::open(&img2).unwrap()).unwrap()).unwrap();
    let read2 = |p: &str| v2.read_file(v2.lookup(p, false).unwrap().unwrap_or_else(|| panic!("{p} is not in the image"))).unwrap();
    assert_eq!(read2("usr/local/bin/dropbear"), b"db\0");
    assert_eq!(read2("bin/sh"), b"sh");
    assert_eq!(read2("private/var/root/.ssh/authorized_keys"), b"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey me@laptop\n");
    assert!(read2("private/etc/shells").ends_with(b"/bin/sh\n"));
    assert!(v2.lookup("usr/local/bin/ls", false).unwrap().is_some(), "toybox applets are linked");
    assert!(v2.lookup("usr/local/libexec/renegade-firstboot.sh", false).unwrap().is_some());
    let _ = fs::remove_dir_all(&work);
}
