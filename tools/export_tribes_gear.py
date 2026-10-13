"""Tribes (1998) and Tribes 2 (2001) infantry gear and vehicle seats -> the engine catalog.

Called by export_tribes_infantry.py (it owns the armours and hand weapons). This module adds:
  * per armour: fall damage (T1 PlayerData minDamageSpeed / damageScale, T2 minImpactSpeed / speedDamageScale),
    hand-item counts ($ItemMax / max[]), allowed packs, the spawn kit's items, the shield pack's energy per point;
  * gamedata/<pack>/gameplay/infantry_gear.json: thrown hand items (grenades, mines), the repair kit and the
    backpacks with the effect each maps to (energy, repair, shield, ammo, jammer) or "unmapped";
  * gamedata/<pack>/gameplay/vehicle_seats.json: each Tribes vehicle seat's role (pilot / gunner / armed
    passenger / passenger) and its seat node in the vehicle shape.
Evidence and approximations: docs/formats/tribes_infantry.md section 6, tribes_vehicles.md section 6.
"""
import json, os, re
import export_tribes_vehicles as V
import siege_paths as P

DAMAGE_SCALE = V.DAMAGE_SCALE
TICKS_PER_SECOND = V.TICKS_PER_SECOND
# Darkstar datablocks without a mass field (T1 MineData AntipersonelMine) weigh the engine default.
DARKSTAR_DEFAULT_MASS = 1.0
# Damage type the armour's fall damage counts as ($LandingDamageType / $DamageType::Ground).
T1_FALL_TYPE = 'landing'
T2_FALL_TYPE = 'ground'


def r(x, n=3):
    return V.r(x, n)


def read(path):
    return re.sub(r'//[^\n]*', '', open(path, encoding='latin1').read())


def find(rx, text, default=None, flags=re.S):
    m = re.search(rx, text, flags)
    if m is None:
        if default is None:
            raise ValueError('pattern not found in the scripts: %s' % rx)
        return default
    return m.group(1)


def keep_burst_fx(pack, gear):
    """Carries each item's `burst_fx` (written by the weapon_fx step, fx_deaths.attach_gear_bursts) over from the
    existing file, so re-running this exporter alone keeps the bursts' explosions."""
    path = P.pack(pack, 'gameplay', 'infantry_gear.json')
    if not os.path.exists(path):
        return
    with open(path, encoding='utf-8') as f:
        old = {i.get('id'): i for i in json.load(f).get('items', [])}
    for item in gear['items']:
        if 'burst_fx' in old.get(item['id'], {}) and 'burst_fx' not in item:
            item['burst_fx'] = old[item['id']]['burst_fx']


def write(pack, gear, seats):
    keep_burst_fx(pack, gear)
    V.wjson(P.pack(pack, 'gameplay', 'infantry_gear.json'), dict(gear, pack=pack, engine_schema=1))
    V.wjson(P.pack(pack, 'gameplay', 'vehicle_seats.json'), {'pack': pack, 'engine_schema': 1, 'vehicles': seats})
    print('%s: %d hand items, %d packs, %d vehicles with seats' % (pack, len(gear['items']), len(gear['packs']),
                                                                  len(seats)))


def load_vehicles(pack):
    with open(P.pack(pack, 'gameplay', 'hercs.json'), encoding='utf-8') as f:
        return json.load(f)


def thrown(key, name, kind, damage, radius, dtype, mass, elasticity, friction, **extra):
    """A thrown hand item: grenade (fuse) or mine (proximity once at rest)."""
    item = {'id': key, 'name': name, 'kind': kind, 'mapped': True, 'damage': r(damage * DAMAGE_SCALE, 1),
            'damage_tribes': damage, 'radius': radius, 'damage_type': dtype, 'mass': mass,
            'elasticity': elasticity, 'friction': friction}
    item.update(extra)
    return item


def shape_id(pack, shape_file):
    """The exported shape of a datablock's shapeFile, None when it was not exported (a stand-in is drawn)."""
    name = os.path.splitext(str(shape_file))[0].lower()
    return '%s:%s' % (pack, name) if name and V.Shape(pack, name).exists else None


def unmapped(key, name, kind, note):
    return {'id': key, 'name': name, 'kind': kind, 'mapped': False, 'note': note}


# ================================================================== Tribes 1

