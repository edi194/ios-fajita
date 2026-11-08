//! The Rust stages against the Python Renegade (`tools/renegade`) on the same inputs: byte-identical
//! files and identical printed output. Needs python3; each test is skipped (with a message) without it.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}
fn renegade_py() -> PathBuf {
    root().join("../renegade")
}
fn fixture(n: &str) -> PathBuf {
    root().join("tests/fixtures").join(n)
}
fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_renegade-rs"))
}

fn have_python() -> bool {
    let ok = Command::new("python3").arg("--version").output().map(|o| o.status.success()).unwrap_or(false);
    if !ok {
        eprintln!("python3 not found: skipping the comparison with the Python Renegade");
    }
    ok
}

fn tmp(name: &str) -> PathBuf {
    static N: AtomicU32 = AtomicU32::new(0);
    let d = std::env::temp_dir().join(format!("renegade-rs-test-{}-{}", std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
    fs::create_dir_all(&d).unwrap();
    d.join(name)
}

fn py(script: &str, args: &[&dyn AsRef<std::ffi::OsStr>]) -> Output {
    let mut c = Command::new("python3");
    c.arg("-I").arg(renegade_py().join(script));
    for a in args {
        c.arg(a);
    }
    let o = c.output().unwrap();
    assert!(o.status.success() || script == "fixupcheck.py", "{script} failed: {}", String::from_utf8_lossy(&o.stderr));
    o
}

fn rs(args: &[&dyn AsRef<std::ffi::OsStr>]) -> Output {
    let mut c = Command::new(bin());
    for a in args {
        c.arg(a);
    }
    c.output().unwrap()
}

/// Deterministic test data.
fn rng(seed: u64) -> impl FnMut() -> u64 {
    let mut s = seed;
    move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    }
}

/// A raw image with zero runs, short data runs and one data run longer than a RAW chunk (4096 blocks),
/// crossing the 16 MiB read pieces.
fn raw_image(blocks: usize, bs: usize, seed: u64) -> Vec<u8> {
    let mut r = rng(seed);
    let mut v = vec![0u8; blocks * bs];
    let mut b = 0;
    while b < blocks {
        let len = match r() % 4 {
            0 => 1 + (r() % 30) as usize,
            1 => 4100 + (r() % 50) as usize,
            _ => 1 + (r() % 300) as usize,
        };
        let data = !r().is_multiple_of(3);
        for k in b..(b + len).min(blocks) {
            if data {
                for x in v[k * bs..(k + 1) * bs].chunks_mut(8) {
                    x.copy_from_slice(&r().to_le_bytes()[..x.len()]);
                }
            }
        }
        b += len;
    }
    v
}

#[test]
fn img2simg_is_byte_identical_to_python() {
    if !have_python() {
        return;
    }
    for (blocks, bs, seed) in [(6000, 4096, 1u64), (2500, 8192, 2), (300, 4096, 3)] {
        let raw = tmp("raw.img");
        fs::write(&raw, raw_image(blocks, bs, seed)).unwrap();
        let (a, b) = (tmp("py.simg"), tmp("rs.simg"));
        let bss = bs.to_string();
        py("img2simg.py", &[&raw, &a, &"--block", &bss]);
        assert!(rs(&[&"img2simg", &raw, &b, &"--block", &bss]).status.success());
        assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "img2simg output differs ({blocks} blocks of {bs})");
    }
}

#[test]
fn simg2img_matches_python_and_the_reader() {
    if !have_python() {
        return;
    }
    let raw = tmp("raw.img");
    let data = raw_image(5000, 4096, 9);
    fs::write(&raw, &data).unwrap();
    let simg = tmp("in.simg");
    py("img2simg.py", &[&raw, &simg]);
    let (a, b) = (tmp("py.img"), tmp("rs.img"));
    py("simg2img.py", &[&simg, &a]);
    assert!(rs(&[&"simg2img", &simg, &b]).status.success());
    let (pa, pb) = (fs::read(&a).unwrap(), fs::read(&b).unwrap());
    assert!(pa == pb, "simg2img output differs");
    assert!(pb == data, "round trip changed the image");

    // random reads through the in-place reader
    use renegade::io::{FileAt, ReadAt};
    let img = renegade::sparse::Sparse::open(FileAt::open(&simg).unwrap()).unwrap();
    let mut r = rng(5);
    for _ in 0..200 {
        let off = (r() % data.len() as u64) as usize;
        let len = ((r() % 70000) as usize).min(data.len() - off);
        assert_eq!(img.read_vec(off as u64, len).unwrap(), &data[off..off + len]);
    }
}

