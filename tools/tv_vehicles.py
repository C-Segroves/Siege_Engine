"""Tribes: Vengeance drivable vehicles -> gamedata/tribes_v (docs/formats/tribes_vengeance.md "Drivable vehicles").

The four vehicles of the campaign (Pod, Tank, AssaultShip, Buggy) were exported as rest-pose shapes only (tv_skeletal.export_props).
This step gives them their handling, health, seats and weapons, all read from the UnrealScript class defaults
(tools/ue2_classes.py merges a class with its supers; Content/Classes/VehicleClasses.pkg and Gameplay.u):

  * VehicleX:  Health, TopSpeed, forward / reverse / up thrust forces, ForceScale, maximumAircraftPitch, angularBankScale, gearTraceLength
               (aircraft); ChassisMass, TopSpeed, steering and gunner / cannon turn rates and pitch limits (cars);
               driverWeaponClass / gunnerWeaponClass / turretWeaponClass, the seat count of `positions`;
  * HavokDataX: hkMass; WeaponX: roundsPerSecond, projectileClass, projectileVelocity, projectileInheritedVelFactor;
    ProjectileX: damage, blast, LifeSpan, GravityScale, armingPeriod (the same fields as the hand weapons, tools/tv_weapons.py).
Units: 1/70 m per unreal unit; one health point = 26.4 Earthsiege points (tools/tv_weapons.hp); turn rates are 65536 units per turn.

It writes, for the pack:
  gameplay/hercs.json            the four vehicles (engine schema 1, category "vehicle", docs/formats/tribes_vehicles.md section 3);
  gameplay/weapons_engine.json   their weapons ("category": "vehicle");
  gameplay/vehicle_seats.json    seat roles (pilot / gunner / passenger), the node a drawn rider stands on and his pose (tv_vehicle_parts);
  shapes/tv_prop_*.json          the shapes get a turret node (a second root, so the yaw is about the world's up axis) and "muzzlepoint"
                                 nodes at the barrel tips; the buggy's gun shape is exported from Weapons.pkg;
and for the maps (map.json "vehicles": the placed Vehicle* actors, drawn as statics until now, become vehicle records:
class, vehicle id, position, orientation, team, label and the actor's healthModifier), "vehicle_pads" and the pads' "stations": the BaseObjectVehicleSpawn* actors),
and the mission scripts of the installed maps are compiled again for the vehicle goal and spawn ops (retrofit_scripts).
The shapes, their moving parts, seat nodes and the riders' poses are tv_vehicle_parts.py's.

    python tools/tv_vehicles.py <game root> [pack folder]        (the game root holds Content/ and Program/)
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import infantry_weapon_json as W  # noqa: E402
import siege_paths as P  # noqa: E402
import tv_skeletal as SK  # noqa: E402
import tv_vehicle_parts as VP  # noqa: E402
import tv_weapons as TW  # noqa: E402
import ue2_package as U  # noqa: E402

PACK = TW.PACK
METRES_PER_UU = TW.METRES_PER_UU
TURN = 2.0 * math.pi / 65536.0            # one unreal rotation unit in radians
HERC_FILE = 'gameplay/hercs.json'
WEAPON_FILE = 'gameplay/weapons_engine.json'
SEATS_FILE = 'gameplay/vehicle_seats.json'
WEAPONS_PACKAGE = 'Weapons'
VEHICLE_ACTORS = (('VehiclePod', 'POD'), ('VehicleTank', 'TANK'), ('VehicleAssaultShip', 'ASSAULT_SHIP'), ('VehicleBuggy', 'BUGGY'))

# Remake choices where the class defaults carry no number (the cars are driven by Havok wheel physics, not by a speed limit):
FASTEST_CAR_MPS = 45.0                    # the Tribes 2 Wildcat, the fastest ground vehicle of the engine: the buggy's TopSpeed is scaled to it
REVERSE_FRACTION = 0.4                    # reverse speed / top speed of the cars; aircraft reverse by their reverse force
CAR_SECONDS_TO_TOP = 5.0
TANK_TURN_RAD_S, BUGGY_TURN_RAD_S = 1.2, 2.0      # the Beowulf's and the Wildcat's
FLIGHT_FRACTION_VERTICAL = 0.2            # maxVertical / maxSpeed of the Tribes 2 fliers (the Shrike's 20 of 100)
MAX_ALTITUDE_M = 300.0                    # as the Aerial Assault fliers
TRIBES_GRAVITY = 20.0                     # FlightPresets.TRIBES_GRAVITY: lift is in multiples of it
BANK_PER_SCALE = 0.5                      # rad of bank for angularBankScale 1.0
MIN_BANK, MAX_BANK = 0.15, 0.5
HOVER_FRACTION_OF_GEAR_TRACE = 0.5
MIN_MOUNT_DIST = 4.0                      # boarding reach, as the Tribes 2 vehicles


# ------------------------------------------------------------------------------------------------ vehicle table
# key -> (class, shape stem, kind, display name, seats: (role, ...), guns). A gun is (name, weapon key, node, position in that node's frame).
# The shape frame is x right, y forward (the nose), z up, in metres; node None = the shape's root. Positions are read off the shape's
# bones (tools/tv_vehicles.py -> bone_world) and checked by eye (tests/tv_vehicles_shots).
VEHICLES = {
    'POD': {'cls': 'VehiclePod', 'shape': 'tv_prop_pod', 'kind': 'flyer', 'name': 'Fighter Pod', 'seats': ['pilot']},
    'TANK': {'cls': 'VehicleTank', 'shape': 'tv_prop_tank', 'kind': 'tank', 'name': 'Jump Tank', 'seats': ['pilot', 'gunner']},
    'ASSAULT_SHIP': {'cls': 'VehicleAssaultShip', 'shape': 'tv_prop_assaultship', 'kind': 'flyer', 'name': 'Assault Ship',
                     'seats': ['pilot', 'gunner', 'passenger']},
    'BUGGY': {'cls': 'VehicleBuggy', 'shape': 'tv_prop_buggy', 'kind': 'wheeled', 'name': 'Rover',
              'seats': ['pilot', 'gunner', 'passenger', 'passenger', 'passenger', 'passenger']},
}

# weapon key -> (weapon class, display, kind, fire group, sound role, impact role, projectile mesh, colour, model shape stem, guns sharing the rate)
WEAPONS = {
    'POD_ROCKET': ('WeaponVehicleFighterRocket', 'Fighter rockets', 'missile', 1, 'PodWeapon', 'PodWeaponProj', 'Rocket',
                   (1.0, 0.6, 0.25), None, 2),
    'TANK_CANNON': ('WeaponVehicleTank', 'Tank cannon', 'cannon', 2, 'Mortar', 'MortarProj', 'Rocket', (1.0, 0.7, 0.3),
                    'tv_prop_tankcannon', 1),
    'TANK_CHAINGUN': ('WeaponVehicleTurretSentry', 'Tank turret chaingun', 'cannon', 1, 'ChainGun', 'ChaingunProj', None,
                      (1.0, 0.95, 0.6), 'tv_prop_tankgunner', 1),
    'SHIP_BOMB': ('WeaponVehicleAssaultShipBomb', 'Assault ship bomb', 'grenade', 2, 'MortarBomb', 'MortarProj', 'Bomb',
                  (1.0, 0.5, 0.2), None, 1),
    'SHIP_AA': ('WeaponVehicleAssaultShip', 'Anti-aircraft turret', 'cannon', 1, 'AAWeapon', 'AAWeaponProj', None,
                (0.6, 0.9, 1.0), 'tv_prop_assaultshipgun', 2),
    'BUGGY_AA': ('WeaponVehicleBuggy', 'Rover anti-aircraft gun', 'cannon', 1, 'AAWeapon', 'AAWeaponProj', None,
                 (0.6, 0.9, 1.0), 'tv_prop_turretbuggy', 1),
}
# weapon stems exported from Weapons.pkg as skeletal shapes (the vehicles' turret models)
WEAPON_SKELETONS = {'TurretBuggy': 'tv_prop_turretbuggy'}
MUZZLE_BONES = ('muzzle', 'muzzle3rd')
MUZZLE_NODE = 'muzzlepoint'               # the name WeaponMount looks for (Torque's muzzlePoint)
TURRET_NODE = 'turret'


def rotation_matrix(a, b, c):
    """Rz(c) Ry(b) Rx(a) of a shape transform's three angles (1/65536 turn), ShapeInstance.tf_to_transform."""
    a, b, c = (v * TURN for v in (a, b, c))
    rx = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
    ry = np.array([[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]])
    rz = np.array([[math.cos(c), -math.sin(c), 0], [math.sin(c), math.cos(c), 0], [0, 0, 1]])
    return rz @ ry @ rx


