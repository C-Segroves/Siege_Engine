"""Export the Battledrome in-sim HUD to gamedata/bd/cockpit/ for the Godot remake.

    python tools/export_bd_cockpit.py [outdir] [--mockup <png>]      (default gamedata/bd/cockpit)

Decoder and evidence: tools/bd_hud.py (SIM.EXE code\\hud.cpp, DTS\\HUD.DAT).  Battledrome has no cockpit
panel art: the HUD is vector graphics drawn over the full-screen 3D view, so the export is mostly hud.json.
Same file conventions as tools/export_es2_cockpit.py (8-bit palette-index PNGs, index 0 transparent, read by
game/games/es1/cockpit/cockpit_assets.gd).

Output:
  palette.json            256 x [r,g,b]: DTS\\NRMPAL.DPL, the normal sim palette (GAMPAL = F8 gamma variant)
  hud.json                canvas, view (centre row, viewport), meters (rect, visible, shapes, colours, dynamic
                          element rules, evidence, confidence), draw order, eye rule
  fonts/HUD.png + .json   the SIM.EXE stroke font rasterised ({height, chars: {code: [x, y, w]}, scale}); the
                          json also carries the strokes ({code: [[x0,y0,x1,y1]..]}, y up from the baseline)
  dba/WINNER/<i>.png + dba/WINNER.json    end-of-match banners ({count, sizes, scale})
  strings.json            MSGTEXT.BIN messages + their attributes (0x76830) + the HUD string tables
--mockup renders hud.json with the exported font onto a grey 320x200 canvas (x3) with sample values.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bd_hud  # noqa: E402
import gfx  # noqa: E402
import shell  # noqa: E402
import siege_paths as P  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

DTS = P.work('bd', 'installed', 'DTS')
PALETTE = 'NRMPAL'
WINNER = 'WINNER'
FONT = 'HUD'
FONT_INDEX = bd_hud.YELLOW            # atlas pixel value; the engine tints text per draw
FONT_COLUMNS = 16
FONT_CODES = range(0x20, bd_hud.FONT_FIRST + bd_hud.FONT_COUNT)   # space .. 'Z'
ADVANCE = bd_hud.FONT_W + bd_hud.FONT_SPACING
LOW_RES = 1
MOCKUP_SCALE = 3
MOCKUP_GREY = (96, 96, 96)


def rd(name):
    with open(os.path.join(DTS, name), 'rb') as f:
        return f.read()


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def save_indexed(b, path):
    """8-bit palette-index PNG (index 0 = transparent)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n = b['w'] * b['h']
    Image.frombytes('L', (b['w'], b['h']), bytes(b['pixels'][:n]).ljust(n, b'\0')).save(path)


def make_palette():
    return [list(c[:3]) for c in gfx.read_dpl(rd(PALETTE + '.DPL'))]


def export_winner(out):
    bs = gfx.read_any(rd(WINNER + '.DBA'))
    for i, b in enumerate(bs):
        save_indexed(b, os.path.join(out, 'dba', WINNER, '%d.png' % i))
    sizes = [[b['w'], b['h']] for b in bs]
    write_json(os.path.join(out, 'dba', WINNER + '.json'), {'count': len(bs), 'sizes': sizes, 'scale': LOW_RES})
    return sizes


# ---------------------------------------------------------------- stroke font -> atlas

def stroke_pixels(seg):
    """Integer points of a stroke, end points included (DDA, as the GFX line routine)."""
    x0, y0, x1, y1 = seg
    steps = max(abs(x1 - x0), abs(y1 - y0))
    if steps == 0:
        return [(x0, y0)]
    return [(round(x0 + (x1 - x0) * t / steps), round(y0 + (y1 - y0) * t / steps)) for t in range(steps + 1)]


def draw_glyph(atlas, strokes, x, y):
    top = bd_hud.FONT_H - 1
    for seg in strokes:
        for gx, gy in stroke_pixels(seg):
            atlas.putpixel((x + gx, y + top - gy), FONT_INDEX)


