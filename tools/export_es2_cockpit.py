"""Export the Earthsiege 2 cockpits to gamedata/es2/cockpit/ for the Godot remake (same layout as the
Earthsiege 1 export, tools/export_cockpit.py, read by game/games/es1/cockpit/).

    python tools/export_es2_cockpit.py [outdir]      (default gamedata/es2/cockpit)

Decoders: tools/cockpit_es2.py (GAU, edge regions, code geometry), tools/cockpit.py (VUE, PDG, OFS, STRINGS0),
tools/shell.py (DFN/HFN fonts). Spec: docs/formats/cockpit.md section 8.

The 640x480 set is exported (HB0..HB2 panels, HBA bitmaps, HFN fonts: what DBSIM loads in its 640x480 mode,
[0x4d25bb] == 3); bitmaps without a 640x480 version (STATIC, FLYERS, pilots) fall back to the DBA (scale 1).
Bitmaps and fonts are 8-bit palette-index PNGs (L mode, index 0 = transparent): the engine colours them with
the cockpit's palette, which differs per Herc (cockpit colour block, palettes/<HERC>.json).

Output:
  palettes/<HERC>.json        256 x [r,g,b]: WORLD0.DPL + COCKPIT.DPL[0x20 + 24 * scheme] in 0x2A..0x41
                              (0x429ac4: scheme = unit DAT word +0x50, the shell Herc type)
  layout/<HERC>.json          decoded layout in the Earthsiege 1 schema + canvas / palette / panels / views
  panels/<HERC>_HB<k>.png     front view, look-down panel, side view (640x480)
  dba/<NAME>/<i>.png + dba/<NAME>.json      instrument bitmaps ({count, sizes, scale})
  fonts/<NAME>.png + .json    font atlases ({height, chars: {code: [x, y, w]}, scale})
  pdg/<UNIT>.json + pdg/<UNIT>_<i>.png      damage diagrams (regions in 320x240 pixels, images at "scale")
  pilots/<PILOTn[S]>_<i>.png + pilots/<PILOTn>.json   comm-video parts + OFS offsets
  strings0.json               STRINGS0 label groups
  skin.json                   which bitmaps, frames, fonts, colours and string groups the instruments use
"""
import glob
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cockpit  # noqa: E402
import cockpit_es2  # noqa: E402
import gfx  # noqa: E402
import shell  # noqa: E402
import siege_paths as P  # noqa: E402
from PIL import Image  # noqa: E402

SIM = P.work('es2', 'extracted', 'SIMVOL0')
EXE = P.work('es2', 'original', 'DBSIM.EXE')
HERCS = ['OUTLAW', 'RAPTOR2', 'TOMAHAWK', 'SAMSON', 'COLOSSUS', 'APOCA', 'OGRE', 'MAVERICK', 'RAZOR']
BITMAPS = ['HUD', 'HUDHTICK', 'MFD', 'MFD_DMG', 'RADAR', 'HDD', 'PWEAPONS', 'WPN_DMG', 'THROTTLE', 'SYSBUTTN',
           'ICONS', 'STATIC', 'WEAPONS', 'FLYERS', 'VEHICLES', 'BASES']
FONTS = ['CPBLACK', 'CPBLUE', 'CPGREEN', 'CPGREY', 'CPOFF', 'CPON', 'CPORANGE', 'CPPRESS', 'CPRED', 'CPYLW',
         'WHITE', 'GRAY', 'DARK', 'GREEN', 'RED', 'HUD1', 'HUD2', 'HUD3']
WORLD_PALETTE = 'WORLD0'
DAT_SCHEME = 0x50             # unit DAT word: shell Herc type = cockpit colour scheme (0x429acd reads +0x52 of
                              # the record, which starts 2 bytes before the DAT data, cf. the flyer flag 0x431f87)
HI_RES = 2
LOW_RES = 1

