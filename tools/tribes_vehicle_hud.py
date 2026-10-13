"""What the original Tribes games showed on screen while piloting a vehicle: decoders and findings.

Used by tools/export_tribes_cockpit.py, which writes gamedata/<pack>/cockpit/hud.json from the layouts below.

FINDINGS (confidence H = read from the data / code, M = inferred from code or layout, L = educated guess)

Tribes 1 (Starsiege: Tribes, Tribes/tribes.exe; scripts.vol, gui.vol, Interface.vol, Entities.vol, fonts.vol)
  1. No vehicle HUD. [H] The only HUD classes in tribes.exe are FearGui::HealthHud, JetPackHud, CompassHud,
     ClockHud, CurrentWeaponHud, FGHSensorPing, Crosshair, HudListCtrl, FGHudArrayCtrl, FGHudMatrix (exe strings
     0x0aa13c..0x0e26b8); none is vehicle-specific. play.gui holds the one HUD (crosshairHud, clockHud, sensorHUD,
     compassHud, jetPackHud, healthHud, weaponHud, chatDisplayHud). Piloting only calls
     Client::setControlObject(%client, %vehicle) (scripts/vehicle.cs Vehicle::onCollision, line ~208); no script
     touches a HUD control on mount/dismount (grep "Hud" over scripts/*.cs: only training and the HUD tutorial).
  2. The armour and energy bars follow the control object. [M] HealthHud / JetPackHud render read the client's
     control object (connection [0x660e20] + 0xa4) through virtuals 0xf8 / 0xfc (0x404be0 / 0x404c00), so while
     piloting the Scout they show the Scout's damage (maxDamage 0.6) and energy (maxEnergy 100).
  3. The pilot's hand weapon is unmounted on boarding (vehicle.cs Player::unMountItem(%object, $WeaponSlot)) [H],
     so the weapon display shows no weapon [M]; the Scout fires FlierRocket on its own trigger (vehicle.cs).
  4. Default layout (gui/play.gui, persisted SimGui controls; 640x480): [H]
       healthHud      (0,0)    131x35        jetPackHud (0,33)   131x35       weaponHud  (0,213) 62x76
       compassHud     (576,0)  64x64         sensorHUD  (505,10) 32x23        clockHud   (505,34) 66x19
       chatDisplayHud (132,9)  370x45        crosshairHud: drawn at the screen centre (Crosshair class)
     Below 512x384 the controls switch to the lr_* art and shrink (0x4dfa1b: extent = bitmap * 6 / 10 + 2). [H]
  5. Health bar (HealthHud render 0x4df9fc): [H] background hudTrans.bmp at +1,+1; icon HH_Icon_Green at +5,+3;
     bar at +37,+10, length = (1 - damage) * 85 px (at least 1 while alive), clipped from a left cap HH_End_*,
     a fill rectangle and the cap mirrored (flag 1) at +84 - cap width. Colour: palette 0xfc green >= 57 px,
     0xf2 yellow >= 28 px, 0xf3 red below; below 28 px the icon blinks HH_Icon_Red / Green every 512 ms.
  6. Energy bar (JetPackHud render 0x4acd10): [H] hudTrans.bmp drawn flipped vertically (flag 2) at +1,+1, so it
     nests under the health piece; icon HJ_Icon_Green [M: +5,+8]; bar at +37,+11, 85 px, colour 0xe7, cap HJ_End_Green.
  7. Compass (CompassHud 0x4e0c50..): Compass.bmp (64x64, translucent palette 1977), rotating marks around the
     centre (31.5, 31.5), fonts if_g_8 / sf_green_5 (lr). [M: letters, L: radius]
     Sensor ping: ping.bmp + HP_PingedLo / Med / Hi, HP_Supressed (jammed) [H names, M placement].
     Weapon: ammoSh.bmp slot, I_<weapon>_on/off icons, I_Infinity_*, fonts if_g_8 / if_dg_8 [H names, L layout].
     Clock: if_w_10 (lr sf_white_6) [H]. Crosshair: H_Reticle.bmp (9x9), H_Friend / H_Foe over targets, target
     names in sf_white_7 (lr sf_white_5) [H]. Chat display font: not resolved [L].
  8. Colours: Interface bitmaps use palette ids 0 (indices 212..255, identical in every world PPL), the Entities
     HUD backgrounds palette 1977 (translucent: per-entry alpha in the PPL flags), so one RGBA export fits all
     worlds. [H]

Tribes 2 (scripts/gui/*.gui, scripts/scripts/*.cs; art in textures/gui; fonts base/fonts/*.gft; Tribes2.exe)
  9. Vehicles have their own HUD: the server sends setHudMode('Pilot', <type>, <seat>) on mount
     (vehicles/vehicle.cs ScoutFlyer/BomberFlyer/AssaultVehicle::playerMounted) [H]; ClientCmdDisplayHuds
     (hud.cs ~974) then hides ammo, objective, inventory, weapons and pack displays, and builds the dashboard with
     clientCmdShowVehicleGauges (client.cs ~485) in dashboardHud (PlayGui, at 0,360 640x120, centred, bottom). [H]
     Still shown: the reticle centre, the HUD cluster (pilot's own armour / energy / heat bars, compass, sensor
     ping), the chat window and the clock. [H]
 10. Every pilot seat (seat 0): dash diagram hud_veh_new_dash (200,10 in the dash), overhead vehicle icon
     (256,0, 128x128), energy bar hud_veh_new_dashpiece_5 (160,80) fill subRegion 4 5 98 10 blue, damage bar
     dashpiece_4 (361,80) fill subRegion 18 5 97 10 green, both displayMounted (the vehicle's values) pulsing below
     30 % every 500 ms, and the speed box (210,47): "<kph> KPH", floor(getControlObjectSpeed() * 3.6), every 500 ms. [H]
     Shrike adds the altitude box dashpiece_1 (371,56) "<getControlObjectAltitude()> M", the weapon box
     dashpiece_2 (358,22) with the blaster icon, and reticle hud_ret_shrike without the range frame. [H]
     Thundersword pilot: overhead bomber icon, seat dots, altitude box; no weapon box, no reticle (unarmed). [H]
     Beowulf driver: overhead assault icon, 2 seat dots; no altitude, no weapon, no reticle (unarmed). [H]
     Seat dots (hud_veh_seatdot) show which seats are taken (clientCmdCheckPassengers, seat 0 = pilot). [H]
 11. Gunner seats (not the remake's pilot, but the remake's pilot fires these weapons): Beowulf turreteer (seat 1):
     tankgunner dash with chaingun / mortar icons and highlight, reticles hud_ret_tankchaingun / tankmortar;
     Thundersword bombardier (seat 1): bombardier dash with blaster / targeting laser / bomb, reticle hud_ret_shrike
     (weapon 1), the bomb sight (weapon 2), hud_ret_targlaser (weapon 3). Their bars are flipped vertically. [H]
 12. Reticles are HudCrosshair (autoCenter, autoResize): the bitmap at its own size, centred in retCenterHud
     (centred 256x256); the range ring hud_retrng (67x67) is reticleFrameHud. [H]
 13. Fonts: dash text GuiDashTextProfile = Univers Condensed 16, colour 154 208 253, centred; clock and compass
     clockProfile = Univers Condensed 12, green. Fonts are GFT files (base/fonts). [H]
"""
import re
import struct

