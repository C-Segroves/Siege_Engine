"""Darkstar (Starsiege: Tribes 1998 / Starsiege 1999) terrain: GFIL (.dtf) + GBLK (.dtb) decoder.

A mission terrain lives in a PVOL (`<mission>.ted` in Tribes, `<mission>.ted.vol` in Starsiege) holding
`<name>.dtf` (the GridFile) and `<name>#<n>.dtb` (one GridBlock per unique block).

GFIL ("GFIL" u32 size):
  u32 version (1), u32 nameLen, char dml[nameLen]        terrain material list (world set, e.g. lush.dml)
  u32 blockCount?  u32 detailCount  u32 scaleShift       square = 1 << scaleShift metres (Tribes 3 = 8 m,
                                                         Starsiege 5 = 32 m)
  32 bytes (editor data), f32 heightMin, f32 heightMax
  u32 mapW, u32 mapH, u32 ?, u32 blockId[mapW * mapH]   block layout (row-major, row 0 = south / min y)
  ... (block name table, unused here)
GBLK ("GBLK" u32 size), version 5:
  0x0c name "block-<n>" (8 bytes) + 2 x u32, u32 detailCount, u32 0, f32 min, f32 max, u32 W, u32 H  (squares)
  then sections, each: u32 uncompressedSize + Darkstar LZH stream (tools/darkstar_lzh.py; the stream is
  followed by one pad byte):
    1. heights   (W+1) x (H+1) float32, metres, row-major, row 0 = min y (south), col 0 = min x (west)
    2. materials W x H x {u8 flags, u8 index}: index into the DML; flags & 7 = tile orientation
       (bit0 rotate 90, bit1 flip x, bit2 flip y), 0x40/0x80 editor/empty bits
    3+. pin map / light map (not needed)
Verified on all 45 Tribes and 24+ Starsiege multiplayer terrains (heights match object placements).
"""
import os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import darkstar_lzh as L  # noqa: E402


def read_gfil(d):
    assert d[:4] == b'GFIL', d[:4]
    ver, nlen = struct.unpack_from('<II', d, 8)
    dml = d[16:16 + nlen].split(b'\0')[0].decode('latin1')
    p = 16 + nlen
    nblocks, detail, shift = struct.unpack_from('<III', d, p)
    p += 12 + 32
    hmin, hmax = struct.unpack_from('<ff', d, p)
    mw, mh = struct.unpack_from('<II', d, p + 8)
    ids = list(struct.unpack_from('<%dI' % (mw * mh), d, p + 20))     # (u32 at p+16: unknown, 0 or 2)
    return {'version': ver, 'dml': dml, 'blocks': nblocks, 'detail': detail, 'scale_shift': shift,
            'square': float(1 << shift), 'height_range': (hmin, hmax), 'map_w': mw, 'map_h': mh, 'map': ids}


def _section(d, p, expect=None):
    """u32 size + LZH stream at p (the stream may be followed by a pad byte)."""
    if expect is not None:
        for k in range(4):
            if struct.unpack_from('<I', d, p + k)[0] == expect:
                p += k
                break
    n, = struct.unpack_from('<I', d, p)
    out, used = L.decode(d[p + 4:], n, True)
    return out, p + 4 + used


def read_gblk(d, materials=True):
    import numpy as np
    assert d[:4] == b'GBLK', d[:4]
    hmin, hmax, w, h = struct.unpack_from('<ffII', d, 0x24)
    raw, p = _section(d, 0x34, (w + 1) * (h + 1) * 4)
    heights = np.frombuffer(raw, '<f4').reshape(h + 1, w + 1).copy()
    out = {'w': w, 'h': h, 'height_range': (hmin, hmax), 'heights': heights}
    if materials:
        raw, p = _section(d, p, w * h * 2)
        m = np.frombuffer(raw, np.uint8).reshape(h, w, 2)
        out['mat_flags'] = m[:, :, 0].copy()
        out['mat_index'] = m[:, :, 1].copy()
    return out


def load_ted(path):
    """Read a terrain PVOL: returns (gfil, {block_number: gblk})."""
    import darkstar_vol as V
    d, ents = V.read_vol(path)
    gfil, blocks = None, {}
    for e in ents:
        n = (e['name'] or '').lower()
        if n.endswith('.dtf'):
            gfil = read_gfil(V.file_data(d, e))
        elif n.endswith('.dtb'):
            num = int(n.rsplit('#', 1)[1].split('.')[0])
            blocks[num] = e
    return gfil, (d, blocks)


def block(ted, num, materials=True):
    import darkstar_vol as V
    d, ents = ted
    return read_gblk(V.file_data(d, ents[num]), materials)
