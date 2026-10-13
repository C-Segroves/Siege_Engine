"""Battledrome (Dynamix 1994, SIM.EXE) in-sim HUD decoder.

    python tools/bd_hud.py            print the decoded HUD (meters, rects, flags)

Battledrome has no cockpit panel art.  The whole 320x200 screen is the 3D view and the HUD is drawn on top
of it by code: 15 small draggable "windows" (code\\hud.cpp classes), a reticle and the WINNER.DBA end-of-match
banners.  Everything is vector graphics: lines, filled/hollow rectangles, hollow ellipses, filled triangles /
quads and a built-in 3x5 *stroke* font.  This module turns the SIM.EXE code and tables plus DTS\\HUD.DAT into
the data the Godot remake needs to draw the HUD natively (tools/export_bd_cockpit.py writes it out).

Addresses are SIM.EXE virtual addresses: VA = file offset - 0x69CD (docs/formats/battledrome.md section 4).
Confidence: H = read from code/data and reproduced by running the original routines in an x86 interpreter,
M = read from code, meaning inferred, L = best estimate.

1. Panel art (H)
   No cockpit bitmaps exist: DTS\\ holds only WINNER.DBA / ERRSCRN.DBA as screen bitmaps, DATA\\ holds the
   shell's W*.DBA windows.  Hud::render (0x23a40) draws widgets with line / rect / ellipse / polygon / text
   primitives and loads only dts\\winner.dba (0x23a60, assert "Hud::render: Missing winner bitmap array").

2. HUD.DAT (H) - a ClassIO "HudPosition" item (class record 0x78276, read by 0x317ec, I/O 0x24294/0x242c4)
       u32 class tag 0x01F40000 (0x24270), u32 payload size 0x85 (0x2427c),
       15 x {s32 x, s32 y}      window top-left corners on the 320x200 screen (0x24294 writes 0x78 bytes)
       13 x u8 visible          (0x242ac writes 0xd bytes), + 1 pad byte to an even length
   Point / flag k belongs to the Hud sub-window listed in WIDGETS (order of 0x234a4 / 0x23eb4); windows 13
   (PrefBox) and 14 (ChatInputBox) have a position but no flag.  Hud::load (0x236f8): if the file is missing,
   the constructor defaults (copied by 0x234a4 into Hud+0xe3) are used and every flag is set.  After loading,
   TTButton, VTButton, ChatInputBox and Damage are forced hidden (0x24180..0x241ac) and PrefBox unless
   [0x967d2].  The shipped file equals the constructor defaults.  Every widget can be dragged with the mouse
   (message 0x20 handlers, e.g. 0x17488) and Hud::save (0x2375c) writes the layout back.

3. Drawing model (H)
   * Colours are palette indices (sim palette NRMPAL.DPL; 0..14 are the HUD colours: 1 blue, 3 light blue,
     4 green, 5 dark green, 7 red, 9 dark red, 10 yellow, 12 dark yellow).  A colour is a {u32 type,
     u32 value} pair: type 0 = solid, type 4 = hollow (outline) for rects / ellipses (0x4a7cc, 0x49d58).
     Lines and text use the context's +0x224 colour, fills +0x228.
   * Primitives: line 0x49b18, rect fill 0x49d58, ellipse 0x4a7cc, filled polygon 0x450e0, text 0x3b330.
     Coordinates are window-local; a window draws inside its own rect (Window::render prep 0x3e084).
   * Font: the global SFont at 0x9b568 (vtable 0x7ed00, init 0x3b094) is a stroke font: chars 0x21..0x5a,
     glyph table 0x7ea90 = 58 x {u32 count, u32 ptr -> count x {s16 x0,y0,x1,y1}} with y up from the
     baseline, cell 3x5, advance 3 + 1 (+0xe, +0x12; 0x3b330).  The text position is the baseline (bottom
     row) of the first character.  No .DFN font is used in the sim; GLFont / "Old GLFont" are unused library
     classes.

4. Widgets: see WIDGETS (class, Hud offset, ctor / resize / render) and the make_* functions below; each
   meter dict carries its own evidence.  Hud::render draw order (0x23c1d..0x23ea6): if [Hud+0x4d] (HUD on)
   and not [Hud+0x54] (reduced HUD): Energy, MechSpinners, TDButton, WeaponButton, Shields, Damage, TTButton;
   then always CameraSpinners, CamButton, ChatBox, ChatInputBox, Control, ActiveCam; then the reticle,
   the TELEPORTING banner and PrefBox.  VTButton is never drawn.  While the match-over flag [Hud+0x53] is
   set only the WINNER banners are drawn.

5. 3D view (H/M)
   Viewport: the main render (0x1604) projects through the viewport [0xa1388] created at 0x1c52 whose
   origin offsets are -(width/2), -(height/2) of the 320x200 screen surface (0x1c79..0x1cb0): the whole
   screen is the view and the projection centre is (160, 100) - the reticle centre (0x243d4).
   Eye (H for the rule, M for the reading): the cockpit camera (0x5eec) takes the transform of DCS logical
   part 18 of the Herc (0x5f2d push 0x12 -> 0x43f78 -> 0x43670), i.e. the last entry of the DCS trailer's
   logical-part table {i32 ?, i32 node, i32 x, y, z} (docs/formats/bd_weapons.md section 6): eye = world
   transform of that node applied to (x, y, z).  It is a torso node; the offset centres the eye (x ~ 0).
   With a probe camera ([user+0x2c] != 0) the probe object's transform is used instead.

Open questions: the exact meaning of the three MechSpinners angles (0x5a1b: chassis / torso / view guesses),
TT/VT marker motion (float code at 0x1f209), the TDButton TSBase colour (+0x49 = 7 when the target is the
aimed object, else 4; consumer not found), the timer unit of message lifetime (0x500 ticks of [0xa1168]).
"""
import os
import struct
import sys
from collections import namedtuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

