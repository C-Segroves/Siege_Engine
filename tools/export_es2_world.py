"""Earthsiege 2 worlds (WLD v2 + DPL + RMP + ground textures) and zone heightmap terrain -> gamedata/es2/.

Everything is derived from DBSIM.EXE 1.0 (Win32 PE, image base 0x400000; VAs below), see
docs/formats/es2.md section 3 for the layouts.

World selection (DBSIM 0x42e010, called from the script loader 0x4246c9 with the 20-byte header of
data\\script.dat at 0x4a9ed2):  n = header.word0 * 2 + header.word9  ->  WORLD<n>.DPL (0x42e093) and
WORLD<n>.WLD, WORLD<n>.CYC (optional, none ship), WORLD<n>.RMP.  word0 = terrain/world type
(0 urban, 1 snow, 2 volcanic, 3 ice, 4 moon by the WLD ground texture), word9 = 0 day / 1 night.
The zone (word1) is loaded by 0x42789c: ZONE<word1>.DAT + ZONE<word1>.DBA.

Output:
  worlds/world<n>.json              sky / haze / light / ground (keys follow gamedata/es1/worlds)
  worlds/es2_ground_<n>_<m>.png     ground texture m of world n, RGB, baked through the world's
                                    RMP table at the flat-ground light level
  worlds/es2_rmp_<n>.png            WORLD<n>.RMP as an L8 image 256 x 384 (row = haze*32 + light)
  worlds/shade_<n>.png              DPL shade slot lists for shaded shape polys (engine Palette.look, 32 x 256)
  worlds/texlight_<n>.png           RMP haze row 0 = light remap for textured shape polys (256 x 32)
  terrain/<zone>/terrain.json       map_schema "terrain" block (engine metres, y up, -z = north)
  terrain/<zone>/heights.r32        float32 metres, rows = +z (row 0 = north edge), cols = +x
  terrain/<zone>/materials.png      L8 material index per 128 m texture tile (row = original tile y)
  terrain/<zone>/preview.png        hill-shaded height preview
  terrain/_index.json

Usage: python tools/export_es2_world.py [--seed N]
"""
import json
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gfx  # noqa: E402
import world  # noqa: E402
import export_es2  # noqa: E402
import siege_paths as P  # noqa: E402

SIM = P.work('es2', 'extracted', 'SIMVOL0')
ZONES = P.work('es2', 'extracted', 'ZONES')
EXE = P.work('es2', 'original', 'DBSIM.EXE')
OUT = P.pack('es2')

UNIT_M = 1.0 / 256.0
WORLD_TYPES = {'urban': 0, 'bsnow': 1, 'volcan': 2, 'ice': 3, 'moon': 4}
TYPE_NAMES = ['urban', 'bsnow', 'volcan', 'ice', 'moon']     # by ground texture DBA

# Sun (DBSIM 0x461240): directional, intensity 0x100, vector (0, 0x1000, 0) rotated by euler
# (rx=0xe890, ry=0, rz=0x5208) through 0x47eaac/0x47ffb4.  Rotation order assumed Rz*Ry*Rx as tools/world.py.
SUN_EULER = (0xe890, 0, 0x5208)
SUN_INTENSITY = 256

# Ground material random choice (0x46c58b): per texture tile, rand()&0xfff < 0x4ce (30 %) -> material 1, else 0.
MAT1_CHANCE = 0x4ce / 4096.0

# Code bytes this exporter depends on (VA -> hex); checked when DBSIM.EXE is present.
EVIDENCE = {
    0x42E042: '66a148fd4c00',      # mov ax,[W+0]      world index = W0*2 + W[0x12]
    0x42E049: '668b155afd4c00',    # mov dx,[W+0x12]
    0x42E050: '8bd803db',          # ebx = ax; ebx += ebx
    0x42E05A: '6603da',            # bx += dx  -> sprintf("world%d")
    0x427A09: '898208010000',      # terrain+0x108 = DAT k (log2 square size)
    0x427A24: '899018010000',      # terrain+0x118 = DAT s (height scale)
    0x46D97F: 'f7ab18010000',      # vertex z = h * s (+min +offset)
    0x46C5A7: '3dce040000',        # material-1 chance 0x4ce/0x1000
    0x475133: '8b151c5b4a00',      # RMP light row: ((w-1) * I) & ~0xff
}


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, indent=indent, separators=None if indent else (',', ':'))


