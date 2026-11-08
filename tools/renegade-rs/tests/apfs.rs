//! The APFS reader against ground truth: a real Apple container (RENEGADE_TEST_APFS, skipped when
//! unset; Apple's file, never copied anywhere) and synthetic volumes made with hdiutil (macOS only),
//! each compared with what the OS shows when it mounts the same image: lstat of every name (mode,
//! owner, size, mtime, nlink, inode), symlink targets and the bytes of every file.

use renegade::apfs::*;
use renegade::io::{FileAt, ReadAt};

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use std::collections::{BTreeMap, HashMap};
    use std::os::unix::fs::{FileExt, MetadataExt};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    pub fn have_hdiutil() -> bool {
        Command::new("hdiutil").arg("help").output().is_ok()
    }

    /// A mount of an image, detached on drop.
    pub struct Mounted {
        pub dir: PathBuf,
        dev: String,
    }

    impl Mounted {
        pub fn attach(img: &Path, mountpoint: &Path, readonly: bool) -> Option<Mounted> {
            std::fs::create_dir_all(mountpoint).ok()?;
            for raw in [false, true] {
                let mut c = Command::new("hdiutil");
                c.args(["attach", "-nobrowse", "-noverify", "-owners", "on", "-mountpoint"]).arg(mountpoint);
                if readonly {
                    c.arg("-readonly");
                }
                if raw {
                    c.args(["-imagekey", "diskimage-class=CRawDiskImage"]);
                }
                c.arg(img);
                let o = c.output().ok()?;
                if o.status.success() {
                    let out = String::from_utf8_lossy(&o.stdout).to_string();
                    let dev = out.lines().next()?.split_whitespace().next()?.to_string();
                    return Some(Mounted { dir: mountpoint.to_path_buf(), dev });
                }
            }
            None
        }
    }

    impl Drop for Mounted {
        fn drop(&mut self) {
            for _ in 0..5 {
                if Command::new("hdiutil").args(["detach", "-force"]).arg(&self.dev).output().map(|o| o.status.success()).unwrap_or(false) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
            let _ = std::fs::remove_dir(&self.dir);
        }
    }

    #[derive(Default, Debug)]
    pub struct Report {
        pub names: usize,
        pub files: usize,
        pub bytes: u64,
        pub mismatches: Vec<String>,
        pub unreadable: usize,
        pub hardlink_groups: usize,
        pub compressed: BTreeMap<u32, usize>,
    }

    fn walk_mount(root: &Path, rel: &str, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(root.join(rel)) else { return };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let p = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            out.push(p.clone());
            if is_dir {
                walk_mount(root, &p, out);
            }
        }
    }

    /// Compares the reader's view of `image` with the OS's view of a mount of it.
    pub fn compare(image: &Path, work: &Path, tag: &str, check_data: bool) -> Report {
        let m = Mounted::attach(image, &work.join(format!("mnt-{tag}")), true).expect("attach");
        let c = Container::open(FileAt::open(image).unwrap()).unwrap();
        let vol = c.volume(0).unwrap();
        let mut rep = Report::default();
        let mut mine: HashMap<String, ()> = HashMap::new();
        let mut inodes: HashMap<u64, u32> = HashMap::new();
        let mut files: Vec<(String, u64, u64)> = Vec::new();
        vol.walk(&mut |n| {
            rep.names += 1;
            if !n.path.is_empty() {
                mine.insert(n.path.to_string(), ());
            }
            let md = match std::fs::symlink_metadata(m.dir.join(n.path)) {
                Ok(md) => md,
                Err(e) => {
                    rep.mismatches.push(format!("{}: not on the mount ({e})", n.path));
                    return Ok(());
                }
            };
            let mut diff = |what: &str, a: String, b: String| {
                if a != b && rep.mismatches.len() < 50 {
                    rep.mismatches.push(format!("{}: {what}: reader {a}, mount {b}", n.path));
                }
            };
            let fmt = md.mode() & 0o170000;
            let kind = match n.kind {
                Kind::Dir => 0o040000,
                Kind::File => 0o100000,
                Kind::Symlink => 0o120000,
                Kind::Other(m) => m as u32,
            };
            diff("type", format!("{kind:o}"), format!("{fmt:o}"));
            diff("mode", format!("{:o}", n.mode), format!("{:o}", md.mode() & 0o7777));
            diff("uid", n.uid.to_string(), md.uid().to_string());
            diff("gid", n.gid.to_string(), md.gid().to_string());
            diff("mtime", n.mtime.to_string(), md.mtime().to_string());
            diff("ino", n.ino.to_string(), md.ino().to_string());
            diff("nlink", n.nlink.to_string(), md.nlink().to_string());
            match n.kind {
                Kind::File => {
                    diff("size", n.size.to_string(), md.size().to_string());
                    files.push((n.path.to_string(), n.ino, n.size));
                    if n.compression != 0 {
                        *rep.compressed.entry(n.compression).or_default() += 1;
                    }
                }
                Kind::Symlink => {
                    let t = std::fs::read_link(m.dir.join(n.path)).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
                    diff("target", n.target.unwrap_or("<none>").to_string(), t);
                    diff("size", n.size.to_string(), md.size().to_string());
                }
                _ => {}
            }
            if n.kind != Kind::Dir && md.nlink() > 1 {
                *inodes.entry(n.ino).or_default() += 1;
            }
            Ok(())
        })
        .unwrap();
        rep.hardlink_groups = inodes.values().filter(|&&c| c > 1).count();
        // names on the mount that the reader did not list
        let mut theirs = Vec::new();
        walk_mount(&m.dir, "", &mut theirs);
        for p in &theirs {
            if !mine.contains_key(p) && rep.mismatches.len() < 50 {
                rep.mismatches.push(format!("{p}: on the mount, not listed by the reader"));
            }
        }
        if theirs.len() != mine.len() && rep.mismatches.len() < 50 {
            rep.mismatches.push(format!("name count: reader {}, mount {}", mine.len(), theirs.len()));
        }
        // file contents
        if check_data {
            for (path, ino, size) in &files {
                let f = vol.open_file(*ino).unwrap_or_else(|e| panic!("{path}: open: {e}"));
                assert_eq!(f.size(), *size);
                let Ok(real) = std::fs::File::open(m.dir.join(path)) else {
                    rep.unreadable += 1;
                    continue;
                };
                let mut off = 0u64;
                let mut a = vec![0u8; 1 << 20];
                let mut b = vec![0u8; 1 << 20];
                let mut ok = true;
                while off < *size {
                    let n = ((*size - off) as usize).min(a.len());
                    if real.read_exact_at(&mut b[..n], off).is_err() {
                        rep.unreadable += 1;
                        ok = false;
                        break;
                    }
                    f.read_at(off, &mut a[..n]).unwrap_or_else(|e| panic!("{path}: read at {off}: {e}"));
                    if a[..n] != b[..n] {
                        rep.mismatches.push(format!("{path}: content differs near byte {off}"));
                        ok = false;
                        break;
                    }
                    off += n as u64;
                }
                if ok {
                    rep.files += 1;
                    rep.bytes += size;
                }
            }
        }
        rep
    }

    /// Removes the scratch directory when the test ends, panics included.
    pub struct Cleanup(pub PathBuf);

    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    pub fn work_dir(name: &str) -> PathBuf {
        let base = std::env::var("RENEGADE_TEST_TMP").map(PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
        let d = base.join(format!("renegade-apfs-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Creates an empty APFS image of `mb` MB (a raw container at offset 0), fills it with `populate`
    /// while mounted writable, detaches it and returns its path.
    pub fn make_image(work: &Path, tag: &str, case_sensitive: bool, mb: u32, populate: &dyn Fn(&Path)) -> Option<PathBuf> {
        let img = work.join(format!("{tag}.dmg"));
        let fs = if case_sensitive { "Case-sensitive APFS" } else { "APFS" };
        let o = Command::new("hdiutil")
            .args(["create", "-size", &format!("{mb}m"), "-layout", "NONE", "-fs", fs, "-volname", "T", "-type", "UDIF"])
            .arg(&img)
            .output()
            .ok()?;
        if !o.status.success() {
            return None;
        }
        {
            let m = Mounted::attach(&img, &work.join(format!("w-{tag}")), false)?;
            populate(&m.dir);
            let _ = Command::new("sync").status();
        }
        // a raw container has "NXSB" at byte 0x20
        let head = std::fs::read(&img).ok()?;
        if head.get(32..36) != Some(b"NXSB") {
            let cdr = work.join(format!("{tag}.cdr"));
            let o = Command::new("hdiutil").args(["convert", "-format", "UDTO", "-o"]).arg(&cdr).arg(&img).output().ok()?;
            if !o.status.success() {
                return None;
            }
            std::fs::rename(&cdr, &img).ok()?;
        }
        Some(img)
    }

    pub fn sh(cmd: &str) {
        let o = Command::new("sh").arg("-c").arg(cmd).output().unwrap();
        assert!(o.status.success(), "{cmd}: {}", String::from_utf8_lossy(&o.stderr));
    }
}

#[cfg(target_os = "macos")]
mod synth {
    use super::mac::*;
    use std::io::Write;
    use std::os::unix::fs::{FileExt, PermissionsExt, symlink};
    use std::path::Path;

    fn pseudo(n: usize, seed: u64) -> Vec<u8> {
        let mut x = seed.wrapping_mul(0x9e3779b97f4a7c15) | 1;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 24) as u8
            })
            .collect()
    }

    fn text(n: usize) -> Vec<u8> {
        let line = b"the quick brown fox jumps over the lazy dog 0123456789 \n";
        line.iter().cycle().take(n).copied().collect()
    }

    pub fn populate(root: &Path, case_sensitive: bool, src: &Path) {
        let w = |p: &str, d: &[u8]| {
            let p = root.join(p);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, d).unwrap();
        };
        // plain files of awkward sizes
        for (i, n) in [0usize, 1, 511, 4095, 4096, 4097, 65535, 65536, 65537, 1 << 20, (3 << 20) + 17].into_iter().enumerate() {
            w(&format!("sizes/f{n}"), &pseudo(n, i as u64 + 1));
        }
        // names
        w("names/with space/ünï cödé.txt", b"unicode");
        w("names/日本語/ファイル.txt", b"cjk");
        w("names/emoji-\u{1F600}", b"emoji");
        w("names/Mixed Case/UPPER", b"u");
        w("names/Mixed Case/lower", b"l");
        w("names/.hidden", b"h");
        w("names/long-".to_string().as_str(), b"x");
        w(&format!("names/{}", "n".repeat(250)), b"255-ish");
        if case_sensitive {
            w("names/cs/Abc", b"1");
            w("names/cs/abc", b"2");
            w("names/cs/e\u{301}", b"nfd");
            w("names/cs/\u{e9}", b"nfc");
        }
        // permissions
        for (n, m) in [("m4755", 0o4755), ("m2755", 0o2755), ("m0600", 0o600), ("m0000", 0o000), ("m0444", 0o444)] {
            w(&format!("perm/{n}"), b"p");
            std::fs::set_permissions(root.join("perm").join(n), std::fs::Permissions::from_mode(m)).unwrap();
        }
        std::fs::create_dir_all(root.join("perm/sticky")).unwrap();
        std::fs::set_permissions(root.join("perm/sticky"), std::fs::Permissions::from_mode(0o1777)).unwrap();
        // fragmented multi-extent files: two files grown alternately
        {
            let mut a = std::fs::File::create(root.join("frag-a")).unwrap();
            let mut b = std::fs::File::create(root.join("frag-b")).unwrap();
            for i in 0..300u64 {
                a.write_all(&pseudo(10_000, i)).unwrap();
                a.sync_all().unwrap();
                b.write_all(&pseudo(7_000, i + 1000)).unwrap();
                b.sync_all().unwrap();
            }
        }
        // sparse files: holes between written islands, and a hole at the end
        {
            let f = std::fs::File::create(root.join("sparse")).unwrap();
            f.set_len(300 << 20).unwrap();
            f.write_all_at(b"head", 0).unwrap();
            f.write_all_at(&pseudo(20_000, 5), 100 << 20).unwrap();
            f.write_all_at(b"tail", (300 << 20) - 4).unwrap();
            let g = std::fs::File::create(root.join("sparse-hole-only")).unwrap();
            g.set_len(10 << 20).unwrap();
        }
        // links
        w("links/target", b"hard link target");
        std::fs::create_dir_all(root.join("links/d1/d2")).unwrap();
        std::fs::hard_link(root.join("links/target"), root.join("links/d1/second")).unwrap();
        std::fs::hard_link(root.join("links/target"), root.join("links/d1/d2/third")).unwrap();
        w("links/other", b"o");
        std::fs::hard_link(root.join("links/other"), root.join("links/other2")).unwrap();
        symlink("target", root.join("links/rel")).unwrap();
        symlink("/abs/path/elsewhere", root.join("links/abs")).unwrap();
        symlink("does-not-exist", root.join("links/dangling")).unwrap();
        symlink("d1/d2", root.join("links/dirlink")).unwrap();
        symlink("é".repeat(400), root.join("links/long")).unwrap();
        // special files
        sh(&format!("mkfifo '{}'", root.join("links/fifo").display()));
        // (bound from inside the directory: the mount path is longer than a socket path may be)
        sh(&format!("cd '{}' && python3 -c \"import socket; socket.socket(socket.AF_UNIX).bind('sock')\"", root.join("links").display()));
        // clone, then change the middle of the clone
        w("clone/orig", &pseudo(1 << 20, 77));
        sh(&format!("cp -c '{}' '{}'", root.join("clone/orig").display(), root.join("clone/copy").display()));
        {
            let f = std::fs::OpenOptions::new().write(true).open(root.join("clone/copy")).unwrap();
            f.write_all_at(&pseudo(5000, 78), 300_000).unwrap();
        }
        // extended attributes (the reader skips them)
        w("xattr/file", b"has xattrs");
        sh(&format!("xattr -w user.test value '{}'", root.join("xattr/file").display()));
        // many names: a multi-level file-system tree
        for d in 0..40 {
            for i in 0..200 {
                std::fs::create_dir_all(root.join(format!("many/d{d:03}"))).unwrap();
                std::fs::File::create(root.join(format!("many/d{d:03}/file-{i:05}-with-a-longish-name"))).unwrap();
            }
        }
        // compressed with ditto (zlib in the attribute, zlib in the resource fork)
        let d = root.join("compressed");
        std::fs::create_dir_all(&d).unwrap();
        let mut cases: Vec<(String, Vec<u8>)> = vec![
            ("tiny.txt".into(), text(100)),
            ("small.txt".into(), text(3000)),
            ("empty.txt".into(), Vec::new()),
            ("exact64k.txt".into(), text(65536)),
            ("over64k.txt".into(), text(65537)),
            ("big.txt".into(), text(3 << 20)),
            ("random.bin".into(), pseudo(300_000, 9)),
            ("mixed.bin".into(), [text(70_000), pseudo(70_000, 3), text(50_000)].concat()),
        ];
        cases.push(("zeros.bin".into(), vec![0u8; 500_000]));
        for (n, data) in &cases {
            std::fs::write(src.join(n), data).unwrap();
        }
        sh(&format!("ditto --hfsCompression '{}' '{}'", src.display(), d.display()));
    }
}

