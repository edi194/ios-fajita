#!/usr/bin/env python3
"""Check the chained fixups of every Mach-O in an iOS root the way the kernel's dyld pager will at page-in.

  fixupcheck.py ROOT_DIR | IMAGE.simg [--prefix /System/Library] [--quiet]

For each 64-bit ARM Mach-O (thin or fat) with LC_DYLD_CHAINED_FIXUPS, every page of every segment is walked from its
page_start along the chain stored in the file's own bytes, with the checks of xnu's vm_dyld_pager.c (fixupPageAuth64 /
fixupPage64): the chain must stay inside its page, and a bind's ordinal must be below the import count. A file whose
bytes do not match its fixup tables (damaged on the way into the image, or by a rewriter) fails here instead of
panicking the phone at boot ("fixupPageAuth64(): chain ... out of range", panic_on_dyld_issue is on in development
kernels). A .simg is read in place through hfsx.py (no mount, no root, no free disk). Exit status 1 when any file fails.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

LC_SEGMENT_64, LC_DYLD_CHAINED_FIXUPS = 0x19, 0x80000034
CPU_ARM64 = 0x0100000C
# pointer_format -> (stride in bytes, mask of the "next" field after >> 51)
FORMATS = {1: (8, 0x7FF), 9: (8, 0x7FF), 12: (8, 0x7FF), 2: (4, 0xFFF), 6: (4, 0xFFF)}
START_NONE = 0xFFFF


def check_slice(b, base, size, name):
    """Problems (strings) of the Mach-O slice at b[base:base+size]."""
    out = []
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiIIIIII', b, base)
    if magic != 0xFEEDFACF or cpu != CPU_ARM64:
        return out
    segs, fix = [], None
    off = base + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', b, off)
        if cmd == LC_SEGMENT_64:
            segname = b[off + 8:off + 24].split(b'\0')[0].decode(errors='replace')
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', b, off + 24)
            segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            fix = struct.unpack_from('<II', b, off + 8)
        if cmdsize < 8:
            return [f'{name}: load command of size {cmdsize}']
        off += cmdsize
    if not fix:
        return out
    dataoff, datasize = fix
    h = base + dataoff
    if dataoff + datasize > size:
        return [f'{name}: chained fixups outside the file']
    _, starts_off, _, _, imports_count, _, _ = struct.unpack_from('<IIIIIII', b, h)
    si = h + starts_off
    seg_count = struct.unpack_from('<I', b, si)[0]
    for s in range(min(seg_count, len(segs))):
        io = struct.unpack_from('<I', b, si + 4 + 4 * s)[0]
        if io == 0:
            continue
        ss = si + io
        _, page_size, fmt, seg_off, _, page_count = struct.unpack_from('<IHHQIH', b, ss)
        if fmt not in FORMATS:
            continue
        stride, nmask = FORMATS[fmt]
        segname, _, _, fileoff, filesize = segs[s]
        for p in range(page_count):
            start = struct.unpack_from('<H', b, ss + 22 + 2 * p)[0]
            if start == START_NONE:
                continue
            page_file = fileoff + p * page_size
            o, steps = start, 0
            while True:
                if o + 8 > page_size or page_file + o + 8 > fileoff + filesize or page_file + o + 8 > size:
                    out.append(f'{name}: {segname} page {p}: chain at page offset {o:#x} leaves the page '
                               f'(page size {page_size:#x}, start {start:#x}, {steps} steps)')
                    break
                v = struct.unpack_from('<Q', b, base + page_file + o)[0]
                if fmt in (1, 9, 12) and v >> 63 and (v >> 62) & 1 and (v & 0xFFFFFF) >= imports_count:
                    out.append(f'{name}: {segname} page {p}: bind ordinal {v & 0xFFFFFF} >= {imports_count} imports')
                    break
                nxt = (v >> 51) & nmask
                if nxt == 0:
                    break
                o += nxt * stride
                steps += 1
    return out


def check_bytes(b, name):
    if len(b) < 32:
        return []
    m = struct.unpack_from('>I', b, 0)[0]
    if m == 0xCAFEBABE:
        n = struct.unpack_from('>I', b, 4)[0]
        res = []
        for i in range(min(n, 32)):
            _, _, off, sz, _ = struct.unpack_from('>IIIII', b, 8 + 20 * i)
            if off + sz <= len(b) and sz >= 32:
                res += check_slice(b, off, sz, f'{name} (slice {i})')
        return res
    if struct.unpack_from('<I', b, 0)[0] == 0xFEEDFACF:
        return check_slice(b, 0, len(b), name)
    return []


def walk_dir(root, prefix):
    top = os.path.join(root, prefix.lstrip('/'))
    for d, dirs, files in os.walk(top):
        for n in files:
            p = os.path.join(d, n)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            with open(p, 'rb') as f:
                if f.read(4) not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                    continue
                f.seek(0)
                yield '/' + os.path.relpath(p, root), f.read()


def walk_simg(path, prefix):
    import hfsx
    v = hfsx.Vol(hfsx.Simg(path))
    e = v.lookup(prefix)
    if not e or e[0] != 1:
        sys.exit(f'{prefix}: not a directory in {path}')
    todo = [(e[1], prefix.rstrip('/'))]
    while todo:
        cnid, p = todo.pop()
        for nm, (rt, c, d) in v.children.get(cnid, {}).items():
            q = p + '/' + nm
            if rt == 1:
                todo.append((c, q))
                continue
            if struct.unpack_from('>II', v.cat, d + 48) == (0x686C6E6B, 0x6866732B):   # hard link -> its iNode
                num = struct.unpack_from('>I', v.cat, d + 32 + 12)[0]
                rt, c, d = v.children[v.private]['iNode%d' % num]
            mode = struct.unpack_from('>H', v.cat, d + 32 + 10)[0]
            if (mode & 0o170000) != 0o100000 or v.fork_of(d)[0] < 32:
                continue
            l, ext = v.file_extents(c, d)
            if v.read_extents(ext, 4)[:4] not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                continue
            yield q, v.read_extents(ext, l)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    quiet = '--quiet' in sys.argv
    prefix = '/'
    if '--prefix' in sys.argv:
        prefix = sys.argv[sys.argv.index('--prefix') + 1]
        args.remove(prefix)
    if len(args) != 1:
        sys.exit(__doc__.split('\n\n')[1])
    src = args[0]
    it = walk_simg(src, prefix) if src.endswith('.simg') else walk_dir(src, prefix)
    n = bad = 0
    for name, data in it:
        n += 1
        probs = check_bytes(data, name)
        if probs:
            bad += 1
            for pr in probs[:5]:
                print('BAD ' + pr)
        if not quiet and n % 500 == 0:
            print(f'... {n} Mach-Os checked, {bad} bad', file=sys.stderr)
    print(f'{n} Mach-O files checked, {bad} with fixup chains that would fail at page-in')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
