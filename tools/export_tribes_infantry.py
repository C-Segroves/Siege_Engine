"""Tribes (1998) and Tribes 2 (2001) infantry: the three armours and their hand weapons -> the engine catalog.

Tribes players are 2 m soldiers in light / medium / heavy powered armour with a jetpack. Each armour is a
PlayerData datablock (movement, jet, energy, damage) plus per-armour item limits ($ItemMax / max[...]): which
weapons it may carry, how many at once ($MaxWeapons / maxWeapons) and how much ammunition. The hand weapons are
ItemImageData / ShapeBaseImageData images firing projectile datablocks. Evidence and approximations:
docs/formats/tribes_infantry.md.

Input  Tribes 1: tribes/extracted/scripts/{ArmorData,item,baseProjData,nsound,game}.cs, tribes/extracted/sound
       Tribes 2: tribes2/extracted/scripts/scripts/{player.cs, weapons/*.cs}, tribes2/extracted/audio/audio
       both: exported shapes gamedata/<pack>/shapes/<shape>.json (heights, eye and hand nodes)
Output gamedata/<pack>/gameplay/armors.json              armours ("engine_schema": 1, metres, m/s, ES damage)
       gamedata/<pack>/gameplay/infantry_gear.json         grenades, mines, repair kit, packs (export_tribes_gear)
       gamedata/<pack>/gameplay/vehicle_seats.json         Tribes vehicle seat roles (export_tribes_gear)
       gamedata/<pack>/gameplay/weapons_infantry.json    docs/formats/weapon_schema.md, "category": "infantry"
       gamedata/<pack>/audio/sfx/sim/<stem>.wav           fire, jet, footstep and mount sounds

Usage: python tools/export_tribes_infantry.py [tribes|tribes2]
"""
import json, math, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_tribes_gear as G  # noqa: E402
import export_tribes_vehicles as V  # noqa: E402
import siege_paths as P  # noqa: E402

CATEGORY = 'infantry'
GRAVITY = V.GRAVITY
TICKS_PER_SECOND = V.TICKS_PER_SECOND
DAMAGE_SCALE = V.DAMAGE_SCALE
# T1 GrenadeData has no muzzle velocity, only maxLevelFlightDist: the 45-degree range on level ground,
# so the launch speed is sqrt(range * g). A lobbed shell is removed after its 45-degree flight time x this margin.
GRENADE_FLIGHT_MARGIN = 1.5
# Neither game states a laser rifle range in the T1 scripts; T2 BasicSniperShot.maxRifleRange = 1000 m.
LASER_RANGE = 1000.0
# T2 ShockLance reach is engine-side (not in the scripts): a guess, recorded in the weapon notes.
SHOCKLANCE_RANGE = 14.0
# Collision capsule radius per size: T2 PlayerData boundingBox (1.2 / 1.45 / 1.63 m wide) / 2; T1 PlayerData has
# no bounding box, so the T2 values are used for both games.
CAPSULE_RADIUS = {'light': 0.6, 'medium': 0.725, 'heavy': 0.815}
INFANTRY_NOTE = ('Tribes damage x%g -> Earthsiege scale (armour maxDamage 0.66 .. 1.32 -> 1980 .. 3960 hp; '
                 'the same factor as the Tribes vehicles). Per-armour damage-type scales ($DamageScale / '
                 '*DamageProfile) are applied per hit by damage type.' % DAMAGE_SCALE)


def r(x, n=3):
    return V.r(x, n)


def num(fields, key, default=0.0):
    """A Darkstar field that may be simple arithmetic (larmor groundForce = "40 * 9.0")."""
    import catalog_tribes2 as C
    value = C.num(str(fields.get(key, default)))
    return float(value) if value is not None else default


def node_position(shape, prefix):
    """Default-pose position (metres, shape frame z up) of the first node whose name starts with `prefix`."""
    for i, name in enumerate(shape.names):
        if name.lower().startswith(prefix.lower()):
            return shape.positions[i], i
    return [0.0, 0.0, 0.0], -1


def damage_type(text):
    """The armours' damage-scale key of a damage type: T1 "$BulletDamageType" -> "bullet", T2 "Blaster" -> "blaster"."""
    return re.sub(r'damagetype$', '', str(text).replace('$DamageType::', '').strip('$').lower())