# --------------------------------------------------------------------------------------------- Tribes 1 GUI

T1_GUI_CANVAS_AT = 0x24          # play.gui: i32 width, height of the root control (640 x 480)
T1_TAG_MARKER = re.compile(rb'\x03\x00\x00\x00(.)(.)\x02\x00', re.S)  # u32 3, u32 tag (0x0002xxxx) after pos / extent
T1_TAG_RANGE = (140000, 142000)  # IDCTG_* control tags (fear.strings.cs)


def read_t1_gui(data):
    """Controls of a persisted Darkstar SimGui file (play.gui): [{tag, position, extent}] in file order.

    Each control stores i32 x, y, width, height right before u32 3 and its IDCTG tag (H: the values match the
    HUD the game draws; the meaning of the 3 is unknown)."""
    controls = []
    for m in T1_TAG_MARKER.finditer(data):
        p = m.start()
        tag = struct.unpack_from('<I', data, p + 4)[0]
        if not T1_TAG_RANGE[0] <= tag < T1_TAG_RANGE[1] or p < 16:
            continue
        x, y, w, h = struct.unpack_from('<4i', data, p - 16)
        controls.append({'tag': tag, 'position': [x, y], 'extent': [w, h]})
    return controls


def read_t1_gui_canvas(data):
    return list(struct.unpack_from('<2i', data, T1_GUI_CANVAS_AT))


def read_ctg_names(strings_cs):
    """IDCTG tag -> name from fear.strings.cs ('IDCTG_HUD_COMPASS = 00140101, "Compass";')."""
    names = {}
    for m in re.finditer(r'(IDCTG_\w+)\s*=\s*(\d+)', strings_cs):
        names[int(m.group(2))] = m.group(1)
    return names


# --------------------------------------------------------------------------------------------- Tribes 1 PFT font

PFT_HEADER_HEIGHT = 0x18         # i32 line height
PFT_HEADER_COLOR = 0x20          # i32 palette index the glyph pixels are drawn in
PFT_RECORD = struct.Struct('<BBBBBbH')   # sheet, x, y, width, height, baseline offset, pad


def read_pft(data, read_pba):
    """Phoenix font ("PFON"): {height, color_index, glyphs {code: (sheet, x, y, w, h, top)}, sheets}.

    Layout (if_g_8.pft): header, u16 count + u16 first code + count x u16 record index, count x 8-byte records
    (sheet, x, y, w, h, s8 offset), then a PBMA of glyph sheets (pixel != 0 = ink). top = ascent - h + offset."""
    assert data[:4] == b'PFON', data[:4]
    pba_at = data.find(b'PBMA')
    count = struct.unpack_from('<I', data, 0x14)[0]
    records_at = pba_at - PFT_RECORD.size * count
    remap_at = records_at - 2 * count
    first = struct.unpack_from('<H', data, remap_at - 2)[0]
    remap = struct.unpack_from('<%dH' % count, data, remap_at)
    records = [PFT_RECORD.unpack_from(data, records_at + PFT_RECORD.size * i) for i in range(count)]
    ascent = max(r[4] - r[5] for r in records)
    glyphs = {}
    for i, k in enumerate(remap):
        sheet, x, y, w, h, off, _pad = records[k]
        glyphs[first + i] = (sheet, x, y, w, h, ascent - h + off)
    return {'height': struct.unpack_from('<i', data, PFT_HEADER_HEIGHT)[0],
            'color_index': struct.unpack_from('<i', data, PFT_HEADER_COLOR)[0],
            'glyphs': glyphs, 'sheets': read_pba(data[pba_at:])}


# --------------------------------------------------------------------------------------------- Tribes 2 GFT font

GFT_RECORD = struct.Struct('<HBBBBbbb')  # sheet, x, y, width, height, x origin, y origin, advance
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'


def read_gft(data):
    """Torque font (.gft, version 1): {height, baseline, glyphs {code: (sheet, x, y, w, h, xo, yo, adv)}, sheets}.

    u32 version, height, baseline, count; count x 9-byte records; u32 sheet count; PNG sheets (8-bit alpha);
    256 x s16 code -> record (-1 = none). Glyph top = baseline - yo."""
    _version, height, baseline, count = struct.unpack_from('<4I', data, 0)
    p = 16
    records = [GFT_RECORD.unpack_from(data, p + GFT_RECORD.size * i) for i in range(count)]
    p += GFT_RECORD.size * count
    sheet_count = struct.unpack_from('<I', data, p)[0]
    p += 4
    sheets = []
    for _ in range(sheet_count):
        end = data.index(PNG_END, p) + len(PNG_END)
        assert data[p:p + 8] == PNG_MAGIC
        sheets.append(data[p:end])
        p = end
    remap = struct.unpack_from('<256h', data, p)
    glyphs = {code: records[k] for code, k in enumerate(remap) if 0 <= k < count}
    return {'height': height, 'baseline': baseline, 'glyphs': glyphs, 'sheets': sheets}


# --------------------------------------------------------------------------------------------- Tribes 2 GUI script

_GUI_TOKEN = re.compile(r'new\s+(\w+)\s*\(\s*(\w*)\s*\)\s*\{|(\w+(?:\[\d+\])?)\s*=\s*(?!new\b)("([^"]*)"|[^;{]*);|\}\s*;')


