//! The whole root build, IPSW in, sparse `userdata` image out (`renegade root` of the Python tools, stage by
//! stage): copy (the three APFS volumes merged, cryptexes first and the OS volume on top), the layout fixes,
//! the tweaks, the macho stage (pacstrip + ad-hoc re-signing), the dyld cache stage, and the seal (an HFSX
//! volume written in image order into an Android sparse image).
//!
//! Everything is a stream: files are read from the APFS volumes when the image writer needs them, never
//! all at once, so the same code runs natively over a local or remote IPSW and in the browser over a `File`.

use crate::apfs::{Container, Kind as AKind, Volume};
use crate::dsc;
use crate::hfswrite::{self, Entry, Kind};
use crate::io::{bad, ReadAt, Src};
use crate::ipsw::{Image, Ipsw};
use crate::machostage;
use crate::sparse::SparseWriter;
use crate::tree;
use crate::tweaks::{self, TreeFs};
use std::collections::HashMap;
use std::io::{Result, Seek, Write};
use std::rc::Rc;
use unicode_normalization::UnicodeNormalization;

pub struct Config {
    /// The AEA keys' private keys (PEM) by the key URL the archives name, when the IPSW has `.aea` images.
    pub pems: Vec<(String, String)>,
    /// unix seconds for dates of new files and the volume
    pub now: u32,
    pub verify_aea: bool,
    /// strip + re-sign the Mach-Os
    pub macho: bool,
    /// the dyld shared cache stage (None: leave the cache as Apple built it, it will not run on the phone)
    pub cache: Option<dsc::Options>,
    pub tweaks: bool,
    pub quiet: bool,
    /// The prebuilt on-device tools (berga-tools.zip); without them the root has no SSH, no first-boot job, ...
    pub tools: Option<crate::tools::Tools>,
    /// The public key SSH logs in with (needs `tools`).
    pub ssh_key: Option<String>,
    /// volume size in bytes (None: used + 6 GiB, at least 24 GiB)
    pub volume_size: Option<u64>,
    /// Debugging: keep only the entries at or under this path (and its folders); implies nothing else.
    pub only: Option<String>,
    /// Called once with the final entries just before the image is written (tests compare the tree).
    pub entries_tap: Option<Box<dyn FnOnce(&[Entry])>>,
    /// Called with (path, byte offset, chunk) for every chunk of every file written (tests compare with a reference).
    pub tap: Option<Box<dyn FnMut(&str, u64, &[u8])>>,
}

impl Default for Config {
    fn default() -> Self {
        Config { pems: Vec::new(), now: 0, verify_aea: false, macho: true, cache: Some(dsc::Options::default()), tweaks: true, quiet: false, tools: None, ssh_key: None, volume_size: None, only: None, entries_tap: None, tap: None }
    }
}

