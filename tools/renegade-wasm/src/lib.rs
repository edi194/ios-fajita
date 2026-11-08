//! The Renegade root builder for the browser. A plain C ABI: the page's Web Worker instantiates the module
//! with the imports below and calls the exports; every long call runs to completion inside the worker
//! (the host reads the IPSW with FileReaderSync and writes the image into an OPFS file, both synchronous in
//! a worker), so none of the Rust code needs to be async.
//!
//! Imports (module "host"):
//! - `read(handle, offset: f64, ptr, len) -> i32`: fill `len` bytes at `ptr` from source `handle` (0 = the IPSW,
//!   1 = the optional tools bundle); 0 on success.
//! - `size(handle) -> f64`
//! - `write(offset: f64, ptr, len) -> i32`: write to the output image at `offset`; 0 on success.
//! - `event(kind, ptr, len, a: f64, b: f64)`: 0 stage (text), 1 log (text), 2 bytes (a done, b total).
//!
//! Exports: `rr_alloc`, `rr_free`, `rr_open_ipsw() -> i32`, `rr_build(config_ptr, config_len) -> i32`,
//! `rr_result_ptr()`, `rr_result_len()` (the JSON of the last call, or its error text when the call returned
//! non-zero).

use renegade::io::{bad, ReadAt, Src};
use std::cell::RefCell;
use std::io::{Result, Seek, SeekFrom, Write};
use std::rc::Rc;

mod host {
    #[link(wasm_import_module = "host")]
    unsafe extern "C" {
        pub fn read(handle: u32, offset: f64, ptr: *mut u8, len: u32) -> i32;
        pub fn size(handle: u32) -> f64;
        pub fn write(offset: f64, ptr: *const u8, len: u32) -> i32;
        pub fn event(kind: u32, ptr: *const u8, len: u32, a: f64, b: f64);
    }
}

/// A JS-side source (a File, read synchronously by the worker).
struct HostSrc {
    handle: u32,
    size: u64,
}

impl HostSrc {
    fn new(handle: u32) -> Self {
        // SAFETY: the host import has no preconditions
        let size = unsafe { host::size(handle) } as u64;
        Self { handle, size }
    }
}

impl ReadAt for HostSrc {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size {
            return Err(bad(format!("read past the end at byte {off}")));
        }
        // SAFETY: `buf` is a valid writable region of linear memory for the whole call
        let rc = unsafe { host::read(self.handle, off as f64, buf.as_mut_ptr(), buf.len() as u32) };
        if rc != 0 { Err(bad(format!("the browser could not read {} bytes at {off}", buf.len()))) } else { Ok(()) }
    }
}

/// The image output: positioned writes into the OPFS file.
struct HostOut {
    pos: u64,
    len: u64,
}

impl Write for HostOut {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        // SAFETY: `b` is valid for the call
        let rc = unsafe { host::write(self.pos as f64, b.as_ptr(), b.len() as u32) };
        if rc != 0 {
            return Err(std::io::Error::other("the browser could not write the image (disk full?)"));
        }
        self.pos += b.len() as u64;
        self.len = self.len.max(self.pos);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Seek for HostOut {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        self.pos = match to {
            SeekFrom::Start(o) => o,
            SeekFrom::End(d) => (self.len as i64 + d) as u64,
            SeekFrom::Current(d) => (self.pos as i64 + d) as u64,
        };
        Ok(self.pos)
    }
}

thread_local! {
    static RESULT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static IPSW: RefCell<Option<renegade::ipsw::Ipsw>> = const { RefCell::new(None) };
}

