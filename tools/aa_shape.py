"""Aerial Assault .SHP shapes (static meshes), decoded from the PS2 VIF packet streams they carry.

The file is a serialised object dump (names, texture paths, "Material?#n" records) with the model data stored as PS2
VIF1 packets: per batch of up to 63 vertices
    UNPACK V2-16 at address 1   texture coordinates, 4.12 fixed point (u / 4096, v / 4096)
    UNPACK V3-8  at address 3   normals, signed bytes
    UNPACK V4-16 at address 4   positions: int16 x, y, z (value / scale) and a control word:
                                bit 15 (0x8000) strip restart (the vertex starts a strip and draws nothing), bit 14 (0x4000)
                                winding hint, alternating along a strip
    UNPACK V4-16 1 vector at 0x11   per-batch constants
Positions are the shape's own axes (Y up, the world's axes: X north, Z east, see aa_terrain.py) divided by the scale
float stored in the object header (32767 / the largest coordinate of the bounding box).
A "Material?#n" record holds a colour (4 floats), then (flags, 1, base texture index, lum texture index) into the
shape's list of texture paths; the batches that follow a material record use it.
"""
import re
import struct

import numpy as np

VN = {0: 1, 1: 2, 2: 3, 3: 4}
VL = {0: 32, 1: 16, 2: 8, 3: 5}
SIMPLE = (0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x13, 0x14, 0x15, 0x17)
TEX_RE = re.compile(rb'[A-Za-z0-9_\-\.\[\]]+\.(?:png|bmp|tga)', re.I)


def walk(d, pos):
    """VIF commands from `pos` -> ([(kind, ...)], end). Stops at the first word that is not a known command."""
    out = []
    n = len(d)
    while pos + 4 <= n:
        w = struct.unpack_from('<I', d, pos)[0]
        cmd, num, imm = w >> 24, (w >> 16) & 0xFF, w & 0xFFFF
        if cmd in SIMPLE:
            out.append(('c', cmd, num, imm))
            pos += 4
        elif cmd == 0x20:
            pos += 8
        elif cmd & 0x60 == 0x60:
            vn, vl = (cmd >> 2) & 3, cmd & 3
            if vl == 3:
                return out, pos
            nb = (VL[vl] * VN[vn] * (num or 256) + 7) // 8
            nb = (nb + 3) & ~3
            if pos + 4 + nb > n:
                return out, pos
            out.append(('u', 'V%d-%d' % (VN[vn], VL[vl]), num, imm & 0x3FFF, d[pos + 4:pos + 4 + nb]))
            pos += 4 + nb
        else:
            return out, pos
    return out, pos


def _batches(d):
    """[(offset, [vertex dict ...])] for every UV + normal + position unpack triple."""
    out = []
    i = 0x40
    while i + 4 <= len(d):
        w = struct.unpack_from('<I', d, i)[0]
        if (w >> 24) == 0x65 and (w & 0x3FFF) == 1 and ((w >> 16) & 0xFF) >= 3:
            cmds, end = walk(d, i)
            ups = [c for c in cmds if c[0] == 'u']
            k = 0
            while k + 2 < len(ups):
                a, b, c = ups[k], ups[k + 1], ups[k + 2]
                if (a[1], b[1], c[1]) == ('V2-16', 'V3-8', 'V4-16') and a[2] == b[2] == c[2] and c[3] == 4:
                    n = a[2]
                    uv = np.frombuffer(a[4], '<u2', n * 2).reshape(n, 2)
                    nrm = np.frombuffer(b[4], 'i1', n * 3 + 0).reshape(n, 3) if len(b[4]) >= n * 3 else None
                    pos = np.frombuffer(c[4], '<i2', n * 4).reshape(n, 4)
                    out.append((i, uv, nrm, pos))
                    k += 3
                else:
                    k += 1
            i = max(end, i + 4)
            continue
        i += 4
    return out


def _textures(d, keep_dups=False):
    """(names in order of first appearance, offset where the list is repeated or len(d)): a shape that stores a second
    copy (its damaged state) repeats the texture list; only the first state is used."""
    names, repeat = [], len(d)
    for m in TEX_RE.finditer(d):
        t = m.group().decode('latin-1')
        if t in names:
            if t == names[0]:
                repeat = m.start()
                break
            if not keep_dups:
                continue
        names.append(t)                    # keep_dups: a texture listed twice keeps both slots (the transport's indices count them)
    return names, repeat


DULL = ('alpha', 'lit', 'hilite', 'chromic', 'side', 'lum_', 'glow')


