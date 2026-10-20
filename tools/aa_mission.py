"""Parser for Aerial Assault MISSION.TXT scripts (ConvertMission output of Tribes 2 .mis files).

Token stream: '//' comments dropped, then a keyword followed by its values. World axes in the file are X east,
Y up, Z north (see docs/formats/aerial_assault.md). One file unit is taken as 1 m (assumption, see to_engine in
aa_import.py).
"""
import re

KEYWORDS = {
    'MISSION', 'MUSIC', 'ENVIRONMENT', 'SUN', 'FOG', 'SKY', 'CAMERA', 'BOUNDS', 'TERRAIN', 'EMPTYSQUARES',
    'BUILDING', 'SCENERY', 'GENERATOR', 'INVEN', 'TURRET', 'SENSOR', 'FORCEFIELD', 'FLIPFLOP', 'PROJECTOR',
    'WAYPOINT', 'NEXUS', 'TAG', 'VEHICLEPAD', 'POWER', 'SWITCH', 'SPAWN', 'FLAG_HOME', 'PICKUP', 'WATERMARK',
}
_TOK = re.compile(r'"[^"]*"|[^\s"]+')
_LISTS = {'GENERATOR': 'generators', 'INVEN': 'inventories', 'VEHICLEPAD': 'vehicle_pads', 'TURRET': 'turrets',
          'SENSOR': 'sensors'}


def _num(t):
    try:
        return float(t)
    except ValueError:
        return None


def tokenize(text):
    text = re.sub(r'//[^\n]*', '', text.replace('\r', '')).replace('#TAG', 'TAG')
    return _TOK.findall(text)


def _groups(tokens):
    """[(keyword, [value tokens])] - values run until the next keyword."""
    out, cur = [], None
    for t in tokens:
        if t in KEYWORDS:
            cur = (t, [])
            out.append(cur)
        elif cur is not None:
            cur[1].append(t)
    return out


def _strip(s):
    return s.strip('"')


def _floats(vals, n, at=0):
    got = [_num(v) for v in vals[at:at + n]]
    if len(got) < n or None in got:
        raise ValueError('expected %d numbers, got %r' % (n, vals[at:at + n]))
    return got


def _ints(vals):
    return [int(float(x)) for x in vals if _num(x) is not None]


def _fog(v):
    f = _floats(v, 15)
    n = int(f[14])
    vols = _floats(v, 3 * n, 15)
    return {'map_size': f[0:2], 'color': f[2:5], 'haze_color': f[5:8], 'start': f[8], 'finish': f[9],
            'haze_angles': f[10:12], 'band_alpha': f[12:14],
            'volumes': [{'min_h': vols[i], 'max_h': vols[i + 1], 'vis': vols[i + 2]} for i in range(0, 3 * n, 3)]}


def _station(kw, v):
    """GENERATOR/INVEN/VEHICLEPAD/TURRET/SENSOR: [type] switch power x y z name, pitch yaw roll [barrel]."""
    at, sensor_type = 0, None
    if _num(v[0]) is None:
        sensor_type, at = v[0], 1
    f = _floats(v, 9, at)
    o = {'switch': int(f[0]), 'power': int(f[1]), 'pos': f[2:5], 'name': int(f[5]), 'rot': f[6:9]}
    if kw == 'TURRET':
        o['barrel'] = v[at + 9] if len(v) > at + 9 else ''
    if sensor_type:
        o['type'] = sensor_type
    return o


def parse(text):
    m = {'sky': [], 'cameras': [], 'buildings': [], 'scenery': [], 'pickups': [], 'spawns': [], 'flags': [],
         'generators': [], 'inventories': [], 'turrets': [], 'sensors': [], 'forcefields': [], 'flipflops': [],
         'projectors': [], 'waypoints': [], 'nexus': [], 'vehicle_pads': [], 'empty_squares': [],
         'power': [], 'switch': []}
    pending = None
    for kw, v in _groups(tokenize(text)):
        before = {k: len(lst) for k, lst in m.items() if isinstance(lst, list)}
        if kw == 'TAG':
            pending = _strip(v[0]) if v else None
        elif kw == 'MISSION':
            m['name'] = _strip(v[0])
        elif kw in ('MUSIC', 'ENVIRONMENT'):
            m[kw.lower()] = v[0]
        elif kw == 'SUN':
            f = _floats(v, 9)
            m['sun'] = {'dir': f[0:3], 'color': f[3:6], 'ambient': f[6:9]}
        elif kw == 'FOG':
            m['fog'] = _fog(v)
        elif kw == 'SKY':
            m['sky'] = [_strip(x) for x in v[:5]]
        elif kw == 'CAMERA':
            m['cameras'].append(_floats(v, 3))
        elif kw == 'BOUNDS':
            f = _floats(v, 6)
            m['bounds'] = {'min': f[0:3], 'max': f[3:6]}
        elif kw == 'TERRAIN':
            m['terrain'] = _strip(v[0])
        elif kw == 'EMPTYSQUARES':
            m['empty_squares'] = _ints(v)
        elif kw == 'BUILDING':
            f = _floats(v, 10)
            m['buildings'].append({'power': int(f[0]), 'pos': f[1:4], 'rot': f[4:7], 'scale': f[7:10], 'shape': _strip(v[10])})
        elif kw == 'SCENERY':
            f = _floats(v, 9)
            m['scenery'].append({'pos': f[0:3], 'rot': f[3:6], 'scale': f[6:9], 'shape': _strip(v[9])})
        elif kw in _LISTS:
            m[_LISTS[kw]].append(_station(kw, v))
        elif kw == 'FORCEFIELD':
            f = _floats(v, 11)
            m['forcefields'].append({'switch': int(f[0]), 'power': int(f[1]), 'pos': f[2:5], 'rot': f[5:8], 'scale': f[8:11]})
        elif kw in ('FLIPFLOP', 'PROJECTOR'):
            f = _floats(v, 7)
            m['flipflops' if kw == 'FLIPFLOP' else 'projectors'].append({'switch': int(f[0]), 'pos': f[1:4], 'rot': f[4:7]})
        elif kw == 'WAYPOINT':
            f = _floats(v, 5)
            m['waypoints'].append({'switch': int(f[0]), 'pos': f[1:4], 'name': int(f[4])})
        elif kw == 'NEXUS':
            f = _floats(v, 4)
            m['nexus'].append({'pos': f[0:3], 'height': f[3]})
        elif kw == 'POWER':
            m['power'] = _ints(v)
        elif kw == 'SWITCH':
            m['switch'] = _ints(v)
        elif kw == 'SPAWN':
            f = _floats(v, 7)
            m['spawns'].append({'team': int(f[0]), 'pos': f[1:4], 'radius': f[4], 'pitch': f[5], 'yaw': f[6]})
        elif kw == 'FLAG_HOME':
            f = _floats(v, 5)
            m['flags'].append({'team': int(f[0]), 'pos': f[1:4], 'yaw': f[4]})
        elif kw == 'PICKUP':
            f = _floats(v, 3)
            m['pickups'].append({'pos': f, 'kind': v[3]})
        if kw != 'TAG' and pending is not None:
            for k, lst in m.items():
                if isinstance(lst, list) and len(lst) > before.get(k, 0) and isinstance(lst[-1], dict):
                    lst[-1]['tag'] = pending
            pending = None
    return m
