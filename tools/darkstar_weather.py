"""Darkstar weather (Starsiege 1999, Starsiege: Tribes 1998) -> engine map schema "environment.weather".

    import darkstar_weather as W
    env['weather'] = W.starsiege_weather(raw)          # Starsiege binary .mis SNOW record (bytes)
    env['weather'] = W.tribes_weather(fields)          # Tribes text .mis "Snowfall" object fields

Evidence:
  * RegisterObjects.cs (both games): the editor's Environment menu creates "Snowfall" as
    Snowfall(intensity 1, wind 0 0, rain 0) and "Rain" as the same class with the last argument 1, so rain
    is a Snowfall with its rain flag set.  Itag.Strings.cs names the fields IDITG_SNOW_INTENSITY
    ("Snowfall Intensity") and IDITG_SNOW_WIND ("Snowfall wind direction").
  * Tribes text missions spell the persist fields out (BloodRunsCold.mis: intensity = "1"; wind = "1 2 -35";
    suspendRendering = "False"; rain = "False").
  * Starsiege SNOW record (42 bytes, all 9 in the shipped .mis files decode this way): 24-byte net header,
    f32 intensity, f32 wind[3] (x east, y north, z up: the fall velocity), u8 suspendRendering, u8 rain.
    Snow maps use wind z -35, the two rain maps (CD1, CTF_Stab_n_Grab) -85.

Engine dict: {"kind": "snow" | "rain", "intensity": 0..1, "wind": [x, y, z] (engine frame: x east, y up,
z south; original units), "source": "..."}.  None when the record asks not to be rendered.
"""
import struct

SNOW_RECORD_SIZE = 42
_NET_HEADER = 24


def make_weather(intensity, wind, rain, source):
    """Engine weather dict from the decoded Snowfall fields (wind in the original Z-up frame)."""
    x, y, z = (float(v) for v in wind)
    # "+ 0.0" turns -0.0 into 0.0
    return {'kind': 'rain' if rain else 'snow', 'intensity': round(float(intensity), 4),
            'wind': [round(x, 4) + 0.0, round(z, 4) + 0.0, round(-y, 4) + 0.0], 'source': source}


def starsiege_weather(raw):
    """Binary SNOW record payload -> engine weather dict (None if short or suspended)."""
    if raw is None or len(raw) < SNOW_RECORD_SIZE:
        return None
    intensity, wx, wy, wz = struct.unpack_from('<4f', raw, _NET_HEADER)
    suspend, rain = raw[_NET_HEADER + 16], raw[_NET_HEADER + 17]
    if suspend:
        return None
    return make_weather(intensity, (wx, wy, wz), rain, 'SNOW intensity=%g wind=(%g %g %g) rain=%d'
                        % (intensity, wx, wy, wz, rain))


def _truthy(s):
    return str(s).strip().lower() in ('1', 'true')


def tribes_weather(fields):
    """Tribes text Snowfall fields -> engine weather dict (None if suspended)."""
    if _truthy(fields.get('suspendRendering', 'False')):
        return None
    wind = [float(v) for v in str(fields.get('wind', '0 0 -35')).split()[:3]]
    wind += [0.0] * (3 - len(wind))
    intensity = float(fields.get('intensity', 1) or 0)
    rain = _truthy(fields.get('rain', 'False'))
    return make_weather(intensity, wind, rain, 'Snowfall intensity=%g wind=%s rain=%s'
                        % (intensity, fields.get('wind'), rain))
