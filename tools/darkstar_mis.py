"""Darkstar mission files (.mis): Tribes text object trees and Starsiege binary persistent streams.

Tribes 1 (text, `base/missions/<name>.mis`):
    instant <Class> ["<name>"] { field = "value"; field[3] = "v"; instant ... { } };
  parse_text() -> nested dicts {class, name, fields{}, children[]}.

Starsiege (binary, `multiplayer/<name>.mis`): a Darkstar persistent object stream. Every object is
  tag[4] u32 size body[size] (+1 pad byte when size is odd)
  SIMG / Ssgp (SimGroup / SimSet-group): u32 version, u32 n, n child objects, then n names (u8 len + chars)
  SVol  volume: net header(24) + u8 len + file name
  ESpt  palette: net header(24) + u8 len + .ppl name
  STER  terrain: net header(24) + f32 pos[3] + f32 rot[3] + f32 visibleDist, hazeDist, ?, ?, ?, ? +
        u8 len + dtf name + f32 gravity[3] + f32 drag + f32 contHeight
  SKYT  sky, SKPL planet (sun): net(24) + u32 dml id + f32 azimuth? + f32 incidence + u16 flags +
        f32 intensity[3] + f32 ambient[3] + ...
  0x10c InteriorShape (v4): u32 ver, u32, u8, u8 len + name (usually empty), ... f32 pos[3] at body+55+len,
        f32 rot[3] (Euler, radians) at body+67+len, ... then
        u32 len + .dis name
  0x100 StaticShape (v7) / TRRT turret: f32 pos[3] at body+48, f32 rot[3] at body+60, then
        u32 len + .dts name (turrets: shape, then the debris shape)
  ESDP  drop point group: u32 version, u32 n, n x DPNT
  DPNT  drop point: net(24) + i32 flags + f32 rot[3][3] (rows) + f32 pos[3]
  ESNM  nav marker, trgr trigger, HERC/TANK/FLYR vehicles (AI, campaign only)
  (after open-siege/siege-studio mission.hpp, MIT; positions/rotations located by RE on all MP maps)
"""
import re, struct

# ------------------------------------------------------------------------------------------- Tribes text
_TOK = re.compile(r'instant\s+(\w+)\s*(?:"([^"]*)")?\s*\{|\}\s*;|(\w+(?:\[\d+\])?)\s*=\s*"([^"]*)"\s*;', re.S)


class CIDict(dict):
    """Field names are case-insensitive in Darkstar scripts (fileName / filename)."""

    def __setitem__(self, k, v):
        super().__setitem__(k.lower(), v)

    def __getitem__(self, k):
        return super().__getitem__(k.lower())

    def __contains__(self, k):
        return super().__contains__(k.lower())

    def get(self, k, default=None):
        return super().get(k.lower(), default)


def parse_text(text):
    text = re.sub(r'//[^\n]*', '', text)
    root = {'class': 'root', 'name': '', 'fields': CIDict(), 'children': []}
    stack = [root]
    for m in _TOK.finditer(text):
        if m.group(1):
            o = {'class': m.group(1), 'name': m.group(2) or '', 'fields': CIDict(), 'children': []}
            stack[-1]['children'].append(o)
            stack.append(o)
        elif m.group(3):
            stack[-1]['fields'][m.group(3)] = m.group(4)
        else:
            if len(stack) > 1:
                stack.pop()
    return root


def walk(o, path=()):
    """Yield (object, path of ancestor objects) depth-first."""
    for c in o['children']:
        yield c, path
        yield from walk(c, path + (c,))


def vec(s, n=3):
    try:
        v = [float(x) for x in s.split()]
    except (ValueError, AttributeError):
        return None
    return (v + [0.0] * n)[:n] if v else None


# ------------------------------------------------------------------------------------------- Starsiege binary
def _tag(t):
    try:
        s = t.decode('ascii')
        if s.isalnum():
            return s
    except UnicodeDecodeError:
        pass
    return '0x%x' % struct.unpack('<I', t)[0]


def _pstr(b, p):
    n = b[p]
    return b[p + 1:p + 1 + n].split(b'\0')[0].decode('latin1'), p + 1 + n


def _lstr(b, p):
    n, = struct.unpack_from('<I', b, p)
    return b[p + 4:p + 4 + n].split(b'\0')[0].decode('latin1'), p + 4 + n


def _f3(b, p):
    return list(struct.unpack_from('<3f', b, p))


def _obj(d, p):
    tag = _tag(d[p:p + 4])
    size, = struct.unpack_from('<I', d, p + 4)
    body = d[p + 8:p + 8 + size]
    o = {'class': tag, 'name': '', 'fields': {}, 'children': []}
    if tag in ('SIMG', 'Ssgp', 'SIMS', 'ESDP'):
        ver, n = struct.unpack_from('<II', body, 0)
        q = 8
        for _ in range(n):
            c, q = _obj(body, q)
            o['children'].append(c)
        if tag != 'ESDP':
            for c in o['children']:
                if q < len(body):
                    c['name'], q = _pstr(body, q)
    else:
        f = o['fields']
        try:
            if tag == 'SVol' or tag == 'ESpt':
                f['file'] = _pstr(body, 24)[0]
            elif tag == 'STER':
                f['position'] = _f3(body, 24)
                f['rotation'] = _f3(body, 36)
                f['visibleDistance'], f['hazeDistance'] = struct.unpack_from('<2f', body, 48)
                f['dtf'], q = _pstr(body, 72)
                f['gravity'] = _f3(body, q)
            elif tag == 'SKPL':
                f['azimuth'], f['incidence'] = struct.unpack_from('<2f', body, 28)
                f['intensity'] = _f3(body, 38)
                f['ambient'] = _f3(body, 50)
            elif tag == '0x10c':
                k = body[9]                      # u8-length name at body+9 (trigger link) shifts the rest
                f['position'] = _f3(body, 55 + k)
                f['rotation'] = _f3(body, 67 + k)
                f['file'] = _find_lstr(body, b'.dis')
            elif tag in ('0x100', 'TRRT'):     # StaticShape and Turret share the shape base layout
                f['position'] = _f3(body, 48)
                f['rotation'] = _f3(body, 60)
                f['file'] = _find_lstr(body, b'.dts')
            elif tag == 'DPNT':
                r = struct.unpack_from('<9f', body, 28)
                f['matrix'] = [list(r[0:3]), list(r[3:6]), list(r[6:9])]
                f['position'] = _f3(body, 64)
        except (struct.error, IndexError, ValueError):
            f['_error'] = True
        f['_raw'] = body
    return o, p + 8 + size + (size & 1)


def _find_lstr(b, ext):
    """A u32-length-prefixed file name ending in ext (e.g. b'.dis') inside a binary body."""
    i = b.lower().find(ext)
    if i < 0:
        return None
    for k in range(i - 4, max(i - 80, -1), -1):
        n, = struct.unpack_from('<I', b, k)
        s = k + 4
        if s + n in (i + 4, i + 5) and all(32 < c < 127 for c in b[s:i]):
            return b[s:i + 4].decode('latin1')
    return None


def parse_binary(d):
    root, _ = _obj(d, 0)
    return root
