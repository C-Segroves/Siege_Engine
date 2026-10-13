"""Tribes (1998) and Tribes 2 (2001) base equipment -> the engine catalog (docs/TRIBES_BASE_EQUIPMENT.md).

The bases of the multiplayer maps hold turrets, generators and solar panels, pulse sensors and the inventory /
ammo / command / vehicle stations. What each one does comes from the user's game scripts and datablocks at
import time; nothing is typed in from the games:
  * turrets      Tribes 1 TurretData (range, reloadDelay, speed, projectileType -> BulletData / GrenadeData /
                 SeekingMissileData / LightningData); Tribes 2 TurretData (thetaMin / thetaMax, energy) plus the
                 barrel image the mission mounts (initialBarrel, or the turret's own `barrel`: attackRadius,
                 degPerSecTheta / Phi, fireEnergy, the projectile datablock)
  * damage       maxDamage; Tribes 2 disabledLevel / destroyedLevel, isShielded energy shields and the
                 damage profile (damageScale per damage type); Tribes 1 objects are disabled at maxDamage times
                 the engine's StaticBase disabled ratio, read from the user's tribes.exe (DISABLED_RATIO_*)
  * sensors      Tribes 1 SensorData range; Tribes 2 sensorData.detectRadius
  * repair       Tribes 1 RepairBolt::onAcquire repairRate (scripts) over the bolt's boltLength; Tribes 2
                 RepairGunImage repairFactorObject per 32 ms tick over DefaultRepairBeam.beamRange
  * power        which SimGroup every base object sits in: a generator powers every object of its own group and
                 of the groups below it (Tribes 1 GameBase::generatePower, tribes.exe 0x44417c, walks the
                 generator's group; Tribes 2 scripts/power.cs SimGroup::powerInit / updatePowerCount), a Tribes 2
                 group with providesPower is always powered.

Writes
  gameplay/base_equipment.json   {"blocks": {lower datablock: spec}, "repair": {...}} (the runtime's TribesBase)
  gameplay/weapons_turret.json   the turrets' guns, docs/formats/weapon_schema.md, "category": "turret"
  maps/<id>/map.json             "power_groups" [{name, parent, provides_power}], and on every station
                                 "power_group" (index) and "spec" (lower datablock in base_equipment.json)
Run after export_darkstar_maps.py / export_tribes2_maps.py, export_tribes_infantry.py and fx (it reads their
output: the map stations, the projectile shapes, the sound copies).

Usage: python tools/export_tribes_base.py [tribes] [tribes2]
"""
import json
import math
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
import export_tribes_vehicles as V  # noqa: E402
import export_tribes_infantry as INF  # noqa: E402
import export_tribes_deployables as DEP  # noqa: E402
import export_tribes_commands as CMD  # noqa: E402

CATEGORY = 'turret'
DAMAGE_SCALE = V.DAMAGE_SCALE
TICKS_PER_SECOND = V.TICKS_PER_SECOND
# Matching a map.json station to its mission object: same datablock within this distance (metres).
MATCH_DISTANCE = 0.05

# tribes.exe StaticBaseData constructor (0x44acac): `mov dword [ebx+0xe0], imm32` at 0x44acc8 stores the ratio
# of maxDamage at which a static shape becomes Disabled (GameBase::getDisabledDamage, 0x41c040, returns
# maxDamage * [data+0xe0]). The importer reads the immediate from the user's executable.
DISABLED_RATIO_VA = 0x44acc8
DISABLED_RATIO_OPCODE = b'\xc7\x83\xe0\x00\x00\x00'
T1_TEXT_VA, T1_TEXT_FILE_OFFSET = 0x401000, 0x600

# Engine roles of the Tribes 1 station datablocks (scripts/station.cs: each has its own script namespace).
T1_STATION_ROLES = {'inventorystation': 'inventory', 'ammostation': 'ammo', 'commandstation': 'command',
                    'vehiclestation': 'vehicle', 'vehiclepad': 'vehicle_pad',
                    'deployableinvstation': 'inventory', 'deployableammostation': 'ammo'}
# Tribes 2 stations by datablock (scripts/StationInventory.cs, StationVehicle.cs, deployables.cs).
T2_STATION_ROLES = {'stationinventory': 'inventory', 'deployedstationinventory': 'inventory',
                    'stationvehiclepad': 'vehicle_pad', 'stationvehicle': 'vehicle'}

# Remake weapon kinds of the projectile classes (Weapon / Projectile behaviour, weapon_schema.md).
T1_KIND = {'BulletData': 'plasma', 'GrenadeData': 'grenade', 'SeekingMissileData': 'missile',
           'LightningData': 'beam', 'RocketData': 'cannon'}
T2_KIND = {'LinearFlareProjectileData': 'plasma', 'TracerProjectileData': 'cannon', 'SeekerProjectileData': 'missile',
           'GrenadeProjectileData': 'grenade', 'ELFProjectileData': 'beam', 'LinearProjectileData': 'cannon',
           'EnergyProjectileData': 'plasma', 'SniperProjectileData': 'beam'}


