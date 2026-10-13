"""Darkstar (Starsiege, Starsiege: Tribes) weapon-effect decoding shared by tools/fx_starsiege.py and
tools/fx_tribes.py (docs/formats/weapon_fx.md sections 5 and 6).

Darkstar draws every explosion, impact, muzzle flash, smoke puff and glowing bolt as a 3Space shape (.dts):
a few textured quads / discs whose sequence animates
  * the bitmap ("IFL" subsequences: keyframe value = material index that replaces material slot `mat & 0xFFF`),
  * the geometry (object subsequences: keyframe value = mesh frame; flag nibble 0x1 = frame matters),
  * visibility (flag nibble 0x4 = visibility matters, 0x8 = visible) and node transforms (node subsequences).
The flag nibble is the top 4 bits of the keyframe material word (v7: u32 >> 28, v8: u16 >> 12).
This module evaluates such a sequence and rasterises it face-on (looking along the shape's thinnest axis, the
plane the artist drew the effect in) into RGBA flipbook frames.

Bitmaps blend by the type of the palette their PiDX selects in the world PPL (g_pal.h palette types):
additive (5, 6) -> "additive" sprite; translucent (2: 4th byte of each entry = alpha) -> alpha; subtractive
(7, 8) -> dark alpha; others -> opaque with index 0 transparent.
"""
import math
import os
import re

import numpy as np
from PIL import Image

import darkstar_dts as D
import darkstar_gfx as G

PALETTE_TRANSLUCENT = 2
PALETTE_ADDITIVE = (5, 6)
PALETTE_SUBTRACTIVE = (7, 8)
MATERIAL_TYPE_MASK = 0xF
MATERIAL_TEXTURE = 3
KEY_FRAME_MATTERS = 0x1
KEY_VISIBILITY_MATTERS = 0x4
KEY_VISIBLE = 0x8
KEY_EPSILON = 1e-4
MAX_FRAMES = 40
MIN_CANVAS = 48
MAX_CANVAS = 256
PIXEL_CENTRE = (0.5 + 1.3e-4, 0.5 + 2.9e-5)   # off-centre sample: a shared quad diagonal is drawn exactly once
BOUNDS_OBJECT = 'bounds'


# ------------------------------------------------------------------ source files

class SourceFiles:
    """Case-insensitive index of an unpacked Darkstar volume tree; `prefer` folders win name clashes."""

    def __init__(self, root, prefer=()):
        self.root = root
        self.index = {}
        order = [d.lower() for d in prefer]
        walk = sorted(os.walk(root), key=lambda w: self._rank(w[0], root, order))
        for folder, _dirs, files in walk:
            for f in files:
                self.index.setdefault(f.lower(), os.path.join(folder, f))

    @staticmethod
    def _rank(folder, root, order):
        top = os.path.relpath(folder, root).split(os.sep)[0].lower()
        return (order.index(top) if top in order else len(order), folder.lower())

    def find(self, name):
        """Path of a file by name; Starsiege's '@' material prefix is ignored."""
        return self.index.get(name.lstrip('@').lower()) if name else None

    def read(self, name):
        path = self.find(name)
        if not path:
            raise FileNotFoundError(name)
        with open(path, 'rb') as f:
            return f.read()


# ------------------------------------------------------------------ palettes and bitmaps

