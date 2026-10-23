"""Tribes: Vengeance hand weapons -> gamedata/tribes_v/gameplay/weapons_infantry.json + infantry_rules.json
(docs/formats/tribes_vengeance.md section "Infantry weapons").

The weapons are UnrealScript classes (Content/Classes/EquipmentClasses.pkg subclassing the script package Gameplay.u);
their `defaultproperties` hold the numbers (tools/ue2_classes.py merges a class with its supers):
  * WeaponX: roundsPerSecond, projectileClass, projectileVelocity (uu/s), ammoCount, energyUsage, numberOfBullets, spread,
    thirdPersonStaticMesh (the held model, Content/Art/Weapons.pkg);
  * ProjectileX: damageAmt (direct hit), radiusDamageAmt / radiusDamageSize (explosion, uu), LifeSpan, MaxVelocity and
    AccelerationMagtitude, GravityScale, FuseTimer;
  * ArmorLight / ArmorMedium / ArmorHeavy: Health, energy, maxCarriedWeapons and AllowedWeapons, a struct array of
    {typeClass, quantity} (the rounds each armour carries);
  * LevelInfo DefaultGravity.
Units: 1/70 m per unreal unit (tools/tv_import.py METRES_PER_UU). Damage: the light armour's Health 75 is 1980 hp (the Tribes
light armour), so one Vengeance health point is 26.4 Earthsiege points for every weapon. Energy: the armours' energy pools are
100 / 105 / 125; the remake's pool is 60 for its light armour, so energy figures are scaled by 0.6.

    python tools/tv_weapons.py <extracted game folder holding Content/ and Program/> [pack folder]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import infantry_weapon_json as W  # noqa: E402
import siege_paths as P  # noqa: E402
import ue2_classes as UC  # noqa: E402

PACK = 'tribes_v'
METRES_PER_UU = 1.0 / 70.0
LIGHT_HEALTH = 75.0                  # ArmorLight Health: 1980 hp in the remake
ENERGY_POOL_LIGHT = 100.0            # ArmorLight energy
REMAKE_ENERGY_POOL = 60.0
WEAPONS_PACKAGE = 'Weapons'
ARMOR_CLASSES = {'LIGHT': 'ArmorLight', 'MEDIUM': 'ArmorMedium', 'HEAVY': 'ArmorHeavy'}
LEVEL_INFO = 'LevelInfo'
HEAT_NOTE = 'Overheats after heatPeriod seconds of fire (not modelled).'

# name -> (weapon class, display, kind, damage type, colour, notes)
WEAPONS = [
    ('SPINFUSOR', 'WeaponSpinfusor', 'Spinfusor', 'cannon', 'disc', (0.35, 0.55, 1.0),
     'Flown at the mean of the launch and top speed (the projectile accelerates: AccelerationMagtitude).'),
    ('CHAINGUN', 'WeaponChaingun', 'Chaingun', 'cannon', 'bullet', (1.0, 0.95, 0.6), HEAT_NOTE),
    ('BLASTER', 'WeaponBlaster', 'Blaster', 'cannon', 'blaster', (0.5, 1.0, 0.6),
     'Fires numberOfBullets pellets per pull (a burst); the pellets bounce off surfaces for bounceTime seconds (not modelled).'),
    ('GRENADE_LAUNCHER', 'WeaponGrenadeLauncher', 'Grenade Launcher', 'grenade', 'grenade', (0.9, 0.9, 0.5),
     'A bouncing arc projectile with a fuse (FuseTimer) and GravityScale 1.2 of the level gravity.'),
    ('MORTAR', 'WeaponMortar', 'Mortar', 'grenade', 'mortar', (1.0, 0.7, 0.3), 'Heavy armour only. Arc projectile like the grenade.'),
    ('SNIPER_RIFLE', 'WeaponSniperRifle', 'Sniper Rifle', 'beam', 'laser', (1.0, 0.3, 0.3),
     'Light armour only. The original does more damage when more energy is used (not modelled); the bullet is a 400000 uu/s projectile.'),
    ('ROCKET_POD', 'WeaponRocketPod', 'Rocket Pod', 'missile', 'missile', (1.0, 0.55, 0.2),
     'Six rockets per pull (launchDelay apart); the original rockets can be steered once fired (not modelled).'),
    ('BURNER', 'WeaponBurner', 'Burner', 'plasma', 'plasma', (1.0, 0.45, 0.15),
     'A plasma ball that ignites a burning area on impact (burning damage over time not modelled).'),
]
NOT_EXPORTED = {'WeaponEnergyBlade': 'melee', 'WeaponGrappler': 'no damage (a grappling hook)', 'WeaponBuckler': 'a shield disc'}
SOUND_ROLE = {'SPINFUSOR': 'Spinfusor', 'CHAINGUN': 'ChainGun', 'BLASTER': 'Blaster', 'GRENADE_LAUNCHER': 'GrenLauncher',
              'MORTAR': 'Mortar', 'SNIPER_RIFLE': 'SniperRifle', 'ROCKET_POD': 'RocketPod', 'BURNER': 'Burner'}
PROJECTILE_MESHES = {'SPINFUSOR': 'Disc', 'GRENADE_LAUNCHER': 'Grenade', 'MORTAR': 'Grenade', 'ROCKET_POD': 'Rocket'}
LEVEL_GRAVITY_DEFAULT = -1160.0
# The multiplayer loadout classes are not decoded: a soldier spawns with the Tribes standard kit where his armour allows it.
DEFAULT_KIT = ('BLASTER', 'CHAINGUN', 'SPINFUSOR')


class Source:
    """The game folder's class defaults and packages."""

    def __init__(self, game_root):
        import tv_assets
        self.classes = UC.ClassIndex(game_root)
        self.packages = tv_assets.PackageIndex(game_root)
        self.shapes = {}                   # (mesh name) -> shape id or None

    def gravity(self):
        """Level gravity in m/s^2 (positive)."""
        return abs(float(self.classes.defaults(LEVEL_INFO).get('DefaultGravity', LEVEL_GRAVITY_DEFAULT))) * METRES_PER_UU

    def mesh_shape(self, mesh_name, pack_dir):
        """Exports the static mesh `mesh_name` of Weapons.pkg as a pack shape; returns 'tribes_v:<id>' or ''."""
        import tv_statics
        if mesh_name in self.shapes:
            return self.shapes[mesh_name]
        pkg = self.packages.load(WEAPONS_PACKAGE)
        found = [e for e in pkg.find('StaticMesh') if e['name'].lower() == mesh_name.lower()] if pkg else []
        sid = tv_statics._write_shape(self.packages, pkg, found[0], pack_dir, METRES_PER_UU, {}) if found else None
        self.shapes[mesh_name] = ('%s:%s' % (PACK, sid)) if sid else ''
        return self.shapes[mesh_name]