def primary_texture(textures):
    """Index of the texture a mesh without a readable material uses: the first that is not a mask / light / highlight."""
    for k, t in enumerate(textures):
        if not any(w in t.lower() for w in DULL):
            return k
    return 0 if textures else -1


def _materials(d, loose=False):
    """[(offset, name, (r, g, b, a), base index, lum index)]: records are recognised by their layout - four colour floats
    ending in 1.0, a word whose low byte is 0x0c, the count 1, then the base and the lum texture indices."""
    mats = []
    n = len(d)
    for p in range(0x60, n - 32, 4):
        if struct.unpack_from('<I', d, p + 12)[0] != 0x3F800000:
            continue
        r, g, b = struct.unpack_from('<3f', d, p)
        if not (0.0 <= r <= 1.0 and 0.0 <= g <= 1.0 and 0.0 <= b <= 1.0):
            continue
        flags, cnt, base, lum, neg = struct.unpack_from('<5I', d, p + 16)
        if (flags & 0xFF) != 0x0C or base > 63:
            continue
        if cnt != 1 or lum > 63 or neg != 0xFFFFFFFF:
            if not (loose and lum == 0xFFFFFFFF):        # loose: records with no lum texture (-1), any count (the transport)
                continue
        lum = -1 if lum == 0xFFFFFFFF else lum
        mats.append((p, 'material%d' % len(mats), (r, g, b, 1.0), base, lum))
    return mats


def _scale(d):
    """Position scale: the float after the (1.0, 0) pair ((1.0, 1) in shapes with moving parts or skins) of the object header; else from the bounding box."""
    for p in range(0x60, min(len(d) - 12, 0x200), 4):
        a, b, c = struct.unpack_from('<IIf', d, p)
        if a == 0x3F800000 and b in (0, 1) and 100.0 < c < 1e6:
            return c
    return None


def _scale_at(d):
    """Offset of the scale float found by _scale (None when it is not stored)."""
    for p in range(0x60, min(len(d) - 12, 0x200), 4):
        a, b, c = struct.unpack_from('<IIf', d, p)
        if a == 0x3F800000 and b in (0, 1) and 100.0 < c < 1e6:
            return p + 8
    return None


def node_boxes(d):
    """[(parent, (min x, y, z, max x, y, z))] of the shape's nodes, read from the node table that follows the scale: a count
    24 bytes after the scale float, then 0x28-byte records (u32 0, i32 parent, u32 tag, six float box bounds, u32 0).
    Boxes of parts are in shape space; pivots/dummies have a +-0.01 box. [] when the table does not read."""
    at = _scale_at(d)
    if at is None or at + 0x28 > len(d):
        return []
    n = struct.unpack_from('<I', d, at + 0x28)[0]
    out = []
    if not 1 <= n <= 200 or at + 0x2C + 0x28 * n > len(d):
        return []
    for k in range(n):
        p = at + 0x2C + 0x28 * k
        z, parent, _tag = struct.unpack_from('<iiI', d, p)
        box = struct.unpack_from('<6f', d, p + 12)
        if z != 0 or not -1 <= parent < n or not all(abs(v) < 1e4 for v in box):
            return []
        out.append((parent, box))
    return out


def mirrored_nodes(boxes, tol=0.03):
    """Indices of nodes that are the stored point-inversion of an earlier node (centre-symmetric parts excluded): the exporter
    kept the left/right copy of a part as (-x, -y, -z) of the original, which the node transform undid."""
    out = set()
    for k, (_p, b) in enumerate(boxes):
        lo, hi = np.array(b[:3]), np.array(b[3:])
        if np.abs(lo + hi).max() < tol or np.abs(hi - lo).max() < 0.1:
            continue
        for j in range(k):
            jl, jh = np.array(boxes[j][1][:3]), np.array(boxes[j][1][3:])
            if np.allclose(jl, -hi, atol=tol) and np.allclose(jh, -lo, atol=tol):
                out.add(k)
                break
    return out


def lateral_axis(boxes):
    """Axis (0 X or 2 Z) a shape's left/right parts mirror across: X unless the main hull (the first node) is clearly
    off-centre in X and centred in Z (the scout flies along X and is mirrored in Z)."""
    if not boxes:
        return 0
    b = np.array(boxes[0][1])
    ext = np.maximum(b[3:] - b[:3], 1e-3)
    off = np.abs(b[:3] + b[3:]) / 2 / ext
    if off[0] <= 0.05:
        return 0
    return 2 if off[2] <= 0.05 else 0


