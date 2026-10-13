"""Darkstar interiors (Starsiege: Tribes 1998 / Starsiege 1999): ITRs shapes (.dis) and ITRGeometry (.dig).

.dis  "ITRs" u32 size, u32 version (3), ... then a string table: state names, per detail level the
      geometry file ("<name>-<detail><state>.dig") and light map ("<name>-<detail><state><light>.dil"),
      the material list (<name>.dml) and the light-state name. read_dis() returns the file names in order
      (detail 0 = most detailed first).
.dig  PERS "ITRGeometry" version 7 (v4 in a few Starsiege low details):
        u32 buildId, f32 textureScale (texels per metre at mip 0; Tribes 32, Starsiege 1..40),
        f32 box[6] (min xyz, max xyz; interior space, metres, z up),
        u32 nSurfaces, nNodes, nSolidLeaves, nEmptyLeaves, nBits, nVertices, nPoint3, nPoint2, nPlanes,
        Surface[nSurfaces]  20 bytes:
          u8 flags   bit4 = scale-shift sign, bits1-3 = |scale shift| s: surface texel density =
                     textureScale * 2^(+-s) "units" per metre (surface cache resolution)
          u8 material (index into the .dml; 0xff = none)
          u8 textureSize x, y   (units)    u8 textureOffset x, y (units, wrap at 256)
          u16 plane, u32 firstVertex, u32 firstPoint (visibility list), u8 vertexCount, u8 pointCount
        BSPNode[nNodes] 8 bytes (i16 plane, i16 front, i16 back, i16 pad)  -- negative = leaf
        BSPLeafSolid[n] 12 bytes, BSPLeafEmpty[n] 44 bytes (flags, surfaces, pvs, box) -- unused here
        u8 bits[nBits], Vertex[nVertices] {u16 point3, u16 point2}, Point3F[nPoint3] (metres),
        Point2F[nPoint2] (0..1 across the surface's textureSize), TPlaneF[nPlanes] {x, y, z, d},
        u32 highestMipLevel, u32 0
Texture coordinates (verified: adjacent surfaces continue the texture across their shared edge, mod 256):
  texel(mip 0) = (textureOffset + point2 * textureSize) * 2^-s   (s signed, see flags)
  uv = texel / bitmap size  (tiles; v down, PBMP rows)
Surfaces are convex polygons (vertex loop) on their plane; the visible side is where the BSP's empty
leaves are -- the polygon winding (Newell normal) points to the visible side.
"""
import re, struct


def read_dis(d):
    names = [s.decode('latin1') for s in re.findall(rb'[\x20-\x7e]{3,}', d[8:])]
    return {'digs': [n for n in names if n.lower().endswith('.dig')],
            'dils': [n for n in names if n.lower().endswith('.dil')],
            'dml': next((n for n in names if n.lower().endswith('.dml')), None)}


def read_dig(d):
    if d[:4] != b'PERS':
        raise ValueError('not PERS')
    nlen, = struct.unpack_from('<h', d, 8)
    name = d[10:10 + nlen].decode('latin1')
    if name != 'ITRGeometry':
        raise ValueError(name)
    p = 10 + nlen + (1 if nlen < 16 else 0)
    ver, build, tscale = struct.unpack_from('<IIf', d, p); p += 12
    if ver != 7:
        raise ValueError('ITRGeometry version %d' % ver)
    box = struct.unpack_from('<6f', d, p); p += 24
    ns, nn, nsl, nel, nbits, nv, np3, np2, npl = struct.unpack_from('<9I', d, p); p += 36
    surfs = []
    for i in range(ns):
        fl, mat, sx, sy, ox, oy, plane, vi, pi, vc, pc = struct.unpack_from('<6BHIIBB', d, p + 20 * i)
        shift = (fl >> 1) & 7
        if fl & 0x10:
            shift = -shift
        surfs.append({'flags': fl, 'material': mat, 'size': (sx, sy), 'offset': (ox, oy), 'shift': shift,
                      'plane': plane, 'first': vi, 'count': vc})
    p += 20 * ns + 8 * nn + 12 * nsl + 44 * nel + nbits
    verts = [struct.unpack_from('<HH', d, p + 4 * i) for i in range(nv)]; p += 4 * nv
    p3 = [struct.unpack_from('<3f', d, p + 12 * i) for i in range(np3)]; p += 12 * np3
    p2 = [struct.unpack_from('<2f', d, p + 8 * i) for i in range(np2)]; p += 8 * np2
    planes = [struct.unpack_from('<4f', d, p + 16 * i) for i in range(npl)]; p += 16 * npl
    return {'version': ver, 'texture_scale': tscale, 'box': box, 'surfaces': surfs, 'vertices': verts,
            'points': p3, 'tex': p2, 'planes': planes, 'unconsumed': len(d) - p}


def polygons(g):
    """[{material, pts: [(x,y,z)...], texel: [(u,v)...] (mip-0 texels), normal}] for every drawable surface."""
    out = []
    for s in g['surfaces']:
        if s['count'] < 3:
            continue
        vs = g['vertices'][s['first']:s['first'] + s['count']]
        pts = [g['points'][a] for a, _ in vs]
        k = 2.0 ** -s['shift']
        tex = [((s['offset'][0] + g['tex'][b][0] * s['size'][0]) * k,
                (s['offset'][1] + g['tex'][b][1] * s['size'][1]) * k) for _, b in vs]
        # Newell normal of the loop
        nx = ny = nz = 0.0
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            nx += (a[1] - b[1]) * (a[2] + b[2])
            ny += (a[2] - b[2]) * (a[0] + b[0])
            nz += (a[0] - b[0]) * (a[1] + b[1])
        ln = (nx * nx + ny * ny + nz * nz) ** 0.5
        if ln < 1e-9:
            continue
        out.append({'material': s['material'], 'pts': pts, 'texel': tex, 'normal': (nx / ln, ny / ln, nz / ln),
                    'plane': g['planes'][s['plane']] if s['plane'] < len(g['planes']) else None,
                    'flags': s['flags']})
    return out