def r(x, n=3):
    return round(float(x), n)


def num(fields, key, default=0.0):
    try:
        return float(fields.get(key, default))
    except (TypeError, ValueError):
        return default


def write_json(path, obj, indent=1):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def damage_spec(max_damage, disabled_level, destroyed_level=None):
    destroyed = destroyed_level if destroyed_level else max_damage
    return {'tribes_max_damage': r(max_damage), 'hp': r(destroyed * DAMAGE_SCALE, 1),
            'disabled_damage': r(disabled_level * DAMAGE_SCALE, 1)}


# ================================================================== Tribes 1

def t1_disabled_ratio():
    """The StaticBase disabled ratio from the user's tribes.exe (None when the executable is not there)."""
    path = P.work('tribes', 'original', 'Tribes', 'tribes.exe')
    if not os.path.exists(path):
        return None
    data = open(path, 'rb').read()
    at = DISABLED_RATIO_VA - T1_TEXT_VA + T1_TEXT_FILE_OFFSET
    if data[at:at + len(DISABLED_RATIO_OPCODE)] != DISABLED_RATIO_OPCODE:
        return None
    return struct.unpack_from('<f', data, at + len(DISABLED_RATIO_OPCODE))[0]


def t1_kind(block):
    cls, f = block['class'], block['fields']
    name = block['name'].lower()
    if cls == 'TurretData':
        return 'turret' if f.get('projectileType') else 'camera'
    if cls == 'SensorData':
        return 'sensor'
    if f.get('className') == 'Generator':
        return 'generator'
    return T1_STATION_ROLES.get(name)


def t1_turret_weapon(db, block):
    """The turret's projectileType as an engine weapon (the infantry exporter's conversions on a synthetic
    image: fireTime 0, reloadTime = the turret's reloadDelay)."""
    f = block['fields']
    proj = db[f['projectileType'].lower()]
    key = block['name'].upper()
    image = {'projectileType': f['projectileType'], 'fireTime': '0', 'reloadTime': f.get('reloadDelay', '1'),
             'sfxFire': f.get('fireSound', ''), 'shapeFile': f.get('shapeFile', ''), 'minEnergy': '0',
             'maxEnergy': f.get('energyRate', '0') if proj['class'] == 'LightningData' else '0'}
    image_name = '_turretimage_' + key.lower()
    db[image_name] = {'class': 'ItemImageData', 'name': image_name, 'fields': image}
    items = {'_turret': {'imageType': image_name}}
    if proj['class'] == 'SeekingMissileData':
        w = t1_missile(db, block, proj)
    else:
        w = INF.t1_weapon(db, items, '_turret', key, f.get('description', block['name']))
    w['category'] = CATEGORY
    w['kind'] = T1_KIND.get(proj['class'], w['kind'])
    w['source'] = 'scripts/turret.cs TurretData %s (projectileType, reloadDelay) -> %s %s' % (
        block['name'], proj['class'], proj['name'])
    w['model'] = {'mount_shapes': []}
    return w


def t1_missile(db, block, proj):
    p = proj['fields']
    speed = num(p, 'muzzleVelocity')
    shape = V.Shape('tribes', os.path.splitext(p.get('bulletShapeName', ''))[0].lower())
    color = [r(x, 2) for x in V._vec(p.get('lightColor', '1 1 1').strip('{} ').replace(',', ' '))]
    projectile = INF.straight_projectile(speed, num(p, 'liveTime', num(p, 'totalTime')),
                                         shape.id if shape.exists else None, num(p, 'inheritedVelocityScale'),
                                         color, 'smoke')
    projectile.update({'guidance': 'heat', 'turn_rate_deg': r(math.degrees(speed / max(num(p, 'seekingTurningRadius'), 1.0))),
                       'proximity': num(p, 'proximityDist')})
    radius = num(p, 'explosionRadius') if num(p, 'damageClass') == 1 else 0.0
    damage = {'value': num(p, 'damageValue'), 'radius': radius, 'type': p.get('damageType', '').strip('$')}
    sound = INF.t1_sound(db, block['fields'].get('fireSound', ''))
    return INF.make_weapon(block['name'].upper(), block['fields'].get('description', block['name']), '', 'missile',
                           num(block['fields'], 'reloadDelay'), damage, projectile, (0, 0), sound, '',
                           'SeekingMissileData: muzzleVelocity, liveTime; turns at muzzleVelocity / '
                           'seekingTurningRadius (rad/s) toward the target.')


