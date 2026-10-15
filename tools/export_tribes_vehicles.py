"""Tribes (1998) and Tribes 2 (2001) vehicles with their ORIGINAL fixed weapons -> the engine catalog.

The Tribes games never let a player change a vehicle's weapons: each vehicle datablock (Tribes 1) or the
vehicle's onAdd script (Tribes 2) mounts its guns. So every vehicle here is "fixed_loadout": true and its
weapons are "category": "vehicle" (never offered on Herc hardpoints). Evidence and approximations:
docs/formats/tribes_vehicles.md.

Input  Tribes 1: tribes/extracted/scripts/{vehicle,baseProjData,nsound}.cs, tribes/extracted/sound/*.wav
       Tribes 2: tribes2/extracted/scripts/scripts/**.cs (datablocks via catalog_tribes2.datablocks),
                 tribes2/extracted/audio/audio/fx/**.wav
       both: the exported shapes gamedata/<pack>/shapes/<shape>.json (node positions, bounds)
Output gamedata/<pack>/gameplay/hercs.json          engine-schema vehicles ("engine_schema": 1)
       gamedata/<pack>/gameplay/weapons_engine.json  docs/formats/weapon_schema.md, category "vehicle"
       gamedata/<pack>/audio/sfx/sim/<stem>.wav       fire sounds (PCM copies)

Usage: python tools/export_tribes_vehicles.py tribes|tribes2
"""
import glob, json, math, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import exe_scan  # noqa: E402
import siege_paths as P  # noqa: E402
import wav_pcm  # noqa: E402

# One Tribes damage unit (armour maxDamage 0.66 light .. 1.32 heavy; vehicles 0.6 .. 3.85) in Earthsiege points.
# Puts a Shrike (1.4) at 4200 hp, between an ES1 light Herc component total and a Starsiege light flyer (~6k).
DAMAGE_SCALE = 3000.0
# Torque / Darkstar simulation tick: 32 ms (rechargeRate is energy per tick).
TICKS_PER_SECOND = 1000.0 / 32.0
GRAVITY = 20.0                         # units.json gravity_mps2 (missions: contGravity "0 0 -20")
CATEGORY = 'vehicle'
NO_HARDPOINT_MASK = 0                  # fixed mounts take no Herc-family weapon
SOUND_DIR = ('audio', 'sfx', 'sim')
WEIGHT_BY_MASS = ((300.0, 'light', 0), (1000.0, 'medium', 1), (float('inf'), 'heavy', 2))


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1)


def r(x, n=3):
    return round(float(x), n)


# ------------------------------------------------------------------ shapes (exported JSON)

def _euler_matrix(e):
    """R = Rz(c) Ry(b) Rx(a), angles in 1/65536 turn (export_tribes convention)."""
    a, b, c = [x * 2 * math.pi / 65536 for x in e]
    ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
    return [[cc * cb, cc * sb * sa - sc * ca, cc * sb * ca + sc * sa],
            [sc * cb, sc * sb * sa + cc * ca, sc * sb * ca - cc * sa],
            [-sb, cb * sa, cb * ca]]


class Shape:
    """Node positions (default pose, metres, shape frame) and size of an exported shape."""

    def __init__(self, pack, name):
        path = P.pack(pack, 'shapes', name + '.json')
        self.id = '%s:%s' % (pack, name)
        self.exists = os.path.exists(path)
        j = json.load(open(path, encoding='utf-8')) if self.exists else {'nodes': [], 'transforms': []}
        self.names = [n['name'] for n in j['nodes']]
        frames = self._world_frames(j)
        self.positions = [f[1] for f in frames]
        self.size = self._size(j, frames)

    @staticmethod
    def _world_frames(j):
        frames = []
        for n in j['nodes']:
            t = j['transforms'][n['default']]
            rot, pos = _euler_matrix(t[:3]), list(t[3:])
            if n['parent'] >= 0:
                prot, ppos = frames[n['parent']]
                pos = [ppos[i] + sum(prot[i][k] * pos[k] for k in range(3)) for i in range(3)]
                rot = [[sum(prot[i][k] * rot[k][c] for k in range(3)) for c in range(3)] for i in range(3)]
            frames.append((rot, pos))
        return frames

    @staticmethod
    def _size(j, frames):
        """Width, length, height (m) of the most detailed geometry in its default pose (the header bounds of
        Torque shapes are loose: the Havoc's reach 14 m high)."""
        lo, hi = [math.inf] * 3, [-math.inf] * 3
        for piece in (j.get('lods') or [{}])[0].get('pieces', []):
            rot, pos = frames[piece['node']]
            for poly in piece['polys']:
                for v in poly['v']:
                    w = [pos[i] + sum(rot[i][k] * v[k] for k in range(3)) for i in range(3)]
                    lo = [min(lo[i], w[i]) for i in range(3)]
                    hi = [max(hi[i], w[i]) for i in range(3)]
        return [r(hi[i] - lo[i], 2) if hi[i] >= lo[i] else 0.0 for i in range(3)]

    def node(self, name):
        """Index of the node called `name` (case-insensitive), -1 when missing."""
        low = [n.lower() for n in self.names]
        return low.index(name.lower()) if name.lower() in low else -1

    def position(self, name):
        i = self.node(name)
        return self.positions[i] if i >= 0 else [0.0, 0.0, 0.0]


def is_true(value):
    """TorqueScript booleans arrive as text ("true") or numbers."""
    return str(value).strip().lower() in ('true', '1')


def _vec(text):
    return [float(x) for x in str(text).split()] if text not in (None, '') else [0.0, 0.0, 0.0]