def uu(v):
    return float(v) * METRES_PER_UU


def hp(health_units):
    return float(health_units) * W.LIGHT_ARMOR_HP / LIGHT_HEALTH


def energy(units):
    return float(units) * REMAKE_ENERGY_POOL / ENERGY_POOL_LIGHT


def fire_sound(sounds, role):
    """'tribes_v:tv_weapons/<Role>_Fired1' from the audio index (tv_audio.export_sounds), '' when missing."""
    keys = (sounds.get('weapons', {}).get(role, {}) or {}).get('Fired', [])
    return '%s:%s' % (PACK, keys[0]) if keys else ''


def impact_sound(sounds, role):
    group = sounds.get('weapons', {}).get(role + 'Proj', {}) or {}
    for kind in ('Exp', 'Hit'):
        if group.get(kind):
            return '%s:%s' % (PACK, group[kind][0])
    return None


def make_projectile_block(name, wd, pd, gravity, mesh_shape, color):
    """(projectile dict, lifetime s) of the weapon's projectile class defaults."""
    life = float(pd.get('LifeSpan', 3.0))
    speed = uu(wd.get('projectileVelocity', 2500.0))
    top = float(pd.get('MaxVelocity', 0.0))
    accel = float(pd.get('AccelerationMagtitude', 0.0))
    if top > 0.0 and accel > 0.0:
        launch = float(wd.get('projectileVelocity', 2500.0))
        reached = min(top, launch + accel * life)
        speed = uu((launch + reached) / 2.0)
    if 'postSpreadVelocity' in pd:      # a pod rocket coasts through its arming and spread time, then flies at the post-spread speed
        slow = min(life, float(pd.get('armingPeriod', 0.0)) + float(pd.get('spreadPeriod', 0.0)))
        speed = uu((float(wd.get('projectileVelocity', 2500.0)) * slow + float(pd['postSpreadVelocity']) * (life - slow)) / life)
    grav = gravity * float(pd.get('GravityScale', 0.0)) if name in ('GRENADE_LAUNCHER', 'MORTAR') else 0.0
    proj = W.make_projectile(speed, life, grav, mesh_shape or None, color,
                             inherit=float(wd.get('projectileInheritedVelFactor', 0.5)),
                             trail='smoke' if name in ('GRENADE_LAUNCHER', 'MORTAR', 'ROCKET_POD') else 'glow',
                             arm_delay=float(pd.get('armingPeriod', 0.0)))
    return proj