def _strip_comments(text):
    return re.sub(r'//[^\n]*', lambda m: ' ' * len(m.group()), text)


def read_gui_script(text):
    """Every `new Class(Name) { field = value; ... }` block of a TorqueScript file, nested, in file order:
    [{class, name, line, fields, children, origin}], origin = position summed over the enclosing blocks."""
    text = _strip_comments(text)
    roots, stack = [], []
    for m in _GUI_TOKEN.finditer(text):
        if m.group(1):
            ctl = {'class': m.group(1), 'name': m.group(2), 'line': text.count('\n', 0, m.start()) + 1,
                   'fields': {}, 'children': []}
            (stack[-1]['children'] if stack else roots).append(ctl)
            stack.append(ctl)
        elif m.group(3) and stack:
            value = m.group(5) if m.group(5) is not None else m.group(4).strip()
            stack[-1]['fields'][m.group(3)] = value
        elif m.group().startswith('}') and stack:
            stack.pop()
    for ctl in roots:
        _set_origins(ctl, (0, 0))
    return roots


def _set_origins(ctl, parent_origin):
    x, y = make_pair(ctl['fields'].get('position', '0 0'))
    ctl['origin'] = [parent_origin[0] + x, parent_origin[1] + y]
    for child in ctl['children']:
        _set_origins(child, ctl['origin'])


def make_pair(value):
    words = value.split()
    return int(float(words[0])), int(float(words[1]))


def make_flat(controls):
    out = []
    for ctl in controls:
        out.append(ctl)
        out.extend(make_flat(ctl['children']))
    return out


def find_control(controls, name, occurrence=0):
    """The occurrence-th block named `name` (file order); client.cs rebuilds the same names per vehicle/seat."""
    hits = [c for c in make_flat(controls) if c['name'].lower() == name.lower()]
    if occurrence >= len(hits):
        raise KeyError('%s #%d not found (%d blocks)' % (name, occurrence, len(hits)))
    return hits[occurrence]


def make_rect(ctl, base=(0, 0)):
    """Inclusive canvas rectangle of a parsed control placed under `base`."""
    w, h = make_pair(ctl['fields'].get('extent', '0 0'))
    x0, y0 = base[0] + ctl['origin'][0], base[1] + ctl['origin'][1]
    return [x0, y0, x0 + w - 1, y0 + h - 1]


def make_anchor(horiz, vert):
    """Torque horizSizing / vertSizing -> hud.json anchor ("left" sizing keeps the right margin)."""
    h = {'left': 'right', 'center': 'center'}.get(horiz, 'left')
    v = {'top': 'bottom', 'center': 'center'}.get(vert, 'top')
    if h == 'center' and v == 'center':
        return 'center'
    if h == 'center':
        return 'top' if v == 'top' else 'bottom'
    return '%s_%s' % ('top' if v != 'bottom' else 'bottom', h)


def make_color(value, alpha=None):
    """'r g b [a]' in 0..1 or 0..255 -> [r, g, b, a] bytes."""
    parts = [float(v) for v in value.split()]
    scale = 255.0 if max(parts[:3]) <= 1.0 else 1.0
    rgba = [int(round(v * scale)) for v in parts[:3]]
    a = parts[3] if len(parts) > 3 else 1.0
    rgba.append(int(round((a if a <= 1.0 else a / 255.0) * 255)) if alpha is None else alpha)
    return rgba


# ============================================================================================= hud.json layouts
# A meter: {id, kind, rect (inclusive canvas px at 640x480), anchor, layers [{dba, frame, at, flip?, opacity?}],
# dynamic parts (bar / text / reticle ...), evidence, confidence}. Layers are the static bitmaps, drawn in order.

CANVAS = [640, 480]


def make_layer(dba, frame, at, **extra):
    layer = {'dba': dba, 'frame': frame, 'at': [int(at[0]), int(at[1])]}
    layer.update(extra)
    return layer


# --------------------------------------------------------------------------------------------- Tribes 1

# Bitmap arrays exported to cockpit/dba/<NAME>/<i>.png ('<vol dir>/<file stem>').
T1_WEAPON_ICONS = ['blaster', 'chain', 'disk', 'energyrifle', 'grenade', 'mortar', 'plasma', 'sniper', 'targetlaser']
T1_DBA = {
    'HUD_HEALTH': ['Entities/hudtrans', 'Interface/HH_Icon_Green', 'Interface/HH_Icon_Red',
                   'Interface/HH_End_Green', 'Interface/HH_End_Yellow', 'Interface/HH_End_Red'],
    'HUD_ENERGY': ['Entities/hudtrans', 'Interface/HJ_Icon_Green', 'Interface/HJ_End_Green'],
    'HUD_COMPASS': ['Entities/Compass'],
    'HUD_SENSOR': ['Entities/ping', 'Interface/HP_Pinged00', 'Interface/HP_PingedLo', 'Interface/HP_PingedMed',
                   'Interface/HP_PingedHi', 'Interface/HP_Supressed'],
    'HUD_WEAPON': ['Entities/ammoSh', 'Interface/I_weapon_off', 'Interface/I_weapon_on', 'Interface/I_Infinity_off',
                   'Interface/I_Infinity_on'] +
                  ['Interface/I_%s_%s' % (w, s) for w in T1_WEAPON_ICONS for s in ('off', 'on')],
    'HUD_RETICLE': ['Interface/H_Reticle', 'Interface/H_Friend', 'Interface/H_Foe'],
    'HUD_LAG': ['Interface/H_Lag'],
}
T1_FONTS = ['if_g_8', 'if_dg_8', 'if_w_10', 'sf_green_5', 'sf_dk_green_5', 'sf_white_5', 'sf_white_6', 'sf_white_7']

# play.gui control tags (fear.strings.cs IDCTG_HUD_*)
T1_TAGS = {'health': 140104, 'energy': 140111, 'weapons': 140102, 'heading': 140101, 'sensor': 140219,
           'clock': 140100, 'messages': 140113, 'reticle': 140103}