def bone_world(shape):
    """[(R, t)] world transforms of every node of a shape JSON (shape frame, metres)."""
    out = []
    for nd in shape['nodes']:
        tf = shape['transforms'][nd['default']]
        r, t = rotation_matrix(*tf[:3]), np.array(tf[3:], float)
        if nd['parent'] >= 0:
            rp, tp = out[nd['parent']]
            out.append((rp @ r, tp + rp @ t))
        else:
            out.append((r, t))
    return out


def node_index(shape, name):
    for i, nd in enumerate(shape['nodes']):
        if nd['name'].lower() == name.lower():
            return i
    return -1


def add_root_node(shape, name, position):
    """A node with no parent and no rotation at `position` (shape frame): its frame is the shape's world frame, so a yaw about
    its up axis turns about the world's. Returns its index (an existing node of that name is moved)."""
    i = node_index(shape, name)
    tf = [0.0, 0.0, 0.0] + [round(float(v), 5) for v in position]
    if i >= 0:
        shape['transforms'][shape['nodes'][i]['default']] = tf
        return i
    shape['transforms'].append(tf)
    shape['nodes'].append({'parent': -1, 'default': len(shape['transforms']) - 1, 'name': name})
    return len(shape['nodes']) - 1


def add_muzzle_node(shape):
    """A 'muzzlepoint' node at the first muzzle bone of a weapon shape; returns the muzzle's position in the shape frame or None."""
    world = bone_world(shape)
    for bone in MUZZLE_BONES:
        i = node_index(shape, bone)
        if i >= 0:
            at = world[i][1]
            add_root_node(shape, MUZZLE_NODE, at)
            return [round(float(v), 4) for v in at]
    return None


