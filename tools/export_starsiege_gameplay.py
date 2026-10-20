"""Starsiege (1999) gameplay export -> gamedata/starsiege/{gameplay,shapes,textures,audio}.

Input: starsiege/extracted/scripts/*.cs (scripts.vol via tools/darkstar_lzh.py), starsiege/extracted/gameObjects/*.dts,
       starsiege/extracted/sound/*.wav (sound.vol).
Output:
  gameplay/weapons_engine.json   docs/formats/weapon_schema.md, all 53 newWeapon records (category "herc"),
                                 joined with datProjectile.cs; every weapon carries "ss_id" (datWeapon.cs id).
  gameplay/hercs.json            every Herc / tank / flyer / drone (datVehicle.cs) in an ENGINE-READY schema
                                 ("engine_schema": 1; loaded by game/engine/packs.gd _load_engine_vehicle):
                                 values already in engine units (m, m/s, rad, Earthsiege damage scale).
  gameplay/ids.json              {"vehicles": {ss_id: key}, "weapons": {ss_id: name}, "components": {id: {kind, name}}}
                                 (mission files reference vehicles / weapons / mountables by these numbers).
  audio/sfx/sim/<stem>.wav       weapon fire / impact sounds referenced by the weapons (PCM copies).
  shapes/<id>.json + textures/   every DTS in gameObjects (export_tribes.export_shape, Starsiege stand pose).
                                 Shape id = lower-case DTS basename without extension: "starsiege:xmarsrock1".

Conversions (see damage_scale_note / notes in the JSON):
  * damage x DAMAGE_SCALE (3.0): Starsiege Herc armour+internals 9-22k and shields ~940-2000 charge vs. ES1
    shields 3500 per pair of banks and ES1 Herc component totals 15-66k -> SS x3 lands both in the ES ranges.
  * energy x ENERGY_SCALE (1.6 = ES1 capacitor 960 / SS standard reactor battery 600).
  * hardpoint sizes S/M/L/X -> masks 7/15/31/63 (a weapon fits when hardpoint mask >= weapon mask, so S weapons
    fit every hardpoint and X hardpoints take everything); turret-only / internal weapons get 127 (never fit).

Usage: python tools/export_starsiege_gameplay.py [--no-shapes] [--shapes-only] [--cloak-only] [shape ...]
  gameplay/cloak.json            the cloak components (export_cloak); --cloak-only writes just this file.
"""
import glob, json, math, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wav_pcm  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SRC = os.path.join(ROOT, 'starsiege', 'extracted')
SCR = os.path.join(ROOT, 'starsiege', 'extracted', 'scripts')
OUT = os.path.join(ROOT, 'gamedata', 'starsiege')

DAMAGE_SCALE = 3.0
ENERGY_SCALE = 1.6
SIZE_MASK = {'S': 7, 'M': 15, 'L': 31, 'X': 63}
NO_FIT_MASK = 127
SIZE_CLASS = {'S': 'light', 'M': 'medium', 'L': 'heavy', 'X': 'special'}
GUIDANCE = {'H': 'heat', 'R': 'arh'}
FACTION = {'tr': 'Terran Empire (Imperial)', 'kn': 'Knights', 'rb': 'Rebels', 'pi': 'Pirates', 'cy': 'Cybrid',
           'mg': 'Cybrid (Metagen)', 'pl': 'Cybrid (Platinum Guard)', 'ha': "Harabec's Weasels", 'ca': 'Caanan',
           'cin': 'cinematic only', 'ss': 'civilian'}
CYBRID_FACTIONS = ('cy', 'mg', 'pl')
# Herc/tank leg & tread parts -> names the engine's leg-damage logic recognises (QUAD/SHIN/FOOT)
PART_ALIAS = {'leftleg': 'LEFT_QUAD', 'rightleg': 'RIGHT_QUAD', 'leftcalf': 'LEFT_SHIN', 'rightcalf': 'RIGHT_SHIN',
              'leftfoot': 'LEFT_FOOT', 'rightfoot': 'RIGHT_FOOT'}


def wjson(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent, separators=None if indent else (',', ':'))


def r(x, n=3):
    return round(float(x), n)


# ------------------------------------------------------------------ script parsing

def val(t):
    t = t.strip()
    if t.startswith('"') and t.endswith('"'):
        return t[1:-1]
    for f in (int, float):
        try:
            return f(t)
        except ValueError:
            pass
    return t