def t1_turret(db, block, weapons):
    """Aim and fire: range (else gunRange, else the gun's reach), reloadDelay, speed (turn rate, rad/s); a shot
    needs minGunEnergy and spends maxGunEnergy (at most what is left) of the turret's energy."""
    f = block['fields']
    w = t1_turret_weapon(db, block)
    weapons.append(w)
    engage = num(f, 'range') or num(f, 'gunRange') or w['range']
    # RocketTurret's reloadDelay is commented out in turret.cs: its energy (maxGunEnergy per shot against the
    # onPower recharge rate) paces it; the runtime then fires as soon as the energy allows.
    return {'weapon': 'tribes:' + w['name'], 'range': r(engage, 1), 'refire': num(f, 'reloadDelay'),
            'turn_rate': num(f, 'speed'), 'pitch_min': r(-math.pi / 2), 'pitch_max': r(math.pi / 2),
            'activation_s': 0.0, 'shot_energy': num(f, 'maxGunEnergy'), 'min_energy': num(f, 'minGunEnergy')}


def t1_power_script(block):
    """setRechargeRate and shieldStrength a powered turret gets: the first of <Name>::onPower / onEnabled,
    <className>::... and Turret::... (the object class the callbacks fall back to) in scripts/turret.cs that sets
    a recharge rate (per second)."""
    text = re.sub(r'//[^\n]*', '', open(os.path.join(V.T1_SCRIPTS, 'turret.cs'), encoding='latin1').read())
    for space in (block['name'], block['fields'].get('className', ''), 'Turret'):
        for callback in ('onPower', 'onEnabled'):
            body = re.search(r'function\s+%s::%s\s*\(.*?\n\}' % (re.escape(space), callback), text, re.S | re.I)
            rate = re.search(r'setRechargeRate\s*\(\s*%this\s*,\s*([\d.]+)', body.group(0)) if body else None
            if rate:
                strength = re.search(r'shieldStrength\s*=\s*([\d.]+)', body.group(0))
                return float(rate.group(1)), (float(strength.group(1)) if strength else 0.0)
    return 0.0, 0.0


def t1_block_spec(db, block, ratio, weapons):
    f = block['fields']
    kind = t1_kind(block)
    max_damage = num(f, 'maxDamage', 1.0)
    spec = {'name': block['name'], 'kind': kind, 'display_name': f.get('description', block['name']),
            'source': '%s %s %s' % (block.get('file', 'scripts'), block['class'], block['name']),
            'damage': damage_spec(max_damage, max_damage * ratio), 'energy': {}, 'shield': {}, 'damage_scale': {}}
    if kind == 'turret':
        spec['turret'] = t1_turret(db, block, weapons)
        rate, strength = t1_power_script(block)
        spec['energy'] = {'max': num(f, 'maxEnergy'), 'recharge_per_s': rate}
        if strength > 0.0:
            # StaticShape::shieldDamage: the energy absorbs a hit up to energy x shieldStrength damage
            spec['shield'] = {'energy_per_point': r(1.0 / (strength * DAMAGE_SCALE), 6)}
    if kind in ('sensor', 'camera', 'turret') and num(f, 'range') > 0.0:
        spec['sensor'] = t1_sensor(f)
    return spec


def t1_sensor(f):
    """SensorData / TurretData sensing (scripts/sensor.cs, turret.cs): range, castLOS (needs a clear line),
    supression (a jammer: hides what is within its range), supressable (default true; jammers blind it)."""
    return {'range': num(f, 'range'), 'los': V.is_true(f.get('castLOS', 'false')),
            'jams': V.is_true(f.get('supression', 'false')), 'detects_jammed': False,
            'pings': V.is_true(f.get('pinger', 'true'))}


def t1_repair():
    """RepairBolt::onAcquire (scripts/baseProjData.cs): the repair rate a repair gun adds to another object
    (the last repairRate assignment; the first is the wearer's own) over the bolt's boltLength."""
    path = os.path.join(V.T1_SCRIPTS, 'baseProjData.cs')
    text = open(path, encoding='latin1').read()
    body = re.search(r'function\s+RepairBolt::onAcquire.*?\n\}', text, re.S)
    rates = re.findall(r'repairRate\s*=\s*([\d.]+)', body.group(0)) if body else []
    length = re.search(r'RepairEffectData\s+RepairBolt\s*\{[^}]*boltLength\s*=\s*([\d.]+)', text, re.S)
    if not rates or not length:
        raise ValueError('RepairBolt repair rate / boltLength not found in %s' % path)
    return {'per_s': r(float(rates[-1]) * DAMAGE_SCALE, 1), 'range': float(length.group(1)),
            'source': 'scripts/baseProjData.cs RepairBolt::onAcquire repairRate (damage per second), boltLength'}


