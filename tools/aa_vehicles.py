"""Aerial Assault vehicles as catalog records (gameplay/hercs.json, engine schema 1).

The disc's scout, bomb scout and grav scout shapes are the Tribes 2 Shrike, Thundersword and Wildcat (same art folder,
same names), so they take the Tribes 2 vehicle stats (scripts/vehicles/*.cs as exported by tools/export_tribes_vehicles.py).
The weapons are Tribes 2's too ("tribes2:" ids; without that pack the vehicle simply flies unarmed). The shapes are
exported facing the engine's forward (aa_shape.face_nose, NOSE below) with a single root node, so the guns hang on the root.
The transport (turrettrans_vehicle, the Tribes 2 Havoc: an AI-only carrier, unarmed) is the turret-style rigged shape: nodes with a
pose block and the wing fold sequence (aa_turret.rigged_json, nose 'back'), shown with the wings out.
The Thundersword's crew (belly-turret bombardier and tail gunner) needs seat data the disc shapes do not give, so the bomb
scout is a one-seat bomber carrying the two bombs only. """

# file axes of the shape's nose (+X is the engine's forward after to_json); see aa_shape.face_nose
NOSE = {'scout': (-1, 0), 'bombscout': (0, 1), 'grav_scout': (0, 1)}
# rigged vehicle shapes (nodes + pose block, aa_turret.rigged_json): stem -> nose direction
RIGGED = {'turrettrans_vehicle': 'back'}


def _hull(hp, max_damage):
    return {'components': [{'name': 'HULL', 'hp': hp, 'fatal': True, 'parent': -1, 'tribes_max_damage': max_damage}]}


def _crew(seats, weapon_seat, **extra):
    c = {'seats': seats, 'weapon_seat': weapon_seat, 'sitting': [0], 'light_only': False, 'no_enemy_control': False,
         'min_mount_dist': 4.0, 'rules': 'tribes2'}
    c.update(extra)
    return c