def make_weapon_record(spec, src, sounds, pack_dir, gravity):
    name, cls, display, kind, dtype, color, notes = spec
    wd = src.classes.defaults(cls)
    pd = src.classes.defaults(str(wd.get('projectileClass', 'Projectile')))
    rps = float(wd.get('roundsPerSecond', 1.0))
    direct = float(pd.get('damageAmt', 0.0))
    blast = float(pd.get('radiusDamageAmt', 0.0))
    radius = uu(pd.get('radiusDamageSize', pd.get('postIgnitionColRadius', 0.0)))
    mesh = PROJECTILE_MESHES.get(name)
    proj_shape = src.mesh_shape(mesh, pack_dir) if mesh else ''
    f = {'refire': 1.0 / rps, 'damage_type': dtype, 'model_shape': src.mesh_shape(str(wd.get('thirdPersonStaticMesh', '')), pack_dir),
         'fire_sound': fire_sound(sounds, SOUND_ROLE[name]), 'damage': hp(max(direct, blast)),
         'tribes': round(max(direct, blast), 2), 'splash': 1.0 if blast > 0 and radius > 0 else 0.0, 'splash_radius': radius}
    f['notes'] = notes
    energy_use = float(wd.get('energyUsage', 0.0)) * float(wd.get('numberOfBullets', 1)) if wd.get('ammoUsage', 1) == 0 else 0.0
    if energy_use > 0:
        f['energy'] = (energy(energy_use), energy(energy_use))
    life = float(pd.get('LifeSpan', 1.0))
    if name == 'SNIPER_RIFLE':
        speed = uu(wd.get('projectileVelocity', 400000.0))
        f.update(beam=W.make_beam(color, 0.08, 0.12), range=speed * life)
    else:
        proj = make_projectile_block(name, wd, pd, gravity, proj_shape, color)
        f['projectile'] = proj
        f['range'] = _range(name, proj)
    if name == 'CHAINGUN':
        f.update(spread_deg=(float(wd.get('minSpread', 0.4)) + float(wd.get('maxSpread', 2.0))) / 2.0)
    elif name == 'BLASTER':
        f.update(burst=int(wd.get('numberOfBullets', 1)), spread_deg=float(wd.get('Spread', 0.0)))
    elif name == 'ROCKET_POD':
        f.update(burst=int(wd.get('numProjectiles', 1)), burst_interval=float(wd.get('launchDelay', 0.0)))
    f['notes'] += ' Vengeance units: %s.' % ', '.join('%s %g' % (k, v) for k, v in (
        ('roundsPerSecond', rps), ('projectileVelocity uu/s', float(wd.get('projectileVelocity', 0))), ('damageAmt', direct),
        ('radiusDamageAmt', blast), ('radiusDamageSize uu', float(pd.get('radiusDamageSize', 0.0))), ('LifeSpan', life)))
    source = 'UE2 class defaults %s / %s (EquipmentClasses.pkg, Gameplay.u)' % (cls, wd.get('projectileClass', ''))
    return W.make_weapon(name, display, source, kind, **f), color, max(radius, 1.0), source


