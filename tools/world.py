"""Earth Siege 1 world / environment decoder (WLD + palette ramps + haze + sky + ground + terrain).

Everything here is derived from DBSIM.EXE; see docs/formats/world.md for the spec and addresses.

Usage:
    python tools/world.py info  <world#>                 # print JSON summary
    python tools/world.py dump  <outdir> [world# ...]    # JSON + PNG previews for worlds (default all 0..23)
    python tools/world.py zone  <terrain 0-3|auto> <zone#>  # terrain feature placements of a zone
    python tools/world.py terrain <outdir>               # height-grid PNG/JSON for all DGS terrain shapes

Library:
    w = World(index)            # index = terrain*6 + time*2 + low_detail
    w.palette                   # 256 x (r,g,b) 8-bit, dynamic ranges filled
    w.shaded_index(slot, intensity, haze_level=0, shade_class=None)   -> palette index
    w.shaded_rgb(...)           -> (r,g,b)
    w.haze_level(distance, terrain=False)
    w.light_intensity(normal_xyz)  -> 0..255 (built-in sun)
"""
import json
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
ROOT = P.WORK        # source tree; see tools/siege_paths.py
SIM = os.path.join(ROOT, 'extracted', 'SIMVOL0')
ZONES = os.path.join(ROOT, 'extracted', 'ZONES')

TERRAINS = ['desert', 'temper', 'ice', 'urban']          # DBSIM 0x924a0
# cockpit colour scheme -> COCKPIT.DPL index copied to world 0x40 (DBSIM 0x925dc)
COCKPIT_0x40 = [0x2c, 0x25, 0x2d, 0x27, 0x2d, 0x2d, 0x2d, 0x28]

# Built-in sun (DBSIM 0x5a888): directional light, intensity 256, vector (0,0x800,0) rotated by
# euler (rx=0xe0c0, ry=0, rz=0x5dc0) in 1/65536 turns.  Rotation order assumed Rz*Ry*Rx (as tools/dts_mesh.py).
SUN_EULER = (0xe0c0, 0, 0x5dc0)
SUN_INTENSITY = 256

GROUND_TEXEL_SHIFT = 8      # world units per texel = 1 << 8, texture wraps every 65536 units (DBSIM 0x29437)
GRID_CELL_SHIFT_DEFAULT = 9


# --------------------------------------------------------------------------- low level readers

