"""Aerial Assault hand weapons -> gamedata/tribes_aa/gameplay/weapons_infantry.json + infantry_rules.json
(docs/formats/aerial_assault.md section "Infantry weapons").

The disc has no weapon script. The numbers live in the PS2 executable (SLUS_201.49) and in the character define files:
  * `player_object::s_WeaponInfo` (13 records of 7 words, indexed by invent_type 0..12): ammo type, ammo (energy) needed
    to fire, amount spent, refire seconds, -, projectile speed (m/s), projectile lifetime (s). Read by
    Weapon_Setup_FIRE (0x241c80: +0 ammo type, +4 minimum, +8 cost, +0xc refire) and by disk/plasma/bullet Setup /
    Initialize (+0x14 speed, +0x18 lifetime). Types: 1 disk launcher, 2 plasma gun, 3 sniper (laser) rifle, 4 mortar,
    5 grenade launcher, 6 chain gun, 7 blaster, 8 ELF gun, 9 missile launcher, 10 repair gun, 11 shocklance,
    12 targeting laser; ammo types 13 disk, 14 bullet, 15 grenade, 16 plasma, 17 mortar, 18 missile.
  * `GetWeaponPainType` (0x197740, a jump table at 0x39f4e0) names each weapon's pain (damage) type; `g_PainBase`
    (68 records of 7 words: id, flag, inner and outer damage radius twice, impulse) and `g_MetalDamageTable`
    (68 rows of 24 floats: damage per victim object type, columns 21 / 22 / 23 = light / medium / heavy armour;
    InflictPain 0x156ce8 multiplies the row by the explosion's scale and the falloff between the radii).
  * `DEFAULT{LIGHT,MEDIUM,HEAVY}DEFINES.TXT`: MAX_DAMAGE, MAX_ENERGY, MAX_WEAPONS and INVENT_MAX per weapon and ammo.
  * `LoadoutList` (0x38cac8): the default loadouts (armour, weapon count, weapon types).
Damage units: InflictPain clamps a hit's table value at 1.0, so the value is a fraction of the victim's whole health (the
table gives a smaller fraction to heavier armours: disc 0.35 / 0.18 / 0.11). The file keeps the light-armour fraction
x 1980 (the light armour, as the Tribes games) as the weapon's damage and the three fractions in `notes`.

    python tools/aa_weapons.py <TribesAerialAssault.iso> [pack folder]
"""
import os
import re
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import infantry_weapon_json as W  # noqa: E402
import siege_paths as P  # noqa: E402

PACK = 'tribes_aa'
WEAPON_INFO = '_13player_object$s_WeaponInfo'
WEAPON_INFO_STRIDE = 28
PAIN_BASE = 'g_PainBase'
PAIN_STRIDE = 28
METAL_TABLE = 'g_MetalDamageTable'
METAL_ROW_BYTES = 96
ARMOR_COLUMNS = {'LIGHT': 21, 'MEDIUM': 22, 'HEAVY': 23}   # ObjectTypes (0x34a630): armour type + 0x15
LOADOUT_LIST = 'LoadoutList'
LOADOUT_STRIDE = 56
ARMOR_ORDER = ('LIGHT', 'MEDIUM', 'HEAVY')
DEFINES_FILE = 'DATA\\CHARACTERS\\DEFAULT%sDEFINES.TXT'
COMMON_DEFINES = 'DATA\\CHARACTERS\\COMMONDEFINES.TXT'
MAX_HIT_FRACTION = 1.0           # InflictPain 0x157354..0x157368 clamps a hit's table value at 1.0: it is a fraction of the victim's health
ENERGY_PC_UNITS = 60.0           # MAX_ENERGY 1 "from pc = 60" (DEFAULTLIGHTDEFINES.TXT): one energy unit = 60 of the soldier's pool
CHAINGUN_PERIOD_S = 0.125        # ChainGun_Advance_FIRE 0x29b024: lui 0x3e00 (the accumulator compared with 0.125)
CHAINGUN_SPREAD_RAD = 0.03       # 0x29b068 lui 0x3cf5 / ori 0xc28f: x_frand(-0.03, 0.03) on yaw and pitch
CHAINGUN_SPINUP_S = 1.0          # CHAINGUN_RAMP_SPEED_UP_TIME (0x384f74)
LASER_REFIRE_S = 1.1             # the table says 0: the shot spends all the energy (cost 5 > the pool), so the recharge sets the pace:
                                 # 0.15 minimum / RECHARGE_RATE 0.1365 per s (DEFAULTLIGHTDEFINES.TXT)