def read_shape(pack_dir, stem):
    path = os.path.join(pack_dir, 'shapes', stem + '.json')
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def write_shape(pack_dir, stem, js):
    with open(os.path.join(pack_dir, 'shapes', stem + '.json'), 'w', encoding='utf-8') as f:
        json.dump(js, f, separators=(',', ':'))


def export_turret_shapes(src, idx, pack_dir, log=print):
    """Exports the skeletal turret models of Weapons.pkg that no earlier step made (WEAPON_SKELETONS)."""
    pkg = idx.load(WEAPONS_PACKAGE)
    if pkg is None:
        return
    import ue2_skeletal as S
    for mesh_name, stem in WEAPON_SKELETONS.items():
        if os.path.isfile(os.path.join(pack_dir, 'shapes', stem + '.json')):
            continue
        found = [e for e in pkg.find('SkeletalMesh') if e['name'].lower() == mesh_name.lower()]
        if not found:
            log('turret %s not found' % mesh_name)
            continue
        mesh = S.parse_skeletal_mesh(pkg, max(found, key=lambda e: e['size']), lenient=True)
        js = SK.shape_json(idx, pkg, found[0], mesh, None, pack_dir, METRES_PER_UU, False, stem, log)
        write_shape(pack_dir, stem, js)
        log('turret %s -> %s' % (mesh_name, stem))


# ------------------------------------------------------------------------------------------------ class data
def pitch_rad(units):
    return float(units) * TURN


def shape_extent(js):
    lo, hi = js['bounds']['header']
    return [hi[i] - lo[i] for i in range(3)], lo, hi


def make_weight(mass):
    return 'light' if mass < 1000 else 'medium' if mass < 5000 else 'heavy'


def flier_data(d, hk, top_mps):
    """The FlyingVehicleData-like block of FlightPresets.make_tribes_datablock from the aircraft's class defaults: maxSpeed = TopSpeed,
    accel = the forward thrust acceleration (force x ForceScale / hkMass) as a share of the top speed per second, lift = the up
    thrust acceleration in multiples of the engine's flight gravity."""
    mass = float(hk.get('hkMass', 1000.0))
    scale = float(d.get('ForceScale', 250.0))
    forward = float(d.get('forwardForce', d.get('forwardThrustForce', 4000.0)))
    up = float(d.get('upThrustForce', forward))
    reverse = float(d.get('reverseForce', forward))
    accel_mps2 = forward * scale / mass * METRES_PER_UU
    lift_mps2 = up * scale / mass * METRES_PER_UU
    bank = min(MAX_BANK, max(MIN_BANK, BANK_PER_SCALE * float(d.get('angularBankScale', 1.0))))
    pitch = abs(float(d.get('maximumAircraftPitch', 4000.0)))      # the nose-up limit (the dive limit is far larger)
    return {'maxSpeed': round(top_mps, 2), 'minSpeed': round(-top_mps * 0.25 * reverse / forward, 2),
            'accel': round(accel_mps2 / top_mps, 4), 'lift': round(lift_mps2 / TRIBES_GRAVITY, 3), 'maxAlt': MAX_ALTITUDE_M,
            'maxVertical': round(top_mps * FLIGHT_FRACTION_VERTICAL, 2), 'maxBank': round(bank, 3),
            'maxPitch': round(pitch_rad(pitch), 3), 'hoverHeight': round(float(d.get('gearTraceLength', 600.0)) * METRES_PER_UU
                                                                       * HOVER_FRACTION_OF_GEAR_TRACE, 2),
            'mass': mass, 'length_m': 0.0}


