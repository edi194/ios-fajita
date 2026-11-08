//! Renegade in Rust: the stages that turn an Apple IPSW into a PAC-stripped, re-signed HFS+ root image for
//! the Poco F1 (Bergamota). A port of the Python Renegade in `tools/renegade`, stage by stage, checked
//! against the Python outputs (`tests/`).
//!
//! The library does no file system access of its own: everything reads through [`io::ReadAt`] and writes
//! through `std::io::Write`, so the same code runs natively (the `renegade-rs` CLI) and in the browser
//! (`wasm32-unknown-unknown`, the web patcher).
//!
//! Ported so far (the stages the iOS 26 port marked stable):
//! - [`sparse`]: Android sparse images (`img2simg.py`, `simg2img.py`, the reader in `hfsx.py`)
//! - [`hfs`]: the read-only HFS+/HFSX reader (`hfsx.py`)
//! - [`macho`] and [`pacstrip`]: the arm64e code rewriter (`pacstrip.py`, without `--sign`)
//! - [`codesign`]: ad-hoc signing as `codesign -f -s -` does it (pacstrip.py --sign)
//! - [`fixups`]: the chained-fixup page-in check (`fixupcheck.py`)
//! - [`hfsedit`]: the owner/mode pass and owner map (`hfsroot_owners.py`, mkroot-full.py), free runs (`hfs_trim.py`)
//! - [`plist`]: plistlib's reader and writers (binary and XML, byte-identical)
//! - [`tweaks`]: the tweaks stage (root_tweaks18.py), the self-contained part
//! - [`apfs`]: a read-only APFS reader (the IPSW's OS and cryptex volumes without a mount)
//! - [`hfswrite`]: a new HFSX writer (the Python build uses newfs_hfs + a mount + ditto instead)

pub mod apfs;
pub mod aea;
pub mod bundle;
pub mod codesign;
pub mod dsc;
pub mod fixups;
pub mod hfs;
pub mod hfsedit;
pub mod hfswrite;
#[cfg(not(target_family = "wasm"))]
pub mod http;
pub mod io;
pub mod ipsw;
pub mod macho;
pub mod machostage;
pub mod pacstrip;
pub mod plist;
pub mod rootbuild;
pub mod sparse;
pub mod tools;
pub mod tree;
pub mod tweaks;
pub mod zip;

/// Big- and little-endian reads from byte slices (the Mach-O and HFS+ structures are both).
pub(crate) mod bytes {
    #[inline]
    pub fn u16be(b: &[u8], o: usize) -> u16 {
        u16::from_be_bytes([b[o], b[o + 1]])
    }
    #[inline]
    pub fn u32be(b: &[u8], o: usize) -> u32 {
        u32::from_be_bytes(b[o..o + 4].try_into().unwrap())
    }
    #[inline]
    pub fn u64be(b: &[u8], o: usize) -> u64 {
        u64::from_be_bytes(b[o..o + 8].try_into().unwrap())
    }
    #[inline]
    pub fn u16le(b: &[u8], o: usize) -> u16 {
        u16::from_le_bytes([b[o], b[o + 1]])
    }
    #[inline]
    pub fn u32le(b: &[u8], o: usize) -> u32 {
        u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
    }
    #[inline]
    pub fn u64le(b: &[u8], o: usize) -> u64 {
        u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
    }
    /// NUL-terminated name in a fixed-size field.
    pub fn cstr(b: &[u8]) -> String {
        let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
        String::from_utf8_lossy(&b[..end]).into_owned()
    }
}

/// The browser build needs no random numbers (the crypto crates link a RNG they never call): a source that fails.
#[cfg(target_family = "wasm")]
fn no_random(_: &mut [u8]) -> std::result::Result<(), getrandom::Error> {
    Err(getrandom::Error::UNSUPPORTED)
}
#[cfg(target_family = "wasm")]
getrandom::register_custom_getrandom!(no_random);
