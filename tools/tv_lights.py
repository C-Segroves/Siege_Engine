"""Tribes: Vengeance lighting (docs/formats/tribes_vengeance.md "Lighting"): the sun, the start zone's ambient light and
distance fog, and the placed point lights of one mission package, as the engine map's "environment" and "lights".

Everything is read from the actors the editor placed (ZoneInfo, Sunlight, Light, DynamicLight...). Compiled BSP and
terrain lightmaps are not decoded; the engine lights the converted geometry with these values at run time (a map without
a sun gets an ambient derived from its lights, see interior_ambient).

Evidence (checked against the game's own data):
- Colour of (Hue, Saturation, Brightness) is Unreal's FGetHSV: brightness V -> V*1.4/255 * 0.7/(0.01+sqrt(V*1.4/255)),
  hue picks a point on the red-green-blue ring, saturation 255 is WHITE (0 is the full hue). It reproduces the
  zone's precomputed AmbientVector exactly (zone ZoneInfo3 of SP-Captured: hsv(149, 150, 50) = 0.2116 0.2483 0.3232,
  stored 0.2117 0.2483 0.3233).
- Class defaults come from Engine.u: Light LightBrightness 64, LightRadius 64, LightSaturation 255, LightType steady;
  ZoneInfo AmbientSaturation 255, DistanceFogColor (128,128,128), DistanceFogStart 3000, DistanceFogEnd 8000.
- A light's world radius is 25 * (LightRadius + 1) Unreal units (the Unreal engine's WorldLightRadius).
- An actor's Region struct ends in "04 01 <zone number> 00": the BSP zone it stands in. The ZoneInfo actor standing in
  zone n sets the ambient and fog of zone n.
"""
import math
import struct

import ue2_package as U

LIGHT_RADIUS_UU = 25.0            # world radius = 25 * (LightRadius + 1) units
DEFAULT_ZONE_FOG = ((128, 128, 128), 3000.0, 8000.0)
DEFAULT_LIGHT = {'LightBrightness': 64.0, 'LightRadius': 64.0, 'LightSaturation': 255, 'LightHue': 0, 'LightType': 1}
LIGHT_CLASSES = ('Light', 'DynamicLight', 'Spotlight')
START_CLASSES = ('SPStartDefault', 'SinglePlayerStart', 'PlayerStart')
LT_NONE = 0
# The lightmaps that give the original's dark rooms their floor of light are not decoded: ambient never falls below this,
# so unlit surfaces stay readable (the placed lights then add the pools of light on top).
AMBIENT_FLOOR = 0.25
# Interior zones (no sun) are lit by lightmaps in the original, so a room never goes black between its lamps. The engine
# has one ambient per map: an interior map's ambient is raised to the mean colour of its placed lights (it keeps the
# rooms' tint) times this gain, at most INTERIOR_AMBIENT_MAX.
INTERIOR_AMBIENT_GAIN = 0.9
INTERIOR_AMBIENT_MAX = 0.5
MAX_LIGHT_RADIUS_M = 120.0


def hsv(hue, saturation, brightness):
    """Unreal FGetHSV: (r, g, b) fractions of a (Hue, Saturation, Brightness) byte triple."""
    v = brightness * 1.4 / 255.0
    v *= 0.7 / (0.01 + math.sqrt(v))
    if hue < 86:
        c = ((85 - hue) / 85.0, hue / 85.0, 0.0)
    elif hue < 171:
        c = (0.0, (170 - hue) / 85.0, (hue - 85) / 85.0)
    else:
        c = ((hue - 170) / 85.0, 0.0, (255 - hue) / 85.0)
    a = (255 - saturation) / 255.0
    return tuple(min(1.0, (1.0 + (x - 1.0) * a) * v) for x in c)


def _rgb(c):
    return [round(x, 4) for x in c]


def zone_number(props):
    """The BSP zone number of an actor's Region struct (None when the struct is absent or short)."""
    r = props.get('Region')
    return r[-2] if isinstance(r, (bytes, bytearray)) and len(r) > 4 else None


