import sys, struct
from symb import *
from capstone import *
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
def text_ranges(ia):
    segs, info, lm = img_info(ia)
    r = []
    for name, vm, vs, fo, fs, secs in segs:
        for sn, sa, ss in secs:
            if sn in ('__text',): r.append((sa, ss))
    return r
def xrefs(ia, targets):
    targets = set(targets)
    res = {}
    for sa, ss in text_ranges(ia):
        code = rd(sa, ss)
        n = len(code) // 4
        words = struct.unpack('<%dI' % n, code)
        # quick scan: adrp then add within next 3 instrs
        for i, w in enumerate(words):
            if (w & 0x9f000000) == 0x90000000:
                rd_ = w & 31
                immlo = (w >> 29) & 3; immhi = (w >> 5) & 0x7ffff
                imm = ((immhi << 2) | immlo)
                if imm & (1 << 20): imm -= 1 << 21
                pc = sa + 4 * i
                page = (pc & ~0xfff) + (imm << 12)
                for j in range(i + 1, min(i + 4, n)):
                    w2 = words[j]
                    if (w2 & 0xffc00000) == 0x91000000 and ((w2 >> 5) & 31) == rd_:
                        off = (w2 >> 10) & 0xfff
                        t = page + off
                        if t in targets: res.setdefault(t, []).append(sa + 4 * j)
    return res
if __name__ == '__main__':
    sub = sys.argv[1]
    ia = [a for a, p in IMGS if sub in p][0]
    ts = [int(x, 16) for x in sys.argv[2:]]
    for t, l in xrefs(ia, ts).items():
        for a in l: print(hex(t), '<-', sym(a))