class Builder:
    def __init__(self, game_root, pack_dir):
        self.src = TW.Source(game_root)
        self.classes = self.src.classes
        self.pack_dir = pack_dir
        self.sounds = W.read_json(os.path.join(pack_dir, 'audio', 'sounds.json')) or {}
        self.gravity = self.src.gravity()

    def weapon(self, key):
        cls, display, kind, group, role, impact_role, mesh, color, model_stem, shared = WEAPONS[key]
        wd = self.classes.defaults(cls)
        pd = self.classes.defaults(str(wd.get('projectileClass', 'Projectile')))
        rps = float(wd.get('roundsPerSecond', 1.0))
        direct = float(pd.get('damageAmt', 0.0))
        blast = float(pd.get('radiusDamageAmt', 0.0))
        radius = TW.uu(pd.get('radiusDamageSize', 0.0))
        speed = TW.uu(wd.get('projectileVelocity', 2500.0))
        life = float(pd.get('LifeSpan', 3.0))
        grav = self.gravity * float(pd.get('GravityScale', 0.0))
        proj_shape = self.src.mesh_shape(mesh, self.pack_dir) if mesh else ''
        rng = speed * life if grav <= 0.0 else speed * speed / grav * math.sin(math.radians(90.0))
        fields = {'refire': shared / rps, 'damage_type': 'vehicle', 'fire_sound': TW.fire_sound(self.sounds, role),
                  'damage': TW.hp(max(direct, blast)), 'tribes': round(max(direct, blast), 2),
                  'splash': 1.0 if blast > 0 and radius > 0 else 0.0, 'splash_radius': radius, 'range': rng}
        if kind == 'cannon' and float(wd.get('Spread', 0.0)) > 0.0:
            fields['spread_deg'] = float(wd['Spread'])
        shape_id = ('%s:%s' % (PACK, model_stem)) if model_stem else ''
        proj = W.make_projectile(speed, life, grav, proj_shape or None, color, inherit=float(wd.get('projectileInheritedVelFactor', 0.5)),
                                 trail='smoke' if kind in ('missile', 'grenade') else 'glow',
                                 arm_delay=float(pd.get('armingPeriod', 0.0)))
        source = 'UE2 class defaults %s / %s (VehicleClasses.pkg, Gameplay.u)' % (cls, wd.get('projectileClass', ''))
        w = W.make_weapon(key, display, source, kind, projectile=proj, **fields)
        w['category'] = 'vehicle'
        w['fire_group'] = group
        w['model'] = {'mount_shapes': [shape_id] if shape_id else []}
        w['energy'] = {'min_charge': 0, 'per_shot': 0, 'uses_vehicle_energy': False}
        w['notes'] = ('Vehicle weapon: no energy use. Vengeance units: roundsPerSecond %g, projectileVelocity %g uu/s, damage %g, '
                      'radiusDamageAmt %g, radiusDamageSize %g uu, LifeSpan %g. %s'
                      % (rps, float(wd.get('projectileVelocity', 0)), direct, blast, float(pd.get('radiusDamageSize', 0.0)), life,
                         'The guns of the vehicle share the weapon\'s rate.' if shared > 1 else ''))
        fx, effects = W.make_fx(w, 'tv_veh_' + key.lower(), color, max(radius, 1.0), source, proj_shape or None, projectile_size=1.0,
                                impact_sound=TW.impact_sound(self.sounds, impact_role))
        w['fx'] = fx
        return w, effects

    def vehicle(self, key, spec, weapon_records, body):
        d = self.classes.defaults(spec['cls'])
        hk = self.classes.defaults(str(d.get('havokDataClass', ''))) if self.classes.has(str(d.get('havokDataClass', ''))) else {}
        js = read_shape(self.pack_dir, spec['shape'])
        size, lo, hi = shape_extent(js)
        top_mps = TW.uu(d.get('TopSpeed', 3000.0))
        health = float(d.get('Health', 100.0))
        flyer = spec['kind'] == 'flyer'
        rec = {'engine_schema': 1, 'category': 'vehicle', 'kind': spec['kind'], 'side': 'herc', 'shape': '%s:%s' % (PACK, spec['shape']),
               'name': spec['name'], 'datablock': spec['cls'], 'class': 'UE2 ' + str(d.get('Mesh', spec['cls'])),
               'width_m': round(size[0], 2), 'length_m': round(size[1], 2), 'height_m': round(size[2], 2),
               'fixed_loadout': True, 'cockpit_node': -1, 'torso_node': -1, 'torso_rate': 0.0, 'torso_limit': 0.0,
               'pitch_rate': 0.0, 'pitch_max': 0.0, 'pitch_min': 0.0, 'fixtures': [],
               'shield_max': 0.0, 'shield_recharge': 0.0,
               'damage': {'components': [{'name': 'HULL', 'hp': round(TW.hp(health), 1), 'fatal': True, 'parent': -1,
                                          'tribes_max_damage': health}]},
               'source': 'UE2 class defaults %s (Health %g, TopSpeed %g uu/s)' % (spec['cls'], health, float(d.get('TopSpeed', 0)))}
        mass = float(hk.get('hkMass', 0.0)) if flyer else float(d.get('ChassisMass', 3000.0))
        rec['mass'] = mass
        rec['weight'] = make_weight(mass)
        rec['size_class'] = {'light': 0, 'medium': 1, 'heavy': 2}[rec['weight']]
        if flyer:
            fd = flier_data(d, hk, top_mps)
            rec.update(flier_data=fd, max_speed=fd['maxSpeed'], reverse_speed=abs(fd['minSpeed']), accel=round(fd['accel'] * fd['maxSpeed'], 3),
                       turn_rate=round(fd['maxBank'] * 3.0, 3))
        else:
            fastest = TW.uu(self.classes.defaults('VehicleBuggy').get('TopSpeed', 13250.0))
            speed = top_mps * FASTEST_CAR_MPS / fastest
            turn = TANK_TURN_RAD_S if spec['kind'] == 'tank' else BUGGY_TURN_RAD_S
            wheel = self.classes.defaults('BuggyFrontLeftWheel' if spec['kind'] == 'wheeled' else 'TankFrontLeftWheel')
            rec.update(max_speed=round(speed, 2), reverse_speed=round(speed * REVERSE_FRACTION, 2), accel=round(speed / CAR_SECONDS_TO_TOP, 3),
                       turn_rate=turn, hover={'tire_radius': round(TW.uu(wheel.get('WheelRadius', 60.0)), 3),
                                              'max_wheel_speed': round(speed, 2)})
        rec['turn_rate_still'] = rec['turn_rate']
        self.add_mounts(key, rec, d, js, weapon_records)
        gunner = (round(math.degrees(pitch_rad(d.get('gunnerMinimumPitch', d.get('gunnerMinimumPitch', -3000.0)))), 1),
                  round(math.degrees(pitch_rad(d.get('gunnerMaximumPitch', 12000.0))), 1))
        rec['crew'] = {'seats': len(spec['seats']), 'weapon_seat': 1 if 'gunner' in spec['seats'] else None, 'sitting': [0],
                       'light_only': False, 'no_enemy_control': False, 'min_mount_dist': MIN_MOUNT_DIST, 'rules': 'tribes2',
                       'note': 'pilot at seat 0 (heavy armour may not pilot: heavyAttemptedToPilot); the gunner works the turret weapons '
                               'of the vehicle (TurretCrew); positions count %d in the class defaults' % len(spec['seats'])}
        rec['pilotable'] = bool(rec.get('guns'))
        rec['parts'] = body['parts']
        return rec, VP.seat_records(spec['seats'], body['rows'], body['placed'], gunner)

    def add_mounts(self, key, rec, d, js, weapon_records):
        """guns / default_loadout / turret of the vehicle (positions: see MOUNTS)."""
        mounts = MOUNTS[key]
        node_name = mounts.get('turret')
        node = -1
        if node_name:
            at = mounts['turret_at']
            node = add_root_node(js, TURRET_NODE, at)
            write_shape(self.pack_dir, VEHICLES[key]['shape'], js)
            yaw_rate = float(d.get('cannonClientTurnRate', d.get('gunnerClientTurnRate', 24000.0))) * TURN
            rec.update(torso_node=node, cockpit_node=node, torso_rate=round(yaw_rate, 3), torso_limit=round(math.pi, 4),
                       pitch_rate=round(yaw_rate, 3),
                       pitch_max=round(pitch_rad(d.get('cannonMaximumPitch', d.get('gunnerMaximumPitch', 10000.0))), 3),
                       pitch_min=round(pitch_rad(d.get('cannonMinimumPitch', d.get('gunnerMinimumPitch', -3000.0))), 3))
        guns, loadout = [], []
        for name, weapon, at in mounts['guns']:
            local = at if not node_name else [at[i] - mounts['turret_at'][i] for i in range(3)]
            guns.append({'name': name, 'attach_node': node, 'muzzle_units': [round(float(v), 3) for v in local], 'mount_node': -1,
                         'mount_group': 0, 'hardpoint_mask': 0})
            loadout.append('%s:%s' % (PACK, weapon))
        rec['guns'], rec['default_loadout'] = guns, loadout


