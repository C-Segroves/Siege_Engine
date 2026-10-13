"""Torque / Tribes 2 (V12, 2001) DTS shape reader: versions 18-26.  Tribes 2 ships v15-23: armors and
vehicles are v22/v23; v19-21 (organics, weapon_energy = the blaster, the missile, flares, wrecks) use the
pre-22 counts / sequences below; v18 (grenade and mortar projectiles, plasma bolt, disc explosion) is the
old plain-stream layout of read_old_shape.  Every shape the scripts and missions reference reads and
consumes exactly; only chaingun_shot (v15) and borg3 (v16), referenced by nothing, are not supported.

Version differences (all checked against the guards / exact consumption of the disc's files):
  * v<22: one node-state count (default pose included) instead of rotation / translation / scale counts;
    sequences have no flags word (three bytes blend / cyclic / makePath), one base state index, one
    rotation+translation bitset; base indices count the default pose (normalise_old_sequences).
  * v<20: decal meshes carry an empty mesh header (guard + 15 words) and 3 words + guard after indices.
  * material list: detail scale from v19, reflection amount from v21.

Layout (TSShape::read / assembleShape, field order as in siege-studio torque_structures.hpp (MIT) and the
public Torque Game Engine 1.x source):

  u32 version (low byte = DTS version, high 16 bits = exporter version)
  i32 sizeMemBuffer (in u32 words), i32 startU16, i32 startU8 (word offsets into the buffer)
  u32 buffer[sizeMemBuffer]   -- three interleaved streams: 32-bit from word 0, 16-bit from startU16,
                                 8-bit from startU8; read sequentially, "guards" (running counters 0,1,2..)
                                 are checked in all three streams at the same time; align32() is a no-op
                                 for the Tribes 2 files (no padding was written).
  i32 numSequences, sequences (plain stream), material list (plain stream)

  buffer: counts (nodes, objects, decals, subShapes, ifls, nodeRots, nodeTrans, uniform/aligned/arbitrary
  scales, groundFrames, objectStates, decalStates, triggers, details, meshes, [v<23: skins], names,
  smallestVisibleSize, smallestVisibleDL) | guard | radius, tubeRadius, center, bounds | guard |
  nodes 5xi32 | guard | objects 6xi32 | guard | decals 5xi32 | guard | ifl 5xi32 | guard |
  subShapeFirstNode, FirstObject, FirstDecal | guard | default rotations (16-bit quats, 4xi16 per node),
  default translations 3xf32, node translations, node rotations | guard | [v>21: uniform, aligned,
  arbitrary scales | guard] | [v>23: ground frames | guard] | object states 3xi32 | guard | decal states |
  guard | triggers | guard | details 7x32 | guard | meshes | guard | names (NUL strings in the 8-bit
  stream) | guard | [v<23: per-detail firstSkin/numSkins | guard | skin meshes | guard]

  mesh: i32 type (0 standard, 1 skin, 2 decal, 3 sorted, 4 null) then guard, numFrames, numMatFrames,
  parentMesh, bounds, center, radius, numVerts + verts (3xf32; shared with parentMesh when >= 0),
  numTVerts + tverts (2xf32), normals 3xf32 + encoded normals u8 (v>21), numPrims + prims
  (16-bit start/count + 32-bit material word; v>=25: 3x32), numIndices + indices (16-bit; v>=25 32-bit),
  numMerge + merge (16-bit), align32, vertsPerFrame, flags, guard.
  Skin: + numInitialVerts, initial verts, normals, encoded normals, initial transforms (16xf32 each),
  vertexIndex/boneIndex/weight (sz each), nodeIndex, guard.
  Sorted: + clusters 8xi32, startCluster, firstVerts, numVerts, firstTVerts, alwaysWriteDepth, guard.
  Primitive material word: bits 30-31 type (0 triangles, 1 strip, 2 fan), 0x10000000 no material,
  low 28 bits material index.

Units: 1 unit = 1 metre (docs/formats/tribes2.md).
"""
import math, struct, sys


