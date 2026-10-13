"""Earthsiege gameplay-data decoder: units, weapons, damage model, tuning constants.

    python tools/units.py [outdir]        (default outdir: extracted/gameplay)

Writes one JSON file per category:
    hercs.json      SIMVOL0/DAT/<UNIT>.DAT (192-byte unit types) + their GL/DMG/COL
    flyers.json     SKIMMER.DAT (+ DMG/COL for SKIMMER and HOVTANK)
    weapons.json    WEAPONS.DAT (17 weapons + 19-row projectile/impact table)
    projectiles.json BULLETS.DAT, ROCKETS.DAT, DEBRIS.DAT, EXPLOS.DAT (raw-ish)
    formations.json MFORMS/FFORMS/BFORMS.DAT
    bases.json      BASES.DAT (raw records)
    bnd.json        SIMVOL0/BND/*.BND and SHELL0/BND/*.BND tuning blocks
    shell_cfg.json  SHELL0/CFG/*.DAT (raw u16 dumps; armory screen layout)

Field names / confidence / EXE addresses are documented in docs/formats/gameplay.md.
All values are kept in the game's native integer units; see the doc for unit notes
(distances: world units, 1 unit = 6 mm, see docs/formats/units.md;
angles: 1/65536 of a turn; 'per-1024' fixed-point fractions are noted where known).
"""
import datetime
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
import self_destruct_rules  # noqa: E402
ROOT = P.WORK        # source tree; see tools/siege_paths.py
SIM = os.path.join(ROOT, 'extracted', 'SIMVOL0')
SHELL = os.path.join(ROOT, 'extracted', 'SHELL0')

HERCS = ['ROADRUNN', 'GUNSLING', 'RAPTOR', 'TOMAHAWK', 'PATRIOT', 'PANTHER', 'HERCULES', 'COLOSSUS']
CYBRIDS = ['MONGOOSE', 'SCORPION', 'MIRIMAC', 'RAMSES', 'ACHILLES', 'APOLLO', 'BULLDOG', 'SPIDER']
FLYERS = ['SKIMMER', 'HOVTANK']

# Damage components (DMG record index), the same layout for every 3Space unit (Herc and Cybrid).
# 0..12 are named by the sim's debug table (DBSIM 0x95e88);
# 13..18 are extra body parts used by non-humanoid units: the rear legs of BULLDOG / SPIDER (ES2
# STRINGS0 group 13 'RL UPPER LEG ARMOR' ...); other units keep 1-hp placeholders there;
# 19+i is weapon i of the unit's GL list (confirmed: Mech::onHit 0x13f1a uses comp-0x13 as gun index).
BODY_COMPONENTS = ['FRONT_COCKPIT', 'REAR_COCKPIT', 'LEFT_BRACKET', 'RIGHT_BRACKET', 'LEFT_SHOULDER',
                   'RIGHT_SHOULDER', 'CROTCH', 'LEFT_QUAD', 'RIGHT_QUAD', 'LEFT_SHIN', 'RIGHT_SHIN',
                   'LEFT_FOOT', 'RIGHT_FOOT']
EXTRA_COMPONENTS = ['REAR_LEFT_QUAD', 'REAR_RIGHT_QUAD', 'REAR_LEFT_SHIN', 'REAR_RIGHT_SHIN',
                    'REAR_LEFT_FOOT', 'REAR_RIGHT_FOOT']
FIRST_WEAPON_COMPONENT = 19
# Internal systems (DMG threshold array, indexed by link targets). Names from the debug table.
SYSTEMS = ['LEFT_LEG_ACTUATOR', 'RIGHT_LEG_ACTUATOR', 'LEFT_ARM_ACTUATOR', 'RIGHT_ARM_ACTUATOR',
           'SENSORS', 'ENGINE', 'HYDRAULICS', 'GYROS', 'LIFE_SUPPORT', 'PILOT']

WEAPON_NAMES = ['ATC20', 'ATC35', 'ATC50', 'ELF', 'EMP', 'GREN', 'LAS100', 'LAS200', 'LAS300',
                'MLRS6', 'MLRS8', 'MLRS10', 'PBEAM', 'ECM', 'EMP_CYBRID', 'PBEAM_CYBRID', 'MISSL_CYBRID']
