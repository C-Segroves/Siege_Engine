"""Tribes: Vengeance level brushes -> one engine shape per map (docs/formats/tribes_vengeance.md "BSP").

Not the compiled BSP tree: the editor brushes. Every Brush actor (CsgOper 1 add, 2 subtract) points at a Model whose Polys
export lists the brush polygons in brush space. Additive brush faces point outward, subtractive ones are flipped so a room
shows its inside. Polys layout (version 130): u32 3, u32 0, u32 1, u8 0, u32 count, u32 max, then per polygon: compact vertex
count, Base, Normal, TextureU, TextureV (f32 x3 each), vertices (f32 x3), a 13-byte trailer (u32 flags, compact actor,
compact material ref, ...). world = Location + Rotation x (PostScale x MainScale x (point - PrePivot)).
Output (engine metres, x = Unreal y, y = z, z = -x): shapes/bsp_<map>.json with all faces in one piece.
"""
import json
import math
import os
import struct

import numpy as np
from PIL import Image

import ue2_package as U
import tv_statics as S

PF_INVISIBLE = 0x1
CSG_ADD, CSG_SUBTRACT = 1, 2
MAX_TEXTURE = 512


def _polys_of_model(pkg, model_export):
    """The Polys export a Model refers to: the compact reference in its bytes that names a Polys export."""
    raw = pkg.raw(model_export)
    for pos in range(0, len(raw) - 1):
        r = U.Reader(raw, pos)
        try:
            ref = r.index()
        except IndexError:
            break
        if 0 < ref <= len(pkg.exports):
            e = pkg.exports[ref - 1]
            if pkg.class_name(e) == 'Polys':
                return e
    return None


def read_polys(pkg, polys_export):
    """[{'verts' (k, 3), 'base', 'normal', 'u', 'v', 'flags', 'material' ref}] of a Polys export (brush space)."""
    d = bytes(pkg.raw(polys_export))
    if len(d) < 21:
        return []
    count = struct.unpack_from('<I', d, 13)[0]
    pos, out = 21, []
    for _ in range(count):
        if pos >= len(d):
            break
        r = U.Reader(d, pos)
        c = r.index()
        b = r.p
        if not 3 <= c <= 32 or b + 48 + c * 12 > len(d):
            break
        base, nrm, tu, tv = (struct.unpack_from('<3f', d, b + 12 * i) for i in range(4))
        verts = np.frombuffer(d, dtype='<f4', count=c * 3, offset=b + 48).reshape(c, 3)
        vend = b + 48 + c * 12
        tr = U.Reader(d, vend + 4)
        tr.index()                                             # actor
        material = tr.index()
        out.append({'verts': verts, 'base': base, 'normal': nrm, 'u': tu, 'v': tv,
                    'flags': struct.unpack_from('<I', d, vend)[0], 'material': material})
        nxt = None
        for off in range(11, 24):                              # trailer length is 13; search to stay safe
            q = vend + off
            if q + 60 > len(d):
                break
            rr = U.Reader(d, q)
            try:
                c2 = rr.index()
            except IndexError:
                break
            if 3 <= c2 <= 32 and rr.p + 24 <= len(d):
                n2 = struct.unpack_from('<3f', d, rr.p + 12)
                if abs(math.sqrt(sum(x * x for x in n2)) - 1.0) < 0.01:
                    nxt = q
                    break
        if nxt is None:
            break
        pos = nxt
    return out


def _rotation(raw):
    if isinstance(raw, (bytes, bytearray)) and len(raw) == 12:
        pitch, yaw, roll = (x * 2 * math.pi / 65536.0 for x in struct.unpack('<3i', raw))
    else:
        return np.eye(3)
    cy, sy, cp, sp, cr, sr = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch), math.cos(roll), math.sin(roll)
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    ry = np.array([[cp, 0, -sp], [0, 1, 0], [sp, 0, cp]])
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    return rz @ ry @ rx


def _brush_scale(pkg, props, key):
    blob = props.get(key)
    if isinstance(blob, (bytes, bytearray)) and blob:
        sub = U.read_properties(pkg, U.Reader(bytes(blob), 0))
        v = U.vec3(sub.get('Scale', b''))
        if v:
            return np.array(v)
    return np.ones(3)


