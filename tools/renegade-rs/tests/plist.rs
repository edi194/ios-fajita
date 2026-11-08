//! plistlib against renegade::plist on random property lists: Python generates them (binary and XML), both sides
//! load and dump; the dumps must be byte-identical. Needs python3.

use std::process::Command;

#[test]
fn random_plists_round_trip_like_plistlib() {
    if Command::new("python3").arg("--version").output().is_err() {
        eprintln!("python3 not found: skipping");
        return;
    }
    // each record: u8 kind (0 binary input, 1 XML input), u32 len + input, u32 len + plistlib binary dump, u32 len + XML dump
    let script = r#"
import datetime, plistlib, random, struct, sys
r = random.Random(7)
def scalar():
    k = r.randrange(9)
    if k == 0: return r.choice(['', 'a', 'café', '☃ snow', 'x' * r.randrange(1, 40), 'tab\tnew\nline & <tag>', '\U0001F600'])
    if k == 1: return r.choice([0, 1, 255, 256, 65535, 65536, 2**31, 2**32, 2**40, 2**63 - 1, 2**63, 2**64 - 1, -1, -2**63])
    if k == 2: return r.choice([0.0, -0.0, 1.0, 0.1, 1e16, 1e15, 1.5e-5, 1e-4, 123456789.125, -2.5, 1e300, 5e-324])
    if k == 3: return r.choice([True, False])
    if k == 4: return bytes(r.randrange(256) for _ in range(r.choice([0, 1, 2, 3, 45, 46, 57, 58, 100, 300])))
    if k == 5: return datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=r.randrange(-10**9, 10**9))
    return r.choice(['k1', 'k2', 1, 2.0])
def value(depth, pool):
    if depth > 3 or r.random() < 0.4:
        return scalar()
    if pool and r.random() < 0.15:
        return r.choice(pool)                 # the same container object twice: shared in the bplist
    if r.random() < 0.5:
        v = [value(depth + 1, pool) for _ in range(r.randrange(0, 20))]
    else:
        v = {r.choice(['a', 'b', 'Label', 'café', 'k%d' % r.randrange(30), '']): value(depth + 1, pool) for _ in range(r.randrange(0, 20))}
    pool.append(v)
    return v
out = sys.stdout.buffer
for i in range(300):
    v = {'root': value(0, []), 'n': i}
    fmt = plistlib.FMT_BINARY if i % 2 == 0 else plistlib.FMT_XML
    src = plistlib.dumps(v, fmt=fmt)
    loaded = plistlib.loads(src)
    b = plistlib.dumps(loaded, fmt=plistlib.FMT_BINARY)
    x = plistlib.dumps(loaded, fmt=plistlib.FMT_XML)
    out.write(struct.pack('<B', 0 if fmt == plistlib.FMT_BINARY else 1))
    for blob in (src, b, x):
        out.write(struct.pack('<I', len(blob)) + blob)
"#;
    let o = Command::new("python3").arg("-I").arg("-c").arg(script).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let b = o.stdout;
    let (mut i, mut n) = (0usize, 0);
    let next = |i: &mut usize| {
        let l = u32::from_le_bytes(b[*i..*i + 4].try_into().unwrap()) as usize;
        let s = b[*i + 4..*i + 4 + l].to_vec();
        *i += 4 + l;
        s
    };
    while i < b.len() {
        let kind = b[i];
        i += 1;
        let src = next(&mut i);
        let want_bin = next(&mut i);
        let want_xml = next(&mut i);
        let v = renegade::plist::parse(&src).unwrap_or_else(|e| panic!("record {n} ({}): {e}", if kind == 0 { "binary" } else { "xml" }));
        assert!(renegade::plist::to_binary(&v) == want_bin, "record {n}: binary dump differs");
        assert!(renegade::plist::to_xml(&v).unwrap() == want_xml, "record {n}: XML dump differs\n{}", String::from_utf8_lossy(&want_xml));
        n += 1;
    }
    assert_eq!(n, 300);
}

#[test]
fn python_float_repr() {
    use renegade::plist::py_float_repr as r;
    for (f, s) in [(1.0, "1.0"), (0.1, "0.1"), (1e16, "1e+16"), (1e15, "1000000000000000.0"), (1.5e-5, "1.5e-05"), (1e-4, "0.0001"), (-0.0, "-0.0"), (123456789.125, "123456789.125"), (5e-324, "5e-324"), (1e300, "1e+300")] {
        assert_eq!(r(f), s);
    }
}