# exe name table at 0x911fc gives "6","8","10" for 9..11 (missile racks) and EMP/PBEAM twice.
WEAPON_EXE_NAMES = ['ATC20', 'ATC35', 'ATC50', 'ELF', 'EMP', 'GREN', 'LAS100', 'LAS200', 'LAS300',
                    '6', '8', '10', 'PBEAM', 'ECM', 'EMP', 'PBEAM', 'MISSL']
WEAPON_CLASS = {  # constructor chosen by GunList ctor jump table 0x913e8
    'ATC20': 'projectile', 'ATC35': 'projectile', 'ATC50': 'projectile', 'ELF': 'beam_elf',
    'EMP': 'beam', 'GREN': 'grenade', 'LAS100': 'beam', 'LAS200': 'beam', 'LAS300': 'beam',
    'MLRS6': 'projectile', 'MLRS8': 'projectile', 'MLRS10': 'projectile', 'PBEAM': 'beam', 'ECM': 'ecm',
    'EMP_CYBRID': 'beam', 'PBEAM_CYBRID': 'beam', 'MISSL_CYBRID': 'projectile'}
PROJ_TYPES = {0: 'missile', 2: 'bullet', 3: 'grenade', 4: 'bolt'}
MISSILE_TYPES = ['SARH', 'ARH', 'ARM', 'EO']   # strings at 0x9109a; projectile rows type 0 sub 0..3


def rd(path):
    with open(path, 'rb') as f:
        return f.read()


def s16(b, o):
    return struct.unpack_from('<h', b, o)[0]


def u16(b, o):
    return struct.unpack_from('<H', b, o)[0]


def words(b, o=0, n=None, signed=True):
    if n is None:
        n = (len(b) - o) // 2
    return list(struct.unpack_from('<%d%s' % (n, 'h' if signed else 'H'), b, o))


def cstr(b):
    return b.split(b'\0', 1)[0].decode('latin-1')


def bytelist(b, o, maxlen):
    out = []
    for i in range(maxlen):
        v = b[o + i]
        if v == 0xff:
            break
        out.append(v)
    return out


