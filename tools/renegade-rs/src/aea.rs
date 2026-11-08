//! Apple Encrypted Archive (AEA1) decryption, as a random-access reader: the IPSW's `.dmg.aea` members come
//! out as the dmg they hold without an output file. Profile 1 (symmetric key; HKDF-SHA256, AES-256-CTR,
//! HMAC-SHA256), segments of `segment_size` bytes in clusters, each segment compressed (LZFSE/LZBITMAP/...) or
//! not. A port of blacktop/ipsw's pure-Go decryptor (pkg/aea).
//!
//! The key: [`fcs_key`] opens the `com.apple.wkms.fcs-response` of the archive's metadata with HPKE
//! (DHKEM P-256, HKDF-SHA256, AES-256-GCM) using the private key published at `com.apple.wkms.fcs-key-url`
//! (a PEM file the caller downloads: the browser cannot reach Apple's host, the Worker proxies it).

use crate::bytes::{u32le, u64le};
use crate::io::{bad, ReadAt, Src};
use aes::cipher::{KeyIvInit, StreamCipher};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::io::Result;
use std::rc::Rc;

type Aes256Ctr = ctr::Ctr128BE<aes::Aes256>;

const MAIN_KEY_INFO: &[u8] = b"AEA_AMK";
const ROOT_HEADER_INFO: &[u8] = b"AEA_RHEK";
const CLUSTER_KEY_INFO: &[u8] = b"AEA_CK";
const CLUSTER_MATERIAL_INFO: &[u8] = b"AEA_CHEK";
const SEGMENT_KEY_INFO: &[u8] = b"AEA_SK";

/// Metadata key/value pairs of the header (`com.apple.wkms.fcs-key-url`, ...), values as raw bytes.
pub fn metadata(src: &dyn ReadAt) -> Result<Vec<(String, Vec<u8>)>> {
    let h = src.read_vec(0, 12)?;
    if &h[..4] != b"AEA1" {
        return Err(bad("not an AEA1 archive"));
    }
    let n = u32le(&h, 8) as usize;
    if n > (1 << 24) {
        return Err(bad("AEA auth data too large"));
    }
    let a = src.read_vec(12, n)?;
    let mut out = Vec::new();
    let mut i = 0;
    while i + 4 <= a.len() {
        let len = u32le(&a, i) as usize;
        if len < 4 || i + len > a.len() {
            return Err(bad("bad AEA metadata record"));
        }
        let kv = &a[i + 4..i + len];
        let z = kv.iter().position(|&c| c == 0).unwrap_or(kv.len());
        out.push((String::from_utf8_lossy(&kv[..z]).into_owned(), kv.get(z + 1..).unwrap_or(&[]).to_vec()));
        i += len;
    }
    Ok(out)
}

/// The URL of the private key (`com.apple.wkms.fcs-key-url`) the archive's key is wrapped for.
pub fn key_url(src: &dyn ReadAt) -> Result<String> {
    let md = metadata(src)?;
    md.into_iter().find(|(k, _)| k == "com.apple.wkms.fcs-key-url").map(|(_, v)| String::from_utf8_lossy(&v).into_owned()).ok_or_else(|| bad("the archive has no fcs-key-url"))
}

/// The archive's symmetric key: HPKE-opens the fcs-response with the private key PEM (PKCS#8, P-256).
pub fn fcs_key(src: &dyn ReadAt, pem: &str) -> Result<Vec<u8>> {
    let md = metadata(src)?;
    if let Some((_, v)) = md.iter().find(|(k, _)| k == "encryption_key") {
        return unhex(&String::from_utf8_lossy(v));
    }
    let resp = md.iter().find(|(k, _)| k == "com.apple.wkms.fcs-response").map(|(_, v)| v.clone()).ok_or_else(|| bad("no com.apple.wkms.fcs-response in the archive"))?;
    let text = String::from_utf8_lossy(&resp).into_owned();
    let enc = b64_decode(&json_str(&text, "enc-request").ok_or_else(|| bad("fcs-response without enc-request"))?)?;
    let wrapped = b64_decode(&json_str(&text, "wrapped-key").ok_or_else(|| bad("fcs-response without wrapped-key"))?)?;
    hpke_open(pem, &enc, &wrapped)
}

fn unhex(s: &str) -> Result<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return Err(bad("odd hex length"));
    }
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).map_err(|_| bad("bad hex"))).collect()
}

