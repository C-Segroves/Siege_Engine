"""Aerial Assault -> engine data: maps (docs/formats/map_schema.md) and the campaign structure.

Reads FILES.DAT in place (aa_files), parses every MISSION.TXT (aa_mission) and the string tables (aa_strings), and
writes into <pack>/: maps/<id>/map.json, maps/_index.json (arena maps), campaign/campaign.json, campaign/strings.json.

Assumptions (docs/formats/aerial_assault.md, "Import status"):
 * 1 file unit = 1 m (the missions are ConvertMission output of Tribes 2 .mis files; BOUNDS span ~630 m).
 * File axes are X north, Y up, Z east (settled with the terrain: the heightfields match the placements and the Tribes 2
   versions of the same maps only this way), so engine (x, y, z) = (file z, y, -file x); yaw zero faces file +Z (unverified).
 * Terrain: heights = u16 / 32 m on 8 m squares (aa_terrain.py); maps without a readable .TER keep "terrain": null and
   "ground_y" (flat ground at the lowest spawn).
 * Look-alike shapes: Tribes 2 shape ids are used for stations the disc places by type (inventory, turret ...).
"""
import io
import json
import math
import os
import re
import struct

import numpy as np
from PIL import Image

import aa_bitmap
import aa_files
import aa_interior
import aa_logic
import aa_mission
import aa_shape
import aa_soldier
import aa_strings
import aa_terrain
import aa_turret
import aa_vehicles
import fx_default

PACK = 'tribes_aa'
MISSIONS = 'DATA/MISSIONS/'
CAMPAIGN_FIRST_NAME = 15      # MISSIONNAMES index of the first campaign mission (The Yard)
TRAINING_NAMES = 42           # MISSIONNAMES index of "Training 1"
TRAINING_OBJECTIVES = 59      # OBJECTIVES index of "BASIC ARMOR TRAINING" (training 1..5)

# Tribes 2 shapes standing in for the disc's typed placements (used only if tribes2 is installed)
LOOKALIKE = {
    'inventory': 'tribes2:station_inv_human', 'generator': 'tribes2:station_generator_large',
    'turret': 'tribes2:turret_base_large', 'sentry': 'tribes2:turret_sentry', 'sensor': 'tribes2:sensor_pulse_medium',
    'vehicle': 'tribes2:vehicle_pad', 'flag': 'tribes2:flag', 'switch': 'tribes2:switch', 'nexus': 'tribes2:nexusbase',
}
# base_equipment.json blocks of the Tribes 2 pack (the engine reads them for tribes_aa too: TribesBase.SPEC_PACK_FALLBACK)
SPEC = {'inventory': 'stationinventory', 'generator': 'generatorlarge', 'sensor': 'sensormediumpulse',
        'vehicle': 'stationvehiclepad'}
BARREL_SPEC = {'Plasma': 'turretbaselarge+plasmabarrellarge', 'AA': 'turretbaselarge+aabarrellarge',
               'Missile': 'turretbaselarge+missilebarrellarge', 'Mortar': 'turretbaselarge+mortarbarrellarge',
               'Sentry': 'sentryturret+sentryturretbarrel'}
# The disc's own turrets (aa_turret): the base is turret_base_large, the barrel mounted on its Mount0 node by barrel type;
# the sentry is one shape with its own barrel
TURRET_BASE = 'turret_base_large'
TURRET_BARREL = {'Plasma': 'turret_fusion_large', 'AA': 'turret_aa_large', 'Missile': 'turret_missile_large',
                 'Mortar': 'turret_mortar_large', 'ELF': 'turret_elf_large'}
TURRET_SENTRY = 'turret_sentry'
RIGGED = {TURRET_BASE, TURRET_SENTRY} | set(TURRET_BARREL.values())
ITEM_SHAPE = {'PLASMA': 'tribes2:weapon_plasma', 'CHAINGUN': 'tribes2:weapon_chaingun', 'DISC': 'tribes2:weapon_disc',
              'GRENADELAUNCHER': 'tribes2:weapon_grenade_launcher', 'SNIPERRIFLE': 'tribes2:weapon_sniper',
              'BLASTER': 'tribes2:weapon_energy', 'REPAIRPACK': 'tribes2:pack_upgrade_repair'}