# ----------------------------------------------------------------------------------------------
# Unit type (.DAT, 192 bytes).  MechType in memory = u16 index + these 192 bytes (+2 bias).
# (offset, name, kind)   kind: h=s16, H=u16
UNIT_FIELDS = [
    (0x00, 'turn_rate_max', 'h'),          # H  0x12a2c  peak yaw rate (curve vs speed, see doc)
    (0x02, 'speed_reverse_max', 'h'),      # H  0x120b2  throttle clamp (negative)
    (0x04, 'speed_forward_max', 'h'),      # H  0x120b8  throttle clamp
    (0x06, 'acceleration', 'h'),           # H  0x12198  approach rate of speed to throttle
    (0x08, 'turn_acceleration', 'h'),      # H  0x12a6e  approach rate of yaw rate
    (0x0a, 'anim_seq_a', 'h'),             # M  shape sequence ids (0x18bcc)
    (0x0c, 'anim_seq_stand', 'h'),         # M  0x124d0
    (0x0e, 'anim_seq_start', 'h'),         # L  0x125c1
    (0x10, 'anim_seq_walk_fwd', 'h'),      # M  0x1225e (also node-index use at 0x115ce)
    (0x12, 'anim_seq_walk_back', 'h'),     # M  0x12267
    (0x14, 'z_offset', 'h'),               # M  0x131d3 added to position z (COLOSSUS 400)
    (0x16, 'shield_center_z', 'h'),        # M  0xfcc2  shield sphere centre height
    (0x18, 'shield_radius', 'h'),          # M  0xfd05  shield/hit bounding sphere radius
    (0x1a, 'torso_yaw_node', 'h'),         # H  0x11652 (-1 = none)
    (0x1c, 'torso_yaw_rate', 'h'),         # H  0x149c6
    (0x1e, 'torso_yaw_accel', 'h'),        # H  0x14a42
    (0x20, 'torso_yaw_limit', 'h'),        # H  0x14a87 (1/65536 turn; 32767 = unlimited turret)
    (0x22, 'torso_pitch_node', 'h'),       # H  0x11682
    (0x24, 'torso_pitch_rate', 'h'),       # H  0x14bba
    (0x26, 'torso_pitch_accel', 'h'),      # H  0x14c36
    (0x28, 'torso_pitch_max', 'h'),        # H  0x14c7d
    (0x2a, 'torso_pitch_min', 'h'),        # H  0x14c85
    (0x2c, 'walk_seq_speed_cap', 'h'),     # M  0x12433 speed clamp while in walk sequence
    (0x42, 'unknown_42', 'h'),             # ?  0x18a15 (AI)
    (0x44, 'anim_seq_shutdown', 'h'),      # L  0x122fc
    (0x46, 'lowdetail_shape_lod', 'h'),    # M  0x19d87 shape detail used when low-detail flag set
    (0x48, 'leg_count', 'h'),  # M  0x13007: mission pre-damage < 20 % blows a quad (7/8) and, > 2 legs, a rear quad (13/14)
    (0x4a, 'self_destruct', 'h'),          # M  0x13919 (SPIDER = 1)
    (0x4c, 'mass', 'h'),                   # H  0x1430f momentum = mass*speed/1024 (ramming)
    (0x52, 'threat_value', 'h'),           # M  0x14106/0x15b37 summed per team; 0 -> passive flag
    (0x54, 'weapons_damageable', 'h'),     # M  0x13eb7 weapon components can be knocked out
    (0x62, 'eye_y', 'h'),                  # M  0x10f04 cockpit eye point (y fwd)
    (0x64, 'eye_z', 'h'),                  # M  0x10f0c (z up)
    (0x66, 'view2_y', 'h'),                # L  0x10f14 second view point
    (0x68, 'view2_z', 'h'),                # L  0x10f1c
    (0x6a, 'runtime_type_id', 'h'),        # H  overwritten at load (0x19d5c)
    (0x6c, 'unknown_6c', 'h'),             # L  0x1492c (compared with -speed)
    (0x6e, 'unknown_6e', 'h'),
    (0x7a, 'anim_seq_7a', 'h'),            # L  0x12842
    (0x94, 'size_class', 'h'),             # H  0 light 1 medium 2 heavy 3 cybrid -> texture set
    (0xbe, 'shield_max', 'h'),             # H  0x115a7 -> Shields::init (front=rear=max/2)
]
SIZE_CLASS = ['light', 'medium', 'heavy', 'enemy']


def parse_unit_dat(b):
    assert len(b) == 192
    r = {}
    for off, name, k in UNIT_FIELDS:
        r[name] = s16(b, off) if k == 'h' else u16(b, off)
    r['name'] = cstr(b[0x56:0x62])
    r['texture_set'] = SIZE_CLASS[r['size_class']] if 0 <= r['size_class'] < 4 else None
    r['shape_nodes_2e'] = bytelist(b, 0x2e, 20)            # 0x19ba0 node list (0xff-terminated)
    r['emitters_70'] = bytelist(b, 0x70, 10)               # 0x1171d effect/emitter type list
    r['unknown_7c_words'] = words(b, 0x7c, 12)             # 12 x 500 in every unit
    r['vec_96'] = words(b, 0x96, 4)
    r['vec_aa'] = words(b, 0xaa, 3)
    r['raw_words'] = words(b)
    return r


def parse_gl(b):
    """Gun list: u16 n, n x 26-byte mounts."""
    n = u16(b, 0)
    out = []
    for i in range(n):
        o = 2 + 26 * i
        r = b[o:o + 26]
        out.append({
            'mount_node': u16(r, 0),          # shape node the weapon hangs on (0xadd4)
            'aux_node_a': s16(r, 2),          # -1 = none (0xa688)
            'aux_node_b': s16(r, 4),
            'mount_group': r[6],              # 0..3 selects weapon shape variant (wpn+0x22+2*g)
            'display_index': r[7],
            'yaw_min': s16(r, 8), 'yaw_max': s16(r, 10),
            'pitch_min': s16(r, 12), 'pitch_max': s16(r, 14),
            'offset': [s16(r, 16), s16(r, 18), s16(r, 20)],
            'side': struct.unpack_from('<b', r, 22)[0],   # 1 left, -1 right, 0 centre
            'loadout_slot': r[23],            # index into player.mec / mission weapon arrays
            'hud_y': r[24],                   # L
            'hardpoint_mask': r[25],          # L 31/15/7 = large/medium/small hardpoint
        })
    return out


