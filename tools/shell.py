"""Earth Siege front-end shell (GO.EXE) presentation-layer converters.

Spec: docs/formats/shell.md.  Uses tools/gfx.py for DPL/DBM/DBA.

Formats handled:
  *.DFN            Dynamix bitmap font            -> PNG atlas (palette + raw-index) + BMFont .fnt + .json
  ENG/*.BIN        string table ("Text")          -> JSON list
  STR/*.STR        grouped string lists           -> JSON
  DLG/MENU*.DLG    dialog layout                  -> JSON (controls, resolved labels, targets, region)
  *.TTM            Dynamix TTM 4.14 scene script  -> JSON (chunks, frames, decoded ops)
  *.DBM / *.DBA    backgrounds / sprite sheets    -> PNG with the palette the shell uses
  *.DCI, STYLES.DAT, *.BND, SNC/*_FILES.DAT       -> JSON

Usage:
  python tools/shell.py all <outdir>            convert everything + render menu composites
  python tools/shell.py dlg <MENUxxxx.DLG>      print decoded dialog
  python tools/shell.py ttm <file.TTM>          print decoded script
  python tools/shell.py menu <id> <out.png>     render one menu screen composite
  python tools/shell.py ttmframe <file.TTM> <frame> <out.png>   run a TTM up to <frame> and save
"""
import glob
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gfx import read_dpl, read_dbm, read_dba, to_image  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

import siege_paths as P  # noqa: E402
ROOT = P.WORK        # source tree; see tools/siege_paths.py
SHELL = os.path.join(ROOT, 'extracted', 'SHELL0')
SIM = os.path.join(ROOT, 'extracted', 'SIMVOL0')
RES32 = os.path.join(SHELL, 'RES32')


def _p(*a):
    return os.path.join(*a)


def _rd(path):
    with open(path, 'rb') as f:
        return f.read()


def _find(name, dirs):
    """Case-insensitive lookup of a resource name in a list of directories."""
    for d in dirs:
        q = _p(d, name.upper())
        if os.path.exists(q):
            return q
    return None


# ====================================================================== palettes

_PAL_CACHE = {}


def palette(name):
    """name like 'REGN1000' or a path; returns list of 256 (r,g,b,f)."""
    if name in _PAL_CACHE:
        return _PAL_CACHE[name]
    path = name if os.path.exists(name) else _find(name + '.DPL', [RES32, _p(SHELL, 'INTRO'), _p(SHELL, 'ANM'),
                                                                   _p(SIM, 'DPL')])
    pal = read_dpl(_rd(path))
    _PAL_CACHE[name] = pal
    return pal


# ====================================================================== fonts (DFN)

def read_dfn(data):
    """Dynamix font, class 0x28 type 0x05.

    0x00 u16 type(5) u16 class(0x28) u32 size
    0x08 u32 nchars (223)       0x0c u16 firstChar (0x20)
    0x0e u16 height             0x10 s16 -1 (unknown, 'proportional' marker?)
    0x12 u16 lineHeight(=height) 0x14 u16 maxWidth
    0x16 u16 8 (?)  0x18 u16 0  0x1a u16 7 (?)  0x1c u16 0
    0x1e u32 pixelBytes, pixels[pixelBytes] (8bpp palette indices, 0 = transparent)
    u32 offset[nchars] (into pixels), u8 width[nchars]
    glyph i = width[i] x height bytes, row-major, at pixels + offset[i]
    """
    typ, cls, size = struct.unpack_from('<HHI', data, 0)
    assert (typ, cls) == (5, 0x28), (typ, cls)
    n, first, h, unk10, lh, maxw, u16a, u18, u1a, u1c, psz = struct.unpack_from('<IHHhHHHHHHI', data, 8)
    pix = data[0x22:0x22 + psz]
    offs = struct.unpack_from('<%dI' % n, data, 0x22 + psz)
    widths = data[0x22 + psz + 4 * n:0x22 + psz + 5 * n]
    glyphs = []
    for i in range(n):
        w = widths[i]
        o = offs[i]
        glyphs.append({'code': first + i, 'w': w, 'h': h, 'pixels': pix[o:o + w * h]})
    return {'n': n, 'first': first, 'height': h, 'line_height': lh, 'max_width': maxw,
            'unknown': {'f10': unk10, 'f16': u16a, 'f18': u18, 'f1a': u1a, 'f1c': u1c}, 'glyphs': glyphs}