def t1_gear(db, item_max, armors, weapon_items):
    """Hand items, packs and per-armour limits of Tribes 1 (item.cs, Mine.cs, baseProjData.cs, player.cs)."""
    S = V.T1_SCRIPTS
    item_cs, mine_cs = read(os.path.join(S, 'item.cs')), read(os.path.join(S, 'Mine.cs'))
    proj_cs, player_cs = read(os.path.join(S, 'baseProjData.cs')), read(os.path.join(S, 'player.cs'))
    client_cs = read(os.path.join(S, 'client.cs'))
    throw = {'hold_max_s': float(find(r'function throwRelease.*?if \(%delta > ([\d.]+)\)', client_cs)),
             'min': float(find(r'throwStrength = ([\d.]+) \+ [\d.]+ \* \(%strength / 100\)', item_cs)),
             'span': float(find(r'throwStrength = [\d.]+ \+ ([\d.]+) \* \(%strength / 100\)', item_cs)),
             'timeout_s': float(find(r'throwTime = getSimTime\(\) \+ ([\d.]+)', item_cs))}
    items = [t1_grenade(db, item_cs, mine_cs, throw), t1_mine(db, item_cs, throw),
             {'id': 'tribes:REPAIR_KIT', 'name': 'Repair Kit', 'kind': 'repair_kit', 'mapped': True,
              'repair': r(float(find(r'RepairKit::onUse.*?repairDamage\(%player,\s*([\d.]+)\)', item_cs)) *
                          DAMAGE_SCALE, 1)},
             unmapped('tribes:BEACON', 'Beacon', 'beacon', 'Target beacon for the commander and the bomb sights; '
                      'no targeting system to feed in the remake.')]
    packs = t1_packs(db, item_cs, proj_cs, player_cs, weapon_items)
    hand = {'tribes:GRENADE': 'grenade', 'tribes:MINE': 'mineammo', 'tribes:REPAIR_KIT': 'repairkit',
            'tribes:BEACON': 'beacon'}
    pack_items = {p['id']: p['item'].lower() for p in packs}
    spawn = set(x.lower() for x in V_spawn_list(S))
    for block, a in armors.items():
        limits = item_max.get(block, {})
        a['hand_items'] = {k: limits.get(v, 0) for k, v in hand.items() if limits.get(v, 0) > 0}
        a['packs'] = [k for k, v in pack_items.items() if limits.get(v, 0) > 0]
        a['default_items'] = {k: 1 for k, v in hand.items() if v in spawn and k in a['hand_items']}
        f = db[block]['fields']
        a['fall_min_speed'] = V._f(f, 'minDamageSpeed')
        a['fall_damage_per_mps'] = r(V._f(f, 'damageScale') * DAMAGE_SCALE, 2)
        a['fall_damage_type'] = T1_FALL_TYPE
        # tribes.exe 0x4162d2: impact speed (velocity . -normal) above minDamageSpeed, damage =
        # (speed - minDamageSpeed) x damageScale (Tribes 2 Armor::onImpact counts the whole speed)
        a['fall_damage_above_min'] = True
    return {'throw': throw, 'items': items, 'packs': packs}


def V_spawn_list(scripts):
    return re.findall(r'\$spawnBuyList\[\d+\]\s*=\s*(\w+)', read(os.path.join(scripts, 'game.cs')))


def t1_grenade(db, item_cs, mine_cs, throw):
    g = db['handgrenade']['fields']
    impulse = float(find(r'function Grenade::onUse.*?GameBase::throw\(%obj,%player,\s*([\d.]+)\s*\*', item_cs))
    mass = V._f(g, 'mass', DARKSTAR_DEFAULT_MASS)
    return thrown('tribes:GRENADE', 'Grenade', 'grenade', V._f(g, 'damageValue'), V._f(g, 'explosionRadius'),
                  g['damageType'].strip('$').replace('DamageType', '').lower(), mass, V._f(g, 'elasticity'),
                  V._f(g, 'friction'),
                  shape=shape_id('tribes', g.get('shapeFile', '')),
                  fuse_s=float(find(r'function Handgrenade::onAdd.*?schedule\(.*?,\s*([\d.]+)\s*,\s*%this\)', mine_cs)),
                  throw_speed=r(impulse / mass, 2), source='Mine.cs MineData Handgrenade, item.cs Grenade::onUse')


