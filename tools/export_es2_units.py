"""Earthsiege 2 units -> engine catalog (gamedata/es2/): Hercs, Cybrids, flyers, bases, formations.

    python tools/export_es2_units.py [--no-shapes]

Writes (schema = the Earthsiege 1 pack, see tools/units.py, tools/units_calib.py, game/engine/packs.gd):
  gameplay/hercs.json       21 MECHS.NAM units + SKIMMER, keyed by file name (vehicle id "es2:<NAME>"):
                            unit DAT fields (ES1 names), guns (GL), damage (DMG), collision (COL), per-unit
                            "loadout" (es2 weapon ids), "flyer": true for RAZOR / SKIMMER
  gameplay/bases.json       BASES.DAT (65 structure types; ES1-compatible rows + decoded records)
  gameplay/formations.json  MFORMS / FFORMS / BFORMS (ES1 schema + ES2 extras)
  units.json                existing keys kept; code-derived conversions (125 ms time base) + hercs[]
  shapes/<UNIT>.json        every unit DTS (all LODs), texture set from the unit DAT (code-verified)
  shapes/<XXXX_DEB>_<i>     debris pieces (one shape per DTS object)
  shapes/BASES_<i>          BASES.DGS objects 0..44, BASES_AN.DTS objects -> BASES_45..52 (+ texset variants)
  shapes/BHULKS_<i>         destroyed-base hulks
  textures/<SET>/...        LIGHT MEDIUM HEAVY ENEMY APOCATEX RAZORTEX NEWHERCS BASETEX VEHTEX
  cockpits/<HERC>_<k>.png   DB0/DB1/DB2 overlays + <HERC>.json views (as export_es1.export_cockpits)

Code evidence (DBSIM.EXE VAs, image base 0x400000; checked by verify_exe when the exe is present):
  texture sets   0x41fe8f table 0x49a360 = light medium heavy enemy apocatex razortex newhercs, loaded into
                 0x4a9df6[8*i]; a Herc/Cybrid shape (and its debris, DAT+0xcc) uses entry [DAT+0x94]
                 (0x420467 / 0x4203d6). Flyers (flyersys 0x422f38) use entry 3 = ENEMY.
                 Bases (base.cpp 0x405ebc): BASES.DAT rec +6 != 0 -> BASES_AN.DTS object [+2], else
                 BASES.DGS object [+2]; texset VEHTEX if rec +0x32 != 0 (type 52 -> RAZORTEX), else BASETEX;
                 BHULKS.DGS uses BASETEX; DEF_DEB/BASE_DEB load without a texture set.
  movement       same model as ES1 (docs/formats/units.md section 2): anim rate = speed (min 60, 0x416e97),
                 walk seq DAT+0x0c, run seq DAT+0x0e above DAT+0x2c (0x416fb3), anim advanced by
                 scale(100) per frame (0x418f5e) = 100 anim ticks per 125 ms -> 1 tick = 1.25 ms at rate 256.
                 speed approach by DAT+6 per frame, unscaled (0x416c82 -> 0x4679d8).
  yaw rate       ES1 speed curve x 1600/1024 (0x417427), per frame unscaled -> angle units per 125 ms.
  torso rates    DAT+0x1c / +0x24 scaled by the frame scale (0x41a5e8, 0x41a8a0) -> per 125 ms.
  shields        recharge <= 5 points per update (0x413b52; ES1 4), capacitor +20 per update (0x40e0cc).
"""
import glob, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
import self_destruct_rules  # noqa: E402
import dts, gfx, export_es1, units, units_calib  # noqa: E402
from export_es2_weapons import PE, SPEC, strtab  # noqa: E402

SRC = P.work('es2', 'extracted')
SIM = os.path.join(SRC, 'SIMVOL0')
GAM = os.path.join(SRC, 'SHELL0', 'GAM')
EXE = P.work('es2', 'original', 'DBSIM.EXE')
OUT = P.pack('es2')

MPU = 1.0 / 256.0                 # world metres per unit (packs.gd WORLD_SCALE es2; manual heights)
DESIGNER_MPU = 0.006              # scale of the manual's km/h and the shell's weapon ranges (as ES1 readouts)
FRAME_S = 0.125                   # nominal frame = "per 256 frame scale" period
TIMER_PER_S = 2048.0
ANIM_TICK_S = FRAME_S / 100.0     # scale(100) anim ticks per frame (0x418f5e) -> 1.25 ms per tick at rate 256
YAW_SCALE = 1600.0 / 1024.0       # 0x417427
ANGLE = 2 * 3.141592653589793 / 65536.0
ANGLE_DEG = 360.0 / 65536.0