#[cfg(target_os = "macos")]
fn synthetic(case_sensitive: bool, tag: &str) {
    use mac::*;
    if !have_hdiutil() {
        return;
    }
    let work = work_dir(tag);
    let _guard = Cleanup(work.clone());
    let src = work.join("src");
    std::fs::create_dir_all(&src).unwrap();
    let Some(img) = make_image(&work, tag, case_sensitive, 200, &|root| synth::populate(root, case_sensitive, &src)) else {
        eprintln!("hdiutil could not make the image; skipped");
        return;
    };
    let rep = compare(&img, &work, tag, true);
    println!("{rep:#?}");
    assert!(rep.mismatches.is_empty(), "{:#?}", rep.mismatches);
    assert!(rep.hardlink_groups >= 2);
    assert_eq!(rep.unreadable, 1, "only the mode-000 file is unreadable on the mount");

    let c = Container::open(FileAt::open(&img).unwrap()).unwrap();
    let vols = c.volumes().unwrap();
    assert_eq!(vols.len(), 1);
    assert_eq!(vols[0].name, "T");
    assert_eq!(vols[0].case_insensitive, !case_sensitive);
    assert!(!vols[0].sealed && !vols[0].encrypted);
    let v = c.volume(0).unwrap();
    let st = v.fsck_stats().unwrap();
    println!("{st}");
    assert!(st.consistent(), "{st}");
    assert!(st.hardlink_groups >= 2);
    assert!(st.symlinks >= 5);
    assert!(st.others >= 2, "fifo and socket");
    assert!(st.sparse_extents > 0 || st.file_extents > 0);
    println!("compressed types seen: {:?}", st.compressed);
    assert!(!st.compressed.is_empty(), "ditto --hfsCompression made no compressed file");

    // lookup, read_link, read_dir
    let big = v.lookup("compressed/big.txt").unwrap().unwrap();
    assert_eq!(big.size, 3 << 20);
    assert_ne!(big.compression, 0);
    let t = v.lookup("links/target").unwrap().unwrap();
    assert_eq!(t.nlink, 3);
    assert_eq!(v.lookup("links/d1/second").unwrap().unwrap().ino, t.ino);
    assert_eq!(v.lookup("links/d1/d2/third").unwrap().unwrap().ino, t.ino);
    assert!(v.lookup("links/nothing").unwrap().is_none());
    assert!(v.lookup("links/target/x").unwrap().is_none());
    assert_eq!(v.lookup("").unwrap().unwrap().ino, 2);
    let rel = v.lookup("links/rel").unwrap().unwrap();
    assert_eq!(rel.kind, Kind::Symlink);
    assert_eq!(v.read_link(rel.ino).unwrap(), "target");
    assert_eq!(v.lookup("Names/MIXED case/Upper").unwrap().is_some(), !case_sensitive);
    assert_eq!(v.read_dir(v.lookup("many/d007").unwrap().unwrap().ino).unwrap().len(), 200);
    assert_eq!(v.lookup("names/cs/Abc").unwrap().is_some(), case_sensitive);

    // random access into a multi-extent file, a sparse file and compressed files
    let sp = v.lookup("sparse").unwrap().unwrap();
    assert_eq!(sp.size, 300 << 20);
    let f = v.open_file(sp.ino).unwrap();
    let mut b = vec![0xffu8; 4];
    f.read_at(0, &mut b).unwrap();
    assert_eq!(&b, b"head");
    f.read_at((300 << 20) - 4, &mut b).unwrap();
    assert_eq!(&b, b"tail");
    let mut z = vec![0xffu8; 1 << 20];
    f.read_at(50 << 20, &mut z).unwrap();
    assert!(z.iter().all(|&x| x == 0), "hole reads as zeros");
    let mut over = vec![0u8; 10];
    assert!(f.read_at((300 << 20) - 5, &mut over).is_err(), "reads past the end fail");
    let hole = v.open_file(v.lookup("sparse-hole-only").unwrap().unwrap().ino).unwrap();
    let mut z = vec![1u8; 4096];
    hole.read_at(5 << 20, &mut z).unwrap();
    assert!(z.iter().all(|&x| x == 0));
    assert!(v.open_file(2).is_err(), "directories cannot be opened as files");
    drop(c);
    let _ = std::fs::remove_dir_all(&work);
}

