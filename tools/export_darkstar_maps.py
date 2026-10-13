"""Darkstar multiplayer maps -> engine map schema (docs/formats/map_schema.md).

    python tools/export_darkstar_maps.py tribes    [mission ...] [--no-preview]
    python tools/export_darkstar_maps.py starsiege [mission ...] [--no-preview]

Tribes (1998): base/missions/<name>.mis (text) + <name>.ted (terrain PVOL) + <name>.vol (mission-lit interior
instances .dis/.dil) + world sets (<w>World palettes/sky, <w>Terrain DML, <w>DML / human1DML bitmaps, interior
geometry .dig), scripts/*.cs (datablock -> shapeFile).
Starsiege (1999): multiplayer/<name>.mis (binary) + <name>.ted.vol + <Planet>.Sim (palette, terrain DML +
tiles) + gameObjects (interiors, DTS shapes).

Output (gamedata/<pack>/):
  maps/<id>/map.json, height.r32 (float32 LE, rows = +z engine = south, cols = +x), albedo.png (baked from the
  terrain tile bitmaps through the world palette, one image across the terrain), preview.png (top-down check)
  sky_panels.png, sky_planet_<n>.png (environment.darkstar_sky, tools/darkstar_sky.py)
  maps/_index.json
  shapes/itr_<interior>.json + textures/itr_<interior>/<material>.png   (interiors, rgba materials)
  shapes/<dts>.json + textures/tribes_<dts>/...                         (static shapes / stations, via
                                                                         tools/export_tribes.py)
Conversions: Darkstar (x east, y north, z up, metres) -> engine (x, z, -y); Euler rotations (radians,
z = counter-clockwise yaw seen from above, verified against floor polygons of rotated bases) -> yaw degrees
(or a basis when pitched/rolled).  Terrain: tools/darkstar_terrain.py; interiors: tools/darkstar_itr.py;
missions: tools/darkstar_mis.py.

Rules applied (project decisions):
  Tribes maps: Herc spawns = vehicle pads (kind "vehicle_pad" + "herc" at the same spot; a team's vehicle
  station when it has no pad); infantry spawns = drop points.
  Starsiege maps: drop points = Herc spawns; for each team spawn area an infantry facility is added on flat
  open ground near the team's spawns: a Tribes inventory station + ammo station ("tribes:inventory_sta",
  "tribes:ammounit", shapes exported by the Tribes import) and 3 infantry spawns (listed in notes).
"""
import json, math, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import siege_paths as P  # noqa: E402
import darkstar_vol as V  # noqa: E402
import darkstar_gfx as G  # noqa: E402
import darkstar_dts as D  # noqa: E402
import darkstar_terrain as T  # noqa: E402
import darkstar_itr as I  # noqa: E402
import darkstar_mis as M  # noqa: E402
import darkstar_sky as DS  # noqa: E402
import darkstar_weather as W  # noqa: E402

GAMES = {
    'tribes': {'missions': ('tribes', 'original', 'Tribes', 'base', 'missions'), 'extracted': ('tribes', 'extracted'),
               'margin': 384.0, 'max_squares': 384, 'px': 4},
    'starsiege': {'missions': ('starsiege', 'original', 'installed', 'multiplayer'),
                  'extracted': ('starsiege', 'extracted'), 'margin': 1024.0, 'max_squares': 320, 'px': 4},
}
INF_STATION = 'tribes:inventory_sta'
AMMO_STATION = 'tribes:ammounit'
TRIBES_ALWAYS = ['inventory_sta', 'ammounit']      # the Starsiege maps reference these


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, separators=(',', ':'))


# ============================================================================================== file system
class VFS:
    """Case-insensitive lookup over the unpacked VOL folders, plus individual VOL files read on demand."""

    def __init__(self, root):
        self.files = {}
        self.vols = {}
        if os.path.isdir(root):
            for d in sorted(os.listdir(root)):
                p = os.path.join(root, d)
                if os.path.isdir(p):
                    for dp, _dn, fs in os.walk(p):
                        for f in fs:
                            self.files.setdefault(f.lower(), os.path.join(dp, f))

    def push_vol(self, path):
        """Entries of this VOL take precedence (mission-lit interior instances)."""
        d, ents = V.read_vol(path)
        layer = {}
        for e in ents:
            if e['name']:
                layer[os.path.basename(e['name'].replace('\\', '/')).lower()] = (d, e)
        self.vols = layer

    def pop_vol(self):
        self.vols = {}

    def get(self, name):
        k = os.path.basename(name.replace('\\', '/')).lower()
        if k in self.vols:
            d, e = self.vols[k]
            return V.file_data(d, e)
        p = self.files.get(k)
        return open(p, 'rb').read() if p else None

    def has(self, name):
        k = os.path.basename(name.replace('\\', '/')).lower()
        return k in self.vols or k in self.files


_ppl_cache = {}


def load_ppl(vfs, name):
    if name not in _ppl_cache:
        d = vfs.get(name)
        _ppl_cache[name] = G.read_ppl(d) if d else None
    return _ppl_cache[name]


def write_world_palettes(pack, pal_name, ppl):
    """Writes palettes/<World>_<d|n|t>_<id>.json for every palette in a world PPL; returns the prefix."""
    prefix = os.path.splitext(os.path.basename(pal_name))[0].replace('.', '_')
    for pal in ppl['palettes']:
        out = P.pack(pack, 'palettes', '%s_%d.json' % (prefix, pal['id']))
        if not os.path.exists(out):
            write_json(out, [list(c) for c in pal['colors']])
    return prefix


def bitmap_rgb(vfs, name, ppl):
    d = vfs.get(name)
    if not d:
        return None
    try:
        b = G.read_pbmp(d)
    except (AssertionError, struct.error, KeyError):
        return None
    if 'pixels' not in b:
        return None
    pal = np.array(G.palette_for(ppl, b['palette_id'])['colors'], np.uint8)
    px = np.frombuffer(b['pixels'], np.uint8).reshape(b['h'], b['w'])
    return pal[px]


