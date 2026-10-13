"""Darkstar / Phoenix bitmaps (PBMP, PBMA arrays) and palettes (PPL "PL98").

After open-siege/siege-studio bmp/bitmap.cpp and pal/palette.cpp (MIT).

PBMP: "PBMP" u32 size, then chunks {tag[4], u32 size, data}:
  head (20): u32 version(3), i32 width, i32 height, u32 bitDepth(8), u32 flags
  data     : width*height pixels (rows padded to 4 bytes), followed by the mip levels
  DETL (4) : u32 detail (mip) level count
  PiDX (4) : u32 palette id -- selects the matching palette in the world's PPL
  RIFF / other chunks are skipped.
PPL: "PL98" u32 count, u32 shadeShift, u32 hazeLevel, u32 hazeColour, 32 bytes allowedMatches,
  count x {256 x (r,g,b,flags), u32 id, u32 type}.
Tribes: every entity skin uses palette ids from the world PPL (e.g. lushWorld/lush.day.ppl);
the low (shared) part of the palette is identical across worlds so skins look the same.
"""
import struct


def read_pbmp(d, p=0):
    assert d[p:p + 4] == b'PBMP', d[p:p + 4]
    size, = struct.unpack_from('<I', d, p + 4)
    end = p + 8 + size + 28  # DETL + PiDX trail the declared size (siege-studio does the same)
    q = p + 8
    out = {'detail_levels': 1, 'palette_id': None}
    while q + 8 <= min(end, len(d)):
        tag, n = d[q:q + 4], struct.unpack_from('<I', d, q + 4)[0]
        body = q + 8
        if tag == b'head':
            out['version'], out['w'], out['h'], out['bpp'], out['flags'] = struct.unpack_from('<IiiII', d, body)
        elif tag == b'data':
            w, h = out['w'], out['h']
            stride = (w * out['bpp'] // 8 + 3) & ~3
            px = bytearray()
            for y in range(h):
                px += d[body + y * stride: body + y * stride + w]
            out['pixels'] = bytes(px)
        elif tag == b'DETL':
            out['detail_levels'], = struct.unpack_from('<I', d, body)
        elif tag == b'PiDX':
            out['palette_id'], = struct.unpack_from('<I', d, body)
        elif tag == b'PBMP':
            break
        if n == 0 and tag not in (b'head', b'data'):
            break
        q = body + n
    return out


def read_pba(d):
    """PBMA array: 'PBMA' u32 size, 'head' chunk, then PBMP entries."""
    out, p = [], 8
    while True:
        p = d.find(b'PBMP', p)
        if p < 0:
            break
        b = read_pbmp(d, p)
        out.append(b)
        p += 8 + struct.unpack_from('<I', d, p + 4)[0]
    return out


def read_ppl(d):
    assert d[:4] == b'PL98', d[:4]
    count, shade_shift, haze_level, haze_colour = struct.unpack_from('<4I', d, 4)
    p = 4 + 16 + 32
    pals = []
    for i in range(count):
        cols = [tuple(d[p + 4 * k:p + 4 * k + 3]) for k in range(256)]
        flags = [d[p + 4 * k + 3] for k in range(256)]   # translucent palettes (type 2): per-entry alpha
        pid, ptype = struct.unpack_from('<II', d, p + 1024)
        pals.append({'id': pid, 'type': ptype, 'colors': cols, 'flags': flags})
        p += 1032
    return {'shade_shift': shade_shift, 'haze_level': haze_level, 'haze_colour': haze_colour, 'palettes': pals}


def palette_for(ppl, pid):
    for pal in ppl['palettes']:
        if pal['id'] == pid:
            return pal
    return ppl['palettes'][0]
