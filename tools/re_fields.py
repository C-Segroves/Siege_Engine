"""Light-weight field-usage scanner for DBSIM.EXE.

Finds loads of a struct pointer from `[X + ptroff]` (e.g. the mech-type pointer at mech+0x188),
then follows that value through registers / stack slots (with constant `add reg, imm` deltas) for a
window of instructions and reports every memory access `[reg + off]` as a field offset of the
pointed-to struct (offset already corrected for the deltas).

    python tools/re_fields.py <ptroff-hex> [delta-hex] [window]

`delta` is subtracted from the final offsets (e.g. 2 for MechType where the .DAT starts at +2),
so the printed offsets are .DAT offsets.
"""
import re
import sys
import os
import collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import re_util as R  # noqa: E402

REG32 = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi')


def scan(ptroff, delta=0, window=60, src_regex=None):
    code = R.all_code()
    res = collections.defaultdict(list)
    src = re.compile(src_regex or (r'^(e[a-d]x|e[sd]i), dword ptr \[e\w\w \+ 0x%x\]$' % ptroff))
    for i, (a, m, o) in enumerate(code):
        if m != 'mov':
            continue
        mm = src.match(o)
        if not mm:
            continue
        alias = {mm.group(1): 0}          # location -> delta
        for j in range(i + 1, min(i + window, len(code))):
            a2, m2, o2 = code[j]
            if m2 in ('ret', 'retf') or (m2 == 'push' and o2 == 'ebp'):
                break
            # field accesses
            for f in re.finditer(r'\[(e[a-d]x|e[sd]i) \+ (0x[0-9a-f]+)\]', o2):
                if f.group(1) in alias:
                    off = alias[f.group(1)] + int(f.group(2), 16) - delta
                    res[off].append((a2, m2, o2))
            for f in re.finditer(r'\[(e[a-d]x|e[sd]i)\]', o2):
                if f.group(1) in alias and m2 != 'lea':
                    res[alias[f.group(1)] - delta].append((a2, m2, o2))
            ops = [s.strip() for s in o2.split(',')]
            dst = ops[0] if ops else ''
            if m2 == 'add' and dst in alias and len(ops) == 2 and re.match(r'^(0x[0-9a-f]+|\d+)$', ops[1]):
                alias[dst] += int(ops[1], 0)
                continue
            if m2 == 'mov' and len(ops) == 2:
                s = ops[1]
                sm = re.match(r'dword ptr \[(ebp [-+] 0x[0-9a-f]+)\]$', s)
                dm = re.match(r'dword ptr \[(ebp [-+] 0x[0-9a-f]+)\]$', dst)
                if s in alias and dst in REG32:
                    alias[dst] = alias[s]
                    continue
                if s in alias and dm:
                    alias[dm.group(1)] = alias[s]
                    continue
                if sm and sm.group(1) in alias and dst in REG32:
                    alias[dst] = alias[sm.group(1)]
                    continue
            # kill overwritten registers
            if dst in alias and m2 not in ('cmp', 'test', 'push'):
                del alias[dst]
            if m2 == 'call':
                for r in ('eax', 'ecx', 'edx'):
                    alias.pop(r, None)
            if not alias:
                break
    return res


if __name__ == '__main__':
    p = int(sys.argv[1], 16)
    d = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    res = scan(p, d, w)
    for k in sorted(res):
        uses = res[k]
        print('%5s %3d  %s' % (hex(k), len(uses), ' '.join('%x' % u[0] for u in uses[:16])))
