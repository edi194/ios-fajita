import sys, struct, subprocess
sys.path.insert(0,'.')
import adis
from capstone import *
# arm64e thin binary; map vmaddr->file offset via segments
def load(path):
    d = open(path,'rb').read()
    off = 0
    magic = struct.unpack_from('<I', d, 0)[0]
    if magic == 0xbebafeca or magic == 0xcafebabe:
        n = struct.unpack_from('>I', d, 4)[0]
        # pick last slice
        for i in range(n):
            ct, cs, o, sz, al = struct.unpack_from('>iiIII', d, 8+20*i)
            off = o
    ncmds, sz = struct.unpack_from('<II', d, off+16)[0:2]
    ncmds = struct.unpack_from('<I', d, off+16)[0]
    o = off+32; segs=[]
    for _ in range(ncmds):
        cmd, cl = struct.unpack_from('<II', d, o)
        if cmd == 0x19:
            name = d[o+8:o+24].split(b'\0')[0].decode()
            vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, o+24)
            segs.append((name, vm, vs, fo, fs))
        o += cl
    return d, off, segs
def rdb(d, off, segs, a, n):
    for name, vm, vs, fo, fs in segs:
        if vm <= a < vm+vs:
            fo2 = off + fo + (a-vm)
            return d[fo2:fo2+n]
    raise Exception('unmapped %#x' % a)
def sym_none(t): 
    return stubs.sym2(t - 0) if False else ''
if __name__ == '__main__':
    path = sys.argv[1]; a = int(sys.argv[2], 16); before = int(sys.argv[3], 0); after = int(sys.argv[4], 0)
    d, off, segs = load(path)
    base = segs[0][1] if segs[0][0]=='__PAGEZERO' else 0
    # vm addresses in the binary start at PAGEZERO end; offsets given relative to __TEXT vmaddr
    text = [s for s in segs if s[0]=='__TEXT'][0][1]
    va = text + a
    code = rdb(d, off, segs, va-before, before+after)
    def sf(t): return ''
    adis.dis(code, va-before, sf, lambda x, n: rdb(d, off, segs, x, n))