MARKER_BUILDING = [12.0, 8.0, 12.0]      # placeholder box sizes in metres until the .SHP shapes are decoded
MARKER_SCENERY = [3.0, 3.0, 3.0]
# the disc's own shape for a typed placement (used when it decoded), else the Tribes 2 look-alike above
OWN_SHAPE = {'sensor': 'sensor_pulse_medium', 'inventory': 'station_inventory_human', 'generator': 'station_generator_large', 'vehicle': 'vehicle_pad',
             'flag': 'flag', 'switch': 'switch', 'nexus': 'nexus_base'}
OWN_ITEM = {'PLASMA': 'weapon_plasma', 'CHAINGUN': 'weapon_chaingun', 'DISC': 'weapon_disc', 'GRENADELAUNCHER': 'weapon_grenade_launcher',
            'BLASTER': 'weapon_blaster01', 'REPAIRPACK': 'pack_repair', 'REPAIRKIT': 'repair_kit', 'SHIELDPACK': 'pack_shield',
            'ENERGYPACK': 'pack_energy', 'AMMOPACK': 'pack_ammo', 'SATCHELCHARGE': 'pack_satchel_charge', 'MINE': 'mine',
            'GRENADELAUNCHERAMMO': 'ammo_grenade', 'PLASMAAMMO': 'ammo_plasma', 'CHAINGUNAMMO': 'ammo_chaingun', 'DISCAMMO': 'ammo_disc'}
_HAVE = set()                # shape names exported by export_shapes in this run
_RIG = set()                 # shapes exported rigged in this run
_BOUNDS = {}                 # vehicle shape -> (min, max) of the exported shape (aa_vehicles.records)


def look_alike(kind, own=OWN_SHAPE):
    n = own.get(kind)
    return '%s:%s' % (PACK, n) if n in _HAVE else LOOKALIKE.get(kind, '')


AMMO_SHAPE = {'GRENADELAUNCHERAMMO': 'tribes2:ammo_grenade', 'PLASMAAMMO': 'tribes2:ammo_plasma',
              'CHAINGUNAMMO': 'tribes2:ammo_chaingun', 'DISCAMMO': 'tribes2:ammo_disc',
              'SPINFUSORAMMO': 'tribes2:ammo_disc', 'MISSILEAMMO': 'tribes2:ammo_missile'}


def folder_of(path):
    m = re.match(re.escape(MISSIONS) + r'([^/]+)/(?:SOLO-)?MISSION\.TXT$', path.replace(chr(92), '/'))
    return m.group(1) if m else None


def mission_folders(files):
    """{folder: parsed mission}. The campaign's SOLO-MISSION.TXT is the MISSION.TXT script plus `#TAG "NAME"` lines that
    name the objects the mission logic uses (GEN1, WAYPT1, DERM_2L_1M_1W ...), so it is read when there is one."""
    names = {}
    for name, _s, _z in files.entries:
        f = folder_of(name)
        if f and (f not in names or name.upper().endswith('SOLO-MISSION.TXT')):
            names[f] = name
    return {f: aa_mission.parse(files.read(n).decode('latin-1')) for f, n in names.items()}


def is_campaign(folder):
    return bool(re.fullmatch(r'MISSION\d+', folder))


def is_training(folder):
    return bool(re.fullmatch(r'TRAINING\d+', folder))


def map_id(folder, parsed):
    if is_campaign(folder) or is_training(folder):
        return folder.title()
    return ''.join(w.capitalize() for w in re.findall(r'[A-Za-z0-9]+', parsed.get('name', folder).replace("'", ''))) or folder.title()


def _p(pos):
    """File (x north, y up, z east) -> engine (x east, y up, z south) = (z, y, -x), rounded."""
    return [round(pos[2], 3), round(pos[1], 3), round(-pos[0], 3)]


def _yaw(rot):
    """File yaw (about Y, from +Z toward +X; zero faces +Z = engine east) -> Godot yaw (zero faces north)."""
    return round(rot[1] - 90.0, 3)


def _team(power):
    return power - 1 if power in (1, 2) else -1    # heuristic: power group 1/2 -> team 0/1


def _power_groups(m):
    """Group 0 (power 0 = unpowered objects) always has power; group n (n >= 1) is powered by its generators."""
    top = max([0] + [o['power'] for k in ('generators', 'inventories', 'turrets', 'sensors', 'vehicle_pads', 'forcefields')
                     for o in m[k]])
    return [{'name': 'group%d' % i, 'parent': -1, 'provides_power': i == 0} for i in range(top + 1)]


