"""Earthsiege 2 cockpit instruments: GAU layout, edge regions and the instrument geometry DBSIM.EXE computes
in code. Spec: docs/formats/cockpit.md section 8. Exporter: tools/export_es2_cockpit.py.

Addresses are ES2 DBSIM.EXE VAs (Win32 PE, image base 0x400000). The ES2 sim is the Earthsiege 1 panel code
grown up (same gauge families, RTTI names in the exe: EnergyWeaponGauge, ProjectileWeaponGauge, MFDGauge,
ThrottleGauge, HUDGauge, HDDGauge ...), so the decoded layout uses the Earthsiege 1 schema
(tools/cockpit.py read_gau) wherever the instrument is the same.

Coordinates: every GAU rect is in 320x240 low-resolution pixels (DB0 / DB1 space); in 640x480 mode the loader
shifts every value left by one ([0x4d25be] / [0x4d25c0], e.g. 0x431cb1). Front-view instruments are relative to
DB0, the head-down display to DB1 (its section origin (0, 197) is not applied: the rects match the DB1 art).
make_layout() moves look-down rects below the front view (+ LOOK_DOWN_TOP) like the Earthsiege 1 layout.
"""
import struct

import cockpit

CANVAS = [320, 240]
LOOK_DOWN_TOP = 240          # look-down (DB1) rects are stored at y + 240 in the exported layout
ART_SCALE = 2                # HB0/HBA/HFN art is 640x480 (DBSIM picks hba/hfn when [0x4d25bb] == 3)
GAU_SIZE = 0x6a4
WEAPON_SLOTS = 10            # 0x14 + 10 * 16 = 0xb4 (panel weapon array +0x70, 10 entries, 0x431fb4)

# ---- GAU sections (gauge builders of the panel ctor 0x431bf8; post-load fixups name the rect fields)
G_INDICATORS = 0x1d4         # 0x432340 -> ctor 0x441dd0: 4 text buttons (STRINGS0 group 4: I, LINK, TRACK)
G_ENERGY = 0x224             # 0x4323e0 -> ctor 0x444d5c: horizontal bar (BarGraphH 0x4395c4, max 0x400)
G_SHIELDS = 0x268            # 0x432454 -> ctor 0x4434fc: front / rear bars + two lamps (ShieldsSelectGadget)
G_MFD = 0x2d8                # 0x4324c8 -> ctor 0x445218
G_THROTTLE = 0x3e8           # 0x43254c -> ctor 0x447b84
G_HUD = 0x440                # 0x4325c0 -> ctor 0x43c7d8 (fixup 0x43e118)
G_HDD = 0x4bc                # 0x432634 -> ctor 0x448cc8 (fixup 0x44bed0, Earthsiege 1 layout)
G_CLOCK = 0x644
G_MESSAGE_VIEW = 0x684       # 0x436244 / 0x435bf0
G_MESSAGE_PANEL = 0x694      # 0x4369a4

# ---- geometry DBSIM computes in code (low-res pixels; shifted by the resolution like the GAU values)
# Weapon slot (55 x 6 px): WeaponSelectGadget 0x442488 puts the status LED at x + 6..9 and the name at
# x + 11..35; EnergyWeaponGauge 0x440a68 the charge bar and ProjectileWeaponGauge 0x440f78 the ammo count at
# x + 36..53 (rows y .. y + 5 / y + 7). PWEAPONS frames 0 / 1 (58 x 9) frame the selected / other slots
# at (x - 1, y - 1) (0x44287b..0x4428b5).
SLOT_LED = [6, 0, 9, 7]
SLOT_LABEL = [11, 0, 35, 5]
SLOT_VALUE = [36, 0, 53, 5]
SLOT_FRAME = [-1, -1, 56, 7]
# MFD (ctor 0x445218): the page area starts 18 px right of the GAU display rect (0x44536d); the 13 buttons
# are placed by the tables 0x49cacc / 0x49cae6 / 0x49cb00 / 0x49cb1a (x0, y0, x1, y1 from the page origin;
# = PMFD.BND words 7..58). Buttons 0..5 = page buttons, 6 = title (empty rect), 7..12 = page options.
MFD_PAGE_OFFSET = 18
MFD_BUTTON_X0 = [-16, -16, -16, -16, -16, -16, 0, 50, 4, 4, 50, 4, 4]
MFD_BUTTON_Y0 = [1, 11, 21, 31, 41, 51, 0, 2, 36, 47, 2, 14, 25]
MFD_BUTTON_X1 = [-2, -2, -2, -2, -2, -2, 0, 95, 30, 30, 95, 30, 30]
MFD_BUTTON_Y1 = [8, 18, 28, 38, 48, 58, 0, 11, 45, 56, 11, 23, 34]
MFD_TITLE = [4, 0, 40, 9]            # 0x44579e: page title text (font "dark", left aligned)
MFD_STATUS_LINE = [22, 46, 74, 52]   # 0x445897: bottom text line (centred)
# HUD (ctor 0x43c7d8): +0x20 = mission clock text ("00:00", update 0x43dcac), +0x28 = speed text ("000 K/H",
# 0x43dc78), both in font hud2; +0x6c = flyers' altimeter (0x43dd70) / nav text (hud3). The torso-twist
# slider sits 15 px right of / 10 px above the heading tape rect and is 90 x 4 px (0x43ca46..0x43ca8e, range
# +-0x38e3 = +-80 deg); the heading window is +-0xe38 (+-20 deg).
HUD_TORSO_SLIDER = [15, -10, 105, -6]

