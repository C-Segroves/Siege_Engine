"""ue2_package: a synthetic minimal UE2.5 package (Tribes: Vengeance version 130 / licensee 27) reads back.

    python -m pytest tools/tests/test_ue2_package.py
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import ue2_package as U  # noqa: E402


def cidx(v):
    neg, v = v < 0, abs(v)
    b = (0x80 if neg else 0) | (v & 0x3F)
    v >>= 6
    out = bytearray()
    if v:
        b |= 0x40
    out.append(b)
    while v:
        c = v & 0x7F
        v >>= 7
        out.append(c | (0x80 if v else 0))
    return bytes(out)


def cstr(s):
    return cidx(len(s) + 1) + s.encode() + b'\0'


def build():
    names = ['None', 'Core', 'Class', 'Actor', 'Location', 'Vector', 'Label', 'Thing']
    nt = b''.join(cstr(n) + struct.pack('<I', 0x70004) for n in names)
    imports = cidx(1) + cidx(2) + struct.pack('<i', 0) + cidx(3)        # Core.Class 'Actor'
    # one export: class = import 1 (-1), name Thing; properties: Location (struct Vector, 12 bytes), Label (name), None
    props = (cidx(4) + bytes([0x3A]) + cidx(5) + struct.pack('<3f', 1.0, 2.0, 3.0)
             + cidx(6) + bytes([0x06]) + cidx(7) + cidx(0))
    head_size = 4 + 2 + 2 + 4 + 6 * 4 + 16 + 4 + 8
    name_off = head_size
    import_off = name_off + len(nt)
    export_off = import_off + len(imports)
    obj_off = export_off + 32
    export = cidx(-1) + cidx(0) + struct.pack('<i', 0) + cidx(7) + struct.pack('<I', 0x70004) + cidx(len(props)) + cidx(obj_off)
    export = export.ljust(32, b'\0')
    header = struct.pack('<IHHI', U.MAGIC, 130, 27, 1) + struct.pack('<6I', len(names), name_off, 1, export_off, 1, import_off)
    header += bytes(range(16)) + struct.pack('<I', 1) + struct.pack('<II', 1, len(names))
    assert len(header) == head_size
    return header + nt + imports + export + props


def test_header_tables_and_properties():
    p = U.Package(build())
    assert (p.version, p.licensee) == (130, 27)
    assert p.generations == [(1, 8)]
    assert p.names[:3] == ['None', 'Core', 'Class']
    assert p.imports == [{'class_package': 'Core', 'class_name': 'Class', 'package': 0, 'name': 'Actor'}]
    e = p.exports[0]
    assert p.class_name(e) == 'Actor' and e['name'] == 'Thing' and e['size'] > 0
    assert p.validate() == []
    props = U.object_properties(p, e)
    assert U.vec3(props['Location']) == (1.0, 2.0, 3.0)
    assert props['Label'] == 'Thing'
    assert p.find('Actor', 'Thing') == [e]


def test_compact_index_roundtrip():
    for v in (0, 1, -1, 63, 64, -64, 5000, -123456):
        assert U.Reader(cidx(v)).index() == v


def test_rejects_non_package():
    try:
        U.Package(b'x' * 100)
    except U.PackageError:
        return
    raise AssertionError('expected PackageError')