#[derive(Debug, Clone)]
pub enum Event<'a> {
    Stage(&'a str),
    Log(&'a str),
    /// bytes of file data written so far, of the total
    Bytes(u64, u64),
}

#[derive(Debug, Default, Clone)]
pub struct Summary {
    pub entries: usize,
    pub machos: u64,
    pub signed: usize,
    pub image_bytes: u64,
    pub chunks: u32,
    pub stats: hfswrite::Stats,
}

/// The (board, ADT target) the iOS root is built for, by device (tools/renegade/targets.py).
pub fn board_for(device: &str) -> (&'static str, &'static str) {
    match device {
        "iPhone11,8" => ("N841", "D22"),
        _ => ("N104", "N104"),
    }
}

struct Vol {
    vol: Volume<Src>,
    image: Image,
}

fn pick_volume(c: &Container<Src>, image: Image) -> Result<Volume<Src>> {
    let vols = c.volumes()?;
    let v = vols.iter().find(|v| v.role == 1).or_else(|| vols.first()).ok_or_else(|| bad(format!("{}: no volume in the APFS container", image.name())))?;
    c.volume(v.index)
}

fn read_all(vol: &Volume<Src>, ino: u64) -> Result<Vec<u8>> {
    let f = vol.open_file(ino)?;
    f.read_vec(0, f.size() as usize)
}

/// Streams a file of a volume in pieces.
fn stream(vol: &Volume<Src>, ino: u64, sink: &mut dyn FnMut(&[u8]) -> Result<()>) -> Result<()> {
    let f = vol.open_file(ino)?;
    let size = f.size();
    let mut buf = vec![0u8; (4 << 20).min(size.max(1) as usize)];
    let mut off = 0;
    while off < size {
        let n = buf.len().min((size - off) as usize);
        f.read_at(off, &mut buf[..n])?;
        sink(&buf[..n])?;
        off += n as u64;
    }
    Ok(())
}

/// Builds the root from the IPSW into `out` (a sparse image, written in order).
pub fn build<W: Write + Seek>(ipsw: &Ipsw, cfg: &mut Config, out: W, ev: &mut dyn FnMut(Event)) -> Result<(W, Summary)> {
    let mut sum = Summary::default();
    ev(Event::Stage("open"));
    ev(Event::Log(&format!("{} {} ({})", ipsw.manifest.device, ipsw.manifest.version, ipsw.manifest.build)));
    let mut vols: Vec<Vol> = Vec::new();
    for im in Image::ALL {
        let pem = match ipsw.key_url(im)? {
            Some(u) => Some(cfg.pems.iter().find(|(k, _)| *k == u).map(|(_, p)| p.as_str()).ok_or_else(|| bad(format!("{}: the key at {u} was not provided", im.name())))?),
            None => None,
        };
        let src = ipsw.open_image(im, pem, cfg.verify_aea)?;
        let c = Container::open(src)?;
        let v = pick_volume(&c, im)?;
        ev(Event::Log(&format!("{}: volume {:?}, {} files", im.name(), v.info().name, v.info().num_files)));
        vols.push(Vol { vol: v, image: im });
    }

    // --- copy: the volumes merged as ditto does it, later ones on top -----------------------------------------
    ev(Event::Stage("copy"));
    let mut entries: Vec<Entry> = Vec::new();
    let mut files: Vec<(usize, u64)> = Vec::new(); // source -> (volume, inode)
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut groups: HashMap<(usize, u64), u64> = HashMap::new();
    for (vi, v) in vols.iter().enumerate() {
        v.vol.walk(&mut |n| {
            let kind = match n.kind {
                AKind::Dir => Kind::Dir,
                AKind::File => {
                    files.push((vi, n.ino));
                    Kind::File { len: n.size, source: files.len() - 1 }
                }
                AKind::Symlink => Kind::Symlink { target: n.target.unwrap_or("").to_string() },
                AKind::Other(_) => return Ok(()),
            };
            let link_group = (matches!(kind, Kind::File { .. }) && n.nlink > 1).then(|| {
                let next = groups.len() as u64;
                *groups.entry((vi, n.ino)).or_insert(next)
            });
            let e = Entry { path: n.path.to_string(), kind, uid: n.uid, gid: n.gid, perm: n.mode & 0o7777, mtime: n.mtime.clamp(0, u32::MAX as i64) as u32, link_group };
            match index.get(n.path) {
                None => {
                    index.insert(e.path.clone(), entries.len());
                    entries.push(e);
                }
                Some(&i) => {
                    // a symlink over a real folder of the merged cryptex leaves the folder (ditto: "Is a directory")
                    if !(entries[i].kind == Kind::Dir && matches!(e.kind, Kind::Symlink { .. })) {
                        entries[i] = e;
                    }
                }
            }
            Ok(())
        })?;
        ev(Event::Log(&format!("{}: {} entries so far", v.image.name(), entries.len())));
    }
    // the OS volume's root has a `.file` entry the Python copy (ditto: "Permission denied") never gets to copy
    entries.retain(|e| e.path != ".file");
    tree::layout_fixes(&mut entries, cfg.now)?;
    if let Some(only) = &cfg.only {
        let sub = format!("{only}/");
        entries.retain(|e| e.path.is_empty() || e.path == *only || e.path.starts_with(&sub) || only.starts_with(&format!("{}/", e.path)));
    }
    sum.entries = entries.len();
    ev(Event::Log(&format!("{} entries after the layout fixes", entries.len())));

    // the dyld cache files, by source
    let dyld_prefix = format!("{}/", tree::DYLD_DIR);
    let mut cache_srcs: Vec<(String, usize)> = Vec::new();
    for e in &entries {
        if let Kind::File { source, .. } = e.kind
            && let Some(name) = e.path.strip_prefix(&dyld_prefix)
            && name.starts_with(dsc::MAIN_NAME)
        {
            cache_srcs.push((name.to_string(), source));
        }
    }

    // The first bytes of every file (the Mach-O test), read in the order the volumes store the files: a random
    // order would decode a megabyte of the disk image for every four bytes.
    ev(Event::Stage("scan"));
    let mut heads: HashMap<usize, [u8; 4]> = HashMap::new();
    {
        let mut order: Vec<(u64, usize)> = Vec::new();
        for e in &entries {
            if let Kind::File { source, len } = e.kind
                && source < files.len()
                && len >= 32
                && !e.path.starts_with(&dyld_prefix)
            {
                order.push((((files[source].0 as u64) << 56) | files[source].1.min((1 << 56) - 1), source));
            }
        }
        order.sort_unstable();
        order.dedup_by_key(|o| o.1);
        for (n, &(_, source)) in order.iter().enumerate() {
            let (v, ino) = files[source];
            let f = vols[v].vol.open_file(ino)?;
            let mut h = [0u8; 4];
            if f.size() >= 4 {
                f.read_at(0, &mut h)?;
            }
            heads.insert(source, h);
            if n % 20000 == 0 {
                ev(Event::Log(&format!("scanned {n} of {} files", order.len())));
            }
        }
    }
    // --- tweaks ----------------------------------------------------------------------------------------------------
    let base = files.len();
    let vols_ref = &vols;
    let files_ref = &files;
    let mut tfs = TreeFs::new(entries, base, cfg.now, |s| {
        let (v, ino) = files_ref[s];
        read_all(&vols_ref[v].vol, ino)
    });
    tfs.set_peek(|s, n| match heads.get(&s) {
        Some(h) => Ok(h[..n.min(4)].to_vec()),
        None => {
            let (v, ino) = files_ref[s];
            let f = vols_ref[v].vol.open_file(ino)?;
            f.read_vec(0, (f.size() as usize).min(n))
        }
    });
    let mut map: std::collections::BTreeMap<String, (u32, u32, u32)> = Default::default();
    if cfg.tweaks {
        ev(Event::Stage("tweaks"));
        let (board, adt) = board_for(&ipsw.manifest.device);
        let tc = tweaks::Config {
            build: ipsw.manifest.build.clone(),
            version: ipsw.manifest.version.clone(),
            board: board.into(),
            adt_target: adt.into(),
            quiet: cfg.quiet,
            netcfg: cfg.tools.as_ref().and_then(|t| t.get("sweetnet/sweetnetcfg")).map(<[u8]>::to_vec),
            sweetreboot: cfg.tools.as_ref().and_then(|t| t.get("sweetnet/sweetreboot")).map(<[u8]>::to_vec),
            root_display: String::new(),
            tools: cfg.tools.clone(),
            ssh_key: cfg.ssh_key.clone(),
            ssh_key_name: None,
        };
        let mut log = Vec::new();
        tweaks::run(&mut tfs, &tc, &mut log)?;
        for l in &log {
            ev(Event::Log(&format!("tweaks: {l}")));
        }
        let recorded: Vec<(String, (u32, u32))> = tweaks::Fs::owners(&tfs).iter().map(|(k, v)| (k.clone(), *v)).collect();
        for (p, (u, g)) in recorded {
            let perm = tweaks::Fs::stat(&tfs, &p).map(|s| s.2).unwrap_or(0o644);
            map.insert(p.nfd().collect(), (u, g, perm));
        }
    }

    // --- macho ----------------------------------------------------------------------------------------------------
    let plan = if cfg.macho {
        ev(Event::Stage("macho"));
        let p = machostage::plan(&mut tfs, tree::DYLD_DIR)?;
        ev(Event::Log(&format!("macho: {} Mach-Os, {} rewritten and re-signed ({} bundles sealed), {} unchanged", p.machos, p.signed.len(), p.bundles_sealed, p.clean)));
        sum.machos = p.machos;
        sum.signed = p.signed.len();
        p
    } else {
        machostage::Plan::default()
    };

    // --- cache -------------------------------------------------------------------------------------------------------
    let mut cache_plans: HashMap<usize, dsc::FilePlan> = HashMap::new();
    if let Some(copts) = &cfg.cache {
        ev(Event::Stage("cache"));
        let srcs: Vec<(String, Src)> = cache_srcs
            .iter()
            .map(|(n, s)| {
                let (v, ino) = files[*s];
                Ok((n.clone(), Rc::new(vols[v].vol.open_file(ino)?) as Src))
            })
            .collect::<Result<_>>()?;
        let cache = dsc::Cache::open(srcs)?;
        let plans = cache.plan(copts, &mut |m| ev(Event::Log(m)))?;
        for (name, source) in &cache_srcs {
            if let Some(p) = plans.get(name)
                && !p.is_empty()
            {
                cache_plans.insert(*source, p.clone());
            }
        }
        ev(Event::Log(&format!("cache: {} of {} files to rewrite", cache_plans.len(), cache_srcs.len())));
    }

    // --- seal: owners, the image ------------------------------------------------------------------------------------
    ev(Event::Stage("seal"));
    let TreeFs { mut entries, overlay, .. } = tfs;
    machostage::apply_sizes(&plan, &mut entries);
    let (mapped, _) = tree::apply_map(&mut entries, &map, false);
    ev(Event::Log(&format!("owners: {mapped} from the tweaks")));
    let mut data_bytes = 0u64;
    let mut est = 0u64;
    for e in &entries {
        if let Kind::File { len, .. } = e.kind {
            data_bytes += len;
            est += len.next_multiple_of(4096);
        }
    }
    est += entries.len() as u64 * 700;
    let vol_size = cfg.volume_size.unwrap_or_else(|| (est + (6 << 30)).next_multiple_of(1 << 30).max(24 << 30));
    // data goes into the image in the order the volumes store it, so every disk image is read front to back
    let order_key: Vec<u64> = files.iter().map(|&(v, ino)| ((v as u64) << 56) | ino.min((1 << 56) - 1)).collect();
    let o = hfswrite::Options { volume_name: "iOSRoot".into(), block_size: 4096, size: Some(vol_size), date: cfg.now, data_order: Some(order_key) };
    let mut w = SparseWriter::new(out, 4096)?;
    let mut done = 0u64;
    let mut last_report = 0u64;
    let paths: HashMap<usize, String> = entries.iter().filter_map(|e| if let Kind::File { source, .. } = e.kind { Some((source, e.path.clone())) } else { None }).collect();
    if let Some(t) = cfg.entries_tap.take() {
        t(&entries);
    }
    let mut tap = cfg.tap.take();
    let st = {
        let mut feed = |source: usize, sink: &mut dyn FnMut(&[u8]) -> Result<()>| -> Result<()> {
            let path = paths.get(&source).map(String::as_str).unwrap_or("");
            let mut off = 0u64;
            let mut put = |b: &[u8]| -> Result<()> {
                if let Some(t) = tap.as_mut() {
                    t(path, off, b);
                }
                off += b.len() as u64;
                done += b.len() as u64;
                if done - last_report >= (64 << 20) {
                    last_report = done;
                    ev(Event::Bytes(done, data_bytes));
                }
                sink(b)
            };
            if source >= base {
                return put(&overlay[source - base]);
            }
            let (v, ino) = files[source];
            let mut one = || -> Result<()> {
                if let Some(p) = cache_plans.get(&source) {
                    let mut d = read_all(&vols[v].vol, ino)?;
                    p.apply(&mut d)?;
                    return put(&d);
                }
                if plan.signed.contains_key(&source) {
                    let d = machostage::final_bytes(&plan, source, read_all(&vols[v].vol, ino)?)?;
                    return put(&d);
                }
                stream(&vols[v].vol, ino, &mut put)
            };
            one().map_err(|e| bad(format!("{path}: {e}")))
        };
        hfswrite::build(&entries, &o, &mut w, &mut feed)?
    };
    ev(Event::Bytes(data_bytes, data_bytes));
    let (out, s) = w.finish(st.total_blocks as u64 * 4096)?;
    sum.image_bytes = st.total_blocks as u64 * 4096;
    sum.chunks = s.chunks;
    ev(Event::Log(&format!("image: {} folders, {} files ({} hard links), {} of {} blocks free, {} sparse chunks", st.folders, st.files, st.hard_links, st.free_blocks, st.total_blocks, s.chunks)));
    sum.stats = st;
    Ok((out, sum))
}
