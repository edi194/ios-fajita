//! A root as a list of [`crate::hfswrite::Entry`]: scanned from a directory (native builds) and given its real
//! owners from an owner map, with the rule of `hfsroot_owners.py --default-root`.

use crate::hfsedit::OwnerMap;
use crate::hfswrite::{Entry, Kind};
use unicode_normalization::UnicodeNormalization;

/// Owners and permission bits from `map` (keys NFD, "" = root); entries missing from it become 0:0 with their
/// mode kept when `default_root`, otherwise keep what they have. Hard links share their iNode's owner, so a
/// mapped link wins for the whole group, as hfsroot_owners.py applies the map entry of any link to its iNode.
pub fn apply_map(entries: &mut [Entry], map: &OwnerMap, default_root: bool) -> (usize, usize) {
    let (mut mapped, mut defaulted) = (0, 0);
    for e in entries.iter_mut() {
        let key: String = e.path.nfd().collect();
        if let Some(&(u, g, m)) = map.get(&key) {
            e.uid = u;
            e.gid = g;
            e.perm = (m & 0o7777) as u16;
            mapped += 1;
        } else if default_root {
            e.uid = 0;
            e.gid = 0;
            defaulted += 1;
        }
    }
    // links of a group: the iNode keeps one owner; use the mapped member when there is one
    let mut chosen: std::collections::HashMap<u64, (u32, u32, u16)> = std::collections::HashMap::new();
    for e in entries.iter() {
        if let (Some(g), Kind::File { .. }) = (e.link_group, &e.kind) {
            let key: String = e.path.nfd().collect();
            if map.contains_key(&key) || !chosen.contains_key(&g) {
                chosen.insert(g, (e.uid, e.gid, e.perm));
            }
        }
    }
    for e in entries.iter_mut() {
        if let Some(&(u, g, p)) = e.link_group.and_then(|g| chosen.get(&g)) {
            e.uid = u;
            e.gid = g;
            e.perm = p;
        }
    }
    (mapped, defaulted)
}

/// Scans `root` with lstat: folders, regular files, symlinks (sockets, fifos and devices are skipped and
/// returned by path). Hard links share a `link_group` (device, inode). File `source` indexes `paths`.
#[cfg(all(unix, not(target_family = "wasm")))]
pub fn scan_dir(root: &std::path::Path) -> std::io::Result<(Vec<Entry>, Vec<std::path::PathBuf>, Vec<String>)> {
    use std::collections::HashMap;
    use std::os::unix::fs::MetadataExt;
    let mut entries = Vec::new();
    let mut paths = Vec::new();
    let mut skipped = Vec::new();
    let mut groups: HashMap<(u64, u64), u64> = HashMap::new();
    let meta = std::fs::symlink_metadata(root)?;
    entries.push(Entry { path: String::new(), kind: Kind::Dir, uid: meta.uid(), gid: meta.gid(), perm: (meta.mode() & 0o7777) as u16, mtime: meta.mtime().max(0) as u32, link_group: None });
    let mut todo = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, rel)) = todo.pop() {
        let mut names: Vec<_> = std::fs::read_dir(&dir)?.collect::<std::io::Result<Vec<_>>>()?;
        names.sort_by_key(|e| e.file_name());
        for ent in names {
            let name = ent.file_name().to_string_lossy().into_owned();
            let p = ent.path();
            let m = std::fs::symlink_metadata(&p)?;
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            let ft = m.file_type();
            let kind = if ft.is_dir() {
                todo.push((p.clone(), path.clone()));
                Kind::Dir
            } else if ft.is_symlink() {
                Kind::Symlink { target: std::fs::read_link(&p)?.to_string_lossy().into_owned() }
            } else if ft.is_file() {
                paths.push(p.clone());
                Kind::File { len: m.len(), source: paths.len() - 1 }
            } else {
                skipped.push(path);
                continue;
            };
            let link_group = (ft.is_file() && m.nlink() > 1).then(|| {
                let n = groups.len() as u64;
                *groups.entry((m.dev(), m.ino())).or_insert(n)
            });
            entries.push(Entry { path, kind, uid: m.uid(), gid: m.gid(), perm: (m.mode() & 0o7777) as u16, mtime: m.mtime().max(0) as u32, link_group });
        }
    }
    Ok((entries, paths, skipped))
}