T1_BAR_LENGTH = 85               # 0x4dfb9c fmul 85.0 (hi-res; lr 51)
T1_BAR_HEIGHT = 13               # HH_End_* / HJ_End_Green height (the bar's clip rectangle uses it, 0x4dfe90)
T1_BAR_ORIGIN_HEALTH = (37, 10)  # 0x4dfe44 / 0x4dfe48
T1_BAR_ORIGIN_ENERGY = (37, 11)  # 0x4acff3 / 0x4acff7
T1_HEALTH_STEPS = [(57, 0xfc, 3), (28, 0xf2, 4), (0, 0xf3, 5)]   # 0x4dfbd6: px threshold, colour, cap frame
T1_ENERGY_COLOR = 0xe7           # 0x4acf11
T1_BLINK = {'below_px': 28, 'period_ms': 512}                     # 0x4dfc7f: (ms >> 9) & 1


def make_t1_hud(controls, color_of):
    """hud.json for Tribes 1: the standard play.gui HUD (the game has no vehicle HUD, finding 1).
    controls: read_t1_gui(play.gui); color_of(index) -> [r, g, b, a] in the HUD palette."""
    at = {kind: next(c for c in controls if c['tag'] == tag) for kind, tag in T1_TAGS.items()}
    meters = [_t1_health(at['health'], color_of), _t1_energy(at['energy'], color_of), _t1_heading(at['heading']),
              _t1_sensor(at['sensor']), _t1_clock(at['clock']), _t1_weapons(at['weapons']), _t1_reticle(),
              _t1_messages(at['messages'])]
    ids = [m['id'] for m in meters]
    return {'canvas': CANVAS, 'pack': 'tribes',
            'note': 'Tribes 1 has no vehicle-specific HUD: piloting the Scout keeps the standard play.gui HUD. '
                    'The armour and energy bars follow the control object, i.e. show the Scout while piloting; '
                    'the hand weapon is unmounted, so the weapon display is empty. Colours are RGBA; layers '
                    'are drawn in order at "at" (canvas px); flip "v" = upside down, "h" = mirrored. Below 512x384 '
                    'the original switches to the lr_* art (not exported).',
            'per_vehicle': {'SCOUT': ids, 'INFANTRY': ids},
            'meters': meters}


def _t1_rect(ctl):
    (x, y), (w, h) = ctl['position'], ctl['extent']
    return [x, y, x + w - 1, y + h - 1]


def _t1_bar(source, origin, steps):
    return {'source': source, 'origin': [origin[0], origin[1]], 'max_px': T1_BAR_LENGTH, 'height': T1_BAR_HEIGHT,
            'min_px_alive': 1, 'direction': 'left_to_right', 'steps': steps,
            'draw': 'cap frame at origin, fill rect, the cap mirrored at origin + max_px - 1 - cap width; '
                    'all clipped to [origin, origin + length)'}


def _t1_health(ctl, color_of):
    x, y = ctl['position']
    origin = (x + T1_BAR_ORIGIN_HEALTH[0], y + T1_BAR_ORIGIN_HEALTH[1])
    steps = [{'min_px': px, 'color': color_of(c), 'cap_frame': f} for px, c, f in T1_HEALTH_STEPS]
    return {
        'id': 't1_health', 'kind': 'health', 'rect': _t1_rect(ctl), 'anchor': 'top_left', 'dba': 'HUD_HEALTH',
        'frames': {'background': 0, 'icon': 1, 'icon_alarm': 2, 'cap_high': 3, 'cap_mid': 4, 'cap_low': 5},
        'layers': [make_layer('HUD_HEALTH', 0, (x + 1, y + 1)), make_layer('HUD_HEALTH', 1, (x + 5, y + 3))],
        'bar': _t1_bar('control_object.health', origin, steps),
        'icon_blink': dict(T1_BLINK, frames=[1, 2], at=[x + 5, y + 3], when_empty=2),
        'colors': {'high': color_of(0xfc), 'mid': color_of(0xf2), 'low': color_of(0xf3)},
        'evidence': 'gui/play.gui healthHud (tag 140104); tribes.exe HealthHud onWake 0x4df544 (hudTrans, HH_*), '
                    'render 0x4df9fc (85 px, thresholds 57 / 28, colours 0xfc / 0xf2 / 0xf3, offsets 37,10 / 5,3)',
        'confidence': 'H'}


def _t1_energy(ctl, color_of):
    x, y = ctl['position']
    origin = (x + T1_BAR_ORIGIN_ENERGY[0], y + T1_BAR_ORIGIN_ENERGY[1])
    steps = [{'min_px': 0, 'color': color_of(T1_ENERGY_COLOR), 'cap_frame': 2}]
    return {
        'id': 't1_energy', 'kind': 'energy', 'rect': _t1_rect(ctl), 'anchor': 'top_left', 'dba': 'HUD_ENERGY',
        'frames': {'background': 0, 'icon': 1, 'cap': 2},
        'layers': [make_layer('HUD_ENERGY', 0, (x + 1, y + 1), flip='v'),
                   make_layer('HUD_ENERGY', 1, (x + 5, y + 8))],
        'bar': _t1_bar('control_object.energy', origin, steps),
        'colors': {'fill': color_of(T1_ENERGY_COLOR)},
        'evidence': 'gui/play.gui jetPackHud (tag 140111); JetPackHud onWake 0x4acb2b, render 0x4acd10 '
                    '(background flag 2 = flipped, 85 px, colour 0xe7, bar 37,11)',
        'confidence': 'H (icon offset M)'}


def _t1_heading(ctl):
    x, y = ctl['position']
    return {
        'id': 't1_heading', 'kind': 'heading', 'rect': _t1_rect(ctl), 'anchor': 'top_right', 'dba': 'HUD_COMPASS',
        'frames': {'background': 0}, 'layers': [make_layer('HUD_COMPASS', 0, (x, y))],
        'center': [x + 31.5, y + 31.5], 'marks': ['N', 'E', 'S', 'W'], 'mark_radius': 23, 'text': {'font': 'IF_G_8'},
        'rotates': 'the marks turn with the view heading; a pointer to the waypoint when one is set',
        'evidence': 'play.gui compassHud (576,0 64x64); CompassHud onWake 0x4e0c50 loads if_g_8 / sf_green_5 / '
                    'Compass.bmp; render centre 31.5,31.5 (0x4e0f96)',
        'confidence': 'M (marks and radius L)'}


