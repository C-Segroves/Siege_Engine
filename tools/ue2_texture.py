"""Unreal Engine 2 Texture export -> pixels (tools/ue2_package.py packages).

  read_texture(pkg, export) -> {'format', 'width', 'height', 'data' (mip 0 bytes), 'props'}
  to_rgba(tex, palette=None) -> numpy uint8 (h, w, 4);  to_height16(tex) -> numpy uint16 (h, w)

ETextureFormat (UE2): 0 P8, 1 RGBA7, 2 RGB16, 3 DXT1, 4 RGB8, 5 RGBA8, 6 NODATA, 7 DXT3, 8 DXT5, 9 L8, 10 G16, 11 RRRGGGBBB.
The mip chain is native bulk data after the tagged properties; mip 0 is found by its compact-index byte count.
"""
import numpy as np

import ue2_package as U

P8, RGB16, DXT1, RGB8, RGBA8, DXT3, DXT5, L8, G16 = 0, 2, 3, 4, 5, 7, 8, 9, 10


def expected_size(fmt, w, h):
    blocks = max(1, w // 4) * max(1, h // 4)
    return {P8: w * h, DXT1: blocks * 8, DXT3: blocks * 16, DXT5: blocks * 16, L8: w * h, G16: w * h * 2,
            RGBA8: w * h * 4, RGB8: w * h * 3, RGB16: w * h * 2}.get(fmt)


def read_texture(pkg, export, scan=400):
    props, end = U.object_with_trailing(pkg, export)
    fmt, w, h = props.get('Format', 0), props.get('USize', 0), props.get('VSize', 0)
    need = expected_size(fmt, w, h)
    if not need or not w or not h:
        return None
    limit = export['offset'] + export['size']
    for pos in range(end, min(end + scan, limit - need)):
        r = U.Reader(pkg.data, pos)
        try:
            n = r.index()
        except IndexError:
            continue
        if n == need and r.p + need <= limit:
            return {'format': fmt, 'width': w, 'height': h, 'data': bytes(pkg.data[r.p:r.p + need]), 'props': props}
    return None


def _565(v):
    r = ((v >> 11) & 31) * 255 // 31
    g = ((v >> 5) & 63) * 255 // 63
    b = (v & 31) * 255 // 31
    return r, g, b


def _decode_dxt(data, w, h, kind):
    bw, bh = max(1, w // 4), max(1, h // 4)
    bsz = 8 if kind == DXT1 else 16
    blocks = np.frombuffer(data, dtype=np.uint8).reshape(bh * bw, bsz)
    cdata = blocks[:, bsz - 8:]
    c0 = cdata[:, 0].astype(np.uint16) | (cdata[:, 1].astype(np.uint16) << 8)
    c1 = cdata[:, 2].astype(np.uint16) | (cdata[:, 3].astype(np.uint16) << 8)

    def rgb(c):
        return np.stack([((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31], axis=1).astype(np.int32)
    p0, p1 = rgb(c0), rgb(c1)
    four = (c0 > c1)[:, None] | (kind != DXT1)
    p2 = np.where(four, (2 * p0 + p1) // 3, (p0 + p1) // 2)
    p3 = np.where(four, (p0 + 2 * p1) // 3, 0)
    pal = np.stack([p0, p1, p2, p3], axis=1)                                   # (n, 4, 3)
    bits = cdata[:, 4:8].astype(np.uint32)
    word = bits[:, 0] | (bits[:, 1] << 8) | (bits[:, 2] << 16) | (bits[:, 3] << 24)
    idx = np.stack([(word >> (2 * i)) & 3 for i in range(16)], axis=1).astype(np.int64)   # (n, 16)
    out = np.take_along_axis(pal, idx[:, :, None].repeat(3, axis=2), axis=1)   # (n, 16, 3)
    alpha = np.full((len(blocks), 16), 255, dtype=np.int32)
    if kind == DXT1:
        alpha = np.where((~four) & (idx == 3), 0, 255)
    elif kind == DXT3:
        a = blocks[:, :8].astype(np.uint32)
        nib = np.stack([a[:, i // 2] >> (4 * (i % 2)) & 15 for i in range(16)], axis=1)
        alpha = nib * 17
    elif kind == DXT5:
        a0, a1 = blocks[:, 0].astype(np.int32), blocks[:, 1].astype(np.int32)
        ab = blocks[:, 2:8].astype(np.uint64)
        word = np.zeros(len(blocks), dtype=np.uint64)
        for i in range(6):
            word |= ab[:, i] << np.uint64(8 * i)
        ai = np.stack([(word >> np.uint64(3 * i)) & np.uint64(7) for i in range(16)], axis=1).astype(np.int64)
        tab = np.zeros((len(blocks), 8), dtype=np.int32)
        tab[:, 0], tab[:, 1] = a0, a1
        big = (a0 > a1)
        for k in range(1, 7):
            tab[:, k + 1] = np.where(big, ((7 - k) * a0 + k * a1) // 7, 0)
        for k in range(1, 5):
            tab[:, k + 1] = np.where(big, tab[:, k + 1], ((5 - k) * a0 + k * a1) // 5)
        tab[:, 6] = np.where(big, tab[:, 6], 0)
        tab[:, 7] = np.where(big, tab[:, 7], 255)
        alpha = np.take_along_axis(tab, ai, axis=1)
    px = np.concatenate([out, alpha[:, :, None]], axis=2).astype(np.uint8)    # (n, 16, 4)
    px = px.reshape(bh, bw, 4, 4, 4).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 4)
    return px[:h, :w]


def to_rgba(tex, palette=None):
    fmt, w, h, d = tex['format'], tex['width'], tex['height'], tex['data']
    if fmt in (DXT1, DXT3, DXT5):
        return _decode_dxt(d, w, h, fmt)
    a = np.frombuffer(d, dtype=np.uint8)
    if fmt == RGBA8:
        px = a.reshape(h, w, 4)[:, :, [2, 1, 0, 3]]               # stored BGRA
    elif fmt == RGB8:
        px = np.concatenate([a.reshape(h, w, 3)[:, :, ::-1], np.full((h, w, 1), 255, np.uint8)], axis=2)
    elif fmt == L8:
        g = a.reshape(h, w)
        px = np.stack([g, g, g, np.full_like(g, 255)], axis=2)
    elif fmt == P8 and palette is not None:
        px = np.asarray(palette, dtype=np.uint8)[a.reshape(h, w)]
    elif fmt == G16:
        g = (np.frombuffer(d, dtype='<u2').reshape(h, w) >> 8).astype(np.uint8)
        px = np.stack([g, g, g, np.full_like(g, 255)], axis=2)
    else:
        return None
    return np.ascontiguousarray(px)


def to_height16(tex):
    if tex['format'] != G16:
        return None
    return np.frombuffer(tex['data'], dtype='<u2').reshape(tex['height'], tex['width'])