def _sub(a, b):
    return [a[i] - b[i] for i in range(3)]


def _add(a, b):
    return [a[i] + b[i] for i in range(3)]


def _weight(mass):
    for limit, weight, size_class in WEIGHT_BY_MASS:
        if mass < limit:
            return weight, size_class
    return 'heavy', 2


# ------------------------------------------------------------------ shared records

def make_hull(max_damage):
    """One fatal hull component: Tribes vehicles have a single damage level (maxDamage)."""
    return {'components': [{'name': 'HULL', 'hp': r(max_damage * DAMAGE_SCALE, 1), 'fatal': True, 'parent': -1,
                            'tribes_max_damage': max_damage}]}


def make_gun(name, attach_node, offset):
    """A fixed mount: the weapon sits at `offset` (shape units = metres) in vehicle node `attach_node`'s frame.
    mount_group picks the weapon's model among its model.mount_shapes (0 = the first)."""
    return {'name': name, 'attach_node': attach_node, 'muzzle_units': [r(x) for x in offset], 'mount_node': -1,
            'mount_group': 0, 'hardpoint_mask': NO_HARDPOINT_MASK}


def make_vehicle(key, block, shape, kind):
    """Fields every Tribes vehicle record has; callers add speeds, guns and crew."""
    mass = float(block.get('mass', 0.0))
    weight, size_class = _weight(mass)
    return {'engine_schema': 1, 'key': key, 'category': CATEGORY, 'kind': kind, 'side': 'herc',
            'shape': shape.id, 'mass': mass, 'weight': weight, 'size_class': size_class,
            'width_m': shape.size[0], 'length_m': shape.size[1], 'height_m': shape.size[2],
            'fixed_loadout': True, 'torso_node': -1, 'cockpit_node': -1,
            'torso_rate': 0.0, 'torso_limit': 0.0, 'pitch_rate': 0.0, 'pitch_max': 0.0, 'pitch_min': 0.0,
            'guns': [], 'default_loadout': [], 'fixtures': []}


def copy_sound(pack, wav_path):
    """Copies a sound into the pack as PCM (wav_pcm: Tribes 2 has IMA ADPCM files); returns its qualified Sfx
    stem ("" when missing)."""
    if not wav_path or not os.path.exists(wav_path):
        return ''
    stem = os.path.splitext(os.path.basename(wav_path))[0].lower()
    out = P.pack(pack, *SOUND_DIR, stem + '.wav')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    wav_pcm.copy_as_pcm(wav_path, out)
    return '%s:%s' % (pack, stem)


def find_file(folder, name):
    """Case-insensitive file lookup below `folder`."""
    for p in glob.glob(os.path.join(folder, '**', '*'), recursive=True):
        if os.path.basename(p).lower() == name.lower():
            return p
    return ''


def keep_fx(path, weapons):
    """Carries each weapon's "fx" block (written later by tools/fx_tribes*.py) over from the existing file, so
    re-running this exporter alone keeps the weapon effects."""
    if not os.path.exists(path):
        return
    with open(path, encoding='utf-8') as f:
        old = {w.get('name'): w.get('fx') for w in json.load(f).get('weapons', [])}
    for w in weapons:
        if old.get(w['name']) is not None:
            w['fx'] = old[w['name']]


def write_pack(pack, vehicles, weapons, note):
    wjson(P.pack(pack, 'gameplay', 'hercs.json'), {v.pop('key'): v for v in vehicles})
    keep_fx(P.pack(pack, 'gameplay', 'weapons_engine.json'), weapons)
    wjson(P.pack(pack, 'gameplay', 'weapons_engine.json'),
          {'pack': pack, 'damage_scale_note': note, 'weapons': weapons})
    print('%s: %d vehicles (%d armed), %d vehicle weapons' % (
        pack, len(vehicles), sum(1 for v in vehicles if v['guns']), len(weapons)))


DAMAGE_NOTE = ('Tribes damage x%g -> Earthsiege scale (vehicle maxDamage 0.6..3.85 -> 1800..11550 hp; one '
               'Tribes damage unit = %g shield and armour points). Per-target damage-type scales of the originals '
               '($DamageScale / *DamageProfile) are not applied.' % (DAMAGE_SCALE, DAMAGE_SCALE))


# ================================================================== Tribes 1

T1_SCRIPTS = P.work('tribes', 'extracted', 'scripts')
T1_SOUNDS = P.work('tribes', 'extracted', 'sound')
# FlierData datablocks of scripts/vehicle.cs: catalog key, datablock name
T1_VEHICLES = (('SCOUT', 'Scout'), ('LAPC', 'LAPC'), ('HAPC', 'HAPC'))
T1_DISPLAY = {'Scout': 'Scout', 'LAPC': 'LPC (light personnel carrier)', 'HAPC': 'HPC (heavy personnel carrier)'}
# The flier fires its projectileType from this shape node (flyer.dts has 'dummy muzzle1' / 'dummy muzzle2';
# which one the Darkstar engine uses is not in the scripts: the first).
T1_MUZZLE_NODE = 'dummy muzzle1'
# Darkstar FlierData.accel read as a fraction of maxSpeed per second (FlightPresets, flight_model.md section 2).
T1_TURN_PER_BANK = 3.0