def _t1_sensor(ctl):
    x, y = ctl['position']
    return {
        'id': 't1_sensor', 'kind': 'sensor', 'rect': _t1_rect(ctl), 'anchor': 'top_right', 'dba': 'HUD_SENSOR',
        'frames': {'background': 0, 'none': 1, 'low': 2, 'medium': 3, 'high': 4, 'jammed': 5},
        'layers': [make_layer('HUD_SENSOR', 0, (x, y))], 'state_frame_at': 'centred on the background',
        'evidence': 'play.gui sensorHUD (505,10 32x23); FGHSensorPing loads ping.bmp, HP_PingedLo / Med / Hi, '
                    'HP_Supressed (exe 0x4e330a)',
        'confidence': 'M'}


def _t1_clock(ctl):
    x, y = ctl['position']
    return {
        'id': 't1_clock', 'kind': 'clock', 'rect': _t1_rect(ctl), 'anchor': 'top_right',
        'text': {'font': 'IF_W_10', 'at': [x + 2, y + 3], 'format': 'mm:ss',
                 'source': 'mission time (setHudTimer, client.cs:349)'},
        'layers': [],
        'evidence': 'play.gui clockHud (505,34 66x19); ClockHud loads if_w_10 (lr sf_white_6) at 0x4e058b',
        'confidence': 'M'}


def _t1_weapons(ctl):
    x, y = ctl['position']
    return {
        'id': 't1_weapons', 'kind': 'weapons', 'rect': _t1_rect(ctl), 'anchor': 'top_left', 'dba': 'HUD_WEAPON',
        'frames': {'slot': 0, 'no_weapon': 1, 'weapon': 2, 'infinite_off': 3, 'infinite_on': 4,
                   'icons_first': 5, 'icons': T1_WEAPON_ICONS, 'icon_frame': '5 + 2 * icon (+1 = selected)'},
        'layers': [make_layer('HUD_WEAPON', 0, (x + 15, y + 22)), make_layer('HUD_WEAPON', 1, (x + 19, y + 29))],
        'text': {'font': 'IF_G_8', 'font_empty': 'IF_DG_8', 'at': [x + 22, y + 58],
                 'source': 'ammo of the weapon in hand (infinity icon for energy weapons)'},
        'vehicle': 'piloting: the hand weapon is unmounted (vehicle.cs), so the slot shows no weapon',
        'evidence': 'play.gui weaponHud (0,213 62x76); CurrentWeaponHud 0x4e1b12 loads if_dg_8 / if_g_8, ammoSh.bmp, '
                    'I_weapon_off, I_Infinity_*',
        'confidence': 'H (rect, art), L (inner layout)'}


def _t1_reticle():
    cx, cy = CANVAS[0] // 2, CANVAS[1] // 2
    return {
        'id': 't1_reticle', 'kind': 'reticle', 'rect': [cx - 4, cy - 4, cx + 4, cy + 4], 'anchor': 'center',
        'dba': 'HUD_RETICLE', 'frames': {'reticle': 0, 'friend': 1, 'foe': 2},
        'layers': [make_layer('HUD_RETICLE', 0, (cx - 4, cy - 4))],
        'target_markers': {'friend': 1, 'foe': 2, 'font': 'SF_WHITE_7', 'placement': 'above the targeted player'},
        'evidence': 'Crosshair 0x4a7a6e loads sf_white_7 / sf_white_5, H_Reticle / H_Friend / H_Foe (0x4a7afa); '
                    'play.gui crosshairHud tag 140103',
        'confidence': 'H (art), M (still drawn while piloting)'}


def _t1_messages(ctl):
    x, y = ctl['position']
    return {
        'id': 't1_messages', 'kind': 'messages', 'rect': _t1_rect(ctl), 'anchor': 'top',
        'text': {'font': 'IF_G_8', 'at': [x + 2, y + 2], 'lines': 4}, 'layers': [],
        'evidence': 'play.gui chatDisplayHud (132,9 370x45, tag 140113)',
        'confidence': 'H (rect), L (font, line count)'}


# --------------------------------------------------------------------------------------------- Tribes 2

T2_DBA = {
    'VEH_DASH': ['hud_veh_new_dash', 'hud_veh_new_dashpiece_1', 'hud_veh_new_dashpiece_2', 'hud_veh_new_dashpiece_3',
                 'hud_veh_new_dashpiece_4', 'hud_veh_new_dashpiece_5'],
    'VEH_GUNNER_DASH': ['hud_veh_new_tankgunner_dash', 'hud_veh_new_bombardier_dash', 'hud_veh_new_hilite_left',
                        'hud_veh_new_hilite_middle', 'hud_veh_new_hilite_right'],
    'VEH_ICONS': ['hud_veh_icon_shrike', 'hud_veh_icon_bomber', 'hud_veh_icon_assault', 'hud_veh_icon_hapc',
                  'hud_veh_icon_hoverbike', 'hud_veh_icon_mpb', 'hud_veh_seatdot'],
    'VEH_WEAPONS': ['hud_blaster', 'hud_chaingun', 'hud_mortor', 'hud_targetlaser', 'hud_veh_bomb'],
    'RETICLES': ['hud_ret_shrike', 'hud_ret_tankchaingun', 'hud_ret_tankmortar', 'hud_ret_targlaser', 'hud_retrng',
                 'RET_blaster'],
    'HUD_CLUSTER': ['hud_new_cog', 'hud_new_compass', 'hud_new_ping', 'hud_new_NSEW', 'hud_north'],
    'HUD_CLOCK': ['hud_mistimer', 'hud_disconnect'],
    'CHAT_WINDOW': ['hud_new_window_%s' % p for p in ('TL', 'TM', 'TR', 'ML', 'MM', 'MR', 'BL', 'BM', 'BR')] +
                   ['hud_ChatPageDown'],
}
T2_FONTS = {'UNIVERS_CONDENSED_16': 'univers condensed_16', 'UNIVERS_CONDENSED_12': 'Univers Condensed_12',
            'UNIVERS_16': 'Univers_16'}
DASH_TEXT = {'font': 'UNIVERS_CONDENSED_16', 'color': [154, 208, 253, 255], 'justify': 'center'}  # GuiDashTextProfile
CLOCK_TEXT = {'font': 'UNIVERS_CONDENSED_12', 'color': [0, 255, 0, 255]}                          # clockProfile
CHAT_TEXT = {'font': 'UNIVERS_16', 'color': [44, 172, 181, 255]}       # GuiChatHudProfile ($ShellFont Univers 16)
SPEED_TO_KPH = 3.6               # client.cs GuiControl::updateSpeed: mFloor(%vel * 3.6)
GAUGE_UPDATE_MS = 500            # updateSpeed / updateAltitude reschedule
RETICLE_SIZE = 64                # hud_ret_* bitmaps; HudCrosshair autoCenter draws them at their own size


