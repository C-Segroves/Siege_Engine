"""Earth Siege 1 cockpit instruments: GAU / VUE / ED? / EDG / PDG / OFS decoders, exports and mock-ups.

Spec: docs/formats/cockpit.md.  Uses tools/gfx.py (DPL/DBM/DBA) and tools/shell.py (DFN fonts).

Usage:
  python tools/cockpit.py all [outdir]        (default outdir: extracted/cockpit)
      <out>/layout/<HERC>.json     decoded instrument layout (absolute 320x400 panel coords)
      <out>/mockup/<HERC>.png      DB0 (y 0..199) + DB1 (y 200..399) with every instrument drawn/labelled
      <out>/mockup/<HERC>_views.png  the 4 views (DB0/DB1/DB2/DB2 mirrored) with ED0..ED3 3D-window regions
      <out>/bitmaps/*.png          every instrument bitmap (COCKPIT palette), contact sheets + single frames
      <out>/pilots/PILOTn*.png     composed pilot comm-video frames (PILOTn.DBA + OFS)
      <out>/pdg/<UNIT>.json/.png   damage diagrams (PDG regions over the unit DBA)
      <out>/fonts/*                cockpit fonts (atlas + .fnt + .json)
      <out>/strings0.json          SIMVOL0/STR/STRINGS0.STR groups (cockpit labels)
  python tools/cockpit.py gau <HERC>          print the decoded layout JSON
"""
import glob
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gfx  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

import siege_paths as P  # noqa: E402
ROOT = P.WORK        # source tree; see tools/siege_paths.py
SIM = os.path.join(ROOT, 'extracted', 'SIMVOL0')
HERCS = ['COLOSSUS', 'GUNSLING', 'HERCULES', 'PANTHER', 'PATRIOT', 'RAPTOR', 'ROADRUNN', 'TOMAHAWK']


def _rd(*p):
    with open(os.path.join(SIM, *p), 'rb') as f:
        return f.read()


_PAL = None


def cockpit_pal():
    global _PAL
    if _PAL is None:
        _PAL = gfx.read_dpl(_rd('DPL', 'COCKPIT.DPL'))
    return _PAL


def dba(name):
    return gfx.read_any(_rd('DBA', name.upper() + '.DBA'))


# ============================================================================ GAU

def _i32(d, off, n=1):
    v = struct.unpack_from('<%di' % n, d, off)
    return v if n > 1 else v[0]


def _rect(d, off, ox=0, oy=0):
    x0, y0, x1, y1 = _i32(d, off, 4)
    return [x0 + ox, y0 + oy, x1 + ox, y1 + oy]


def _rel(d, off, org):
    return _rect(d, off, org[0], org[1])


# PBUTTONS.DBA indices used by the instruments (pairs normal/pressed unless noted)
PB = {
    'F1': (10, 11), 'F2': (12, 13), 'F3': (14, 15), 'F4': (16, 17), 'F5': (18, 19), 'F6': (20, 21),
    'F7': (22, 23), 'F8': (24, 25), 'bar_cursor': 26, 'throttle_lever': 27,
    'mfd_wide_button': (3, 4, 5), 'mfd_up': (29, 30, 31), 'mfd_down': (32, 33, 34),
    'diamond': (35, 36, 37, 38, 39, 40, 41, 42), 'square_arrows': (43, 44, 45, 46, 47, 48, 49, 50),
    'zoom_out': (51, 52), 'zoom_in': (53, 54), 'weapon_led': (55, 56, 57),
    'small_up': (58, 59, 60), 'small_down': (61, 62, 63), 'indicator_button': (6, 7, 8),
}

MFD_MODES = ['STATUS', 'FLASH COMM', 'NAV MAP', 'SCANNER', 'TARGET', 'MISSILE CAM']