class Alloc:
    def __init__(self, buf, start16, start8):
        self.b = buf
        self.p32 = 0
        self.p16 = start16 * 4
        self.p8 = start8 * 4
        self.g = 0

    def i32(self, n=None):
        k = 1 if n is None else n
        v = struct.unpack_from('<%di' % k, self.b, self.p32)
        self.p32 += 4 * k
        return v[0] if n is None else list(v)

    def f32(self, n):
        v = struct.unpack_from('<%df' % n, self.b, self.p32)
        self.p32 += 4 * n
        return list(v)

    def i16(self, n):
        v = struct.unpack_from('<%dh' % n, self.b, self.p16)
        self.p16 += 2 * n
        return list(v)

    def u8(self, n):
        v = self.b[self.p8:self.p8 + n]
        self.p8 += n
        return v

    # Tribes 2 (v22/v23) buffers are NOT padded at align32() points: aligning breaks every guard check
    # (verified on all 183 v22/v23 shapes, which then consume exactly).  Kept switchable for later engines.
    ALIGN = False

    def align32(self):
        if self.ALIGN:
            self.p16 = (self.p16 + 3) & ~3
            self.p8 = (self.p8 + 3) & ~3

    def guard(self, where=''):
        a = struct.unpack_from('<i', self.b, self.p32)[0]
        b = struct.unpack_from('<h', self.b, self.p16)[0]
        c = self.b[self.p8]
        self.p32 += 4
        self.p16 += 2
        self.p8 += 1
        if not (a == self.g and b == self.g and c == (self.g & 0xFF)):
            raise ValueError('guard %d failed at %s: %r' % (self.g, where, (a, b, c)))
        self.g += 1


def read_decal_mesh(a, ver, m):
    """TSDecalMesh: prims (16-bit start/count + 32-bit mat), 16-bit indices, startPrimitive, texgenS/T
    (4 floats each per start), materialIndex.  Before v20 decals were derived from meshes: an empty mesh
    header (guard + 15 words) precedes the prims and 3 words + a guard follow the indices
    (TSDecalMesh::assemble)."""
    if ver < 20:
        a.guard('old decal mesh')
        a.i32(15)
    n = a.i32()
    a.i16(2 * n)
    a.i32(n)
    a.align32()
    n = a.i32()
    a.i16(n)
    a.align32()
    if ver < 20:
        a.i32(3)
        a.guard('old decal mesh end')
    n = a.i32()
    a.i32(n)
    a.f32(4 * n)
    a.f32(4 * n)
    m['material'] = a.i32()
    a.guard('decal end')


def read_mesh(a, mtype, ver, store):
    """store: per-mesh-index lists for shared (parentMesh) data."""
    m = {'type': mtype}
    if mtype == 4:
        return m
    if mtype == 2:
        read_decal_mesh(a, ver, m)
        return m
    a.guard('mesh start')
    m['num_frames'], m['num_mat_frames'], m['parent'] = a.i32(), a.i32(), a.i32()
    m['bounds'] = a.f32(6)
    m['center'] = a.f32(3)
    m['radius'] = a.f32(1)[0]
    par = m['parent']

    def shared32(key, n, kind='f'):
        if par < 0:
            v = a.f32(n) if kind == 'f' else a.i32(n)
        else:
            v = store[par][key]
        return v

    nv = a.i32()
    m['verts'] = shared32('verts', 3 * nv)
    nt = a.i32()
    m['tverts'] = shared32('tverts', 2 * nt)
    if ver >= 26:
        n2 = a.i32()
        shared32('tverts2', 2 * n2)
        nc = a.i32()
        shared32('colors', nc, 'i')
    if ver > 21:
        m['norms'] = shared32('norms', 3 * nv)
        if par < 0:
            a.u8(nv)
    else:
        m['norms'] = shared32('norms', 3 * nv)
    np_ = a.i32()
    if ver >= 25:
        raw = a.i32(3 * np_)
        prims = [(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2] & 0xFFFFFFFF) for i in range(np_)]
        ni = a.i32()
        idx = a.i32(ni)
    else:
        se = a.i16(2 * np_)
        mats = a.i32(np_)
        prims = [(se[2 * i], se[2 * i + 1], mats[i] & 0xFFFFFFFF) for i in range(np_)]
        ni = a.i32()
        idx = [x & 0xFFFF for x in a.i16(ni)]
    m['prims'], m['indices'] = prims, idx
    nmerge = a.i32()
    a.i16(nmerge)
    a.align32()
    m['verts_per_frame'] = a.i32()
    m['flags'] = a.i32()
    a.guard('mesh end')
    if mtype == 1:
        niv = a.i32()
        m['initial_verts'] = shared32('initial_verts', 3 * niv)
        if ver > 21:
            m['initial_norms'] = shared32('initial_norms', 3 * niv)
            if par < 0:
                a.u8(niv)
        else:
            m['initial_norms'] = shared32('initial_norms', 3 * niv)
        n = a.i32()
        m['initial_transforms'] = shared32('initial_transforms', 16 * n)
        n = a.i32()
        m['vertex_index'] = shared32('vertex_index', n, 'i')
        m['bone_index'] = shared32('bone_index', n, 'i')
        m['weight'] = shared32('weight', n)
        n = a.i32()
        m['node_index'] = shared32('node_index', n, 'i')
        a.guard('skin end')
    elif mtype == 3:
        nc = a.i32()
        a.i32(nc * 8)
        for _ in range(4):
            n = a.i32()
            a.i32(n)
        a.i32()
        a.guard('sorted end')
    return m