/// `"name": "value"` out of a flat JSON object (no escapes in these values).
fn json_str(j: &str, name: &str) -> Option<String> {
    let k = j.find(&format!("\"{name}\""))?;
    let rest = &j[k + name.len() + 2..];
    let q1 = rest.find('"')?;
    let rest = &rest[q1 + 1..];
    Some(rest[..rest.find('"')?].to_string())
}

pub fn b64_decode(s: &str) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\n' | b'\r' | b' ' => continue,
            _ => return Err(bad("bad base64")),
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

pub fn b64_encode(d: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in d.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                s.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

// --- HPKE (RFC 9180), base mode, DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM, empty info ----------------
fn labeled_extract(suite: &[u8], salt: &[u8], label: &[u8], ikm: &[u8]) -> Vec<u8> {
    let mut l = b"HPKE-v1".to_vec();
    l.extend_from_slice(suite);
    l.extend_from_slice(label);
    l.extend_from_slice(ikm);
    let (prk, _) = Hkdf::<Sha256>::extract(Some(salt), &l);
    prk.to_vec()
}

fn labeled_expand(suite: &[u8], prk: &[u8], label: &[u8], info: &[u8], len: usize) -> Result<Vec<u8>> {
    let mut l = (len as u16).to_be_bytes().to_vec();
    l.extend_from_slice(b"HPKE-v1");
    l.extend_from_slice(suite);
    l.extend_from_slice(label);
    l.extend_from_slice(info);
    let h = Hkdf::<Sha256>::from_prk(prk).map_err(|_| bad("bad PRK"))?;
    let mut out = vec![0; len];
    h.expand(&l, &mut out).map_err(|_| bad("HKDF expand"))?;
    Ok(out)
}

pub fn hpke_open(pem: &str, enc: &[u8], ct: &[u8]) -> Result<Vec<u8>> {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    use p256::elliptic_curve::sec1::ToEncodedPoint;
    use p256::pkcs8::DecodePrivateKey;
    let sk = p256::SecretKey::from_pkcs8_pem(pem).map_err(|e| bad(format!("private key: {e}")))?;
    let pk_e = p256::PublicKey::from_sec1_bytes(enc).map_err(|_| bad("bad ephemeral public key"))?;
    let dh = p256::ecdh::diffie_hellman(sk.to_nonzero_scalar(), pk_e.as_affine());
    let pk_r = sk.public_key().to_encoded_point(false).as_bytes().to_vec();
    let kem_suite = [b"KEM".as_slice(), &[0x00, 0x10]].concat();
    let eae = labeled_extract(&kem_suite, &[], b"eae_prk", dh.raw_secret_bytes());
    let ctx = [enc, &pk_r].concat();
    let shared = labeled_expand(&kem_suite, &eae, b"shared_secret", &ctx, 32)?;
    let suite = [b"HPKE".as_slice(), &[0x00, 0x10, 0x00, 0x01, 0x00, 0x02]].concat();
    let psk_id_hash = labeled_extract(&suite, &[], b"psk_id_hash", &[]);
    let info_hash = labeled_extract(&suite, &[], b"info_hash", &[]);
    let ksc = [&[0u8][..], &psk_id_hash, &info_hash].concat();
    let secret = labeled_extract(&suite, &shared, b"secret", &[]);
    let key = labeled_expand(&suite, &secret, b"key", &ksc, 32)?;
    let nonce = labeled_expand(&suite, &secret, b"base_nonce", &ksc, 12)?;
    let c = aes_gcm::Aes256Gcm::new_from_slice(&key).map_err(|_| bad("key"))?;
    c.decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: ct, aad: &[] }).map_err(|_| bad("HPKE: the wrapped key does not open (wrong private key?)"))
}

// --- the archive ----------------------------------------------------------------------------------------------
struct HeaderKey {
    mac: [u8; 32],
    key: [u8; 32],
    iv: [u8; 16],
}

fn hkdf_bytes(ikm: &[u8], salt: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    let h = Hkdf::<Sha256>::new(if salt.is_empty() { None } else { Some(salt) }, ikm);
    let mut out = vec![0; len];
    h.expand(info, &mut out).expect("hkdf length");
    out
}

fn header_key(ikm: &[u8], info: &[u8]) -> HeaderKey {
    let b = hkdf_bytes(ikm, &[], info, 80);
    HeaderKey { mac: b[..32].try_into().unwrap(), key: b[32..64].try_into().unwrap(), iv: b[64..80].try_into().unwrap() }
}

fn info_idx(label: &[u8], n: u32) -> Vec<u8> {
    let mut v = label.to_vec();
    v.extend_from_slice(&n.to_le_bytes());
    v
}