def make_weapon(key, display, source, kind, refire, damage, projectile, energy, sound, model, notes, **extra):
    """An engine weapon record (weapon_schema.md) of the infantry family."""
    radius = float(damage.get('radius', 0.0))
    dmg = r(float(damage['value']) * DAMAGE_SCALE, 1)
    w = {'name': key, 'display_name': display, 'category': CATEGORY, 'source': source, 'size_class': 'special',
         'hardpoint_mask': 0, 'kind': kind, 'fire_group': 1, 'refire': r(refire), 'burst': 1,
         'burst_interval': 0.0, 'spread_deg': r(extra.get('spread_deg', 0.0), 2), 'ammo': -1,
         'energy': {'min_charge': energy[0], 'per_shot': energy[1]}, 'heat': None,
         'damage': {'shield': dmg, 'armor': dmg, 'splash': 1.0 if radius > 0 else 0.0, 'splash_radius': radius,
                    'tribes': float(damage['value']), 'type': damage_type(damage.get('type', ''))},
         'effects': extra.get('effects', {}), 'projectile': projectile, 'beam': extra.get('beam'),
         'model': {'mount_shapes': [model] if model else []}, 'sounds': {'fire': sound}, 'notes': notes}
    w['range'] = r(extra['range'] if 'range' in extra else projectile['speed'] * projectile['lifetime'], 1)
    return w


def lobbed_projectile(speed, shape, inherit):
    flight = 2.0 * speed * math.sin(math.radians(45.0)) / GRAVITY * GRENADE_FLIGHT_MARGIN
    return {'speed': r(speed, 2), 'gravity': GRAVITY, 'lifetime': r(flight, 2), 'guidance': 'none', 'turn_rate_deg': 0.0,
            'arm_delay': 0.0, 'proximity': 0.0, 'shape': shape, 'trail': 'smoke', 'inherit_velocity': inherit}


def straight_projectile(speed, lifetime, shape, inherit, color, trail='glow'):
    return {'speed': r(speed, 2), 'gravity': 0.0, 'lifetime': r(lifetime, 2), 'guidance': 'none', 'turn_rate_deg': 0.0,
            'arm_delay': 0.0, 'proximity': 0.0, 'shape': shape, 'trail': trail, 'inherit_velocity': inherit,
            'color': color}


def beam(color, width=0.08, duration=0.12):
    return {'color': color, 'width': width, 'duration': duration, 'count': 1}


def keep_fx(pack, weapons):
    """Keeps the weapons' "fx" blocks of the existing weapons_infantry.json (V.keep_fx)."""
    V.keep_fx(P.pack(pack, 'gameplay', 'weapons_infantry.json'), weapons)


# The bodies an armour can be worn with, by pack and size: (shape, label, bioderm). The female and Bioderm
# PlayerData blocks share the male values (section 1 of tribes_infantry.md), so they are bodies, not armours.
BODIES = {
    'tribes': {'light': (('larmor', 'Male', False), ('lfemale', 'Female', False)),
               'medium': (('marmor', 'Male', False), ('mfemale', 'Female', False)),
               'heavy': (('harmor', 'Male', False),)},
    'tribes2': {'light': (('light_male', 'Male', False), ('light_female', 'Female', False),
                          ('bioderm_light', 'Bioderm', True)),
                'medium': (('medium_male', 'Male', False), ('medium_female', 'Female', False),
                           ('bioderm_medium', 'Bioderm', True)),
                'heavy': (('heavy_male', 'Male', False), ('bioderm_heavy', 'Bioderm', True))},
}


def add_bodies(pack, armors):
    """Each armour's `bodies` [{shape, label, bioderm}]: the exported body shapes, its own shape first."""
    for a in armors.values():
        bodies = [{'shape': '%s:%s' % (pack, name), 'label': label, 'bioderm': bio}
                  for name, label, bio in BODIES[pack][a['size']] if V.Shape(pack, name).exists]
        own = [b for b in bodies if b['shape'] == a['shape']] or [{'shape': a['shape'], 'label': 'Male', 'bioderm': False}]
        a['bodies'] = own + [b for b in bodies if b['shape'] != a['shape']]


def write(pack, armors, weapons, gear, seats):
    add_bodies(pack, armors)
    G.write(pack, gear, seats)
    keep_fx(pack, weapons)
    V.wjson(P.pack(pack, 'gameplay', 'armors.json'), {'pack': pack, 'engine_schema': 1, 'armors': armors})
    V.wjson(P.pack(pack, 'gameplay', 'weapons_infantry.json'),
            {'pack': pack, 'damage_scale_note': INFANTRY_NOTE, 'weapons': weapons})
    print('%s: %d armours, %d infantry weapons' % (pack, len(armors), len(weapons)))


# ================================================================== Tribes 1

