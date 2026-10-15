"""Aerial Assault .TER heightfields.

Layout (little endian, found by comparison with the mission placements and the Tribes 2 versions of the same maps):
  u8   version (2)
  u16  heights[256 * 256]   row-major, row = file X index, column = file Z index; metres = value / 32
  u8   flags[256 * 256]     per square (bit 7 and the low bits are not interpreted)
  n x  Pascal string        material names ("LushWorld.Lakebed"), until the layer data begins
  u8   layers[n][256 * 256] blend weight of each material per vertex (they sum to ~255); the last n * 65536 bytes
  Squares are 8 m, the grid starts at file (0, 0) and spans 2048 m.

World axes: file X = north, Y = up, Z = east (right-handed); the engine frame is x east, y up, z south:
engine (x, y, z) = (file Z, file Y, -file X). engine_grid() returns the arrays in the engine's terrain layout
(rows = +z = south, columns = +x = east).
"""
import numpy as np

SIZE = 256
SQUARE = 8.0
HEIGHT_DIV = 32.0


def parse(data):
    n2 = SIZE * SIZE
    if len(data) < 1 + 3 * n2 or data[0] != 2:
        raise ValueError('not a version 2 terrain')
    heights = np.frombuffer(data, '<u2', n2, 1).reshape(SIZE, SIZE) / HEIGHT_DIV
    pos = 1 + 2 * n2
    flags = np.frombuffer(data, 'u1', n2, pos).reshape(SIZE, SIZE)
    pos += n2
    names = []
    while pos < len(data):
        ln = data[pos]
        s = data[pos + 1:pos + 1 + ln]
        if ln < 3 or len(s) != ln or not all(32 <= c < 127 for c in s) or b'.' not in s:
            break
        names.append(s.decode('ascii'))
        pos += 1 + ln
    n = len(names)
    if (len(data) - pos) < n * n2:
        raise ValueError('terrain layers truncated')
    base = len(data) - n * n2
    layers = [np.frombuffer(data, 'u1', n2, base + k * n2).reshape(SIZE, SIZE) for k in range(n)]
    return {'heights': heights, 'flags': flags, 'materials': names, 'layers': layers}


def engine_grid(a):
    """File grid [x index, z index] -> engine grid [row (south), column (east)]."""
    return a[::-1, :]


def engine_origin():
    """Engine (x, z) of grid sample (0, 0): column 0 = file z 0, row 0 = file x 255 * SQUARE (z = -that)."""
    return [0.0, -(SIZE - 1) * SQUARE]


def hole_square(index):
    """MISSION.TXT EMPTYSQUARES value (file x index * 256 + z index) -> [column, row] in the engine grid."""
    xi, zi = divmod(index, SIZE)
    return [zi, SIZE - 2 - xi]
