"""Starsiege (1999, Darkstar) in-sim HUD: decoded layout, art and colours for a native redraw.

Reverse-engineered from starsiege/original/installed/Starsiege.exe (Win32 PE, image base 0x400000, Borland;
addresses are virtual addresses) and the unpacked shell.vol (starsiege/extracted/shell).  Confidence per
finding: H = read straight from code/data, M = inferred from code structure, L = estimate.

1. Meters, default layout and anchoring
   * HudManager meter table 0x6dc274: 18 rows x 28 bytes {id, gui tag, mode, f32, 3, IDSTR label, class name}
     (H).  id 1 radar (IDHUD_GEN_RADAR), 2 aim reticle, 3 weapon display, 4 hud select, 5 shields, 6 damage
     (self, "STATUS"), 7 target damage ("TARGET"), 8 sim prefs, 9 chat receive ("Mesgs:"), 12 internals,
     13..15 hud timers 1..3, 16 command orders.
   * Hud::HudLayout (hudLayout.prf, object id 0x27b): 18 records x 32 bytes at +0x4c {u8 visible, f32 fx,
     f32 fy, 5 x u32 meter state}; +0x28c = colour scheme.  Constructor 0x508b0c: every record visible=1,
     0; defaults 0x508b70 (H):  radar (0.90, 0.95) mode 2 | reticle (0.5, 0.5) | weapons (0.05, 0.35) |
     shields (0.10, 0.95) | damage (0.04, 0.02) mode 3 | target (0.96, 0.02) mode 6 | chat (0.5, 0.0) mode 2 |
     internals (0.95, 0.30) | timers (0.40 / 0.50 / 0.60, 0.26) | command (0.41, 0.65) | scheme 0.
   * Anchoring 0x50c174 (H): fx, fy are clamped to [0, 1]; meter top-left = (parent - extent) * f, truncated
     (0x6adc90 = __ftol).  So 0 = left/top edge, 1 = right/bottom edge, 0.5 = centred, at any resolution.
   * Resolution set 0x508aa0 (H): ResourceSet[1] (the *_high / un-suffixed art, hud_high fonts) when the sim
     canvas is >= 600 x 380, else ResourceSet[0] (*_low art, hud_low fonts).  640 x 480 uses the high set.
   * Meters created per vehicle (H for the calls, M for the class attribution via the vtables 0x6c7ad4 Herc,
     0x6b911c Tank, 0x6b9474 Flyer): Herc 0x49b4d8 and Tank 0x42f76d: reticle, radar, weapons, damage,
     target, internals, timers 3/2/1, command (only when 0x74d85c is set), shields (only when the vehicle has
     a shield, +0xa04).  Flyer 0x437e19: the same without internals and command.  Chat (id 9) is created by
     the HudManager itself (0x509549).  Timers stay empty until setHudTimer() (L).
2. How each meter draws (all bitmaps go through the translucent blitter with alpha 0.7: push 0x3f333333 +
   vtable +0x70 at 0x517a4f radar, 0x51b26d reticle, 0x51abdc shields, 0x522cd5 damage; M)
   * Reticle (HudMtrAimReticle, ctor 0x51aed8, render 0x51b0e0): meter covers the whole canvas (0x51b068);
     retical.pba frame drawn centred on the projected aim point (canvas centre when the torso is level,
     0x51b644).  Frame 2 = missile weapon (weapon data +0xd5) with a completed lock (0x46f1bc), frame 0 = lock
     weapon not locked; other weapons: frame 1 when the lead point lies within 12 px of the aim point on both
     axes (0x51b578), else frame 0 (H).
   * Lead (0x51b85c): lead.pba drawn at lead point + (-23, -26) (high) / (-11, -13) (low) (DisplayItems
     +0x2a8, H); frame 1 when the target is in range (flag [ebp-0x3d], M) else 0; a filled triangle in colour
     248 (radius 15, half-width 24... DisplayItems 15/24/3, M) rotated around it and the range "%.0fm" in the
     HUD font at lead + (18, -32) minus the text width (H).  A nav point marker "%s (%i m)" uses the same set.
   * Radar (HudMtrRadar, ctor 0x5148d0, wake 0x518310, render 0x517874): extent = radar bitmap + (35, 10)
     high / + (20, 7) low (0x726aac / 0x722cfc, H); the bitmap is drawn at meter + (35, 10).  Frame by mode
     (0x5178eb, H): mode 2 "With Backgnd 1" -> frame 1 (dark inner disc, default), mode 4 "With Backgnd 2" ->
     frame 2 (dark disc and ring), else frame 0.  Title "%s %0.0fm" (ACTIVE / PASSIVE, IDSTR 130189/130190,
     radar range +0x298) centred at bitmap + (91, -10) (H).  Contact colours by team (jump table 0x517ed1, H):
     team 0 -> 249 cyan, 1 -> 240 yellow, 2 -> 241 blue, 4 -> 242 red, 8 -> 243 purple; without teams enemy
     (flag 0x200) -> 242, others 249.  Speed "%0.0fKph" averaged over 4 frames (0x518043, H) and an arc gauge
     filled in colour 248 with "%0.0f%%" (0x5166b0, arc 3.03 -> 0.84 rad, value from vehicle +0x9c8; L: read
     as throttle).  The yellow (240) arc is baked into the art.  cwBlips.pba is never loaded by tag (L: unused).
   * Weapons (HudMtrWeapDisplay, ctor 0x51fab0, extent 0x51fd94, render 0x51fea8): DispConsts[2] (stride 0x28,
     high = {4, 5, -3, 15, 60, 60, 8, 4}); width = 4 * c3 + 4 * c0 + c4 + c5 = 196 (high) / 131 (low), height =
     (c6 + c1) * (weapons + 1) + c1 (+ extra rows).  Per weapon: name, three group circles (hud_circle_f when
     the weapon is in group k else hud_circle_o, k < 3, 0x52049e), ammo "%d" right aligned for ammo weapons
     (+0xd4), charge bar in 244/246, row backgrounds 247.  Fonts hud gray (unready) / dim / plain (M).
   * Shields (HudMtrShields, ctor 0x519350, wake 0x51acb0): extent = shields.bmp (128 x 101) (low: +3 px
     high).  The shield object at vehicle +0xa04 gives direction (+0x1c), focus 1 - (+0x24) and strength.
     0x51a258 recolours strCircle (48 ring segments, pixel value = segment 1..48, 1 = front, counter-clockwise)
     into the shield bitmap at (12, 14) high / (6, 7) low: segment distance e from the focus segment
     round(angle * 48 / 2pi) + 1; n1 = round(8 * focus), n2 = 24 - round(8 * (focus - 0.5)) (focus > 0.5),
     n3 = n1 + (n2 - n1) / 2; e <= n1 -> 246, e > n2 -> 247, e <= n3 -> 245, else 244 (all symmetric);
     strength 0 -> all 247, focus 0 -> all 244 (H).  Option 9 "With Background" (mode bit 2) uses
     shields_solid.bmp.  A focus marker with two "%0.0f" values (0x51a4e8) and an arc gauge with "%0.0f%%"
     (0x519cf0, arc 3.6 -> 6.15 rad, colours 248 / 247 / 245) complete it (M).
   * Damage self / target (HudMtrDamage ctor 0x520e40, HudMtrTarget ctor 0x523440): a 64 x 64 offscreen 3D
     view of the vehicle shape lit grey (0.7, 0x522646) inside dam_self / dam_tar.bmp drawn at (2, 30) high
     / (2, 15) low (target (-2, 30) / (-1, 15)), label STATUS / TARGET at (10, 1) high; extent = (bitmap w + 2,
     font height + bitmap h + 30 + 2) (0x52157b, H).  Options 2 "Rotate Only", 3 "Animate Only", 4 "Rot and
     Anim" (self, default 3) and 5 "Track Only", 6 "Track and Anim" (target, default 6).  How component damage
     tints the model was not traced (L).
   * Internals (HudMtrIntDamage, ctor 0x523a30): text list, title "Internals Status:", width 210 high / 160
     low (0x523ad5), height from the line count (0x523df0) -> L estimate.
   * Timers (HudMtrTimer, ctor 0x525bac): one text line in hud_dim, width from the text (0x5263d2) -> L.
   * Chat receive (HudMtrChatRecieve, ctor 0x5246b8): sizes 400 x 39 / 83 / 116 high, 310 x 31 / 63 / 87
     low, picked by the saved size index (default 0) (0x5249a0, H); fonts gray / dim / plain.
   * Command (HudMtrCommand, ctor 0x526e00): order menu, max 280 x 160 high / 160 x 120 low (L).
   * Not found as separate meters: heading/compass, altitude, energy/reactor bars.  Reactor/engine/sensor
     state is text in the internals list (IDSTR_V_* 130215..) (M).
3. Colours (HudPalModCtrl, ctor 0x50bdd0; apply 0x50be7c, H): written into the current screen palette (PiDX
   0xffffffff, the id every HUD bitmap carries): fixed table 0x6dd184 {240 yellow, 241 blue, 242 red, 243
   purple, 249 cyan, 250 orange, 252, 253 greys} plus scheme table 0x6dd1c4 (8 schemes x 6 entries for 244,
   245, 246, 247, 248, 251); the importer reads both from the user's exe (read_hud_colors).  Scheme = HudLayout +0x28c, default 0 (green); "Cycle Colors" (IDSTR 130052)
   steps it (0x50c040).  Slots 236..239 stay world colours.  No human / cybrid difference in HUD colours or art
   (no faction test in the HUD code; same scheme default) (M).  Font colours: plain 246, dim 245, gray 251,
   yellow 240, blue 241, red 242, purple 243 (PFT header colour, H).
4. First-person view (H unless noted)
   * Eye node 0x471520: first node named "cockpit" (then cockpit1.. are collected for the detail levels), else
     "head0"; head0.. head4 collected too.  Herc 0x4a33c6 additionally looks up "cam" / "camera"; when found it
     is the eye node (0x4a2e60).  Tank 0x430df4 / Flyer 0x439368 use the cockpit/head0 node.  Eye = node
     transform * (eye rotation +0x45c, translation +0x4e0); +0x4e0 = hercCpit / tankCpit / flyerCpit (vehicle
     data +0x3c..+0x44) = an offset in that node's frame (Darkstar: x right, y forward, z up, metres).
   * Cockpit mesh 0x481fc0: in the first-person view the shape's Seq*_cockpit sequence is set to 1.0 on the
     cockpit / head nodes of the current detail level (0.0 in the external view).  Its object keyframes
     toggle visibility: head0.. visible at 0, hidden at >= 0.5; cockpit.. hidden at 0, visible at >= 0.5.
     So the sim draws the textured cockpit interior (tr_/cy_/rb_/ha_cpit.bmp) from the first-person eye.
   * translucentCockpit() (console command 0x29, handler 0x415c03) sets vehicle data +0x112; on spawn
     (0x4684b3) it clears shape instance byte +0x9c.  Only cin_apoc / cin_basl use it (L: meaning of +0x9c).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import darkstar_gfx as G  # noqa: E402

CANVAS = (640, 480)
HIGH_RES_MIN = (600, 380)            # 0x508ae9 / 0x508af5: canvas >= 600 x 380 -> ResourceSet[1]
TRANSLUCENT_ALPHA = 0.7              # push 0x3f333333 before every meter blit (0x517a4f)

# Palette slots written by HudPalModCtrl::setScheme 0x50be7c; their RGB values are read from the user's
# Starsiege.exe (read_hud_colors): fixed table 0x6dd184, scheme table 0x6dd1c4, records {u32 slot, u8 r, g, b, 0}.
FIXED_SLOTS = (240, 241, 242, 243, 249, 250, 252, 253)
SCHEME_SLOTS = (244, 245, 246, 247, 248, 251)
SCHEME_COUNT = 8                     # 0x50be82: cmp edx, 8 (a larger scheme index wraps to 0)
FIXED_TABLE_VA = 0x6dd184
SCHEME_TABLE_VA = 0x6dd1c4
COLOR_RECORD = struct.Struct('<I3Bx')
HUD_COLOR_CODE = {                   # setScheme instructions that index the two tables (build check)
    0x50be82: bytes.fromhex('83fa087c02'),     # cmp edx, 8; jl
    0x50bed9: bytes.fromhex('81c284d16d00'),   # add edx, 0x6dd184
    0x50befa: bytes.fromhex('83f8087cd2'),     # cmp eax, 8 (fixed records); jl
    0x50bf17: bytes.fromhex('81c2c4d16d00'),   # add edx, 0x6dd1c4
    0x50bf38: bytes.fromhex('83f8067cc4'),     # cmp eax, 6 (records per scheme); jl
}
DEFAULT_SCHEME = 0                  # HudLayout +0x28c = 0 (0x508c85)
SCREEN_PALETTE_ID = 0xFFFFFFFF       # PiDX of every HUD bitmap; the world PPL palette holding the HUD slots

# Palette roles (indices) used by the meters
COLOR_DIM, COLOR_MID, COLOR_BRIGHT, COLOR_BACK, COLOR_ACCENT = 244, 245, 246, 247, 248
TEAM_COLORS = {0: 249, 1: 240, 2: 241, 4: 242, 8: 243}        # radar contact colour by team, 0x517ed1
ENEMY_COLOR, NEUTRAL_COLOR = 242, 249                          # no-team games, 0x517f6c

# PFT colour variants (header +0x20) -> HUD font names (Gui.Strings IDFNT_HUD_HIGH_RES_*)
HIGH_FONTS = {'HUD_HIGH': 'hud_high.pft', 'HUD_HIGH_DIM': 'hud_high_dim.pft', 'HUD_HIGH_GRAY': 'hud_high_gray.pft',
              'HUD_HIGH_YELLOW': 'hud_high_yellow.pft', 'HUD_HIGH_BLUE': 'hud_high_blue.pft',
              'HUD_HIGH_PURPLE': 'hud_high_purple.pft', 'HUD_HIGH_RED': 'hud_high_red.pft',
              'HUD_HIGH_I': 'hud_high_i.pft'}
PFT_SHEET_FILL = 252                 # unused glyph-sheet area in every PFT
GLYPH_SPACING = 1                    # L: glyph cells are packed tight; 1 px gap assumed between characters

# High-res art the meters load (tag -> file, Gui.Strings.cs); single bitmaps are 1-frame arrays
HIGH_ART = {
    'RETICAL': 'retical.pba', 'LEAD': 'lead.pba', 'RADAR_HIGH': 'radar_high.pba', 'CWBLIPS': 'cwBlips.pba',
    'SHIELDS': 'shields.bmp', 'SHIELDS_SOLID': 'shields_solid.bmp', 'STRCIRCLE': 'strCircle.bmp',
    'DAM_SELF': 'dam_self.bmp', 'DAM_TAR': 'dam_tar.bmp', 'HUD_CIRCLE_O': 'hud_circle_o.bmp',
    'HUD_CIRCLE_F': 'hud_circle_f.bmp', 'LIGHTNING_HIGH': 'lightning_high.bmp', 'SLIDER_HUD': 'slider_hud.pba',
    'SCROLLHUD': 'scrollHud.pba', 'SORT_ARROW_HUD': 'sort_arrow_hud.bmp', 'TRANSMIT': 'transmit.bmp',
    'ICON_NAV_BLUE': 'icon_nav_blue.bmp', 'ICON_NAV_YELO': 'icon_nav_yelo.bmp', 'ICON_NAV_RED': 'icon_nav_red.bmp',
    'ICON_NAV_PRPL': 'icon_nav_prpl.bmp', 'PING_GREEN': 'ping_green.bmp', 'PING_YELLOW': 'ping_yellow.bmp',
    'PING_RED': 'ping_red.bmp', 'BUT_HUD_BACK': 'but_hud_back.pba', 'BUT_HUD_CENTER': 'but_hud_center.pba',
    'BUT_HUD_ZOOMIN': 'but_hud_zoomin.pba', 'BUT_HUD_ZOOMOUT': 'but_hud_zoomout.pba',
}

# HudLayout defaults 0x508b70: meter id -> (fx, fy, mode)
LAYOUT_DEFAULTS = {1: (0.90, 0.95, 2), 2: (0.5, 0.5, 0), 3: (0.05, 0.35, 0), 5: (0.10, 0.95, 0),
                   6: (0.04, 0.02, 3), 7: (0.96, 0.02, 6), 9: (0.5, 0.0, 2), 12: (0.95, 0.30, 0),
                   13: (0.40, 0.26, 0), 14: (0.50, 0.26, 0), 15: (0.60, 0.26, 0), 16: (0.41, 0.65, 0)}

RADAR_ART_OFFSET = (35, 10)          # 0x726aac / 0x726ab0: extent = art + offset, art drawn at the offset
RADAR_TITLE_CENTRE = (91, -10)       # 0x726a9c / 0x726aa0, relative to the art
RADAR_FRAME_BY_MODE = {2: 1, 4: 2}   # 0x5178eb; any other mode -> frame 0
WEAPON_CONSTS = {'c0': 4, 'c1': 5, 'c2': -3, 'c3': 15, 'c4': 60, 'c5': 60, 'c6': 8, 'c7': 4}  # 0x51fba1
WEAPON_GROUPS = 3                    # group circles per row, 0x52049e
SHIELD_RING_OFFSET = (12, 14)        # 0x72b3f8 / 0x72b3fc (low: 6, 7)
SHIELD_SEGMENTS = 48
DAMAGE_ART_OFFSET = {6: (2, 30), 7: (-2, 30)}   # DispConsts +0x300/+0x304 (self 0x520f76, target 0x5234a0)
DAMAGE_LABEL_OFFSET = (10, 1)        # +0x2f8 high (0x520f5d)
DAMAGE_VIEW_SIZE = 64                # offscreen 3D view 0x52101a
DAMAGE_EXTRA_HEIGHT = 30 + 2         # 0x5215ff: + DispConsts +0x304 + 2
LEAD_OFFSET = (-23, -26)             # DisplayItems +0x2f0 high
LEAD_RANGE_TEXT = (18, -32)          # DisplayItems +0x304 high
LEAD_ARROW = (15, 24, 3)             # DisplayItems +0x2f8..+0x300 high
RETICLE_ON_TARGET_PX = 12            # 0x51b578
CHAT_SIZES = [(400, 39), (400, 83), (400, 116)]  # 0x5247f8
INTERNALS_WIDTH = 210                # 0x523b12
DEFAULT_WEAPONS = 4                  # mock-up row count (the real count is the vehicle's weapon list)


# ---------------------------------------------------------------------------------------------- reading
def read_art(shell_dir, filename):
    """Frames of a PBMP (.bmp) or PBMA (.pba) shell bitmap: list of {w, h, pixels, palette_id}."""
    with open(os.path.join(shell_dir, filename), 'rb') as f:
        data = f.read()
    return G.read_pba(data) if filename.lower().endswith('.pba') else [G.read_pbmp(data)]


def read_pft(data):
    """Phoenix font (Starsiege / Tribes .pft).

    "PFON" u32 size; +8 u32 version (2), u32 flags (0x45), u32 0, u32 glyph count (224), u32 height,
    u32 baseline, u32 colour index, u32 0, u32 (space width?), 2 x u32 0x10000 (16.16 scale), u32 sheet
    count; +0x38 u16 count, u16 first char (32), u16 glyph index per char; then 8 bytes per glyph
    {u8 sheet, u8 x, u8 y, u8 w, u8 h, s8 y offset, u16 0}; then the glyph sheet as a PBMP (index 0 =
    transparent, 252 = unused sheet area).  Glyph top in the cell = baseline - h + y offset.
    """
    assert data[:4] == b'PFON', data[:4]
    height, baseline, color = struct.unpack_from('<3I', data, 0x18)
    count, first = struct.unpack_from('<HH', data, 0x38)
    index = struct.unpack_from('<%dH' % count, data, 0x3c)
    table = 0x3c + 2 * count
    glyphs = [_read_glyph(data, table + 8 * gi, first + ci) for ci, gi in enumerate(index)]
    sheet = G.read_pbmp(data, data.find(b'PBMP'))
    return {'height': height, 'baseline': baseline, 'color': color, 'glyphs': glyphs, 'sheet': sheet}


def _read_glyph(data, at, code):
    _sheet, x, y, w, h = data[at:at + 5]
    y_offset, = struct.unpack_from('<b', data, at + 5)
    return {'code': code, 'x': x, 'y': y, 'w': w, 'h': h, 'y_offset': y_offset}


def make_font_atlas(font, cols=16):
    """(rows of palette indices, width, height, chars {code: [x, y, advance]}): one font-height cell per glyph,
    the glyph pasted at its baseline position; same convention as tools/shell.py font_atlas."""
    cell_w = max(g['w'] for g in font['glyphs']) + GLYPH_SPACING
    cell_h = font['height']
    rows = (len(font['glyphs']) + cols - 1) // cols
    width, height = cols * cell_w, rows * cell_h
    pixels = bytearray(width * height)
    chars = {}
    for i, g in enumerate(font['glyphs']):
        x0, y0 = (i % cols) * cell_w, (i // cols) * cell_h
        _paste_glyph(font, g, pixels, width, (x0, y0))
        chars[str(g['code'])] = [x0, y0, g['w'] + GLYPH_SPACING]
    return bytes(pixels), width, height, chars


def _paste_glyph(font, g, pixels, width, origin):
    sheet = font['sheet']
    top = font['baseline'] - g['h'] + g['y_offset']
    for row in range(g['h']):
        if not 0 <= top + row < font['height']:
            continue
        for col in range(g['w']):
            v = sheet['pixels'][(g['y'] + row) * sheet['w'] + g['x'] + col]
            if v and v != PFT_SHEET_FILL:
                pixels[(origin[1] + top + row) * width + origin[0] + col] = v


# ---------------------------------------------------------------------------------------------- colours
def read_hud_colors(exe_path):
    """{'fixed': {slot: (r, g, b)}, 'schemes': [{slot: (r, g, b)}] x 8}: the HUD colour tables of the user's
    Starsiege.exe, after checking the setScheme code (0x50be7c) that reads them."""
    if not os.path.exists(exe_path):
        raise SystemExit('Starsiege.exe not found at %s: the HUD colours cannot be read' % exe_path)
    with open(exe_path, 'rb') as f:
        exe = f.read()
    to_offset = _make_pe_offset(exe)
    for va, code in HUD_COLOR_CODE.items():
        if exe[to_offset(va):to_offset(va) + len(code)] != code:
            raise SystemExit('Starsiege.exe is not the analysed build: 0x%x does not hold the HUD colour code' % va)
    scheme_size = len(SCHEME_SLOTS) * COLOR_RECORD.size
    return {'fixed': _read_color_records(exe, to_offset(FIXED_TABLE_VA), FIXED_SLOTS),
            'schemes': [_read_color_records(exe, to_offset(SCHEME_TABLE_VA) + i * scheme_size, SCHEME_SLOTS)
                        for i in range(SCHEME_COUNT)]}


def _read_color_records(exe, at, slots):
    colors = {}
    for i, slot in enumerate(slots):
        found, *rgb = COLOR_RECORD.unpack_from(exe, at + i * COLOR_RECORD.size)
        if found != slot:
            raise SystemExit('Starsiege.exe HUD colour table: record at file offset 0x%x is slot %d, expected %d'
                             % (at + i * COLOR_RECORD.size, found, slot))
        colors[slot] = tuple(rgb)
    return colors


def _make_pe_offset(exe):
    """VA -> file offset function of a PE image."""
    pe = struct.unpack_from('<I', exe, 0x3c)[0]
    count, opt = struct.unpack_from('<H', exe, pe + 6)[0], struct.unpack_from('<H', exe, pe + 20)[0]
    base = struct.unpack_from('<I', exe, pe + 52)[0]
    sections = [struct.unpack_from('<IIII', exe, pe + 24 + opt + i * 40 + 8) for i in range(count)]

    def to_offset(va):
        for _vsize, vaddr, rsize, raddr in sections:
            if base + vaddr <= va < base + vaddr + rsize:
                return va - base - vaddr + raddr
        raise SystemExit('Starsiege.exe is not the analysed build: 0x%x is outside its sections' % va)
    return to_offset


def make_hud_palette(world_colors, hud_colors, scheme=DEFAULT_SCHEME):
    """256 x [r, g, b]: the world screen palette with the HUD slots of `scheme` filled in (0x50be7c);
    `hud_colors` from read_hud_colors."""
    pal = [list(c[:3]) for c in world_colors]
    for slot, rgb in list(hud_colors['fixed'].items()) + list(hud_colors['schemes'][scheme].items()):
        pal[slot] = list(rgb)
    return pal


def make_scheme_table(hud_colors):
    """[{slot: [r, g, b]}] for the 8 colour schemes ("Cycle Colors")."""
    return [{str(s): list(c) for s, c in row.items()} for row in hud_colors['schemes']]


def make_shield_ring_lut(angle, focus, strength):
    """Palette index per strCircle segment value (index 0 unused), as 0x51a258 builds it."""
    import math
    if strength == 0.0:
        return [COLOR_BACK] * (SHIELD_SEGMENTS + 1)
    if focus == 0.0:
        return [COLOR_DIM] * (SHIELD_SEGMENTS + 1)
    centre = _wrap_segment(int(round(angle * SHIELD_SEGMENTS / (2 * math.pi))) + 1)
    n1 = int(round(focus * 8))
    n2 = 24 - (int(round((focus - 0.5) * 8)) if focus > 0.5 else 0)
    n3 = (n2 - n1) // 2 + n1
    return [_ring_color(_wrap_segment(k - centre + 1), n1, n2, n3) for k in range(SHIELD_SEGMENTS + 1)]


def _wrap_segment(e):
    return (e - 1) % SHIELD_SEGMENTS + 1


def _ring_color(e, n1, n2, n3):
    def within(n):
        return e <= n or e > SHIELD_SEGMENTS - n
    if within(n1):
        return COLOR_BRIGHT
    if not within(n2):
        return COLOR_BACK
    return COLOR_MID if within(n3) else COLOR_DIM


# ---------------------------------------------------------------------------------------------- layout
def make_rect(extent, layout_id, canvas=CANVAS):
    """Inclusive canvas rect of a meter: top-left = (canvas - extent) * fraction (0x50c174)."""
    fx, fy = LAYOUT_DEFAULTS[layout_id][:2]
    x = int((canvas[0] - extent[0]) * fx)
    y = int((canvas[1] - extent[1]) * fy)
    return [x, y, x + extent[0] - 1, y + extent[1] - 1]


def make_anchor(layout_id):
    """Nearest named anchor; the exact rule is the proportional `layout_fraction` (0x50c174)."""
    fx, fy = LAYOUT_DEFAULTS[layout_id][:2]
    horizontal = 'left' if fx < 0.34 else ('right' if fx > 0.66 else '')
    if fx == 0.5 and fy == 0.5:
        return 'center'
    vertical = 'top' if fy <= 0.5 else 'bottom'
    return vertical + '_' + horizontal if horizontal else vertical


def make_meter(kind, layout_id, extent, **fields):
    """A hud.json meter record: rect from the HudLayout default, plus the layout fraction for other sizes."""
    fx, fy, mode = LAYOUT_DEFAULTS[layout_id]
    meter = {'kind': kind, 'id': layout_id, 'rect': make_rect(extent, layout_id), 'anchor': make_anchor(layout_id),
             'layout_fraction': [fx, fy], 'mode': mode, 'alpha': TRANSLUCENT_ALPHA}
    meter.update(fields)
    return meter


def make_weapon_extent(weapons):
    c = WEAPON_CONSTS
    width = 4 * c['c3'] + 4 * c['c0'] + c['c4'] + c['c5']
    return (width, (c['c6'] + c['c1']) * (weapons + 1) + c['c1'])


def make_default_meters(art, fonts, weapons=DEFAULT_WEAPONS):
    """The default meter list at 640 x 480 (ResourceSet[1]); `art` = {NAME: frames}, `fonts` = {NAME: font}."""
    def size(name):
        return (art[name][0]['w'], art[name][0]['h'])
    font_h = fonts['HUD_HIGH']['height']
    return [_reticle_meter(size('RETICAL')), _lead_meter(size('LEAD')), _radar_meter(size('RADAR_HIGH')),
            _weapons_meter(weapons), _shields_meter(size('SHIELDS')),
            _damage_meter('damage_self', 6, 'DAM_SELF', size('DAM_SELF'), font_h),
            _damage_meter('damage_target', 7, 'DAM_TAR', size('DAM_TAR'), font_h),
            _internals_meter(font_h), _messages_meter()] + _timer_meters(font_h) + [_command_meter()]


def _reticle_meter(art_size):
    centre = (CANVAS[0] // 2, CANVAS[1] // 2)
    x0, y0 = centre[0] - art_size[0] // 2, centre[1] - art_size[1] // 2
    meter = make_meter('reticle', 2, art_size, dba='RETICAL', frames={'idle': 0, 'on_target': 1, 'locked': 2},
                       on_target_px=RETICLE_ON_TARGET_PX, meter_rect=[0, 0, CANVAS[0] - 1, CANVAS[1] - 1],
                       evidence='ctor 0x51aed8, render 0x51b0e0, frame 0x51b4e6/0x51b578, extent 0x51b068',
                       confidence='H')
    meter['rect'] = [x0, y0, x0 + art_size[0] - 1, y0 + art_size[1] - 1]
    return meter


def _lead_meter(art_size):
    meter = _reticle_meter(art_size)
    meter.update({'kind': 'lead', 'dba': 'LEAD', 'frames': {'out_of_range': 0, 'in_range': 1},
                  'offset_from_lead_point': list(LEAD_OFFSET), 'range_text_offset': list(LEAD_RANGE_TEXT),
                  'range_format': '%.0fm', 'font': 'HUD_HIGH', 'arrow': {'color': COLOR_ACCENT,
                                                                         'radius_halfwidth_tip': list(LEAD_ARROW)},
                  'evidence': '0x51b85c (frame 0x51bf35, offset +0x2a8, text 0x51c346, arrow 0x51c2e5)',
                  'confidence': 'M'})
    meter.pop('on_target_px')
    meter['rect'] = [CANVAS[0] // 2 + LEAD_OFFSET[0], CANVAS[1] // 2 + LEAD_OFFSET[1],
                     CANVAS[0] // 2 + LEAD_OFFSET[0] + art_size[0] - 1, CANVAS[1] // 2 + LEAD_OFFSET[1] + art_size[1] - 1]
    return meter


def _radar_meter(art_size):
    extent = (art_size[0] + RADAR_ART_OFFSET[0], art_size[1] + RADAR_ART_OFFSET[1])
    mode = LAYOUT_DEFAULTS[1][2]
    return make_meter('radar', 1, extent, dba='RADAR_HIGH', art_offset=list(RADAR_ART_OFFSET),
                      frames={'plain': 0, 'background_1': 1, 'background_2': 2, 'default': RADAR_FRAME_BY_MODE.get(mode, 0)},
                      title={'format': '%s %0.0fm', 'centre': list(RADAR_TITLE_CENTRE), 'strings': ['ACTIVE', 'PASSIVE']},
                      speed={'format': '%0.0fKph', 'average_frames': 4},
                      throttle_arc={'radians': [3.032, 0.84], 'color': COLOR_ACCENT, 'format': '%0.0f%%',
                                    'confidence': 'L'},
                      font='HUD_HIGH', colors={'team_%d' % t: c for t, c in TEAM_COLORS.items()} | {
                          'enemy': ENEMY_COLOR, 'neutral': NEUTRAL_COLOR, 'arc': COLOR_ACCENT},
                      evidence='ctor 0x5148d0, wake 0x518310 (extent +0x726aac), render 0x517874, frame 0x5178eb, '
                               'team colours 0x517ed1, speed 0x518043, arc 0x5166b0', confidence='H')


def _weapons_meter(weapons):
    c = WEAPON_CONSTS
    return make_meter('weapons', 3, make_weapon_extent(weapons), dba='HUD_CIRCLE_F', font='HUD_HIGH',
                      fonts={'selected': 'HUD_HIGH', 'ready': 'HUD_HIGH_DIM', 'unready': 'HUD_HIGH_GRAY'},
                      frames={'in_group': 0}, dba_open='HUD_CIRCLE_O', groups=WEAPON_GROUPS,
                      row_height=c['c6'] + c['c1'], row_pad=c['c1'], group_column_width=c['c3'],
                      name_width=c['c4'], status_width=c['c5'], weapons=weapons, ammo_format='%d',
                      colors={'bar': COLOR_BRIGHT, 'bar_back': COLOR_DIM, 'row_back': COLOR_BACK},
                      evidence='ctor 0x51fab0 (DispConsts 0x51fba1), extent 0x51fd94, render 0x51fea8',
                      confidence='M')


def _shields_meter(art_size):
    return make_meter('shields', 5, art_size, dba='SHIELDS', dba_solid='SHIELDS_SOLID', ring_dba='STRCIRCLE',
                      ring_offset=list(SHIELD_RING_OFFSET), ring_segments=SHIELD_SEGMENTS, frames={'outline': 0},
                      font='HUD_HIGH', colors={'focus': COLOR_BRIGHT, 'near': COLOR_MID, 'far': COLOR_DIM,
                                               'none': COLOR_BACK, 'arc': COLOR_ACCENT},
                      ring_rule='seg=round(angle*48/2pi)+1; e=dist; n1=round(8f); n2=24-round(8(f-0.5)) if f>0.5; '
                                'n3=n1+(n2-n1)/2; e<=n1:246, e>n2:247, e<=n3:245, else 244',
                      evidence='ctor 0x519350, wake 0x51acb0, ring 0x51a258, arc 0x519cf0', confidence='H')


def _damage_meter(kind, layout_id, dba, art_size, font_h):
    extent = (art_size[0] + 2, font_h + art_size[1] + DAMAGE_EXTRA_HEIGHT)
    label = 'STATUS' if layout_id == 6 else 'TARGET'
    return make_meter(kind, layout_id, extent, dba=dba, frames={'frame': 0}, font='HUD_HIGH',
                      art_offset=list(DAMAGE_ART_OFFSET[layout_id]), label=label,
                      label_offset=list(DAMAGE_LABEL_OFFSET), model_view=DAMAGE_VIEW_SIZE,
                      evidence='ctor 0x520e40 / 0x523440, extent 0x52157b, render 0x522b68', confidence='M')


def _internals_meter(font_h):
    lines = 6
    return make_meter('internal_damage', 12, (INTERNALS_WIDTH, lines * (font_h + 2) + 6), font='HUD_HIGH_DIM',
                      title='Internals Status:', evidence='ctor 0x523a30, height 0x523df0 (text lines)',
                      confidence='L')


def _messages_meter():
    return make_meter('messages', 9, CHAT_SIZES[0], font='HUD_HIGH',
                      fonts={'old': 'HUD_HIGH_GRAY', 'recent': 'HUD_HIGH_DIM', 'new': 'HUD_HIGH'},
                      sizes=[list(s) for s in CHAT_SIZES], evidence='ctor 0x5246b8, size 0x5249a0',
                      confidence='H')


def _timer_meters(font_h):
    return [make_meter('timer', i, (60, font_h + 4), font='HUD_HIGH_DIM', visible='when setHudTimer() is active',
                       evidence='ctor 0x525bac, width 0x5263d2 (text)', confidence='L') for i in (13, 14, 15)]


def _command_meter():
    return make_meter('command', 16, (280, 160), font='HUD_HIGH', visible='commander only (0x74d85c)',
                      evidence='ctor 0x526e00 (+0x2b8/+0x2bc)', confidence='L')


# ---------------------------------------------------------------------------------------------- first person
EYE_RULES = {
    'herc': {'node': ['cam', 'camera', 'cockpit', 'head0'], 'offset_field': 'hercCpit',
             'evidence': '0x4a33c6 (cam/camera), 0x471520 (cockpit/head0), eye 0x4a2e60', 'confidence': 'H'},
    'tank': {'node': ['cockpit', 'head0'], 'offset_field': 'tankCpit',
             'evidence': '0x471520, eye 0x430df4', 'confidence': 'H'},
    'flyer': {'node': ['cockpit', 'head0'], 'offset_field': 'flyerCpit',
              'evidence': '0x471520, eye 0x439368', 'confidence': 'H'},
}
EYE_FRAME = ('eye = shape_to_world * node_transform(first existing node) * [rotation +0x45c | translation Cpit]; '
             'Cpit (vehicle data +0x3c..+0x44) is in that node frame: x right, y forward, z up, metres')

COCKPIT_MESH = {
    'first_person_sequence': 'Seq07_cockpit (Hercs) / Seq01_cockpit (tanks, flyers) set to 1.0 on the current '
                             'detail level (0.0 outside), 0x481fc0',
    'visibility': 'object keyframes: head0..head4 visible at 0 / hidden at >= 0.5; cockpit, cockpit1, cockpit2 '
                  'hidden at 0 / visible at >= 0.5 (flag 0x80000000 = visible, 0x40000000 = visibility matters)',
    'rendered': True,
    'textures': 'cockpit objects use the faction cockpit skins tr_cpit / cy_cpit / rb_cpit / ha_cpit.bmp',
    'translucent_cockpit': 'translucentCockpit() (handler 0x415c03) sets vehicle data +0x112; spawn 0x4684b3 then '
                           'clears shape instance +0x9c; used by cin_apoc / cin_basl only (L: exact effect)',
    'confidence': 'H',
}


def make_hud(art, fonts, hud_colors, weapons=DEFAULT_WEAPONS):
    """hud.json content (everything except the per-variant palette paths); `hud_colors` from read_hud_colors."""
    return {'canvas': list(CANVAS), 'resource_set': 'high (canvas >= 600 x 380, 0x508aa0)',
            'meters': make_default_meters(art, fonts, weapons), 'schemes': make_scheme_table(hud_colors),
            'default_scheme': DEFAULT_SCHEME, 'eye': dict(EYE_RULES, frame=EYE_FRAME), 'cockpit_mesh': COCKPIT_MESH}
