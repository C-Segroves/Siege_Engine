"""Aerial Assault bitmaps (.XBM, .XBMP): PS2 8-bit paletted textures.

Header (8 u32): pixel-block bytes, CLUT bytes, width, height, stride, format (0x107), levels, 0x27/0x28.
  .XBM   header, w*h index bytes, CLUT                       (lightmaps, interior textures)
  .XBMP  header, block { u32 data_offset(48), levels x (u32 width|height<<16, u32 end offset), padding, indices of every
         mip level }, CLUT(s)                                (terrain, shapes, HUD)
A CLUT holds 256 RGBA entries (alpha 0x80 = opaque), stored in the PS2 CSM1 order (entries 8..15 and 16..23 of every 32
swapped). XBMP files can hold several CLUTs (clut_bytes / 1024); the first is used.
"""
import struct

import numpy as np

HEADER = 32
CLUT_ENTRIES = 256


def _unswizzle_clut(pal):
    out = pal.copy()
    for i in range(CLUT_ENTRIES):
        k = i & 0x18
        j = i + 8 if k == 0x08 else (i - 8 if k == 0x10 else i)
        out[i] = pal[j]
    return out


def _alpha(a):
    return np.minimum(255, a.astype(np.uint16) * 2).astype(np.uint8)


def _level_bytes(w, h, mode):
    return w * h * 4 if mode == 'rgba' else (w * h + 1) // 2 if mode == 'p4' else w * h


def _read_level(data, pos, w, h, mode):
    n = _level_bytes(w, h, mode)
    raw = np.frombuffer(data, 'u1', n, pos)
    if mode == 'rgba':
        return raw.reshape(h, w, 4)
    if mode == 'p4':
        px = np.empty(n * 2, 'u1')
        px[0::2] = raw & 15
        px[1::2] = raw >> 4
        return px[:w * h].reshape(h, w)
    return raw.reshape(h, w)


def parse(data):
    """-> dict(width, height, mode ('p8' | 'p4' | 'rgba'), levels (index or RGBA arrays, mip 0 first),
    palettes [(n, 4) uint8 RGBA, alpha already 0..255]); the first palette is the picture's."""
    if len(data) < HEADER:
        raise ValueError('bitmap too short')
    pix_bytes, clut_bytes, w, h, _stride, _fmt, nlev, _x = struct.unpack_from('<8I', data)
    mode = {1024: 'p8', 64: 'p4', 0: 'rgba'}.get(clut_bytes) if clut_bytes in (0, 64) or clut_bytes % 1024 == 0 else None
    if mode is None and clut_bytes % 1024 == 0:
        mode = 'p8'
    if mode is None or w == 0 or h == 0:
        raise ValueError('unsupported bitmap header')
    if clut_bytes > 1024:
        mode = 'p8'
    levels = []
    if nlev > 0:                                             # mip table: u32 data offset, then dims / end offset pairs
        pos = HEADER + struct.unpack_from('<I', data, HEADER)[0]
        for k in range(nlev + 1):
            dims = struct.unpack_from('<I', data, HEADER + 4 + 8 * k)[0]
            lw, lh = dims & 0xFFFF, dims >> 16
            levels.append(_read_level(data, pos, lw, lh, mode))
            pos += _level_bytes(lw, lh, mode)
    else:
        levels.append(_read_level(data, HEADER, w, h, mode))
    pals = []
    clut_at = len(data) - clut_bytes
    if mode == 'p8':
        raw = np.frombuffer(data, 'u1', 1024, clut_at).reshape(256, 4)
        pal = _unswizzle_clut(raw)
        pals.append(np.concatenate([pal[:, :3], _alpha(pal[:, 3:4])], axis=1))
    elif mode == 'p4':
        pal = np.frombuffer(data, 'u1', 64, clut_at).reshape(16, 4)
        pals.append(np.concatenate([pal[:, :3], _alpha(pal[:, 3:4])], axis=1))
    else:
        levels = [np.concatenate([lv[..., :3], _alpha(lv[..., 3:4])], axis=-1) for lv in levels]
    return {'width': w, 'height': h, 'mode': mode, 'levels': levels, 'palettes': pals}


def to_rgba(bmp, level=0, palette=0):
    """(h, w, 4) uint8 image of one mip level."""
    if bmp['mode'] == 'rgba':
        return bmp['levels'][level]
    return bmp['palettes'][palette][bmp['levels'][level]]