#[cfg(target_os = "macos")]
#[test]
fn synthetic_case_insensitive_matches_mount() {
    synthetic(false, "ci");
}

#[cfg(target_os = "macos")]
#[test]
fn synthetic_case_sensitive_matches_mount() {
    synthetic(true, "cs");
}

fn real_image() -> Option<String> {
    std::env::var("RENEGADE_TEST_APFS").ok().filter(|p| std::path::Path::new(p).exists())
}

/// The real iOS 26 AppOS cryptex container: sealed volume, hashed fs-tree, file extents in the fext
/// tree, LZBITMAP (type 14) and raw (type 9) compressed files; compared with a read-only mount.
#[cfg(target_os = "macos")]
#[test]
fn real_container_matches_mount() {
    let Some(p) = real_image() else { return };
    if !mac::have_hdiutil() {
        return;
    }
    let work = mac::work_dir("real");
    let _guard = mac::Cleanup(work.clone());
    let rep = mac::compare(std::path::Path::new(&p), &work, "real", true);
    println!("{rep:#?}");
    assert!(rep.mismatches.is_empty(), "{:#?}", rep.mismatches);
    assert!(rep.names > 1000);
    assert!(rep.compressed.get(&14).copied().unwrap_or(0) > 100, "expected LZBITMAP files");
    assert_eq!(rep.unreadable, 0);
    let _ = std::fs::remove_dir_all(work);
}