SIM_EXE = P.work('bd', 'installed', 'SIM.EXE')
HUD_DAT = P.work('bd', 'installed', 'DTS', 'HUD.DAT')
VA_BASE = 0x69CD                       # SIM.EXE: VA = file offset - 0x69CD
CANVAS = (320, 200)
SCREEN_CENTRE = (160, 100)             # viewport origin -(w/2, h/2), 0x1c79..0x1cb0

HUD_DAT_TAG = 0x01F40000               # HudPosition class tag, 0x24270
HUD_DAT_SIZE = 0x85                    # payload bytes, 0x2427c
HUD_POINTS = 15                        # 0x24383 loop bound / 0x78 bytes at 0x2429c
HUD_FLAGS = 13                         # 0xd bytes at 0x242ac

# Palette indices used by the HUD (NRMPAL.DPL)
BLACK, BLUE, LIGHT_BLUE, GREEN, DARK_GREEN = 0, 1, 3, 4, 5
RED, DARK_RED, YELLOW, DARK_YELLOW = 7, 9, 10, 12
DIM_GREEN = 6

# Damage / heat colour ramp shared by WeaponButton (0x1d42a), Damage (0x1c4a9) and Shields (0x217f2)
DAMAGE_GREEN_BELOW = 100
DAMAGE_YELLOW_BELOW = 180
SHIELD_GREEN_FROM = 180                # 0x215aa: level >= 0xb4 green, >= 0x64 yellow, else red
SHIELD_YELLOW_FROM = 100

# Stroke font (SFont, 0x3b094)
FONT_FIRST = 0x21
FONT_COUNT = 0x3a
FONT_GLYPHS = 0x7ea90
FONT_W, FONT_H, FONT_SPACING = 3, 5, 1

# String tables (u32 pointer arrays)
CAMERA_NAMES = (0x771a4, 5)            # COCKPIT, PROBE 1..4
TARGET_TYPES = (0x77208, 11)           # HERC, PROBE, OBSTACLE ...
PROBE_MODES = (0x77240, 3)             # NON, FRE, ATT
CONTROL_MODES = (0x77358, 3)           # HERC, TURRET, PROBE
TARGET_LABELS = (0x77278, 2)           # TARGET:, DIST:
PREF_LABELS = (0x772b8, 6)
PREF_ONOFF = (0x772d8, 2)
PREF_MUSIC = (0x7730c, 5)
PREF_DETAIL = (0x77334, 4)
WEAPON_NAMES = (0x7744c, 32)           # by weapon type id, used by WeaponButton 0x1cdc1
COMPONENT_NAMES = (0x8063c, 26)        # logical part names, Damage 0x1c518
MESSAGE_TABLE = 0x76830                # 32 x {u32 text, s32 sound, u8 ?, u8 urgent, s32 repeat, s32 last}
MESSAGE_RECORD = 18
MESSAGE_COUNT = 32

HERC_TABLE = 0x82ffc                   # 10 Herc records of 0x364 bytes (docs/formats/battledrome.md 7)
HERC_RECORD = 0x364
HERC_COUNT = 10
HERC_DIAGRAM = 0xf4                    # {u32 count, u32 ptr -> count x {kind, x, y, part}}, read at 0x574b
EYE_LOGICAL_PART = 0x12                # 0x5f2d

Widget = namedtuple('Widget', 'index cls hud_offset size ctor resize render kind')
# HUD.DAT index order = Hud offset order of 0x234a4; size = constructor rect (x1-x0+1, y1-y0+1)
WIDGETS = [
    Widget(0, 'CameraSpinners', 0x15c, (47, 41), 0x16bb4, 0x17278, 0x175b0, 'camera_heading'),
    Widget(1, 'Energy', 0x1125, (60, 23), 0x1d724, 0x1e7e4, 0x1e91c, 'energy'),
    Widget(2, 'MechSpinners', 0x36a, (57, 41), 0x17880, 0x18504, 0x18c00, 'throttle'),
    Widget(3, 'Control', 0x9c0, (60, 7), 0x1b664, 0x1b97c, 0x1bc24, 'control_mode'),
    Widget(4, 'TDButton', 0x772, (97, 7), 0x192b8, 0x19d50, 0x19ff0, 'target_info'),
    Widget(5, 'ActiveCam', 0x8e3, (60, 7), 0x1aef8, 0x1b1f8, 0x1b4a0, 'active_camera'),
    Widget(6, 'CamButton', 0xa98, (60, 39), 0x1a124, 0x1a858, 0x1ac30, 'camera_list'),
    Widget(7, 'WeaponButton', 0xd29, (60, 47), 0x1c56c, 0x1cfd8, 0x1d320, 'weapons'),
    Widget(8, 'TTButton', 0x12c7, (179, 3), 0x1ee88, 0x1f164, 0x1f418, 'torso_twist'),
    Widget(9, 'VTButton', 0x176e, (3, 73), 0x1f598, 0x1f874, 0x1fb24, 'torso_pitch'),
    Widget(10, 'Shields', 0x2143, (60, 48), 0x20808, 0x20b3c, 0x21518, 'shields'),
    Widget(11, 'Damage', 0x229d, (151, 61), 0x1bde4, 0x1c194, 0x1c2e8, 'damage_list'),
    Widget(12, 'ChatBox', 0x1c15, (283, 7), 0x1fca4, 0x1ff98, 0x20148, 'messages'),
    Widget(13, 'PrefBox', 0x1e3d, (84, 114), 0x218c0, 0x222f4, 0x228f0, 'preferences'),
    Widget(14, 'ChatInputBox', 0x1d2f, (283, 7), 0x2020c, 0x20560, 0x20710, 'chat_input'),
]
ALWAYS_HIDDEN = {'VTButton'}           # not in Hud::render's list (0x23c34..0x23d97)