def font_atlas(font, pal=None, cols=16, pad=1):
    """Returns (rgba_image, index_image, char_rects)."""
    h = font['height']
    cw = max(font['max_width'], max(g['w'] for g in font['glyphs'])) + pad
    ch = h + pad
    rows = (len(font['glyphs']) + cols - 1) // cols
    W, H = cols * cw, rows * ch
    idx = Image.new('L', (W, H), 0)
    rects = []
    for i, g in enumerate(font['glyphs']):
        x, y = (i % cols) * cw, (i // cols) * ch
        if g['w']:
            gi = Image.frombytes('L', (g['w'], h), bytes(g['pixels']).ljust(g['w'] * h, b'\0'))
            idx.paste(gi, (x, y))
        rects.append((x, y, g['w'], h))
    rgba = None
    if pal is not None:
        p = idx.copy().convert('P')
        flat = []
        for c in pal[:256]:
            flat += c[:3]
        p.putpalette(flat + [0] * (768 - len(flat)))
        rgba = p.convert('RGBA')
        a = idx.point(lambda v: 0 if v == 0 else 255)
        rgba.putalpha(a)
    return rgba, idx, rects


def export_font(path, outdir, pal_name='REGN1000'):
    name = os.path.splitext(os.path.basename(path))[0]
    f = read_dfn(_rd(path))
    rgba, idx, rects = font_atlas(f, palette(pal_name))
    os.makedirs(outdir, exist_ok=True)
    rgba.save(_p(outdir, name + '.png'))
    idx.save(_p(outdir, name + '_idx.png'))
    W, H = idx.size
    chars = []
    lines = ['info face="%s" size=%d bold=0 italic=0 charset="" unicode=0 stretchH=100 smooth=0 aa=1 '
             'padding=0,0,0,0 spacing=0,0' % (name, f['height']),
             'common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0' % (
                 f['line_height'], f['height'], W, H),
             'page id=0 file="%s.png"' % name,
             'chars count=%d' % len(f['glyphs'])]
    for g, (x, y, w, h) in zip(f['glyphs'], rects):
        chars.append({'id': g['code'], 'x': x, 'y': y, 'width': w, 'height': h, 'xoffset': 0, 'yoffset': 0,
                      'xadvance': w})
        lines.append('char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=0 xadvance=%d page=0 chnl=15'
                     % (g['code'], x, y, w, h, w))
    with open(_p(outdir, name + '.fnt'), 'w') as fo:
        fo.write('\n'.join(lines) + '\n')
    meta = {k: f[k] for k in ('n', 'first', 'height', 'line_height', 'max_width', 'unknown')}
    meta.update({'atlas': name + '.png', 'atlas_indices': name + '_idx.png', 'palette': pal_name,
                 'colors_used': sorted(set(b for g in f['glyphs'] for b in g['pixels']) - {0}),
                 'encoding': 'char code = byte value (DOS CP437 above 0x7f)', 'chars': chars})
    with open(_p(outdir, name + '.json'), 'w') as fo:
        json.dump(meta, fo, indent=1)
    return f


class Font:
    """Tiny renderer for composites."""

    def __init__(self, name, dirs=None):
        self.f = read_dfn(_rd(_find(name + '.DFN', dirs or [_p(SHELL, 'DFN'), _p(SIM, 'DFN')])))
        self.by = {g['code']: g for g in self.f['glyphs']}

    def width(self, s):
        return sum(self.by.get(ord(c), {'w': 0})['w'] for c in s)

    def draw(self, canvas, x, y, s, pal):
        """canvas: 'P'-like index list via putpixel on an RGBA image using pal."""
        px = canvas.load()
        h = self.f['height']
        for c in s:
            g = self.by.get(ord(c))
            if not g:
                continue
            for yy in range(h):
                for xx in range(g['w']):
                    v = g['pixels'][yy * g['w'] + xx] if yy * g['w'] + xx < len(g['pixels']) else 0
                    if v and 0 <= x + xx < canvas.size[0] and 0 <= y + yy < canvas.size[1]:
                        px[x + xx, y + yy] = tuple(pal[v][:3]) + (255,)
            x += g['w']
        return x


# ====================================================================== string tables

def read_text_bin(data):
    """ENG/*.BIN ("Text" class, GO.EXE Text::getString).

    v1: u32 count, u32 dataSize, u16 offset[count], char data[dataSize] (NUL-terminated strings)
    v2: u16 2, then the same (C?_TEXT, D?_TEXT, G0_TEXT, T1_TEXT)
    """
    for pre in (0, 2):
        if len(data) < pre + 8:
            continue
        n, sz = struct.unpack_from('<II', data, pre)
        if pre + 8 + 2 * n + sz == len(data):
            offs = struct.unpack_from('<%dH' % n, data, pre + 8)
            base = pre + 8 + 2 * n
            out = []
            for o in offs:
                e = data.index(b'\0', base + o)
                out.append(data[base + o:e].decode('cp437'))
            return {'version': 1 if pre == 0 else struct.unpack_from('<H', data)[0], 'strings': out}
    raise ValueError('not a text table')


def read_str(data):
    """STR/*.STR: u32 size; repeat { u16 count; count x { u16 len; char s[len] (incl NUL); u8 0 } }."""
    size = struct.unpack_from('<I', data)[0]
    p, end = 4, min(len(data), 4 + size)
    groups = []
    while p + 2 <= end:
        n = struct.unpack_from('<H', data, p)[0]
        p += 2
        g = []
        for _ in range(n):
            ln = struct.unpack_from('<H', data, p)[0]
            p += 2
            g.append(data[p:p + ln].split(b'\0')[0].decode('cp437'))
            p += ln + 1
        groups.append(g)
    return groups


# ====================================================================== dialogs (DLG)

CTL_TYPES = {
    0: 'window',        # flag 0: MTWindow framed with res32\menu<id>.dba panel; flag 1: plain (no panel)
    1: 'text',          # static text, justify 0 (left)
    2: 'editbox',       # MTEditBox
    3: 'button',        # flag 0: MTButton (text, style-drawn); flag 1: MTBmpButton (CORNERS.DBA images)
    4: 'text_j1',       # static text, justify 1 (probably right)
    5: 'text_j2',       # static text, justify 2 (probably centred)
    14: 'gadget',       # custom-drawn info gadget (per-screen callbacks keyed by id)
    15: 'list',         # list box fed by id (MTStrListBox-like, scrolled by id 101/102 arrows)
    16: 'gfx_list',     # MTGfxListBox
    17: 'anim_list',    # MTAnimListBox
    18: 'separator',    # vertical/horizontal divider line
}
SCANCODES = {1: 'Esc', 17: 'W', 18: 'E', 23: 'I', 28: 'Enter', 57: 'Space', 71: 'Home', 72: 'Up', 73: 'PgUp',
             74: 'KP-', 75: 'Left', 77: 'Right', 78: 'KP+', 79: 'End', 80: 'Down', 81: 'PgDn'}
COMMANDS = {99: 'cancel/back', 100: 'accept/ok/proceed', 101: 'scroll up', 102: 'scroll down',
            103: 'edit field', 106: 'prev', 107: 'next', 108: 'zoom in', 109: 'zoom out',
            1003: 'exit to DOS (MENU999 confirm)', 1499: 'briefing transmission -> launch sim', 1501: 'briefing (MENU1501)'}

# GO.EXE 0x40afa: menu id -> shell region (background REGN<r>.DBM / .DPL); other menus keep current region.
MENU_REGION = {1000: 1000, 1200: 1000, 1100: 1000, 1310: 1000, 1320: 1000, 9999: 1000, 1490: 7000,
               1499: 3000, 1500: 6000, 1501: 6000, 1510: 5000, 1520: 5000, 1700: 4000, 1710: 4000,
               1900: 4000, 1800: 4000, 1820: 4000, 2000: 4000, 1610: 4000, 5555: 4000}
# region -> music track number (GO.EXE table @0x817d0 indexed by region/1000-1)
REGION_MUSIC = {1000: 1, 2000: 1, 3000: 3, 4000: 4, 5000: 3, 6000: 3, 7000: 1}
# popups: parent region used for preview rendering (they inherit whatever region is current)
POPUP_PARENT = {1110: 1000, 1210: 1000, 1220: 1000, 1230: 1000, 1240: 1000, 1250: 1000, 1260: 1000,
                1270: 1000, 1300: 1000, 1330: 1000, 999: 1000, 888: 1000, 3000: 4000, 3333: 4000, 4444: 4000,
                6666: 1000, 7770: 4000, 7771: 4000, 7772: 4000, 1910: 4000, 1920: 4000, 2010: 4000}

# MTBmpButton image indices into RES32\CORNERS.DBA (normal, pressed, disabled), GO.EXE 0x1d47d
def bmp_button_images(hotkey, cid):
    t = {
        0x48: {1503: (36, 37)}, 0x49: {}, 0x50: {1504: (38, 39)}, 0x51: {},
        0x4d: {1506: (42, 43), 2004: (45, 47)}, 0x4b: {1505: (40, 41), 2003: (44, 46)},
        0x4e: {108: (32, 33)}, 0x4a: {109: (34, 35)},
    }
    dflt = {0x48: (20, 22), 0x49: (20, 22), 0x50: (21, 23), 0x51: (21, 23), 0x4d: (24, 26), 0x4b: (25, 27),
            0x4e: (28, 30), 0x4a: (29, 31)}
    if hotkey in t:
        n, pr = t[hotkey].get(cid, dflt[hotkey])
        return {'normal': n, 'pressed': pr, 'disabled': n}
    if cid in (1806, 2003):
        return {'normal': 48, 'pressed': 50, 'disabled': 51}
    if cid in (1807, 2004):
        return {'normal': 48, 'pressed': 49, 'disabled': 51}
    return None


def menu_strings(mid):
    p = _p(SHELL, 'ENG', 'MENU%d.BIN' % mid)
    return read_text_bin(_rd(p))['strings'] if os.path.exists(p) else []


def read_dlg(path):
    """DLG: u16 count, count x { s16 x1,y1,x2,y2; u8 type; u8 flags; u8 hotkeyScancode; u16 id }.

    Record 0 is the window (screen coords); others are relative to the window origin.
    Label of record i = ENG\\MENU<n>.BIN string i (missing -> none).
    """
    data = _rd(path)
    mid = int(os.path.splitext(os.path.basename(path))[0][4:])
    n = struct.unpack_from('<H', data)[0]
    strs = menu_strings(mid)
    recs = []
    for i in range(n):
        x1, y1, x2, y2, t, fl, hk, cid = struct.unpack_from('<4hBBBH', data, 2 + 13 * i)
        r = {'index': i, 'type': t, 'type_name': CTL_TYPES.get(t, 'unknown%d' % t), 'flags': fl,
             'hotkey': hk, 'hotkey_name': SCANCODES.get(hk) if hk else None, 'id': cid,
             'rect': [x1, y1, x2, y2], 'label': strs[i] if i < len(strs) else None}
        if t == 3 and fl == 1:
            r['type_name'] = 'bmp_button'
            r['images'] = bmp_button_images(hk, cid)
            if hk:                      # GO.EXE 0x3a7ce: bitmap buttons with a hotkey get no text
                r['label'] = None
        if os.path.exists(_p(SHELL, 'DLG', 'MENU%d.DLG' % cid)) and i > 0 and t == 3:
            r['target_menu'] = cid
        if cid in COMMANDS and t == 3:
            r['command'] = COMMANDS[cid]
        recs.append(r)
    win = recs[0]
    ox, oy = win['rect'][0], win['rect'][1]
    for r in recs[1:]:
        x1, y1, x2, y2 = r['rect']
        r['screen_rect'] = [x1 + ox, y1 + oy, x2 + ox, y2 + oy]
    panel = 'MENU%d.DBA' % win['id'] if win['flags'] == 0 and os.path.exists(_p(RES32, 'MENU%d.DBA' % win['id'])) else None
    region = MENU_REGION.get(mid) or POPUP_PARENT.get(mid)
    return {'menu': mid, 'window': win, 'controls': recs[1:], 'panel': panel,
            'region': MENU_REGION.get(mid), 'preview_region': region or 1000,
            'extra_strings': strs[n:], 'title': win['label']}


# ====================================================================== TTM scripts

TTM_OPS = {
    0x0010: 'DISSOLVE', 0x0020: 'FIXBACK', 0x0030: 'RESTORE', 0x0050: 'PRESERVE', 0x0060: 'FREERESTORE',
    0x0070: 'FREEPAL', 0x0080: 'FREESHAPE', 0x0090: 'FREEFONT', 0x00c0: 'FREEPUT', 0x00e0: 'FREESCG',
    0x0110: 'ENDLABEL', 0x0400: 'STOP_CYCLE', 0x0500: 'FLIP_MODE', 0x0510: 'SMART_MODE', 0x0ff0: 'ENDFRAME',
    0x1011: 'BORDER', 0x1021: 'WAIT', 0x1031: 'BRUSHSELECT', 0x1041: 'SETDISSOLVE', 0x1051: 'SHAPESELECT',
    0x1061: 'PALSELECT', 0x1071: 'FONTSELECT', 0x1101: 'LLABEL', 0x1111: 'GLABEL', 0x1121: 'PUTSELECT',
    0x1201: 'JUMP_LABEL', 0x1301: 'START_SX(alias c051)', 0x1311: 'STOP_SX(alias c061)',
    0x2002: 'PALETTE', 0x2012: 'USERFUNC', 0x2022: 'RANDOM_WAIT', 0x2032: 'SCG_SCROLL',
    0x2302: 'SET_RANGE0', 0x2312: 'SET_RANGE1', 0x2322: 'SET_RANGE2', 0x2402: 'CYCLE',
    0x3003: 'CALL_LABEL', 0x3103: 'QUICKSCROLL', 0x3201: 'CALL_START', 0x3303: 'CALL_OFFSET',
    0x4004: 'SETCLIP', 0x4114: 'FADE_OUT', 0x4124: 'FADE_IN', 0x4136: 'FADE_PCT', 0x4204: 'FIX_RECT',
    0x4214: 'GET', 0x5005: 'HOTSPOT',
    0xa000: 'START/END GRAPHICS', 0xa002: 'SET_PIXEL', 0xa014: 'DISSOLVERECT', 0xa024: 'SHOW',
    0xa034: 'EDGE_TO_CENTER', 0xa044: 'BLINDS_HORIZONTAL', 0xa054: 'LEFT_TO_RIGHT', 0xa064: 'RIGHT_TO_LEFT',
    0xa074: 'TOP_TO_BOTTOM', 0xa084: 'BOTTOM_TO_TOP', 0xa094: 'CENTER_TO_EDGE', 0xa0a4: 'LINE',
    0xa0b5: 'FIZZLERECT', 0xa104: 'RECTFILL', 0xa114: 'RECT', 0xa204: 'PUTTEXTSTART', 0xa294: 'PUTTEXTEND',
    0xa304: 'AGENTBOX', 0xa404: 'CIRCFILL', 0xa424: 'CIRCLE',
    0xa504: 'DRAWBRUSH0', 0xa514: 'DRAWBRUSH1', 0xa524: 'DRAWBRUSH2', 0xa534: 'DRAWBRUSH3',
    0xa505: 'RLEDRAWBRUSH0', 0xa515: 'RLEDRAWBRUSH1', 0xa525: 'RLEDRAWBRUSH2', 0xa535: 'RLEDRAWBRUSH3',
    0xa506: 'SIZEDRAWBRUSH0', 0xa516: 'SIZEDRAWBRUSH1', 0xa526: 'SIZEDRAWBRUSH2', 0xa536: 'SIZEDRAWBRUSH3',
    0xa5a7: 'DRAW_ROT_BRUSH', 0xa601: 'NEW_PUT', 0xa704: 'SCGDRAW', 0xaf02: 'FLOOD_FILL', 0xaf1f: 'POLY',
    0xaf2f: 'POLYFILL', 0xb000: 'MACRO_CR_RESET', 0xb013: 'MACRO_CREDITS', 0xb606: 'COPYRECT',
    0xc01f: 'OPEN_PATCH', 0xc02f: 'OPEN_SXFILE', 0xc021: 'LOAD_PATCH', 0xc031: 'LOAD_SX', 0xc041: 'FREE_SX',
    0xc051: 'START_SX', 0xc061: 'STOP_SX', 0xc071: 'PAUSE_SX', 0xc081: 'UNPAUSE_SX', 0xc091: 'MUTE_SX',
    0xc0a1: 'UNMUTE_SX', 0xc0b2: 'PRIORITY_SX', 0xc0c2: 'HOLD_SX', 0xc0d3: 'BEND_SX', 0xc0e3: 'FADE_SX',
    0xc0f4: 'CONTROLLER_SX', 0xc102: 'VOLUME_SX', 0xc202: 'HDS_INIT', 0xc21f: 'HDS_LOAD', 0xc220: 'HDS_PLAY',
    0xc230: 'HDS_STOP', 0xc240: 'HDS_DEINIT', 0xc252: 'HDS_MARKER', 0xcf01: 'REVERB_SX',
    0xcf11: 'MASTER_VOL_SX', 0xf01f: 'SCRNLOAD', 0xf02f: 'SHAPELOAD', 0xf04f: 'FONTLOAD', 0xf05f: 'PALLOAD',
    0xf08f: 'SCGLOAD', 0xf10f: 'GETTEXTSTART', 0xf19f: 'GETTEXTEND',
}
# argument names for the ops actually used by Earth Siege scripts
TTM_ARGS = {
    'WAIT': ['ticks30'], 'RANDOM_WAIT': ['min', 'max'], 'PALETTE': ['fg', 'bg'],
    'SHAPESELECT': ['slot'], 'PALSELECT': ['slot'], 'FONTSELECT': ['slot'], 'PUTSELECT': ['slot'],
    'LLABEL': ['label'], 'GLABEL': ['label'], 'JUMP_LABEL': ['label'], 'CALL_LABEL': ['dx', 'dy', 'label'],
    'CALL_START': ['label'], 'CALL_OFFSET': ['dx', 'dy', 'n'],
    'DRAWBRUSH0': ['x', 'y', 'frame', 'slot'], 'DRAWBRUSH1': ['x', 'y', 'frame', 'slot'],
    'DRAWBRUSH2': ['x', 'y', 'frame', 'slot'], 'DRAWBRUSH3': ['x', 'y', 'frame', 'slot'],
    'LINE': ['x1', 'y1', 'x2', 'y2'], 'RECTFILL': ['x', 'y', 'w', 'h'], 'RECT': ['x', 'y', 'w', 'h'],
    'FIX_RECT': ['x', 'y', 'w', 'h'], 'GET': ['x', 'y', 'w', 'h'], 'NEW_PUT': ['?'],
    'FADE_OUT': ['first', 'count', 'colour', 'speed'], 'FADE_IN': ['first', 'count', 'colour', 'speed'],
    'HOTSPOT': ['w0|l0', 'w1|l1', 'w2|l2', 'w3|l3', 'w4|l4'], 'VOLUME_SX': ['?', '?'],
}
RES_EXT = {'SCR': 'DBM', 'BMP': 'DBA', 'PAL': 'DPL', 'FNT': 'DFN'}


def _ttm_chunks(d):
    p, out = 0, []
    while p + 8 <= len(d):
        tag = d[p:p + 4].decode('latin1')
        sz = struct.unpack_from('<I', d, p + 4)[0]
        if sz & 0x80000000:          # container chunk (TTI:), children follow
            out.append((tag, None))
            p += 8
            continue
        out.append((tag, d[p + 8:p + 8 + sz]))
        p += 8 + sz
    return out


def dgds_rle(src, n):
    """Compression type 1 (as ScummVM dgds RleDecompressor): b&0x80 -> run of (b&0x7f) x next byte."""
    out, p = bytearray(), 0
    while len(out) < n and p < len(src):
        c = src[p]
        p += 1
        if c & 0x80:
            out += bytes([src[p]]) * (c & 0x7f)
            p += 1
        else:
            out += src[p:p + c]
            p += c
    return bytes(out[:n])


def decode_ttm_code(code):
    ops, p = [], 0
    while p + 2 <= len(code):
        op = struct.unpack_from('<H', code, p)[0]
        p += 2
        n = op & 0xf
        if n == 0xf:
            e = code.index(b'\0', p)
            args = [code[p:e].decode('latin1')]
            p = e + 1
            p += p & 1
        else:
            args = list(struct.unpack_from('<%dh' % n, code, p))
            p += 2 * n
        ops.append((op, args))
    return ops


def read_ttm(data):
    ch = _ttm_chunks(data)
    res = {'version': None, 'pages': None, 'tags': {}, 'compression': None}
    code = b''
    for tag, d in ch:
        if tag == 'VER:':
            res['version'] = d.split(b'\0')[0].decode()
        elif tag == 'PAG:':
            res['pages'] = struct.unpack_from('<H', d)[0]
        elif tag == 'TT3:':
            comp, usz = d[0], struct.unpack_from('<I', d, 1)[0]
            res['compression'] = comp
            if comp == 0:
                code = d[5:5 + usz]
            elif comp == 1:
                code = dgds_rle(d[5:], usz)
            else:
                raise ValueError('TT3 compression %d not supported' % comp)
        elif tag == 'TAG:':
            n = struct.unpack_from('<H', d)[0]
            q = 2
            for _ in range(n):
                tid = struct.unpack_from('<H', d, q)[0]
                e = d.index(b'\0', q + 2)
                res['tags'][tid] = d[q + 2:e].decode('latin1')
                q = e + 1
    ops = decode_ttm_code(code)
    frames, cur = [], []
    for op, a in ops:
        cur.append((op, a))
        if op == 0x0ff0:
            frames.append(cur)
            cur = []
    if cur:
        frames.append(cur)
    res['frames'] = frames
    return res


def ttm_to_json(t):
    out = {k: t[k] for k in ('version', 'pages', 'compression')}
    out['tags'] = {str(k): v for k, v in t['tags'].items()}
    out['frames'] = []
    labels = {}
    for i, fr in enumerate(t['frames']):
        ops = []
        for op, a in fr:
            name = TTM_OPS.get(op, 'OP_%04X' % op)
            o = {'op': '0x%04x' % op, 'name': name, 'args': a}
            an = TTM_ARGS.get(name)
            if an and len(an) == len(a):
                o['named'] = dict(zip(an, a))
            if isinstance(a[0] if a else None, str):
                base, _, ext = a[0].rpartition('.')
                o['resource'] = (base + '.' + RES_EXT.get(ext.upper(), ext)).upper()
            if name in ('LLABEL', 'GLABEL'):
                labels[a[0]] = i
                o['tag'] = t['tags'].get(a[0])
            ops.append(o)
        out['frames'].append({'index': i, 'ops': ops})
    out['labels'] = {str(k): v for k, v in labels.items()}
    return out


# ---------------------------------------------------------------- minimal TTM player (for previews)

class TTMPlayer:
    """Best-effort interpreter of the subset used by Earth Siege (see shell.md section TTM)."""

    def __init__(self, path, base_pal=None):
        self.dir = os.path.dirname(path)
        self.t = read_ttm(_rd(path))
        self.pal = base_pal
        self.shapes = {}
        self.slot = 0
        self.bg = Image.new('RGBA', (320, 200), (0, 0, 0, 255))
        self.scr = self.bg.copy()
        self.fg = 0

    def _load(self, name):
        base, _, ext = name.rpartition('.')
        fn = base + '.' + RES_EXT.get(ext.upper(), ext)
        return _find(fn, [self.dir, RES32, _p(SHELL, 'INTRO'), _p(SHELL, 'DBA')])

    def run_frame(self, i, dx=0, dy=0, clear=True):
        """Each frame the screen is rebuilt from the background layer, then the frame's ops draw on it."""
        if clear:
            self.scr = self.bg.copy()
        for op, a in self.t['frames'][i]:
            name = TTM_OPS.get(op)
            if name == 'PALLOAD':
                p = self._load(a[0])
                if p:
                    self.pal = read_dpl(_rd(p))
            elif name == 'SHAPESELECT':
                self.slot = a[0]
            elif name == 'SHAPELOAD':
                p = self._load(a[0])
                if p:
                    self.shapes[self.slot] = read_dba(_rd(p))
            elif name == 'SCRNLOAD':
                p = self._load(a[0])
                if p and self.pal:
                    self.bg = to_image(read_dbm(_rd(p)), self.pal, False)
                    self.scr = self.bg.copy()
            elif name == 'PALETTE':
                self.fg = a[0]
            elif name == 'RECTFILL' and self.pal:
                x, y, w, h = a
                ImageDraw.Draw(self.scr).rectangle([x + dx, y + dy, x + dx + w - 1, y + dy + h - 1],
                                                   fill=tuple(self.pal[self.fg][:3]) + (255,))
            elif name == 'FIX_RECT':       # (x, y, w, h): commit screen rect into the background layer
                x, y, w, h = a
                x1, y1, x2, y2 = max(0, min(x, x + w)), max(0, min(y, y + h)), min(320, max(x, x + w)), \
                    min(200, max(y, y + h))
                if x2 > x1 and y2 > y1:
                    self.bg.paste(self.scr.crop((x1, y1, x2, y2)), (x1, y1))
            elif name == 'FIXBACK':        # commit whole screen into the background layer
                self.bg = self.scr.copy()
            elif name and name.startswith('DRAWBRUSH') and self.pal:
                x, y, fr, sl = a
                sh = self.shapes.get(sl)
                if sh and 0 <= fr < len(sh):
                    im = to_image(sh[fr], self.pal, True)
                    mode = int(name[-1])
                    if mode & 1:
                        im = im.transpose(Image.FLIP_LEFT_RIGHT)
                    if mode & 2:
                        im = im.transpose(Image.FLIP_TOP_BOTTOM)
                    self.scr.alpha_composite(im, (x + dx, y + dy)) if x + dx >= 0 and y + dy >= 0 else \
                        self.scr.paste(im, (x + dx, y + dy), im)

    def run_until(self, n):
        for i in range(min(n + 1, len(self.t['frames']))):
            self.run_frame(i)
        return self.scr


# ====================================================================== misc small formats

def read_dci(data):
    """Cursor: header(type 0x0b, class 0x28, size), s32 hotX, s32 hotY, then a DBM."""
    hx, hy = struct.unpack_from('<ii', data, 8)
    return {'hotspot': [hx, hy], 'bitmap': read_dbm(data, 16)}


def read_styles(data):
    """CFG\\STYLES.DAT: u16 count; count x { u32 colour[13]; u16 corner[4]; u16 bw, bh }  (64 bytes).

    colour[0] = face (filled inset 3), colour[1..4] / [5..8] / [9..12] = rings at inset 0 / 1 / 2, each
    left, top, right, bottom (GO.EXE 0x44b86 -> 0x44dc8); corner = CORNERS.DBA frames TL, TR, BL, BR at
    (x1 | x2-bw, y1 | y2-bh) (0x451c1). MTButton: style 0 normal, 1 pushed, 2 inactive (0x1cde8).
    """
    n = struct.unpack_from('<H', data)[0]
    out = []
    for i in range(n):
        p = 2 + 64 * i
        cols = list(struct.unpack_from('<13I', data, p))
        corners = list(struct.unpack_from('<4H', data, p + 52))
        bw, bh = struct.unpack_from('<2H', data, p + 60)
        out.append({'colors': cols, 'corners_dba_index': corners, 'border': [bw, bh]})
    return out


def read_bnd(data):
    """BND: u32 stamp (class version), then class-specific packed parameters (shown as s16 words)."""
    stamp = struct.unpack_from('<I', data)[0]
    body = data[4:]
    words = list(struct.unpack_from('<%dh' % (len(body) // 2), body))
    return {'stamp': '0x%08x' % stamp, 'words': words, 'bytes': body.hex()}


def read_files_dat(data):
    """SNC\\??_FILES.DAT (256-byte buffer): u8 n; char ttm[]; n x { u8 k; k x char name[] } (NUL-terminated)."""
    n = data[0]
    p = 1
    e = data.index(b'\0', p)
    ttm = data[p:e].decode('latin1')
    p = e + 1
    entries = []
    for _ in range(n):
        if p >= len(data):
            break
        k = data[p]
        p += 1
        names = []
        for _ in range(k):
            e = data.find(b'\0', p)
            if e < 0:
                names.append(data[p:].decode('latin1'))
                p = len(data)
                break
            names.append(data[p:e].decode('latin1'))
            p = e + 1
        entries.append(names)
    return {'ttm': ttm, 'entries': entries}


# ====================================================================== palette assignment for art

def ttm_resource_palettes():
    """Scan every TTM: resource (DBM/DBA) -> palette (DPL) active when it is loaded."""
    m = {}
    for path in glob.glob(_p(SHELL, '*', '*.TTM')):
        try:
            t = read_ttm(_rd(path))
        except Exception:
            continue
        cur = None
        for fr in t['frames']:
            for op, a in fr:
                n = TTM_OPS.get(op)
                if n == 'PALLOAD':
                    cur = a[0].rpartition('.')[0].upper()
                elif n in ('SCRNLOAD', 'SHAPELOAD') and cur:
                    m.setdefault(a[0].rpartition('.')[0].upper(), cur)
    return m


def palette_for(name, ttm_map):
    """Best guess of the palette a DBM/DBA is displayed with (shell)."""
    n = name.upper()
    if os.path.exists(_p(RES32, n + '.DPL')) or os.path.exists(_p(SHELL, 'INTRO', n + '.DPL')):
        return n
    if n.startswith('REGN') and n[4:].isdigit():
        r = int(n[4:]) // 1000 * 1000
        return 'REGN%d' % r
    if len(n) > 2 and n[1] == '_' and n[0] in 'ABDG':
        return n[0] + '_PAL'
    if n.startswith('ENDF'):
        return 'ENDF'
    if n.startswith('MENU') and n[4:].isdigit():
        mid = int(n[4:])
        r = MENU_REGION.get(mid) or POPUP_PARENT.get(mid) or (4000 if mid in (1810, 1820) else 1000)
        if mid == 1610:
            return 'REGN1610'
        if mid >= 9995:
            return 'REGN9999'
        return 'REGN%d' % r
    if n in ttm_map:
        return ttm_map[n]
    if len(n) > 2 and n[0] == 'C' and n[1] in '0123' and n[2] == '_':
        return 'REGN300' + n[1]    # campaign commander briefing: REGN3000.DBM + REGN300<c>.DPL (verified)
    if len(n) > 2 and n[0] == 'D' and n[1] in '0123' and n[2] == '_':
        return 'REGN500' + n[1]    # debriefing officer over REGN500<c> (verified)
    if n.startswith('G0_'):
        return 'REGN7000'          # general/single-mission briefing on the video monitor (verified)
    if n.startswith('T1_'):
        return 'REGN4000'          # hangar chief (verified)
    if n.startswith(('PILOT', 'INSIGNIA', 'JEFTALK', 'MESH')):
        return 'REGN1610'          # crew assignment screen (verified for PILOTS/PILOT_n/INSIGNIA)
    if n.startswith(('W1800', 'HEADS', 'HEDS', 'MECHS', 'BLUEHERX', 'ALLWEAP')):
        return 'REGN4000'
    if n.endswith(('BILD', 'OUTL', 'DMG1', 'WEP1', 'WEPD', 'WELD1', 'WELD2')):
        return 'REGN4000'
    return 'REGN1000'


# ====================================================================== menu composite

def draw_style_box(img, style, rect, pal, corners):
    """Draws a STYLES.DAT box over the inclusive rect (x1, y1, x2, y2) like GO.EXE 0x44b86."""
    x1, y1, x2, y2 = rect
    dr = ImageDraw.Draw(img)
    cols = style['colors']

    def col(i):
        return tuple(pal[i][:3]) + (255,)

    dr.rectangle([x1 + 3, y1 + 3, x2 - 3, y2 - 3], fill=col(cols[0]))
    for ring, first in enumerate((1, 5, 9)):
        a, b, c, d = x1 + ring, y1 + ring, x2 - ring, y2 - ring
        edges = ([a, b + 1, a, d - 1], [a + 1, b, c - 1, b], [c, b + 1, c, d - 1], [a + 1, d, c - 1, d])
        for k, e in enumerate(edges):
            if cols[first + k]:
                dr.line(e, fill=col(cols[first + k]))
    bw, bh = style['border']
    for frame, (px, py) in zip(style['corners_dba_index'], ((x1, y1), (x2 - bw, y1), (x1, y2 - bh), (x2 - bw, y2 - bh))):
        img.alpha_composite(to_image(corners[frame], pal, True), (px, py))


def render_menu(mid, out=None, region=None, debug=True):
    d = read_dlg(_p(SHELL, 'DLG', 'MENU%d.DLG' % mid))
    reg = region or d['preview_region']
    pal = palette('REGN1610' if mid == 1610 else 'REGN%d' % reg)
    img = to_image(read_dbm(_rd(_p(RES32, 'REGN%d.DBM' % reg)))
                   if os.path.exists(_p(RES32, 'REGN%d.DBM' % reg)) else
                   read_dbm(_rd(_p(RES32, 'REGN1000.DBM'))), pal, False)
    win = d['window']
    ox, oy = win['rect'][:2]
    if d['panel']:
        panel = read_dba(_rd(_p(RES32, d['panel'])))[0]
        img.alpha_composite(to_image(panel, pal, True), (ox, oy))
    fonts = {k: Font(k) for k in ('TITLE', 'GRAY', 'ACTIVE', 'INACTIVE', 'PUSHED')}
    corners = read_dba(_rd(_p(RES32, 'CORNERS.DBA')))
    styles = read_styles(_rd(_p(SHELL, 'CFG', 'STYLES.DAT')))
    dr = ImageDraw.Draw(img)
    if win['label'] and win['flags'] == 0:
        f = fonts['TITLE']
        w = f.width(win['label'])
        f.draw(img, ox + (win['rect'][2] - ox - w) // 2, oy + 4, win['label'], pal)
    for c in d['controls']:
        x1, y1, x2, y2 = c['screen_rect']
        t = c['type_name']
        if t == 'button':
            draw_style_box(img, styles[0], (x1, y1, x2, y2), pal, corners)
        if t == 'bmp_button' and c.get('images'):
            im = to_image(corners[c['images']['normal']], pal, True)
            img.alpha_composite(im, (x1, y1))
        if c['label'] and t in ('button', 'bmp_button', 'text', 'text_j1', 'text_j2'):
            f = fonts['ACTIVE'] if 'button' in t else fonts['GRAY']
            w = f.width(c['label'])
            if t == 'button':
                tx = x1 + int((x2 - x1 - w) / 2)    # MTButton: centred over x2 - x1 (0x520d8)
            elif t in ('bmp_button', 'text_j2'):
                tx = x1 + (x2 - x1 + 1 - w) // 2
            elif t == 'text_j1':
                tx = x2 - w
            else:
                tx = x1
            ty = y1 + (y2 - y1 + 1 - f.f['height']) // 2 + 1
            f.draw(img, tx, ty, c['label'], pal)
        if debug and t not in ('button',):
            dr.rectangle([x1, y1, x2, y2], outline=(255, 0, 255, 255))
    if out:
        img.save(out)
    return img


# ====================================================================== bulk export

def export_all(out):
    os.makedirs(out, exist_ok=True)
    summary = {}
    # fonts
    for path in sorted(glob.glob(_p(SHELL, 'DFN', '*.DFN'))):
        export_font(path, _p(out, 'fonts', 'shell'), 'REGN1000')
    for path in sorted(glob.glob(_p(SIM, 'DFN', '*.DFN'))):
        export_font(path, _p(out, 'fonts', 'sim'), 'COCKPIT')
    # strings
    os.makedirs(_p(out, 'strings'), exist_ok=True)
    for path in sorted(glob.glob(_p(SHELL, 'ENG', '*.BIN')) + [_p(SHELL, 'CFG', 'FILENAME.BIN')]):
        with open(_p(out, 'strings', os.path.basename(path)[:-4] + '.json'), 'w') as fo:
            json.dump(read_text_bin(_rd(path)), fo, indent=1)
    for path in sorted(glob.glob(_p(SHELL, 'STR', '*.STR'))):
        with open(_p(out, 'strings', os.path.basename(path)[:-4] + '_str.json'), 'w') as fo:
            json.dump(read_str(_rd(path)), fo, indent=1)
    # dialogs
    os.makedirs(_p(out, 'dlg'), exist_ok=True)
    graph = {}
    for path in sorted(glob.glob(_p(SHELL, 'DLG', '*.DLG'))):
        d = read_dlg(path)
        with open(_p(out, 'dlg', os.path.basename(path)[:-4] + '.json'), 'w') as fo:
            json.dump(d, fo, indent=1)
        graph[d['menu']] = {'title': d['title'], 'region': d['region'],
                            'buttons': [{'label': c['label'], 'id': c['id'], 'hotkey': c['hotkey_name'],
                                         'target_menu': c.get('target_menu'), 'command': c.get('command')}
                                        for c in d['controls'] if c['type'] == 3]}
    with open(_p(out, 'dlg', 'menu_graph.json'), 'w') as fo:
        json.dump(graph, fo, indent=1)
    # TTM
    os.makedirs(_p(out, 'ttm'), exist_ok=True)
    tmap = ttm_resource_palettes()
    for path in sorted(glob.glob(_p(SHELL, '*', '*.TTM'))):
        sub = os.path.basename(os.path.dirname(path))
        j = ttm_to_json(read_ttm(_rd(path)))
        j['palette_hint'] = palette_for(os.path.basename(path)[:-4], tmap)
        with open(_p(out, 'ttm', sub + '_' + os.path.basename(path)[:-4] + '.json'), 'w') as fo:
            json.dump(j, fo, indent=1)
    # backgrounds + sprite sheets
    os.makedirs(_p(out, 'bg'), exist_ok=True)
    os.makedirs(_p(out, 'dba'), exist_ok=True)
    pal_used = {}
    for path in sorted(glob.glob(_p(SHELL, '*', '*.DBM'))):
        n = os.path.splitext(os.path.basename(path))[0]
        b = read_dbm(_rd(path))
        variants = [palette_for(n, tmap)]
        if n == 'REGN3000':
            variants = ['REGN3000', 'REGN3001', 'REGN3002', 'REGN3003']
        if n == 'REGN1000':
            variants = ['REGN1000', 'REGN1610']
        for v in variants:
            on = n if v == variants[0] else n + '_' + v
            to_image(b, palette(v), False).save(_p(out, 'bg', on + '.png'))
            pal_used[on] = v
    for path in sorted(glob.glob(_p(RES32, '*.DBA')) + glob.glob(_p(SHELL, 'INTRO', '*.DBA'))
                       + glob.glob(_p(SHELL, 'DBA', '*.DBA'))):
        n = os.path.splitext(os.path.basename(path))[0]
        sub = os.path.basename(os.path.dirname(path))
        try:
            frames = read_dba(_rd(path))
        except AssertionError:
            continue
        pn = palette_for(n, tmap)
        pal = palette(pn)
        W = sum(f['w'] for f in frames) + len(frames)
        H = max(f['h'] for f in frames)
        sheet = Image.new('RGBA', (max(1, W), max(1, H)), (0, 0, 0, 0))
        x, rects = 0, []
        for f in frames:
            if f['w'] and f['h']:
                sheet.alpha_composite(to_image(f, pal, True), (x, 0))
            rects.append([x, 0, f['w'], f['h']])
            x += f['w'] + 1
        on = sub + '_' + n
        sheet.save(_p(out, 'dba', on + '.png'))
        with open(_p(out, 'dba', on + '.json'), 'w') as fo:
            json.dump({'palette': pn, 'frames': rects}, fo)
        pal_used[on] = pn
    with open(_p(out, 'palette_assignment.json'), 'w') as fo:
        json.dump(pal_used, fo, indent=1)
    # palettes as JSON (8-bit rgb)
    os.makedirs(_p(out, 'palettes'), exist_ok=True)
    for path in sorted(glob.glob(_p(SHELL, '*', '*.DPL'))):
        n = os.path.splitext(os.path.basename(path))[0]
        with open(_p(out, 'palettes', n + '.json'), 'w') as fo:
            json.dump([list(c[:3]) for c in read_dpl(_rd(path))], fo)
    # misc
    misc = {'styles': read_styles(_rd(_p(SHELL, 'CFG', 'STYLES.DAT'))),
            'bnd': {os.path.basename(p): read_bnd(_rd(p)) for p in sorted(glob.glob(_p(SHELL, 'BND', '*.BND')))},
            'snc_files': {os.path.basename(p): read_files_dat(_rd(p))
                          for p in sorted(glob.glob(_p(SHELL, 'SNC', '*_FILES.DAT')))},
            'tm_files': open(_p(SHELL, 'CFG', 'TM_FILES.DAT'), 'rb').read().decode('latin1').split(),
            'menu_region': MENU_REGION, 'region_music': REGION_MUSIC}
    for p in glob.glob(_p(SHELL, 'DCI', '*.DCI')) + glob.glob(_p(RES32, '*.DCI')) + glob.glob(_p(SIM, 'DCI', '*.DCI')):
        n = os.path.splitext(os.path.basename(p))[0]
        try:
            c = read_dci(_rd(p))
        except AssertionError:
            continue
        os.makedirs(_p(out, 'cursors'), exist_ok=True)
        to_image(c['bitmap'], palette('REGN1000'), True).save(_p(out, 'cursors', n + '.png'))
        misc.setdefault('cursors', {})[n] = {'hotspot': c['hotspot'], 'w': c['bitmap']['w'], 'h': c['bitmap']['h']}
    with open(_p(out, 'shell_misc.json'), 'w') as fo:
        json.dump(misc, fo, indent=1)
    # composites
    os.makedirs(_p(out, 'menus'), exist_ok=True)
    for path in sorted(glob.glob(_p(SHELL, 'DLG', '*.DLG'))):
        mid = int(os.path.basename(path)[4:-4])
        render_menu(mid, _p(out, 'menus', 'MENU%d.png' % mid))
    summary['ok'] = True
    return summary


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return
    cmd = argv[1]
    if cmd == 'all':
        export_all(argv[2])
    elif cmd == 'dlg':
        print(json.dumps(read_dlg(argv[2]), indent=1))
    elif cmd == 'ttm':
        t = read_ttm(_rd(argv[2]))
        print('version', t['version'], 'pages', t['pages'], 'tags', t['tags'])
        for i, fr in enumerate(t['frames']):
            print('-- frame', i)
            for op, a in fr:
                print('   %04x %-18s %s' % (op, TTM_OPS.get(op, '?'), a))
    elif cmd == 'menu':
        render_menu(int(argv[2]), argv[3])
    elif cmd == 'ttmframe':
        TTMPlayer(argv[2]).run_until(int(argv[3])).save(argv[4])
    else:
        print(__doc__)


if __name__ == '__main__':
    main(sys.argv)
