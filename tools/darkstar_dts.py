"""Darkstar (3Space v3: Starsiege, Starsiege: Tribes) DTS shape reader.

Structures follow open-siege/siege-studio darkstar_structures.hpp (MIT). Every object is a
"PERS" persistent block:  "PERS" u32 size, u16 nameLen, name (+1 NUL pad when nameLen < 16),
u32 version, body.  TS::Shape v2..v8, TS::CelAnimMesh v1..v3, TS::MaterialList v2..v4.

Tribes 1.x shapes are TS::Shape v8 with v3 meshes and v3/v4 material lists; all structures are
packed except the v8 object record (2 pad bytes after the int16 node index: 28 bytes) --
verified by consuming every Tribes DTS exactly.

Geometry: vertex = frame.origin + (u8 x,y,z) * frame.scale (mesh v3: per frame; v1/v2: header),
in the space of the object's node.  Node local transform = transforms[node.default]:
v8 = (int16 quaternion x,y,z,w / 32767, float translation); the quaternion is applied
conjugated (siege-studio: transpose(toMat4(q))).  Faces are triangles (vi, ti) x3 + material.
Units: 1 unit = 1 metre (see docs/formats/tribes.md).
"""
import math, struct, sys


class R:
    def __init__(self, d, p=0):
        self.d, self.p = d, p

    def take(self, fmt):
        v = struct.unpack_from('<' + fmt, self.d, self.p)
        self.p += struct.calcsize('<' + fmt)
        return v

    def arr(self, fmt, n):
        sz = struct.calcsize('<' + fmt)
        out = [struct.unpack_from('<' + fmt, self.d, self.p + i * sz) for i in range(n)]
        self.p += sz * n
        return out


def read_header(r):
    tag, size, nlen = r.take('4sIh')
    if tag != b'PERS':
        raise ValueError('expected PERS at %d, got %r' % (r.p - 10, tag))
    start = r.p - 2  # size counts from after the size field
    name = r.d[r.p:r.p + nlen].decode('latin1')
    r.p += nlen + (1 if nlen < 16 else 0)
    ver, = r.take('I')
    return name, ver, start + size


def read_mesh(r):
    name, ver, end = read_header(r)
    assert name == 'TS::CelAnimMesh', name
    m = {'version': ver}
    if ver == 1:
        nv, vpf, ntv, nf, nfr = r.take('5i'); sc = r.take('3f'); org = r.take('3f'); rad, = r.take('f')
        tvpf = ntv
    elif ver == 2:
        nv, vpf, ntv, nf, nfr, tvpf = r.take('6i'); sc = r.take('3f'); org = r.take('3f'); rad, = r.take('f')
    else:
        nv, vpf, ntv, nf, nfr, tvpf, rad = r.take('6if')
        sc = org = None
    m.update(verts_per_frame=vpf, tverts_per_frame=tvpf, radius=rad)
    m['verts'] = r.arr('4B', nv)
    m['tverts'] = r.arr('2f', ntv)
    m['faces'] = r.arr('7i', nf)  # vi1,ti1,vi2,ti2,vi3,ti3,material
    if ver < 3:
        m['frames'] = [{'first': f[0], 'scale': sc, 'origin': org} for f in r.arr('i', nfr)]
    else:
        m['frames'] = [{'first': f[0], 'scale': f[1:4], 'origin': f[4:7]} for f in r.arr('i6f', nfr)]
    if r.p != end:
        raise ValueError('mesh size mismatch %d != %d' % (r.p, end))
    return m


def read_material_list(r, ver):
    nd, nm = r.take('2i')
    fmt = {2: 'ifi4B32s', 3: 'ifi4B32siff', 4: 'ifi4B32siffI'}[ver]
    mats = []
    for t in r.arr(fmt, nd * nm):
        mats.append({'flags': t[0], 'alpha': t[1], 'index': t[2], 'rgb': list(t[3:6]), 'rgb_flags': t[6],
                     'file': t[7].split(b'\0')[0].decode('latin1'), 'type': t[8] if len(t) > 8 else None})
    return {'details': nd, 'count': nm, 'materials': mats}