def _env(m):
    sun = m.get('sun', {'dir': [0, -1, 0], 'color': [200] * 3, 'ambient': [100] * 3})
    fog = m.get('fog')
    out = {'sun_dir': [round(-v, 4) for v in (sun['dir'][2], sun['dir'][1], -sun['dir'][0])],   # the file gives the direction TO the sun; the engine wants the light's travel
           'sun_color': [round(c / 255.0, 3) for c in sun['color']],
           'ambient': [round(c / 255.0, 3) for c in sun['ambient']],
           'sky_images': m.get('sky', []), 'theme': m.get('environment', ''), 'music': m.get('music', ''),
           'gravity': None, 'fog_sky_affect': 0.25}
    if fog:
        out.update({'fog_color': [round(c / 255.0, 3) for c in fog['color']],
                    'horizon_color': [round(c / 255.0, 3) for c in fog['haze_color']],
                    'fog_start': fog['start'], 'fog_end': fog['finish'], 'fog_volumes': fog['volumes']})
    return out


def _modes(m):
    modes = []
    teams = {s['team'] for s in m['spawns']}
    if len(m['flags']) >= 2:
        modes.append('ctf')
    if m['nexus']:
        modes.append('hunters')
    if m['flipflops'] and len(m['flags']) < 2:
        modes.append('capture_hold')
    if not modes and len(teams) <= 1:
        modes.append('deathmatch')
    return modes


def to_map(folder, m, source):
    """Parsed mission -> engine map dict."""
    mid = map_id(folder, m)
    ys = [s['pos'][1] for s in m['spawns']] or [b['pos'][1] for b in m['buildings']] or [0.0]
    ground = min(ys)
    statics = [{'shape': '%s:%s' % (PACK, o['shape'].lower()), 'pos': _p(o['pos']), 'yaw': _yaw(o['rot']),
                'scale': o['scale'][0], 'collide': False, 'source': o['shape'], 'marker': MARKER_SCENERY}
               for o in m['scenery']]
    interiors = [{'shape': '%s:%s' % (PACK, o['shape'].lower()), 'pos': _p(o['pos']), 'yaw': _yaw(o['rot']),
                  'scale': o['scale'][0], 'collide': True,
                  'source': o['shape'], 'marker': MARKER_BUILDING, 'team': _team(o['power'])} for o in m['buildings']]
    stations = []
    for kind, key in (('inventory', 'inventories'), ('generator', 'generators'), ('turret', 'turrets'),
                      ('sensor', 'sensors'), ('vehicle', 'vehicle_pads')):
        for o in m[key]:
            shape = LOOKALIKE['sentry'] if kind == 'turret' and o.get('barrel') == 'Sentry' else look_alike(kind)
            st = {'kind': kind, 'shape': shape, 'pos': _p(o['pos']), 'yaw': _yaw(o['rot']), 'team': _team(o['power']),
                  'switch': o['switch'], 'power': o['power']}
            if o.get('tag'):
                st['tag'] = o['tag']
            if o.get('barrel'):
                st['barrel'] = o['barrel']
            if kind == 'turret':
                st.update(_own_turret(o.get('barrel')))
            st['spec'] = BARREL_SPEC.get(o.get('barrel'), 'turretbaselarge') if kind == 'turret' else SPEC.get(kind, '')
            st['power_group'] = o['power']
            if not st['spec']:
                del st['spec']
            stations.append(st)
    for o in m['forcefields']:
        stations.append({'kind': 'forcefield', 'shape': '', 'pos': _p(o['pos']), 'yaw': _yaw(o['rot']), 'team': _team(o['power']),
                         'switch': o['switch'], 'power': o['power'], 'size': o['scale']})
    for o in m['pickups']:
        own = OWN_ITEM.get(o['kind'])
        shape = ('%s:%s' % (PACK, own)) if own in _HAVE else (AMMO_SHAPE.get(o['kind']) or ITEM_SHAPE.get(o['kind'], ''))
        stations.append({'kind': 'ammo' if o['kind'].endswith('AMMO') else 'pickup', 'shape': shape, 'pos': _p(o['pos']),
                         'yaw': 0.0, 'team': -1, 'item': o['kind']})
    spawns = [{'kind': 'infantry', 'pos': _p(s['pos']), 'yaw': _yaw([0, s['yaw'], 0]), 'team': s['team'],
               'radius': s['radius'], 'indoor': False} for s in m['spawns']]
    # A mission drop point is a terrain placement (the y in the file is often far off the ground: Escalade's lies
    # 136 m below it); "indoor": False puts the soldier on the terrain at its x/z (MapBuilder._spawn_transform).
    for o in m['vehicle_pads']:
        spawns.append({'kind': 'vehicle_pad', 'pos': _p(o['pos']), 'yaw': _yaw(o['rot']), 'team': _team(o['power'])})
        if o.get('tag'):
            spawns[-1]['tag'] = o['tag']
    mode_objects, mid_n = [], 0
    for f in m['flags']:
        mid_n += 1
        mode_objects.append({'id': mid_n, 'kind': 'flag', 'team': f['team'], 'pos': _p(f['pos']), 'yaw': _yaw([0, math.degrees(f['yaw']), 0]),
                             'shape': look_alike('flag'), 'modes': []})
    for f in m['flipflops']:
        mid_n += 1
        mode_objects.append({'id': mid_n, 'kind': 'switch', 'team': -1, 'pos': _p(f['pos']), 'yaw': _yaw(f['rot']),
                             'shape': look_alike('switch'), 'modes': [], 'switch': f['switch']})
        if f.get('tag'):
            mode_objects[-1]['tag'] = f['tag']
    for n in m['nexus']:
        mid_n += 1
        mode_objects.append({'id': mid_n, 'kind': 'nexus', 'team': -1, 'pos': _p(n['pos']), 'yaw': 0.0,
                             'shape': look_alike('nexus'), 'modes': [], 'height': n['height']})
    b = m.get('bounds', {'min': [0, 0, 0], 'max': [0, 0, 0]})
    return {
        'pack': PACK, 'id': mid, 'name': m.get('name', folder), 'source': source,
        'modes': _modes(m), 'original_modes': [], 'mode_objects': mode_objects, 'mode_settings': {},
        'bounds': {'min': [b['min'][2], -b['max'][0]], 'max': [b['max'][2], -b['min'][0]]},
        'terrain': None, 'terrain_source': m.get('terrain', ''), 'ground_y': ground,
        'environment': _env(m), 'interiors': interiors, 'statics': statics, 'spawns': spawns, 'stations': stations,
        'power': m['power'], 'switch': m['switch'], 'power_groups': _power_groups(m),
        'waypoints': [dict({'switch': w['switch'], 'name': w['name'], 'pos': _p(w['pos'])}, **({'tag': w['tag']} if w.get('tag') else {}))
                      for w in m['waypoints']],
        'cameras': [_p(c) for c in m['cameras']],
        'notes': 'Aerial Assault: terrain (.TER) and shapes (.SHP) are not converted yet; flat ground at ground_y, '
                 'placements reference tribes_aa shape names, stations use Tribes 2 look-alikes. Team of a station is '
                 'a heuristic (power group 1/2 = team 0/1).',
    }