#[test]
fn real_container_stats_are_consistent() {
    let Some(p) = real_image() else { return };
    let c = Container::open(FileAt::open(&p).unwrap()).unwrap();
    let vols = c.volumes().unwrap();
    assert!(!vols.is_empty());
    let v = c.volume(vols[0].index).unwrap();
    let s = v.fsck_stats().unwrap();
    println!("{s}");
    assert!(s.consistent(), "{s}");
    assert!(v.info().sealed);
    assert!(v.snapshots().unwrap().is_empty());
    assert!(v.at_snapshot(1).is_err());
}

// ---- corrupt input: errors, never panics or runaway allocations ----

fn fletcher64(b: &[u8]) -> u64 {
    const M: u64 = 0xffff_ffff;
    let (mut s1, mut s2) = (0u64, 0u64);
    for w in b.chunks_exact(4) {
        s1 = (s1 + u32::from_le_bytes([w[0], w[1], w[2], w[3]]) as u64) % M;
        s2 = (s2 + s1) % M;
    }
    let c1 = M - (s1 + s2) % M;
    let c2 = M - (s1 + c1) % M;
    c2 << 32 | c1
}

/// Opens the image and exercises every code path; any outcome but a panic is acceptable.
fn exercise(img: Vec<u8>) {
    let Ok(c) = Container::open(img) else { return };
    let Ok(vols) = c.volumes() else { return };
    for vi in vols {
        let Ok(v) = c.volume(vi.index) else { continue };
        let _ = v.fsck_stats();
        let mut inos = Vec::new();
        let _ = v.walk(&mut |n| {
            if n.kind == Kind::File && inos.len() < 3000 {
                inos.push(n.ino);
            }
            Ok(())
        });
        let _ = v.lookup("System/Library");
        let _ = v.read_dir(2);
        for ino in inos {
            if let Ok(f) = v.open_file(ino) {
                let n = f.size().min(1 << 20) as usize;
                let mut b = vec![0u8; n];
                let _ = f.read_at(0, &mut b);
            }
        }
    }
}