def verify_exe():
    if not os.path.exists(EXE):
        return 'DBSIM.EXE not found: layouts not re-verified'
    d = open(EXE, 'rb').read()
    bad = []
    for va, hx in EVIDENCE.items():
        off = va - 0x400A00          # CODE section: VA 0x401000 <- file 0x600
        if d[off:off + len(hx) // 2].hex() != hx:
            bad.append(hex(va))
    if bad:
        raise SystemExit('DBSIM.EXE differs at %s - re-check docs/formats/es2.md section 3' % bad)
    return 'verified %d code sites in DBSIM.EXE' % len(EVIDENCE)


# ------------------------------------------------------------------------------------- readers

class _R:
    def __init__(self, d):
        self.d, self.p = d, 0

    def s16(self):
        v = struct.unpack_from('<h', self.d, self.p)[0]; self.p += 2; return v

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]; self.p += 2; return v

    def s32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v

    def cstr(self):
        e = self.d.index(b'\0', self.p)
        s = self.d[self.p:e].decode('latin1'); self.p = e + 1; return s


def parse_wld2(path):
    """WLD v2, in the order DBSIM 0x42e0f8.. reads it (all little-endian)."""
    r = _R(open(path, 'rb').read())
    w = {}
    w['horizon_offset'] = r.s16()        # 00 -> horizon+0x6c
    w['sky_first'] = r.s16()             # 02 arg of 0x42ebbc (sky ramp first index = zenith)
    w['sky_band_px'] = r.s16()           # 04 -> horizon+0x54
    w['sky_count'] = r.s16()             # 06 -> horizon+0x58
    w['ground_first'] = r.s16()          # 08 arg of 0x42ebbc; [0x49aee8] = ground_first+ground_count-1
    w['ground_band_px'] = r.s16()        # 0a -> horizon+0x5c
    w['ground_count'] = r.s16()          # 0c -> horizon+0x60
    w['horizon_field_30'] = r.s16()      # 0e arg of 0x42ebbc
    w['unused_10'] = r.s16()             # 10 read, not used (ES1 flat_field_15)
    w['flat_variant'] = r.s16()          # 12 -> [0x49aeea] -> 0x4097a8
    w['ambient_low_index'] = r.s16()     # 14 -> [0x4cfd76]
    w['ambient_high_index'] = r.s16()    # 16 -> [0x4cfd78]
    w['unused_18'] = r.s16()             # 18 new in v2 (6000), read into a local and dropped
    w['unused_1a'] = r.s16()             # 1a new in v2 (7), read into a local and dropped
    n = r.s32()
    w['haze_dist_objects'] = [r.s32() for _ in range(n)]     # 1c -> [0x4cfd84]
    n = r.s32()
    w['haze_dist_terrain'] = [r.s32() for _ in range(n)]     # -> [0x4cfd88]
    w['haze_levels'] = r.s16()           # -> [0x4cfd62]
    nr = r.s16()                         # -> [0x4cfd60] (11)
    rr = [(r.u16(), r.u16()) for _ in range(nr)]
    nt = r.s16()
    tt = [(r.u16(), r.u16()) for _ in range(nt)]
    w['ramps'] = [{'start': a, 'count': b, 'haze_start': c, 'haze_count': e} for (a, b), (c, e) in zip(rr, tt)]
    a, b, c, e = r.u16(), r.u16(), r.u16(), r.u16()
    w['glow_ramp'] = {'start': a, 'count': b, 'haze_start': c, 'haze_count': e}
    w['unused_cloud_count'] = r.s16()    # read into a local, unused in 1.0 (ES1 cloud_count)
    w['unused_flat_count'] = r.s16()     # idem (ES1 decal pool)
    w['haze_offset_low'] = r.s32()       # -> [0x4cfd6c]
    w['haze_offset_high'] = r.s32()      # -> [0x4cfd70]
    w['unused_panorama'] = r.cstr()      # 'world24': read and dropped (no panorama in ES2)
    w['unused_clouds'] = r.cstr()        # 'clouds2': read and dropped (no cloud layer)
    w['impact_palette'] = r.cstr()       # -> 0x474ba4 -> [0x49aef8]
    w['ground_texture'] = r.cstr()       # -> 0x46bc98: <name>.dba, 13 x 256x256 ground textures
    w['unused_ground_dat'] = r.cstr()    # 'tex': read and dropped
    return w


def read_rmp(n):
    d = open(os.path.join(SIM, 'RMP', 'WORLD%d.RMP' % n), 'rb').read()
    lw, rows = struct.unpack_from('<II', d, 0)
    tabs = [d[8 + 256 * i:8 + 256 * (i + 1)] for i in range(lw * rows)]
    return lw, rows, tabs