T1 = V.T1_SCRIPTS
T1_SOUNDS = V.T1_SOUNDS
# PlayerData -> (catalog key, display, size). The female armours (lfemale, mfemale) share the male values except
# a few ammo / damage-scale entries and are not exported.
T1_ARMORS = (('larmor', 'LIGHT', 'Light Armor', 'light'), ('marmor', 'MEDIUM', 'Medium Armor', 'medium'),
             ('harmor', 'HEAVY', 'Heavy Armor', 'heavy'))
# ItemData (the $ItemMax key) -> catalog key, display. TargetingLaser and RepairGun do no damage: not exported.
T1_WEAPONS = (('Blaster', 'BLASTER', 'Blaster'), ('Chaingun', 'CHAINGUN', 'Chaingun'),
              ('PlasmaGun', 'PLASMA_GUN', 'Plasma Gun'), ('GrenadeLauncher', 'GRENADE_LAUNCHER', 'Grenade Launcher'),
              ('Mortar', 'MORTAR', 'Mortar'), ('DiscLauncher', 'DISC_LAUNCHER', 'Disc Launcher'),
              ('LaserRifle', 'LASER_RIFLE', 'Laser Rifle'), ('EnergyRifle', 'ELF_GUN', 'ELF Gun'))
T1_ARMOR_ITEMS = {'LIGHT': 'LightArmor', 'MEDIUM': 'MediumArmor', 'HEAVY': 'HeavyArmor'}


def t1_globals():
    """$ItemMax[armor, item], $MaxWeapons[armor], $DamageScale[armor, $Type] and $spawnBuyList of the scripts."""
    txt = ''.join(open(os.path.join(T1, f), encoding='latin1').read() for f in ('ArmorData.cs', 'game.cs'))
    item_max, max_weapons, scale = {}, {}, {}
    for a, item, n in re.findall(r'\$ItemMax\[(\w+),\s*(\w+)\]\s*=\s*([\d.]+)', txt):
        item_max.setdefault(a.lower(), {})[item.lower()] = int(float(n))
    for a, n in re.findall(r'\$MaxWeapons\[(\w+)\]\s*=\s*(\d+)', txt):
        max_weapons[a.lower()] = int(n)
    for a, t, n in re.findall(r'\$DamageScale\[(\w+),\s*\$(\w+)DamageType\]\s*=\s*([\d.]+)', txt):
        scale.setdefault(a.lower(), {})[t.lower()] = float(n)
    spawn = [m for m in re.findall(r'\$spawnBuyList\[\d+\]\s*=\s*(\w+)', txt)]
    return item_max, max_weapons, scale, spawn


def t1_sound(db, sound_block):
    wav = db.get(str(sound_block).lower(), {}).get('fields', {}).get('wavFileName', '')
    return V.copy_sound('tribes', V.find_file(T1_SOUNDS, wav)) if wav else ''


# Footstep sound ranges (metres, [min, max] distance): T1 nsound.cs Profile3dFoot; T2 serverAudio.cs
# AudioClosest3d (soft, the L/RFootSoftSound profiles) and AudioClose3d (hard: interiors).
T1_FOOTSTEP_RANGE = [2.0, 30.0]
T2_FOOTSTEP_RANGE = [5.0, 30.0]
T2_FOOTSTEP_HARD_RANGE = [10.0, 60.0]
# Darkstar footstep surface index of the l/rFootSounds arrays: 0 soft (terrain), 1 hard.
T1_SOFT, T1_HARD = 0, 1


def t1_foot_sounds(db, block):
    """{footstep_left, footstep_right, footstep_hard_left, footstep_hard_right} of PlayerData `block`'s
    lFootSounds / rFootSounds arrays (ArmorData.cs; the datablock parser does not read brace arrays)."""
    txt = re.sub(r'//[^\n]*', '', open(os.path.join(T1, 'ArmorData.cs'), encoding='latin1').read())
    m = re.search(r'PlayerData\s+%s\s*\{(.*?)\n\}' % re.escape(block), txt, re.S | re.I)
    body = m.group(1) if m else ''
    arrays = {k.lower(): [w.strip() for w in v.split(',') if w.strip()]
              for k, v in re.findall(r'(\w+FootSounds)\s*=\s*\{(.*?)\}', body, re.S)}
    left, right = arrays.get('lfootsounds', []), arrays.get('rfootsounds', [])

    def sound(arr, i):
        return t1_sound(db, arr[i]) if i < len(arr) else ''
    return {'footstep_left': sound(left, T1_SOFT), 'footstep_right': sound(right, T1_SOFT),
            'footstep_hard_left': sound(left, T1_HARD), 'footstep_hard_right': sound(right, T1_HARD),
            'footstep_range': T1_FOOTSTEP_RANGE, 'footstep_hard_range': T1_FOOTSTEP_RANGE}


