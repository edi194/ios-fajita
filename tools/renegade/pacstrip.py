#!/usr/bin/env python3
"""pacstrip (Renegade's core rewriter, `renegade strip`): rewrite arm64e Mach-O code to run on a CPU without pointer authentication (ARMv8.0-8.2).

Every rewrite is 4 bytes for 4 bytes, so no offset, branch target, unwind table, function-starts table or
chained-fixup chain moves. The table is docs/IOS18_FEASIBILITY.md section 3.1:

  RETAA/RETAB                      -> RET                      (LR is never signed: PACIBSP/PACIASP are NOPs)
  BRAA/BRAB/BRAAZ/BRABZ Xn[,Xm]    -> BR  Xn
  BLRAA/BLRAB/BLRAAZ/BLRABZ        -> BLR Xn
  LDRAA/LDRAB Xt,[Xn,#imm]{!}      -> LDR Xt,[Xn,#imm]{!}  (pre-index/offset forms; LDUR for small negatives)
  PACIA/PACIB/PACDA/PACDB (+Z)     -> NOP                      (the pointer stays a plain pointer)
  AUTIA/AUTIB/AUTDA/AUTDB (+Z)     -> NOP
  XPACI/XPACD                      -> NOP
  PACGA Xd,Xn,Xm                   -> EOR Xd,Xn,Xm,ROR #k      (deterministic mix; Xm=SP -> MOV Xd,Xn)
  HINT space (PACIBSP, AUTIBSP, PACIA1716, XPACLRI, BTI ...) is untouched: NOP on a CPU without PAuth.
  FJCVTZS is NOT rewritten (no 1:1 form): its locations are logged.

Only executable sections are touched (S_ATTR_PURE_INSTRUCTIONS / S_ATTR_SOME_INSTRUCTIONS) and inside them
the LC_DATA_IN_CODE ranges are skipped. Fat files: every arm64/arm64e slice is processed.

  pacstrip.py [-v] [--sign] [--dylinker PATH] [--subtype arm64] IN [OUT]      (OUT defaults to in-place)
  pacstrip.py --scan FILE...                                                  (count only, write nothing)

--sign       ad-hoc re-sign with `codesign -f -s -`, preserving the entitlements (macOS codesign or, on Linux, ldid)
--dylinker   replace the LC_LOAD_DYLINKER path of an executable (load commands are repacked into the header
             slack; fails if there is not enough room)
--subtype    set the CPU subtype to arm64 (ALL): NOT needed with kernel patch 0131 and NOT recommended, see
             docs/IOS18_PORT.md (the arm64 subtype makes iOS 18 dyld use the arm64 shared region/graded archs)
"""
import argparse
import os
import struct
import subprocess
import sys
from array import array
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import renegade_platform as rplat  # noqa: E402

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0xFF000000
CPU_SUBTYPE_ARM64_ALL, CPU_SUBTYPE_ARM64E = 0, 2

LC_SEGMENT_64 = 0x19
LC_DATA_IN_CODE = 0x29
LC_LOAD_DYLINKER = 0x0E
LC_CODE_SIGNATURE = 0x1D
S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL = 0x1, 0xC, 0x12
S_ATTR_PURE_INSTRUCTIONS, S_ATTR_SOME_INSTRUCTIONS = 0x80000000, 0x00000400

NOP = 0xD503201F
RET = 0xD65F03C0

# --- classification -----------------------------------------------------------------------------------------
# (mask, value) -> name. Checked only for words whose top byte is in PREFIX (cheap pre-filter).
PREFIX = {0xD6, 0xD7, 0xDA, 0x9A, 0xF8, 0x1E}