def export_t1():
    db = V.t1_datablocks()
    ratio = t1_disabled_ratio()
    note = 'tribes.exe 0x44acc8 StaticBase disabled ratio %s' % ratio
    if ratio is None:
        raise SystemExit('tribes.exe not found or not the expected build: the disabled ratio cannot be read')
    weapons, blocks = [], {}
    for key, block in list(db.items()):
        if block['class'] in ('TurretData', 'SensorData', 'StaticShapeData') and t1_kind(block):
            blocks[key] = t1_block_spec(db, block, ratio, weapons)
    deployables = DEP.t1_deployables(DEP.pack_ids('tribes'))
    for rules in deployables.values():
        for place in rules['places']:
            block = db.get(place['deployed'], {})
            place['shape'] = 'tribes:' + str(block.get('fields', {}).get('shapeFile', '')).lower()
            place['spec'] = place['deployed']
            if place['deployed'] not in blocks:
                raise SystemExit('deployable %s has no base spec' % place['deployed'])
    write_pack('tribes', blocks, weapons, t1_repair(), note, deployables=deployables, door_scale=t1_door_scale(),
               commands=CMD.t1_commands())
    annotate_t1_maps(blocks)


# ------------------------------------------------------------------ Tribes 1 moveables (doors, elevators)

# Moveable script namespaces (MoveableData className, scripts/moveable.cs) the runtime animates.
T1_MOVER_CLASSES = {'door': 'door', 'elevator': 'elevator'}
# Mission fields of a Moveable the Door / Elevator scripts read (stopWayUp ..., noTeam, triggerOpen, loop).
T1_MOVER_FIELDS = ('stopWayUp', 'stopWayDown', 'noTeam', 'triggerOpen', 'loop', 'destroyable')


def t1_force_field_names():
    """$ForceFields[<datablock>] of scripts/moveable.cs: the doors that fade instead of moving."""
    text = open(os.path.join(V.T1_SCRIPTS, 'moveable.cs'), encoding='latin1').read()
    return {n.lower() for n in re.findall(r'\$ForceFields\[\s*"(\w+)"\s*\]\s*=\s*1', text)}


def t1_mover(db, o, path, M, DM, fade_names):
    """A Moveable with its datablock values and the waypoints of the SimPath beside it ({} when it is none)."""
    f = o['fields']
    block = db.get(f.get('dataBlock', '').lower())
    kind = T1_MOVER_CLASSES.get(str(block['fields'].get('className', '')).lower()) if block else None
    pos = M.vec(f.get('position', ''))
    if not kind or not pos:
        return {}
    waypoints, triggers = [], []
    for sibling in (path[-1]['children'] if path else []):
        if sibling['class'] == 'SimPath':
            waypoints = [DM.eng(M.vec(c['fields'].get('position', ''))) for c in sibling['children']
                         if 'position' in c['fields']]
        elif sibling['class'] == 'Trigger' and t1_trigger(sibling, M, DM):
            triggers.append(t1_trigger(sibling, M, DM))
    bf = block['fields']
    mover = dict({'kind': kind, 'datablock': block['name'].lower(), 'pos': DM.eng(pos),
                  'shape_file': bf.get('shapeFile', '').lower(), 'speed': num(bf, 'speed', 10.0),
                  'side': bf.get('side', 'single').lower(), 'trigger_radius': num(bf, 'triggerRadius'),
                  'fades': block['name'].lower() in fade_names, 'waypoints': waypoints or [DM.eng(pos)],
                  'max_damage': num(bf, 'maxDamage'), 'triggers': triggers,
                  'source': 'scripts/moveable.cs MoveableData %s (%s)' % (block['name'], bf.get('className'))},
                 **DM.orient(M.vec(f.get('rotation', '0 0 0')) or [0, 0, 0]))
    for k in T1_MOVER_FIELDS:
        if f.get(k, '') != '':
            mover[k.lower()] = f.get(k)
    return mover


# Trigger datablocks that pass their contacts to the group (scripts/trigger.cs GroupTrigger::onEnter / onLeave ->
# <object>::onTrigEnter / onTrigLeave of every object in the trigger's group).
T1_GROUP_TRIGGERS = ('grouptrigger',)


def t1_trigger(o, M, DM):
    """A GroupTrigger box: position, rotation and boundingBox (local min / max, Darkstar axes) in the engine frame."""
    f = o['fields']
    if f.get('dataBlock', '').lower() not in T1_GROUP_TRIGGERS or 'position' not in f:
        return {}
    b = M.vec(f.get('boundingBox', '-1 -1 -1 1 1 1'), 6)
    lo, hi = DM.eng(b[:3]), DM.eng(b[3:])
    box = [[min(a, c) for a, c in zip(lo, hi)], [max(a, c) for a, c in zip(lo, hi)]]
    return dict({'pos': DM.eng(M.vec(f['position'])), 'box': box, 'sphere': V.is_true(f.get('isSphere', 'false'))},
                **DM.orient(M.vec(f.get('rotation', '0 0 0')) or [0, 0, 0]))


def t1_door_scale():
    """$DoorScale[$<Type>DamageType] of scripts/moveable.cs (Door::onDamage) by the infantry damage-type keys."""
    text = open(os.path.join(V.T1_SCRIPTS, 'moveable.cs'), encoding='latin1').read()
    return {t.lower(): float(v) for t, v in re.findall(r'\$DoorScale\[\$(\w+?)DamageType\]\s*=\s*([\d.]+)', text)}