def _quat_matrix(q):
    x, y, z, w = q
    n = (x * x + y * y + z * z + w * w) ** 0.5 or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _find_all(d, needle, start):
    """Offsets (any alignment) of `needle` in `d` from `start` on."""
    out, at = [], d.find(needle, start)
    while at >= 0:
        out.append(at)
        at = d.find(needle, at + 1)
    return out


def bones(d):
    """[(quaternion x y z w, translation)] of a skinned shape's bones (soldiers), local to the parent, in the node default pose.
    The record list follows the "<name>_root" string: ... fps (30.0, or 10.0 in the medium bioderm), 1, 0, count, then
    0x30-byte records (-0.0, 1.0, 1, quaternion, 1, translation, 0). [] when the shape has none."""
    try:
        p = d.index(b'_root', 0x1000)
    except ValueError:
        return []
    hits = sorted(h for fps in (10.0, 30.0) for h in _find_all(d, struct.pack('<f', fps), p))
    for q in hits:
        if q + 16 > len(d):
            break
        fps, one, zero, count = struct.unpack_from('<fIII', d, q)
        if one != 1 or zero != 0 or not 1 <= count <= 64 or q + 16 + 0x30 * count > len(d):
            continue
        if struct.unpack_from('<fII', d, q + 16)[1:] != (0x3F800000, 1):
            continue
        out = []
        for k in range(count):
            f = struct.unpack_from('<ffI4fI3fI', d, q + 16 + 0x30 * k)
            out.append((f[3:7], f[8:11]))
        return out
    return []


def batch_groups(d, first=0x40):
    """Index of the first VIF batch of every part: a part starts where the stream issues MSCAL 4 (0x14 with immediate 4)."""
    out, nb = [], -1
    i = first
    while i + 4 <= len(d):
        w = struct.unpack_from('<I', d, i)[0]
        if (w >> 24) == 0x65 and (w & 0x3FFF) == 1 and ((w >> 16) & 0xFF) >= 3:
            cmds, end = walk(d, i)
            for c in cmds:
                if c[0] == 'u' and c[1] == 'V2-16' and c[3] == 1:
                    nb += 1
                elif c[0] == 'c' and c[1] == 0x14 and c[3] == 4:
                    out.append(nb)
            i = max(end, i + 4)
            continue
        i += 4
    return out


SOLDIER_PARENTS = (-1, 0, 1, 2, 2, 4, 5, 2, 7, 8, 0, 10, 11, 0, 13, 14)     # pelvis, spine, head, two arms, two legs
# The bioderms' skeletons have another bone order (alien, hunched, reverse-jointed): light and medium (16 bones) = pelvis, spine,
# chest, head, two arms of two bones (hanging from the chest), two legs of four (hip, thigh, ankle, foot); heavy (15) = pelvis,
# three spine bones, head, two arms of two, two legs of three. The heavy shape has 14 parts for 15 bones: the part list skips the
# third bone (a pivot between belly and chest; the others skipped or not assemble the same, this keeps each part at the origin of the
# bone its children hang from).
BIODERM_PARENTS = (-1, 0, 1, 2, 2, 4, 2, 6, 0, 8, 9, 10, 0, 12, 13, 14)
HEAVY_BIODERM_PARENTS = (-1, 0, 1, 2, 3, 3, 5, 3, 7, 0, 9, 10, 0, 12, 13)
HEAVY_PART_BONES = (0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14)


def skeleton_of(d, count):
    """Parent table of the bones of shape bytes `d` with `count` bones (a bioderm is told by the name at the head of the file)."""
    name = d[8:d.index(b'\x00', 8)].lower()
    if name.startswith(b'bioderm'):
        return HEAVY_BIODERM_PARENTS if count == len(HEAVY_BIODERM_PARENTS) else BIODERM_PARENTS
    return SOLDIER_PARENTS


def part_bones(parents, parts):
    """Bone of every part, in part order: bone order, except the heavy bioderm (one part fewer than bones)."""
    if parts == len(parents):
        return list(range(parts))
    if parents == HEAVY_BIODERM_PARENTS and parts == len(HEAVY_PART_BONES):
        return list(HEAVY_PART_BONES)
    return []


def skeleton_pose(bone_list, parents=SOLDIER_PARENTS):
    """World (rotation, translation) of every bone of a skeleton given its parent table. The soldiers' parents are not stored; this
    order (a pelvis root, two spine bones and the head, then two arm chains of three hanging from the chest and two leg chains
    from the pelvis) was read off the translations and confirmed by the assembled shape. None for other bone counts."""
    if len(bone_list) != len(parents):
        return None
    world = []
    for k, (q, t) in enumerate(bone_list):
        rot, t = _quat_matrix(q), np.array(t, float)
        if parents[k] < 0:
            world.append((rot, t))
        else:
            rp, tp = world[parents[k]]
            world.append((rp @ rot, tp + rp @ t))
    return world


