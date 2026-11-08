import os, sys
from symb import *
import adis as D
import stubs, objc
def symf(t):
    o = objc.objc_sym(t) if os.environ.get('DSC_OBJC', '1') == '1' else None
    s = stubs.sym2(t)
    if o and o.endswith('+0x0'): return o[:-4]
    return s if not o else (s + '  [' + o + ']')
def run(a, before, after):
    start = a - before
    code = rd(start, before + after)
    D.dis(code, start, symf, lambda x, n: rd(x, n))
if __name__ == '__main__':
    run(int(sys.argv[1], 16), int(sys.argv[2], 0), int(sys.argv[3], 0))
