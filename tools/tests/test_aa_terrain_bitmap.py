"""aa_terrain and aa_bitmap on synthetic data.

    python -m pytest tools/tests/test_aa_terrain_bitmap.py
"""
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import aa_bitmap  # noqa: E402
import aa_terrain  # noqa: E402


def test_terrain_layout_and_axes():
    n2 = aa_terrain.SIZE ** 2
    heights = np.arange(n2, dtype='<u2') % 1000
    name = b'LushWorld.Rock'
    data = (b'\x02' + heights.tobytes() + bytes(n2) + bytes([len(name)]) + name + bytes(4)
            + b''.join(bytes([k + 1]) * n2 for k in range(1)))
    t = aa_terrain.parse(data)
    assert t['materials'] == ['LushWorld.Rock'] and len(t['layers']) == 1 and t['layers'][0][0, 0] == 1
    assert t['heights'][0, 1] == 1 / 32.0
    g = aa_terrain.engine_grid(t['heights'])
    assert g[0, 0] == t['heights'][255, 0]            # engine row 0 = the largest file X (north is -z)
    assert aa_terrain.engine_origin() == [0.0, -2040.0]
    assert aa_terrain.hole_square(2 * 256 + 5) == [5, 254 - 2]


def _xbm(w, h, idx, pal):
    return struct.pack('<8I', w * h, 1024, w, h, w, 0x107, 0, 39) + idx.tobytes() + pal.tobytes()


def test_bitmap_p8_clut_swizzle_and_alpha():
    pal = np.zeros((256, 4), 'u1')
    pal[:, 0] = np.arange(256)
    pal[:, 3] = 0x80
    pal[8] = (1, 2, 3, 0x80)          # stored entry 8 belongs to index 16 once the CSM1 order is undone
    idx = np.array([[16, 8], [0, 255]], 'u1')
    bmp = aa_bitmap.parse(_xbm(2, 2, idx, pal))
    img = aa_bitmap.to_rgba(bmp)
    assert tuple(img[0, 0]) == (1, 2, 3, 255)          # 0x80 -> opaque
    assert img[1, 1, 0] == 255


def test_bitmap_p4_and_rgba():
    pal = np.zeros((16, 4), 'u1')
    pal[:, 0] = np.arange(16) * 16
    pal[:, 3] = 0x40
    raw = np.array([0x21, 0x43], 'u1')                 # low nibble first: 1 2 3 4
    d = struct.pack('<8I', 2, 64, 2, 2, 2, 0x207, 0, 63) + raw.tobytes() + pal.tobytes()
    img = aa_bitmap.to_rgba(aa_bitmap.parse(d))
    assert img[0, 0, 0] == 16 and img[0, 1, 0] == 32 and img[1, 1, 0] == 64 and img[0, 0, 3] == 128
    px = np.array([[(10, 20, 30, 0x80)]], 'u1')
    d = struct.pack('<8I', 4, 0, 1, 1, 1, 3, 0, 16) + px.tobytes()
    assert tuple(aa_bitmap.to_rgba(aa_bitmap.parse(d))[0, 0]) == (10, 20, 30, 255)


def test_bitmap_mip_table():
    w = 4
    table = struct.pack('<I', 48) + struct.pack('<II', w | (w << 16), 0) + struct.pack('<I', 2 | (2 << 16))
    table = table.ljust(48, b'\0')
    body = table + bytes([1] * 16) + bytes([2] * 4)
    d = struct.pack('<8I', len(body), 1024, w, w, w, 0x107, 1, 40) + body + bytes(1024)
    bmp = aa_bitmap.parse(d)
    assert [l.shape for l in bmp['levels']] == [(4, 4), (2, 2)] and bmp['levels'][1][0, 0] == 2