fn set_result(s: String) {
    RESULT.with(|r| *r.borrow_mut() = s.into_bytes());
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn event(kind: u32, text: &str, a: f64, b: f64) {
    // SAFETY: `text` is valid for the call
    unsafe { host::event(kind, text.as_ptr(), text.len() as u32, a, b) }
}

/// A flat JSON object of strings, numbers and booleans.
fn parse_flat(s: &str) -> std::collections::HashMap<String, String> {
    let mut m = std::collections::HashMap::new();
    let b = s.as_bytes();
    let mut i = 0;
    let string = |i: &mut usize| -> Option<String> {
        if b.get(*i) != Some(&b'"') {
            return None;
        }
        *i += 1;
        let mut out = Vec::new();
        while *i < b.len() && b[*i] != b'"' {
            if b[*i] == b'\\' && *i + 1 < b.len() {
                *i += 1;
                out.push(match b[*i] {
                    b'n' => b'\n',
                    b't' => b'\t',
                    c => c,
                });
            } else {
                out.push(b[*i]);
            }
            *i += 1;
        }
        *i += 1;
        Some(String::from_utf8_lossy(&out).into_owned())
    };
    while i < b.len() {
        if b[i] == b'"' {
            let Some(k) = string(&mut i) else { break };
            while i < b.len() && (b[i] == b':' || b[i] == b' ') {
                i += 1;
            }
            let v = if b.get(i) == Some(&b'"') {
                string(&mut i).unwrap_or_default()
            } else {
                let st = i;
                while i < b.len() && !matches!(b[i], b',' | b'}') {
                    i += 1;
                }
                s[st..i].trim().to_string()
            };
            m.insert(k, v);
        } else {
            i += 1;
        }
    }
    m
}

#[unsafe(no_mangle)]
pub extern "C" fn rr_alloc(n: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(n.max(1));
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rr_free(p: *mut u8, n: usize) {
    // SAFETY: the pointer came from rr_alloc with this capacity
    drop(unsafe { Vec::from_raw_parts(p, 0, n.max(1)) });
}

#[unsafe(no_mangle)]
pub extern "C" fn rr_result_ptr() -> *const u8 {
    RESULT.with(|r| r.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn rr_result_len() -> usize {
    RESULT.with(|r| r.borrow().len())
}

/// Opens the IPSW (host source 0) and describes it: JSON {device, version, build, images: [{name, path, encrypted, keyUrl}]}.
#[unsafe(no_mangle)]
pub extern "C" fn rr_open_ipsw() -> i32 {
    // a panic aborts the module (panic = "abort"): say why first, through the log
    std::panic::set_hook(Box::new(|info| event(1, &format!("internal error: {info}"), 0.0, 0.0)));
    let src: Src = Rc::new(HostSrc::new(0));
    match renegade::ipsw::Ipsw::open(src).and_then(|ipsw| {
        let mut images = Vec::new();
        for (im, p) in &ipsw.manifest.paths {
            let key = ipsw.key_url(*im)?;
            images.push(format!("{{\"name\":{},\"path\":{},\"encrypted\":{},\"keyUrl\":{}}}", json_str(im.name()), json_str(p), key.is_some(), key.as_deref().map(json_str).unwrap_or("null".into())));
        }
        let m = &ipsw.manifest;
        let j = format!("{{\"device\":{},\"version\":{},\"build\":{},\"images\":[{}]}}", json_str(&m.device), json_str(&m.version), json_str(&m.build), images.join(","));
        Ok((ipsw, j))
    }) {
        Ok((ipsw, j)) => {
            IPSW.with(|i| *i.borrow_mut() = Some(ipsw));
            set_result(j);
            0
        }
        Err(e) => {
            set_result(e.to_string());
            1
        }
    }
}

/// Runs the build. Config JSON: {"pem:<key URL>": "<PEM>" (one per key URL of the IPSW), "now": unix seconds, "macho": bool, "cache": bool, "tweaks": bool,
/// "tools": true when a tools bundle is source 1, "ssh_key": "ssh-ed25519 AAAA..."}. The image goes out through `host.write`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rr_build(cfg_ptr: *const u8, cfg_len: usize) -> i32 {
    // SAFETY: the host passes a buffer it got from rr_alloc
    let cfg_s = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(cfg_ptr, cfg_len) }).into_owned();
    let c = parse_flat(&cfg_s);
    let on = |k: &str, d: bool| c.get(k).map(|v| v == "true").unwrap_or(d);
    let r = IPSW.with(|i| -> Result<renegade::rootbuild::Summary> {
        let guard = i.borrow();
        let ipsw = guard.as_ref().ok_or_else(|| bad("no IPSW is open"))?;
        let mut cfg = renegade::rootbuild::Config { pems: c.iter().filter_map(|(k, v)| k.strip_prefix("pem:").map(|u| (u.to_string(), v.clone()))).collect(), now: c.get("now").and_then(|n| n.parse().ok()).unwrap_or(0), macho: on("macho", true), tweaks: on("tweaks", true), ..Default::default() };
        if !on("cache", true) {
            cfg.cache = None;
        }
        cfg.verify_aea = on("verify", false);
        if on("tools", false) {
            // the tools bundle (berga-tools.zip) is host source 1
            cfg.tools = Some(renegade::tools::Tools::from_zip(Rc::new(HostSrc::new(1)))?);
            cfg.ssh_key = c.get("ssh_key").filter(|k| !k.trim().is_empty()).cloned();
        }
        let mut ev = |e: renegade::rootbuild::Event| match e {
            renegade::rootbuild::Event::Stage(s) => event(0, s, 0.0, 0.0),
            renegade::rootbuild::Event::Log(l) => event(1, l, 0.0, 0.0),
            renegade::rootbuild::Event::Bytes(d, t) => event(2, "", d as f64, t as f64),
        };
        let (_, sum) = renegade::rootbuild::build(ipsw, &mut cfg, HostOut { pos: 0, len: 0 }, &mut ev)?;
        Ok(sum)
    });
    match r {
        Ok(s) => {
            set_result(format!("{{\"imageBytes\":{},\"entries\":{},\"machos\":{},\"signed\":{},\"chunks\":{}}}", s.image_bytes, s.entries, s.machos, s.signed, s.chunks));
            0
        }
        Err(e) => {
            set_result(e.to_string());
            1
        }
    }
}
