//! Bundle resource sealing as `codesign` does it when it signs a bundle's main executable: the
//! `_CodeSignature/CodeResources` plist (iOS rules: SHA-1 in `files`, SHA-256 in `files2`, `.lproj` optional,
//! nested bundles hashed as plain files), written the way CoreFoundation writes XML.

use sha1::Sha1;
use sha2::{Digest, Sha256};

/// A file of the bundle, path relative to the bundle folder: its SHA-1 and SHA-256, or a symlink's target.
pub enum Item {
    File { sha1: [u8; 20], sha256: [u8; 32] },
    Symlink(String),
}

impl Item {
    pub fn file(d: &[u8]) -> Self {
        Item::File { sha1: Sha1::digest(d).into(), sha256: Sha256::digest(d).into() }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Rule {
    Include,
    Optional,
    Omit,
}

/// The rule that applies (highest weight wins), for the v1 (`files`) or v2 (`files2`) rule set.
fn rule(path: &str, v2: bool) -> Rule {
    let mut best = (1u32, Rule::Include); // "^.*" = true
    let mut consider = |w: u32, r: Rule| {
        if w > best.0 {
            best = (w, r);
        }
    };
    let in_lproj = path.split('/').rev().skip(1).any(|c| c.ends_with(".lproj"));
    let first = path.split('/').next().unwrap_or("");
    if in_lproj {
        consider(1000, Rule::Optional);
    }
    if path.ends_with(".lproj/locversion.plist") {
        consider(1100, Rule::Omit);
    }
    if first == "Base.lproj" && path.contains('/') {
        consider(1010, Rule::Include);
    }
    if v2 {
        if path.split('/').any(|c| c.ends_with(".dSYM")) {
            consider(11, Rule::Include);
        }
        if path.rsplit('/').next() == Some(".DS_Store") {
            consider(2000, Rule::Omit);
        }
        match path {
            "Info.plist" | "PkgInfo" => consider(20, Rule::Omit),
            "embedded.provisionprofile" | "version.plist" => consider(20, Rule::Include),
            _ => {}
        }
    }
    best.1
}

fn b64(d: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in d.chunks(3) {
        let v = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for k in 0..4 {
            s.push(if k <= c.len() { T[((v >> (18 - 6 * k)) & 63) as usize] as char } else { '=' });
        }
    }
    s
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

const RULES: &str = "\t<key>rules</key>
\t<dict>
\t\t<key>^.*</key>
\t\t<true/>
\t\t<key>^.*\\.lproj/</key>
\t\t<dict>
\t\t\t<key>optional</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>1000</real>
\t\t</dict>
\t\t<key>^.*\\.lproj/locversion.plist$</key>
\t\t<dict>
\t\t\t<key>omit</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>1100</real>
\t\t</dict>
\t\t<key>^Base\\.lproj/</key>
\t\t<dict>
\t\t\t<key>weight</key>
\t\t\t<real>1010</real>
\t\t</dict>
\t\t<key>^version.plist$</key>
\t\t<true/>
\t</dict>
\t<key>rules2</key>
\t<dict>
\t\t<key>.*\\.dSYM($|/)</key>
\t\t<dict>
\t\t\t<key>weight</key>
\t\t\t<real>11</real>
\t\t</dict>
\t\t<key>^(.*/)?\\.DS_Store$</key>
\t\t<dict>
\t\t\t<key>omit</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>2000</real>
\t\t</dict>
\t\t<key>^.*</key>
\t\t<true/>
\t\t<key>^.*\\.lproj/</key>
\t\t<dict>
\t\t\t<key>optional</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>1000</real>
\t\t</dict>
\t\t<key>^.*\\.lproj/locversion.plist$</key>
\t\t<dict>
\t\t\t<key>omit</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>1100</real>
\t\t</dict>
\t\t<key>^Base\\.lproj/</key>
\t\t<dict>
\t\t\t<key>weight</key>
\t\t\t<real>1010</real>
\t\t</dict>
\t\t<key>^Info\\.plist$</key>
\t\t<dict>
\t\t\t<key>omit</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>20</real>
\t\t</dict>
\t\t<key>^PkgInfo$</key>
\t\t<dict>
\t\t\t<key>omit</key>
\t\t\t<true/>
\t\t\t<key>weight</key>
\t\t\t<real>20</real>
\t\t</dict>
\t\t<key>^embedded\\.provisionprofile$</key>
\t\t<dict>
\t\t\t<key>weight</key>
\t\t\t<real>20</real>
\t\t</dict>
\t\t<key>^version\\.plist$</key>
\t\t<dict>
\t\t\t<key>weight</key>
\t\t\t<real>20</real>
\t\t</dict>
\t</dict>
";

/// Closes the dict opened by "<key>NAME</key>\n\t<dict>\n"; an empty one becomes "<dict/>", as CoreFoundation
/// writes it.
fn close_dict(s: &mut String, name: &str) {
    let open = format!("\t<key>{name}</key>\n\t<dict>\n");
    if s.ends_with(&open) {
        s.truncate(s.len() - "\t<dict>\n".len());
        s.push_str("\t<dict/>\n");
    } else {
        s.push_str("\t</dict>\n");
    }
}

/// `_CodeSignature/CodeResources` for a bundle. `items`: every file and symlink of the bundle folder (paths
/// relative to it), the main executable and `_CodeSignature/` already left out.
pub fn code_resources(items: &[(String, Item)]) -> Vec<u8> {
    write(items, &|_, h1, h2| (h1, h2))
}

/// CodeResources with the hashes of `old` (an existing CodeResources) where it lists the path: what codesign
/// would have written then. Used to recognise an image's CodeResources whose only difference is stale hashes.
pub fn code_resources_with(items: &[(String, Item)], old: &[u8]) -> Vec<u8> {
    let Ok(v) = crate::plist::parse(old) else { return Vec::new() };
    let pick = |set: &str, p: &str, key: &str| -> Option<Vec<u8>> {
        let e = v.get(set)?.get(p)?;
        let d = match e.inner() {
            crate::plist::Value::Data(d) => d.clone(),
            other => match other.get(key)?.inner() {
                crate::plist::Value::Data(d) => d.clone(),
                _ => return None,
            },
        };
        Some(d)
    };
    write(items, &|p, h1, h2| {
        let h1 = pick("files", p, "hash").and_then(|d| <[u8; 20]>::try_from(d).ok()).unwrap_or(h1);
        let h2 = pick("files2", p, "hash2").and_then(|d| <[u8; 32]>::try_from(d).ok()).unwrap_or(h2);
        (h1, h2)
    })
}

/// Paths whose hash in an existing CodeResources is not the hash of the file now (None: unparsable).
pub fn stale_entries(old: &[u8], items: &[(String, Item)]) -> Option<Vec<String>> {
    let v = crate::plist::parse(old).ok()?;
    let f2 = v.get("files2")?.as_dict()?;
    let mut out = Vec::new();
    for (p, it) in items {
        if let (Item::File { sha256, .. }, Some(e)) = (it, f2.get(p))
            && let Some(crate::plist::Value::Data(h)) = e.get("hash2").map(|x| x.inner())
            && h[..] != sha256[..]
        {
            out.push(p.clone());
        }
    }
    Some(out)
}

type HashFn<'a> = dyn Fn(&str, [u8; 20], [u8; 32]) -> ([u8; 20], [u8; 32]) + 'a;

fn write(items: &[(String, Item)], hashes: &HashFn) -> Vec<u8> {
    let mut sorted: Vec<&(String, Item)> = items.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n");
    // files (v1): SHA-1; symlinks are not listed in the v1 set
    s.push_str("\t<key>files</key>\n\t<dict>\n");
    for (p, it) in &sorted {
        let Item::File { sha1, sha256 } = it else { continue };
        let r = rule(p, false);
        if r == Rule::Omit {
            continue;
        }
        let h = b64(&hashes(p, *sha1, *sha256).0);
        s.push_str(&format!("\t\t<key>{}</key>\n", esc(p)));
        if r == Rule::Optional {
            s.push_str(&format!("\t\t<dict>\n\t\t\t<key>hash</key>\n\t\t\t<data>\n\t\t\t{h}\n\t\t\t</data>\n\t\t\t<key>optional</key>\n\t\t\t<true/>\n\t\t</dict>\n"));
        } else {
            s.push_str(&format!("\t\t<data>\n\t\t{h}\n\t\t</data>\n"));
        }
    }
    close_dict(&mut s, "files");
    // files2 (v2): SHA-256, symlinks by target
    s.push_str("\t<key>files2</key>\n\t<dict>\n");
    for (p, it) in &sorted {
        let r = rule(p, true);
        if r == Rule::Omit {
            continue;
        }
        s.push_str(&format!("\t\t<key>{}</key>\n\t\t<dict>\n", esc(p)));
        match it {
            Item::File { sha1, sha256 } => s.push_str(&format!("\t\t\t<key>hash2</key>\n\t\t\t<data>\n\t\t\t{}\n\t\t\t</data>\n", b64(&hashes(p, *sha1, *sha256).1))),
            Item::Symlink(t) => s.push_str(&format!("\t\t\t<key>symlink</key>\n\t\t\t<string>{}</string>\n", esc(t))),
        }
        if r == Rule::Optional {
            s.push_str("\t\t\t<key>optional</key>\n\t\t\t<true/>\n");
        }
        s.push_str("\t\t</dict>\n");
    }
    close_dict(&mut s, "files2");
    s.push_str(RULES);
    s.push_str("</dict>\n</plist>\n");
    s.into_bytes()
}

/// codesign's view of a Mach-O at `dir/name`: the bundle's main executable when `dir` has an Info.plist whose
/// CFBundleExecutable is `name`, or, without that key, when `name` is the folder's name minus its extension
/// (CFBundle's fallback: Seika.brailledriver/Seika).
pub fn is_main_executable(info_plist: Option<&[u8]>, dir_name: &str, name: &str) -> bool {
    let Some(v) = info_plist.and_then(|b| crate::plist::parse(b).ok()) else { return false };
    match v.get("CFBundleExecutable").and_then(|x| x.as_str()) {
        Some(exe) => exe == name,
        None => dir_name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(dir_name) == name,
    }
}