def t1_datablocks():
    """Darkstar datablocks `Class Name { field = value; ... };` of the Tribes 1 scripts."""
    out = {}
    rx = re.compile(r'^(\w+Data)\s+(\w+)\s*\{(.*?)\n\s*\}\s*;', re.S | re.M)
    for f in glob.glob(os.path.join(T1_SCRIPTS, '*.cs')):
        txt = re.sub(r'//[^\n]*', '', open(f, encoding='latin1').read())
        for m in rx.finditer(txt):
            fields = {}
            for fm in re.finditer(r'(\w+)\s*=\s*([^;]+);', m.group(3)):
                fields[fm.group(1)] = fm.group(2).strip().strip('"')
            out[m.group(2).lower()] = {'class': m.group(1), 'name': m.group(2), 'fields': fields,
                                       'file': 'scripts/' + os.path.basename(f)}
    return out


def _f(fields, key, default=0.0):
    try:
        return float(fields.get(key, default))
    except ValueError:
        return default


def t1_rocket_flight(p):
    """Distance a RocketData flies in totalTime: muzzleVelocity accelerating to terminalVelocity."""
    v0, vt, a, t = (_f(p, 'muzzleVelocity'), _f(p, 'terminalVelocity'), _f(p, 'acceleration'), _f(p, 'totalTime'))
    t_acc = min(t, (vt - v0) / a) if a > 0 else 0.0
    return v0 * t_acc + 0.5 * a * t_acc * t_acc + vt * (t - t_acc)


def t1_weapon(db, flier):
    """The flier's projectileType as an engine weapon (FlierRocket for the Scout)."""
    f = flier['fields']
    proj = db[f['projectileType'].lower()]
    p = proj['fields']
    radius = _f(p, 'damageClass') == 1
    rng = t1_rocket_flight(p)
    sound = db.get(f.get('fireSound', '').lower(), {}).get('fields', {}).get('wavFileName', '')
    dmg = _f(p, 'damageValue') * DAMAGE_SCALE
    return {
        'name': 'FLIER_ROCKET', 'display_name': 'Flier rocket', 'category': CATEGORY,
        'source': 'scripts/vehicle.cs FlierData %s (projectileType, reloadDelay, fireSound) + scripts/baseProjData.cs '
                  'RocketData %s' % (flier['name'], proj['name']),
        'size_class': 'special', 'kind': 'missile', 'fire_group': 1,
        'range': r(rng, 1), 'refire': _f(f, 'reloadDelay'), 'burst': 1, 'burst_interval': 0.0, 'spread_deg': 0.0,
        'ammo': -1, 'energy': {'min_charge': 0, 'per_shot': 0}, 'heat': None,
        'damage': {'shield': r(dmg, 1), 'armor': r(dmg, 1), 'splash': 1.0 if radius else 0.0,
                   'splash_radius': _f(p, 'explosionRadius') if radius else 0.0, 'tribes': _f(p, 'damageValue')},
        'effects': {},
        'projectile': {'speed': r(rng / _f(p, 'totalTime'), 2), 'gravity': 0.0, 'lifetime': _f(p, 'totalTime'),
                       'guidance': 'none', 'turn_rate_deg': 0.0, 'arm_delay': 0.0, 'proximity': 0.0,
                       'shape': 'tribes:' + os.path.splitext(p.get('bulletShapeName', ''))[0].lower(),
                       'trail': 'smoke', 'inherit_velocity': _f(p, 'inheritedVelocityScale'),
                       'color': [r(x, 2) for x in _vec(p.get('lightColor', '').strip('{} ').replace(',', ' '))]},
        'beam': None, 'model': {'mount_shapes': []},
        'sounds': {'fire': copy_sound('tribes', find_file(T1_SOUNDS, sound))},
        'notes': 'Unguided rocket; muzzleVelocity %g accelerating at %g to %g m/s for totalTime %g s: the remake flies '
                 'it at the mean speed so the range matches. Radius damage %s (damageClass 1) of %g at %g m. Fired by '
                 'the pilot; no ammo or energy in the datablock.' % (
                     _f(p, 'muzzleVelocity'), _f(p, 'acceleration'), _f(p, 'terminalVelocity'), _f(p, 'totalTime'),
                     'only' if radius else 'not', _f(p, 'damageValue'), _f(p, 'explosionRadius')),
    }


def t1_vehicle(db, key, block_name):
    flier = db[block_name.lower()]
    f = flier['fields']
    shape = Shape('tribes', f['shapeFile'].lower())
    v = make_vehicle(key, {'mass': _f(f, 'mass')}, shape, 'flyer')
    max_speed = _f(f, 'maxSpeed')
    v.update({'name': T1_DISPLAY[block_name], 'datablock': block_name, 'source': 'scripts/vehicle.cs FlierData ' + block_name,
              'flier_data': t1_flier_data(f, shape), 'max_speed': max_speed, 'reverse_speed': -_f(f, 'minSpeed'),
              'accel': r(_f(f, 'accel') * max_speed), 'turn_rate': r(_f(f, 'maxBank') * T1_TURN_PER_BANK),
              'shield_max': 0.0, 'shield_recharge': 0.0, 'damage': make_hull(_f(f, 'maxDamage')),
              'energy': {'max': _f(f, 'maxEnergy')}})
    v['crew'] = t1_crew(block_name)
    if f.get('projectileType'):
        v['guns'] = [make_gun(f['projectileType'], shape.node(T1_MUZZLE_NODE), [0.0, 0.0, 0.0])]
        v['default_loadout'] = ['FLIER_ROCKET']
    v['pilotable'] = bool(v['guns'])
    return v


# FlierData fields the flight model reads (FlightPresets.make_hover_params).
T1_FLIER_FIELDS = ('maxSpeed', 'minSpeed', 'accel', 'lift', 'maxAlt', 'maxVertical', 'maxBank', 'maxPitch', 'mass')