def t1_mine(db, item_cs, throw):
    m = db['antipersonelmine']['fields']
    impulse = float(find(r'function MineAmmo::onUse.*?GameBase::throw\(%obj,%player,\s*([\d.]+)\s*\*', item_cs))
    mass = V._f(m, 'mass', DARKSTAR_DEFAULT_MASS)
    arm = float(find(r'AntipersonelMine::deployCheck\(" @ %this @ "\);",\s*([\d.]+)', read(os.path.join(V.T1_SCRIPTS, 'Mine.cs'))))
    return thrown('tribes:MINE', 'Mine', 'mine', V._f(m, 'damageValue'), V._f(m, 'explosionRadius'),
                  m['damageType'].strip('$').replace('DamageType', '').lower(), mass, 0.0, 1.0,
                  proximity=V._f(m, 'triggerRadius'), arm_s=arm, shape=shape_id('tribes', m.get('shapeFile', '')), throw_speed=r(impulse / mass, 2),
                  source='Mine.cs MineData AntipersonelMine (arms at rest, checked every %g s), item.cs MineAmmo::onUse'
                  % arm)


def t1_pack(db, item, effect, **extra):
    fields = db[item.lower()]['fields']
    key = 'tribes:' + re.sub(r'(?<=[a-z])(?=[A-Z])', '_', item).upper()
    p = {'id': key, 'item': item, 'name': fields.get('description', item), 'effect': effect,
         'mapped': effect != 'unmapped', 'price': int(V._f(fields, 'price'))}
    p.update(extra)
    return p


def t1_packs(db, item_cs, proj_cs, player_cs, weapon_items):
    img = lambda n: db[n.lower()]['fields']
    shield = float(find(r'ShieldPackImage::onActivate.*?shieldStrength = ([\d.]+);', item_cs))
    ammo_max = {k.lower(): int(v) for k, v in re.findall(r'\$AmmoPackMax\[(\w+)\]\s*=\s*(\d+);', item_cs)}
    extra = {wid: ammo_max[ammo] for wid, ammo in weapon_items.items() if ammo in ammo_max}
    extra.update({'tribes:GRENADE': ammo_max.get('grenade', 0), 'tribes:MINE': ammo_max.get('mineammo', 0)})
    deployables = ('DeployableInvPack', 'DeployableAmmoPack', 'MotionSensorPack', 'PulseSensorPack',
                   'DeployableSensorJammerPack', 'CameraPack', 'TurretPack')
    return [
        t1_pack(db, 'EnergyPack', 'energy', recharge_bonus_per_s=-V._f(img('EnergyPackImage'), 'maxEnergy'),
                note='Sustained image with a negative energy use: it adds that much energy per second.'),
        t1_pack(db, 'RepairPack', 'repair', toggled=True, min_energy=V._f(img('RepairGunImage'), 'minEnergy'),
                energy_per_s=V._f(img('RepairGunImage'), 'maxEnergy'),
                repair_per_s=r(float(find(r'if \(%target == %player\) \{.*?repairRate = ([\d.]+);', proj_cs)) *
                               DAMAGE_SCALE, 1),
                note='Use mounts the repair gun; with no target it repairs its user (RepairBolt::onAcquire).'),
        t1_pack(db, 'ShieldPack', 'shield', toggled=True, min_energy=V._f(img('ShieldPackImage'), 'minEnergy'),
                energy_per_s=V._f(img('ShieldPackImage'), 'maxEnergy'),
                energy_per_damage=r(1.0 / shield / DAMAGE_SCALE, 5),
                weak_types={t: float(find(r'%strength \*= ([\d.]+);', player_cs)) for t in ('shrapnel', 'mortar')},
                note='Player::onDamage: energy x shieldStrength %g absorbs the hit; shrapnel and mortar hits '
                     'face a weaker shield.' % shield),
        t1_pack(db, 'SensorJammerPack', 'jammer', toggled=True,
                energy_per_s=V._f(img('SensorJammerPackImage'), 'maxEnergy'), min_energy=1.0,
                jam_radius=float(find(r'getSensorSupression\(%player\) \+ (\d+)', item_cs)),
                note='Sensor suppression; the remake hides the wearer from bots beyond the radius and deflects '
                     'homing missiles.'),
        t1_pack(db, 'AmmoPack', 'ammo', extra_rounds=extra, note='$AmmoPackMax rounds on top of the armour limit.'),
    ] + [t1_pack(db, n, 'deploy', note='Deployable: pack use places it (TribesDeployables; rules in '
                                       'base_equipment.json "deployables").') for n in deployables]


# Tribes 1 PlayerData animData slot the engine poses a seated passenger with (driverPose is the pilot's).
T1_PASSENGER_POSE = 24
T1_BLOCKS = {'SCOUT': 'Scout', 'LAPC': 'LAPC', 'HAPC': 'HAPC'}


