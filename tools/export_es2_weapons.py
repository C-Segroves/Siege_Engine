"""Earthsiege 2 weapons -> gamedata/es2/gameplay/weapons_engine.json (docs/formats/weapon_schema.md),
weapons_raw.json, weapon pod / projectile shapes, weapon sounds.

    python tools/export_es2_weapons.py

Sources (es2/extracted, see docs/formats/es2.md section 9):
  SIMVOL0/DAT/WEAPONS.DAT  u16 33 + 33 records, ES1 layout: [DMG component][COL spheres][0x30-byte params]
                           (record 0 = "None"); loader DBSIM 0x40fc8c (GUNLIST.CPP), 0x58-byte objects
  SIMVOL0/DAT/PROJ.DAT     u16 27 + 27 x 36-byte projectile/impact rows (ES1 kept them inside WEAPONS.DAT)
  SIMVOL0/DAT/BULLETS.DAT  u16 12 + 12 x 7 words, indexed by bullet sub   (bullet.cpp, 0x40ade0)
  SIMVOL0/DAT/ROCKETS.DAT  u16 5 + 5 x 7 words, indexed by missile sub    (rocket.cpp, 0x40a836)
  SIMVOL0/DAT/BEAM.DAT     u16 10 + 10 x 3 words, indexed by bolt sub      (BEAM.CPP, 0x40b71d)
  SIMVOL0/DAT/LC_WPNS.DAT  base defence weapons (base.cpp 0x406183) - raw only
  SIMVOL0/STR/SOUNDS.STR   sound id -> WAV name (SIMSOUND/HMI = 22 kHz, HMX = 11 kHz)
  LANG0/ENG/WEAPONS.BIN, WPN_DESC.BIN, WPN_INFO.BIN   display names / shell texts
  SHELL0/GAM/WEAPONS.DAT   shell names + salvage cost; SHELL0/GAM/INI_*.DAT default loadouts

Conversions (all verified against es2/original/DBSIM.EXE, Win32 PE, image base 0x400000, VA = 0x400000+RVA;
the instruction bytes listed in EVIDENCE are checked when the exe is present):
  distance  1 unit = 1/256 m (shared world scale; gamedata/es2/units.json). Shell texts use 1/166.7 m.
  frame     scale = elapsed_ms*256/125 (0x46779b..0x4677f3, nominal [0x4d3bf4]=1000 -> /8 = 125 ms,
            clamped 64..450, min frame 40 ms) -> "per 256 scale" quantities are per 125 ms (ES1: 100 ms).
  timers    count down by the scale (0x467944/0x4679a4) -> 2048 units per second (ES1: 2560).
  speeds    move += scale(speed)>>8 per frame (bullets 0x40b1eb, rockets 0x40a66d) -> units per 125 ms
            -> m/s = v * 8 / 256.
  per-frame quantities without scaling (rocket lifetime 0x40a5d7, capacitor +20 0x40e0cc/0x40f00c, ELF ticks)
            use the nominal 125 ms frame.
"""
import json, os, re, shutil, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
SRC = P.work('es2', 'extracted')
SIM = os.path.join(SRC, 'SIMVOL0')
EXE = P.work('es2', 'original', 'DBSIM.EXE')
OUT = P.pack('es2')

MPU = 1.0 / 256.0            # metres per unit (packs.gd WORLD_SCALE es2)
FRAME_S = 0.125              # nominal frame / "per 256 scale" period
TIMER_PER_S = 2048.0         # timer units per second
SPEED_TO_MPS = MPU / FRAME_S  # units per 125 ms -> m/s
ANGLE_DEG = 360.0 / 65536.0
CAPACITOR = 820 * 1200 >> 10  # 960: Beam ctor 0x40e09b, 0x47dfa4(a,b) = a*b>>10
CAP_RATE = 20                 # capacitor points per update (0x40e0cc)

# exe weapon name table 0x498eb0 (index -> name), 13/14 are "6" and "8"
EXE_NAMES = ['None', 'ATC20', 'ATC35', 'ATC50', 'ATC75', 'ATC100', 'ELF', 'EMP', 'LAS100', 'LAS200', 'LAS300',
             'LAS400', 'LAS500', '6', '8', '10', '24', 'PBEAM', 'ECM', 'EMP', 'PBEAM', 'MISSL', 'ELF2', 'EMP2',
             'PBW2', 'PLAS', 'LAEW', 'MINE', 'MAGN', 'TARG', 'SHIELD', 'TURBO', 'ENERGY']
# GunList::create jump table 0x4100fd -> constructor (0x41011e cases)
CLASS_CASES = {0: 'none', 1: 'energy_pod', 2: 'turbo_pod', 3: 'shield_pod', 4: 'targeting_pod',
               5: 'beam', 6: 'locust', 7: 'beam_continuous', 8: 'projectile', 9: 'ecm'}
CLASS_TABLE_FALLBACK = bytes.fromhex('000808080808070505050505050808080805090505080705050506000504030201')
PROJ_TYPES = {0: 'missile', 2: 'bullet', 3: 'grenade', 4: 'bolt'}
MISSILE_SUBS = [('SARH', 'sarh'), ('ARH', 'arh'), ('ARM', 'arm'), ('EO', 'eo')]

