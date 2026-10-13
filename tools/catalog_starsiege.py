"""Catalogue Starsiege (1999) content from the decoded scripts -> gamedata/starsiege/catalog.json.

Input: starsiege/extracted/scripts/*.cs (scripts.vol, LZH-decoded by tools/darkstar_lzh.py),
       starsiege/original/installed/{campaign,multiplayer,training} (InstallShield cab, tools/installshield_cab.py),
       starsiege/extracted/gameObjects/*.dts (shape heights via tools/darkstar_dts.py).
The dat*.cs files are tables of function calls (`newWeapon(101, "wg_las.dts", S, IDSFX_LAS, 800, A, ...);`)
with column headers in the preceding comments; the column names used here come from those comments.
String tags (IDVEH_TR_APOC ...) are resolved through *.Strings.cs (`IDVEH_TR_APOC = 00300100, "Apocalypse";`).

Usage: python tools/catalog_starsiege.py
"""
import glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SCR = os.path.join(ROOT, 'starsiege', 'extracted', 'scripts')
INST = os.path.join(ROOT, 'starsiege', 'original', 'installed')
OUT = os.path.join(ROOT, 'gamedata', 'starsiege')

FACTION = {'tr': 'Terran Empire (Imperial)', 'kn': 'Knights', 'rb': 'Rebels', 'pi': 'Pirates', 'cy': 'Cybrid',
           'mg': 'Cybrid (Metagen)', 'pl': 'Cybrid (Platinum Guard)', 'ha': "Harabec's Weasels", 'ca': 'Caanan',
           'cin': 'cinematic only', 'ss': 'civilian'}
TECH_BASE = {'A': 'all', 'H': 'human', 'C': 'cybrid', 'X': 'alien/masters'}


def val(t):
    t = t.strip()
    if t.startswith('"') and t.endswith('"'):
        return t[1:-1]
    try:
        return int(t)
    except ValueError:
        pass
    try:
        return float(t)
    except ValueError:
        return t


def calls(path):
    txt = open(path, encoding='latin1').read()
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


def strings():
    out = {}
    for f in glob.glob(os.path.join(SCR, '*.[Ss]trings.cs')):
        for m in re.finditer(r'^\s*(ID\w+)\s*=\s*\d+\s*,\s*"([^"]*)"', open(f, encoding='latin1').read(), re.M):
            out[m.group(1)] = m.group(2)
    return out


def shape_height(shape):
    import darkstar_dts as D
    cands = glob.glob(os.path.join(ROOT, 'starsiege', 'extracted', 'gameObjects', '*'))
    path = next((c for c in cands if os.path.basename(c).lower() == shape.lower()), None)
    if not path:
        return None
    s = D.read_shape(open(path, 'rb').read())
    # standing pose when available
    pose = [nd['default'] for nd in s['nodes']]
    for qi, q in enumerate(s['sequences']):
        if s['names'][q['name']].lower() == 'seq02_stand':
            for i, nd in enumerate(s['nodes']):
                for k in range(nd['firstsub'], nd['firstsub'] + nd['nsub']):
                    ss = s['subsequences'][k]
                    if ss['seq'] == qi and ss['nkf'] > 0:
                        pose[i] = s['keyframes'][ss['firstkf']]['tf']
    W = D.world_matrices(dict(s, nodes=[dict(nd, default=pose[i]) for i, nd in enumerate(s['nodes'])]))
    nodes = set(D.detail_nodes(s, 0))
    pts = []
    for o in s['objects']:
        if o['node'] not in nodes or s['names'][o['name']] in ('bounds', 'coll0'):
            continue
        R, T = W[o['node']]
        for v in D.mesh_frame_verts(s['meshes'][o['mesh']]):
            pts.append([T[a] + sum(R[a][k] * v[k] for k in range(3)) for a in range(3)])
    if not pts:
        return None
    ext = [round(max(p[a] for p in pts) - min(p[a] for p in pts), 2) for a in range(3)]
    return {'width_m': ext[0], 'length_m': ext[1], 'height_m': ext[2]}