def strips_to_triangles(pos):
    """(n, 4) int16 positions with control words -> [(i, j, k)]: vertex i kicks the triangle (i-2, i-1, i) unless its
    control word has bit 15 (ADC) set; bit 14 marks the odd triangles of a strip (reversed order)."""
    tris = []
    for i in range(2, len(pos)):
        w = int(pos[i, 3]) & 0xFFFF
        if w & 0x8000:
            continue
        tris.append((i - 1, i - 2, i) if w & 0x4000 else (i - 2, i - 1, i))
    return tris


def decode(data, assemble=True, loose=False):
    """-> {'name', 'textures': [str], 'materials': [{'base', 'lum', 'colour'}], 'meshes': [{'material', 'pos' (n,3) float,
    'uv' (n,2) float, 'normal' (n,3) float | None, 'tris' [(i, j, k)]}]}. Raises ValueError when no geometry is found.
    `assemble` puts the mirrored (stored inverted) parts in place by a half turn; a shape with a node-pose record
    (aa_turret) is built with assemble=False and the records place every part. `loose`: also read material records of the
    looser layout when the strict one finds none (only checked on the transport)."""
    if len(data) < 0x100:
        raise ValueError('shape too short')
    name = data[8:data.index(b'\0', 8)].decode('latin-1')
    batches = _batches(data)
    if not batches:
        raise ValueError('no vertex batches')
    mats = [m for m in _materials(data) if m[0] < 0xFFFFFFF]
    textures, limit = _textures(data)
    if not mats and loose:                 # records in the looser layout (the transport); their indices count repeated textures
        mats = [m for m in _materials(data, loose=True) if m[0] < 0xFFFFFFF]
        if mats:
            textures, limit = _textures(data, keep_dups=True)
    bb = np.array(struct.unpack_from('<6f', data, 0x44)) if len(data) > 0x5c else None
    scale = _scale(data)
    if scale is None:
        ext = float(np.abs(bb).max()) if bb is not None and np.isfinite(bb).all() and np.abs(bb).max() > 0 else 1.0
        scale = 32767.0 / ext
    meshes = []
    kept = [i for i, b in enumerate(batches) if b[0] < limit] or list(range(len(batches)))
    bone_list = bones(data)
    parents = skeleton_of(data, len(bone_list))
    pose, starts = skeleton_pose(bone_list, parents), batch_groups(data)
    owner_bones = part_bones(parents, len(starts))
    if pose is not None and not owner_bones:
        pose = None
    for bi in kept:
        off, uv, nrm, pos = batches[bi]
        owner = [k for k, m in enumerate(mats) if m[0] < off]
        mesh = {'material': owner[-1] if owner else -1, 'pos': pos[:, :3].astype('f4') / scale,
                'uv': uv.astype('f4') / 4096.0, 'normal': None if nrm is None else nrm.astype('f4') / 127.0,
                'tris': strips_to_triangles(pos)}
        if pose is not None:                           # a soldier part: bone-local -> shape space in the default pose
            bone = owner_bones[max(k for k, s0 in enumerate(starts) if s0 <= bi)]
            rot, trans = pose[bone]
            mesh['bone'] = bone
            mesh['pos'] = (mesh['pos'] @ rot.T + trans).astype('f4')
            if mesh['normal'] is not None:
                mesh['normal'] = (mesh['normal'] @ rot.T).astype('f4')
        meshes.append(mesh)
    if not meshes:
        raise ValueError('no vertex batches in the first state')
    boxes = node_boxes(data)
    flipped = mirrored_nodes(boxes) if assemble else set()    # assemble=False: node-local parts, a rig places them (aa_turret)
    half_turn = np.array([-1, -1, -1], 'f4')
    half_turn[lateral_axis(boxes)] = 1     # a half turn about the axis the shape is mirrored across
    for m in meshes:                       # a mirror copy: undo the stored inversion
        lo, hi = m['pos'].min(0), m['pos'].max(0)
        tol = 0.04 + 0.01 * abs(hi - lo).max()      # the part's batches lie inside its node's box (a batch is only a piece of it)
        near = sorted((float(np.prod(np.array(b[3:]) - np.array(b[:3]) + 1e-3)), k) for k, (_p, b) in enumerate(boxes)
                      if np.all(lo >= np.array(b[:3]) - tol) and np.all(hi <= np.array(b[3:]) + tol))
        if near and near[0][1] in flipped:
            m['pos'] = m['pos'] * half_turn
            if m['normal'] is not None:
                m['normal'] = m['normal'] * half_turn
        if 'bone' in m:                        # the part in its bone's own space (animated export)
            rot, trans = pose[m['bone']]
            m['local'] = ((m['pos'] - trans) @ rot).astype('f4')
    return {'name': name, 'textures': textures, 'scale': scale,
            'materials': [{'name': m[1], 'colour': m[2], 'base': m[3], 'lum': m[4]} for m in mats], 'meshes': meshes}