# Which art the instruments use (engine: CockpitSkin; Earthsiege 1 values are its defaults). Frame numbers are
# indices into the named bitmap arrays; colours are palette indices; strings are STRINGS0 group numbers.
SKIN = {
    'buttons': {'dba': 'PBUTTONS'},
    'weapons': {
        'dba': 'PWEAPONS',
        'led_selected': -1, 'led_ready': 4, 'led_charging': 5, 'led_destroyed': 6,   # 0x4427c0..0x442762
        'frame_selected': 0, 'frame_idle': 1,                                        # 0x44287b / 0x44288c
        'font': 'GRAY', 'font_selected': 'WHITE',                                    # 0x4427e1 / 0x4427eb
        'bar_marker': -1, 'bar_ready': 0x20, 'bar_charging': 0x22,                   # slider colours 0x442ae3
        'value_font': 'GRAY', 'value_font_empty': 'RED',
    },
    'indicators': {'lamp_count': 1, 'button_off': -1, 'button_on': -1,
                   'font_on': 'GREEN', 'font_off': 'GRAY', 'button_font_on': 'WHITE', 'button_font_off': 'GRAY'},
    'engine_bar': {'source': 'capacitor', 'colors': [0x0e, 0x0a]},                   # EnergyPoolGauge (L colours)
    'shields': {'color_ok': 0x0e, 'color_low': 0x0a, 'lamp_on': 0x0e, 'lamp_off': 0x11},
    'throttle': {'dba': 'THROTTLE', 'lever': 1, 'lever_size': [14, 6],               # slider marker 0x447ef7
                 'bar_color': 0x0e, 'reverse_color': 0x0d},                        # BarGraphV colours (L)
    'message': {'font': 'GREEN'},
    'hud': {
        'tape_dba': 'HUDHTICK', 'dba': 'HUD',
        'torso_track': 11, 'torso_marker': 12, 'torso_marker_centred': 13,         # 0x43b4b6 / 0x43b525
        'torso_centred_units': 300,                                                # +-0x12c of 65536 per turn
        'reticle': [0, 1, 2],                                                      # 0x43b7e0: free / hostile / friend
        'reticle_lock_px': 5,
        'target_pipper': [3, 7], 'target_corner': [4, 8],                          # 0x43bc05: green / red sets
        'text_font': 'HUD2', 'nav_font': 'HUD3',                                   # 0x43d27d / 0x43d4da
        'marker_color': 0x4c, 'text_color': -1,
        'altimeter': {'top': 15, 'bottom': 16, 'marker': 17, 'scale': 18, 'height': 36,  # flyers, 0x43dd70
                      'ceiling_margin': 5000},
    },
    'mfd': {
        'dba': 'MFD', 'mode_off': 3, 'mode_on': 4, 'mode_step': 0, 'mode_labels': False,   # case 5 of 0x44552a
        'range_step_button': 8, 'range_down_button': -1, 'range_up_button': -1,   # RANGE = STRINGS0 5 item 8
        'page_frames': [1, 1, -1, 2, 1, -1],                                       # 0x4461f7 per page
        'option_buttons': [[7], [10], [], [8, 9, 11, 12], [7], []],                # table 0x49cbd8
        'option_frames': {'7': 5, '8': 7, '9': 7, '10': 5, '11': 9, '12': 9},      # cases 1..3
        'option_font': 'WHITE', 'title_font': 'DARK', 'page_font': 'GREEN', 'label_font': 'RED',
        'radar_dba': 'RADAR', 'radar_frames': 10, 'radar_fps': 10.0,               # ping rings (L timing)
        'radar_origin': [39, 3], 'radar_centre': [66, 30], 'radar_radius': 26,     # right of the options (L)
        'radar_colors': {'friend': 0x0e, 'enemy': 0x0a, 'target': 0x0d, 'target_blink': 0x0f, 'nav': 0x09},
        'status_picture': [2, 13, 44, 46], 'diagram_offset': [2, 13], 'status_text_x': 47,  # PSTATUS.BND
        'status_rows': [16, 23, 32, 40, 49], 'own_rows': [16, 23, 32, 40, 49],
    },
    'hdd': {
        'dba': 'HDD', 'page_off': 25, 'page_on': 26, 'page_step': 0,               # page lamps (M)
        'arrows': [5, 7, 9, 11], 'button6': 21, 'button7': 23,                     # scroll pad, zoom (M)
        'zoom_in_button': 7, 'zoom_out_button': 6,                                 # 23/24 "+", 21/22 "-" art
        'icons': {'dba': 'ICONS', 'nav_first': 78, 'self': 42, 'friend': 33, 'enemy': 24, 'target': 60,
                  'octant_offsets': [4, 0, 5, 1, 6, 2, 7, 3]},
        'font': 'GREEN', 'title_font': 'GREEN', 'grid_color': 0x24, 'led_color': 0x0e,
    },
    'damage': {'colors': [], 'shades': 1},                                          # filled by make_skin()
    'strings': {'indicators': 4, 'mfd': 5, 'own_status': 10, 'hdd_pages': 11, 'damage_titles': 12,
                'components': 13, 'no_target': 19, 'no_info': 19, 'target': 20, 'status': 21, 'target_status': 28,
                'range': 31, 'missile': 35, 'ecm': -1},
    'string_items': {'no_target': 0, 'no_info': 1, 'target': 1},
}