def t1_force_field_static(o, M, DM, db):
    """A StaticShape ForceField (shape forcefield): a powered field across its shape's box ({} for others)."""
    f = o['fields']
    block = db.get(f.get('dataBlock', '').lower(), {})
    if block.get('name', '').lower() != 'forcefield':
        return {}
    pos = M.vec(f.get('position', ''))
    return dict({'datablock': 'forcefield', 'pos': DM.eng(pos), 'shape_file': block['fields'].get('shapeFile', '').lower(),
                 'team_permeable': False, 'other_permeable': False},
                **DM.orient(M.vec(f.get('rotation', '0 0 0')) or [0, 0, 0]))


# Darkstar SimLight types in the missions: 1 the sun (the environment's), 2 a point light with a range.
T1_POINT_LIGHT = 2


def t1_point_light(o, M, DM):
    """A mission SimLight of the point type: position, range (metres), colour ({} for other types). SimLights
    are not GameBase objects: no power, always on."""
    f = o['fields']
    if int(num(f, 'type')) != T1_POINT_LIGHT or num(f, 'range') <= 0.0:
        return {}
    return {'pos': DM.eng(M.vec(f.get('position', '0 0 0'))), 'range': num(f, 'range'),
            'color': [r(x, 3) for x in (M.vec(f.get('color', '1 1 1')) or [1, 1, 1])]}


def t1_team(path):
    team = -1
    for a in path:
        m = re.match(r'team(\d+)$', a['name'], re.I)
        if a['class'] == 'TeamGroup' and m:
            team = int(m.group(1))
    return team


def annotate_t1_maps(blocks):
    import darkstar_mis as M
    import export_darkstar_maps as DM
    t1db = V.t1_datablocks()
    fade_names = t1_force_field_names()
    mdir = P.work('tribes', 'original', 'Tribes', 'base', 'missions')
    for mid in map_ids('tribes'):
        mis = [f for f in os.listdir(mdir) if f.lower() == mid.lower() + '.mis']
        if not mis:
            continue
        root = M.parse_text(open(os.path.join(mdir, mis[0]), encoding='latin-1').read())
        groups, objects, movers, fields, lights = [], [], [], [], []
        group_index = {}
        for o, path in M.walk(root):
            if o['class'] in ('SimGroup', 'TeamGroup'):
                parent = group_index.get(id(path[-1]), -1) if path else -1
                group_index[id(o)] = len(groups)
                groups.append({'name': o['name'], 'parent': parent, 'provides_power': False})
                continue
            if o['class'] == 'SimLight' and t1_point_light(o, M, DM):
                lights.append(t1_point_light(o, M, DM))
                continue
            extra = t1_mover(t1db, o, path, M, DM, fade_names) if o['class'] == 'Moveable' else \
                t1_force_field_static(o, M, DM, t1db) if o['class'] == 'StaticShape' else {}
            if extra:
                extra['team'] = t1_team(path)
                extra['power_group'] = group_index.get(id(path[-1]), -1) if path else -1
                (movers if o['class'] == 'Moveable' else fields).append(extra)
                continue
            pos = M.vec(o['fields'].get('position', '')) if 'position' in o['fields'] else None
            db = o['fields'].get('dataBlock', '').lower()
            if pos and db in blocks:
                objects.append({'datablock': db, 'pos': DM.eng(pos),
                                'group': group_index.get(id(path[-1]), -1) if path else -1})
        annotate_map('tribes', mid, groups, objects, {'movers': movers, 'force_fields': fields, 'lights': lights})


# ================================================================== Tribes 2

def t2_kind(resolve, name):
    b = resolve(name)
    cls = b.get('_class', '')
    if cls == 'TurretData':
        return 'turret'
    role = T2_STATION_ROLES.get(name.lower())
    if role:
        return role
    return {'Generator': 'generator', 'Sensor': 'sensor'}.get(str(b.get('className', '')))


def t2_damage_scale(b):
    """damageScale[$DamageType::X] of the block's damage profile -> {"x": scale} (the infantry type keys)."""
    out = {}
    for k, v in b.items():
        if k.endswith(']') and '[' not in k:
            try:
                out[k[:-1].lower()] = float(v)
            except (TypeError, ValueError):
                pass
    return out


def t2_energy(b):
    return {'max': num(b, 'maxEnergy'), 'recharge_per_s': r(num(b, 'rechargeRate') * TICKS_PER_SECOND, 2)}


def t2_shield(b):
    """isShielded: the energy absorbs damage, energyPerDamagePoint energy per Tribes damage unit."""
    per_point = num(b, 'energyPerDamagePoint')
    if not V.is_true(b.get('isShielded')) or per_point <= 0.0:
        return {}
    return {'energy_per_point': r(per_point / DAMAGE_SCALE, 6)}