# instruction bytes the conversions rely on (VA -> hex)
EVIDENCE = {
    0x46774C: ('66bae803', 'nominal frame 1000/8 = 125 ms'),
    0x4677A3: ('663dc201', 'frame scale clamp 450'),
    0x4677C9: ('83c328', 'min frame 40 ms'),
    0x40E936: ('0fbf784c', 'refire timer = DAT+0x4c * rof(1024) >> 10'),
    0x40E0CC: ('c7437f14000000', 'capacitor +20 per update'),
    0x40E09B: ('68b0040000', 'capacitor 820*1200>>10 = 960'),
    0x40B197: ('6800020000', 'bullet age += scale(512); lifetime in 125 ms units'),
    0x40A41E: ('6800050000', 'missile turn limit 0x500 per 125 ms'),
    0x40B0BA: ('6880020000', 'plasma homing turn limit 0x280 per 125 ms'),
    0x40B3F2: ('68a00f0000', 'plasma blast radius 4000 units'),
    0x40B387: ('3dd0070000', 'plasma proximity fuse 2000 units'),
    0x418C4A: ('66c7836b0200007017', 'EMP hit: shields off, timer 6000'),
    0x40C054: ('6a0b', 'beam fire sound id 11'),
    0x40EC89: ('68b0040000', 'ELF tick damage scale 1200/1024'),
    0x40F04C: ('03d2', 'PLAS (index 25) draws double energy for its capacitor'),
    0x40EC13: ('0fbf424c', 'EMP2 (row 19) second burst after refire/4'),
}


# ------------------------------------------------------------------------------------------- PE
class PE:
    """Minimal PE section mapper (VA -> bytes)."""

    def __init__(self, path):
        d = open(path, 'rb').read()
        pe = struct.unpack_from('<I', d, 0x3c)[0]
        assert d[pe:pe + 4] == b'PE\0\0'
        nsec = struct.unpack_from('<H', d, pe + 6)[0]
        opt = struct.unpack_from('<H', d, pe + 20)[0]
        self.base = struct.unpack_from('<I', d, pe + 52)[0]
        self.secs = []
        so = pe + 24 + opt
        for i in range(nsec):
            vsize, rva, rsize, raw = struct.unpack_from('<IIII', d, so + 40 * i + 8)
            self.secs.append((self.base + rva, max(vsize, rsize), raw, rsize))
        self.d = d

    def at(self, va, n):
        for sva, size, raw, rsize in self.secs:
            if sva <= va < sva + size:
                o = va - sva
                return self.d[raw + o:raw + o + n] if o < rsize else b'\0' * n
        raise KeyError(hex(va))