def _range(name, proj):
    if proj['gravity'] > 0:
        import math
        return proj['speed'] ** 2 / proj['gravity'] * math.sin(math.radians(2 * 45.0))
    return proj['speed'] * proj['lifetime']


def make_rules(src):
    """infantry_rules.json sizes from the three armour classes."""
    by_class = {spec[1]: spec[0] for spec in WEAPONS}
    sizes = {}
    for size, cls in ARMOR_CLASSES.items():
        d = src.classes.defaults(cls)
        allowed = UC.struct_array(src.classes.package_of(cls), d['AllowedWeapons'])
        weapons, ammo = [], {}
        for entry in allowed:
            name = by_class.get(str(entry.get('typeClass')))
            if name:
                wid = '%s:%s' % (PACK, name)
                weapons.append(wid)
                if int(entry.get('quantity', 0)) > 0:
                    ammo[wid] = int(entry['quantity'])
        slots = int(d.get('maxCarriedWeapons', 3))
        kit = ['%s:%s' % (PACK, n) for n in DEFAULT_KIT if '%s:%s' % (PACK, n) in weapons]
        sizes[size] = {'max_weapons': slots, 'weapons': weapons, 'ammo': ammo, 'default_loadout': kit[:slots],
                       'hp': W.r(hp(d.get('Health', 75.0)), 1), 'max_energy': W.r(energy(d.get('energy', 100.0)), 1)}
    return sizes


def export(game_root, pack_dir=None, sounds=None):
    """Writes the weapon files into the pack; returns the weapon count. `sounds`: the audio index (audio/sounds.json)."""
    pack_dir = pack_dir or P.pack(PACK)
    if sounds is None:
        sounds = W.read_json(os.path.join(pack_dir, 'audio', 'sounds.json')) or {}
    src = Source(game_root)
    gravity = src.gravity()
    weapons, effects = [], {}
    for spec in WEAPONS:
        rec, color, radius, source = make_weapon_record(spec, src, sounds, pack_dir, gravity)
        name = spec[0]
        fx, fx_effects = W.make_fx(rec, 'tv_' + name.lower(), color, radius, source,
                                   rec['projectile']['shape'] if rec.get('projectile') else None,
                                   projectile_size=1.0, impact_sound=impact_sound(sounds, SOUND_ROLE[name]))
        rec['fx'] = fx
        weapons.append(rec)
        effects.update(fx_effects)
    note = ('Vengeance damage: the class default damage (health points) x 26.4 (the light armour Health 75 = 1980 hp as in the '
            'Tribes games). Energy x 0.6 (energy pool 100 -> 60).')
    W.write_weapons(pack_dir, PACK, weapons, note)
    W.write_effects(pack_dir, PACK, effects, 'engine default (no explosion data in the pack)')
    rules = make_rules(src)
    rules['default_loadout_note'] = 'the armour\'s AllowedWeapons order (the MP loadout classes are not decoded)'
    W.write_rules(pack_dir, PACK, {k: v for k, v in rules.items() if isinstance(v, dict)})
    return len(weapons)



def main(argv):
    if not argv:
        print(__doc__)
        return 1
    n = export(argv[0], argv[1] if len(argv) > 1 else None)
    print('%s: %d weapons' % (PACK, n))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