def read_gau(d):
    """Decode a GAU file into a dict of instruments with ABSOLUTE rects (x0,y0,x1,y1) in the
    320x400 panel space (y 0..199 = DB0 front view, y 200..399 = DB1 look-down panel)."""
    assert len(d) == 0x6a4, len(d)
    gx, gy = _i32(d, 0, 2)                      # global offset added to everything by the loader
    out = {'panel_extent': _rect(d, 0), 'global_offset': [gx, gy]}

    # ---- weapon slots (one per hardpoint, created by the weapon objects)
    n = _i32(d, 0x10)
    out['weapon_slots'] = [_rect(d, 0x14 + 16 * i, gx, gy) for i in range(n)]

    def org(off):
        x, y = _i32(d, off, 2)
        return (x + gx, y + gy)

    def rel(off, base):
        o = org(base)
        return _rel(d, off, o)

    # templates (relative to the slot rect origin; bounds field is overwritten with the slot rect)
    out['weapon_templates'] = {
        'ammo_text': {'gau_off': 0xa4, 'ctor': '0x373a4', 'label': _rect(d, 0xb4), 'value': _rect(d, 0xc4),
                      'raw': list(_i32(d, 0xa4, 20))},
        'charge_bar': {'gau_off': 0xf4, 'ctor': '0x3700c', 'label': _rect(d, 0x104), 'bar': _rect(d, 0x114),
                       'params': list(_i32(d, 0x124, 4)), 'raw': list(_i32(d, 0xf4, 24))},
        'ecm': {'gau_off': 0x154, 'ctor': '0x37810', 'button': _rect(d, 0x164), 'label': _rect(d, 0x174),
                'raw': list(_i32(d, 0x154, 28))},
    }

    g = {}
    b = 0x1c4
    g['indicators'] = {'gau_off': b, 'ctor': '0x37bd0', 'bounds': _rect(d, b, gx, gy),
                       'items': [rel(b + 0x10 + 16 * i, b) for i in range(5)],
                       'labels': ['I', 'II', 'III', 'LINK', 'TRACK']}
    b = 0x224
    t, e = _i32(d, b + 0x20, 2)
    g['engine_bar'] = {'gau_off': b, 'ctor': '0x39818', 'bounds': _rect(d, b, gx, gy), 'bar': rel(b + 0x10, b),
                       'bar_type': t, 'edg_clip': ('ENG_CLP%d' % e) if e else None,
                       'params': list(_i32(d, b + 0x28, 3))}
    b = 0x268
    g['brightness'] = {'gau_off': b, 'ctor': '0x38f34', 'bounds': _rect(d, b, gx, gy),
                       'button_up': rel(b + 0x10, b), 'button_down': rel(b + 0x20, b),
                       'text_up': rel(b + 0x30, b), 'text_down': rel(b + 0x40, b),
                       'raw_tail': list(_i32(d, b + 0x50, 8))}
    b = 0x2d8
    g['mfd'] = {'gau_off': b, 'ctor': '0x39c64', 'bounds': _rect(d, b, gx, gy),
                'buttons': [rel(b + 0x10 + 16 * i, b) for i in range(13)],
                'button_roles': ['mode F1 ' + MFD_MODES[0], 'mode F2 ' + MFD_MODES[1], 'mode F3 ' + MFD_MODES[2],
                                 'mode F4 ' + MFD_MODES[3], 'mode F5 ' + MFD_MODES[4], 'mode F6 ' + MFD_MODES[5],
                                 'title text', 'option 1', 'option 2', 'option 3', 'option 4', 'up', 'down'],
                'display': rel(b + 0xe0, b), 'raw_tail': list(_i32(d, b + 0xf0, 8))}
    b = 0x3e8
    t, lever = _i32(d, b + 0x40, 2)
    g['throttle'] = {'gau_off': b, 'ctor': '0x3b0d4', 'bounds': _rect(d, b, gx, gy), 'lever': rel(b + 0x10, b),
                     'bar_forward': rel(b + 0x20, b), 'bar_reverse': rel(b + 0x30, b),
                     'orientation': {1: 'vertical', 2: 'horizontal'}.get(t, t),
                     'led_dba': ['WPN_LED1', 'THR_LED1', 'THR_LED2'][t] if 0 <= t < 3 else None,
                     'lever_pbutton': lever, 'raw_tail': list(_i32(d, b + 0x48, 8))}
    b = 0x450
    o = org(b)
    cx, cy, rs = _i32(d, b + 0x30, 3)
    g['hud'] = {'gau_off': b, 'ctor': '0x34aec', 'bounds': _rect(d, b, gx, gy), 'heading_tape': rel(b + 0x10, b),
                'pitch_slider': rel(b + 0x20, b), 'center': [cx + o[0], cy + o[1]], 'reticle_half': rs,
                'target_area': rel(b + 0x3c, b), 'raw_tail': list(_i32(d, b + 0x4c, 8))}
    b = 0x4bc
    btn = [rel(b + 0x50 + 16 * i, b) for i in range(15)]
    g['hdd'] = {'gau_off': b, 'ctor': '0x3c258', 'bounds': _rect(d, b, gx, gy), 'screen': rel(b + 0x10, b),
                'map_area': rel(b + 0x20, b), 'damage_area': rel(b + 0x30, b), 'small_rect': rel(b + 0x40, b),
                'buttons': btn,
                'button_roles': ['F7', 'F8', 'scroll up', 'scroll down', 'scroll left', 'scroll right',
                                 'zoom out', 'zoom in', 'text button 8', 'title / mode text',
                                 'wingman 1 video', 'wingman 2 video', 'wingman 3 video',
                                 'text button 13', 'text button 14'],
                'wingman_leds': [rel(b + 0x140 + 16 * i, b) for i in range(3)],
                'arrow_pbutton_base': _i32(d, b + 0x170), 'raw_tail': list(_i32(d, b + 0x174, 5))}
    b = 0x644
    g['clock'] = {'gau_off': b, 'ctor': '0x433cc', 'bounds': _rect(d, b, gx, gy), 'text': rel(b + 0x10, b),
                  'anim_pos': list(_i32(d, b + 0x20, 2)), 'raw_tail': list(_i32(d, b + 0x28, 6))}
    g['message_view'] = {'gau_off': 0x684, 'ctor': '0x2f3d8', 'bounds': _rect(d, 0x684)}
    g['message_panel'] = {'gau_off': 0x694, 'ctor': '0x2eb80', 'bounds': _rect(d, 0x694)}
    out['gauges'] = g
    return out