def rewrite_word(w):
    """Return (new_word, class_name) or (None, class_name_to_report) or (None, None) for untouched words."""
    top = w >> 24
    if top not in PREFIX:
        return None, None
    if top in (0xD6, 0xD7):
        if w == 0xD65F0BFF or w == 0xD65F0FFF:
            return RET, 'RETAA' if w == 0xD65F0BFF else 'RETAB'
        # BRAA*/BLRAA*: 1101011 Z 0 opc(2:0)... op3 = 00001M (bits 15:10), op2 = 11111
        if (w & 0xFEFFF800) == 0xD61F0800:
            rn = (w >> 5) & 31
            return 0xD61F0000 | rn << 5, 'BR' + ('AB' if w & 0x400 else 'AA') + ('' if w & 0x01000000 else 'Z')
        if (w & 0xFEFFF800) == 0xD63F0800:
            rn = (w >> 5) & 31
            return 0xD63F0000 | rn << 5, 'BLR' + ('AB' if w & 0x400 else 'AA') + ('' if w & 0x01000000 else 'Z')
        if (w & 0xFFFFF800) == 0xD69F0800:       # ERETAA/ERETAB: kernel only
            return None, 'ERETA*(unhandled)'
        return None, None
    if top == 0xDA:
        if (w & 0xFFFFC000) == 0xDAC10000:        # PAC*/AUT* register forms, with and without Z
            names = ('PACIA', 'PACIB', 'PACDA', 'PACDB', 'AUTIA', 'AUTIB', 'AUTDA', 'AUTDB')
            return NOP, names[(w >> 10) & 7] + ('Z' if w & 0x2000 else '')
        if (w & 0xFFFFFBE0) == 0xDAC143E0:        # XPACI / XPACD
            return NOP, 'XPACD' if w & 0x400 else 'XPACI'
        return None, None
    if top == 0x9A:
        if (w & 0xFFE0FC00) == 0x9AC03000:        # PACGA Xd, Xn, Xm
            rd, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
            if rm == 31:                          # modifier is SP: cannot be an EOR operand
                return 0xAA0003E0 | rn << 16 | rd, 'PACGA'   # MOV Xd, Xn (ORR Xd, XZR, Xn)
            # EOR Xd, Xn, Xm, ROR #13. k must NOT depend on the registers: code that stores a PACGA MAC and
            # re-verifies it elsewhere (Foundation _NSThreadData setTarget: -> __NSThreadPoisoned brk #1, which
            # killed xpcproxy) uses different registers at the two sites and must still get the same value.
            k = 13
            return 0xCA000000 | 3 << 22 | rm << 16 | k << 10 | rn << 5 | rd, 'PACGA'
        return None, None
    if top == 0xF8:
        if (w & 0xFF200400) == 0xF8200400:        # LDRAA/LDRAB
            m, s, imm9, wb = (w >> 23) & 1, (w >> 22) & 1, (w >> 12) & 0x1FF, (w >> 11) & 1
            rn, rt = (w >> 5) & 31, w & 31
            imm = ((s << 9 | imm9) - (1 << 10 if s else 0)) * 8      # signed 10-bit, scaled by 8
            name = 'LDRAB' if m else 'LDRAA'
            if wb:                                                    # pre-index: simm9, unscaled
                if -256 <= imm <= 255:
                    return 0xF8400C00 | (imm & 0x1FF) << 12 | rn << 5 | rt, name
            elif imm >= 0:                                            # unsigned-offset LDR, imm12 scaled by 8
                return 0xF9400000 | (imm // 8) << 10 | rn << 5 | rt, name
            elif imm >= -256:                                         # LDUR
                return 0xF8400000 | (imm & 0x1FF) << 12 | rn << 5 | rt, name
            return None, name + '(unencodable)'
        return None, None
    if top == 0x1E:
        if (w & 0xFFFFFC00) == 0x1E7E0000:
            return None, 'FJCVTZS(left)'
    return None, None


# --- Mach-O walking -------------------------------------------------------------------------------------------
def code_ranges(buf, base):
    """Executable file ranges [(start, end, name)] of the 64-bit Mach-O at buf[base:], minus data-in-code."""
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', buf, base)
    assert magic == MH_MAGIC_64, 'not a 64-bit little-endian Mach-O'
    sects, dice = [], []
    off = base + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            for i in range(nsects):
                so = off + 72 + i * 80
                sectname, segname = (x.split(b'\0')[0].decode() for x in struct.unpack_from('<16s16s', buf, so))
                addr, ssize, foff, align, reloff, nreloc, flags = struct.unpack_from('<QQIIIII', buf, so + 32)
                stype = flags & 0xFF
                if flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) and stype not in (
                        S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL) and foff:
                    sects.append((base + foff, base + foff + ssize, f'{segname},{sectname}'))
        elif cmd == LC_DATA_IN_CODE:
            dataoff, datasize = struct.unpack_from('<II', buf, off + 8)
            for j in range(datasize // 8):
                o, length, kind = struct.unpack_from('<IHH', buf, base + dataoff + j * 8)
                dice.append((base + o, base + o + length))
        off += size
    out = []
    for s, e, n in sects:
        pos = s
        for ds, de in sorted(d for d in dice if d[0] < e and d[1] > s):
            if ds > pos:
                out.append((pos, ds, n))
            pos = max(pos, de)
        if pos < e:
            out.append((pos, e, n))
    return out


def process_slice(buf, base, write, verbose, name, counts, fj_sites):
    for s, e, secname in code_ranges(buf, base):
        n = (e - s) // 4
        words = array('I')
        words.frombytes(bytes(buf[s:s + n * 4]))
        changed = False
        for i, w in enumerate(words):
            if (w >> 24) not in PREFIX:
                continue
            nw, cls = rewrite_word(w)
            if cls is None:
                continue
            counts[cls] += 1
            if nw is None:
                if cls.startswith('FJCVTZS'):
                    fj_sites.append((secname, s + i * 4 - base))
                elif verbose:
                    print(f'  {name}: {cls} at file+0x{s + i * 4 - base:x} left as is', file=sys.stderr)
                continue
            if write:
                words[i] = nw
                changed = True
        if changed:
            buf[s:s + n * 4] = words.tobytes()


def repack_dylinker(buf, base, newpath):
    """Replace the LC_LOAD_DYLINKER path, shifting later load commands within the header slack."""
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack_from('<IiiIIIII', buf, base)
    off, end = base + 32, base + 32 + sizeofcmds
    cmds, first_content = [], None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', buf, off)
        cmds.append((cmd, bytes(buf[off:off + size])))
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', buf, off + 64)[0]
            for i in range(nsects):
                foff = struct.unpack_from('<I', buf, off + 72 + i * 80 + 48)[0]
                if foff and (first_content is None or foff < first_content):
                    first_content = foff
        off += size
    new = []
    for cmd, data in cmds:
        if cmd == LC_LOAD_DYLINKER:
            p = newpath.encode() + b'\0'
            size = (12 + len(p) + 7) & ~7
            data = struct.pack('<III', cmd, size, 12) + p.ljust(size - 12, b'\0')
        new.append(data)
    blob = b''.join(new)
    limit = base + (first_content if first_content is not None else 1 << 30)
    if base + 32 + len(blob) > limit:
        raise SystemExit(f'not enough header slack for the new dylinker path ({base + 32 + len(blob) - limit} bytes short)')
    buf[base + 32:base + 32 + max(len(blob), sizeofcmds)] = blob.ljust(max(len(blob), sizeofcmds), b'\0')
    struct.pack_into('<I', buf, base + 20, len(blob))


def slices(buf):
    magic = struct.unpack_from('>I', buf, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from('>I', buf, 4)[0]
        for i in range(nfat):
            if magic == FAT_MAGIC:
                ct, cs, off, size, al = struct.unpack_from('>iiIII', buf, 8 + i * 20)
            else:
                ct, cs, off, size, al = struct.unpack_from('>iiQQI', buf, 8 + i * 32)[:5]
            if ct == CPU_TYPE_ARM64:
                yield off
    else:
        yield 0


CS_FLAG_OPTIONS = rplat.CS_FLAG_OPTIONS
CS_FLAG_IGNORED = 0x2 | 0x20000 | 0x4000 | 0x1000      # adhoc (codesign adds it), linker-signed, (computed bits)


def cs_identity(path):
    """(identifier, team_id, flags) of the first arm64 slice's CodeDirectory, or None if unsigned/unparsable.

    launchd compares the signing identifier of a boot task with the one it expects ("com.apple.mount"): an ad-hoc
    re-sign must keep it (codesign would invent name-<hash>)."""
    buf = open(path, 'rb').read()
    for base in slices(bytearray(buf[:1 << 16]) if buf[:4] not in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca') else bytearray(buf)):
        magic, cputype, cpusub, ftype, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', buf, base)
        off = base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', buf, off)
            if cmd == LC_CODE_SIGNATURE:
                dataoff, datasize = struct.unpack_from('<II', buf, off + 8)
                sb = base + dataoff
                if struct.unpack_from('>I', buf, sb)[0] != 0xFADE0CC0:
                    return None
                count = struct.unpack_from('>I', buf, sb + 8)[0]
                for i in range(count):
                    typ, boff = struct.unpack_from('>II', buf, sb + 12 + 8 * i)
                    if typ == 0:
                        cd = sb + boff
                        if struct.unpack_from('>I', buf, cd)[0] != 0xFADE0C02:
                            return None
                        ver, flags = struct.unpack_from('>II', buf, cd + 8)
                        identoff = struct.unpack_from('>I', buf, cd + 20)[0]
                        ident = bytes(buf[cd + identoff:buf.index(b'\0', cd + identoff)]).decode()
                        team = ''
                        if ver >= 0x20200:
                            to = struct.unpack_from('>I', buf, cd + 48)[0]
                            if to:
                                team = bytes(buf[cd + to:buf.index(b'\0', cd + to)]).decode()
                        return ident, team, flags
                return None
            off += size
        return None
    return None


def code_signature_blobs(buf):
    """{slot type: blob bytes} of the first arm64 slice's embedded signature."""
    for base in slices(buf):
        ncmds = struct.unpack_from('<I', buf, base + 16)[0]
        off = base + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', buf, off)
            if cmd == LC_CODE_SIGNATURE:
                sb = base + struct.unpack_from('<I', buf, off + 8)[0]
                if struct.unpack_from('>I', buf, sb)[0] != 0xFADE0CC0:
                    return {}
                out = {}
                for i in range(struct.unpack_from('>I', buf, sb + 8)[0]):
                    t, o = struct.unpack_from('>II', buf, sb + 12 + 8 * i)
                    ln = struct.unpack_from('>I', buf, sb + o + 4)[0]
                    out[t] = bytes(buf[sb + o:sb + o + ln])
                return out
            off += size
        return {}
    return {}


def entitlements_xml(path):
    """XML entitlements of a (ldid- or Apple-signed) binary, parsed from the signature blob (slot 5), or None."""
    blob = code_signature_blobs(open(path, 'rb').read()).get(5)
    if blob and blob[:4] == b'\xfa\xde\x71\x71':
        return blob[8:]
    return None


def sign(path, check=True):
    """Ad-hoc re-sign keeping identifier, entitlements and the CS options of the old signature; verified after.
    codesign on macOS, ldid on Linux (renegade_platform.py)."""
    old = cs_identity(path)
    ents = rplat.read_entitlements(path)
    rplat.adhoc_sign(path, old[0] if old else None, old[2] if old else None, ents)
    if check and old:
        new = cs_identity(path)
        if not new or new[0] != old[0] or new[1] != old[1]:
            raise SystemExit(f'identity changed by re-sign of {path}: {old[:2]} -> {new and new[:2]}')
        lost = (old[2] & ~new[2]) & ~CS_FLAG_IGNORED
        if lost:
            raise SystemExit(f'CS flags {lost:#x} lost by re-sign of {path} (old {old[2]:#x}, new {new[2]:#x})')
    return old


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('input', nargs='+')
    ap.add_argument('-o', '--output')
    ap.add_argument('-v', '--verbose', action='store_true')
    ap.add_argument('--scan', action='store_true', help='count only')
    ap.add_argument('--sign', action='store_true')
    ap.add_argument('--dylinker')
    ap.add_argument('--subtype', choices=['arm64'])
    a = ap.parse_args()
    if a.output and len(a.input) != 1:
        ap.error('-o needs exactly one input')
    total = Counter()
    for path in a.input:
        out = a.output or path
        buf = bytearray(open(path, 'rb').read())
        counts, fj = Counter(), []
        for base in slices(buf):
            process_slice(buf, base, not a.scan, a.verbose, os.path.basename(path), counts, fj)
            if a.dylinker and not a.scan:
                repack_dylinker(buf, base, a.dylinker)
            if a.subtype and not a.scan:
                ct, cs = struct.unpack_from('<ii', buf, base + 4)
                struct.pack_into('<i', buf, base + 8, (cs & CPU_SUBTYPE_MASK) | CPU_SUBTYPE_ARM64_ALL)
        summary = ', '.join(f'{k}={v}' for k, v in sorted(counts.items())) or 'no PAC code'
        print(f'{path}: {summary}')
        for secname, off in fj[:20]:
            print(f'  FJCVTZS at file+0x{off:x} ({secname})')
        total.update(counts)
        if not a.scan:
            if out != path or True:
                open(out, 'wb').write(buf)
            if a.sign:
                sign(out)
    if len(a.input) > 1:
        print('TOTAL: ' + ', '.join(f'{k}={v}' for k, v in sorted(total.items())))


if __name__ == '__main__':
    main()
