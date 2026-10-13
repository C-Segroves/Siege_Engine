"""Convert Metaltech: Battledrome (1995) assets into the same engine-neutral layout that
tools/export_es1.py writes for Earthsiege, under gamedata/bd/.

Input: bd/installed/ (produced by tools/bd_unchunk.py from the CD's RESOURCE.000).
Battledrome has no VOL archives: everything is loose in DTS/, DATA/, SOUND/.

Output layout (identical schema to gamedata/es1/ where the content exists):
  palettes/<NAME>.json            256 x [r,g,b] (8-bit)                      (export_es1 schema)
  textures/<SET>/<i>.png          8-bit palette-index images (mode "L")       (export_es1 schema)
  textures/<SET>.json             [{w,h}] per index                           (export_es1 schema)
  shapes/<NAME>.json              export_es1.shape_to_json() schema; LOD 0 = most detailed
  shapes/_index.json              [{name, lods, kind}]  kind = dts | dcs
  collision/<NAME>.json           DCS collision / logical-part data (BD only, see docs/formats/battledrome.md)
  arenas/arena<N>.json            DOA contents: radius, ceiling, shape list, obstacles, turrets, start pads
  arenas/_index.json
  gameplay/hercs.json, weapons.json, components.json   tables read from SIM.EXE (partially decoded)
  text/*.json                     WATEXT.BIN / MSGTEXT.BIN string tables
No cockpit overlays exist in Battledrome (the sim view is a HUD only: DTS/HUD.DAT).
"""
import glob
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dts            # noqa: E402  (ES1 3Space parser - works unchanged on BD shapes)
import gfx            # noqa: E402
import export_es1     # noqa: E402  (shape_to_json / flatten_lod reused as-is)
import world          # noqa: E402  (read_dpl_full: DPL shade lists, same layout as ES1)

import siege_paths as P  # noqa: E402
BD = P.work('bd', 'installed')
OUT = P.pack('bd')
SIM_EXE_BASE = 0x69cd   # SIM.EXE: VA = file offset - 0x69cd (X-32VM flat image, cf. DBSIM 0x48fd)

# texture bitmap arrays (DBA) exported as texture sets
TEXTURE_SETS = {
    # sim
    'LIGHT': 'DTS/LIGHT.DBA', 'MEDIUM': 'DTS/MEDIUM.DBA', 'HEAVY': 'DTS/HEAVY.DBA', 'OBS': 'DTS/OBS.DBA',
    # bitmap effects (used by the matching DTS shapes' bitmap parts)
    'BLASTHIT': 'DTS/BLASTHIT.DBA', 'EXPLD1': 'DTS/EXPLD1.DBA', 'EXPLD2': 'DTS/EXPLD2.DBA',
    'LSRHIT': 'DTS/LSRHIT.DBA', 'PLASMBAL': 'DTS/PLASMBAL.DBA', 'RDLASER': 'DTS/RDLASER.DBA',
    'SHIELD1': 'DTS/SHIELD1.DBA', 'SHLDHIT2': 'DTS/SHLDHIT2.DBA', 'SHROOM': 'DTS/SHROOM.DBA',
    # shell (hangar / selection screen low-poly Hercs)
    'S_LIGHT': 'DATA/S_LIGHT.DBA', 'S_MEDIUM': 'DATA/S_MEDIUM.DBA', 'S_HEAVY': 'DATA/S_HEAVY.DBA',
}

# Herc table in SIM.EXE (file name -> display name, weight class)
HERCS = [
    ('STRYDER', 'Stryder', 'LIGHT'), ('BARETTA', 'Barretta', 'LIGHT'), ('AVENGER', 'Avenger', 'LIGHT'),
    ('VIPER', 'Cobra', 'LIGHT'), ('NOMAD', 'Nomad', 'MEDIUM'), ('TALON', 'Talon', 'MEDIUM'),
    ('PHANTOM', 'Ronin', 'MEDIUM'), ('SLAYER', 'Slayer', 'HEAVY'), ('VNDICTR', 'Judicator', 'HEAVY'),
    ('THOR', 'Hammer', 'HEAVY'),
]

SHAPE_TEXSET = {h[0]: h[2] for h in HERCS}
SHAPE_TEXSET.update({'S' + h[0]: 'S_' + h[2] for h in HERCS})
SHAPE_TEXSET.update({'TURRET': 'OBS', 'TURHLK': 'OBS', 'PAD': 'OBS'})
for _s in range(3):
    for _l in 'ABCD':
        SHAPE_TEXSET['OBS%d%s' % (_s, _l)] = 'OBS'
