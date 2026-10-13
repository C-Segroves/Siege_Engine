"""Metaltech: Battledrome weapons -> gamedata/bd/gameplay/weapons_engine.json (docs/formats/weapon_schema.md),
gamedata/bd/gameplay/loadouts.json, weapon/impact sounds (gamedata/bd/audio/sfx/<stem>.wav) and sprite
frame lists for the bitmap effect shapes (gamedata/bd/shapes/<FX>.json, key "sprite").

    python tools/export_bd_weapons.py

Everything is read from bd/installed/ (tools/bd_unchunk.py): SIM.EXE static tables, DTS/*.DCS logical-part
tables, DATA/NETDATA.DAT (the shipped ladder: 59 AI pilots with their Herc configurations), SOUND/*.RAW.
Full description: docs/formats/bd_weapons.md.

SIM.EXE: VA = file offset - 0x69CD. The instruction bytes in EVIDENCE are checked first, so another exe build
fails loudly instead of exporting garbage.

Units (docs/formats/units.md section 4): sim clock 1 unit = 4 ms; Hercs update (charge, fire) every 25 units
= 100 ms; positions integrate v*dt>>8 -> speeds are units per 256 ticks = 1.024 s; distances use the shared
world scale 0.00215 m per BD unit (game/engine/packs.gd WORLD_SCALE bd).
Damage: BD points x 0.5 = Earthsiege scale (see DAMAGE_NOTE / bd_weapons.md section 5).
"""
import collections
import glob
import json
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
BD = P.work('bd', 'installed')
OUT = P.pack('bd')
BASE = 0x69CD

MPU = 0.00215                 # metres per BD unit (shared world scale)
TICK = 0.004                  # s per sim clock unit
UPDATE = 25                   # Herc / projectile update period in clock units (100 ms)
SPEED = MPU / (256 * TICK)    # units per 1.024 s -> m/s
ACCEL = MPU / (256 * TICK) ** 2
ANGLE_DEG = 360.0 / 65536
DMG_K = 0.5                   # BD damage / armour points -> Earthsiege points

# VA -> (hex bytes, meaning). All are instructions the decoding below depends on.
EVIDENCE = {
    0x9C24: ('6bf27c81c6e40b08', 'Herc::firePodWeapon: weapon record = 0x80be4 + 0x7c*index'),
    0xBB96: ('0504540700', 'Laser ctor: row = 0x75404 + 0x14*index'),
    0xCE4B: ('057c550700', 'Blaster ctor: row = 0x7557c + 0x14*index'),
    0xD83F: ('0558560700', 'Plasma ctor: row = 0x75658 + 0x18*index'),
    0x10A0B: ('05905f0700', 'Canon (bullet) ctor: row = 0x75f90 + 0x18*index'),
    0xEBD8: ('056c550700', 'Missile ctor: row = 0x7556c + 0x3c*index'),
    0xFD63: ('05545b0700', 'Mine ctor: row = 0x75b54 + 0x2c*index'),
    0x114B0: ('81c1a8620700', 'Explosion ctor: row = 0x762a8 + 0x2c*type'),
    0x10C33: ('3d00030000', 'canon bullet lifetime 0x300 ticks'),
    0xD058: ('3d00040000', 'blaster bolt lifetime 0x400 ticks'),
    0xBDF8: ('83c01e', 'laser beam removed 0x1e ticks after firing'),
    0xFFBA: ('3d00060000', 'mine radar blip for the first 0x600 ticks'),
    0x80EB: ('d1a6bf020000', 'Herc shield vs area damage: shield value doubled (2 damage per point)'),
    0x70DA: ('b958000000', 'power split: engine 0x58/256'),
    0x70E5: ('ba54000000', 'power split: shield 0x54/256, weapons 0x54/256'),
    0x762C: ('8b4f30c1f902','damage event on a body part: 1/4 radial splash, 3/4 to the part'),
}

CLASSES = {0: 'laser', 1: 'blaster', 2: 'plasma', 3: 'autocannon', 4: 'missile_launcher', 5: 'mine_launcher'}
FIRE_SOUND_PUSH = {0: 0x9D24, 1: 0x9DB9, 2: 0x9E05, 3: 0x9D6D, 4: 0x9E5E, 5: 0x9EA5}  # 'push n' (6a nn)
HIT_EXPLOSION = {'laser': 4, 'blaster': 5, 'autocannon': 6, 'plasma': 1, 'missile_launcher': 1,
                 'mine_launcher': 7, 'shield': 3, 'missile_ground': 7}