# ============================================================================================== shapes
class ShapeExporter:
    def __init__(self, pack, vfs, src_root):
        self.pack, self.vfs, self.src = pack, vfs, src_root
        self.done = {}         # shape id -> info (box/radius) or None when failed
        self.failed = {}

    # ---------------------------------------------------------------- interiors (.dis -> .dig)
    def interior(self, dis_name, ppl):
        """Export the interior referenced by a mission (.dis); returns (shape name, info) or (None, reason)."""
        d = self.vfs.get(dis_name)
        base = re.sub(r'\.\d+\.dis$', '.dis', dis_name, flags=re.I)
        if d is None:
            d = self.vfs.get(base)
        if d is None:
            return None, 'missing ' + dis_name
        ds = I.read_dis(d)
        if not ds['digs']:
            return None, 'no geometry in ' + dis_name
        dig = ds['digs'][0]
        sid = 'itr_' + re.sub(r'-\d+\.dig$', '', dig, flags=re.I).lower()
        if sid in self.done:
            return sid, self.done[sid]
        if sid in self.failed:
            return None, self.failed[sid]
        gd = self.vfs.get(dig)
        if gd is None:
            self.failed[sid] = 'missing ' + dig
            return None, self.failed[sid]
        try:
            g = I.read_dig(gd)
        except (ValueError, struct.error) as e:
            self.failed[sid] = '%s: %s' % (dig, e)
            return None, self.failed[sid]
        dml = ds['dml'] or (os.path.splitext(base)[0] + '.dml')
        mats = []
        md = self.vfs.get(dml)
        if md:
            ml = D.read_shape(md)['material_list']
            mats = ml['materials'][:ml['count']]
        from PIL import Image
        tdir = os.path.join(P.pack(self.pack), 'textures', sid)
        os.makedirs(tdir, exist_ok=True)
        materials, sizes = [], []
        for i, m in enumerate(mats):
            img = bitmap_rgb(self.vfs, m['file'], ppl) if m['file'] else None
            if img is None:
                materials.append({'name': m['file'], 'texture': None, 'flags': 0, 'w': 0, 'h': 0, 'rgb': m['rgb']})
                sizes.append(None)
                continue
            Image.fromarray(img, 'RGB').save(os.path.join(tdir, '%d.png' % i))
            materials.append({'name': m['file'], 'texture': 'textures/%s/%d.png' % (sid, i), 'flags': 0,
                              'w': int(img.shape[1]), 'h': int(img.shape[0])})
            sizes.append((img.shape[1], img.shape[0]))
        polys = []
        for q in I.polygons(g):
            n = [-c for c in q['normal']]          # loops wind clockwise seen from the visible side
            mi = q['material']
            sz = sizes[mi] if mi < len(sizes) else None
            poly = {'v': [[round(c, 4) for c in p] for p in q['pts']], 'n': [round(c, 5) for c in n],
                    't': 'darkstar_itr'}
            if sz:
                us = [t[0] / sz[0] for t in q['texel']]
                vs = [t[1] / sz[1] for t in q['texel']]
                du, dv = math.floor(min(us)), math.floor(min(vs))
                poly['uv'] = [[round(u - du, 4), round(v - dv, 4)] for u, v in zip(us, vs)]
                poly['m'] = {'kind': 'rgba', 'index': mi}
            else:
                poly['m'] = {'kind': 'none', 'index': mi}
            polys.append(poly)
        box = list(g['box'])
        c = [(box[i] + box[i + 3]) / 2 for i in range(3)]
        r = math.sqrt(sum(((box[i + 3] - box[i]) / 2) ** 2 for i in range(3)))
        shape = {
            'name': sid, 'texset': None, 'source': 'darkstar_itr_v%d %s' % (g['version'], dig), 'units': 'metres',
            'lods': [{'radius': r, 'center': c, 'size': 0, 'root': 0, 'cells': [],
                      'pieces': [{'node': 0, 'id': 1000, 'name': sid, 'cell': -1, 'state': 0, 'polys': polys}]}],
            'nodes': [{'parent': -1, 'default': 0, 'name': 'root'}], 'transforms': [[0, 0, 0, 0, 0, 0]],
            'materials': materials, 'bounds': {'header': [box[:3], box[3:]], 'collision_box': None},
            'interior': {'dis': dis_name, 'dig': dig, 'texture_scale': g['texture_scale'], 'surfaces': len(polys)},
        }
        write_json(os.path.join(P.pack(self.pack), 'shapes', sid + '.json'), shape)
        info = {'box': box, 'polys': len(polys)}
        self.done[sid] = info
        return sid, info

    # ---------------------------------------------------------------- DTS (via export_tribes)
    def dts(self, name, ppl_rel):
        """Export <name>.dts into this pack with tools/export_tribes.export_shape; returns (id, info)."""
        name = os.path.splitext(name)[0]
        sid = name.lower()
        if sid in self.done:
            return sid, self.done[sid]
        if sid in self.failed:
            return None, self.failed[sid]
        import export_tribes as ET
        saved = (ET.SRC, ET.OUT, ET.WORLD_PPL)
        ET.SRC, ET.OUT, ET.WORLD_PPL = self.src, P.pack(self.pack), ppl_rel
        try:
            if not ET.find_file(name + '.dts'):
                raise FileNotFoundError(name + '.dts')
            ppl = G.read_ppl(open(os.path.join(self.src, *ppl_rel), 'rb').read())
            j = ET.export_shape(name, ppl)
            # export_tribes names the file after the argument; keep ids lower-case for map references
            if name != sid:
                src = os.path.join(P.pack(self.pack), 'shapes', name + '.json')
                if os.path.exists(src):
                    os.replace(src, os.path.join(P.pack(self.pack), 'shapes', sid + '.json'))
            info = {'radius': j['lods'][0]['radius'] if j['lods'] else 1.0,
                    'center': j['lods'][0]['center'] if j['lods'] else [0, 0, 0],
                    'box': (j['bounds']['header'][0] + j['bounds']['header'][1]) if j['bounds'].get('header') else None}
            self.done[sid] = info
            return sid, info
        except Exception as e:  # noqa: BLE001 - a broken prop must not stop the map
            self.failed[sid] = '%s.dts: %s: %s' % (name, type(e).__name__, e)
            return None, self.failed[sid]
        finally:
            ET.SRC, ET.OUT, ET.WORLD_PPL = saved