for _fx in ('BLASTHIT', 'EXPLD1', 'EXPLD2', 'LSRHIT', 'PLASMBAL', 'RDLASER', 'SHIELD1', 'SHLDHIT2', 'SHROOM'):
    SHAPE_TEXSET[_fx] = _fx

ARENA_SIZES = ['MINI', 'SMALL', 'MED', 'LARGE', 'HUGE']           # WATEXT "SIZE" options -> ARENA1..5
DENSITY = ['NONE', 'FEW', 'SEVERAL', 'MANY']                       # obstacle / blaster-turret settings
OBJ_TYPES = {0: 'obstacle', 1: 'turret', 2: 'start_pad'}

write_json = export_es1.write_json


# ---------------------------------------------------------------- palettes / textures

def export_palettes():
    lists = {}
    for f in sorted(glob.glob(os.path.join(BD, 'DTS', '*.DPL')) + glob.glob(os.path.join(BD, 'DATA', '*.DPL'))):
        name = os.path.splitext(os.path.basename(f))[0]
        pal = gfx.read_dpl(open(f, 'rb').read())
        write_json(os.path.join(OUT, 'palettes', name + '.json'), [list(c[:3]) for c in pal])
        try:
            lists[name] = world.read_dpl_full(f)[1]
        except struct.error:      # SIMTEST.DPL (type 2) has a different trailer
            lists[name] = []
    return lists


def export_texture_set(name, rel):
    from PIL import Image
    bmps = gfx.read_any(open(os.path.join(BD, rel), 'rb').read())
    d = os.path.join(OUT, 'textures', name)
    os.makedirs(d, exist_ok=True)
    meta = []
    for i, b in enumerate(bmps):
        n = b['w'] * b['h']
        img = Image.frombytes('L', (b['w'], b['h']), bytes(b['pixels'][:n]).ljust(n, b'\0'))
        img.save(os.path.join(d, '%d.png' % i))
        meta.append({'w': b['w'], 'h': b['h']})
    write_json(os.path.join(OUT, 'textures', name + '.json'), meta)
    return len(meta)


# ---------------------------------------------------------------- DCS (DCShape) container

def read_dcs(data):
    """DCS = object (0x1f8, 0x2bc) wrapping
         (0x1f5, 0x2bc) detail-collision table
         a 3Space shape object ((8,0x14) shape or (3,0x1e) an_shape) - dts.py parses it unchanged
         a trailer (compiled logical-part / cell-anim / mat-anim tables, cf. DTS/OBS0B.DCD source)."""
    typ, cls, size = struct.unpack_from('<HHI', data, 0)
    assert (typ, cls) == (0x1f8, 0x2bc), (typ, cls)
    t2, c2, s2 = struct.unpack_from('<HHI', data, 8)
    assert (t2, c2) == (0x1f5, 0x2bc), (t2, c2)
    coll = read_collision(data[16:16 + s2])
    p = 16 + s2
    p += p & 1
    r = dts.Reader(data, p)
    shape = dts.read_obj(r)
    trailer = data[r.p:8 + size]
    return shape, coll, trailer


def read_collision(b):
    """(0x1f5,0x2bc) body: u8 nDetail, u8 nTubes,
         nDetail x {s16 a, s16 b, u8 tubeCount, u16 firstTube, u8 c}     (8 bytes)
         nTubes  x {i32 x1,y1,z1, x2,y2,z2, radius}                      (capsules, shape units)
         nDetail x u8 enabled
    Field meaning of a/b/c is tentative: for Hercs a looks like the shape node of the part and b the
    logical part (TORSO, LEFT LEG, POD n ...); for OBS0B (source DTS/OBS0B.DCD) the single record
    is 'Detail Part 0 ID 0 On' with 6 tubes."""
    nd, nt = b[0], b[1]
    p = 2
    parts = []
    for _ in range(nd):
        a, bb, cnt, first, c = struct.unpack_from('<hhBHB', b, p)
        parts.append({'a': a, 'b': bb, 'tube_count': cnt, 'first_tube': first, 'c': c})
        p += 8
    tubes = []
    for _ in range(nt):
        v = struct.unpack_from('<7i', b, p)
        tubes.append({'p0': list(v[0:3]), 'p1': list(v[3:6]), 'radius': v[6]})
        p += 28
    flags = list(b[p:p + nd])
    p += nd
    for i, f in enumerate(flags):
        parts[i]['enabled'] = f
    return {'parts': parts, 'tubes': tubes, 'consumed': p, 'size': len(b)}


