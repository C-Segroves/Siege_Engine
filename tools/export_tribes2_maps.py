"""Tribes 2 missions -> engine arena maps (docs/formats/map_schema.md).

Input  (siege_paths.work('tribes2', 'extracted')): missions/missions/*.mis (TorqueScript object tree),
       missions/terrains/*.ter, interiors/interiors/*.dif, shapes/shapes/*.dts, textures (terrain/,
       details/, skies, interior textures in lush/desert/ice/lava/badlands .vl2 folders).
Output (siege_paths.pack('tribes2')):
  maps/<id>/map.json, height.r32, albedo.png, detail.png, sky_*.png      one folder per mission
  maps/_index.json
  shapes/int_<dif>.json      interiors (.dif detail level 0 = highest detail), truecolour "rgba" materials,
                             one piece, node space = interior space (metres, Z up); collision = the render
                             surfaces (the engine builds a concave collision mesh from the visible geometry)
  textures/tribes2_interiors/<texture>.png   shared interior textures
  shapes/<dts>.json          station / prop shapes via tools/export_tribes2.py (DTS v22/v23 only)
  previews/maps/<id>.png     top-down check images (only with --preview)

Conversions (all derived from the Torque V12 sources the formats come from):
  * Torque frame: metres, Z up, +Y north.  Engine: (x, y, z) -> (x, z, -y).
  * Mission "rotation = ax ay az deg": Torque builds QuatF(AngAxisF) and m_quatF_set_matF writes the
    transposed matrix, so objects turn by -deg about the axis (clockwise seen from +axis). Engine yaw for a
    Z-axis rotation = -deg * sign(az); other axes -> "basis".
  * .ter v2: u8 version, 256x256 u16 heights (/32 = metres), 256x256 u8 (material group & 7 | flags),
    material names (u8-length strings, empties skipped), one 256x256 u8 alpha map per material.
    Heights index = x + 256 * y, world = TerrainBlock.position + (x, y) * squareSize; the block repeats
    (wraps) every 256 squares. Exported: the mission area plus MARGIN metres, sampled with wrap-around.
  * Albedo: material textures (textures/terrain/<name>.png, "terrain." prefix dropped) blended by the
    bilinearly interpolated alpha maps; one texture repeat per TILE_SQUARES squares (Torque blender:
    256-texel source over 2^(10 - TerrainTextureMipLevel) squares).
  * Teams: SimGroup Team<N> -> team N - 1 (Team0 / no team = -1, neutral).
  * Herc starts (user rule): every vehicle pad (StationVehiclePad) gives a "vehicle_pad" spawn and a "herc"
    spawn at the pad position facing the pad heading.

Usage: python tools/export_tribes2_maps.py [--preview] [mission ...]
       python tools/export_tribes2_maps.py --interiors   (re-export only the interior shapes)
"""
import json
import math
import os
import re
import shutil
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import siege_paths as P
import torque_dif as D

SRC = P.work('tribes2', 'extracted')
OUT = P.pack('tribes2')
MARGIN = 320.0            # metres of terrain exported around the mission area
PX_PER_SQUARE = 8         # albedo texels per terrain square (8 m) -> 1 texel per metre
TILE_SQUARES = 8          # terrain material texture repeats every 8 squares (64 m)
INVISIBLE_MATERIALS = {'null', 'origin', 'trigger', 'forcefield', 'emitter'}

STATION_KINDS = {
    'stationinventory': 'inventory', 'deployedstationinventory': 'inventory',
    'stationvehiclepad': 'vehicle', 'stationvehicle': 'vehicle',
    'generatorlarge': 'generator', 'solarpanel': 'generator',
    'sensorlargepulse': 'sensor', 'sensormediumpulse': 'sensor',
    'turretbaselarge': 'turret', 'sentryturret': 'turret', 'traininglongdetectturret': 'turret',
    'flag': 'flag', 'flipflop': 'objective', 'nexus': 'objective', 'nexusbase': 'objective',
    'repairpack': 'repair', 'ammopack': 'ammo',
}
# datablocks whose shapeFile the catalogue cannot resolve (set in script functions / parents)
SHAPE_FALLBACK = {
    'flag': 'flag', 'exteriorflagstand': 'ext_flagstand', 'interiorflagstand': 'int_flagstand',
    'flipflop': 'switch', 'nexusbase': 'nexusbase', 'nexuscap': 'nexuscap', 'nexus': 'nexus_effect',
    'banner_strength': 'banner_strength', 'banner_unity': 'banner_unity', 'banner_honor': 'banner_honor',
    'traininglongdetectturret': 'turret_base_large', 'stationinventory': 'station_inv_human',
    'stationvehiclepad': 'vehicle_pad', 'generatorlarge': 'station_generator_large',
    'turretbaselarge': 'turret_base_large', 'sentryturret': 'turret_sentry', 'solarpanel': 'solarpanel',
    'sensorlargepulse': 'sensor_pulse_large', 'sensormediumpulse': 'sensor_pulse_medium',
    'logoprojector': 'teamlogo_projector', 'repairpack': 'pack_upgrade_repair', 'ammopack': 'pack_upgrade_ammo',
}
STATIC_DATABLOCKS = {'exteriorflagstand', 'interiorflagstand', 'nexuscap', 'banner_strength', 'banner_unity',
                     'banner_honor', 'logoprojector'}

