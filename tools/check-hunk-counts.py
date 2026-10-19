#!/usr/bin/env python3
"""Validate that every unified-diff hunk header count matches its hunk body.

`git apply` trusts the declared counts: when a header declares fewer lines than
the body actually contains, git applies the patch "cleanly" but silently drops
the trailing lines. That is exactly how the closing `#endif` disappeared from
`pexpert/arm64/SWEET.h`: patch 0004 declared `+1,75` for a 76-line body.

Run this before pushing new or edited patches:

    python3 tools/check-hunk-counts.py xnu/patches

Exits non-zero when any hunk header disagrees with its body.
"""
import re
import sys
from pathlib import Path

HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
FILE_OLD = re.compile(r'^--- ')
FILE_NEW = re.compile(r'^\+\+\+ ')


def check(path):
    problems = []
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    file = '?'
    hunk = None
    old_n = new_n = 0
    start = 0

    def flush():
        if hunk is not None and (old_n, new_n) != (hunk[1], hunk[3]):
            problems.append(
                f"{file}:{start}: header says -{hunk[0]},{hunk[1]} +{hunk[2]},{hunk[3]}"
                f" but body has -{old_n} +{new_n}")

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        nxt = lines[i + 1] if i + 1 < n else ''
        m = HUNK.match(line)
        if m:
            flush()
            hunk = (int(m.group(1)), int(m.group(2) or 1),
                    int(m.group(3)), int(m.group(4) or 1))
            old_n = new_n = 0
            start = i + 1
        elif line.startswith('diff --git '):
            flush()
            hunk = None
            file = line.split(' b/', 1)[-1] if ' b/' in line else line
        elif FILE_OLD.match(line) and FILE_NEW.match(nxt):
            # File header pair; these patches often omit the "diff --git" line.
            flush()
            hunk = None
            file = nxt[4:].strip()
            i += 1
        elif hunk is not None:
            if line.startswith('\\'):
                pass
            elif line.startswith('+'):
                new_n += 1
            elif line.startswith('-'):
                old_n += 1
            elif line.startswith(' ') or line == '':
                old_n += 1
                new_n += 1
            else:
                flush()
                hunk = None
        i += 1
    flush()
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else 'xnu/patches')
    files = sorted(root.glob('*.patch'))
    bad = 0
    for p in files:
        probs = check(p)
        if probs:
            bad += 1
            print(f"== {p.name} ==")
            for x in probs:
                print("  ", x)
    if bad:
        print(f"\n{bad} of {len(files)} file(s) with hunk-count mismatches")
        return 1
    print(f"all {len(files)} patch files OK")
    return 0


if __name__ == '__main__':
    sys.exit(main())