def parse_dmg(b):
    """Damage model: system thresholds + component records."""
    p = 0
    n = u16(b, p); p += 2
    thresholds = words(b, p, n); p += 2 * n
    m = u16(b, p); p += 2
    comps = []
    for i in range(m):
        hp = u16(b, p)
        b2, node, parent, flags = struct.unpack_from('<4b', b, p + 2)
        c = u16(b, p + 6)
        p += 8
        links = []
        for k in range(c):
            w, s = struct.unpack_from('<hh', b, p + 4 * k)
            links.append({'weight': w, 'system': s})
        p += 4 * c
        comps.append({'index': i, 'hp': hp, 'b2': b2, 'shape_part': node, 'parent': parent,
                      'flags': flags, 'fatal': bool(flags & 1), 'debris_on_destroy': bool(flags & 2),
                      'big_explosion': bool(flags & 4), 'links': links})
    assert p == len(b)
    return {'system_thresholds': thresholds, 'components': comps}


def parse_col(b):
    """Collision spheres: u16 n, n x {u16 node, u16 m, m x {u16 component, u16 k, k x (x,y,z,r)}}."""
    p = 0
    n = u16(b, p); p += 2
    out = []
    for i in range(n):
        node, m = struct.unpack_from('<hH', b, p); p += 4
        parts = []
        for j in range(m):
            comp, k = struct.unpack_from('<hH', b, p); p += 4
            sph = [list(struct.unpack_from('<4h', b, p + 8 * q)) for q in range(k)]
            p += 8 * k
            parts.append({'component': comp, 'spheres': sph})
        out.append({'node': node, 'parts': parts})
    assert p == len(b)
    return out


def component_name(index):
    """Name of DMG component `index`: the layout is fixed by index for every 3Space unit."""
    if index >= FIRST_WEAPON_COMPONENT:
        return 'WEAPON %d' % (index - FIRST_WEAPON_COMPONENT + 1)
    return (BODY_COMPONENTS + EXTRA_COMPONENTS)[index]


def load_units():
    res = {}
    for n in HERCS + CYBRIDS:
        d = {'file': n, 'side': 'herc' if n in HERCS else 'cybrid'}
        d.update(parse_unit_dat(rd(os.path.join(SIM, 'DAT', n + '.DAT'))))
        d['guns'] = parse_gl(rd(os.path.join(SIM, 'GL', n + '.GL')))
        dm = parse_dmg(rd(os.path.join(SIM, 'DMG', n + '.DMG')))
        for c in dm['components']:
            c['name'] = component_name(c['index'])
        d['damage'] = dm
        d['damage']['system_names'] = SYSTEMS
        d['collision'] = parse_col(rd(os.path.join(SIM, 'COL', n + '.COL')))
        res[n] = d
    self_destruct_rules.apply_to_units(res, 'es1')
    return res


# ----------------------------------------------------------------------------------------------
FLYER_FIELDS = ['yaw_rate_accel', 'unknown_02', 'cruise_value_04', 'unknown_06', 'pitch_rate_accel',
                'bank_shift', 'unknown_0c', 'unknown_0e', 'unknown_10']


def load_flyers():
    res = {}
    b = rd(os.path.join(SIM, 'DAT', 'SKIMMER.DAT'))
    w = words(b)
    res['SKIMMER'] = {'fields': dict(zip(FLYER_FIELDS, w[:9])), 'raw_words': w}
    for n in FLYERS:
        res.setdefault(n, {})
        b = rd(os.path.join(SIM, 'DMG', n + '.DMG'))
        try:
            res[n]['damage'] = parse_dmg(b)
        except (struct.error, AssertionError):
            # HOVTANK.DMG does not follow the DMG layout (looks like 3 spheres + 1500); the unit
            # has no .DAT and is probably never instantiated.
            res[n]['damage'] = {'unparsed_words': words(b)}
        res[n]['collision'] = parse_col(rd(os.path.join(SIM, 'COL', n + '.COL')))
    res['HOVTANK']['note'] = 'listed in FLYERS.NAM but has no .DAT (only DMG/COL)'
    return res