class SimImage:
    """SIM.EXE bytes addressed by virtual address."""

    def __init__(self, data):
        self.data = data

    def u32(self, va):
        return struct.unpack_from('<I', self.data, va + VA_BASE)[0]

    def s32(self, va):
        return struct.unpack_from('<i', self.data, va + VA_BASE)[0]

    def points(self, va, start, count):
        """`count` {s32 x, s32 y} points from the table at `va`, starting at entry `start`."""
        return [list(struct.unpack_from('<2i', self.data, va + VA_BASE + 8 * (start + i))) for i in range(count)]

    def cstr(self, va):
        p = va + VA_BASE
        return self.data[p:self.data.index(b'\0', p)].decode('latin1')

    def string_table(self, table):
        va, count = table
        return [self.cstr(self.u32(va + 4 * i)) for i in range(count)]


def load_image(path=SIM_EXE):
    with open(path, 'rb') as f:
        return SimImage(f.read())


# ---------------------------------------------------------------- HUD.DAT

HudLayout = namedtuple('HudLayout', 'positions visible')


def read_hud_dat(data):
    """HUD.DAT -> HudLayout(15 [x, y] window corners, 13 visibility flags)."""
    tag, size = struct.unpack_from('<II', data, 0)
    if tag != HUD_DAT_TAG or size != HUD_DAT_SIZE:
        raise ValueError('not a HudPosition item: tag %#x size %#x' % (tag, size))
    coords = struct.unpack_from('<%di' % (2 * HUD_POINTS), data, 8)
    flags = data[8 + 8 * HUD_POINTS:8 + 8 * HUD_POINTS + HUD_FLAGS]
    return HudLayout([list(coords[2 * i:2 * i + 2]) for i in range(HUD_POINTS)], [bool(b) for b in flags])


def load_hud_dat(path=HUD_DAT):
    with open(path, 'rb') as f:
        return read_hud_dat(f.read())


# ---------------------------------------------------------------- stroke font

def read_stroke_font(img):
    """{char code: [[x0, y0, x1, y1], ...]} with y up from the baseline (glyph table 0x7ea90)."""
    glyphs = {}
    for i in range(FONT_COUNT):
        count, ptr = img.u32(FONT_GLYPHS + 8 * i), img.u32(FONT_GLYPHS + 8 * i + 4)
        segs = [list(struct.unpack_from('<4h', img.data, ptr + VA_BASE + 8 * k)) for k in range(count)] if ptr else []
        glyphs[FONT_FIRST + i] = segs
    return glyphs


# ---------------------------------------------------------------- primitives (window-local coordinates)

def polyline(points, color):
    return {'op': 'polyline', 'points': points, 'color': color}


def line(p0, p1, color):
    return {'op': 'line', 'points': [list(p0), list(p1)], 'color': color}


def fill(rect, color):
    return {'op': 'fill', 'rect': list(rect), 'color': color}


def frame(rect, color):
    """Rectangle drawn with fill type 4 (hollow)."""
    return {'op': 'frame', 'rect': list(rect), 'color': color}


def ellipse(rect, color):
    """Ellipse inscribed in rect, fill type 4 = hollow (0x4a7cc)."""
    return {'op': 'ellipse', 'rect': list(rect), 'color': color}


def polygon(points, color):
    return {'op': 'polygon', 'points': [list(p) for p in points], 'color': color}


def text(s, at, color):
    """`at` = [x, baseline y] of the first character."""
    return {'op': 'text', 'text': s, 'at': list(at), 'color': color}


def rect_of(points):
    (x0, y0), (x1, y1) = points
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


def rows_of(table, rows, points_per_row, color, img):
    return [polyline(img.points(table, k * points_per_row, points_per_row), color) for k in range(rows)]


# ---------------------------------------------------------------- widgets

ROW_PITCH = 8                          # list rows (Energy 0x1e7e4, CamButton, WeaponButton): baseline 5 + 8k
FIRST_BASELINE = 5