def read_bitset(d, p):
    dummy, nw = struct.unpack_from('<ii', d, p)
    words = struct.unpack_from('<%dI' % nw, d, p + 8)
    bits = [i for i in range(nw * 32) if words[i // 32] >> (i % 32) & 1]
    return bits, p + 8 + 4 * nw


def read_counts(a, ver):
    """Header counts.  Before v22 one 'node states' count covers rotations and translations alike and
    includes the default state of every node (TSShape::assembleShape: numNodeRots = numNodeTrans =
    count - numNodes); there are no scale arrays."""
    head = dict(zip(('nodes', 'objects', 'decals', 'subshapes', 'ifls'), a.i32(5)))
    if ver < 22:
        states = a.i32() - head['nodes']
        head.update(node_rots=states, node_trans=states, uscales=0, ascales=0, arbscales=0)
    else:
        head.update(zip(('node_rots', 'node_trans', 'uscales', 'ascales', 'arbscales'), a.i32(5)))
    head['ground'] = a.i32() if ver > 23 else 0
    head.update(zip(('object_states', 'decal_states', 'triggers', 'details', 'meshes'), a.i32(5)))
    return head


SEQUENCE_BITSETS = ('rot_matters', 'trans_matters', 'scale_matters', 'decal_matters', 'ifl_matters',
                    'vis_matters', 'frame_matters', 'matframe_matters')
# TSShape::Sequence flags (tsShape.h): Blend BIT(3), Cyclic BIT(4), MakePath BIT(5)
SEQUENCE_FLAG_BLEND, SEQUENCE_FLAG_CYCLIC, SEQUENCE_FLAG_MAKE_PATH = 0x8, 0x10, 0x20


def read_sequence(data, r, ver, name_index=True):
    """One TSShape::Sequence (plain stream).  Before v22 there is no flags word: three bytes (blend,
    cyclic, makePath) follow the duration, one 'base state' replaces the base rotation / translation
    pair, there is no base scale, and one bitset covers rotations and translations.  A .dsq writes the
    name as a string before the sequence instead of the name index (`name_index` False: 'name' is -1)."""
    name = -1
    if name_index:
        name, = struct.unpack_from('<i', data, r)
        r += 4
    if ver >= 22:
        f = struct.unpack_from('<Iifiii5iiif', data, r)
        r += struct.calcsize('<Iifiii5iiif')
        sq = dict(zip(('flags', 'num_keyframes', 'duration', 'priority', 'first_ground', 'num_ground',
                       'base_rotation', 'base_translation', 'base_scale', 'base_object_state', 'base_decal_state',
                       'first_trigger', 'num_triggers', 'tool_begin'), f))
        keys = SEQUENCE_BITSETS
    else:
        num_keys, duration = struct.unpack_from('<if', data, r)
        blend, cyclic, make_path = data[r + 8:r + 11]
        f = struct.unpack_from('<iii3iiif', data, r + 11)
        r += 11 + struct.calcsize("<iii3iiif")
        flags = (SEQUENCE_FLAG_BLEND if blend else 0) | (SEQUENCE_FLAG_CYCLIC if cyclic else 0) | (
            SEQUENCE_FLAG_MAKE_PATH if make_path else 0)
        sq = {'flags': flags, 'num_keyframes': num_keys, 'duration': duration}
        sq.update(zip(('priority', 'first_ground', 'num_ground', 'base_rotation', 'base_object_state',
                       'base_decal_state', 'first_trigger', 'num_triggers', 'tool_begin'), f))
        sq['base_translation'], sq['base_scale'] = sq['base_rotation'], 0
        keys = tuple(k for k in SEQUENCE_BITSETS if k not in ('trans_matters', 'scale_matters'))
    sq['name'] = name
    for key in keys:
        sq[key], r = read_bitset(data, r)
    sq.setdefault('trans_matters', sq['rot_matters'])
    sq.setdefault('scale_matters', [])
    return sq, r


def read_sequences(data, r, ver):
    nseq, = struct.unpack_from('<i', data, r)
    r += 4
    seqs = []
    for _ in range(nseq):
        sq, r = read_sequence(data, r, ver)
        seqs.append(sq)
    return seqs, r


def read_dsq(data):
    """A .dsq external sequence file (TSShape::importSequences, version 22 on the Tribes 2 disc; all 301
    armour files consume exactly):
      u32 version, i32 numNodes, node names (i32 length + chars; matched to the shape's nodes by name),
      i32 0 (legacy object count), i32 (unused),
      i32 n + n x 4xi16 rotations, i32 n + n x 3xf32 translations, uniform / aligned / arbitrary scale counts
      (0 here: f32 / 3xf32 / 3xf32 + 4xi16 each),
      i32 n + n x 3xf32 ground translations + n x 4xi16 ground rotations, i32 n + n x (f32, i32, i32) object
      states, i32 numSequences + per sequence (i32 length + name, TSShape::Sequence without name index),
      i32 n + n x (u32 state, f32 pos) triggers.
    Sequence bitsets index the file's own node list; base indices its own arrays."""
    p = 0

    def ints(n):
        nonlocal p
        v = struct.unpack_from('<%di' % n, data, p)
        p += 4 * n
        return v

    def string():
        nonlocal p
        n, = ints(1)
        p += n
        return data[p - n:p].decode('latin1')

    ver = ints(1)[0] & 0xFF
    names = [string() for _ in range(ints(1)[0])]
    ints(2)
    n, = ints(1)
    rots = [tuple(v / 32767.0 for v in struct.unpack_from('<4h', data, p + 8 * i)) for i in range(n)]
    p += 8 * n
    n, = ints(1)
    trans = [struct.unpack_from('<3f', data, p + 12 * i) for i in range(n)]
    p += 12 * n
    for size in (4, 12, 20):
        n, = ints(1)
        p += size * n
    n, = ints(1)
    ground_t = [struct.unpack_from('<3f', data, p + 12 * i) for i in range(n)]
    p += 12 * n
    ground_r = [tuple(v / 32767.0 for v in struct.unpack_from('<4h', data, p + 8 * i)) for i in range(n)]
    p += 8 * n
    n, = ints(1)
    p += 12 * n
    seqs = []
    for _ in range(ints(1)[0]):
        name = string()
        sq, p = read_sequence(data, p, ver, name_index=False)
        sq['name'] = name
        seqs.append(sq)
    n, = ints(1)
    triggers = [struct.unpack_from('<If', data, p + 8 * i) for i in range(n)]
    p += 8 * n
    return {'version': ver, 'nodes': names, 'node_rotations': rots, 'node_translations': trans,
            'ground_translations': ground_t, 'ground_rotations': ground_r, 'sequences': seqs,
            'triggers': triggers, 'unconsumed': len(data) - p}


def read_material_list(data, r, ver):
    """TSMaterialList: u8 version, count, names (u8 length + chars), then per-material arrays: flags,
    reflectance, bump and detail map indices, detail scale; the reflection amount only from v21 on (v19
    files end exactly after the detail scales)."""
    mver = data[r]
    nmat, = struct.unpack_from('<i', data, r + 1)
    r += 5
    mats = []
    for _ in range(nmat):
        n = data[r]
        mats.append({'name': data[r + 1:r + 1 + n].decode('latin1'), 'detail_scale': 1.0, 'reflection': 1.0})
        r += 1 + n
    arrays = [('flags', 'I'), ('reflectance', 'i'), ('bump', 'i'), ('detail', 'i'), ('detail_scale', 'f')]
    if ver > 20:
        arrays.append(('reflection', 'f'))
    for key, fmt in arrays:
        vals = struct.unpack_from('<%d%s' % (nmat, fmt), data, r)
        r += 4 * nmat
        for mm, v in zip(mats, vals):
            mm[key] = v
    return mats, mver, r


class PlainStream:
    """Sequential little-endian reader over the plain (pre-v19) shape stream."""

    def __init__(self, data, pos):
        self.d = data
        self.p = pos

    def i32(self, n=None):
        k = 1 if n is None else n
        v = struct.unpack_from('<%di' % k, self.d, self.p)
        self.p += 4 * k
        return v[0] if n is None else list(v)

    def f32(self, n):
        v = struct.unpack_from('<%df' % n, self.d, self.p)
        self.p += 4 * n
        return list(v)

    def i16(self, n):
        v = struct.unpack_from('<%dh' % n, self.d, self.p)
        self.p += 2 * n
        return list(v)

    def counted_i32(self, width=1):
        n = self.i32()
        return [self.i32(width) for _ in range(n)]


def read_old_mesh(r, mtype):
    """Pre-v19 TSMesh: no parent mesh, bounds or encoded normals; prims are interleaved
    (i16 start, i16 count, u32 material word); 16-bit indices are not padded."""
    m = {'type': mtype, 'parent': -1}
    if mtype == 4:
        return m
    if mtype != 0:
        raise NotImplementedError('pre-v19 mesh type %d' % mtype)
    m['num_frames'], m['num_mat_frames'] = r.i32(), r.i32()
    m['verts'] = r.f32(3 * r.i32())
    m['tverts'] = r.f32(2 * r.i32())
    m['norms'] = r.f32(3 * r.i32())
    prims = []
    for _ in range(r.i32()):
        start, count = r.i16(2)
        prims.append((start, count, r.i32() & 0xFFFFFFFF))
    m['prims'] = prims
    m['indices'] = [x & 0xFFFF for x in r.i16(r.i32())]
    m['verts_per_frame'], m['flags'] = r.i32(), r.i32()
    set_mesh_bounds(m)
    return m


def set_mesh_bounds(m):
    """Old meshes store no bounds; derive them (all frames) as the later versions store them."""
    v = m['verts'] or [0.0, 0.0, 0.0]
    lo = [min(v[a::3]) for a in range(3)]
    hi = [max(v[a::3]) for a in range(3)]
    m['bounds'] = lo + hi
    m['center'] = [(lo[a] + hi[a]) / 2 for a in range(3)]
    m['radius'] = math.sqrt(sum((hi[a] - lo[a]) ** 2 for a in range(3))) / 2


def read_old_names(r):
    names = []
    for _ in range(r.i32()):
        n = r.i32()
        names.append(r.d[r.p:r.p + n].decode('latin1'))
        r.p += n
    return names


def read_old_node_states(r):
    rots, trans = [], []
    for _ in range(r.i32()):
        rots.append(tuple(v / 32767.0 for v in r.i16(4)))
        trans.append(tuple(r.f32(3)))
    return rots, trans


def read_old_shape(data):
    """Pre-v19 shapes (Tribes 2 ships v15/16/18: grenade_projectile, mortar_projectile, plasmabolt,
    disc_explosion, octahedron, chaingun_shot, borg3).  One plain stream instead of the three interleaved
    buffers, every array preceded by its own count, verified byte-exact on the disc's files:

      version | radius, tubeRadius, center 3f, bounds 6f | nodes (name, parent) | objects (name, numMeshes,
      startMesh, node) | decals | ifls (name, materialSlot) | subShapeFirstNode, FirstObject, FirstDecal
      (each counted) | node states (i16 quat + 3f translation; the first numNodes are the default pose,
      sequences index the whole array) | object states (f vis, frame, matFrame) | decal states | triggers
      (2 words) | details (name, subShape, objectDetail, f size) | sequences (v<22 layout) | meshes (type +
      read_old_mesh) | names (i32 length + chars) | i32 1, material list (v19 layout) | i32 0.
    """
    ver = data[0]
    r = PlainStream(data, 4)
    s = {'version': ver, 'exporter': struct.unpack_from('<I', data, 0)[0] >> 16}
    s['radius'], s['tube_radius'] = r.f32(2)
    s['center'], s['bounds'] = r.f32(3), r.f32(6)
    s['nodes'] = [dict(zip(('name', 'parent'), v)) for v in r.counted_i32(2)]
    s['objects'] = [dict(zip(('name', 'num_meshes', 'start_mesh', 'node'), v)) for v in r.counted_i32(4)]
    if r.i32():
        raise NotImplementedError('pre-v19 decals')
    s['ifls'] = r.counted_i32(2)
    first_node, first_object, _first_decal = [[v[0] for v in r.counted_i32()] for _ in range(3)]
    rots, trans = read_old_node_states(r)
    nn = len(s['nodes'])
    s['default_rotations'], s['default_translations'] = rots[:nn], trans[:nn]
    s['node_rotations'], s['node_translations'] = rots[nn:], trans[nn:]
    s['object_states'] = [(r.f32(1)[0], r.i32(), r.i32()) for _ in range(r.i32())]
    if r.i32():
        raise NotImplementedError('pre-v19 decal states')
    r.i32(2 * r.i32())
    s['details'] = []
    for _ in range(r.i32()):
        name, subshape, object_detail = r.i32(3)
        s['details'].append({'name': name, 'subshape': subshape, 'object_detail': object_detail,
                             'size': r.f32(1)[0], 'avg_error': 0.0, 'max_error': 0.0, 'poly_count': 0})
    s['sequences'], r.p = read_sequences(data, r.p, ver)
    s['meshes'] = [read_old_mesh(r, r.i32()) for _ in range(r.i32())]
    s['names'] = read_old_names(r)
    s['skins'] = []
    set_subshape_ranges(s, first_node, first_object)
    if r.i32():
        s['materials'], s['material_list_version'], r.p = read_material_list(data, r.p, ver)
    else:
        s['materials'], s['material_list_version'] = [], 0
    r.i32()
    s['unconsumed'] = len(data) - r.p
    s['counts'] = {'nodes': nn, 'objects': len(s['objects']), 'subshapes': len(first_node), 'ifls': len(s['ifls']),
                   'node_rots': len(s['node_rotations']), 'object_states': len(s['object_states']),
                   'details': len(s['details']), 'meshes': len(s['meshes']), 'names': len(s['names'])}
    return s


def set_subshape_ranges(s, first_node, first_object):
    """Old shapes store only the first node / object of each subshape; the counts run to the next one."""
    def spans(firsts, total):
        return [(firsts[i + 1] if i + 1 < len(firsts) else total) - f for i, f in enumerate(firsts)]
    s['subshape_first_node'], s['subshape_first_object'] = first_node, first_object
    s['subshape_num_nodes'] = spans(first_node, len(s['nodes']))
    s['subshape_num_objects'] = spans(first_object, len(s['objects']))


def read_shape(data):
    ver_full, = struct.unpack_from('<I', data, 0)
    ver = ver_full & 0xFF
    if ver < 18:
        raise NotImplementedError('DTS version %d (pre-18 layout: per-node flag byte, other node states)' % ver)
    if ver < 19:
        return normalise_old_sequences(read_old_shape(data))
    size, s16, s8 = struct.unpack_from('<3i', data, 4)
    buf = data[16:16 + 4 * size]
    a = Alloc(buf, s16, s8)
    c = read_counts(a, ver)
    c['skins'] = a.i32() if ver < 23 else 0
    c['names'] = a.i32()
    s = {'version': ver, 'exporter': ver_full >> 16, 'counts': c}
    s['smallest_size'], s['smallest_dl'] = a.i32(), a.i32()
    a.guard('counts')
    s['radius'], s['tube_radius'] = a.f32(2)
    s['center'] = a.f32(3)
    s['bounds'] = a.f32(6)
    a.guard('bounds')
    s['nodes'] = [dict(zip(('name', 'parent', 'first_object', 'first_child', 'next_sibling'), a.i32(5)))
                  for _ in range(c['nodes'])]
    a.guard('nodes')
    s['objects'] = [dict(zip(('name', 'num_meshes', 'start_mesh', 'node', 'next_sibling', 'first_decal'), a.i32(6)))
                    for _ in range(c['objects'])]
    a.guard('objects')
    a.i32(5 * c['decals'])
    a.guard('decals')
    s['ifls'] = [a.i32(5) for _ in range(c['ifls'])]
    a.guard('ifls')
    s['subshape_first_node'] = a.i32(c['subshapes'])
    s['subshape_first_object'] = a.i32(c['subshapes'])
    a.i32(c['subshapes'])
    a.guard('subshapes')
    s['subshape_num_nodes'] = a.i32(c['subshapes'])
    s['subshape_num_objects'] = a.i32(c['subshapes'])
    a.i32(c['subshapes'])
    a.guard('subshape counts')
    q = a.i16(4 * c['nodes'])
    s['default_rotations'] = [tuple(v / 32767.0 for v in q[4 * i:4 * i + 4]) for i in range(c['nodes'])]
    t = a.f32(3 * c['nodes'])
    s['default_translations'] = [tuple(t[3 * i:3 * i + 3]) for i in range(c['nodes'])]
    t = a.f32(3 * c['node_trans'])
    s['node_translations'] = [tuple(t[3 * i:3 * i + 3]) for i in range(c['node_trans'])]
    q = a.i16(4 * c['node_rots'])
    s['node_rotations'] = [tuple(v / 32767.0 for v in q[4 * i:4 * i + 4]) for i in range(c['node_rots'])]
    a.align32()
    a.guard('node transforms')
    if ver > 21:
        a.f32(c['uscales'])
        a.f32(3 * c['ascales'])
        a.f32(3 * c['arbscales'])
        a.i16(4 * c['arbscales'])
        a.align32()
        a.guard('scales')
    if ver > 23:
        a.f32(3 * c['ground'])
        a.i16(4 * c['ground'])
        a.align32()
        a.guard('ground')
    os_ = a.i32(3 * c['object_states'])
    s['object_states'] = [(struct.unpack('<f', struct.pack('<i', os_[3 * i]))[0], os_[3 * i + 1], os_[3 * i + 2])
                          for i in range(c['object_states'])]
    a.guard('object states')
    a.i32(c['decal_states'])
    a.guard('decal states')
    a.i32(2 * c['triggers'])
    a.guard('triggers')
    s['details'] = []
    for _ in range(c['details']):
        raw = a.i32(7)
        f = struct.unpack('<3f', struct.pack('<3i', *raw[3:6]))
        s['details'].append({'name': raw[0], 'subshape': raw[1], 'object_detail': raw[2], 'size': f[0],
                             'avg_error': f[1], 'max_error': f[2], 'poly_count': raw[6]})
        if ver >= 26:
            a.i32(6)
    a.guard('details')
    store = []
    s['meshes'] = []
    for i in range(c['meshes']):
        mtype = a.i32()
        m = read_mesh(a, mtype, ver, store)
        store.append(m)
        s['meshes'].append(m)
    a.guard('meshes')
    names = []
    p = a.p8
    for _ in range(c['names']):
        e = buf.index(b'\0', p)
        names.append(buf[p:e].decode('latin1'))
        p = e + 1
    a.p8 = p
    a.align32()
    a.guard('names')
    s['names'] = names
    s['skins'] = []
    if ver < 23 and c['skins']:
        first = a.i32(c['details'])
        num = a.i32(c['details'])
        a.guard('skin details')
        for i in range(c['skins']):
            m = read_mesh(a, 1, ver, store)
            store.append(m)
            s['skins'].append(m)
        a.guard('skins')
        s['detail_first_skin'], s['detail_num_skins'] = first, num

    r = 16 + 4 * size
    s['sequences'], r = read_sequences(data, r, ver)
    s['materials'], s['material_list_version'], r = read_material_list(data, r, ver)
    s['unconsumed'] = len(data) - r
    return normalise_old_sequences(s) if ver < 22 else s


def normalise_old_sequences(s):
    """Before v22 the node-state array starts with the default pose, and sequence base indices count
    from its start; the readers keep the default pose apart, so shift the bases past it."""
    nn = len(s['nodes'])
    for sq in s['sequences']:
        sq['base_rotation'] = max(sq['base_rotation'] - nn, 0)
        sq['base_translation'] = max(sq['base_translation'] - nn, 0)
    return s


# ------------------------------------------------------------------ geometry helpers

def quat_to_mat(q):
    """Torque stores quaternions conjugated relative to the usual convention (same as Darkstar):
    the matrix is the transpose of the standard one.  Verified visually on vehicle_grav_scout."""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    m = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[m[j][i] for j in range(3)] for i in range(3)]


def world_matrices(s, rots=None, trans=None):
    rots = rots or s['default_rotations']
    trans = trans or s['default_translations']
    cache = {}

    def get(i):
        if i in cache:
            return cache[i]
        R_, T = quat_to_mat(rots[i]), trans[i]
        par = s['nodes'][i]['parent']
        if par >= 0:
            PR, PT = get(par)
            R2 = [[sum(PR[a][k] * R_[k][b] for k in range(3)) for b in range(3)] for a in range(3)]
            T2 = [PT[a] + sum(PR[a][k] * T[k] for k in range(3)) for a in range(3)]
            cache[i] = (R2, T2)
        else:
            cache[i] = (R_, list(T))
        return cache[i]

    for i in range(len(s['nodes'])):
        get(i)
    return cache


def mesh_triangles(m, frame=0):
    """[(i0, i1, i2, material)] with strips/fans unrolled; material -1 = none."""
    idx = m['indices']
    off = frame * (m.get('verts_per_frame') or 0) if m.get('num_frames', 1) > 1 else 0
    out = []
    for start, n, mat in m['prims']:
        kind = (mat >> 30) & 3
        mi = -1 if mat & 0x10000000 else mat & 0x0FFFFFFF
        seg = [idx[start + k] + off for k in range(n)]
        if kind == 0:
            for k in range(0, n - 2, 3):
                out.append((seg[k], seg[k + 1], seg[k + 2], mi))
        elif kind == 1:
            for k in range(n - 2):
                a_, b_, c_ = seg[k], seg[k + 1], seg[k + 2]
                if k & 1:
                    a_, b_ = b_, a_
                if a_ != b_ and b_ != c_ and a_ != c_:
                    out.append((a_, b_, c_, mi))
        else:
            for k in range(1, n - 1):
                out.append((seg[0], seg[k], seg[k + 1], mi))
    return out


if __name__ == '__main__':
    import glob, collections
    files = sys.argv[1:]
    stat = collections.Counter()
    for f in files:
        try:
            s = read_shape(open(f, 'rb').read())
            stat['ok v%d' % s['version']] += 1
            if len(files) < 5:
                print(f, 'v%d' % s['version'], {k: v for k, v in s['counts'].items() if v},
                      'mesh types', collections.Counter(m['type'] for m in s['meshes']),
                      'unconsumed', s['unconsumed'])
                print('  details', [(s['names'][d['name']], d['subshape'], d['object_detail'], d['size']) for d in s['details']])
                print('  seqs', [s['names'][q['name']] for q in s['sequences']])
                print('  mats', [m['name'] for m in s['materials']])
        except Exception as e:
            stat['fail %s' % type(e).__name__] += 1
            print('FAIL', f, repr(e)[:120])
    print(dict(stat))