def t1_flier_data(fields, shape):
    """The flier's own FlierData values, read from the user's scripts/vehicle.cs at import time."""
    data = {k: _f(fields, k) for k in T1_FLIER_FIELDS}
    data['length_m'] = r(max(shape.size), 2)
    return data


def t1_crew(block_name):
    """Seats from scripts/vehicle.cs: only light armour pilots; Vehicle::findEmptySeat gives the HAPC 4
    passenger slots, the LAPC 2, the Scout none (passengers fire their own hand weapons)."""
    passengers = {'Scout': 0, 'LAPC': 2, 'HAPC': 4}[block_name]
    return {'seats': 1 + passengers, 'weapon_seat': 0 if block_name == 'Scout' else None,
            'pilot_armor': 'light only', 'rules': 'tribes'}


def export_tribes():
    db = t1_datablocks()
    vehicles = [t1_vehicle(db, key, block) for key, block in T1_VEHICLES]
    weapons = [t1_weapon(db, db['scout'])]
    write_pack('tribes', vehicles, weapons, DAMAGE_NOTE)


# ================================================================== Tribes 2

T2_SCRIPTS = P.work('tribes2', 'extracted', 'scripts', 'scripts')
T2_AUDIO = P.work('tribes2', 'extracted', 'audio', 'audio')
# vehicle.cs <Vehicle>::onAdd: %obj.mountObject(%turret, 10) - turrets sit on the vehicle's mount point 10.
TURRET_MOUNT_POINT = 10
# Weapon images per vehicle, from vehicle.cs onAdd (ScoutFlyer / BomberFlyer / AssaultVehicle). The paired images
# inherit their numbers from the first one. fire_group: the remake's trigger (1 = primary, 2 = secondary).
T2_WEAPONS = {
    'SHRIKE_BLASTER': {'image': 'ScoutChaingunImage', 'display': 'Shrike blaster', 'kind': 'cannon', 'fire_group': 1},
    'BOMBER_FUSION_GUN': {'image': 'BomberTurretBarrel', 'display': 'Belly turret fusion gun', 'kind': 'plasma',
                          'fire_group': 1},
    'BOMBER_BOMB': {'image': 'BomberBombImage', 'display': 'Bombs', 'kind': 'bomb', 'fire_group': 2},
    'TANK_CHAINGUN': {'image': 'AssaultPlasmaTurretBarrel', 'display': 'Turret chaingun', 'kind': 'cannon',
                      'fire_group': 1},
    'TANK_MORTAR': {'image': 'AssaultMortarTurretBarrel', 'display': 'Turret mortar', 'kind': 'grenade',
                    'fire_group': 2},
}
# key -> datablock, kind, Tribes 1 flier of the same role (FlightPresets attitude limits), turret, mounted images.
T2_VEHICLES = {
    'SHRIKE': {'block': 'ScoutFlyer', 'kind': 'flyer', 'role': 'Scout', 'turret': '',
               'images': [('ScoutChaingunImage', 'SHRIKE_BLASTER'), ('ScoutChaingunPairImage', 'SHRIKE_BLASTER')],
               'crew': {'seats': 1, 'weapon_seat': 0}},
    'THUNDERSWORD': {'block': 'BomberFlyer', 'kind': 'flyer', 'role': 'HAPC', 'turret': 'BomberTurret',
                     'images': [('BomberTurretBarrel', 'BOMBER_FUSION_GUN'), ('BomberTurretBarrelPair', 'BOMBER_FUSION_GUN'),
                                ('BomberBombImage', 'BOMBER_BOMB'), ('BomberBombPairImage', 'BOMBER_BOMB')],
                     'crew': {'seats': 3, 'weapon_seat': 1, 'note': 'pilot (0) flies unarmed; bombardier (1) works '
                              'the belly turret, bombs and targeting laser (BomberTurret::onTrigger); tail gunner (2) '
                              'is a passenger'}},
    'HAVOC': {'block': 'HAPCFlyer', 'kind': 'flyer', 'role': 'HAPC', 'turret': '', 'images': [],
              'crew': {'seats': 6, 'weapon_seat': None}},
    'BEOWULF': {'block': 'AssaultVehicle', 'kind': 'tank', 'role': '', 'turret': 'AssaultPlasmaTurret',
                'images': [('AssaultPlasmaTurretBarrel', 'TANK_CHAINGUN'), ('AssaultMortarTurretBarrel', 'TANK_MORTAR')],
                'crew': {'seats': 2, 'weapon_seat': 1, 'note': 'driver (0) unarmed; turreteer (1) switches chaingun / '
                         'mortar (AssaultPlasmaTurret::onTrigger)'}},
    'WILDCAT': {'block': 'ScoutVehicle', 'kind': 'cycle', 'role': '', 'turret': '', 'images': [],
                'crew': {'seats': 1, 'weapon_seat': None}},
    'JERICHO': {'block': 'MobileBaseVehicle', 'kind': 'wheeled', 'role': '', 'turret': '', 'images': [],
                'crew': {'seats': 1, 'weapon_seat': None, 'note': 'deployed (stationary) it raises an inventory '
                         'station and a MissileBarrelLarge turret (vehicle.cs vehicleDeploy); not modelled'}},
}
T2_DISPLAY = {'SHRIKE': 'Shrike', 'THUNDERSWORD': 'Thundersword', 'HAVOC': 'Havoc', 'BEOWULF': 'Beowulf',
              'WILDCAT': 'Wildcat', 'JERICHO': 'Jericho'}