def _rgb6(c):
    return tuple(min(255, v * 4 + v // 16) for v in c)


def read_dpl_full(path):
    """DPL: header(8) u32 count, count*(r,g,b,flags 6-bit) [, u32 nlists, nlists*(u16 n, n*u16 index)]"""
    d = open(path, 'rb').read()
    typ, cls, size, n = struct.unpack_from('<HHII', d, 0)
    raw = [tuple(d[12 + i * 4:16 + i * 4]) for i in range(n)]
    p = 12 + n * 4
    lists = []
    if p + 4 <= len(d):
        m = struct.unpack_from('<I', d, p)[0]
        p += 4
        for _ in range(m):
            k = struct.unpack_from('<H', d, p)[0]
            p += 2
            lists.append(list(struct.unpack_from('<%dH' % k, d, p)))
            p += 2 * k
    return raw, lists


def read_bitmaps(path):
    import gfx
    return gfx.read_any(open(path, 'rb').read())


class _R:
    def __init__(self, d):
        self.d, self.p = d, 0

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]; self.p += 2; return v

    def s16(self):
        v = struct.unpack_from('<h', self.d, self.p)[0]; self.p += 2; return v

    def s32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v

    def cstr(self):
        e = self.d.index(b'\0', self.p)
        s = self.d[self.p:e].decode('latin1'); self.p = e + 1; return s


def parse_wld(path):
    """WLD file, field order exactly as read by DBSIM 0x251c4."""
    r = _R(open(path, 'rb').read())
    w = {}
    w['horizon_offset'] = r.s16()          # 0x00 -> horizon+0x6c ; bands start (v/2) px off the horizon
    w['sky_first'] = r.s16()               # 0x02 sky ramp first palette index (zenith colour)
    w['sky_band_px'] = r.s16()             # 0x04 sky band thickness (pixels @320x200)
    w['sky_count'] = r.s16()               # 0x06 number of sky bands / ramp length
    w['ground_first'] = r.s16()            # 0x08 ground ramp first palette index (near ground colour)
    w['ground_band_px'] = r.s16()          # 0x0a ground band thickness
    w['ground_count'] = r.s16()            # 0x0c ground ramp length (last = horizon haze)
    w['horizon_field_30'] = r.s16()        # 0x0e -> horizon+0x30 (added to a horizon y coordinate; 0 or 1)
    w['flat_field_15'] = r.s16()           # 0x10 -> obj(0x26dec)+0x15 (always 0xe4..0xfb: a palette index)
    w['flat_variant'] = r.s16()            # 0x12 nonzero -> FLAT2 shape set instead of FLAT (craters/scorch decals)
    w['ambient_low_index'] = r.s16()       # 0x14 palette idx: cockpit ambient colour when looking down
    w['ambient_high_index'] = r.s16()      # 0x16 palette idx: cockpit ambient colour when looking up
    n = r.s32()
    w['haze_dist_objects'] = [r.s32() for _ in range(n)]   # 0x18 thresholds -> haze level 0..15
    n = r.s32()
    w['haze_dist_terrain'] = [r.s32() for _ in range(n)]   # thresholds for class-0 objects (terrain shapes)
    w['haze_levels'] = r.s16()             # 16
    nr = r.s16()                           # 8
    rr = [(r.u16(), r.u16()) for _ in range(nr)]
    nt = r.s16()                           # same as nr
    tt = [(r.u16(), r.u16()) for _ in range(nt)]
    w['ramps'] = [{'start': a, 'count': b, 'haze_start': c, 'haze_count': e} for (a, b), (c, e) in zip(rr, tt)]
    a, b = r.u16(), r.u16()
    c, e = r.u16(), r.u16()
    w['glow_ramp'] = {'start': a, 'count': b, 'haze_start': c, 'haze_count': e}
    w['cloud_count'] = r.s16()             # 0xee  number of cloud billboards (20)
    w['flat_count'] = r.s16()              # 0xf0  pool size for 0x26dec object (250) (crater/scorch decals)
    w['haze_offset_low'] = r.s32()         # 0xf2  added to distance for class-5 (alt<5000) and class-8 objects
    w['haze_offset_high'] = r.s32()        # 0xf6  added to distance for class-5 objects with alt>=5000
    w['panorama'] = r.cstr()               # DBA of distant mountain strips (empty = none, low detail)
    w['clouds'] = r.cstr()                 # DBA of cloud bitmaps
    w['impact_palette'] = r.cstr()         # DPL swapped in for the hit flash
    w['ground_texture'] = r.cstr()         # dba\<name>.64k
    w['ground_haze_dat'] = r.cstr()        # DAT: distance thresholds for the 15 ground haze tables
    w['_trailing'] = len(r.d) - r.p
    return w


def haze_ramp_table(levels, ramps):
    """DBSIM 0x289e0: for each ramp and haze level k, the palette sub-range used by shaded polys.
    returns [ramp][level] = (start, count)"""
    out = []
    n1 = levels - 1
    for rp in ramps:
        s, c, ts, tc = rp['start'], rp['count'], rp['haze_start'], rp['haze_count']
        e, te = s + c - 1, ts + tc - 1
        ds = ((ts - s + 1) << 8) // n1 if n1 else 0
        de = ((te - e + 1) << 8) // n1 if n1 else 0
        row = []
        for k in range(n1):
            a = s + ((k * ds) >> 8)
            b = e + ((k * de) >> 8)
            row.append((a, b - a + 1))
        row.append((ts, te - ts + 1))
        out.append(row)
    return out


def read_shades_dat(path=None):
    """SHADES.DAT (DBSIM 0x25bc8): u8 nclasses, u8 nrec, nrec*(u8 class, u8 n, n*(u8 slot, u8 ramp))."""
    d = open(path or os.path.join(SIM, 'DAT', 'SHADES.DAT'), 'rb').read()
    ncls, nrec = d[0], d[1]
    p = 2
    classes = {i: [] for i in range(ncls)}
    for _ in range(nrec):
        c, n = d[p], d[p + 1]
        p += 2
        classes[c] = [(d[p + 2 * i], d[p + 2 * i + 1]) for i in range(n)]
        p += 2 * n
    return classes


def read_u32_list(path):
    d = open(path, 'rb').read()
    n = struct.unpack_from('<I', d, 0)[0]
    return list(struct.unpack_from('<%dI' % n, d, 4))


def euler_matrix(rx, ry, rz):
    k = 2 * math.pi / 65536.0
    ax, ay, az = rx * k, ry * k, rz * k
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    Rx = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]]
    Ry = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
    Rz = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]]

    def mm(a, b):
        return [[sum(a[i][k2] * b[k2][j] for k2 in range(3)) for j in range(3)] for i in range(3)]
    return mm(mm(Rz, Ry), Rx)