def t2_sensor_radius(resolve, b):
    sensor = resolve(str(b.get('sensorData', ''))) if b.get('sensorData') else {}
    return num(sensor, 'detectRadius')


def t2_sensor(resolve, sensor_name):
    """SensorData (scripts/*.cs): detectRadius, detectsUsingLOS, detectsPassiveJammed (sees a jammer pack's
    wearer), detectsFOVOnly with detectFOVPercent of the owner's FOV (the PlayerSensor)."""
    s = resolve(sensor_name)
    return {'range': num(s, 'detectRadius'), 'los': V.is_true(s.get('detectsUsingLOS')),
            'detects_jammed': V.is_true(s.get('detectsPassiveJammed')), 'jams': V.is_true(s.get('jams')),
            'fov_only': V.is_true(s.get('detectsFOVOnly')), 'fov_percent': num(s, 'detectFOVPercent', 1.0),
            'pings': V.is_true(s.get('detectionPings'))}


def t2_player_sensor(resolve):
    """Every soldier carries the PlayerSensor (scripts/player.cs; FOV = the armour's cameraDefaultFov)."""
    out = t2_sensor(resolve, 'PlayerSensor')
    out['fov_deg'] = num(resolve('LightMaleHumanArmor'), 'cameraDefaultFov', 90.0)
    return out


def t2_barrel_weapon(resolve, barrel_name, weapons):
    img = resolve(barrel_name)
    p = resolve(str(img['projectile']))
    kind = T2_KIND.get(p.get('_class', ''), 'cannon')
    w = INF.t2_weapon(seeker_resolver(resolve, str(img['projectile'])), barrel_name.upper(), barrel_name,
                      barrel_name, kind)
    w['category'] = CATEGORY
    w['model'] = {'mount_shapes': []}
    if kind == 'missile' and p.get('turningSpeed'):
        w['projectile']['turn_rate_deg'] = num(p, 'turningSpeed')
    weapons.append(w)
    return w


def seeker_resolver(resolve, projectile):
    """`resolve` with a SeekerProjectile that has no maxVelocity (the turret missile flies at its
    muzzleVelocity) given that speed, as the infantry conversion reads maxVelocity."""
    def wrapped(name):
        out = resolve(name)
        if str(name).lower() == projectile.lower() and 'maxVelocity' not in out and 'muzzleVelocity' in out:
            out['maxVelocity'] = out['muzzleVelocity']
        return out
    return wrapped


def t2_barrel_shape(img):
    """The barrel image's model (exported like the map statics); "" for the invisible muzzle-point mounts."""
    import export_tribes2_maps as T2M
    name = os.path.splitext(str(img.get('shapeFile', '')))[0].lower()
    if not name or name == 'turret_muzzlepoint':
        return ''
    return T2M.export_dts(name) or ''


def t2_turret(resolve, b, barrel_name, weapons):
    img = resolve(barrel_name)
    w = t2_barrel_weapon(resolve, barrel_name, weapons)
    refire = w['refire'] if w['refire'] > 0 else num(img, 'thinkTimeMS') / 1000.0
    # the barrel model sits on the base's mount node (TurretData mounts image slot 0 on Mount0)
    return {'weapon': 'tribes2:' + w['name'], 'barrel': barrel_name, 'barrel_shape': t2_barrel_shape(img),
            'barrel_mount': 'Mount%d' % int(num(img, 'mountPoint', 0)),
            'deactivate_s': num(img, 'deactivateDelayMS') / 1000.0,
            'range': num(img, 'attackRadius', w['range']),
            'refire': refire, 'turn_rate': r(math.radians(num(img, 'degPerSecTheta', 360.0))),
            'pitch_min': r(math.radians(90.0 - num(b, 'thetaMax', 180.0))),
            'pitch_max': r(math.radians(90.0 - num(b, 'thetaMin', 0.0))),
            'activation_s': num(img, 'activationMS') / 1000.0,
            'shot_energy': num(img, 'fireEnergy'), 'min_energy': num(img, 'minEnergy')}


def t2_block_spec(resolve, name, barrel, weapons):
    b = resolve(name)
    kind = t2_kind(resolve, name)
    max_damage = num(b, 'maxDamage', 1.0)
    invincible = V.is_true(b.get('isInvincible'))
    spec = {'name': name, 'kind': kind,
            'display_name': ('%s %s' % (b.get('targetNameTag', ''), b.get('targetTypeTag', ''))).strip() or name,
            'source': 'scripts/%s %s %s' % (b.get('_file', ''), b.get('_class', ''), name),
            'damage': damage_spec(max_damage, num(b, 'disabledLevel', max_damage), num(b, 'destroyedLevel', max_damage)),
            'energy': t2_energy(b), 'shield': t2_shield(b), 'damage_scale': t2_damage_scale(b), 'invincible': invincible}
    if kind == 'turret' and barrel:
        spec['turret'] = t2_turret(resolve, b, barrel, weapons)
    if kind in ('sensor', 'turret') and b.get('sensorData'):
        spec['sensor'] = t2_sensor(resolve, str(b['sensorData']))
    return spec