# ============================================================================================== terrain
class Terrain:
    def __init__(self, ted_path):
        self.gfil, self.ted = T.load_ted(ted_path)
        g = self.gfil
        self.sq = g['square']
        self.map = np.array(g['map']).reshape(g['map_h'], g['map_w'])
        self.blocks = {k: T.block(self.ted, k) for k in self.ted[1]}
        self.n = next(iter(self.blocks.values()))['w']
        self.pos = (0.0, 0.0)

    def sample_grid(self, gx0, gy0, w, h):
        """Heights (h+1, w+1) and material (h, w) [index, flags] for grid squares starting at (gx0, gy0) in
        terrain grid coordinates (wrapping around the block map like the game does)."""
        n, mh, mw = self.n, self.map.shape[0], self.map.shape[1]
        gy = np.arange(gy0, gy0 + h + 1)
        gx = np.arange(gx0, gx0 + w + 1)
        H = np.zeros((h + 1, w + 1), np.float32)
        MI = np.zeros((h, w), np.uint8)
        MF = np.zeros((h, w), np.uint8)
        by_all, ly_all = np.divmod(gy, n)
        bx_all, lx_all = np.divmod(gx, n)
        for yi in range(h + 1):
            by, ly = by_all[yi] % mh, ly_all[yi]
            ids = self.map[by, bx_all % mw]
            for bid in np.unique(ids):
                sel = ids == bid
                blk = self.blocks[int(bid)]
                H[yi, sel] = blk['heights'][ly, lx_all[sel]]
                if yi < h:
                    s2 = sel[:w]
                    MI[yi, s2] = blk['mat_index'][ly, lx_all[:w][s2]]
                    MF[yi, s2] = blk['mat_flags'][ly, lx_all[:w][s2]]
        return H, MI, MF

    def height(self, x, y):
        """Bilinear terrain height at world (x, y)."""
        fx = (x - self.pos[0]) / self.sq
        fy = (y - self.pos[1]) / self.sq
        x0, y0 = math.floor(fx), math.floor(fy)
        tx, ty = fx - x0, fy - y0
        h = self._h
        return float((h(x0, y0) * (1 - tx) + h(x0 + 1, y0) * tx) * (1 - ty) +
                     (h(x0, y0 + 1) * (1 - tx) + h(x0 + 1, y0 + 1) * tx) * ty)

    def _h(self, gx, gy):
        by, ly = divmod(gy, self.n)
        bx, lx = divmod(gx, self.n)
        bid = int(self.map[by % self.map.shape[0], bx % self.map.shape[1]])
        return self.blocks[bid]['heights'][ly, lx]


def bake_albedo(vfs, dml_name, ppl, MI, MF, px):
    """One RGB image, px pixels per square, row 0 = first grid row (the caller flips to north-up)."""
    md = vfs.get(dml_name)
    ml = D.read_shape(md)['material_list'] if md else {'materials': [], 'count': 0}
    mats = ml['materials'][:ml['count']]
    from PIL import Image
    tiles = {}

    def tile(i):
        if i not in tiles:
            img = bitmap_rgb(vfs, mats[i]['file'], ppl) if i < len(mats) and mats[i]['file'] else None
            if img is None:
                tiles[i] = np.full((px, px, 3), 110, np.uint8)
            else:
                tiles[i] = np.asarray(Image.fromarray(img).resize((px, px), Image.BOX))
        return tiles[i]

    h, w = MI.shape
    out = np.zeros((h * px, w * px, 3), np.uint8)
    for y in range(h):
        for x in range(w):
            t = tile(int(MI[y, x]))
            f = int(MF[y, x])
            if f & 1:
                t = np.rot90(t)
            if f & 2:
                t = t[:, ::-1]
            if f & 4:
                t = t[::-1]
            # bitmap rows run top-down = toward -y in the grid; the grid's row index runs +y
            out[y * px:(y + 1) * px, x * px:(x + 1) * px] = t[::-1]
    return out


# ============================================================================================== helpers
def eng(p):
    return [round(float(p[0]), 3), round(float(p[2]), 3), round(-float(p[1]), 3)]


def orient(rot):
    """Darkstar Euler (rx, ry, rz radians) -> engine placement fields."""
    rx, ry, rz = (rot or [0, 0, 0])[:3]
    yaw = round((math.degrees(rz) + 180.0) % 360.0 - 180.0, 3)
    if abs(rx) < 1e-3 and abs(ry) < 1e-3:
        return {'yaw': yaw}
    cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    R = Rz @ Rx @ Ry
    C = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]])
    B = C @ R @ C.T
    return {'yaw': yaw, 'basis': [[round(float(v), 5) for v in row] for row in B]}


def yaw_of_matrix(m):
    """DPNT matrix (rows = rotated axes, row-vector convention) -> yaw degrees (ccw from above)."""
    return round(math.degrees(math.atan2(m[0][1], m[0][0])), 3)


def parse_datablocks(vfs, script_dir):
    """Tribes scripts: datablock name (lower) -> (type, shapeFile)."""
    out = {}
    if not os.path.isdir(script_dir):
        return out
    for f in os.listdir(script_dir):
        if not f.lower().endswith('.cs'):
            continue
        txt = open(os.path.join(script_dir, f), encoding='latin-1').read()
        for m in re.finditer(r'^\s*(\w+Data)\s+(\w+)\s*\{(.*?)\n\s*\};', txt, re.S | re.M):
            sm = re.search(r'shapeFile\s*=\s*"([^"]+)"', m.group(3))
            out[m.group(2).lower()] = (m.group(1), sm.group(1) if sm else None)
    return out


def obb_contains(o, x, y, margin):
    """o: {'pos', 'yaw' (deg), 'box' (min xyz, max xyz) local}; 2-D containment with margin."""
    th = math.radians(o['yaw'])
    dx, dy = x - o['pos'][0], y - o['pos'][1]
    lx = math.cos(th) * dx + math.sin(th) * dy
    ly = -math.sin(th) * dx + math.cos(th) * dy
    b = o['box']
    return b[0] - margin < lx < b[3] + margin and b[1] - margin < ly < b[4] + margin


# ============================================================================================== Tribes
TRIBES_STATION = {
    'inventorystation': 'inventory', 'ammostation': 'ammo', 'vehiclestation': 'vehicle', 'vehiclepad': 'vehicle',
    'generator': 'generator', 'portgenerator': 'generator', 'solarpanel': 'generator',
    'pulsesensor': 'sensor', 'mediumpulsesensor': 'sensor', 'deployablepulsesensor': 'sensor',
    'commandstation': 'command', 'towerswitch': 'objective', 'flag': 'flag',
}
TRIBES_MODES = {'capture the flag': ['ctf'], 'capture and hold': ['ch'], 'deathmatch': ['dm'],
                'defend and destroy': ['dd'], 'find and retrieve': ['fr'], 'multiple team': ['ctf', 'mt']}


def tribes_missions(mdir, training=False):
    """The multiplayer missions, or (training) the training missions <n>_*.mis."""
    out = []
    for f in sorted(os.listdir(mdir)):
        if f.lower().endswith('.mis') and bool(re.match(r'\d_', f)) == training:
            out.append(f)
    return out