def _bgra(raw, default):
    """An Unreal Color property (stored blue, green, red, alpha) -> (r, g, b) bytes."""
    if isinstance(raw, (bytes, bytearray)) and len(raw) == 4:
        return raw[2], raw[1], raw[0]
    return default


def _byte(p, key, default):
    v = p.get(key)
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def zone_ambient(p):
    """(r, g, b) fractions: the precomputed AmbientVector, else the colour of the hue / saturation / brightness."""
    v = p.get('AmbientVector')
    if isinstance(v, (bytes, bytearray)) and len(v) == 12:
        return tuple(min(1.0, max(0.0, x)) for x in struct.unpack('<3f', v))
    return hsv(_byte(p, 'AmbientHue', 0), _byte(p, 'AmbientSaturation', 255), _byte(p, 'AmbientBrightness', 0))


def zone_fog(p, metres_per_uu):
    """{fog_color, fog_start, fog_end} (metres) of a zone with distance fog, else {}."""
    if not p.get('bDistanceFog'):
        return {}
    rgb = _bgra(p.get('DistanceFogColor'), DEFAULT_ZONE_FOG[0])
    start = float(p.get('DistanceFogStart', DEFAULT_ZONE_FOG[1]))
    end = float(p.get('DistanceFogEnd', DEFAULT_ZONE_FOG[2]))
    return {'fog_color': _rgb([x / 255.0 for x in rgb]), 'fog_start': round(max(0.0, start) * metres_per_uu, 1),
            'fog_end': round(max(start + 1.0, end) * metres_per_uu, 1)}


def _direction(rotation_raw):
    """The direction an Unreal rotator (pitch, yaw, roll as int32, 65536 per turn) points along, in Unreal axes."""
    if not isinstance(rotation_raw, (bytes, bytearray)) or len(rotation_raw) != 12:
        return (1.0, 0.0, 0.0)
    pitch, yaw, _roll = (a * 2.0 * math.pi / 65536.0 for a in struct.unpack('<3i', rotation_raw))
    return (math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch))


def light_properties(p):
    """The light's own properties with the Light class defaults filled in (a value the tagged-property reader got wrong,
    bytes instead of a number, keeps the default)."""
    out = dict(DEFAULT_LIGHT)
    out.update({k: p[k] for k in DEFAULT_LIGHT if isinstance(p.get(k), (int, float)) and not isinstance(p.get(k), bool)})
    return out


def sun_of(sunlights, to_direction):
    """{sun_dir, sun_color} of the brightest Sunlight (the engine has one sun), or a black sun when the map has none
    (interiors: the engine's default sun must not shine into them). sunlights: [properties]."""
    best = None
    for p in sunlights:
        lp = light_properties(p)
        if best is None or lp['LightBrightness'] > best[0]['LightBrightness']:
            best = (lp, p)
    if best is None:
        return {'sun_color': [0.0, 0.0, 0.0]}
    lp, p = best
    d = to_direction(_direction(p.get('Rotation')))
    return {'sun_dir': [round(x, 4) for x in d],
            'sun_color': _rgb(hsv(int(lp['LightHue']), int(lp['LightSaturation']), int(lp['LightBrightness'])))}


def _pick_zone(zones, start_zone):
    """The ZoneInfo properties that set the player's surroundings: the zone the start stands in, else a terrain zone,
    else the first zone with an ambient value."""
    here = zones.get(start_zone)
    if here:
        return here[0]
    flat = [p for ps in zones.values() for p in ps]
    for p in flat:
        if p.get('bTerrainZone'):
            return p
    return flat[0] if flat else None


def interior_ambient(lights):
    """(r, g, b) fractions an interior map's ambient light is at least: the mean colour of its placed lights (make_lights)
    times INTERIOR_AMBIENT_GAIN, capped; black without lights."""
    if not lights:
        return (0.0, 0.0, 0.0)
    n = float(len(lights))
    return tuple(min(INTERIOR_AMBIENT_MAX, INTERIOR_AMBIENT_GAIN * sum(l['color'][c] for l in lights) / n) for c in range(3))


