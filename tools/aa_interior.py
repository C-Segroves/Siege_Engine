r"""Aerial Assault interiors (DATA/INTERIORS/*.BIN, magic "BILD006A"): the buildings of the missions.

A header (relocated pointers, bounding box floats at 0x64) is followed by VIF packets, nine or so batches each of
    UNPACK V2-32 1   (vertex count, texture number)
    UNPACK V4-32 n   positions: float x, y, z (metres, the world's axes: Y up) and a control word; as in the shapes,
                     bit 15 of the word is the strip-restart (ADC) flag and bit 14 the winding flag
    UNPACK V2-16 2n  per vertex two texture coordinate pairs (texture, lightmap) as int16 pairs (s0, t0, s1, t1)
and, after the packets, the texture path list ("Data\interiors\Ps2Tex\NAME.tga": NAME.XBM; the last one is the
mission's lightmap atlas). The texture number of a batch is 1-based into that list (an assumption; the numbers run up to
the list's length). Texture coordinates are taken as value / 256 (assumption: one repeat per 2 m).
"""
import re
import struct

import numpy as np

import aa_shape

MAGIC = b'BILD006A'
_BS = re.escape(chr(92)).encode()
TEX_RE = re.compile(rb'[Dd]ata' + _BS + rb'interiors' + _BS + rb'[Pp]s2[Tt]ex' + _BS + rb'([A-Za-z0-9_\-\.]+)\.tga')
UV_DIV = 256.0


def decode(data):
    """-> {'textures': [names without the lightmap], 'meshes': [{'texture': int, 'pos', 'uv', 'tris'}]}."""
    if data[:8] != MAGIC:
        raise ValueError('not an interior')
    textures = [m.group(1).decode('latin-1') for m in TEX_RE.finditer(data)]
    textures = [t for t in textures if '_lm' not in t.lower()]
    meshes = []
    i = 0xC0
    n = len(data)
    while i < n - 4:
        w = struct.unpack_from('<I', data, i)[0]
        if w in (0x01000101, 0x01010001):
            cmds, end = aa_shape.walk(data, i)
            ups = [c for c in cmds if c[0] == 'u']
            k = 0
            while k + 2 < len(ups):
                a, p, u = ups[k], ups[k + 1], ups[k + 2]
                if a[1] == 'V2-32' and p[1] == 'V4-32' and u[1] == 'V2-16' and u[2] == 2 * p[2]:
                    cnt, tex = struct.unpack('<2I', a[4][:8])
                    raw = np.frombuffer(p[4], '<u4', p[2] * 4).reshape(-1, 4)
                    meshes.append({'texture': int(tex) - 1, 'pos': raw[:, :3].view('<f4').astype('f4'), 'w': raw[:, 3].copy(),
                                   'uv': np.frombuffer(u[4], '<i2', u[2] * 2).reshape(-1, 4)[:, :2].astype('f4') / UV_DIV})
                    k += 3
                else:
                    k += 1
            if ups:
                i = end
                continue
        i += 4
    if not meshes:
        raise ValueError('no geometry')
    for m in meshes:
        m['tris'] = _triangles(m['w'])
    _orient_outward(meshes)
    return {'textures': textures, 'meshes': meshes}


def _triangles(w):
    tris = []
    for i in range(2, len(w)):
        flags = int(w[i])
        if flags & 0x8000:
            continue
        tris.append((i - 1, i - 2, i) if flags & 0x4000 else (i - 2, i - 1, i))
    return tris


def _orient_outward(meshes):
    """Triangle order is flipped for every mesh when most of the geometry faces the building's centre."""
    allp = np.vstack([m['pos'] for m in meshes])
    c = (allp.min(0) + allp.max(0)) / 2
    score = 0.0
    for m in meshes:
        p = m['pos']
        for a, b, d in m['tris']:
            n = np.cross(p[b] - p[a], p[d] - p[a])
            score += float(np.dot(n, (p[a] + p[b] + p[d]) / 3 - c))
    if score < 0:
        for m in meshes:
            m['tris'] = [(a, d, b) for a, b, d in m['tris']]


def to_shape(it, name):
    """Adapter to aa_shape.to_json's input."""
    textures = it['textures']
    meshes = []
    for m in it['meshes']:
        t = min(max(m['texture'], 0), max(len(textures) - 1, 0))
        meshes.append({'material': t, 'pos': m['pos'], 'uv': m['uv'], 'normal': None, 'tris': m['tris']})
    mats = [{'name': 'tex%d' % k, 'colour': (1, 1, 1, 1), 'base': k, 'lum': -1} for k in range(len(textures))]
    return {'name': name, 'textures': textures, 'materials': mats, 'meshes': meshes, 'scale': 1.0}