def export_tribes_map(fn, ctx):
    mdir, vfs, shapes = ctx['mdir'], ctx['vfs'], ctx['shapes']
    mid = os.path.splitext(fn)[0]
    notes = []
    root = M.parse_text(open(os.path.join(mdir, fn), encoding='latin-1').read())
    mtype = ''
    dsc = [f for f in os.listdir(mdir) if f.lower() == mid.lower() + '.dsc']
    if dsc:
        m = re.search(r'\$MDESC::Type\s*=\s*"([^"]+)"', open(os.path.join(mdir, dsc[0]), encoding='latin-1').read())
        mtype = m.group(1) if m else ''
    vol = [f for f in os.listdir(mdir) if f.lower() == mid.lower() + '.vol']
    if vol:
        vfs.push_vol(os.path.join(mdir, vol[0]))
    ted = [f for f in os.listdir(mdir) if f.lower() == mid.lower() + '.ted']
    try:
        objs = list(M.walk(root))
        F = lambda cls: [o for o, _ in objs if o['class'] == cls]  # noqa: E731
        palette = (F('SimPalette') or [{'fields': {}}])[0]['fields'].get('fileName', 'lush.day.ppl')
        ppl = load_ppl(vfs, palette) or load_ppl(vfs, 'lush.day.ppl')
        ter_o = F('SimTerrain')[0]['fields'] if F('SimTerrain') else {}
        terrain = Terrain(os.path.join(mdir, ted[0])) if ted else None
        tpos = M.vec(ter_o.get('position', '0 0 0'))
        if terrain:
            terrain.pos = (tpos[0], tpos[1])

        # ------------------------------------------------ objects
        interiors, statics, spawns, stations, foot = [], [], [], [], []
        pads_by_team, vstations = {}, []
        for o, path in objs:
            f = o['fields']
            team = -1
            for a in path:
                m = re.match(r'team(\d+)$', a['name'], re.I)
                if a['class'] == 'TeamGroup' and m:
                    team = int(m.group(1))
            pos = M.vec(f.get('position', '')) if 'position' in f else None
            rot = M.vec(f.get('rotation', '0 0 0')) or [0, 0, 0]
            if o['class'] == 'InteriorShape' and pos:
                sid, info = shapes.interior(f.get('fileName', ''), ppl)
                if not sid:
                    notes.append('interior %s left out (%s)' % (f.get('fileName'), info))
                    continue
                interiors.append(dict({'shape': 'tribes:' + sid, 'pos': eng(pos), 'scale': 1, 'collide': True},
                                      **orient(rot)))
                foot.append({'pos': pos, 'yaw': math.degrees(rot[2]), 'box': info['box']})
                continue
            db = f.get('dataBlock', '').lower()
            if not pos or not db:
                continue
            if o['class'] == 'Marker':
                if db == 'droppointmarker':
                    spawns.append(dict({'kind': 'infantry', 'pos': eng(pos), 'team': team}, **orient(rot)))
                continue
            if o['class'] == 'Item' and db != 'flag':
                continue                                   # weapons/ammo/packs lying around
            dtype, shape_file = ctx['datablocks'].get(db, (None, None))
            sid = None
            if shape_file:
                sid, info = shapes.dts(shape_file, ctx['ppl_rel'])
                if not sid:
                    notes.append('shape %s (%s) left out: %s' % (shape_file, db, info))
            kind = TRIBES_STATION.get(db)
            if o['class'] == 'Turret':
                kind = 'turret'
            ent = dict({'pos': eng(pos)}, **orient(rot))
            if kind:
                st = dict({'kind': kind, 'shape': ('tribes:' + sid) if sid else '', 'team': team,
                           'datablock': f.get('dataBlock')}, **ent)
                stations.append(st)
                if db == 'vehiclepad':
                    pads_by_team.setdefault(team, []).append(ent)
                elif db == 'vehiclestation':
                    vstations.append((team, ent))
            elif sid:
                collide = not (o['class'] == 'Moveable' and ('door' in db or 'force' in db)) and 'forcefield' not in db
                statics.append(dict({'shape': 'tribes:' + sid, 'scale': 1, 'collide': collide}, **ent))
        # Herc spawns: vehicle pads (or a team's vehicle station when it has no pad)
        for team, pads in pads_by_team.items():
            for e in pads:
                for k in ('vehicle_pad', 'herc'):
                    spawns.append(dict({'kind': k, 'team': team}, **e))
        for team, e in vstations:
            if team not in pads_by_team:
                for k in ('vehicle_pad', 'herc'):
                    spawns.append(dict({'kind': k, 'team': team}, **e))
                notes.append('team %d has a vehicle station but no pad: Herc spawn at the station' % team)
        if not pads_by_team and not vstations:
            notes.append('no vehicle pads/stations: no Herc spawns (engine falls back to the drop points)')

        # ------------------------------------------------ bounds + terrain
        mc = (F('MissionCenterPos') or [None])[0]
        pts = [(s['pos'][0], -s['pos'][2]) for s in spawns + stations + interiors]
        if mc:
            x0, y0 = float(mc['fields'].get('x', 0)), float(mc['fields'].get('y', 0))
            w, h = float(mc['fields'].get('w', 0)), float(mc['fields'].get('h', 0))
            far = [p for p in pts if not (x0 - 1000 < p[0] < x0 + w + 1000 and y0 - 1000 < p[1] < y0 + h + 1000)]
            if far:
                notes.append('%d objects far outside the mission area ignored for the terrain extent' % len(far))
            pts = [p for p in pts if p not in far] + [(x0, y0), (x0 + w, y0 + h)]
        bmin = [min(p[0] for p in pts), min(p[1] for p in pts)]
        bmax = [max(p[0] for p in pts), max(p[1] for p in pts)]
        terr = None
        if terrain:
            terr, extra = write_terrain(ctx, mid, terrain, bmin, bmax, ppl)
            notes += extra
        env = tribes_environment(F, vfs, ppl, ter_o, P.pack('tribes', 'maps', mid))
        m = {
            'pack': 'tribes', 'id': mid, 'name': re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', mid).replace('_', ' '),
            'source': 'base/missions/' + fn, 'modes': TRIBES_MODES.get(mtype.lower(), ['dm']),
            'mission_type': mtype,
            'bounds': {'min': [round(bmin[0], 1), round(-bmax[1], 1)], 'max': [round(bmax[0], 1), round(-bmin[1], 1)]},
            'terrain': terr, 'environment': env,
            'interiors': interiors, 'statics': statics, 'spawns': spawns, 'stations': stations,
            'notes': '; '.join(dict.fromkeys(notes)),
        }
        return m, terrain, foot
    finally:
        vfs.pop_vol()