# Flying vehicles have no altitude limit of their own; most missions with a limit set MissionArea flightCeiling 300.
T2_FLIGHT_CEILING = 300.0
# T2 FlyingVehicleData is force driven and has no attitude limits: they are borrowed by role from the
# Tribes 1 FlierData (Scout for fighters, HAPC for transports) when the user imported Tribes 1, else the
# remake's own generic values below. Ratios are per maxSpeed.
GENERIC_T2_ATTITUDE = {'Scout': {'bank': 0.6, 'pitch': 0.45, 'reverse': 0.05, 'climb': 0.25},
                       'HAPC': {'bank': 0.3, 'pitch': 0.2, 'reverse': 0.05, 'climb': 0.25}}


def t2_attitudes():
    """Attitude limits by role from the user's Tribes 1 scripts (GENERIC_T2_ATTITUDE without them)."""
    db = t1_datablocks()
    out = {}
    for role, generic in GENERIC_T2_ATTITUDE.items():
        block = db.get(role.lower(), {}).get('fields')
        if not block or _f(block, 'maxSpeed') <= 0:
            out[role] = dict(generic)
            continue
        top = _f(block, 'maxSpeed')
        out[role] = {'bank': _f(block, 'maxBank'), 'pitch': _f(block, 'maxPitch'),
                     'reverse': abs(_f(block, 'minSpeed')) / top, 'climb': _f(block, 'maxVertical') / top}
    return out
# Hover / wheeled ground vehicles: an exponential approach to top speed (time constant 1 / dragForce) is drawn as
# a linear ramp that gets there in this many time constants (95 %).
TIME_CONSTANTS_TO_TOP_SPEED = 3.0
# HoverVehicleData steeringForce -> yaw rate (rad/s per unit); approximation: Wildcat 2.0, Beowulf 1.2 rad/s.
HOVER_TURN_PER_STEERING = 0.08
BOMB_RANGE = 300.0                      # remake: bombs are released below this distance to the target (m)
BOMB_LIFETIME = 20.0                    # remake: a bomb that never hits anything is removed (originals: on impact)
# GrenadeProjectileData (the Beowulf mortar) has no lifetimeMS: the shell flies until it hits something. The remake
# removes it after its 45-degree ballistic flight time (2 v sin45 / g) times this margin, so a shell lobbed into a
# valley below the muzzle still lands.
GRENADE_FLIGHT_MARGIN = 1.5
# Ballistic projectiles (GrenadeProjectile, and the BombProjectile built on it) do not fall at the missions' 20 m/s2:
# GrenadeProjectile's force step applies an engine constant times the datablock's gravityMod, found by scanning the
# code of the user's Tribes2.exe (tools/exe_scan.py), two layouts:
#   build 21570: `fld [G]; fmul [data+0x144]` (G = 9.81 at 0x779c54, instruction 0x61655b; gravityMod default 1.0);
#   build 25034: `fld [A]; fmul [B]; fchs; fmul [data+0x140]` (A = 0.4905 at 0x7acf44, B = -20.0 at 0x7a1a20,
#                instruction 0x633521-0x633529): 0.4905 x 20 = 9.81 again, field offset moved to 0x140.
T2_EXE = P.work('tribes2', 'original', 'Tribes2', 'GameData', 'Tribes2.exe')
T2_GRAVITY_CODE_OLD = 'd905 ??{4} d888 ??{2} 0000 8d45dc 50'                      # fld [G]; fmul [eax+off]; lea; push
T2_GRAVITY_CODE_NEW = 'd905 ??{4} d80d ??{4} d9e0 d888 ??{2} 0000 8d45dc 50'      # fld [A]; fmul [B]; fchs; fmul [eax+off]
# Drag: GrenadeProjectile's force step (build 21570: 0x6194b2, constant 0x77a264; build 25034: 0x63673e, 0x7ad524)
# applies -velocity x drag x 15.0 only when the in-water test says the shell is in water; in air the datablock's
# `drag` does nothing.
T2_WATER_DRAG_CODE = 'd905 ??{4} d8cc dddc d986 ??{2} 0000 d9e0 ddd9 d986 ??{2} 0000 d9e0 ddda'   # fld [15.0]; fmul st(4) ...
T2_GRAVITY_RANGE = (1.0, 50.0)         # sanity: m/s2
_t2_constants = {}


def _t2_pe():
    if not os.path.exists(T2_EXE):
        raise SystemExit('Tribes2.exe not found at %s: engine constants cannot be read' % T2_EXE)
    return exe_scan.Pe(T2_EXE)


def t2_water_drag_factor():
    """The in-water drag factor of the user's Tribes2.exe (15.0), read by scanning for the instruction that loads it."""
    if 'drag' not in _t2_constants:
        pe = _t2_pe()
        at = pe.find_one(T2_WATER_DRAG_CODE, 'GrenadeProjectile water drag')
        _t2_constants['drag'] = round(pe.f32(pe.u32(at + 2)), 4)
    return _t2_constants['drag']


def t2_engine_gravity():
    """The ballistic projectiles' gravity constant of the user's Tribes2.exe (m/s2); exactly one of the two known
    instruction layouts must match once."""
    if 'gravity' not in _t2_constants:
        pe = _t2_pe()
        old, new = pe.find_all(T2_GRAVITY_CODE_OLD), pe.find_all(T2_GRAVITY_CODE_NEW)
        if len(old) + len(new) != 1:
            raise SystemExit('Tribes2.exe: GrenadeProjectile gravity code: expected exactly one match, found %d '
                             '(this build is not known to the importer)' % (len(old) + len(new)))
        if old:
            value = pe.f32(pe.u32(old[0] + 2))
        else:
            value = abs(pe.f32(pe.u32(new[0] + 2)) * pe.f32(pe.u32(new[0] + 8)))
        if not T2_GRAVITY_RANGE[0] <= value <= T2_GRAVITY_RANGE[1]:
            raise SystemExit('Tribes2.exe: gravity constant %s m/s2 is outside %s' % (value, T2_GRAVITY_RANGE))
        _t2_constants['gravity'] = round(value, 4)
    return _t2_constants['gravity']