def make_camera_heading(img):
    """CameraSpinners: view-direction compass (0x175b0)."""
    return {
        'shapes': [polyline(img.points(0x774d0, 0, 9), BLUE),          # octagon, colour [+0x62] = 1 (0x16f97)
                   polyline(img.points(0x774d0, 9, 11), DARK_GREEN),   # field-of-view wedge, [+0x72] = 5
                   polyline(img.points(0x774d0, 20, 3), DARK_GREEN),
                   ellipse(rect_of(img.points(0x77588, 0, 2)), GREEN),  # [+0x66] = 4, type 4 = hollow
                   ellipse(rect_of(img.points(0x77588, 2, 2)), DARK_GREEN),
                   ellipse(rect_of(img.points(0x77588, 4, 2)), YELLOW)],
        'centre': [23, 20],                                            # +0x19a (0x16f46)
        'pointers': [
            {'role': 'view', 'points': img.points(0x770cc, 0, 3), 'color': YELLOW, 'y_scale': 0.9,
             'note': 'heading of the camera relative to the Herc (0x58aa); y follows the ellipse (0x17020)'},
            {'role': 'probe', 'points': img.points(0x770e4, 0, 3), 'color': GREEN,
             'note': 'second heading, only when viewing through a probe ([user+0x2c], 0x5938), else 0'}],
        'angle_units': 'u16, 65536 = full turn, 0 = up, clockwise (0x17020)',
        'evidence': 'ctor 0x16bb4 rect (194,152)-(240,192); resize 0x17278; render 0x175b0; set 0x17220 from 0x594f',
        'confidence': 'H',
    }


def make_energy(img):
    """Energy: SHIELDS / ENGINE / WEAPONS power sliders (0x1e91c)."""
    labels = ['SHIELDS', 'ENGINE', 'WEAPONS']                         # 0x78184, 0x7818c, 0x78193
    return {
        'shapes': rows_of(0x77af0, 3, 9, BLUE, img),
        'rows': [{'label': s, 'baseline': FIRST_BASELINE + ROW_PITCH * k, 'label_x': 3} for k, s in enumerate(labels)],
        'colors': {'label': YELLOW, 'label_active': BLUE, 'box': BLUE, 'bar': YELLOW},
        'bar': {'x': 39, 'line_dy': -2, 'knob': [3, 5], 'px_per_level': 1 / 15.0,
                'level_max': 255, 'level_default': 85, 'levels_sum': 255},
        'note': 'levels 0..255 always sum to 255: moving one re-balances the other two (0x1dad4..0x1dccc); '
                'bar = line (39, y-2)-(39+level/15, y-2) + knob rect (39+len, y-4)-(41+len, y); clicking a label '
                'toggles its selection (blue, 0x1e609); release sends events 0x2d/0x2e/0x2f (0x1e6a9)',
        'evidence': 'ctor 0x1d724 rect (9,100)-(68,122); resize 0x1e7e4 (label x 3, rows 5/13/21, /15, x 39); '
                    'render 0x1e91c',
        'confidence': 'H',
    }


def make_throttle(img):
    """MechSpinners: Herc orientation spinner + throttle scale (0x18c00)."""
    return {
        'shapes': [polyline(img.points(0x775b8, 0, 9), BLUE), polyline(img.points(0x775b8, 9, 11), DARK_GREEN),
                   polyline(img.points(0x775b8, 20, 3), DARK_GREEN),
                   ellipse(rect_of(img.points(0x77670, 0, 2)), DARK_GREEN),
                   ellipse(rect_of(img.points(0x77670, 2, 2)), YELLOW),
                   polyline(img.points(0x77bc8, 0, 6), BLUE), polyline(img.points(0x77bc8, 6, 2), BLUE)],
        'centre': [23, 20],
        'pointers': [
            {'role': 'view', 'points': img.points(0x770fc, 0, 3), 'color': YELLOW, 'y_scale': 0.9, 'angle_arg': 3},
            {'role': 'chassis', 'polygons': [img.points(0x7712c, 0, 3), img.points(0x77144, 0, 3)], 'color': GREEN,
             'angle_arg': 1},
            {'role': 'torso', 'points': img.points(0x77114, 0, 3), 'color': YELLOW, 'angle_arg': 2}],
        'angle_units': 'u16, 65536 = full turn, 0 = up, clockwise; set by 0x1846c(a, b, c) from 0x5a5b',
        'throttle': {
            'range': [-127, 127],
            'forward': {'marker_base_y': '19 - floor(12*t/127), min 8', 'tip_dy': -3, 'x': [48, 54], 'tip_x': 51,
                        'ticks_y': [18, 16, 14, 12, 10], 'tick_rule': 'tick y > marker base'},
            'reverse': {'marker_base_y': '22 + floor(11*|t|/127), max 32', 'tip_dy': 3, 'x': [48, 54], 'tip_x': 51,
                        'ticks_y': [22, 24, 26, 28, 30], 'tick_rule': 'tick y < marker base'},
            'forward_button': {'polygon': [[47, 6], [43, 1], [51, 1], [56, 6]], 'label': 'F', 'at': [48, 6]},
            'reverse_button': {'polygon': [[43, 39], [47, 35], [55, 35], [51, 39]], 'label': 'R', 'at': [48, 39]},
            'colors': {'marker': YELLOW, 'tick': YELLOW, 'button': GREEN, 'label_active': BLACK, 'label': GREEN},
            'note': 't = 0: no marker; the button of the current direction is filled green and its letter black'},
        'evidence': 'ctor 0x17880 rect (134,152)-(190,192); resize 0x18504; render 0x18c00; throttle 0x1809c / '
                    'mouse 0x18180; angles 0x1846c',
        'confidence': 'H',
        'confidence_meaning': 'L (which game angle drives each pointer)',
    }