class Bitmaps:
    """PBMP bitmaps resolved through the world PPL into RGBA arrays plus their blend mode."""

    def __init__(self, files, ppl_name):
        self.files = files
        self.ppl = G.read_ppl(files.read(ppl_name))
        self.ppl_name = ppl_name
        self.cache = {}

    def palette_lut(self, palette_id):
        """256 x RGBA lookup table and blend mode of a palette id."""
        pal = G.palette_for(self.ppl, palette_id)
        lut = np.zeros((256, 4), np.uint8)
        lut[:, :3] = np.array(pal['colors'], np.uint8)
        kind = pal['type']
        if kind in PALETTE_ADDITIVE:
            lut[:, 3] = 255
        elif kind == PALETTE_TRANSLUCENT:
            lut[:, 3] = np.array(pal['flags'], np.uint8)
        elif kind in PALETTE_SUBTRACTIVE:
            lut[:, 3] = lut[:, :3].max(axis=1)
            lut[:, :3] = 0
        else:
            lut[:, 3] = 255
        lut[0, 3] = 0
        return lut, ('additive' if kind in PALETTE_ADDITIVE else 'alpha')

    def load(self, name):
        """(RGBA uint8 array h x w x 4, blend) of a bitmap, or None when the file is missing."""
        key = name.lstrip('@').lower()
        if key not in self.cache:
            self.cache[key] = self._decode(name)
        return self.cache[key]

    def _decode(self, name):
        path = self.files.find(name)
        if not path:
            return None
        with open(path, 'rb') as f:
            b = G.read_pbmp(f.read())
        lut, blend = self.palette_lut(b['palette_id'])
        idx = np.frombuffer(b['pixels'], np.uint8).reshape(b['h'], b['w'])
        return lut[idx], blend

    def image(self, name):
        """(PIL RGBA image, blend) of a bitmap for beam textures, or None; additive bitmaps use the sprite
        encoding (alpha = brightest channel, rgb * alpha = the added light)."""
        got = self.load(name)
        if not got:
            return None
        rgba, blend = got
        if blend == 'additive':
            rgb = rgba[..., :3].astype(np.float32) / 255.0
            canvas = (rgb * (rgba[..., 3:4] > 0), np.zeros(rgba.shape[:2], np.float32))
            return finish_canvas(canvas, True), blend
        return Image.fromarray(rgba, 'RGBA'), blend


# ------------------------------------------------------------------ shape animation

def key_flags(shape, mat):
    """(flag nibble, low bits) of a keyframe material word."""
    if shape['version'] >= 8:
        return (mat >> 12) & 0xF, mat & 0x0FFF
    return (mat >> 28) & 0xF, mat & 0x0FFFFFFF


class ShapeAnimation:
    """One sequence of a Darkstar shape evaluated at a 0..1 position: textured triangles in shape space."""

    def __init__(self, shape, sequence=0):
        self.s = shape
        self.seq = sequence if shape['sequences'] else None
        q = shape['sequences'][sequence] if self.seq is not None else {}
        self.duration = float(q.get('duration', 0.0))
        self.cyclic = bool(q.get('cyclic', 1))
        n_ifl = q.get('n_ifl', 0) or 0
        first = q.get('first_ifl', 0) or 0
        subs = shape['subsequences']
        self.ifl = [subs[i] for i in range(first, first + n_ifl) if 0 <= i < len(subs)]
        self.nodes = set(D.detail_nodes(shape, 0)) if shape['details'] else set(range(len(shape['nodes'])))
        self.mat_count = shape['material_list']['count'] if shape['material_list'] else 0

    def track(self, owner):
        for i in range(owner['firstsub'], owner['firstsub'] + owner['nsub']):
            sub = self.s['subsequences'][i]
            if sub['seq'] == self.seq:
                return sub
        return None

    def key_at(self, sub, pos):
        keys = self.s['keyframes'][sub['firstkf']:sub['firstkf'] + sub['nkf']]
        best = keys[0]
        for k in keys:
            if k['pos'] <= pos + KEY_EPSILON:
                best = k
        return best

    def key_positions(self):
        if self.seq is None:
            return [0.0]
        out = set()
        for sub in self.s['subsequences']:
            if sub['seq'] == self.seq:
                ks = self.s['keyframes'][sub['firstkf']:sub['firstkf'] + sub['nkf']]
                out.update(round(k['pos'], 4) for k in ks if 0.0 <= k['pos'] < 1.0 - KEY_EPSILON)
        return sorted(out) or [0.0]

    def material_map(self, pos):
        out = {}
        for sub in self.ifl:
            k = self.key_at(sub, pos)
            out[key_flags(self.s, k['mat'])[1]] = k['tf']
        return out

    def node_matrix(self, index, pos, cache):
        if index in cache:
            return cache[index]
        nd = self.s['nodes'][index]
        sub = self.track(nd)
        tf = self.s['transforms'][self.key_at(sub, pos)['tf'] if sub else nd['default']]
        rot = D.quat_to_mat(tf['q'])
        rot = [[rot[a][b] * tf['s'][b] for b in range(3)] for a in range(3)]
        mat = (rot, list(tf['t']))
        if nd['parent'] >= 0:
            prot, ptr = self.node_matrix(nd['parent'], pos, cache)
            mat = ([[sum(prot[a][k] * rot[k][b] for k in range(3)) for b in range(3)] for a in range(3)],
                   [ptr[a] + sum(prot[a][k] * tf['t'][k] for k in range(3)) for a in range(3)])
        cache[index] = mat
        return mat

    def object_frame(self, obj, pos):
        """Mesh frame of an object, or None when the object is hidden at `pos`."""
        sub = self.track(obj)
        if not sub:
            return 0
        flags, _low = key_flags(self.s, self.key_at(sub, pos)['mat'])
        if flags & KEY_VISIBILITY_MATTERS and not flags & KEY_VISIBLE:
            return None
        return self.key_at(sub, pos)['tf'] if flags & KEY_FRAME_MATTERS else 0

    def triangles(self, pos):
        """[(3 world vertices, 3 uvs, material index)] of the visible textured faces at sequence position pos."""
        out, cache = [], {}
        remap = self.material_map(pos)
        names = self.s['names']
        for obj in self.s['objects']:
            if obj['node'] not in self.nodes or names[obj['name']].lower() == BOUNDS_OBJECT:
                continue
            mesh = self.s['meshes'][obj['mesh']]
            frame = self.object_frame(obj, pos)
            if frame is None or not mesh['faces']:
                continue
            rot, tr = self.node_matrix(obj['node'], pos, cache)
            verts = D.mesh_frame_verts(mesh, min(frame, max(0, len(mesh['frames']) - 1)))
            offset = (obj['ox'], obj['oy'], obj['oz'])
            world = [[tr[a] + sum(rot[a][k] * (v[k] + offset[k]) for k in range(3)) for a in range(3)] for v in verts]
            out += [self._face(f, world, mesh['tverts'], remap) for f in mesh['faces']]
        return out

    def _face(self, f, world, tverts, remap):
        mat = f[6] % max(self.mat_count, 1)
        uv = [tverts[f[i]] if f[i] < len(tverts) else (0.0, 0.0) for i in (1, 3, 5)]
        return [world[f[0]], world[f[2]], world[f[4]]], uv, remap.get(mat, mat)