def make_environment(zones, sunlights, start_zone, metres_per_uu, to_direction, lights=()):
    """The "environment" dictionary of docs/formats/map_schema.md for one mission; `lights` (make_lights) lift the ambient
    of a map without a sun."""
    env = {}
    zone = _pick_zone(zones, start_zone)
    if zone is not None:
        env['ambient'] = _rgb(max(AMBIENT_FLOOR, x) for x in zone_ambient(zone))
        env.update(zone_fog(zone, metres_per_uu))
        if zone.get('bClearToFogColor') and 'fog_color' in env:
            env['horizon_color'] = env['sky_color'] = env['fog_color']
    env.update(sun_of(sunlights, to_direction))
    if 'ambient' in env and not any(env['sun_color']):
        env['ambient'] = _rgb(max(a, b) for a, b in zip(env['ambient'], interior_ambient(lights)))
    return env


def make_lights(light_actors, to_world, metres_per_uu):
    """[{pos, color, range, type}] of the placed point lights; spotlights stay omni. light_actors: [(class, props)]."""
    out = []
    for cls, p in light_actors:
        lp = light_properties(p)
        if lp['LightType'] == LT_NONE or lp['LightBrightness'] <= 0 or not isinstance(p.get('Location'), (bytes, bytearray)):
            continue
        radius = min(MAX_LIGHT_RADIUS_M, LIGHT_RADIUS_UU * (lp['LightRadius'] + 1.0) * metres_per_uu)
        out.append({'pos': to_world(U.vec3(p['Location'])), 'color': _rgb(hsv(int(lp['LightHue']), int(lp['LightSaturation']),
                                                                              int(lp['LightBrightness']))),
                    'range': round(radius, 1), 'type': int(lp['LightType'])})
    return out


def export_lighting(pkg, to_world, metres_per_uu):
    """(environment, lights) of one mission package (see the module docstring)."""
    zones, sunlights, lights, start = {}, [], [], None
    for e in pkg.exports:
        cls = pkg.class_name(e)
        if cls in ('Class', 'Function', 'State') or e['size'] < 16:
            continue
        if cls == 'ZoneInfo' or cls == 'Sunlight' or cls in LIGHT_CLASSES or cls in START_CLASSES:
            p = U.object_properties(pkg, e)
            if cls == 'ZoneInfo':
                zones.setdefault(zone_number(p), []).append(p)
            elif cls == 'Sunlight':
                sunlights.append(p)
            elif cls in START_CLASSES:
                start = zone_number(p) if start is None else start
            else:
                lights.append((cls, p))

    placed = make_lights(lights, to_world, metres_per_uu)
    return make_environment(zones, sunlights, start, metres_per_uu, _engine_direction, placed), placed


def relight(game_root, pack_dir, log=print):
    """Rewrites "environment" (keeping what the map has besides ambient, fog, sun and sky colours) and "point_lights" in the
    pack's campaign maps from the game's own mission packages, without redoing the rest of the import."""
    import json
    import os
    import tv_import
    content = os.path.join(game_root, 'Content')
    chapters = tv_import.parse_campaign_ini(tv_import.read_text(os.path.join(content, 'System', 'Campaign.ini')))
    for ch in chapters:
        for entry in ch['maps']:
            path = tv_import._ci_file(os.path.join(content, 'Maps'), entry['map'] + '.tvm')
            map_path = os.path.join(pack_dir, 'maps', os.path.splitext(os.path.basename(path or ''))[0], 'map.json') if path else ''
            if not path or not os.path.isfile(map_path):
                continue
            with open(map_path, encoding='utf-8') as f:
                m = json.load(f)
            env, lights = export_lighting(U.load(path), tv_import.to_world, tv_import.METRES_PER_UU)
            m['environment'], m['point_lights'] = env, lights
            with open(map_path, 'w', encoding='utf-8') as f:
                json.dump(m, f, indent=1, ensure_ascii=False)
            log('%-26s %4d lights  %s' % (entry['map'], len(lights), sorted(env)))


def _engine_direction(d):
    """An Unreal direction (x forward, y right, z up) in the engine frame (x right, y up, -z forward), unit length."""
    v = (d[1], d[2], -d[0])
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 3:
        sys.exit('python tools/tv_lights.py <game root: the unpacked "Tribes Vengeance" folder> <pack folder>')
    relight(sys.argv[1], sys.argv[2])