#[test]
fn garbage_inputs_do_not_panic() {
    exercise(Vec::new());
    exercise(vec![0u8; 1 << 16]);
    let mut x = 0x1234_5678_9abc_def1u64;
    let rnd: Vec<u8> = (0..1 << 20)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect();
    exercise(rnd.clone());
    // a plausible superblock followed by noise
    let mut sb = rnd;
    sb[32..36].copy_from_slice(b"NXSB");
    sb[36..40].copy_from_slice(&4096u32.to_le_bytes());
    let ck = fletcher64(&sb[8..4096]);
    sb[..8].copy_from_slice(&ck.to_le_bytes());
    exercise(sb);
}

#[test]
fn mutated_real_container_does_not_panic() {
    let Some(p) = real_image() else { return };
    let base = std::fs::read(&p).unwrap();
    let nblocks = base.len() / 4096;
    let used: Vec<usize> = (0..nblocks).filter(|&b| base[b * 4096..(b + 1) * 4096].iter().any(|&x| x != 0)).collect();
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    let mut next = move || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let started = std::time::Instant::now();
    for iter in 0..400 {
        let mut img = base.clone();
        let mut touched = Vec::new();
        for _ in 0..1 + next() % 6 {
            let blk = used[(next() % used.len() as u64) as usize];
            let off = blk * 4096 + (next() % 4096) as usize;
            // biased to the header and table areas, where the structure is
            let off = if next() % 2 == 0 { blk * 4096 + (next() % 128) as usize } else { off };
            img[off] = match next() % 3 {
                0 => 0xff,
                1 => 0,
                _ => next() as u8,
            };
            touched.push(blk);
        }
        // keep the checksum valid where the block had one, so the parsers see the damage
        for blk in touched {
            let r = blk * 4096..(blk + 1) * 4096;
            if base[r.clone()][8..].len() % 4 == 0
                && u64::from_le_bytes(base[r.start..r.start + 8].try_into().unwrap()) == fletcher64(&base[r.start + 8..r.end])
            {
                let ck = fletcher64(&img[r.start + 8..r.end]);
                img[r.start..r.start + 8].copy_from_slice(&ck.to_le_bytes());
            }
        }
        let r = std::panic::catch_unwind(|| exercise(img));
        assert!(r.is_ok(), "iteration {iter} panicked");
    }
    println!("400 mutated images in {:?}", started.elapsed());
}