# gun mounts per vehicle: (gun name, weapon key, position in the shape frame, metres). With a turret the position is read in the
# turret node's frame (the node sits at turret_at); the gun frame is where the weapon model's own origin hangs.
MOUNTS = {
    'POD': {'guns': [('PodRocketLeft', 'POD_ROCKET', (-0.47, 1.11, -0.66)), ('PodRocketRight', 'POD_ROCKET', (0.46, 1.11, -0.66))]},
    'TANK': {'turret': True, 'turret_at': (0.0, -0.63, 1.08),
             'guns': [('TankCannon', 'TANK_CANNON', (0.0, -0.63, 1.30)), ('TankGunnerChaingun', 'TANK_CHAINGUN', (0.0, -1.55, 1.75))]},
    'ASSAULT_SHIP': {'guns': [('ShipBomb', 'SHIP_BOMB', (-0.6, 5.1, 0.64)),
                              ('ShipAALeft', 'SHIP_AA', (-1.6, 1.0, 1.2)), ('ShipAARight', 'SHIP_AA', (1.6, 1.0, 1.2))]},
    'BUGGY': {'turret': True, 'turret_at': (0.0, -1.1, 1.0),
              'guns': [('BuggyGun', 'BUGGY_AA', (0.0, -1.1, 1.0))]},
}