def tribes_environment(F, vfs, ppl, ter, out_dir):
    env = {}
    haze = tuple(G.palette_for(ppl, 0xFFFFFFFF)['colors'][ppl['haze_colour'] & 255]) if ppl else (150, 150, 160)
    env['horizon_color'] = list(haze)
    env['fog_color'] = list(haze)
    env['darkstar_sky'] = DS.tribes_sky(F, vfs.get, ppl, ter, out_dir)
    env['sky_color'] = env['darkstar_sky']['top_color']
    env['fog_start'] = float(ter.get('hazeDistance', 200) or 200)
    env['fog_end'] = float(ter.get('visibleDistance', 450) or 450)
    pl = F('Planet')
    if pl:
        f = pl[0]['fields']
        env.update(sun_from(float(f.get('azimuth', 0)), float(f.get('incidence', 45)), M.vec(f.get('intensity', '0.6 0.6 0.6')),
                            M.vec(f.get('ambient', '0.4 0.4 0.4'))))
    g = M.vec(ter.get('contGravity', '0 0 -20'))
    env['gravity'] = abs(g[2]) if g else 20.0
    weather = next((w for w in (W.tribes_weather(o['fields']) for o in F('Snowfall')) if w), None)
    if weather:
        env['weather'] = weather
    return env


def sun_from(az, inc, intensity, ambient):
    """Darkstar Planet: azimuth (deg, from north toward WEST), incidence (elevation, deg) -> light direction
    (tools/darkstar_sky.py make_planet_dir, tribes.exe 0x4777c4)."""
    to_sun = DS.make_planet_dir(az, inc)                                           # engine frame
    return {'sun_dir': [round(-c, 4) for c in to_sun],                             # sun -> ground
            'sun_color': [int(min(255, 255 * c)) for c in (intensity or [0.6] * 3)],
            'ambient': [int(min(255, 255 * c)) for c in (ambient or [0.4] * 3)],
            'sun_azimuth': az, 'sun_incidence': inc}


# ============================================================================================== terrain output
def write_terrain(ctx, mid, terrain, bmin, bmax, ppl):
    cfg, vfs = ctx['cfg'], ctx['vfs']
    sq = terrain.sq
    margin = cfg['margin']
    gx0 = math.floor((bmin[0] - margin - terrain.pos[0]) / sq)
    gy0 = math.floor((bmin[1] - margin - terrain.pos[1]) / sq)
    gx1 = math.ceil((bmax[0] + margin - terrain.pos[0]) / sq)
    gy1 = math.ceil((bmax[1] + margin - terrain.pos[1]) / sq)
    notes = []
    w, h = gx1 - gx0, gy1 - gy0
    mx = cfg['max_squares']
    if w > mx:
        c = (gx0 + gx1) // 2
        gx0, w = c - mx // 2, mx
        notes.append('terrain clipped to %d squares east-west' % mx)
    if h > mx:
        c = (gy0 + gy1) // 2
        gy0, h = c - mx // 2, mx
        notes.append('terrain clipped to %d squares north-south' % mx)
    H, MI, MF = terrain.sample_grid(gx0, gy0, w, h)
    out = os.path.join(P.pack(ctx['pack']), 'maps', mid)
    os.makedirs(out, exist_ok=True)
    # engine rows = +z = south: flip the grid (row 0 = north)
    np.ascontiguousarray(H[::-1]).astype('<f4').tofile(os.path.join(out, 'height.r32'))
    img = bake_albedo(vfs, terrain.gfil['dml'], ppl, MI, MF, cfg['px'])
    from PIL import Image
    Image.fromarray(np.ascontiguousarray(img[::-1])).save(os.path.join(out, 'albedo.png'), optimize=True)
    x_west = terrain.pos[0] + gx0 * sq
    y_north = terrain.pos[1] + (gy0 + h) * sq
    t = {'heights': 'height.r32', 'size': [w + 1, h + 1], 'square': sq, 'origin': [x_west, -y_north],
         'height_scale': 1.0, 'albedo': 'albedo.png', 'albedo_repeat': 1.0}
    holes = (MF & 0x08) != 0
    if holes.any():
        # Darkstar "empty" squares: openings in the terrain above underground interiors (base entrances)
        Image.fromarray(np.ascontiguousarray(holes[::-1]).astype(np.uint8) * 255, 'L').save(os.path.join(out, 'holes.png'))
        t['holes'] = 'holes.png'
        notes.append('terrain has %d hole squares (holes.png, 1 px per square, rows = +z): base entrances into '
                     'interiors below the terrain surface' % int(holes.sum()))
    t.update({
         'source': {'dtf': terrain.gfil['dml'], 'scale_shift': terrain.gfil['scale_shift'],
                    'block_map': [terrain.map.shape[1], terrain.map.shape[0]], 'grid_origin': [gx0, gy0],
                    'wraps': True}})
    return t, notes


# ============================================================================================== Starsiege
SS_TEAMS = {1: 'red', 2: 'blue', 3: 'yellow', 4: 'purple'}


def ss_team_of(path, name=''):
    for a in list(path)[::-1] + [{'name': name}]:
        n = a.get('name', '').lower()
        for k, c in SS_TEAMS.items():
            if c in n:
                return k
    return None


def ss_missions(mdir):
    return sorted(f for f in os.listdir(mdir) if f.lower().endswith('.mis'))