def t2_gravity(p, kind):
    """Fall acceleration of projectile datablock `p`: engine constant x gravityMod for ballistic kinds."""
    if kind not in ('grenade', 'bomb'):
        return 0.0
    return r(t2_engine_gravity() * float(p.get('gravityMod', 1.0)), 4)


def t2_water_drag(p, kind):
    """Per-second velocity loss of a ballistic shell in water (drag x the engine factor); 0 in air."""
    if kind not in ('grenade', 'bomb'):
        return 0.0
    return r(float(p.get('drag', 0.0)) * t2_water_drag_factor(), 4)


def t2_lifetime(p, kind, speed):
    """Seconds a projectile lives: lifetimeMS when the datablock has one, else derived from its flight."""
    if kind == 'bomb':
        return BOMB_LIFETIME
    lifetime_ms = float(p.get('lifetimeMS', 0.0))
    if lifetime_ms > 0.0:
        return lifetime_ms / 1000.0
    if kind == 'grenade' and speed > 0.0:
        return r(2.0 * speed * math.sin(math.radians(45.0)) / t2_gravity(p, kind) * GRENADE_FLIGHT_MARGIN, 2)
    raise ValueError('projectile %s (%s) has neither lifetimeMS nor a derivable flight time' % (p.get('_name', '?'), kind))


def t2_db():
    import catalog_tribes2 as C
    db = C.datablocks(T2_SCRIPTS)
    return db, (lambda name: C.resolved(db, name))


def t2_fire_cycle(img):
    """Seconds between shots of one image: its state machine from the firing state back to a firing state or to
    a state waiting for the trigger. A script-alternated pair (fireTimeout, Shrike) fires every 2 x fireTimeout."""
    if img.get('fireTimeout'):
        return 2.0 * float(img['fireTimeout']) / 1000.0
    names = {}
    for k, v in img.items():
        m = re.match(r'stateName\[(\d+)\]', k)
        if m:
            names[str(v).lower()] = int(m.group(1))
    state = next(int(re.search(r'\d+', k).group()) for k, v in img.items() if k.startswith('stateFire[') and is_true(v))
    total = float(img.get('stateTimeoutValue[%d]' % state, 0.0))
    for _ in range(10):
        state = names.get(str(img.get('stateTransitionOnTimeout[%d]' % state, '')).lower())
        if state is None or is_true(img.get('stateFire[%d]' % state)) or img.get('stateTransitionOnTriggerDown[%d]' % state):
            break
        total += float(img.get('stateTimeoutValue[%d]' % state, 0.0))
    return round(total, 3)


def t2_fire_sound(img, resolve):
    """The AudioProfile file of the image's firing state."""
    state = next((k[len('stateFire['):-1] for k, v in img.items() if k.startswith('stateFire[') and is_true(v)), None)
    profile = resolve(str(img.get('stateSound[%s]' % state, ''))) if state is not None else {}
    path = os.path.join(T2_AUDIO, *str(profile.get('filename', '')).split('/')) if profile.get('filename') else ''
    return copy_sound('tribes2', path)


def _color(text):
    vals = []
    for part in str(text).split('@'):
        part = part.strip().strip('"').strip()
        for tok in part.split():
            vals.append(eval_number(tok))
    return [r(x, 2) for x in vals[:3]] if len(vals) >= 3 else [1.0, 1.0, 1.0]


def eval_number(tok):
    if '/' in tok:
        a, b = tok.split('/')
        return float(a) / float(b)
    return float(tok)


def t2_projectile(p, kind, shape_name):
    speed = float(p.get('dryVelocity', p.get('muzzleVelocity', 0.0)))
    lifetime = t2_lifetime(p, kind, speed)
    gravity = t2_gravity(p, kind)
    color = p.get('tracerColor') or p.get('flareColor') or p.get('lightColor') or '1 1 1'
    return {'speed': r(speed, 2), 'gravity': gravity, 'lifetime': lifetime, 'guidance': 'none',
            'turn_rate_deg': 0.0, 'arm_delay': float(p.get('armingDelayMS', 0.0)) / 1000.0, 'proximity': 0.0,
            'shape': 'tribes2:' + shape_name if shape_name and Shape('tribes2', shape_name).exists else None,
            'trail': 'smoke' if kind in ('grenade', 'bomb') else 'glow',
            'inherit_velocity': float(p.get('velInheritFactor', 0.0)), 'color': _color(color),
            'water_drag_per_s': t2_water_drag(p, kind)}


def t2_range(p, kind, proj):
    if kind == 'bomb':
        return BOMB_RANGE
    if kind == 'grenade':
        return proj['speed'] ** 2 / proj['gravity']       # ballistic maximum at 45 degrees
    return proj['speed'] * proj['lifetime']


