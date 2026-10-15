"""Byte-signature scans of a PE executable, so exporters find code and tables by what they look like instead of at
fixed addresses (builds of one game move them: Starsiege Feb 1999 vs Aug 1999, Tribes 2 build 21570 vs 25034).

A signature is a hex string with `??` wildcards ('??{n}' = n bytes) for the bytes that differ between builds (operands, addresses):
    'b81e5c0500 ?? ?? ?? ?? ?? ?? ?? ?? 83c04f'
`find_one` demands exactly one match in the code section and stops with a clear message otherwise.
"""
import os
import re
import struct



class Pe:
    """A PE image: virtual address <-> file offset and signature scans."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.data = open(path, 'rb').read()
        d = self.data
        pe = struct.unpack_from('<I', d, 0x3c)[0]
        count = struct.unpack_from('<H', d, pe + 6)[0]
        opt = struct.unpack_from('<H', d, pe + 20)[0]
        self.base = struct.unpack_from('<I', d, pe + 52)[0]
        self.sections = []          # (name, va, size, raw offset, characteristics)
        at = pe + 24 + opt
        for _ in range(count):
            name = d[at:at + 8].rstrip(bytes(1)).decode('latin1')
            size, va, raw_size, raw = struct.unpack_from('<IIII', d, at + 8)
            flags = struct.unpack_from('<I', d, at + 36)[0]
            self.sections.append((name, va + self.base, min(max(size, raw_size), len(d) - raw), raw, flags))
            at += 40

    def to_offset(self, va):
        for _name, sva, size, raw, _f in self.sections:
            if sva <= va < sva + size:
                return raw + va - sva
        raise ValueError('%s: address 0x%x is in no section' % (self.name, va))

    def to_va(self, offset):
        for _name, sva, size, raw, _f in self.sections:
            if raw <= offset < raw + size:
                return sva + offset - raw
        raise ValueError('%s: file offset 0x%x is in no section' % (self.name, offset))

    def at(self, va, n):
        o = self.to_offset(va)
        return self.data[o:o + n]

    def u32(self, va):
        return struct.unpack('<I', self.at(va, 4))[0]

    def u16(self, va):
        return struct.unpack('<H', self.at(va, 2))[0]

    def f32(self, va):
        return struct.unpack('<f', self.at(va, 4))[0]

    def f64(self, va):
        return struct.unpack('<d', self.at(va, 8))[0]

    def _ranges(self, where):
        if where == 'code':
            r = [(s[3], s[3] + s[2]) for s in self.sections if s[4] & 0x20] or [(0, len(self.data))]
        else:
            r = [(0, len(self.data))]
        return r

    def find_all(self, signature, where='code'):
        """-> [virtual address] of every match of `signature` ('code' section(s) or 'all')."""
        rx = signature_regex(signature)
        out = []
        for lo, hi in self._ranges(where):
            out.extend(self.to_va(m.start()) for m in rx.finditer(self.data, lo, hi))
        return out

    def find_one(self, signature, what, where='code'):
        """The virtual address of the only match; SystemExit with a clear message when there are none or several."""
        hits = self.find_all(signature, where)
        if len(hits) != 1:
            raise SystemExit('%s: %s: expected exactly one match of the byte pattern, found %d%s (this build of the '
                             'executable is not known to the importer)'
                             % (self.name, what, len(hits), ' at ' + ', '.join('0x%x' % h for h in hits[:6]) if hits else ''))
        return hits[0]


def signature_regex(signature):
    parts = signature.split()
    if len(parts) == 1 and len(parts[0]) > 2:           # 'aabb??cc' without spaces
        s = parts[0]
        parts = [s[i:i + 2] for i in range(0, len(s), 2)]
    out = b''
    for p in parts:
        gap = re.fullmatch(r'\?\?\{(\d+)\}', p)       # '??{12}': twelve bytes of anything
        out += (b'.{%d}' % int(gap.group(1))) if gap else b'.' if p == '??' else re.escape(bytes.fromhex(p))
    return re.compile(out, re.S)
