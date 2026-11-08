//! The macho stage of the root build (mkroot-full.py `stage_macho`): every Mach-O outside the dyld cache is
//! rewritten by [`crate::pacstrip`]; the ones that changed are re-signed ad hoc keeping identifier, options and
//! entitlements ([`crate::codesign::resign`]), a bundle's main executable with its bundle's CodeResources
//! regenerated first ([`crate::bundle`]). Files pacstrip leaves unchanged keep their signature, as in Python.
//!
//! Unlike the Python stage (a process pool in arbitrary order, which can seal a bundle before its nested code is
//! re-signed and leave stale hashes in its CodeResources), bundles are handled deepest first.
//!
//! Two passes, so a 15 GB root never sits in memory: [`plan`] decides and writes the CodeResources files into the
//! tree, [`final_bytes`] recomputes a file's rewritten, re-signed bytes when the image writer asks for them.

use crate::bundle::{self, Item};
use crate::hfswrite::Kind;
use crate::pacstrip::{self, Options};
use crate::tweaks::{Fs, TreeFs};
use std::collections::{BTreeMap, HashMap};
use std::io::Result;

/// Where a re-signed file's bundle context lives (paths in the tree).
#[derive(Debug, Clone, Default)]
pub struct Context {
    pub info_plist: Option<Vec<u8>>,
    pub code_resources: Option<Vec<u8>>,
    /// the file's final size (re-signing can change it)
    pub len: u64,
}

#[derive(Debug, Default)]
pub struct Plan {
    /// source -> bundle context, for every file that is rewritten and re-signed
    pub signed: HashMap<usize, Context>,
    pub machos: u64,
    pub clean: u64,
    pub bundles_sealed: u64,
    pub counts: BTreeMap<String, u64>,
}

fn is_macho(d: &[u8]) -> bool {
    crate::fixups::looks_like_macho(d) || d.starts_with(&[0xCA, 0xFE, 0xBA, 0xBF])
}

/// The rewritten bytes of a Mach-O, or None when pacstrip changes nothing.
fn stripped(data: &[u8], counts: Option<&mut BTreeMap<String, u64>>) -> Result<Option<Vec<u8>>> {
    let mut d = data.to_vec();
    let rep = pacstrip::strip(&mut d, &Options { write: true, ..Default::default() })?;
    if let Some(c) = counts {
        for (k, v) in rep.counts {
            *c.entry(k).or_default() += v;
        }
    }
    Ok(if d == data { None } else { Some(d) })
}

/// Pass 1: decide which files are rewritten and re-signed, seal their bundles (CodeResources written into `t`).
/// The image writer needs the final sizes up front: [`Context::len`], applied by [`apply_sizes`].
pub fn plan(t: &mut TreeFs, dyld_dir: &str) -> Result<Plan> {
    let mut p = Plan::default();
    let dyld = format!("{dyld_dir}/");
    // one entry per file (hard links once), deepest first, then by path
    let mut seen_groups = std::collections::HashSet::new();
    let mut files: Vec<(String, usize)> = Vec::new();
    for e in &t.entries {
        if let Kind::File { source, .. } = e.kind {
            if source >= t.base || e.path.starts_with(&dyld) {
                continue;
            }
            if let Some(g) = e.link_group
                && !seen_groups.insert(g)
            {
                continue;
            }
            files.push((e.path.clone(), source));
        }
    }
    files.sort_by(|a, b| b.0.matches('/').count().cmp(&a.0.matches('/').count()).then_with(|| a.0.cmp(&b.0)));
    // final hashes of rewritten files, for the CodeResources of the bundles around them
    let mut hashes: HashMap<usize, Item> = HashMap::new();
    for (path, source) in files {
        if !is_macho(&t.head(source, 4)?) {
            continue;
        }
        let data = t.data(source)?;
        if data.len() < 32 {
            continue;
        }
        p.machos += 1;
        let Some(new) = stripped(&data, Some(&mut p.counts))? else {
            p.clean += 1;
            continue;
        };
        if crate::codesign::identity(&new).is_none() {
            // unsigned before: nothing to keep (pacstrip.py --sign would fail the same way)
            return Err(crate::io::bad(format!("{path}: rewritten but not signed, no identity to keep")));
        }
        let (dir, name) = path.rsplit_once('/').unwrap_or(("", path.as_str()));
        let info_path = if dir.is_empty() { "Info.plist".to_string() } else { format!("{dir}/Info.plist") };
        let info = if t.exists(&info_path) { Some(t.read(&info_path)?) } else { None };
        let mut ctx = Context::default();
        let dir_name = dir.rsplit('/').next().unwrap_or(dir);
        if bundle::is_main_executable(info.as_deref(), dir_name, name) {
            let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
            let mut items: Vec<(String, Item)> = Vec::new();
            for q in t.walk(dir)? {
                let rel = q.strip_prefix(&prefix).unwrap_or(&q).to_string();
                if rel == name || rel == "_CodeSignature" || rel.starts_with("_CodeSignature/") {
                    continue;
                }
                match t.kind_of(&q) {
                    Some(Kind::Symlink { target }) => items.push((rel, Item::Symlink(target))),
                    Some(Kind::File { source: s, .. }) => {
                        let it = match hashes.get(&s) {
                            Some(Item::File { sha1, sha256 }) => Item::File { sha1: *sha1, sha256: *sha256 },
                            _ => Item::file(&t.data(s)?),
                        };
                        items.push((rel, it));
                    }
                    _ => {}
                }
            }
            let cr = bundle::code_resources(&items);
            let cs_dir = format!("{prefix}_CodeSignature");
            t.makedirs(&cs_dir)?;
            let cr_path = format!("{cs_dir}/CodeResources");
            t.write(&cr_path, &cr)?;
            p.bundles_sealed += 1;
            ctx = Context { info_plist: info, code_resources: Some(cr), len: 0 };
        }
        let signed = crate::codesign::resign(&new, ctx.info_plist.clone(), ctx.code_resources.clone())?;
        hashes.insert(source, Item::file(&signed));
        ctx.len = signed.len() as u64;
        p.signed.insert(source, ctx);
    }
    Ok(p)
}

/// Gives the entries of re-signed files their final size.
pub fn apply_sizes(plan: &Plan, entries: &mut [crate::hfswrite::Entry]) {
    for e in entries {
        if let Kind::File { len, source } = &mut e.kind
            && let Some(c) = plan.signed.get(source)
        {
            *len = c.len;
        }
    }
}

/// Pass 2: the bytes the image gets for a scanned file (rewritten and re-signed when the plan says so).
pub fn final_bytes(plan: &Plan, source: usize, data: Vec<u8>) -> Result<Vec<u8>> {
    let Some(ctx) = plan.signed.get(&source) else { return Ok(data) };
    let new = stripped(&data, None)?.unwrap_or(data);
    crate::codesign::resign(&new, ctx.info_plist.clone(), ctx.code_resources.clone())
}