def read_shape(data):
    r = R(data)
    name, ver, end = read_header(r)
    if name == 'TS::MaterialList':
        return {'material_list': read_material_list(r, ver)}
    assert name == 'TS::Shape', name
    if ver < 5:
        h = r.take('10i') + (0,)
    else:
        h = r.take('11i')
    (n_nodes, n_seq, n_sub, n_kf, n_tf, n_names, n_obj, n_det, n_mesh, n_trans, n_trig) = h
    s = {'version': ver}
    if ver >= 8:
        d = r.take('10f'); s['radius'], s['center'], s['bounds'] = d[0], d[1:4], (d[4:7], d[7:10])
        s['nodes'] = [dict(zip(('name', 'parent', 'nsub', 'firstsub', 'default'), t)) for t in r.arr('5h', n_nodes)]
    else:
        d = r.take('4f'); s['radius'], s['center'], s['bounds'] = d[0], d[1:4], None
        s['nodes'] = [dict(zip(('name', 'parent', 'nsub', 'firstsub', 'default'), t)) for t in r.arr('5i', n_nodes)]
    if ver >= 5:
        s['sequences'] = [dict(zip(('name', 'cyclic', 'duration', 'priority', 'first_trigger', 'n_triggers',
                                    'n_ifl', 'first_ifl'), t)) for t in r.arr('iifi4i', n_seq)]
    else:
        s['sequences'] = [dict(zip(('name', 'cyclic', 'duration', 'priority'), t)) for t in r.arr('iifi', n_seq)]
    s['subsequences'] = [dict(zip(('seq', 'nkf', 'firstkf'), t)) for t in r.arr('3h' if ver >= 8 else '3i', n_sub)]
    if ver >= 8:
        s['keyframes'] = [dict(zip(('pos', 'tf', 'mat'), t)) for t in r.arr('f2H', n_kf)]
    elif ver >= 3:
        s['keyframes'] = [dict(zip(('pos', 'tf', 'mat'), t)) for t in r.arr('f2I', n_kf)]
    else:
        s['keyframes'] = [dict(zip(('pos', 'tf'), t)) for t in r.arr('fI', n_kf)]
    if ver >= 8:
        s['transforms'] = [{'q': tuple(c / 32767.0 for c in t[:4]), 't': t[4:7], 's': (1, 1, 1)} for t in r.arr('4h3f', n_tf)]
    elif ver == 7:
        s['transforms'] = [{'q': tuple(c / 32767.0 for c in t[:4]), 't': t[4:7], 's': t[7:10]} for t in r.arr('4h6f', n_tf)]
    else:
        s['transforms'] = [{'q': t[:4], 't': t[4:7], 's': t[7:10]} for t in r.arr('10f', n_tf)]
    s['names'] = [t[0].split(b'\0')[0].decode('latin1') for t in r.arr('24s', n_names)]
    if ver >= 8:
        s['objects'] = [dict(zip(('name', 'flags', 'mesh', 'node', 'ox', 'oy', 'oz', 'nsub', 'firstsub'), t))
                        for t in r.arr('hhih2x3fhh', n_obj)]
    else:
        s['objects'] = [dict(zip(('name', 'flags', 'mesh', 'node', 'dep_flags'), t[:5]), ox=t[14], oy=t[15], oz=t[16],
                             nsub=t[17], firstsub=t[18]) for t in r.arr('hhiii9f3fii', n_obj)]
    s['details'] = [dict(zip(('root', 'size'), t)) for t in r.arr('if', n_det)]
    tsz = {8: 'iifff4h3f', 7: 'iifff4h6f'}.get(ver, 'iifff10f')
    s['transitions'] = r.arr(tsz, n_trans)
    if ver >= 5:
        s['triggers'] = r.arr('2f', n_trig)
        s['default_materials'], = r.take('i')
        if ver >= 6:
            s['always_node'], = r.take('i')
    s['meshes'] = [read_mesh(r) for _ in range(n_mesh)]
    has_ml, = r.take('i')
    s['material_list'] = None
    if has_ml:
        mname, mver, mend = read_header(r)
        s['material_list'] = read_material_list(r, mver)
    s['unconsumed'] = end - r.p
    return s


# ---------------------------------------------------------------- geometry helpers

def quat_to_mat(q):
    """Rotation matrix used by Darkstar for a stored quaternion (conjugate of the usual)."""
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    m = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
         [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
         [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
    return [[m[j][i] for j in range(3)] for i in range(3)]  # transpose


def mesh_frame_verts(mesh, frame=0):
    fr = mesh['frames'][frame] if mesh['frames'] else {'first': 0, 'scale': (1, 1, 1), 'origin': (0, 0, 0)}
    vpf = mesh['verts_per_frame'] or len(mesh['verts'])
    sc, org = fr['scale'], fr['origin']
    return [(org[0] + v[0] * sc[0], org[1] + v[1] * sc[1], org[2] + v[2] * sc[2])
            for v in mesh['verts'][fr['first']:fr['first'] + vpf]]


def detail_nodes(s, detail=0):
    """Nodes reachable from a detail level's root (breadth first)."""
    root = s['details'][detail]['root']
    out, todo = [], [root]
    while todo:
        n = todo.pop(0)
        out.append(n)
        todo += [i for i, nd in enumerate(s['nodes']) if nd['parent'] == n and i not in out]
    return out


def world_matrices(s):
    """Default-pose node->shape 3x4 matrices (rotation, translation)."""
    cache = {}

    def get(i):
        if i in cache:
            return cache[i]
        nd = s['nodes'][i]
        t = s['transforms'][nd['default']]
        R_, T = quat_to_mat(t['q']), t['t']
        if nd['parent'] >= 0:
            PR, PT = get(nd['parent'])
            R2 = [[sum(PR[a][k] * R_[k][b] for k in range(3)) for b in range(3)] for a in range(3)]
            T2 = [PT[a] + sum(PR[a][k] * T[k] for k in range(3)) for a in range(3)]
            cache[i] = (R2, T2)
        else:
            cache[i] = (R_, list(T))
        return cache[i]

    for i in range(len(s['nodes'])):
        get(i)
    return cache


if __name__ == '__main__':
    for f in sys.argv[1:]:
        s = read_shape(open(f, 'rb').read())
        if 'nodes' not in s:
            print(f, 'material list', s['material_list']['count'])
            continue
        print('%s v%d nodes=%d seq=%d obj=%d det=%d mesh=%d r=%.3f bounds=%s unconsumed=%d' % (
            f, s['version'], len(s['nodes']), len(s['sequences']), len(s['objects']), len(s['details']),
            len(s['meshes']), s['radius'], s['bounds'], s['unconsumed']))
