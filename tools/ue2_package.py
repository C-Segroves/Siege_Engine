"""Unreal Engine 2/2.5 package reader (.u .utx .usx .ukx .uax and Tribes: Vengeance .tvm/.pkg).

Reads the header, generations, name table, import table and export table; object bytes are fetched on demand.
Layout (UE2 versions 100..140, Tribes: Vengeance is version 130 / licensee 27):
  u32 magic C1832A9E, u16 version, u16 licensee, u32 package flags,
  u32 name count/offset, export count/offset, import count/offset, 16-byte GUID,
  u32 generation count + (export count, name count) pairs.
  name   = compact-index length (incl. NUL; negative = UTF-16) + chars + u32 flags
  import = compact class package, compact class name, i32 package, compact object name
  export = compact class, compact super, i32 package, compact name, u32 flags, compact size, compact offset (size > 0)
Compact index: first byte bit7 = sign, bit6 = more, low 6 bits; each further byte bit7 = more, low 7 bits.
No whole-file compression exists in this format (bulk data inside objects may be compressed per object).
Object references (compact) are: 0 = none, > 0 = export (index - 1), < 0 = import (-index - 1).
See docs/formats/tribes_vengeance.md.
"""
import struct

MAGIC = 0x9E2A83C1


class PackageError(Exception):
    pass


class Reader:
    def __init__(self, data, pos=0):
        self.d, self.p = data, pos

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]
        self.p += 4
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]
        self.p += 4
        return v

    def f32(self):
        v = struct.unpack_from('<f', self.d, self.p)[0]
        self.p += 4
        return v

    def index(self):
        b = self.u8()
        neg, v = b & 0x80, b & 0x3F
        if b & 0x40:
            shift = 6
            while True:
                b = self.u8()
                v |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
        return -v if neg else v

    def string(self):
        n = self.index()
        if n < 0:
            raw = self.d[self.p:self.p + -n * 2]
            self.p += -n * 2
            return raw.decode('utf-16-le').rstrip('\0')
        raw = self.d[self.p:self.p + n]
        self.p += n
        return raw.decode('latin-1').rstrip('\0')


class Package:
    """Package(data: bytes). Attributes: version, licensee, flags, guid, generations [(exports, names)],
    names [str], name_flags, imports [dict], exports [dict]."""

    def __init__(self, data):
        self.data = data
        if len(data) < 64 or struct.unpack_from('<I', data, 0)[0] != MAGIC:
            raise PackageError('not a UE package (bad magic)')
        r = Reader(data, 4)
        self.version, self.licensee, self.flags = r.u16(), r.u16(), r.u32()
        name_count, name_off = r.u32(), r.u32()
        export_count, export_off = r.u32(), r.u32()
        import_count, import_off = r.u32(), r.u32()
        self.guid = data[r.p:r.p + 16].hex()
        r.p += 16
        self.generations = [(r.u32(), r.u32()) for _ in range(r.u32())]
        for what, cnt, off in (('name', name_count, name_off), ('export', export_count, export_off),
                               ('import', import_count, import_off)):
            if cnt > 10_000_000 or off > len(data):
                raise PackageError('implausible %s table' % what)
        self.names, self.name_flags = [], []
        r.p = name_off
        for _ in range(name_count):
            self.names.append(r.string())
            self.name_flags.append(r.u32())
        self.imports = []
        r.p = import_off
        for _ in range(import_count):
            self.imports.append({'class_package': self.name(r.index()), 'class_name': self.name(r.index()),
                                 'package': r.i32(), 'name': self.name(r.index())})
        self.exports = []
        r.p = export_off
        for _ in range(export_count):
            e = {'class': r.index(), 'super': r.index(), 'package': r.i32(), 'name': self.name(r.index()),
                 'flags': r.u32(), 'size': r.index()}
            e['offset'] = r.index() if e['size'] > 0 else 0
            self.exports.append(e)

    def name(self, i):
        return self.names[i] if 0 <= i < len(self.names) else '<name %d>' % i

    def object_name(self, ref):
        """Name of an object reference (export > 0, import < 0, 0 = None)."""
        if ref > 0:
            return self.exports[ref - 1]['name']
        if ref < 0:
            return self.imports[-ref - 1]['name']
        return 'None'

    def class_name(self, export):
        return self.object_name(export['class']) if export['class'] else 'Class'

    def path(self, export):
        """Dotted group path of an export, e.g. 'Group.Name'."""
        parts, e = [export['name']], export
        while e['package'] > 0:
            e = self.exports[e['package'] - 1]
            parts.append(e['name'])
        return '.'.join(reversed(parts))

    def raw(self, export):
        return self.data[export['offset']:export['offset'] + export['size']]

    def find(self, class_name=None, name=None):
        return [e for e in self.exports if (class_name is None or self.class_name(e) == class_name)
                and (name is None or e['name'] == name)]

    def validate(self):
        """Returns problems found (empty = consistent): export ranges inside the file, references in range."""
        bad = []
        for i, e in enumerate(self.exports):
            if e['size'] and e['offset'] + e['size'] > len(self.data):
                bad.append('export %d (%s) lies outside the file' % (i, e['name']))
            if not -len(self.imports) <= e['class'] <= len(self.exports):
                bad.append('export %d has class reference %d' % (i, e['class']))
        return bad