fn ctr(data: &mut [u8], key: &[u8; 32], iv: &[u8; 16]) {
    Aes256Ctr::new(key.into(), iv.into()).apply_keystream(data);
}

/// HMAC-SHA256(key, salt || data || len(salt) as u64le)
fn aea_hmac(key: &[u8], data: &[u8], salt: &[u8]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("hmac key");
    m.update(salt);
    m.update(data);
    m.update(&(salt.len() as u64).to_le_bytes());
    m.finalize().into_bytes().into()
}

#[derive(Clone, Copy)]
struct Seg {
    /// where the (encrypted, compressed) segment data lies in the archive
    off: u64,
    comp: u32,
    raw: u32,
    checksum: [u8; 32],
}

struct Cluster {
    key: Vec<u8>,
    segs: Vec<Seg>,
}

type SegCache = (HashMap<u64, Rc<Vec<u8>>>, VecDeque<u64>);

pub struct Aea {
    src: Src,
    size: u64,
    seg_size: u32,
    seg_per_cluster: u32,
    compression: u8,
    checksum: u8,
    clusters: Vec<Cluster>,
    /// check every segment's checksum while reading
    pub verify: bool,
    cache: RefCell<SegCache>,
    cache_segments: usize,
}

fn checksum_len(t: u8) -> Result<usize> {
    match t {
        0 => Ok(0),
        1 => Ok(8),
        2 => Ok(32),
        _ => Err(bad(format!("unsupported AEA checksum type {t}"))),
    }
}

impl Aea {
    /// Opens the archive with its symmetric key and indexes every cluster's segment table (one small read per
    /// cluster). `verify`: check every segment's checksum while reading (slower).
    pub fn open(src: Src, key: &[u8], verify: bool) -> Result<Self> {
        let h = src.read_vec(0, 12)?;
        if &h[..4] != b"AEA1" {
            return Err(bad("not an AEA1 archive"));
        }
        let pas = u32le(&h, 4);
        if pas & 0xffffff != 1 {
            return Err(bad(format!("AEA profile {} is not supported (only 1: symmetric encryption)", pas & 0xffffff)));
        }
        let auth_len = u32le(&h, 8) as usize;
        if auth_len > (1 << 24) {
            return Err(bad("AEA auth data too large"));
        }
        let auth = src.read_vec(12, auth_len)?;
        let mut pos = 12 + auth_len as u64;
        let salt = src.read_vec(pos, 32)?;
        pos += 32;
        let main_key = hkdf_bytes(key, &salt, &info_idx(MAIN_KEY_INFO, pas), 32);
        let enc_root = src.read_vec(pos, 32 + 48 + 32)?;
        pos += 112;
        let (root_mac, root_data, cluster_hmac) = (&enc_root[..32], &enc_root[32..80], &enc_root[80..112]);
        let rk = header_key(&main_key, ROOT_HEADER_INFO);
        let salt2 = [cluster_hmac, &auth[..]].concat();
        if aea_hmac(&rk.mac, root_data, &salt2) != root_mac {
            return Err(bad("AEA root header HMAC does not match: wrong key?"));
        }
        let mut rd = [root_data, &auth[..]].concat();
        ctr(&mut rd, &rk.key, &rk.iv);
        let file_size = u64le(&rd, 0);
        let seg_size = u32le(&rd, 16);
        let seg_per_cluster = u32le(&rd, 20);
        let compression = rd[24];
        let checksum = rd[25];
        let cs = checksum_len(checksum)?;
        if seg_size == 0 || seg_per_cluster == 0 || seg_per_cluster > 65536 || seg_size > (64 << 20) {
            return Err(bad("implausible AEA segment geometry"));
        }
        let hdr_len = seg_per_cluster as usize * (cs + 8);
        let mut clusters = Vec::new();
        let mut total = 0u64;
        let mut cmac = cluster_hmac.to_vec();
        let mut cindex = 0u32;
        while total < file_size {
            let ckey = hkdf_bytes(&main_key, &[], &info_idx(CLUSTER_KEY_INFO, cindex), 32);
            let hk = header_key(&ckey, CLUSTER_MATERIAL_INFO);
            let raw = src.read_vec(pos, hdr_len + 32 + 32 * seg_per_cluster as usize)?;
            let enc_hdrs = &raw[..hdr_len];
            let next_mac = &raw[hdr_len..hdr_len + 32];
            let seg_macs = &raw[hdr_len + 32..];
            let salt3 = [next_mac, seg_macs].concat();
            if aea_hmac(&hk.mac, enc_hdrs, &salt3) != cmac[..] {
                return Err(bad(format!("AEA cluster {cindex}: header HMAC does not match")));
            }
            let mut hd = enc_hdrs.to_vec();
            ctr(&mut hd, &hk.key, &hk.iv);
            pos += raw.len() as u64;
            let mut segs = vec![Seg { off: 0, comp: 0, raw: 0, checksum: [0; 32] }; seg_per_cluster as usize];
            for (s, seg) in segs.iter_mut().enumerate() {
                let e = &hd[s * (cs + 8)..(s + 1) * (cs + 8)];
                let (rawsz, comp) = (u32le(e, 0), u32le(e, 4));
                if rawsz == 0 {
                    continue;
                }
                if rawsz > seg_size {
                    return Err(bad("AEA segment larger than the segment size"));
                }
                let mut checksum_b = [0u8; 32];
                checksum_b[..cs].copy_from_slice(&e[8..8 + cs]);
                *seg = Seg { off: pos, comp, raw: rawsz, checksum: checksum_b };
                pos += comp as u64;
                total += rawsz as u64;
            }
            clusters.push(Cluster { key: ckey, segs });
            cmac = next_mac.to_vec();
            cindex += 1;
        }
        Ok(Aea { src, size: file_size, seg_size, seg_per_cluster, compression, checksum, clusters, verify, cache: RefCell::new((HashMap::new(), VecDeque::new())), cache_segments: 48 })
    }

