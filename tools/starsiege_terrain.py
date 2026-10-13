"""Darkstar terrain (GFIL .dtf + GBLK .dtb) decoder and exporter -- Starsiege (1999) and Tribes.

Shared Darkstar terrain decoder; export_darkstar_maps.py should import this
(read_gfil / read_gblk / assemble / load_terrain) instead of duplicating it.

Format (reverse engineered; see docs/formats/starsiege.md section 7):

.dtf  "GFIL" u32 size, u32 version(1), u32 n + n chars DML name (no NUL, e.g. "Mars.terrain.dml"),
      u32 blockCount (distinct blocks / .dtb files), u32 detailCount, u32 scaleShift
      (square = 1 << scaleShift metres: Starsiege 5 = 32 m, Tribes 3 = 8 m), 32 bytes unknown
      (lighting params?), f32 minHeight, f32 maxHeight, u32 mapW, u32 mapH, u32 unknown (2 SS / 0 Tribes),
      mapW*mapH u32 block ids (row-major, x fastest, row index = +y), u32 n, n x (u32 0, u32 id).
.dtb  "GBLK" u32 size, u32 version(4|5; v3 = uncompressed variant, see read_gblk), char name[16] ("block-<k>"), u32 detailCount,
      u32 unknown(0), f32 minHeight, f32 maxHeight, u32 sizeX, u32 sizeY (squares; 64 SS, 256 Tribes),
      then a chain of {u32 rawSize, LZHUF stream} (tools/darkstar_lzh.py):
        1. heights: (sizeX+1)*(sizeY+1) f32 metres, x fastest, row index = +y; edges are shared with
           the neighbouring block (identical values), so blocks overlap by one sample;
        2. materials: sizeX*sizeY x {u8 flags, u8 index}: index into the DML, flags bits 0..2 = tile
           rotate / flip (exact meaning approximated: bit0 rotate 90, bit1 flip x, bit2 flip y);
        3. further streams (pin maps / light map) -- not decoded.
      Streams are not byte-exact delimited: the decoder may stop up to 3 bytes before the next u32
      size, so the next header is located by matching its expected size.

Coordinates: arrays returned by load_terrain are indexed [row, col] with col = original +x
(east) and row = original +y (north); sample [0, 0] is at origin_xy (verified against Tribes
Raindance object heights: best fit with no flip/transpose).
Engine export converts Z-up original (x, y, z) -> engine (x, z, -y): rows are flipped so engine
row 0 is the northern edge (min engine z).

API:
  load_terrain(ted_dir) -> dict
  export_map_terrain(ted_dir, out_dir, planet, origin_xy=None, crop=None) -> terrain schema dict
CLI:
  python tools/starsiege_terrain.py <ted_dir> <out_png>      shaded-relief preview
  python tools/starsiege_terrain.py --all <ted_root>         decode every *.ted dir (check)
"""
import glob, os, struct, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from darkstar_lzh import decode as lzh_decode  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SS_EXTRACTED = os.path.join(ROOT, 'starsiege', 'extracted')


# ----------------------------------------------------------------------------- file readers

def read_gfil(d):
    if d[:4] != b'GFIL':
        raise ValueError('not a GFIL file: %r' % d[:4])
    version, n = struct.unpack_from('<II', d, 8)
    p = 16
    dml = d[p:p + n].split(b'\0')[0].decode('latin1')
    p += n
    nblocks, detail, shift = struct.unpack_from('<3I', d, p)
    p += 12
    unknown = d[p:p + 32]
    p += 32
    hmin, hmax = struct.unpack_from('<2f', d, p)
    w, h, unk2 = struct.unpack_from('<3I', d, p + 8)
    p += 20
    bmap = np.frombuffer(d, '<u4', w * h, p).reshape(h, w).copy()
    p += 4 * w * h
    cnt, = struct.unpack_from('<I', d, p)
    ids = [struct.unpack_from('<II', d, p + 4 + 8 * i) for i in range(cnt)]
    return {'version': version, 'dml': dml, 'block_count': nblocks, 'detail': detail,
            'scale_shift': shift, 'square': float(1 << shift), 'height_range': (hmin, hmax),
            'map': bmap, 'map_unknown': unk2, 'block_ids': [a for a, _ in ids], 'block_extra': [b for _, b in ids], 'unknown': unknown}