# Damage level colours (0x438624, region flag 0): >= 90 % / 74 % / 51 % / 1 % / destroyed = COLORS.DAT words
# 12, 15, 20, 9, 18 (read at 0x43865e, 0x438671, 0x438684, 0x438695, 0x4386a3).
DAMAGE_COLOR_ENTRIES = [12, 15, 20, 9, 18]


def make_skin(colors):
    skin = json.loads(json.dumps(SKIN))
    skin['damage']['colors'] = [colors[i] for i in DAMAGE_COLOR_ENTRIES]
    return skin


def rd(*p):
    with open(os.path.join(SIM, *p), 'rb') as f:
        return f.read()


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def save_indexed(b, path):
    """8-bit palette-index PNG (index 0 = transparent; the engine colours it with the cockpit palette)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n = b['w'] * b['h']
    Image.frombytes('L', (b['w'], b['h']), bytes(b['pixels'][:n]).ljust(n, b'\0')).save(path)


def read_bitmaps(name):
    """(bitmaps, scale): the 640x480 HBA when the disc has one, else the DBA."""
    hba = os.path.join(SIM, 'HBA', name + '.HBA')
    if os.path.exists(hba):
        return gfx.read_any(rd('HBA', name + '.HBA')), HI_RES
    return gfx.read_any(rd('DBA', name + '.DBA')), LOW_RES


def make_palette(scheme):
    import export_es2
    return export_es2.make_world_palette(WORLD_PALETTE, scheme)


def read_scheme(herc):
    return struct.unpack_from('<h', rd('DAT', herc + '.DAT'), DAT_SCHEME)[0]


def verify_exe():
    """Check the code constants cockpit_es2 relies on (skipped without DBSIM.EXE)."""
    if not os.path.exists(EXE):
        return 'DBSIM.EXE missing: code constants not re-verified'
    from export_es2_weapons import PE
    pe = PE(EXE)
    bad = [hex(va) for va, (b, _) in cockpit_es2.EVIDENCE.items() if pe.at(va, len(b)) != b]
    if bad:
        raise SystemExit('DBSIM.EXE build differs at %s - re-check docs/formats/cockpit.md section 8' % bad)
    return 'verified %d code sites' % len(cockpit_es2.EVIDENCE)


def export_bitmaps(out):
    for n in BITMAPS:
        bs, scale = read_bitmaps(n)
        for i, b in enumerate(bs):
            save_indexed(b, os.path.join(out, 'dba', n, '%d.png' % i))
        write_json(os.path.join(out, 'dba', n + '.json'),
                   {'count': len(bs), 'sizes': [[b['w'], b['h']] for b in bs], 'scale': scale})


def export_fonts(out):
    for n in FONTS:
        f = shell.read_dfn(rd('HFN', n + '.HFN'))
        _rgba, idx, rects = shell.font_atlas(f)
        os.makedirs(os.path.join(out, 'fonts'), exist_ok=True)
        idx.save(os.path.join(out, 'fonts', n + '.png'))
        chars = {str(g['code']): [x, y, w] for g, (x, y, w, h) in zip(f['glyphs'], rects)}
        write_json(os.path.join(out, 'fonts', n + '.json'), {'height': f['height'], 'chars': chars, 'scale': HI_RES})


def export_panels(out, herc):
    for k in '012':
        b = gfx.read_any(rd('HB' + k, '%s.HB%s' % (herc, k)))[0]
        save_indexed(b, os.path.join(out, 'panels', '%s_HB%s.png' % (herc, k)))


def make_gun_slots(hercs, herc):
    return [g.get('display_index', i) for i, g in enumerate(hercs.get(herc, {}).get('guns', []))]


def export_layout(out, herc, hercs):
    gau = cockpit_es2.read_gau(rd('GAU', herc + '.GAU'))
    lay = cockpit_es2.make_layout(gau)
    scheme = read_scheme(herc)
    lay.update({
        'herc': herc, 'pack': 'es2', 'palette': 'palettes/%s.json' % herc, 'palette_scheme': scheme,
        'views': cockpit.read_vue(rd('VUE', herc + '.VUE')),
        'windows': [[list(s) for s in cockpit_es2.read_edges(rd('ED%d' % k, '%s.ED%d' % (herc, k)))]
                    for k in range(4)],
        'gun_slots': make_gun_slots(hercs, herc),
        'panels': {'front': 'panels/%s_HB0.png' % herc, 'look_down': 'panels/%s_HB1.png' % herc,
                   'side': 'panels/%s_HB2.png' % herc},
    })
    write_json(os.path.join(out, 'layout', herc + '.json'), lay)
    write_json(os.path.join(out, 'palettes', herc + '.json'), make_palette(scheme))


def read_colors():
    """DAT/COLORS.DAT: 27 palette indices, loaded into 0x4d3c00 by 0x467a60 (the damage colours 0x438624 use)."""
    d = rd('DAT', 'COLORS.DAT')
    return list(struct.unpack('<%dh' % (len(d) // 2), d))


def resolve_region_colors(pdg, colors):
    """ES2 PDG region colours are COLORS.DAT entries (region 12 -> COLORS[12] = 0x0e, the green the unit bitmaps
    are drawn in; M: from the bitmap pixels): store the palette index the recolour matches."""
    for im in pdg['images']:
        for reg in im['regions']:
            reg['color_entry'] = reg['color']
            reg['color'] = colors[reg['color']] if 0 <= reg['color'] < len(colors) else reg['color']


def export_diagrams(out):
    colors = read_colors()
    write_json(os.path.join(out, 'pdg', 'WEAPONS.json'), {'sizes_wh': cockpit.read_weapons_pdg(rd('PDG', 'WEAPONS.PDG'))})
    for p in sorted(glob.glob(os.path.join(SIM, 'PDG', '*.PDG'))):
        name = os.path.splitext(os.path.basename(p))[0]
        if name == 'WEAPONS':
            continue
        pdg = cockpit.read_pdg(open(p, 'rb').read())
        resolve_region_colors(pdg, colors)
        try:
            bs, scale = read_bitmaps(name)
        except FileNotFoundError:
            bs, scale = [], LOW_RES
        for i, b in enumerate(bs):
            save_indexed(b, os.path.join(out, 'pdg', '%s_%d.png' % (name, i)))
        pdg['image_count'] = len(bs)
        pdg['scale'] = scale
        write_json(os.path.join(out, 'pdg', name + '.json'), pdg)


def export_pilots(out):
    for p in sorted(glob.glob(os.path.join(SIM, 'OFS', '*.OFS'))):
        name = os.path.splitext(os.path.basename(p))[0]
        meta = {'ofs': cockpit.read_ofs(open(p, 'rb').read()), 'format': '(dba_index, dx, dy)', 'sets': {}}
        for suf in ('', 'S'):
            try:
                bs = gfx.read_any(rd('DBA', name + suf + '.DBA'))
            except FileNotFoundError:
                continue
            for i, b in enumerate(bs):
                save_indexed(b, os.path.join(out, 'pilots', '%s%s_%d.png' % (name, suf, i)))
            meta['sets'][name + suf] = [[b['w'], b['h']] for b in bs]
        write_json(os.path.join(out, 'pilots', name + '.json'), meta)


def load_hercs():
    path = P.pack('es2', 'gameplay', 'hercs.json')
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def export(out):
    note = verify_exe()
    os.makedirs(out, exist_ok=True)
    export_bitmaps(out)
    export_fonts(out)
    hercs = load_hercs()
    for h in HERCS:
        export_panels(out, h)
        export_layout(out, h, hercs)
    export_diagrams(out)
    export_pilots(out)
    write_json(os.path.join(out, 'strings0.json'), cockpit.read_strings0(rd('STR', 'STRINGS0.STR')), 1)
    write_json(os.path.join(out, 'skin.json'), make_skin(read_colors()), 1)
    print('es2 cockpits: %d Hercs -> %s (%s)' % (len(HERCS), out, note))


def main(argv=None):
    argv = sys.argv if argv is None else argv
    export(argv[1] if len(argv) > 1 else P.pack('es2', 'cockpit'))


if __name__ == '__main__':
    main()