# Darkstar ItemImageData weaponType (item.cs comments): 1 spinning (the chaingun spins while firing), 3 the disc
# launcher (spins while ready: sfxReady SoundDiscSpin).
T1_SPINNING, T1_DISC = 1, 3


def t1_weapon_animation(img):
    """The weapon model's sequences by role (InfantryWeaponAnimation; docs/formats/tribes_infantry.md section 1):
    Darkstar plays the image shape's "activation" when drawn, "fire" per shot, "reload" after it, "ambient" all the
    time and "spin" (spinUpTime / spinDownTime) while firing a spinning weapon or while a disc launcher is ready.
    Sequences play at their authored speed; a role whose sequence the shape lacks plays nothing."""
    spin_on = {T1_SPINNING: 'trigger', T1_DISC: 'ready'}.get(int(V._f(img, 'weaponType')), '')
    return {'activate': 'activation', 'fire': 'fire', 'reload': 'reload', 'ambient': 'ambient',
            'spin': 'spin' if spin_on else '', 'spin_on': spin_on,
            'spin_up_s': V._f(img, 'spinUpTime'), 'spin_down_s': V._f(img, 'spinDownTime')}


def t2_weapon_animation(img):
    """The same roles from a Tribes 2 ShapeBaseImageData state machine (weapons/*.cs): stateSequence of the states
    named Activate, Ready, Fire, Reload and NoAmmo (as named in the script: a name the shape lacks, e.g. the disc's
    "Activated", plays nothing, as in the original); Torque plays the image's "ambient" sequence always and its
    "spin" sequence by stateSpinThread (SpinUp / FullSpeed while firing). stateScaleAnimation is never set, so
    sequences play at their authored speed."""
    by_state, timeout = {}, {}
    for k, v in img.items():
        m = re.match(r'stateName\[(\d+)\]$', k)
        if m:
            by_state[str(v).lower()] = str(img.get('stateSequence[%s]' % m.group(1), '') or '')
            timeout[str(v).lower()] = float(img.get('stateTimeoutValue[%s]' % m.group(1), 0) or 0)
    spins = [str(v).lower() for k, v in img.items() if k.startswith('stateSpinThread[')]
    spin_on = 'trigger' if 'fullspeed' in spins else ''
    return {'activate': by_state.get('activate', ''), 'ready': by_state.get('ready', ''),
            'fire': by_state.get('fire', ''), 'reload': by_state.get('reload', ''),
            'no_ammo': by_state.get('noammo', ''), 'ambient': 'ambient',
            'spin': 'spin' if spin_on else '', 'spin_on': spin_on, 'spin_up_s': timeout.get('spinup', 0.0),
            'spin_down_s': timeout.get('spindown', 0.0)}


def t1_items(db):
    """ItemData blocks (weapons with their imageType, armour prices) of item.cs (the datablock parser skips
    them: their class is ItemData, matched here separately)."""
    txt = re.sub(r'//[^\n]*', '', open(os.path.join(T1, 'item.cs'), encoding='latin1').read())
    out = {}
    for m in re.finditer(r'^ItemData\s+(\w+)\s*\{(.*?)\n\s*\}\s*;', txt, re.S | re.M):
        out[m.group(1).lower()] = {k: v.strip().strip('"') for k, v in re.findall(r'(\w+)\s*=\s*([^;]+);', m.group(2))}
    return out


