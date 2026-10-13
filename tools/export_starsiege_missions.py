"""Starsiege campaigns (Human + Cybrid) -> engine mission/campaign data in gamedata/starsiege/.

Inputs (siege_paths work tree):
  starsiege/original/installed/campaign/Human, campaign/Cybrid (Advanced), training   (.mis + .cs)
  starsiege/extracted/scripts       (scripts.vol: *.Strings.cs, missionStdLib.cs, DatPilot_*.cs, *_planet_init.cs,
                                     datVehicle.cs)
  starsiege/extracted/ted/<M>.ted   (mission terrain, decoded by tools/starsiege_terrain.py when available)

Outputs:
  campaigns/human.json, campaigns/cybrid.json   order, start vehicle, player team, chapters/cut-scenes
  missions/<ID>.json                             resolved mission (see docs/formats/starsiege.md section 8)
  missions/<ID>.cs                               the original mission script (run by the GDScript VM)
  scripts/                                       missionStdLib.cs, DatPilot_*.cs, *_planet_init.cs, strings.json
  maps/<ID>/map.json (+ height.r32, albedo.png)  engine map schema (terrain + environment) per mission
  missions/_index.json

Coordinates in the mission JSON are ENGINE frame (metres, y up, Godot -z = original north):
original Z-up (x, y, z) -> (x, z, -y); yaw (radians) = original rotation about +z (counter-clockwise from
+y), which equals the Godot yaw of Basis(Vector3.UP, yaw) facing -z.

Usage: python tools/export_starsiege_missions.py [--no-terrain] [--no-interiors] [mission ...]
  --no-terrain    keep the terrain of the previous export (objects, interiors and camera paths only)
"""
import glob
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import starsiege_mis as SM  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
INST = os.path.join(ROOT, 'starsiege', 'original', 'installed')
SCR = os.path.join(ROOT, 'starsiege', 'extracted', 'scripts')
TED = os.path.join(ROOT, 'starsiege', 'extracted', 'ted')
SRC_ROOT = os.path.join(ROOT, 'starsiege', 'extracted')
OUT = os.path.join(ROOT, 'gamedata', 'starsiege')

CAMPAIGNS = {'human': 'campaign/Human', 'cybrid': 'campaign/Cybrid (Advanced)'}
COPY_SCRIPTS = ['missionStdLib.cs', 'DatPilot_hu.cs', 'DatPilot_cy.cs', 'hu_planet_init.cs', 'cy_planet_init.cs',
                'datFormation.cs']


# ------------------------------------------------------------------ strings / script declarations

def _unescape(s):
    return (s.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace("\\'", "'")
            .replace('\\\\', '\\'))


_STR = r'"((?:[^"\\]|\\.)*)"'


def load_string_tags():
    """All *.Strings.cs tags by number: {301712: 'IDWEA_TUR_HATC'} (the .mis stores tag numbers)."""
    out = {}
    for f in sorted(glob.glob(os.path.join(SCR, '*.[Ss]trings.cs'))):
        for m in re.finditer(r'^\s*(ID\w+)\s*=\s*(\d+)\s*,', open(f, encoding='latin1').read(), re.M):
            out.setdefault(int(m.group(2)), m.group(1))
    return out


def load_strings():
    """All *.Strings.cs tags: TAG = number, "text" [@ "more" ...];  -> {TAG: text}."""
    out = {}
    for f in sorted(glob.glob(os.path.join(SCR, '*.[Ss]trings.cs'))):
        txt = open(f, encoding='latin1').read()
        for m in re.finditer(r'^\s*(ID\w+)\s*=\s*(\d+)\s*,\s*((?:' + _STR + r'\s*(?:@\s*)?)+);', txt, re.M):
            parts = re.findall(_STR, m.group(3))
            out[m.group(1)] = _unescape(''.join(parts))
    return out


def _strip_comments(txt):
    out = []
    for ln in txt.splitlines():
        res, q, i = '', False, 0
        while i < len(ln):
            c = ln[i]
            if c == '"' and (i == 0 or ln[i - 1] != '\\'):
                q = not q
            if not q and (ln.startswith('//', i) or c == '#'):
                break
            res += c
            i += 1
        out.append(res)
    return '\n'.join(out)


