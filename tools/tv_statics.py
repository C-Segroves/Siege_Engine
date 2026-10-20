"""Tribes: Vengeance static meshes -> engine shapes and map "statics" (docs/formats/tribes_vengeance.md "Static meshes").

StaticMesh export layout after the tagged properties (version 130; verified on the PhoenixBase package):
  bounding box (6 f32 + valid byte), bounding sphere (4 f32), u32 3, u32 1, u32 3, u32 section count, sections,
  bounding box again (25 bytes), u32 3, u32 0, u32 1, vertex stream: compact count + count x (position f32 x3, normal f32 x3),
  colour stream (u32 3, byte 0, compact count, count x 4 bytes), alpha stream (u32 3, compact count, count x 4 bytes), UV stream (u32 3, byte sets, compact
  count, count x 8 bytes x sets), index buffer (u32, u32, compact count, count x u16).
Sections: the first is 11 bytes, each further one 14 bytes; the triangle count is the u16 at byte 7 of the first and byte 10
of the others; section i uses Materials[i]. Materials -> Shader.Diffuse -> Texture (Combiner/TexScaler follow their first
material). Output shape JSON is the engine shape schema (lods/pieces/polys) in engine metres (x = Unreal y, y = z, z = -x).
"""
import json
import math
import os
import struct

import numpy as np
from PIL import Image

import ue2_package as U
import ue2_texture as T

SECTION_FIRST_BYTES, SECTION_BYTES = 11, 14
CHAINED = ('Combiner', 'TexScaler', 'FinalBlend', 'Shader', 'MaterialSwitch', 'ColorModifier', 'TexRotator', 'TexPanner',
           'TexOscillator', 'TexEnvMap', 'TexCoordSource', 'VertexColor', 'MaterialSequence', 'ConstantColor', 'BitmapMaterial')
CHAIN_KEYS = ('Diffuse', 'Material1', 'Material', 'Material2', 'SelfIllumination', 'FallbackMaterial')
MAX_TEXTURE = 512


LAST_FAIL = ''


def _fail(why):
    global LAST_FAIL
    LAST_FAIL = why
    return None


def parse_static_mesh(pkg, export):
    """{'verts' (n, 3), 'normals', 'uvs' (n, 2), 'tris' (m, 3) int, 'sections' [(first triangle, count)], 'materials' [ref]}
    in Unreal units, or None when the layout is not the known one."""
    props, _end = U.object_with_trailing(pkg, export)
    full = bytes(pkg.data[export['offset']:export['offset'] + export['size']])
    t, j = b'', -1
    for s0 in range(0, min(len(full) - 120, 700)):          # bounding box, then again after the section table
        box = struct.unpack_from('<6f', full, s0)
        if not (all(abs(x) < 1e6 for x in box) and all(box[i] <= box[i + 3] for i in range(3)) and any(box)):
            continue
        if full[s0 + 24] != 1 or full[s0 + 25:s0 + 41] == b'\x00' * 16:
            continue
        k = full.find(full[s0:s0 + 24], s0 + 24)
        if 0 < k - s0 < 41 + 16 + SECTION_FIRST_BYTES + 64 * SECTION_BYTES + 8 and full[k + 25:k + 29] == b'\x03\x00\x00\x00':
            t, j = full[s0:], k - s0
            break
    if j < 0:
        return _fail('2')
    nsec_pos = 41 + 12
    if j < nsec_pos + 4:
        return _fail('3')
    nsec = struct.unpack_from('<I', t, nsec_pos)[0]
    sections, pos, first_tri = [], nsec_pos + 4, 0
    for k in range(nsec):
        off = pos + 7 if k == 0 else pos + 10
        if off + 2 > len(t):
            return _fail('4')
        tris = struct.unpack_from('<H', t, off)[0]
        sections.append((first_tri, tris))
        first_tri += tris
        pos += SECTION_FIRST_BYTES if k == 0 else SECTION_BYTES
    r = U.Reader(t, j + 25 + 12)
    n = r.index()
    if n <= 0 or n > 200000 or r.p + n * 24 > len(t):
        return _fail('5')
    vb = np.frombuffer(t, dtype='<f4', count=n * 6, offset=r.p).reshape(n, 6)
    r.p += n * 24
    found = _find_index_and_uv(t, r.p, n)
    if found is None:
        return _fail('6')
    uv_at, sets, m, ind_at = found
    uv = np.frombuffer(t, dtype='<f4', count=n * 2 * sets, offset=uv_at).reshape(n, 2 * sets)[:, :2]
    ind = np.frombuffer(t, dtype='<u2', count=m, offset=ind_at)
    mats = []
    blob = props.get('Materials')
    if isinstance(blob, (bytes, bytearray)) and blob:
        rr = U.Reader(blob, 0)
        for _k in range(rr.index()):
            el = U.read_properties(pkg, rr)
            mats.append(el.refs.get('Material', 0))
    elif 'Material' in props.refs:
        mats = [props.refs['Material']]
    return {'verts': vb[:, :3], 'normals': vb[:, 3:], 'uvs': uv, 'tris': ind.reshape(-1, 3).astype(np.int64),
            'sections': sections, 'materials': mats}