def load(path):
    with open(path, 'rb') as f:
        return Package(f.read())


_SIZES = (1, 2, 4, 12, 16)


class Props(dict):
    """Property values by name; .refs holds the raw object reference (compact index) of object/class properties."""
    def __init__(self):
        super().__init__()
        self.refs = {}


def read_properties(pkg, r, strict=False, limit=None):
    """Reads UE2 tagged properties from Reader r until 'None'. Returns {name: value} (array elements as
    'name[i]'). byte/int/bool/float/str native, object/name refs as str, structs (Vector, Rotator...) as raw
    bytes. Returns what was read so far if the layout is unexpected."""
    out = Props()
    limit = limit or len(r.d)
    try:
        while r.p < limit:
            ni = r.index()
            if strict and not 0 <= ni < len(pkg.names):
                return None
            name = pkg.name(ni)
            if name == 'None':
                break
            info = r.u8()
            ptype, size_code, flag = info & 0xF, (info >> 4) & 7, bool(info & 0x80)
            if ptype == 10:
                r.index()                      # struct name
            size = _SIZES[size_code] if size_code < 5 else (r.u8() if size_code == 5 else r.u16() if size_code == 6 else r.u32())
            idx = 0
            if flag and ptype != 3:
                idx = r.u8()
                if idx & 0x80:
                    idx = ((idx & 0x7F) << 8) | r.u8()
            start = r.p
            if ptype == 3:
                val = flag
            elif ptype == 1:
                val = r.u8()
            elif ptype == 2:
                val = r.i32()
            elif ptype == 4:
                val = r.f32()
            elif ptype in (5, 8):
                ref = r.index()
                val = pkg.object_name(ref)
                refkey = ('%s[%d]' % (name, idx)) if flag else name
                out.refs[refkey] = ref
            elif ptype == 6:
                val = pkg.name(r.index())
            elif ptype in (7, 13):
                val = r.string()
            else:
                val = bytes(r.d[start:start + size])
            if strict and (ptype not in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13) or start + size > limit):
                return None
            r.p = start + size
            out[('%s[%d]' % (name, idx)) if flag and ptype != 3 else name] = val
    except (IndexError, struct.error, UnicodeDecodeError):
        return None if strict else out
    return out


def _strict_properties(pkg, data, pos, end, trailing=False):
    """Tagged properties from pos that finish with 'None' exactly at end (or anywhere before it with trailing),
    else None. With trailing the end position is returned too."""
    r = Reader(data, pos)
    out = read_properties(pkg, r, strict=True, limit=end)
    if out is None or not (trailing or r.p == end):
        return None
    return (out, r.p) if trailing else out


def _best_start(pkg, export, max_header, trailing):
    """(properties, end) of the best property stream start: most properties, then a first tag that is not an array
    element, then the earliest start (a start one byte late parses the same tags but swallows the first one)."""
    end = export['offset'] + export['size']
    best, best_end, best_key = {}, export['offset'], None
    for skip in range(0, min(max_header, export['size'] - 1)):
        res = _strict_properties(pkg, pkg.data, export['offset'] + skip, end, trailing=True)
        if not res or (not trailing and res[1] != end):
            continue
        props, pend = res
        if not props:
            continue
        key = (len(props), '[' not in next(iter(props)), -skip)
        if best_key is None or key > best_key:
            best, best_end, best_key = props, pend, key
    return best, best_end


def object_properties(pkg, export, max_header=160):
    """Tagged properties of an export. Actors start with a variable-length state header (stack node, probe mask,
    latent action, collision/zone fields), so the start is found by trying offsets until a clean property stream
    ends with 'None' exactly at the end of the export. Returns {} for objects with other layouts."""
    if export['size'] < 2:
        return {}
    return _best_start(pkg, export, max_header, False)[0]


def vec3(raw):
    return struct.unpack('<3f', raw) if isinstance(raw, (bytes, bytearray)) and len(raw) == 12 else None


def object_with_trailing(pkg, export, max_header=160):
    """(properties, end offset of the property stream) of an export that carries native data after its properties
    (terrain, textures ...)."""
    return _best_start(pkg, export, max_header, True)