# ============================================================================ VUE / edge regions

def read_vue(d):
    n = _i32(d, 0)
    views = []
    for i in range(n):
        v = _i32(d, 4 + 32 * i, 8)
        views.append({'viewport': list(v[0:4]), 'center_offset': list(v[4:6]), 'pan': list(v[6:8])})
    return views


def read_edges(d):
    """Edge-table region (ED0..ED3, EDG). Returns list of (y, xL, xR) spans (inclusive)."""
    spans = []
    if len(d) < 2:
        return spans
    p = 0
    n = struct.unpack_from('<h', d, p)[0]
    p += 2
    for _ in range(n):                      # full-width bands
        y0, y1 = struct.unpack_from('<hh', d, p)
        p += 4
        for y in range(y0, y1 + 1):
            spans.append((y, 0, 319))
    if p + 2 > len(d):
        return spans
    n = struct.unpack_from('<h', d, p)[0]
    p += 2
    for _ in range(n):                      # per-scanline span lists
        y0, rows = struct.unpack_from('<hh', d, p)
        p += 4
        for r in range(rows):
            xl, xr = struct.unpack_from('<hh', d, p)
            p += 4
            spans.append((y0 + r, xl, xr))
    return spans


def read_ofs(d):
    n = len(d) // 12
    return [list(_i32(d, 12 * i, 3)) for i in range(n)]