class T2Gui:
    """The parsed Tribes 2 GUI sources the layout reads: PlayGui.gui, ChatDlg.gui, client.cs (vehicle gauges)."""

    def __init__(self, play, chat, gauges):
        self.play, self.chat, self.gauges = play, chat, gauges
        self.frames = {stem.lower(): (dba, i) for dba, stems in T2_DBA.items() for i, stem in enumerate(stems)}
        self.dash = find_control(play, 'dashboardHud')['origin']

    def gauge(self, name, occurrence=0):
        return find_control(self.gauges, name, occurrence)

    def layer(self, ctl, base=(0, 0), bitmap=None):
        """Layer of a HudBitmapCtrl / GuiBitmapCtrl (bitmap = override for setBitmap() calls)."""
        stem = (bitmap or ctl['fields']['bitmap']).split('/')[-1].rsplit('.', 1)[0]
        dba, frame = self.frames[stem.lower()]
        extra = {}
        if float(ctl['fields'].get('opacity', 1)) != 1.0:
            extra['opacity'] = float(ctl['fields']['opacity'])
        if ctl['fields'].get('flipVertical', '').lower() in ('true', '1'):
            extra['flip'] = 'v'
        return make_layer(dba, frame, (base[0] + ctl['origin'][0], base[1] + ctl['origin'][1]), **extra)


def make_t2_hud(gui):
    """hud.json for Tribes 2 (findings 9..13). gui: T2Gui."""
    cluster = _t2_cluster_meters(gui)
    shrike = _t2_pilot_meters(gui, 'shrike', 'hud_veh_icon_shrike') + [
        _t2_altitude(gui, 0, 'shrike'), _t2_shrike_weapon(gui), _t2_reticle('t2_reticle_shrike', ['hud_ret_shrike'], gui)]
    bomber = _t2_pilot_meters(gui, 'bomber', 'hud_veh_icon_bomber') + [
        _t2_seats(gui, 0, 'bomber', 'hud_veh_icon_bomber'), _t2_altitude(gui, 1, 'bomber')]
    tank = _t2_pilot_meters(gui, 'assault', 'hud_veh_icon_assault') + [
        _t2_seats(gui, 2, 'assault', 'hud_veh_icon_assault')]
    turreteer = _t2_gunner_meters(gui, 'turreteer', 4) + [
        _t2_reticle('t2_reticle_tank', ['hud_ret_tankchaingun', 'hud_ret_tankmortar'], gui)]
    bombardier = _t2_gunner_meters(gui, 'bombardier', 1) + [
        _t2_reticle('t2_reticle_bombardier', ['hud_ret_shrike', None, 'hud_ret_targlaser'], gui)]
    meters = [_clipped(m) for m in _unique(cluster + shrike + bomber + tank + turreteer + bombardier)]
    ids = lambda ms: [m['id'] for m in cluster] + [m['id'] for m in ms]
    return {'canvas': CANVAS, 'pack': 'tribes2',
            'note': 'Tribes 2 pilots get a vehicle dashboard (dashboardHud, bottom centre) on top of the HUD cluster, '
                    'chat and clock; the ammo / weapons / inventory / objective displays are hidden '
                    '(hud.cs ClientCmdDisplayHuds "Pilot"). The Thundersword pilot and the Beowulf driver are unarmed '
                    'and have no reticle; "<ID>/1" are the gunner seats (bombardier, turreteer) whose weapons the '
                    "remake's pilot fires (docs/formats/tribes_vehicles.md section 5): a remake pilot of those "
                    'vehicles may add the gunner weapon box and reticle. Anchors follow horizSizing / vertSizing; '
                    'the dashboard keeps its centre and bottom.',
            'per_vehicle': {'SHRIKE': ids(shrike), 'THUNDERSWORD': ids(bomber), 'BEOWULF': ids(tank),
                            'THUNDERSWORD/1': ids(bombardier), 'BEOWULF/1': ids(turreteer)},
            'meters': meters}


def _unique(meters):
    seen, out = set(), []
    for m in meters:
        if m['id'] not in seen:
            seen.add(m['id'])
            out.append(m)
    return out


def _clipped(meter):
    """Clip the rect to the canvas (the 128x128 overhead icon hangs below the 120 px dashboard)."""
    x0, y0, x1, y1 = meter['rect']
    meter['rect'] = [max(x0, 0), max(y0, 0), min(x1, CANVAS[0] - 1), min(y1, CANVAS[1] - 1)]
    return meter


def _sizing_anchor(ctl):
    return make_anchor(ctl['fields'].get('horizSizing', 'right'), ctl['fields'].get('vertSizing', 'bottom'))


# ------------------------------------------------------------------ the HUD cluster, clock and chat (PlayGui.gui)

def _t2_cluster_meters(gui):
    play = gui.play
    back = find_control(play, 'hudClusterBack')
    meters = [{
        'id': 't2_cluster', 'kind': 'frame', 'rect': make_rect(back), 'anchor': _sizing_anchor(back),
        'layers': [gui.layer(back), gui.layer(find_control(play, 'hudCompassBack'))],
        'evidence': 'gui/PlayGui.gui hudClusterBack (line %d), hudCompassBack' % back['line'], 'confidence': 'H'}]
    for name, kind, source in (('damageHud', 'health', 'player.health'), ('energyHud', 'energy', 'player.energy'),
                               ('HeatHud', 'heat', 'player.heat')):
        meters.append(_t2_cluster_bar(find_control(play, name), kind, source))
    meters += [_t2_heading(gui), _t2_sensor(gui), _t2_clock(gui), _t2_messages(gui)]
    return meters