def _next_stream(d, p, expect):
    """Locate the u32 size header (== expect) at p..p+3 (LZH streams carry 0-3 trailing bytes)."""
    for q in range(p, min(p + 4, len(d) - 3)):
        if struct.unpack_from('<I', d, q)[0] == expect:
            return q
    raise ValueError('GBLK stream header (size %d) not found at 0x%x' % (expect, p))


def read_gblk(d, materials=True):
    if d[:4] != b'GBLK':
        raise ValueError('not a GBLK block: %r' % d[:4])
    version, = struct.unpack_from('<I', d, 8)
    name = d[12:28].split(b'\0')[0].decode('latin1')
    detail, unk, hmin, hmax, sx, sy = struct.unpack_from('<IIffII', d, 28)
    p = 52
    nh = (sx + 1) * (sy + 1) * 4
    if version < 4:
        # version 3 (only cin_CB.ted): 4 u32 (pointers) instead of the name, uncompressed data:
        # row 0 = (sx+1) raw f32; rows 1..sy-1 = {f32 step, f32 h[0], (sx-1) int8 deltas
        # (h[c] = h[c-1] + step*delta), f32 h[sx]}; row sy = (sx+1) raw f32 (block edges exact);
        # then sx*sy {u8 flags, u8 index} materials raw; then a light map (not decoded).
        n = sx + 1
        H = np.empty((sy + 1, n), np.float32)
        H[0] = np.frombuffer(d, '<f4', n, p)
        p += 4 * n
        for r in range(1, sy):
            step, h0 = struct.unpack_from('<ff', d, p)
            q = np.frombuffer(d, 'i1', sx - 1, p + 8).astype(np.float64)
            H[r, :sx] = h0 + np.concatenate([[0.0], np.cumsum(step * q)])
            H[r, sx], = struct.unpack_from('<f', d, p + 8 + sx - 1)
            p += 12 + sx - 1
        H[sy] = np.frombuffer(d, '<f4', n, p)
        p += 4 * n
        mats = np.frombuffer(d, 'u1', sx * sy * 2, p).reshape(sy, sx, 2) if materials else None
        return {'version': version, 'name': '', 'detail': detail, 'height_range': (hmin, hmax),
                'size': (sx, sy), 'heights': H, 'mat_flags': None if mats is None else mats[..., 0],
                'mat_index': None if mats is None else mats[..., 1]}
    p = _next_stream(d, p, nh)
    raw, used = lzh_decode(d[p + 4:], nh, with_pos=True)
    heights = np.frombuffer(raw, '<f4').reshape(sy + 1, sx + 1)
    p += 4 + used
    mats = None
    if materials:
        nm = sx * sy * 2
        p = _next_stream(d, p, nm)
        raw, used = lzh_decode(d[p + 4:], nm, with_pos=True)
        mats = np.frombuffer(raw, 'u1').reshape(sy, sx, 2)
        p += 4 + used
    return {'version': version, 'name': name, 'detail': detail, 'height_range': (hmin, hmax),
            'size': (sx, sy), 'heights': heights, 'mat_flags': None if mats is None else mats[..., 0],
            'mat_index': None if mats is None else mats[..., 1]}


def _find_files(ted_dir):
    dtfs = glob.glob(os.path.join(ted_dir, '*.dtf'))
    if len(dtfs) != 1:
        raise FileNotFoundError('%s: expected one .dtf, found %d' % (ted_dir, len(dtfs)))
    dtf = dtfs[0]
    base = dtf[:-4]
    return dtf, base


# ----------------------------------------------------------------------------- terrain assembly

