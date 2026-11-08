from symb import *
import struct
from capstone import *
_md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
def decptr(v):
    if v & (1 << 63): return BASE + (v & 0xFFFFFFFF)
    return BASE + (v & 0x3FFFFFFFF) if (v & 0x3FFFFFFFF) else 0
def resolve_stub(t):
    r = direct(t)
    if r: return r
    return resolve_stub0(t)
def direct(t):
    try: code = rd(t, 12)
    except Exception: return None
    ins = list(_md.disasm(code, t))
    if len(ins)==3 and ins[0].mnemonic=='adrp' and ins[1].mnemonic=='add' and ins[2].mnemonic=='br' and ins[0].op_str.startswith('x16'):
        page=int(ins[0].op_str.split('#')[-1],16); a=int(ins[1].op_str.split('#')[-1],16)
        return page+a
    return None
def resolve_stub0(t):
    try:
        code = rd(t, 16)
    except Exception: return None
    ins = list(_md.disasm(code, t))
    if len(ins) < 3 or ins[0].mnemonic != 'adrp' or not ins[0].op_str.startswith('x16') and not ins[0].op_str.startswith('x17'): return None
    r, imm = ins[0].op_str.split(', #'); page = int(imm, 16)
    off = 0
    for i in ins[1:3]:
        if i.mnemonic == 'add': off = int(i.op_str.split('#')[-1], 16)
        if i.mnemonic == 'ldr' and '[' in i.op_str and off == 0:
            o = i.op_str.split('#')
            if len(o) > 1: off = int(o[-1].rstrip(']'), 16)
    try:
        v = struct.unpack('<Q', rd(page + off, 8))[0]
    except Exception: return None
    return decptr(v)
def sym2(t):
    s = resolve_stub(t)
    if s:
        return sym(t).split(' ')[0] + ' -> ' + sym(s)
    return sym(t)

def objc_sel(t):
    try: code = rd(t, 8)
    except Exception: return None
    ins = list(_md.disasm(code, t))
    if len(ins) == 2 and ins[0].mnemonic == 'adrp' and ins[0].op_str.startswith('x1,') and ins[1].mnemonic == 'ldr' and ins[1].op_str.startswith('x1, [x1'):
        try:
            page = int(ins[0].op_str.split('#')[-1], 16); off = int(ins[1].op_str.split('#')[-1].rstrip(']'), 16)
            v = struct.unpack('<Q', rd(page + off, 8))[0]
            a = decptr(v) if v else 0
            b = rd(a, 96); s = b[:b.find(b'\0')].decode()
            return s
        except Exception: return None
_old = sym2
def sym2(t):
    s = objc_sel(t)
    if s: return 'objc_msgSend[%s]' % s
    return _old(t)