def _t2_cluster_bar(ctl, kind, source):
    f = ctl['fields']
    bar = {'source': source, 'rect': make_rect(ctl), 'fill': make_color(f['fillColor']),
           'direction': 'left_to_right', 'pulse_below': float(f.get('pulseThreshold', 0)),
           'pulse_ms': int(f.get('pulseRate', 0))}
    if 'heatWarning' in f:
        bar['warning_at'] = float(f['heatWarning'])
    return {'id': 't2_pilot_%s' % kind, 'kind': kind, 'rect': make_rect(ctl), 'anchor': _sizing_anchor(ctl),
            'layers': [], 'bar': bar, 'opacity': float(f.get('opacity', 1)),
            'colors': {'fill': make_color(f['fillColor'])},
            'note': "the pilot's own armour (not displayMounted: the vehicle's bars are on the dashboard)",
            'evidence': 'gui/PlayGui.gui %s %s (line %d)' % (ctl['class'], ctl['name'], ctl['line']),
            'confidence': 'H'}


def _t2_heading(gui):
    ctl, back = find_control(gui.play, 'compassHud'), find_control(gui.play, 'hudCompassBack')
    x0, y0, x1, y1 = make_rect(back)
    return {'id': 't2_heading', 'kind': 'heading', 'rect': make_rect(ctl), 'anchor': _sizing_anchor(ctl),
            'layers': [], 'center': [(x0 + x1 + 1) / 2.0, (y0 + y1 + 1) / 2.0], 'marks': ['N', 'E', 'S', 'W'],
            'mark_radius': 30, 'text': dict(CLOCK_TEXT, color=make_color(find_control(gui.play, 'compass')
                                                                          ['fields']['textColor'])),
            'evidence': 'gui/PlayGui.gui compassHud / HudCompass compass (textColor 0 255 0, clockProfile)',
            'confidence': 'H (rect), L (how HudCompass draws its marks: exe code, not read)'}


def _t2_sensor(gui):
    back, ping = find_control(gui.play, 'sensorHudBack'), find_control(gui.play, 'sensorHud')
    return {'id': 't2_sensor', 'kind': 'sensor', 'rect': make_rect(ping), 'anchor': _sizing_anchor(ping),
            'layers': [dict(gui.layer(back), tint=make_color(back['fields']['color']))],
            'states': {'idle': make_color(back['fields']['color']), 'pinged': make_color(ping['fields']['pingColor']),
                       'jammed': make_color(ping['fields']['jamColor'])},
            'pulse_ms': int(ping['fields']['pulseRate']),
            'evidence': 'gui/PlayGui.gui sensorHudBack / sensorHud (HudPulsingBitmap, hud_new_ping)',
            'confidence': 'H'}


def _t2_clock(gui):
    clock = find_control(gui.play, 'clockHud')
    x0, y0, x1, y1 = make_rect(clock)
    sub = [int(v) for v in clock['fields']['subRegion'].split()]
    return {'id': 't2_clock', 'kind': 'clock', 'rect': [x0, y0, x1, y1], 'anchor': _sizing_anchor(clock),
            'layers': [dict(gui.layer(clock), src_rect=sub)],
            'text': dict(CLOCK_TEXT, rect=[x0, y0, x1, y1], justify='center', format='mm:ss'),
            'alternate': 'lagHudIndicator (hud_disconnect) in its place when $showLagIcon',
            'evidence': 'gui/PlayGui.gui HudClock clockHud (subRegion %s)' % clock['fields']['subRegion'],
            'confidence': 'H'}


def _t2_messages(gui):
    outer = find_control(gui.chat, 'OuterChatHud')
    scroll = find_control(gui.chat, 'ChatScrollHud')
    return {'id': 't2_messages', 'kind': 'messages', 'rect': make_rect(outer), 'anchor': 'top_left',
            'layers': [], 'nine_slice': {'dba': 'CHAT_WINDOW', 'frames': list(range(9)), 'corner': 8},
            'text': dict(CHAT_TEXT, rect=make_rect(scroll), lines=4),
            'evidence': 'gui/ChatDlg.gui OuterChatHud (GuiChatBackProfile bitmapbase gui/hud_new_window), '
                        'GuiChatHudProfile ($ShellFont Univers 16); $pref::chatHudLength 1 = 72 px',
            'confidence': 'H'}


# ------------------------------------------------------------------ vehicle dashboard (client.cs)

def _t2_pilot_meters(gui, vehicle, icon):
    """clientCmdShowVehicleGauges, seat 0: the elements every pilot gets (client.cs ~488..608)."""
    dash, over = gui.gauge('vDiagramHud'), gui.gauge('vOverheadHud')
    return [
        {'id': 't2_dash', 'kind': 'frame', 'rect': make_rect(dash, gui.dash), 'anchor': 'bottom',
         'layers': [gui.layer(dash, gui.dash)],
         'evidence': 'scripts/client.cs vDiagramHud (line %d)' % dash['line'], 'confidence': 'H'},
        {'id': 't2_overhead_%s' % vehicle, 'kind': 'vehicle_icon', 'rect': make_rect(over, gui.dash),
         'anchor': 'bottom', 'layers': [gui.layer(over, gui.dash, icon)],
         'evidence': 'scripts/client.cs vOverheadHud (line %d) setBitmap("gui/%s.png")' % (over['line'], icon),
         'confidence': 'H'},
        _t2_dash_bar(gui, 'energy', 0), _t2_dash_bar(gui, 'health', 0), _t2_speed(gui)]


def _t2_dash_bar(gui, kind, occurrence, prefix='t2_vehicle'):
    names = {'energy': ('vEnergyFrame', 'vEnergyBar'), 'health': ('vDamageFrame', 'vDamageBar')}[kind]
    frame, bar = gui.gauge(names[0], occurrence), gui.gauge(names[1], occurrence)
    sx, sy, sw, sh = [int(v) for v in bar['fields']['subRegion'].split()]
    x0, y0 = gui.dash[0] + bar['origin'][0] + sx, gui.dash[1] + bar['origin'][1] + sy
    f = bar['fields']
    return {'id': '%s_%s' % (prefix, kind), 'kind': kind, 'rect': make_rect(frame, gui.dash), 'anchor': 'bottom',
            'layers': [gui.layer(frame, gui.dash)],
            'bar': {'source': 'vehicle.%s' % kind, 'rect': [x0, y0, x0 + sw - 1, y0 + sh - 1],
                    'fill': make_color(f['fillColor']), 'direction': 'left_to_right',
                    'pulse_below': float(f['pulseThreshold']), 'pulse_ms': int(f['pulseRate'])},
            'colors': {'fill': make_color(f['fillColor']), 'frame': make_color(f['frameColor'])},
            'evidence': 'scripts/client.cs %s / %s %s (line %d, subRegion %s, displayMounted)'
                        % (names[0], bar['class'], names[1], bar['line'], f['subRegion']),
            'confidence': 'H (fill direction M)'}