def t2_repair(resolve):
    gun = resolve('RepairGunImage')
    beam = resolve('DefaultRepairBeam')
    return {'per_s': r(num(gun, 'repairFactorObject') * TICKS_PER_SECOND * DAMAGE_SCALE, 1),
            'range': num(beam, 'beamRange'),
            'source': 'scripts/packs/repairpack.cs RepairGunImage repairFactorObject (per 32 ms tick), '
                      'DefaultRepairBeam beamRange'}


def t2_mission_datablocks(text):
    """Datablocks a mission file declares itself (Training3: TrainingLongDetectTurret : TurretBaseLarge)."""
    import catalog_tribes2 as C
    out = {}
    rx = re.compile(r'datablock\s+(\w+)\s*\(\s*(\w+)\s*\)\s*(?::\s*(\w+))?\s*\{(.*?)\n\s*\}\s*;', re.S)
    for m in rx.finditer(re.sub(r'//[^\n]*', '', text)):
        fields = {}
        for fm in re.finditer(r'([\w\[\]$]+)\s*=\s*([^;]+);', m.group(4)):
            value = C.parse_value(fm.group(2))
            if not str(value).startswith('%'):          # script variables (%range) keep the parent's value
                fields[fm.group(1)] = value
        out[m.group(2).lower()] = {'class': m.group(1), 'name': m.group(2), 'parent': m.group(3),
                                   'file': 'mission', 'fields': fields}
    return out


def t2_force_field(resolve, o, T2M):
    """A ForceFieldBare: a box from its position (a corner) over its scale (metres, along its own axes), its
    team and its ForceFieldBareData (teamPermiable / otherPermiable, color, baseTranslucency; scripts/forceField.cs:
    gainPower closes it, losePower opens it)."""
    pl = T2M.placement(o)[0]
    scale = T2M.vec(T2M.field(o, 'scale', '1 1 1')) or [1.0, 1.0, 1.0]
    b = resolve(T2M.field(o, 'dataBlock') or '')
    out = {'datablock': str(T2M.field(o, 'dataBlock') or '').lower(), 'pos': pl['pos'], 'team': T2M.team_of(o),
           'size': [r(scale[0]), r(scale[2]), r(scale[1])],
           'team_permeable': V.is_true(b.get('teamPermiable')), 'other_permeable': V.is_true(b.get('otherPermiable')),
           'color': V._color(b.get('color', '0 0.55 0.99')), 'translucency': num(b, 'baseTranslucency', 0.3),
           'source': 'scripts/forceField.cs ForceFieldBareData %s' % T2M.field(o, 'dataBlock')}
    for k in ('yaw', 'basis'):
        if k in pl:
            out[k] = pl[k]
    return out


def script_ancestor(db, name):
    """The first datablock of `name`'s parent chain declared in the game scripts (a mission's own datablock,
    Training3 LongAttackAABarrelLarge, takes its look from its scripts parent)."""
    entry = db.get(str(name).lower(), {})
    while entry.get('file') == 'mission' and entry.get('parent'):
        entry = db.get(entry['parent'].lower(), {})
    return entry.get('name', name)


def export_t2():
    import catalog_tribes2 as C
    import export_tribes2_maps as T2M
    db, _ = V.t2_db()
    mdir = P.work('tribes2', 'extracted', 'missions', 'missions')
    missions = {}
    for mid in map_ids('tribes2'):
        path = os.path.join(mdir, mid + '.mis')
        if os.path.exists(path):
            text = open(path, encoding='latin1').read()
            db.update(t2_mission_datablocks(text))
            missions[mid] = text

    def resolve(name):
        out = dict(C.resolved(db, name))
        entry = db.get(str(name).lower(), {})
        out['_file'] = entry.get('file', '')
        out['_class'] = entry.get('class', '')
        return out

    weapons, blocks, done = [], {}, set()
    for mid, text in missions.items():
        _, root = T2M.parse_mission(text)
        groups, objects, fields, group_index = [], [], [], {}
        for o in T2M.walk(root):
            if o['class'] == 'SimGroup':
                parent = group_index.get(id(o['parent']), -1)
                group_index[id(o)] = len(groups)
                groups.append({'name': o['name'], 'parent': parent,
                               'provides_power': V.is_true(T2M.field(o, 'providesPower', '0'))})
                continue
            if o['class'] == 'ForceFieldBare':
                fields.append(dict(t2_force_field(resolve, o, T2M), power_group=group_index.get(id(o['parent']), -1)))
                continue
            name = T2M.field(o, 'dataBlock') or ''
            if o['class'] not in ('StaticShape', 'Turret') or not t2_kind(resolve, name):
                continue
            barrel = T2M.field(o, 'initialBarrel') or resolve(name).get('barrel')
            key = (name.lower() + ('+' + barrel.lower() if barrel else ''))
            if key not in done:
                done.add(key)
                blocks[key] = t2_block_spec(resolve, db[name.lower()]['name'], barrel, weapons)
                if blocks[key].get('turret'):
                    blocks[key]['turret']['fx_image'] = script_ancestor(db, barrel)
            objects.append({'datablock': name.lower(), 'spec': key, 'pos': T2M.placement(o)[0]['pos'],
                            'group': group_index.get(id(o['parent']), -1)})
        annotate_map('tribes2', mid, groups, objects, {'force_fields': fields})
    deployables = DEP.t2_deployables(resolve, DEP.pack_ids('tribes2'))
    for rules in deployables.values():
        for place in rules['places']:
            name = db[place['deployed']]['name']
            barrel = resolve(name).get('barrel')
            key = name.lower() + ('+' + barrel.lower() if barrel else '')
            if key not in blocks:
                blocks[key] = t2_block_spec(resolve, name, barrel, weapons)
            place['spec'] = key
            place['shape'] = T2M.export_dts(resolve(name).get('shapeFile', '')) or ''
    write_pack('tribes2', blocks, unique(weapons), t2_repair(resolve), 'Tribes 2 disabledLevel / destroyedLevel',
               t2_player_sensor(resolve), deployables, commands=CMD.t2_commands())