BAYS = ['LIGHT BAY', 'MEDIUM BAY', 'HEAVY BAY', 'MINE LNCHR', 'MSL LNCHR']
BAY_MASK = {0: 7, 1: 15, 2: 31, 3: 7, 4: 7}
HARDPOINTS = ['POD 1', 'POD 2', 'POD 3', 'POD 4', 'MINE POD', 'MISSILE P1', 'MISSILE P2']
SPRITE_FX = ['BLASTHIT', 'EXPLD1', 'EXPLD2', 'LSRHIT', 'PLASMBAL', 'RDLASER', 'SHIELD1', 'SHLDHIT2', 'SHROOM']

DAMAGE_NOTE = (
    "BD damage (= capacitor charge spent for lasers/blasters/plasma, table value for cannon/missile/mine) x 0.5 "
    "= armour damage in the Earthsiege scale; BD per-part armour (ARMOR1-12: 400..4800 per logical part) x 0.5 "
    "-> 200..2400 (ES1 components 300-2500). BD shields (SG I-VI: 3000..5500 points) map 1:1 onto ES1 shield "
    "points (ES1 Herc 3500): area damage removes 1 shield point per 2 damage (0x80eb), so damage.shield = "
    "shield points one hit removes from an unsaturated shield (laser/blaster/plasma 1 per damage, cannon 1 per 4, "
    "area 1 per 2, mines 0 - they bypass shields). One factor for weapons and armour keeps every BD "
    "time-to-kill ratio. BD-only rules (shield leak, area damage applied to every logical part in range) are in "
    "each weapon's notes / native block; docs/formats/bd_weapons.md section 5.")