def export_bsp(idx, pkg, out_dir, map_id, mpu):
    """Writes shapes/bsp_<map>.json (and textures); returns the statics entry for it or None."""
    texture_slots, slot_names, polys_out = {}, [], []
    tex_dir = os.path.join(out_dir, 'textures', 'tv')
    sizes = {}
    for e in pkg.find('Brush'):
        props = U.object_properties(pkg, e)
        csg = props.get('CsgOper', 0)
        loc = U.vec3(props.get('Location', b''))
        mref = props.refs.get('Brush', 0)
        if csg not in (CSG_ADD, CSG_SUBTRACT) or loc is None or mref <= 0:
            continue
        model = pkg.exports[mref - 1]
        pe = _polys_of_model(pkg, model)
        if pe is None:
            continue
        pre = np.array(U.vec3(props.get('PrePivot', b'')) or (0.0, 0.0, 0.0))
        rot = _rotation(props.get('Rotation'))
        sc = _brush_scale(pkg, props, 'MainScale') * _brush_scale(pkg, props, 'PostScale')
        for poly in read_polys(pkg, pe):
            if poly['flags'] & PF_INVISIBLE:
                continue
            local = (poly['verts'].astype(float) - pre) * sc
            world = local @ rot.T + np.array(loc)
            nrm = rot @ np.array(poly['normal'])
            if csg == CSG_SUBTRACT:
                nrm = -nrm
            ref = poly['material']
            if ref not in texture_slots:
                rgba, name = S.material_texture(idx, pkg, ref) if ref else (None, '')
                name = ''.join(ch if ch.isalnum() or ch in '-_' else '_' for ch in name).lower() if rgba is not None else ''
                if rgba is not None:
                    path = os.path.join(tex_dir, name + '.png')
                    if not os.path.isfile(path):
                        os.makedirs(tex_dir, exist_ok=True)
                        img = Image.fromarray(rgba)
                        if max(img.size) > MAX_TEXTURE:
                            img = img.resize((min(img.width, MAX_TEXTURE), min(img.height, MAX_TEXTURE)), Image.LANCZOS)
                        img.save(path)
                    sizes[ref] = (rgba.shape[1], rgba.shape[0])
                texture_slots[ref] = len(slot_names)
                slot_names.append(name)
            if not name:
                continue                                       # editor placeholders (DefaultTexture, ConsoleBK, no material)
            w, h = sizes.get(ref, (256, 256))
            rel = poly['verts'].astype(float) - np.array(poly['base'])
            uv = np.stack([rel @ np.array(poly['u']) / w, -(rel @ np.array(poly['v'])) / h], axis=1)
            uv = uv - np.floor(uv.min(axis=0))                 # small offsets keep float precision; textures repeat
            polys_out.append((world, nrm, uv, texture_slots[ref]))
    if not polys_out:
        return None
    shape = _shape_json(polys_out, slot_names, mpu, 'bsp_' + map_id)
    os.makedirs(os.path.join(out_dir, 'shapes'), exist_ok=True)
    with open(os.path.join(out_dir, 'shapes', 'bsp_%s.json' % map_id), 'w', encoding='utf-8') as f:
        json.dump(shape, f, separators=(',', ':'))
    return {'shape': 'tribes_v:bsp_' + map_id, 'pos': [0.0, 0.0, 0.0], 'basis': [[1, 0, 0], [0, 1, 0], [0, 0, 1]], 'collide': True}


def _shape_json(polys, slot_names, mpu, name):
    out = []
    allv = []
    for world, nrm, uv, slot in polys:
        v = np.stack([world[:, 1], world[:, 0], world[:, 2]], axis=1) * mpu       # shape frame: x right, y forward, z up (the engine converts)
        n = np.array([nrm[1], nrm[0], nrm[2]])
        n = n / (np.linalg.norm(n) or 1.0)
        allv.append(v)
        for k in range(1, len(v) - 1):
            tri = [0, k, k + 1]
            p0, p1, p2 = v[tri[0]], v[tri[1]], v[tri[2]]
            if float(np.dot(np.cross(p1 - p0, p2 - p0), n)) < 0:
                tri = [0, k + 1, k]
            out.append({'v': [[round(float(x), 4) for x in v[i]] for i in tri], 'n': [round(float(x), 4) for x in n], 't': 'tri',
                        'm': {'kind': 'rgba', 'index': slot},
                        'uv': [[round(float(uv[i][0]), 4), round(float(uv[i][1]), 4)] for i in tri]})
    cat = np.concatenate(allv)
    lo, hi = cat.min(axis=0), cat.max(axis=0)
    return {'name': name, 'texset': None, 'source': 'unreal_brushes', 'units': 'metres',
            'lods': [{'radius': round(float(np.linalg.norm(hi - lo) / 2), 3), 'center': [round(float(c), 3) for c in (lo + hi) / 2],
                      'size': 128.0, 'name': 'Detail128',
                      'pieces': [{'node': 0, 'id': 1000, 'name': name, 'cell': -1, 'state': 0, 'polys': out}], 'cells': []}],
            'nodes': [{'parent': -1, 'default': 0, 'name': 'Shape'}], 'transforms': [[0, 0, 0, 0, 0, 0, 1]], 'ds_sequences': [],
            'bounds': {'header': [lo.tolist(), hi.tolist()]},
            'materials': [{'name': n, 'flags': 0, 'texture': 'textures/tv/%s.png' % n if n else '', 'w': 0, 'h': 0} for n in slot_names]}
