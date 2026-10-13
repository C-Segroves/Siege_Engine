"""Torque V12 interior reader (.dif, Tribes 2: InteriorResource version 44, Interior version 0).

Layout (Torque Game Engine interiorRes.cc / interiorIO.cc, same as Tribes 2 data on the disc):
  InteriorResource: u32 version (44), u8 previewIncluded (+ PNG if set), u32 numDetailLevels,
                    numDetailLevels x Interior, then sub-objects, triggers, path followers, force fields,
                    AI special nodes (not read here).
  Interior (v0):    u32 fileVersion (0), u32 detailLevel, u32 minPixels, Box3F (6 f32), SphereF (4 f32),
                    u8 hasAlarmState, u32 numLightStateEntries,
                    planes:   u32 nNormals, nNormals x Point3F; u32 nPlanes, nPlanes x (u16 normalIndex, f32 d)
                    points:   u32 n, n x Point3F
                    pointVis: u32 n, n x u8
                    texGens:  u32 n, n x (PlaneF x, PlaneF y)          u = x.xyz . p + x.d  (texture repeats)
                    bspNodes: u32 n, n x (u16 plane, u16 front, u16 back)
                    solidLeaves: u32 n, n x (u32 surfaceIndex, u16 surfaceCount)
                    materialList: u8 version (1), u32 count, count x (u8 len, chars)
                    windings: u32 n, n x u32 (point indices)
                    windingIndices: u32 n, n x (u32 start, u32 count)
                    zones: u32 n, n x (u16 portalStart, u16 portalCount, u32 surfaceStart, u32 surfaceCount)
                           (Tribes 2 has no zone flags word; detected by validation)
                    zoneSurfaces: u32 n x u16; zonePortalList: u32 n x u16
                    portals: u32 n, n x (u16 plane, u16 triFanCount, u32 triFanStart, u16 zoneFront, u16 zoneBack)
                    surfaces: u32 n, n x (u32 windingStart, u8 windingCount, u16 planeIndex (bit 15 = flipped),
                              u16 textureIndex, u32 texGenIndex, u8 surfaceFlags, u32 fanMask,
                              lightmap texgen (u16 finalWord, f32 xd, f32 yd), u16 lightCount,
                              u32 lightStateInfoStart, u8 mapOffsetX, mapOffsetY, mapSizeX, mapSizeY)
                    normal / alarm lightmap index per surface: u32 n, n x u8 (twice)
                    nullSurfaces: u32 n, n x (u32 windingStart, u16 planeIndex (bit 15 = flipped), u8 surfaceFlags,
                              u8 windingCount): untextured faces the engine never draws but that close the
                              hull geometry (floors over pits between rooms; the remake collides with them)
                    ... (lightmaps, hulls, ...: not needed for geometry)
  A surface's winding (windingCount point indices from windings[windingStart]) is a TRIANGLE STRIP.

Usage: python tools/torque_dif.py <file.dif> [...]   (prints a summary)
"""
import struct
import sys


class Reader:
    def __init__(self, data, pos=0):
        self.d, self.p = data, pos

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

    def f32(self):
        v = struct.unpack_from('<f', self.d, self.p)[0]
        self.p += 4
        return v

    def arr(self, fmt, n):
        sz = struct.calcsize('<' + fmt)
        if n < 0 or self.p + sz * n > len(self.d):
            raise ValueError('array out of range (%s x %d at %d)' % (fmt, n, self.p))
        v = list(struct.iter_unpack('<' + fmt, self.d[self.p:self.p + sz * n]))
        self.p += sz * n
        return v

    def string(self):
        n = self.u8()
        s = self.d[self.p:self.p + n].decode('latin1')
        self.p += n
        return s


def _count(r, limit=10_000_000):
    n = r.u32()
    if n > limit:
        raise ValueError('implausible count %d at %d' % (n, r.p - 4))
    return n


