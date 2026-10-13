"""Small reverse-engineering helpers on top of tools/exe.py (DBSIM.EXE).

    python tools/re_util.py fn <va>          disassemble one whole function (until next prologue)
    python tools/re_util.py callers <va>     list call sites (E8 rel32) of a function
    python tools/re_util.py vt <va> [n]      dump a vtable (n entries)
    python tools/re_util.py grep <regex> [lo hi]  regex over disassembly of the code range
"""
import re
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from exe import Exe  # noqa: E402

E = Exe()
CODE_LO, CODE_HI = 0x1000, 0x66000


def func_end(va, limit=0x3000):
    """Address of the next 'push ebp; mov ebp, esp' prologue after va (approximate function end)."""
    for a in range(va + 3, va + limit):
        if E.bytes_at(a, 3) in (b'\x55\x8b\xec', b'\x55\x89\xe5'):
            return a
    return va + limit


def fn(va):
    end = func_end(va)
    out = []
    code = E.bytes_at(va, end - va)
    for ins in E.md.disasm(code, va):
        s = '%08x: %-8s %s' % (ins.address, ins.mnemonic, ins.op_str)
        for m in re.finditer(r'0x([0-9a-f]{4,8})', ins.op_str):
            cs = E.cstr(int(m.group(1), 16))
            if cs:
                s += '   ; "%s"' % cs
        out.append(s)
    return out


def callers(t):
    d = E.d
    res = []
    for m in re.finditer(b'\xe8', d[E.fo(CODE_LO):E.fo(CODE_HI)]):
        fo = m.start() + E.fo(CODE_LO)
        rel = struct.unpack_from('<i', d, fo + 1)[0]
        va = E.va(fo)
        if va + 5 + rel == t:
            res.append(va)
    return res


_all = None


def all_code():
    global _all
    if _all is None:
        _all = []
        code = E.bytes_at(CODE_LO, CODE_HI - CODE_LO)
        off = 0
        while off < len(code):
            n = 0
            for ins in E.md.disasm(code[off:], CODE_LO + off):
                _all.append((ins.address, ins.mnemonic, ins.op_str))
                n = ins.address + ins.size - CODE_LO
            if n <= off:
                off += 1
            else:
                off = n
    return _all


if __name__ == '__main__':
    c = sys.argv[1]
    if c == 'fn':
        a = int(sys.argv[2], 16)
        print('\n'.join(fn(a)))
    elif c == 'callers':
        t = int(sys.argv[2], 16)
        for x in callers(t):
            print('%x in func %x' % (x, E.func_start(x) or 0))
    elif c == 'vt':
        a = int(sys.argv[2], 16)
        n = int(sys.argv[3]) if len(sys.argv) > 3 else 16
        for i in range(n):
            print('%2d +%02x %x' % (i, 4 * i, E.u32(a + 4 * i)))
    elif c == 'grep':
        rx = re.compile(sys.argv[2])
        lo = int(sys.argv[3], 16) if len(sys.argv) > 3 else CODE_LO
        hi = int(sys.argv[4], 16) if len(sys.argv) > 4 else CODE_HI
        for a, m, o in all_code():
            if lo <= a < hi and rx.search(m + ' ' + o):
                print('%08x: %-8s %s' % (a, m, o))
