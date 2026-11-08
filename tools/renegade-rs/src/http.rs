//! A remote file as a [`ReadAt`] (HTTP range requests, native builds only): lets the tools run on an IPSW
//! without downloading it, the way the browser reads a local file with `File.slice`.

use crate::io::{bad, short, ReadAt};
use std::cell::RefCell;
use std::io::{Read, Result};

pub struct HttpAt {
    url: String,
    size: u64,
    agent: ureq::Agent,
    /// one read-ahead window (offset, bytes)
    win: RefCell<(u64, Vec<u8>)>,
    block: u64,
    pub requests: std::cell::Cell<u64>,
    pub bytes: std::cell::Cell<u64>,
}

/// IPv4 first: a host with a broken IPv6 route to Apple's CDN otherwise waits for a timeout on every connection.
struct V4First;

impl ureq::Resolver for V4First {
    fn resolve(&self, netloc: &str) -> std::io::Result<Vec<std::net::SocketAddr>> {
        use std::net::ToSocketAddrs;
        let mut v: Vec<_> = netloc.to_socket_addrs()?.collect();
        v.sort_by_key(|a| a.is_ipv6());
        Ok(v)
    }
}

impl HttpAt {
    pub fn open(url: &str) -> Result<Self> {
        let agent = ureq::AgentBuilder::new().resolver(V4First).timeout_connect(std::time::Duration::from_secs(30)).timeout_read(std::time::Duration::from_secs(120)).build();
        let r = agent.head(url).call().map_err(|e| bad(format!("{url}: {e}")))?;
        let size: u64 = r.header("content-length").and_then(|v| v.parse().ok()).ok_or_else(|| bad("no Content-Length"))?;
        Ok(Self { url: url.into(), size, agent, win: RefCell::new((0, Vec::new())), block: 8 << 20, requests: Default::default(), bytes: Default::default() })
    }

    fn fetch(&self, off: u64, len: u64) -> Result<Vec<u8>> {
        let end = (off + len).min(self.size) - 1;
        let t0 = std::time::Instant::now();
        let _log = std::env::var_os("RENEGADE_HTTP_LOG").map(|_| LogOnDrop(format!("GET {off}-{end}"), t0));
        for attempt in 0..5 {
            let r = self.agent.get(&self.url).set("Range", &format!("bytes={off}-{end}")).call();
            match r {
                Ok(resp) => {
                    let mut v = Vec::with_capacity((end - off + 1) as usize);
                    if resp.into_reader().take(end - off + 1).read_to_end(&mut v).is_ok() && v.len() as u64 == end - off + 1 {
                        self.requests.set(self.requests.get() + 1);
                        self.bytes.set(self.bytes.get() + v.len() as u64);
                        return Ok(v);
                    }
                }
                Err(e) if attempt == 4 => return Err(bad(format!("{}: {e}", self.url))),
                Err(_) => {}
            }
            std::thread::sleep(std::time::Duration::from_millis(500 * (attempt + 1)));
        }
        Err(bad(format!("{}: range {off}-{end} failed", self.url)))
    }
}

impl ReadAt for HttpAt {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size {
            return Err(short(off));
        }
        let mut w = self.win.borrow_mut();
        if off >= w.0 && off + buf.len() as u64 <= w.0 + w.1.len() as u64 {
            let o = (off - w.0) as usize;
            buf.copy_from_slice(&w.1[o..o + buf.len()]);
            return Ok(());
        }
        if buf.len() as u64 >= self.block {
            drop(w);
            buf.copy_from_slice(&self.fetch(off, buf.len() as u64)?);
            return Ok(());
        }
        // a read that continues the previous window is a stream: read ahead big; a jump gets a small window
        let sequential = off == w.0 + w.1.len() as u64;
        let len = if sequential { self.block } else { 1 << 20 }.max(buf.len() as u64);
        *w = (off, self.fetch(off, len)?);
        buf.copy_from_slice(&w.1[..buf.len()]);
        Ok(())
    }
}

struct LogOnDrop(String, std::time::Instant);
impl Drop for LogOnDrop {
    fn drop(&mut self) {
        eprintln!("{} {:.2}s", self.0, self.1.elapsed().as_secs_f64());
    }
}