def t1_pose_names(slot):
    """Sequence names of animData[slot] over every armour, in ArmorData.cs order without repeats: a soldier
    plays the first his shape has (lfemale / mfemale name "apc root" where the male armours name "apc pilot")."""
    armor_cs = read(os.path.join(V.T1_SCRIPTS, 'ArmorData.cs'))
    names = re.findall(r'animData\[%d\]\s*=\s*\{\s*"([^"]+)"' % slot, armor_cs)
    return list(dict.fromkeys(names))


def t1_seats(vehicles):
    """Seats at the vehicle's dummy nodes. FlierData visibleDriver = true on all three: the pilot shows in its
    driverPose (animData slot); passengers show in animData[T1_PASSENGER_POSE]."""
    vehicle_cs = read(os.path.join(V.T1_SCRIPTS, 'vehicle.cs'))
    out = {}
    for key, v in vehicles.items():
        crew = v.get('crew', {})
        block = find(r'FlierData %s\s*\{(.*?)\n\};' % T1_BLOCKS[key], vehicle_cs)
        shown = find(r'visibleDriver\s*=\s*(\w+);', block, 'false') == 'true'
        driver_pose = t1_pose_names(int(find(r'driverPose\s*=\s*(\d+);', block, '0')))
        seats = [{'seat': 0, 'role': 'pilot', 'node': 'dummy pilot128', 'shown': shown, 'pose': driver_pose,
                  'weapon_shown': False}]
        for s in range(1, int(crew.get('seats', 1))):
            # Vehicle::onCollision unmounts only the pilot's weapon: passengers keep theirs and fire.
            seats.append({'seat': s, 'role': 'armed', 'node': 'dummy passenger%d' % s, 'shown': shown,
                          'pose': t1_pose_names(T1_PASSENGER_POSE), 'weapon_shown': True})
        out['tribes:' + key] = seats
    return out


# ================================================================== Tribes 2

T2_HAND = (('Grenade', 'GRENADE', 'Grenade', 'grenade'), ('ConcussionGrenade', 'CONCUSSION_GRENADE',
           'Concussion Grenade', 'concussion'), ('FlashGrenade', 'FLASH_GRENADE', 'Flash Grenade', 'grenade'),
           ('Mine', 'MINE', 'Mine', 'mine'))
T2_UNMAPPED_HAND = (('FlareGrenade', 'FLARE_GRENADE', 'Flare Grenade', 'Missile decoy: missiles home on targets only.'),
                    ('CameraGrenade', 'CAMERA_GRENADE', 'Deployable Camera', 'Deployable camera: no remote views.'),
                    ('Beacon', 'BEACON', 'Beacon', 'Target beacon: no targeting system to feed.'))
T2_PACKS = (('EnergyPack', 'energy'), ('RepairPack', 'repair'), ('ShieldPack', 'shield'),
            ('SensorJammerPack', 'jammer'), ('AmmoPack', 'ammo'), ('CloakingPack', 'unmapped'),
            ('SatchelCharge', 'unmapped'), ('InventoryDeployable', 'deploy'), ('TurretIndoorDeployable', 'deploy'),
            ('TurretOutdoorDeployable', 'deploy'), ('MotionSensorDeployable', 'deploy'),
            ('PulseSensorDeployable', 'deploy'), ('AABarrelPack', 'unmapped'), ('ELFBarrelPack', 'unmapped'),
            ('MissileBarrelPack', 'unmapped'), ('MortarBarrelPack', 'unmapped'), ('PlasmaBarrelPack', 'unmapped'))
T2_UNMAPPED_NOTES = {'CloakingPack': 'Cloak: the remake renders no cloaked shapes.',
                     'SatchelCharge': 'Large pack: a remote charge (not modelled).'}


def t2_type(text):
    return str(text).replace('$DamageType::', '').lower()


