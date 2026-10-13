"""Earth Siege 1 palette (DPL) and bitmap (DBM / DBA / DCI) readers."""
import struct
from PIL import Image


def read_dpl(data):
    """Returns list of 256 (r, g, b, flags) tuples in 8-bit colour."""
    typ, cls, size, count = struct.unpack_from('<HHII', data, 0)
    assert (typ, cls) in ((0x0f, 0x28), (0x02, 0x28)), (typ, cls)
    out = []
    for i in range(count):
        r, g, b, f = data[12 + i * 4:16 + i * 4]
        out.append((min(255, r * 4 + r // 16), min(255, g * 4 + g // 16), min(255, b * 4 + b // 16), f))
    return out


def read_dbm(data, p=0):
    """Returns (width, height, pixels bytes, end offset)."""
    typ, cls, size, h, w, bd, u0, u1, isize, extra = struct.unpack_from('<HHIHHBBBIH', data, p)
    assert (typ, cls) == (0x0e, 0x28), (hex(p), typ, cls)
    # NB: siege-studio names the first field height; empirically the first is height, second width
    start = p + 21
    pix = data[start:start + isize]
    return {'w': w, 'h': h, 'bpp': bd, 'u0': u0, 'u1': u1, 'extra': extra, 'pixels': pix, 'end': p + 8 + size}


def read_dba(data):
    typ, cls, size, count = struct.unpack_from('<HHII', data, 0)
    assert (typ, cls) == (0x01, 0x28), (typ, cls)
    p = 12
    out = []
    for _ in range(count):
        b = read_dbm(data, p)
        out.append(b)
        p = b['end']
        p += p & 1  # word alignment
    return out


def read_any(data):
    typ, cls = struct.unpack_from('<HH', data, 0)
    if (typ, cls) == (0x01, 0x28):
        return read_dba(data)
    if (typ, cls) == (0x0e, 0x28):
        return [read_dbm(data, 0)]
    if (typ, cls) == (0x0b, 0x28):  # cursor: header + 2 u32 + dbm
        return [read_dbm(data, 16)]
    raise ValueError('not a bitmap: %x %x' % (typ, cls))


def to_image(bmp, pal, transparent0=True):
    w, h = bmp['w'], bmp['h']
    img = Image.new('P', (w, h))
    pix = bmp['pixels']
    if len(pix) < w * h:
        pix = pix + bytes(w * h - len(pix))
    img.putdata(pix[:w * h])
    flat = []
    for c in pal[:256]:
        flat += c[:3]
    flat += [0] * (768 - len(flat))
    img.putpalette(flat)
    img = img.convert('RGBA')
    if transparent0:
        px = img.load()
        raw = pix
        for y in range(h):
            for x in range(w):
                if raw[y * w + x] == 0:
                    px[x, y] = (0, 0, 0, 0)
    return img
