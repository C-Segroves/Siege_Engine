"""Export the Tribes 1 / Tribes 2 HUD shown while piloting a vehicle to gamedata/<pack>/cockpit/ for the Godot remake.

    python tools/export_tribes_cockpit.py [tribes|tribes2|all] [--render]

Findings, evidence and the layouts: tools/tribes_vehicle_hud.py. Sources (read only): tribes/extracted
(Interface, Entities, fonts, gui, scripts, lushWorld) and tribes2/extracted (textures/gui, scripts, base/fonts).

Output per pack (gamedata/tribes/cockpit/, gamedata/tribes2/cockpit/):
  dba/<NAME>/<i>.png + dba/<NAME>.json   RGBA bitmaps ({count, sizes, scale, names}); Tribes 1 PBMPs are resolved
                                         through the world palette (HUD indices and the translucent palette 1977
                                         are the same in every world, so one RGBA set fits all maps)
  fonts/<NAME>.png + .json               glyph atlases ({height, chars {code: [x, y, w]}, scale}); Tribes 1 glyphs
                                         carry their colour, Tribes 2 glyphs are white (tint with the meter colour)
  hud.json                               {canvas, note, per_vehicle, meters} (schema: tribes_vehicle_hud.py)
--render also draws 640x480 mock-ups to renders/tribes_vehicle_hud_<ID>.png.
"""
import glob
import io
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import darkstar_gfx as gfx  # noqa: E402
import siege_paths as P  # noqa: E402
import tribes_vehicle_hud as H  # noqa: E402
from PIL import Image  # noqa: E402

T1 = P.work('tribes', 'extracted')
T2 = P.work('tribes2', 'extracted')
T1_PALETTE = ('lushWorld', 'lush.day.ppl')     # HUD indices 212..255 and palette 1977 are identical in all worlds
T1_PLAY_GUI = ('gui', 'gui', 'play.gui')
T1_STRINGS = ('scripts', 'fear.strings.cs')
T2_GUI_ART = ('textures', 'textures', 'gui')
T2_SCRIPTS = ('scripts', 'gui', 'PlayGui.gui'), ('scripts', 'gui', 'ChatDlg.gui'), ('scripts', 'scripts', 'client.cs')
T2_FONT_DIR = ('base', 'fonts')
OPAQUE = 255
NATIVE_SCALE = 1
RENDERS = os.path.join(P.ROOT, 'renders')


# ------------------------------------------------------------------ shared writers

def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def save_dba(out, name, images, sources):
    for i, im in enumerate(images):
        path = os.path.join(out, 'dba', name, '%d.png' % i)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        im.save(path)
    write_json(os.path.join(out, 'dba', name + '.json'),
               {'count': len(images), 'sizes': [list(im.size) for im in images], 'scale': NATIVE_SCALE,
                'names': sources})


def save_font(out, name, cells, height):
    """cells: [(code, RGBA cell image of `height` rows)] -> one-row atlas + {height, chars, scale}."""
    atlas = Image.new('RGBA', (max(1, sum(c.width for _, c in cells)), height), (0, 0, 0, 0))
    chars, x = {}, 0
    for code, cell in cells:
        atlas.paste(cell, (x, 0))
        chars[str(code)] = [x, 0, cell.width]
        x += cell.width
    os.makedirs(os.path.join(out, 'fonts'), exist_ok=True)
    atlas.save(os.path.join(out, 'fonts', name + '.png'))
    write_json(os.path.join(out, 'fonts', name + '.json'), {'height': height, 'chars': chars, 'scale': NATIVE_SCALE})


# ------------------------------------------------------------------ Tribes 1

def read_t1(*parts):
    with open(os.path.join(T1, *parts), 'rb') as f:
        return f.read()