def declarations(txt, S):
    """`Type name { field = value; ... };` blocks -> [(type, name, {field: value})] with *TAG resolved."""
    txt = _strip_comments(txt)
    res = []
    for m in re.finditer(r'^\s*([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*\{([^{}]*)\}\s*;', txt, re.M):
        fields = {}
        for fm in re.finditer(r'([A-Za-z_]\w*)\s*=\s*([^;]*);', m.group(3)):
            v = fm.group(2).strip()
            if v.startswith('*'):
                v = S.get(v[1:].strip(), v[1:].strip())
            elif v.startswith('"'):
                v = _unescape(''.join(re.findall(_STR, v)))
            else:
                try:
                    v = float(v) if '.' in v else int(v)
                except ValueError:
                    v = {'true': True, 'false': False}.get(v.lower(), v)
            fields[fm.group(1)] = v
        res.append((m.group(1), m.group(2), fields))
    return res


# ------------------------------------------------------------------ vehicles

def vehicle_table():
    """datVehicle.cs: buildHerc(1, "H", "datHerc_tr_apoc.cs") -> {1: {kind, dat, shape}} (+ ids.json if exported)."""
    out = {}
    p = os.path.join(SCR, 'datVehicle.cs')
    if os.path.exists(p):
        for m in re.finditer(r'build(Herc|Tank|Drone|Flyer)\s*\(\s*(\d+)\s*,(?:\s*"[^"]*"\s*,)?\s*"([^"]+)"',
                             _strip_comments(open(p, encoding='latin1').read())):
            kind, vid, dat = m.group(1).lower(), int(m.group(2)), m.group(3)
            shape = None
            dp = os.path.join(SCR, dat)
            if os.path.exists(dp):
                sm = re.search(r'"([\w.]+)\.dts"', open(dp, encoding='latin1').read(), re.I)
                if sm:
                    shape = sm.group(1).lower()
            out[vid] = {'kind': kind, 'dat': dat, 'shape': shape}
    ids = _load_json(os.path.join(OUT, 'gameplay', 'ids.json'))
    if isinstance(ids, dict):
        for k, key in ids.get('vehicles', {}).items():
            out.setdefault(int(k), {})['key'] = key
    return out


_HARDPOINT = re.compile(r'newHardPoint(?:Ext)?\s*\(([^)]*)\)')
_FUNCTION = re.compile(r'function\s+(\w+)\s*\(\s*\)\s*\{([^}]*)\}')


def _turret_hardpoint(args):
    """newHardPoint(id, size, side, parent node, x, y, z (m, on the parent node), pitch min, max, yaw min,
    max (degrees; datTurret.cs column headers X_rot_rnge / Z_rot_rnge))."""
    a = [s.strip() for s in args.split(',')]
    nums = [float(v) for v in a[4:11]]
    return {'id': int(a[0]), 'size': a[1], 'side': a[2], 'node': a[3], 'offset': nums[0:3],
            'pitch_deg': nums[3:5], 'yaw_deg': nums[5:7]}


def turret_table():
    """datTurret.cs -> {type id: {shape, activate_range, turn_rate, check_interval, hardpoints}}.
    turretBase(tag, shape, hulk, radar cross-section, activateDist, turretVel, checkFreq, teamId, numHardpts, ?)
    (the two header rows of the table interleave); hardpoints may come from a shared function (humanLaser())."""
    p = os.path.join(SCR, 'datTurret.cs')
    if not os.path.exists(p):
        return {}
    txt = _strip_comments(open(p, encoding='latin1').read())
    funcs = {name.lower(): body for name, body in _FUNCTION.findall(txt)}
    txt = _FUNCTION.sub('', txt)
    out = {}
    for block in re.split(r'(?=\bnewTurret\s*\()', txt)[1:]:
        tid = int(re.match(r'newTurret\s*\(\s*(\d+)', block).group(1))
        base = re.search(r'turretBase\s*\(([^)]*)\)', block)
        if not base:
            continue
        a = [s.strip().strip('"') for s in base.group(1).split(',')]
        shared = ''.join(funcs.get(c.lower(), '') for c in re.findall(r'\b(\w+)\s*\(\s*\)\s*;', block))
        out[tid] = {'tag': a[0], 'shape': a[1].lower(), 'activate_range': float(a[4]), 'turn_rate': float(a[5]),
                    'check_interval': float(a[6]),
                    'hardpoints': [_turret_hardpoint(m) for m in _HARDPOINT.findall(block + shared)]}
    return out