def _find_index_and_uv(t, start, n):
    """After the vertex stream the layout varies (colour and tangent streams): the UV stream is [u32][byte sets][compact n]
    + n x 8 x sets plausible floats; the index buffer (u32 0, u32 1, compact count, u16 indices) follows later."""
    c = _compact(n)
    q = t.find(c, start + 1)
    while q >= 0:
        sets = t[q - 1]
        at = q + len(c)
        if 1 <= sets <= 4 and at + n * 8 * sets <= len(t):
            uv = np.frombuffer(t, dtype='<f4', count=n * 2 * sets, offset=at)
            if np.isfinite(uv).all() and float(np.abs(uv).max()) < 256.0:
                found = _find_indices(t, at + n * 8 * sets, n)
                if found is not None:
                    return at, sets, found[0], found[1]
        q = t.find(c, q + 1)
    return None


def _find_indices(t, start, n):
    """The index buffer starts within a few header bytes after the UV stream: compact count, then u16 indices < n."""
    for off in range(0, 24):
        r = U.Reader(t, start + off)
        try:
            m = r.index()
        except IndexError:
            return None
        if 3 <= m <= n * 24 and m % 3 == 0 and r.p + m * 2 <= len(t):
            ind = np.frombuffer(t, dtype='<u2', count=m, offset=r.p)
            if int(ind.max()) < n and int(ind.max()) > n // 2 and ind[0] != ind[1]:
                return m, r.p
    return None


def _compact(v):
    out = bytearray()
    b = v & 0x3F
    v >>= 6
    out.append(b | (0x40 if v else 0))
    while v:
        c = v & 0x7F
        v >>= 7
        out.append(c | (0x80 if v else 0))
    return bytes(out)


def material_texture(idx, pkg, ref, depth=0):
    """Decoded RGBA (numpy) and a name for a material reference, following shader chains; (None, '') if none."""
    home, ex = idx.object(pkg, ref)
    if ex is None or depth > 4:
        return None, ''
    cls = home.class_name(ex)
    if cls == 'Texture':
        tex = T.read_texture(home, ex)
        rgba = T.to_rgba(tex) if tex else None
        return rgba, ex['name']
    if cls in CHAINED:
        props, _ = U.object_with_trailing(home, ex)
        for k in CHAIN_KEYS:
            if k in props.refs and props.refs[k]:
                rgba, name = material_texture(idx, home, props.refs[k], depth + 1)
                if rgba is not None:
                    return rgba, name
        tail = _tail_material_ref(home, ex)
        if tail:
            return material_texture(idx, home, tail, depth + 1)
    return None, ''


def _tail_material_ref(home, ex):
    """The 'Material' reference of a TexPanner / TexRotator ...: the tagged-property reader stops at the end of their struct
    properties (Matrix, PanRate), but the Material tag follows them at the end of the export."""
    if 'Material' not in home.names:
        return 0
    tag = _compact(home.names.index('Material'))
    raw = bytes(home.raw(ex))
    for info in (0x05, 0x15):
        i = raw.rfind(tag + bytes([info]))
        if i >= 0:
            try:
                return U.Reader(raw, i + len(tag) + 1).index()
            except IndexError:
                return 0
    return 0


def _unreal_to_engine(v, mpu):
    return np.stack([v[:, 1], v[:, 2], -v[:, 0]], axis=1) * mpu


def _unreal_to_shape(v, mpu):
    """Unreal (x forward, y right, z up) -> shape frame (x right, y forward, z up): ShapeInstance turns that into the engine's
    (x, z, -y) itself, so shapes are stored in the frame of the original 3Space / Torque shapes."""
    return np.stack([v[:, 1], v[:, 0], v[:, 2]], axis=1) * mpu


def mesh_shape_json(mesh, mpu, texture_names, name):
    """Engine shape dictionary (one LOD, one piece, triangle polys) of a parsed mesh."""
    v = _unreal_to_shape(mesh['verts'], mpu)
    nrm = _unreal_to_shape(mesh['normals'], 1.0)
    uv = mesh['uvs']
    polys = []
    for si, (first, count) in enumerate(mesh['sections'] or [(0, len(mesh['tris']))]):
        for tri in mesh['tris'][first:first + count]:
            a, b, c = (int(i) for i in tri)
            p0, p1, p2 = v[a], v[b], v[c]
            n = (nrm[a] + nrm[b] + nrm[c])
            face = np.cross(p1 - p0, p2 - p0)
            if float(np.dot(face, n)) < 0:                       # keep cross(v1 - v0, v2 - v0) . n > 0
                b, c = c, b
                p1, p2 = p2, p1
            ln = float(np.linalg.norm(n)) or 1.0
            polys.append({'v': [[round(float(x), 4) for x in p] for p in (p0, p1, p2)],
                          'n': [round(float(x) / ln, 4) for x in n], 't': 'tri',
                          'm': {'kind': 'rgba', 'index': min(si, max(0, len(texture_names) - 1))},
                          'uv': [[round(float(uv[i][0]), 4), round(float(uv[i][1]), 4)] for i in (a, b, c)]})
    lo, hi = v.min(axis=0), v.max(axis=0)
    centre = ((lo + hi) / 2).tolist()
    radius = float(np.linalg.norm(hi - lo) / 2) or 1.0
    return {'name': name, 'texset': None, 'source': 'unreal_static_mesh', 'units': 'metres',
            'lods': [{'radius': round(radius, 3), 'center': [round(c, 3) for c in centre], 'size': 128.0, 'name': 'Detail128',
                      'pieces': [{'node': 0, 'id': 1000, 'name': name, 'cell': -1, 'state': 0, 'polys': polys}], 'cells': []}],
            'nodes': [{'parent': -1, 'default': 0, 'name': 'Shape'}], 'transforms': [[0, 0, 0, 0, 0, 0, 1]], 'ds_sequences': [],
            'bounds': {'header': [lo.tolist(), hi.tolist()]},
            'materials': [{'name': n, 'flags': 0, 'texture': 'textures/tv/%s.png' % n if n else '', 'w': 0, 'h': 0}
                          for n in texture_names]}