def _own_turret(barrel):
    """The disc's own turret shapes for a turret placement (when they exported rigged): {} keeps the Tribes 2 look-alike.
    TribesBase.make_spec reads barrel_shape / barrel_mount over the Tribes 2 block's."""
    if barrel == 'Sentry':
        return {'shape': '%s:%s' % (PACK, TURRET_SENTRY), 'barrel_shape': '', 'barrel_mount': ''} if TURRET_SENTRY in _RIG else {}
    own = TURRET_BARREL.get(barrel)
    if TURRET_BASE in _RIG and own in _RIG:
        return {'shape': '%s:%s' % (PACK, TURRET_BASE), 'barrel_shape': '%s:%s' % (PACK, own), 'barrel_mount': aa_turret.MOUNT}
    return {}


def index_row(mp):
    spawns, objs = {}, {}
    for s in mp['spawns']:
        spawns[s['kind']] = spawns.get(s['kind'], 0) + 1
    for o in mp['mode_objects']:
        objs[o['kind']] = objs.get(o['kind'], 0) + 1
    b = mp['bounds']
    return {'id': mp['id'], 'name': mp['name'], 'modes': mp['modes'], 'terrain': bool(mp.get('terrain')), 'spawns': spawns,
            'size_m': [round(b['max'][0] - b['min'][0], 1), round(b['max'][1] - b['min'][1], 1)],
            'interiors': len(mp['interiors']), 'statics': len(mp['statics']),
            'stations': len(mp['stations']), 'mode_objects': objs}