# ----------------------------------------------------------------------------------------------
WEAPON_BLOCK = [  # offsets are within the 0x58-byte runtime object; block starts at 0x22
    (0x22, 'shape_group0', 'h'), (0x24, 'shape_group1', 'h'), (0x26, 'shape_group2', 'h'),
    (0x28, 'shape_group3', 'h'),
    (0x2a, 'unknown_2a', 'h'), (0x2c, 'unknown_2c', 'h'), (0x2e, 'unknown_2e', 'h'),
    (0x30, 'range', 'I'),             # u32  passed as range to beam/bolt spawn (0xb09e, 0xb259)
    (0x34, 'ai_cost', 'h'),           # AI weapon choice penalty (0x1902d)
    (0x36, 'min_charge', 'h'),        # beam: minimum capacitor charge to fire (0xb28c)
    (0x38, 'per_shot', 'h'),          # beam: charge per full shot; gun: ammo used per shot
    (0x3a, 'ammo', 'h'),              # projectile guns: magazine (0xaa1b)
    (0x3c, 'beams', 'h'),             # 3 = triple beam using muzzle x mirrored (0xb0f5)
    (0x3e, 'projectile', 'h'),        # row in projectile table; 20 none (ECM), 21 missile rack, 22 grenade
    (0x40, 'muzzle_x', 'h'), (0x42, 'muzzle_y', 'h'), (0x44, 'muzzle_z', 'h'),  # 0xaea4
    (0x46, 'unknown_46', 'h'), (0x48, 'unknown_48', 'h'), (0x4a, 'unknown_4a', 'h'),
    (0x4c, 'refire_delay', 'h'),      # cooldown timer loaded on fire (0xaf11)
    (0x4e, 'unknown_4e', 'h'),        # mech code 0x18a74, scaled by (256-x)/256
    (0x50, 'hud_icon', 'h'),          # 0x30644
]


def parse_weapons(b):
    p = 0
    weapons = []
    for i in range(17):
        hp, b2, node, parent, flags, cnt = struct.unpack_from('<H4bH', b, p); p += 8
        links = [dict(zip(('weight', 'system'), struct.unpack_from('<hh', b, p + 4 * k))) for k in range(cnt)]
        p += 4 * cnt
        col_node = s16(b, p); p += 2
        ns = u16(b, p); p += 2
        spheres = [list(struct.unpack_from('<4h', b, p + 8 * k)) for k in range(ns)]
        p += 8 * ns
        blk = b[p:p + 0x30]; p += 0x30
        w = {'index': i, 'name': WEAPON_NAMES[i], 'exe_name': WEAPON_EXE_NAMES[i],
             'class': WEAPON_CLASS[WEAPON_NAMES[i]],
             'component': {'hp': hp, 'b2': b2, 'shape_part': node, 'parent': parent, 'flags': flags,
                           'links': links},
             'collision': {'node': col_node, 'spheres': spheres}}
        for off, name, k in WEAPON_BLOCK:
            o = off - 0x22
            w[name] = struct.unpack_from('<' + k, blk, o)[0]
        weapons.append(w)
    tail = b[p:]
    assert len(tail) == 19 * 36
    proj = []
    for i in range(19):
        r = words(tail, 36 * i, 18)
        t = r[0]
        proj.append({'index': i, 'type': t, 'type_name': PROJ_TYPES.get(t, '?'), 'sub': r[1],
                     'shield_damage': r[2], 'armor_damage': r[3], 'splash_per1024': r[4],
                     'speed_or_limit': r[5],
                     'fx_miss': r[6:10], 'fx_shield_hit': r[10:14], 'fx_armor_hit': r[14:18]})
    for w in weapons:
        pi = w['projectile']
        if 0 <= pi < 19:
            w['projectile_row'] = proj[pi]
        elif pi == 21:
            w['projectile_row'] = 'missile rack: row = (type 0, sub = loadout missile type %s)' % MISSILE_TYPES
        elif pi == 20:
            w['projectile_row'] = None
    return {'weapons': weapons, 'projectiles': proj, 'missile_types': MISSILE_TYPES}


