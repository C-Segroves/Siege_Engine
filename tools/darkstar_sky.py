"""Darkstar skies (Starsiege: Tribes 1998, Starsiege 1999) -> engine map schema "environment.darkstar_sky".

    import darkstar_sky as DS
    env['darkstar_sky'] = DS.tribes_sky(F, find, ppl, terrain_fields, out_dir)      # Tribes text .mis
    env['darkstar_sky'] = DS.starsiege_sky(F, find, ppl, out_dir)                   # Starsiege binary .mis
    env.update(DS.starsiege_mission_sky(mis_path, ppl_name, out_dir))               # campaign helper

F(cls) -> mission objects of that class (tools/darkstar_mis.py), find(name) -> file bytes (case-insensitive VOL
lookup), ppl = the mission's world palette (darkstar_gfx.read_ppl).

How Darkstar draws the sky (RE of tribes.exe 1.11 / Starsiege.exe 1.0003; Borland flat model):

Sky object (Tribes persist fields @0x472d9c: dmlName +0xa8, skyColor +0xb8, hazeColor +0xc4, featurePosition
+0x11c, size +0x124, textures[16] +0xdc; console help "Sky: [colR colG colB] [dmlFileName rotZ i1 ... i16]";
Starsiege @0x572dec adds distance +0x128 and names the DML by a Mission.Strings.cs tag, "matListTag"):
  * a ring of 16 flat panels around the camera.  Corner k (0x473908 / SS 0x573454) is at math angle
    a_k = 90 + featurePosition - 22.5 - 22.5 k degrees (CCW from east, Darkstar x east / y north), so the panels
    run clockwise seen from above; ring radius r = 1.5 x the terrain's visible distance (Tribes 0x473923, the
    "distance" field read by the Tribes .mis loader is not a persist field there), r = distance (Starsiege).
  * panel k is a quad from corner k to corner k+1 textured with DML material textures[k] % count
    (idiv @0x473718), u 0 -> 1 from corner k to k+1, v 0 at the top (uv table @0x473828).
  * Tribes heights (0x4731e0): panel bottom z = -size/8, top z = +0.75 size relative to the camera
    (0x473271 x0.125, 0x473320 +0.875).  Starsiege (0x573514): bottom on the horizon, top = size, the
    whole sky scaled by 1.45 x far / distance (angles unchanged).
  * a cone from the top edge to the zenith and from the bottom edge to the nadir, flat-filled
    (0x473613 / 0x4735c8) with the colour of the first panel bitmap's first pixel of row 0 (top) / last row
    (bottom) (0x473808); without a DML the colours are skyColor / hazeColor matched into the palette (0x472f6c).
    Between the cones, untextured skies show the screen clear (the haze colour).
Planet object (Tribes @0x478256: fileName, azimuth +0x6c, incidence +0x70 clamped to +-89, size +0x128,
distance +0x12c; Starsiege SKPL: u32 bitmap tag, f32 azimuth, incidence, u16 flags, f32 intensity[3],
ambient[3], size, distance): direction (0x4777c4) = (cos(az + 90) cos(inc), sin(az + 90) cos(inc), sin(inc)),
i.e. azimuth runs from north toward WEST; a billboard of `size` at `distance` (angular diameter
2 atan(size / 2 distance)).  PBMP flag bit 0 = colour 0 transparent (lushdaysun, niteplanet_256 ...).
StarField (Tribes: inFrontOfSky, colors[3]; Starsiege SKSF: u8 inFrontOfSky + f32 colors[3][3]): procedural
stars in three brightness classes; drawn over the panels when inFrontOfSky.
"""
import math
import os
import re
import struct

import numpy as np
from PIL import Image

import darkstar_dts as D
import darkstar_gfx as G
import darkstar_mis as M