def sun_vector():
    m = euler_matrix(*SUN_EULER)
    v = (0, 1.0, 0)
    return tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))


# --------------------------------------------------------------------------- terrain (DGS grid shapes)

def read_dgs_objects(d):
    """Top-level objects of a DGS file.  Objects are word aligned: an odd-sized object is followed by
    one pad byte (dts.read_file does not skip it and desyncs on TEMPER/ICE/URBAN.DGS)."""
    import dts
    r = dts.Reader(d)
    objs = []
    while r.p + 8 <= len(d):
        objs.append(dts.read_obj(r))
        r.p += r.p & 1
    return objs


def read_grid_shapes(terrain):
    """Returns list of dicts {index, radius, center, grid:{cols,rows,origin_col,origin_row,cell_shift,
    height_table[256], heights[rows][cols]}, lods} for <terrain>.DGS"""
    import dts
    d = open(os.path.join(SIM, 'DGS', terrain.upper() + '.DGS'), 'rb').read()
    out = []
    for i, o in enumerate(read_dgs_objects(d)):
        e = {'index': i, 'type': o['type'], 'radius': o.get('radius'), 'center': o.get('center')}
        if o['type'] == 'grid_shape':
            # GridShape::read (0x1ff48) = TSShape::read (part list, u16 ntl, u16 nseq, seq[], tl[]) + grid
            st = o['_off'] + 8 + o.get('_consumed', o['_size'])
            end = o['_off'] + 8 + o['_size']
            if o.get('_consumed') is not None:
                ntl, nsl = struct.unpack_from('<HH', d, st)
                st += 4 + 2 * (ntl + nsl)
            if st + 10 + 1024 <= end:
                cols, rows, ox, oy, sh = struct.unpack_from('<5h', d, st)
                tab = list(struct.unpack_from('<256I', d, st + 10))
                g = d[st + 1034:st + 1034 + cols * rows]
                e['grid'] = {'cols': cols, 'rows': rows, 'origin_col': ox, 'origin_row': oy, 'cell_shift': sh,
                             'cell_size': 1 << sh, 'height_table': tab,
                             'heights': [list(g[r * cols:(r + 1) * cols]) for r in range(rows)],
                             'extra_bytes': end - (st + 1034 + cols * rows)}
            kids = o['parts'][0]['parts'] if o['parts'] and o['parts'][0]['type'] == 'detail_part' else o['parts']
            e['lods'] = len(kids)
        out.append(e)
    return out


def grid_height(gs, x, y):
    """Bilinear height (shape units) at shape-local (x, y) from a grid entry; None outside."""
    g = gs['grid']
    fx = x / g['cell_size'] + g['origin_col']
    fy = y / g['cell_size'] + g['origin_row']
    c0, r0 = int(math.floor(fx)), int(math.floor(fy))
    if not (0 <= c0 < g['cols'] - 1 and 0 <= r0 < g['rows'] - 1):
        return None
    tx, ty = fx - c0, fy - r0
    H = g['heights']
    t = g['height_table']
    h00, h10, h01, h11 = t[H[r0][c0]], t[H[r0][c0 + 1]], t[H[r0 + 1][c0]], t[H[r0 + 1][c0 + 1]]
    return (h00 * (1 - tx) + h10 * tx) * (1 - ty) + (h01 * (1 - tx) + h11 * tx) * ty