def read_mat0():
    """MAT0.DAT (0x46c6a2): u32 n, n x (u32 texture index, u32 scale b).  Texel = 2^(13-b) units."""
    d = open(os.path.join(SIM, 'DAT', 'MAT0.DAT'), 'rb').read()
    n = struct.unpack_from('<I', d, 0)[0]
    mats = [struct.unpack_from('<II', d, 4 + 8 * i) for i in range(n)]
    return [{'texture': t, 'b': b, 'texel_units': 1 << (13 - b), 'tile_units': 256 << (13 - b)} for t, b in mats], d[4 + 8 * n:]


def sun_vector():
    k = 2 * math.pi / 65536.0
    ax, ay, az = (a * k for a in SUN_EULER)
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    Rx = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]]
    Ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
    Rz = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]]

    def mm(a, b):
        return [[sum(a[i][q] * b[q][j] for q in range(3)) for j in range(3)] for i in range(3)]
    m = mm(mm(Rz, Ry), Rx)
    return tuple(m[i][1] for i in range(3))


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


# --------------------------------------------------------------------------------------- worlds

def export_shape_lighting(n, light_levels, rmp_tables):
    """Lookup images for shapes drawn in world n. Shaded polys: DPL slot lists, as in ES1 (WORLD<n>.DPL ships
    the same 256-list tail). Textured polys: the rasteriser picks RMP + ((levels-1)*I + haze_row) & ~0xff
    (0x468054), so light level (31*I)>>8 of haze row 0 for unfogged objects (ES1 built 8 tables itself)."""
    _, lists = world.read_dpl_full(os.path.join(SIM, 'DPL', 'WORLD%d.DPL' % n))
    world.make_shade_list_image(lists).save(os.path.join(OUT, 'worlds', 'shade_%d.png' % n))
    world.make_light_table_image(rmp_tables[:light_levels]).save(os.path.join(OUT, 'worlds', 'texlight_%d.png' % n))