MECHS = ['OUTLAW', 'RAPTOR2', 'TOMAHAWK', 'SAMSON', 'COLOSSUS', 'APOCA', 'OGRE', 'MAVERICK', 'RAZOR',
         'MONGOOSE', 'STINGRAY', 'MIRIMAC', 'RAMSES', 'ACHILLES', 'HYPERION', 'PITBULL', 'SPIDER',
         'DIABLO', 'HEADHUNT', 'SCARAB', 'CERBERUS']          # NAM/MECHS.NAM order = mission herc type
PILOTABLE = MECHS[:9]                                         # have cockpits / shell INI_* loadouts
FLYERS = ['RAZOR', 'SKIMMER']
TEXSETS = ['LIGHT', 'MEDIUM', 'HEAVY', 'ENEMY', 'APOCATEX', 'RAZORTEX', 'NEWHERCS']   # exe table 0x49a360
INI = {'OUTLAW': 'OUTL', 'RAPTOR2': 'RAPT', 'TOMAHAWK': 'TOMA', 'SAMSON': 'SAMS', 'COLOSSUS': 'COLO',
       'APOCA': 'APOC', 'OGRE': 'OGRE', 'MAVERICK': 'MAVR', 'RAZOR': 'RAZR'}
N_BASES_DGS = 45                  # BASES.DGS objects; BASES_AN.DTS object k is exported as BASES_<45+k>

EVIDENCE = {
    0x41FE8F: ('be60a34900', 'texture set name table 0x49a360 (7 entries)'),
    0x420467: ('0fbf9796000000', 'mech texture set = table[DAT+0x94]'),
    0x422F38: ('c747260e9e4a00', 'flyer texture set = table entry 3 (enemy)'),
    0x405ED7: ('66837b0600', 'base rec +6 != 0 -> animated shape (BASES_AN)'),
    0x405F1E: ('66837b3200', 'base rec +0x32 != 0 -> vehtex'),
    0x405F7E: ('66837d0834', 'base type 52 -> razortex'),
    0x418F5E: ('6a64', 'animation advanced by scale(100) per frame'),
    0x416E97: ('66837d963c', 'walk animation rate >= 60'),
    0x416FB3: ('663b562c', 'run sequence above DAT+0x2c'),
    0x416C82: ('e8510d0500', 'speed approach (unscaled, per frame)'),
    0x417427: ('6840060000', 'yaw rate x 1600/1024'),
    0x41A5E8: ('e833d20400', 'torso yaw rate scaled per 125 ms'),
    0x41A8A0: ('e87bcf0400', 'torso pitch rate scaled per 125 ms'),
    0x413B52: ('66837d0c05', 'shield recharge <= 5 per update'),
}

# Mech components keep the ES1 names (units.component_name; game code keys leg damage on QUAD/SHIN/FOOT;
# 13..18 are the rear legs of PITBULL / SPIDER). Flyer body parts:
FLYER_BODY = {0: 'COCKPIT', 4: 'LEFT_NACELLE', 5: 'RIGHT_NACELLE', 6: 'FUSELAGE', 7: 'LEFT_WING',
              8: 'RIGHT_WING'}       # STRINGS0 group 14


def rd(*p):
    with open(os.path.join(*p), 'rb') as f:
        return f.read()


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent, separators=None if indent else (',', ':'))