LASER_RANGE_M = 800.0            # laser::Initialize 0x1de7b8 lui 0x4448 (the ray length)
MISSILE_START_SPEED = 30.0       # missile::OnAdd 0x1a3d84 lui 0x41f0 (speed and acceleration, m/s and m/s^2)
MISSILE_ACCELERATION = 30.0
MISSILE_MAX_SPEED = 200.0        # missile::AdvanceLogic 0x1a2820 lui 0x4348 (the clamp)
MISSILE_LIFETIME_S = 10.0        # estimate: the code has no timer; 10 s covers the climb to top speed and a long chase
ELF_RANGE_M = 40.0               # estimate (the lock-on cone is 45 degrees, Elf_Advance_FIRE; the reach is a Select radius not decoded)
ELF_DRAIN_PER_TICK = 0.05        # Elf_Advance_FIRE 0x29c150: AddEnergy(-0.05) of the shooter per update
ELF_LEECH = 12.0                 # estimate: the original drains the target's energy every tick (pain type 7); strength not decoded
ARC_ANGLE_DEG = 45.0             # the mortar and grenade launcher lob; the range figure uses the 45 degree flight
CODE_WORDS = {0x29b024: 0x3c013e00, 0x29b068: 0x3c013cf5, 0x1de7b8: 0x3c014448, 0x1a3d84: 0x3c0141f0, 0x1a2820: 0x3c014348}

# name -> (invent type, display, shape, pain type, kind, damage type, fire sound id (EFFECTS bank), colour, notes)
WEAPONS = [
    ('DISC_LAUNCHER', 1, 'Disc Launcher', 'weapon_disc', 0, 'cannon', 'disc', 9, (0.4, 0.55, 1.0),
     'Fire sound = the disc projectile\'s flight loop (disk::Setup 0x174e20 stores sound 9); no separate launch sound is set.'),
    ('PLASMA_GUN', 2, 'Plasma Gun', 'weapon_plasma', 3, 'plasma', 'plasma', 0x1b, (1.0, 0.7, 0.25), ''),
    ('LASER_RIFLE', 3, 'Laser Rifle', 'weapon_laser_rifle', 8, 'beam', 'laser', 0x71, (1.0, 0.25, 0.25),
     'A hitscan ray of 800 m; the original scales the damage with the charge spent, here the whole energy is spent per shot.'),
    ('MORTAR', 4, 'Mortar', 'weapon_mortar', 5, 'grenade', 'mortar', 0x13, (1.0, 0.8, 0.4),
     'Heavy armour only. Lobbed (arcing class, gravity -20); the original aims with an auto-aim point, the remake fires along the aim.'),
    ('GRENADE_LAUNCHER', 5, 'Grenade Launcher', 'weapon_grenade_launcher', 4, 'grenade', 'grenade', 0x5f, (0.9, 0.9, 0.5),
     'Lobbed (arcing class, gravity -20); the grenade arms 1 s after launch (GrenadeArmTime).'),
    ('CHAINGUN', 6, 'Chaingun', 'weapon_chaingun', 1, 'cannon', 'bullet', 0x27, (1.0, 1.0, 0.7), ''),
    ('BLASTER', 7, 'Blaster', 'weapon_blaster01', 2, 'cannon', 'blaster', 0x77, (1.0, 0.35, 0.2),
     'The original bolt ricochets (blaster::AddLeg); the remake bolt does not.'),
    ('ELF_GUN', 8, 'ELF Gun', 'weapon_elf', 7, 'beam', 'elf', 0x96, (0.3, 0.4, 1.0),
     'Locks a target within 45 degrees and drains its energy (pain type 7, flag 1, no health damage); range and drain rate are estimates.'),
    ('MISSILE_LAUNCHER', 9, 'Missile Launcher', 'weapon_missile01', 6, 'missile', 'missile', 0x86, (1.0, 0.5, 0.2),
     'Heavy armour only. Speed starts at 30 m/s, +30 m/s^2, clamped at 200 m/s; lifetime is an estimate.'),
]
UNUSED = {'REPAIR_GUN': 10, 'SHOCKLANCE': 11, 'TARGETING_LASER': 12}   # no health damage / no model: not exported
INVENT_WEAPON = {'WEAPON_DISK_LAUNCHER': 'DISC_LAUNCHER', 'WEAPON_PLASMA_GUN': 'PLASMA_GUN', 'WEAPON_SNIPER_RIFLE': 'LASER_RIFLE',
                 'WEAPON_MORTAR_GUN': 'MORTAR', 'WEAPON_GRENADE_LAUNCHER': 'GRENADE_LAUNCHER', 'WEAPON_CHAIN_GUN': 'CHAINGUN',
                 'WEAPON_BLASTER': 'BLASTER', 'WEAPON_ELF_GUN': 'ELF_GUN', 'WEAPON_MISSILE_LAUNCHER': 'MISSILE_LAUNCHER'}