def make_font_atlas(glyphs):
    rows = (len(FONT_CODES) + FONT_COLUMNS - 1) // FONT_COLUMNS
    atlas = Image.new('L', (FONT_COLUMNS * ADVANCE, rows * bd_hud.FONT_H), 0)
    chars = {}
    for i, code in enumerate(FONT_CODES):
        x, y = (i % FONT_COLUMNS) * ADVANCE, (i // FONT_COLUMNS) * bd_hud.FONT_H
        draw_glyph(atlas, glyphs.get(code, []), x, y)
        chars[str(code)] = [x, y, ADVANCE]
    return atlas, chars


def export_font(out, img):
    glyphs = bd_hud.read_stroke_font(img)
    atlas, chars = make_font_atlas(glyphs)
    os.makedirs(os.path.join(out, 'fonts'), exist_ok=True)
    atlas.save(os.path.join(out, 'fonts', FONT + '.png'))
    write_json(os.path.join(out, 'fonts', FONT + '.json'), {
        'height': bd_hud.FONT_H, 'chars': chars, 'scale': LOW_RES, 'baseline': bd_hud.FONT_H - 1,
        'advance': ADVANCE, 'strokes': {str(k): v for k, v in glyphs.items() if v},
        'source': 'SIM.EXE SFont glyph table 0x7ea90 (stroke font, y up from the baseline)'})


def export_strings(out, img):
    messages = shell.read_text_bin(rd('MSGTEXT.BIN'))['strings']
    write_json(os.path.join(out, 'strings.json'), {
        'messages': messages, 'message_attributes': bd_hud.read_message_table(img),
        'tables': bd_hud.read_string_tables(img)}, 1)


def export(out):
    img = bd_hud.load_image()
    layout = bd_hud.load_hud_dat()
    os.makedirs(out, exist_ok=True)
    write_json(os.path.join(out, 'palette.json'), make_palette())
    sizes = export_winner(out)
    export_font(out, img)
    export_strings(out, img)
    hud = bd_hud.make_hud(img, layout, sizes)
    write_json(os.path.join(out, 'hud.json'), hud, 1)
    shown = sum(1 for m in hud['meters'] if m['visible'])
    print('bd cockpit: %d meters (%d visible) -> %s' % (len(hud['meters']), shown, out))
    return hud


# ---------------------------------------------------------------- mock-up

class Mockup:
    """Draws hud.json primitives on a 320x200 canvas with the exported font."""

    def __init__(self, out):
        with open(os.path.join(out, 'palette.json'), encoding='utf-8') as f:
            self.palette = [tuple(c) for c in json.load(f)]
        with open(os.path.join(out, 'fonts', FONT + '.json'), encoding='utf-8') as f:
            self.font = json.load(f)
        self.atlas = Image.open(os.path.join(out, 'fonts', FONT + '.png'))
        self.canvas = Image.new('RGB', bd_hud.CANVAS, MOCKUP_GREY)
        self.draw = ImageDraw.Draw(self.canvas)
        self.origin = (0, 0)

    def at(self, p):
        return (self.origin[0] + p[0], self.origin[1] + p[1])

    def shape(self, s):
        c = self.palette[s['color']]
        op = s['op']
        if op in ('line', 'polyline'):
            self.draw.line([self.at(p) for p in s['points']], fill=c)
        elif op == 'polygon':
            self.draw.polygon([self.at(p) for p in s['points']], fill=c)
        elif op in ('fill', 'frame', 'ellipse'):
            box = [self.at(s['rect'][:2]), self.at(s['rect'][2:])]
            {'fill': lambda: self.draw.rectangle(box, fill=c), 'frame': lambda: self.draw.rectangle(box, outline=c),
             'ellipse': lambda: self.draw.ellipse(box, outline=c)}[op]()
        elif op == 'text':
            self.text(s['text'], s['at'], s['color'])

    def text(self, s, at, color):
        x, y = self.at(at)
        top = y - self.font['baseline']
        for ch in s:
            gl = self.font['chars'].get(str(ord(ch)))
            if gl is None:
                continue
            gx, gy, w = gl
            for yy in range(self.font['height']):
                for xx in range(w):
                    if self.atlas.getpixel((gx + xx, gy + yy)):
                        self.canvas.putpixel((x + xx, top + yy), self.palette[color])
            x += w

    def shapes(self, shapes):
        for s in shapes:
            self.shape(s)


def rotate(points, angle, centre, y_scale=1.0):
    a = angle * 2 * math.pi / 65536
    ca, sa = math.cos(a), math.sin(a)
    return [[round(centre[0] + px * ca - py * sa), round(centre[1] + (px * sa + py * ca) * y_scale)] for px, py in points]


def sample_pointers(m, mk, angles):
    for p, angle in zip(m['pointers'], angles):
        for poly in p.get('polygons', [p.get('points')]):
            mk.shape(bd_hud.polygon(rotate(poly, angle, m['centre'], p.get('y_scale', 1.0)), p['color']))


def sample_energy(m, mk):
    for row, level in zip(m['rows'], (120, 85, 50)):
        y, n = row['baseline'], int(level * m['bar']['px_per_level'])
        mk.text(row['label'], [row['label_x'], y], m['colors']['label'])
        x = m['bar']['x']
        mk.shape(bd_hud.line([x, y - 2], [x + n, y - 2], m['colors']['bar']))
        mk.shape(bd_hud.fill([x + n, y - 4, x + n + 2, y], m['colors']['bar']))


def sample_throttle(m, mk, t=64):
    sample_pointers(m, mk, (0x1800, 0x2800, 0))
    th = m['throttle']
    base = max(8, 19 - (12 * t) // 127)
    mk.shape(bd_hud.polygon(th['forward_button']['polygon'], th['colors']['button']))
    mk.text('F', th['forward_button']['at'], th['colors']['label_active'])
    mk.text('R', th['reverse_button']['at'], th['colors']['label'])
    mk.shape(bd_hud.polygon([[48, base], [51, base - 3], [54, base]], th['colors']['marker']))
    for ty in th['forward']['ticks_y']:
        if ty > base:
            mk.shape(bd_hud.line([48, ty], [54, ty], th['colors']['tick']))


def sample_weapons(m, mk):
    names = ['LASER', 'BLASTER', 'CANON', 'HORNET']
    for k, (row, name) in enumerate(zip(m['rows'], names)):
        y = row['baseline']
        mk.text(str(k + 1), [m['number']['x'], y], m['number']['color'])
        if k == 0:
            f = m['selected']['fill']
            mk.shape(bd_hud.fill([f[0], y + f[1], f[2], y + f[3]], bd_hud.GREEN))
        mk.text(name, [m['name']['x'], y], bd_hud.BLACK if k == 0 else (bd_hud.GREEN, bd_hud.YELLOW, bd_hud.RED)[k % 3])
        if k < 2:
            for x in range(m['charge']['x0'], 43 + (200 * 15 >> 8), m['charge']['step']):
                mk.shape(bd_hud.line([x, y - 4], [x, y], m['charge']['color']))
        else:
            mk.text('12', [m['ammo']['at_x'], y], m['ammo']['color'])


def sample_shields(m, mk, level=200, herc=5):
    bar = m['bar']
    top = (255 - level) * 39 // 255
    color = bar['colors']['from_180']
    for y in bar['ticks_y']:
        if y > top:
            mk.shape(bd_hud.line([bar['x0'], y], [min(56, 48 + y), y], color))
    mk.shape(bd_hud.polygon(bar['base_polygon'], color))
    for e in m['diagram']['by_herc'][herc]:
        for x0, y0, x1, y1 in m['diagram']['part_lines'][str(e['kind'])]:
            ex, ey = e['at']
            mk.shape(bd_hud.line([ex + x0, ey + y0], [ex + x1, ey + y1], bd_hud.GREEN if e['part'] != 3 else bd_hud.YELLOW))


def sample_camera_list(m, mk):
    for k, row in enumerate(m['rows']):
        y = row['baseline']
        if k == 0:
            for f, c in zip(m['active_fills'], ('active_name_fill', 'active_mode_fill')):
                mk.shape(bd_hud.fill([f[0], y + f[1], f[2], y + f[3]], m['colors'][c]))
        mk.text(row['name'], [m['name_x'], y], m['colors']['active_text' if k == 0 else 'name'])
        if k:
            mk.text('FRE', [m['mode_x'], y], m['colors']['mode'])


SAMPLES = {
    'camera_heading': lambda m, mk: sample_pointers(m, mk, (0x2000, 0)),
    'energy': sample_energy,
    'throttle': sample_throttle,
    'control_mode': lambda m, mk: mk.text(m['value']['values'][0], m['value']['at'], m['value']['color']),
    'target_info': lambda m, mk: (mk.text('HERC', m['name']['at'], m['name']['color']),
                                  mk.text('1234', m['distance']['at'], m['distance']['color'])),
    'active_camera': lambda m, mk: mk.text(m['camera']['values'][0], m['camera']['at'], m['camera']['color']),
    'camera_list': sample_camera_list,
    'weapons': sample_weapons,
    'shields': sample_shields,
    'messages': lambda m, mk: mk.text('SHIELDS LOW', m['text']['at'], m['text']['color_normal']),
}


def render_mockup(out, hud, path):
    mk = Mockup(out)
    for m in hud['meters']:
        if not m['visible']:
            continue
        mk.origin = tuple(m['rect'][:2]) if m['kind'] != 'reticle' else (0, 0)
        mk.shapes(m['shapes'])
        if m['kind'] in SAMPLES:
            SAMPLES[m['kind']](m, mk)
    big = mk.canvas.resize((bd_hud.CANVAS[0] * MOCKUP_SCALE, bd_hud.CANVAS[1] * MOCKUP_SCALE), Image.NEAREST)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    big.save(path)
    print('mock-up -> %s' % path)


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)[1:]
    mockup = None
    if '--mockup' in argv:
        i = argv.index('--mockup')
        mockup = argv[i + 1]
        del argv[i:i + 2]
    out = argv[0] if argv else P.pack('bd', 'cockpit')
    hud = export(out)
    if mockup:
        render_mockup(out, hud, mockup)


if __name__ == '__main__':
    main()