/// The tree under `prefix` of an existing HFS+ volume (owners, modes, dates and hard links from its catalog),
/// paths relative to `prefix`. File `source` is the file's CNID in the volume (the iNode's for hard links).
pub fn from_volume<R: crate::io::ReadAt>(v: &crate::hfs::Volume<R>, prefix: &str) -> std::io::Result<Vec<Entry>> {
    use crate::bytes::u32be;
    use crate::hfs::{FILE, FOLDER};
    let top = v.lookup(prefix, true)?.filter(|e| e.rt == FOLDER).ok_or_else(|| crate::io::bad(format!("{prefix}: not a folder")))?;
    let meta = |d: usize| -> (u32, u32, u16, u32) {
        let (u, g) = v.owner(d);
        (u, g, v.mode(d) & 0o7777, u32be(&v.cat, d + 16).saturating_sub(crate::hfswrite::HFS_EPOCH_OFFSET))
    };
    let mut out = Vec::new();
    let (u, g, p, t) = top.rec.map(meta).unwrap_or((0, 0, 0o755, 0));
    out.push(Entry { path: String::new(), kind: Kind::Dir, uid: u, gid: g, perm: p, mtime: t, link_group: None });
    let mut todo = vec![(top.cnid, String::new())];
    while let Some((cnid, rel)) = todo.pop() {
        for (name, e) in v.children(cnid) {
            if name.starts_with("\0\0\0\0HFS+") || name == ".HFS+ Private Directory Data\r" {
                continue;
            }
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            let d = e.rec.unwrap();
            if e.rt == FOLDER {
                let (u, g, p, t) = meta(d);
                out.push(Entry { path: path.clone(), kind: Kind::Dir, uid: u, gid: g, perm: p, mtime: t, link_group: None });
                todo.push((e.cnid, path));
                continue;
            }
            if e.rt != FILE {
                continue;
            }
            let link = v.is_hard_link(d);
            let target = v.resolve_link(*e).ok_or_else(|| crate::io::bad(format!("{path}: hard link without iNode")))?;
            let td = target.rec.unwrap();
            let (u, g, p, t) = meta(td);
            let mode = v.mode(td);
            let len = v.fork_of(td).0;
            let kind = if mode & 0o170000 == 0o120000 {
                Kind::Symlink { target: String::from_utf8_lossy(&v.read_file(target)?).into_owned() }
            } else {
                Kind::File { len, source: target.cnid as usize }
            };
            let link_group = (link && matches!(kind, Kind::File { .. })).then_some(target.cnid as u64);
            out.push(Entry { path, kind, uid: u, gid: g, perm: p, mtime: t, link_group });
        }
    }
    Ok(out)
}

/// mkroot-full.py's EXCLUDE (not copied) and prune_after (removed after the copy).
pub const EXCLUDE: [&str; 2] = ["usr/standalone/update", "System/Library/NanoTimeKit"];
pub const DYLD_DIR: &str = "System/Library/Caches/com.apple.dyld";

/// mkroot-full.py's copy-stage clean-up on the tree: the excluded and pruned paths and the macOS junk folders
/// go, the dyld cache's .symbols files go, and /private/preboot/Cryptexes/{OS,App} become symlinks to "../../.."
/// (the cryptexes are merged into the root). Fails without the dyld shared cache.
pub fn layout_fixes(entries: &mut Vec<Entry>, now: u32) -> std::io::Result<()> {
    let junk = [".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100", ".TemporaryItems"];
    let under = |p: &str, top: &str| p == top || p.starts_with(&format!("{top}/"));
    entries.retain(|e| {
        !EXCLUDE.iter().any(|x| under(&e.path, x))
            && !junk.iter().any(|j| under(&e.path, j))
            && !(e.path.starts_with(&format!("{DYLD_DIR}/")) && e.path.ends_with(".symbols"))
    });
    let mut have: std::collections::HashSet<String> = entries.iter().map(|e| e.path.clone()).collect();
    let dir = |p: &str| Entry { path: p.into(), kind: Kind::Dir, uid: 0, gid: 0, perm: 0o755, mtime: now, link_group: None };
    for p in ["private", "private/preboot", "private/preboot/Cryptexes"] {
        if have.insert(p.to_string()) {
            entries.push(dir(p));
        }
    }
    for n in ["OS", "App"] {
        let p = format!("private/preboot/Cryptexes/{n}");
        entries.retain(|e| !under(&e.path, &p));
        entries.push(Entry { path: p, kind: Kind::Symlink { target: "../../..".into() }, uid: 0, gid: 0, perm: 0o755, mtime: now, link_group: None });
    }
    if !entries.iter().any(|e| e.path == format!("{DYLD_DIR}/dyld_shared_cache_arm64e")) {
        return Err(crate::io::bad("no dyld cache in the root"));
    }
    Ok(())
}