def verify_exe():
    if not os.path.exists(EXE):
        print('  DBSIM.EXE not found: conversions not re-verified')
        return None, 'DBSIM.EXE missing (constants from docs)'
    pe = PE(EXE)
    bad = [hex(va) for va, (hx, _) in EVIDENCE.items() if pe.at(va, len(hx) // 2).hex() != hx]
    if bad:
        raise SystemExit('DBSIM.EXE build differs at %s - re-check docs/formats/es2.md section 9' % bad)
    return pe.at(0x4100FD, 33), 'verified %d code sites in es2/original/DBSIM.EXE' % len(EVIDENCE)


# ---------------------------------------------------------------------------------------- parse
def rd(*p):
    return open(os.path.join(*p), 'rb').read()


def strtab(b):
    """LANG0 *.BIN: u16 n, u16 0, u32 size, n x u16 offset, NUL-terminated strings."""
    n = struct.unpack_from('<H', b, 0)[0]
    offs = struct.unpack_from('<%dH' % n, b, 8)
    base = 8 + 2 * n
    return [b[base + o:b.index(b'\0', base + o)].decode('latin1') for o in offs]


WEAPON_BLOCK = [  # (offset in 0x58-byte object, name, struct code); block = obj 0x22..0x52
    (0x22, 'shape_group0', 'h'), (0x24, 'shape_group1', 'h'), (0x26, 'shape_group2', 'h'),
    (0x28, 'shape_group3', 'h'), (0x2a, 'unknown_2a', 'h'), (0x2c, 'unknown_2c', 'h'), (0x2e, 'unknown_2e', 'h'),
    (0x30, 'range', 'I'), (0x34, 'ai_cost', 'h'), (0x36, 'min_charge', 'h'), (0x38, 'per_shot', 'h'),
    (0x3a, 'ammo', 'h'), (0x3c, 'beams', 'h'), (0x3e, 'projectile', 'h'),
    (0x40, 'muzzle_x', 'h'), (0x42, 'muzzle_y', 'h'), (0x44, 'muzzle_z', 'h'),
    (0x46, 'unknown_46', 'h'), (0x48, 'unknown_48', 'h'), (0x4a, 'unknown_4a', 'h'),
    (0x4c, 'refire_delay', 'h'), (0x4e, 'unknown_4e', 'h'), (0x50, 'hud_icon', 'h'),
]


def parse_weapons(b):
    n = struct.unpack_from('<H', b, 0)[0]
    p, out = 2, []
    for i in range(n):
        hp, b2, node, parent, flags, cnt = struct.unpack_from('<H4bH', b, p); p += 8
        links = [dict(zip(('weight', 'system'), struct.unpack_from('<hh', b, p + 4 * k))) for k in range(cnt)]
        p += 4 * cnt
        col_node, ns = struct.unpack_from('<hH', b, p); p += 4
        spheres = [list(struct.unpack_from('<4h', b, p + 8 * k)) for k in range(ns)]
        p += 8 * ns
        w = {'index': i, 'component': {'hp': hp, 'b2': b2, 'shape_part': node, 'parent': parent,
                                       'flags': flags, 'links': links},
             'collision': {'node': col_node, 'spheres': spheres}}
        for off, name, k in WEAPON_BLOCK:
            w[name] = struct.unpack_from('<' + k, b, p + off - 0x22)[0]
        p += 0x30
        out.append(w)
    assert p == len(b), (p, len(b))
    return out


def parse_counted(b, words):
    n = struct.unpack_from('<H', b, 0)[0]
    assert 2 + 2 * words * n == len(b), (n, words, len(b))
    return [list(struct.unpack_from('<%dh' % words, b, 2 + 2 * words * i)) for i in range(n)]


def parse_proj(b):
    rows = []
    for i, r in enumerate(parse_counted(b, 18)):
        rows.append({'index': i, 'type': r[0], 'type_name': PROJ_TYPES.get(r[0], '?'), 'sub': r[1],
                     'shield_damage': r[2], 'armor_damage': r[3], 'splash_per1024': r[4], 'speed': r[5],
                     'fx_miss': r[6:10], 'fx_shield_hit': r[10:14], 'fx_armor_hit': r[14:18]})
    return rows


def parse_sounds(b):
    """SOUNDS.STR: u32 size, u16 n, n x {u16 len, name[len], u8 k, k bytes params}."""
    n = struct.unpack_from('<H', b, 4)[0]
    p, out = 6, []
    for i in range(n):
        ln = struct.unpack_from('<H', b, p)[0]; p += 2
        name = b[p:p + ln].split(b'\0')[0].decode('latin1'); p += ln
        k = b[p]; p += 1
        out.append({'id': i, 'file': name, 'params': list(b[p:p + k])}); p += k
    return out


def parse_shell_weapons(b):
    """SHELL0/GAM/WEAPONS.DAT: u16 n, n x {u16 id, u16 len, name, u16 salvage_t, u8 stock, u8 order, u8 0},
    then u16 m + m x (weapon, 100, 5) starting inventory."""
    n = struct.unpack_from('<H', b, 0)[0]
    p, out = 2, []
    for i in range(n):
        wid, ln = struct.unpack_from('<HH', b, p); p += 4
        name = b[p:p + ln].split(b'\0')[0].decode('latin1'); p += ln
        salvage, f1, f2, f3 = struct.unpack_from('<H3B', b, p); p += 5
        out.append({'id': wid, 'name': name, 'salvage_kg': salvage * 1000, 'flag': f1, 'order': f2})
    m = struct.unpack_from('<H', b, p)[0]; p += 2
    inv = [list(struct.unpack_from('<3h', b, p + 6 * k)) for k in range(m)]
    return {'weapons': out, 'starting_inventory': inv}


def default_loadout_masks():
    """Hardpoint masks each weapon occupies in the shell's default loadouts (INI_* + sim GL)."""
    herc = {'OUTL': 'OUTLAW', 'RAPT': 'RAPTOR2', 'TOMA': 'TOMAHAWK', 'SAMS': 'SAMSON', 'COLO': 'COLOSSUS',
            'APOC': 'APOCA', 'OGRE': 'OGRE', 'MAVR': 'MAVERICK', 'RAZR': 'RAZOR'}
    seen = {}
    for k, unit in herc.items():
        try:
            ini = rd(SRC, 'SHELL0', 'GAM', 'INI_%s.DAT' % k)
            gl = rd(SIM, 'GL', unit + '.GL')
        except OSError:
            continue
        w = struct.unpack_from('<%dh' % (len(ini) // 2), ini)
        ng = struct.unpack_from('<H', gl, 0)[0]
        mask = {gl[2 + 26 * i + 23]: gl[2 + 26 * i + 25] for i in range(ng)}
        for e in range(w[3]):
            slot, wpn = w[4 + 4 * e], w[5 + 4 * e]
            if slot in mask:
                seen.setdefault(wpn, set()).add(mask[slot])
    return {k: sorted(v) for k, v in seen.items()}


# --------------------------------------------------------------------------------------- tables
# per weapon index: engine name, kind, hardpoint mask (7 small / 15 medium / 31 large), mask evidence
SPEC = {
    1: ('ATC20', 'cannon', 7, 'L'), 2: ('ATC35', 'cannon', 7, 'INI'), 3: ('ATC50', 'cannon', 7, 'INI'),
    4: ('ATC75', 'cannon', 15, 'L'), 5: ('ATC100', 'cannon', 15, 'L'),
    6: ('ELF', 'beam', 7, 'INI'), 7: ('EMP', 'emp', 31, 'INI'),
    8: ('LAS100', 'beam', 7, 'L'), 9: ('LAS200', 'beam', 7, 'INI'), 10: ('LAS300', 'beam', 15, 'INI'),
    11: ('LAS400', 'beam', 15, 'L'), 12: ('LAS500', 'beam', 31, 'L'),
    13: ('MSL6', 'missile', 7, 'L'), 14: ('MSL8', 'missile', 7, 'INI'), 15: ('MSL10', 'missile', 7, 'INI'),
    16: ('FLYMSL', 'missile', 7, 'Razor GL masks are all 7/15'),
    17: ('PBEAM', 'beam', 15, 'INI'), 18: ('ECM', 'ecm', 7, 'L'),
    19: ('EMP_BULL', 'emp', 31, 'Cybrid'), 20: ('PBEAM_BULL', 'beam', 31, 'Cybrid'),
    21: ('MISSL_BULL', 'missile', 31, 'Cybrid'),
    22: ('ELF2', 'beam', 7, 'INI'), 23: ('EMP2', 'emp', 31, 'INI'), 24: ('PBW2', 'beam', 15, 'L'),
    25: ('PLAS', 'plasma', 31, 'L'), 26: ('LAEW', 'other', 31, 'L'), 27: ('MINE', 'mine', 15, 'L'),
    28: ('MAGN', 'plasma', 31, 'L'), 29: ('TARG', 'other', 7, 'L'), 30: ('SHIELD', 'other', 7, 'L'),
    31: ('TURBO', 'other', 7, 'L'), 32: ('ENERGY', 'other', 7, 'L'),
}
SIZE_OF_MASK = {7: 'light', 15: 'medium', 31: 'heavy'}
# WPN_INFO.BIN block (5 lines) per weapon index, for the description text
INFO_BLOCK = {1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 22: 6, 7: 7, 23: 8, 18: 9, 8: 10, 9: 11, 10: 12, 11: 13,
              12: 14, 13: 15, 14: 16, 15: 17, 16: 18, 17: 19, 24: 20, 25: 21, 29: 22, 30: 23, 31: 24, 32: 25}
# BEAM.DAT colour = palette index (L); used with the default world palette
BEAM_SOUND_ID = 11        # 0x40c054
BULLET_SOUND_BASE = 10    # 0x40b577: sound = 10 + BULLETS.DAT w4
ROCKET_SOUND_BASE = 10    # 0x40aaf6: sound = 10 + ROCKETS.DAT w6
HIT_SOUNDS = {'bolt': 'lsrhit2', 'bullet': 'impacts2', 'missile': 'xplmlt2', 'plasma': 'plsmahit',
              'grenade': 'explo4'}   # L: impact sounds come from the EXPLOS tables (not decoded)
WEAPON_SOUND_FILES = ['bacann4', 'laser1', 'laser3h', 'lsrhit2', 'plasma', 'plsmahit', 'missle', 'missin',
                      'xplmlt2', 'xplmlt4', 'impacts2', 'impacts3', 'impacts5', 'ricup', 'shield1', 'explo1d',
                      'explo2', 'explo3', 'explo4', 'explo5', 'explo7', 'explos1', 'explos2']


def r1(x, n=3):
    return round(float(x), n)


def build_engine(weapons, proj, bullets, rockets, beams, names, info, sounds, shell, ini_masks, palette):
    snd = {s['id']: os.path.splitext(s['file'])[0].lower() for s in sounds}

    def snd_stem(i):
        return 'sim/%s' % snd[i] if snd.get(i) else None

    out = []
    for w in weapons:
        i = w['index']
        if i not in SPEC:
            continue
        name, kind, mask, mask_ev = SPEC[i]
        cls = w['class']
        if cls == 'projectile' and kind == 'missile':
            continue   # missile racks: one entry per missile type, built below
        row = proj[w['projectile']] if 0 <= w['projectile'] < len(proj) else None
        refire = w['refire_delay'] / TIMER_PER_S                      # rof modifier 1024 = x1
        notes = []
        blk = INFO_BLOCK.get(i)
        desc = ' '.join(x for x in info[5 * blk + 3:5 * blk + 5] if x) if blk is not None else ''
        e = {
            'name': name, 'display_name': names[i].rstrip('.'),
            'source': 'WEAPONS.DAT rec %d (exe name %s, class %s via jump table 0x4100fd); PROJ.DAT row %s'
                      % (i, EXE_NAMES[i], cls, w['projectile']),
            'size_class': 'missile' if kind == 'missile' and mask == 7 else
                          ('special' if kind in ('ecm', 'other') else SIZE_OF_MASK[mask]),
            'hardpoint_mask': mask, 'kind': kind,
            'range': r1(w['range'] * MPU, 2), 'refire': r1(refire), 'burst': 1, 'burst_interval': 0.0,
            'spread_deg': 0.0, 'ammo': -1,
            'energy': {'min_charge': 0, 'per_shot': 0}, 'heat': None,
            'damage': {'shield': 0, 'armor': 0, 'splash': 0.0, 'splash_radius': 0.0},
            'effects': {'emp_shield_drain': 0, 'elf_leech': 0, 'disable_seconds': 0},
            'projectile': None, 'beam': None,
            'model': pod_model(w),
            'sounds': {}, 'cybrid_only': name.endswith('_BULL'), 'category': 'herc',
            'description': desc, 'salvage_kg': shell[i]['salvage_kg'] if i < len(shell) else None,
        }
        if mask_ev == 'INI':
            notes.append('hardpoint mask = smallest mask this weapon occupies in the shell default loadouts '
                         '(INI_*.DAT vs GL masks: %s)' % ini_masks.get(i))
        elif mask_ev != 'Cybrid':
            notes.append('hardpoint mask: %s (not in any default loadout; by analogy)' % mask_ev)
        if w['component']['hp'] == 0:
            e['model']['mount_shapes'] = []

        if cls == 'projectile' and row and row['type'] == 2:        # autocannons
            b = bullets[row['sub']]
            speed = row['speed'] * SPEED_TO_MPS
            life = b[1] * FRAME_S
            e['ammo'] = w['ammo'] // max(w['per_shot'], 1)
            e['damage'].update(shield=row['shield_damage'], armor=row['armor_damage'])
            e['projectile'] = {'speed': r1(speed, 2), 'gravity': 0.0, 'lifetime': r1(life), 'guidance': 'none',
                               'turn_rate_deg': 0.0, 'arm_delay': 0.0, 'proximity': 0.0,
                               'shape': 'es2:BULLETS_%d' % b[0], 'trail': 'none',
                               'hit_radius': r1(b[2] * MPU), 'inherits_shooter_speed': True}
            if b[6]:
                e['effects']['damage_falloff'] = 'linear to 0 over the projectile lifetime (0x40b55c/0x40b2f8)'
            e['spread_deg'] = 0.0
            e['sounds'] = {'fire': snd_stem(BULLET_SOUND_BASE + b[4]), 'hit': 'sim/' + HIT_SOUNDS['bullet']}
            notes.append('magazine %d rounds, %d rounds per trigger pull (ammo field = trigger pulls); '
                         'muzzle jitter +-%d units (%.2f m) on x/z; reach %.0f m before expiry'
                         % (w['ammo'], w['per_shot'], b[5], b[5] * MPU, speed * life))
        elif cls in ('beam', 'beam_continuous'):
            e['energy'] = {'min_charge': w['min_charge'], 'per_shot': w['per_shot'], 'capacitor': CAPACITOR,
                           'recharge_per_s': CAP_RATE / FRAME_S}
            if row['type'] == 4:                                       # hitscan bolt
                if cls == 'beam_continuous':
                    used = 1200                                        # 0x40ec89
                    e['refire'] = FRAME_S
                    notes.append('continuous: fires every frame while held (nominal 125 ms), drains %d '
                                 'capacitor per tick, damage per tick = row x 1200/1024' % w['per_shot'])
                else:
                    used = min(w['per_shot'], CAPACITOR)
                    notes.append('damage = PROJ row (%d/%d per 1024 charge) x charge used / 1024 '
                                 '(0x40eab7 used = min(per_shot, charge); 0x40bfe6 0x47dfa4)' %
                                 (row['shield_damage'], row['armor_damage']))
                bm = beams[row['sub']] if row['sub'] < len(beams) else [0, 0, 0]
                col = palette[bm[1]] if palette and 0 <= bm[1] < len(palette) else [255, 255, 255]
                e['damage'].update(shield=round(row['shield_damage'] * used / 1024),
                                   armor=round(row['armor_damage'] * used / 1024))
                e['damage_per_1024_charge'] = {'shield': row['shield_damage'], 'armor': row['armor_damage']}
                e['beam'] = {'color': [r1(c / 255.0) for c in col], 'width': r1(bm[0] * MPU),
                             'duration': FRAME_S, 'count': max(w['beams'], 1),
                             'beam_dat': bm}
                e['sounds'] = {'fire': snd_stem(BEAM_SOUND_ID), 'hit': 'sim/' + HIT_SOUNDS['bolt']}
                notes.append('BEAM.DAT[%d] = %s: width units (L) and palette colour index (L)' % (row['sub'], bm))
            else:                                                      # charged bullet (EMP/PLAS/MAGN)
                b = bullets[row['sub']]
                used = CAPACITOR if w['per_shot'] > CAPACITOR else w['per_shot']
                speed = row['speed'] * SPEED_TO_MPS
                e['damage'].update(shield=round(row['shield_damage'] * used / 1024),
                                   armor=round(row['armor_damage'] * used / 1024),
                                   splash=r1(row['splash_per1024'] / 1024.0))
                e['damage_per_1024_charge'] = {'shield': row['shield_damage'], 'armor': row['armor_damage']}
                e['projectile'] = {'speed': r1(speed, 2), 'gravity': 0.0, 'lifetime': r1(b[1] * FRAME_S),
                                   'guidance': 'none', 'turn_rate_deg': 0.0, 'arm_delay': 0.0, 'proximity': 0.0,
                                   'shape': 'es2:BULLETS_%d' % b[0], 'trail': 'glow',
                                   'hit_radius': r1(b[2] * MPU), 'inherits_shooter_speed': True}
                e['sounds'] = {'fire': snd_stem(BULLET_SOUND_BASE + b[4]),
                               'hit': 'sim/' + HIT_SOUNDS['plasma' if kind == 'plasma' else 'bolt']}
                notes.append('dumps the whole capacitor (per_shot %d): damage = row x charge/1024, value at a full '
                             '960 capacitor' % w['per_shot'])
                if kind == 'emp':
                    e['effects'].update(emp_shield_drain=e['damage']['shield'], disable_seconds=r1(6000 / TIMER_PER_S, 2))
                    notes.append('EMP-kind hit switches the target shields off for 6000 timer units = 2.93 s (0x418c4a)')
                if w['beams'] == 3:
                    e['burst'] = 3
                    notes.append('fires 3 bolts: centre + mirrored muzzle x %d (0x40eb24)' % w['muzzle_x'])
                if w['projectile'] == 19:
                    e['burst'], e['burst_interval'] = 2, r1(refire / 4)
                    notes.append('twin burst: second shot after refire/4 (0x40ec03)')
                if kind == 'plasma':
                    e['projectile'].update(guidance='arh', turn_rate_deg=r1(0x280 * 8 * ANGLE_DEG, 2),
                                           proximity=r1(2000 * MPU, 2))
                    e['damage'].update(splash_radius=r1(4000 * MPU, 2))
                    notes.append('homes on the shooter\'s target (0x40b5cb) at 0x280/125 ms; detonates when it '
                                 'passes within 2000 u, blast radius 4000 u hits every unit (0x40b345..0x40b3f8)')
                if i == 25:
                    notes.append('PLAS capacitor charges at half efficiency (draws 2x energy, 0x40f045)')
                if i == 28:
                    notes.append('MAGN re-uses the plasma projectile row 22; range 35000 u; ammo field 20 unused')
        elif cls == 'ecm':
            e['effects']['missile_jam_deg'] = r1(0xC00 * ANGLE_DEG, 2)
            notes.append('passive: radar-homing missiles (SARH/ARH/EO, not ARM) aimed at an ECM unit are '
                         'deflected by +-0xc00 (16.9 deg) (0x40a3ab..0x40a41a)')
        elif cls == 'locust':
            row = proj[9]
            e['energy'] = {'min_charge': 20000, 'per_shot': 0}
            e['damage'].update(shield=row['shield_damage'], armor=row['armor_damage'],
                               splash=r1(row['splash_per1024'] / 1024.0), splash_radius=r1(500 * MPU, 2))
            e['projectile'] = {'speed': r1(row['speed'] * SPEED_TO_MPS, 2), 'gravity': 9.8, 'lifetime': 5.0,
                               'guidance': 'none', 'turn_rate_deg': 0.0, 'arm_delay': 0.0, 'proximity': 0.0,
                               'shape': None, 'trail': 'smoke'}
            e['ammo'] = 10
            e['range'] = r1(e['projectile']['speed'] * e['projectile']['lifetime'], 2)
            notes.append('Locust AEW launcher: class 6 (0x41027c) charges while the trigger is held (start 20000, '
                         '+1000 per update, cap 100000, 0x40e71c) but its launch routine 0x40acac is an empty stub '
                         'in DBSIM 1.0 and WEAPONS.DAT record 26 is blank. Projectile values are a guess from the '
                         'unused grenade row 9 (type 3 sub 2); gravity/lifetime/ammo invented')
        elif cls == 'none' and i == 27:
            row = proj[8]
            e['damage'].update(shield=row['shield_damage'], armor=row['armor_damage'],
                               splash=r1(row['splash_per1024'] / 1024.0), splash_radius=r1(2000 * MPU, 2))
            e['refire'] = r1(3000 / TIMER_PER_S)
            e['ammo'] = 10
            e['projectile'] = {'speed': 0.0, 'gravity': 9.8, 'lifetime': 120.0, 'guidance': 'none',
                               'turn_rate_deg': 0.0, 'arm_delay': 2.0, 'proximity': r1(2000 * MPU, 2),
                               'shape': None, 'trail': 'none'}
            notes.append('Mine launcher: no gun class in DBSIM 1.0 (jump table entry 0) and WEAPONS.DAT record 27 '
                         'is blank. Damage from the unused grenade row 8 (type 3 sub 1); 10 rounds from the shell '
                         'text; refire (ES1 GREN 3000), arm delay, proximity and lifetime invented')
        elif cls.endswith('_pod'):
            pod = {'targeting_pod': {'ecm_counter': True}, 'shield_pod': {'shield_multiplier': 2.0},
                   'turbo_pod': {'speed_burst': True}, 'energy_pod': {'energy_bonus': True}}[cls]
            e['effects'].update(pod)
            notes.append('passive equipment (%s ctor); effect taken from the shell text, not reversed' % cls)
        e['notes'] = '; '.join(notes)
        out.append(e)

    # missile racks: one entry per loadout missile type (row = (type 0, sub = type))
    rows_by_sub = {r['sub']: r for r in proj if r['type'] == 0}
    racks = []
    for w in weapons:
        i = w['index']
        if w['class'] != 'projectile' or i not in SPEC or SPEC[i][1] != 'missile':
            continue
        name, kind, mask, mask_ev = SPEC[i]
        subs = [(None, 'cybrid', 4)] if w['projectile'] != 34 else [(a, g, k) for k, (a, g) in enumerate(MISSILE_SUBS)]
        for abbr, guid, sub in subs:
            row = rows_by_sub[sub]
            rk = rockets[sub]
            vmax = row['speed'] * SPEED_TO_MPS
            e = {
                'name': name if abbr is None else '%s_%s' % (name, abbr),
                'display_name': names[i] if abbr is None else '%s (%s)' % (names[i], abbr),
                'source': 'WEAPONS.DAT rec %d (exe name %s); PROJ.DAT row %d (type 0 sub %d); ROCKETS.DAT[%d]'
                          % (i, EXE_NAMES[i], row['index'], sub, sub),
                'size_class': 'missile' if mask == 7 else 'heavy', 'hardpoint_mask': mask, 'kind': 'missile',
                'range': r1(w['range'] * MPU, 2), 'refire': r1(w['refire_delay'] / TIMER_PER_S), 'burst': 1,
                'burst_interval': 0.0, 'spread_deg': 0.0, 'ammo': w['ammo'] // max(w['per_shot'], 1),
                'energy': {'min_charge': 0, 'per_shot': 0}, 'heat': None,
                'damage': {'shield': row['shield_damage'], 'armor': row['armor_damage'],
                           'splash': r1(row['splash_per1024'] / 1024.0), 'splash_radius': r1(500 * MPU, 2)},
                'effects': {'emp_shield_drain': 0, 'elf_leech': 0, 'disable_seconds': 0},
                'projectile': {'speed': r1(vmax, 2), 'gravity': 0.0, 'lifetime': r1(rk[1] * FRAME_S, 2),
                               'guidance': 'arh' if guid == 'cybrid' else guid,
                               'turn_rate_deg': r1(0x500 * 8 * ANGLE_DEG, 2), 'arm_delay': 0.0, 'proximity': 0.0,
                               'shape': 'es2:ROCKETS_%d' % rk[0], 'trail': 'smoke',
                               'accel': r1(rk[2] * 4 * SPEED_TO_MPS, 2), 'ecm_immune': guid == 'arm'},
                'beam': None,
                'model': pod_model(w),
                'sounds': {'fire': snd_stem(ROCKET_SOUND_BASE + rk[6]), 'hit': 'sim/' + HIT_SOUNDS['missile'],
                           'incoming': snd_stem(0x32)},
                'cybrid_only': name.endswith('_BULL'), 'category': 'herc',
                'salvage_kg': shell[i]['salvage_kg'] if i < len(shell) else None,
                'notes': ('rack holds %d missiles of the type chosen at loadout (sub 5 -> 0, 0x4100aa); all four '
                          'types share one PROJ row set (400/1600, splash 500/1024) although the shell quotes '
                          'warheads 3000/2250/2500/3500 and ranges 510/420/420/360 m. Speed ramps by ROCKETS w2=%d '
                          'per 125 ms (averaged, 0x40a5f0) up to PROJ speed %d; lifetime %d frames (0x40a5d7, '
                          'nominal 125 ms); turn <= 0x500 per 125 ms. splash_radius = ES1 component splash radius '
                          '500 u (not re-verified in ES2).' % (w['ammo'], rk[2], row['speed'], rk[1]))
                         + (' EO: the target is flagged as EO-tracked and the player can steer the missile '
                            '(0x40a636 -> 0x40a488).' if guid == 'eo' else '')
                         + (' ARM ignores ECM jamming (0x40a3ab).' if guid == 'arm' else ''),
            }
            racks.append(e)
    return out + racks


# -------------------------------------------------------------------------------------- exports
def export_shapes():
    import dts, export_es1, export_es2
    sets = {'MECHWPNS': 'WPNTEX', 'MECHWPN2': 'WPNTEX', 'BULLETS': 'BULLETS', 'ROCKETS': None}
    os.makedirs(os.path.join(OUT, 'shapes'), exist_ok=True)
    count = 0
    for lib, ts in sets.items():
        objs = dts.read_file(rd(SIM, 'DTS', lib + '.DTS'))
        for i, o in enumerate(objs):
            j = export_es1.shape_to_json([o], '%s_%d' % (lib, i))
            j['texset'] = ts
            export_es2.write_json(os.path.join(OUT, 'shapes', '%s_%d.json' % (lib, i)), j)
            count += 1
    export_es2.export_palettes()
    for ts in sorted({t for t in sets.values() if t}):
        export_es2.export_texture_set(ts)
    return count


def export_sounds():
    d = os.path.join(OUT, 'audio', 'sfx', 'sim')
    os.makedirs(d, exist_ok=True)
    n = 0
    for stem in WEAPON_SOUND_FILES:
        for sub in ('HMI', 'HMX'):
            src = os.path.join(SRC, 'SIMSOUND', sub, stem.upper() + '.WAV')
            if os.path.exists(src):
                b = open(src, 'rb').read()
                fmt = struct.unpack_from('<HHIIHH', b, 20)
                assert b[:4] == b'RIFF' and b[8:12] == b'WAVE' and fmt[0] == 1, (src, fmt)   # plain PCM
                shutil.copyfile(src, os.path.join(d, stem + '.wav'))
                n += 1
                break
    return n


def pod_model(w):
    """Weapon pod placement (docs/formats/weapon_mounts.md section 1): pod shape per GL mount group
    (0x40fab0: MECHWPNS index = record +0x22 + 2*group), the pod half extent (+0x46/+0x48/+0x4a; 0x40f904 and
    its jump table 0x40f946 push the pod out by it per mount group, y = 0) and the muzzle in the pod frame
    (+0x40..0x44, 0x40e8cc), original units."""
    return {'mount_shapes': ['es2:MECHWPNS_%d' % w['shape_group%d' % g] for g in range(4)],
            'pod_extent': [w['unknown_46'], w['unknown_48'], w['unknown_4a']],
            'muzzle_units': [w['muzzle_x'], w['muzzle_y'], w['muzzle_z']]}


def main():
    class_table, verified = verify_exe()
    if class_table is None:
        class_table = CLASS_TABLE_FALLBACK
    names = strtab(rd(SRC, 'LANG0', 'ENG', 'WEAPONS.BIN'))
    desc = strtab(rd(SRC, 'LANG0', 'ENG', 'WPN_DESC.BIN'))
    info = strtab(rd(SRC, 'LANG0', 'ENG', 'WPN_INFO.BIN'))
    weapons = parse_weapons(rd(SIM, 'DAT', 'WEAPONS.DAT'))
    for w in weapons:
        w['exe_name'] = EXE_NAMES[w['index']]
        w['display_name'] = names[w['index']]
        w['class'] = CLASS_CASES[class_table[w['index']]]
    proj = parse_proj(rd(SIM, 'DAT', 'PROJ.DAT'))
    bullets = parse_counted(rd(SIM, 'DAT', 'BULLETS.DAT'), 7)
    rockets = parse_counted(rd(SIM, 'DAT', 'ROCKETS.DAT'), 7)
    beams = parse_counted(rd(SIM, 'DAT', 'BEAM.DAT'), 3)
    lc = rd(SIM, 'DAT', 'LC_WPNS.DAT')
    sounds = parse_sounds(rd(SIM, 'STR', 'SOUNDS.STR'))
    shell = parse_shell_weapons(rd(SRC, 'SHELL0', 'GAM', 'WEAPONS.DAT'))
    ini_masks = default_loadout_masks()
    pal_path = os.path.join(OUT, 'palettes', 'WORLD0.json')
    palette = json.load(open(pal_path)) if os.path.exists(pal_path) else None

    gp = os.path.join(OUT, 'gameplay')
    os.makedirs(gp, exist_ok=True)
    raw = {
        'source': 'es2/extracted (see tools/export_es2_weapons.py docstring); ' + verified,
        'weapon_fields': {'range': 'u32 units (1/256 m)', 'refire_delay': 'timer units, 2048/s',
                          'per_shot': 'beam: capacitor per shot; gun: rounds per shot',
                          'projectile': 'PROJ row; 33 = none (ECM), 34 = missile rack (row = type 0, sub = '
                                        'loadout missile type)', 'class': 'GunList ctor via jump table 0x4100fd'},
        'weapons': weapons,
        'projectiles': proj,
        'bullets': [dict(zip(('shape', 'lifetime_ticks', 'hit_size', 'trail_interval', 'sound_minus_10',
                              'muzzle_jitter', 'damage_falloff'), r)) for r in bullets],
        'rockets': [dict(zip(('shape', 'lifetime_frames', 'accel', 'w3', 'w4', 'w5', 'sound_minus_10'), r))
                    for r in rockets],
        'beams': [dict(zip(('width', 'palette_colour', 'w2'), r)) for r in beams],
        'lc_wpns_words': list(struct.unpack_from('<%dh' % (len(lc) // 2), lc)),
        'sounds': sounds,
        'shell_weapons': shell,
        'default_loadout_masks': {str(k): v for k, v in ini_masks.items()},
        'texts': {'WEAPONS.BIN': names, 'WPN_DESC.BIN': desc, 'WPN_INFO.BIN': info},
        'time_base': {'frame_s': FRAME_S, 'timer_units_per_s': TIMER_PER_S, 'metres_per_unit': MPU,
                      'speed_to_mps': SPEED_TO_MPS, 'evidence': {hex(k): v[1] for k, v in EVIDENCE.items()}},
    }
    with open(os.path.join(gp, 'weapons_raw.json'), 'w') as f:
        json.dump(raw, f, indent=1)

    eng_weapons = build_engine(weapons, proj, bullets, rockets, beams, names, info, sounds,
                               shell['weapons'], ini_masks, palette)
    eng = {
        'pack': 'es2',
        'damage_scale_note': 'Earthsiege damage scale, unchanged: PROJ.DAT rows of the weapons shared with ES1 are '
                             'identical (ATC20 60/360, LAS100 1500/600, EMP 2000/400, PBEAM 1000/1000, missiles '
                             '400/1600) and Herc shields are still 3500 (unit DAT +0xbe). Capacitor weapons scale the '
                             'row by the charge spent / 1024 (beam 0x40bfe6, charged bullet 0x40b28c); the damage '
                             'values here are per shot at full charge, the raw rows are in damage_per_1024_charge.',
        'units_note': 'distances 1/256 m (shell texts read 1/166.7 m: ATC20 75000 u = 293 m here, "450 m" in the '
                      'shell); speeds = units per 125 ms x 8/256; timers 2048/s; ' + verified,
        'weapons': eng_weapons,
    }
    with open(os.path.join(gp, 'weapons_engine.json'), 'w') as f:
        json.dump(eng, f, indent=1)

    pj = os.path.join(OUT, 'pack.json')
    if not os.path.exists(pj):
        with open(pj, 'w') as f:
            json.dump({'name': 'Earthsiege 2', 'default_palette': 'WORLD0'}, f)

    nshapes = export_shapes()
    nsnd = export_sounds()
    sanity(eng_weapons)
    print('es2 weapons: %d engine entries, %d raw records, %d shapes, %d sounds; %s'
          % (len(eng_weapons), len(weapons), nshapes, nsnd, verified))


def sanity(ws):
    by = {w['name']: w for w in ws}
    lasers = [by['LAS%d' % k] for k in (100, 200, 300, 400, 500)]
    atcs = [by['ATC%d' % k] for k in (20, 35, 50, 75, 100)]
    tot = lambda w: w['damage']['shield'] + w['damage']['armor']
    assert all(a['damage']['shield'] <= b['damage']['shield'] and tot(a) < tot(b)
               for a, b in zip(lasers, lasers[1:])), 'laser order'   # LAS400/500 share shield 3000
    assert all(a['range'] > b['range'] for a, b in zip(lasers, lasers[1:])), 'laser range order'
    assert all(a['damage']['armor'] < b['damage']['armor'] for a, b in zip(atcs, atcs[1:])), 'ATC order'
    assert all(a['range'] > b['range'] for a, b in zip(atcs, atcs[1:])), 'ATC range order'
    assert by['ELF2']['damage']['shield'] > by['ELF']['damage']['shield']
    assert by['PBW2']['damage']['shield'] > by['PBEAM']['damage']['shield']
    for w in ws:
        for k in ('fire', 'hit'):
            s = w['sounds'].get(k)
            if s:
                assert os.path.exists(os.path.join(OUT, 'audio', 'sfx', s + '.wav')), s
        for s in w['model'].get('mount_shapes', []) + [(w['projectile'] or {}).get('shape')]:
            if s:
                assert os.path.exists(os.path.join(OUT, 'shapes', s.split(':')[1] + '.json')), s
    for w in sorted(ws, key=lambda x: x['name']):
        p = w['projectile'] or {}
        print('  %-14s %-8s %-7s mask %2d rng %5.0f m refire %5.2f s ammo %4d dmg %5d/%-5d spd %6.1f %s'
              % (w['name'], w['kind'], w['size_class'], w['hardpoint_mask'], w['range'], w['refire'], w['ammo'],
                 w['damage']['shield'], w['damage']['armor'], p.get('speed', 0.0), p.get('guidance', '')))


if __name__ == '__main__':
    main()