def t1_weapon(db, items, item_name, key, display):
    img_name = items[item_name.lower()]['imageType']
    img = db[img_name.lower()]['fields']
    proj_block = db[img['projectileType'].lower()]
    p, pclass = proj_block['fields'], proj_block['class']
    refire = V._f(img, 'fireTime') + V._f(img, 'reloadTime')
    sound = t1_sound(db, img.get('sfxFire', ''))
    model = 'tribes:' + img['shapeFile'].lower()
    source = 'scripts/item.cs ItemImageData %s -> scripts/baseProjData.cs %s %s' % (img_name, pclass, proj_block['name'])
    color = [r(x, 2) for x in V._vec(p.get('lightColor', img.get('lightColor', '1 1 1')).strip('{} ').replace(',', ' '))]
    energy = (int(V._f(img, 'minEnergy')), int(round(V._f(img, 'maxEnergy'))))
    inherit = V._f(p, 'inheritedVelocityScale')
    radius = V._f(p, 'explosionRadius') if V._f(p, 'damageClass') == 1 else 0.0
    damage = {'value': V._f(p, 'damageValue'), 'radius': radius, 'type': p.get('damageType', '').strip('$')}
    shape = V.Shape('tribes', os.path.splitext(p.get('bulletShapeName', ''))[0].lower())
    shape_id = shape.id if p.get('bulletShapeName') and shape.exists else None
    if pclass == 'BulletData':
        proj = straight_projectile(V._f(p, 'muzzleVelocity'), V._f(p, 'totalTime'), shape_id, inherit, color)
        kind = 'plasma' if radius > 0 else 'cannon'
        return make_weapon(key, display, source, kind, refire, damage, proj, energy, sound, model,
                           'Bullet: muzzleVelocity, totalTime; refire = fireTime + reloadTime.' +
                           (' Energy: minEnergy to fire, maxEnergy per shot.' if energy[1] else ''),
                           spread_deg=math.degrees(V._f(p, 'aimDeflection')))
    if pclass == 'RocketData':
        dist = V.t1_rocket_flight(p)
        proj = straight_projectile(dist / V._f(p, 'totalTime'), V._f(p, 'totalTime'), shape_id, inherit, color, 'smoke')
        return make_weapon(key, display, source, 'cannon', refire, damage, proj, energy, sound, model,
                           'Disc: muzzleVelocity %g accelerating to %g m/s, flown at the mean speed so the range '
                           'matches; radius damage.' % (V._f(p, 'muzzleVelocity'), V._f(p, 'terminalVelocity')))
    if pclass == 'GrenadeData':
        speed = math.sqrt(V._f(p, 'maxLevelFlightDist') * GRAVITY)
        proj = lobbed_projectile(speed, shape_id, inherit)
        w = make_weapon(key, display, source, 'grenade', refire, damage, proj, energy, sound, model,
                        'GrenadeData has no muzzle velocity: launch speed sqrt(maxLevelFlightDist %g x g). Bounces '
                        '(elasticity) and the fuse (liveTime) are not modelled: it bursts on impact.'
                        % V._f(p, 'maxLevelFlightDist'), range=V._f(p, 'maxLevelFlightDist'))
        return w
    if pclass == 'LaserData':
        full = V._f(p, 'damageConversion') * energy[1]
        return make_weapon(key, display, source, 'beam', refire, dict(damage, value=full, type=p.get('baseDamageType', '').strip('$')),
                           None, energy, sound, model,
                           'Damage = damageConversion %g x the energy spent (maxEnergy %d at most): a full shot does '
                           'the listed damage, less energy proportionally less. The original needs an Energy Pack '
                           '(LaserRifle::onUse); packs are not modelled. Range: T2 maxRifleRange.'
                           % (V._f(p, 'damageConversion'), energy[1]), range=LASER_RANGE, beam=beam(color))
    # LightningData (ELF): a sustained beam, one pulse per reloadTime
    pulse = V._f(img, 'reloadTime')
    return make_weapon(key, display, source, 'beam', pulse,
                       dict(damage, value=V._f(p, 'damagePerSec') * pulse), None,
                       (energy[0], int(round(V._f(img, 'maxEnergy') * pulse))), sound, model,
                       'Sustained: damagePerSec and the target drain energyDrainPerSec in pulses of reloadTime; the '
                       'shooter spends maxEnergy per second.', range=V._f(p, 'boltLength'),
                       effects={'elf_leech': r(V._f(p, 'energyDrainPerSec') * pulse, 1)}, beam=beam(color, 0.12))