# ------------------------------------------------------------------------------------------------ export
def prepare_shapes(pack_dir, log=print):
    """Adds the muzzlepoint nodes to the weapon shapes; returns {stem: muzzle position or None}."""
    out = {}
    for stem in ('tv_prop_tankcannon', 'tv_prop_tankgunner', 'tv_prop_assaultshipgun', 'tv_prop_turretbuggy'):
        js = read_shape(pack_dir, stem)
        if js is None:
            log('shape %s missing' % stem)
            continue
        out[stem] = add_muzzle_node(js)
        write_shape(pack_dir, stem, js)
    return out


def export(game_root, pack_dir=None, log=print):
    """Writes the vehicle files of the pack; returns the number of vehicles. Needs the prop shapes (tv_skeletal.export_props)."""
    import tv_assets
    pack_dir = pack_dir or P.pack(PACK)
    idx = tv_assets.PackageIndex(game_root)
    b = Builder(game_root, pack_dir)
    export_turret_shapes(b.src, idx, pack_dir, log)
    bodies = VP.export_vehicle_bodies(idx, game_root, pack_dir, log)       # the shapes with their bones, sequences and seat nodes
    for body in bodies.values():
        VP.write_shape(pack_dir, body['stem'], body['js'])
    muzzles = prepare_shapes(pack_dir, log)
    weapons, effects = [], {}
    for key in WEAPONS:
        w, fx = b.weapon(key)
        stem = WEAPONS[key][8]
        if stem and muzzles.get(stem):
            w['model']['muzzle_units'] = muzzles[stem]
        weapons.append(w)
        effects.update(fx)
    note = ('Vengeance damage: the class default damage (health points) x 26.4 (the light armour Health 75 = 1980 hp as in the Tribes games). '
            'Vehicle weapons use no energy.')
    W.write_json(os.path.join(pack_dir, WEAPON_FILE), {'pack': PACK, 'damage_scale_note': note, 'weapons': weapons})
    W.write_effects(pack_dir, PACK, effects, 'engine default (no explosion data in the pack)')
    hercs, seats = {}, {}
    for key, spec in VEHICLES.items():
        js = read_shape(pack_dir, spec['shape'])
        if js is None:
            log('vehicle %s skipped: shape %s missing' % (key, spec['shape']))
            continue
        rec, rows = b.vehicle(key, spec, weapons, bodies[key])
        hercs[key] = rec
        seats['%s:%s' % (PACK, key)] = rows
    log('rider poses added to %d bodies' % VP.patch_rider_poses(idx, game_root, pack_dir, log))
    W.write_json(os.path.join(pack_dir, HERC_FILE), hercs)
    W.write_json(os.path.join(pack_dir, SEATS_FILE), {'pack': PACK, 'engine_schema': 1, 'vehicles': seats})
    log('vehicles: %d, vehicle weapons: %d' % (len(hercs), len(weapons)))
    return len(hercs)