#[test]
fn sparse_reader_handles_dont_care_and_patterned_fill() {
    // built by hand: RAW(1) FILL(2, 0xdeadbeef) DONT_CARE(3) CRC RAW(1)
    let bs = 4096u32;
    let mut s = Vec::new();
    s.extend_from_slice(&renegade::sparse::SPARSE_MAGIC.to_le_bytes());
    for v in [1u16, 0, 28, 12] {
        s.extend_from_slice(&v.to_le_bytes());
    }
    for v in [bs, 7, 5, 0] {
        s.extend_from_slice(&v.to_le_bytes());
    }
    let chunk = |s: &mut Vec<u8>, t: u16, blocks: u32, data: &[u8]| {
        s.extend_from_slice(&t.to_le_bytes());
        s.extend_from_slice(&0u16.to_le_bytes());
        s.extend_from_slice(&blocks.to_le_bytes());
        s.extend_from_slice(&(12 + data.len() as u32).to_le_bytes());
        s.extend_from_slice(data);
    };
    chunk(&mut s, 0xCAC1, 1, &[7u8; 4096]);
    chunk(&mut s, 0xCAC2, 2, &0xDEAD_BEEFu32.to_le_bytes());
    chunk(&mut s, 0xCAC3, 3, &[]);
    chunk(&mut s, 0xCAC4, 0, &[1, 2, 3, 4]);
    chunk(&mut s, 0xCAC1, 1, &[9u8; 4096]);
    use renegade::io::ReadAt;
    let img = renegade::sparse::Sparse::open(s).unwrap();
    assert_eq!(img.size(), 7 * 4096);
    let all = img.read_vec(0, 7 * 4096).unwrap();
    assert!(all[..4096].iter().all(|&b| b == 7));
    assert_eq!(&all[4096..4104], &[0xEF, 0xBE, 0xAD, 0xDE, 0xEF, 0xBE, 0xAD, 0xDE]);
    assert_eq!(img.read_vec(4097, 3).unwrap(), vec![0xBE, 0xAD, 0xDE], "fill pattern keeps its phase");
    assert!(all[3 * 4096..6 * 4096].iter().all(|&b| b == 0));
    assert!(all[6 * 4096..].iter().all(|&b| b == 9));
}

fn same_output(script_args: &[&str], rs_args: &[&str]) {
    let a: Vec<&dyn AsRef<std::ffi::OsStr>> = script_args[1..].iter().map(|s| s as &dyn AsRef<std::ffi::OsStr>).collect();
    let b: Vec<&dyn AsRef<std::ffi::OsStr>> = rs_args.iter().map(|s| s as &dyn AsRef<std::ffi::OsStr>).collect();
    let p = py(script_args[0], &a);
    let r = rs(&b);
    assert!(r.status.success() || script_args[0] == "fixupcheck.py", "renegade-rs {rs_args:?} failed: {}", String::from_utf8_lossy(&r.stderr));
    assert_eq!(String::from_utf8_lossy(&r.stdout), String::from_utf8_lossy(&p.stdout), "output differs for {rs_args:?}");
    assert_eq!(r.status.code(), p.status.code(), "exit status differs for {rs_args:?}");
}

#[test]
fn hfs_reader_matches_hfsx_py() {
    if !have_python() {
        return;
    }
    for img in ["hfsplus.simg", "hfsx.simg"] {
        let f = fixture(img);
        let f = f.to_str().unwrap();
        for d in ["/", "/usr/lib", "/usr/lib/sub dir", "/System", "/System/lib-link", "/Library/Café", "/Library/Cafe\u{301}"] {
            same_output(&["hfsx.py", f, "ls", d], &["hfs", f, "ls", d]);
        }
        for p in ["/usr/lib/hello.txt", "/usr/lib/hardlink.txt", "/usr/lib/abs-link", "/usr/lib/rel-link", "/usr/lib", "/", "/nope", "/Library/Café/naïve.txt"] {
            same_output(&["hfsx.py", f, "stat", p], &["hfs", f, "stat", p]);
        }
        for p in ["/usr/lib/hello.txt", "/usr/lib/hardlink.txt", "/usr/lib/abs-link", "/usr/lib/rel-link", "/System/lib-link/sub dir/big.bin", "/Library/Café/naïve.txt"] {
            same_output(&["hfsx.py", f, "cat", p], &["hfs", f, "cat", p]);
        }
        for s in ["l", "dyld", "é", "zzz"] {
            same_output(&["hfsx.py", f, "find", s], &["hfs", f, "find", s]);
        }
        // dsc: the same files with the same bytes
        let (a, b) = (tmp("dsc-py"), tmp("dsc-rs"));
        same_output(&["hfsx.py", f, "dsc", a.to_str().unwrap()], &["hfs", f, "dsc", b.to_str().unwrap()]);
        assert_eq!(tree(&a), tree(&b));
        // getdir: the same tree (files, modes, symlinks)
        let (a, b) = (tmp("getdir-py"), tmp("getdir-rs"));
        same_output(&["hfsx.py", f, "getdir", "/usr", a.to_str().unwrap()], &["hfs", f, "getdir", "/usr", b.to_str().unwrap()]);
        assert_eq!(tree(&a), tree(&b));
    }
}