def t1_armor(db, items, glob, block, key, display, size):
    item_max, max_weapons, scales, spawn = glob
    f = db[block]['fields']
    mass = V._f(f, 'mass')
    shape = V.Shape('tribes', f['shapeFile'].lower())
    eye, _ = node_position(shape, 'dummy eye')
    hand, hand_node = node_position(shape, 'dummy hand')
    limits = item_max.get(block, {})
    allowed = ['tribes:' + k for item, k, _ in T1_WEAPONS if limits.get(item.lower(), 0) > 0]
    ammo = {}
    for item, k, _ in T1_WEAPONS:
        img = db[items[item.lower()]['imageType'].lower()]['fields']
        if img.get('ammoType') and limits.get(item.lower(), 0) > 0:
            ammo['tribes:' + k] = limits.get(img['ammoType'].lower(), 0)
    spawn_items = [x.lower() for x in spawn]
    start = ['tribes:' + k for item, k, _ in T1_WEAPONS if item.lower() in spawn_items and 'tribes:' + k in allowed]
    return {
        'name': display, 'pack': 'tribes', 'datablock': block, 'size': size, 'shape': shape.id,
        'source': 'scripts/ArmorData.cs PlayerData %s, $ItemMax / $MaxWeapons / $DamageScale' % block,
        'mass': mass, 'height_m': shape.size[2], 'eye_height_m': r(eye[2], 2), 'capsule_radius': CAPSULE_RADIUS[size],
        'hand_node': hand_node,
        'max_forward_speed': V._f(f, 'maxForwardSpeed'), 'max_backward_speed': V._f(f, 'maxBackwardSpeed'),
        'max_side_speed': V._f(f, 'maxSideSpeed'), 'ground_accel': r(num(f, 'groundForce') / mass, 2),
        'jump_speed': r(V._f(f, 'jumpImpulse') / mass, 2), 'jet_accel': r(V._f(f, 'jetForce') / mass, 2),
        'jet_energy_per_s': r(V._f(f, 'jetEnergyDrain') * TICKS_PER_SECOND, 2), 'min_jet_energy': V._f(f, 'minJetEnergy'),
        'jet_side_factor': V._f(f, 'maxJetSideForceFactor'), 'max_jet_forward_speed': V._f(f, 'maxJetForwardVelocity'),
        'max_energy': V._f(f, 'maxEnergy'), 'energy_recharge_per_s': 8.0,
        'max_damage': V._f(f, 'maxDamage'), 'hp': r(V._f(f, 'maxDamage') * DAMAGE_SCALE, 1),
        'max_weapons': max_weapons.get(block, 3), 'weapons': allowed, 'ammo': ammo, 'default_loadout': start,
        'damage_scale': scales.get(block, {}), 'price': int(V._f(items[T1_ARMOR_ITEMS[key].lower()], 'price')),
        'can_pilot': size == 'light',
        'sounds': dict({'jet': t1_sound(db, f.get('jetSound', '')), 'footstep': t1_sound(db, 'SoundLFootRSoft'),
                        'mount': t1_sound(db, 'SoundFlyerMount'), 'dismount': t1_sound(db, 'SoundFlyerDismount')},
                       **t1_foot_sounds(db, block)),
    }


def export_tribes():
    db = V.t1_datablocks()
    items = t1_items(db)
    glob = t1_globals()
    weapons = [t1_weapon(db, items, item, key, disp) for item, key, disp in T1_WEAPONS]
    for (item, _, _), w in zip(T1_WEAPONS, weapons):
        w['model']['animation'] = t1_weapon_animation(db[items[item.lower()]['imageType'].lower()]['fields'])
    armors = {key: t1_armor(db, items, glob, block, key, disp, size) for block, key, disp, size in T1_ARMORS}
    by_block = {block: armors[key] for block, key, _, _ in T1_ARMORS}
    ammo_of = {'tribes:' + k: db[items[item.lower()]['imageType'].lower()]['fields'].get('ammoType', '').lower()
               for item, k, _ in T1_WEAPONS}
    gear = G.t1_gear(db, glob[0], by_block, {k: v for k, v in ammo_of.items() if v})
    write('tribes', armors, weapons, gear, G.t1_seats(G.load_vehicles('tribes')))


# ================================================================== Tribes 2

T2_ARMORS = (('LightMaleHumanArmor', 'LIGHT', 'Scout (light) armor', 'light', 'light_male'),
             ('MediumMaleHumanArmor', 'MEDIUM', 'Assault (medium) armor', 'medium', 'medium_male'),
             ('HeavyMaleHumanArmor', 'HEAVY', 'Juggernaut (heavy) armor', 'heavy', 'heavy_male'))
# max[] item -> catalog key, display, image, kind. TargetingLaser / RepairGun do no damage: not exported.
T2_WEAPONS = (('Blaster', 'BLASTER', 'Blaster', 'BlasterImage', 'cannon'),
              ('Chaingun', 'CHAINGUN', 'Chaingun', 'ChaingunImage', 'cannon'),
              ('Disc', 'SPINFUSOR', 'Spinfusor', 'DiscImage', 'cannon'),
              ('GrenadeLauncher', 'GRENADE_LAUNCHER', 'Grenade Launcher', 'GrenadeLauncherImage', 'grenade'),
              ('Mortar', 'MORTAR', 'Fusion Mortar', 'MortarImage', 'grenade'),
              ('Plasma', 'PLASMA_RIFLE', 'Plasma Rifle', 'PlasmaImage', 'plasma'),
              ('MissileLauncher', 'MISSILE_LAUNCHER', 'Missile Launcher', 'MissileLauncherImage', 'missile'),
              ('SniperRifle', 'LASER_RIFLE', 'Laser Rifle', 'SniperRifleImage', 'beam'),
              ('ShockLance', 'SHOCKLANCE', 'Shocklance', 'ShockLanceImage', 'beam'),
              ('ELFGun', 'ELF_PROJECTOR', 'ELF Projector', 'ELFGunImage', 'beam'))