/// Listing and read speed on a bigger volume: `RENEGADE_TEST_PERF=files cargo test --release --test apfs perf -- --ignored --nocapture`
#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn perf_big_synthetic() {
    use mac::*;
    let Some(n) = std::env::var("RENEGADE_TEST_PERF").ok().and_then(|s| s.parse::<usize>().ok()) else { return };
    if !have_hdiutil() {
        return;
    }
    let work = work_dir("perf");
    let _guard = Cleanup(work.clone());
    let img = make_image(&work, "perf", true, 700, &|root| {
        for i in 0..n {
            let d = root.join(format!("d{:04}/s{:02}", i / 1000, (i / 50) % 20));
            if i % 50 == 0 {
                std::fs::create_dir_all(&d).unwrap();
            }
            let p = d.join(format!("file-{i:07}.dat"));
            if i % 7 == 0 {
                std::fs::write(&p, [b'x'; 100]).unwrap()
            } else {
                std::fs::File::create(&p).unwrap();
            }
        }
        let mut big = Vec::with_capacity(200 << 20);
        let mut x = 88172645463325252u64;
        while big.len() < 200 << 20 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            big.extend_from_slice(&x.to_le_bytes());
        }
        std::fs::write(root.join("big.bin"), &big).unwrap();
    })
    .expect("image");
    let c = Container::open(FileAt::open(&img).unwrap()).unwrap();
    let v = c.volume(0).unwrap();
    let t = std::time::Instant::now();
    let tree = v.tree().unwrap();
    let scan = t.elapsed();
    let t = std::time::Instant::now();
    let mut count = 0usize;
    tree.walk(&mut |_| {
        count += 1;
        Ok(())
    })
    .unwrap();
    let walk = t.elapsed();
    println!(
        "{count} nodes: scan {scan:?} ({:.0} nodes/s), walk {walk:?}; cache (misses, hits) {:?}",
        count as f64 / scan.as_secs_f64(),
        c.cache_stats()
    );
    let ino = v.lookup("big.bin").unwrap().unwrap().ino;
    let f = v.open_file(ino).unwrap();
    let mut buf = vec![0u8; 1 << 20];
    let t = std::time::Instant::now();
    let mut off = 0;
    while off < f.size() {
        let n = ((f.size() - off) as usize).min(buf.len());
        f.read_at(off, &mut buf[..n]).unwrap();
        off += n as u64;
    }
    println!("read {} MB in {:?}", f.size() >> 20, t.elapsed());
    let _ = std::fs::remove_dir_all(&work);
}