def read_pdg(d):
    v = struct.unpack('<%di' % (len(d) // 4), d)
    p = 0
    ni = v[p]
    p += 1
    imgs = []
    for _ in range(ni):
        hdr = v[p:p + 4]
        p += 4
        npart = v[p]
        p += 1
        parts = []
        for _ in range(npart):
            q = v[p:p + 7]
            p += 7
            parts.append({'component': q[0], 'rect': list(q[1:5]), 'color': q[5], 'flag': q[6]})
        imgs.append({'origin': list(hdr[0:2]), 'size': list(hdr[2:4]), 'regions': parts})
    nw = v[p]
    p += 1
    mounts = []
    for _ in range(nw):
        mounts.append(list(v[p:p + 5]))
        p += 5
    return {'images': imgs, 'mounts': mounts}


def read_weapons_pdg(d):
    n = _i32(d, 0)
    return [list(_i32(d, 4 + 8 * i, 2)) for i in range(n)]


def read_strings0(d):
    """SIMVOL0 STR: u32 size; groups { u16 count; count x { u16 len; char s[len]; 1..2 pad bytes } }.
    The pad size varies per group (STRINGS0 group 0 has 2 bytes), so resynchronise by lookahead."""
    size = _i32(d, 0)
    end = min(len(d), 4 + size)
    p = 4
    groups = []

    def ok(q):
        if q + 2 > end:
            return False
        ln = struct.unpack_from('<H', d, q)[0]
        return 1 <= ln < 80 and q + 2 + ln <= end and d[q + 1 + ln] == 0 and \
            all(32 <= c < 127 for c in d[q + 2:q + 1 + ln])

    while p + 2 <= end:
        n = struct.unpack_from('<H', d, p)[0]
        p += 2
        if n == 0 or n > 200:
            break
        g = []
        for i in range(n):
            ln = struct.unpack_from('<H', d, p)[0]
            g.append(d[p + 2:p + 1 + ln].decode('cp437'))
            p += 2 + ln
            if i < n - 1:
                for k in (1, 2, 0, 3):
                    if ok(p + k):
                        p += k
                        break
            else:
                for k in (1, 2, 0, 3):      # next token is a group count followed by a string
                    if p + k + 2 <= end and ok(p + k + 2):
                        p += k
                        break
                else:
                    p += 1
        groups.append(g)
    return groups


# ============================================================================ images

def img(b, transparent=True):
    return gfx.to_image(b, cockpit_pal(), transparent)


def contact_sheet(bs, scale=3):
    cw = max(b['w'] for b in bs) * scale + 8
    ch = max(b['h'] for b in bs) * scale + 14
    cols = max(1, min(len(bs), 1200 // cw))
    rows = (len(bs) + cols - 1) // cols
    im = Image.new('RGB', (cols * cw, rows * ch), (40, 0, 60))
    dr = ImageDraw.Draw(im)
    for i, b in enumerate(bs):
        x, y = (i % cols) * cw, (i // cols) * ch
        t = img(b).resize((b['w'] * scale, b['h'] * scale), Image.NEAREST)
        im.paste(t, (x + 4, y + 12), t)
        dr.text((x + 2, y), str(i), fill=(255, 255, 0))
    return im


def pilot_frame(base, faces, ofs, face_i, body_i=None):
    """Compose a pilot comm-video frame: last DBA entry is the torso/background (drawn at 0,0),
    then a face frame and a shoulder/mouth strip at their OFS offsets."""
    bg = faces[-1]
    W, H = 80, 64
    im = Image.new('RGBA', (W, H), (0, 0, 0, 255))
    off = {r[0]: (r[1], r[2]) for r in ofs}
    order = [len(faces) - 1, face_i] + ([body_i] if body_i is not None else [])
    for k in order:
        if k is None or k >= len(faces):
            continue
        dx, dy = off.get(k, (0, 0))
        t = img(faces[k])
        im.paste(t, (dx, dy + 4), t)
    return im


# ============================================================================ mock-up

COL = {'weapon': (255, 255, 255), 'indicators': (255, 64, 64), 'engine_bar': (0, 255, 0),
       'brightness': (0, 255, 255), 'mfd': (255, 255, 0), 'throttle': (255, 0, 255), 'hud': (255, 160, 0),
       'hdd': (160, 200, 255), 'clock': (80, 120, 255), 'message_view': (255, 128, 192),
       'message_panel': (255, 128, 192)}


class Painter:
    def __init__(self, im, scale):
        self.im, self.s = im, scale
        self.dr = ImageDraw.Draw(im)

    def rect(self, r, c, lab=None, fill=False):
        x0, y0, x1, y1 = r
        if x1 < x0 or y1 < y0:
            return
        s = self.s
        box = (x0 * s, y0 * s, (x1 + 1) * s - 1, (y1 + 1) * s - 1)
        if fill:
            self.dr.rectangle(box, fill=c + (70,))
        self.dr.rectangle(box, outline=c)
        if lab:
            self.dr.text((x0 * s + 2, y0 * s + 1), lab, fill=c)

    def bmp(self, b, x, y, clip=None):
        t = img(b)
        if clip:
            cx0, cy0, cx1, cy1 = clip
            t = t.crop((max(0, cx0 - x), max(0, cy0 - y), min(t.width, cx1 - x + 1), min(t.height, cy1 - y + 1)))
            x, y = max(x, cx0), max(y, cy0)
        t = t.resize((t.width * self.s, t.height * self.s), Image.NEAREST)
        self.im.alpha_composite(t, (x * self.s, y * self.s))

    def text(self, font, x, y, s):
        tmp = Image.new('RGBA', (font.width(s) + 2, font.f['height']), (0, 0, 0, 0))
        font.draw(tmp, 0, 0, s, cockpit_pal())
        tmp = tmp.resize((tmp.width * self.s, tmp.height * self.s), Image.NEAREST)
        self.im.alpha_composite(tmp, (x * self.s, y * self.s))


def _fonts():
    import shell
    return {k: shell.Font(k, [os.path.join(SIM, 'DFN')]) for k in
            ('CPGREEN', 'CPBLUE', 'CPRED', 'CPYLW', 'CPON', 'CPGREY', 'CPBLACK', 'GREEN6X8')}


def mockup(herc, lay, scale=3, labels=True):
    pal = cockpit_pal()
    base = Image.new('RGBA', (320, 400), (0, 0, 0, 255))
    for k in '01':
        b = gfx.read_any(_rd('DB' + k, '%s.DB%s' % (herc, k)))[0]
        base.paste(img(b, False), (0, 200 * int(k)))
    # tint the 3D window regions (ED0 for the front view, ED1 for the look-down view)
    tint = Image.new('RGBA', (320, 400), (0, 0, 0, 0))
    tp = tint.load()
    for k, dy in (('0', 0), ('1', 200)):
        for y, xl, xr in read_edges(_rd('ED' + k, '%s.ED%s' % (herc, k))):
            for x in range(max(0, xl), min(319, xr) + 1):
                if 0 <= y < 200:
                    tp[x, y + dy] = (40, 70, 120, 255)
    base.alpha_composite(tint)
    im = base.resize((320 * scale, 400 * scale), Image.NEAREST)
    P = Painter(im, scale)
    pb = dba('PBUTTONS')
    F = _fonts()
    g = lay['gauges']

    # --- HUD (drawn in the 3D view)
    h = g['hud']
    tick = dba('HUDHTICK')
    r = h['heading_tape']
    P.bmp(tick[0], r[0] - 4, r[1], clip=r)
    hs = dba('HUDHSLID')
    P.bmp(hs[0], (r[0] + r[2]) // 2 - 48, r[1] + 10)
    P.bmp(hs[1], (r[0] + r[2]) // 2 - 16, r[1] + 10)
    vs = dba('HUDVSLID')
    r2 = h['pitch_slider']
    P.bmp(vs[0], r2[0] - 3, (r2[1] + r2[3]) // 2 - 14)
    cx, cy = h['center']
    q = h['reticle_half']
    P.rect([cx - q, cy - q, cx + q, cy + q], COL['hud'], None)
    # --- MFD
    m = g['mfd']
    for i, key in enumerate(['F1', 'F2', 'F3', 'F4', 'F5', 'F6']):
        r = m['buttons'][i]
        P.bmp(pb[PB[key][1 if i == 3 else 0]], r[0], r[1])
    for i in range(7, 11):
        r = m['buttons'][i]
        P.bmp(pb[3], r[0], r[1], clip=r)
    P.bmp(pb[29], m['buttons'][11][0], m['buttons'][11][1], clip=m['buttons'][11])
    P.bmp(pb[32], m['buttons'][12][0], m['buttons'][12][1], clip=m['buttons'][12])
    rad = dba('RADAR')[0]
    dsp = m['display']
    P.bmp(rad, dsp[0], dsp[1], clip=dsp)
    P.text(F['CPRED'], m['buttons'][6][0] + 1, m['buttons'][6][1] + 1, 'SCANNER')
    # --- throttle
    t = g['throttle']
    if t['led_dba'] in ('THR_LED1', 'THR_LED2'):
        led = dba(t['led_dba'])
        for key, idx in (('bar_forward', 0), ('bar_reverse', 2)):
            r = t[key]
            P.bmp(led[idx], r[0], r[1], clip=[r[0], r[1], r[0] + led[idx]['w'] - 1, r[3]] if t['orientation'] == 'vertical'
                  else [r[0], r[1], r[2], r[1] + led[idx]['h'] - 1])
        lv = pb[t['lever_pbutton']]
        r = t['lever']
        if t['orientation'] == 'vertical':
            P.bmp(lv, r[0], (r[1] + r[3]) // 2 - lv['h'] // 2)
        else:
            P.bmp(lv, (r[0] + r[2]) // 2 - lv['w'] // 2, r[1])
    # --- weapons
    names = ['LAS 200', 'ATC 35', 'MLRS 8', 'PBW', 'ATC 20', 'EMP', 'ELF', 'GREN', 'ECM']
    for i, r in enumerate(lay['weapon_slots']):
        P.text(F['CPGREEN'], r[0] + 4, r[1], names[i % len(names)])
        P.bmp(pb[55 + (i % 3)], r[0], r[1])
    # --- indicators
    for lab, r in zip(g['indicators']['labels'], g['indicators']['items']):
        if lab in ('LINK', 'TRACK'):
            P.bmp(pb[6], r[0], r[1], clip=r)
            P.text(F['CPON'], r[0] + 2, r[1] + 2, lab)
        else:
            P.text(F['CPBLUE'], r[0] + 2, r[1], lab)
    # --- brightness
    bb = g['brightness']
    P.bmp(pb[58], bb['button_up'][0], bb['button_up'][1], clip=bb['button_up'])
    P.bmp(pb[61], bb['button_down'][0], bb['button_down'][1], clip=bb['button_down'])
    P.text(F['CPGREEN'], bb['text_up'][0], bb['text_up'][1], '75')
    # --- clock / messages
    c = g['clock']['text']
    P.text(F['CPBLUE'], c[0], c[1], '12:34')
    r = g['message_panel']['bounds']
    P.text(F['CPGREEN'], r[0] + 2, r[1] + 1, 'MESSAGE LINE')
    # --- HDD
    d = g['hdd']
    base_arrow = d['arrow_pbutton_base']
    for i, idx in enumerate([22, 24, base_arrow, base_arrow + 2, base_arrow + 4, base_arrow + 6, 51, 53]):
        r = d['buttons'][i]
        if idx < len(pb):
            P.bmp(pb[idx], r[0], r[1], clip=[r[0], r[1], r[0] + 40, r[1] + 40])
    pil = dba('PILOT1S')
    ofs = read_ofs(_rd('OFS', 'PILOT1.OFS'))
    st = dba('STATIC')
    for k, i in enumerate((10, 11, 12)):
        r = d['buttons'][i]
        if k == 1:
            P.bmp(st[0], r[0], r[1], clip=r)
        else:
            fr = pilot_frame(None, pil, ofs, 0, 6)
            fr = fr.crop((0, 0, r[2] - r[0] + 1, r[3] - r[1] + 1)).resize(
                ((r[2] - r[0] + 1) * scale, (r[3] - r[1] + 1) * scale), Image.NEAREST)
            im.alpha_composite(fr, (r[0] * scale, r[1] * scale))
    P.text(F['CPGREEN'], d['buttons'][9][0] + 2, d['buttons'][9][1] + 1, 'NAV MAP')

    if labels:
        for i, r in enumerate(lay['weapon_slots']):
            P.rect(r, COL['weapon'], 'W%d' % i)
        for name, gg in g.items():
            c = COL.get(name, (255, 255, 255))
            if 'bounds' in gg and gg['bounds'] != [0, 0, 0, 0] and name not in ('hud',):
                P.rect(gg['bounds'], c, name)
            for k, v in gg.items():
                if k in ('bounds', 'raw', 'raw_tail', 'params', 'center', 'anim_pos'):
                    continue
                if isinstance(v, list) and len(v) == 4 and all(isinstance(x, int) for x in v):
                    P.rect(v, c, '%s.%s' % (name[:4], k))
                elif isinstance(v, list) and v and isinstance(v[0], list):
                    for j, rr in enumerate(v):
                        if len(rr) == 4:
                            P.rect(rr, c, '%s.%s%d' % (name[:4], k[0], j))
    return im


def views_mockup(herc, scale=2):
    """4 panels: front DB0+ED0, look-down DB1+ED1, left DB2+ED2, right mirrored DB2+ED3."""
    out = Image.new('RGBA', (640 * scale, 400 * scale), (0, 0, 0, 255))
    vue = read_vue(_rd('VUE', herc + '.VUE'))
    for k in range(4):
        dbk = '012'[min(k, 2)]
        b = gfx.read_any(_rd('DB' + dbk, '%s.DB%s' % (herc, dbk)))[0]
        im = img(b, False)
        if k == 3:
            im = im.transpose(Image.FLIP_LEFT_RIGHT)
        px = im.load()
        for y, xl, xr in read_edges(_rd('ED%d' % k, '%s.ED%d' % (herc, k))):
            for x in range(max(0, xl), min(319, xr) + 1):
                if 0 <= y < 200:
                    r, g, bb, a = px[x, y]
                    px[x, y] = (r // 2, min(255, g // 2 + 60), min(255, bb // 2 + 120), 255)
        dr = ImageDraw.Draw(im)
        v = vue[k]
        x0, y0, x1, y1 = v['viewport']
        if x1 > x0 and y1 > y0:
            dr.rectangle((x0, y0, x1 - 1, y1 - 1), outline=(255, 255, 0))
        ccx, ccy = -v['center_offset'][0], -v['center_offset'][1]
        dr.line((ccx - 4, ccy, ccx + 4, ccy), fill=(255, 0, 0))
        dr.line((ccx, ccy - 4, ccx, ccy + 4), fill=(255, 0, 0))
        dr.text((2, 190), 'view %d vp=%s c=%s pan=%s' % (k, v['viewport'], v['center_offset'], v['pan']),
                fill=(255, 255, 255))
        out.paste(im.resize((320 * scale, 200 * scale), Image.NEAREST), ((k % 2) * 320 * scale, (k // 2) * 200 * scale))
    return out


# ============================================================================ export

INSTR_DBA = ['PBUTTONS', 'ICONS', 'HUDHSLID', 'HUDHTICK', 'HUDVSLID', 'RADAR', 'STATIC', 'THR_LED1', 'THR_LED2',
             'SMLWLD0', 'SMLWLD1', 'SMLWLD2', 'WEAPONS', 'CORNERS', 'CAL_ALRT', 'CTL_ALRT', 'GNL_ALRT',
             'GNL2ALRT', 'HST_ALRT', 'PRF_ALRT']


def export_all(out):
    os.makedirs(out, exist_ok=True)
    for sub in ('layout', 'mockup', 'bitmaps', 'pilots', 'pdg', 'fonts', 'edges'):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    pal = cockpit_pal()
    # --- bitmaps
    for n in INSTR_DBA:
        bs = dba(n)
        contact_sheet(bs).save(os.path.join(out, 'bitmaps', n + '_sheet.png'))
        d = os.path.join(out, 'bitmaps', n)
        os.makedirs(d, exist_ok=True)
        for i, b in enumerate(bs):
            img(b).save(os.path.join(d, '%s_%02d.png' % (n, i)))
    for n in ('DCI/ALERT.DCI',):
        b = gfx.read_any(_rd(*n.split('/')))[0]
        img(b).save(os.path.join(out, 'bitmaps', 'ALERT_DCI.png'))
    for h in HERCS:
        for k in '012':
            b = gfx.read_any(_rd('DB' + k, '%s.DB%s' % (h, k)))[0]
            img(b, False).save(os.path.join(out, 'bitmaps', '%s_DB%s.png' % (h, k)))
    # --- edge regions (EDG clips + per-view windows) as JSON
    edges = {}
    for p in sorted(glob.glob(os.path.join(SIM, 'EDG', '*.EDG'))):
        edges[os.path.basename(p)] = read_edges(open(p, 'rb').read())
    for h in HERCS:
        for k in range(4):
            edges['%s.ED%d' % (h, k)] = read_edges(_rd('ED%d' % k, '%s.ED%d' % (h, k)))
    with open(os.path.join(out, 'edges', 'edges.json'), 'w') as f:
        json.dump({k: [list(s) for s in v] for k, v in edges.items()}, f)
    for p in sorted(glob.glob(os.path.join(SIM, 'EDG', '*.EDG'))):
        sp = read_edges(open(p, 'rb').read())
        W = max(s[2] for s in sp) + 1
        H = max(s[0] for s in sp) + 1
        im = Image.new('L', (W, H), 0)
        for y, xl, xr in sp:
            for x in range(xl, xr + 1):
                im.putpixel((x, y), 255)
        im.resize((W * 4, H * 4), Image.NEAREST).save(os.path.join(out, 'edges', os.path.basename(p) + '.png'))
    # --- pilots
    for p in sorted(glob.glob(os.path.join(SIM, 'OFS', '*.OFS'))):
        name = os.path.splitext(os.path.basename(p))[0]
        ofs = read_ofs(open(p, 'rb').read())
        for suf in ('', 'S'):
            try:
                faces = dba(name + suf)
            except FileNotFoundError:
                continue
            nf = len(faces)
            nface = sum(1 for b in faces[:-1] if b['h'] > 20)
            frames = [pilot_frame(None, faces, ofs, i, nface if nface < nf - 1 else None) for i in range(nface)]
            sheet = Image.new('RGBA', (82 * len(frames), 66), (40, 0, 60, 255))
            for i, fr in enumerate(frames):
                sheet.paste(fr, (82 * i, 0))
            sheet.save(os.path.join(out, 'pilots', name + suf + '.png'))
            contact_sheet(faces, 2).save(os.path.join(out, 'pilots', name + suf + '_parts.png'))
        with open(os.path.join(out, 'pilots', name + '_ofs.json'), 'w') as f:
            json.dump({'records': ofs, 'format': '(dba_index, dx, dy)'}, f)
    # --- PDG damage diagrams
    wp = read_weapons_pdg(_rd('PDG', 'WEAPONS.PDG'))
    with open(os.path.join(out, 'pdg', 'WEAPONS.json'), 'w') as f:
        json.dump({'sizes_wh': wp}, f)
    for p in sorted(glob.glob(os.path.join(SIM, 'PDG', '*.PDG'))):
        name = os.path.splitext(os.path.basename(p))[0]
        if name == 'WEAPONS':
            continue
        pdg = read_pdg(open(p, 'rb').read())
        with open(os.path.join(out, 'pdg', name + '.json'), 'w') as f:
            json.dump(pdg, f, indent=1)
        try:
            bs = dba(name)
        except FileNotFoundError:
            continue
        s = 4
        W = sum(b['w'] for b in bs) * s + 20 * len(bs)
        H = max(b['h'] for b in bs) * s + 10
        im = Image.new('RGBA', (W, H), (30, 30, 30, 255))
        dr = ImageDraw.Draw(im)
        x = 0
        for i, b in enumerate(bs):
            t = img(b).resize((b['w'] * s, b['h'] * s), Image.NEAREST)
            im.alpha_composite(t, (x, 0))
            if i < len(pdg['images']):
                for part in pdg['images'][i]['regions']:
                    r = part['rect']
                    c = tuple(pal[part['color']][:3])
                    dr.rectangle((x + r[0] * s, r[1] * s, x + r[2] * s, r[3] * s), outline=c)
                    dr.text((x + r[0] * s + 1, r[1] * s + 1), str(part['component']), fill=(255, 255, 0))
            x += b['w'] * s + 20
        im.save(os.path.join(out, 'pdg', name + '.png'))
    # --- fonts
    import shell
    for p in sorted(glob.glob(os.path.join(SIM, 'DFN', '*.DFN'))):
        shell.export_font(p, os.path.join(out, 'fonts'), os.path.join(SIM, 'DPL', 'COCKPIT.DPL'))
    # --- strings
    with open(os.path.join(out, 'strings0.json'), 'w') as f:
        json.dump(read_strings0(_rd('STR', 'STRINGS0.STR')), f, indent=1)
    # --- BND blocks of the cockpit modules (raw; the shipping exe does not read them)
    bnd = {}
    for n in ('PANEL', 'PGAUGE', 'PHDD', 'PHDDDAMG', 'PHDDMAP', 'PHUD', 'PMFD', 'PRADAR', 'PSTATUS', 'MECHVIEW',
              'ALERT', 'GNL_ALRT', 'CAL_ALRT', 'CTL_ALRT', 'OBJ_ALRT', 'PRF_ALRT'):
        d = _rd('BND', n + '.BND')
        bnd[n] = {'stamp': '0x%08x' % _i32(d, 0), 'words': list(struct.unpack_from('<%dh' % ((len(d) - 4) // 2), d, 4))}
    with open(os.path.join(out, 'layout', 'bnd_cockpit.json'), 'w') as f:
        json.dump(bnd, f, indent=1)
    # --- per-Herc layout + mock-ups
    for h in HERCS:
        lay = read_gau(_rd('GAU', h + '.GAU'))
        lay['herc'] = h
        lay['views'] = read_vue(_rd('VUE', h + '.VUE'))
        lay['overlays'] = {'front': 'DB0/%s.DB0' % h, 'look_down': 'DB1/%s.DB1' % h, 'side': 'DB2/%s.DB2' % h,
                           'palette': 'DPL/COCKPIT.DPL'}
        lay['window_regions'] = {'ED%d' % k: 'edges.json[%s.ED%d]' % (h, k) for k in range(4)}
        with open(os.path.join(out, 'layout', h + '.json'), 'w') as f:
            json.dump(lay, f, indent=1)
        mockup(h, lay).convert('RGB').save(os.path.join(out, 'mockup', h + '.png'))
        mockup(h, lay, 2, labels=False).convert('RGB').save(os.path.join(out, 'mockup', h + '_clean.png'))
        views_mockup(h).convert('RGB').save(os.path.join(out, 'mockup', h + '_views.png'))
    print('wrote', out)


def main(argv):
    if len(argv) >= 2 and argv[1] == 'all':
        export_all(argv[2] if len(argv) > 2 else os.path.join(ROOT, 'extracted', 'cockpit'))
    elif len(argv) >= 3 and argv[1] == 'gau':
        print(json.dumps(read_gau(_rd('GAU', argv[2].upper() + '.GAU')), indent=1))
    else:
        print(__doc__)


if __name__ == '__main__':
    main(sys.argv)