PANELS = 16
PANEL_DEG = 22.5
FIRST_CORNER_DEG = 90.0 - PANEL_DEG          # 0x47392f: 90 + featurePosition - 22.5
TRIBES_RING_PER_VISIBLE = 1.5                # 0x473923
TRIBES_BAND_BOTTOM = -0.125                  # x size, 0x473271
TRIBES_BAND_TOP = 0.75                       # x size, -0.125 + 0.875 (0x473320)
TRIBES_DEFAULT_SKY_SIZE = 14000.0            # Sky constructor 0x4726fc
TRIBES_DEFAULT_VISIBLE = 450.0
PLANET_MAX_INCIDENCE = 89.0                  # 0x47779d
TRANSPARENT_FLAG = 1                         # PBMP head flags bit 0: colour index 0 is transparent
PANELS_FILE = 'sky_panels.png'
PLANET_FILE = 'sky_planet_%d.png'
MAX_PLANETS = 4                              # engine shader slots


# ============================================================================================== bitmaps
def _bitmap(find, name, ppl):
    """(rgb uint8 HxWx3, alpha uint8 HxW, top rgb, bottom rgb) of a PBMP through the world palette, or None."""
    data = find(name) if name else None
    if not data:
        return None
    try:
        b = G.read_pbmp(data)
    except (AssertionError, struct.error, KeyError):
        return None
    if 'pixels' not in b:
        return None
    pal = np.array(G.palette_for(ppl, b['palette_id'])['colors'], np.uint8)
    idx = np.frombuffer(b['pixels'], np.uint8).reshape(b['h'], b['w'])
    alpha = np.where(idx == 0, 0, 255).astype(np.uint8) if b.get('flags', 0) & TRANSPARENT_FLAG else \
        np.full(idx.shape, 255, np.uint8)
    return pal[idx], alpha, [int(c) for c in pal[idx[0, 0]]], [int(c) for c in pal[idx[-1, 0]]]


def _material_files(find, dml_name):
    data = find(dml_name) if dml_name else None
    if not data:
        return []
    ml = D.read_shape(data)['material_list']
    return [m['file'] for m in ml['materials'][:ml['count']]]


def _color255(c):
    return [int(round(min(1.0, max(0.0, float(x))) * 255)) for x in (c or [0, 0, 0])[:3]]


# ============================================================================================== panels
def write_panel_strip(find, ppl, dml_name, slots, out_dir):
    """Writes the 16 panels side by side (slot k at x = k * w) and returns {top_color, bottom_color} from the
    first panel bitmap as the original fills its cones, or {} when the DML has no usable bitmap."""
    files = _material_files(find, dml_name)
    if not files:
        return {}
    bitmaps = [_bitmap(find, f, ppl) for f in files]
    panels = [bitmaps[s % len(bitmaps)] if s >= 0 else None for s in slots]
    first = next((p for p in panels if p is not None), None)
    if first is None:
        return {}
    h, w = first[0].shape[:2]
    strip = np.zeros((h, w * PANELS, 3), np.uint8)
    for k, p in enumerate(panels):
        img = p[0] if p is not None else np.repeat(first[0][:, :1], w, 1)
        if img.shape[:2] != (h, w):
            img = np.asarray(Image.fromarray(img).resize((w, h), Image.BILINEAR))
        strip[:, k * w:(k + 1) * w] = img
    os.makedirs(out_dir, exist_ok=True)
    Image.fromarray(strip).save(os.path.join(out_dir, PANELS_FILE))
    return {'panels': PANELS_FILE, 'top_color': first[2], 'bottom_color': first[3]}


def make_band(feature_deg, bottom_h, top_h):
    """Ring geometry for the engine: first corner angle, panel bottom/top heights per ring radius."""
    return {'first_corner_deg': round(FIRST_CORNER_DEG + feature_deg, 4), 'panel_deg': PANEL_DEG,
            'band_bottom': round(bottom_h, 5), 'band_top': round(top_h, 5)}