_index = None
_db = None
_shape_ok = {}
_tex_cache = {}


# ------------------------------------------------------------------ helpers

def write_json(path, obj, pretty=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        if pretty:
            json.dump(obj, f, indent=1)
        else:
            json.dump(obj, f, separators=(',', ':'))


def index():
    global _index
    if _index is None:
        _index = {}
        for dp, dn, fn in os.walk(SRC):
            for f in fn:
                _index.setdefault(f.lower(), os.path.join(dp, f))
    return _index


def find_image(name):
    base = name.replace('\\', '/').split('/')[-1].lower()
    for ext in ('.png', '.jpg', '.bmp'):
        p = index().get(base + ext)
        if p:
            return p
    return None


def datablocks():
    global _db
    if _db is None:
        try:
            import catalog_tribes2 as C
            C.SCR = os.path.join(SRC, 'scripts', 'scripts')
            db = C.datablocks()
            _db = {k: C.resolved(db, k) for k in db}
        except Exception:  # noqa: BLE001 - fall back to the built-in table
            _db = {}
    return _db


def datablock_shape(name):
    n = name.lower()
    sf = datablocks().get(n, {}).get('shapeFile')
    if isinstance(sf, str) and sf.lower().endswith('.dts'):
        return sf[:-4].lower()
    return SHAPE_FALLBACK.get(n)


def vec(s, n=3):
    try:
        v = [float(x) for x in str(s).split()]
    except ValueError:
        return None
    return v[:n] if len(v) >= n else None


def eng_pos(p):
    return [round(p[0], 3), round(p[2], 3), round(-p[1], 3)]


def torque_matrix(rot):
    """Mission "ax ay az deg" -> 3x3 rotation actually applied by Torque (Torque frame)."""
    r = vec(rot, 4) or [1, 0, 0, 0]
    ax = np.array(r[:3], float)
    ln = np.linalg.norm(ax)
    if ln < 1e-9 or abs(r[3]) < 1e-9:
        return np.eye(3)
    ax /= ln
    a = math.radians(r[3])
    x, y, z = ax * math.sin(a / 2)
    w = math.cos(a / 2)
    # m_quatF_set_matF: m[r][c] with m[0][1] = xy + wz (the transpose of the textbook matrix)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)],
        [2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)],
        [2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)]])


C_ENG = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)   # Torque -> engine axes


def placement(obj):
    """-> dict with pos + yaw (or basis) + scale in the engine frame, plus the Torque matrix."""
    f = obj['fields']
    p = vec(f.get('position', '0 0 0')) or [0, 0, 0]
    M = torque_matrix(f.get('rotation', '1 0 0 0'))
    B = C_ENG @ M @ C_ENG.T
    out = {'pos': eng_pos(p)}
    if abs(B[1][1] - 1.0) < 1e-4:
        # Godot yaw basis: [[cos, 0, sin], [0, 1, 0], [-sin, 0, cos]]
        out['yaw'] = round(math.degrees(math.atan2(B[0][2], B[0][0])), 3)
    else:
        out['basis'] = [[round(float(v), 6) for v in row] for row in B]
    s = vec(f.get('scale', '1 1 1')) or [1, 1, 1]
    if max(s) - min(s) < 1e-4:
        out['scale'] = round(s[0], 4)
    else:
        out['scale'] = [round(s[0], 4), round(s[2], 4), round(s[1], 4)]
    return out, M, p, s


# ------------------------------------------------------------------ mission parser