def vehicles(S):
    out = {'herc': [], 'tank': [], 'flyer': [], 'drone': []}
    for f in sorted(glob.glob(os.path.join(SCR, 'dat*.cs'))):
        base = os.path.basename(f)
        m = re.match(r'dat(Herc|Tank|Flyer|Drone)_(\w+?)_(\w+)\.cs$', base)
        if not m:
            continue
        kind, fac = m.group(1).lower(), m.group(2)
        C = calls(f)
        get = lambda n: next((a for c, a in C if c == n), None)
        b = get(kind + 'Base')
        if not b:
            continue
        v = {'file': base, 'tag': b[0], 'name': S.get(b[0], b[0]), 'abbr': b[1], 'shape': b[2],
             'faction': FACTION.get(fac, fac), 'mass_t': b[3]}
        if len(b) > 7:
            v.update(max_mass_t=b[4], radar_cross_section=b[5], tech_level=b[6], combat_value=b[7])
        pos = get(kind + 'Pos')
        if kind in ('herc', 'tank') and pos:
            v['speed_mps'] = {'max_accel': pos[0], 'min': pos[1], 'max_forward': pos[2], 'max_reverse': pos[3]}
            v['max_forward_kmh'] = round(pos[2] * 3.6, 1)
        elif kind == 'flyer' and pos:
            v['flight_mps'] = dict(zip(('max_accel', 'thrust_multiple', 'max_lift', 'max_fall', 'max_fly'), pos))
        rot = get(kind + 'Rot')
        if rot:
            v['turn_deg_s'] = rot
        coll = get(kind + 'Coll')
        if coll:
            v['collision_sphere_m'] = {'offset': coll[:3], 'radius': coll[3] if len(coll) > 3 else None}
        cp = get(kind + 'Cpit')
        if cp:
            v['cockpit_offset_m'] = cp
        v['hardpoints'] = [{'id': a[0], 'size': a[1], 'side': a[2], 'damage_parent': a[3], 'offset_m': a[4:7]}
                           for c, a in C if c == 'newHardPoint']
        v['mountpoints'] = [{'id': a[0], 'size': a[1], 'damage_parent': a[2], 'allowed': a[3:]}
                            for c, a in C if c == 'newMountPoint']
        v['components'] = [{'id': a[0], 'type': a[1], 'parent': a[2], 'max_damage': a[3]}
                           for c, a in C if c == 'newComponent']
        dw = get('defaultWeapons')
        if dw:
            v['default_weapons'] = dw
        dm = get('defaultMountables')
        if dm:
            v['default_mountables'] = dm
        if kind != 'drone':
            try:
                v['shape_extents'] = shape_height(b[2])
            except Exception as e:
                v['shape_extents'] = 'error: %s' % e
        v['weapon_family'] = 'herc'
        out[kind].append(v)
    return out


def projectiles():
    C = calls(os.path.join(SCR, 'datProjectile.cs'))
    P = {}
    for c, a in C:
        if c == 'newBullet':
            P[a[1]] = {'class': 'bullet', 'abbr': a[0], 'speed_mps': a[2], 'range_m': a[3], 'mass': a[4], 'damage': a[9],
                       'blast_radius_m': a[10], 'mix': dict(zip(('concussion', 'electric', 'thermal', 'special'), a[11:15])),
                       'vs_shield': a[17], 'vs_armor': a[18], 'shape': a[19]}
        elif c == 'newMissile':
            P[a[1]] = {'class': 'missile', 'abbr': a[0], 'start_speed_mps': a[2], 'speed_mps': a[3], 'accel': a[4],
                       'range_m': a[5], 'min_range_m': a[6], 'damage': a[12], 'blast_radius_m': a[13],
                       'vs_shield': a[20], 'vs_armor': a[21], 'tracking': a[22], 'turn_rate': a[23], 'shape': a[31]}
        elif c == 'NewEnergy':
            P[a[1]] = {'class': 'energy', 'abbr': a[0], 'speed_mps': a[2], 'range_m': a[3], 'damage': a[9],
                       'blast_radius_m': a[10], 'vs_shield': a[17], 'vs_armor': a[18], 'shape': a[20]}
        elif c == 'NewBeam':
            P[a[1]] = {'class': 'beam', 'abbr': a[0], 'range_m': a[2], 'beam_length_m': a[3], 'speed_mps': a[8],
                       'damage': a[10], 'blast_radius_m': a[12], 'vs_shield': a[19], 'vs_armor': a[20]}
        elif c == 'newMine':
            P[a[1]] = {'class': 'mine', 'abbr': a[0], 'duration_s': a[5], 'arm_delay_s': a[6], 'proximity_m': a[8],
                       'damage': a[9], 'blast_radius_m': a[10]}
        elif c == 'newBomb':
            P[a[1]] = {'class': 'bomb', 'abbr': a[0], 'damage': a[4], 'blast_radius_m': a[5]}
    return P


def weapons(S, P):
    C = calls(os.path.join(SCR, 'datWeapon.cs'))
    out, cur = [], None
    for c, a in C:
        if c == 'newWeapon':
            cur = {'id': a[0], 'shape': a[1], 'size': a[2], 'damage': a[4], 'tech_base': TECH_BASE.get(a[5], a[5]),
                   'category': 'herc', 'shots': []}
            out.append(cur)
        elif cur is None:
            continue
        elif c == 'weaponInfo1':
            cur['short'] = S.get(a[0], a[0])
            cur['name'] = S.get(a[1], a[1])
        elif c == 'weaponInfo2':
            cur.update(tech_level=a[0], combat_value=a[1], mass_t=a[2])
        elif c == 'weaponGeneral':
            cur.update(reload_s=a[0], lock_time_s=a[1])
        elif c == 'weaponShot':
            cur['shots'].append(a)
        elif c == 'weaponEnergy':
            cur.update(projectile=P.get(a[0], a[0]), energy={'charge_limit': a[1], 'charge_rate': a[2]})
        elif c == 'weaponAmmo':
            cur.update(projectile=P.get(a[0], a[0]), ammo={'max': a[1], 'start': a[2], 'rounds_per_volley': a[3]})
    return out


