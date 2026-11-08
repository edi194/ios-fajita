#!/usr/bin/env python3
"""Host checks for the kernel PAC emulation (xnu/patches-12377/1019-sweet-pac-emulation.patch).

  tools/pacemu/check.py [--header sweet_pacemu.h] [--fuzz N]

1. sweet_pacemu.h is taken from the patch (or --header) and pacemu_test.c is built with ASan/UBSan;
   its unit tests run.
2. forms.s (every decoded form + near neighbours) is assembled with `clang -arch arm64e`; each word's
   decode must equal the comment in forms.s.
3. Fuzz: single-bit flips of every form plus N random words are disassembled by llvm-objdump (arm64e,
   +pauth). The decoder must accept exactly the PAC mnemonics it handles, with the same operands.
4. Every accepted word is executed on a fixed state by the C executor and, after pacstrip.py's
   rewrite_word(), by a small interpreter of the rewritten ARMv8.0 word here: the results must agree.
   Known, intended differences are counted, not failed: pacstrip also rewrites the unallocated Z forms
   with a non-11111 field, and leaves LDRAx offsets it cannot encode (the kernel emulates those).
Needs Xcode (xcrun clang, llvm-objdump). Exit status 0 = all checks passed.
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PATCH = os.path.join(ROOT, 'xnu', 'patches-12377', '1019-sweet-pac-emulation.patch')
sys.path.insert(0, os.path.join(ROOT, 'tools', 'renegade'))
import pacstrip  # noqa: E402

M64 = (1 << 64) - 1
FAILS = []


def fail(msg):
    FAILS.append(msg)
    if len(FAILS) <= 40:
        print('FAIL ' + msg)


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        raise SystemExit(f'{" ".join(cmd)} failed:\n{r.stderr[-2000:]}')
    return r.stdout


def extract_header(tmp):
    os.makedirs(os.path.join(tmp, 'x'))
    run(['git', 'apply', '--include=osfmk/arm64/sweet_pacemu.h', PATCH], cwd=os.path.join(tmp, 'x'))
    return os.path.join(tmp, 'x', 'osfmk', 'arm64', 'sweet_pacemu.h')


def assemble_words(tmp, asm_lines, name):
    """[(word, llvm disassembly)] of asm_lines, in order."""
    s, o = os.path.join(tmp, name + '.s'), os.path.join(tmp, name + '.o')
    open(s, 'w').write('\n'.join(asm_lines) + '\n')
    run(['xcrun', 'clang', '-arch', 'arm64e', '-c', s, '-o', o])
    raw = run(['xcrun', 'llvm-objdump', '-d', '--mattr=+pauth', o])
    words = []
    for line in raw.splitlines():
        m = re.match(r'\s*[0-9a-f]+:\s+([0-9a-f]{8})\s+(.*)$', line)
        if m:
            words.append((int(m.group(1), 16), m.group(2).split('//')[0].strip()))
    return words


# ---- llvm text -> the decoder's canonical form ----------------------------------------------------------------
FAM = {
    'retaa': 'RET', 'retab': 'RET',
    'braa': 'BR', 'brab': 'BR', 'braaz': 'BR', 'brabz': 'BR',
    'blraa': 'BLR', 'blrab': 'BLR', 'blraaz': 'BLR', 'blrabz': 'BLR',
    'ldraa': 'LDR', 'ldrab': 'LDR', 'pacga': 'PACGA',
    'xpaci': 'XPAC', 'xpacd': 'XPAC',
}
for k in ('ia', 'ib', 'da', 'db', 'iza', 'izb', 'dza', 'dzb'):
    FAM['pac' + k] = 'PAC'
    FAM['aut' + k] = 'AUT'


def reg(r):
    r = r.strip()
    if r in ('sp', 'xzr', 'wzr'):
        return 31
    if r == 'fp':
        return 29
    if r == 'lr':
        return 30
    m = re.fullmatch(r'x(\d+)', r)
    if not m:
        raise ValueError(r)
    return int(m.group(1))


def llvm_canonical(text):
    parts = text.split(None, 1)
    mn, ops = parts[0], (parts[1] if len(parts) > 1 else '')
    fam = FAM.get(mn)
    if fam is None:
        return 'NONE'
    if fam == 'RET':
        return 'RET'
    if fam in ('BR', 'BLR'):
        return f'{fam} n={reg(ops.split(",")[0])}'
    if fam in ('PAC', 'AUT', 'XPAC'):
        return f'NOP {fam} d={reg(ops.split(",")[0])}'
    if fam == 'PACGA':
        d, n, m = (reg(x) for x in ops.split(','))
        return f'PACGA d={d} n={n} m={m}'
    m = re.fullmatch(r'(\w+),\s*\[(\w+)(?:,\s*#(-?(?:0x)?[0-9a-f]+))?\](!?)', ops)
    imm = int(m.group(3), 0) if m.group(3) else 0
    return f'LDR t={reg(m.group(1))} n={reg(m.group(2))} imm={imm}' + (' wb' if m.group(4) else '')


# ---- the fixed state of pacemu_test.c and an interpreter of pacstrip's replacement words -------------------------
def init_state():
    x = [(0x0000000100000000 + 0x10000 * i + 0x40) & M64 for i in range(31)]
    return {'x': x, 'sp': 0x000000016fdff000, 'pc': 0x0000000100004000}


def mem_value(addr):
    return ((addr * 0x9E3779B97F4A7C15) & M64) ^ 0x5555AAAA5555AAAA


def sext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def interp(w, st):
    """Execute one ARMv8.0 word of the kinds pacstrip emits. Returns the result line or None if unknown."""
    x, sp, pc = list(st['x']), st['sp'], st['pc']

    def xr(r):
        return 0 if r == 31 else x[r]

    rd, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
    if w == pacstrip.NOP:
        pc += 4
    elif w == pacstrip.RET:
        pc = x[30]
    elif (w & 0xFFFFFC1F) == 0xD61F0000:                       # BR
        pc = xr(rn)
    elif (w & 0xFFFFFC1F) == 0xD63F0000:                       # BLR
        t = xr(rn)
        x[30] = (pc + 4) & M64
        pc = t
    elif (w & 0xFFE0FFE0) == 0xAA0003E0:                       # MOV Xd, Xm
        if rd != 31:
            x[rd] = xr(rm)
        pc += 4
    elif (w & 0xFFE00000) == 0xCAC00000:                       # EOR Xd, Xn, Xm, ROR #imm6
        k = (w >> 10) & 63
        v = xr(rm)
        v = ((v >> k) | (v << (64 - k))) & M64 if k else v
        if rd != 31:
            x[rd] = xr(rn) ^ v
        pc += 4
    elif (w & 0xFFE00C00) in (0xF8400C00, 0xF8400000) or (w & 0xFFC00000) == 0xF9400000:   # LDR pre/LDUR/LDR uoff
        base = sp if rn == 31 else x[rn]
        if (w & 0xFFC00000) == 0xF9400000:
            off, wb = ((w >> 10) & 0xFFF) * 8, False
        else:
            off, wb = sext((w >> 12) & 0x1FF, 9), (w & 0xC00) == 0xC00
        addr = (base + off) & M64
        if wb:
            if rn == 31:
                sp = addr
            else:
                x[rn] = addr
        if rd != 31:
            x[rd] = mem_value(addr)
        pc += 4
    else:
        return None
    pc &= M64
    s = f'pc={pc:x}'
    if sp != st['sp']:
        s += f' sp={sp:x}'
    for i in range(31):
        if x[i] != st['x'][i]:
            s += f' x{i}={x[i]:x}'
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--header', help='sweet_pacemu.h to test instead of the one in the patch')
    ap.add_argument('--fuzz', type=int, default=20000, help='random words (default 20000)')
    ap.add_argument('--seed', type=int, default=845)
    ap.add_argument('--keep', action='store_true', help='keep the temporary directory')
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix='pacemu-')
    try:
        hdr = a.header or extract_header(tmp)
        os.makedirs(os.path.join(tmp, 'inc'), exist_ok=True)
        shutil.copy(hdr, os.path.join(tmp, 'inc', 'sweet_pacemu.h'))
        exe = os.path.join(tmp, 'pacemu_test')
        run(['xcrun', 'clang', '-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-Wshadow',
             '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-I', os.path.join(tmp, 'inc'),
             os.path.join(HERE, 'pacemu_test.c'), '-o', exe])

        # 1. unit tests
        r = subprocess.run([exe, 'unit'], capture_output=True, text=True)
        print(r.stdout.strip())
        if r.returncode:
            fail('unit tests: ' + r.stderr.strip()[-500:])

        def decode(words):
            out = subprocess.run([exe, 'decode'], input=''.join(f'{w:08x}\n' for w in words),
                                 capture_output=True, text=True, check=True).stdout.splitlines()
            return {int(l[:8], 16): l[9:] for l in out}

        # 2. forms.s
        asm, expect = [], []
        for line in open(os.path.join(HERE, 'forms.s')):
            if line.strip().startswith('//') or not line.strip():
                continue
            ins, exp = line.split('//')
            asm.append('\t' + ins.strip())
            expect.append((ins.strip(), exp.strip()))
        words = assemble_words(tmp, asm, 'forms')
        if len(words) != len(expect):
            fail(f'forms.s: {len(expect)} lines but {len(words)} words')
        dec = decode([w for w, _ in words])
        nform = 0
        for (w, dis), (src, exp) in zip(words, expect):
            got = dec[w]
            if got != exp:
                fail(f'forms: {src!r} = {w:08x} ({dis}): decoded {got!r}, expected {exp!r}')
            elif got != 'NONE' and llvm_canonical(dis) != got:
                fail(f'forms: {src!r} = {w:08x}: llvm says {dis!r} = {llvm_canonical(dis)!r}, decoded {got!r}')
            else:
                nform += 1
        print(f'forms.s: {nform}/{len(expect)} words decoded as expected '
              f'({sum(1 for _, e in expect if e != "NONE")} PAC forms, {sum(1 for _, e in expect if e == "NONE")} others)')

        # 3. fuzz against llvm-objdump
        rnd = random.Random(a.seed)
        fz = set()
        for w, _ in words:
            for b in range(32):
                fz.add(w ^ (1 << b))
            fz.add(w)
        tops = [0xD6, 0xD7, 0xDA, 0x9A, 0xF8]
        for i in range(a.fuzz):
            w = rnd.getrandbits(32)
            if i % 4:
                w = (tops[i % len(tops)] << 24) | (w & 0xFFFFFF)
            fz.add(w)
        fz = sorted(fz)
        dis = assemble_words(tmp, [f'\t.inst 0x{w:08x}' for w in fz], 'fuzz')
        dec = decode(fz)
        nacc = 0
        for w, text in dis:
            try:
                want = llvm_canonical(text) if not text.startswith('<unknown>') else 'NONE'
            except (ValueError, AttributeError) as e:
                fail(f'fuzz {w:08x}: cannot parse llvm {text!r}: {e}')
                continue
            if dec[w] != want:
                fail(f'fuzz {w:08x}: llvm {text!r} = {want!r}, decoded {dec[w]!r}')
            nacc += want != 'NONE'
        print(f'fuzz: {len(dis)} words vs llvm-objdump, {nacc} PAC instructions, '
              f'{sum(1 for f in FAILS if f.startswith("fuzz"))} mismatches')

        # 4. executor vs pacstrip's rewrite
        cand = sorted(set(fz) | {w for w, _ in words})
        out = subprocess.run([exe, 'exec'], input=''.join(f'{w:08x}\n' for w in cand),
                             capture_output=True, text=True, check=True).stdout.splitlines()
        st = init_state()
        same = lenient = unenc = 0
        for line in out:
            w, res = int(line[:8], 16), line[9:]
            new, name = pacstrip.rewrite_word(w)
            if res == 'NONE':
                if new is not None:
                    # pacstrip rewrites Z forms whose Rm/Rn field is not 11111 (unallocated): intended
                    zform = ((w & 0xFEDFF800) == 0xD61F0800 and not (w >> 24) & 1 and (w & 31) != 31) or \
                            ((w & 0xFFFFC000) == 0xDAC10000 and (w >> 13) & 1 and ((w >> 5) & 31) != 31)
                    if zform:
                        lenient += 1
                    else:
                        fail(f'pacstrip rewrites {w:08x} ({name}) but the kernel does not emulate it')
                continue
            if res == 'FAULT':
                fail(f'exec {w:08x}: unexpected fault')
                continue
            if new is None:
                if name and 'unencodable' in name:
                    unenc += 1
                else:
                    fail(f'kernel emulates {w:08x} but pacstrip does not rewrite it ({name})')
                continue
            ref = interp(new, st)
            if ref is None:
                fail(f'interp: unknown pacstrip word {new:08x} for {w:08x}')
            elif ref != res:
                fail(f'exec {w:08x} ({name}): kernel {res!r}, pacstrip {new:08x} {ref!r}')
            else:
                same += 1
        print(f'pacstrip: {same} emulated words behave like their pacstrip rewrite; {lenient} unallocated Z-form '
              f'words only pacstrip rewrites; {unenc} LDRAx offsets only the kernel handles')
    finally:
        if a.keep:
            print('kept ' + tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)

    print(('FAIL: %d problem(s)' % len(FAILS)) if FAILS else 'PASS: all PAC emulation checks')
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