def turret_fields(n, turrets, tags):
    """Mission fields of a TRRT record: its datTurret.cs type, the weapons and AI settings stored in the record
    (record velocity / activation distance override the type's turretVel / activateDist when set)."""
    ttype = n.get('turret_type')
    if not ttype:
        return {'turret_type': None, 'turret_weapons': []}
    names = [tags.get(t, '') for t in n.get('weapon_tags', [])]
    weapons = ['starsiege:%s' % s[len('IDWEA_'):] if s.startswith('IDWEA_') else None for s in names]
    t = turrets.get(ttype, {})
    return {'turret_type': ttype, 'turret_weapons': weapons, 'turret_range': n.get('range'),
            'turret_velocity': n.get('turret_velocity'), 'skill': n.get('skill'),
            'target_period': n.get('target_period'), 'turret_ai': n.get('turret_ai', {}),
            'activate_range': t.get('activate_range'), 'turn_rate': t.get('turn_rate'),
            'check_interval': t.get('check_interval'), 'hardpoints': t.get('hardpoints', [])}


DAMAGE_FIELDS = ('hit_points', 'current_damage', 'indestructible', 'damage_flags', 'fire_threshold', 'burn_rate',
                 'explosion_tag')


def damage_fields(n):
    """SimShape damage block and fire block of a static / turret record (original damage units)."""
    return {k: n[k] for k in DAMAGE_FIELDS if k in n}


def weapon_names():
    ids = _load_json(os.path.join(OUT, 'gameplay', 'ids.json'))
    return {int(k): v for k, v in ids.get('weapons', {}).items()} if isinstance(ids, dict) else {}