def make_control_mode(img):
    """Control: what the player steers (0x1bc24)."""
    return {
        'shapes': [fill([1, 1, 21, 5], YELLOW), fill([22, 1, 58, 5], GREEN), text('CTRL:', [3, 5], BLACK),
                   polyline(img.points(0x777a0, 0, 7), BLUE)],
        'value': {'at': [30, 5], 'color': BLACK, 'values': img.string_table(CONTROL_MODES)},
        'evidence': 'ctor 0x1b664 rect (75,11)-(134,17); render 0x1bc24; "CTRL:" 0x780ee; set 0x1b948 (table 0x77358)',
        'confidence': 'H',
    }


def make_target_info(img):
    """TDButton: target type and distance (0x19ff0)."""
    target, dist = img.string_table(TARGET_LABELS)
    return {
        'shapes': [polyline(img.points(0x77740, 0, 5), BLUE), text(target, [2, 5], LIGHT_BLUE),
                   text(dist, [64, 5], LIGHT_BLUE)],
        'name': {'at': [29, 5], 'color': YELLOW, 'values': img.string_table(TARGET_TYPES), 'none': ''},
        'distance': {'at': [83, 5], 'color': YELLOW, 'format': 'integer, clamped to -999..9999 (0x19c7c)'},
        'note': 'no target: empty name and distance (0x5da0); TSBase field +0x49 = 7 if the target is the '
                'aimed object [herc+0x180] else 4 (0x5d76), consumer not found',
        'evidence': 'ctor 0x192b8 rect (194,11)-(290,17); render 0x19ff0 (class record 0x78034 +8); set 0x19bf4 / 0x19ce8',
        'confidence': 'H',
    }


def make_active_camera(img):
    """ActiveCam: name and probe mode of the camera being viewed (0x1b4a0)."""
    return {
        'shapes': [fill([1, 1, 38, 5], YELLOW), fill([39, 1, 58, 5], GREEN), polyline(img.points(0x77768, 0, 7), BLUE)],
        'camera': {'at': [3, 5], 'color': BLACK, 'values': img.string_table(CAMERA_NAMES)},
        'mode': {'at': [43, 5], 'color': BLACK, 'values': img.string_table(PROBE_MODES), 'cockpit': ''},
        'evidence': 'ctor 0x1aef8 rect (13,11)-(72,17); render 0x1b4a0; texts copied by CamButton 0x1a5c8 / 0x1a4fc',
        'confidence': 'H',
    }


def make_camera_list(img):
    """CamButton: COCKPIT + 4 probe cameras with probe mode (0x1ac30)."""
    return {
        'shapes': rows_of(0x777d8, 5, 9, BLUE, img),
        'rows': [{'name': s, 'baseline': FIRST_BASELINE + ROW_PITCH * k} for k, s in
                 enumerate(img.string_table(CAMERA_NAMES))],
        'name_x': 3, 'mode_x': 43, 'mode_values': img.string_table(PROBE_MODES),
        'active_fills': [[1, -4, 37, 0], [39, -4, 58, 0]],
        'colors': {'name': YELLOW, 'mode': GREEN, 'active_text': BLACK, 'active_name_fill': YELLOW,
                   'active_mode_fill': GREEN, 'box': BLUE},
        'note': 'active fills are relative to the row baseline; clicking a probe row toggles FRE / ATT (0x1a68c)',
        'evidence': 'ctor 0x1a124 rect (243,152)-(302,190); resize 0x1a858; render 0x1ac30 / row 0x1a7f4 / fill 0x1a704',
        'confidence': 'H',
    }


def make_weapons(img):
    """WeaponButton: six weapon rows (0x1d320)."""
    return {
        'shapes': rows_of(0x77940, 6, 9, BLUE, img),
        'rows': [{'baseline': FIRST_BASELINE + ROW_PITCH * k} for k in range(6)],
        'number': {'x': 3, 'color': YELLOW, 'format': 'slot + 1'},
        'name': {'x': 8, 'values': img.string_table(WEAPON_NAMES)},
        'damage_colors': {'below_100': GREEN, 'below_180': YELLOW, 'else': RED},
        'damage_colors_dim': {'below_100': DIM_GREEN, 'below_180': DARK_YELLOW, 'else': DARK_RED},
        'selected': {'fill': [7, -4, 41, 0], 'fill_color': 'damage colour', 'name_color': BLACK},
        'ammo': {'at_x': 44, 'color': GREEN, 'color_flag': LIGHT_BLUE, 'format': '%d'},
        'charge': {'x0': 43, 'x_end': '43 + charge*15/256 (charge 0..256)', 'step': 2, 'y': [-4, 0],
                   'color': GREEN, 'color_flag': LIGHT_BLUE},
        'note': 'name colour = damage ramp of the pod part (0xb1f8, logical part 11+mount) bright when '
                '[slot+0xa] (herc byte +0x26d+mount) else dim; energy weapons show charge ticks, ammo weapons '
                'the count; colour_flag when 0x98e8 is false; click selects the row (0x1ccaf)',
        'evidence': 'ctor 0x1c56c rect (9,144)-(68,190); render 0x1d320; slot 0x1cd60 ("%d %s"); charge 0x1cb00; '
                    'bar 0x1ce60; update 0x5ad8..0x5b81',
        'confidence': 'H',
    }