# ================================================================== output

def unique(weapons):
    out = {}
    for w in weapons:
        out.setdefault(w['name'], w)
    return list(out.values())


def map_ids(pack):
    root = P.pack(pack, 'maps')
    return sorted(d for d in os.listdir(root) if os.path.isfile(os.path.join(root, d, 'map.json')))


def annotate_map(pack, mid, groups, objects, extra=None):
    """Adds "power_groups" to map.json and "power_group" / "spec" to each station its mission object matches;
    `extra` lists ("movers", "force_fields") replace the plain statics at their places."""
    path = P.pack(pack, 'maps', mid, 'map.json')
    with open(path, encoding='utf-8') as f:
        m = json.load(f)
    for key, items in (extra or {}).items():
        take_over_statics(m, pack, items)
        m[key] = items
    matched = 0
    for st in m.get('stations', []):
        db = str(st.get('datablock', '')).lower()
        for o in objects:
            if o['datablock'] == db and max(abs(a - b) for a, b in zip(o['pos'], st['pos'])) <= MATCH_DISTANCE:
                st['power_group'] = o['group']
                st['spec'] = o.get('spec', db)
                matched += 1
                break
    m['power_groups'] = groups
    write_json(path, m, indent=None if pack == 'tribes' else 2)
    print('%-24s %3d base objects matched to their power groups (%d groups)' % (mid, matched, len(groups)))


def take_over_statics(m, pack, items):
    """Moves each item's plain static (its shape file at the same place) out of "statics": the maps exporter
    placed doors, elevators and force fields as statics. Gives every item its shape id when the shape exists."""
    keep = []
    for st in m.get('statics', []):
        owner = next((it for it in items if it.get('shape_file') and str(st['shape']).endswith(':' + it['shape_file'])
                      and max(abs(a - b) for a, b in zip(st['pos'], it['pos'])) <= MATCH_DISTANCE), None)
        if owner is None:
            keep.append(st)
    m['statics'] = keep
    for it in items:
        if it.get('shape_file') and os.path.exists(P.pack(pack, 'shapes', it['shape_file'] + '.json')):
            it['shape'] = '%s:%s' % (pack, it['shape_file'])


def write_pack(pack, blocks, weapons, repair, note, player_sensor=None, deployables=None, door_scale=None,
               commands=None):
    """`player_sensor`: the sensor every soldier carries ({} in Tribes 1: players have no SensorData, only the
    team's sensors fill the radar)."""
    write_json(P.pack(pack, 'gameplay', 'base_equipment.json'),
               {'pack': pack, 'engine_schema': 1, 'damage_note': note, 'repair': repair, 'blocks': blocks,
                'player_sensor': player_sensor or {}, 'deployables': deployables or {},
                'door_scale': door_scale or {}, 'commands': commands or []})
    V.keep_fx(P.pack(pack, 'gameplay', 'weapons_turret.json'), weapons)   # the fx step writes them later
    write_json(P.pack(pack, 'gameplay', 'weapons_turret.json'),
               {'pack': pack, 'damage_scale_note': INF.INFANTRY_NOTE, 'weapons': weapons})
    print('%s: %d base datablocks, %d turret weapons' % (pack, len(blocks), len(weapons)))


def main():
    for pack in sys.argv[1:] or ['tribes', 'tribes2']:
        {'tribes': export_t1, 'tribes2': export_t2}[pack]()


if __name__ == '__main__':
    main()