# ============================================================================================== planets / stars
def make_planet_dir(azimuth, incidence):
    """Engine-frame unit vector toward a Planet (0x4777c4: azimuth + 90 deg from east, CCW)."""
    inc = math.radians(max(-PLANET_MAX_INCIDENCE, min(PLANET_MAX_INCIDENCE, incidence)))
    a = math.radians(azimuth + 90.0)
    ds = (math.cos(a) * math.cos(inc), math.sin(a) * math.cos(inc), math.sin(inc))
    return [round(ds[0], 5), round(ds[2], 5), round(-ds[1], 5)]          # Darkstar (x, y, z) -> engine (x, z, -y)


def write_planet(find, ppl, bitmap_name, planet, slot, out_dir):
    """Writes sky_planet_<slot>.png; returns its engine entry or None (no bitmap, zero size)."""
    size, distance = float(planet.get('size') or 0), float(planet.get('distance') or 0)
    bm = _bitmap(find, bitmap_name, ppl)
    if bm is None or size <= 0 or distance <= 0:
        return None
    rgba = np.dstack([bm[0], bm[1]])
    name = PLANET_FILE % slot
    os.makedirs(out_dir, exist_ok=True)
    Image.fromarray(rgba, 'RGBA').save(os.path.join(out_dir, name))
    return {'image': name, 'bitmap': bitmap_name, 'dir': make_planet_dir(planet['azimuth'], planet['incidence']),
            'radius_deg': round(math.degrees(math.atan2(size * 0.5, distance)), 4)}


def make_stars(colors, in_front):
    return {'colors': [_color255(c) for c in colors[:3]], 'in_front': bool(in_front)}


# ============================================================================================== Tribes
def tribes_sky(F, find, ppl, terrain, out_dir):
    """Sky / Planet / StarField objects of a Tribes text mission -> darkstar_sky dict (writes the images)."""
    skies = F('Sky')
    f = skies[0]['fields'] if skies else {}
    size = float(f.get('size', TRIBES_DEFAULT_SKY_SIZE) or TRIBES_DEFAULT_SKY_SIZE)
    ring = TRIBES_RING_PER_VISIBLE * float(terrain.get('visibleDistance', TRIBES_DEFAULT_VISIBLE) or
                                           TRIBES_DEFAULT_VISIBLE)
    slots = [int(float(f.get('textures[%d]' % k, -1))) for k in range(PANELS)]
    sky = make_band(float(f.get('featurePosition', 0) or 0), TRIBES_BAND_BOTTOM * size / ring,
                    TRIBES_BAND_TOP * size / ring)
    sky.update({'panels': None, 'top_color': _color255(M.vec(f.get('skyColor', '0 0 0'))),
                'bottom_color': _color255(M.vec(f.get('hazeColor', '0 0 0'))),
                'source': 'Sky dml=%s size=%g ring=%g' % (f.get('dmlName', ''), size, ring)})
    sky.update(write_panel_strip(find, ppl, f.get('dmlName', ''), slots, out_dir))
    planets = []
    for o in F('Planet'):
        p = o['fields']
        name = p.get('fileName', '')
        if name and len(planets) < MAX_PLANETS:
            entry = write_planet(find, ppl, name, {'azimuth': float(p.get('azimuth', 0)),
                                                   'incidence': float(p.get('incidence', 0)),
                                                   'size': p.get('size'), 'distance': p.get('distance')},
                                 len(planets), out_dir)
            if entry:
                planets.append(entry)
    sky['planets'] = planets
    stars = F('StarField')
    sky['stars'] = make_stars([M.vec(stars[0]['fields'].get('colors[%d]' % k, '1 1 1')) for k in range(3)],
                              str(stars[0]['fields'].get('inFrontOfSky', 'true')).lower() == 'true') if stars else None
    return sky


# ============================================================================================== Starsiege
_tags = {}


