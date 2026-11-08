#!/usr/bin/env python3
"""Read-only HFS+/HFSX reader directly on an Android sparse image: no raw image, no mount, no free disk.

  hfsx.py SIMG ls PATH | cat PATH | get PATH OUT | getdir PATH OUTDIR | stat PATH | find SUBSTR | dsc OUTDIR

The simg chunk table maps raw offsets (RAW/FILL/DONT_CARE), the catalog B-tree is parsed in memory (hard links
through the iNode files, symlinks followed, extents-overflow honoured). `dsc OUTDIR` copies the dyld shared cache
files of the root (not .symbols) for the symbolication tools in tools/renegade/dsctools. Needs ~1 GB RAM for the
catalog of a full iOS root; reading 100 MB takes seconds. A 15 GB simg cannot be converted with simg2img on a Mac
with less than 15 GB free, this reads it where it is.
"""
import struct, sys, bisect, unicodedata, os
RAW, FILL, DONT_CARE, CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4

class Simg:
    def __init__(s, path):
        s.f = open(path, 'rb')
        m, mj, mn, hs, cs, bs, tb, nc, crc = struct.unpack('<IHHHHIIII', s.f.read(28))
        assert m == 0xED26FF3A
        s.bs = bs; s.size = tb * bs
        s.starts = []; s.chunks = []
        pos = 0
        s.f.seek(hs)
        for i in range(nc):
            t, _, sz, tot = struct.unpack('<HHII', s.f.read(12))
            data = s.f.tell()
            if t == FILL: fv = s.f.read(4)
            else: fv = None
            if t == CRC:
                s.f.seek(data + tot - 12); continue
            s.starts.append(pos * bs); s.chunks.append((t, sz * bs, data, fv))
            pos += sz
            s.f.seek(data + (tot - 12))
    def read(s, off, n):
        out = bytearray()
        while n > 0:
            i = bisect.bisect_right(s.starts, off) - 1
            t, ln, data, fv = s.chunks[i]
            o = off - s.starts[i]
            k = min(n, ln - o)
            if t == RAW:
                s.f.seek(data + o); out += s.f.read(k)
            elif t == FILL:
                out += (fv * ((k + 3) // 4 + 1))[:k] if fv != b'\0\0\0\0' else bytes(k)
            else:
                out += bytes(k)
            off += k; n -= k
        return bytes(out)

def u16(b): return b.decode('utf-16-be')

class Vol:
    def __init__(s, img):
        s.img = img
        vh = img.read(1024, 512)
        assert vh[:2] in (b'H+', b'HX')
        s.vh = vh; s.bsize = struct.unpack_from('>I', vh, 40)[0]
        s.overflow = {}
        s._load_overflow()
        s.cat = s.read_fork_all(s.fork(272), 4)
        s._parse_catalog()
    def fork(s, off):
        logical = struct.unpack_from('>Q', s.vh, off)[0]
        ext = [struct.unpack_from('>II', s.vh, off + 16 + 8 * i) for i in range(8)]
        return logical, [e for e in ext if e[1]]
    def _load_overflow(s):
        l, e = s.fork(192)
        data = s.read_extents(e, l)
        ns = struct.unpack_from('>H', data, 14 + 18)[0]
        node = struct.unpack_from('>I', data, 14 + 10)[0]
        while node:
            nd = data[node * ns:(node + 1) * ns]
            flink, blink, kind, h, nrec = struct.unpack_from('>IIbBH', nd, 0)
            for i in range(nrec):
                ro = struct.unpack_from('>H', nd, ns - 2 * (i + 1))[0]
                klen, fk, pad, fid, start = struct.unpack_from('>HBBII', nd, ro)
                ex = []
                for j in range(8):
                    st, c = struct.unpack_from('>II', nd, ro + 2 + klen + 8 * j)
                    if c: ex.append((st, c))
                s.overflow.setdefault((fid, fk), []).append((start, ex))
            node = flink
    def all_extents(s, fid, fk, ext):
        ext = list(ext)
        for start, ex in sorted(s.overflow.get((fid, fk), [])):
            ext += ex
        return ext
    def read_extents(s, ext, size):
        out = bytearray()
        for st, c in ext:
            out += s.img.read(st * s.bsize, c * s.bsize)
            if len(out) >= size: break
        return bytes(out[:size])
    def read_fork_all(s, fk, fid):
        l, ext = fk
        return s.read_extents(s.all_extents(fid, 0, ext), l)
    def _parse_catalog(s):
        cat = s.cat
        ns = struct.unpack_from('>H', cat, 14 + 18)[0]
        n = struct.unpack_from('>I', cat, 14 + 10)[0]
        s.children = {}   # parent -> {name: (type, cnid, rec offset)}
        s.recs = {}
        s.threads = {}
        while n:
            base = n * ns
            flink, blink, kind, h, nrec = struct.unpack_from('>IIbBH', cat, base)
            for i in range(nrec):
                ro = base + struct.unpack_from('>H', cat, base + ns - 2 * (i + 1))[0]
                klen = struct.unpack_from('>H', cat, ro)[0]
                parent = struct.unpack_from('>I', cat, ro + 2)[0]
                nlen = struct.unpack_from('>H', cat, ro + 6)[0]
                name = u16(cat[ro + 8:ro + 8 + 2 * nlen])
                d = ro + 2 + klen; d += d & 1
                rt = struct.unpack_from('>H', cat, d)[0]
                if rt in (1, 2):
                    cnid = struct.unpack_from('>I', cat, d + 8)[0]
                    s.children.setdefault(parent, {})[name] = (rt, cnid, d)
                elif rt == 3:
                    tp = struct.unpack_from('>I', cat, d + 4)[0]
                    s.threads[parent] = tp
            n = flink
        s.private = None
        for nm, (rt, cnid, d) in s.children.get(2, {}).items():
            if nm.startswith('\0\0\0\0HFS+'): s.private = cnid
    def lookup(s, path, follow=True, depth=0):
        cur = 2; rec = None
        parts = [p for p in path.split('/') if p]
        i = 0
        while i < len(parts):
            p = unicodedata.normalize('NFD', parts[i])
            ch = s.children.get(cur, {})
            e = ch.get(p) or ch.get(parts[i])
            if e is None: return None
            rt, cnid, d = e
            if rt == 2:
                ftype, creator = struct.unpack_from('>II', s.cat, d + 48)
                mode = struct.unpack_from('>H', s.cat, d + 32 + 10)[0]
                if (ftype, creator) == (0x686C6E6B, 0x6866732B):
                    num = struct.unpack_from('>I', s.cat, d + 32 + 12)[0]
                    e2 = s.children[s.private].get('iNode%d' % num)
                    rt, cnid, d = e2
                    mode = struct.unpack_from('>H', s.cat, d + 32 + 10)[0]
                if (mode & 0o170000) == 0o120000 and (follow or i < len(parts) - 1):
                    tgt = s.read_file(rt, cnid, d).decode()
                    assert depth < 20
                    if tgt.startswith('/'): np_ = tgt
                    else: np_ = '/' + '/'.join(parts[:i]) + '/' + tgt
                    rest = '/'.join(parts[i + 1:])
                    return s.lookup(os.path.normpath(np_) + '/' + rest, follow, depth + 1)
                if i < len(parts) - 1: return None
                return (rt, cnid, d)
            cur = cnid; rec = (rt, cnid, d)
            i += 1
        return rec if rec else (1, 2, None)
    def fork_of(s, d):
        # data fork at d+88
        return struct.unpack_from('>Q', s.cat, d + 88)[0], [struct.unpack_from('>II', s.cat, d + 88 + 16 + 8 * i) for i in range(8)]
    def file_extents(s, cnid, d):
        l, ext = s.fork_of(d)
        ext = [e for e in ext if e[1]]
        return l, s.all_extents(cnid, 0, ext)
    def read_file(s, rt, cnid, d):
        l, ext = s.file_extents(cnid, d)
        return s.read_extents(ext, l)
    def open(s, path):
        e = s.lookup(path)
        assert e and e[0] == 2, path
        l, ext = s.file_extents(e[1], e[2])
        return VFile(s, l, ext)

class VFile:
    def __init__(s, vol, size, ext):
        s.vol = vol; s.size = size; s.pos = 0
        s.ext = []; o = 0
        for st, c in ext:
            s.ext.append((o, st, c)); o += c * vol.bsize
        s.starts = [e[0] for e in s.ext]
    def seek(s, p, w=0): s.pos = p if w == 0 else (s.pos + p if w == 1 else s.size + p)
    def tell(s): return s.pos
    def read(s, n=-1):
        if n < 0 or s.pos + n > s.size: n = s.size - s.pos
        out = bytearray(); bs = s.vol.bsize
        while n > 0:
            i = bisect.bisect_right(s.starts, s.pos) - 1
            o, st, c = s.ext[i]
            rel = s.pos - o
            k = min(n, c * bs - rel)
            out += s.vol.img.read(st * bs + rel, k)
            s.pos += k; n -= k
        return bytes(out)

def main():
    img = Simg(sys.argv[1]); v = Vol(img)
    cmd = sys.argv[2]
    if cmd == 'ls':
        e = v.lookup(sys.argv[3])
        for nm, (rt, cnid, d) in sorted(v.children.get(e[1], {}).items()):
            print(('d ' if rt == 1 else 'f ') + nm + ('' if rt == 1 else '  %d' % v.fork_of(d)[0]))
    elif cmd == 'cat':
        sys.stdout.buffer.write(v.open(sys.argv[3]).read())
    elif cmd == 'get':
        f = v.open(sys.argv[3]); out = open(sys.argv[4], 'wb')
        while True:
            b = f.read(1 << 24)
            if not b: break
            out.write(b)
    elif cmd == 'getdir':
        # copy a directory tree (files, symlinks, modes; not owners) out of the image: used to build small test images
        src, dst = sys.argv[3].rstrip('/'), sys.argv[4]
        def cp(cnid, rt, d, p, out):
            if rt == 1:
                os.makedirs(out, exist_ok=True)
                for nm, (rt2, c2, d2) in sorted(v.children.get(cnid, {}).items()):
                    cp(c2, rt2, d2, p + '/' + nm, os.path.join(out, nm))
                return
            if rt == 2 and struct.unpack_from('>II', v.cat, d + 48) == (0x686C6E6B, 0x6866732B):
                num = struct.unpack_from('>I', v.cat, d + 32 + 12)[0]
                rt, cnid, d = v.children[v.private]['iNode%d' % num]
            mode = struct.unpack_from('>H', v.cat, d + 32 + 10)[0]
            data = v.read_file(rt, cnid, d)
            if (mode & 0o170000) == 0o120000:
                if os.path.lexists(out): os.unlink(out)
                os.symlink(data.decode(), out)
            else:
                with open(out, 'wb') as fh: fh.write(data)
                os.chmod(out, mode & 0o7777)
        e = v.lookup(src, follow=False)
        assert e, src
        cp(e[1], e[0], e[2], src, dst)
    elif cmd == 'stat':
        e = v.lookup(sys.argv[3], follow=False)
        print(e)
        if e and e[0] == 2:
            d = e[2]
            print('uid,gid', struct.unpack_from('>II', v.cat, d + 32), 'mode %o' % struct.unpack_from('>H', v.cat, d + 32 + 10)[0], 'size', v.fork_of(d)[0])
    elif cmd == 'dsc':
        d = '/System/Library/Caches/com.apple.dyld'
        e = v.lookup(d)
        os.makedirs(sys.argv[3], exist_ok=True)
        for nm, (rt, c, off) in sorted(v.children[e[1]].items()):
            if rt != 2 or nm.endswith('.symbols'):
                continue
            f = v.open(d + '/' + nm)
            with open(os.path.join(sys.argv[3], nm), 'wb') as out:
                while True:
                    b = f.read(1 << 24)
                    if not b:
                        break
                    out.write(b)
            print(nm)
    elif cmd == 'find':
        sub = sys.argv[3]
        def walk(cnid, p):
            for nm, (rt, c, d) in v.children.get(cnid, {}).items():
                q = p + '/' + nm
                if sub in nm: print(q)
                if rt == 1: walk(c, q)
        walk(2, '')
if __name__ == '__main__': main()