# ------------------------------------------------------------------ rasteriser

UP_AXIS = 2                      # Darkstar shapes are z-up

class Flipbook:
    """Face-on rendition of an animated effect shape."""

    def __init__(self, images, fps, duration, metres_per_pixel, blend, loop, source):
        self.images, self.fps, self.duration = images, fps, duration
        self.metres_per_pixel, self.blend, self.loop, self.source = metres_per_pixel, blend, loop, source
        self.depth_axis = 1          # the axis it was looked along (Darkstar: 2 = up, a flat ground shape)

    @property
    def is_ground_flat(self):
        """A shape lying flat in the ground plane (a shockwave ring): drawn on the ground, not facing the camera."""
        return self.depth_axis == UP_AXIS

    @property
    def height_m(self):
        return max(im.height for im in self.images) * self.metres_per_pixel

    def sprite_meta(self):
        return {'fps': round(self.fps, 3), 'loop': self.loop, 'metres_per_pixel': round(self.metres_per_pixel, 5),
                'blend': self.blend, 'source': self.source}


def view_axes(tri_sets):
    """(image x axis, image up axis, depth axis): look along the axis with the smallest extent."""
    pts = np.array([v for tris in tri_sets for t in tris for v in t[0]] or [[0.0, 0.0, 0.0]])
    ext = pts.max(axis=0) - pts.min(axis=0)
    depth = int(np.argmin(ext + np.array([0.0, -1e-3, 0.0])))   # ties: Darkstar shapes face -Y
    return {0: (1, 2, 0), 1: (0, 2, 1), 2: (0, 1, 2)}[depth]


def texel_size(tris, materials, bitmaps):
    """Median world size of one texel over the textured triangles (m)."""
    sizes = []
    for verts, uv, mat in tris:
        got = bitmaps.load(materials[mat]['file']) if mat < len(materials) else None
        if not got:
            continue
        w = got[0].shape[1]
        world = math.dist(verts[0], verts[1])
        tex = math.dist(uv[0], uv[1]) * w
        if tex > 1e-3 and world > 1e-6:
            sizes.append(world / tex)
    return float(np.median(sizes)) if sizes else None