def export_starsiege_map(fn, ctx):
    mdir, vfs, shapes = ctx['mdir'], ctx['vfs'], ctx['shapes']
    mid = os.path.splitext(fn)[0]
    notes = []
    root = M.parse_binary(open(os.path.join(mdir, fn), 'rb').read())
    objs = list(M.walk(root))
    F = lambda cls: [o for o, _ in objs if o['class'] == cls]  # noqa: E731
    pal_name = (F('ESpt') or [{'fields': {}}])[0]['fields'].get('file') or 'Mars.d.ppl'
    ppl = load_ppl(vfs, pal_name) or load_ppl(vfs, 'Mars.d.ppl')
    if not load_ppl(vfs, pal_name):
        pal_name = 'Mars.d.ppl'
    # Darkstar draws indexed shape skins through the current world's palette: export this world's
    # palettes (<World>_d_<PiDX id>) so the engine can swap Mars_d_* (the exported default) for them
    world_palette = write_world_palettes(ctx['pack'], pal_name, ppl)
    ster = F('STER')[0]['fields'] if F('STER') else {}
    ted = [f for f in os.listdir(mdir) if f.lower() == mid.lower() + '.ted.vol']
    terrain = Terrain(os.path.join(mdir, ted[0])) if ted else None
    if terrain:
        terrain.pos = tuple(ster.get('position', [0, 0])[:2])
    interiors, statics, spawns, stations, foot = [], [], [], [], []
    colors = set()
    raw_spawns = []
    for o, path in objs:
        f = o['fields']
        cls = o['class']
        if cls == 'ESDP':
            continue
        if cls == 'DPNT':
            grp = path[-1]['name'] if path else ''
            m = re.match(r'DropPointGroup(\d*)$', grp, re.I)
            col = int(m.group(1)) if m and m.group(1) else 0
            if col:
                colors.add(col)
            raw_spawns.append((col, f))
            continue
        pos = f.get('position')
        if not pos or f.get('_error'):
            continue
        rot = f.get('rotation', [0, 0, 0])
        if cls == '0x10c':
            sid, info = shapes.interior(f.get('file') or '', ppl)
            if not sid:
                notes.append('interior %s left out (%s)' % (f.get('file'), info))
                continue
            e = dict({'shape': 'starsiege:' + sid, 'pos': eng(pos), 'scale': 1, 'collide': True}, **orient(rot))
            interiors.append(e)
            foot.append({'pos': pos, 'yaw': math.degrees(rot[2]), 'box': info['box']})
            low = (f.get('file') or '').lower()
            kind = 'repair' if ('heal' in low or 'zen' in low) else 'ammo' if 'ammo' in low else None
            if kind:
                stations.append(dict({'kind': kind, 'shape': '', 'team': ss_team_of(path, o['name']),
                                      'source': 'Herc %s pad %s' % (kind, f.get('file'))}, **orient(rot), pos=eng(pos)))
            continue
        if cls in ('0x100', 'TRRT') and f.get('file'):
            sid, info = shapes.dts(f['file'], ctx['ppl_rel'])
            if not sid:
                notes.append('shape %s left out: %s' % (f['file'], info))
                continue
            low = f['file'].lower()
            ent = dict({'pos': eng(pos)}, **orient(rot))
            team = ss_team_of(path, o['name'])
            m = re.match(r'team(\d)\.dts$', low)
            if m:
                team = int(m.group(1))
            if team:
                colors.add(team)
            kind = 'turret' if cls == 'TRRT' else 'flag' if m else \
                'generator' if ('generator' in o['name'].lower() or re.match(r'x\w+_dark', low)) else None
            if kind:
                stations.append(dict({'kind': kind, 'shape': 'starsiege:' + sid, 'team': team}, **ent))
            else:
                statics.append(dict({'shape': 'starsiege:' + sid, 'scale': 1, 'collide': True}, **ent))
            r = (info or {}).get('radius') or 4.0
            foot.append({'pos': pos, 'yaw': 0.0, 'box': [-r, -r, 0, r, r, 0]})
    # teams: Starsiege colours -> engine team numbers 0.. in colour order; group 0 = any team
    order = sorted(colors)
    tnum = {c: i for i, c in enumerate(order)}
    for s in stations:
        t = s.get('team')
        s['team'] = tnum.get(t, -1) if t else -1
    for col, f in raw_spawns:
        spawns.append({'kind': 'herc', 'pos': eng(f['position']), 'yaw': yaw_of_matrix(f['matrix']),
                       'team': tnum.get(col, -1) if col else -1})
    # extent: the drop points, plus every object within 1.5 km of them (some maps scatter decoration
    # rocks/drop pods 10 km out; those stay in the lists but do not grow the terrain)
    sp = [(s['pos'][0], -s['pos'][2]) for s in spawns] or [(0.0, 0.0)]
    lo = [min(p[0] for p in sp) - 1500, min(p[1] for p in sp) - 1500]
    hi = [max(p[0] for p in sp) + 1500, max(p[1] for p in sp) + 1500]
    pts = sp + [(e['pos'][0], -e['pos'][2]) for e in stations + interiors + statics
                if lo[0] < e['pos'][0] < hi[0] and lo[1] < -e['pos'][2] < hi[1]]
    nfar = len(stations + interiors + statics) - (len(pts) - len(sp))
    if nfar:
        notes.append('%d objects more than 1.5 km from the spawn area ignored for the terrain extent' % nfar)
    bmin = [min(p[0] for p in pts), min(p[1] for p in pts)]
    bmax = [max(p[0] for p in pts), max(p[1] for p in pts)]
    terr = None
    if terrain:
        terr, extra = write_terrain(ctx, mid, terrain, bmin, bmax, ppl)
        notes += extra
    # ------------------------------------------------ added infantry facilities
    added = add_infantry(spawns, stations, foot, terrain, bmin, bmax)
    if added:
        notes.append('ADDED (not in the original): ' + '; '.join(added))
    env = {}
    haze = tuple(G.palette_for(ppl, 0xFFFFFFFF)['colors'][ppl['haze_colour'] & 255]) if ppl else (150, 150, 160)
    env.update({'horizon_color': list(haze), 'fog_color': list(haze), 'sky_color': list(haze),
                'fog_start': float(ster.get('hazeDistance', 700)), 'fog_end': float(ster.get('visibleDistance', 1500))})
    pl = F('SKPL')
    if pl and not pl[0]['fields'].get('_error'):
        p = pl[0]['fields']
        env.update(sun_from(p.get('azimuth', 0), p.get('incidence', 45), p.get('intensity'), p.get('ambient')))
    sky = DS.starsiege_sky(F, vfs.get, ppl, P.pack('starsiege', 'maps', mid))
    if sky:
        env['darkstar_sky'] = sky
        env['sky_color'] = sky['top_color']
    g = ster.get('gravity')
    env['gravity'] = round(abs(g[2]), 3) if g else None
    weather = next((w for w in (W.starsiege_weather(o['fields'].get('_raw')) for o in F('SNOW')) if w), None)
    if weather:
        env['weather'] = weather
    mode = mid.split('_')[0].lower()
    modes = {'ctf': ['ctf'], 'dm': ['dm'], 'war': ['war', 'tdm'], 'starsiege': ['football']}.get(mode, ['dm'])
    m = {
        'pack': 'starsiege', 'id': mid, 'name': ' '.join(mid.split('_')[1:]) if mode in ('ctf', 'dm', 'war') else mid.replace('_', ' '),
        'source': 'multiplayer/' + fn, 'modes': modes,
        'bounds': {'min': [round(bmin[0], 1), round(-bmax[1], 1)], 'max': [round(bmax[0], 1), round(-bmin[1], 1)]},
        'world_palette': world_palette,
        'terrain': terr, 'environment': env, 'interiors': interiors, 'statics': statics, 'spawns': spawns,
        'stations': stations, 'teams': {tnum[c]: SS_TEAMS[c] for c in order},
        'notes': '; '.join(dict.fromkeys(notes)),
    }
    return m, terrain, foot


