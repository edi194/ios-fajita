import sys, struct, re
from capstone import *
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = False
md.skipdata = True

def cstr(read, a):
    try:
        b = read(a, 160)
    except Exception: return None
    e = b.find(b'\0')
    if e < 2: return None
    s = b[:e]
    if all(32 <= c < 127 or c in (9, 10) for c in s): return s.decode()
    return None

def dis(code, base, symf, read, uns=0):
    regs = {}
    for i in md.disasm(code, base):
        note = ''
        op = i.op_str
        m = i.mnemonic
        if m == 'adrp':
            r, imm = op.split(', #')
            regs[r] = int(imm, 16)
        elif m == 'add' and '#' in op:
            p = [x.strip() for x in op.split(',')]
            if len(p) == 3 and p[1] in regs and p[2].startswith('#'):
                v = regs[p[1]] + int(p[2][1:], 16)
                regs[p[0]] = v
                s = cstr(read, v + uns)
                note = '  ; %#x' % v + (' "%s"' % s if s else '')
        elif m in ('bl', 'b') and op.startswith('#'):
            t = int(op[1:], 16)
            note = '  ; ' + symf(t)
        elif m == 'ldr' and 'x' in op and ', [x' in op:
            pass
        print('%#x: %-8s %s%s' % (i.address, m, op, note))