def read_interior(r, zone_flags):
    it = {}
    ver = r.u32()
    if ver != 0:
        raise ValueError('interior version %d' % ver)
    it['detail_level'] = r.u32()
    it['min_pixels'] = r.u32()
    it['bbox'] = [r.f32() for _ in range(6)]
    it['sphere'] = [r.f32() for _ in range(4)]
    it['has_alarm'] = r.u8()
    it['num_light_state_entries'] = r.u32()
    normals = r.arr('3f', _count(r))
    planes = []
    for ni, dist in r.arr('Hf', _count(r)):
        n = normals[ni]
        planes.append((n[0], n[1], n[2], dist))
    it['planes'] = planes
    it['points'] = r.arr('3f', _count(r))
    n = _count(r)
    r.p += n                       # point visibility
    it['texgens'] = r.arr('8f', _count(r))
    it['bsp_nodes'] = r.arr('3H', _count(r))
    it['solid_leaves'] = r.arr('IH', _count(r))
    mver = r.u8()
    if mver != 1:
        raise ValueError('material list version %d' % mver)
    it['materials'] = [r.string() for _ in range(_count(r, 4096))]
    it['windings'] = [w[0] for w in r.arr('I', _count(r))]
    it['winding_indices'] = r.arr('II', _count(r))
    nz = _count(r)
    it['zones'] = r.arr('HHIIH' if zone_flags else 'HHII', nz)
    r.arr('H', _count(r))          # zone surfaces
    r.arr('H', _count(r))          # zone portal list
    it['portals'] = r.arr('HHIHH', _count(r))
    surfs = []
    ns = _count(r)
    for _ in range(ns):
        s = {}
        s['winding_start'] = r.u32()
        s['winding_count'] = r.u8()
        s['plane'] = r.u16()
        s['texture'] = r.u16()
        s['texgen'] = r.u32()
        s['flags'] = r.u8()
        s['fan_mask'] = r.u32()
        r.p += 10                  # lightmap texgen
        r.p += 2 + 4 + 4           # lightCount, lightStateInfoStart, map offset/size
        surfs.append(s)
    it['surfaces'] = surfs
    for _ in range(2):             # normal and alarm lightmap index per surface
        if _count(r) != ns:
            raise ValueError('lightmap index count != surface count')
        r.p += ns
    it['null_surfaces'] = [{'winding_start': ws, 'plane': pl, 'flags': fl, 'winding_count': wc}
                           for ws, pl, fl, wc in r.arr('IHBB', _count(r))]
    _validate(it)
    return it


def _validate(it):
    npnt, nw = len(it['points']), len(it['windings'])
    for s in it['surfaces']:
        if s['winding_start'] + s['winding_count'] > nw:
            raise ValueError('surface winding out of range')
        if (s['plane'] & 0x7fff) >= len(it['planes']):
            raise ValueError('surface plane out of range')
        if s['texgen'] >= len(it['texgens']):
            raise ValueError('surface texgen out of range')
        if s['texture'] >= len(it['materials']):
            raise ValueError('surface material out of range')
    for s in it['null_surfaces']:
        if s['winding_start'] + s['winding_count'] > nw or (s['plane'] & 0x7fff) >= len(it['planes']):
            raise ValueError('null surface out of range')
    for w in it['windings']:
        if w >= npnt:
            raise ValueError('winding point out of range')


def read_dif(data, all_details=False):
    """-> {'version', 'details': [interior, ...]} (only detail 0 unless all_details)."""
    r = Reader(data)
    ver = r.u32()
    if ver != 44:
        raise ValueError('InteriorResource version %d (expected 44)' % ver)
    if r.u8():
        raise ValueError('preview bitmap present (not supported)')
    nd = r.u32()
    details = []
    for k in range(nd if all_details else min(nd, 1)):
        start = r.p
        last = None
        for zf in (False, True):
            try:
                r.p = start
                details.append(read_interior(r, zf))
                last = None
                break
            except (ValueError, struct.error, IndexError) as e:
                last = e
        if last is not None:
            raise last
        if all_details and k + 1 < nd:
            raise ValueError('reading past detail 0 needs the full interior layout (not implemented)')
    return {'version': ver, 'num_details': nd, 'details': details}


def strip_triangles(idx):
    """Triangle strip -> triangles with consistent winding."""
    out = []
    for i in range(len(idx) - 2):
        a, b, c = idx[i], idx[i + 1], idx[i + 2]
        if a == b or b == c or a == c:
            continue
        out.append((a, b, c) if i % 2 == 0 else (b, a, c))
    return out


def main():
    for f in sys.argv[1:]:
        d = read_dif(open(f, 'rb').read())
        it = d['details'][0]
        print(f, 'details', d['num_details'], 'points', len(it['points']), 'surfaces', len(it['surfaces']),
              'materials', it['materials'][:8])


if __name__ == '__main__':
    main()