def make_torso_twist(img):
    """TTButton: horizontal torso-twist track (0x1f418)."""
    return {
        'shapes': [fill([1, 0, 177, 1], GREEN), polyline(img.points(0x77c08, 0, 4), BLUE)],
        'marker': {'rect': [83, 0, 93, 1], 'color': YELLOW, 'axis': 'x', 'centred_x': 83},
        'note': 'track rect from 0x96fe0 (0x24456); marker x computed with float code at 0x1f209 (L)',
        'evidence': 'ctor 0x1ee88 rect (70,14)-(248,16); render 0x1f418',
        'confidence': 'M',
    }


def make_torso_pitch(img):
    """VTButton: vertical track, never drawn by Hud::render."""
    return {
        'shapes': [fill([0, 1, 1, 71], GREEN), polyline(img.points(0x77c28, 0, 4), BLUE)],
        'marker': {'rect': [0, 30, 1, 40], 'color': YELLOW, 'axis': 'y'},
        'evidence': 'ctor 0x1f598 rect (11,38)-(13,110); render 0x1fb24 (not called by 0x23a40)',
        'confidence': 'M',
    }


SHIELD_PART_LINES = {   # 0x20db0, 0x20ea0, 0x20f94, 0x21088, 0x2117c, 0x21270, 0x213c4 (jump table 0x78220)
    0: [[0, 0, 4, 0], [4, 0, 4, 2], [4, 2, 0, 2], [0, 2, 0, 0]],
    1: [[1, 0, 4, 0], [5, 1, 5, 4], [0, 1, 0, 4], [1, 5, 4, 5]],
    2: [[1, 0, 7, 0], [8, 1, 8, 3], [1, 4, 7, 4], [0, 1, 0, 3]],
    3: [[1, 0, 21, 0], [22, 1, 22, 7], [1, 8, 21, 8], [0, 1, 0, 7]],
    4: [[1, 0, 9, 0], [10, 1, 10, 4], [1, 5, 9, 5], [0, 1, 0, 4]],
    5: [[1, 0, 4, 0], [5, 1, 5, 18], [2, 19, 4, 19], [1, 6, 1, 18], [0, 1, 0, 5]],
    6: [[1, 0, 4, 0], [5, 1, 5, 5], [4, 6, 4, 18], [1, 19, 3, 19], [0, 1, 0, 18]],
}
SHIELD_TICKS = 19                       # y = 39, 37, ... 3


def read_herc_diagrams(img):
    """Per Herc type: Shields front-view diagram entries {kind, at, part} (Herc record +0xf4)."""
    out = []
    for k in range(HERC_COUNT):
        rec = HERC_TABLE + HERC_RECORD * k + HERC_DIAGRAM
        count, ptr = img.u32(rec), img.u32(rec + 4)
        entries = [struct.unpack_from('<4i', img.data, ptr + VA_BASE + 16 * i) for i in range(count)]
        out.append([{'kind': e[0], 'at': [e[1], e[2]], 'part': e[3]} for e in entries])
    return out


def make_shields(img):
    """Shields: shield bar + Herc damage diagram (0x21518)."""
    return {
        'shapes': [polyline(img.points(0x77eb8, 0, 13), BLUE), text('SHIELD', [17, 45], BLUE)],
        'bar': {'ticks_y': [39 - 2 * i for i in range(SHIELD_TICKS)], 'x0': 51, 'x1_rule': 'min(56, 48 + y)',
                'visible_rule': 'y > (255 - level) * 39 // 255', 'base_polygon': img.points(0x7715c, 0, 4),
                'base_rule': 'level > 0', 'level_max': 255,
                'colors': {'from_180': GREEN, 'from_100': YELLOW, 'else': RED}},
        'diagram': {'part_lines': {str(k): v for k, v in SHIELD_PART_LINES.items()},
                    'by_herc': read_herc_diagrams(img),
                    'color_rule': 'part damage 0..255 (0xb298): < 100 green, < 180 yellow, else red'},
        'evidence': 'ctor 0x20808 rect (71,144)-(130,191); render 0x21518; level 0x20ae0; part damage 0x20ab0; '
                    'diagram table Herc+0xf4 (0x574b)',
        'confidence': 'H',
    }