class T1Palette:
    """PBMP palette ids -> RGBA (index 0 transparent; translucent palettes carry alpha in their flags)."""

    def __init__(self):
        self.ppl = gfx.read_ppl(read_t1(*T1_PALETTE))

    def rgba(self, palette_id, index):
        pal = gfx.palette_for(self.ppl, palette_id)
        alpha = pal['flags'][index] if pal['type'] != 1 else OPAQUE
        return tuple(pal['colors'][index]) + (0 if index == 0 else alpha,)

    def hud_color(self, index):
        return list(self.rgba(0, index))

    def image(self, bmp):
        table = [self.rgba(bmp['palette_id'] or 0, i) for i in range(256)]
        im = Image.new('RGBA', (bmp['w'], bmp['h']))
        im.putdata([table[p] for p in bmp['pixels'][:bmp['w'] * bmp['h']]])
        return im


def export_t1_bitmaps(out, palette):
    for name, sources in H.T1_DBA.items():
        images = [palette.image(gfx.read_pbmp(read_t1(*(src + '.bmp').split('/')))) for src in sources]
        save_dba(out, name, images, sources)


def make_pft_cells(font, color):
    sheets = font['sheets']
    height = max(top + h for _s, _x, _y, _w, h, top in font['glyphs'].values())
    cells = []
    for code, (sheet, x, y, w, h, top) in sorted(font['glyphs'].items()):
        bmp = sheets[sheet]
        cell = Image.new('RGBA', (w + 1, height), (0, 0, 0, 0))
        for yy in range(h):
            row = (y + yy) * bmp['w']
            for xx in range(w):
                if bmp['pixels'][row + x + xx]:
                    cell.putpixel((xx, top + yy), color)
        cells.append((code, cell))
    return cells, height


def export_t1_fonts(out, palette):
    for stem in H.T1_FONTS:
        font = H.read_pft(read_t1('fonts', stem + '.pft'), gfx.read_pba)
        cells, height = make_pft_cells(font, palette.rgba(0, font['color_index']))
        save_font(out, stem.upper(), cells, height)


def export_tribes(out):
    palette = T1Palette()
    export_t1_bitmaps(out, palette)
    export_t1_fonts(out, palette)
    controls = H.read_t1_gui(read_t1(*T1_PLAY_GUI))
    names = H.read_ctg_names(read_t1(*T1_STRINGS).decode('latin-1'))
    hud = H.make_t1_hud(controls, palette.hud_color)
    hud['play_gui'] = {'canvas': H.read_t1_gui_canvas(read_t1(*T1_PLAY_GUI)),
                       'controls': [dict(c, name=names.get(c['tag'], '')) for c in controls]}
    write_json(os.path.join(out, 'hud.json'), hud, 1)
    print('tribes HUD: %d meters, %d bitmap arrays, %d fonts -> %s'
          % (len(hud['meters']), len(H.T1_DBA), len(H.T1_FONTS), out))


# ------------------------------------------------------------------ Tribes 2

def find_t2_art():
    """Lower-case stem -> path of the textures/gui PNGs (scripts and files disagree on case)."""
    return {os.path.splitext(os.path.basename(p))[0].lower(): p
            for p in glob.glob(os.path.join(T2, *T2_GUI_ART, '*.png'))}


def export_t2_bitmaps(out):
    art = find_t2_art()
    for name, stems in H.T2_DBA.items():
        images = [Image.open(art[s.lower()]).convert('RGBA') for s in stems]
        save_dba(out, name, images, ['gui/%s.png' % s for s in stems])


def make_gft_cells(font):
    sheets = [Image.open(io.BytesIO(png)).convert('L') for png in font['sheets']]
    height = max(font['height'], max(font['baseline'] - g[6] + g[4] for g in font['glyphs'].values()))
    cells = []
    for code, (sheet, x, y, w, h, xo, yo, adv) in sorted(font['glyphs'].items()):
        cell = Image.new('RGBA', (max(adv, xo + w, 1), height), (255, 255, 255, 0))
        if w and h:
            alpha = sheets[sheet].crop((x, y, x + w, y + h))
            glyph = Image.new('RGBA', (w, h), (255, 255, 255, 255))
            glyph.putalpha(alpha)
            cell.alpha_composite(glyph, (max(xo, 0), max(font['baseline'] - yo, 0)))
        cells.append((code, cell))
    return cells, height