def load_terrain(ted_dir, materials=True):
    """Decode a terrain volume directory (<name>.dtf + <name>#k.dtb).

    Returns {"heights": float32 [rows, cols] metres (row = original +y / north, col = original +x),
    "materials": uint8 [rows-1, cols-1] DML index per square (or None), "mat_flags": uint8 same shape,
    "square": metres, "origin_xy": (x0, y0) original frame of sample [0,0] (default: centred, which
    matches Starsiege STER placement -(w*square)/2), "size": (cols, rows) samples, "dml": name,
    "height_range": (min, max) from GFIL, "notes": str}.
    """
    dtf, base = _find_files(ted_dir)
    g = read_gfil(open(dtf, 'rb').read())
    blocks = {}
    for k, bid in enumerate(g['block_ids']):
        path = '%s#%d.dtb' % (base, k)
        if not os.path.exists(path):
            cand = [f for f in glob.glob(os.path.join(ted_dir, '*.dtb')) if f.endswith('#%d.dtb' % k)]
            if not cand:
                raise FileNotFoundError(path)
            path = cand[0]
        blocks[bid] = read_gblk(open(path, 'rb').read(), materials)
    bmap = g['map']
    mh, mw = bmap.shape
    sx, sy = next(iter(blocks.values()))['size']
    rows, cols = mh * sy + 1, mw * sx + 1
    H = np.zeros((rows, cols), np.float32)
    M = np.zeros((rows - 1, cols - 1), np.uint8) if materials else None
    F = np.zeros((rows - 1, cols - 1), np.uint8) if materials else None
    no_mats = False
    for by in range(mh):
        for bx in range(mw):
            b = blocks[int(bmap[by, bx])]
            H[by * sy:(by + 1) * sy + 1, bx * sx:(bx + 1) * sx + 1] = b['heights']
            if materials and b['mat_index'] is None:
                M[by * sy:(by + 1) * sy, bx * sx:(bx + 1) * sx] = 255   # unknown -> fallback colour
                no_mats = True
            elif materials:
                M[by * sy:(by + 1) * sy, bx * sx:(bx + 1) * sx] = b['mat_index']
                F[by * sy:(by + 1) * sy, bx * sx:(bx + 1) * sx] = b['mat_flags']
    sq = g['square']
    notes = ('%d unique %dx%d-square blocks tiled in a %dx%d block map; heights decoded exactly; '
             'origin defaults to centred (use the mission STER/SimTerrain position)'
             % (len(blocks), sx, sy, mw, mh))
    if no_mats:
        notes += '; blocks without a material map (albedo uses the average tile colour)'
    if any(b["version"] < 4 for b in blocks.values()):
        notes += '; version-3 blocks: interior heights int8-delta quantised (as stored)'
    return {'heights': H, 'materials': M, 'mat_flags': F, 'square': sq,
            'origin_xy': (-(cols - 1) * sq / 2.0, -(rows - 1) * sq / 2.0), 'size': (cols, rows),
            'dml': g['dml'], 'height_range': g['height_range'], 'gfil': g, 'notes': notes}


# ----------------------------------------------------------------------------- materials -> colours

def find_world(dml_or_planet):
    """Return the <Planet>.Sim directory for a DML name ("Mars.terrain.dml") or planet ("Mars")."""
    key = os.path.basename(dml_or_planet).split('.')[0].lower()
    for d in glob.glob(os.path.join(SS_EXTRACTED, '*.Sim')):
        if os.path.basename(d).split('.')[0].lower() == key:
            return d
    return None


def _read_dml(path):
    from darkstar_dts import R, read_material_list
    d = open(path, 'rb').read()
    if d[:4] == b'PERS':
        n, = struct.unpack_from('<H', d, 8)
        p = 10 + n
        ver, = struct.unpack_from('<I', d, p)
        r = R(d, p + 4)
    else:
        r, ver = R(d, 0), 4
    return read_material_list(r, ver)


def _orient(tile, flags):
    # Order/direction chosen by minimising colour seams between neighbouring squares on HA0
    # (flip x, flip y, then rotate 90 deg clockwise; bitmap row 0 = north edge of the square).
    # Bit 0x40 (rare) is ignored.
    if flags & 2:
        tile = tile[:, ::-1]
    if flags & 4:
        tile = tile[::-1, :]
    if flags & 1:
        tile = np.rot90(tile, -1)
    return tile