/// (relative path, kind, mode, content or link target) of every entry under `d`.
fn tree(d: &Path) -> Vec<(String, String, u32, Vec<u8>)> {
    use std::os::unix::fs::PermissionsExt;
    let mut out = Vec::new();
    fn walk(d: &Path, base: &Path, out: &mut Vec<(String, String, u32, Vec<u8>)>) {
        let mut ents: Vec<_> = fs::read_dir(d).unwrap().map(|e| e.unwrap().path()).collect();
        ents.sort();
        for p in ents {
            let m = fs::symlink_metadata(&p).unwrap();
            let rel = p.strip_prefix(base).unwrap().display().to_string();
            if m.file_type().is_symlink() {
                out.push((rel, "link".into(), 0, fs::read_link(&p).unwrap().display().to_string().into_bytes()));
            } else if m.is_dir() {
                out.push((rel, "dir".into(), 0, vec![]));
                walk(&p, base, out);
            } else {
                out.push((rel, "file".into(), m.permissions().mode() & 0o7777, fs::read(&p).unwrap()));
            }
        }
    }
    walk(d, d, &mut out);
    out
}

#[test]
fn pacstrip_matches_python_scan_and_rewrite() {
    if !have_python() {
        return;
    }
    let dice = synthetic_macho_with_dice();
    for f in [fixture("pac.o"), fixture("libpac.dylib"), fixture("libfix.dylib"), fixture("exe"), dice] {
        let s = f.to_str().unwrap();
        same_output(&["pacstrip.py", "--scan", s], &["strip", "--scan", s]);
        let (a, b) = (tmp("py.bin"), tmp("rs.bin"));
        let (pa, pb) = (a.to_str().unwrap(), b.to_str().unwrap());
        let p = py("pacstrip.py", &[&"-v", &s, &"-o", &pa]);
        let r = rs(&[&"strip", &"-v", &s, &"-o", &pb]);
        assert_eq!(String::from_utf8_lossy(&r.stdout), String::from_utf8_lossy(&p.stdout));
        assert_eq!(String::from_utf8_lossy(&r.stderr), String::from_utf8_lossy(&p.stderr), "verbose lines differ for {s}");
        assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "rewritten bytes differ for {s}");
    }
    // the stripped dylib has no PAC instruction left except what pacstrip reports and leaves
    let out = tmp("stripped.dylib");
    assert!(rs(&[&"strip", &fixture("libpac.dylib"), &"-o", &out]).status.success());
    let again = String::from_utf8(rs(&[&"strip", &"--scan", &out]).stdout).unwrap();
    assert!(again.contains("FJCVTZS(left)=1") && again.contains("LDRAA(unencodable)=2") && !again.contains("RETAA"), "{again}");
}

#[test]
fn pacstrip_options_match_python() {
    if !have_python() {
        return;
    }
    let exe = fixture("exe");
    for extra in [vec!["--dylinker", "/usr/lib/dyld-renegade"], vec!["--dylinker", "/x"]] {
        let (a, b) = (tmp("py.exe"), tmp("rs.exe"));
        let mut pargs: Vec<&dyn AsRef<std::ffi::OsStr>> = vec![&exe, &"-o", &a];
        let mut rargs: Vec<&dyn AsRef<std::ffi::OsStr>> = vec![&"strip", &exe, &"-o", &b];
        for e in &extra {
            pargs.push(e);
            rargs.push(e);
        }
        py("pacstrip.py", &pargs);
        assert!(rs(&rargs).status.success());
        assert!(fs::read(&a).unwrap() == fs::read(&b).unwrap(), "{extra:?}: bytes differ");
    }
    // --subtype arm64: pacstrip.py raises struct.error on arm64e (cpusubtype 0x81000002 read as a signed int,
    // the masked value no longer fits '<i'); the Rust port keeps the flag byte and clears the subtype
    let out = tmp("sub.exe");
    assert!(rs(&[&"strip", &exe, &"-o", &out, &"--subtype", &"arm64"]).status.success());
    let orig = u32::from_le_bytes(fs::read(&exe).unwrap()[8..12].try_into().unwrap());
    let b = fs::read(&out).unwrap();
    assert_eq!(orig & 0xFF, 2, "fixture is arm64e");
    assert_eq!(u32::from_le_bytes(b[8..12].try_into().unwrap()), orig & 0xFF00_0000);
    // not enough header slack: both refuse
    let long = "/".to_string() + &"x".repeat(40000);
    let r = rs(&[&"strip", &exe, &"-o", &tmp("rs.exe"), &"--dylinker", &long]);
    assert!(!r.status.success());
}