# DefaultGame::equip (scripts/defaultGame.cs): Blaster, Disc, Chaingun.
T2_SPAWN = ('Blaster', 'Disc', 'Chaingun')
T2_AUDIO = V.T2_AUDIO


def t2_audio(resolve, profile):
    p = resolve(profile)
    path = os.path.join(T2_AUDIO, *str(p.get('filename', '')).split('/')) if p.get('filename') else ''
    return V.copy_sound('tribes2', path)


def t2_model(img):
    name = os.path.splitext(str(img.get('shapeFile', '')))[0].lower()
    return 'tribes2:' + name if V.Shape('tribes2', name).exists else ''


def t2_weapon(resolve, key, display, image, kind):
    img = resolve(image)
    p = resolve(str(img['projectile']))
    p['_name'] = img['projectile']
    source = 'scripts/weapons %s -> %s' % (image, img['projectile'])
    sound = V.t2_fire_sound(img, resolve)
    model = t2_model(img)
    energy = (int(float(img.get('minEnergy', 0.0))), int(round(float(img.get('fireEnergy', 0.0)))))
    radius = V.is_true(p.get('hasDamageRadius'))
    damage = {'value': float(p.get('indirectDamage', 0.0) if radius else p.get('directDamage', 0.0)),
              'radius': float(p.get('damageRadius', 0.0)) if radius else 0.0,
              'type': str(p.get('radiusDamageType' if radius else 'directDamageType', '') or p.get('radiusDamageType', ''))}
    refire = V.t2_fire_cycle(img)
    spread = math.degrees(float(img.get('projectileSpread', 0.0) or 0.0))
    if kind == 'beam':
        return t2_beam_weapon(key, display, source, img, p, damage, energy, sound, model, refire)
    proj = V.t2_projectile(p, kind, '')
    shape = os.path.splitext(str(p.get('projectileShapeName', '')))[0].lower()
    proj['shape'] = 'tribes2:' + shape if shape and V.Shape('tribes2', shape).exists else None
    if kind == 'missile':
        proj.update({'speed': float(p['maxVelocity']), 'guidance': 'heat', 'turn_rate_deg': 140.0,
                     'proximity': float(p.get('proximityRadius', 0.0))})
    rng = V.t2_range(p, kind, proj)
    notes = 'Refire = the image state machine from Fire back to Ready.'
    if kind == 'grenade':
        notes += ' No lifetimeMS: the shell is removed after its 45-degree flight time x %g.' % V.GRENADE_FLIGHT_MARGIN
    if kind == 'missile':
        notes += ' SeekerProjectile homes on the target (seekRadius %s m); flown at maxVelocity.' % img.get('seekRadius')
    return make_weapon(key, display, source, kind, refire, damage, proj, energy, sound, model, notes, range=rng,
                       spread_deg=spread)


def t2_beam_weapon(key, display, source, img, p, damage, energy, sound, model, refire):
    if key == 'LASER_RIFLE':
        return make_weapon(key, display, source, 'beam', refire, damage, None, (energy[0], 60), sound, model,
                           'Damage scales with the energy spent (a full 60 = the listed directDamage). The original '
                           'needs an Energy Pack; packs are not modelled.', range=float(p['maxRifleRange']),
                           beam=beam([1.0, 0.2, 0.2]))
    if key == 'SHOCKLANCE':
        return make_weapon(key, display, source, 'beam', refire, damage, None, (energy[0], energy[0]), sound, model,
                           'Contact weapon; its reach is engine-side, %g m is a remake guess.' % SHOCKLANCE_RANGE,
                           range=SHOCKLANCE_RANGE, beam=beam([0.5, 0.7, 1.0], 0.15))
    drain = float(img.get('stateEnergyDrain[3]', 0.0))
    pulse = 0.2
    return make_weapon(key, display, source, 'beam', pulse, damage, None,
                       (energy[0], int(round(drain * pulse))), sound, model,
                       'Sustained beam in %g s pulses: the shooter spends stateEnergyDrain %g per second, the target '
                       'loses drainEnergy %g per 32 ms tick.' % (pulse, drain, float(p.get('drainEnergy', 0.0))),
                       range=float(p['beamRange']), beam=beam([0.4, 0.6, 1.0], 0.12),
                       effects={'elf_leech': r(float(p.get('drainEnergy', 0.0)) * TICKS_PER_SECOND * pulse, 1)})