def read_dcs_trailer(t):
    if len(t) < 20:
        return {'raw_hex': t.hex()}
    cx, cy, cz, rad, v4 = struct.unpack_from('<5i', t, 0)
    words = list(struct.unpack_from('<%dH' % ((len(t) - 20) // 2), t, 20))
    return {'sphere_center': [cx, cy, cz], 'sphere_radius': rad, 'unknown_10': v4, 'words': words}


# ---------------------------------------------------------------- shapes

def _most_detailed_first(det):
    """detail_part children ordered most detailed first (BD stores them low -> high, thresholds
    ascending, ES1 stores separate top-level shapes high -> low)."""
    kids = list(det['parts'])
    th = det.get('details') or []
    if len(th) >= 2 and th[0] < th[-1]:
        kids = kids[::-1]
    return kids


def _fix_nested_details(o):
    if o.get('type') == 'detail_part' and o.get('parts'):
        o['parts'] = _most_detailed_first(o)
        o['details'] = sorted(o.get('details') or [], reverse=True)
    for k in ('parts', 'items', 'extra'):
        for c in o.get(k, []):
            if isinstance(c, dict):
                _fix_nested_details(c)


def split_lods(shape):
    """Turn a shape whose root part is a detail_part into one pseudo top-level shape per LOD so
    export_es1.shape_to_json produces the ES1 'lods' list (most detailed first)."""
    parts = shape.get('parts', [])
    if len(parts) == 1 and parts[0]['type'] == 'detail_part' and len(parts[0]['parts']) > 1:
        det = parts[0]
        out = []
        for i, c in enumerate(_most_detailed_first(det)):
            _fix_nested_details(c)
            s = {'type': shape['type'], 'radius': c['radius'], 'center': c['center'], 'parts': [c],
                 'transform': shape['transform'], 'id': shape['id']}
            if i == 0:
                s['extra'] = shape.get('extra', [])
                s['sequence_list'] = shape.get('sequence_list', [])
                s['transform_list'] = shape.get('transform_list', [])
            else:
                s['extra'] = []
            out.append(s)
        return out, sorted(det.get('details') or [], reverse=True)
    _fix_nested_details(shape)
    return [shape], []


def max_tex_index(j):
    m = -1
    for lod in j['lods']:
        for pc in lod['pieces']:
            for p in pc['polys']:
                if p['m']['kind'] == 'tex':
                    m = max(m, p['m']['index'])
    return m


def export_shapes(tex_counts):
    index = []
    files = sorted(glob.glob(os.path.join(BD, 'DTS', '*.DTS')) + glob.glob(os.path.join(BD, 'DTS', '*.DCS')) +
                   glob.glob(os.path.join(BD, 'DATA', '*.DCS')))
    for f in files:
        name, ext = os.path.splitext(os.path.basename(f))
        data = open(f, 'rb').read()
        thresholds = []
        if ext.upper() == '.DCS':
            shape, coll, trailer = read_dcs(data)
            coll['trailer'] = read_dcs_trailer(trailer)
            coll['shape_extra_tail_bytes'] = len(trailer)
            write_json(os.path.join(OUT, 'collision', name + '.json'), coll)
            objs, thresholds = split_lods(shape)
        else:
            objs = dts.read_file(data)
            if len(objs) == 1:
                objs, thresholds = split_lods(objs[0])
        j = export_es1.shape_to_json(objs, name)
        j['texset'] = SHAPE_TEXSET.get(name)
        ts = j['texset']
        mt = max_tex_index(j)
        if ts and mt >= tex_counts.get(ts, 0):
            print('WARNING %s: texture index %d outside set %s (%d)' % (name, mt, ts, tex_counts.get(ts, 0)))
        write_json(os.path.join(OUT, 'shapes', name + '.json'), j)
        index.append({'name': name, 'lods': len(j['lods']), 'kind': ext[1:].lower()})
    write_json(os.path.join(OUT, 'shapes', '_index.json'), index)
    return index


# ---------------------------------------------------------------- arenas

def read_doa(path):
    """DTS/ARENAn.DOA (SIM.EXE ArenaData::loadFile @0x2ac74):
         header 0x24: u32 nShapes, u32 nObjects, i32 ceiling(?) z, i32 radius, char palette[20]
         nShapes x char name[13]
         nObjects x 38 bytes: u32 type (0 obstacle, 1 blaster turret, 2 start pad), u32 shape index,
                   i32 x, y, z, u16 rx, ry, rz (65536 = 360 deg), u32 (uninitialised padding),
                   u32 side (0/1), u32 level (object present when level <= obstacle / turret setting)"""
    d = open(path, 'rb').read()
    ns, no, top, radius = struct.unpack_from('<IIii', d, 0)
    pal = d[0x10:0x24].split(b'\0')[0].decode('ascii')
    names = [d[0x24 + 13 * i:0x24 + 13 * i + 13].split(b'\0')[0].decode('ascii') for i in range(ns)]
    p = 0x24 + 13 * ns
    objs = []
    for _ in range(no):
        typ, shp, x, y, z, rx, ry, rz, pad, side, level = struct.unpack_from('<IIiiiHHHIII', d, p)
        p += 38
        objs.append({'type': OBJ_TYPES.get(typ, typ), 'shape': shp, 'pos': [x, y, z], 'rot': [rx, ry, rz],
                     'side': side, 'level': level})
    return {'shapes': names, 'radius': radius, 'ceiling_z': top, 'palette_file': pal, 'objects': objs}


def export_arenas(pal_lists):
    idx = []
    for n in range(1, 6):
        a = read_doa(os.path.join(BD, 'DTS', 'ARENA%d.DOA' % n))
        a['index'] = n
        a['name'] = ARENA_SIZES[n - 1]
        a['file'] = 'ARENA%d.DOA' % n
        # obstacle shapes named obsXY.dcs are re-lettered at load time: "dts\obs%d%s" with a random
        # style 0..2 (SIM.EXE 0x2b156), i.e. OBS0A/OBS1A/OBS2A share the layout but differ in textures
        a['shape_variants'] = [[('OBS%d%s' % (s, nm[4:].split('.')[0])).upper() for s in range(3)]
                               if nm.lower().startswith('obs') else [nm.split('.')[0].upper()] for nm in a['shapes']]
        a['texset'] = 'OBS'
        a['turret_shapes'] = {'normal': 'TURRET', 'destroyed': 'TURHLK', 'texset': 'OBS'}
        a['palettes'] = {'normal': 'NRMPAL', 'gamma': 'GAMPAL', 'death': 'DEATHPAL', 'textures': 'TEXTURES',
                         'note': 'DOA palette field (simtest.dpl) is read but ignored by the sim'}
        a['dpl_shade_lists'] = {str(i): l for i, l in enumerate(pal_lists.get('NRMPAL', [])) if l != [255]}
        a['texture_shade_lists'] = {str(i): l for i, l in enumerate(pal_lists.get('TEXTURES', []))}
        pads = [o for o in a['objects'] if o['type'] == 'start_pad']
        a['spawn_points'] = {str(s): [{'pos': o['pos'], 'heading': o['rot'][2]} for o in pads if o['side'] == s]
                             for s in (0, 1)}
        a['settings'] = {'obstacles': DENSITY, 'blaster_turrets': DENSITY,
                         'lighting': ['BRIGHT', 'DIM', 'DARK']}
        a['sky_ground'] = None   # not stored in the DOA - flat floor + ceiling, colours unresolved
        write_json(os.path.join(OUT, 'arenas', 'arena%d.json' % n), a)
        idx.append({'index': n, 'name': a['name'], 'radius': a['radius'], 'objects': len(a['objects'])})
    write_json(os.path.join(OUT, 'arenas', '_index.json'), idx)


# ---------------------------------------------------------------- text tables

def read_text_bin(path):
    d = open(path, 'rb').read()
    n, _ = struct.unpack_from('<II', d, 0)
    offs = struct.unpack_from('<%dH' % n, d, 8)
    base = 8 + 2 * n
    return [d[base + o:d.index(b'\0', base + o)].decode('latin1') for o in offs]


def export_text():
    write_json(os.path.join(OUT, 'text', 'watext.json'), read_text_bin(os.path.join(BD, 'DATA', 'WATEXT.BIN')))
    write_json(os.path.join(OUT, 'text', 'msgtext.json'), read_text_bin(os.path.join(BD, 'DTS', 'MSGTEXT.BIN')))


# ---------------------------------------------------------------- gameplay tables (SIM.EXE)

def _cstr(b):
    return b.split(b'\0')[0].decode('latin1')


def export_gameplay():
    """Static tables in SIM.EXE's data segment. Field names marked '?' are guesses from value
    patterns only (not yet confirmed in code)."""
    d = open(os.path.join(BD, 'SIM.EXE'), 'rb').read()
    hercs = {}
    for m in re.finditer(rb'dts\\[a-z]+\.dcs\x00', d):
        sn = m.start()
        if d[sn + 0x18:sn + 0x1d] != b'data\\':
            continue
        e = sn - 0xfc                         # record = 0x364 bytes: stats, file names, parts, name, price, tier
        w = struct.unpack_from('<63i', d, e)
        name = _cstr(d[e + 0x350:e + 0x35c])
        price, tier = struct.unpack_from('<ii', d, e + 0x35c)
        shape = os.path.splitext(os.path.basename(_cstr(d[sn:sn + 0x18]).replace('\\', '/')))[0].upper()
        mounts = []
        for k in range(5):                    # words 36..60: 5 weapon mounts x 5 words, -1 = absent
            mt = w[36 + 5 * k:41 + 5 * k]
            mounts.append(None if mt[0] == -1 and mt[1] == -1 else
                          {'bay_type?': mt[0], 'part?': mt[1], 'capacity?': mt[3], 'raw': list(mt)})
        hercs[shape] = {
            'name': name, 'shape': shape, 'shell_shape': 'S' + shape,
            'texture_set': _cstr(d[sn + 0x2c:sn + 0x40]).split('\\')[-1].split('.')[0].upper(),
            'price': price, 'tier?': tier,
            'speed_forward_max?': w[7], 'speed_reverse_max?': w[8], 'acceleration?': w[9],
            'mass?': w[17], 'size_class?': w[26], 'unknown_29': w[29], 'unknown_34': w[34],
            'mounts?': mounts, 'n_logical_parts?': w[61],
            'record_va': e - SIM_EXE_BASE, 'raw_words': list(w),
        }
    write_json(os.path.join(OUT, 'gameplay', 'hercs.json'), hercs)

    def table(first_name, count, stride):
        a = d.find(first_name)
        rows = []
        for k in range(count):
            p = a + k * stride
            raw = list(struct.unpack_from('<%di' % (stride // 4), d, p - stride + 16))
            rows.append({'name': _cstr(d[p:p + 12]), 'record_end_va': p + 16 - SIM_EXE_BASE, 'raw_words_before_name': raw[:-4]})
        return rows

    weapons = table(b'LASER 1\0', 33, 0x7c)   # 7 lasers, 4 blasters, 3 plasma, 5 cannon, 7 x2 launchers
    wclass = {0: 'laser', 1: 'blaster', 2: 'plasma', 3: 'autocannon', 4: 'launcher_4', 5: 'launcher_5'}
    for r in weapons:
        w = r['raw_words_before_name']
        r['class?'] = wclass.get(w[1], w[1])
        r['price?'] = w[-3]
        r['herc_allowed_flags?'] = w[9:22]
    write_json(os.path.join(OUT, 'gameplay', 'weapons.json'), {'weapons': weapons})
    comps = {
        'shields': table(b'SG II\0', 4, 0x6c),
        'reactors': table(b'1.2TW\0', 6, 0x64),
        'armor': table(b'ARMOR1\0', 12, 0xb0),
        'engines': table(b'250 DL\0', 12, 0x88),
    }
    write_json(os.path.join(OUT, 'gameplay', 'components.json'), comps)
    # HUD.DAT: 33 u32 + 14 bytes, layout of the HUD gauges (unresolved)
    hud = open(os.path.join(BD, 'DTS', 'HUD.DAT'), 'rb').read()
    write_json(os.path.join(OUT, 'gameplay', 'hud.json'),
               {'words': list(struct.unpack_from('<%di' % (len(hud) // 4), hud, 0)), 'tail': list(hud[len(hud) // 4 * 4:])})


def main():
    lists = export_palettes()
    counts = {k: export_texture_set(k, v) for k, v in TEXTURE_SETS.items()}
    export_shapes(counts)
    export_arenas(lists)
    export_text()
    export_gameplay()
    print('done ->', os.path.abspath(OUT))


if __name__ == '__main__':
    main()
