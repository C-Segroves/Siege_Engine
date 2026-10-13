"""Catalogue Tribes 2 (2001, Torque V12) content -> gamedata/tribes2/catalog.json.

Input: tribes2/extracted/scripts/scripts/**/*.cs (TorqueScript source; scripts.vl2 ships the .cs text),
       tribes2/extracted/missions/missions/*.mis, tribes2/extracted/shapes/shapes/*.dts (heights via
       tools/torque_dts.py).
All gameplay data are TorqueScript datablocks:  datablock Class(Name) [: Parent] { field = value; ... };
Inheritance (": Parent") is resolved; simple arithmetic values ("26.2 * 90") are evaluated.

Families (docs/formats/weapon_schema.md): weapons in scripts/weapons/*.cs -> "infantry";
datablocks in scripts/vehicles/*.cs -> "vehicle"; turret barrels (base / deployable turrets) -> "turret".

Usage: python tools/catalog_tribes2.py
"""
import ast, glob, json, operator, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SCR = os.path.join(ROOT, 'tribes2', 'extracted', 'scripts', 'scripts')
MIS = os.path.join(ROOT, 'tribes2', 'extracted', 'missions', 'missions')
SHAPES = os.path.join(ROOT, 'tribes2', 'extracted', 'shapes', 'shapes')
OUT = os.path.join(ROOT, 'gamedata', 'tribes2')

OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
       ast.USub: operator.neg}


def num(expr):
    try:
        node = ast.parse(expr.strip(), mode='eval').body

        def ev(n):
            if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
                return n.value
            if isinstance(n, ast.BinOp) and type(n.op) in OPS:
                return OPS[type(n.op)](ev(n.left), ev(n.right))
            if isinstance(n, ast.UnaryOp) and type(n.op) in OPS:
                return OPS[type(n.op)](ev(n.operand))
            raise ValueError
        v = ev(node)
        return round(v, 6) if isinstance(v, float) else v
    except Exception:
        return None


def parse_value(v):
    v = v.strip()
    n = num(v)
    if n is not None:
        return n
    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
        return v[1:-1]
    return v


def datablocks(scripts_dir=None):
    """Every datablock under `scripts_dir` (default SCR): lower-case name -> {class, name, parent, file, fields}."""
    scripts_dir = scripts_dir or SCR
    db = {}
    rx = re.compile(r'datablock\s+(\w+)\s*\(\s*(\w+)\s*\)\s*(?::\s*(\w+))?\s*\{(.*?)\n\s*\}\s*;', re.S)
    for f in glob.glob(os.path.join(scripts_dir, '**', '*.cs'), recursive=True):
        txt = open(f, encoding='latin1').read()
        txt = re.sub(r'//[^\n]*', '', txt)
        rel = os.path.relpath(f, scripts_dir).replace('\\', '/')
        for m in rx.finditer(txt):
            fields = {}
            for fm in re.finditer(r'([\w\[\]$]+)\s*=\s*([^;]+);', m.group(4)):
                fields[fm.group(1)] = parse_value(fm.group(2))
            db[m.group(2).lower()] = {'class': m.group(1), 'name': m.group(2), 'parent': m.group(3), 'file': rel,
                                      'fields': fields}
    return db


def resolved(db, name, seen=()):
    d = db.get(name.lower())
    if not d or name.lower() in seen:
        return {}
    out = dict(resolved(db, d['parent'], seen + (name.lower(),))) if d['parent'] else {}
    out.update(d['fields'])
    return out