# ------------------------------------------------------------------------------------------------ maps
def vehicle_id_of(cls):
    """'tribes_v:POD' for a placed actor class (VehiclePod, VehiclePodPalace ...), '' for others."""
    for prefix, key in VEHICLE_ACTORS:
        if cls.startswith(prefix):
            return '%s:%s' % (PACK, key)
    return ''


def export_vehicles(actors, to_world, basis_of, team_of, yaw_of):
    """The map's placed vehicles [{vehicle, actor, label, pos, basis, yaw, team_name, health_modifier, goals}] from tv_import.read_actors rows."""
    out = []
    for _e, cls, p in actors:
        vid = vehicle_id_of(cls)
        if not vid:
            continue
        scale = [1.0, 1.0, 1.0]
        out.append({'vehicle': vid, 'actor': cls, 'label': p.get('Label', ''), 'pos': to_world(U.vec3(p['Location'])),
                    'basis': [[round(float(x), 5) for x in row] for row in basis_of(p.get('Rotation'), scale)],
                    'yaw': yaw_of(p.get('Rotation')), 'team_name': team_of(p), 'health_modifier': float(p.get('healthModifier', 1.0)),
                    'ai_goals': bool(p.get('goals'))})
    return out


PAD_PREFIX = 'BaseObjectVehicleSpawn'      # the pads: ...Buggy, ...Fighter, ...Tank, ...AssaultShip
PAD_SHAPE_PREFIX = 'tv_prop_'


def is_pad(cls):
    return cls.startswith(PAD_PREFIX)


def make_pad_table(game_root):
    """{pad actor class: {vehicle, shape, spawn_s, offset_m, abandon_radius_m, abandon_s}} from the class defaults (VehicleClass, Mesh,
    spawnDuration, spawnOffsetHeight, abandonmentDesturctionStartRadius / Period: an empty vehicle left that far from its pad that long is
    destroyed, so the pad can build the next)."""
    import ue2_classes
    classes = ue2_classes.ClassIndex(game_root)
    table = {}
    for name in classes.by_name:
        d = classes.defaults(name) if is_pad(name) else {}
        vehicle = vehicle_id_of(str(d.get('VehicleClass', '')))
        if vehicle:
            table[name] = {'vehicle': vehicle, 'shape': '%s:%s%s' % (PACK, PAD_SHAPE_PREFIX, str(d.get('Mesh', '')).lower()),
                           'spawn_s': float(d.get('spawnDuration', 0.0)), 'offset_m': round(TW.uu(d.get('spawnOffsetHeight', 0.0)), 3),
                           'abandon_radius_m': round(TW.uu(d.get('abandonmentDesturctionStartRadius', 0.0)), 1),
                           'abandon_s': float(d.get('abandonmentDesturctionPeriod', 0.0))}
    return table


def export_pads(actors, table, to_world, basis_of, team_of, yaw_of):
    """The map's vehicle pads [{vehicle, actor, label, shape, pos, basis, yaw, team_name, spawn_s, offset_m}]: a pad holds its vehicle
    (the script's label is the pad's label + "vehicle") and builds a new one `spawn_s` seconds after it is gone."""
    out = []
    for _e, cls, p in actors:
        info = table.get(cls)
        if info is None:
            continue
        rec = dict(info)
        rec.update({'actor': cls, 'label': p.get('Label', ''), 'pos': to_world(U.vec3(p['Location'])),
                    'basis': [[round(float(x), 5) for x in row] for row in basis_of(p.get('Rotation'), [1.0, 1.0, 1.0])],
                    'yaw': yaw_of(p.get('Rotation')), 'team_name': team_of(p)})
        out.append(rec)
    return out