def draw_triangle(canvas, pts, uv, texture, additive):
    """Affine-textured triangle into a premultiplied (rgb, alpha) float canvas; nearest texel, wrapping UVs."""
    rgb, alpha = canvas
    h, w = alpha.shape
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    x0, x1 = max(0, int(math.floor(min(xs)))), min(w, int(math.ceil(max(xs))))
    y0, y1 = max(0, int(math.floor(min(ys)))), min(h, int(math.ceil(max(ys))))
    (ax, ay), (bx, by), (cx, cy) = pts
    area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    if x0 >= x1 or y0 >= y1 or abs(area) < 1e-9:
        return
    X, Y = np.meshgrid(np.arange(x0, x1) + PIXEL_CENTRE[0], np.arange(y0, y1) + PIXEL_CENTRE[1])
    w0 = ((bx - X) * (cy - Y) - (by - Y) * (cx - X)) / area
    w1 = ((cx - X) * (ay - Y) - (cy - Y) * (ax - X)) / area
    w2 = 1.0 - w0 - w1
    inside = (w0 >= 0.0) & (w1 >= 0.0) & (w2 >= 0.0)
    th, tw = texture.shape[:2]
    u = w0 * uv[0][0] + w1 * uv[1][0] + w2 * uv[2][0]
    v = w0 * uv[0][1] + w1 * uv[1][1] + w2 * uv[2][1]
    texel = texture[np.floor(v * th).astype(int) % th, np.floor(u * tw).astype(int) % tw].astype(np.float32) / 255.0
    sa = texel[..., 3] * inside
    src = texel[..., :3] * sa[..., None]
    region_rgb, region_a = rgb[y0:y1, x0:x1], alpha[y0:y1, x0:x1]
    if additive:
        region_rgb += src
        np.maximum(region_a, src.max(axis=2), out=region_a)
    else:
        region_rgb *= (1.0 - sa)[..., None]
        region_rgb += src
        region_a *= (1.0 - sa)
        region_a += sa


def finish_canvas(canvas, additive):
    """Premultiplied float canvas -> straight-alpha PIL RGBA. Additive sprites get alpha = brightest channel, so
    rgb * alpha is exactly the light the original adds (and plain alpha blending still previews sensibly)."""
    rgb, alpha = canvas
    rgb = np.clip(rgb, 0.0, 1.0)
    a = rgb.max(axis=2) if additive else np.clip(np.maximum(alpha, rgb.max(axis=2)), 0.0, 1.0)
    safe = np.where(a > 1e-6, a, 1.0)
    out = np.zeros(alpha.shape + (4,), np.uint8)
    out[..., :3] = np.clip(rgb / safe[..., None] * 255.0 + 0.5, 0, 255)
    out[..., 3] = np.clip(a * 255.0 + 0.5, 0, 255)
    return Image.fromarray(out, 'RGBA')