def _t2_text(ctl, base, **extra):
    text = dict(DASH_TEXT, rect=make_rect(ctl, base))
    text.update(extra)
    return text


def _t2_speed(gui):
    box = gui.gauge('vSpeedBox')
    return {'id': 't2_speed', 'kind': 'speed', 'rect': make_rect(box, gui.dash), 'anchor': 'bottom', 'layers': [],
            'text': _t2_text(gui.gauge('vSpeedText'), gui.dash, source='control_object.speed_mps',
                             scale=SPEED_TO_KPH, format='floor', update_ms=GAUGE_UPDATE_MS),
            'label': _t2_text(gui.gauge('vSpeedTxtLbl'), gui.dash, value=gui.gauge('vSpeedTxtLbl')['fields']['text']),
            'evidence': 'scripts/client.cs vSpeedBox (line %d), GuiControl::updateSpeed (mFloor(vel * 3.6), 500 ms)'
                        % box['line'], 'confidence': 'H'}


def _t2_altitude(gui, occurrence, vehicle):
    box = gui.gauge('vAltitudeBox', occurrence)
    value, label = gui.gauge('vAltitudeText', occurrence), gui.gauge('vAltitudeTxtLbl', occurrence)
    return {'id': 't2_altitude', 'kind': 'altitude', 'rect': make_rect(box, gui.dash), 'anchor': 'bottom',
            'layers': [gui.layer(box, gui.dash)],
            'text': _t2_text(value, gui.dash, source='control_object.altitude_m', format='int',
                             update_ms=GAUGE_UPDATE_MS),
            'label': _t2_text(label, gui.dash, value=label['fields']['text']),
            'evidence': 'scripts/client.cs vAltitudeBox (%s, line %d; the Shrike, Thundersword and Havoc pilots share '
                        'it), getControlObjectAltitude() every 500 ms' % (vehicle, box['line']),
            'confidence': 'H (altitude reference: exe, M)'}


def _t2_shrike_weapon(gui):
    group, back, icon = gui.gauge('vWeapHiliteOne'), gui.gauge('vWeapBkgdOne'), gui.gauge('vWeapIconOne')
    return {'id': 't2_weapon_shrike', 'kind': 'weapons', 'rect': make_rect(group, gui.dash), 'anchor': 'bottom',
            'layers': [gui.layer(back, gui.dash), gui.layer(icon, gui.dash)], 'weapons': ['blaster'],
            'evidence': 'scripts/client.cs case "Shrike" vWeapHiliteOne / vWeapBkgdOne / vWeapIconOne (line %d)'
                        % group['line'], 'confidence': 'H'}


def _t2_seats(gui, occurrence, vehicle, icon):
    seats = gui.gauge('vPassengerHud', occurrence)
    base = (gui.dash[0] + gui.gauge('vOverheadHud')['origin'][0], gui.dash[1] + gui.gauge('vOverheadHud')['origin'][1])
    dots = [gui.layer(c, base) for c in seats['children']]
    return {'id': 't2_seats_%s' % vehicle, 'kind': 'crew', 'rect': make_rect(seats, base), 'anchor': 'bottom',
            'layers': [], 'seats': dots,
            'shown': 'a seat dot is drawn while that seat is taken (clientCmdCheckPassengers; seat 0 = pilot)',
            'evidence': 'scripts/client.cs vPassengerHud (line %d) added to vOverheadHud (%s)' % (seats['line'], icon),
            'confidence': 'H'}


def _t2_reticle(meter_id, bitmaps, gui):
    """Reticle per selected weapon (None = no reticle: the bomb sight HudBombSight 67x67 at 286,206)."""
    cx, cy = CANVAS[0] // 2, CANVAS[1] // 2
    x0, y0 = cx - RETICLE_SIZE // 2, cy - RETICLE_SIZE // 2
    ring = find_control(gui.play, 'reticleFrameHud')
    per_weapon = [gui.layer({'origin': [x0, y0], 'fields': {}}, bitmap=b) if b else None for b in bitmaps]
    return {'id': meter_id, 'kind': 'reticle', 'rect': [x0, y0, x0 + RETICLE_SIZE - 1, y0 + RETICLE_SIZE - 1],
            'anchor': 'center', 'layers': [per_weapon[0]], 'per_weapon': per_weapon,
            'opacity': float(find_control(gui.play, 'reticleHud')['fields']['opacity']),
            'range_ring': dict(gui.layer(ring), shown='with $vehicleReticle[.., frame] (hud.cs:145)'),
            'evidence': 'scripts/hud.cs $vehicleReticle (145..155), client.cs reticleHud.setBitmap, '
                        'gui/PlayGui.gui retCenterHud / reticleHud (HudCrosshair autoCenter, opacity 0.5)',
            'confidence': 'H'}


def _t2_gunner_meters(gui, seat, bar_occurrence):
    """Turreteer / bombardier dash (seat 1): weapon box with selection highlights and flipped bars."""
    hud = gui.gauge('%sHud' % seat)
    layers, highlights = [], {}
    for ctl in make_flat(hud['children']):
        if 'bitmap' not in ctl['fields']:
            continue
        layer = gui.layer(ctl, (gui.dash[0], gui.dash[1]))
        if ctl['name'].endswith('Hilite'):
            highlights[ctl['name'][len('vWeap'):-len('Hilite')]] = layer
        else:
            layers.append(layer)
    box = {'id': 't2_weapons_%s' % seat, 'kind': 'weapons', 'rect': make_rect(hud, gui.dash), 'anchor': 'bottom',
           'layers': layers, 'highlight_per_weapon': highlights,
           'evidence': 'scripts/client.cs %sHud (line %d), clientCmdSetVWeaponsHudActive (hud.cs:163)'
                       % (seat, hud['line']), 'confidence': 'H'}
    prefix = 't2_%s' % seat
    return [box, _t2_dash_bar(gui, 'energy', bar_occurrence, prefix), _t2_dash_bar(gui, 'health', bar_occurrence, prefix)]
