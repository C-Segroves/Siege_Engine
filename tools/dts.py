"""Earth Siege 1 DTS (3Space v2 shape) parser.

Structure layout follows open-siege/siege-studio (MIT), 3space.cpp (v1 shapes).
Every object starts with an 8-byte header: u16 type, u16 class, u32 size.
"""
import struct

# (type, class) -> name
TAGS = {
    (0x08, 0x14): 'shape', (0x03, 0x1e): 'an_shape',
    (0x07, 0x14): 'part_list', (0x15, 0x14): 'bsp_part', (0x0b, 0x14): 'cell_anim_part',
    (0x0c, 0x14): 'detail_part', (0x05, 0x14): 'base_part', (0x13, 0x14): 'bitmap_part',
    (0x14, 0x14): 'group', (0x0a, 0x14): 'bsp_group',
    (0x01, 0x14): 'poly', (0x02, 0x14): 'solid_poly', (0x0f, 0x14): 'texture_for_poly',
    (0x03, 0x14): 'shaded_poly', (0x09, 0x14): 'gouraud_poly',
    (0x10, 0x14): 'alias_solid_poly', (0x11, 0x14): 'alias_shaded_poly', (0x12, 0x14): 'alias_gouraud_poly',
    (0x0e, 0x14): 'null_obj', (0x01, 0x2bc): 'grid_shape',
    (0x01, 0x1e): 'an_sequence', (0x04, 0x1e): 'an_cyclic_sequence', (0x02, 0x1e): 'an_anim_list',
}


class Reader:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]; self.p += 2; return v

    def s16(self):
        v = struct.unpack_from('<h', self.d, self.p)[0]; self.p += 2; return v

    def s32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]; self.p += 4; return v

    def arr(self, fmt, n):
        size = struct.calcsize('<' + fmt)
        out = [struct.unpack_from('<' + fmt, self.d, self.p + i * size) for i in range(n)]
        self.p += size * n
        return [o[0] if len(o) == 1 else o for o in out]


def read_base(r, o):
    o['transform'] = r.s16(); o['id'] = r.s16(); o['radius'] = r.s16()
    o['center'] = r.arr('hhh', 1)[0]


def read_part_list(r, o):
    read_base(r, o)
    n = r.u16()
    o['parts'] = [read_obj(r) for _ in range(n)]


def read_group(r, o):
    read_base(r, o)
    ni, np_, nc, nitems = r.u16(), r.u16(), r.u16(), r.u16()
    o['indexes'] = r.arr('H', ni)
    o['points'] = r.arr('hhh', np_)
    o['colors'] = [bytes(c) for c in r.arr('4B', nc)]
    o['items'] = [read_obj(r) for _ in range(nitems)]


def read_poly(r, o):
    o['normal'] = r.u16(); o['center'] = r.u16(); o['vcount'] = r.u16(); o['vlist'] = r.u16()


def read_sequence(r, o):
    o['tick'] = r.s16(); o['priority'] = r.s16(); o['gm'] = r.s16()
    nf = r.s16()
    o['frames'] = r.arr('HHH', nf)
    npl = r.u16()
    o['part_list'] = r.arr('H', npl)
    o['transform_index'] = r.arr('H', nf * npl)


def read_obj(r):
    start = r.p
    typ, cls, size = struct.unpack_from('<HHI', r.d, r.p)
    r.p += 8
    end = r.p + size
    name = TAGS.get((typ, cls), 'unknown_%02x_%02x' % (typ, cls))
    o = {'type': name}
    if name in ('shape', 'an_shape'):
        read_part_list(r, o)
        ntl, nsl = r.u16(), r.u16()
        o['sequence_list'] = r.arr('h', nsl)
        o['transform_list'] = r.arr('h', ntl)
        o['extra'] = []
        while r.p < end:
            o['extra'].append(read_obj(r))
    elif name in ('part_list', 'grid_shape'):
        read_part_list(r, o)
    elif name == 'bsp_part':
        read_part_list(r, o)
        n = r.u16()
        o['nodes'] = r.arr('hhhihh', n)
        o['node_transforms'] = r.arr('H', n)
    elif name == 'cell_anim_part':
        read_part_list(r, o); o['anim_sequence'] = r.s16()
    elif name == 'detail_part':
        read_part_list(r, o)
        o['details'] = r.arr('h', len(o['parts']))  # visible-size threshold per detail level
    elif name == 'base_part':
        read_base(r, o)
    elif name == 'bitmap_part':
        read_base(r, o); o['bmp_tag'] = r.u16(); o['xo'] = r.d[r.p]; o['yo'] = r.d[r.p + 1]; r.p += 2
    elif name == 'group':
        read_group(r, o)
    elif name == 'bsp_group':
        read_group(r, o)
        n = r.u16(); o['nodes'] = r.arr('ihhh', n)
    elif name == 'poly':
        read_poly(r, o)
    elif name in ('solid_poly', 'texture_for_poly', 'shaded_poly', 'alias_solid_poly', 'alias_shaded_poly'):
        read_poly(r, o); o['color'] = r.u16()
    elif name in ('gouraud_poly', 'alias_gouraud_poly'):
        read_poly(r, o); o['color'] = r.u16(); o['normal_list'] = r.u16()
    elif name in ('an_sequence', 'an_cyclic_sequence'):
        read_sequence(r, o)
    elif name == 'an_anim_list':
        n = r.s16()
        o['sequences'] = []
        for _ in range(n):
            r.p += 8
            s = {}; read_sequence(r, s); o['sequences'].append(s)
        o['transitions'] = r.arr('HHHH', r.s16())
        o['transforms'] = r.arr('HHHhhh', r.s16())
        o['default_transforms'] = r.arr('H', r.s16())
        o['relations'] = r.arr('hh', r.s16())
    o['_size'] = size
    o['_off'] = start
    if r.p != end:
        o['_consumed'] = r.p - (start + 8)
    r.p = end
    return o


def read_file(data):
    """A DTS file may contain several top-level objects back to back."""
    r = Reader(data)
    objs = []
    while r.p + 8 <= len(data):
        objs.append(read_obj(r))
        r.p += r.p & 1  # top-level objects are word aligned
    return objs


def dump(o, depth=0, out=print):
    pad = '  ' * depth
    keys = {k: v for k, v in o.items() if k not in ('parts', 'items', 'extra', 'type', 'sequences')}
    summary = []
    for k, v in keys.items():
        if isinstance(v, list):
            summary.append('%s[%d]' % (k, len(v)))
        else:
            summary.append('%s=%s' % (k, v))
    out(pad + o['type'] + ' ' + ' '.join(summary))
    for k in ('parts', 'items', 'extra'):
        for c in o.get(k, []):
            dump(c, depth + 1, out)


if __name__ == '__main__':
    import sys
    for o in read_file(open(sys.argv[1], 'rb').read()):
        dump(o)