# ----------------------------------------------------------------------------------------------
def parse_counted(b, recsize):
    n = u16(b, 0)
    assert 2 + n * recsize == len(b), (n, recsize, len(b))
    return [words(b, 2 + recsize * i, recsize // 2) for i in range(n)]


def load_projectiles():
    out = {}
    out['bullets'] = [dict(zip(('shape', 'lifetime', 'hit_size', 'flags', 'sound'), r))
                      for r in parse_counted(rd(os.path.join(SIM, 'DAT', 'BULLETS.DAT')), 10)]
    out['rockets'] = [dict(zip(('shape', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6'), r))
                      for r in parse_counted(rd(os.path.join(SIM, 'DAT', 'ROCKETS.DAT')), 14)]
    b = rd(os.path.join(SIM, 'DAT', 'DEBRIS.DAT'))
    n, p, deb = u16(b, 0), 2, []
    for i in range(n):
        a, c = struct.unpack_from('<hH', b, p); p += 4
        deb.append({'w0': a, 'pieces': [list(struct.unpack_from('<hh', b, p + 4 * k)) for k in range(c)]})
        p += 4 * c
    out['debris'] = deb
    out['explosions'] = parse_counted(rd(os.path.join(SIM, 'DAT', 'EXPLOS.DAT')), 44)
    return out


def load_forms():
    def pts(b, rec, fmt, k):
        return [[list(struct.unpack_from('<' + fmt, b, 2 + rec * i + struct.calcsize('<' + fmt) * j))
                 for j in range(rec // struct.calcsize('<' + fmt))] for i in range(u16(b, 0))]
    out = {
        'mech_formations': pts(rd(os.path.join(SIM, 'DAT', 'MFORMS.DAT')), 0x1c, 'hh', 2),
        'flyer_formations': pts(rd(os.path.join(SIM, 'DAT', 'FFORMS.DAT')), 18, 'hhh', 3),
        'base_formations': pts(rd(os.path.join(SIM, 'DAT', 'BFORMS.DAT')), 0x38, 'ii', 2),
    }
    return out


def load_bases():
    return {'bases': parse_counted(rd(os.path.join(SIM, 'DAT', 'BASES.DAT')), 0x36),
            'basecol_raw_words': words(rd(os.path.join(SIM, 'DAT', 'BASECOL.DAT')))}


# ----------------------------------------------------------------------------------------------
# BND: u32 unix timestamp (build/tune time) + packed tuning values (u16/s16, longs as 2 words).
# DBSIM does NOT read .BND at run time (the 'bnd' extension pointer at 0x980c0 has no code refs);
# the values were compiled in as immediates / static tables.  Names below are for values whose
# use in the exe was located (word index -> (name, kind, exe address, confidence)).
BND_NAMES = {
    'SHIELDS': {0: ('balance_step_per1024', 'h', 0xfaf0, 'H'),
                1: ('recharge_max_per_update', 'h', 0xfb51, 'H'),
                2: ('balance_follow_rate', 'h', 0xfb94, 'H'),
                3: ('drain_scale_per1024', 'h', 0xfc85, 'M')},
    'MECH': {7: ('emp_shield_down_time', 'h', 0x13c39, 'H'),
             14: ('dist_45000', 'i', 0x15b0d, 'L'), 16: ('dist_50000', 'i', 0x1001c, 'L'),
             18: ('dist_35000', 'i', 0x15ce0, 'L'),
             32: ('leg_damage_threshold_slow', 'h', 0x137eb, 'M'),
             33: ('leg_damage_threshold_crippled', 'h', 0x137c6, 'M'),
             34: ('speed_scale_both_legs_damaged_per1024', 'h', 0x1212e, 'H'),
             35: ('speed_scale_one_leg_damaged_per1024', 'h', 0x12153, 'H'),
             47: ('min_speed_for_turning', 'h', 0x1299c, 'H'),
             48: ('min_anim_rate', 'h', 0x12458, 'M')},
    'MECHIQ': {90: ('weapon_choice_noise_vs_player', 'h', 0x18ed2, 'M'),
               91: ('weapon_choice_noise', 'h', 0x18ed9, 'M'),
               92: ('skill_lerp_hi', 'h', 0x18e69, 'L'),
               93: ('skill_lerp_lo', 'h', 0x18e67, 'L')},
    'MECHDMG': {0: ('unknown_0', 'h', 0x918e6, 'L')},
    'BEAM': {4: ('charge_rate_fast', 'h', 0xb52a, 'H'),
             7: ('charge_rate_normal', 'h', 0xb531, 'H')},
}
BND_NOTES = {
    'MECHDMG': 'word0 ?, words1..19 = body-component weights, words20..31 = system weights used by '
               'MechDamage::integrity (0x10c38; exe tables 0x918e8 / 0x91910, word0 is 100 in exe).',
    'MECHSYS': '7 x u32 {75,60,45,25,18,12,6} identical to exe table 0x91dac (attached to every mech '
               'shape at 0x19da7; probably shape LOD distance/size thresholds).',
}


def parse_bnd(path, name):
    b = rd(path)
    ts = struct.unpack_from('<I', b, 0)[0]
    body = b[4:]
    w = words(body)
    r = {'timestamp': ts,
         'time_utc': datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat()
         if 600000000 < ts < 900000000 else None,
         'size': len(body), 'words': w}
    named = {}
    for i, (nm, k, addr, conf) in BND_NAMES.get(name, {}).items():
        v = struct.unpack_from('<' + k, body, 2 * i)[0]
        named[nm] = {'word': i, 'value': v, 'exe': '0x%x' % addr, 'confidence': conf}
    if named:
        r['named'] = named
    if name in BND_NOTES:
        r['note'] = BND_NOTES[name]
    return r


def load_bnd():
    out = {}
    for vol, d in (('SIMVOL0', os.path.join(SIM, 'BND')), ('SHELL0', os.path.join(SHELL, 'BND'))):
        out[vol] = {}
        for f in sorted(os.listdir(d)):
            if f.upper().endswith('.BND'):
                out[vol][f[:-4]] = parse_bnd(os.path.join(d, f), f[:-4])
    return out


def load_shell_cfg():
    d = os.path.join(SHELL, 'CFG')
    out = {}
    for f in sorted(os.listdir(d)):
        if not f.upper().endswith('.DAT') or f.upper() == 'CONFIG.DAT':
            continue
        b = rd(os.path.join(d, f))
        out[f] = {'size': len(b), 'words': words(b)}
    out['_note'] = ('Shell (GO.EXE) armory/repair screen data: <HERC>.DAT = hardpoint hotspots, '
                    '<HERC>DMG1.DAT = damage-diagram regions, DAMAGE.DAT = cost tables. Not decoded.')
    return out


# ----------------------------------------------------------------------------------------------
def sanity(units, weapons):
    msgs = []
    hs = sorted(((units[n]['mass'], units[n]['speed_forward_max'], n) for n in HERCS))
    msgs.append('Hercs by mass (mass, max fwd speed): ' + ', '.join('%s %d/%d' % (n, m, s) for m, s, n in hs))
    ok = all(a[1] >= b[1] for a in hs for b in hs if a[0] < b[0])
    msgs.append('  heavier class never faster than a lighter one: %s' % ok)
    wd = {w['name']: w for w in weapons['weapons']}

    def arm(n):
        r = wd[n].get('projectile_row')
        return r['armor_damage'] if isinstance(r, dict) else None

    for grp in (('LAS100', 'LAS200', 'LAS300'), ('ATC20', 'ATC35', 'ATC50')):
        vals = [arm(n) for n in grp]
        msgs.append('  armor dmg %s = %s increasing: %s' % (grp, vals, vals == sorted(vals)))
    return msgs


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'extracted', 'gameplay')
    os.makedirs(outdir, exist_ok=True)
    units = load_units()
    weapons = parse_weapons(rd(os.path.join(SIM, 'DAT', 'WEAPONS.DAT')))
    cats = {
        'hercs': units,
        'flyers': load_flyers(),
        'weapons': weapons,
        'projectiles': load_projectiles(),
        'formations': load_forms(),
        'bases': load_bases(),
        'bnd': load_bnd(),
        'shell_cfg': load_shell_cfg(),
    }
    for k, v in cats.items():
        with open(os.path.join(outdir, k + '.json'), 'w', encoding='utf-8') as f:
            json.dump(v, f, indent=1)
    print('wrote %d files to %s' % (len(cats), outdir))
    for m in sanity(units, weapons):
        print(m)


if __name__ == '__main__':
    main()
