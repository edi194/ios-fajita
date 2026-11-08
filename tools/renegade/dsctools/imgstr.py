import sys, re
from symb import *
def find_img(sub):
    return [(a,p) for a,p in IMGS if sub in p]
def img_cstrings(addr):
    segs, info, lm = img_info(addr)
    out = []
    for name, vm, vs, fo, fs, secs in segs:
        if name != '__TEXT': continue
        for sn, sa, ss in secs:
            if sn in ('__cstring', '__oslogstring', '__objc_methname', '__objc_classname', '__ustring'):
                data = rd(sa, ss)
                for m in re.finditer(rb'[\x20-\x7e\t\n]{4,}', data):
                    out.append((sa + m.start(), sn, m.group().decode()))
    return out
if __name__ == '__main__':
    sub = sys.argv[1]; pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
    for a, p in find_img(sub):
        print('#', hex(a), p)
        for sa, sn, s in img_cstrings(a):
            if not pat or pat.search(s): print('%#x %s: %s' % (sa, sn, s[:200].replace('\n', '\\n')))