def t2_armor(resolve, key, display, size, shape_name, block):
    b = resolve(block)
    mass = float(b['mass'])
    shape = V.Shape('tribes2', shape_name)
    eye, _ = node_position(shape, 'eye')
    _, hand_node = node_position(shape, 'mount0')
    allowed = ['tribes2:' + k for item, k, _, _, _ in T2_WEAPONS if int(float(b.get('max[%s]' % item, 0))) > 0]
    ammo = {}
    for item, k, _, image, _ in T2_WEAPONS:
        ammo_item = resolve(image).get('ammo')
        if ammo_item and 'tribes2:' + k in allowed:
            ammo['tribes2:' + k] = int(float(b.get('max[%s]' % ammo_item, 0)))
    scales = {k[len('damageScale['):-1].replace('$DamageType::', '').lower(): float(v)
              for k, v in b.items() if k.startswith('damageScale[') and isinstance(v, (int, float))}
    return {
        'name': display, 'pack': 'tribes2', 'datablock': block, 'size': size, 'shape': shape.id,
        'source': 'scripts/player.cs PlayerData %s (max[] item limits, maxWeapons)' % block,
        'mass': mass, 'height_m': shape.size[2], 'eye_height_m': r(eye[2], 2), 'capsule_radius': CAPSULE_RADIUS[size],
        'hand_node': hand_node,
        'max_forward_speed': float(b['maxForwardSpeed']), 'max_backward_speed': float(b['maxBackwardSpeed']),
        'max_side_speed': float(b['maxSideSpeed']), 'ground_accel': r(float(b['runForce']) / mass, 2),
        'jump_speed': r(float(b['jumpForce']) / mass, 2), 'jet_accel': r(float(b['jetForce']) / mass, 2),
        'jet_energy_per_s': r(float(b['jetEnergyDrain']) * TICKS_PER_SECOND, 2),
        'min_jet_energy': float(b.get('minJetEnergy', 1)), 'jet_side_factor': float(b.get('maxJetHorizontalPercentage', 0.8)),
        'max_jet_forward_speed': float(b.get('maxJetForwardSpeed', 30)), 'max_energy': float(b['maxEnergy']),
        'energy_recharge_per_s': r(float(b['rechargeRate']) * TICKS_PER_SECOND, 2),
        'max_damage': float(b['maxDamage']), 'hp': r(float(b['maxDamage']) * DAMAGE_SCALE, 1),
        'max_weapons': int(b.get('maxWeapons', 3)), 'weapons': allowed, 'ammo': ammo,
        'default_loadout': ['tribes2:' + k for item, k, _, _, _ in T2_WEAPONS if item in T2_SPAWN and 'tribes2:' + k in allowed],
        'damage_scale': scales, 'price': 0,
        'can_pilot': size != 'heavy',
        'sounds': {'jet': t2_audio(resolve, str(b.get('jetSound', ''))),
                   'footstep': t2_audio(resolve, str(b.get('RFootSoftSound', ''))),
                   'footstep_left': t2_audio(resolve, str(b.get('LFootSoftSound', ''))),
                   'footstep_right': t2_audio(resolve, str(b.get('RFootSoftSound', ''))),
                   'footstep_hard_left': t2_audio(resolve, str(b.get('LFootHardSound', ''))),
                   'footstep_hard_right': t2_audio(resolve, str(b.get('RFootHardSound', ''))),
                   'footstep_range': T2_FOOTSTEP_RANGE, 'footstep_hard_range': T2_FOOTSTEP_HARD_RANGE,
                   'mount': t2_audio(resolve, 'MountVehicleSound'), 'dismount': t2_audio(resolve, 'UnmountVehicleSound')},
    }


def export_tribes2():
    db, base_resolve = V.t2_db()

    def resolve(name):
        return dict(base_resolve(name))

    weapons = [t2_weapon(resolve, key, disp, image, kind) for _, key, disp, image, kind in T2_WEAPONS]
    for (_, _, _, image, _), w in zip(T2_WEAPONS, weapons):
        w['model']['animation'] = t2_weapon_animation(resolve(image))
    armors = {key: t2_armor(resolve, key, disp, size, shape, block) for block, key, disp, size, shape in T2_ARMORS}
    by_block = {block: armors[key] for block, key, _, _, _ in T2_ARMORS}
    ammo_of = {'tribes2:' + key: str(resolve(image).get('ammo', '')) for _, key, _, image, _ in T2_WEAPONS}
    gear = G.t2_gear(resolve, by_block, {k: v for k, v in ammo_of.items() if v})
    write('tribes2', armors, weapons, gear, G.t2_seats(G.load_vehicles('tribes2'), resolve))


def main():
    for pack in sys.argv[1:] or ['tribes', 'tribes2']:
        {'tribes': export_tribes, 'tribes2': export_tribes2}[pack]()


if __name__ == '__main__':
    main()
