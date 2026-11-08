#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Names and method type encodings of one image of the PAC-stripped iOS 18 dyld cache (nothing is written to git).

Setup (scratch dir, ~4 GB, delete afterwards):
    python3 tools/renegade/hfsx.py research/ios18/ios18-root-full.simg dsc $SCRATCH/dsc
    python3 -m venv $SCRATCH/v && $SCRATCH/v/bin/pip install capstone
Run:   DSC_DIR=$SCRATCH/dsc $SCRATCH/v/bin/python3 dsc_oglinfo.py OpenGLES.framework/OpenGLES exports|objc
`exports` = export-trie symbol names (compare with `nm -gU` of the shim); `objc` = class methods with type encodings
(a class's own list; list-of-lists entries are relative to the entry address).
"""
import os, sys, struct
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', '..', 'tools', 'renegade', 'dsctools'))
assert os.environ.get('DSC_DIR'), 'set DSC_DIR'
from symb import rd, IMGS, img_info, exports
import objc, stubs
from objc import ptr, cstring
sub=sys.argv[1]
ia=[a for a,p in IMGS if sub in p][0]
print('image',hex(ia))
if sys.argv[2]=='exports':
    for a,n in sorted(exports(ia).items(), key=lambda x:x[1]): print(n)
else:
    segs,info,lm=img_info(ia)
    def meths(ml,cls,pre):
        if not ml: return
        if ml&1:
            lol=ml&~1
            es,n=struct.unpack('<II',rd(lol,8))
            for i in range(n):
                v=struct.unpack('<Q',rd(lol+8+8*i,8))[0]
                off=v>>16
                if off>>47: off-=1<<48
                meths(lol+8+8*i+off,cls,pre)
            return
        ent,cnt=struct.unpack('<II',rd(ml,8))
        small=bool(ent&0x80000000); direct=bool(ent&0x40000000); esz=ent&0xfffc
        for i in range(cnt):
            e=ml+8+i*esz
            try: rd(e,12)
            except Exception: continue
            if small:
                s=cstring(objc.SELBASE+struct.unpack('<i',rd(e,4))[0]) if direct else cstring(ptr(objc.rel(e)))
                ty=cstring(objc.rel(e+4)) if True else ''
            else:
                s=cstring(ptr(e)); ty=cstring(ptr(e+8))
            print(pre+'[%s %s] %s  imp=%#x'%(cls,s,ty, objc.rel(e+8) if small else 0))
    for name,vm,vs,fo,fs,secs in segs:
        for sn,sa,ss in secs:
            if sn=='__objc_classlist':
                for i in range(ss//8):
                    c=ptr(sa+8*i); ro=ptr(c+32)&~7
                    cn=cstring(ptr(ro+24))
                    meths(ptr(ro+32),cn,'-'); 
                    isa=ptr(c)
                    if isa: meths(ptr((ptr(isa+32)&~7)+32),cn,'+')
            if sn=='__objc_catlist':
                for i in range(ss//8):
                    cat=ptr(sa+8*i); nm=cstring(ptr(cat)); cl=ptr(cat+8)
                    cn=cstring(ptr((ptr(cl+32)&~7)+24)) if cl else '?'
                    meths(ptr(cat+16),cn+'('+nm+')','-'); meths(ptr(cat+24),cn+'('+nm+')','+')