def add_infantry(spawns, stations, foot, terrain, bmin, bmax):
    """Per team spawn area (Herc drop points; DM: clusters of them) place a Tribes inventory + ammo station and
    3 infantry spawns on flat open ground close to the spawns. Returns note strings."""
    if not terrain:
        return []
    herc = [s for s in spawns if s['kind'] == 'herc']
    areas = []
    teams = sorted({s['team'] for s in herc})
    for t in teams:
        pts = [(s['pos'][0], -s['pos'][2]) for s in herc if s['team'] == t]
        if t >= 0:
            areas.append((t, pts))
        elif len(teams) == 1:            # neutral drop points only matter when the map has no team groups
            # free-for-all: greedy clusters of drop points within 600 m, at most 4 areas
            rest = list(pts)
            while rest and len(areas) < 4:
                c = rest[0]
                grp = [p for p in rest if math.hypot(p[0] - c[0], p[1] - c[1]) < 600]
                rest = [p for p in rest if p not in grp]
                areas.append((-1, grp))
    notes = []
    taken = []
    for team, pts in areas:
        # anchor: the drop point nearest the area's centroid (spawns are in the open part of a base)
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        ax, ay = min(pts, key=lambda p: (p[0] - cx) ** 2 + (p[1] - cy) ** 2)
        best = None
        for r in range(12, 260, 6):
            n = max(8, int(2 * math.pi * r / 10))
            for k in range(n):
                a = 2 * math.pi * k / n
                x, y = ax + r * math.cos(a), ay + r * math.sin(a)
                if site_ok(x, y, foot, herc, taken, terrain, 14.0):
                    # the ammo station 8 m to the side must fit too
                    bx, by = x + 8 * math.cos(a + math.pi / 2), y + 8 * math.sin(a + math.pi / 2)
                    if site_ok(bx, by, foot, herc, taken, terrain, 8.0):
                        best = (x, y, bx, by, a)
                        break
            if best:
                break
        if not best:
            notes.append('team %d: no flat open site found for infantry facilities' % team)
            continue
        x, y, bx, by, a = best
        # Darkstar shapes face +y; yaw so that +y points back toward the spawn anchor
        yaw = (math.degrees(a + math.pi) - 90.0 + 180.0) % 360.0 - 180.0
        zi, za = terrain.height(x, y), terrain.height(bx, by)
        stations.append({'kind': 'inventory', 'shape': INF_STATION, 'pos': eng((x, y, zi)), 'yaw': round(yaw, 1),
                         'team': team, 'added': True})
        stations.append({'kind': 'ammo', 'shape': AMMO_STATION, 'pos': eng((bx, by, za)), 'yaw': round(yaw, 1),
                         'team': team, 'added': True})
        taken += [(x, y), (bx, by)]
        sp = []
        for k in range(3):
            aa = a + math.radians(-50 + 50 * k)
            for d in (14.0, 18.0, 22.0):
                sx, sy = x + d * math.cos(aa), y + d * math.sin(aa)
                if site_ok(sx, sy, foot, [], taken, terrain, 3.0, slope=1.5):
                    spawns.append({'kind': 'infantry', 'pos': eng((sx, sy, terrain.height(sx, sy))),
                                   'yaw': round(yaw, 1), 'team': team, 'added': True})
                    taken.append((sx, sy))
                    sp.append((round(sx), round(sy)))
                    break
        notes.append('team %d: inventory+ammo station at (%d, %d) and %d infantry spawns (Darkstar x,y)'
                     % (team, round(x), round(y), len(sp)))
    return notes


def site_ok(x, y, foot, herc, taken, terrain, clear, slope=0.8):
    for o in foot:
        if obb_contains(o, x, y, clear):
            return False
    for s in herc:
        if math.hypot(s['pos'][0] - x, -s['pos'][2] - y) < 15.0:
            return False
    for t in taken:
        if math.hypot(t[0] - x, t[1] - y) < 6.0:
            return False
    h0 = terrain.height(x, y)
    for dx, dy in ((4, 0), (-4, 0), (0, 4), (0, -4), (3, 3), (-3, -3), (3, -3), (-3, 3)):
        if abs(terrain.height(x + dx, y + dy) - h0) > slope:
            return False
    return True