def load_tags(find):
    """Mission.Strings.cs resource tags (IDDML_SKY_* / IDBMP_SKY_*): number -> file name."""
    if not _tags:
        txt = (find('Mission.Strings.cs') or b'').decode('latin-1')
        for num, name in re.findall(r'=\s*(\d+)\s*,\s*"([^"]+)"', txt):
            _tags[int(num)] = name
    return _tags


def read_skyt(raw):
    """SKYT body after the 24-byte net header: skyColor f32[3], u32 DML tag, featurePosition, size, distance,
    u8 textures[16] (Starsiege persist order @0x572dec)."""
    col = struct.unpack_from('<3f', raw, 24)
    tag, feature, size, distance = struct.unpack_from('<I3f', raw, 36)
    return {'sky_color': col, 'dml_tag': tag, 'feature': feature, 'size': size, 'distance': distance,
            'textures': list(raw[52:52 + PANELS])}


def read_skpl(raw):
    tag, az, inc = struct.unpack_from('<I2f', raw, 24)
    size, distance = struct.unpack_from('<2f', raw, 62)
    return {'bitmap_tag': tag, 'azimuth': az, 'incidence': inc, 'size': size, 'distance': distance}


def read_sksf(raw):
    flag = raw[24]
    c = struct.unpack_from('<9f', raw, 25)
    return {'in_front': bool(flag), 'colors': [c[0:3], c[3:6], c[6:9]]}


def starsiege_sky(F, find, ppl, out_dir):
    """SKYT / SKPL / SKSF records of a Starsiege binary mission -> darkstar_sky dict (writes the images)."""
    tags = load_tags(find)
    skies = [o for o in F('SKYT') if len(o['fields'].get('_raw', b'')) >= 52 + PANELS]
    if not skies:
        return None
    s = read_skyt(skies[0]['fields']['_raw'])
    distance = s['distance'] or 1.0
    sky = make_band(s['feature'], 0.0, s['size'] / distance)
    sky.update({'panels': None, 'top_color': _color255(s['sky_color']), 'bottom_color': None,
                'source': 'SKYT dml=%s size=%g distance=%g' % (tags.get(s['dml_tag'], s['dml_tag']), s['size'],
                                                               s['distance'])})
    sky.update(write_panel_strip(find, ppl, tags.get(s['dml_tag'], ''), s['textures'], out_dir))
    planets = []
    for o in F('SKPL'):
        raw = o['fields'].get('_raw', b'')
        if len(raw) < 70:
            continue
        p = read_skpl(raw)
        if len(planets) >= MAX_PLANETS:
            break
        entry = write_planet(find, ppl, tags.get(p['bitmap_tag'], ''), p, len(planets), out_dir)
        if entry:
            planets.append(entry)
    sky['planets'] = planets
    stars = [o for o in F('SKSF') if len(o['fields'].get('_raw', b'')) >= 61]
    sky['stars'] = None
    if stars:
        sf = read_sksf(stars[0]['fields']['_raw'])
        sky['stars'] = make_stars(sf['colors'], sf['in_front'])
    return sky


_starsiege_vfs = []


def starsiege_mission_sky(mis_path, ppl_name, out_dir):
    """Campaign missions (tools/export_starsiege_missions.py): {'darkstar_sky': ...} or {}."""
    import export_darkstar_maps as DM
    if not _starsiege_vfs:
        _starsiege_vfs.append(DM.VFS(DM.P.work('starsiege', 'extracted')))
    vfs = _starsiege_vfs[0]
    ppl = DM.load_ppl(vfs, ppl_name) if ppl_name else None
    if ppl is None:
        return {}
    objs = [o for o, _ in M.walk(M.parse_binary(open(mis_path, 'rb').read()))]
    sky = starsiege_sky(lambda cls: [o for o in objs if o['class'] == cls], vfs.get, ppl, out_dir)
    return {'darkstar_sky': sky} if sky else {}