def export_t2_fonts(out):
    for name, stem in H.T2_FONTS.items():
        with open(os.path.join(T2, *T2_FONT_DIR, stem + '.gft'), 'rb') as f:
            cells, height = make_gft_cells(H.read_gft(f.read()))
        save_font(out, name, cells, height)


def read_t2_gui():
    def parse(parts):
        with open(os.path.join(T2, *parts), encoding='latin-1') as f:
            return H.read_gui_script(f.read())
    return H.T2Gui(*[parse(parts) for parts in T2_SCRIPTS])


def export_tribes2(out):
    export_t2_bitmaps(out)
    export_t2_fonts(out)
    hud = H.make_t2_hud(read_t2_gui())
    write_json(os.path.join(out, 'hud.json'), hud, 1)
    print('tribes2 HUD: %d meters, %d bitmap arrays, %d fonts -> %s'
          % (len(hud['meters']), len(H.T2_DBA), len(H.T2_FONTS), out))


# ------------------------------------------------------------------ mock-ups (check the export by eye)

SAMPLE = {'health': 0.72, 'energy': 0.55, 'heat': 0.12, 'speed_mps': 31.0, 'altitude_m': 46, 'heading_deg': 30.0,
          'clock': '04:59'}
SAMPLE_CHAT = ['Shrike ready.', 'Defend our flag!', 'Incoming!', 'Need a pilot.']
SKY, GROUND = ((92, 120, 156), (160, 180, 200)), ((70, 84, 52), (40, 50, 30))
HORIZON = 300