def export_worlds():
    from PIL import Image
    os.makedirs(os.path.join(OUT, 'worlds'), exist_ok=True)
    mats, mat_tail = read_mat0()
    L = sun_vector()
    i_flat = int(SUN_INTENSITY * (1 - L[2]) / 2)          # up normal (0,0,1): I = 256*(1 - n.L)/2
    index = []
    for n in range(10):
        w = parse_wld2(os.path.join(SIM, 'WLD', 'WORLD%d.WLD' % n))
        pal = export_es2.make_world_palette('WORLD%d' % n)
        lw, rows, tabs = read_rmp(n)
        export_shape_lighting(n, lw, tabs)
        flat_level = ((lw - 1) * i_flat) >> 8
        gname = w['ground_texture'].lower()
        bmps = gfx.read_any(open(os.path.join(SIM, 'DBA', gname.upper() + '.DBA'), 'rb').read())
        # texel histogram of the random materials (0, 1) -> light curve
        hist = [0] * 256
        for m in (0, 1):
            for v in bmps[mats[m]['texture']]['pixels'][:65536]:
                hist[v] += 1
        base = tabs[flat_level]
        tot_ref = sum(hist[c] * lum(pal[base[c]]) for c in range(256)) or 1.0
        curve = [round(sum(hist[c] * lum(pal[tabs[lv][c]]) for c in range(256)) / tot_ref, 4) for lv in range(lw)]
        # terrain haze colour: what RMP's last haze row maps the ground texels to
        hz = [0.0, 0.0, 0.0]
        tot = float(sum(hist))
        for c in range(256):
            if hist[c]:
                q = pal[tabs[(rows - 1) * lw + flat_level][c]]
                for j in range(3):
                    hz[j] += q[j] * hist[c] / tot
        terrain_haze = [int(round(v)) for v in hz]
        # baked ground textures (flat light level, haze row 0)
        tex_files = []
        for m in (0, 1):
            b = bmps[mats[m]['texture']]
            px = b['pixels'][:65536]
            img = Image.frombytes('RGB', (256, 256), bytes(v for c in px for v in pal[base[c]]))
            fn = 'es2_ground_%d_%d.png' % (n, m)
            img.save(os.path.join(OUT, 'worlds', fn))
            tex_files.append(fn)
        rmp_img = Image.frombytes('L', (256, lw * rows), b''.join(tabs))
        rmp_img.save(os.path.join(OUT, 'worlds', 'es2_rmp_%d.png' % n))

        sky_cols = [w['sky_first'] + i for i in range(w['sky_count'])]
        gnd_cols = [w['ground_first'] + i for i in range(w['ground_count'])]
        wtype = WORLD_TYPES.get(gname, n // 2)
        haze_idx = w['ramps'][0]['haze_start']
        j = {
            'world': n, 'pack': 'es2', 'format': 'WLD v2 (DBSIM 1.0 0x42e010)',
            'terrain': TYPE_NAMES[wtype], 'terrain_type': wtype, 'time_of_day': n & 1,
            'time_of_day_name': 'night' if n & 1 else 'day',
            'header_words': {'word0': n // 2, 'word9': n & 1, 'formula': 'n = word0*2 + word9'},
            'palette_file': 'WORLD%d.DPL' % n,
            'palette_rgb': [list(c) for c in pal],
            'wld': {k: v for k, v in w.items() if k != 'ramps'},
            'ramps': w['ramps'],
            'haze': {
                'object_thresholds': w['haze_dist_objects'], 'terrain_thresholds': w['haze_dist_terrain'],
                'offset_low': w['haze_offset_low'], 'offset_high': w['haze_offset_high'],
                'haze_colour_index': haze_idx,
                'haze_colour_rgb': terrain_haze,
                'object_haze_rgb': list(pal[haze_idx]),
                'terrain_haze_rgb': terrain_haze,
                'fog_begin_units': w['haze_dist_terrain'][0], 'fog_end_units': w['haze_dist_terrain'][-1],
                'note': 'objects: ramp windows slide to haze_start with the level (#thresholds <= distance); '
                        'textured terrain: RMP haze row (12 rows; row 11 = full haze). Engine: linear depth fog '
                        'from the first to the last threshold in terrain_haze_rgb.',
            },
            'light': {'type': 'directional', 'intensity': SUN_INTENSITY, 'euler_rx_ry_rz': list(SUN_EULER),
                      'source': 'DBSIM 0x461240',
                      'vector_assumed_RzRyRx': [round(c, 4) for c in L],
                      'formula': 'I = clamp(256*(1 - dot(n, L))/2, 0, 255); textured: RMP table (31*I)>>8'},
            'sky': {
                'band_indices_top_to_horizon': sky_cols,
                'band_rgb_top_to_horizon': [list(pal[i]) for i in sky_cols],
                'band_px': w['sky_band_px'], 'horizon_offset_px': w['horizon_offset'] / 2,
                'zenith_rgb': list(pal[w['sky_first']]),
                'panorama_dba': None, 'clouds_dba': None,
                'note': 'WLD v2 still names world24/clouds2 but DBSIM 1.0 reads and drops both strings; '
                        'no panorama or cloud layer is drawn',
            },
            'ground': {
                'texture': gname + '.dba', 'texture_count': len(bmps),
                'band_indices_near_to_horizon': gnd_cols,
                'band_rgb_near_to_horizon': [list(pal[i]) for i in gnd_cols],
                'band_px': w['ground_band_px'],
                'materials': mats,
                'random_materials': [0, 1], 'material1_chance': round(MAT1_CHANCE, 4),
                'material_textures_png': tex_files,
                'texel_world_units': mats[0]['texel_units'], 'tile_world_units': mats[0]['tile_units'],
                'rmp_png': 'es2_rmp_%d.png' % n, 'rmp_light_levels': lw, 'rmp_haze_rows': rows,
                'flat_light_intensity': i_flat, 'flat_light_level': flat_level,
                'light_curve': curve,
                'note': 'material_textures_png are baked through RMP[haze 0][flat_light_level]; '
                        'multiply by light_curve[(31*I)>>8] for other slopes',
            },
        }
        write_json(os.path.join(OUT, 'worlds', 'world%d.json' % n), j)
        index.append({'world': n, 'terrain': TYPE_NAMES[wtype], 'time': j['time_of_day_name'],
                      'ground': gname, 'haze_rgb': terrain_haze, 'sky_horizon_rgb': list(pal[sky_cols[-1]])})
        print('world%d  %-8s %-5s ground=%s flat_level=%d haze=%s' % (n, TYPE_NAMES[wtype], j['time_of_day_name'],
                                                                     gname, flat_level, terrain_haze))
    write_json(os.path.join(OUT, 'worlds', '_index.json'), index, indent=1)
    return mats


# -------------------------------------------------------------------------------------- terrain

def read_zone_dat(zone):
    lw, lh, k, s = struct.unpack('<4i', open(os.path.join(ZONES, 'DAT', 'ZONE%d.DAT' % zone), 'rb').read()[:16])
    return lw, lh, k, s


def export_terrain(mats, seed):
    from PIL import Image
    zones = sorted(int(f[4:-4]) for f in os.listdir(os.path.join(ZONES, 'DAT')) if f.upper().startswith('ZONE'))
    index = []
    m0 = mats[0]
    for z in zones:
        lw, lh, k, s = read_zone_dat(z)
        b = gfx.read_any(open(os.path.join(ZONES, 'DBA', 'ZONE%d.DBA' % z), 'rb').read())[0]
        w, h = b['w'], b['h']
        if (1 << lw, 1 << lh) != (w, h):
            # ZONE7000.DAT says 7,7 for a 256x256 bitmap; DBSIM takes the size from the bitmap (0x46c3c0)
            print('  zone %d: DAT size 2^%d x 2^%d != bitmap %dx%d (bitmap wins)' % (z, lw, lh, w, h))
        px = b['pixels'][:w * h]
        sq_u = 1 << k
        sq = sq_u * UNIT_M
        hs = s * UNIT_M
        heights = struct.pack('<%df' % (w * h), *[v * hs for v in px])
        d = os.path.join(OUT, 'terrain', str(z))
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'heights.r32'), 'wb').write(heights)
        # material tiles: one texture repeat (256 texels) = 2^(21-b-k) cells share a random material
        tile_u = m0['tile_units']
        nt_x = max(1, (w * sq_u + tile_u - 1) // tile_u)
        nt_y = max(1, (h * sq_u + tile_u - 1) // tile_u)
        rng = random.Random(seed * 100003 + z)
        mat = bytes(1 if rng.random() < MAT1_CHANCE else 0 for _ in range(nt_x * nt_y))
        Image.frombytes('L', (nt_x, nt_y), mat).save(os.path.join(d, 'materials.png'))
        # hill-shaded preview (north up)
        sh = bytearray(w * h)
        for y in range(h):
            for x in range(w):
                a = px[y * w + max(x - 1, 0)] - px[y * w + min(x + 1, w - 1)]
                c = px[max(y - 1, 0) * w + x] - px[min(y + 1, h - 1) * w + x]
                sh[y * w + x] = max(0, min(255, int(px[y * w + x] * 0.6 + 60 + (a + c) * s / sq_u * 40)))
        Image.frombytes('L', (w, h), bytes(sh)).save(os.path.join(d, 'preview.png'))
        ext_u = [(w - 1) * sq_u, (h - 1) * sq_u]
        t = {
            'zone': z, 'pack': 'es2',
            'heights': 'heights.r32', 'size': [w, h], 'square': sq,
            'origin': [0.0, -(h - 1) * sq], 'height_scale': 1.0,
            'materials': 'materials.png', 'material_tiles': [nt_x, nt_y], 'material_tile_m': tile_u * UNIT_M,
            'material_tile_rows': 'row = original tile y index (row 0 = south edge, original y = 0)',
            'texel_m': m0['texel_units'] * UNIT_M,
            'min_height_m': min(px) * hs, 'max_height_m': max(px) * hs,
            'source': {'dat': 'ZONE%d.DAT' % z, 'dba': 'ZONE%d.DBA' % z, 'log2_w': lw, 'log2_h': lh,
                       'k_log2_square_units': k, 's_height_units_per_step': s},
            'original_extent_units': {'x': [0, ext_u[0]], 'y': [0, ext_u[1]]},
            'notes': 'Grid corner at original (0,0), +x east, +y north; bitmap row 0 = north edge '
                     '(DBSIM 0x46c3c0 flips rows). Vertex = (cx<<k, cy<<k, pixel*s) (0x46d953). '
                     'No wrap: outside the grid there is no terrain (0x46cb2a clamps the drawn area). '
                     'Engine: x = orig x/256, z = -orig y/256, y = height.',
        }
        write_json(os.path.join(d, 'terrain.json'), t, indent=1)
        index.append({'zone': z, 'size': [w, h], 'square_m': sq, 'extent_m': [ext_u[0] * UNIT_M, ext_u[1] * UNIT_M],
                      'height_step_m': hs, 'min_height_m': t['min_height_m'], 'max_height_m': t['max_height_m']})
        print('zone %4d  %dx%d  square %.0f m  extent %.0f m  heights %.1f..%.1f m' % (
            z, w, h, sq, ext_u[0] * UNIT_M, t['min_height_m'], t['max_height_m']))
    write_json(os.path.join(OUT, 'terrain', '_index.json'), index, indent=1)


def main():
    seed = 0
    if '--seed' in sys.argv:
        seed = int(sys.argv[sys.argv.index('--seed') + 1])
    print(verify_exe())
    mats = export_worlds()
    export_terrain(mats, seed)


if __name__ == '__main__':
    main()