def make_campaign(files, parsed):
    """campaign/campaign.json: the training missions then the numbered missions, each with its text.

    Heuristics (flagged in the file): the 11 numbered folders take MISSIONNAMES 15..25 in order, the five
    training folders take OBJECTIVES 59..63, and communique i belongs to mission i (training first)."""
    names = aa_strings.read_table(files, 'MISSIONNAMES')
    objectives = aa_strings.read_table(files, 'OBJECTIVES')
    comm = aa_strings.read_table(files, 'COMMUNIQUE')
    camp_raw = aa_strings.parse_table(files.read(MISSIONS + 'CAMPAIGN.BIN'))
    camp = [aa_strings.clean(s) for s in camp_raw]
    trainings = sorted((f for f in parsed if is_training(f)), key=lambda f: int(f[8:]))
    numbered = sorted((f for f in parsed if is_campaign(f)), key=lambda f: int(f[7:]))
    missions = []
    for i, f in enumerate(trainings):
        missions.append({'folder': f, 'map': map_id(f, parsed[f]), 'name': names[TRAINING_NAMES + i] if TRAINING_NAMES + i < len(names) else f,
                         'kind': 'training', 'objectives_text': objectives[TRAINING_OBJECTIVES + i]})
    for i, f in enumerate(numbered):
        idx = CAMPAIGN_FIRST_NAME + i
        missions.append({'folder': f, 'map': map_id(f, parsed[f]), 'name': names[idx] if idx < len(names) else parsed[f].get('name', f),
                         'kind': 'mission', 'objectives_text': ''})
    for i, mi in enumerate(missions):
        mi['index'] = i
        mi['briefing'] = comm[i] if i < len(comm) else ''
    return {
        'id': 'main', 'name': 'Tribes: Aerial Assault', 'missions': missions,
        'assignment': 'heuristic: names by folder order, communique i = mission i; scripted logic lives in the ELF',
        'briefings_extra': [camp[i] for i, s in enumerate(camp_raw) if aa_strings.is_briefing(s)],
        'hints': [{'index': i, 'text': t} for i, t in enumerate(camp) if t and not aa_strings.is_briefing(camp_raw[i])],
        'objective_lists': [{'index': i, 'text': t} for i, t in enumerate(objectives) if t.startswith('Objectives:')],
    }


MATERIAL_COLOURS = (('grass', (92, 122, 58)), ('dirt', (110, 88, 62)), ('rock', (118, 114, 108)), ('lake', (96, 98, 84)),
                    ('sand', (196, 170, 118)), ('snow', (236, 240, 244)), ('ice', (170, 200, 220)), ('lava', (150, 60, 30)),
                    ('crust', (70, 50, 44)), ('ash', (90, 84, 80)), ('mud', (96, 78, 60)))


def material_colour(name):
    low = name.lower()
    for key, rgb in MATERIAL_COLOURS:
        if key in low:
            return rgb
    return (128, 128, 128)


ALBEDO_PX_PER_SQUARE = 8
TILE_METRES = 32            # one terrain material texture covers 32 m (assumption)
_TILES = {}


def bitmap_rgba(files, name):
    """RGBA array (mip 0) of a .XBM/.XBMP, or None when it is missing or unreadable."""
    try:
        return aa_bitmap.to_rgba(aa_bitmap.parse(files.read(name)), 0)
    except (KeyError, ValueError):
        return None


