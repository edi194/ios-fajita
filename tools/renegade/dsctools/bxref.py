import sys, struct, re
import dbin
def main(path, pats):
    d, off, segs = dbin.load(path)
    text = [s for s in segs if s[0]=='__TEXT'][0]
    # find strings in file
    found = {}
    for name, vm, vs, fo, fs in segs:
        data = d[off+fo: off+fo+fs]
        for p in pats:
            for m in re.finditer(re.escape(p.encode()), data):
                found.setdefault(p, []).append(vm + m.start())
    print({k: [hex(x) for x in v] for k, v in found.items()})
    targets = {a: p for p, l in found.items() for a in l}
    # scan text
    sa = text[1]; fo = text[3]
    code = d[off+fo: off+fo+text[4]]
    n = len(code)//4
    words = struct.unpack('<%dI' % n, code)
    for i, w in enumerate(words):
        if (w & 0x9f000000) == 0x90000000:
            rd = w & 31
            imm = (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)
            if imm & (1<<20): imm -= 1<<21
            pc = sa + 4*i
            page = (pc & ~0xfff) + (imm << 12)
            for j in range(i+1, min(i+4, n)):
                w2 = words[j]
                if (w2 & 0xffc00000) == 0x91000000 and ((w2 >> 5) & 31) == rd:
                    t = page + ((w2 >> 10) & 0xfff)
                    for a, p in targets.items():
                        if t == a: print('%s <- text+%#x' % (p, sa + 4*j - sa))
if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])