def _basis(rotation_raw, scale3):
    """Engine-frame 3x3 basis (rows = columns of the rotation applied to the engine axes) of an Unreal rotator."""
    if isinstance(rotation_raw, (bytes, bytearray)) and len(rotation_raw) == 12:
        pitch, yaw, roll = (x * 2 * math.pi / 65536.0 for x in struct.unpack('<3i', rotation_raw))
    else:
        pitch = yaw = roll = 0.0
    cy, sy, cp, sp, cr, sr = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll), math.sin(roll)
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    ry = np.array([[cp, 0, -sp], [0, 1, 0], [sp, 0, cp]])        # positive pitch looks up (+z)
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    rot = rz @ ry @ rx
    m = np.array([[0, 1, 0], [0, 0, 1], [-1, 0, 0]], dtype=float)  # Unreal -> engine axes
    return m @ rot @ np.diag(scale3) @ m.T


def export_statics(idx, pkg, pack_dir, mpu, shape_cache, log=print):
    """Statics list of a map; writes any new shapes and textures into pack_dir. shape_cache: {(package, mesh): shape id or None}."""
    statics, failed = [], 0
    for e in pkg.find('StaticMeshActor'):
        props = U.object_properties(pkg, e)
        ref = props.refs.get('StaticMesh') if hasattr(props, 'refs') else None
        loc = U.vec3(props.get('Location', b''))
        if not ref or loc is None or props.get('bHidden'):
            continue
        home, mex = idx.object(pkg, ref)
        if mex is None:
            continue
        key = (getattr(home, 'stem', ''), mex['name'], mex['offset'])
        if key not in shape_cache:
            shape_cache[key] = _write_shape(idx, home, mex, pack_dir, mpu, shape_cache)
            if shape_cache[key] is None:
                failed += 1
        sid = shape_cache[key]
        if sid is None:
            continue
        scale = float(props.get('DrawScale', 1.0))
        s3 = U.vec3(props.get('DrawScale3D', b'')) or (1.0, 1.0, 1.0)
        b = _basis(props.get('Rotation'), [scale * s3[0], scale * s3[1], scale * s3[2]])
        statics.append({'shape': 'tribes_v:' + sid, 'pos': [round(float(x), 3) for x in _unreal_to_engine(np.array([loc]), mpu)[0]],
                        'basis': [[round(float(x), 5) for x in row] for row in b], 'collide': True})
    return statics, failed


def _safe(s):
    return ''.join(c if c.isalnum() or c in '-_' else '_' for c in s)


def _write_shape(idx, home, mex, pack_dir, mpu, shape_cache):
    mesh = parse_static_mesh(home, mex)
    if mesh is None or not len(mesh['tris']):
        return None
    sid = _safe('%s__%s' % (getattr(home, 'stem', 'map'), mex['name'])).lower()
    names = []
    tex_dir = os.path.join(pack_dir, 'textures', 'tv')
    for ref in mesh['materials'] or [0]:
        rgba, tname = material_texture(idx, home, ref) if ref else (None, '')
        tname = _safe(tname).lower() if rgba is not None else ''
        if rgba is not None:
            path = os.path.join(tex_dir, tname + '.png')
            if not os.path.isfile(path):
                os.makedirs(tex_dir, exist_ok=True)
                img = Image.fromarray(rgba)
                if max(img.size) > MAX_TEXTURE:
                    img = img.resize((min(img.width, MAX_TEXTURE), min(img.height, MAX_TEXTURE)), Image.LANCZOS)
                img.save(path)
        names.append(tname)
    os.makedirs(os.path.join(pack_dir, 'shapes'), exist_ok=True)
    with open(os.path.join(pack_dir, 'shapes', sid + '.json'), 'w', encoding='utf-8') as f:
        json.dump(mesh_shape_json(mesh, mpu, names, sid), f, separators=(',', ':'))
    return sid
