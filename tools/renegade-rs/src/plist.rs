//! Property lists the way Python's `plistlib` reads and writes them, so the tweaks stage writes the same bytes
//! as `root_tweaks18.py`: binary (`bplist00`) and XML in, `plistlib.dump(..., fmt=FMT_BINARY / FMT_XML)` out
//! (sorted keys, the same object table, integer widths, ASCII/UTF-16 strings, offset sizes; for XML the tab
//! indentation, escaping, base64 line length and Python's float repr).
//!
//! Dicts are kept sorted (BTreeMap): plistlib dumps with sort_keys=True, so the input order never reaches the
//! output. Dates are microseconds since 2001-01-01, as plistlib's datetime holds them.

use crate::io::bad;
use std::collections::{BTreeMap, HashMap};
use std::io::Result;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Dict(BTreeMap<String, Value>),
    Array(Vec<Value>),
    String(String),
    Integer(i128),
    Real(f64),
    Bool(bool),
    Data(Vec<u8>),
    /// Microseconds since 2001-01-01 00:00:00 UTC.
    Date(i64),
    Uid(u64),
    /// A container the binary plist referenced from several places: plistlib reads it as ONE Python object and
    /// writes it once again (its writer deduplicates containers by identity). The number is its object index in
    /// the file it was read from; every copy carries the same number and is written as one object.
    Shared(u32, Box<Value>),
}

impl Value {
    pub fn dict() -> Self {
        Value::Dict(BTreeMap::new())
    }
    /// The value itself, through a [`Value::Shared`] marker.
    pub fn inner(&self) -> &Value {
        match self {
            Value::Shared(_, v) => v.inner(),
            v => v,
        }
    }
    pub fn inner_mut(&mut self) -> &mut Value {
        match self {
            Value::Shared(_, v) => v.inner_mut(),
            v => v,
        }
    }
    pub fn as_dict(&self) -> Option<&BTreeMap<String, Value>> {
        if let Value::Dict(d) = self.inner() { Some(d) } else { None }
    }
    pub fn as_dict_mut(&mut self) -> Option<&mut BTreeMap<String, Value>> {
        if let Value::Dict(d) = self.inner_mut() { Some(d) } else { None }
    }
    pub fn as_array_mut(&mut self) -> Option<&mut Vec<Value>> {
        if let Value::Array(a) = self.inner_mut() { Some(a) } else { None }
    }
    pub fn as_str(&self) -> Option<&str> {
        if let Value::String(s) = self.inner() { Some(s) } else { None }
    }
    /// `d.get(key)` for a dict.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_dict()?.get(key)
    }
}

impl From<&str> for Value {
    fn from(s: &str) -> Self {
        Value::String(s.into())
    }
}
impl From<String> for Value {
    fn from(s: String) -> Self {
        Value::String(s)
    }
}
impl From<bool> for Value {
    fn from(b: bool) -> Self {
        Value::Bool(b)
    }
}
impl From<i64> for Value {
    fn from(i: i64) -> Self {
        Value::Integer(i as i128)
    }
}
impl From<f64> for Value {
    fn from(f: f64) -> Self {
        Value::Real(f)
    }
}

/// plistlib.loads: binary or XML.
pub fn parse(b: &[u8]) -> Result<Value> {
    if b.starts_with(b"bplist00") { parse_binary(b) } else { parse_xml(b) }
}

// ---------------------------------------------------------------------------------------------------------- binary in

fn be_uint(b: &[u8]) -> u64 {
    b.iter().fold(0u64, |a, &x| (a << 8) | x as u64)
}

/// timedelta(seconds=f) rounds to whole microseconds, half to even.
fn secs_to_micros(f: f64) -> i64 {
    (f * 1e6).round_ties_even() as i64
}

