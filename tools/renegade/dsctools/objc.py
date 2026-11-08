import struct, sys, bisect
from symb import *
import stubs

_b = rd(0x18014e378, 0x30)
SELBASE = 0x18014e378 + struct.unpack('<Q', _b[0x28:0x30])[0]
def ptr(a):
    v = struct.unpack('<Q', rd(a, 8))[0]
    return stubs.decptr(v) if v else 0
def cstring(a):
    b = rd(a, 200); return b[:b.find(b'\0')].decode('utf8', 'replace')
def rel(a):
    v = struct.unpack('<i', rd(a, 4))[0]
    return a + v
def methods(ml_addr, cls, cat=False):
    out = []
    if not ml_addr: return out
    ent, cnt = struct.unpack('<II', rd(ml_addr, 8))
    small = bool(ent & 0x80000000)
    direct = bool(ent & 0x40000000)
    esz = ent & 0xfffc
    for i in range(cnt):
        e = ml_addr + 8 + i * esz
        try:
            if small:
                if direct:
                    s = cstring(SELBASE + struct.unpack('<i', rd(e, 4))[0])
                else:
                    s = cstring(ptr(rel(e)))
                imp = rel(e + 8)
            else:
                s = cstring(ptr(e)); imp = ptr(e + 16)
            out.append((imp, s))
        except Exception as ex:
            pass
    return out
def dump(ia):
    segs, info, lm = img_info(ia)
    res = {}
    for name, vm, vs, fo, fs, secs in segs:
        for sn, sa, ss in secs:
            if sn == '__objc_classlist':
                for i in range(ss // 8):
                    c = ptr(sa + 8 * i)
                    if not c: continue
                    bits = struct.unpack('<Q', rd(c + 32, 8))[0]
                    ro = (bits & 0x00007ffffffffff8)
                    ro = stubs.decptr(bits) if False else (BASE + (bits & 0x3FFFFFFFF) & ~7) if (bits >> 63) == 0 and False else None
                    # class_t.bits: pointer to class_ro_t (slide-v5 format)
                    ro = ptr(c + 32)
                    if not ro: continue
                    ro &= ~7
                    name = cstring(ptr(ro + 24))
                    for imp, s in methods(ptr(ro + 32), name): res[imp] = '-[%s %s]' % (name, s)
                    # metaclass
                    isa = ptr(c)
                    if isa:
                        mro = ptr(isa + 32) & ~7
                        if mro:
                            for imp, s in methods(ptr(mro + 32), name): res[imp] = '+[%s %s]' % (name, s)
            if sn == '__objc_catlist':
                for i in range(ss // 8):
                    cat = ptr(sa + 8 * i)
                    try:
                        nm = cstring(ptr(cat))
                        cl = ptr(cat + 8)
                        cname = cstring(ptr(ptr(cl + 32) & ~7 + 24)) if cl else '?'
                    except Exception: cname = '?'
                    for imp, s in methods(ptr(cat + 16), cname, True): res[imp] = '-[%s(%s) %s]' % (cname, nm, s)
                    for imp, s in methods(ptr(cat + 24), cname, True): res[imp] = '+[%s(%s) %s]' % (cname, nm, s)
    return res
_cache = {}
def objc_sym(a):
    ia, p = image_of(a)
    if ia not in _cache:
        import os, pickle
        d = os.environ.get('DSC_OBJC_CACHE', '/tmp/dsc_objc_cache')       # a big image (CoreServices) takes minutes: keep the result
        fn = os.path.join(d, '%x.pkl' % ia)
        try:
            _cache[ia] = pickle.load(open(fn, 'rb'))
        except Exception:
            try: _cache[ia] = dump(ia)
            except Exception as e: _cache[ia] = {}
            try:
                os.makedirs(d, exist_ok=True); pickle.dump(_cache[ia], open(fn, 'wb'))
            except Exception: pass
    d = _cache[ia]
    ks = sorted(d)
    i = bisect.bisect_right(ks, a) - 1
    if i >= 0 and a - ks[i] < 0x4000: return '%s+0x%x' % (d[ks[i]], a - ks[i])
    return None
if __name__ == '__main__':
    ia = [a for a, p in IMGS if sys.argv[1] in p][0]
    d = dump(ia)
    print(len(d))
    for k in sorted(d)[:int(sys.argv[2]) if len(sys.argv) > 2 else 20]: print(hex(k), d[k])
