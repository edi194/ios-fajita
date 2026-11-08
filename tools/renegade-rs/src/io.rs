//! Positioned reads: a file, a buffer, a sparse image or a file inside an HFS+ volume all look the same.

use std::io::{Error, ErrorKind, Result};

pub trait ReadAt {
    fn size(&self) -> u64;
    /// Fills `buf` from `off`; an error if that runs past the end.
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()>;

    fn read_vec(&self, off: u64, len: usize) -> Result<Vec<u8>> {
        let mut v = vec![0; len];
        self.read_at(off, &mut v)?;
        Ok(v)
    }
}

impl ReadAt for [u8] {
    fn size(&self) -> u64 {
        self.len() as u64
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        let o = usize::try_from(off).map_err(|_| short(off))?;
        let src = self.get(o..o + buf.len()).ok_or_else(|| short(off))?;
        buf.copy_from_slice(src);
        Ok(())
    }
}

impl ReadAt for Vec<u8> {
    fn size(&self) -> u64 {
        self.len() as u64
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        self.as_slice().read_at(off, buf)
    }
}

impl<T: ReadAt + ?Sized> ReadAt for std::rc::Rc<T> {
    fn size(&self) -> u64 {
        (**self).size()
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        (**self).read_at(off, buf)
    }
}

/// A shared, type-erased source: what the IPSW readers hand around.
pub type Src = std::rc::Rc<dyn ReadAt>;

/// A window `[start, start + len)` of another source.
pub struct SubRange<R> {
    pub inner: R,
    pub start: u64,
    pub len: u64,
}

impl<R: ReadAt> SubRange<R> {
    pub fn new(inner: R, start: u64, len: u64) -> Result<Self> {
        if start.checked_add(len).is_none_or(|e| e > inner.size()) {
            return Err(bad("window runs past the end of its source"));
        }
        Ok(Self { inner, start, len })
    }
}

impl<R: ReadAt> ReadAt for SubRange<R> {
    fn size(&self) -> u64 {
        self.len
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off.checked_add(buf.len() as u64).is_none_or(|e| e > self.len) {
            return Err(short(off));
        }
        self.inner.read_at(self.start + off, buf)
    }
}

impl<T: ReadAt + ?Sized> ReadAt for &T {
    fn size(&self) -> u64 {
        (**self).size()
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        (**self).read_at(off, buf)
    }
}

pub fn short(off: u64) -> Error {
    Error::new(ErrorKind::UnexpectedEof, format!("read past the end at byte {off}"))
}

pub fn bad(msg: impl Into<String>) -> Error {
    Error::new(ErrorKind::InvalidData, msg.into())
}

/// A file on disk (native builds).
#[cfg(not(target_family = "wasm"))]
pub struct FileAt {
    file: std::fs::File,
    size: u64,
}

#[cfg(not(target_family = "wasm"))]
impl FileAt {
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self> {
        let file = std::fs::File::open(path)?;
        let size = file.metadata()?.len();
        Ok(Self { file, size })
    }
}

#[cfg(not(target_family = "wasm"))]
impl ReadAt for FileAt {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size {
            return Err(short(off));
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::FileExt::read_exact_at(&self.file, buf, off)
        }
        #[cfg(windows)]
        {
            let mut done = 0;
            while done < buf.len() {
                let n = std::os::windows::fs::FileExt::seek_read(&self.file, &mut buf[done..], off + done as u64)?;
                if n == 0 {
                    return Err(short(off + done as u64));
                }
                done += n;
            }
            Ok(())
        }
    }
}

/// Positioned writes, for in-place edits of an image (the owners pass).
pub trait WriteAt {
    fn write_at(&mut self, off: u64, data: &[u8]) -> Result<()>;
}

impl WriteAt for Vec<u8> {
    fn write_at(&mut self, off: u64, data: &[u8]) -> Result<()> {
        let o = off as usize;
        if self.len() < o + data.len() {
            self.resize(o + data.len(), 0);
        }
        self[o..o + data.len()].copy_from_slice(data);
        Ok(())
    }
}

/// A file opened for reading and writing (native builds).
#[cfg(not(target_family = "wasm"))]
pub struct FileRw {
    file: std::fs::File,
    size: u64,
}

#[cfg(not(target_family = "wasm"))]
impl FileRw {
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Self> {
        let file = std::fs::OpenOptions::new().read(true).write(true).open(path)?;
        let size = file.metadata()?.len();
        Ok(Self { file, size })
    }
    pub fn file(&self) -> &std::fs::File {
        &self.file
    }
}

#[cfg(all(unix, not(target_family = "wasm")))]
impl ReadAt for FileRw {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off + buf.len() as u64 > self.size {
            return Err(short(off));
        }
        std::os::unix::fs::FileExt::read_exact_at(&self.file, buf, off)
    }
}

#[cfg(all(unix, not(target_family = "wasm")))]
impl WriteAt for FileRw {
    fn write_at(&mut self, off: u64, data: &[u8]) -> Result<()> {
        std::os::unix::fs::FileExt::write_all_at(&self.file, data, off)?;
        self.size = self.size.max(off + data.len() as u64);
        Ok(())
    }
}