#[test]
fn rewrite_word_matches_python_on_random_words() {
    if !have_python() {
        return;
    }
    // 200k random words from the instruction groups pacstrip looks at, classified by pacstrip.py
    let script = r#"
import sys, struct, random
sys.path.insert(0, sys.argv[1])
import pacstrip
r = random.Random(1234)
out = sys.stdout.buffer
for _ in range(200000):
    top = r.choice([0xD6, 0xD7, 0xDA, 0x9A, 0xF8, 0x1E])
    w = top << 24 | r.getrandbits(24)
    if r.random() < 0.5:   # bias towards the encodings that match
        w = r.choice([0xD61F0800, 0xD63F0800, 0xD71F0800, 0xD73F0800, 0xDAC10000, 0xDAC143E0, 0x9AC03000, 0xF8200400, 0xF8A00400, 0x1E7E0000, 0xD65F0BFF]) | (r.getrandbits(32) & r.choice([0x3FF, 0x1F, 0xFFFFF, 0x7FF, 0x3E0, 0]))
    nw, cls = pacstrip.rewrite_word(w)
    out.write(struct.pack('<IIq', w, 0 if nw is None else nw, -1 if nw is None else 0))
    c = (cls or '').encode()
    out.write(struct.pack('<B', len(c)) + c)
"#;
    let o = Command::new("python3").arg("-I").arg("-c").arg(script).arg(renegade_py()).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let b = o.stdout;
    let mut i = 0;
    let mut n = 0;
    while i < b.len() {
        let w = u32::from_le_bytes(b[i..i + 4].try_into().unwrap());
        let nw = u32::from_le_bytes(b[i + 4..i + 8].try_into().unwrap());
        let none = i64::from_le_bytes(b[i + 8..i + 16].try_into().unwrap()) == -1;
        let l = b[i + 16] as usize;
        let cls = std::str::from_utf8(&b[i + 17..i + 17 + l]).unwrap();
        i += 17 + l;
        let (rnw, rcls) = renegade::pacstrip::rewrite_word(w);
        assert_eq!(rnw, if none { None } else { Some(nw) }, "word {w:#010x}");
        assert_eq!(rcls.unwrap_or(""), cls, "word {w:#010x}");
        n += 1;
    }
    assert_eq!(n, 200_000);
}

/// A minimal arm64e dylib-shaped Mach-O: __TEXT,__text with PAC instructions and an LC_DATA_IN_CODE entry
/// covering two of them (which must stay untouched).
fn synthetic_macho_with_dice() -> PathBuf {
    let words: [u32; 8] = [0xD65F0BFF, 0xDAC10000, 0xD65F0BFF, 0xDAC10000, 0xD71F0822, 0xD503201F, 0xD65F0FFF, 0xD65F03C0];
    let text_off = 0x200usize;
    let dice_off = 0x300usize;
    let mut b = vec![0u8; 0x400];
    let w32 = |b: &mut Vec<u8>, o: usize, v: u32| b[o..o + 4].copy_from_slice(&v.to_le_bytes());
    let w64 = |b: &mut Vec<u8>, o: usize, v: u64| b[o..o + 8].copy_from_slice(&v.to_le_bytes());
    w32(&mut b, 0, 0xFEEDFACF);
    w32(&mut b, 4, 0x0100000C);
    w32(&mut b, 8, 2);
    w32(&mut b, 12, 6);
    w32(&mut b, 16, 2);
    let seg = 32;
    let segsize = 72 + 80;
    w32(&mut b, 20, (segsize + 16) as u32);
    w32(&mut b, seg, 0x19);
    w32(&mut b, seg + 4, segsize as u32);
    b[seg + 8..seg + 14].copy_from_slice(b"__TEXT");
    w64(&mut b, seg + 40, 0);
    w64(&mut b, seg + 48, 0x400);
    w32(&mut b, seg + 64, 1);
    let sect = seg + 72;
    b[sect..sect + 6].copy_from_slice(b"__text");
    b[sect + 16..sect + 22].copy_from_slice(b"__TEXT");
    w64(&mut b, sect + 32, text_off as u64);
    w64(&mut b, sect + 40, 32);
    w32(&mut b, sect + 48, text_off as u32);
    w32(&mut b, sect + 64, 0x80000400);
    let dic = seg + segsize;
    w32(&mut b, dic, 0x29);
    w32(&mut b, dic + 4, 16);
    w32(&mut b, dic + 8, dice_off as u32);
    w32(&mut b, dic + 12, 8);
    w32(&mut b, dice_off, (text_off + 8) as u32);
    b[dice_off + 4..dice_off + 6].copy_from_slice(&8u16.to_le_bytes());
    b[dice_off + 6..dice_off + 8].copy_from_slice(&1u16.to_le_bytes());
    for (i, w) in words.iter().enumerate() {
        w32(&mut b, text_off + 4 * i, *w);
    }
    let p = tmp("dice.macho");
    fs::write(&p, b).unwrap();
    p
}