def material_tile(files, material, size):
    """(size, size, 3) float image of terrain material "LushWorld.Lakebed" tiled every TILE_METRES (flat colour if missing)."""
    key = (material, size)
    if key not in _TILES:
        img = bitmap_rgba(files, 'DATA/TERRAIN/%s.XBMP' % material.upper())
        if img is None:
            _TILES[key] = np.ones((size, size, 3), 'f4') * np.array(material_colour(material), 'f4')
        else:
            px = TILE_METRES * ALBEDO_PX_PER_SQUARE // 8
            tile = np.asarray(Image.fromarray(img[..., :3]).resize((px, px), Image.BOX), 'f4')
            reps = -(-size // px)
            _TILES[key] = np.tile(tile, (reps, reps, 1))[:size, :size]
    return _TILES[key]


def detail_image(files, theme):
    name = {'BADLAND': 'LUSH', 'BADLANDS': 'LUSH'}.get(theme.upper(), theme.upper())
    img = bitmap_rgba(files, 'DATA/TERRAIN/DETAIL/%s.XBMP' % name)
    return None if img is None else np.ascontiguousarray(img[..., :3])


FACE = 256
# OpenGL cubemap face basis: direction = f(u, v in -1..1)
_CUBE = {'right': lambda a, b: (1, -b, -a), 'left': lambda a, b: (-1, -b, a), 'top': lambda a, b: (a, 1, b),
         'bottom': lambda a, b: (a, -1, -b), 'back': lambda a, b: (a, -b, 1), 'front': lambda a, b: (-a, -b, -1)}


def _sample(tile, u, v):
    h, w = tile.shape[:2]
    x = np.clip((u * w).astype(int), 0, w - 1)
    y = np.clip((v * h).astype(int), 0, h - 1)
    return tile[y, x]


def bake_sky(tiles, fog):
    """The disc's sky is a box viewed from its floor: a 2 x 2 top tile at height 1 and four 2 x 1 side tiles (the tile's
    upper half of a square face). Renders it into the six faces of a cubemap. Engine axes: x east, y up, z south; the F tile
    is the east wall, L north, B west, R south (assumption, as the file's yaw zero faces +Z = east)."""
    g = (np.arange(FACE) + 0.5) / FACE * 2 - 1
    a, b = np.meshgrid(g, g)
    faces = {}
    for name, f in _CUBE.items():
        x, y, z = [np.asarray(c, 'f4') * np.ones_like(a) for c in f(a, b)]
        out = np.empty((FACE, FACE, 3), 'u1')
        out[:] = fog
        up = y > 1e-4
        t = np.where(up, 1.0 / np.maximum(y, 1e-4), 0)
        hx, hz = x * t, z * t
        top = up & (np.abs(hx) <= 1) & (np.abs(hz) <= 1)
        if top.any():
            out[top] = _sample(tiles['T'], ((hx + 1) / 2)[top], ((hz + 1) / 2)[top])
        side = up & ~top
        ax, az = np.abs(x), np.abs(z)
        for wall, mask, u_of in (('F', side & (ax >= az) & (x > 0), lambda hz_, hx_: (hz_ + 1) / 2),
                                 ('B', side & (ax >= az) & (x < 0), lambda hz_, hx_: (1 - hz_) / 2),
                                 ('R', side & (az > ax) & (z > 0), lambda hz_, hx_: (1 - hx_) / 2),
                                 ('L', side & (az > ax) & (z < 0), lambda hz_, hx_: (hx_ + 1) / 2)):
            if not mask.any():
                continue
            dom = np.where(ax >= az, ax, az)
            tw = 1.0 / np.maximum(dom, 1e-4)             # ray scale reaching the wall plane (|coordinate| = 1)
            wy = y * tw
            col = _sample(tiles[wall], u_of(z * tw, x * tw)[mask], (1 - wy)[mask])
            col = np.where((wy[mask] > 1)[:, None], fog, col)
            out[mask] = col
        faces[name] = out
    return faces


def export_sky(files, m, out_dir):
    """Writes sky_<face>.png (six cubemap faces) from the mission's five SKY bitmaps; returns the faces dict."""
    sky = m.get('sky', [])
    if len(sky) < 5:
        return {}
    os.makedirs(out_dir, exist_ok=True)
    fog = tuple(int(c) for c in (m.get('fog') or {}).get('haze_color', (127, 132, 132)))
    tiles = {}
    for path in sky:
        key = os.path.splitext(os.path.basename(path))[0][-1].upper()
        try:
            tile = np.asarray(Image.open(io.BytesIO(files.read(path.replace(chr(92), '/')))).convert('RGB')).copy()
        except (KeyError, OSError):
            return {}
        tile[(tile == 0).all(-1)] = fog                  # black = below the horizon
        tiles[key] = tile
    faces = {}
    for name, img in bake_sky(tiles, np.array(fog, 'u1')).items():
        Image.fromarray(img).save(os.path.join(out_dir, 'sky_%s.png' % name))
        faces[name] = 'sky_%s.png' % name
    return faces


def export_terrain(files, folder, m, out_dir):
    """Writes heights.r32, layers.png (RGBA weights, engine layout) and a flat-colour albedo.png; returns the map's
    "terrain" dict, or None when the folder has no readable .TER."""
    try:
        ter = aa_terrain.parse(files.read(MISSIONS + folder + '/' + m.get('terrain', '')))
    except (KeyError, ValueError):
        return None
    heights = aa_terrain.engine_grid(ter['heights']).astype('<f4')
    os.makedirs(out_dir, exist_ok=True)
    heights.tofile(os.path.join(out_dir, 'height.r32'))
    layers = [aa_terrain.engine_grid(a) for a in ter['layers']][:4]
    while len(layers) < 4:
        layers.append(np.zeros_like(layers[0]))
    Image.fromarray(np.stack(layers, -1).astype('u1'), 'RGBA').save(os.path.join(out_dir, 'layers.png'))
    albedo_px = (aa_terrain.SIZE - 1) * ALBEDO_PX_PER_SQUARE
    albedo = np.zeros((albedo_px, albedo_px, 3), 'f4')
    for k, name in enumerate(ter['materials'][:4]):
        w = np.asarray(Image.fromarray(layers[k]).resize((albedo_px, albedo_px), Image.BILINEAR), 'f4') / 255.0
        albedo += w[..., None] * material_tile(files, name, albedo_px)
    Image.fromarray(np.clip(albedo, 0, 255).astype('u1'), 'RGB').save(os.path.join(out_dir, 'albedo.png'))
    detail = detail_image(files, m.get('_theme', 'LUSH'))
    if detail is not None:
        Image.fromarray(detail, 'RGB').save(os.path.join(out_dir, 'detail.png'))
    n = aa_terrain.SIZE
    holes = [aa_terrain.hole_square(i) for i in m.get('empty_squares', []) if 0 <= i < n * n]
    return {'heights': 'height.r32', 'size': [n, n], 'square': aa_terrain.SQUARE, 'origin': aa_terrain.engine_origin(),
            'height_scale': 1.0, 'albedo': 'albedo.png', 'albedo_repeat': 1.0, 'layers': 'layers.png',
            'detail': 'detail.png' if detail is not None else None, 'detail_square_repeat': 1,
            'materials': ter['materials'], 'holes': holes, 'source': m.get('terrain', ''), 'wraps': False}


SHAPE_DIR = 'C:/PROJECTS/T2/DEMO1/DATA/SHAPES/PS2/'
SKIP_SUFFIX = ('_c', '_col', '_coll')


def export_texture(files, name, out, done):
    """Decodes the shape texture `name` ("BASE_x.png") from the disc into textures/aa/<stem>.png; returns its pack path."""
    stem = os.path.splitext(name)[0]
    rel = 'textures/aa/%s.png' % stem
    if stem.lower() in done:
        return rel if done[stem.lower()] else None
    img = bitmap_rgba(files, SHAPE_DIR + stem.upper() + '.XBMP')
    done[stem.lower()] = img is not None
    if img is None:
        return None
    os.makedirs(os.path.join(out, 'textures', 'aa'), exist_ok=True)
    Image.fromarray(img, 'RGBA').save(os.path.join(out, rel))
    return rel


INTERIOR_DIR = 'DATA/INTERIORS/'


def export_interior_texture(files, name, out, done):
    stem = os.path.splitext(name)[0]
    rel = 'textures/aa/int_%s.png' % stem
    key = 'int_' + stem.lower()
    if key in done:
        return rel if done[key] else None
    img = bitmap_rgba(files, INTERIOR_DIR + 'PS2TEX/' + stem.upper() + '.XBM')
    done[key] = img is not None
    if img is None:
        return None
    os.makedirs(os.path.join(out, 'textures', 'aa'), exist_ok=True)
    Image.fromarray(img, 'RGBA').save(os.path.join(out, rel))
    return rel


def export_interiors(files, out, names, progress=None):
    """The interiors (buildings) the missions place -> shapes/<name>.json. Returns {name: error | None}."""
    status, done = {}, {}
    names = sorted(names)
    for k, name in enumerate(names):
        try:
            it = aa_interior.decode(files.read(INTERIOR_DIR + name + '.BIN'))
            js = aa_shape.to_json(aa_interior.to_shape(it, name), lambda t: export_interior_texture(files, t, out, done))
            write_json(os.path.join(out, 'shapes', name.lower() + '.json'), js)
            _HAVE.add(name.lower())
            status[name] = None
        except (ValueError, KeyError, struct.error) as e:
            status[name] = str(e)
        if progress:
            progress(name, (k + 1) / len(names))
    return status


def export_shapes(files, out, progress=None):
    """Every decodable .SHP of the shapes folder -> shapes/<name>.json (+ textures/aa/*.png). Returns {name: error | None}."""
    _HAVE.clear()
    _BOUNDS.clear()
    _RIG.clear()
    status, done = {}, {}
    names = [n for n, _s, _z in files.entries if n.replace(chr(92), '/').upper().startswith(SHAPE_DIR.upper().replace('C:/', 'C:/'))
             and n.upper().endswith('.SHP')]
    names = sorted(set(names))
    for k, n in enumerate(names):
        stem = os.path.splitext(n.replace(chr(92), '/').rsplit('/', 1)[-1])[0].lower()
        if stem.endswith(SKIP_SUFFIX):
            continue
        try:
            raw = files.read(n)
            tex = lambda t: export_texture(files, t, out, done)
            js = None
            if stem in RIGGED:                                  # animated turret part (aa_turret)
                try:
                    js = aa_turret.rigged_json(raw, tex)
                except (ValueError, KeyError, IndexError, struct.error):
                    js = None
            if stem in aa_vehicles.RIGGED:                      # the transport: nodes + pose block like a turret
                try:
                    js = aa_turret.rigged_json(raw, tex)
                    _BOUNDS[stem] = js['bounds']['header']
                except (ValueError, KeyError, IndexError, struct.error):
                    js = None
            if js is None and re.search(r'(?:light|medium|heavy)_(?:male|female|bioderm)$', stem):    # animated soldier (aa_soldier); else the rest-pose shape
                try:
                    js = aa_soldier.rigged_json(raw, tex)
                except (ValueError, KeyError, IndexError, struct.error):
                    js = None
            if js is None:
                sh = aa_shape.decode(raw)
                if stem in aa_vehicles.NOSE:
                    aa_shape.face_nose(sh, aa_vehicles.NOSE[stem])
                js = aa_shape.to_json(sh, tex)
                if stem in aa_vehicles.NOSE:
                    _BOUNDS[stem] = js['bounds']['header']
            write_json(os.path.join(out, 'shapes', stem + '.json'), js)
            _HAVE.add(stem)
            if js.get('source') == 'aa_shp_rigged' and stem in RIGGED:
                _RIG.add(stem)
            status[stem] = None
        except (ValueError, KeyError, struct.error) as e:
            status[stem] = str(e)
        if progress:
            progress(stem, (k + 1) / len(names))
    return status


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


def import_all(files, out, progress=None):
    """Write the whole pack content under `out`. Returns {'maps': n, 'campaign_missions': n}."""
    parsed = mission_folders(files)
    export_shapes(files, out, (lambda name, f: progress('shape ' + name, f * 0.5)) if progress else None)
    vehicles = aa_vehicles.records(PACK, _BOUNDS)
    if vehicles:
        write_json(os.path.join(out, 'gameplay', 'hercs.json'), vehicles)
    fx_default.export(PACK, out)                       # death effects: engine defaults (the pack names no explosions)
    buildings = {o['shape'] for m in parsed.values() for o in m['buildings']}
    export_interiors(files, out, buildings, (lambda name, f: progress('building ' + name, 0.5 + f * 0.25)) if progress else None)
    index = []
    for n, folder in enumerate(sorted(parsed)):
        mp = to_map(folder, parsed[folder], MISSIONS + folder + '/MISSION.TXT')
        parsed[folder]['_theme'] = parsed[folder].get('environment', 'LUSH')
        faces = export_sky(files, parsed[folder], os.path.join(out, 'maps', mp['id']))
        if faces:
            mp['environment']['skybox_faces'] = faces
        mp['terrain'] = export_terrain(files, folder, parsed[folder], os.path.join(out, 'maps', mp['id']))
        write_json(os.path.join(out, 'maps', mp['id'], 'map.json'), mp)
        if not (is_campaign(folder) or is_training(folder)):
            index.append(index_row(mp))
        if progress:
            progress(mp['name'], (n + 1) / len(parsed))
    index.sort(key=lambda r: r['name'])
    write_json(os.path.join(out, 'maps', '_index.json'), index)
    camp = make_campaign(files, parsed)
    write_json(os.path.join(out, 'campaign', 'campaign.json'), camp)
    iso_path = getattr(files, 'iso_path', '')
    if iso_path:
        try:
            logic = aa_logic.extract(aa_logic.read_elf(iso_path), aa_strings.read_table(files, 'OBJECTIVES'),
                                     aa_strings.read_table(files, 'CAMPAIGN'))
        except ImportError:      # capstone is not installed: the missions keep the reach-and-destroy fallback
            logic = None
        if logic:
            write_json(os.path.join(out, 'campaign', 'logic.json'), logic)
    return {'maps': len(parsed), 'arena_maps': len(index), 'campaign_missions': len(camp['missions'])}