class ShapeRenderer:
    """Darkstar effect shape -> Flipbook (sequence sampled at its keyframe rate, at most MAX_FRAMES frames)."""

    def __init__(self, files, bitmaps):
        self.files, self.bitmaps = files, bitmaps

    def render(self, dts_name, sequence=0):
        shape = D.read_shape(self.files.read(dts_name))
        anim = ShapeAnimation(shape, sequence)
        count = max(1, min(MAX_FRAMES, len(anim.key_positions())))
        positions = [i / count for i in range(count)]
        tri_sets = [anim.triangles(p) for p in positions]
        materials = shape['material_list']['materials'] if shape['material_list'] else []
        textured = [[t for t in tris if self._texture(materials, t[2])] for tris in tri_sets]
        blend = self._blend(textured, materials)
        axes = view_axes(textured)
        half = self._half_extent(textured, axes)
        texel = texel_size(textured[0] or [t for s in textured for t in s], materials, self.bitmaps) or half / 32.0
        size = int(min(MAX_CANVAS, max(MIN_CANVAS, round(2.0 * half / texel)))) & ~1
        mpp = 2.0 * half / size
        images = [self._frame(tris, materials, axes, half, mpp, size, blend) for tris in textured]
        duration = anim.duration if anim.duration > 0 else 0.0
        fps = count / duration if duration > 0 else 1.0
        source = '%s (%s, sequence %d, %d frames)' % (os.path.basename(self.files.find(dts_name)),
                                                      self.bitmaps.ppl_name, sequence, count)
        flip = Flipbook(images, fps, duration, mpp, blend, anim.cyclic, source)
        flip.depth_axis = axes[2]
        return flip

    def _texture(self, materials, mat):
        if mat >= len(materials) or (materials[mat]['flags'] & MATERIAL_TYPE_MASK) != MATERIAL_TEXTURE:
            return None
        return self.bitmaps.load(materials[mat]['file'])

    def _blend(self, textured, materials):
        modes = {self._texture(materials, t[2])[1] for tris in textured for t in tris}
        return 'additive' if modes == {'additive'} else 'alpha'

    @staticmethod
    def _half_extent(textured, axes):
        pts = [v for tris in textured for t in tris for v in t[0]]
        if not pts:
            return 0.5
        return max(max(abs(p[axes[0]]), abs(p[axes[1]])) for p in pts) * 1.02 + 1e-3

    def _frame(self, tris, materials, axes, half, mpp, size, blend):
        canvas = (np.zeros((size, size, 3), np.float32), np.zeros((size, size), np.float32))
        far_first = sorted(tris, key=lambda t: -sum(v[axes[2]] for v in t[0]))
        for verts, uv, mat in far_first:
            texture, mode = self._texture(materials, mat)
            pts = [((v[axes[0]] + half) / mpp, (half - v[axes[1]]) / mpp) for v in verts]
            draw_triangle(canvas, pts, uv, texture, mode == 'additive')
        return finish_canvas(canvas, blend == 'additive')


# ------------------------------------------------------------------ helpers shared by the pack modules

def unit_rgb(values, scale=1.0):
    """Colour components (0..scale) -> [0..1] floats."""
    return [round(min(1.0, max(0.0, float(c) / scale)), 4) for c in values]


def add_flipbook_sprite(library, name, flip, sheet_rows):
    """Registers a flipbook as an RGBA sprite of the library and queues it for the contact sheet."""
    library.add_rgba_sprite(name, flip.images, **flip.sprite_meta())
    sheet_rows.append((name, flip.images))
    return name


def beam_texture(library, bitmaps, bitmap_names, texture_name):
    """(pack-relative texture path, blend) of the first existing bitmap; (None, 'additive') when none exists."""
    for bmp in bitmap_names:
        got = bitmaps.image(str(bmp)) if bmp else None
        if got:
            return library.save_texture(texture_name, got[0]), got[1]
    return None, 'additive'


def passive_fx(note):
    return {'source': note, 'projectile': None, 'beam': None, 'trail': None, 'muzzle': None,
            'impact': {'miss': [], 'shield': [], 'armor': []}, 'notes': 'passive'}


def is_true(value):
    return str(value).strip().lower() in ('true', 't', '1')


def parse_value(text):
    text = text.strip()
    if text.startswith('{'):
        return [float(x) for x in re.findall(r'-?\d+(?:\.\d+)?(?:[eE]-?\d+)?', text)]
    if text.startswith('"'):
        return text.strip('"')
    try:
        return float(text)
    except ValueError:
        return text


DATABLOCK_RX = re.compile(r'^\s*(\w+Data)\s+(\w+)\s*\{(.*?)^\s*\}\s*;', re.S | re.M)
FIELD_RX = re.compile(r'(\w+)(?:\[(\d+)\])?\s*=\s*(\{[^}]*\}|"[^"]*"|[^;]+);')


def parse_datablocks(text, source):
    """Darkstar script datablocks `Class Name { field = value; field[i] = {a, b, c}; };` -> {lower name: block}.
    Field names are lower-case; indexed fields become lists."""
    text = re.sub(r'//[^\n]*', '', text)
    out = {}
    for m in DATABLOCK_RX.finditer(text):
        fields = {}
        for fm in FIELD_RX.finditer(m.group(3)):
            key, index, value = fm.group(1).lower(), fm.group(2), parse_value(fm.group(3))
            if index is None:
                fields[key] = value
            else:
                fields.setdefault(key, {})[int(index)] = value
        out[m.group(2).lower()] = {'class': m.group(1), 'name': m.group(2), 'fields': fields, 'source': source}
    return out