pub fn parse_binary(b: &[u8]) -> Result<Value> {
    if b.len() < 40 {
        return Err(bad("binary plist too short"));
    }
    let t = &b[b.len() - 32..];
    let (offset_size, ref_size) = (t[6] as usize, t[7] as usize);
    let num = be_uint(&t[8..16]) as usize;
    let top = be_uint(&t[16..24]) as usize;
    let table = be_uint(&t[24..32]) as usize;
    let offsets: Vec<usize> = (0..num).map(|i| be_uint(&b[table + i * offset_size..table + (i + 1) * offset_size]) as usize).collect();
    struct P<'a> {
        b: &'a [u8],
        offsets: Vec<usize>,
        ref_size: usize,
        /// how many times each object is referenced (the top object counts once)
        uses: Vec<u32>,
    }
    impl P<'_> {
        fn size(&self, tok: u8, at: &mut usize) -> Result<usize> {
            let n = (tok & 0xF) as usize;
            if n != 0xF {
                return Ok(n);
            }
            let m = self.b[*at];
            let w = 1usize << (m & 0x3);
            let v = be_uint(&self.b[*at + 1..*at + 1 + w]) as usize;
            *at += 1 + w;
            Ok(v)
        }
        fn obj(&self, r: usize, depth: u32) -> Result<Value> {
            if depth > 512 {
                return Err(bad("plist nested too deep"));
            }
            let mut at = *self.offsets.get(r).ok_or_else(|| bad("bad object reference"))?;
            let tok = self.b[at];
            at += 1;
            let refs = |at: usize, n: usize| -> Vec<usize> { (0..n).map(|i| be_uint(&self.b[at + i * self.ref_size..at + (i + 1) * self.ref_size]) as usize).collect() };
            let shared = self.uses.get(r).copied().unwrap_or(0) > 1 && matches!(tok >> 4, 0xA | 0xD);
            let v = self.plain(r, tok, at, depth, &refs)?;
            Ok(if shared { Value::Shared(r as u32, Box::new(v)) } else { v })
        }
        fn plain(&self, _r: usize, tok: u8, mut at: usize, depth: u32, refs: &dyn Fn(usize, usize) -> Vec<usize>) -> Result<Value> {
            Ok(match tok >> 4 {
                0x0 => match tok {
                    0x08 => Value::Bool(false),
                    0x09 => Value::Bool(true),
                    _ => return Err(bad(format!("unsupported plist token {tok:#x}"))),
                },
                0x1 => {
                    let w = 1usize << (tok & 0xF);
                    let raw = &self.b[at..at + w];
                    match w {
                        8 => Value::Integer(i64::from_be_bytes(raw.try_into().unwrap()) as i128),
                        16 => Value::Integer(i128::from_be_bytes(raw.try_into().unwrap())),
                        _ => Value::Integer(be_uint(raw) as i128),
                    }
                }
                0x2 => match tok & 0xF {
                    2 => Value::Real(f32::from_be_bytes(self.b[at..at + 4].try_into().unwrap()) as f64),
                    3 => Value::Real(f64::from_be_bytes(self.b[at..at + 8].try_into().unwrap())),
                    _ => return Err(bad("bad real")),
                },
                0x3 => Value::Date(secs_to_micros(f64::from_be_bytes(self.b[at..at + 8].try_into().unwrap()))),
                0x4 => {
                    let n = self.size(tok, &mut at)?;
                    Value::Data(self.b[at..at + n].to_vec())
                }
                0x5 => {
                    let n = self.size(tok, &mut at)?;
                    Value::String(self.b[at..at + n].iter().map(|&c| c as char).collect())
                }
                0x6 => {
                    let n = self.size(tok, &mut at)?;
                    let u: Vec<u16> = (0..n).map(|i| u16::from_be_bytes([self.b[at + 2 * i], self.b[at + 2 * i + 1]])).collect();
                    Value::String(String::from_utf16(&u).map_err(|_| bad("bad UTF-16 string"))?)
                }
                0x8 => Value::Uid(be_uint(&self.b[at..at + (tok & 0xF) as usize + 1])),
                0xA => {
                    let n = self.size(tok, &mut at)?;
                    Value::Array(refs(at, n).into_iter().map(|r| self.obj(r, depth + 1)).collect::<Result<_>>()?)
                }
                0xD => {
                    let n = self.size(tok, &mut at)?;
                    let ks = refs(at, n);
                    let vs = refs(at + n * self.ref_size, n);
                    let mut d = BTreeMap::new();
                    for (k, v) in ks.into_iter().zip(vs) {
                        let Value::String(k) = self.obj(k, depth + 1)? else { return Err(bad("non-string dict key")) };
                        d.insert(k, self.obj(v, depth + 1)?);
                    }
                    Value::Dict(d)
                }
                _ => return Err(bad(format!("unsupported plist token {tok:#x}"))),
            })
        }
    }
    // count the references of every container (dicts and arrays reference their members)
    let mut uses = vec![0u32; num];
    if top < num {
        uses[top] += 1;
    }
    for &o in &offsets {
        let tok = b[o];
        if !matches!(tok >> 4, 0xA | 0xD) {
            continue;
        }
        let mut at = o + 1;
        let mut n = (tok & 0xF) as usize;
        if n == 0xF {
            let w = 1usize << (b[at] & 0x3);
            n = be_uint(&b[at + 1..at + 1 + w]) as usize;
            at += 1 + w;
        }
        let count = if tok >> 4 == 0xD { 2 * n } else { n };
        for i in 0..count {
            let r = be_uint(&b[at + i * ref_size..at + (i + 1) * ref_size]) as usize;
            if r < num {
                uses[r] += 1;
            }
        }
    }
    P { b, offsets, ref_size, uses }.obj(top, 0)
}

