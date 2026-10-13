"""Helpers for disassembling the Earth Siege X-32VM executables (flat model).

Virtual address = file offset - BASE.  BASE found by matching string references.
"""
import re, struct, sys
import capstone

IMAGES = {
    'DBSIM': ('original/DBSIM.EXE', 0x48fd),
    'GO': ('original/GO.EXE', 0x48fd),  # same delta (247 string-push hits)
}


class Exe:
    def __init__(self, name='DBSIM'):
        path, base = IMAGES[name]
        self.d = open(path, 'rb').read()
        self.base = base
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.md.detail = False

    def va(self, fo):
        return fo - self.base

    def fo(self, va):
        return va + self.base

    def bytes_at(self, va, n):
        return self.d[self.fo(va):self.fo(va) + n]

    def cstr(self, va):
        fo = self.fo(va)
        if not (0 <= fo < len(self.d)):
            return None
        e = self.d.find(b'\0', fo)
        s = self.d[fo:e]
        if 2 <= len(s) < 120 and all(32 <= c < 127 for c in s):
            return s.decode()
        return None

    def u32(self, va):
        return struct.unpack_from('<I', self.d, self.fo(va))[0]

    def refs_to(self, va):
        pat = struct.pack('<I', va)
        return [self.va(m.start()) for m in re.finditer(re.escape(pat), self.d)]

    def dis(self, va, n=60, stop_at_ret=False):
        out = []
        code = self.bytes_at(va, n * 8)
        for ins in self.md.disasm(code, va):
            s = '%08x: %-8s %s' % (ins.address, ins.mnemonic, ins.op_str)
            for m in re.finditer(r'0x([0-9a-f]{4,8})', ins.op_str):
                t = int(m.group(1), 16)
                cs = self.cstr(t)
                if cs:
                    s += '   ; "%s"' % cs
            out.append(s)
            if len(out) >= n or (stop_at_ret and ins.mnemonic in ('ret', 'retf')):
                break
        return '\n'.join(out)

    def func_start(self, va, limit=0x2000):
        """Walk backwards to the nearest 'push ebp; mov ebp, esp' prologue."""
        for a in range(va, va - limit, -1):
            b = self.bytes_at(a, 3)
            if b == b'\x55\x8b\xec' or b == b'\x55\x89\xe5':
                return a
        return None


if __name__ == '__main__':
    e = Exe()
    cmd = sys.argv[1]
    if cmd == 'str':
        s = sys.argv[2].encode()
        for m in re.finditer(re.escape(s), e.d):
            va = e.va(m.start())
            print('string @%x refs:' % va, ['%x' % r for r in e.refs_to(va)])
    elif cmd == 'dis':
        print(e.dis(int(sys.argv[2], 16), int(sys.argv[3]) if len(sys.argv) > 3 else 60))
    elif cmd == 'func':
        a = e.func_start(int(sys.argv[2], 16))
        print('func @%x' % a)
        print(e.dis(a, int(sys.argv[3]) if len(sys.argv) > 3 else 120))