def _load_json(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------------ conversion

def eng(p):
    """original Z-up metres -> engine (x, y up, z = -north)."""
    return [round(p[0], 3), round(p[2], 3), round(-p[1], 3)]


def _planet_of(root):
    for _p, n in SM.walk(root):
        if n.get('kind') == 'volume' and n['file'].lower().endswith('.sim.vol'):
            return n['file'][:-8]
    return None


class InteriorShapes:
    """Exports the campaign interiors (.dis -> shapes/itr_<name>.json) with the multiplayer-map exporter's
    Darkstar interior decoder (tools/export_darkstar_maps.py ShapeExporter, tools/darkstar_itr.py)."""

    def __init__(self):
        import export_darkstar_maps as DM
        self.dm = DM
        self.vfs = DM.VFS(SRC_ROOT)
        self.shapes = DM.ShapeExporter('starsiege', self.vfs, SRC_ROOT)

    def export(self, dis_name, palette):
        """(shape id, info) or (None, reason)."""
        ppl = self.dm.load_ppl(self.vfs, palette or DEFAULT_PALETTE) or self.dm.load_ppl(self.vfs, DEFAULT_PALETTE)
        return self.shapes.interior(dis_name or '', ppl)

    def placement(self, n):
        """Map-schema orientation fields of an interior record (yaw degrees, basis when tilted)."""
        return self.dm.orient(n.get('rot_xyz'))


DEFAULT_PALETTE = 'Mars.d.ppl'
WORLD_KINDS = ('terrain', 'sky', 'planet', 'starfield', 'snow', 'palette', 'volume')


def make_lookups(with_interiors):
    return {'vt': vehicle_table(), 'wn': weapon_names(), 'turrets': turret_table(), 'tags': load_string_tags(),
            'interiors': InteriorShapes() if with_interiors else None}


def _vehicle_fields(n, lk):
    v = lk['vt'].get(n['vehicle_id'], {})
    wn = lk['wn']
    return {'vehicle_id': n['vehicle_id'], 'vehicle': 'starsiege:%s' % v['key'] if v.get('key') else None,
            'vehicle_kind': v.get('kind'), 'vehicle_shape': v.get('shape'), 'team': n['team'],
            'script': n['script'], 'weapon_ids': n['weapons'],
            'weapons': ['starsiege:%s' % wn[w] if w in wn else None for w in n['weapons']],
            'mountables': n['mountables'], 'pilot': n['pilot'], 'skin': n['skin']}


def _interior_fields(n, lk, palette, map_interiors, notes):
    """Exports the interior shape and lists it for the map (placed with collision by MapBuilder)."""
    o = {'shape_file': n['shape'], 'shape': None}
    if lk['interiors'] is None or 'pos' not in n:
        return o
    sid, info = lk['interiors'].export(n['shape'], palette)
    if not sid:
        notes.append('interior %s left out (%s)' % (n['shape'], info))
        return o
    o['shape'] = 'starsiege:' + sid
    o['in_map'] = True
    map_interiors.append(dict({'shape': o['shape'], 'pos': eng(n['pos']), 'scale': 1, 'collide': True},
                              **lk['interiors'].placement(n)))
    return o


def _camera_waypoint(n):
    r = n['rot']
    return {'pos': eng(n['pos']), 'forward': eng(r[3:6]), 'up': eng(r[6:9]), 'speed': n['speed']}


def convert_objects(root, lk, palette):
    """Mission objects in the engine frame; also the drop points, nav markers, world records, camera paths
    and the map interiors (map.json "interiors")."""
    objs, drops, navs, world = [], [], [], {}
    extra = {'camera_paths': {}, 'map_interiors': [], 'notes': []}
    for path, n in SM.walk(root):
        k = n.get('kind')
        if k in ('group', 'unknown', 'error', 'camera_path', None):
            continue
        if k in WORLD_KINDS:
            world.setdefault(k, []).append(n)
            continue
        if k == 'camera_waypoint':
            group = path.rsplit('/', 1)[0]
            cp = extra['camera_paths'].setdefault(group.rsplit('/', 1)[-1].lower(), {'path': group, 'waypoints': []})
            cp['waypoints'].append(_camera_waypoint(n))
            continue
        o = {'path': path, 'name': n.get('name', ''), 'kind': k}
        if 'pos' in n:
            o.update({'pos': eng(n['pos']), 'pos_orig': n['pos'], 'yaw': n.get('yaw', 0.0)})
        if k == 'drop_point':
            drops.append(o)
            continue
        if k == 'nav_marker':
            navs.append(o)
        if k in ('herc', 'tank', 'flyer'):
            o.update(_vehicle_fields(n, lk))
        elif k in ('static', 'turret'):
            o.update({'shape': 'starsiege:%s' % os.path.splitext(n['shape'])[0].lower(), 'shape_file': n['shape'],
                      'team': n.get('team') or 'neutral', 'script': n.get('script', '')})
            o.update(damage_fields(n))
            if k == 'turret':
                o.update(turret_fields(n, lk['turrets'], lk['tags']))
        elif k == 'interior':
            o.update(_interior_fields(n, lk, palette, extra['map_interiors'], extra['notes']))
        elif k == 'trigger':
            o.update({'script': n['script'], 'box_min': n['box_min'], 'box_max': n['box_max'], 'rate': n['rate']})
        objs.append(o)
    return objs, drops, navs, world, extra


def _palette_of(root):
    for _p, n in SM.walk(root):
        if n.get('kind') == 'palette':
            return n['file']
    return None


def terrain_dir(dtf):
    base = os.path.basename(dtf).lower()
    stem = base[:-len('.ted.dtf')] if base.endswith('.ted.dtf') else os.path.splitext(base)[0]
    if os.path.isdir(TED):
        for d in os.listdir(TED):
            if d.lower() == stem + '.ted':
                return os.path.join(TED, d)
    return None


def apply_world_palette(env, pal):
    """Exports the world PPL's palettes (shared with tools/export_darkstar_maps.py) and sets haze colours."""
    if not pal:
        return None
    import glob
    import darkstar_gfx as G
    import export_darkstar_maps as DM
    hits = glob.glob(os.path.join(SRC_ROOT, '*', pal)) if os.path.isdir(SRC_ROOT) else []
    if not hits:
        return None
    ppl = G.read_ppl(open(hits[0], 'rb').read())
    haze = list(G.palette_for(ppl, 0xFFFFFFFF)['colors'][ppl['haze_colour'] & 255])
    env.update({'horizon_color': haze, 'fog_color': haze, 'sky_color': haze, 'fog_start': 700.0, 'fog_end': 1500.0})
    return DM.write_world_palettes('starsiege', pal, ppl)


## Darkstar terrain material flag of an "empty" square: an opening above an interior below the surface
## (HA0's mole tunnel); the same bit tools/export_darkstar_maps.py writes for the multiplayer maps.
HOLE_FLAG = 0x08


def export_terrain_holes(T, tdir, out_dir, terrain):
    """holes.png (map schema: 1 px per square, rows = +z, 255 = hole) when the terrain has empty squares."""
    import numpy as np
    from PIL import Image
    holes = (T.load_terrain(tdir)['mat_flags'] & HOLE_FLAG) != 0
    if not holes.any():
        return []
    Image.fromarray(np.ascontiguousarray(holes[::-1]).astype(np.uint8) * 255, 'L').save(
        os.path.join(out_dir, 'holes.png'))
    terrain['holes'] = 'holes.png'
    return ['terrain has %d hole squares (holes.png): openings into interiors below the surface' % int(holes.sum())]


def _previous_terrain(out_dir):
    """The terrain block of an earlier export (--no-terrain re-exports objects only)."""
    old = _load_json(os.path.join(out_dir, 'map.json'))
    return old.get('terrain') if isinstance(old, dict) else None


def export_map(mid, ster, planet, world, out_dir, do_terrain, extra):
    env = {'gravity': abs(ster.get('gravity') or 9.8) if ster else 9.8, 'palette': None}
    pal = world.get('palette', [{}])[0].get('file') if world.get('palette') else None
    if pal:
        env['palette'] = pal
    world_palette = apply_world_palette(env, pal)
    import darkstar_sky as DS
    env.update(DS.starsiege_mission_sky(extra['mis_path'], pal, out_dir))   # sky panels, planets, stars
    weather = next((w['weather'] for w in world.get('snow', []) if w.get('weather')), None)
    if weather:
        env['weather'] = weather
    m = {'pack': 'starsiege', 'id': mid, 'name': mid, 'source': 'campaign .mis STER/SVol (%s)' % (ster or {}).get('file'),
         'modes': ['mission'], 'terrain': None, 'environment': env, 'interiors': [], 'statics': [], 'spawns': [],
         'stations': [], 'notes': ''}
    if world_palette:
        m['world_palette'] = world_palette
    notes = []
    tdir = terrain_dir(ster['file']) if ster else None
    if do_terrain and tdir:
        try:
            import starsiege_terrain as T
            os.makedirs(out_dir, exist_ok=True)
            m['terrain'] = T.export_map_terrain(tdir, out_dir, planet, origin_xy=tuple(ster['origin']))
            notes += export_terrain_holes(T, tdir, out_dir, m['terrain'])
        except ImportError:
            notes.append('terrain decoder (tools/starsiege_terrain.py) not available: flat ground')
        except Exception as e:  # noqa: BLE001
            notes.append('terrain export failed: %s: %s' % (type(e).__name__, e))
    elif not tdir:
        notes.append('no terrain volume found for %s' % (ster or {}).get('file'))
    else:
        m['terrain'] = _previous_terrain(out_dir)
    m['interiors'] = extra['map_interiors']
    notes += extra['notes']
    if m['terrain']:
        t = m['terrain']
        x0, z0 = t['origin']
        w, h = t['size'][0] * t['square'], t['size'][1] * t['square']
        m['bounds'] = {'min': [x0, z0], 'max': [x0 + w, z0 + h]}
    notes.append('interiors are placed from this file; vehicles, structures and turrets by the mission runtime '
                 'from missions/%s.json' % mid)
    m['notes'] = '; '.join(notes)
    os.makedirs(out_dir, exist_ok=True)
    json.dump(m, open(os.path.join(out_dir, 'map.json'), 'w'), indent=1)
    return m


def export_mission(campaign, mis_path, cs_path, S, lk, index, do_terrain):
    mid = os.path.splitext(os.path.basename(mis_path))[0].upper()
    root = SM.read_mis(mis_path)
    objs, drops, navs, world, extra = convert_objects(root, lk, _palette_of(root))
    ster = world.get('terrain', [None])[0]
    planet = _planet_of(root)
    cs = open(cs_path, encoding='latin1').read() if cs_path else ''
    decl = declarations(cs, S) if cs else []
    brief = next((f for t, _n, f in decl if t == 'MissionBriefInfo'), {})
    objectives = [{'object': n, 'primary': bool(f.get('isPrimary', True)), 'status': f.get('status'),
                   'short': f.get('shortTxt'), 'long': f.get('longTxt'), 'bmp': f.get('bmpname')}
                  for t, n, f in decl if t == 'MissionBriefObjective']
    pilots = {n: f for t, n, f in decl if t == 'Pilot'}
    music = re.findall(r'cdAudioCycle\s*\(([^)]*)\)', _strip_comments(cs))
    nxt = brief.get('nextMission')
    mdir = os.path.join(OUT, 'maps', mid)
    extra['mis_path'] = mis_path
    mp = export_map(mid, ster, planet, world, mdir, do_terrain, extra)
    team_count = {}
    for o in objs:
        if 'team' in o:
            team_count[o['team']] = team_count.get(o['team'], 0) + 1
    m = {
        'pack': 'starsiege', 'id': mid, 'campaign': campaign, 'index': index,
        'cinematic': mid.upper().startswith('CIN'),
        'source': os.path.relpath(mis_path, INST).replace(os.sep, '/'),
        'title': brief.get('title', mid), 'planet': brief.get('planet', planet), 'planet_set': planet,
        'location': brief.get('location'), 'campaign_name': brief.get('campaign'), 'date': brief.get('dateOnMissionEnd'),
        'short_brief': brief.get('shortDesc'), 'long_brief': brief.get('longDescRichText'),
        'debrief_success': brief.get('successDescRichText'), 'debrief_fail': brief.get('failDescRichText'),
        'media': brief.get('media'), 'end_cinematic': brief.get('endCinematicSmk'), 'sound_vol': brief.get('soundvol'),
        'next': nxt.upper() if isinstance(nxt, str) and nxt else None,
        'objectives': objectives, 'pilots': pilots, 'music': music,
        'map': 'starsiege:%s' % mid, 'terrain_file': ster['file'] if ster else None,
        'terrain_origin_orig': ster['origin'] if ster else None, 'has_terrain': bool(mp.get('terrain')),
        'environment': mp['environment'],
        'player': {'team': 'yellow', 'drop_points': [d['path'] for d in drops]},
        'drop_points': drops, 'nav_markers': navs, 'objects': objs, 'team_counts': team_count,
        'camera_paths': extra['camera_paths'],
        'script': 'missions/%s.cs' % mid if cs_path else None,
    }
    if cs_path:
        shutil.copyfile(cs_path, os.path.join(OUT, 'missions', mid + '.cs'))
    json.dump(m, open(os.path.join(OUT, 'missions', mid + '.json'), 'w'), indent=1)
    return m


def _find(d, stem, exts):
    for f in os.listdir(d):
        b, e = os.path.splitext(f)
        if b.lower() == stem.lower() and e.lower() in exts:
            return os.path.join(d, f)
    return None


def campaign_order(d, S):
    """campaign.cs curMission, then each mission's nextMission (literal or *IDSTR_<M>_NEXTMISSION)."""
    cc = open(os.path.join(d, 'campaign.cs'), encoding='latin1').read()
    info = next((f for t, _n, f in declarations(cc, S) if t == 'Campaign'), {})
    order, cur = [], info.get('curMission')
    while cur and cur.upper() not in order and len(order) < 60:
        order.append(cur.upper())
        cs = _find(d, cur, ('.cs',))
        nxt = None
        if cs:
            b = next((f for t, _n, f in declarations(open(cs, encoding='latin1').read(), S) if t == 'MissionBriefInfo'), {})
            nxt = b.get('nextMission')
        cur = nxt
    return info, order


def inventory_calls(fname):
    p = os.path.join(SCR, fname)
    out = []
    if not os.path.exists(p):
        return out
    for m in re.finditer(r'\b(Inventory\w+)\s*\(([^()]*)\)\s*;', _strip_comments(open(p, encoding='latin1').read()), re.I):
        args = [a.strip() for a in m.group(2).split(',')]
        out.append([m.group(1)] + [int(a) if re.fullmatch(r'-?\d+', a) else a for a in args])
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    do_terrain = '--no-terrain' not in sys.argv
    S = load_strings()
    lk = make_lookups('--no-interiors' not in sys.argv)
    vt = lk['vt']
    for sub in ('missions', 'campaigns', 'scripts', 'maps'):
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
    json.dump(S, open(os.path.join(OUT, 'scripts', 'strings.json'), 'w'), indent=0)
    for f in COPY_SCRIPTS:
        if os.path.exists(os.path.join(SCR, f)):
            shutil.copyfile(os.path.join(SCR, f), os.path.join(OUT, 'scripts', f))
    index = []
    for camp, rel in CAMPAIGNS.items():
        d = os.path.join(INST, *rel.split('/'))
        info, order = campaign_order(d, S)
        shutil.copyfile(os.path.join(d, 'campaign.cs'), os.path.join(OUT, 'scripts', 'campaign_%s.cs' % camp))
        cins = sorted({os.path.splitext(f)[0].upper() for f in os.listdir(d)
                       if f.lower().startswith('cin') and f.lower().endswith(('.mis', '.rec'))})
        missions = []
        for i, mid in enumerate(order):
            if args and mid not in [a.upper() for a in args]:
                continue
            mis = _find(d, mid, ('.mis',))
            cs = _find(d, mid, ('.cs',))
            if not mis:
                print('missing .mis for', mid)
                continue
            m = export_mission(camp, mis, cs, S, lk, i, do_terrain)
            missions.append(m)
            nveh = sum(1 for o in m['objects'] if o['kind'] in ('herc', 'tank', 'flyer'))
            print('%-6s %-4s %-28s planet %-8s objs %4d vehicles %3d navs %d drops %d terrain %s' % (
                camp, mid, (m['title'] or '')[:28], m['planet_set'], len(m['objects']), nveh, len(m['nav_markers']),
                len(m['drop_points']), m['has_terrain']))
            index.append({'id': mid, 'campaign': camp, 'index': i, 'title': m['title'], 'planet': m['planet'],
                          'next': m['next'], 'objectives': len(m['objectives']), 'vehicles': nveh,
                          'terrain': m['has_terrain']})
        start_vehicle = {'human': 52, 'cybrid': 21}[camp]   # stash vehicle given by *_planet_init.cs
        init = 'hu_planet_init.cs' if camp == 'human' else 'cy_planet_init.cs'
        c = {
            'pack': 'starsiege', 'id': camp, 'name': info.get('name'), 'player_race': info.get('playerRace'),
            'player_team': 'yellow', 'tech_level': info.get('techLevel'), 'start_date': info.get('curDate'),
            'intro_recording': info.get('cinematicRec'), 'end_movie': info.get('campaignEndSmk'),
            'pilots_script': 'scripts/DatPilot_%s.cs' % ('hu' if camp == 'human' else 'cy'),
            'inventory_script': 'scripts/' + init, 'inventory_init': inventory_calls(init),
            'start_vehicle_id': start_vehicle,
            'start_vehicle': ('starsiege:%s' % vt[start_vehicle]['key']) if vt.get(start_vehicle, {}).get('key') else None,
            'missions': [{'id': mid, 'file': 'missions/%s.json' % mid, 'next': (order[i + 1] if i + 1 < len(order) else None),
                          'on_fail': mid, 'chapter': mid[:2]} for i, mid in enumerate(order)],
            'cutscenes': cins,
            'branching': 'linear: success -> next mission (nextMission of the briefing); failure -> replay the same '
                         'mission (the original campaign has no failure branches)',
        }
        json.dump(c, open(os.path.join(OUT, 'campaigns', camp + '.json'), 'w'), indent=1)
    json.dump(index, open(os.path.join(OUT, 'missions', '_index.json'), 'w'), indent=1)
    print('missions', len(index))


if __name__ == '__main__':
    main()