def face_nose(sh, nose):
    """Turn a decoded shape about the up axis (file Y) so that its nose, the file (X, Z) direction `nose`, points along file +X,
    which to_json maps to the engine's forward. A proper rotation, so the winding is kept."""
    nx, nz = nose
    for m in sh['meshes']:
        for key in ('pos', 'normal'):
            a = m.get(key)
            if a is None:
                continue
            x, z = a[:, 0].copy(), a[:, 2].copy()
            if (nx, nz) == (-1, 0):
                a[:, 0], a[:, 2] = -x, -z
            elif (nx, nz) == (0, 1):
                a[:, 0], a[:, 2] = z, -x
            elif (nx, nz) == (0, -1):
                a[:, 0], a[:, 2] = -z, x
    return sh


def to_json(sh, texture_path):
    """Engine shape JSON (docs/formats/map_schema.md, ES1 shape schema with "rgba" materials). `texture_path(name)` ->
    pack-relative png path or None. The shape's axes become the engine's source frame (x, y, z) = (file Z, file X, file Y)
    so that the engine's (x, z, -y) conversion gives (east, up, south)."""
    materials, index = [], {}

    def material_of(tex_index):
        tex = sh['textures'][tex_index] if 0 <= tex_index < len(sh['textures']) else None
        if tex not in index:
            index[tex] = len(materials)
            low = (tex or '').lower()
            materials.append({'name': tex or 'none', 'flags': 4 if ('punch' in low or 'tran' in low) else 0,
                              'texture': (texture_path(tex) if tex else None) or '', 'w': 0, 'h': 0})
        return index[tex]

    fallback = primary_texture(sh['textures'])
    polys, allp = [], []
    by_bone = {}
    for m in sh['meshes']:
        mat = sh['materials'][m['material']] if m['material'] >= 0 else None
        mi = material_of(mat['base'] if mat and mat['base'] >= 0 else fallback)
        p, uv, nr = m['pos'], m['uv'], m['normal']
        if 'local_override' in m:
            p = m['local_override']
        target = by_bone.setdefault(m['bone'], []) if 'bone' in m and 'local_override' in m else polys
        for t in m['tris']:
            v = [[round(float(p[i][2]), 5), round(float(p[i][0]), 5), round(float(p[i][1]), 5)] for i in t]
            n = np.cross(p[t[1]] - p[t[0]], p[t[2]] - p[t[0]])
            ln = float(np.linalg.norm(n))
            if ln < 1e-12:
                continue
            n = n / ln
            target.append({'v': v, 'n': [round(float(n[2]), 5), round(float(n[0]), 5), round(float(n[1]), 5)],
                          'm': {'kind': 'rgba', 'index': mi}, 't': 'tri',
                          'uv': [[round(float(uv[i][0]), 5), round(float(uv[i][1]), 5)] for i in t]})
        allp.append(p)
    allp = np.vstack(allp)
    lo, hi = allp.min(0), allp.max(0)
    centre = (lo + hi) / 2
    radius = float(np.linalg.norm(hi - lo) / 2)
    pieces = [{'node': 0, 'id': 1000, 'name': sh['name'], 'cell': -1, 'state': 0, 'polys': polys}]
    if by_bone:                            # a rigged soldier: one piece per bone (see aa_soldier.py)
        pieces = [{'node': b, 'id': 1000 + b, 'name': 'bone%d' % b, 'cell': -1, 'state': 0, 'polys': by_bone[b]}
                  for b in sorted(by_bone)]
    return {'name': sh['name'], 'texset': None, 'source': 'inevitable_shp', 'units': 'metres',
            'lods': [{'radius': radius, 'center': [float(centre[2]), float(centre[0]), float(centre[1])], 'size': 128.0,
                      'name': 'Detail128', 'pieces': pieces, 'cells': []}],
            'nodes': [{'parent': -1, 'default': 0, 'name': 'Shape'}], 'transforms': [[0, 0, 0, 0, 0, 0]],
            'ds_sequences': [],
            'bounds': {'header': [[float(lo[2]), float(lo[0]), float(lo[1])], [float(hi[2]), float(hi[0]), float(hi[1])]]},
            'materials': materials}
