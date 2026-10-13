"""Starsiege (1999, Darkstar) binary mission files (.mis) -> object tree.

A .mis is a Darkstar persistent-object stream (Tribes 1 stored the same objects as text):

  object   = u32 tag (FOURCC or class number), u32 size, payload[size], pad byte if size is odd
  group    = tag SIMG (SimGroup) / ESDP (drop-point group) / Ssgp / SCPG (camera paths):
             u32 version, u32 count, count x object, then count x pstring child names
             (pstring = u8 length + chars).  The root group is "MissionGroup" (script paths
             "MissionGroup/navMarkers/navAlpha").

Leaf objects decoded here (H = checked against data/scripts, M = consistent, L = guess):
  net header (24 bytes): u32 version, u32 id, u32 flags, u32 0, u32 -1, u32 0             (M)
  SVol  SimVolume        net + pstring file ("Mars.Sim.vol", "<mission>.ted.vol")          (H)
  STER  SimTerrain       net + 12 f32 (origin x,y, ...) + pstring dtf + 5 f32 (gravity z)   (M)
  ESpt  palette          net + pstring ("Mars.d.ppl")                                       (H)
  SKYT/SKPL/SKSF         sky / planet (sun) / starfield (tools/darkstar_sky.py)              (H)
  SNOW                   Snowfall / Rain (tools/darkstar_weather.py)                         (H)
  DPNT  drop point, mark  path marker:  net + u32 flags + f32 rot[3][3] (rows = images of the
        x/y/z axes, row 1 = forward) + f32 pos[3]                                           (H)
  ESNM  nav marker       as mark + 12 bytes                                                 (H)
  trgr  trigger          net + pstring script name + u8 u8 + f32 rate + u32 + u32 flags +
                         rot[9] + pos[3] + bbox min[3] max[3] (box around pos, metres)      (M)
  0x100 static shape (StaticShape/structure) and TRRT turret: version 7 / 6; SimShape damage block at 16
        (read_damage; Starsiege.exe inspect 0x674f40 tags IDITG_SSP_*): u32 flags (bit 0 indestructible,
        bit 1 "is destroyed", bit 2 locally conserve damage), u32 damage distribution tag
        (IDSIMOBJ_SSP_DAMAGETO*), u32 destruction event tag (IDSIMOBJ_SSP_DEST*), f32 sustainable damage
        (= hit points, 1..250000, mostly 4000), f32 current damage, u32 explosion tag (IDDTS_EXP_*),
        f32 forward attenuation; f32 pos[3] at 48, f32 euler rot[3] at 60, u32 len + shape file at 121,
        script name = pstring after the bytes 07 00 00 00 01 01 <team bits> that follow it;
        static-base fire block (Starsiege.exe read 0x456a0a, inspect 0x4536e9 tags IDITG_FIREDAMAGETHRESH /
        IDITG_FIREDAMAGERATE): f32 fire threshold (catches fire with this much damage left, 1000),
        f32 burn rate (damage/s while on fire, 100), u8, f32 -- the last 13 bytes of a static record  (H)
        TRRT tail (read_turret, Turret::read 0x443cc8, inspect 0x444100): fire block, u32 turret type
        (datTurret.cs newTurret id), f32 rotational velocity (rad/s), f32 skill, f32 activation distance
        (m: 200-1500), f32 target selection period (s), u32 n, u32 weapon tag[n] (IDWEA_* short-name string
        tags of datWeapon.cs weaponInfo1), u32 len + AI file ("turretFire.ai"), f32 accuracy, track period,
        fire period, (unnamed +0xf90), reload/rearm period (s), deactivation buffer (m)               (H)
  0x10c interior shape   pos at (name offset - 73), rot at (name offset - 61), u32 len + .dis (M)
  SCPG camera path group = SCPR (net header + u32 1) + SCPW waypoints in flight order:
        SCPW  net + u32 flags + f32 rot[9] (rows = axis images, row 1 = view direction) + f32 pos[3]
              + f32 pos[3] (same again) + f32 quaternion[4] + f32 0.6 + f32 speed (m/s at this
              waypoint; HE1 path2 follows a drop pod falling 1.3 km in ~4.5 s at 300)     (M)
  HERC / TANK / FLYR     u32 version + LZH stream (tools/darkstar_lzh.py, same coder as VOL
                         compression 3); decoded layout, see read_vehicle()                 (H)
Coordinates: original frame Z up, metres (docs/formats/units.md).

Usage: python tools/starsiege_mis.py <file.mis>   (prints the tree)
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import darkstar_lzh  # noqa: E402
import darkstar_weather  # noqa: E402

GROUP_TAGS = {b'SIMG', b'ESDP', b'Ssgp', b'SCPG'}
TAG_STATIC = 0x100
TAG_INTERIOR = 0x10c
TEAMS = {0: 'neutral', 1: 'yellow', 2: 'blue', 4: 'red', 8: 'purple'}
## Turrets carry at most 12 weapons (datTurret.cs: cMissleTurret has 12 hardpoints).
MAX_TURRET_WEAPONS = 16
## Plausible turret type ids (datTurret.cs newTurret 1..35).
MAX_TURRET_TYPE = 100
_AI_FILE = re.compile(rb'([\x01-\x40])\x00\x00\x00([\x20-\x7e]+\.ai)\x00')


def tag_name(t):
    if all(32 <= c < 127 for c in t):
        return t.decode('ascii')
    return '0x%x' % struct.unpack('<I', t)[0]


class R:
    def __init__(self, d, p=0):
        self.d, self.p = d, p

    def u8(self):
        v = self.d[self.p]
        self.p += 1
        return v

    def u16(self):
        v = struct.unpack_from('<H', self.d, self.p)[0]
        self.p += 2
        return v

    def u32(self):
        v = struct.unpack_from('<I', self.d, self.p)[0]
        self.p += 4
        return v

    def i32(self):
        v = struct.unpack_from('<i', self.d, self.p)[0]
        self.p += 4
        return v

    def f32(self, n=1):
        v = struct.unpack_from('<%df' % n, self.d, self.p)
        self.p += 4 * n
        return v[0] if n == 1 else list(v)

    def pstr(self):
        n = self.u8()
        s = self.d[self.p:self.p + n].decode('latin1')
        self.p += n
        return s

    def lstr(self):
        n = self.u32()
        if n == 0xffffffff:   # "no string"
            return ''
        s = self.d[self.p:self.p + n].split(b'\0')[0].decode('latin1')
        self.p += n
        return s


def _r(v, n=3):
    return round(float(v), n)


def _transform(r):
    flags = r.u32()
    rot = r.f32(9)
    pos = r.f32(3)
    fwd = rot[3:6]   # row 1 = image of the y (forward) axis
    import math
    yaw = math.atan2(-fwd[0], fwd[1])   # rotation about +z (counter-clockwise from +y)
    return {'pos': [_r(x) for x in pos], 'yaw': _r(yaw, 4), 'rot': [_r(x, 5) for x in rot], 'xf_flags': flags}


def read_vehicle(tag, payload):
    """HERC/TANK/FLYR: u32 version, then an LZH stream holding (all little-endian):
       5 x u32 net header (0, 0x100, 0, -1, 0)
       u8 6 (record version), u8 vehicle id (datVehicle.cs buildHerc/buildTank/... number),
       u8 n, u16 mountable[n] (engine, reactor, computer, shield, armour, sensor, specials...; 0 = empty),
       u8 a, u8 b, u8 c (flags, 01 01 01 / 01 01 00),
       u32 team (bit: 1 yellow, 2 blue, 4 red, 8 purple; 0 neutral),
       pstring script name ("patrol" -> patrol::vehicle::onDestroyed etc.),
       u8 nw, u8 weapon[nw] (datWeapon.cs ids per hardpoint; 0 = empty),
       f32 pos[3], f32 rot_z (radians),
       u8 k, 3k+1 bytes (per-weapon linkage/fire-group bytes, L),
       u32 len + skin bitmap ("skins\\talo_dust.BMP"), u32 pilot id (Pilot objects in the mission .cs /
       DatPilot_*.cs; 0 = generic)."""
    ver = struct.unpack_from('<I', payload, 0)[0]
    out = darkstar_lzh.decode(payload[4:], 512)
    r = R(out, 20)
    rv = r.u8()
    if rv != 6:
        raise ValueError('vehicle record version %d' % rv)
    vid = r.u8()
    n = r.u8()
    mounts = [r.u16() for _ in range(n)]
    flags = [r.u8(), r.u8(), r.u8()]
    team = r.u32()
    name = r.pstr()
    nw = r.u8()
    weapons = [r.u8() for _ in range(nw)]
    pos = r.f32(3)
    rot = r.f32()
    k = r.u8()
    links = list(out[r.p:r.p + 3 * k + 1])
    r.p += 3 * k + 1
    skin = r.lstr()
    pilot = r.u32()
    return {'kind': {'HERC': 'herc', 'TANK': 'tank', 'FLYR': 'flyer'}[tag], 'stream_version': ver,
            'vehicle_id': vid, 'mountables': mounts, 'flags': flags, 'team_bits': team,
            'team': TEAMS.get(team, str(team)), 'script': name, 'weapons': weapons,
            'pos': [_r(x) for x in pos], 'yaw': _r(rot, 4), 'links': links, 'skin': skin, 'pilot': pilot}


## SimShape damage block (Starsiege.exe 0x674f40 inspect order; flags word +0x1fc).
DAMAGE_AT = 16
FLAG_INDESTRUCTIBLE = 1
FLAG_DESTROYED = 2
## Static-base fire block: f32 threshold, f32 burn rate, u8, f32 (13 bytes, Starsiege.exe 0x456a0a).
FIRE_BLOCK_SIZE = 13
## Turret::read (0x443cc8): u32 type, f32 velocity, skill, activation distance, target period, u32 n.
TURRET_HEAD_SIZE = 20
## Turret::read version >= 4 tail after the AI file name.
TURRET_AI_FIELDS = ('accuracy', 'track_period', 'fire_period', 'unknown_f90', 'reload_period',
                    'deactivate_buffer')


def read_damage(b):
    """SimShape damage block of a static / turret record (see the module doc)."""
    flags, dist, event, sustain, current, explosion, atten = struct.unpack_from('<3I2fIf', b, DAMAGE_AT)
    return {'damage_flags': flags, 'indestructible': bool(flags & FLAG_INDESTRUCTIBLE),
            'damage_distribution': dist, 'destruct_event': event, 'hit_points': _r(sustain),
            'current_damage': _r(current), 'explosion_tag': explosion, 'forward_attenuation': _r(atten, 4)}


def read_fire_block(b, at):
    """Fire threshold and burn rate (damage/s) of a static base; the trailing u8/f32 are kept raw."""
    threshold, rate, flag, extra = struct.unpack_from('<2fBf', b, at)
    return {'fire_threshold': _r(threshold), 'burn_rate': _r(rate), 'fire_raw': [flag, _r(extra)]}


def _static(tag, b):
    r = R(b, 48)
    pos = r.f32(3)
    rot = r.f32(3)
    r.p = 121
    shape = r.lstr()
    # after the damage block: 07 00 00 00 01 01, u8 team bits, pstring script name
    script = ''
    team = None
    i = b.find(b'\x07\x00\x00\x00\x01\x01', r.p)
    if i >= 0 and i + 7 < len(b) and b[i + 6] < 16:
        team = b[i + 6]
        n = b[i + 7]
        s = b[i + 8:i + 8 + n]
        if n and all(32 <= c < 127 for c in s):
            script = s.decode('ascii')
    out = {'kind': 'turret' if tag == b'TRRT' else 'static', 'shape': shape, 'pos': [_r(x) for x in pos],
           'yaw': _r(rot[2], 4), 'rot_xyz': [_r(x, 4) for x in rot], 'script': script,
           'team_bits': team, 'team': TEAMS.get(team, str(team)) if team is not None else None,
           'version': struct.unpack_from('<I', b, 0)[0]}
    out.update(read_damage(b))
    if tag != b'TRRT':
        out.update(read_fire_block(b, len(b) - FIRE_BLOCK_SIZE))
    return out


def read_turret(b):
    """The turret part of a TRRT record (see the module doc); {} when it cannot be found."""
    m = _AI_FILE.search(b)
    if not m:
        return {}
    # empty weapon slots are 0, so the count is the n whose head also holds a plausible turret type
    for n in range(MAX_TURRET_WEAPONS + 1):
        count_at = m.start() - 4 - 4 * n
        if count_at < TURRET_HEAD_SIZE or struct.unpack_from('<I', b, count_at)[0] != n:
            continue
        head_at = count_at - TURRET_HEAD_SIZE
        ttype, velocity, skill, activate, target_period = struct.unpack_from('<I4f', b, head_at)
        if 0 < ttype < MAX_TURRET_TYPE:
            break
    else:
        return {}
    ai = dict(zip(TURRET_AI_FIELDS, (_r(x, 4) for x in struct.unpack_from('<6f', b, m.end()))))
    out = {'ai_file': m.group(2).decode('ascii'), 'turret_ai': ai, 'turret_type': ttype,
           'weapon_tags': list(struct.unpack_from('<%dI' % n, b, count_at + 4)), 'range': _r(activate),
           'turret_velocity': _r(velocity, 4), 'skill': _r(skill, 4), 'target_period': _r(target_period, 4)}
    out.update(read_fire_block(b, head_at - FIRE_BLOCK_SIZE))
    return out


def read_camera_waypoint(b):
    """SCPW: one waypoint of a camera path (see the module doc)."""
    r = R(b, 24)
    flags = r.u32()
    rot = r.f32(9)
    pos = r.f32(3)
    r.p += 12
    quat = r.f32(4)
    r.p += 4
    speed = r.f32()
    return {'kind': 'camera_waypoint', 'pos': [_r(x) for x in pos], 'rot': [_r(x, 5) for x in rot],
            'quat': [_r(x, 5) for x in quat], 'speed': _r(speed, 6), 'flags': flags}


def _interior(b):
    m = re.search(rb'([\x01-\x7f])\x00\x00\x00([\x20-\x7e]{1,80}\.(?:dis|DIS|Dis))\x00', b)
    if not m:
        return {'kind': 'interior', 'shape': None}
    o = m.start()
    pos = struct.unpack_from('<3f', b, o - 73)
    rot = struct.unpack_from('<3f', b, o - 61)
    return {'kind': 'interior', 'shape': m.group(2).decode('ascii'), 'pos': [_r(x) for x in pos],
            'yaw': _r(rot[2], 4), 'rot_xyz': [_r(x, 4) for x in rot]}


def _trigger(b):
    r = R(b, 24)
    name = r.pstr()
    a, c = r.u8(), r.u8()
    rate = r.f32()
    u = r.u32()
    t = _transform(r)
    bb = r.f32(6)
    t.update({'kind': 'trigger', 'script': name, 'flags': [a, c, u], 'rate': _r(rate),
              'box_min': [_r(x) for x in bb[:3]], 'box_max': [_r(x) for x in bb[3:]]})
    return t


def _floats(b, off):
    n = (len(b) - off) // 4
    return [_r(x, 4) for x in struct.unpack_from('<%df' % n, b, off)]


def decode_leaf(tag, b):
    t = tag_name(tag)
    try:
        if t in ('HERC', 'TANK', 'FLYR'):
            return read_vehicle(t, b)
        if t in ('SVol', 'ESpt'):
            r = R(b, 24)
            return {'kind': 'volume' if t == 'SVol' else 'palette', 'file': r.pstr()}
        if t == 'STER':
            r = R(b, 24)
            data = r.f32(12)
            dtf = r.pstr()
            foot = _floats(b, r.p)
            return {'kind': 'terrain', 'file': dtf, 'data': [_r(x) for x in data], 'footer': foot,
                    'origin': [_r(data[0]), _r(data[1])],
                    'gravity': next((x for x in foot if -40.0 < x < -0.5), None)}
        if t in ('DPNT', 'mark'):
            r = R(b, 24)
            d = _transform(r)
            d['kind'] = 'drop_point' if t == 'DPNT' else 'marker'
            return d
        if t == 'ESNM':
            r = R(b, 24)
            d = _transform(r)
            d['kind'] = 'nav_marker'
            d['extra'] = list(struct.unpack_from('<3I', b, r.p))
            return d
        if t == 'trgr':
            return _trigger(b)
        if t == 'TRRT':
            return dict(_static(tag, b), **read_turret(b))
        if struct.unpack('<I', tag)[0] == TAG_STATIC:
            return _static(tag, b)
        if t == 'SCPW':
            return read_camera_waypoint(b)
        if t == 'SCPR':
            return {'kind': 'camera_path'}
        if struct.unpack('<I', tag)[0] == TAG_INTERIOR:
            return _interior(b)
        if t == 'SNOW':
            return {'kind': 'snow', 'weather': darkstar_weather.starsiege_weather(b)}
        if t in ('SKYT', 'SKPL', 'SKSF'):
            return {'kind': {'SKYT': 'sky', 'SKPL': 'planet', 'SKSF': 'starfield'}[t], 'floats': _floats(b, 24)}
    except Exception as e:  # noqa: BLE001 - keep the tree; report
        return {'kind': 'error', 'tag': t, 'error': '%s: %s' % (type(e).__name__, e)}
    return {'kind': 'unknown', 'tag': t, 'size': len(b)}


def parse_object(d, o):
    tag = d[o:o + 4]
    sz = struct.unpack_from('<I', d, o + 4)[0]
    body = d[o + 8:o + 8 + sz]
    end = o + 8 + sz + (sz & 1)
    if tag in GROUP_TAGS:
        r = R(body)
        ver, n = r.u32(), r.u32()
        kids = []
        p = o + 16
        for _ in range(n):
            k, p = parse_object(d, p)
            kids.append(k)
        names = []
        r.p = p - (o + 8)
        for _ in range(n):
            names.append(r.pstr() if r.p < len(body) else '')
        for k, nm in zip(kids, names):
            k['name'] = nm
        return {'kind': 'group', 'tag': tag_name(tag), 'children': kids}, end
    obj = decode_leaf(tag, body)
    return obj, end


def read_mis(path):
    d = open(path, 'rb').read()
    root, _ = parse_object(d, 0)
    root['name'] = 'MissionGroup'
    return root


def walk(node, path=''):
    """Yields (path, node) for every object; paths like 'MissionGroup/navMarkers/navAlpha'."""
    p = (path + '/' if path else '') + (node.get('name') or '')
    yield p, node
    for k in node.get('children', []):
        yield from walk(k, p)


def main():
    for f in sys.argv[1:]:
        root = read_mis(f)
        for p, n in walk(root):
            if n['kind'] == 'group':
                print(p + '/')
            else:
                x = {k: v for k, v in n.items() if k not in ('rot', 'name', 'links', 'floats', 'footer', 'data')}
                print('  ', p, x)


if __name__ == '__main__':
    main()