def t2_weapon(name, spec, resolve):
    img = resolve(spec['image'])
    p = resolve(str(img['projectile']))
    kind = spec['kind']
    proj_shape = os.path.splitext(str(p.get('projectileShapeName', '')))[0].lower()
    proj = t2_projectile(p, kind, proj_shape)
    radius = is_true(p.get('hasDamageRadius'))
    raw = float(p.get('indirectDamage', 0.0) if radius else p.get('directDamage', 0.0))
    dmg = r(raw * DAMAGE_SCALE, 1)
    spread = float(img.get('projectileSpread', 0.0) or 0.0)
    return {
        'name': name, 'display_name': spec['display'], 'category': CATEGORY,
        'source': '%s %s -> %s %s' % (img.get('_file', ''), spec['image'], p.get('_class', ''), img['projectile']),
        'size_class': 'special', 'kind': kind, 'fire_group': spec['fire_group'],
        'range': r(t2_range(p, kind, proj), 1), 'refire': t2_fire_cycle(img), 'burst': 1, 'burst_interval': 0.0,
        'spread_deg': r(math.degrees(spread), 2), 'ammo': -1,
        'energy': {'min_charge': float(img.get('minEnergy', 0.0)), 'per_shot': float(img.get('fireEnergy', 0.0)),
                   'uses_vehicle_energy': is_true(img.get('useMountEnergy'))},
        'heat': None,
        'damage': {'shield': dmg, 'armor': dmg, 'splash': 1.0 if radius else 0.0,
                   'splash_radius': float(p.get('damageRadius', 0.0)) if radius else 0.0, 'tribes': raw},
        'effects': {}, 'projectile': proj, 'beam': None,
        'model': {'mount_shapes': t2_weapon_shapes(name, resolve)},
        'sounds': {'fire': t2_fire_sound(img, resolve)},
        'notes': 'Energy is the vehicle\'s pool (fireEnergy / minEnergy, original units); the remake limits fire by '
                 'refire only.' + (' Bombs drop with the bomber\'s velocity (velInheritFactor 1), Tribes gravity.'
                                   if kind == 'bomb' else ''),
    }


def t2_weapon_shapes(weapon, resolve):
    """Models of every image that mounts `weapon` (a left and a right barrel), in mount order."""
    out = []
    for spec in T2_VEHICLES.values():
        for image_name, w in spec['images']:
            for shape in t2_image_shapes(resolve(image_name)) if w == weapon else []:
                if shape not in out:
                    out.append(shape)
    return out


def t2_image_shapes(img):
    """The image's own model ([] for the invisible turret_muzzlepoint.dts mounts)."""
    name = os.path.splitext(str(img.get('shapeFile', '')))[0].lower()
    return ['tribes2:' + name] if name and name != 'turret_muzzlepoint' and Shape('tribes2', name).exists else []


def _mount_node(shape, point):
    return shape.node('Mount%d' % point)


def t2_guns(spec, shape, resolve):
    """Fixed mounts in the frame of the vehicle's turret mount node (mount point 10): the image's mount point on
    the vehicle or on the turret, plus the image offset, minus the image model's own mountPoint node."""
    attach = _mount_node(shape, TURRET_MOUNT_POINT)
    turret = Shape('tribes2', os.path.splitext(resolve(spec['turret'])['shapeFile'])[0].lower()) if spec['turret'] else None
    guns, loadout = [], []
    for image_name, weapon in spec['images']:
        img = resolve(image_name)
        point = int(img.get('mountPoint', 0))
        if turret:
            at = turret.position('mount%d' % point)
        else:
            at = _sub(shape.position('Mount%d' % point), shape.position('Mount%d' % TURRET_MOUNT_POINT))
        model = t2_image_shapes(img)
        own = Shape('tribes2', model[0].split(':')[1]).position('mountPoint') if model else [0.0, 0.0, 0.0]
        gun = make_gun(image_name, attach, _sub(_add(at, _vec(img.get('offset'))), own))
        shapes = t2_weapon_shapes(weapon, resolve)
        gun['mount_group'] = shapes.index(model[0]) if model else 0
        guns.append(gun)
        loadout.append(weapon)
    fixtures = [{'shape': turret.id, 'attach_node': attach}] if turret else []
    return guns, loadout, fixtures


def t2_shield(b):
    """isShielded vehicles absorb damage with their energy pool: maxEnergy / energyPerDamagePoint damage units,
    recharged at rechargeRate per 32 ms tick."""
    per_point = float(b.get('energyPerDamagePoint', 0.0))
    if not is_true(b.get('isShielded')) or per_point <= 0.0:
        return 0.0, 0.0
    return (r(float(b['maxEnergy']) / per_point * DAMAGE_SCALE, 1),
            r(float(b['rechargeRate']) * TICKS_PER_SECOND / per_point * DAMAGE_SCALE, 1))


def t2_flier(b, role):
    """FlyingVehicleData forces as FlierData-style hover parameters (FlightPresets.make_hover_params)."""
    max_speed = float(b['maneuveringForce']) / float(b['minDrag'])
    att = t2_attitudes()[role]
    fighter = t2_attitudes()['Scout']
    return {'maxSpeed': r(max_speed, 2), 'minSpeed': r(-max_speed * fighter['reverse'], 2),
            'accel': r(float(b['minDrag']) / float(b['mass'])),
            'lift': r(float(b['jetForce']) * float(b.get('vertThrustMultiple', 1.0)) / float(b['mass']) / GRAVITY),
            'maxAlt': T2_FLIGHT_CEILING, 'maxVertical': r(max_speed * fighter['climb'], 2),
            'maxBank': att['bank'], 'maxPitch': att['pitch'], 'hoverHeight': float(b.get('hoverHeight', 2.0)),
            'mass': float(b['mass']), 'length_m': 0.0}


