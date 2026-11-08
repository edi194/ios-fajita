//! An IPSW as the root build needs it: the zip, its BuildManifest (device, version, build, the three disk
//! images: OS, SystemOS cryptex, AppOS cryptex) and each image as a random-access [`ReadAt`] of a raw APFS
//! container (the `.aea` ones decrypted on the fly, see [`crate::aea`]).

use crate::aea::{self, Aea};
use crate::io::{bad, ReadAt, Src};
use crate::plist::{self, Value};
use crate::zip::Zip;
use std::io::Result;
use std::rc::Rc;

/// The three images of a root, in the order the copy stage lays them down: cryptexes first, the OS volume on top.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Image {
    AppOs,
    SystemOs,
    Os,
}

impl Image {
    pub const ALL: [Image; 3] = [Image::AppOs, Image::SystemOs, Image::Os];
    pub fn key(self) -> &'static str {
        match self {
            Image::Os => "OS",
            Image::SystemOs => "Cryptex1,SystemOS",
            Image::AppOs => "Cryptex1,AppOS",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Image::Os => "os",
            Image::SystemOs => "sysos",
            Image::AppOs => "appos",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Manifest {
    pub device: String,
    pub version: String,
    pub build: String,
    /// member path of each image in the zip (as the manifest names it, `.aea` included)
    pub paths: Vec<(Image, String)>,
}

pub struct Ipsw {
    pub zip: Zip,
    pub manifest: Manifest,
}

fn dict_str<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut cur = v;
    for k in path {
        cur = cur.get(k)?;
    }
    cur.as_str()
}

impl Ipsw {
    pub fn open(src: Src) -> Result<Self> {
        let zip = Zip::open(src)?;
        let e = zip.find("BuildManifest.plist").ok_or_else(|| bad("this zip has no BuildManifest.plist: not an IPSW"))?;
        let m = plist::parse(&zip.read_all(e)?)?;
        let ident = match m.get("BuildIdentities") {
            Some(Value::Array(a)) if !a.is_empty() => &a[0],
            _ => return Err(bad("BuildManifest.plist has no build identities")),
        };
        let manifest = ident.get("Manifest").ok_or_else(|| bad("build identity without a Manifest"))?;
        let mut paths = Vec::new();
        for im in Image::ALL {
            let p = dict_str(manifest, &[im.key(), "Info", "Path"]).ok_or_else(|| bad(format!("the manifest has no {} image", im.key())))?;
            paths.push((im, p.to_string()));
        }
        let device = match m.get("SupportedProductTypes") {
            Some(Value::Array(a)) => a.first().and_then(|v| v.as_str()).unwrap_or("").to_string(),
            _ => String::new(),
        };
        let version = m.get("ProductVersion").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let build = m.get("ProductBuildVersion").and_then(|v| v.as_str()).unwrap_or("").to_string();
        Ok(Ipsw { zip, manifest: Manifest { device, version, build, paths } })
    }

    pub fn path_of(&self, im: Image) -> &str {
        &self.manifest.paths.iter().find(|(i, _)| *i == im).expect("all images are listed").1
    }

    /// The stored zip member holding the image (the encrypted one when it is `.aea`).
    pub fn member(&self, im: Image) -> Result<Src> {
        let p = self.path_of(im);
        let e = self.zip.find(p).ok_or_else(|| bad(format!("{p}: not in the IPSW")))?;
        if e.method == 8 {
            // a deflated image (the small AppOS one): inflated whole
            return Ok(Rc::new(self.zip.read_all(e)?));
        }
        Ok(Rc::new(self.zip.stored(e)?))
    }

    pub fn is_encrypted(&self, im: Image) -> bool {
        self.path_of(im).ends_with(".aea")
    }

    /// The private key URL the image's AEA key is wrapped for (None: not encrypted).
    pub fn key_url(&self, im: Image) -> Result<Option<String>> {
        if !self.is_encrypted(im) {
            return Ok(None);
        }
        Ok(Some(aea::key_url(&*self.member(im)?)?))
    }

    /// The image as a raw APFS container. `pem`: the private key of its key URL (needed for `.aea` images).
    pub fn open_image(&self, im: Image, pem: Option<&str>, verify: bool) -> Result<Src> {
        let m = self.member(im)?;
        if !self.is_encrypted(im) {
            return Ok(m);
        }
        let pem = pem.ok_or_else(|| bad(format!("{} is encrypted: the AEA key is needed", self.path_of(im))))?;
        let key = aea::fcs_key(&*m, pem)?;
        Ok(Rc::new(Aea::open(m, &key, verify)?))
    }
}

/// Reads a source as a UTF-8 string (for tests and the CLI).
pub fn read_text(s: &dyn ReadAt, off: u64, len: usize) -> Result<String> {
    Ok(String::from_utf8_lossy(&s.read_vec(off, len)?).into_owned())
}