def components(S):
    out = {}
    for fname, kind, n_new in (('datEngine.cs', 'engine', ('id', 'velocity_rating', 'accel_rating', 'accel_at_max_v')),
                               ('datReactor.cs', 'reactor', ('id', 'output', 'battery', 'meltdown')),
                               ('datShield.cs', 'shield', ('id', 'charge_limit', 'charge_rate', 'decay_time', 'constant')),
                               ('datSensor.cs', 'sensor', ('id', 'sweep_time')),
                               ('datArmor.cs', 'armor', None), ('datIntMounts.cs', 'internal', None)):
        p = os.path.join(SCR, fname)
        if not os.path.exists(p):
            continue
        lst, cur = [], None
        for c, a in calls(p):
            if c.lower().startswith('new'):
                cur = {'kind': c[3:].lower(), 'raw': a}
                if n_new:
                    cur.update(dict(zip(n_new, a)))
                lst.append(cur)
            elif cur is not None and c.lower().endswith('info1'):
                cur['short'] = S.get(a[0], a[0])
                cur['name'] = S.get(a[1], a[1])
            elif cur is not None and c.lower().endswith('info2'):
                cur.update(dict(zip(('tech_level', 'tech_base', 'combat_value', 'mass_t', 'mount_size', 'damage'), a)))
        out[kind] = lst
    return out


def missions():
    def mlist(d):
        res = []
        for f in sorted(glob.glob(os.path.join(d, '*.[mM][iI][sS]'))):
            stem = os.path.splitext(os.path.basename(f))[0]
            cs = [c for c in glob.glob(os.path.join(d, '*.[cC][sS]')) if os.path.splitext(os.path.basename(c))[0].lower() == stem.lower()]
            info = {'id': stem, 'mis_bytes': os.path.getsize(f)}
            if cs:
                t = open(cs[0], encoding='latin1').read()
                for k in ('planet', 'title'):
                    m = re.search(r'\b%s\s*=\s*\*?(\w+)' % k, t)
                    if m:
                        info[k] = m.group(1)
                m = re.search(r'nextMission\s*=\s*"([^"]*)"', t)
                if m:
                    info['next'] = m.group(1)
                obj = re.findall(r'^//\s*\d\.\s*(.+)$', t, re.M)
                if obj:
                    info['objectives'] = obj
            res.append(info)
        return res
    S = strings()
    out = {}
    for name, d in (('human', 'campaign/Human'), ('cybrid', 'campaign/Cybrid (Advanced)'), ('training', 'training'),
                    ('multiplayer', 'multiplayer')):
        lst = mlist(os.path.join(INST, *d.split('/')))
        for m in lst:
            for k in ('planet', 'title'):
                if k in m and m[k] in S:
                    m[k] = S[m[k]]
            if name == 'multiplayer':
                m['mode'] = m['id'].split('_')[0]
        out[name] = lst
    return out


def main():
    S = strings()
    P = projectiles()
    cat = {
        'game': 'Starsiege (Dynamix/Sierra, 1999), Darkstar engine',
        'source': 'starsiege/extracted/scripts (scripts.vol), starsiege/original/installed',
        'units': 'metres, m/s, deg/s, tonnes (column headers in the dat*.cs files say "(all_m/s)", "(all_deg/s)")',
        'vehicles': vehicles(S),
        'weapons': weapons(S, P),
        'projectiles': P,
        'components': components(S),
        'missions': missions(),
        'server_modes': sorted(os.path.splitext(os.path.basename(f))[0] for f in glob.glob(os.path.join(INST, 'Server_*.cs'))),
        'planets': sorted(os.path.basename(f)[:-8] for f in glob.glob(os.path.join(INST, '*.Sim.vol'))),
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'catalog.json'), 'w') as f:
        json.dump(cat, f, indent=1)
    v = cat['vehicles']
    print('hercs', len(v['herc']), 'tanks', len(v['tank']), 'flyers', len(v['flyer']), 'drones', len(v['drone']),
          'weapons', len(cat['weapons']), 'projectiles', len(P),
          {k: len(x) for k, x in cat['components'].items()}, {k: len(x) for k, x in cat['missions'].items()})


if __name__ == '__main__':
    main()