class HudMockup:
    """Draws a pack's hud.json with its exported art at 640x480 (sample values, first weapon selected)."""

    def __init__(self, out):
        self.out = out
        with open(os.path.join(out, 'hud.json'), encoding='utf-8') as f:
            self.hud = json.load(f)
        self.meters = {m['id']: m for m in self.hud['meters']}
        self.images, self.fonts = {}, {}

    def frame(self, dba, i):
        key = (dba, i)
        if key not in self.images:
            self.images[key] = Image.open(os.path.join(self.out, 'dba', dba, '%d.png' % i)).convert('RGBA')
        return self.images[key]

    def font(self, name):
        if name not in self.fonts:
            with open(os.path.join(self.out, 'fonts', name + '.json'), encoding='utf-8') as f:
                meta = json.load(f)
            self.fonts[name] = (Image.open(os.path.join(self.out, 'fonts', name + '.png')).convert('RGBA'), meta)
        return self.fonts[name]

    def render(self, vehicle_id):
        canvas = make_backdrop(self.hud['canvas'])
        for meter_id in self.hud['per_vehicle'][vehicle_id]:
            self.draw_meter(canvas, self.meters[meter_id])
        return canvas

    def draw_meter(self, canvas, m):
        highlight = m.get('highlight_per_weapon', {}).get('1')
        for layer in ([highlight] if highlight else []) + [l for l in m['layers'] if l]:
            self.draw_layer(canvas, layer, m.get('opacity', 1.0) if m['kind'] == 'reticle' else 1.0)
        draw = getattr(self, 'draw_' + m['kind'], None)
        if draw:
            draw(canvas, m)

    def draw_layer(self, canvas, layer, opacity=1.0):
        im = self.frame(layer['dba'], layer['frame'])
        if 'src_rect' in layer:
            x, y, w, h = layer['src_rect']
            im = im.crop((x, y, x + w, y + h))
        if layer.get('flip') == 'v':
            im = im.transpose(Image.FLIP_TOP_BOTTOM)
        if layer.get('flip') == 'h':
            im = im.transpose(Image.FLIP_LEFT_RIGHT)
        if 'tint' in layer:
            im = make_tinted(im, layer['tint'])
        alpha = layer.get('opacity', 1.0) * opacity
        if alpha < 1.0:
            im.putalpha(im.getchannel('A').point(lambda a: int(a * alpha)))
        composite(canvas, im, layer['at'])

    def draw_text(self, canvas, text, value):
        atlas, meta = self.font(text['font'])
        glyphs = [meta['chars'][str(ord(c))] for c in value if str(ord(c)) in meta['chars']]
        width = sum(g[2] for g in glyphs)
        if 'rect' in text:
            x0, y0, x1, y1 = text['rect']
            x = x0 + (x1 - x0 + 1 - width) // 2 if text.get('justify') == 'center' else x0
            y = y0 + (y1 - y0 + 1 - meta['height']) // 2
        else:
            x, y = text['at']
        for gx, gy, gw in glyphs:
            glyph = atlas.crop((gx, gy, gx + gw, gy + meta['height']))
            composite(canvas, make_tinted(glyph, text['color']) if 'color' in text else glyph, (x, y))
            x += gw

    def draw_bar(self, canvas, m, value):
        bar = m['bar']
        if 'steps' in bar:
            self.draw_t1_bar(canvas, bar, value)
            return
        x0, y0, x1, y1 = bar['rect']
        fill = Image.new('RGBA', (max(1, int((x1 - x0 + 1) * value)), y1 - y0 + 1), tuple(bar['fill']))
        composite(canvas, fill, (x0, y0))

    def draw_t1_bar(self, canvas, bar, value):
        length = max(bar['min_px_alive'], int(bar['max_px'] * value))
        step = next(s for s in bar['steps'] if length >= s['min_px'])
        cap = self.frame(self.dba_of(bar), step['cap_frame'])
        strip = Image.new('RGBA', (bar['max_px'], cap.height), (0, 0, 0, 0))
        strip.paste(Image.new('RGBA', (bar['max_px'] - 1 - 2 * cap.width, cap.height), tuple(step['color'])),
                    (cap.width, 0))
        strip.alpha_composite(cap, (0, 0))
        strip.alpha_composite(cap.transpose(Image.FLIP_LEFT_RIGHT), (bar['max_px'] - 1 - cap.width, 0))
        composite(canvas, strip.crop((0, 0, length, cap.height)), bar['origin'])

    def dba_of(self, bar):
        return 'HUD_HEALTH' if bar['source'].endswith('health') else 'HUD_ENERGY'

    def draw_health(self, canvas, m):
        self.draw_bar(canvas, m, SAMPLE['health'])

    def draw_energy(self, canvas, m):
        self.draw_bar(canvas, m, SAMPLE['energy'])

    def draw_heat(self, canvas, m):
        self.draw_bar(canvas, m, SAMPLE['heat'])

    def draw_speed(self, canvas, m):
        self.draw_text(canvas, m['text'], str(int(SAMPLE['speed_mps'] * m['text']['scale'])))
        self.draw_text(canvas, m['label'], m['label']['value'])

    def draw_altitude(self, canvas, m):
        self.draw_text(canvas, m['text'], str(SAMPLE['altitude_m']))
        self.draw_text(canvas, m['label'], m['label']['value'])

    def draw_clock(self, canvas, m):
        self.draw_text(canvas, m['text'], SAMPLE['clock'])

    def draw_heading(self, canvas, m):
        text = m['text']
        cx, cy = m['center']
        for i, mark in enumerate(m['marks']):
            angle = math.radians(i * 90 - SAMPLE['heading_deg'])
            x, y = cx + m['mark_radius'] * math.sin(angle), cy - m['mark_radius'] * math.cos(angle)
            self.draw_text(canvas, dict(text, at=[int(x) - 3, int(y) - 5]), mark)

    def draw_crew(self, canvas, m):
        self.draw_layer(canvas, m['seats'][0])

    def draw_sensor(self, canvas, m):
        frames = m.get('frames')
        if frames:
            x0, y0, x1, y1 = m['rect']
            state = self.frame(m['dba'], frames['none'])
            composite(canvas, state, ((x0 + x1 + 1 - state.width) // 2, (y0 + y1 + 1 - state.height) // 2))

    def draw_messages(self, canvas, m):
        if 'nine_slice' in m:
            self.draw_nine_slice(canvas, m['rect'], m['nine_slice'])
        text = m['text']
        atlas_height = self.font(text['font'])[1]['height']
        x0, y0 = (text['rect'][0], text['rect'][1]) if 'rect' in text else text['at']
        for i, line in enumerate(SAMPLE_CHAT[:text.get('lines', 4)]):
            line_text = {k: v for k, v in text.items() if k in ('font', 'color')}
            self.draw_text(canvas, dict(line_text, at=[x0, y0 + i * atlas_height]), line)

    def draw_nine_slice(self, canvas, rect, spec):
        x0, y0, x1, y1 = rect
        c = spec['corner']
        tiles = [self.frame(spec['dba'], f) for f in spec['frames']]
        cols = [(x0, c), (x0 + c, x1 + 1 - x0 - 2 * c), (x1 + 1 - c, c)]
        rows = [(y0, c), (y0 + c, y1 + 1 - y0 - 2 * c), (y1 + 1 - c, c)]
        for r, (y, h) in enumerate(rows):
            for k, (x, w) in enumerate(cols):
                composite(canvas, tiles[r * 3 + k].resize((w, h)), (x, y))


def make_backdrop(size):
    """Sky and ground gradient behind the HUD."""
    w, h = size
    im = Image.new('RGBA', (w, h))
    for y in range(h):
        (top, bottom), t = (SKY, y / float(HORIZON)) if y < HORIZON else (GROUND, (y - HORIZON) / float(h - HORIZON))
        im.paste(tuple(int(p + (q - p) * t) for p, q in zip(top, bottom)) + (255,), (0, y, w, y + 1))
    return im


def make_tinted(im, color):
    """`im` recoloured to `color` (its alpha kept, scaled by color's alpha)."""
    alpha = im.getchannel('A')
    if len(color) > 3 and color[3] < 255:
        alpha = alpha.point(lambda a: a * color[3] // 255)
    return Image.merge('RGBA', [Image.new('L', im.size, v) for v in color[:3]] + [alpha])


def composite(canvas, im, at):
    layer = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    layer.paste(im, (int(at[0]), int(at[1])))
    canvas.alpha_composite(layer)


def render_pack(out, vehicle_ids, render_dir):
    mock = HudMockup(out)
    os.makedirs(render_dir, exist_ok=True)
    for vid in vehicle_ids:
        path = os.path.join(render_dir, 'tribes_vehicle_hud_%s.png' % vid.replace('/', '_seat'))
        mock.render(vid).convert('RGB').save(path)
        print('  mock-up', path)


# ------------------------------------------------------------------ main

EXPORTERS = {'tribes': export_tribes, 'tribes2': export_tribes2}
RENDER_IDS = {'tribes': ['SCOUT'], 'tribes2': ['SHRIKE', 'THUNDERSWORD', 'BEOWULF', 'THUNDERSWORD/1', 'BEOWULF/1']}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    packs = [a for a in argv if not a.startswith('--')] or ['all']
    packs = list(EXPORTERS) if packs == ['all'] else packs
    for pack in packs:
        out = P.pack(pack, 'cockpit')
        EXPORTERS[pack](out)
        if '--render' in argv:
            render_pack(out, RENDER_IDS[pack], RENDERS)


if __name__ == '__main__':
    main()