def verify_exe():
    if not os.path.exists(EXE):
        return 'DBSIM.EXE missing: constants not re-verified'
    pe = PE(EXE)
    bad = ['%x' % va for va, (hx, _) in EVIDENCE.items() if pe.at(va, len(hx) // 2).hex() != hx]
    if bad:
        raise SystemExit('DBSIM.EXE build differs at %s - re-check tools/export_es2_units.py' % bad)
    names = pe.at(0x49A437, 54).split(b'\0')[:7]
    assert [n.decode().upper() for n in names] == TEXSETS, names
    return 'verified %d code sites in es2/original/DBSIM.EXE' % len(EVIDENCE)


def strings0():
    import cockpit
    return cockpit.read_strings0(rd(SIM, 'STR', 'STRINGS0.STR'))


# ------------------------------------------------------------------------------------------- units
ES2_EXTRA = [   # ES2 216-byte DAT: fields beyond the ES1 192-byte table (offset, name)
    (0x4e, 'flyer_flag'), (0x50, 'herc_type_shell'), (0xc0, 'unknown_c0'), (0xc2, 'unknown_c2'),
    (0xc4, 'unknown_c4')]


def parse_dat(name):
    b = rd(SIM, 'DAT', name + '.DAT')
    assert len(b) == 216, (name, len(b))
    r = units.parse_unit_dat(b[:192])
    r['raw_words'] = list(struct.unpack('<108h', b))
    r['texture_set_index'] = r.pop('size_class')       # ES2: DAT+0x94 indexes the texture set table
    r['texture_set'] = TEXSETS[r['texture_set_index']]
    for off, nm in ES2_EXTRA:
        r[nm] = struct.unpack_from('<h', b, off)[0]
    r['debris'] = b[0xcc:0xd8].split(b'\0')[0].decode('latin1').upper() or None
    return r


def herc_info():
    """SHELL0/GAM/HERC_INF.DAT: u16 n, n x 8 words (type, tons, shell km/h, hardpoints, salvage, ?,
    weight class 1..3, ?)."""
    b = rd(GAM, 'HERC_INF.DAT')
    w = struct.unpack('<%dh' % (len(b) // 2), b)
    out = {}
    for i in range(w[0]):
        r = w[1 + 8 * i:9 + 8 * i]
        out[MECHS[r[0]]] = {'tons': r[1], 'shell_kmh': r[2], 'hardpoints': r[3], 'salvage': r[4],
                            'unknown_5': r[5], 'weight_class': r[6], 'unknown_7': r[7]}
    return out


def weapon_name(idx, missile_type=5):
    """WEAPONS.DAT index -> engine weapon name (gamedata/es2/gameplay/weapons_engine.json)."""
    if idx not in SPEC:
        return None
    nm, kind = SPEC[idx][0], SPEC[idx][1]
    if kind == 'missile' and not nm.endswith('_BULL'):
        mt = ['SARH', 'ARH', 'ARM', 'EO'][missile_type if 0 <= missile_type < 4 else 0]  # 5 -> 0 (0x4100aa)
        nm = '%s_%s' % (nm, mt)
    return nm


def ini_loadout(unit, guns):
    """SHELL0/GAM/INI_*.DAT: herc type, 100, 0, n, n x (loadout slot, weapon index, 100, missile type)."""
    b = rd(GAM, 'INI_%s.DAT' % INI[unit])
    w = struct.unpack('<%dh' % (len(b) // 2), b)
    by_slot = {w[4 + 4 * e]: weapon_name(w[5 + 4 * e], w[7 + 4 * e]) for e in range(w[3])}
    return [by_slot.get(g['loadout_slot']) for g in guns]


# Cybrid default loadouts are not in the data (missions arm every unit); chosen per weight and hardpoint
# mask from the ES2 arsenal (L).
CYBRID_PICKS = {
    'light': {31: ['LAS300'], 15: ['LAS200'], 7: ['ATC35']},
    'medium': {31: ['PBEAM'], 15: ['LAS300'], 7: ['MSL6_ARH']},
    'heavy': {31: ['PLAS', 'LAS400'], 15: ['PBW2'], 7: ['MSL8_ARH']},
}


def cybrid_loadout(d, guns, wmask):
    cls = 'light' if d['mass'] <= 6000 else ('medium' if d['mass'] <= 8000 else 'heavy')
    out, k = [], {}
    for g in guns:
        m = g['hardpoint_mask']
        opts = CYBRID_PICKS[cls].get(m) or CYBRID_PICKS[cls][7]
        i = k.get(m, 0)
        k[m] = i + 1
        nm = opts[i % len(opts)]
        if wmask.get(nm, 99) > m:
            nm = 'LAS100'
        out.append(nm)
    return out


def components(dm, flyer):
    out = []
    for c in dm['components']:
        i = c['index']
        if flyer and i < units.FIRST_WEAPON_COMPONENT:
            c['name'] = FLYER_BODY.get(i, 'PART_%d' % i)
        else:
            c['name'] = units.component_name(i)
        out.append(c)
    dm['components'] = out
    dm['system_names'] = units.SYSTEMS
    return dm


def load_units(wmask):
    info = herc_info()
    res = {}
    for n in MECHS:
        d = {'file': n, 'side': 'herc' if n in PILOTABLE else 'cybrid'}
        d.update(parse_dat(n))
        d['guns'] = units.parse_gl(rd(SIM, 'GL', n + '.GL'))
        d['damage'] = components(units.parse_dmg(rd(SIM, 'DMG', n + '.DMG')), n == 'RAZOR')
        d['collision'] = units.parse_col(rd(SIM, 'COL', n + '.COL'))
        if n in info:
            d['shell_info'] = info[n]
            d['size_class'] = info[n]['weight_class'] - 1
        else:
            d['size_class'] = 3
        if n in PILOTABLE:
            d['loadout'] = ini_loadout(n, d['guns'])
            d['loadout_source'] = 'SHELL0/GAM/INI_%s.DAT (shell default loadout, missile type 5 -> SARH)' % INI[n]
        else:
            d['loadout'] = cybrid_loadout(d, d['guns'], wmask)
            d['loadout_source'] = 'chosen by weight/hardpoint mask (missions arm Cybrids individually)'
        d['shield_recharge_per_frame'] = 5
        if n == 'RAZOR':
            d['flyer'] = True
            d['flight_model'] = list(struct.unpack('<27h', rd(SIM, 'FM', 'RAZOR.FM')))
        res[n] = d
    # SKIMMER: 46-byte flyer DAT (ES1 34 bytes + name), FM flight model, DMG/COL, no GL
    w = list(struct.unpack('<23h', rd(SIM, 'DAT', 'SKIMMER.DAT')))
    sk = {'file': 'SKIMMER', 'name': 'Landskimmer', 'side': 'cybrid', 'flyer': True, 'size_class': 3,
          'texture_set': 'ENEMY', 'mass': 5000, 'shield_max': 0, 'guns': [],
          'flyer_fields': dict(zip(units.FLYER_FIELDS, w[:9])), 'raw_words': w,
          'cruise_mps': round(w[2] * MPU / FRAME_S, 2),
          'flight_model': list(struct.unpack('<27h', rd(SIM, 'FM', 'SKIMMER.FM'))),
          'damage': components(units.parse_dmg(rd(SIM, 'DMG', 'SKIMMER.DMG')), True),
          'collision': units.parse_col(rd(SIM, 'COL', 'SKIMMER.COL')),
          'loadout': ['LAS200'], 'loadout_source': 'guess (flyer weapons are not in the unit data)'}
    res['SKIMMER'] = sk
    self_destruct_rules.apply_to_units(res, 'es2')
    return res


# ------------------------------------------------------------------------------------------ bases
def parse_bases():
    """BASES.DAT (base.cpp 0x405fac): u16 n, n x variable records read into 0x3c-byte structs."""
    b = rd(SIM, 'DAT', 'BASES.DAT')
    n = struct.unpack_from('<H', b, 0)[0]
    p, recs = 2, []
    for i in range(n):
        h = struct.unpack_from('<5h', b, p); p += 10
        a = struct.unpack_from('<3h', b, p); p += 6
        w10, nc = struct.unpack_from('<2h', b, p); p += 4
        comps = [list(struct.unpack_from('<15h', b, p + 30 * k)) for k in range(nc)]; p += 30 * nc
        c = struct.unpack_from('<3h', b, p); p += 6
        w1e = struct.unpack_from('<h', b, p)[0]; p += 2
        w20 = struct.unpack_from('<2h', b, p); p += 4
        t = struct.unpack_from('<8h', b, p); p += 16
        recs.append({'type': i, 'category': h[0], 'shape_index': h[1], 'hulk': h[2], 'animated': h[3],
                     'w8': h[4], 'w0a': list(a), 'w10': w10,
                     'components': [{'hp': r[0], 'part': r[1], 'raw': r} for r in comps],
                     'centre': list(c), 'w1e': w1e, 'w20': list(w20), 'tail': list(t),
                     'name_index': t[2], 'vehicle_texset': t[7]})
    assert p == len(b), (p, len(b))
    return recs


def base_texset(r):
    if r['vehicle_texset']:
        return 'RAZORTEX' if r['type'] == 0x34 else 'VEHTEX'
    return 'BASETEX'


# ----------------------------------------------------------------------------------------- shapes
def export_shape(objs, name, texset):
    j = export_es1.shape_to_json(objs, name)
    j['texset'] = texset
    write_json(os.path.join(OUT, 'shapes', name + '.json'), j)
    return j


def export_shapes(res, recs):
    made = []
    for n in MECHS + ['SKIMMER']:
        ts = res[n]['texture_set']
        export_shape(dts.read_file(rd(SIM, 'DTS', n + '.DTS')), n, ts)
        made.append(n)
        deb = res[n].get('debris')
        if deb and os.path.exists(os.path.join(SIM, 'DTS', deb + '.DTS')):
            for i, o in enumerate(dts.read_file(rd(SIM, 'DTS', deb + '.DTS'))):
                export_shape([o], '%s_%d' % (deb, i), ts)
                made.append('%s_%d' % (deb, i))
    for deb in ('DEF_DEB', 'BASE_DEB'):
        for i, o in enumerate(dts.read_file(rd(SIM, 'DTS', deb + '.DTS'))):
            export_shape([o], '%s_%d' % (deb, i), None)
            made.append('%s_%d' % (deb, i))
    for i, o in enumerate(dts.read_file(rd(SIM, 'DGS', 'BHULKS.DGS'))):
        export_shape([o], 'BHULKS_%d' % i, 'BASETEX')
        made.append('BHULKS_%d' % i)
    # base shapes: unified index (DGS 0..44, BASES_AN k -> 45+k); a shape used with two texture sets
    # gets an extra index for the second set (only if it has textured polygons)
    dgs = dts.read_file(rd(SIM, 'DGS', 'BASES.DGS'))
    an = dts.read_file(rd(SIM, 'DTS', 'BASES_AN.DTS'))
    assert len(dgs) == N_BASES_DGS, len(dgs)
    src = {i: ('BASES.DGS', i, [o]) for i, o in enumerate(dgs)}
    src.update({N_BASES_DGS + k: ('BASES_AN.DTS', k, [o]) for k, o in enumerate(an)})
    first_ts, variants, nxt = {}, {}, N_BASES_DGS + len(an)
    for r in recs:
        u = r['shape_index'] + (N_BASES_DGS if r['animated'] else 0)
        ts = base_texset(r)
        if first_ts.setdefault(u, ts) == ts:
            r['shape_unified'] = u
            continue
        has_tex = any(q['m']['kind'] == 'tex' for lod in export_es1.shape_to_json(src[u][2], 'x')['lods']
                      for pc in lod['pieces'] for q in pc['polys'])
        if not has_tex:
            r['shape_unified'] = u
            continue
        if (u, ts) not in variants:
            variants[(u, ts)] = nxt
            src[nxt] = src[u]
            first_ts[nxt] = ts
            nxt += 1
        r['shape_unified'] = variants[(u, ts)]
    for u, (f, k, objs) in sorted(src.items()):
        export_shape(objs, 'BASES_%d' % u, first_ts.get(u, 'BASETEX'))
        made.append('BASES_%d' % u)
    return made, {u: '%s[%d]' % (f, k) for u, (f, k, _) in src.items()}


def export_textures(sets):
    import export_es2
    export_es2.export_palettes()
    for s in sorted(sets):
        export_es2.export_texture_set(s)


def write_shape_index():
    d = os.path.join(OUT, 'shapes')
    idx = []
    for f in sorted(glob.glob(os.path.join(d, '*.json'))):
        nm = os.path.splitext(os.path.basename(f))[0]
        if nm.startswith('_'):
            continue
        idx.append({'name': nm, 'kind': 'dgs' if nm.startswith(('BASES_', 'BHULKS_')) else 'dts'})
    write_json(os.path.join(d, '_index.json'), idx)


def export_cockpits():
    pal = gfx.read_dpl(rd(SIM, 'DPL', 'COCKPIT.DPL'))
    d = os.path.join(OUT, 'cockpits')
    os.makedirs(d, exist_ok=True)
    n = 0
    for f in sorted(glob.glob(os.path.join(SIM, 'VUE', '*.VUE'))):
        name = os.path.splitext(os.path.basename(f))[0]
        raw = rd(f)
        v = struct.unpack('<%di' % (len(raw) // 4), raw)
        views = [list(v[1 + i * 8:9 + i * 8]) for i in range(v[0])]
        for k in range(3):
            p = os.path.join(SIM, 'DB%d' % k, '%s.DB%d' % (name, k))
            if os.path.exists(p):
                gfx.to_image(gfx.read_any(rd(p))[0], pal).save(os.path.join(d, '%s_%d.png' % (name, k)))
        write_json(os.path.join(d, name + '.json'), {'views': views})
        n += 1
    return n


# ------------------------------------------------------------------------------------- formations
def formations():
    def pts(b, rec, fmt):
        sz = struct.calcsize('<' + fmt)
        return [[list(struct.unpack_from('<' + fmt, b, 2 + rec * i + sz * j)) for j in range(rec // sz)]
                for i in range(struct.unpack_from('<H', b, 0)[0])]
    out = {'mech_formations': pts(rd(SIM, 'DAT', 'MFORMS.DAT'), 0x1c, 'hh'),
           'flyer_formations': pts(rd(SIM, 'DAT', 'FFORMS.DAT'), 18, 'hhh')}
    # BFORMS (base.cpp 0x405fac): u32 n; n x {u32 count, count x (s32 x, s32 y, s16 heading),
    #   u32 zone (-1 none), s32 a, s32 b, u32 rows, rows x (u8 len, len bytes)}  (heights/flatten grid?)
    b = rd(SIM, 'DAT', 'BFORMS.DAT')
    n = struct.unpack_from('<I', b, 0)[0]
    p, slots, heads, extra = 4, [], [], []
    for i in range(n):
        c = struct.unpack_from('<I', b, p)[0]; p += 4
        s = [struct.unpack_from('<iih', b, p + 10 * k) for k in range(c)]; p += 10 * c
        zone = struct.unpack_from('<i', b, p)[0]; p += 4
        ab = struct.unpack_from('<ii', b, p); p += 8
        k = struct.unpack_from('<I', b, p)[0]; p += 4
        rows = []
        for _ in range(k):
            ln = b[p]; p += 1
            rows.append(list(b[p:p + ln])); p += ln
        slots.append([[x, y] for x, y, _ in s])
        heads.append([h for _, _, h in s])
        extra.append({'zone': zone, 'origin': list(ab), 'grid': rows})
    assert p == len(b)
    out['base_formations'] = slots
    out['base_formation_headings'] = heads
    out['base_formation_extra'] = extra
    out['notes'] = ('Same schema as gamedata/es1/gameplay/formations.json (offsets in world units, x right, '
                    'y forward). ES2 BFORMS has 17 formations of up to 14 slots with a per-slot heading '
                    '(base_formation_headings, 1/65536 turn) and, for 5..16, a zone index / origin / 0-1 grid '
                    '(base_formation_extra, meaning not decoded).')
    return out


# ------------------------------------------------------------------------------------------ units
def calib(res, verified):
    table = []
    for key, h in res.items():
        sp = os.path.join(OUT, 'shapes', key + '.json')
        if not os.path.exists(sp):
            continue
        shape = json.load(open(sp))
        if 'transforms' not in shape:      # static shape (SKIMMER): nodes default to identity
            shape = dict(shape, transforms=[[0, 0, 0, 0, 0, 0]], nodes=[])
        lo, hi = units_calib.shape_extent(shape)
        row = {'unit': key, 'name': h['name'], 'side': h['side'], 'flyer': bool(h.get('flyer')),
               'height_m': round((hi[2] - lo[2]) * MPU, 2), 'height_units': round(hi[2] - lo[2])}
        ws, rs = h.get('anim_seq_stand', -1), h.get('anim_seq_start', -1)
        seqs = shape.get('sequences', [])
        if not h.get('flyer') and 0 <= ws < len(seqs) and 0 <= rs < len(seqs):
            dw, tw = units_calib.seq_ground(shape, ws)
            dr, tr = units_calib.seq_ground(shape, rs)
            kw = dw / tw / (ANIM_TICK_S * 256.0)          # units/s per speed unit
            kr = dr / tr / (ANIM_TICK_S * 256.0)
            vmax = h['speed_forward_max']
            k_top = kr if vmax > h['walk_seq_speed_cap'] else kw
            row.update({
                'walk_seq': ws, 'walk_mps_per_speed_unit': round(kw * MPU, 5),
                'run_seq': rs, 'run_mps_per_speed_unit': round(kr * MPU, 5),
                'walk_run_switch_speed': h['walk_seq_speed_cap'],
                'speed_forward_max': vmax, 'speed_reverse_max': h['speed_reverse_max'],
                'top_speed_mps': round(vmax * k_top * MPU, 2), 'top_speed_kmh': round(vmax * k_top * MPU * 3.6, 1),
                'top_speed_kmh_designer_scale': round(vmax * k_top * DESIGNER_MPU * 3.6, 1),
                'reverse_kmh': round(abs(h['speed_reverse_max']) * kw * MPU * 3.6, 1),
                'accel_mps2': round(h['acceleration'] / FRAME_S * k_top * MPU, 2),
            })
        elif h.get('flyer'):
            kmh = h.get('shell_info', {}).get('shell_kmh') or h.get('cruise_mps', 30) * 3.6 / (MPU / DESIGNER_MPU)
            v = kmh / 3.6 * MPU / DESIGNER_MPU
            row.update({'top_speed_mps': round(v, 2), 'top_speed_kmh': round(v * 3.6, 1),
                        'top_speed_note': 'flyer: shell km/h (designer scale) x 256/166.7 (L)',
                        'reverse_kmh': 0.0, 'accel_mps2': round(v / 3.0, 2)})
        if 'turn_rate_max' in h:
            row.update({
                'turn_rate_max_deg_s': round(h['turn_rate_max'] * YAW_SCALE / FRAME_S * ANGLE_DEG, 1),
                'torso_yaw_rate_deg_s': round(h['torso_yaw_rate'] / FRAME_S * ANGLE_DEG, 1),
                'torso_pitch_rate_deg_s': round(h['torso_pitch_rate'] / FRAME_S * ANGLE_DEG, 1),
                'shield_radius_m': round(h['shield_radius'] * MPU, 2)})
        row.update({'mass_raw': h.get('mass'), 'shield_max': h.get('shield_max')})
        table.append(row)
    hr = [r for r in table if r['side'] == 'herc' and 'run_mps_per_speed_unit' in r]
    mean_k = sum(r['run_mps_per_speed_unit'] for r in hr) / max(1, len(hr))
    return {
        'game': 'Earthsiege 2 (DBSIM.EXE 1.0, Win32)',
        'verified': verified,
        'seconds_per_tick': FRAME_S,
        'tick_notes': 'Variable frame rate; frame scale = elapsed_ms*256/125 (0x46779b, clamp 64..450, frames '
                      '>= 40 ms). Scaled quantities are per 125 ms; per-update quantities without scaling (speed '
                      'approach, yaw rate, shield recharge, capacitor) use the nominal 125 ms frame.',
        'angle_units_per_turn': 65536,
        'timer_units_per_second': TIMER_PER_S,
        'designer_metres_per_unit': DESIGNER_MPU,
        'designer_scale_note': 'The manual km/h and the shell weapon ranges use 6 mm per unit (the ES1 readout '
                               'scale): computed top speeds at that scale (hercs[].top_speed_kmh_designer_scale) '
                               'match the manual within +-12% (Outlaw 111/100, Maverick 97/90, Tomahawk 67/75, '
                               'Raptor II 73/65, Samson 57/60, Colossus 63/55, Hyperion 42/45). In the shared '
                               '1/256 m world the same original unit speeds read 0.651x (top_speed_mps).',
        'speed': {'field_units': 'animation rate, 256 = authored speed; 1 anim tick = 1.25 ms at rate 256 '
                                 '(scale(100) per 125 ms frame, 0x418f5e); m/s per speed unit per Herc/sequence',
                  'to_mps': round(mean_k, 5), 'to_mps_note': 'mean run-sequence factor of the pilotable Hercs',
                  'walk_min_anim_rate': 60, 'manual_fit_to_mps_designer_scale': 0.085},
        'accel': {'field_units': 'speed units per frame (unscaled, 0x416c82)', 'to_mps2': round(mean_k / FRAME_S, 5)},
        'turn_rate': {'field_units': 'angle units per frame x 1600/1024 (0x417427), nominal 125 ms',
                      'to_rad_per_s': ANGLE * YAW_SCALE / FRAME_S,
                      'turn_accel_to_rad_per_s2': ANGLE / FRAME_S ** 2},
        'torso_rate': {'field_units': 'angle units per 125 ms (scaled, 0x41a5e8/0x41a8a0)',
                       'to_rad_per_s': ANGLE / FRAME_S, 'accel_to_rad_per_s2': ANGLE / FRAME_S ** 2},
        'projectile_speed': {'field_units': 'units per 125 ms (0x40b1eb)', 'to_mps': MPU / FRAME_S},
        'refire': {'field_units': 'timer units (2048/s)', 'to_seconds': 1.0 / TIMER_PER_S},
        'timers': {'to_seconds': 1.0 / TIMER_PER_S, 'examples': {'emp_shield_down_6000': round(6000 / TIMER_PER_S, 3)}},
        'anim_tick_seconds': ANIM_TICK_S,
        'shield_recharge': {'field_units': 'shield points per update (<= 5, 0x413b52)', 'to_per_second': 1 / FRAME_S,
                            'max_per_frame': 5},
        'beam_charge': {'field_units': 'capacitor points per update (20, 0x40e0cc)', 'to_per_second': 1 / FRAME_S},
        'bullet_lifetime': {'field_units': '125 ms ticks', 'to_seconds': FRAME_S},
        'damage_scale': 1.0,
        'hercs': table,
    }


def main():
    verified = verify_exe()
    eng = json.load(open(os.path.join(OUT, 'gameplay', 'weapons_engine.json')))
    wmask = {w['name']: w['hardpoint_mask'] for w in eng['weapons']}
    res = load_units(wmask)
    for k, h in res.items():   # loadout names must exist in the weapon catalog
        for i, nm in enumerate(h['loadout']):
            if nm is not None and nm not in wmask:
                print('  %s: unknown weapon %s' % (k, nm))
                h['loadout'][i] = None
    recs = parse_bases()
    s0 = strings0()
    base_names = next(g for g in s0 if g and g[0] == 'MINING FACILITY')
    veh_names = next(g for g in s0 if g and g[0] == 'MOBILE CANNON')
    shapes_note = ''
    if '--no-shapes' not in sys.argv:
        sets = {h['texture_set'] for h in res.values()} | {'BASETEX', 'VEHTEX', 'RAZORTEX'}
        export_textures(sets)
        made, srcmap = export_shapes(res, recs)
        write_shape_index()
        shapes_note = '%d shapes' % len(made)
        ncock = export_cockpits()
    else:
        for r in recs:
            r['shape_unified'] = r['shape_index'] + (N_BASES_DGS if r['animated'] else 0)
        srcmap, ncock = {}, 0

    gp = os.path.join(OUT, 'gameplay')
    write_json(os.path.join(gp, 'hercs.json'), res, indent=1)

    rows, out_recs = [], []
    for r in recs:
        hp = sum(c['hp'] for c in r['components'])
        tbl = veh_names if r['vehicle_texset'] else base_names     # ground vehicles: STRINGS0 group 24
        nm = tbl[r['name_index']] if 0 <= r['name_index'] < len(tbl) else 'STRUCTURE'
        rows.append([r['type'], r['shape_unified'], r['hulk'], r['animated'], hp, r['category'], r['name_index'],
                     r['vehicle_texset']])
        rr = dict(r)
        rr.update(name=nm.title(), hp=hp, shape='es2:BASES_%d' % r['shape_unified'],
                  shape_source=srcmap.get(r['shape_unified']), texset=base_texset(r),
                  hulk_shape='es2:BHULKS_%d' % r['hulk'] if r['hulk'] >= 0 else None)
        out_recs.append(rr)
    write_json(os.path.join(gp, 'bases.json'), {
        'bases': rows,
        'row_columns': ['type', 'shape (es2:BASES_<n>)', 'hulk (es2:BHULKS_<n>, -1 none)', 'animated',
                        'hp (sum of components)', 'category', 'name index (STRINGS0 group 23)',
                        'vehicle texset flag'],
        'names': [s.title() for s in base_names], 'vehicle_names': [s.title() for s in veh_names],
        'records': out_recs,
        'notes': 'BASES.DAT has 65 types; Cybrid variants are separate types (no BASES_E set as in ES1). '
                 'Rows keep the ES1 column meaning used by mission_runtime (row[1] shape index, row[4] hp). '
                 'Each record has several damage components (hp, part, flags, sphere...): hp = their sum. '
                 'Type names: tail word 2 indexes STRINGS0 group 23 (matches ES1 types 0..8, M), or group 24 '
                 '(vehicle_names) for the ground vehicles 45..64 (tail word 7 set, VEHTEX). Types 45..64 are '
                 'mobile targets (cannon / missile carrier / transport / assault) placed as structures.',
    }, indent=1)
    write_json(os.path.join(gp, 'formations.json'), formations(), indent=1)

    up = os.path.join(OUT, 'units.json')
    u = json.load(open(up)) if os.path.exists(up) else {}
    u.update(calib(res, verified))
    u.setdefault('metres_per_unit', MPU)
    write_json(up, u, indent=1)

    print('es2 units: %d vehicles, %d base types, %s, %d cockpits; %s'
          % (len(res), len(recs), shapes_note, ncock, verified))
    for r in u['hercs']:
        print('  %-9s %-6s h %5.2f m  top %5.1f km/h (designer %5s)  rev %4s  loadout %s'
              % (r['unit'], r['side'], r['height_m'], r.get('top_speed_kmh', 0), r.get('top_speed_kmh_designer_scale', '-'),
                 r.get('reverse_kmh', '-'), res[r['unit']]['loadout']))


if __name__ == '__main__':
    main()