#[test]
fn fixupcheck_matches_python() {
    if !have_python() {
        return;
    }
    // a directory with good and broken Mach-Os
    let dir = tmp("root").with_file_name("root");
    fs::create_dir_all(dir.join("usr/lib")).unwrap();
    fs::copy(fixture("libfix.dylib"), dir.join("usr/lib/libfix.dylib")).unwrap();
    fs::copy(fixture("exe"), dir.join("usr/lib/exe")).unwrap();
    fs::write(dir.join("usr/lib/notes.txt"), b"not a mach-o").unwrap();
    let mut broken = fs::read(fixture("libfix.dylib")).unwrap();
    break_first_chain(&mut broken);
    fs::write(dir.join("usr/lib/broken.dylib"), &broken).unwrap();
    let d = dir.to_str().unwrap();
    // file order on disk may differ between os.walk and read_dir: compare sorted lines
    let p = py("fixupcheck.py", &[&d, &"--quiet"]);
    let r = rs(&[&"fixupcheck", &d, &"--quiet"]);
    let sorted = |o: &[u8]| {
        let mut v: Vec<String> = String::from_utf8_lossy(o).lines().map(String::from).collect();
        v.sort();
        v
    };
    assert_eq!(sorted(&r.stdout), sorted(&p.stdout));
    assert_eq!(r.status.code(), p.status.code());
    assert!(String::from_utf8_lossy(&r.stdout).contains("BAD /usr/lib/broken.dylib"));
    // straight on the HFS+ image (catalog order: identical output)
    let f = fixture("hfsplus.simg");
    let f = f.to_str().unwrap();
    same_output(&["fixupcheck.py", f, "--quiet"], &["fixupcheck", f, "--quiet"]);
    same_output(&["fixupcheck.py", f, "--prefix", "/usr/lib", "--quiet"], &["fixupcheck", f, "--prefix", "/usr/lib", "--quiet"]);
}

/// Turns the first fixup of the first segment with fixups into a bind with an impossible ordinal.
fn break_first_chain(b: &mut [u8]) {
    use renegade::macho::{load_commands, LC_DYLD_CHAINED_FIXUPS, LC_SEGMENT_64};
    let lcs = load_commands(b, 0).unwrap();
    let rd32 = |b: &[u8], o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap()) as usize;
    let rd16 = |b: &[u8], o: usize| u16::from_le_bytes(b[o..o + 2].try_into().unwrap()) as usize;
    let segs: Vec<usize> = lcs.iter().filter(|l| l.cmd == LC_SEGMENT_64).map(|l| u64::from_le_bytes(b[l.off + 40..l.off + 48].try_into().unwrap()) as usize).collect();
    let fx = lcs.iter().find(|l| l.cmd == LC_DYLD_CHAINED_FIXUPS).unwrap();
    let h = rd32(b, fx.off + 8);
    let si = h + rd32(b, h + 4);
    for (s, &seg) in segs.iter().enumerate().take(rd32(b, si)) {
        let io = rd32(b, si + 4 + 4 * s);
        if io == 0 {
            continue;
        }
        let ss = si + io;
        let start = rd16(b, ss + 22);
        if start == 0xFFFF {
            continue;
        }
        let at = seg + start;
        // an authenticated bind with an ordinal far beyond the import table, keeping the chain's next field
        let v = u64::from_le_bytes(b[at..at + 8].try_into().unwrap());
        let v = (v & (0x7FF << 51)) | 1 << 63 | 1 << 62 | 0xFF_FFFF;
        b[at..at + 8].copy_from_slice(&v.to_le_bytes());
        return;
    }
    panic!("no chain to break");
}