INVENT_AMMO = {'WEAPON_AMMO_DISK': 'DISC_LAUNCHER', 'WEAPON_AMMO_BULLET': 'CHAINGUN', 'WEAPON_AMMO_GRENADE': 'GRENADE_LAUNCHER',
               'WEAPON_AMMO_PLASMA': 'PLASMA_GUN', 'WEAPON_AMMO_MORTAR': 'MORTAR', 'WEAPON_AMMO_MISSILE': 'MISSILE_LAUNCHER'}
TYPE_NAME = {1: 'DISC_LAUNCHER', 2: 'PLASMA_GUN', 3: 'LASER_RIFLE', 4: 'MORTAR', 5: 'GRENADE_LAUNCHER', 6: 'CHAINGUN', 7: 'BLASTER',
             8: 'ELF_GUN', 9: 'MISSILE_LAUNCHER'}
PROJECTILE_SHAPES = {'DISC_LAUNCHER': 'tribes_aa:projectile_disc_core', 'MORTAR': 'tribes_aa:projectile_mortar',
                     'GRENADE_LAUNCHER': 'tribes_aa:grenade', 'MISSILE_LAUNCHER': 'tribes_aa:projectile_missile'}


class Tables:
    """The decoded tables of the executable."""

    def __init__(self, elf):
        self.elf = elf
        self._check_code()
        self.info = self._records(WEAPON_INFO, WEAPON_INFO_STRIDE, '7f')
        self.info_ints = self._records(WEAPON_INFO, WEAPON_INFO_STRIDE, '7I')
        self.pain = self._records(PAIN_BASE, PAIN_STRIDE, '2I5f')
        addr, size = elf.symbols[METAL_TABLE]
        data = elf.read(addr, size)
        self.metal = [struct.unpack_from('<24f', data, i * METAL_ROW_BYTES) for i in range(size // METAL_ROW_BYTES)]
        self.pain_of_weapon = self._weapon_pain_types()

    def _check_code(self):
        for addr, word in CODE_WORDS.items():
            if self.elf.u32(addr) != word:
                raise ValueError('executable differs from the one decoded: %#x holds %#x, expected %#x' % (addr, self.elf.u32(addr), word))

    def _records(self, symbol, stride, fmt):
        addr, size = self.elf.symbols[symbol]
        data = self.elf.read(addr, size)
        return [struct.unpack_from('<' + fmt, data, i * stride) for i in range(size // stride)]

    def _weapon_pain_types(self):
        """invent type -> pain type: the jump table of GetWeaponPainType (0x197740): each case is `addiu $v0, $zero, n`."""
        import aa_elf
        table = struct.unpack('<21I', self.elf.read(0x39f4e0, 84))
        out = {}
        for index, target in enumerate(table):
            ins = aa_elf.disasm(self.elf, target, 8)
            out[index + 1] = int(ins[1].op_str.split(',')[-1], 0) if len(ins) > 1 and ins[1].mnemonic == 'addiu' else 0
        return out

    def weapon(self, invent_type):
        """(ammo type, minimum, cost, refire, speed, lifetime) of a weapon."""
        w = self.info[invent_type]
        i = self.info_ints[invent_type]
        return {'ammo_type': i[0], 'minimum': w[1], 'cost': w[2], 'refire': w[3], 'speed': w[5], 'lifetime': w[6]}

    def blast(self, pain_type):
        """Radii and impulse of a pain type: (inner, outer, impulse)."""
        rec = self.pain[pain_type]
        return rec[2], rec[3], rec[6]

    def damage(self, pain_type):
        """{'LIGHT': x, 'MEDIUM': y, 'HEAVY': z} of the metal damage table."""
        row = self.metal[pain_type]
        return {size: row[col] for size, col in ARMOR_COLUMNS.items()}

    def default_loadouts(self):
        """{'LIGHT': [weapon names] ...}: the first light / medium / heavy entries of LoadoutList."""
        addr, _size = self.elf.symbols[LOADOUT_LIST]
        out = {}
        for i in range(29):
            entry = struct.unpack('<14i', self.elf.read(struct.unpack('<I', self.elf.read(addr + 4 * i, 4))[0], LOADOUT_STRIDE))
            size = ARMOR_ORDER[entry[0]]
            if size not in out:
                out[size] = [TYPE_NAME[t] for t in entry[3:3 + entry[2]] if t in TYPE_NAME]
        return out


def read_defines(files):
    """{size: {'max_damage', 'max_energy', 'max_weapons', 'invent': {name: n}}} of the three DEFAULT*DEFINES.TXT files."""
    out = {}
    for size in ARMOR_ORDER:
        text = files.read(DEFINES_FILE % size).decode('latin-1')
        rec = {'invent': {}}
        for key, field in (('MAX_DAMAGE', 'max_damage'), ('MAX_ENERGY', 'max_energy'), ('MAX_WEAPONS', 'max_weapons')):
            m = re.search(r'DEFINE_ATTRIBUTE_\w+\s*\(\s*%s,\s*([0-9.]+)' % key, text)
            rec[field] = float(m.group(1)) if m else 0.0
        for name, n in re.findall(r'INVENT_MAX\[INVENT_TYPE_(\w+)\],\s*(\d+)', text):
            rec['invent'][name] = int(n)
        out[size] = rec
    return out


def read_gravity(files):
    text = files.read(COMMON_DEFINES).decode('latin-1')
    m = re.search(r'DEFINE_ATTRIBUTE_F32\s*\(\s*GRAVITY,\s*(-?[0-9.]+)', text)
    return -float(m.group(1)) if m else 20.0


def arc_flight(speed, gravity):
    """(range m, flight seconds) of a lob at 45 degrees over level ground."""
    import math
    angle = math.radians(ARC_ANGLE_DEG)
    return speed * speed * math.sin(2 * angle) / gravity, 2 * speed * math.sin(angle) / gravity


def make_weapon_record(spec, tables, defines, gravity):
    name, itype, display, shape, pain, kind, dtype, sound_id, color, notes = spec
    info = tables.weapon(itype)
    inner, outer, impulse = tables.blast(pain)
    dmg = tables.damage(pain)
    hp = min(dmg['LIGHT'], MAX_HIT_FRACTION) * W.LIGHT_ARMOR_HP
    energy = (0, 0)
    if info['ammo_type'] == 0:
        energy = (info['minimum'] * ENERGY_PC_UNITS, min(info['cost'], 1.0) * ENERGY_PC_UNITS)
    source = ('PS2 executable SLUS_201.49: player_object::s_WeaponInfo[%d], pain type %d (g_PainBase / g_MetalDamageTable)' % (itype, pain))
    f = {'refire': info['refire'], 'damage': hp, 'damage_type': dtype, 'energy': energy, 'model_shape': 'tribes_aa:' + shape,
         'fire_sound': 'tribes_aa:aa_%s_fire' % name.lower(), 'tribes': round(dmg['LIGHT'], 3),
         'splash': 1.0 if outer > 0 else 0.0, 'splash_radius': outer}
    proj_shape = PROJECTILE_SHAPES.get(name)
    if name == 'LASER_RIFLE':
        f.update(beam=W.make_beam(color, 0.08, 0.12), range=LASER_RANGE_M, refire=LASER_REFIRE_S)
        f['energy'] = (info['minimum'] * ENERGY_PC_UNITS, W.r(ENERGY_PC_UNITS, 1))
        f['splash'], f['splash_radius'] = 0.0, 0.0
        kind_out = 'beam'
    elif name == 'ELF_GUN':
        f.update(beam=W.make_beam(color, 0.12, 0.12), range=ELF_RANGE_M, effects={'elf_leech': ELF_LEECH}, damage=0.0,
                 refire=0.2, energy=(info['minimum'] * ENERGY_PC_UNITS, ELF_DRAIN_PER_TICK * ENERGY_PC_UNITS))
        f['splash'], f['splash_radius'] = 0.0, 0.0
        kind_out = 'beam'
    elif name in ('MORTAR', 'GRENADE_LAUNCHER'):
        reach, flight = arc_flight(info['speed'], gravity)
        f.update(projectile=W.make_projectile(info['speed'], flight * 1.5, gravity, proj_shape, color, trail='smoke'), range=reach)
        kind_out = 'grenade'
    elif name == 'MISSILE_LAUNCHER':
        speed = MISSILE_MAX_SPEED
        f.update(projectile=W.make_projectile(speed, MISSILE_LIFETIME_S, 0.0, proj_shape, color, guidance='heat', turn_rate_deg=90.0,
                                              inherit=1.0, proximity=2.0), range=speed * MISSILE_LIFETIME_S * 0.5)
        kind_out = 'missile'
    else:
        speed, life = info['speed'], info['lifetime']
        f.update(projectile=W.make_projectile(speed, life, 0.0, proj_shape, color, inherit=1.0 if name == 'CHAINGUN' else 0.5),
                 range=speed * life)
        kind_out = kind
        if name == 'CHAINGUN':
            f.update(refire=CHAINGUN_PERIOD_S, spread_deg=W.degrees(CHAINGUN_SPREAD_RAD),
                     animation=W.make_animation(spin_up_s=CHAINGUN_SPINUP_S))
    f['notes'] = '%s Damage by armour (light / medium / heavy): %.2f / %.2f / %.2f; blast radius %.1f m full to %.1f m; impulse %g.%s' % (
        ('Cost %.3g of the energy pool.' % info['cost'] if info['cost'] > 0 else 'Drains energy while held.') if info['ammo_type'] == 0 else
        'Ammo: %d per shot.' % int(info['cost']), dmg['LIGHT'], dmg['MEDIUM'], dmg['HEAVY'], inner, outer, impulse,
        (' ' + notes) if notes else '')
    rec = W.make_weapon(name, display, source, kind_out, **f)
    return rec, color, max(outer, inner), source


def make_rules(tables, defines):
    """infantry_rules.json sizes: what each armour size may carry (INVENT_MAX), the default loadouts (LoadoutList)."""
    loadouts = tables.default_loadouts()
    sizes = {}
    for size in ARMOR_ORDER:
        d = defines[size]
        weapons = []
        for invent, name in INVENT_WEAPON.items():
            if d['invent'].get(invent, 0) > 0:
                weapons.append('%s:%s' % (PACK, name))
        ammo = {}
        for invent, name in INVENT_AMMO.items():
            if d['invent'].get(invent, 0) > 0 and '%s:%s' % (PACK, name) in weapons:
                ammo['%s:%s' % (PACK, name)] = d['invent'][invent]
        sizes[size] = {'max_weapons': int(d['max_weapons']), 'weapons': weapons, 'ammo': ammo,
                       'default_loadout': ['%s:%s' % (PACK, n) for n in loadouts.get(size, []) if '%s:%s' % (PACK, n) in weapons],
                       'hp': W.r(d['max_damage'] * 3000.0, 1), 'max_energy': W.r(d['max_energy'] * ENERGY_PC_UNITS, 1)}
    return sizes


# The weapon shapes are authored with the barrel along a different axis each (found by looking at the geometry: bounds and
# outlines); the held-weapon contract is the barrel along the shape's +Y (the engine's -Z) with the grip at the origin.
BARREL_AXIS = {'weapon_chaingun': '+x', 'weapon_blaster01': '+x', 'weapon_laser_rifle': '+x', 'weapon_plasma': '+x',
               'weapon_mortar': '-x', 'weapon_elf': '-x', 'weapon_missile01': '-z', 'weapon_disc': '+z',
               'weapon_grenade_launcher': '-z'}
FRAME_FLAG = 'weapon_frame'


def _turn(axis):
    """Function turning a shape-frame vector so that the barrel axis `axis` becomes +Y (a rotation about Z or X)."""
    return {'+x': lambda v: [-v[1], v[0], v[2]], '-x': lambda v: [v[1], -v[0], v[2]],
            '+z': lambda v: [v[0], v[2], -v[1]], '-z': lambda v: [v[0], -v[2], v[1]]}[axis]


def _untwist(axis):
    """The inverse of _turn(axis)."""
    return {'+x': lambda v: [v[1], -v[0], v[2]], '-x': lambda v: [-v[1], v[0], v[2]],
            '+z': lambda v: [v[0], -v[2], v[1]], '-z': lambda v: [v[0], v[2], -v[1]]}[axis]


def _compose(first, second):
    return lambda v: second(first(v))


def orient_shapes(pack_dir):
    """Turns each exported weapon shape so its barrel points along +Y; returns the number turned (a shape already turned is skipped)."""
    n = 0
    for name, axis in BARREL_AXIS.items():
        path = os.path.join(pack_dir, 'shapes', name + '.json')
        shape = W.read_json(path)
        if shape is None or shape.get(FRAME_FLAG) == axis:
            continue
        # a shape turned for another axis earlier (a corrected table) is first put back
        turn = _turn(axis) if not shape.get(FRAME_FLAG) else _compose(_untwist(shape[FRAME_FLAG]), _turn(axis))
        pts = []
        for lod in shape['lods']:
            for piece in lod['pieces']:
                for poly in piece['polys']:
                    poly['v'] = [[round(x, 5) for x in turn(v)] for v in poly['v']]
                    poly['n'] = [round(x, 5) for x in turn(poly['n'])]
                    pts.extend(poly['v'])
            lod['center'] = [round(x, 5) for x in turn(lod['center'])]
        shape['bounds'] = {'header': [[min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)]]}
        shape[FRAME_FLAG] = axis
        W.write_json(path, shape)
        n += 1
    return n


def copy_sounds(pack_dir):
    """The fire sounds from the pack's EFFECTS bank (audio/effects/NNN.wav, written by the audio step) to
    audio/sfx/sim/aa_<weapon>_fire.wav, where the sound player finds a stem. Returns the number copied."""
    dst_dir = os.path.join(pack_dir, 'audio', 'sfx', 'sim')
    os.makedirs(dst_dir, exist_ok=True)
    n = 0
    for name, _t, _d, _s, _p, _k, _dt, sound_id, _c, _n in WEAPONS:
        src = os.path.join(pack_dir, 'audio', 'effects', '%03d.wav' % sound_id)
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(dst_dir, 'aa_%s_fire.wav' % name.lower()))
            n += 1
    return n


def export(iso_path, pack_dir=None):
    """Writes the weapon files of the pack; returns the weapon count."""
    import aa_files
    import aa_logic
    pack_dir = pack_dir or P.pack(PACK)
    elf = aa_logic.read_elf(iso_path)
    tables = Tables(elf)
    files = aa_files.IsoFilesDat(iso_path)
    try:
        defines = read_defines(files)
        gravity = read_gravity(files)
    finally:
        files.close()
    weapons, effects = [], {}
    for spec in WEAPONS:
        rec, color, radius, source = make_weapon_record(spec, tables, defines, gravity)
        fx, fx_effects = W.make_fx(rec, 'aa_' + spec[0].lower(), color, radius, source, PROJECTILE_SHAPES.get(spec[0]),
                                   projectile_size=1.0 if spec[0] in PROJECTILE_SHAPES else 0.5)
        rec['fx'] = fx
        weapons.append(rec)
        effects.update(fx_effects)
    note = ('Aerial Assault damage: g_MetalDamageTable (light armour column) x 1980 = Earthsiege points; the light armour '
            '(MAX_DAMAGE 0.66) is 1980 hp as in the Tribes games; a table value is a fraction of the victim health (clamped at 1.0). '
            'Energy: one unit = 60 (MAX_ENERGY "from pc = 60").')
    W.write_weapons(pack_dir, PACK, weapons, note)
    W.write_effects(pack_dir, PACK, effects, 'engine default (no explosion data in the pack)')
    W.write_rules(pack_dir, PACK, make_rules(tables, defines))
    print('%s: %d fire sounds copied, %d shapes turned' % (PACK, copy_sounds(pack_dir), orient_shapes(pack_dir)))
    return len(weapons)


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    export(argv[0], argv[1] if len(argv) > 1 else None)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