def calls_text(txt):
    """Table-style function calls `name(a, b, ...);` with '#' / '//' comments removed."""
    lines = []
    for ln in txt.splitlines():
        s = ln.strip()
        if s.startswith('#') or s.startswith('//'):
            continue
        ln = re.split(r'\)\s*;\s*(#|//).*$', ln)[0] + (');' if re.search(r'\)\s*;\s*(#|//)', ln) else '')
        lines.append(ln)
    txt = '\n'.join(lines)
    return [(m.group(1), [val(a) for a in m.group(2).split(',') if a.strip() != ''])
            for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\(([^()]*)\)\s*;', txt)]


def read(name):
    p = find_script(name)
    return open(p, encoding='latin1').read() if p else ''


_scripts = None


def find_script(name):
    global _scripts
    if _scripts is None:
        _scripts = {f.lower(): os.path.join(SCR, f) for f in os.listdir(SCR)}
    return _scripts.get(name.lower())


def strings():
    out = {}
    for f in glob.glob(os.path.join(SCR, '*.[Ss]trings.cs')):
        for m in re.finditer(r'^\s*(ID\w+)\s*=\s*\d+\s*,\s*"([^"]*)"', open(f, encoding='latin1').read(), re.M):
            out[m.group(1)] = m.group(2)
    return out


def sound_files():
    """IDSFX_* tag -> wav file name (sound.cs sfxAddPair)."""
    out = {}
    for c, a in calls_text(read('sound.cs')):
        if c == 'sfxAddPair' and len(a) >= 3:
            out[str(a[0])] = str(a[2])
    return out


# ------------------------------------------------------------------ sounds

_sound_dir = None
_sound_used = {}


def sound(wav):
    """Copy a WAV from sound.vol into audio/sfx/sim/ and return its stem reference "sim/<stem>" (or None)."""
    global _sound_dir
    if not wav:
        return None
    if _sound_dir is None:
        d = os.path.join(SRC, 'sound')
        _sound_dir = {f.lower(): os.path.join(d, f) for f in os.listdir(d)} if os.path.isdir(d) else {}
    src = _sound_dir.get(wav.lower())
    if not src:
        return None
    stem = os.path.splitext(wav)[0].lower()
    if stem not in _sound_used:
        dst = os.path.join(OUT, 'audio', 'sfx', 'sim', stem + '.wav')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        wav_pcm.copy_as_pcm(src, dst)
        _sound_used[stem] = os.path.basename(src)
    return 'sim/' + stem


# ------------------------------------------------------------------ projectiles / weapons

def projectiles():
    P = {}
    for c, a in calls_text(read('datProjectile.cs')):
        if c == 'newBullet':
            P[a[1]] = {'class': 'bullet', 'abbr': a[0], 'speed': a[2], 'range': a[3], 'glow': a[6:9], 'damage': a[9],
                       'blast': a[10], 'mix': a[11:15], 'pass_shield': a[15], 'pass_armor': a[16],
                       'vs_shield': a[17], 'vs_armor': a[18], 'shape': a[19]}
        elif c == 'newMissile':
            P[a[1]] = {'class': 'missile', 'abbr': a[0], 'start_speed': a[2], 'speed': a[3], 'accel': a[4],
                       'range': a[5], 'min_range': a[6], 'glow': a[9:12], 'damage': a[12], 'blast': a[13],
                       'mix': a[14:18], 'pass_shield': a[18], 'pass_armor': a[19], 'vs_shield': a[20],
                       'vs_armor': a[21], 'tracking': a[22], 'turn_rate': a[23], 'cruise': a[26], 'shape': a[31]}
        elif c == 'NewEnergy':
            P[a[1]] = {'class': 'energy', 'abbr': a[0], 'speed': a[2], 'range': a[3], 'glow': a[6:9], 'damage': a[9],
                       'blast': a[10], 'mix': a[11:15], 'pass_shield': a[15], 'pass_armor': a[16],
                       'vs_shield': a[17], 'vs_armor': a[18], 'shape': a[20]}
        elif c == 'NewBeam':
            P[a[1]] = {'class': 'beam', 'abbr': a[0], 'range': a[2], 'beam_length': a[3], 'tracking': a[5],
                       'speed': a[8], 'damage': a[10], 'var': a[11], 'blast': a[12], 'mix': a[13:17],
                       'pass_shield': a[17], 'pass_armor': a[18], 'vs_shield': a[19], 'vs_armor': a[20],
                       'near_width': a[22], 'far_width': a[23], 'glow': a[26:29]}
        elif c == 'newMine':
            P[a[1]] = {'class': 'mine', 'abbr': a[0], 'start_speed': a[2], 'speed': a[3], 'accel': a[4], 'duration': a[5],
                       'arm_delay': a[6], 'proximity': a[8], 'damage': a[9], 'blast': a[10], 'mix': a[11:15],
                       'pass_shield': a[15], 'pass_armor': a[16], 'vs_shield': a[17], 'vs_armor': a[18],
                       'turn_rate': a[19], 'shape': a[21]}
        elif c == 'newBomb':
            P[a[1]] = {'class': 'bomb', 'abbr': a[0], 'speed': a[2], 'damage': a[4], 'blast': a[5], 'mix': a[6:10],
                       'pass_shield': a[10], 'pass_armor': a[11], 'vs_shield': a[12], 'vs_armor': a[13],
                       'turn_rate': a[14], 'shape': a[15]}
    return P


def raw_weapons():
    out, cur = [], None
    for c, a in calls_text(read('datWeapon.cs')):
        if c == 'newWeapon':
            cur = {'id': a[0], 'shape': a[1], 'size': a[2], 'sfx': a[3], 'hp': a[4], 'tech': a[5], 'shots': []}
            out.append(cur)
        elif cur is None:
            continue
        elif c == 'weaponInfo1':
            cur['tag'], cur['long_tag'] = a[0], a[1]
        elif c == 'weaponInfo2':
            cur.update(tech_level=a[0], combat_value=a[1], mass=a[2])
        elif c == 'weaponMuzzle':
            cur['muzzle'] = a
        elif c == 'weaponGeneral':
            cur.update(reload=a[0], lock=a[1])
        elif c == 'weaponShot':
            cur['shots'].append(a)
        elif c == 'weaponEnergy':
            cur.update(proj=a[0], energy=(a[1], a[2]))
        elif c == 'weaponAmmo':
            cur.update(proj=a[0], ammo=(a[1], a[2], a[3]))
    return out


def shape_id(dts):
    if not isinstance(dts, str) or not dts.lower().endswith('.dts'):
        return None
    return 'starsiege:' + os.path.splitext(os.path.basename(dts))[0].lower()


def export_weapons(S, SFX, P):
    weapons, names = [], set()
    TECH = {'A': 'all', 'H': 'human', 'C': 'cybrid', 'X': 'alien/masters'}
    for w in raw_weapons():
        p = P.get(w.get('proj'), {})
        tag = str(w.get('tag', 'W%d' % w['id']))
        name = tag[6:] if tag.startswith('IDWEA_') else tag
        if name in names:
            name = '%s_%d' % (name, w['id'])
        names.add(name)
        disp = S.get(w.get('long_tag'), S.get(tag, name))
        cls = p.get('class', 'bullet')
        turret = disp.lower().startswith('turret') or name.startswith('TUR_')
        internal = w['shape'] == 'internal'
        notes = []
        # kind
        if internal and not turret:
            kind = 'other'
            notes.append('Electrohull: passive hull discharge (internal mountable 912 "electroHull"), not a hardpoint gun')
        elif cls == 'beam':
            kind = 'beam'
        elif cls == 'missile':
            kind = 'artillery' if p.get('range', 0) >= 3000 and p.get('cruise') == 'T' else 'missile'
        elif cls == 'mine':
            kind = 'mine'
        elif cls == 'bomb':
            kind = 'grenade'
            notes.append('bomb: dropped with zero velocity, falls under gravity (flyer weapon)')
        elif cls == 'energy':
            kind = 'emp' if p.get('vs_shield', 1) >= 4 else 'plasma'
        else:
            kind = 'artillery' if p.get('range', 0) >= 3000 else 'cannon'
        size = str(w['size']).upper()
        mask = NO_FIT_MASK if (turret or internal or size not in SIZE_MASK) else SIZE_MASK[size]
        # shots: distinct fire times = burst, same time = simultaneous beams
        times = sorted({float(s[3]) if len(s) > 3 else 0.0 for s in w['shots']}) or [0.0]
        nshots = max(1, len(w['shots']))
        burst, burst_iv, count = 1, 0.0, 1
        if len(times) > 1:
            burst, burst_iv = len(times), r(times[1] - times[0])
        elif nshots > 1:
            count = nshots
        dmg = float(p.get('damage', 0))
        vs_s = float(p.get('vs_shield', 1.0) if p.get('vs_shield') is not None else 1.0)
        vs_a = float(p.get('vs_armor', 1.0) if p.get('vs_armor') is not None else 1.0)
        blast = float(p.get('blast', 0) or 0)
        energy = {'min_charge': 0, 'per_shot': 0}
        ammo = -1
        if 'energy' in w:
            lim, rate = w['energy']
            energy = {'min_charge': int(round(lim * ENERGY_SCALE)), 'per_shot': int(round(lim * ENERGY_SCALE)),
                      'ss_charge_limit': lim, 'ss_charge_rate': rate}
        if 'ammo' in w:
            mx, st, rpv = w['ammo']
            ammo = max(1, int(mx // max(1, rpv)))
            if rpv > 1:
                notes.append('magazine %d rounds, %d rounds per trigger pull (ammo = trigger pulls)' % (mx, rpv))
        rng = float(p.get('range', 0) or 0)
        speed = float(p.get('speed', 0) or 0)
        proj = None
        if kind not in ('beam', 'other'):
            gravity = 0.0
            if kind in ('artillery',) and cls == 'bullet':
                gravity = 9.8
            if cls in ('bomb', 'mine'):
                gravity = 9.8
            spd = speed if speed > 0 else (50.0 if cls in ('mine', 'bomb') else 300.0)
            guid = GUIDANCE.get(str(p.get('tracking', '')).upper(), 'none') if cls == 'missile' else 'none'
            prox = 0.0
            if cls == 'mine':
                prox = float(p.get('proximity') or 0)   # 0: goes off on contact (the ARAC spider mine)
            proj = {
                'speed': r(spd), 'gravity': gravity,
                'lifetime': r(float(p.get('duration', 0)) if cls == 'mine' else (rng / spd * (1.05 if not gravity else 1.6) if rng and spd else 0.0)),
                'guidance': guid,
                'turn_rate_deg': r(math.degrees(float(p.get('turn_rate') or 0))) if guid != 'none' or cls == 'mine' else 0.0,
                'arm_delay': r(float(p.get('arm_delay', 0) or 0)),
                'proximity': r(prox),
                'shape': shape_id(p.get('shape')),
                'trail': 'smoke' if cls == 'missile' else ('glow' if cls == 'energy' else 'none'),
                'ss_class': cls, 'ss_abbr': p.get('abbr'),
            }
            if cls == 'missile':
                proj.update(start_speed=p.get('start_speed'), accel=p.get('accel'), min_range=p.get('min_range'))
            if cls == 'mine':
                proj.update(start_speed=float(p.get('start_speed') or 0), accel=float(p.get('accel') or 0))
                if prox <= 0.0:
                    proj['trigger'] = 'contact'
                notes.append('turn_rate_deg = degrees(turn rate 1 %s, assumed rad/s)' % p.get('turn_rate'))
        beam = None
        if kind == 'beam':
            g = p.get('glow') or [255, 0, 0]
            col = [r(c / 255.0) for c in g[:3]] if any(g[:3]) else None
            mz = w.get('muzzle')
            if col is None and mz and len(mz) >= 6:
                col = [r(float(c) / 255.0) for c in mz[3:6]]
            beam = {'color': col or [1.0, 1.0, 1.0], 'width': r(max(float(p.get('near_width') or 0.15), 0.05)),
                    'duration': 0.12, 'count': count, 'length': p.get('beam_length'),
                    'speed': p.get('speed')}
        # sounds
        fire = sound(SFX.get(str(w['sfx'])))
        if cls == 'bullet' and blast <= 0:
            hit = sound('bullet_armor.wav')
        elif blast >= 8:
            hit = sound('explosionLarge.wav')
        elif blast >= 2:
            hit = sound('explo3.wav')
        else:
            hit = sound('exploNear2.wav') if cls not in ('beam',) else None
        snd = {k: v for k, v in (('fire', fire), ('hit', hit)) if v}
        rec = {
            'name': name, 'display_name': disp, 'ss_id': w['id'], 'category': 'herc',
            'source': 'datWeapon.cs newWeapon(%d) + datProjectile.cs %s id %s' % (w['id'], cls, w.get('proj')),
            'size': size, 'size_class': SIZE_CLASS.get(size, 'special'), 'hardpoint_mask': mask, 'kind': kind,
            # mines/bombs have no range in the tables: aim distance only (mines drop behind the vehicle)
            'range': r(rng if rng else (150.0 if kind in ('grenade', 'mine') else 0.0)),
            'refire': r(w.get('reload', 1.0)), 'burst': burst, 'burst_interval': burst_iv, 'spread_deg': 0.0,
            'ammo': ammo, 'energy': energy, 'heat': None,
            'damage': {'shield': r(dmg * vs_s * DAMAGE_SCALE, 1), 'armor': r(dmg * vs_a * DAMAGE_SCALE, 1),
                       'splash': (1.0 if blast >= 2 else (0.5 if blast > 0 else 0.0)), 'splash_radius': r(blast),
                       'ss_damage': dmg, 'vs_shield': vs_s, 'vs_armor': vs_a,
                       'pass_shield': p.get('pass_shield'), 'pass_armor': p.get('pass_armor'),
                       'mix_concussion_electric_thermal_special': p.get('mix')},
            'effects': {'emp_shield_drain': r(dmg * vs_s * DAMAGE_SCALE, 1) if kind == 'emp' else 0,
                        'elf_leech': 0, 'disable_seconds': 0},
            'projectile': proj, 'beam': beam,
            'model': pod_model(w),
            'sounds': snd,
            'cybrid_only': w['tech'] == 'C',
            'tech_base': TECH.get(w['tech'], w['tech']), 'tech_level': w.get('tech_level'),
            'mass_t': w.get('mass'), 'hp': r(float(w['hp']) * DAMAGE_SCALE, 1), 'lock_time': w.get('lock', 0.0),
            'fire_offset_m': (w['shots'][0][:3] if w['shots'] else None),
            'turret_only': turret, 'notes': '; '.join(notes),
        }
        weapons.append(rec)
    return weapons


def pod_model(w):
    """Weapon model on a hardpoint (docs/formats/weapon_mounts.md section 4): the shape, mounted with its
    origin on the hardpoint (Starsiege.exe 0x4bc858 / 0x494e34: no scale), and its muzzles, the
    weaponShot offsets in the weapon's own frame (handler 0x413e5d, WeaponDef +0x148; they sit on the
    barrel tips), metres = shape units."""
    shots = [[float(v) for v in s[:3]] for s in w['shots'] if len(s) >= 3]
    return {'mount_shapes': [shape_id(w['shape'])] if shape_id(w['shape']) else [],
            'muzzle_units': shots[0] if shots else None, 'fire_offsets': shots}


# ------------------------------------------------------------------ vehicles

def vehicle_ids():
    """datVehicle.cs build*(id, ..., "datX.cs") -> {script lower: (id, techbase or None)}."""
    out = {}
    txt = read('datVehicle.cs')
    for m in re.finditer(r'^\s*build(Herc|Tank|Drone|Flyer)\s*\(\s*(\d+)\s*,(?:\s*"(\w)"\s*,)?\s*"([^"]+)"', txt, re.M):
        out[m.group(4).lower()] = (int(m.group(2)), m.group(3), m.group(1).lower())
    return out


def drone_generic(n):
    txt = read('datDroneGeneric.cs')
    m = re.search(r'function\s+genericDrone\s*\([^)]*\)\s*\{(.*)\}\s*$', txt, re.S)
    body = m.group(1) if m else ''
    body = re.sub(r'if\s*\(\s*%cargoCount\s*>\s*(\d+)\s*\)\s*\{([^}]*)\}',
                  lambda mm: mm.group(2) if n > int(mm.group(1)) else '', body)
    return calls_text(body)


def vehicle_calls(fname):
    out = []
    for c, a in calls_text(read(fname)):
        if c == 'genericDrone':
            out.extend(drone_generic(int(a[0]) if a else 0))
        else:
            out.append((c, a))
    return out


_shape_cache = {}


def shape_geom(dts):
    """(height_m, head node position) of a DTS in its standing pose (LOD 0); None if missing."""
    key = dts.lower()
    if key in _shape_cache:
        return _shape_cache[key]
    import darkstar_dts as D
    import export_starsiege as ESS
    res = None
    path = find_dts(dts)
    if path:
        try:
            s = D.read_shape(open(path, 'rb').read())
            pose = ESS.stand_pose(s)
            W = D.world_matrices(dict(s, nodes=[dict(nd, default=pose[i]) for i, nd in enumerate(s['nodes'])]))
            nodes = set(D.detail_nodes(s, 0))
            pts = []
            for o in s['objects']:
                if o['node'] not in nodes or s['names'][o['name']] in ('bounds', 'coll0'):
                    continue
                R, T = W[o['node']]
                for v in D.mesh_frame_verts(s['meshes'][o['mesh']]):
                    pts.append([T[a] + sum(R[a][k] * v[k] for k in range(3)) for a in range(3)])
            root = s['details'][0]['root'] if s['details'] else 0
            head = _head_node(s, nodes)
            ref_rot, ref = W[head if head is not None else root]
            ext = [max(p[a] for p in pts) - min(p[a] for p in pts) for a in range(3)] if pts else [0, 0, 0]
            res = {'height_m': r(ext[2], 2), 'length_m': r(ext[1], 2), 'width_m': r(ext[0], 2),
                   'min_z': r(min(p[2] for p in pts), 3) if pts else 0.0,
                   'ref_node': s['names'][s['nodes'][head if head is not None else root]['name']],
                   'ref_pos': [r(x, 3) for x in ref], 'ref_rot': ref_rot,
                   'torso_node': head if head is not None else -1,
                   'lower_body_nodes': _lower_body_children(s, head) if head is not None else []}
        except Exception as e:  # noqa: BLE001
            res = {'error': '%s: %s' % (type(e).__name__, e)}
    _shape_cache[key] = res
    return res


def _head_node(s, nodes):
    """LOD-0 "head" node: Starsiege turns it for the torso twist / tank turret (Starsiege.exe 0x443278 finds
    "head0", 0x445838-0x445860 sets its rotation to EulerF(0, 0, yaw) every frame) and mounts every hardpoint on
    it (0x4952c1: hardpoints without a node name use "head0"). None when the shape has no head."""
    for i in sorted(nodes):
        if s['names'][s['nodes'][i]['name']].lower().startswith('head'):
            return i
    return None


# Leg / hip node names in the Herc DTS files (Left_Leg0, Right_Calf2, Left_Thigh0, Right_Foot1, Pelvis0 ...).
LOWER_BODY_WORDS = ('leg', 'calf', 'thigh', 'foot', 'pelvis')


def _lower_body_children(s, node):
    """Children of `node` that carry the legs or hips (Basilisk, Minotaur, Goad, Executioner, Emancipator, Olympian
    hang their legs below the head): the engine counter-rotates them so the torso twist leaves the legs planted."""
    return [i for i, nd in enumerate(s['nodes'])
            if nd['parent'] == node and _has_lower_body(s, i)]


def _has_lower_body(s, node):
    if any(w in s['names'][s['nodes'][node]['name']].lower() for w in LOWER_BODY_WORDS):
        return True
    return any(_has_lower_body(s, i) for i, nd in enumerate(s['nodes']) if nd['parent'] == node)


def node_local(rot, offset):
    """Shape-frame offset -> the node's frame (rot = node->shape rotation, rows = shape axes)."""
    return [sum(rot[k][a] * offset[k] for k in range(3)) for a in range(3)]


def _muzzle_units(geo, offset):
    """Hardpoint muzzle in the head node's frame, or in the shape-root frame when the shape has no head."""
    if geo.get('torso_node', -1) < 0:
        ref = geo.get('ref_pos', [0.0, 0.0, 0.0])
        return [r(ref[i] + offset[i], 3) for i in range(3)]
    return [r(x, 3) for x in node_local(geo['ref_rot'], offset)]


def torso_rig(kind, geo):
    """Which nodes the engine turns (docs/formats/animation.md "Torso and turret"). The original turns only the
    head node, by the torso / turret yaw. Herc: the head also carries the view and the engine's torso pitch
    (legs hanging below it are counter-rotated). Tank / drone: the head is the turret; the hardpoint weapons
    pitch on their own (newHardPoint X_rot_rnge), the view follows the turret from the chase camera."""
    head = geo.get('torso_node', -1)
    if kind == 'herc':
        return {'torso_node': head, 'cockpit_node': head, 'lower_body_nodes': geo.get('lower_body_nodes', [])}
    if kind in ('tank', 'drone'):
        return {'torso_node': head, 'cockpit_node': -1, 'pitch_mounts': head >= 0}
    return {}


def herc_anim(anim):
    """Gait sequences and switch speeds of a Herc (hercAnim(toStandVel, toRunVel, toFastRunVel m/s,
    toFastTurnVel deg/s); sequence names are the DTS suffixes Seq00_walk, Seq01_run, Seq02_stand,
    Seq05_t22 / Seq06_t45 (turn in place 22.5 / 45 deg per cycle), Seq08_frun). docs/formats/animation.md"""
    if not anim or len(anim) < 4:
        return None
    return {'stand': 'stand', 'walk': 'walk', 'run': 'run', 'fast_run': 'frun', 'turn': 't22', 'fast_turn': 't45',
            'stand_speed': r(anim[0]), 'run_switch_speed': r(anim[1]), 'fast_run_speed': r(anim[2]),
            'fast_turn_rate': r(math.radians(float(anim[3])))}


_dts_index = None


def find_dts(name):
    global _dts_index
    if _dts_index is None:
        _dts_index = {}
        d = os.path.join(SRC, 'gameObjects')
        if os.path.isdir(d):
            for f in os.listdir(d):
                _dts_index.setdefault(f.lower(), os.path.join(d, f))
    return _dts_index.get(name.lower())


def component_table(S):
    import catalog_starsiege as C
    C.SCR = SCR
    comps = C.components(S)
    table = {}
    for kind, lst in comps.items():
        for x in lst:
            raw = x.get('raw') or []
            if not raw or not isinstance(raw[0], int):
                continue
            k = kind if kind != 'internal' else x.get('kind', 'internal')
            table[raw[0]] = dict(x, kind=k)
    return table


# ------------------------------------------------------------------ cloaks

SENSOR_MODE_FIELDS = ('base', 'range', 'shutdown', 'squat', 'stop', 'slow', 'fast', 'activ', 'camo', 'jam', 'shld', 'tjam')
STANDARD_SENSOR_ID = 408
CLOAK_SPEC_TAGS = {830: 'IDSPEC_CLK1', 831: 'IDSPEC_CLK2'}
CLOAK_ORDER = 'cloak'
MASK_RATING_RX = re.compile(r'Mask Rating:\s*<Jr>(\d+)')


def sensor_modes():
    """datSensor.cs: {sensor id: {'a'|'p': {sweep_s, base, range, ..., camo, ...}}} from newSensor / sensorMode."""
    out, current, sweep = {}, None, 0.0
    for call, args in calls_text(read('datSensor.cs')):
        if call == 'newSensor':
            current, sweep = int(args[0]), float(args[1])
            out[current] = {}
        elif call == 'sensorMode' and current is not None:
            mode = dict(zip(SENSOR_MODE_FIELDS, [float(a) for a in args[1:]]))
            out[current][str(args[0]).lower()] = dict(mode, sweep_s=sweep)
    return out


def export_cloak(S, SFX, comps):
    """gameplay/cloak.json: the Chameleon / Cuttlefish cloaks (datIntMounts.cs newCloak: id, rating, dmg_amt_glitch,
    glitch_coef, dmg_amt_fail, fail_coef) with the sensors' `camo` modifiers (datSensor.cs sensorMode) the cloak earns
    against a standard sensor, every sensor's modes (a Herc's own sensor decides how well it sees a cloak: the Emission
    Scanning and Cybrid Motion sensors have camo -0.5), and the action's sound (sound.cs IDSFX_CAMOUFLAGE)."""
    sensors = sensor_modes()
    standard = sensors.get(STANDARD_SENSOR_ID, {})
    camo = {m: [min(x[m]['camo'] for x in sensors.values() if m in x), max(x[m]['camo'] for x in sensors.values() if m in x)]
            for m in ('a', 'p')}
    profiles = {}
    for cid, c in sorted(comps.items()):
        if c['kind'] != 'cloak':
            continue
        raw = c['raw']
        rating = MASK_RATING_RX.search(S.get(CLOAK_SPEC_TAGS.get(cid, ''), ''))
        profiles['starsiege:%d' % cid] = {
            'id': 'starsiege:%d' % cid, 'name': c['name'], 'kind': 'component', 'component_id': cid,
            'source': 'scripts/datIntMounts.cs newCloak (%s)' % ', '.join(str(x) for x in raw),
            'mask_rating': int(rating.group(1)) if rating else int(raw[1]) // 10,
            'glitch_health': r(raw[2]), 'glitch_coef': r(raw[3]), 'fail_health': r(raw[4]), 'fail_coef': r(raw[5]),
            'sensor_modes': standard, 'sensor_camo_range': camo, 'sensor_id': STANDARD_SENSOR_ID,
            'energy_per_s': 0.0, 'breaks_on': [], 'reveal_range_m': 0.0, 'ai_uses': True, 'ai_order': CLOAK_ORDER,
            'sound_toggle': 'starsiege:' + str(sound(SFX.get('IDSFX_CAMOUFLAGE', ''))).replace('sim/', ''),
            'note': 'No energy, firing or damage rule exists in the data; the camo modifier of each sensor is the rule.'}
    sensor_table = {'starsiege:%d' % sid: dict(modes, name=comps.get(sid, {}).get('name', '')) for sid, modes in sorted(sensors.items())}
    wjson(os.path.join(OUT, 'gameplay', 'cloak.json'),
          {'pack': 'starsiege', 'engine_schema': 1, 'profiles': profiles, 'sensors': sensor_table}, indent=1)
    return len(profiles)


def export_vehicles(S, W, comps):
    ids = vehicle_ids()
    wby_id = {w['ss_id']: w for w in W}
    out, idmap, keys = {}, {}, set()
    order = {'herc': 0, 'tank': 1, 'flyer': 2, 'drone': 3}   # Hercs keep the plain key on a name clash
    files = sorted(glob.glob(os.path.join(SCR, 'dat*.cs')),
                   key=lambda p: (order.get((re.match(r'dat([a-z]+)_', os.path.basename(p), re.I) or [None, ''])[1].lower(), 9), p.lower()))
    for f in files:
        base = os.path.basename(f)
        m = re.match(r'dat(Herc|Tank|Flyer|Drone)_(.+)\.cs$', base, re.I)
        if not m or base.lower() == 'datdronegeneric.cs':
            continue
        kind = m.group(1).lower()
        stem = m.group(2)
        fac = stem.split('_')[0].lower() if '_' in stem else ('ha' if 'pred' in stem.lower() else stem.lower())
        C = vehicle_calls(base)
        get = lambda n: next((a for c, a in C if c.lower() == n.lower()), None)
        b = get(kind + 'Base')
        if not b:
            continue
        vid = ids.get(base.lower())
        key = stem.lower()
        if key in keys:
            key = '%s_%s' % (kind, key)
        keys.add(key)
        side = 'cybrid' if (fac in CYBRID_FACTIONS or (vid and vid[1] == 'C')) else 'herc'
        dts = b[2]
        geo = shape_geom(dts) or {}
        notes = []
        chassis_t = float(b[3])
        # ---- hardpoints / guns
        hps = [a for c, a in C if c == 'newHardPoint']
        guns = []
        head = geo.get('torso_node', -1)
        for a in hps:
            size = str(a[1]).upper()
            off = [float(x) for x in a[4:7]]
            g = {'hardpoint': a[0], 'size': size, 'hardpoint_mask': SIZE_MASK.get(size, 7), 'side': a[2],
                 'damage_parent': a[3], 'offset_m': off, 'mount_node': -1,
                 # Offset_fm_Node: the hardpoint sits on the head node (Starsiege.exe 0x4952c1), so the muzzle
                 # (original units = metres) hangs off that node and turns with the torso / turret
                 'attach_node': head, 'muzzle_units': _muzzle_units(geo, off)}
            if len(a) >= 11:
                g.update(pitch_min_deg=a[7], pitch_max_deg=a[8], yaw_min_deg=a[9], yaw_max_deg=a[10])
            guns.append(g)
        # ---- default loadout
        dw = get('defaultWeapons') or []
        loadout = []
        for i in range(len(guns)):
            wid = dw[i] if i < len(dw) else 0
            w = wby_id.get(wid) if isinstance(wid, int) else None
            loadout.append('starsiege:%s' % w['name'] if w else '')
        # ---- mountables
        mps = [{'id': a[0], 'size': a[1], 'damage_parent': a[2], 'allowed': a[3:]} for c, a in C if c == 'newMountPoint']
        dm = get('defaultMountables') or []
        mounted = []
        for x in dm:
            if isinstance(x, int) and x > 0:
                cpt = comps.get(x)
                mounted.append({'id': x, 'kind': cpt['kind'] if cpt else None, 'name': cpt.get('name') if cpt else None})
        mass_items = [float(wby_id[x]['mass_t'] or 0) for x in dw if isinstance(x, int) and x in wby_id] + \
                     [float(comps[m_['id']].get('mass_t') or 0) for m_ in mounted
                      if m_['id'] in comps and isinstance(comps[m_['id']].get('mass_t'), (int, float))
                      and comps[m_['id']]['kind'] != 'armor']
        total_t = chassis_t + sum(mass_items)
        eng = next((comps[m_['id']] for m_ in mounted if m_['kind'] == 'engine'), None)
        rea = next((comps[m_['id']] for m_ in mounted if m_['kind'] == 'reactor'), None)
        shl = next((comps[m_['id']] for m_ in mounted if m_['kind'] == 'shield'), None)
        amp = next((comps[m_['id']] for m_ in mounted if m_['kind'] == 'amplifier'), None)
        vel_f = acc_f = 1.0
        if eng:
            vel_f = min(1.0, float(eng['velocity_rating']) / total_t / 100.0)
            acc_f = min(1.0, float(eng['accel_rating']) / total_t / 100.0)
        # ---- motion
        pos = get(kind + 'Pos') or []
        rot = get(kind + 'Rot') or []
        anim = get(kind + 'Anim') or []
        rec_motion = {}
        if kind in ('herc', 'tank', 'drone') and len(pos) >= 4:
            rec_motion = {'max_speed': r(pos[2] * vel_f), 'reverse_speed': r(abs(pos[3]) * vel_f),
                          'accel': r(pos[0] * acc_f)}
        elif kind == 'flyer' and len(pos) >= 5:
            rec_motion = {'max_speed': r(pos[4] * vel_f), 'reverse_speed': 0.0, 'accel': r(pos[4] * vel_f / 3.0)}
            notes.append('flyer: accel = max_speed/3 (flyerPos maxPosAcc %s is a thrust figure)' % pos[0])
        if kind == 'flyer' and len(rot) >= 3:
            turn = math.radians(rot[2])
            rec_motion.update(turn_rate=r(turn), turn_rate_still=r(turn), torso_rate=0.0, torso_limit=0.0)
        elif len(rot) >= 3:
            rec_motion.update(turn_rate=r(math.radians(rot[1])), turn_rate_still=r(math.radians(rot[1])),
                              turn_rate_fast=r(math.radians(rot[2])))
            if kind in ('tank', 'drone') and len(rot) >= 4:
                rec_motion.update(torso_rate=r(math.radians(rot[3])), torso_limit=r(math.pi))
            else:
                rec_motion.update(torso_rate=r(math.radians(60.0)), torso_limit=r(math.radians(90.0)))
                notes.append('torso_rate 60 deg/s / torso_limit 90 deg assumed (not in the scripts)')
        ext = [g for g in guns if g['side'] != 'I'] or guns
        if ext and 'pitch_max_deg' in ext[0]:
            pmax = min(float(g['pitch_max_deg']) for g in ext)
            pmin = max(float(g['pitch_min_deg']) for g in ext)
        else:
            pmax, pmin = 30.0, -20.0
        rec_motion.update(pitch_max=r(math.radians(pmax)), pitch_min=r(math.radians(pmin)),
                          pitch_rate=rec_motion.get('torso_rate', r(math.radians(60.0))) or r(math.radians(45.0)))
        # ---- shields / energy
        shield_max = shield_rate = 0.0
        if shl:
            shield_max = float(shl['charge_limit']) * DAMAGE_SCALE
            shield_rate = float(shl['charge_rate']) * DAMAGE_SCALE / 2.0     # engine adds the rate to each of 2 banks
            if amp and isinstance(amp.get('raw'), list) and len(amp['raw']) > 2:
                shield_max *= float(amp['raw'][2])
        cap_rate = float(rea['output']) * ENERGY_SCALE if rea else 0.0
        # ---- damage model
        comp_raw = [a for c, a in C if c == 'newComponent']
        conf = [a for c, a in C if c == 'newConfiguration']
        internal = {str(a[0]): float(a[3]) for a in comp_raw}
        external = [a for a in comp_raw if str(a[0]).lower() not in ('armor', 'leftservos', 'rightservos', 'pilot')]
        idx = {str(a[0]).lower(): i for i, a in enumerate(external)}
        comps_out = []
        for a in external:
            nm = str(a[0])
            hp = float(a[3])
            folded = {}
            for cf in conf:
                if str(cf[1]).lower() == nm.lower() and str(cf[0]) in internal:
                    add = internal[str(cf[0])] * float(cf[2])
                    hp += add
                    folded[str(cf[0])] = r(add, 1)
            parent = str(a[2]).lower()
            pi = idx.get(parent, -1)
            alias = PART_ALIAS.get(nm.lower(), nm.upper())
            root = pi < 0
            comps_out.append({'name': alias, 'ss_name': nm, 'hp': r(hp * DAMAGE_SCALE, 1),
                              'ss_hp': r(hp, 1), 'folded_ss': folded,
                              'fatal': root or nm.lower() in ('head', 'tankhead', 'flyerhead'),
                              'parent': pi})
        pilot = next((float(a[3]) for a in comp_raw if str(a[0]).lower() == 'pilot'), None)
        name = S.get(b[0], b[0])
        rec = {
            'engine_schema': 1, 'ss_id': vid[0] if vid else None, 'tag': b[0], 'abbr': b[1], 'file': base,
            'kind': kind, 'side': side, 'faction': FACTION.get(fac, fac), 'category': 'herc',
            'pilotable': kind in ('herc', 'tank'), 'name': name,
            'shape': shape_id(dts) or 'starsiege:' + dts.lower(),
            'size_class': 3 if side == 'cybrid' and kind == 'herc' else (0 if chassis_t <= 8 else (1 if chassis_t <= 12 else 2)),
            'weight': 'light' if chassis_t <= 8 else ('medium' if chassis_t <= 12 else 'heavy'),
            'mass': r(total_t, 2), 'chassis_mass': chassis_t,
            'max_mass': b[4] if len(b) > 4 else None,
        }
        rec.update(rec_motion)
        rec.update({
            'run_switch_speed': r(anim[1]) if kind == 'herc' and len(anim) > 1 else None,
            'shield_max': r(shield_max, 1), 'shield_recharge': r(shield_rate, 2), 'capacitor_rate': r(cap_rate, 1),
            'height_m': geo.get('height_m'), 'length_m': geo.get('length_m'), 'width_m': geo.get('width_m'),
            'guns': guns, 'mountpoints': mps,
            'damage': {'components': comps_out, 'pilot_hp': r(pilot * DAMAGE_SCALE, 1) if pilot else None},
            'default_loadout': loadout,
            'default_mountables': mounted,
            'speed_factor': {'total_mass_t': r(total_t, 2), 'engine_velocity': r(vel_f), 'engine_accel': r(acc_f)},
            'ss_raw': {'pos': pos, 'rot': rot, 'anim': anim, 'coll': get(kind + 'Coll'), 'cpit': get(kind + 'Cpit'),
                       'default_weapons': dw, 'default_mountables': dm},
            'notes': '; '.join(notes),
        })
        rec.update(torso_rig(kind, geo))
        if kind == 'herc' and herc_anim(anim):
            rec['anim'] = herc_anim(anim)
        if 'error' in geo:
            rec['notes'] += ('; ' if rec['notes'] else '') + 'shape read failed: ' + geo['error']
        out[key] = rec
        if vid:
            idmap[str(vid[0])] = key
    return out, idmap


# ------------------------------------------------------------------ shapes

def export_shapes(names=None):
    import export_tribes as ET
    import export_starsiege as ESS
    import darkstar_gfx as G
    ET.SRC, ET.OUT = SRC, OUT
    ET.WORLD_PPL = ('Mars.Sim', 'Mars.d.ppl')
    ET.root_pose = ESS.stand_pose
    # cached, case-insensitive file lookup (gameObjects first, as export_tribes' directory scan order may vary)
    idx = {}
    dirs = sorted(d for d in os.listdir(SRC) if os.path.isdir(os.path.join(SRC, d)))
    dirs.sort(key=lambda d: d.lower() != 'gameobjects')
    for d in dirs:
        for f in os.listdir(os.path.join(SRC, d)):
            idx.setdefault(f.lower(), os.path.join(SRC, d, f))
    ET.find_file = lambda n: idx.get(n.lower())
    ppl = G.read_ppl(open(os.path.join(SRC, *ET.WORLD_PPL), 'rb').read())
    if not names:
        d = os.path.join(SRC, 'gameObjects')
        names = sorted({os.path.splitext(f)[0].lower() for f in os.listdir(d) if f.lower().endswith('.dts')})
    ok, failed = [], {}
    t0 = time.time()
    for i, n in enumerate(names):
        try:
            ET.export_shape(n.lower(), ppl)
            ok.append(n.lower())
        except Exception as e:  # noqa: BLE001
            failed[n] = '%s: %s' % (type(e).__name__, e)
        if (i + 1) % 50 == 0:
            print('  shapes %d/%d (%.0fs)' % (i + 1, len(names), time.time() - t0))
            sys.stdout.flush()
    write_shape_index()
    wjson(os.path.join(OUT, 'gameplay', 'shape_export_report.json'),
          {'exported': len(ok), 'failed': failed, 'id_rule': 'starsiege:<lower-case dts basename>'}, indent=1)
    return ok, failed


def write_shape_index():
    """shapes/_index.json in the shape-viewer format ([{name, kind}], game/tools/shape_viewer.gd)."""
    wjson(os.path.join(OUT, 'shapes', '_index.json'), [{'name': n, 'kind': 'darkstar'} for n in sorted(_existing_shapes())])


def _existing_shapes():
    d = os.path.join(OUT, 'shapes')
    return [os.path.splitext(f)[0] for f in os.listdir(d) if f.endswith('.json') and not f.startswith('_')] if os.path.isdir(d) else []


# ------------------------------------------------------------------ main

def main():
    args = [a for a in sys.argv[1:]]
    no_shapes = '--no-shapes' in args
    if '--cloak-only' in args:
        S, SFX = strings(), sound_files()
        print('cloaks', export_cloak(S, SFX, component_table(S)))
        return
    shapes_only = '--shapes-only' in args
    names = [a for a in args if not a.startswith('--')]
    if not shapes_only:
        S = strings()
        SFX = sound_files()
        P = projectiles()
        W = export_weapons(S, SFX, P)
        wjson(os.path.join(OUT, 'gameplay', 'weapons_engine.json'), {
            'pack': 'starsiege',
            'damage_scale_note': (
                'Starsiege damage x%.1f -> Earthsiege scale. Starsiege Herc armour 7-11k + internals ~9k and shield '
                'charge ~940-2000 vs. ES1 shields 3500 per pair of banks and ES1 Herc component totals 15-66k: x3 puts '
                'SS shields (938-1200 standard) at 2800-3600 and an Apocalypse (11000 armour + 9000 parts + servos) at '
                '~65k. Per-shot damage: shield = damage x Effect_v_Shield x3, armor = damage x Effect_v_Armor x3 '
                '(datProjectile.cs). Energy: charge limit x%.1f = capacitor cost (ES1 capacitor 960 / SS standard '
                'reactor battery 600). hardpoint_mask S=7 M=15 L=31 X=63 (fits when hardpoint mask >= weapon mask; '
                'turret-only/internal weapons 127 = never on a vehicle hardpoint).' % (DAMAGE_SCALE, ENERGY_SCALE)),
            'weapons': W}, indent=1)
        comps = component_table(S)
        V, vid = export_vehicles(S, W, comps)
        wjson(os.path.join(OUT, 'gameplay', 'hercs.json'), V, indent=1)
        wjson(os.path.join(OUT, 'gameplay', 'ids.json'), {
            'vehicles': vid,
            'weapons': {str(w['ss_id']): w['name'] for w in W},
            'components': {str(k): {'kind': v['kind'], 'name': v.get('name')} for k, v in sorted(comps.items())},
        }, indent=1)
        print('cloaks', export_cloak(S, SFX, comps))
        kinds = {}
        for v in V.values():
            kinds[v['kind']] = kinds.get(v['kind'], 0) + 1
        print('weapons', len(W), 'vehicles', kinds, 'components', len(comps), 'sounds', len(_sound_used))
    if not no_shapes:
        ok, failed = export_shapes(names or None)
        print('shapes exported', len(ok), 'failed', len(failed))
        for k, v in sorted(failed.items()):
            print('  FAIL', k, v)


if __name__ == '__main__':
    main()
