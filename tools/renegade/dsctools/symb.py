"""Symbolicate / disassemble the iOS 18 (PAC-stripped) dyld shared cache without dyld_shared_cache_util.

Setup (once; ~4 GB, deleted again with `rm -r research/ios18/dsc`):
    python3 tools/renegade/hfsx.py research/ios18/ios18-root-full.simg dsc research/ios18/dsc
    python3 -m venv /tmp/v && /tmp/v/bin/pip install capstone      # disassembler (the system python has none)
Tools (run with the venv python, from anywhere; DSC_DIR overrides the cache directory):
    symb.py SLIDE ADDR...          ADDR - SLIDE -> image+off nearest-export (slide = 'slide 0x...' of the CRASH line)
    crash.py LOG PROC [N]          symbolicate the Nth 'CRASH PROC[pid]' block of a usb-*.txt log (cache frames, MAIN offsets)
    dcache.py UNSLID_ADDR BEFORE AFTER   disassemble around an unslid cache address; resolves bl targets through the
                                   cache's direct stubs, objc_msgSend[selector] stubs and ObjC method lists (-[Class sel])
    imgstr.py IMAGE-SUBSTR [REGEX] __cstring/__oslogstring/__objc_methname of one image (os_log format strings = what
                                   the daemon would have said; the kernel log never shows os_log)
    xref.py IMAGE-SUBSTR ADDR...   adrp+add cross references to string addresses inside one image
    dbin.py FILE OFF BEFORE AFTER  disassemble a thin Mach-O (e.g. a daemon pulled with hfsx.py get); bxref.py FILE STR..
v5 slide pointers are decoded (value & 0x3FFFFFFFF + 0x180000000, auth: low 32 bits); PAC instructions appear as
the NOPs/ret the rewriter left; `autibsp/eor/tbz/brk #0xc471` tails are the original compiler FPAC check, not ours.
"""
import sys, struct, bisect, os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import pacstrip_cache as pc
C = pc.Cache(os.environ.get('DSC_DIR') or os.path.join(HERE, '..', '..', '..', 'research', 'ios18', 'dsc'))
BASE = 0x180000000
IMGS = sorted(C.images())
ADDRS = [a for a, p in IMGS]

def rd(addr, n):
    out = b''
    while n > 0:
        t = C.translate(addr, 1)
        fn, off, _ = t
        # limit to mapping
        k = min(n, 0x4000 - (off & 0x3fff))
        out += bytes(C.bufs[fn][off:off + k]); addr += k; n -= k
    return out

def image_of(a):
    i = bisect.bisect_right(ADDRS, a) - 1
    return IMGS[i]

def macho(addr):
    h = rd(addr, 32)
    magic, ct, cs, ft, ncmds, sz, fl, _ = struct.unpack('<IiiIIIII', h)
    cmds = rd(addr + 32, sz)
    o = 0; segs = []; info = {}
    for _ in range(ncmds):
        cmd, cl = struct.unpack_from('<II', cmds, o)
        if cmd == 0x19:
            name = cmds[o + 8:o + 24].split(b'\0')[0].decode()
            vm, vs, fo, fs = struct.unpack_from('<QQQQ', cmds, o + 24)
            nsec = struct.unpack_from('<I', cmds, o + 64)[0]
            secs = []
            for j in range(nsec):
                so = o + 72 + 80 * j
                sn = cmds[so:so + 16].split(b'\0')[0].decode()
                sa, ss = struct.unpack_from('<QQ', cmds, so + 32)
                secs.append((sn, sa, ss))
            segs.append((name, vm, vs, fo, fs, secs))
        elif cmd == 0x26: info['fstarts'] = struct.unpack_from('<II', cmds, o + 8)
        elif cmd == 0x80000033: info['exports'] = struct.unpack_from('<II', cmds, o + 8)
        elif cmd == 0x2: info['symtab'] = struct.unpack_from('<IIII', cmds, o + 8)
        o += cl
    return segs, info

_cache = {}
def img_info(addr):
    if addr in _cache: return _cache[addr]
    segs, info = macho(addr)
    le = [s for s in segs if s[0] == '__LINKEDIT'][0]
    def lm(off): return le[1] + (off - le[3])
    r = (segs, info, lm)
    _cache[addr] = r
    return r

def uleb(b, o):
    r = 0; s = 0
    while True:
        x = b[o]; o += 1
        r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r, o

def exports(addr):
    segs, info, lm = img_info(addr)
    if 'exports' not in info: return {}
    off, size = info['exports']
    data = rd(lm(off), size)
    res = {}
    def walk(o, pre):
        t, o2 = uleb(data, o)
        if t:
            fl, p = uleb(data, o2)
            if not fl & 8:
                v, p = uleb(data, p)
                res[addr + v] = pre
        else:
            o2 = o2
        o2 = o + 0
        t, p = uleb(data, o)
        p += t
        n = data[p]; p += 1
        for _ in range(n):
            e = p
            while data[e]: e += 1
            lab = data[p:e].decode(); p = e + 1
            ch, p = uleb(data, p)
            walk(ch, pre + lab)
    walk(0, '')
    return res

_ex = {}
def sym(a):
    """a: unslid address -> 'image+off sym+off'"""
    ia, path = image_of(a)
    if ia not in _ex:
        try: _ex[ia] = exports(ia)
        except Exception as e: _ex[ia] = {}
    ex = _ex[ia]
    ks = sorted(ex)
    i = bisect.bisect_right(ks, a) - 1
    s = ''
    if i >= 0: s = ' %s+0x%x' % (ex[ks[i]], a - ks[i])
    return '%s+0x%x%s' % (os.path.basename(path), a - ia, s)

def fstarts(ia):
    segs, info, lm = img_info(ia)
    off, size = info['fstarts']
    d = rd(lm(off), size)
    o = 0; a = ia; out = []
    while o < len(d):
        v, o = uleb(d, o)
        if v == 0: break
        a += v; out.append(a)
    return out

if __name__ == '__main__':
    slide = int(sys.argv[1], 16)
    for x in sys.argv[2:]:
        v = int(x, 16)
        print('%#x -> %s' % (v, sym(v - slide)))