def t2_gear(resolve, armors, weapon_items):
    S = V.T2_SCRIPTS
    weapons_cs, inv_cs = read(os.path.join(S, 'weapons.cs')), read(os.path.join(S, 'inventory.cs'))
    turret_cs, item_cs = read(os.path.join(S, 'weapTurretCode.cs')), read(os.path.join(S, 'item.cs'))
    throw = {'per_strength': float(find(r'vectorScale\(%eye, \(%throwStren \* ([\d.]+)\)\)', weapons_cs)),
             'lift': float(find(r'vectorScale\("0 0 ([\d.]+)", 1 - %dot\)', weapons_cs)),
             'inherit': float(find(r'vectorScale\(%obj.getVelocity\(\), ([\d.]+)\)', weapons_cs)),
             'timeout_s': float(find(r'\$HandInvThrowTimeout = ([\d.]+) \* 1000', weapons_cs)),
             'hold_ms_per_strength': float(find(r'throwStart\) / (\d+);', inv_cs)),
             'strength_max': float(find(r'if\(%throwStrength > ([\d.]+)\)', inv_cs)),
             'strength_min': float(find(r'else if\(%throwStrength < ([\d.]+)\)', inv_cs)),
             'strength_divisor': float(find(r'%throwScale = %throwStrength / (\d+);', inv_cs))}
    fuses = {n.lower(): float(ms) / 1000.0 for n, ms in
             re.findall(r'function (\w+)::onThrow\(%this, %gren\)\s*\{[^}]*?schedule\((\d+), %gren', turret_cs)}
    items = [t2_thrown(resolve, item, key, name, kind, fuses) for item, key, name, kind in T2_HAND]
    items.append({'id': 'tribes2:REPAIR_KIT', 'name': 'Repair Kit', 'kind': 'repair_kit', 'mapped': True,
                  'repair': r(float(find(r'RepairKit::onUse.*?applyRepair\(([\d.]+)\)', item_cs)) * DAMAGE_SCALE, 1)})
    items += [unmapped('tribes2:' + key, name, 'other', note) for _, key, name, note in T2_UNMAPPED_HAND]
    packs = [t2_pack(resolve, item, effect, weapon_items) for item, effect in T2_PACKS]
    for block, a in armors.items():
        b = resolve(block)
        hand = {'tribes2:' + key: int(float(b.get('max[%s]' % item, 0))) for item, key, _, _ in T2_HAND}
        hand['tribes2:REPAIR_KIT'] = int(float(b.get('max[RepairKit]', 0)))
        a['hand_items'] = {k: v for k, v in hand.items() if v > 0}
        a['max_grenade_types'] = int(float(b.get('maxGrenades', 1)))
        a['packs'] = [p['id'] for p in packs if int(float(b.get('max[%s]' % p['item'], 0))) > 0]
        a['default_items'] = t2_spawn_items(a['hand_items'])
        a['fall_min_speed'] = float(b['minImpactSpeed'])
        a['fall_damage_per_mps'] = r(float(b['speedDamageScale']) * DAMAGE_SCALE, 2)
        a['fall_damage_type'] = T2_FALL_TYPE
        a['fall_damage_above_min'] = False
        a['shield_energy_per_damage'] = r(float(b['energyPerDamagePoint']) / DAMAGE_SCALE, 5)
        a['damage_scale'] = t2_damage_scale(block)
    return {'throw': throw, 'items': items, 'packs': packs}


def t2_damage_scale(block):
    """damageScale[$DamageType::X] of the armour's damage profile (player.cs `PlayerData(Armor) : Profile`,
    damageTypes.cs), read from the text: the datablock reader does not split the `::` keys."""
    profile = find(r'datablock PlayerData\(%s\)\s*:\s*(\w+)' % block, read(os.path.join(V.T2_SCRIPTS, 'player.cs')))
    body = find(r'datablock SimDataBlock\(%s\)\s*\{(.*?)\n\}' % profile,
                read(os.path.join(V.T2_SCRIPTS, 'damageTypes.cs')))
    return {t.lower(): float(v) for t, v in
            re.findall(r'^\s*damageScale\[\$DamageType::(\w+)\]\s*=\s*([\d.]+)', body, re.M)}


def t2_spawn_items(hand):
    """DefaultGame::equip (defaultGame.cs): setInventory(RepairKit, 1), setInventory(Grenade, n)."""
    txt = read(os.path.join(V.T2_SCRIPTS, 'defaultGame.cs'))
    body = find(r'function DefaultGame::equip.*?\{(.*?)\n\}', txt)
    out = {}
    for item, n in re.findall(r'setInventory\((\w+)\s*,\s*(\d+)\)', body):
        key = {'RepairKit': 'tribes2:REPAIR_KIT', 'Grenade': 'tribes2:GRENADE'}.get(item)
        if key in hand:
            out[key] = min(int(n), hand[key])
    return out