// ---------------------------------------------------------------------------------------------------------- binary out

#[derive(Hash, PartialEq, Eq)]
enum ScalarKey {
    Str(String),
    Int(i128),
    Bool(bool),
    Real(u64),
    Date(i64),
    Data(Vec<u8>),
}

fn scalar_key(v: &Value) -> Option<ScalarKey> {
    Some(match v {
        Value::String(s) => ScalarKey::Str(s.clone()),
        Value::Integer(i) => ScalarKey::Int(*i),
        Value::Bool(b) => ScalarKey::Bool(*b),
        // (float, 0.0) == (float, -0.0) in Python; NaN never equals itself (no dedup)
        Value::Real(f) if f.is_nan() => return None,
        Value::Real(f) => ScalarKey::Real(if *f == 0.0 { 0 } else { f.to_bits() }),
        Value::Date(d) => ScalarKey::Date(*d),
        Value::Data(d) => ScalarKey::Data(d.clone()),
        _ => return None,
    })
}

fn count_to_size(n: usize) -> usize {
    let n = n as u64;
    if n < 1 << 8 {
        1
    } else if n < 1 << 16 {
        2
    } else if n < 1 << 32 {
        4
    } else {
        8
    }
}

/// One entry of plistlib's object list: a value, or a dict key (keys are strings and share the string table).
#[derive(Clone, Copy)]
enum Obj<'a> {
    Val(&'a Value),
    Key(&'a str),
}

/// `plistlib.dumps(value, fmt=FMT_BINARY)`.
pub fn to_binary(value: &Value) -> Vec<u8> {
    // flatten: plistlib's object order (scalars deduplicated by (type, value), containers never)
    let mut objs: Vec<Obj> = Vec::new();
    let mut scalars: HashMap<ScalarKey, usize> = HashMap::new();
    let mut ids: HashMap<*const Value, usize> = HashMap::new();
    let mut tags: HashMap<u32, usize> = HashMap::new();
    fn flatten<'a>(o: Obj<'a>, objs: &mut Vec<Obj<'a>>, scalars: &mut HashMap<ScalarKey, usize>, ids: &mut HashMap<*const Value, usize>, tags: &mut HashMap<u32, usize>) {
        // a shared container: one object for every copy
        if let Obj::Val(Value::Shared(t, inner)) = o {
            if tags.contains_key(t) {
                return;
            }
            tags.insert(*t, objs.len());
            return flatten(Obj::Val(inner), objs, scalars, ids, tags);
        }
        let key = match o {
            Obj::Key(k) => Some(ScalarKey::Str(k.to_string())),
            Obj::Val(v) => scalar_key(v),
        };
        match key {
            Some(k) => {
                if scalars.contains_key(&k) {
                    return;
                }
                scalars.insert(k, objs.len());
            }
            None => {
                if let Obj::Val(v) = o {
                    ids.insert(v as *const Value, objs.len());
                }
            }
        }
        objs.push(o);
        match o {
            Obj::Val(Value::Dict(d)) => {
                for k in d.keys() {
                    flatten(Obj::Key(k), objs, scalars, ids, tags);
                }
                for x in d.values() {
                    flatten(Obj::Val(x), objs, scalars, ids, tags);
                }
            }
            Obj::Val(Value::Array(a)) => a.iter().for_each(|x| flatten(Obj::Val(x), objs, scalars, ids, tags)),
            _ => {}
        }
    }
    flatten(Obj::Val(value), &mut objs, &mut scalars, &mut ids, &mut tags);
    let refnum = |v: &Value| -> usize {
        if let Value::Shared(t, _) = v {
            return tags[t];
        }
        match scalar_key(v) {
            Some(k) => scalars[&k],
            None => ids[&(v as *const Value)],
        }
    };
    let ref_size = count_to_size(objs.len());
    let mut out = b"bplist00".to_vec();
    let mut offsets = vec![0usize; objs.len()];
    let size_hdr = |out: &mut Vec<u8>, tok: u8, n: usize| {
        let n = n as u64;
        if n < 15 {
            out.push(tok | n as u8);
        } else if n < 1 << 8 {
            out.extend_from_slice(&[tok | 0xF, 0x10, n as u8]);
        } else if n < 1 << 16 {
            out.extend_from_slice(&[tok | 0xF, 0x11]);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        } else if n < 1 << 32 {
            out.extend_from_slice(&[tok | 0xF, 0x12]);
            out.extend_from_slice(&(n as u32).to_be_bytes());
        } else {
            out.extend_from_slice(&[tok | 0xF, 0x13]);
            out.extend_from_slice(&n.to_be_bytes());
        }
    };
    let put_ref = |out: &mut Vec<u8>, r: usize| out.extend_from_slice(&(r as u64).to_be_bytes()[8 - ref_size..]);
    let key_ref = |k: &str| scalars[&ScalarKey::Str(k.to_string())];
    for (i, o) in objs.iter().enumerate() {
        offsets[i] = out.len();
        let owned;
        let v: &Value = match o {
            Obj::Val(v) => v,
            Obj::Key(k) => {
                owned = Value::String((*k).to_string());
                &owned
            }
        };
        match v {
            Value::Bool(false) => out.push(0x08),
            Value::Bool(true) => out.push(0x09),
            Value::Integer(n) => {
                let n = *n;
                if n < 0 {
                    out.push(0x13);
                    out.extend_from_slice(&(n as i64).to_be_bytes());
                } else if n < 1 << 8 {
                    out.extend_from_slice(&[0x10, n as u8]);
                } else if n < 1 << 16 {
                    out.push(0x11);
                    out.extend_from_slice(&(n as u16).to_be_bytes());
                } else if n < 1 << 32 {
                    out.push(0x12);
                    out.extend_from_slice(&(n as u32).to_be_bytes());
                } else if n < 1 << 63 {
                    out.push(0x13);
                    out.extend_from_slice(&(n as u64).to_be_bytes());
                } else {
                    out.push(0x14);
                    out.extend_from_slice(&n.to_be_bytes());
                }
            }
            Value::Real(f) => {
                out.push(0x23);
                out.extend_from_slice(&f.to_be_bytes());
            }
            Value::Date(us) => {
                out.push(0x33);
                out.extend_from_slice(&(*us as f64 / 1e6).to_be_bytes());
            }
            Value::Data(d) => {
                size_hdr(&mut out, 0x40, d.len());
                out.extend_from_slice(d);
            }
            Value::String(s) => {
                if s.is_ascii() {
                    size_hdr(&mut out, 0x50, s.len());
                    out.extend_from_slice(s.as_bytes());
                } else {
                    let u: Vec<u16> = s.encode_utf16().collect();
                    size_hdr(&mut out, 0x60, u.len());
                    for x in u {
                        out.extend_from_slice(&x.to_be_bytes());
                    }
                }
            }
            Value::Shared(..) => unreachable!("shared containers are flattened to their inner value"),
            Value::Uid(u) => {
                let u = *u;
                if u < 1 << 8 {
                    out.extend_from_slice(&[0x80, u as u8]);
                } else if u < 1 << 16 {
                    out.push(0x81);
                    out.extend_from_slice(&(u as u16).to_be_bytes());
                } else if u < 1 << 32 {
                    out.push(0x83);
                    out.extend_from_slice(&(u as u32).to_be_bytes());
                } else {
                    out.push(0x87);
                    out.extend_from_slice(&u.to_be_bytes());
                }
            }
            Value::Array(a) => {
                size_hdr(&mut out, 0xA0, a.len());
                for x in a {
                    put_ref(&mut out, refnum(x));
                }
            }
            Value::Dict(d) => {
                size_hdr(&mut out, 0xD0, d.len());
                for k in d.keys() {
                    put_ref(&mut out, key_ref(k));
                }
                for x in d.values() {
                    put_ref(&mut out, refnum(x));
                }
            }
        }
    }
    let top = refnum(value);
    let table = out.len();
    let offset_size = count_to_size(table);
    for o in &offsets {
        out.extend_from_slice(&(*o as u64).to_be_bytes()[8 - offset_size..]);
    }
    out.extend_from_slice(&[0; 5]);
    out.push(0); // sort version
    out.push(offset_size as u8);
    out.push(ref_size as u8);
    out.extend_from_slice(&(objs.len() as u64).to_be_bytes());
    out.extend_from_slice(&(top as u64).to_be_bytes());
    out.extend_from_slice(&(table as u64).to_be_bytes());
    out
}