# ============================================================================================== preview + checks
def preview(path, m, terrain_ctx, foot_shapes):
    """Top-down map: albedo x hillshade, interior footprints, markers. Returns check dict."""
    from PIL import Image, ImageDraw
    out = os.path.dirname(path)
    t = m['terrain']
    if not t:
        return {}
    w, h = t['size']
    H = np.fromfile(os.path.join(out, t['heights']), '<f4').reshape(h, w)
    alb = np.asarray(Image.open(os.path.join(out, t['albedo'])).convert('RGB').resize((w - 1, h - 1)), np.float32)
    gy, gx = np.gradient(H[:-1, :-1], t['square'])
    shade = np.clip(0.75 + 0.6 * (-gx * 0.5 - gy * 0.5) / np.sqrt(1 + gx ** 2 + gy ** 2), 0.35, 1.25)
    img = np.clip(alb * shade[:, :, None], 0, 255).astype(np.uint8)
    if t.get('holes'):
        hm = np.asarray(Image.open(os.path.join(out, t['holes']))) > 0
        img[hm] = (20, 0, 30)
    S = max(1, int(900 // max(w, h)))
    im = Image.fromarray(img).resize(((w - 1) * S, (h - 1) * S), Image.NEAREST)
    dr = ImageDraw.Draw(im)
    x0, z0, sq = t['origin'][0], t['origin'][1], t['square']

    def px(p):
        return ((p[0] - x0) / sq * S, (p[2] - z0) / sq * S)

    def hgt(p):
        fx, fz = (p[0] - x0) / sq, (p[2] - z0) / sq
        if not (0 <= fx < w - 1 and 0 <= fz < h - 1):
            return None
        i, j = int(fx), int(fz)
        tx, tz = fx - i, fz - j
        return float((H[j, i] * (1 - tx) + H[j, i + 1] * tx) * (1 - tz) + (H[j + 1, i] * (1 - tx) + H[j + 1, i + 1] * tx) * tz)

    for e in m['interiors']:
        sid = e['shape'].split(':')[1]
        box = (foot_shapes.get(sid) or {}).get('box')
        if not box:
            continue
        th = math.radians(e.get('yaw', 0))
        pts = []
        for lx, ly in ((box[0], box[1]), (box[3], box[1]), (box[3], box[4]), (box[0], box[4])):
            wx = e['pos'][0] + math.cos(th) * lx - math.sin(th) * ly
            wy = -e['pos'][2] + math.sin(th) * lx + math.cos(th) * ly
            pts.append(px((wx, 0, -wy)))
        dr.polygon(pts, outline=(255, 255, 255))
    colors = {'herc': (255, 40, 40), 'vehicle_pad': (255, 140, 0), 'infantry': (40, 120, 255)}
    scol = {'inventory': (0, 255, 0), 'ammo': (255, 255, 0), 'flag': (255, 0, 255), 'vehicle': (255, 140, 0),
            'generator': (0, 255, 255), 'turret': (160, 160, 160)}
    checks = {'spawns': 0, 'spawn_below_ground': 0, 'spawn_high_above': 0, 'station_in_interior': 0, 'off_map': 0}
    for s in m['spawns']:
        x, y = px(s['pos'])
        r = 2 + S
        dr.ellipse((x - r, y - r, x + r, y + r), fill=colors.get(s['kind'], (255, 255, 255)),
                   outline=(255, 255, 255) if s.get('added') else (0, 0, 0))
        g = hgt(s['pos'])
        checks['spawns'] += 1
        if g is None:
            checks['off_map'] += 1
        elif s['pos'][1] < g - 1.0:
            checks['spawn_below_ground'] += 1
        elif s['pos'][1] > g + 60:
            checks['spawn_high_above'] += 1
    for s in m['stations']:
        x, y = px(s['pos'])
        r = 2 + S
        dr.rectangle((x - r, y - r, x + r, y + r), fill=scol.get(s['kind'], (200, 200, 200)),
                     outline=(255, 255, 255) if s.get('added') else (0, 0, 0))
        if s.get('added'):
            for e in m['interiors']:
                box = (foot_shapes.get(e['shape'].split(':')[1]) or {}).get('box')
                if box and obb_contains({'pos': (e['pos'][0], -e['pos'][2]), 'yaw': e.get('yaw', 0), 'box': box},
                                        s['pos'][0], -s['pos'][2], 0):
                    checks['station_in_interior'] += 1
    dr.text((4, 4), '%s:%s  %dx%d m  N up' % (m['pack'], m['id'], (w - 1) * sq, (h - 1) * sq), fill=(255, 255, 255))
    im.save(path)
    return checks


# ============================================================================================== main
def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args or args[0] not in GAMES:
        print(__doc__)
        return 2
    pack = args[0]
    cfg = GAMES[pack]
    # --training: the Tribes training missions' maps, played by the mission runtime (not arena maps: left out
    # of maps/_index.json)
    training = '--training' in sys.argv
    mdir = P.work(*cfg['missions'])
    src = P.work(*cfg['extracted'])
    vfs = VFS(src)
    ctx = {'pack': pack, 'cfg': cfg, 'mdir': mdir, 'vfs': vfs, 'shapes': ShapeExporter(pack, vfs, src)}
    if pack == 'tribes':
        ctx['datablocks'] = parse_datablocks(vfs, os.path.join(src, 'scripts'))
        ctx['ppl_rel'] = ('lushWorld', 'lush.day.ppl')
        missions = tribes_missions(mdir, training)
        fn_export = export_tribes_map
        for n in TRIBES_ALWAYS:
            sid, info = ctx['shapes'].dts(n, ctx['ppl_rel'])
            print('station shape', n, 'ok' if sid else info)
    else:
        ctx['ppl_rel'] = ('Mars.Sim', 'Mars.d.ppl')
        missions = ss_missions(mdir)
        fn_export = export_starsiege_map
    want = {a.lower() for a in args[1:]}
    if want:
        missions = [f for f in missions if os.path.splitext(f)[0].lower() in want]
    idx_path = P.pack(pack, 'maps', '_index.json')
    # merge: other exporters (e.g. campaign missions) may share maps/; replace only the maps exported here
    index = {e['id']: e for e in json.load(open(idx_path))} if os.path.exists(idx_path) else {}
    report = []
    for fn in missions:
        mid = os.path.splitext(fn)[0]
        try:
            m, terrain, foot = fn_export(fn, ctx)
        except Exception as e:  # noqa: BLE001 - report and continue with the next map
            import traceback
            traceback.print_exc()
            report.append((mid, 'failed', '%s: %s' % (type(e).__name__, e)))
            continue
        out = P.pack(pack, 'maps', mid)
        write_json(os.path.join(out, 'map.json'), m)
        checks = {}
        if '--no-preview' not in sys.argv:
            checks = preview(os.path.join(out, 'preview.png'), m, None, ctx['shapes'].done)
            m.setdefault('checks', checks)
            write_json(os.path.join(out, 'map.json'), m)
        cnt = {}
        for s in m['spawns']:
            cnt[s['kind']] = cnt.get(s['kind'], 0) + 1
        t = m['terrain']
        size = [round((t['size'][0] - 1) * t['square']), round((t['size'][1] - 1) * t['square'])] if t else \
            [round(m['bounds']['max'][0] - m['bounds']['min'][0]), round(m['bounds']['max'][1] - m['bounds']['min'][1])]
        if not training:
            index[mid] = {'id': mid, 'name': m['name'], 'modes': m['modes'], 'terrain': bool(t), 'spawns': cnt,
                          'size_m': size}
        left_out = m['notes'].count('left out')
        status = 'full' if not left_out else 'partial'
        report.append((mid, status, 'interiors %d statics %d stations %d spawns %s %s%s' % (
            len(m['interiors']), len(m['statics']), len(m['stations']), cnt,
            ('left out %d; ' % left_out) if left_out else '', checks)))
        print('%-28s %-8s %s' % report[-1], flush=True)
    write_json(idx_path, sorted(index.values(), key=lambda e: e['id'].lower()))
    print('\n%d maps: %d full, %d partial, %d failed' % (len(report), sum(r[1] == 'full' for r in report),
                                                       sum(r[1] == 'partial' for r in report),
                                                       sum(r[1] == 'failed' for r in report)))
    sh = ctx['shapes']
    print('shapes exported: %d, failed: %d' % (len(sh.done), len(sh.failed)))
    for k, v in sh.failed.items():
        print('  failed shape', k, v)
    return 0


if __name__ == '__main__':
    sys.exit(main())