class Sim:
    def __init__(self, path):
        self.d = open(path, 'rb').read()

    def b(self, va, n):
        return self.d[va + BASE:va + BASE + n]

    def i32(self, va, n=1):
        v = struct.unpack_from('<%di' % n, self.d, va + BASE)
        return v if n > 1 else v[0]

    def cstr(self, va, n=64):
        return self.b(va, n).split(b'\0')[0].decode('latin1')

    def check(self):
        bad = [(hex(va), m) for va, (h, m) in EVIDENCE.items() if self.b(va, len(h) // 2).hex() != h]
        if bad:
            raise SystemExit('SIM.EXE does not match the decoded build (Release 1.3.2): %s' % bad)


# ---------------------------------------------------------------- tables

def weapon_records(s):
    out = []
    for i in range(33):
        a = 0x80BE4 + 0x7C * i
        w = s.i32(a, 26)
        out.append({
            'index': i, 'va': a, 'name': s.cstr(a + 0x68, 16),
            'class': w[0], 'energy_divisor': w[1], 'leak': w[2], 'refire_ticks': w[3], 'unknown_10': w[4],
            'min': w[5], 'capacity': w[6], 'per_shot': w[7],
            'hercs': list(w[8:18]), 'bays': list(w[18:21]), 'mine_lnchr': w[21], 'msl_lnchr': w[22],
            'price': w[23], 'ammo_price': w[24], 'mass': w[25]})
    return out


def class_rows(s, rec):
    i, c = rec['index'], rec['class']
    if c == 0:
        r = s.i32(0x75404 + 0x14 * i, 5)
        return {'range': r[0], 'radius': r[1], 'splash_radius': r[2], 'damage_shift': r[3], 'unknown_10': r[4]}
    if c == 1:
        r = s.i32(0x7557C + 0x14 * i, 5)
        return {'speed': r[0], 'radius': r[1], 'splash_radius': r[2], 'damage_shift': r[3], 'shape_index': r[4]}
    if c == 2:
        r = s.i32(0x75658 + 0x18 * i, 6)
        return {'speed': r[0], 'radius': r[1], 'splash_radius': r[2], 'damage_divisor': r[3], 'decay': r[4],
                'shape_index': r[5]}
    if c == 3:
        r = s.i32(0x75F90 + 0x18 * i, 6)
        return {'speed': r[0], 'radius': r[1], 'splash_radius': r[2], 'damage': r[3], 'unused_10': r[4],
                'shape_index': r[5]}
    if c == 4:
        r = s.i32(0x7556C + 0x3C * i, 15)
        keys = ['lifetime', 'impact_mass', 'radius', 'seeker_half_angle', 'max_thrust', 'max_lateral',
                'launch_speed', 'cruise_speed', 'cruise_altitude', 'proximity', 'dive_distance',
                'shield_detonate_above', 'blast_radius', 'damage', 'shape_index']
        return dict(zip(keys, r))
    r = s.i32(0x75B54 + 0x2C * i, 11)
    keys = ['max_speed', 'chase_speed', 'hover_height', 'drop_speed', 'trigger_distance', 'scan_every_updates',
            'detect_radius', 'blast_radius', 'damage', 'update_ticks', 'shape_index']
    return dict(zip(keys, r))


def sound_list(s):
    out, va = [], 0x78648
    for _ in range(15):
        n = s.cstr(va, 40)
        out.append(os.path.splitext(n.split('\\')[-1])[0].lower())
        va += len(n) + 1
    return out


def explosions(s):
    out = []
    for t in range(8):
        r = s.i32(0x762A8 + 0x2C * t, 6)
        shapes = [s.cstr(s.i32(r[5] + 4 * k), 20).split('\\')[-1].upper() for k in range(r[4])]
        out.append({'type': t, 'sound_index': r[0], 'light': list(r[1:4]), 'shapes': shapes})
    return out


def components(s):
    def tab(base, n, stride, name_off, price_off, mass_off, extra):
        rows = []
        for i in range(n):
            a = base + stride * i
            row = {'index': i, 'name': s.cstr(a + name_off, 12), 'price': s.i32(a + price_off),
                   'mass': s.i32(a + mass_off)}
            row.update(extra(a))
            rows.append(row)
        return rows
    return {
        'shields': tab(0x81BE0, 6, 0x6C, 0x58, 0x50, 0x54, lambda a: {
            'points': s.i32(a), 'recharge_table': [list(s.i32(a + 8 + 8 * k, 2)) for k in range(4)],
            'hercs': list(s.i32(a + 0x28, 10))}),
        'reactors': tab(0x81E68, 6, 0x64, 0x50, 0x48, 0x4C, lambda a: {
            'output_vs_damage': [list(s.i32(a + 8 * k, 2)) for k in range(4)], 'hercs': list(s.i32(a + 0x20, 10))}),
        'armor': tab(0x851E4, 12, 0xB0, 0x9C, 0x94, 0x98, lambda a: {
            'value_0?': s.i32(a), 'part_points': list(s.i32(a + 4, 26)), 'hercs': list(s.i32(a + 0x6C, 10)),
            'note': '+0x94 (price slot of the other tables) is 0; value_0 (5..75) may be the per-point repair/'
                    'price factor (not traced)'}),
        'engines': tab(0x85A24, 12, 0x88, 0x74, 0x6C, 0x70, lambda a: {'raw': list(s.i32(a, 27))}),
    }


def hercs(s):
    out = []
    for k in range(10):
        a = 0x82FFC + 0x364 * k
        shape = s.cstr(a + 0xFC, 0x18).split('\\')[-1].split('.')[0].upper()
        mounts = [s.i32(a + 0x68 + 20 * i, 5) for i in range(7)]
        out.append({'index': k, 'name': s.cstr(a + 0x350, 12), 'shape': shape, 'mounts': mounts})
    return out


# ---------------------------------------------------------------- DCS logical parts / pods

def dcs_logical_parts(shape):
    """DCShape::read (0x44848) trailer: sphere(4 i32), i32, u32 nA, nB, nC, nL, u16 nE, then nA u32, nA u16,
    nB u32, nC x 6 bytes (cell sequences), nL x 20 bytes logical parts {i32 ?, i32 node, i32 x,y,z}, nE u16."""
    import export_bd
    data = open(os.path.join(BD, 'DTS', shape + '.DCS'), 'rb').read()
    _shape, _coll, t = export_bd.read_dcs(data)
    p = 20
    na, nb, nc, nl = struct.unpack_from('<4I', t, p)
    p += 16 + 2
    p += 6 * na + 4 * nb + 6 * nc
    return [struct.unpack_from('<5i', t, p + 20 * i) for i in range(nl)]


def node_positions(sj):
    nodes, tf = sj['nodes'], sj['transforms']
    pos = {}

    def get(i):
        if i in pos:
            return pos[i]
        t = tf[nodes[i]['default']]
        par = nodes[i]['parent']
        base = get(par) if par >= 0 else (0, 0, 0)
        pos[i] = (base[0] + t[3], base[1] + t[4], base[2] + t[5])   # default rotations are all 0 in BD Hercs
        return pos[i]
    for i in range(len(nodes)):
        get(i)
    return pos


def pods(herc):
    sj = json.load(open(os.path.join(OUT, 'shapes', herc['shape'] + '.json')))
    lp = dcs_logical_parts(herc['shape'])
    npos = node_positions(sj)
    cells = sj['lods'][0].get('cells', [])
    out = []
    for i, (bay, slot, mx, my, mz) in enumerate(herc['mounts']):
        if bay < 0:
            continue
        part = lp[11 + i] if 11 + i < len(lp) else (0, -1, 0, 0, 0)
        node = part[1]
        base = npos.get(node, (0, 0, 0)) if node >= 0 else (0, 0, 0)
        mount = [base[0] + part[2], base[1] + part[3], base[2] + part[4]]
        muzzle = [mount[0] + mx, mount[1] + my, mount[2] + mz]
        states = sorted({c['states'] for c in cells if c['slot'] == slot}) if slot >= 0 else []
        box = pod_box(sj, npos, slot, mount) if slot >= 0 else None
        out.append({
            'slot': i, 'hardpoint': HARDPOINTS[i], 'bay': BAYS[bay], 'hardpoint_mask': BAY_MASK[bay],
            'cell_slot': slot if slot >= 0 else None, 'cell_states': states[-1] if states else None,
            'side': None if abs(mount[0]) < 50 else ('left' if mount[0] < 0 else 'right'),
            'logical_part': {'index': 11 + i, 'field0': part[0], 'node': node, 'offset': list(part[2:5])},
            'muzzle_offset': [mx, my, mz],
            'mount_units': mount, 'muzzle_units': muzzle,
            'mount_m': [round(v * MPU, 3) for v in mount], 'muzzle_m': [round(v * MPU, 3) for v in muzzle],
            'pod_cells': [k for k, c in enumerate(cells) if c['slot'] == slot] if slot >= 0 else [],
            'pod_box_units': box,
        })
    return out


def pod_box(sj, npos, slot, mount):
    """Box of the baked pod drawn for a cell slot (render prep 0x7904 sets the slot's state; idle = state 0),
    relative to the logical-part point (units, x right, y forward, z up; BD node rotations are all 0).
    Only the pod body counts: connected groups of >= 3 polygons that straddle the pod's x = 0 plane, so
    struts, fins and torso plates sharing the slot are left out."""
    lod = sj['lods'][0]
    polys = []
    for p in lod['pieces']:
        c = p.get('cell', -1)
        if c < 0 or p.get('state', 0) != 0 or lod['cells'][c]['slot'] != slot:
            continue
        base = npos.get(p['node'], (0, 0, 0))
        for q in p['polys']:
            polys.append([tuple(base[k] + v[k] - mount[k] for k in range(3)) for v in q['v']])
    core = []
    for group in connected_groups(polys):
        pts = [v for k in group for v in polys[k]]
        if len(group) >= 3 and min(v[0] for v in pts) <= 0 <= max(v[0] for v in pts):
            core += pts
    if not core:
        return None
    return {'min': [int(min(v[k] for v in core)) for k in range(3)],
            'max': [int(max(v[k] for v in core)) for k in range(3)]}


def connected_groups(polys):
    """Polygon index groups that share vertices (union-find on rounded vertex positions)."""
    parent = list(range(len(polys)))

    def root(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    seen = {}
    for k, vs in enumerate(polys):
        for v in vs:
            key = tuple(int(round(x)) for x in v)
            if key in seen:
                parent[root(k)] = root(seen[key])
            else:
                seen[key] = k
    groups = {}
    for k in range(len(polys)):
        groups.setdefault(root(k), []).append(k)
    return list(groups.values())


# ---------------------------------------------------------------- ladder (AI loadouts)

def ladder(names_by_index):
    path = os.path.join(BD, 'DATA', 'NETDATA.DAT')
    d = open(path, 'rb').read()
    out = []
    for r in range(len(d) // 698):
        rec = d[698 * r:698 * (r + 1)]
        w = struct.unpack_from('<79i', rec, 0x11A)
        herc, armor, eng, shield, reactor = w[0], w[1], w[54], w[56], w[57]
        mounts = [w[58 + 3 * i:61 + 3 * i] for i in range(7)]
        if not (0 <= herc < 10 and 0 <= armor < 12 and 0 <= eng < 12 and 0 <= shield < 6 and 0 <= reactor < 6
                and all(-1 <= m[1] < 33 for m in mounts)):
            continue
        out.append({'rank': r + 1, 'pilot': rec[0x1C:0x28].split(b'\0')[0].decode('latin1'), 'herc': herc,
                    'armor': armor, 'engine': eng, 'shield': shield, 'reactor': reactor,
                    'weapons': [names_by_index.get(m[1]) for m in mounts], 'ammo': [m[2] for m in mounts],
                    'bays': [BAYS[m[0]] if m[0] >= 0 else None for m in mounts]})
    return out


# ---------------------------------------------------------------- conversion

def q_refire(ticks):
    """canFire: now - lastFire > refire (strict); fire processing runs in the 100 ms Herc update."""
    return (ticks // UPDATE + 1) * UPDATE * TICK


def unique_names(recs):
    cnt = collections.Counter(r['name'] for r in recs)
    for r in recs:
        r['key'] = r['name'].replace(' ', '') if cnt[r['name']] == 1 else '%s_%d' % (r['name'], r['capacity'])
    return {r['index']: r['key'] for r in recs}


def size_class(r):
    if r['class'] == 5:
        return 'special'
    if r['class'] == 4:
        return 'missile'
    for i, sz in enumerate(('light', 'medium', 'heavy')):
        if r['bays'][i]:
            return sz
    return 'heavy'


def build_weapon(r, row, snd, expl, herc_names):
    c = CLASSES[r['class']]
    name, title = r['key'], r['name'].title().replace('Bloodhnd', 'Bloodhound')
    if r['class'] in (4, 5):
        title = '%s (%d)' % (title, r['capacity'])
    sz = size_class(r)
    hit = expl[HIT_EXPLOSION[c]]
    w = {
        'name': name, 'display_name': title,
        'source': 'SIM.EXE weapon record 0x%x (index %d); class row %s' % (r['va'], r['index'], c),
        'size_class': sz,
        'hardpoint_mask': {'light': 7, 'medium': 15, 'heavy': 31}.get(sz, 7),
        'kind': None, 'range': None, 'refire': round(q_refire(r['refire_ticks']), 3), 'burst': 1,
        'burst_interval': 0.0, 'spread_deg': 0.0, 'ammo': -1, 'energy': None, 'heat': None,
        'damage': None, 'effects': {'emp_shield_drain': 0, 'elf_leech': 0, 'disable_seconds': 0},
        'projectile': None, 'beam': None,
        'model': {'mount_shapes': [], 'pod': 'baked into the Herc shape: cell slot of the hardpoint '
                  '(loadouts.json pods); states 0 idle, 1-4 firing frames, 6-10 damaged, 12 destroyed'},
        'sounds': {'fire': snd[r['class']], 'hit': snd_hit(hit, SOUNDS_CACHE)},
        'hit_shapes': ['bd:' + x for x in hit['shapes']],
        'notes': '',
        'native': {'record': {k: v for k, v in r.items() if k not in ('va', 'key')}, 'row': row,
                   'bays': [BAYS[i] for i in range(3) if r['bays'][i]] +
                           (['MINE LNCHR'] if r['mine_lnchr'] else []) + (['MSL LNCHR'] if r['msl_lnchr'] else []),
                   'hercs': [herc_names[i] for i in range(10) if r['hercs'][i]],
                   'refire_code_s': round(r['refire_ticks'] * TICK, 3), 'price': r['price']},
    }
    notes = ['refire = record %d ticks (%.2f s) rounded up to the 100 ms Herc update (strict > test).'
             % (r['refire_ticks'], r['refire_ticks'] * TICK)]
    energy = r['energy_divisor'] > 0
    if energy:
        w['energy'] = {'min_charge': r['min'], 'per_shot': r['per_shot'], 'capacity': r['capacity'],
                       'draw_divisor': r['energy_divisor'], 'leak_per_update': r['leak'],
                       'damage_per_charge': DMG_K}
        notes.append('capacitor: +((weapon_power/n_weapons + d/2)/d) per 100 ms (d = draw_divisor, weapon_power = '
                     'reactor output x 84/256, reduced by pod damage), capped at capacity; drains leak/update '
                     'without power. Fires when charge >= min_charge; uses min(charge, per_shot) and the shot '
                     'damage equals the charge used (x0.5 here).')
    if c == 'laser':
        d = r['per_shot'] << row['damage_shift']
        w.update(kind='beam', range=round(row['range'] * MPU, 1))
        w['damage'] = dmg(d, d, 0.25, row['splash_radius'])
        w['beam'] = {'color': [1.0, 0.15, 0.1], 'width': round(row['radius'] * MPU, 3), 'duration': 0.12, 'count': 1}
        notes.append('instant beam (raycast %d units); visible 0x1e ticks = 120 ms. Shield absorbs 1 point per '
                     'damage, beam stops if the shield holds. Beam colour not decoded (red assumed: RDLASER hit '
                     'sprite).' % row['range'])
    elif c == 'blaster':
        d = r['per_shot'] << row['damage_shift']
        life = 0x400 * TICK
        w.update(kind='plasma', range=round(row['speed'] * SPEED * life, 1))
        w['damage'] = dmg(d, d, 0.25, row['splash_radius'])
        w['projectile'] = proj(row['speed'] * SPEED, life, 'none', 'bd:BLASTER', 'glow')
        notes.append('energy bolt; shield absorbs min(shield, 3/4 dmg) 1:1 - at least 1/4 always leaks through.')
    elif c == 'plasma':
        d = r['per_shot'] // row['damage_divisor']
        life = d * 256 / row['decay'] * TICK
        w.update(kind='plasma', range=round(row['speed'] * SPEED * life, 1))
        w['damage'] = dmg(d, d, 0.8125, row['splash_radius'])
        w['projectile'] = proj(row['speed'] * SPEED, life, 'none', 'bd:PLASMBAL', 'glow')
        notes.append('damage decays linearly by %d per 1.024 s (%.0f/s) and the ball dies at 0 (lifetime shown '
                     'for a full charge). Shield absorbs 1:1 up to its value. On impact 1/4 of the remaining damage '
                     'hits (3/4 part, 1/4 radial) and 3/4 explodes as area damage (radius %d units, shields 2:1).'
                     % (row['decay'], row['decay'] / 1.024, row['splash_radius']))
    elif c == 'autocannon':
        d = row['damage']
        life = 0x300 * TICK
        w.update(kind='cannon', range=round(row['speed'] * SPEED * life, 1), ammo=r['capacity'] // max(1, r['per_shot']))
        w['damage'] = dmg(d / 4.0, d, 0.25, row['splash_radius'])
        w['projectile'] = proj(row['speed'] * SPEED, life, 'none', 'bd:CANON', 'none')
        notes.append('shells: a shield absorbs min(7/8 dmg, 4 x shield) and loses 1 point per 4 absorbed; at least '
                     '1/8 always penetrates. Ammo price %d per reload (record +0x60, meaning inferred).' % r['ammo_price'])
    elif c == 'missile_launcher':
        sp = row['cruise_speed'] * SPEED
        life = row['lifetime'] * TICK
        lat = row['max_lateral'] * ACCEL
        w.update(kind='missile', range=round(sp * life, 1), ammo=r['capacity'])
        w['damage'] = dmg(row['damage'] / 2.0, row['damage'], 1.0, row['blast_radius'])
        w['projectile'] = proj(sp, life, 'arh', 'bd:MISSILE', 'smoke')
        w['projectile'].update(turn_rate_deg=round(math.degrees(lat / sp), 1), proximity=round(row['proximity'] * MPU, 2),
                               launch_speed=round(row['launch_speed'] * SPEED, 1),
                               max_accel=round(row['max_thrust'] * ACCEL, 1), max_lateral_accel=round(lat, 1),
                               seeker_half_angle_deg=round(row['seeker_half_angle'] * ANGLE_DEG, 1),
                               cruise_altitude=round(row['cruise_altitude'] * MPU, 2),
                               dive_distance=round(row['dive_distance'] * MPU, 1))
        w['hit_shapes'].append('bd:SHROOM')
        notes.append('homes on the firing Herc\'s target at launch (Herc+0x17c); flies at %.1f m (+0..3.2 m random, '
                     '<= 3/4 ceiling) until within %.0f m, then dives. Steering a = 4 v sin(angle) clamped to %.0f m/s2 '
                     'while the target is inside +-%.0f deg, else straight. Fuse: < %.1f m, or < %.1f m and receding. '
                     'Shield hit with shield > %d: detonates on the shield at half damage and drains dmg/8. '
                     'Area damage hits every logical part within the blast radius with linear falloff.'
                     % (row['cruise_altitude'] * MPU, row['dive_distance'] * MPU, lat, row['seeker_half_angle'] * ANGLE_DEG,
                        row['proximity'] / 4 * MPU, row['proximity'] * MPU, row['shield_detonate_above']))
    else:
        w.update(kind='mine', range=round(row['detect_radius'] * MPU, 1), ammo=r['capacity'])
        w['damage'] = dmg(0, row['damage'], 1.0, row['blast_radius'])
        arm = row['scan_every_updates'] * row['update_ticks'] * TICK
        w['projectile'] = proj(row['max_speed'] * SPEED if row['chase_speed'] else 0.0, -1, 'none', 'bd:MINE', 'none')
        w['projectile'].update(gravity=0.0, arm_delay=round(arm, 2), proximity=round(row['trigger_distance'] * MPU, 2),
                               hover_height=round(row['hover_height'] * MPU, 2),
                               drop_speed=round(row['drop_speed'] * SPEED, 1),
                               detect_radius=round(row['detect_radius'] * MPU, 1),
                               chase=bool(row['chase_speed']), shootable=True)   # 'detonates when shot' (0x104b8)
        w['effects']['ignores_shields'] = True
        notes.append('dropped backwards at %.1f m/s (+ Herc velocity), stops and hovers %.2f m above the floor, spins. '
                     'Every %d updates of %d ms it scans %.1f m for Hercs/turrets/probes of the other side; one '
                     'closer than %.2f m sets it off, otherwise %s. Blast %.1f m radius, %d dmg to every part in range, '
                     'shields bypassed (part id -2). Detonates when shot. No lifetime.'
                     % (row['drop_speed'] * SPEED, row['hover_height'] * MPU, row['scan_every_updates'],
                        row['update_ticks'] * 4, row['detect_radius'] * MPU, row['trigger_distance'] * MPU,
                        'it chases the nearest one (speed <= %.1f m/s)' % (row['max_speed'] * SPEED)
                        if row['chase_speed'] else 'it stays put', row['blast_radius'] * MPU, row['damage']))
    w['notes'] = ' '.join(notes)
    return w


def dmg(shield_points, armour, splash, radius_units):
    """shield_points: BD shield points one hit removes (= ES1 shield points, 1:1); armour: BD damage (x DMG_K)."""
    return {'shield': round(shield_points, 1), 'armor': round(armour * DMG_K, 1), 'splash': splash,
            'splash_radius': round(radius_units * MPU, 2)}


def proj(speed, life, guidance, shape, trail):
    return {'speed': round(speed, 1), 'gravity': 0.0, 'lifetime': round(life, 3) if life >= 0 else -1,
            'guidance': guidance, 'turn_rate_deg': 0.0, 'arm_delay': 0.0, 'proximity': 0.0, 'shape': shape,
            'trail': trail}


SOUNDS_CACHE = []


def snd_hit(hit, snd):
    return snd[hit['sound_index']] if 0 <= hit['sound_index'] < len(snd) else None


# ---------------------------------------------------------------- sprites / sounds

def export_sprites():
    import dts
    n = 0
    for fx in SPRITE_FX:
        jp = os.path.join(OUT, 'shapes', fx + '.json')
        src = os.path.join(BD, 'DTS', fx + '.DTS')
        if not (os.path.exists(jp) and os.path.exists(src)):
            continue
        o = dts.read_obj(dts.Reader(open(src, 'rb').read(), 0))
        frames = []

        def walk(p):
            if p['type'] == 'bitmap_part':
                frames.append({'bitmap': p['bmp_tag'], 'xo': p['xo'], 'yo': p['yo'], 'radius': p['radius'],
                               'radius_m': round(p['radius'] * MPU, 3)})
            for c in p.get('parts', []):
                walk(c)
        walk(o)
        sj = json.load(open(jp))
        sj['sprite'] = {'texset': fx, 'frames': frames, 'frame_time': 0.1,
                        'note': 'cell_anim_part of bitmap_parts (camera-facing sprites, DBA index = bitmap, xo/yo = '
                                'hotspot pixels, radius = world size in units). Explosions advance one frame per '
                                '100 ms (SIM 0x11736) and fade their light 127->0; PLASMBAL frame = (t/100ms)%7 + '
                                '7*min(2, t*3/lifetime) (shrinks as the ball loses damage).'}
        json.dump(sj, open(jp, 'w'), separators=(',', ':'))
        n += 1
    return n


def export_sounds():
    import audio
    od = os.path.join(OUT, 'audio', 'sfx')
    os.makedirs(od, exist_ok=True)
    n = 0
    for f in sorted(glob.glob(os.path.join(BD, 'SOUND', '*.RAW')) + glob.glob(os.path.join(BD, 'SOUND', '*.SFX'))):
        audio.pcm_to_wav(f, os.path.join(od, os.path.splitext(os.path.basename(f))[0].lower() + '.wav'))
        n += 1
    return n


# ---------------------------------------------------------------- main

def main():
    s = Sim(os.path.join(BD, 'SIM.EXE'))
    s.check()
    recs = weapon_records(s)
    keys = unique_names(recs)
    snd = sound_list(s)
    SOUNDS_CACHE[:] = snd
    fire = {c: snd[s.b(va, 2)[1]] for c, va in FIRE_SOUND_PUSH.items()}
    expl = explosions(s)
    hs = hercs(s)
    herc_names = [h['name'].title() for h in hs]
    weapons = []
    for r in recs:
        weapons.append(build_weapon(r, class_rows(s, r), fire, expl, herc_names))
    # arena blaster turret (turret.cpp 0x15b34): twin BLASTER 2 bolts, 200 damage each
    b2 = class_rows(s, recs[8])
    tw = {'name': 'TURRET_BLASTER', 'display_name': 'Blaster turret', 'size_class': 'special', 'hardpoint_mask': 31,
          'source': 'SIM.EXE 0x15b34 (Turret::update) -> Blaster ctor 0xcc1c(index 8, charge 200) x2',
          'kind': 'plasma', 'range': round(b2['speed'] * SPEED * 0x400 * TICK, 1), 'refire': 0.7, 'burst': 2,
          'burst_interval': 0.0, 'spread_deg': 0.0, 'ammo': -1, 'energy': None, 'heat': None,
          'damage': dmg(200, 200, 0.25, b2['splash_radius']),
          'effects': {'emp_shield_drain': 0, 'elf_leech': 0, 'disable_seconds': 0},
          'projectile': proj(b2['speed'] * SPEED, 0x400 * TICK, 'none', 'bd:BLASTER', 'glow'), 'beam': None,
          'model': {'mount_shapes': ['bd:TURRET']}, 'sounds': {'fire': fire[1], 'hit': snd_hit(expl[5], snd)},
          'hit_shapes': ['bd:' + x for x in expl[5]['shapes']], 'category': 'turret',
          'notes': 'Arena hazard, not sold. Fires both barrels (logical parts 2 and 3) every 7 updates (0.7 s, update '
                   'period assumed 100 ms) during on-phases that toggle every 20-39 updates. Bolts carry no owner '
                   'side (hit anything).'}
    weapons.append(tw)
    eng = {'pack': 'bd', 'damage_scale_note': DAMAGE_NOTE,
           'units_note': 'distances 0.00215 m/unit, time 4 ms/tick, speeds units per 1.024 s; refire quantised to the '
                         '100 ms Herc update', 'weapons': weapons}
    os.makedirs(os.path.join(OUT, 'gameplay'), exist_ok=True)
    json.dump(eng, open(os.path.join(OUT, 'gameplay', 'weapons_engine.json'), 'w'), indent=1)

    # loadouts
    comps = components(s)
    lad = ladder(keys)
    pod_map = {h['shape']: pods(h) for h in hs}
    lo = {}
    meta_hercs = {}
    for h in hs:
        mine = [x for x in lad if x['herc'] == h['index']]
        cnt = collections.Counter(tuple(x['weapons']) for x in mine)
        best = list(cnt.most_common(1)[0][0]) if cnt else [None] * 7
        first = next((x for x in mine if tuple(x['weapons']) == tuple(best)), None)
        lo[h['shape']] = best
        meta_hercs[h['shape']] = {
            'name': h['name'].title(), 'index': h['index'],
            'bays': [BAYS[m[0]] if m[0] >= 0 else None for m in h['mounts']],
            'default_source': ('most common NETDATA.DAT AI loadout (%d of %d pilots)' % (cnt.most_common(1)[0][1], len(mine)))
            if cnt else 'no AI pilot uses this Herc',
            'components': None if not first else {
                'armor': comps['armor'][first['armor']]['name'], 'engine': comps['engines'][first['engine']]['name'],
                'shield': comps['shields'][first['shield']]['name'], 'reactor': comps['reactors'][first['reactor']]['name'],
                'ammo': first['ammo']},
        }
    for x in lad:
        x['herc'] = hs[x['herc']]['shape']
        x['armor'] = comps['armor'][x['armor']]['name']
        x['engine'] = comps['engines'][x['engine']]['name']
        x['shield'] = comps['shields'][x['shield']]['name']
        x['reactor'] = comps['reactors'][x['reactor']]['name']
    lo['pods'] = pod_map
    lo['meta'] = {
        'hardpoints': HARDPOINTS,
        'note': 'Herc key -> weapon name (weapons_engine.json) per hardpoint POD 1..4, MINE POD, MISSILE P1/P2; '
                'null = empty or no bay. Bought Hercs come bare (SHELL 0x1f7ac); a new pilot starts with a Stryder '
                'with LASER 1 x2 + MOSQUITO_15 (SHELL 0x11e2b).',
        'hercs': meta_hercs,
        'player_start': {'herc': 'STRYDER', 'weapons': ['LASER1', 'LASER1', None, None, None, 'MOSQUITO_15', None],
                         'engine': comps['engines'][4]['name'], 'source': 'SHELL.EXE 0x11b28 new pilot'},
        'ai_pilots': lad,
        'components': comps,
    }
    json.dump(lo, open(os.path.join(OUT, 'gameplay', 'loadouts.json'), 'w'), indent=1)
    ns = export_sprites()
    na = export_sounds()
    print('weapons %d, AI pilots %d, sprite shapes %d, sounds %d -> %s' % (len(weapons), len(lad), ns, na,
                                                                           os.path.abspath(OUT)))


if __name__ == '__main__':
    main()