def shape_extents(shape):
    import torque_dts as T
    p = os.path.join(SHAPES, shape)
    if not shape or not os.path.exists(p):
        return None
    try:
        s = T.read_shape(open(p, 'rb').read())
    except Exception as e:
        return 'unreadable: %s' % e
    W = T.world_matrices(s)
    det = next((d for d in s['details'] if d['size'] >= 0), None)
    if det is None:
        return None
    pts = []
    for oi, o in enumerate(s['objects']):
        if det['object_detail'] >= o['num_meshes']:
            continue
        if oi < len(s['object_states']) and s['object_states'][oi][0] <= 0.01:
            continue
        m = s['meshes'][o['start_mesh'] + det['object_detail']]
        if m['type'] not in (0, 1, 3):
            continue
        R, Tt = W[o['node']] if o['node'] >= 0 else ([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [0, 0, 0])
        v = m['verts']
        for i in range(0, len(v), 3):
            pts.append([Tt[a] + sum(R[a][k] * v[i + k] for k in range(3)) for a in range(3)])
    if not pts:
        return None
    ext = [round(max(p[a] for p in pts) - min(p[a] for p in pts), 2) for a in range(3)]
    return {'width_m': ext[0], 'length_m': ext[1], 'height_m': ext[2], 'version': s['version']}


def pick(f, keys):
    return {k: f[k] for k in keys if k in f}


PROJ_CLASSES = ('LinearProjectileData', 'LinearFlareProjectileData', 'GrenadeProjectileData', 'SeekerProjectileData',
                'TracerProjectileData', 'SniperProjectileData', 'ELFProjectileData', 'ShockLanceProjectileData',
                'EnergyProjectileData', 'BombProjectileData', 'TargetProjectileData', 'RepairProjectileData',
                'FlareProjectileData')
PROJ_KEYS = ('directDamage', 'indirectDamage', 'damageRadius', 'radiusDamageType', 'directDamageType', 'kickBackStrength',
             'muzzleVelocity', 'maxVelocity', 'acceleration', 'dryVelocity', 'wetVelocity', 'velInheritFactor',
             'lifetimeMS', 'fizzleTimeMS', 'armingDelayMS', 'gravityMod', 'maxRifleRange', 'beamRange',
             'zapDuration', 'drainEnergy', 'drainHealth', 'maxSeekAngle', 'seekRadius', 'flareDistance',
             'proximityRadius', 'grenadeElasticity', 'grenadeFriction', 'tracerLength')
IMAGE_KEYS = ('projectile', 'projectileType', 'ammo', 'usesEnergy', 'fireEnergy', 'minEnergy', 'emap', 'shapeFile',
              'mountPoint', 'stateTimeoutValue[3]', 'stateTimeoutValue[4]', 'stateTimeoutValue[6]', 'reloadTime',
              'fireTimeout', 'item', 'projectileSpread')


def catalog():
    db = datablocks()
    R = lambda n: resolved(db, n)
    out = {'game': 'Tribes 2 (Dynamix/Sierra, 2001), Torque V12 engine',
           'units': 'metres, metres/second, seconds (lifetimeMS etc. in ms), kg-like mass (armor 90/130/180)'}

    armors = []
    for k, d in db.items():
        if d['class'] == 'PlayerData':
            f = R(d['name'])
            a = {'datablock': d['name'], 'file': d['file'], **pick(f, (
                'shapeFile', 'mass', 'maxDamage', 'maxEnergy', 'rechargeRate', 'maxForwardSpeed', 'maxBackwardSpeed',
                'maxSideSpeed', 'runForce', 'jetForce', 'jumpForce', 'jetEnergyDrain', 'boundingBox',
                'maxUnderwaterForwardSpeed', 'minImpactSpeed', 'maxWeapons', 'maxGrenades', 'maxMines'))}
            if 'jumpForce' in f and f.get('mass'):
                a['jump_impulse_mps'] = round(f['jumpForce'] / f['mass'], 2)
            if 'jetForce' in f and f.get('mass'):
                a['jet_accel_mps2'] = round(f['jetForce'] / f['mass'], 2)
            a['max_forward_kmh'] = round(f.get('maxForwardSpeed', 0) * 3.6, 1)
            a['allowed'] = {kk[4:-1]: v for kk, v in f.items() if kk.startswith('max[') and kk.endswith(']')}
            a['shape_extents'] = shape_extents(f.get('shapeFile'))
            armors.append(a)
    out['armors'] = sorted(armors, key=lambda a: a['datablock'])

    projectiles = {}
    for k, d in db.items():
        if d['class'] in PROJ_CLASSES:
            projectiles[d['name']] = {'class': d['class'], 'file': d['file'], **pick(R(d['name']), PROJ_KEYS)}
    out['projectiles'] = projectiles

    weapons = []
    for k, d in db.items():
        if d['class'] not in ('ShapeBaseImageData', 'TurretImageData'):
            continue
        f = R(d['name'])
        proj = f.get('projectile')
        if not proj and 'ammo' not in f and 'usesEnergy' not in f:
            continue
        top = d['file'].split('/')[0]
        family = ('vehicle' if top == 'vehicles' else 'turret' if top in ('turrets', 'weapTurretCode.cs') or
                  d['class'] == 'TurretImageData' else 'infantry' if top == 'weapons' else 'other')
        w = {'datablock': d['name'], 'class': d['class'], 'file': d['file'], 'category': family,
             **pick(f, IMAGE_KEYS)}
        if isinstance(proj, str) and proj in projectiles:
            w['projectile_data'] = projectiles[proj]
        weapons.append(w)
    out['weapons'] = sorted(weapons, key=lambda w: (w['category'], w['file'], w['datablock']))

    items = []
    for k, d in db.items():
        if d['class'] == 'ItemData':
            f = R(d['name'])
            items.append({'datablock': d['name'], 'className': f.get('className'), 'file': d['file'],
                          **pick(f, ('shapeFile', 'pickUpName', 'image', 'mass', 'maxInventory'))})
    out['items'] = sorted(items, key=lambda i: (str(i['className']), i['datablock']))

    vehicles = []
    for k, d in db.items():
        if d['class'] in ('HoverVehicleData', 'FlyingVehicleData', 'WheeledVehicleData'):
            f = R(d['name'])
            v = {'datablock': d['name'], 'class': d['class'], 'file': d['file'],
                 'name': f.get('targetNameTag'), 'type': f.get('targetTypeTag'),
                 **pick(f, ('shapeFile', 'mass', 'maxDamage', 'maxEnergy', 'rechargeRate', 'maxForwardSpeed',
                            'maxAutoSpeed', 'maxSteeringAngle', 'mainThrustForce', 'reverseThrustForce', 'floatingThrustFactor',
                            'jetForce', 'minDrag', 'numMountPoints', 'cameraMaxDist', 'minImpactSpeed', 'maxEnginePitch',
                            'collDamageThresholdVel', 'hoverHeight', 'createHoverHeight', 'isShielded', 'energyPerDamagePoint'))}
            v['speed_fields'] = {kk: vv for kk, vv in f.items() if 'speed' in kk.lower() and isinstance(vv, (int, float))}
            v['shape_extents'] = shape_extents(f.get('shapeFile'))
            v['weapon_family'] = 'vehicle'
            vehicles.append(v)
    out['vehicles'] = sorted(vehicles, key=lambda v: v['datablock'])

    statics = []
    for k, d in db.items():
        if d['class'] in ('StaticShapeData', 'TurretData', 'SensorData') and d['file'] in (
                'deployables.cs', 'turret.cs', 'station.cs', 'staticShape.cs', 'vehicles/vehicle.cs', 'power.cs'):
            f = R(d['name'])
            statics.append({'datablock': d['name'], 'class': d['class'], 'file': d['file'],
                            **pick(f, ('shapeFile', 'maxDamage', 'deployedObject', 'targetNameTag', 'barrel', 'mass'))})
    out['deployables_and_base_objects'] = sorted(statics, key=lambda s: (s['file'], s['datablock']))

    missions = []
    for f in sorted(glob.glob(os.path.join(MIS, '*.mis'))):
        t = open(f, encoding='latin1').read()
        m = {'id': os.path.splitext(os.path.basename(f))[0]}
        mt = re.search(r'//\s*MissionTypes\s*=\s*([^\n]+)', t)
        m['types'] = mt.group(1).split() if mt else []
        dn = re.search(r'//\s*DisplayName\s*=\s*([^\n]+)', t)
        if dn:
            m['display_name'] = dn.group(1).strip()
        for key in ('squareSize', 'terrainFile', 'musicTrack', 'materialListFileName', 'flightCeiling', 'area'):
            r = re.search(r'\b%s\s*=\s*"([^"]*)"' % key, t)
            if r:
                m[key] = r.group(1)
        g = re.search(r'gravity\s*=\s*"([^"]*)"', t, re.I)
        if g:
            m['gravity'] = g.group(1)
        missions.append(m)
    out['missions'] = missions
    modes = {}
    for m in missions:
        for ty in m['types']:
            modes.setdefault(ty, []).append(m['id'])
    out['game_modes'] = {k: sorted(v) for k, v in sorted(modes.items())}
    out['game_mode_scripts'] = sorted(os.path.basename(f) for f in glob.glob(os.path.join(SCR, '*Game.cs')))
    return out


def main():
    c = catalog()
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'catalog.json'), 'w') as f:
        json.dump(c, f, indent=1)
    print('armors', len(c['armors']), 'vehicles', len(c['vehicles']), 'weapons', len(c['weapons']),
          'projectiles', len(c['projectiles']), 'items', len(c['items']), 'statics', len(c['deployables_and_base_objects']),
          'missions', len(c['missions']), 'modes', {k: len(v) for k, v in c['game_modes'].items()})


if __name__ == '__main__':
    main()