def make_damage_list(img):
    """Damage: two-column component list, hidden by default (0x1c2e8)."""
    return {
        'shapes': [line([75, 0], [75, 60], BLUE), line([0, 0], [150, 0], BLUE), line([150, 0], [150, 60], BLUE),
                   line([0, 0], [0, 60], BLUE), line([0, 60], [150, 60], BLUE)],
        'columns': [{'name_x': 3, 'value_x': 60, 'rows': 9}, {'name_x': 80, 'value_x': 132}],
        'first_baseline': 8, 'row_pitch': 6,
        'names': img.string_table(COMPONENT_NAMES),
        'value_format': '%d = 100 - damage*100/256 (0x1c16e)',
        'colors': {'below_100': GREEN, 'below_180': YELLOW, 'else': RED},
        'evidence': 'ctor 0x1bde4 rect (100,50)-(250,110); render 0x1c2e8; add 0x1c0c0; value 0x1c0f0',
        'confidence': 'H',
    }


def make_messages(img):
    """ChatBox: one-line message strip (0x20148)."""
    return {
        'shapes': [polyline(img.points(0x77cb8, 0, 5), BLUE)],
        'text': {'at': [8, 5], 'color_normal': GREEN, 'color_urgent': RED, 'lifetime_ticks': 0x500},
        'note': 'MessageManager (0x14978) shows MSGTEXT.BIN line n with the colour of table 0x76830 byte +9; '
                'chat lines are formatted "%s: %s" (0x23bd2); the text clears after 0x500 ticks of [0xa1168]',
        'evidence': 'ctor 0x1fca4 rect (14,4)-(296,10); render 0x20148; set 0x1ff44',
        'confidence': 'H',
    }


def make_preferences(img):
    """PrefBox: in-sim preferences popup (0x228f0), shown with its default values."""
    title, sound, voices, music, detail, vol = img.string_table(PREF_LABELS)
    shapes = [polyline(img.points(0x77d08, 0, 6), BLUE), polyline(img.points(0x77d08, 6, 4), BLUE),
              polyline(img.points(0x77d08, 10, 4), BLUE)]
    shapes += [polyline(img.points(0x77d08, 14 + 5 * k, 5), BLUE) for k in range(4)]
    shapes += [polyline(img.points(0x77d08, 34 + 5 * k, 5), GREEN) for k in range(4)]
    shapes += [text(title, [16, 7], YELLOW), text(sound, [27, 31], YELLOW), text(voices, [27, 54], YELLOW),
               text(music, [16, 77], YELLOW), text(detail, [12, 100], YELLOW), text(vol, [66, 22], YELLOW)]
    shapes += [line([68, 74 - 6 * i], [69 + i, 74 - 6 * i], GREEN) for i in range(9)]
    shapes += [frame([68, 69, 83, 74], YELLOW), fill([69, 70, 82, 73], DARK_RED)]
    return {
        'shapes': shapes,
        'values': {'sound': img.string_table(PREF_ONOFF), 'voices': img.string_table(PREF_ONOFF),
                   'music': img.string_table(PREF_MUSIC), 'detail': img.string_table(PREF_DETAIL)},
        'value_baselines': [21, 44, 67, 90], 'value_color': GREEN,
        'note': 'values are centred in their boxes (default OFF at x 30, ROCK \'N ROLL at x 12); the volume knob '
                '(frame + dark red fill) slides on the green ramp',
        'evidence': 'ctor 0x218c0 rect (200,26)-(283,139); resize 0x222f4; render 0x228f0',
        'confidence': 'M',
    }


def make_chat_input(img):
    """ChatInputBox: chat entry line (0x20710)."""
    return {
        'shapes': [polyline(img.points(0x77ce0, 0, 5), BLUE)],
        'text': {'at': [8, 5], 'color': DARK_YELLOW},
        'cursor': {'color': YELLOW, 'rule': 'line x = 8 + text width + 1, from y 5 to 1'},
        'evidence': 'ctor 0x2020c rect (14,18)-(296,24); render 0x20710 (visible flag +0x45)',
        'confidence': 'H',
    }


BUILDERS = {
    'camera_heading': make_camera_heading, 'energy': make_energy, 'throttle': make_throttle,
    'control_mode': make_control_mode, 'target_info': make_target_info, 'active_camera': make_active_camera,
    'camera_list': make_camera_list, 'weapons': make_weapons, 'torso_twist': make_torso_twist,
    'torso_pitch': make_torso_pitch, 'shields': make_shields, 'damage_list': make_damage_list,
    'messages': make_messages, 'preferences': make_preferences, 'chat_input': make_chat_input,
}


def make_meter(img, widget, layout):
    x, y = layout.positions[widget.index]
    w, h = widget.size
    visible = widget.index < HUD_FLAGS and layout.visible[widget.index] and widget.cls not in ALWAYS_HIDDEN
    meter = {'kind': widget.kind, 'class': widget.cls, 'hud_dat_index': widget.index,
             'rect': [x, y, x + w - 1, y + h - 1], 'visible': visible, 'font': 'HUD',
             'code': {'ctor': hex(widget.ctor), 'resize': hex(widget.resize), 'render': hex(widget.render),
                      'hud_offset': hex(widget.hud_offset)}}
    meter.update(BUILDERS[widget.kind](img))
    meter.setdefault('colors', {})['shapes'] = sorted({s['color'] for s in meter['shapes']})
    return meter


# ---------------------------------------------------------------- reticle, banners, view

