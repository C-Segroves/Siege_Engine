"""Export the Earthsiege front-end shell (GO.EXE screens) for the Godot runtime.

    python tools/export_shell.py [outdir]        (default gamedata/es1/shell)

Reuses tools/shell.py (decoders, spec in docs/formats/shell.md).  Everything image-like is written
as **palette-index PNGs** in LA mode (L = palette index, A = 0 where index 0 is transparent) so the
Godot shell can composite a true 8-bit 320x200 frame buffer and apply palettes / palette fades in a
shader exactly like VGA mode 13h.  RGB previews with the palette the shell uses go to `preview/`.

Layout of <outdir>:
  palettes/<SUB>/<NAME>.json      256 x [r,g,b] (8-bit)   SUB = RES32 | INTRO | ANM
  bg/<SUB>/<NAME>.png             full-screen DBM pictures (index PNG, opaque)
  dba/<SUB>/<NAME>.png + .json    sprite sheets (index PNG) + frame rects [x,y,w,h]
  fonts/<NAME>.png + .json        DFN glyph atlas (index PNG) + metrics (height, first, char rects)
  cursors/<NAME>.png, cursors.json
  dlg/MENU<n>.json, dlg/menu_graph.json
  strings/<NAME>.json             ENG/*.BIN tables, STR groups (<NAME>_str.json)
  ttm/<SUB>/<NAME>.json           decoded TTM scripts (frames, ops, labels, palette hint)
  anm/<name>/NNN.png              ESIEGE2/3 blast-door animation, RGBA with the green key removed
  shell.json                      styles, menu->region, region->music, talking-head tables, palette assignment
  preview/                        RGB renders (backgrounds with their palette, menu composites)
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import shell  # noqa: E402
from shell import (SHELL, RES32, _p, _rd, read_dlg, read_text_bin, read_str, read_ttm, ttm_to_json,  # noqa: E402
                   read_dfn, read_styles, read_files_dat, read_dci, palette, palette_for, ttm_resource_palettes,
                   MENU_REGION, REGION_MUSIC, POPUP_PARENT, render_menu)
from gfx import read_dpl, read_dbm, read_dba, to_image  # noqa: E402
from PIL import Image  # noqa: E402

import siege_paths as P  # noqa: E402
SUBDIRS = ('RES32', 'INTRO', 'DBA', 'ANM')
# GO.EXE sound table 0x828c0 from id 1 (REGION_MUSIC values are these ids; None = sound effects); see
# tools/music_games.py for when each track plays
MUSIC_NAMES = ['menu', 'menu', 'shella', 'shellb', 'shellc', 'shella', 'death', 'win2', None, None, None,
               'intro1', 'intro2', None, 'rubble', 'ice', 'desert', 'volcano', 'losing']


def _w(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fo:
        json.dump(obj, fo, indent=1)


def index_image(bmp, transparent0):
    """DBM dict -> 'LA' PIL image: L = palette index, A = 255 (or 0 for index 0 when transparent0)."""
    w, h = bmp['w'], bmp['h']
    pix = bytes(bmp['pixels'][:w * h]).ljust(w * h, b'\0')
    lum = Image.frombytes('L', (w, h), pix)
    alpha = lum.point(lambda v: 0 if v == 0 else 255) if transparent0 else Image.new('L', (w, h), 255)
    return Image.merge('LA', (lum, alpha))


def export_palettes(out):
    names = {}
    for sub in SUBDIRS:
        for path in sorted(glob.glob(_p(SHELL, sub, '*.DPL'))):
            n = os.path.splitext(os.path.basename(path))[0]
            _w(_p(out, 'palettes', sub, n + '.json'), [list(c[:3]) for c in read_dpl(_rd(path))])
            names.setdefault(n, sub)
    return names


def export_backgrounds(out, tmap):
    assign = {}
    for sub in ('RES32', 'INTRO'):
        for path in sorted(glob.glob(_p(SHELL, sub, '*.DBM'))):
            n = os.path.splitext(os.path.basename(path))[0]
            b = read_dbm(_rd(path))
            os.makedirs(_p(out, 'bg', sub), exist_ok=True)
            index_image(b, False).save(_p(out, 'bg', sub, n + '.png'))
            pn = palette_for(n, tmap)
            assign['bg/%s/%s' % (sub, n)] = pn
            os.makedirs(_p(out, 'preview', 'bg'), exist_ok=True)
            to_image(b, palette(pn), False).save(_p(out, 'preview', 'bg', n + '.png'))
    return assign


def export_dbas(out, tmap):
    assign = {}
    for sub in ('RES32', 'INTRO', 'DBA'):
        for path in sorted(glob.glob(_p(SHELL, sub, '*.DBA'))):
            n = os.path.splitext(os.path.basename(path))[0]
            try:
                frames = read_dba(_rd(path))
            except AssertionError:
                continue
            W = sum(f['w'] for f in frames) + len(frames)
            H = max([f['h'] for f in frames] + [1])
            sheet = Image.new('LA', (max(1, W), H), (0, 0))
            x, rects = 0, []
            for f in frames:
                if f['w'] and f['h']:
                    sheet.paste(index_image(f, True), (x, 0))
                rects.append([x, 0, f['w'], f['h']])
                x += f['w'] + 1
            os.makedirs(_p(out, 'dba', sub), exist_ok=True)
            sheet.save(_p(out, 'dba', sub, n + '.png'))
            pn = palette_for(n, tmap)
            _w(_p(out, 'dba', sub, n + '.json'), {'palette': pn, 'frames': rects})
            assign['dba/%s/%s' % (sub, n)] = pn
    return assign


def export_fonts(out):
    for path in sorted(glob.glob(_p(SHELL, 'DFN', '*.DFN'))):
        name = os.path.splitext(os.path.basename(path))[0]
        f = read_dfn(_rd(path))
        cols, pad = 16, 1
        h = f['height']
        cw = max(f['max_width'], max(g['w'] for g in f['glyphs'])) + pad
        rows = (len(f['glyphs']) + cols - 1) // cols
        atlas = Image.new('LA', (cols * cw, rows * (h + pad)), (0, 0))
        chars = {}
        for i, g in enumerate(f['glyphs']):
            x, y = (i % cols) * cw, (i // cols) * (h + pad)
            if g['w']:
                atlas.paste(index_image({'w': g['w'], 'h': h, 'pixels': g['pixels']}, True), (x, y))
            chars[str(g['code'])] = [x, y, g['w']]
        os.makedirs(_p(out, 'fonts'), exist_ok=True)
        atlas.save(_p(out, 'fonts', name + '.png'))
        _w(_p(out, 'fonts', name + '.json'), {'name': name, 'height': h, 'line_height': f['line_height'],
                                              'first': f['first'], 'max_width': f['max_width'],
                                              'encoding': 'cp437 byte', 'chars': chars})


def export_strings(out):
    for path in sorted(glob.glob(_p(SHELL, 'ENG', '*.BIN')) + [_p(SHELL, 'CFG', 'FILENAME.BIN')]):
        _w(_p(out, 'strings', os.path.basename(path)[:-4] + '.json'), read_text_bin(_rd(path)))
    for path in sorted(glob.glob(_p(SHELL, 'STR', '*.STR'))):
        _w(_p(out, 'strings', os.path.basename(path)[:-4] + '_str.json'), read_str(_rd(path)))


def export_dialogs(out):
    graph = {}
    for path in sorted(glob.glob(_p(SHELL, 'DLG', '*.DLG'))):
        d = read_dlg(path)
        mid = d['menu']
        d['music'] = MUSIC_NAMES[REGION_MUSIC[d['region']] - 1] if d['region'] in REGION_MUSIC else None
        _w(_p(out, 'dlg', 'MENU%d.json' % mid), d)
        graph[str(mid)] = {'title': d['title'], 'region': d['region'], 'panel': d['panel'],
                           'buttons': [{'label': c['label'], 'id': c['id'], 'hotkey': c['hotkey_name'],
                                        'target_menu': c.get('target_menu'), 'command': c.get('command')}
                                       for c in d['controls'] if c['type'] == 3]}
    _w(_p(out, 'dlg', 'menu_graph.json'), graph)


def export_ttms(out, tmap):
    for sub in ('RES32', 'INTRO'):
        for path in sorted(glob.glob(_p(SHELL, sub, '*.TTM'))):
            n = os.path.basename(path)[:-4]
            j = ttm_to_json(read_ttm(_rd(path)))
            j['name'] = n
            j['dir'] = sub
            j['palette_hint'] = palette_for(n, tmap)
            # compact the op list: [opcode, name, args]
            j['frames'] = [[[o['name'], o['args']] for o in fr['ops']] for fr in j['frames']]
            _w(_p(out, 'ttm', sub, n + '.json'), j)


def export_cursors(out):
    meta = {}
    for p in sorted(glob.glob(_p(SHELL, 'DCI', '*.DCI')) + glob.glob(_p(RES32, '*.DCI'))):
        n = os.path.splitext(os.path.basename(p))[0]
        try:
            c = read_dci(_rd(p))
        except AssertionError:
            continue
        os.makedirs(_p(out, 'cursors'), exist_ok=True)
        index_image(c['bitmap'], True).save(_p(out, 'cursors', n + '.png'))
        meta[n] = {'hotspot': c['hotspot'], 'w': c['bitmap']['w'], 'h': c['bitmap']['h']}
    _w(_p(out, 'cursors', 'cursors.json'), meta)


def export_anm(out):
    """ESIEGE2/3 blast-door frames (already decoded by tools/video.py) -> RGBA with the green key cleared."""
    src = P.pack('es1', 'video', 'anm')
    res = {}
    for d in sorted(glob.glob(_p(src, '*_frames'))):
        name = os.path.basename(d)[:-7]
        frames = sorted(glob.glob(_p(d, '*.png')))
        os.makedirs(_p(out, 'anm', name), exist_ok=True)
        for f in frames:
            im = Image.open(f).convert('RGBA')
            px = im.getdata()
            im.putdata([(0, 0, 0, 0) if p[:3] == (0, 255, 0) else p for p in px])
            im.save(_p(out, 'anm', name, os.path.basename(f)))
        res[name] = {'frames': len(frames), 'fps': 15}
    return res


# ---------------------------------------------------------------- career hangar (GO.EXE inventor.cpp / mechman.cpp)
# Herc types in shell order (= sim MECH type 0..7). The original hangar art (CFG\<c>.DAT, HOTSPOT.DAT,
# <p>WEP1.DBA) is documented in docs/formats/shell.md section 7b; the game draws its hangar in 3D.
HANGAR_HERCS = ['ROADRUNN', 'GUNSLING', 'RAPTOR', 'TOMAHAWK', 'PATRIOT', 'PANTHER', 'HERCULES', 'COLOSSUS']
# Shell weapon index (= sim WEAPONS.DAT order, docs/formats/gameplay.md section 4); 17 = empty hardpoint.
SHELL_WEAPONS = ['ATC20', 'ATC35', 'ATC50', 'ELF', 'EMP', 'GREN', 'LAS100', 'LAS200', 'LAS300', 'MLRS6', 'MLRS8',
                 'MLRS10', 'PBEAM', 'ECM']


def _words(b):
    import struct
    return list(struct.unpack('<%dh' % (len(b) // 2), b[:len(b) // 2 * 2]))


def _read_mec_hercs(b):
    """CAR\\CAR_INIT.DAT / SM_INIT.DAT: 14-byte header (word 6 = herc count), then per herc
    {slot, type, n, n x weapon (17 = none), n x missile type (5 = n/a), u16 ? (2), 33 x condition %}."""
    w = _words(b)
    n = w[6]
    i = 7
    out = []
    for _ in range(n):
        slot, typ, nw = w[i], w[i + 1], w[i + 2]
        i += 3
        weapons = w[i:i + nw]
        i += nw
        missiles = w[i:i + nw]
        i += nw
        tail = w[i]
        i += 1
        cond = w[i:i + 33]
        i += 33
        out.append({'slot': slot, 'type': typ, 'weapons': weapons, 'missiles': missiles, 'unknown': tail,
                    'condition': cond})
    return out


def _read_armory(b):
    """CAR\\C_ARMORY.DAT / S_ARMORY.DAT: u16 n, n x {u16 weapon, u16 count, count x condition %}."""
    w = _words(b)
    i = 1
    out = []
    for _ in range(w[0]):
        wid, cnt = w[i], w[i + 1]
        out.append({'weapon': wid, 'count': cnt, 'condition': w[i + 2:i + 2 + cnt]})
        i += 2 + cnt
    return out


# BST\TECH_0.DAT record kinds (GO.EXE 0x1e16): 0 = Herc type (sim MECH order), 1 = weapon (WEAPONS.DAT order)
TECH_KINDS = {0: 'herc', 1: 'weapon'}
ES1_ZONES = os.path.join(os.path.dirname(SHELL), 'ZONES')


def _read_tech(b):
    """BST\TECH_0.DAT (career) / TECH_SNG.DAT (single missions), loaded by GO.EXE 0x158ff into the tech
    object (ctor 0x1ee3: 8 Herc + 17 weapon entries {s16 early, s16 late, u8 released}): u16 n,
    n x {s16 kind, s16 index, s16 early, s16 late}. Release test 0x1f78(missions flown): an item with
    early/late != -1 is released once missions >= early while the pilot's standing (0x36837) is good,
    and at the latest once missions >= late; -1 = never. A release raises TechReleaseAlert."""
    w = _words(b)
    out = []
    for k in range(w[0]):
        kind, index, early, late = w[1 + 4 * k:5 + 4 * k]
        out.append({'kind': TECH_KINDS.get(kind, kind), 'index': index, 'early': early, 'late': late})
    return out


def export_hangar(out):
    hercs = [{'type': t, 'unit': unit} for t, unit in enumerate(HANGAR_HERCS)]
    car = _p(SHELL, 'CAR')
    data = {
        'source': 'GO.EXE CAR/*_INIT.DAT, CAR/?_ARMORY.DAT, ZONES BST/TECH_*.DAT (tools/export_shell.py)',
        'weapons': SHELL_WEAPONS, 'empty_weapon': 17, 'missile_types': ['SARH', 'ARH', 'ARM', 'EO'],
        'hercs': hercs,
        'career_init': _read_mec_hercs(_rd(_p(car, 'CAR_INIT.DAT'))),
        'career_armory': _read_armory(_rd(_p(car, 'C_ARMORY.DAT'))),
        'single_init': _read_mec_hercs(_rd(_p(car, 'SM_INIT.DAT'))),
        'single_armory': _read_armory(_rd(_p(car, 'S_ARMORY.DAT'))),
        'career_tech': _read_tech(_rd(_p(ES1_ZONES, 'BST', 'TECH_0.DAT'))),
        'single_tech': _read_tech(_rd(_p(ES1_ZONES, 'BST', 'TECH_SNG.DAT'))),
        'tech_weapons': SHELL_WEAPONS + ['EMP_CYBRID', 'PBEAM_CYBRID', 'MISSL_CYBRID'],
    }
    _w(_p(out, 'hangar.json'), data)


def export_all(out):
    os.makedirs(out, exist_ok=True)
    tmap = ttm_resource_palettes()
    pal_dirs = export_palettes(out)
    assign = {}
    assign.update(export_backgrounds(out, tmap))
    assign.update(export_dbas(out, tmap))
    export_fonts(out)
    export_strings(out)
    export_dialogs(out)
    export_ttms(out, tmap)
    export_cursors(out)
    anm = export_anm(out)
    export_hangar(out)
    misc = {
        'styles': read_styles(_rd(_p(SHELL, 'CFG', 'STYLES.DAT'))),
        'menu_region': {str(k): v for k, v in MENU_REGION.items()},
        'popup_parent': {str(k): v for k, v in POPUP_PARENT.items()},
        'region_music': {str(k): MUSIC_NAMES[v - 1] for k, v in REGION_MUSIC.items()},
        'music_names': MUSIC_NAMES,
        'palette_dirs': pal_dirs,
        'palette_assignment': assign,
        'snc_files': {os.path.basename(p)[:2]: read_files_dat(_rd(p))
                      for p in sorted(glob.glob(_p(SHELL, 'SNC', '*_FILES.DAT')))},
        'anm': anm,
        'startup': ['INTRO/DYNAMIX', 'INTRO/LEAD_IN', 'INTRO/IINTRO', 'INTRO/EARTH_W'],
        'credits': ['INTRO/CREDIT_A', 'INTRO/CREDIT_B'],
    }
    _w(_p(out, 'shell.json'), misc)
    os.makedirs(_p(out, 'preview', 'menus'), exist_ok=True)
    for path in sorted(glob.glob(_p(SHELL, 'DLG', '*.DLG'))):
        mid = int(os.path.basename(path)[4:-4])
        render_menu(mid, _p(out, 'preview', 'menus', 'MENU%d.png' % mid), debug=False)
    print('shell exported to', out)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--hangar':
        export_hangar(sys.argv[2] if len(sys.argv) > 2 else P.pack('es1', 'shell'))
    else:
        export_all(sys.argv[1] if len(sys.argv) > 1 else P.pack('es1', 'shell'))