EVIDENCE = {   # VA: (bytes, meaning) - checked against es2/original/DBSIM.EXE by export_es2_cockpit.verify_exe
    0x49cacc: (struct.pack('<13h', *MFD_BUTTON_X0), 'MFD button x0 table'),
    0x49cae6: (struct.pack('<13h', *MFD_BUTTON_Y0), 'MFD button y0 table'),
    0x49cb00: (struct.pack('<13h', *MFD_BUTTON_X1), 'MFD button x1 table'),
    0x49cb1a: (struct.pack('<13h', *MFD_BUTTON_Y1), 'MFD button y1 table'),
    0x445368: (bytes.fromhex('b812000000'), 'MFD page area x + 18'),
    0x442542: (bytes.fromhex('ba23000000'), 'weapon name rect x + 35 (mirrored slot)'),
    0x440b5a: (bytes.fromhex('ba35000000'), 'charge bar x + 53'),
    0x43ca4d: (bytes.fromhex('ba0f000000'), 'torso slider x + 15'),
    0x4428ab: (bytes.fromhex('b801000000'), 'weapon slot frame at x - 1, y - 1'),
    0x429ad9: (bytes.fromhex('8d1c5b83c320'), 'cockpit colour scheme: 0x20 + 24 * DAT word'),
}


def _i32(d, off, n=1):
    v = struct.unpack_from('<%di' % n, d, off)
    return list(v) if n > 1 else v[0]


def _rect(d, off, dy=0):
    x0, y0, x1, y1 = _i32(d, off, 4)
    return [x0, y0 + dy, x1, y1 + dy]


def _offset(r, origin, dy=0):
    return [r[0] + origin[0], r[1] + origin[1] + dy, r[2] + origin[0], r[3] + origin[1] + dy]


def read_gau(d):
    """Decode an ES2 GAU (1700 bytes of s32, read whole by 0x431778) into the raw sections."""
    assert len(d) == GAU_SIZE, len(d)
    g = {'slot_count': _i32(d, 0x10), 'slots': [_rect(d, 0x14 + 16 * i) for i in range(WEAPON_SLOTS)]}
    g['indicators'] = [_rect(d, G_INDICATORS + 0x10 + 16 * i) for i in range(4)]
    g['energy_bar'] = _rect(d, G_ENERGY + 0x10)
    g['energy_params'] = _i32(d, G_ENERGY + 0x20, 4)
    g['shields'] = [_rect(d, G_SHIELDS + 0x10 + 16 * i) for i in range(4)]
    g['mfd_display'] = _rect(d, G_MFD + 0xe0)
    g['throttle'] = {'lever': _rect(d, G_THROTTLE + 0x10), 'bar_forward': _rect(d, G_THROTTLE + 0x20),
                     'bar_reverse': _rect(d, G_THROTTLE + 0x30), 'type': _i32(d, G_THROTTLE + 0x40)}
    h = G_HUD
    g['hud'] = {'bounds': _rect(d, h), 'heading_tape': _rect(d, h + 0x10), 'clock_text': _i32(d, h + 0x20, 2),
                'speed_text': _i32(d, h + 0x28, 2), 'center': _i32(d, h + 0x30, 2), 'reticle_half': _i32(d, h + 0x38),
                'target_area': _rect(d, h + 0x3c), 'text_left': _rect(d, h + 0x4c), 'text_right': _rect(d, h + 0x5c),
                'nav_text': _i32(d, h + 0x6c, 2)}
    b = G_HDD
    g['hdd'] = {'origin': _i32(d, b, 2), 'screen': _rect(d, b + 0x10), 'map_area': _rect(d, b + 0x20),
                'damage_area': _rect(d, b + 0x30), 'small_rect': _rect(d, b + 0x40),
                'buttons': [_rect(d, b + 0x50 + 16 * i) for i in range(15)],
                'wingman_leds': [_rect(d, b + 0x140 + 16 * i) for i in range(3)]}
    g['clock'] = _rect(d, G_CLOCK + 0x10)
    g['message_view'] = _rect(d, G_MESSAGE_VIEW)
    g['message_panel'] = _rect(d, G_MESSAGE_PANEL)
    return g