def material_tiles(world_dir, px=2, palette='d'):
    """{dml_index: uint8 [px, px, 3] downsampled tile colour (tile row 0 = original +y side? assumed
    bitmap row 0 = north)} for every material of the world's terrain DML."""
    from darkstar_gfx import read_pbmp, read_ppl, palette_for
    planet = os.path.basename(world_dir).split('.')[0]
    files = {f.lower(): os.path.join(world_dir, f) for f in os.listdir(world_dir)}
    dml = files.get(('%s.terrain.dml' % planet).lower())
    pplf = files.get(('%s.%s.ppl' % (planet, palette)).lower())
    if not dml or not pplf:
        return {}
    ml = _read_dml(dml)
    ppl = read_ppl(open(pplf, 'rb').read())
    out = {}
    for i, m in enumerate(ml['materials'][:ml['count']]):
        f = files.get(m['file'].lower())
        if not f:
            continue
        try:
            b = read_pbmp(open(f, 'rb').read())
            pal = np.array(palette_for(ppl, b['palette_id'])['colors'], np.uint8)
            img = pal[np.frombuffer(b['pixels'], np.uint8).reshape(b['h'], b['w'])]
        except Exception:
            continue
        hh, ww = img.shape[:2]
        k = max(1, min(hh, ww) // px)
        img = img[:k * px, :k * px].astype(np.float32).reshape(px, k, px, k, 3).mean(axis=(1, 3))
        out[i] = img.astype(np.uint8)
    return out


def bake_albedo(materials, mat_flags, tiles, px=2):
    """Colour map [rows*px, cols*px, 3] in the same row order as `materials` (row = +y)."""
    rows, cols = materials.shape
    img = np.zeros((rows, cols, px, px, 3), np.uint8)
    fallback = (np.mean([t.reshape(-1, 3).mean(0) for t in tiles.values()], 0).astype(np.uint8)
                if tiles else np.array([128, 112, 96], np.uint8))
    for idx in np.unique(materials):
        t = tiles.get(int(idx))
        m = materials == idx
        for fl in np.unique(mat_flags[m]):
            sel = m & (mat_flags == fl)
            if t is None:
                img[sel] = fallback
            else:
                # bitmap row 0 assumed at the square's north edge -> flip into row = +y order
                img[sel] = _orient(t, int(fl))[::-1]
    return img.transpose(0, 2, 1, 3, 4).reshape(rows * px, cols * px, 3)


# ----------------------------------------------------------------------------- engine export

def _crop(t, crop, origin):
    """crop = (xmin, ymin, xmax, ymax) original metres -> sub-arrays + new origin."""
    sq = t['square']
    H, M, F = t['heights'], t['materials'], t['mat_flags']
    if not crop:
        return H, M, F, origin
    x0, y0 = origin
    c0 = max(0, int(np.floor((crop[0] - x0) / sq)))
    r0 = max(0, int(np.floor((crop[1] - y0) / sq)))
    c1 = min(H.shape[1] - 1, int(np.ceil((crop[2] - x0) / sq)))
    r1 = min(H.shape[0] - 1, int(np.ceil((crop[3] - y0) / sq)))
    H = H[r0:r1 + 1, c0:c1 + 1]
    if M is not None:
        M, F = M[r0:r1, c0:c1], F[r0:r1, c0:c1]
    return H, M, F, (x0 + c0 * sq, y0 + r0 * sq)


def export_map_terrain(ted_dir, out_dir, planet=None, origin_xy=None, crop=None, px=None):
    """Write height.r32 + albedo.png to out_dir and return the map-schema "terrain" dict.

    planet: world name ("Mars") or None to use the DML named by the .dtf. origin_xy: original-frame
    position of sample [0,0] (mission STER/SimTerrain position); default centred. crop: optional
    (xmin, ymin, xmax, ymax) in original metres."""
    from PIL import Image
    t = load_terrain(ted_dir)
    origin = tuple(origin_xy) if origin_xy is not None else t['origin_xy']
    H, M, F, origin = _crop(t, crop, origin)
    sq = t['square']
    rows, cols = H.shape
    os.makedirs(out_dir, exist_ok=True)
    # engine: rows = +z = original -y -> flip so engine row 0 = northernmost original row
    np.ascontiguousarray(H[::-1], dtype='<f4').tofile(os.path.join(out_dir, 'height.r32'))
    if px is None:
        px = max(1, min(8, 2048 // max(rows - 1, cols - 1)))
    world = find_world(planet or t['dml'])
    tiles = material_tiles(world, px) if world else {}
    notes = t['notes']
    if not tiles:
        notes += '; planet tiles not found: albedo is flat grey-brown'
    img = bake_albedo(M, F, tiles, px)[::-1]
    Image.fromarray(np.ascontiguousarray(img)).save(os.path.join(out_dir, 'albedo.png'), optimize=True)
    notes += ('; albedo baked from %s terrain tiles at %d px/square (tile rotate/flip flags '
              'approximated, no lightmap)' % (os.path.basename(world) if world else '?', px))
    x0, y0 = origin
    z0 = -(y0 + (rows - 1) * sq)
    return {'heights': 'height.r32', 'size': [cols, rows], 'square': sq,
            'origin': [float(x0), float(z0)], 'height_scale': 1.0, 'albedo': 'albedo.png',
            'albedo_repeat': 1.0, 'height_range': [float(H.min()), float(H.max())], 'notes': notes}


# ----------------------------------------------------------------------------- preview

def preview(ted_dir, out_png, max_px=1024):
    from PIL import Image
    t = load_terrain(ted_dir)
    H = t['heights'].astype(np.float64)
    sq = t['square']
    gy, gx = np.gradient(H, sq)
    # light from the north-west (original frame), 45 deg elevation
    lx, ly, lz = -0.5, 0.5, 0.7071
    n = np.sqrt(gx * gx + gy * gy + 1)
    shade = np.clip((-gx * lx - gy * ly + lz) / n, 0, 1)
    world = find_world(t['dml'])
    tiles = material_tiles(world, 1) if world else {}
    if tiles:
        col = bake_albedo(t['materials'], t['mat_flags'], tiles, 1).astype(np.float64)
        col = np.pad(col, ((0, 1), (0, 1), (0, 0)), mode='edge')
    else:
        hn = (H - H.min()) / max(1e-6, np.ptp(H))
        col = np.stack([90 + 140 * hn, 80 + 110 * hn, 60 + 90 * hn], -1)
    img = np.clip(col * (0.35 + 0.9 * shade[..., None]), 0, 255).astype(np.uint8)[::-1]  # north up
    im = Image.fromarray(img)
    if max(im.size) > max_px:
        im = im.resize((max_px, max_px * im.size[1] // im.size[0]), Image.LANCZOS)
    os.makedirs(os.path.dirname(os.path.abspath(out_png)), exist_ok=True)
    im.save(out_png)
    return t


def _check(path):
    try:
        t = load_terrain(path)
        H = t['heights']
        return '%-34s %-22s %4dx%-4d sq=%2.0f  h=[%7.1f %7.1f]  gfil=[%7.1f %7.1f]' % (
            os.path.basename(path), t['dml'], t['size'][0], t['size'][1], t['square'], H.min(), H.max(),
            t['height_range'][0], t['height_range'][1])
    except Exception as e:
        return '%-34s FAILED %s: %s' % (os.path.basename(path), type(e).__name__, e)


def main(argv):
    if len(argv) == 2 and argv[0] == '--all':
        from multiprocessing import Pool
        dirs = sorted(d for d in glob.glob(os.path.join(argv[1], '*.ted')) if os.path.isdir(d))
        with Pool() as pool:
            for line in pool.imap(_check, dirs):
                print(line, flush=True)
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 1
    t = preview(argv[0], argv[1])
    H = t['heights']
    print('%s: %s %dx%d samples, square %.0f m, heights %.1f..%.1f (GFIL %.1f..%.1f)' % (
        argv[0], t['dml'], t['size'][0], t['size'][1], t['square'], H.min(), H.max(), *t['height_range']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