def t2_thrown(resolve, item, key, name, kind, fuses):
    t_name = str(resolve(item)['thrownItem'])
    t = resolve(t_name)
    common = dict(fuse_s=fuses.get(t_name.lower(), 0.0), kick=float(t.get('kickBackStrength', 0.0)),
                  source='scripts/weapons %s -> %s' % (item, t_name), shape=shape_id('tribes2', t.get('shapeFile', '')))
    if kind == 'mine':
        common.update(proximity=float(t['proximity']), arm_s=float(t['armTime']) / 1000.0)
    return thrown('tribes2:' + key, name, kind, float(t.get('indirectDamage', 0.0)), float(t['damageRadius']),
                  t2_type(t.get('radiusDamageType', '')), float(t['mass']), float(t['elasticity']),
                  float(t['friction']), **common)


def t2_pack(resolve, item, effect, weapon_items):
    b = resolve(item)
    img = resolve(str(b.get('image', item + 'Image')))
    p = {'id': 'tribes2:' + re.sub(r'(?<=[a-z])(?=[A-Z])', '_', item).upper(), 'item': item,
         'name': re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', item), 'effect': effect, 'mapped': effect != 'unmapped', 'price': 0}
    if effect == 'energy':
        p['recharge_bonus_per_s'] = r(float(img['rechargeRateBoost']) * TICKS_PER_SECOND, 2)
    elif effect == 'repair':
        gun = resolve('RepairGunImage')
        p.update(toggled=True, min_energy=float(gun['minEnergy']), energy_per_s=float(gun['stateEnergyDrain[3]']),
                 repair_per_s=r(float(gun['repairFactorPlayer']) * TICKS_PER_SECOND * DAMAGE_SCALE, 1),
                 note='Use activates the repair gun; with no target in range it repairs its user.')
    elif effect in ('shield', 'jammer'):
        p.update(toggled=True, min_energy=float(img['minEnergy']), energy_per_s=float(img['stateEnergyDrain[1]']))
        if effect == 'jammer':
            p['jam_radius'] = float(resolve('JammerSensorObject')['jamRadius'])
        else:
            p['note'] = 'Armor checkShields: energy / energyPerDamagePoint (per armour) absorbs the hit.'
    elif effect == 'ammo':
        p['extra_rounds'] = {wid: int(float(b['max[%s]' % ammo])) for wid, ammo in weapon_items.items()
                             if 'max[%s]' % ammo in b}
        p['extra_rounds'].update({'tribes2:' + key: int(float(b.get('max[%s]' % it, 0))) for it, key, _, _ in T2_HAND
                                  if 'max[%s]' % it in b})
    else:
        p['note'] = T2_UNMAPPED_NOTES.get(item, 'Deployable: no deployable objects in the remake.')
    return p


# The turret datablock a gunner seat works (BomberFlyer / AssaultVehicle::onAdd mount them on mount point 10).
T2_GUNNER_TURRETS = {'THUNDERSWORD': 'BomberTurret', 'BEOWULF': 'AssaultPlasmaTurret'}


def t2_turret_pitch(resolve, vehicle_key):
    """The turret's pitch range (degrees above level) from TurretData thetaMin / thetaMax (angle from straight
    up): theta 90 = level, 180 = straight down."""
    t = resolve(T2_GUNNER_TURRETS[vehicle_key])
    return {'pitch_max_deg': 90.0 - float(t['thetaMin']), 'pitch_min_deg': 90.0 - float(t['thetaMax']),
            'turret': T2_GUNNER_TURRETS[vehicle_key]}


def t2_seats(vehicles, resolve):
    out = {}
    for key, v in vehicles.items():
        crew = v.get('crew', {})
        sitting = [int(s) for s in crew.get('sitting', [])]
        gunner = crew.get('weapon_seat')
        seats = []
        for s in range(int(crew.get('seats', 1))):
            role = 'pilot' if s == 0 else 'gunner' if s == gunner else 'passenger' if s in sitting else 'armed'
            # Armor::onMount: the player sits on the mount node in the vehicle's mountPose[node] (else "root");
            # the pilot (onMount node 0) and the gunner (<Vehicle>::playerMounted node 1) unmount their weapon.
            pose = str(resolve(v['datablock']).get('mountPose[%d]' % s) or 'root')
            seats.append({'seat': s, 'role': role, 'node': 'Mount%d' % s, 'shown': True, 'pose': [pose],
                          'weapon_shown': role not in ('pilot', 'gunner')})
            if role == 'gunner':
                seats[-1].update(t2_turret_pitch(resolve, key))
        out['tribes2:' + key] = seats
    return out