def read_edges(d):
    """ES2 ED0..ED3 / HD0..HD3: like Earthsiege 1 (tools/cockpit.read_edges) except that a band carries its
    x range too: s16 nBands; nBands x {s16 y0, y1, xL, xR}; s16 nRuns; nRuns x {s16 y0, nRows, nRows x {xL, xR}}."""
    spans = []
    if len(d) < 2:
        return spans
    p = 0
    n = struct.unpack_from('<h', d, p)[0]
    p += 2
    for _ in range(n):
        y0, y1, xl, xr = struct.unpack_from('<4h', d, p)
        p += 8
        spans += [(y, xl, xr) for y in range(y0, y1 + 1)]
    if p + 2 > len(d):
        return spans
    n = struct.unpack_from('<h', d, p)[0]
    p += 2
    for _ in range(n):
        y0, rows = struct.unpack_from('<hh', d, p)
        p += 4
        for r in range(rows):
            xl, xr = struct.unpack_from('<hh', d, p)
            p += 4
            spans.append((y0 + r, xl, xr))
    return spans


def make_mfd(display):
    """The MFD gauge in the Earthsiege 1 schema: display = the page area (GAU display + 18 px), buttons placed
    by the code tables (relative to the page area)."""
    page = [display[0] + MFD_PAGE_OFFSET, display[1], display[2], display[3]]
    o = page[:2]
    buttons = [[o[0] + MFD_BUTTON_X0[i], o[1] + MFD_BUTTON_Y0[i], o[0] + MFD_BUTTON_X1[i], o[1] + MFD_BUTTON_Y1[i]]
               for i in range(len(MFD_BUTTON_X0))]
    return {'bounds': display, 'display': page, 'buttons': buttons,
            'title': _offset(MFD_TITLE, o), 'status_line': _offset(MFD_STATUS_LINE, o)}


def make_hud(hud):
    t = hud['heading_tape']
    slider = [t[0] + HUD_TORSO_SLIDER[0], t[1] + HUD_TORSO_SLIDER[1], t[0] + HUD_TORSO_SLIDER[2],
              t[1] + HUD_TORSO_SLIDER[3]]
    out = dict(hud)
    out['torso_slider'] = slider
    return out


def make_hdd(hdd):
    """HDD rects are DB1-relative: move them below the front view."""
    def down(r):
        return [r[0], r[1] + LOOK_DOWN_TOP, r[2], r[3] + LOOK_DOWN_TOP]
    out = {k: down(hdd[k]) for k in ('screen', 'map_area', 'damage_area', 'small_rect')}
    out['bounds'] = [0, LOOK_DOWN_TOP, CANVAS[0] - 1, LOOK_DOWN_TOP + CANVAS[1] - 1]
    out['buttons'] = [down(r) for r in hdd['buttons']]
    out['wingman_leds'] = [down(r) for r in hdd['wingman_leds']]
    return out


def make_layout(gau):
    """Engine layout (Earthsiege 1 schema + the ES2 gauges) from read_gau()."""
    g = {
        'indicators': {'items': gau['indicators'][:3], 'labels': ['I', 'LINK', 'TRACK']},
        'engine_bar': {'bar': gau['energy_bar'], 'bar_type': 3, 'params': gau['energy_params']},
        'shields': {'front': gau['shields'][0], 'rear': gau['shields'][1], 'front_lamp': gau['shields'][2],
                    'rear_lamp': gau['shields'][3]},
        'mfd': make_mfd(gau['mfd_display']),
        'throttle': dict(gau['throttle'], orientation='vertical' if gau['throttle']['type'] == 1 else 'horizontal'),
        'hud': make_hud(gau['hud']),
        'hdd': make_hdd(gau['hdd']),
        'message_view': {'bounds': gau['message_view']},
        'message_panel': {'bounds': gau['message_panel'], 'all_views': True},
    }
    tpl = {'led': SLOT_LED, 'label': SLOT_LABEL, 'frame': SLOT_FRAME}
    return {
        'canvas': {'size': CANVAS, 'look_down_top': LOOK_DOWN_TOP, 'art_scale': ART_SCALE},
        'weapon_slots': gau['slots'][:gau['slot_count']],
        'weapon_templates': {'charge_bar': dict(tpl, bar=SLOT_VALUE), 'ammo_text': dict(tpl, value=SLOT_VALUE)},
        'gauges': g,
    }


def read_vue(d):
    return cockpit.read_vue(d)