    pub fn set_cache_segments(&mut self, n: usize) {
        self.cache_segments = n.max(2);
    }

    fn segment(&self, index: u64) -> Result<Rc<Vec<u8>>> {
        if let Some(s) = self.cache.borrow().0.get(&index) {
            return Ok(s.clone());
        }
        let (c, s) = ((index / self.seg_per_cluster as u64) as usize, (index % self.seg_per_cluster as u64) as u32);
        let cl = self.clusters.get(c).ok_or_else(|| bad("AEA segment out of range"))?;
        let seg = cl.segs[s as usize];
        if seg.raw == 0 {
            return Err(bad("AEA hole"));
        }
        let mut data = self.src.read_vec(seg.off, seg.comp as usize)?;
        let sk = header_key(&cl.key, &info_idx(SEGMENT_KEY_INFO, s));
        ctr(&mut data, &sk.key, &sk.iv);
        let out = if seg.raw == seg.comp {
            data
        } else {
            match self.compression {
                b'-' => data,
                b'e' => {
                    let mut o = Vec::with_capacity(seg.raw as usize);
                    lzfse_rust::decode_bytes(&data, &mut o).map_err(|e| bad(format!("AEA LZFSE segment {index}: {e}")))?;
                    o
                }
                b'b' => crate::apfs::lzbitmap::decode(&data, seg.raw as usize)?,
                b'f' => crate::apfs::lzvn::decode(&data, seg.raw as usize)?,
                b'z' => miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&data, seg.raw as usize + 1).map_err(|e| bad(format!("AEA zlib segment: {:?}", e.status)))?,
                c => return Err(bad(format!("unsupported AEA compression '{}'", c as char))),
            }
        };
        if out.len() != seg.raw as usize {
            return Err(bad(format!("AEA segment {index}: {} bytes, expected {}", out.len(), seg.raw)));
        }
        if self.verify && self.checksum == 2 && Sha256::digest(&out)[..] != seg.checksum[..] {
            return Err(bad(format!("AEA segment {index}: SHA-256 mismatch")));
        }
        let rc = Rc::new(out);
        let mut c = self.cache.borrow_mut();
        c.0.insert(index, rc.clone());
        c.1.push_back(index);
        while c.1.len() > self.cache_segments {
            if let Some(old) = c.1.pop_front() {
                c.0.remove(&old);
            }
        }
        Ok(rc)
    }
}

impl ReadAt for Aea {
    fn size(&self) -> u64 {
        self.size
    }
    fn read_at(&self, off: u64, buf: &mut [u8]) -> Result<()> {
        if off.checked_add(buf.len() as u64).is_none_or(|e| e > self.size) {
            return Err(crate::io::short(off));
        }
        let mut done = 0usize;
        while done < buf.len() {
            let pos = off + done as u64;
            let idx = pos / self.seg_size as u64;
            let s = self.segment(idx)?;
            let o = (pos % self.seg_size as u64) as usize;
            let n = (buf.len() - done).min(s.len().saturating_sub(o));
            if n == 0 {
                return Err(bad("AEA read past a short segment"));
            }
            buf[done..done + n].copy_from_slice(&s[o..o + n]);
            done += n;
        }
        Ok(())
    }
}