def read_terrain_dat(terrain):
    """<TERRAIN>.DAT: one 24-byte record per DGS shape: two points (i32 x,y,z); z=-1 => no record."""
    d = open(os.path.join(SIM, 'DAT', terrain.upper() + '.DAT'), 'rb').read()
    out = []
    for i in range(len(d) // 24):
        v = struct.unpack_from('<6i', d, i * 24)
        out.append(None if v[2] < 0 else {'a': v[0:3], 'b': v[3:6]})
    return out


def read_zone(zone, terrain_type=None):
    """ZONE<n>.DAT (DBSIM 0x20238): u16 terrain type (0..3; the sim uses the mission's value instead),
    u16 count, count*(u16 shape index into <terrain>.DGS, i32 x,y,z, u16 rx,ry,rz 1/65536 turn)."""
    for base in (os.path.join(SIM, 'DAT'), os.path.join(ZONES, 'DAT')):
        p = os.path.join(base, 'ZONE%d.DAT' % zone)
        if os.path.exists(p):
            break
    else:
        raise FileNotFoundError('ZONE%d.DAT' % zone)
    d = open(p, 'rb').read()
    unk, n = struct.unpack_from('<Hh', d, 0)
    if terrain_type is None:
        terrain_type = unk if unk < 4 else 0
    terr = TERRAINS[terrain_type]
    shapes = read_grid_shapes(terr)
    out = []
    for i in range(n):
        s, x, y, z, rx, ry, rz = struct.unpack_from('<h3i3H', d, 4 + 20 * i)
        out.append({'shape': s, 'pos': [x, y, z], 'rot': [rx, ry, rz],
                    'radius': shapes[s]['radius'] if 0 <= s < len(shapes) else None})
    return {'file': p, 'header_terrain_type': unk, 'terrain': terr, 'dgs': terr.upper() + '.DGS', 'objects': out}


# --------------------------------------------------------------------------- the world

CANDIDATES = [i for i in range(256) if not 0x20 <= i <= 0x4f]


class World:
    def __init__(self, index, cockpit_scheme=0):
        self.index = index
        self.terrain_type = index // 6
        self.time_of_day = (index % 6) // 2
        self.low_detail = index & 1
        self.wld = parse_wld(os.path.join(SIM, 'WLD', 'WORLD%d.WLD' % index))
        self.palette_name = 'WORLD%d' % (index & ~1)       # DBSIM 0x251ee: palette index excludes the detail bit
        raw, self.dpl_lists = read_dpl_full(os.path.join(SIM, 'DPL', self.palette_name + '.DPL'))
        self.raw_palette = [list(c) for c in raw]
        self.cockpit_scheme = cockpit_scheme
        self._fill_dynamic()
        self.palette = [_rgb6(c[:3]) for c in self.raw_palette]
        w = self.wld
        self.ramp_table = haze_ramp_table(w['haze_levels'], w['ramps'])
        self.glow_table = haze_ramp_table(w['haze_levels'], [w['glow_ramp']])[0]
        self.shades = read_shades_dat()
        self.ground_haze_dist = read_u32_list(os.path.join(SIM, 'DAT', w['ground_haze_dat'].upper() + '.DAT'))
        self.ground_tables = self._ground_tables()

    # -- palette ---------------------------------------------------------------------------
    def _fill_dynamic(self):
        """0x20-0x2F / 0x40-0x4F are copied from COCKPIT.DPL (DBSIM 0x220d6); 0x40 is then a single
        cockpit colour and 0x40-0x4F is rewritten every frame with the cockpit ambient gradient (0x25fe4)."""
        ck, _ = read_dpl_full(os.path.join(SIM, 'DPL', 'COCKPIT.DPL'))
        k = self.cockpit_scheme
        for i in range(16):
            self.raw_palette[0x20 + i] = list(ck[k * 32 + i])
            self.raw_palette[0x40 + i] = list(ck[k * 32 + 16 + i])
        self.raw_palette[0x40] = list(ck[COCKPIT_0x40[k]])
        self._cockpit_ambient(pitch_level=8)

    def _cockpit_ambient(self, pitch_level):
        """0x25fe4: c = lerp(pal[ambient_low], pal[ambient_high], pitch_level/15) (pitch_level =
        (pitch+0x2000)>>10, clamped 0..15); pal[0x40..0x4F] = lerp(pal[0x40], c, i/15)."""
        w = self.wld

        def lerp_tab(a, b, n):
            # 0x283b0: 8.8 fixed point per-channel gradient, last entry = b exactly
            out = []
            st = [int(((b[j] - a[j]) * 256) / (n - 1)) for j in range(3)]     # C idiv truncates
            for i in range(n - 1):
                out.append([a[j] + ((i * st[j]) >> 8) for j in range(3)])
            out.append(list(b[:3]))
            return out
        lo = self.raw_palette[w['ambient_low_index']][:3]
        hi = self.raw_palette[w['ambient_high_index']][:3]
        base = self.raw_palette[0x40][:3]
        c = lerp_tab(lo, hi, 16)[max(0, min(15, pitch_level))]
        for i, v in enumerate(lerp_tab(base, c, 16)):
            self.raw_palette[0x40 + i] = v + [self.raw_palette[0x40 + i][3]]

    def solid_rgb(self, index):
        return self.palette[index]

    # -- shading ---------------------------------------------------------------------------
    def slot_list(self, slot, haze_level=0, shade_class=None):
        """Palette index list behind a shaded colour 'slot' (byte0 of a 3Space shaded colour).
        Default = DPL shade list <slot>; SHADES.DAT class entries override some slots with a WLD ramp
        window that slides toward the haze colour with haze_level (DBSIM 0x25d44 / 0x28044)."""
        if shade_class is not None:
            for s, ramp in self.shades.get(shade_class, []):
                if s == slot:
                    a, n = self.ramp_table[ramp][haze_level]
                    return list(range(a, a + n))
        if 0 <= slot < len(self.dpl_lists):
            return self.dpl_lists[slot]
        return [slot]

    def shaded_index(self, slot, intensity, haze_level=0, shade_class=None):
        """DBSIM 0x68ce8: index = list[(intensity * len(list)) >> 8], intensity 0..255."""
        lst = self.slot_list(slot, haze_level, shade_class)
        return lst[min(len(lst) - 1, (max(0, min(255, intensity)) * len(lst)) >> 8)]

    def shaded_rgb(self, slot, intensity, haze_level=0, shade_class=None):
        return self.palette[self.shaded_index(slot, intensity, haze_level, shade_class)]

    def haze_level(self, distance, terrain=False, offset=0):
        """DBSIM 0x25cb4: number of thresholds passed (0..15)."""
        t = self.wld['haze_dist_terrain' if terrain else 'haze_dist_objects']
        d = max(0, distance + offset)
        k = 0
        while k < len(t) - 1 and d >= t[k]:
            k += 1
        return k

    @staticmethod
    def light_intensity(normal, sun=None, intensity=SUN_INTENSITY, ambient=0):
        """DBSIM 0x5bc30, directional light: I += intensity * (1 - n.L)/2 ; clamp to 255.
        n = unit normal, L = light vector (points from the sun into the scene)."""
        L = sun or sun_vector()
        nl = sum(a * b for a, b in zip(normal, L)) / (math.sqrt(sum(a * a for a in normal)) or 1)
        return int(max(0, min(255, ambient + intensity * (1 - nl) / 2)))

    def texture_light_tables(self):
        """DBSIM 0x28b27: 8 remap tables (light level 0..7) for textured polys; table chosen by
        7*I/255.  Colour c in DPL list (last list containing it wins) is scaled per channel by
        rgb(list[(n-1)*L/7]) / rgb(list[round((n-1)*650/1024)]) and re-matched to the nearest colour."""
        pal = [c[:3] for c in self.raw_palette]
        tables = []
        for L in range(8):
            t = []
            for c in range(256):
                found = None
                for lst in self.dpl_lists:
                    if c in lst:
                        found = lst
                if found is None:
                    t.append(c)
                    continue
                n = len(found)
                tgt = pal[found[(n - 1) * L // 7]]
                ref = pal[found[((n - 1) * 650 + 512) >> 10]]
                ratio = [((tgt[j] << 10) // ref[j]) if ref[j] else 0 for j in range(3)]
                want = [(pal[c][j] * ratio[j] + 512) >> 10 for j in range(3)]
                # 0x20-0x4F belong to the cockpit colour block at runtime: never remap world colours there
                best = min(CANDIDATES, key=lambda i: sum((pal[i][j] - want[j]) ** 2 for j in range(3)))
                t.append(best)
            tables.append(t)
        return tables

    # -- ground -----------------------------------------------------------------------------
    def _ground_tables(self):
        """DBSIM 0x28ef2: 15 tables x 16 entries: texel (low nibble i) at haze band j ->
        base + i + ((top - (base+i)) * j) / 14, base = ground_first & 0xF0, top = ground_first+count-1."""
        w = self.wld
        base = w['ground_first'] & 0xf0
        top = w['ground_first'] + w['ground_count'] - 1
        nb = 15
        out = []
        for j in range(nb):
            row = []
            for i in range(16):
                s = top - (i + base)
                q = int(s * j / (nb - 1))      # C division truncates toward zero
                row.append(base + i + q)
            out.append(row)
        return out

    def ground_band(self, distance):
        """DBSIM 0x294d0: j = number of TEX.DAT thresholds passed, max 14."""
        t = self.ground_haze_dist
        j = 0
        while j < 14 and distance >= t[j]:
            j += 1
        return j

    def ground_texture(self):
        return open(os.path.join(SIM, 'DBA', self.wld['ground_texture'].upper() + '.64K'), 'rb').read()

    # -- summary ----------------------------------------------------------------------------
    def to_json(self):
        w = self.wld
        sv = sun_vector()
        sky_cols = [w['sky_first'] + i for i in range(w['sky_count'])]
        gnd_cols = [w['ground_first'] + i for i in range(w['ground_count'])]
        classes = {}
        for cls, pairs in self.shades.items():
            if pairs:
                classes[cls] = {str(s): [list(range(a, a + n)) for a, n in (self.ramp_table[r][h] for h in range(w['haze_levels']))]
                                for s, r in pairs}
        return {
            'world': self.index, 'terrain': TERRAINS[self.terrain_type], 'terrain_type': self.terrain_type,
            'time_of_day': self.time_of_day, 'low_detail': bool(self.low_detail),
            'palette_file': self.palette_name + '.DPL', 'cockpit_scheme_used': self.cockpit_scheme,
            'palette_rgb': [list(c) for c in self.palette],
            'wld': {k: v for k, v in w.items() if k != 'ramps'},
            'ramps': w['ramps'],
            'dpl_shade_lists': {str(i): l for i, l in enumerate(self.dpl_lists) if l != [255]},
            'haze': {
                'object_thresholds': w['haze_dist_objects'], 'terrain_thresholds': w['haze_dist_terrain'],
                'offset_low': w['haze_offset_low'], 'offset_high': w['haze_offset_high'],
                'haze_colour_index': w['ramps'][0]['haze_start'],
                'haze_colour_rgb': list(self.palette[w['ramps'][0]['haze_start']]),
                'ramp_windows': self.ramp_table,      # [ramp][level] = (start, count)
                'glow_windows': self.glow_table,
            },
            'shade_classes': {str(k): v for k, v in self.shades.items()},
            'shade_class_slot_lists': {str(k): v for k, v in classes.items()},   # [class][slot][level] -> indices
            'light': {'type': 'directional', 'intensity': SUN_INTENSITY, 'euler_rx_ry_rz': SUN_EULER,
                      'vector_assumed_RzRyRx': [round(c, 4) for c in sv],
                      'formula': 'I = clamp(256*(1 - dot(n, L))/2, 0, 255); index = list[I*len(list)>>8]'},
            'sky': {
                'band_indices_top_to_horizon': sky_cols,
                'band_rgb_top_to_horizon': [list(self.palette[i]) for i in sky_cols],
                'band_px': w['sky_band_px'], 'horizon_offset_px': w['horizon_offset'] / 2,
                'zenith_rgb': list(self.palette[w['sky_first']]),
                'panorama_dba': w['panorama'] or None,
                'clouds_dba': w['clouds'], 'cloud_count': w['cloud_count'],
                'cloud_layer': {'altitude': 10000, 'ring_step': 25000, 'max_radius': 200000, 'quad_half_size': 25000,
                                'drift_speed': '50..149 (random)', 'bitmap': 'random 0..2'},
            },
            'ground': {
                'texture': w['ground_texture'] + '.64k', 'texel_world_units': 1 << GROUND_TEXEL_SHIFT,
                'band_indices_near_to_horizon': gnd_cols,
                'band_rgb_near_to_horizon': [list(self.palette[i]) for i in gnd_cols],
                'band_px': w['ground_band_px'],
                'haze_dat': w['ground_haze_dat'] + '.dat', 'haze_band_distances': self.ground_haze_dist,
                'haze_tables': self.ground_tables, 'nearest_horizon_rows_full_haze': w['horizon_offset'] // 2,
            },
            'terrain_features': {'dgs': TERRAINS[self.terrain_type].upper() + '.DGS',
                                 'dat': TERRAINS[self.terrain_type].upper() + '.DAT'},
        }


# --------------------------------------------------------------------------- engine lookup images

SHADE_IMAGE_COLUMNS = 32     # engine/shaders/shaded.gdshader samples column int(I * 32)


def make_shade_list_image(lists):
    """DPL shade slot lists as the engine's L8 image (32 x 256): row = slot, column c holds
    list[((c*8+4)*len)>>8], i.e. DBSIM 0x68ce8's list[(I*len)>>8] sampled at the column centre.
    A slot without a list maps to itself."""
    from PIL import Image
    img = Image.new('L', (SHADE_IMAGE_COLUMNS, 256))
    for r in range(256):
        lst = lists[r] if r < len(lists) and lists[r] else [r]
        for c in range(SHADE_IMAGE_COLUMNS):
            img.putpixel((c, r), lst[min(len(lst) - 1, ((c * 8 + 4) * len(lst)) >> 8)])
    return img


def make_light_table_image(tables):
    """Textured-poly light remap tables as the engine's L8 image (256 x len(tables)): row = light level."""
    from PIL import Image
    return Image.frombytes('L', (256, len(tables)), b''.join(bytes(t) for t in tables))


# --------------------------------------------------------------------------- previews

def _pal_img(pal):
    from PIL import Image
    im = Image.new('RGB', (16 * 12, 16 * 12))
    px = im.load()
    for i in range(256):
        for y in range(12):
            for x in range(12):
                px[(i % 16) * 12 + x, (i // 16) * 12 + y] = tuple(pal[i])
    return im


def render_preview(w, path, cam_h=1500, focal=200, heading=0x2000, size=(320, 200), scale=3):
    """Software preview: sky bands, panorama strip, perspective ground texture with band haze."""
    from PIL import Image
    W, H = size
    hz = H // 2 - 10
    pal = w.palette
    img = Image.new('RGB', (W, H))
    px = img.load()
    wl = w.wld
    # sky
    for y in range(hz):
        k = (hz - 1 - y - wl['horizon_offset'] // 2) // max(1, wl['sky_band_px'])
        k = max(0, k)
        idx = wl['sky_first'] + wl['sky_count'] - 1 - k if k < wl['sky_count'] else wl['sky_first']
        for x in range(W):
            px[x, y] = pal[idx]
    # panorama: 1280 px per turn, bottom on horizon
    if wl['panorama']:
        strips = read_bitmaps(os.path.join(SIM, 'DBA', wl['panorama'].upper() + '.DBA'))
        tot = sum(b['w'] for b in strips)
        x0 = heading * tot // 65536
        for x in range(W):
            u = (x0 + x) % tot
            for b in strips:
                if u < b['w']:
                    break
                u -= b['w']
            for yy in range(b['h']):
                c = b['pixels'][yy * b['w'] + u]
                if c:
                    y = hz - b['h'] + yy
                    if 0 <= y < H:
                        px[x, y] = pal[c]
    # ground
    tex = w.ground_texture()
    ch, sh = math.cos(heading * 2 * math.pi / 65536), math.sin(heading * 2 * math.pi / 65536)
    for y in range(hz, H):
        dy = y - hz + 0.5
        dist = cam_h * focal / dy
        j = 14 if (y - hz) < wl['horizon_offset'] // 2 else w.ground_band(dist)
        tab = w.ground_tables[j]
        for x in range(W):
            dx = (x - W / 2) * dist / focal
            wx = sh * dist + ch * dx
            wy = ch * dist - sh * dx
            u = (int(wx) >> 8) & 255
            v = (int(wy) >> 8) & 255
            t = tex[v * 256 + u]
            px[x, y] = pal[tab[t & 15]]
    img.resize((W * scale, H * scale), Image.NEAREST).save(path)


def dump_world(w, outdir):
    from PIL import Image
    import gfx
    os.makedirs(outdir, exist_ok=True)
    j = w.to_json()
    with open(os.path.join(outdir, 'world%d.json' % w.index), 'w') as f:
        json.dump(j, f, indent=1)
    _pal_img(w.palette).save(os.path.join(outdir, 'world%d_palette.png' % w.index))
    # ramp windows at haze levels 0..15 (rows) per ramp
    ramps = w.ramp_table
    im = Image.new('RGB', (len(ramps) * 20 * 4, 16 * 8))
    px = im.load()
    for r, row in enumerate(ramps):
        for lvl, (a, n) in enumerate(row):
            for x in range(80):
                idx = a + min(n - 1, x * n // 80)
                for yy in range(8):
                    px[r * 80 + x, lvl * 8 + yy] = w.palette[idx]
    im.save(os.path.join(outdir, 'world%d_ramps.png' % w.index))
    # ground texture with band 0 and band 14
    tex = w.ground_texture()
    im = Image.new('RGB', (512, 256))
    px = im.load()
    for v in range(256):
        for u in range(256):
            t = tex[v * 256 + u] & 15
            px[u, v] = w.palette[w.ground_tables[0][t]]
            px[256 + u, v] = w.palette[w.ground_tables[10][t]]
    im.save(os.path.join(outdir, 'world%d_ground.png' % w.index))
    render_preview(w, os.path.join(outdir, 'world%d_view.png' % w.index))


def dump_terrain(outdir):
    from PIL import Image
    os.makedirs(outdir, exist_ok=True)
    for t in TERRAINS:
        shapes = read_grid_shapes(t)
        dat = read_terrain_dat(t)
        js = []
        for s in shapes:
            e = {k: v for k, v in s.items() if k != 'grid'}
            e['dat_points'] = dat[s['index']] if s['index'] < len(dat) else None
            if 'grid' in s:
                g = s['grid']
                e['grid'] = g
                im = Image.new('L', (g['cols'], g['rows']))
                im.putdata([v for row in g['heights'] for v in row])
                im = im.transpose(Image.FLIP_TOP_BOTTOM)        # row 0 = -y (south) at the bottom
                im.resize((g['cols'] * 6, g['rows'] * 6), Image.NEAREST).save(
                    os.path.join(outdir, '%s_%02d_grid.png' % (t, s['index'])))
            js.append(e)
        with open(os.path.join(outdir, '%s_terrain.json' % t), 'w') as f:
            json.dump(js, f)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'info'
    if cmd == 'info':
        w = World(int(sys.argv[2]) if len(sys.argv) > 2 else 0)
        j = w.to_json()
        j.pop('palette_rgb')
        j.pop('shade_class_slot_lists')
        print(json.dumps(j, indent=1)[:20000])
    elif cmd == 'dump':
        out = sys.argv[2]
        idx = [int(a) for a in sys.argv[3:]] or list(range(24))
        for i in idx:
            dump_world(World(i), out)
            print('world', i, 'done')
        dump_terrain(os.path.join(out, 'terrain'))
    elif cmd == 'zone':
        t = None if sys.argv[2] in ('-', 'auto') else int(sys.argv[2])
        print(json.dumps(read_zone(int(sys.argv[3]), t), indent=1))
    elif cmd == 'terrain':
        dump_terrain(sys.argv[2])
    else:
        print(__doc__)