# shape stem -> (catalog key, Tribes 2 stats)
VEHICLES = {
    'scout': ('AA_SCOUT', {
        'kind': 'flyer', 'name': 'Scout', 'datablock': 'ScoutFlyer', 'class': 'FlyingVehicleData', 'mass': 150.0,
        'weight': 'light', 'size_class': 0, 'shield_max': 5250.0, 'shield_recharge': 468.8, 'damage': _hull(4200.0, 1.4),
        'energy': {'max': 280.0, 'recharge_per_s': 25.0}, 'crew': _crew(1, 0),
        'run_over': {'threshold_mps': 20.0, 'multiplier': 0.02},
        'flier_data': {'maxSpeed': 100.0, 'minSpeed': -4.0, 'accel': 0.2, 'lift': 1.333, 'maxAlt': 300.0,
                       'maxVertical': 20.0, 'maxBank': 0.5, 'maxPitch': 0.5, 'hoverHeight': 5.0, 'mass': 150.0,
                       'length_m': 0.0},
        'max_speed': 100.0, 'reverse_speed': 4.0, 'accel': 20.0, 'turn_rate': 1.5,
        'default_loadout': ['tribes2:SHRIKE_BLASTER', 'tribes2:SHRIKE_BLASTER'],
        'guns': [('ScoutChaingunImage', -0.6), ('ScoutChaingunPairImage', 0.6)]}),
    'bombscout': ('AA_BOMBSCOUT', {
        'kind': 'flyer', 'name': 'Bomb Scout', 'datablock': 'BomberFlyer', 'class': 'FlyingVehicleData', 'mass': 350.0,
        'weight': 'medium', 'size_class': 1, 'shield_max': 8000.0, 'shield_recharge': 500.0, 'damage': _hull(8400.0, 2.8),
        'energy': {'max': 400.0, 'recharge_per_s': 25.0}, 'crew': _crew(1, 0),
        'run_over': {'threshold_mps': 20.0, 'multiplier': 0.025},
        'flier_data': {'maxSpeed': 78.33, 'minSpeed': -3.13, 'accel': 0.171, 'lift': 1.429, 'maxAlt': 300.0,
                       'maxVertical': 15.67, 'maxBank': 0.25, 'maxPitch': 0.175, 'hoverHeight': 5.0, 'mass': 350.0,
                       'length_m': 0.0},
        'max_speed': 78.33, 'reverse_speed': 3.13, 'accel': 13.394, 'turn_rate': 0.75,
        'default_loadout': ['tribes2:BOMBER_BOMB', 'tribes2:BOMBER_BOMB'],
        'guns': [('BomberBombImage', -1.0), ('BomberBombPairImage', 1.0)]}),
    'turrettrans_vehicle': ('AA_TRANSPORT', {
        'kind': 'flyer', 'name': 'Transport', 'datablock': 'HAPCFlyer', 'class': 'FlyingVehicleData', 'mass': 550.0,
        'weight': 'medium', 'size_class': 1, 'shield_max': 8250.0, 'shield_recharge': 375.0, 'damage': _hull(10500.0, 3.5),
        'energy': {'max': 550.0, 'recharge_per_s': 25.0}, 'crew': _crew(6, None),
        'run_over': {'threshold_mps': 20.0, 'multiplier': 0.03},
        'flier_data': {'maxSpeed': 60.0, 'minSpeed': -2.4, 'accel': 0.182, 'lift': 0.909, 'maxAlt': 300.0,
                       'maxVertical': 12.0, 'maxBank': 0.25, 'maxPitch': 0.175, 'hoverHeight': 8.0, 'mass': 550.0,
                       'length_m': 0.0},
        'max_speed': 60.0, 'reverse_speed': 2.4, 'accel': 10.92, 'turn_rate': 0.75, 'default_loadout': [], 'guns': []}),
    'grav_scout': ('AA_GRAV_SCOUT', {
        'kind': 'cycle', 'name': 'Grav Scout', 'datablock': 'ScoutVehicle', 'class': 'HoverVehicleData', 'mass': 400.0,
        'weight': 'medium', 'size_class': 1, 'shield_max': 6000.0, 'shield_recharge': 875.0, 'damage': _hull(1800.0, 0.6),
        'energy': {'max': 150.0, 'recharge_per_s': 21.88}, 'crew': _crew(1, None, light_only=True),
        'run_over': {'threshold_mps': 20.0, 'multiplier': 0.01},
        'hover': {'stabLenMin': 2.25, 'stabLenMax': 3.25, 'floatingGravMag': 2.5, 'mainThrustForce': 25.0,
                  'reverseThrustForce': 10.0, 'dragForce': 0.555556, 'turboFactor': 2.0},
        'max_speed': 45.0, 'reverse_speed': 18.0, 'accel': 8.333, 'turn_rate': 2.0, 'default_loadout': [], 'guns': []}),
}


def records(pack, bounds):
    """{catalog key: record} for the vehicle shapes that were exported. `bounds[stem]` = (min, max) of the exported shape in
    its file axes after facing (aa_shape bounds header: x = engine east, y = file X forward, z = file Y up)."""
    out = {}
    for stem, (key, stats) in VEHICLES.items():
        if stem not in bounds:
            continue
        lo, hi = bounds[stem]
        width, length, height = hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]
        rec = {k: v for k, v in stats.items() if k != 'guns'}
        # muzzles in the source frame (x east, y forward, z up) at the nose, under the hull
        nose_y, belly_z = hi[1] - 0.3, lo[2] + 0.45 * height
        rec['guns'] = [{'name': name, 'attach_node': 0, 'muzzle_units': [round(side, 3), round(nose_y, 3), round(belly_z, 3)],
                        'mount_node': -1, 'mount_group': 0, 'hardpoint_mask': 0} for name, side in stats['guns']]
        rec.update({'engine_schema': 1, 'category': 'vehicle', 'side': 'herc', 'shape': '%s:%s' % (pack, stem),
                    'width_m': round(width, 2), 'length_m': round(length, 2), 'height_m': round(height, 2),
                    'fixed_loadout': True, 'torso_node': -1, 'cockpit_node': -1, 'torso_rate': 0.0, 'torso_limit': 0.0,
                    'pitch_rate': 0.0, 'pitch_max': 0.0, 'pitch_min': 0.0, 'fixtures': [],
                    'source': 'Aerial Assault %s.SHP with the Tribes 2 %s stats' % (stem.upper(), stats['datablock']),
                    'turn_rate_still': stats['turn_rate'], 'pilotable': bool(stats['guns'])})
        out[key] = rec
    return out