// ---------------------------------------------------------------------------------------------------------- XML in

/// A minimal XML reader for the plist DTD (elements, text, entities, comments, PIs, DOCTYPE).
pub fn parse_xml(b: &[u8]) -> Result<Value> {
    let s = std::str::from_utf8(b).map_err(|_| bad("XML plist is not UTF-8"))?;
    #[derive(Debug)]
    enum Tok<'a> {
        Open(&'a str),
        Close(&'a str),
        Empty(&'a str),
        Text(String),
    }
    let mut toks = Vec::new();
    let mut i = 0;
    let bytes = s.as_bytes();
    while i < bytes.len() {
        if bytes[i] == b'<' {
            if s[i..].starts_with("<!--") {
                i += s[i..].find("-->").ok_or_else(|| bad("unterminated comment"))? + 3;
            } else if s[i..].starts_with("<?") {
                i += s[i..].find("?>").ok_or_else(|| bad("unterminated PI"))? + 2;
            } else if s[i..].starts_with("<!") {
                i += s[i..].find('>').ok_or_else(|| bad("unterminated declaration"))? + 1;
            } else {
                let end = i + s[i..].find('>').ok_or_else(|| bad("unterminated tag"))?;
                let inner = &s[i + 1..end];
                if let Some(n) = inner.strip_prefix('/') {
                    toks.push(Tok::Close(n.trim()));
                } else if let Some(n) = inner.strip_suffix('/') {
                    toks.push(Tok::Empty(n.split_whitespace().next().unwrap_or("")));
                } else {
                    toks.push(Tok::Open(inner.split_whitespace().next().unwrap_or("")));
                }
                i = end + 1;
            }
        } else {
            let end = s[i..].find('<').map(|k| i + k).unwrap_or(s.len());
            toks.push(Tok::Text(unescape(&s[i..end])?));
            i = end;
        }
    }
    let mut pos = 0;
    fn skip_ws(toks: &[Tok], pos: &mut usize) {
        while let Some(Tok::Text(t)) = toks.get(*pos) {
            if t.trim().is_empty() {
                *pos += 1;
            } else {
                break;
            }
        }
    }
    fn text_until(toks: &[Tok], pos: &mut usize, name: &str) -> Result<String> {
        let mut out = String::new();
        loop {
            match toks.get(*pos) {
                Some(Tok::Text(t)) => {
                    out.push_str(t);
                    *pos += 1;
                }
                Some(Tok::Close(n)) if *n == name => {
                    *pos += 1;
                    return Ok(out);
                }
                _ => return Err(bad(format!("bad <{name}> element"))),
            }
        }
    }
    fn value(toks: &[Tok], pos: &mut usize) -> Result<Value> {
        skip_ws(toks, pos);
        let t = toks.get(*pos).ok_or_else(|| bad("unexpected end of plist"))?;
        *pos += 1;
        Ok(match t {
            Tok::Empty("dict") => Value::dict(),
            Tok::Empty("array") => Value::Array(vec![]),
            Tok::Empty("true") => Value::Bool(true),
            Tok::Empty("false") => Value::Bool(false),
            Tok::Empty("string") => Value::String(String::new()),
            Tok::Empty("data") => Value::Data(vec![]),
            Tok::Open("true") => {
                text_until(toks, pos, "true")?;
                Value::Bool(true)
            }
            Tok::Open("false") => {
                text_until(toks, pos, "false")?;
                Value::Bool(false)
            }
            Tok::Open("string") => Value::String(text_until(toks, pos, "string")?),
            Tok::Open("integer") => {
                let t = text_until(toks, pos, "integer")?;
                let t = t.trim();
                let v = if let Some(h) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) { i128::from_str_radix(h, 16) } else { t.parse::<i128>() };
                Value::Integer(v.map_err(|_| bad(format!("bad integer {t:?}")))?)
            }
            Tok::Open("real") => {
                let t = text_until(toks, pos, "real")?;
                Value::Real(t.trim().parse::<f64>().map_err(|_| bad(format!("bad real {t:?}")))?)
            }
            Tok::Open("data") => Value::Data(b64decode(&text_until(toks, pos, "data")?)?),
            Tok::Open("date") => Value::Date(parse_date(&text_until(toks, pos, "date")?)?),
            Tok::Open("array") => {
                let mut a = Vec::new();
                loop {
                    skip_ws(toks, pos);
                    if let Some(Tok::Close("array")) = toks.get(*pos) {
                        *pos += 1;
                        break;
                    }
                    a.push(value(toks, pos)?);
                }
                Value::Array(a)
            }
            Tok::Open("dict") => {
                let mut d = BTreeMap::new();
                loop {
                    skip_ws(toks, pos);
                    match toks.get(*pos) {
                        Some(Tok::Close("dict")) => {
                            *pos += 1;
                            break;
                        }
                        Some(Tok::Open("key")) => {
                            *pos += 1;
                            let k = text_until(toks, pos, "key")?;
                            let v = value(toks, pos)?;
                            d.insert(k, v);
                        }
                        Some(Tok::Empty("key")) => {
                            *pos += 1;
                            let v = value(toks, pos)?;
                            d.insert(String::new(), v);
                        }
                        _ => return Err(bad("bad <dict>")),
                    }
                }
                Value::Dict(d)
            }
            other => return Err(bad(format!("unexpected {other:?} in plist"))),
        })
    }
    skip_ws(&toks, &mut pos);
    match toks.get(pos) {
        Some(Tok::Open("plist")) => pos += 1,
        _ => return Err(bad("no <plist> element")),
    }
    let v = value(&toks, &mut pos)?;
    Ok(v)
}

fn unescape(s: &str) -> Result<String> {
    if !s.contains('&') {
        return Ok(s.to_string());
    }
    let mut out = String::new();
    let mut rest = s;
    while let Some(k) = rest.find('&') {
        out.push_str(&rest[..k]);
        let end = rest[k..].find(';').ok_or_else(|| bad("bad entity"))? + k;
        let ent = &rest[k + 1..end];
        match ent {
            "amp" => out.push('&'),
            "lt" => out.push('<'),
            "gt" => out.push('>'),
            "quot" => out.push('"'),
            "apos" => out.push('\''),
            _ if ent.starts_with("#x") => out.push(char::from_u32(u32::from_str_radix(&ent[2..], 16).map_err(|_| bad("bad entity"))?).ok_or_else(|| bad("bad entity"))?),
            _ if ent.starts_with('#') => out.push(char::from_u32(ent[1..].parse().map_err(|_| bad("bad entity"))?).ok_or_else(|| bad("bad entity"))?),
            _ => return Err(bad(format!("unknown entity &{ent};"))),
        }
        rest = &rest[end + 1..];
    }
    out.push_str(rest);
    // expat normalizes line ends
    Ok(out.replace("\r\n", "\n").replace('\r', "\n"))
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64decode(s: &str) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => continue, // whitespace (binascii ignores non-alphabet characters)
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Ok(out)
}

fn b64line(chunk: &[u8]) -> String {
    let mut s = String::new();
    for c in chunk.chunks(3) {
        let n = c.len();
        let v = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for k in 0..4 {
            if k <= n {
                s.push(B64[((v >> (18 - 6 * k)) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

/// Days from 1970-01-01 to y-m-d (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

const EPOCH_2001_DAYS: i64 = 11323; // 2001-01-01 in days since 1970-01-01

/// "2024-01-02T03:04:05Z" -> microseconds since 2001 (plistlib's _date_from_string: fields may be missing).
fn parse_date(s: &str) -> Result<i64> {
    let s = s.trim().trim_end_matches('Z');
    let mut f = [0i64, 1, 1, 0, 0, 0];
    for (i, part) in s.split(['-', 'T', ':']).enumerate().take(6) {
        f[i] = part.parse().map_err(|_| bad(format!("bad date {s:?}")))?;
    }
    let days = days_from_civil(f[0], f[1], f[2]) - EPOCH_2001_DAYS;
    Ok((days * 86400 + f[3] * 3600 + f[4] * 60 + f[5]) * 1_000_000)
}

fn format_date(us: i64) -> String {
    let secs = us.div_euclid(1_000_000);
    let days = secs.div_euclid(86400) + EPOCH_2001_DAYS;
    let r = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", r / 3600, r % 3600 / 60, r % 60)
}

// ---------------------------------------------------------------------------------------------------------- XML out

/// Python's repr(float): shortest round-trip digits, exponent form below 1e-4 and from 1e16.
pub fn py_float_repr(f: f64) -> String {
    if f.is_nan() {
        return "nan".into();
    }
    if f.is_infinite() {
        return if f > 0.0 { "inf".into() } else { "-inf".into() };
    }
    if f == 0.0 {
        return if f.is_sign_negative() { "-0.0".into() } else { "0.0".into() };
    }
    let e = format!("{f:e}"); // shortest digits: "1.2345e-5"
    let (mant, exp) = e.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let neg = mant.starts_with('-');
    let digits: String = mant.chars().filter(|c| c.is_ascii_digit()).collect();
    let sign = if neg { "-" } else { "" };
    if !(-4..16).contains(&exp) {
        let m = if digits.len() > 1 { format!("{}.{}", &digits[..1], &digits[1..]) } else { digits.clone() };
        return format!("{sign}{m}e{}{:02}", if exp < 0 { '-' } else { '+' }, exp.abs());
    }
    let point = exp + 1; // digits before the decimal point
    if point <= 0 {
        format!("{sign}0.{}{}", "0".repeat((-point) as usize), digits)
    } else if point as usize >= digits.len() {
        format!("{sign}{}{}.0", digits, "0".repeat(point as usize - digits.len()))
    } else {
        format!("{sign}{}.{}", &digits[..point as usize], &digits[point as usize..])
    }
}

fn xml_escape(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n").replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// `plistlib.dumps(value, fmt=FMT_XML)`.
pub fn to_xml(value: &Value) -> Result<Vec<u8>> {
    struct W {
        out: String,
        level: usize,
    }
    impl W {
        fn line(&mut self, s: &str) {
            for _ in 0..self.level {
                self.out.push('\t');
            }
            self.out.push_str(s);
            self.out.push('\n');
        }
        fn simple(&mut self, el: &str, v: Option<&str>) {
            match v {
                Some(v) => self.line(&format!("<{el}>{}</{el}>", xml_escape(v))),
                None => self.line(&format!("<{el}/>")),
            }
        }
        fn value(&mut self, v: &Value) -> Result<()> {
            match v {
                Value::String(s) => self.simple("string", Some(s)),
                Value::Bool(true) => self.simple("true", None),
                Value::Bool(false) => self.simple("false", None),
                Value::Integer(i) => {
                    if *i < -(1i128 << 63) || *i >= 1i128 << 64 {
                        return Err(bad("integer out of range"));
                    }
                    self.simple("integer", Some(&i.to_string()))
                }
                Value::Real(f) => self.simple("real", Some(&py_float_repr(*f))),
                Value::Date(d) => self.simple("date", Some(&format_date(*d))),
                Value::Uid(_) => return Err(bad("UID cannot be written to an XML plist")),
                Value::Shared(_, v) => self.value(v)?,
                Value::Data(d) => {
                    self.line("<data>");
                    // the base64 lines sit one level out, at most 76 columns counting a tab as 8
                    let width = 76usize.saturating_sub(8 * self.level).max(16);
                    let maxbin = (width / 4) * 3;
                    for c in d.chunks(maxbin.max(1)) {
                        self.line(&b64line(c));
                    }
                    self.line("</data>");
                }
                Value::Dict(d) => {
                    if d.is_empty() {
                        self.simple("dict", None);
                    } else {
                        self.line("<dict>");
                        self.level += 1;
                        for (k, x) in d {
                            self.simple("key", Some(k));
                            self.value(x)?;
                        }
                        self.level -= 1;
                        self.line("</dict>");
                    }
                }
                Value::Array(a) => {
                    if a.is_empty() {
                        self.simple("array", None);
                    } else {
                        self.line("<array>");
                        self.level += 1;
                        for x in a {
                            self.value(x)?;
                        }
                        self.level -= 1;
                        self.line("</array>");
                    }
                }
            }
            Ok(())
        }
    }
    let mut w = W { out: String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"), level: 0 };
    w.line("<plist version=\"1.0\">");
    w.value(value)?;
    w.line("</plist>");
    Ok(w.out.into_bytes())
}