def make_pad_stations(pads):
    """The pads as vehicle stations of the shared Tribes station code (TribesStations): neutral, one vehicle each, drawn as the pad."""
    return [{'kind': 'vehicle', 'shape': pad['shape'], 'pos': pad['pos'], 'basis': pad['basis'], 'yaw': pad['yaw'], 'team': -1,
             'vehicle': pad['vehicle'], 'label': pad['label'], 'lift_m': pad['offset_m'], 'collide': True} for pad in pads]


def retrofit_scripts(game_root, pack_dir, log=print):
    """Compiles the mission scripts of the installed maps again (the goal and vehicle ops) from the original map packages."""
    import tv_import as T
    import tv_script
    chapters, chapter_texts, prompts = T.load_texts(game_root)
    maps_dir = os.path.join(game_root, 'Content', 'Maps')
    count = 0
    for ch in chapters:
        texts = T.make_map_texts(chapter_texts, prompts, ch['number'])
        for entry in ch['maps']:
            src = T._ci_file(maps_dir, entry['map'] + '.tvm')
            target = os.path.join(pack_dir, 'maps', os.path.splitext(os.path.basename(src))[0], 'script.json') if src else ''
            if not target or not os.path.isfile(target):
                continue
            pkg = U.load(src)
            pkg.stem = entry['map'].lower()
            script = tv_script.compile_map(pkg, T.to_world, texts, METRES_PER_UU)
            with open(target, 'w', encoding='utf-8') as f:
                json.dump(script, f, separators=(',', ':'), ensure_ascii=False)
            count += 1
    log('scripts compiled again: %d' % count)
    return count


def retrofit_maps(game_root, pack_dir, log=print):
    """Gives the installed maps their `vehicles` list and takes the vehicle meshes out of their statics (what tv_import does on a fresh
    import), reading the actors of the original map packages again."""
    import tv_import as T
    import tv_statics
    idx_path = os.path.join(pack_dir, 'maps', '_index.json')
    with open(idx_path, encoding='utf-8') as f:
        ids = [m['id'] for m in json.load(f)]
    maps_dir = os.path.join(game_root, 'Content', 'Maps')
    pad_table = make_pad_table(game_root)
    total = 0
    for map_id in ids:
        path = os.path.join(pack_dir, 'maps', map_id, 'map.json')
        with open(path, encoding='utf-8') as f:
            m = json.load(f)
        src = T._ci_file(maps_dir, map_id + '.tvm')
        if src is None:
            continue
        pkg = U.load(src)
        pkg.stem = map_id.lower()
        actors = T.read_actors(pkg)
        vehicles = export_vehicles(actors, T.to_world, tv_statics._basis, T._team_of, T.yaw_degrees)
        pads = export_pads(actors, pad_table, T.to_world, tv_statics._basis, T._team_of, T.yaw_degrees)
        m['statics'] = [s for s in m.get('statics', []) if not is_vehicle_static(s) and not is_pad(str(s.get('actor', '')))]
        m['vehicles'] = vehicles
        m['vehicle_pads'] = pads
        m['stations'] = [s for s in m.get('stations', []) if not s.get('vehicle')] + make_pad_stations(pads)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(m, f, indent=1, ensure_ascii=False)
        total += len(vehicles)
        if vehicles:
            log('%-26s %d vehicles' % (map_id, len(vehicles)))
    return total


def is_vehicle_static(s):
    return vehicle_id_of(str(s.get('actor', ''))) != ''


def update_pack_json(pack_dir, count):
    path = os.path.join(pack_dir, 'pack.json')
    with open(path, encoding='utf-8') as f:
        meta = json.load(f)
    meta.setdefault('provides', {})['hercs'] = count
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(meta, f, indent=1)


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    import tv_import
    root = tv_import.find_game_root(argv[0])
    pack_dir = argv[1] if len(argv) > 1 else P.pack(PACK)
    n = export(root, pack_dir)
    retrofit_maps(root, pack_dir)
    retrofit_scripts(root, pack_dir)
    update_pack_json(pack_dir, n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