RETICLE_CROSS = [[[160, 95], [160, 105]], [[165, 100], [155, 100]]]                       # 0x243da..0x24420
RETICLE_DIAMOND = [[[155, 100], [160, 105]], [[160, 105], [165, 100]], [[165, 100], [160, 95]], [[160, 95], [155, 100]]]
RETICLE_COLOR = DARK_GREEN                                                                # {0, 5} at 0x23daa
WINNER_TITLE_Y = 0x4b                  # 0x23af9
WINNER_RESULT_Y = 0x6e                 # 0x23b62


def make_reticle():
    return {'kind': 'reticle', 'rect': [155, 95, 165, 105], 'visible': True, 'colors': {'line': RETICLE_COLOR},
            'shapes': [line(a, b, RETICLE_COLOR) for a, b in RETICLE_CROSS],
            'diamond_shapes': [line(a, b, RETICLE_COLOR) for a, b in RETICLE_DIAMOND],
            'note': 'cross when [Hud+0x4e] (cockpit camera, 0x5dc9: user+0x2c == 0), diamond otherwise',
            'evidence': 'points 0x243d4; Hud::render 0x23da4..0x23e43', 'confidence': 'H'}


def make_winner(sizes):
    """WINNER.DBA frames: 0 END OF MATCH, 1 YOU HAVE WON, 2 YOU HAVE LOST, 3 TELEPORTING."""
    def centred(frame, y):
        w, h = sizes[frame]
        x = (CANVAS[0] - w) // 2
        return {'frame': frame, 'rect': [x, y, x + w - 1, y + h - 1]}
    return {'kind': 'winner', 'dba': 'WINNER', 'visible': False, 'rect': centred(0, WINNER_TITLE_Y)['rect'],
            'frames': {'end_of_match': centred(0, WINNER_TITLE_Y), 'won': centred(1, WINNER_RESULT_Y),
                       'lost': centred(2, WINNER_RESULT_Y), 'teleporting': centred(3, WINNER_TITLE_Y)},
            'note': 'match over ([Hud+0x53]): END OF MATCH + (result 1 = won, 2 = lost, 0 = none) and no other '
                    'HUD; TELEPORTING is drawn over the normal HUD while [Hud+0x55]; x centred (0x3cac0 width)',
            'evidence': 'Hud::render 0x23a60..0x23b77, 0x23e46..0x23e8b', 'confidence': 'H'}


def make_view():
    return {'centre_row': SCREEN_CENTRE[1], 'centre': list(SCREEN_CENTRE),
            'viewport': [0, 0, CANVAS[0] - 1, CANVAS[1] - 1],
            'evidence': 'viewport 0x1c52..0x1cb0 (origin -(w/2), -(h/2)); reticle centre 0x243d4', 'confidence': 'H'}


EYE_RULE = ('DCS logical part 18 (last trailer entry {i32 ?, i32 node, i32 x,y,z}): eye = node world transform '
            'x (x, y, z); probe cameras use the probe transform (0x5eec, 0x5f2d push 0x12 -> 0x43f78)')

DRAW_ORDER = ['Energy', 'MechSpinners', 'TDButton', 'WeaponButton', 'Shields', 'Damage', 'TTButton',
              'CameraSpinners', 'CamButton', 'ChatBox', 'ChatInputBox', 'Control', 'ActiveCam', 'reticle',
              'teleporting', 'PrefBox']


def make_hud(img, layout, winner_sizes):
    meters = [make_meter(img, w, layout) for w in WIDGETS]
    meters += [make_reticle(), make_winner(winner_sizes)]
    return {'canvas': list(CANVAS), 'palette': 'palette.json', 'view': make_view(), 'meters': meters,
            'draw_order': DRAW_ORDER,
            'reduced_hud_hides': DRAW_ORDER[:7],
            'eye': EYE_RULE,
            'text_anchor': 'baseline: a text at [x, y] puts glyph rows y-4..y (font height 5, advance 4)',
            'source': 'SIM.EXE HUD (code\\hud.cpp) + DTS\\HUD.DAT, decoded by tools/bd_hud.py'}


def read_message_table(img):
    """32 x {text, sound, flag, urgent, repeat}: 0x76830, used by MessageManager 0x14978."""
    out = []
    for i in range(MESSAGE_COUNT):
        t, snd, flag, urgent, repeat, _last = struct.unpack_from('<IiBBii', img.data, MESSAGE_TABLE + VA_BASE + MESSAGE_RECORD * i)
        out.append({'text': t, 'sound': snd, 'flag': flag, 'urgent': bool(urgent), 'repeat_ticks': repeat})
    return out


def read_string_tables(img):
    tables = {'camera_names': CAMERA_NAMES, 'target_types': TARGET_TYPES, 'probe_modes': PROBE_MODES,
              'control_modes': CONTROL_MODES, 'target_labels': TARGET_LABELS, 'preference_labels': PREF_LABELS,
              'preference_on_off': PREF_ONOFF, 'music_types': PREF_MUSIC, 'detail_levels': PREF_DETAIL,
              'weapon_names': WEAPON_NAMES, 'component_names': COMPONENT_NAMES}
    return {k: img.string_table(v) for k, v in tables.items()}


def main():
    img = load_image()
    layout = load_hud_dat()
    for w in WIDGETS:
        m = make_meter(img, w, layout)
        print('%2d %-14s %-15s rect %-22s visible %s' % (w.index, w.cls, w.kind, m['rect'], m['visible']))


if __name__ == '__main__':
    main()
