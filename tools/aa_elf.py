"""Minimal ELF32 (MIPS R5900, little endian) reader for the Aerial Assault executable SLUS_201.49: sections, symbols, a
disassembler (capstone) and a call tracer that follows constant arguments through a function. Used to read the campaign
mission scripts (classes cNN_logic / ctN_logic) compiled into the game."""
import struct

import capstone


class Elf:
    def __init__(self, data):
        self.d = data
        shoff, = struct.unpack_from('<I', data, 32)
        shentsize, shnum, shstr = struct.unpack_from('<HHH', data, 46)
        self.sections = []
        for i in range(shnum):
            name, typ, flags, addr, off, size, link, info, align, ent = struct.unpack_from('<10I', data, shoff + shentsize * i)
            self.sections.append(dict(name=name, type=typ, addr=addr, off=off, size=size, link=link, ent=ent))
        self.segs = []
        phoff, = struct.unpack_from('<I', data, 28)
        phnum, = struct.unpack_from('<H', data, 44)
        for i in range(phnum):
            t, off, va, pa, fs, ms, fl, al = struct.unpack_from('<8I', data, phoff + 32 * i)
            if t == 1:
                self.segs.append((va, off, fs))
        self.symbols = {}          # name -> (address, size)
        self.by_addr = {}
        for s in self.sections:
            if s['type'] == 2:     # SHT_SYMTAB
                strs = self.sections[s['link']]
                for k in range(s['size'] // 16):
                    nm, val, sz, info, other, shndx = struct.unpack_from('<IIIBBH', data, s['off'] + 16 * k)
                    end = data.index(b'\0', strs['off'] + nm)
                    name = data[strs['off'] + nm:end].decode('latin-1')
                    if name and val:
                        self.symbols.setdefault(name, (val, sz))
                        self.by_addr.setdefault(val, name)

    def read(self, addr, n):
        for va, off, fs in self.segs:
            if va <= addr < va + fs:
                return self.d[off + addr - va:off + addr - va + n]
        raise ValueError('address %#x not mapped' % addr)

    def cstr(self, addr):
        s = bytearray()
        while True:
            c = self.read(addr + len(s), 1)
            if c == b'\0' or len(s) > 400:
                return s.decode('latin-1')
            s += c

    def u32(self, addr):
        return struct.unpack('<I', self.read(addr, 4))[0]

    def utf16(self, addr):
        s = bytearray()
        while True:
            c = self.read(addr + len(s), 2)
            if c == b'\0\0' or len(s) > 800:
                return s.decode('utf-16le', 'replace')
            s += c


class Ins:
    """One instruction: address, mnemonic, operand string (unknown R5900 opcodes: mnemonic '.word', op_str hex)."""
    def __init__(self, address, mnemonic, op_str, word):
        self.address, self.mnemonic, self.op_str, self.word = address, mnemonic, op_str, word


_MD = None


def disasm(elf, addr, size):
    """[Ins] word by word, so R5900-only opcodes do not stop the listing."""
    global _MD
    if _MD is None:
        _MD = capstone.Cs(capstone.CS_ARCH_MIPS, capstone.CS_MODE_MIPS64 | capstone.CS_MODE_LITTLE_ENDIAN)
    code = elf.read(addr, size)
    out = []
    for o in range(0, size - 3, 4):
        w = code[o:o + 4]
        got = list(_MD.disasm(w, addr + o))
        if got:
            out.append(Ins(addr + o, got[0].mnemonic, got[0].op_str, struct.unpack('<I', w)[0]))
        else:
            out.append(Ins(addr + o, '.word', '%08x' % struct.unpack('<I', w)[0], struct.unpack('<I', w)[0]))
    return out


def _demangle(name):
    return name.split('__')[0] if '__' in name else name


def trace(elf, name, show_all=False):
    """Pseudo-listing of function `name`: constants propagated through registers (lui/ori/addiu/move), calls shown as
    `callee(a0, a1, a2, a3)` with known values (strings and floats resolved), branches with their targets."""
    addr, size = elf.symbols[name]
    ins = disasm(elf, addr, size)
    regs = {}
    out = []

    def val(r):
        v = regs.get(r)
        if v is None:
            return r
        if isinstance(v, tuple):
            return v[0]
        if 0x300000 <= v < 0x500000:
            try:
                s = elf.cstr(v)
                if s and s.isprintable():
                    return '"%s"' % s
            except ValueError:
                pass
            try:
                s = elf.utf16(v)
                if s and s.isprintable() and len(s) > 1:
                    return 'u"%s"' % s
            except ValueError:
                pass
        return hex(v) if v > 255 else str(v)

    def step(i):
        m, o = i.mnemonic, [x.strip() for x in i.op_str.split(',')]
        try:
            if m == 'lui':
                regs[o[0]] = int(o[1], 0) << 16
            elif m in ('addiu', 'ori') and len(o) == 3 and o[1] == '$zero':
                regs[o[0]] = int(o[2], 0) & 0xFFFFFFFF
            elif m in ('addiu', 'ori') and len(o) == 3 and isinstance(regs.get(o[1]), int):
                regs[o[0]] = (regs[o[1]] + int(o[2], 0) if m == 'addiu' else regs[o[1]] | int(o[2], 0)) & 0xFFFFFFFF
            elif m == 'li':
                regs[o[0]] = int(o[1], 0)
            elif m == 'move':
                regs[o[0]] = regs.get(o[1], ('=' + o[1],))
            elif m == 'mtc1':
                if isinstance(regs.get(o[0]), int):
                    import struct as _s
                    regs[o[1]] = ('%gf' % _s.unpack('<f', _s.pack('<I', regs[o[0]]))[0],)
            elif m in ('lw', 'ld', 'lwc1', 'lbu', 'lb', 'lh', 'lhu', 'addu', 'subu', 'mul', 'sll', 'lq', 'lwl', 'lwr') and o:
                regs.pop(o[0], None)
        except (ValueError, IndexError):
            pass

    skip = -1
    for k, i in enumerate(ins):
        if k == skip:
            continue
        m = i.mnemonic
        if m in ('jal', 'j'):
            if k + 1 < len(ins):
                step(ins[k + 1])
                skip = k + 1
            tgt = int(i.op_str, 0)
            nm = elf.by_addr.get(tgt, hex(tgt))
            args = [val(r) for r in ('$a0', '$a1', '$a2', '$a3')]
            out.append('%x  %s %s(%s)' % (i.address, 'CALL' if m == 'jal' else 'TAILCALL', nm, ', '.join(str(a) for a in args)))
            if m == 'jal':
                for r in ('$v0', '$v1', '$a0', '$a1', '$a2', '$a3'):
                    regs.pop(r, None)
        elif m.startswith('b') or m in ('jr',):
            out.append('%x  %s %s' % (i.address, m, i.op_str))
        else:
            step(i)
            if show_all or m in ('lw', 'sw', 'lwc1', 'swc1', 'slti', 'sltiu', 'c.lt.s', 'c.le.s', 'c.olt.s', 'c.ole.s', 'beq'):
                out.append('%x    %s %s' % (i.address, m, i.op_str))
    return out