def t2_ground(b, kind, shape):
    """Ground speeds: hover thrust / drag terminal speed; wheeled maxWheelSpeed with the bicycle turn model."""
    if kind == 'wheeled':
        top = float(b['maxWheelSpeed'])
        accel = float(b['engineTorque']) / (float(b['tireRadius']) * float(b['mass']))
        base = abs(shape.position('Ground0')[1] - shape.position('Ground4')[1]) or shape.size[1]
        turn = top * math.tan(float(b['maxSteeringAngle'])) / base
        hover = {'tire_radius': float(b['tireRadius']), 'max_wheel_speed': top}
        return {'max_speed': top, 'reverse_speed': top, 'accel': r(accel), 'turn_rate': r(turn), 'hover': hover}
    drag = float(b['dragForce'])
    top = float(b['mainThrustForce']) / drag
    hover = {k: float(b[k]) for k in ('stabLenMin', 'stabLenMax', 'floatingGravMag', 'mainThrustForce',
                                      'reverseThrustForce', 'dragForce', 'turboFactor') if k in b}
    return {'max_speed': r(top, 2), 'reverse_speed': r(float(b['reverseThrustForce']) / drag, 2),
            'accel': r(top * drag / TIME_CONSTANTS_TO_TOP_SPEED),
            'turn_rate': r(float(b['steeringForce']) * HOVER_TURN_PER_STEERING), 'hover': hover}


def t2_turret_aim(spec, resolve):
    """Turret yaw (unlimited) and pitch from TurretData thetaMin / thetaMax (degrees from straight up) and the
    barrel's degPerSecTheta / degPerSecPhi."""
    t = resolve(spec['turret'])
    barrel = resolve(spec['images'][0][0])
    return {'torso_rate': r(math.radians(float(barrel.get('degPerSecTheta', 360)))), 'torso_limit': r(math.pi),
            'pitch_rate': r(math.radians(float(barrel.get('degPerSecPhi', 360)))),
            'pitch_max': r(math.radians(90.0 - float(t.get('thetaMin', 0)))),
            'pitch_min': r(math.radians(90.0 - float(t.get('thetaMax', 180))))}


def t2_crew(crew, b):
    """Seat rules of findEmptySeat (scripts/vehicles/vehicle.cs): a seat is free within minMountDist of its mount
    node; lightOnly vehicles take only light armour as pilot; heavy armour may only take seats without a
    mountPose (findFirstHeavyNode); noEnemyControl vehicles refuse the other team (Armor::onCollision)."""
    seats = int(b.get('numMountPoints', crew['seats']) or crew['seats'])
    out = dict(crew)
    out.update({'seats': seats, 'sitting': [i for i in range(seats) if b.get('mountPose[%d]' % i)],
                'light_only': is_true(b.get('lightOnly')), 'no_enemy_control': is_true(b.get('noEnemyControl')),
                'min_mount_dist': float(b.get('minMountDist', 4.0)), 'rules': 'tribes2'})
    return out


def t2_run_over(b):
    """Collision damage to a soldier the vehicle runs down (VehicleData collDamageThresholdVel m/s,
    collDamageMultiplier Tribes damage per m/s); read by engine/collision_damage.gd."""
    return {'threshold_mps': float(b['collDamageThresholdVel']), 'multiplier': float(b['collDamageMultiplier'])}


def t2_vehicle(key, spec, db, resolve):
    b = resolve(spec['block'])
    entry = db[spec['block'].lower()]
    shape = Shape('tribes2', os.path.splitext(str(b['shapeFile']))[0].lower())
    v = make_vehicle(key, b, shape, spec['kind'])
    shield, recharge = t2_shield(b)
    v.update({'name': T2_DISPLAY[key], 'datablock': spec['block'], 'class': entry['class'],
              'source': 'scripts/%s %s' % (entry['file'], spec['block']), 'shield_max': shield,
              'shield_recharge': recharge, 'damage': make_hull(float(b['maxDamage'])),
              'energy': {'max': float(b.get('maxEnergy', 0.0)),
                         'recharge_per_s': r(float(b.get('rechargeRate', 0.0)) * TICKS_PER_SECOND, 2)},
              'crew': t2_crew(spec['crew'], b), 'run_over': t2_run_over(b)})
    if spec['kind'] == 'flyer':
        flier = t2_flier(b, spec['role'])
        v.update({'flier_data': flier, 'max_speed': flier['maxSpeed'], 'reverse_speed': -flier['minSpeed'],
                  'accel': r(flier['accel'] * flier['maxSpeed']), 'turn_rate': r(flier['maxBank'] * T1_TURN_PER_BANK)})
    else:
        v.update(t2_ground(b, spec['kind'], shape))
    v['turn_rate_still'] = v['turn_rate']
    v['guns'], v['default_loadout'], v['fixtures'] = t2_guns(spec, shape, resolve)
    if spec['turret'] and spec['kind'] != 'flyer':
        v.update(t2_turret_aim(spec, resolve))
        v['torso_node'] = _mount_node(shape, TURRET_MOUNT_POINT)
    v['pilotable'] = bool(v['guns'])
    return v


def export_tribes2():
    db, base_resolve = t2_db()

    def resolve(name):
        out = dict(base_resolve(name))
        entry = db.get(str(name).lower(), {})
        out['_file'] = 'scripts/' + entry.get('file', '')
        out['_class'] = entry.get('class', '')
        return out

    vehicles = [t2_vehicle(key, spec, db, resolve) for key, spec in T2_VEHICLES.items()]
    weapons = [t2_weapon(name, spec, resolve) for name, spec in T2_WEAPONS.items()]
    write_pack('tribes2', vehicles, weapons, DAMAGE_NOTE)


def main():
    packs = sys.argv[1:] or ['tribes', 'tribes2']
    for pack in packs:
        {'tribes': export_tribes, 'tribes2': export_tribes2}[pack]()


if __name__ == '__main__':
    main()