_TOK = re.compile(r'new\s+(\w+)\s*\(\s*([^)]*?)\s*\)\s*\{'      # 1, 2: new Class(Name) {
                  r'|(\}\s*;)'                                    # 3: };
                  r'|([A-Za-z_][\w\[\]]*)\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)   # 4, 5: field


def parse_mission(text):
    header = {}
    for m in re.finditer(r'^//\s*(\w+)\s*=\s*(.*?)\s*$', text, re.M):
        header.setdefault(m.group(1), m.group(2))
    body = '\n'.join(l for l in text.split('\n') if not l.lstrip().startswith('//'))
    root = {'class': 'root', 'name': '', 'fields': {}, 'children': [], 'parent': None}
    cur = root
    for m in _TOK.finditer(body):
        if m.group(1):
            o = {'class': m.group(1), 'name': m.group(2), 'fields': {}, 'children': [], 'parent': cur}
            cur['children'].append(o)
            cur = o
        elif m.group(3):
            if cur['parent'] is not None:
                cur = cur['parent']
        else:
            cur['fields'].setdefault(m.group(4), m.group(5))
            cur['fields'][m.group(4).lower()] = m.group(5)
    return header, root


def walk(o):
    yield o
    for c in o['children']:
        yield from walk(c)


def team_of(o):
    p = o['parent']
    while p is not None:
        m = re.match(r'team(\d+)$', p['name'] or '', re.I)
        if p['class'] == 'SimGroup' and m:
            return int(m.group(1)) - 1
        p = p['parent']
    return -1


def field(o, k, default=None):
    return o['fields'].get(k, o['fields'].get(k.lower(), default))


# ------------------------------------------------------------------ terrain

def read_ter(path):
    d = open(path, 'rb').read()
    ver = d[0]
    o = 1
    h = np.frombuffer(d, '<u2', 65536, o).reshape(256, 256).astype(np.float32) / 32.0   # [y][x]
    o += 131072
    mm = np.frombuffer(d, 'u1', 65536, o).reshape(256, 256)
    o += 65536
    names = []
    k, mx = 0, 8
    while k < mx:
        n = d[o]
        s = d[o + 1:o + 1 + n].decode('latin1')
        o += 1 + n
        if s:
            names.append(s)
            k += 1
        else:
            mx -= 1
    alphas = []
    if ver >= 2:
        for _ in names:
            alphas.append(np.frombuffer(d, 'u1', 65536, o).reshape(256, 256).astype(np.float32) / 255.0)
            o += 65536
    else:
        for i in range(len(names)):
            alphas.append(((mm & 7) == i).astype(np.float32))
    return {'version': ver, 'heights': h, 'flags': mm, 'materials': names, 'alphas': alphas}


def terrain_texture(name, px):
    """Material texture resized to px x px (float RGB array)."""
    from PIL import Image
    key = (name.lower(), px)
    if key not in _tex_cache:
        n = name
        if n.lower().startswith('terrain.'):
            n = n[8:]
        f = index().get(n.lower() + '.png') or index().get(n.lower() + '.jpg') or find_image(n)
        if f is None:
            _tex_cache[key] = None
        else:
            img = Image.open(f).convert('RGB').resize((px, px), Image.LANCZOS)
            _tex_cache[key] = np.asarray(img, np.float32)
    return _tex_cache[key]


def bilinear_wrap(a, gx, gy):
    """Sample a 256x256 [y][x] grid at fractional grid coords with wrap-around."""
    x0 = np.floor(gx).astype(np.int64)
    y0 = np.floor(gy).astype(np.int64)
    fx = (gx - x0).astype(np.float32)
    fy = (gy - y0).astype(np.float32)
    x0 &= 255
    y0 &= 255
    x1 = (x0 + 1) & 255
    y1 = (y0 + 1) & 255
    top = a[y0, x0] * (1 - fx) + a[y0, x1] * fx
    bot = a[y1, x0] * (1 - fx) + a[y1, x1] * fx
    return top * (1 - fy) + bot * fy


def export_terrain(tb, area, outdir, notes):
    from PIL import Image
    tf = field(tb, 'terrainFile')
    path = index().get((tf or '').lower())
    if not path:
        notes.append('terrain file %s not found' % tf)
        return None, None
    ter = read_ter(path)
    sq = float(field(tb, 'squareSize', '8'))
    pos = vec(field(tb, 'position', '-1024 -1024 0')) or [-1024, -1024, 0]
    ax, ay, aw, ah = area
    # region in Torque coords snapped to the terrain grid
    gx0 = math.floor((ax - MARGIN - pos[0]) / sq)
    gx1 = math.ceil((ax + aw + MARGIN - pos[0]) / sq)
    gy0 = math.floor((ay - MARGIN - pos[1]) / sq)
    gy1 = math.ceil((ay + ah + MARGIN - pos[1]) / sq)
    w = gx1 - gx0 + 1
    hgt = gy1 - gy0 + 1
    # engine rows run +z = south: row r <-> grid y = gy1 - r
    gxs = np.arange(gx0, gx1 + 1)
    gys = gy1 - np.arange(hgt)
    H = ter['heights'][np.ix_(gys & 255, gxs & 255)].astype('<f4')
    os.makedirs(outdir, exist_ok=True)
    H.tofile(os.path.join(outdir, 'height.r32'))
    x0 = pos[0] + gx0 * sq
    z0 = -(pos[1] + gy1 * sq)

    # albedo: (w-1) x (hgt-1) squares
    P_ = PX_PER_SQUARE
    W_img, H_img = (w - 1) * P_, (hgt - 1) * P_
    tile_px = TILE_SQUARES * P_
    texs = [terrain_texture(n, tile_px) for n in ter['materials']]
    missing = [n for n, t in zip(ter['materials'], texs) if t is None]
    if missing:
        notes.append('terrain textures not found: %s' % ', '.join(missing))
    img = np.zeros((H_img, W_img, 3), np.uint8)
    cols = np.arange(W_img)
    sx = gx0 + (cols + 0.5) / P_                      # grid x of each texel column
    for r0 in range(0, H_img, 256):
        rows = np.arange(r0, min(r0 + 256, H_img))
        sy = gy1 - (rows + 0.5) / P_                  # grid y of each texel row
        GX, GY = np.meshgrid(sx, sy)
        acc = np.zeros(GX.shape + (3,), np.float32)
        wsum = np.zeros(GX.shape, np.float32)
        tu = (np.floor(GX * P_).astype(np.int64)) % tile_px
        tv = (np.floor(-GY * P_).astype(np.int64)) % tile_px
        for a, t in zip(ter['alphas'], texs):
            if t is None:
                continue
            wgt = bilinear_wrap(a, GX, GY)
            acc += t[tv, tu] * wgt[..., None]
            wsum += wgt
        wsum[wsum < 1e-4] = 1.0
        img[rows[0]:rows[-1] + 1] = np.clip(acc / wsum[..., None], 0, 255).astype(np.uint8)
    Image.fromarray(img).save(os.path.join(outdir, 'albedo.png'), optimize=True)

    t = {'heights': 'height.r32', 'size': [int(w), int(hgt)], 'square': sq, 'origin': [round(x0, 3), round(z0, 3)],
         'height_scale': 1.0, 'albedo': 'albedo.png', 'albedo_repeat': 1.0,
         'source': os.path.relpath(path, SRC).replace('\\', '/'), 'materials': ter['materials'],
         'wraps': True}
    det = field(tb, 'detailTexture')
    if det:
        f = find_image(det)
        if f:
            Image.open(f).convert('RGB').save(os.path.join(outdir, 'detail.png'))
            t['detail'] = 'detail.png'
            t['detail_square_repeat'] = 1
    # empty (hole) squares from the mission, in exported grid cells [col, row] of the square's NW corner
    holes = []
    runs = (field(tb, 'emptySquares') or '').split()
    for rv in runs:
        try:
            rv = int(rv)
        except ValueError:
            continue
        off, run = rv & 0xffff, rv >> 16
        for j in range(run):
            sqi = off + j
            sx_, sy_ = sqi & 255, sqi >> 8
            for kx in range(gx0 - (gx0 % 256) - 256, gx1 + 1, 256):
                for ky in range(gy0 - (gy0 % 256) - 256, gy1 + 1, 256):
                    cx, cy = kx + sx_, ky + sy_
                    if gx0 <= cx < gx1 and gy0 < cy + 1 <= gy1:
                        holes.append([cx - gx0, gy1 - (cy + 1)])
    if holes:
        t['holes'] = holes
        notes.append('%d terrain hole squares (terrain.holes: cut from the terrain mesh and collision, MapTerrain)'
                     % len(holes))
    return t, ter


# ------------------------------------------------------------------ interiors

def export_interior(dif):
    """.dif -> shapes/int_<name>.json; returns shape id or None."""
    base = os.path.splitext(os.path.basename(dif))[0].lower()
    sid = 'int_' + base
    if sid in _shape_ok:
        return _shape_ok[sid]
    from PIL import Image
    path = index().get(base + '.dif')
    if not path:
        _shape_ok[sid] = None
        return None
    try:
        d = D.read_dif(open(path, 'rb').read())
    except Exception as e:  # noqa: BLE001
        print('interior %s: %s' % (base, e))
        _shape_ok[sid] = None
        return None
    it = d['details'][0]
    mats = []
    for mname in it['materials']:
        short = mname.replace('\\', '/').split('/')[-1]
        ent = {'name': mname, 'texture': None, 'flags': 3, 'w': 0, 'h': 0}
        if short.lower() not in INVISIBLE_MATERIALS:
            f = find_image(short)
            if f:
                rel = 'textures/tribes2_interiors/%s.png' % short.lower()
                dst = os.path.join(OUT, *rel.split('/'))
                if not os.path.exists(dst):
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    img = Image.open(f)
                    img = img.convert('RGBA') if img.mode in ('RGBA', 'LA', 'P') else img.convert('RGB')
                    img.save(dst)
                    sz = img.size
                else:
                    sz = Image.open(dst).size
                ent.update(texture=rel, w=sz[0], h=sz[1])
        mats.append(ent)
    pts = it['points']
    polys = []
    lo = [1e9] * 3
    hi = [-1e9] * 3
    for s in it['surfaces']:
        m = mats[s['texture']]
        if m['name'].replace('\\', '/').split('/')[-1].lower() in INVISIBLE_MATERIALS:
            continue
        pl = it['planes'][s['plane'] & 0x7fff]
        n = [pl[0], pl[1], pl[2]]
        if s['plane'] & 0x8000:
            n = [-c for c in n]
        tg = it['texgens'][s['texgen']]
        w = it['windings'][s['winding_start']:s['winding_start'] + s['winding_count']]
        for a, b, c in D.strip_triangles(w):
            V = [pts[a], pts[b], pts[c]]
            uv = [[round(tg[0] * p[0] + tg[1] * p[1] + tg[2] * p[2] + tg[3], 4),
                   round(tg[4] * p[0] + tg[5] * p[1] + tg[6] * p[2] + tg[7], 4)] for p in V]
            for p in V:
                for k in range(3):
                    lo[k] = min(lo[k], p[k])
                    hi[k] = max(hi[k], p[k])
            polys.append({'v': [[round(x, 3) for x in p] for p in V], 'n': [round(x, 5) for x in n],
                          't': 'torque_tri', 'uv': uv,
                          'm': {'kind': 'rgba' if m['texture'] else 'none', 'index': s['texture']}})
    if not polys:
        _shape_ok[sid] = None
        return None
    collision = make_null_surface_polys(it)
    center = [(lo[k] + hi[k]) / 2 for k in range(3)]
    radius = math.sqrt(sum((hi[k] - lo[k]) ** 2 for k in range(3))) / 2
    out = {
        'name': sid, 'texset': 'tribes2_interiors', 'source': 'torque_dif_v%d (%s, detail 0 of %d)' % (
            d['version'], os.path.relpath(path, SRC).replace('\\', '/'), d['num_details']),
        'units': 'metres', 'kind': 'interior', 'collision': 'render_mesh',
        'lods': [{'radius': round(radius, 3), 'center': [round(c, 3) for c in center], 'size': 0, 'name': 'detail0',
                  'pieces': [{'node': 0, 'id': 1000, 'name': base, 'cell': -1, 'state': 0, 'polys': polys,
                              'collision_polys': collision}],
                  'cells': []}],
        'nodes': [{'parent': -1, 'default': 0, 'name': base}],
        'transforms': [[0, 0, 0, 0, 0, 0]],
        'ds_sequences': [],
        'bounds': {'header': [[round(x, 3) for x in lo], [round(x, 3) for x in hi]]},
        'materials': mats,
        'winding_flipped': False,
    }
    write_json(os.path.join(OUT, 'shapes', sid + '.json'), out)
    _shape_ok[sid] = 'tribes2:' + sid
    return _shape_ok[sid]


def make_null_surface_polys(it):
    """The interior's null surfaces (torque_dif) as collision-only triangles {'v': [3 points], 'n'}: never drawn,
    but they close the hull geometry the original collides with (e.g. the floor over the generator pit in
    sbunk2, Katabatic)."""
    pts = it['points']
    out = []
    for s in it['null_surfaces']:
        pl = it['planes'][s['plane'] & 0x7fff]
        n = [-c for c in pl[:3]] if s['plane'] & 0x8000 else list(pl[:3])
        w = it['windings'][s['winding_start']:s['winding_start'] + s['winding_count']]
        for a, b, c in D.strip_triangles(w):
            out.append({'v': [[round(x, 3) for x in pts[k]] for k in (a, b, c)], 'n': [round(x, 5) for x in n]})
    return out


def export_all_interiors():
    """Re-exports every .dif interior shape (shapes/int_*.json) without touching the maps."""
    done = [export_interior(name) for name in sorted(index()) if name.endswith('.dif')]
    print('interiors: %d of %d exported' % (sum(1 for d in done if d), len(done)))
    return 0


def export_dts(name):
    """DTS shape via export_tribes2 (cached); returns shape id or None."""
    if not name:
        return None
    name = os.path.splitext(os.path.basename(name))[0].lower()
    if name in _shape_ok:
        return _shape_ok[name]
    import export_tribes2 as T
    T.SRC, T.OUT = SRC, OUT
    T._index = index() if T._index is None else T._index
    if name + '.dts' not in index():
        _shape_ok[name] = None
        return None
    try:
        if not os.path.exists(os.path.join(OUT, 'shapes', name + '.json')):
            j = T.export_shape(name)
            if not j['lods'] or not j['lods'][0]['pieces']:
                raise ValueError('no geometry')
        _shape_ok[name] = 'tribes2:' + name
    except Exception as e:  # noqa: BLE001 - a shape without geometry or an unsupported (pre-v18) DTS
        print('shape %s: %s: %s' % (name, type(e).__name__, e))
        _shape_ok[name] = None
    return _shape_ok[name]


# ------------------------------------------------------------------ environment

def colour(s, n=3):
    v = vec(s, 4) or vec(s, 3)
    if not v:
        return None
    return [round(max(0.0, min(1.0, c)), 4) for c in v[:n]]


def environment(root, outdir, notes):
    env = {'gravity': 20.0}
    sky = next((o for o in walk(root) if o['class'] == 'Sky'), None)
    sun = next((o for o in walk(root) if o['class'] == 'Sun'), None)
    if sky:
        sc = colour(field(sky, 'SkySolidColor'))
        fc = colour(field(sky, 'fogColor'))
        if sc:
            env['sky_color'] = sc
        if fc:
            env['fog_color'] = fc
            env['horizon_color'] = fc
        vis = float(field(sky, 'visibleDistance', '0') or 0)
        fog = float(field(sky, 'fogDistance', '0') or 0)
        if vis > 0:
            env['fog_start'] = round(min(fog, vis), 2)
            env['fog_end'] = round(vis, 2)
            env['visible_distance'] = round(vis, 2)
        dml = field(sky, 'materialList')
        if dml and field(sky, 'useSkyTextures', '1') != '0':
            p = index().get(dml.lower())
            if p:
                from PIL import Image
                lines = [l.strip() for l in open(p, encoding='latin1').read().split('\n') if l.strip()]
                # Torque sky DML: front(+Y), right(+X), back(-Y), left(-X), top, bottom
                faces = {}
                for k, nm in zip(('front', 'right', 'back', 'left', 'top', 'bottom'), lines[:6]):
                    f = find_image(nm)
                    if f:
                        fn = 'sky_%s.png' % k
                        Image.open(f).convert('RGB').save(os.path.join(outdir, fn))
                        faces[k] = fn
                if len(faces) == 6:
                    # engine cube order +x, -x, +y, -y, +z, -z  (engine -z = Torque +Y = "front")
                    env['skybox'] = [faces['right'], faces['left'], faces['top'], faces['bottom'], faces['back'],
                                     faces['front']]
                    env['skybox_faces'] = faces
                    env['skybox_source'] = dml
                    env['skybox_layout'] = 'torque'    # the pictures untouched; the engine orients them per face
                else:
                    notes.append('sky %s: %d of 6 faces found' % (dml, len(faces)))
    if sun:
        dvec = vec(field(sun, 'direction'))
        if dvec:
            n = math.sqrt(sum(c * c for c in dvec)) or 1
            env['sun_dir'] = [round(c / n, 5) for c in eng_pos(dvec)]
        c = colour(field(sun, 'color'))
        a = colour(field(sun, 'ambient'))
        if c:
            env['sun_color'] = c
        if a:
            env['ambient'] = a
    water = []
    for o in walk(root):
        if o['class'] == 'WaterBlock':
            p = vec(field(o, 'position')) or [0, 0, 0]
            s = vec(field(o, 'scale')) or [1, 1, 1]
            water.append({'level': round(p[2] + s[2], 3), 'bottom': round(p[2], 3),
                          'min': [round(p[0], 3), round(-(p[1] + s[1]), 3)], 'max': [round(p[0] + s[0], 3), round(-p[1], 3)],
                          'type': field(o, 'liquidType'), 'texture': field(o, 'surfaceTexture'),
                          'opacity': float(field(o, 'surfaceOpacity', '1') or 1)})
    if water:
        env['water'] = water
        notes.append('water blocks in environment.water (level = surface height, engine y)')
    prec = [field(o, 'dataBlock') for o in walk(root) if o['class'] == 'Precipitation']
    if prec:
        env['precipitation'] = prec
    return env


# ------------------------------------------------------------------ mission -> map

def area_with_drop_points(area, objs, notes):
    """A single-player mission's terrain also covers its drop points (Training3 starts its player 4 km outside the
    MissionArea, at the Shrike he flies to it): the area grown to hold every object in a DropPoints group."""
    x0, y0, x1, y1 = area[0], area[1], area[0] + area[2], area[1] + area[3]
    grown = False
    for o in objs:
        p = vec(field(o, 'position', ''))
        parent = o['parent']
        if not p or parent is None or not any(re.match(r'droppoints$', (g['name'] or ''), re.I)
                                              for g in (parent, parent.get('parent') or {}) if g):
            continue
        if not (x0 <= p[0] <= x1 and y0 <= p[1] <= y1):
            x0, y0, x1, y1 = min(x0, p[0]), min(y0, p[1]), max(x1, p[0]), max(y1, p[1])
            grown = True
    if grown:
        notes.append('single-player drop points outside the MissionArea: terrain grown to %.0f x %.0f m' % (x1 - x0, y1 - y0))
    return [x0, y0, x1 - x0, y1 - y0]


def export_mission(mis_path, preview=False):
    from collections import Counter
    mid = os.path.splitext(os.path.basename(mis_path))[0]
    text = open(mis_path, encoding='latin1').read()
    header, root = parse_mission(text)
    outdir = os.path.join(OUT, 'maps', mid)
    if os.path.isdir(outdir):
        shutil.rmtree(outdir)
    os.makedirs(outdir, exist_ok=True)
    notes = []
    modes = [m.lower() for m in re.split(r'\s+', header.get('MissionTypes', '').strip()) if m]
    objs = list(walk(root))
    ma = next((o for o in objs if o['class'] == 'MissionArea'), None)
    area = vec(field(ma, 'area', ''), 4) if ma else None
    tb = next((o for o in objs if o['class'] == 'TerrainBlock'), None)
    if not area:
        area = [-1024, -1024, 2048, 2048]
        notes.append('no MissionArea: whole terrain block used')
    if 'singleplayer' in modes:
        area = area_with_drop_points(area, objs, notes)
    terrain, ter = (export_terrain(tb, area, outdir, notes) if tb else (None, None))
    env = environment(root, outdir, notes)

    interiors, statics, spawns, stations = [], [], [], []
    failed_int, failed_shapes, skipped = Counter(), Counter(), Counter()
    for o in objs:
        cls = o['class']
        if cls in ('InteriorInstance',):
            sid = export_interior(field(o, 'interiorFile', ''))
            if not sid:
                failed_int[field(o, 'interiorFile', '?')] += 1
                continue
            pl = placement(o)[0]
            pl.update(shape=sid, collide=True, source=field(o, 'interiorFile'))
            interiors.append(pl)
        elif cls == 'TSStatic':
            sid = export_dts(field(o, 'shapeName'))
            if not sid:
                failed_shapes[field(o, 'shapeName', '?')] += 1
                continue
            pl = placement(o)[0]
            pl.update(shape=sid, collide=True)
            statics.append(pl)
        elif cls == 'SpawnSphere':
            pl = placement(o)[0]
            spawns.append({'kind': 'infantry', 'pos': pl['pos'], 'yaw': pl.get('yaw', 0), 'team': team_of(o),
                           'radius': float(field(o, 'radius', '0') or 0),
                           'weight': float(field(o, 'sphereWeight', '0') or 0),
                           'indoor': float(field(o, 'outdoorWeight', '100') or 0) <= 0})
        elif cls in ('StaticShape', 'Turret', 'Item'):
            dbn = (field(o, 'dataBlock') or '').lower()
            kind = STATION_KINDS.get(dbn)
            if kind is None and dbn.endswith('ammo') and cls == 'Item':
                kind = 'ammo'
            pl = placement(o)[0]
            team = team_of(o)
            if kind:
                sid = export_dts(datablock_shape(dbn))
                st = {'kind': kind, 'shape': sid, 'pos': pl['pos'], 'team': team, 'datablock': field(o, 'dataBlock')}
                for k in ('yaw', 'basis'):
                    if k in pl:
                        st[k] = pl[k]
                if field(o, 'nameTag'):
                    st['name'] = field(o, 'nameTag')
                if cls == 'Turret' and field(o, 'initialBarrel'):
                    st['barrel'] = field(o, 'initialBarrel')
                if sid is None:
                    failed_shapes[datablock_shape(dbn) or dbn] += 1
                stations.append(st)
                if dbn == 'stationvehiclepad':
                    yaw = pl.get('yaw', 0.0)
                    spawns.append({'kind': 'vehicle_pad', 'pos': pl['pos'], 'yaw': yaw, 'team': team})
                    spawns.append({'kind': 'herc', 'pos': pl['pos'], 'yaw': yaw, 'team': team})
            elif dbn in STATIC_DATABLOCKS:
                sid = export_dts(datablock_shape(dbn))
                if sid:
                    pl.update(shape=sid, collide=True)
                    statics.append(pl)
                else:
                    failed_shapes[datablock_shape(dbn) or dbn] += 1
            else:
                skipped[cls + ':' + (field(o, 'dataBlock') or '?')] += 1
        elif cls in ('WheeledVehicle', 'FlyingVehicle', 'HoverVehicle', 'ForceFieldBare'):
            skipped[cls + ':' + (field(o, 'dataBlock') or '?')] += 1

    if failed_int:
        notes.append('interiors not converted: %s' % dict(failed_int))
    if failed_shapes:
        notes.append('shapes not converted (unreadable or missing; placements left out): %s' % dict(failed_shapes))
    if skipped:
        notes.append('objects not exported: %s' % dict(skipped))
    if any(s.get('barrel') for s in stations):
        notes.append('turret barrels (station.barrel) are not mounted on the base shapes')
    notes.append('teams: Team1 -> 0, Team2 -> 1, neutral -> -1; herc spawns = vehicle pads (user rule); '
                 'interior lightmaps not baked; terrain albedo unlit')

    if terrain:
        # how far each spawn sits above the terrain (indoor spheres / pads on structures are not on the ground)
        for sp in spawns:
            th = terrain_height({'terrain': terrain}, outdir, sp['pos'][0], sp['pos'][2])
            if th is not None:
                sp['above_terrain'] = round(sp['pos'][1] - th, 2)
        lifted = [sp for sp in spawns if sp['kind'] == 'herc' and abs(sp.get('above_terrain', 0)) > 3]
        if lifted:
            notes.append('%d vehicle-pad herc spawns are on/in structures (above_terrain %s m), not on the terrain'
                         % (len(lifted), [sp['above_terrain'] for sp in lifted]))
        if any(sp.get('indoor') for sp in spawns):
            notes.append('indoor-only spawn spheres (outdoorWeight 0) are marked "indoor": true')
    ax, ay, aw, ah = area
    spawn_counts = dict(Counter(s['kind'] for s in spawns))
    m = {
        'pack': 'tribes2', 'id': mid, 'name': header.get('DisplayName', mid),
        'source': os.path.relpath(mis_path, SRC).replace('\\', '/'),
        'modes': modes,
        'bounds': {'min': [round(ax, 3), round(-(ay + ah), 3)], 'max': [round(ax + aw, 3), round(-ay, 3)]},
        'flight_ceiling': float(field(ma, 'flightCeiling', '0') or 0) if ma else None,
        'terrain': terrain,
        'environment': env,
        'interiors': interiors,
        'statics': statics,
        'spawns': spawns,
        'stations': stations,
        'notes': '; '.join(notes),
    }
    write_json(os.path.join(outdir, 'map.json'), m, pretty=True)
    entry = {'id': mid, 'name': m['name'], 'modes': modes, 'terrain': terrain is not None, 'spawns': spawn_counts,
             'size_m': [round(aw, 1), round(ah, 1)],
             'interiors': len(interiors), 'interiors_failed': sum(failed_int.values()),
             'statics': len(statics), 'stations': len(stations)}
    if preview:
        entry['check'] = render_preview(m, outdir)
    return entry


# ------------------------------------------------------------------ preview / checks

def terrain_height(m, outdir, x, z):
    t = m['terrain']
    w, h = t['size']
    H = np.fromfile(os.path.join(outdir, t['heights']), '<f4').reshape(h, w)
    fx = (x - t['origin'][0]) / t['square']
    fz = (z - t['origin'][1]) / t['square']
    if not (0 <= fx < w - 1 and 0 <= fz < h - 1):
        return None
    x0, z0 = int(fx), int(fz)
    a = H[z0, x0] * (1 - (fx - x0)) + H[z0, x0 + 1] * (fx - x0)
    b = H[z0 + 1, x0] * (1 - (fx - x0)) + H[z0 + 1, x0 + 1] * (fx - x0)
    return float(a * (1 - (fz - z0)) + b * (fz - z0))


def render_preview(m, outdir):
    from PIL import Image, ImageDraw
    t = m['terrain']
    if not t:
        return {}
    w, h = t['size']
    H = np.fromfile(os.path.join(outdir, t['heights']), '<f4').reshape(h, w)
    alb = Image.open(os.path.join(outdir, t['albedo'])).convert('RGB')
    S = 1024.0 / max(alb.size)
    size = (int(alb.size[0] * S), int(alb.size[1] * S))
    alb = np.asarray(alb.resize(size, Image.BILINEAR), np.float32)
    # hillshade from heights
    gz, gx = np.gradient(H, t['square'])
    sh = np.clip(0.55 + 0.45 * (-gx * 0.7 - gz * 0.7) / np.sqrt(1 + gx * gx + gz * gz), 0.2, 1.2)
    sh = np.asarray(Image.fromarray((sh * 200).astype(np.uint8)).resize(size, Image.BILINEAR), np.float32) / 200
    img = Image.fromarray(np.clip(alb * sh[..., None], 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(img, 'RGBA')
    ppm = size[0] / ((w - 1) * t['square'])          # pixels per metre

    def px(x, z):
        return ((x - t['origin'][0]) * ppm, (z - t['origin'][1]) * ppm)

    b = m['bounds']
    dr.rectangle([px(b['min'][0], b['min'][1]), px(b['max'][0], b['max'][1])], outline=(255, 255, 255, 200), width=2)
    # interiors footprints
    for it in m['interiors']:
        sid = it['shape'].split(':')[1]
        sj = json.load(open(os.path.join(OUT, 'shapes', sid + '.json')))
        if 'basis' in it:
            B = np.array(it['basis'])
        else:
            a = math.radians(it.get('yaw', 0))
            B = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
        sc = it['scale'] if isinstance(it['scale'], (int, float)) else 1.0
        pos = np.array(it['pos'])
        for poly in sj['lods'][0]['pieces'][0]['polys'][::1]:
            if abs(poly['n'][2]) < 0.5:
                continue
            V = np.array([[v[0], v[2], -v[1]] for v in poly['v']]) * sc
            E = V @ B.T + pos
            dr.polygon([px(e[0], e[2]) for e in E], fill=(255, 120, 40, 60))
    cols = {'inventory': (0, 200, 255), 'vehicle': (255, 0, 255), 'generator': (255, 255, 0), 'sensor': (0, 255, 120),
            'turret': (255, 60, 60), 'flag': (255, 255, 255), 'objective': (255, 160, 0), 'repair': (120, 255, 120),
            'ammo': (200, 200, 200)}
    for s in m['stations']:
        x, y = px(s['pos'][0], s['pos'][2])
        c = cols.get(s['kind'], (128, 128, 128))
        dr.rectangle([x - 3, y - 3, x + 3, y + 3], fill=c + (255,), outline=(0, 0, 0, 255))
    check = {'infantry_dz': [], 'herc_dz': []}
    for s in m['spawns']:
        x, y = px(s['pos'][0], s['pos'][2])
        th = terrain_height(m, outdir, s['pos'][0], s['pos'][2])
        if th is not None:
            check['infantry_dz' if s['kind'] == 'infantry' else 'herc_dz'].append(round(s['pos'][1] - th, 1))
        if s['kind'] == 'infantry':
            r = max(4, s.get('radius', 0) * ppm)
            dr.ellipse([x - r, y - r, x + r, y + r], outline=(0, 255, 0, 220), width=2)
            dr.ellipse([x - 4, y - 4, x + 4, y + 4], fill=(0, 255, 0, 255))
        elif s['kind'] == 'herc':
            a = math.radians(s.get('yaw', 0))
            fx, fz = -math.sin(a), -math.cos(a)        # engine forward = -z rotated by yaw
            dr.line([x, y, x + fx * 20, y + fz * 20], fill=(255, 0, 0, 255), width=3)
            dr.ellipse([x - 6, y - 6, x + 6, y + 6], outline=(255, 0, 0, 255), width=3)
    pdir = os.path.join(OUT, 'previews', 'maps')
    os.makedirs(pdir, exist_ok=True)
    img.save(os.path.join(pdir, m['id'] + '.png'))
    return check


# ------------------------------------------------------------------ main

def main():
    if '--interiors' in sys.argv:
        return export_all_interiors()
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    preview = '--preview' in sys.argv
    mdir = os.path.join(SRC, 'missions', 'missions')
    files = sorted(f for f in os.listdir(mdir) if f.lower().endswith('.mis'))
    if args:
        want = {a.lower() for a in args}
        files = [f for f in files if os.path.splitext(f)[0].lower() in want]
    idx_path = os.path.join(OUT, 'maps', '_index.json')
    old = {}
    if args and os.path.exists(idx_path):
        old = {e['id']: e for e in json.load(open(idx_path))}
    ok = 0
    for f in files:
        try:
            e = export_mission(os.path.join(mdir, f), preview)
            old[e['id']] = e
            ok += 1
            print('%-20s spawns %-45s interiors %3d (failed %d) statics %4d stations %3d %s' % (
                e['id'], e['spawns'], e['interiors'], e['interiors_failed'], e['statics'], e['stations'],
                e.get('check', '')))
        except Exception as ex:  # noqa: BLE001 - keep converting the other maps
            traceback.print_exc()
            print('%s: FAILED %s: %s' % (f, type(ex).__name__, ex))
    idx = [{k: v for k, v in e.items() if k != 'check'} for e in sorted(old.values(), key=lambda e: e['id'].lower())]
    write_json(idx_path, idx, pretty=True)
    print('maps: %d of %d converted' % (ok, len(files)))
    if not ok and files:
        return 1


if __name__ == '__main__':
    sys.exit(main())
