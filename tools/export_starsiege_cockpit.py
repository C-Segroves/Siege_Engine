"""Export the Starsiege in-sim HUD to gamedata/starsiege/cockpit/ for the Godot remake (same file formats as
tools/export_es2_cockpit.py writes for Earthsiege 2; decoded layout and evidence in tools/starsiege_hud.py).

    python tools/export_starsiege_cockpit.py [outdir] [--mockup <dir>]
        outdir    default gamedata/starsiege/cockpit
        --mockup  also render <dir>/starsiege_hud_mockup_<variant>.png from the exported files

Output (the 640 x 480 high-res set, scale 1):
  dba/<NAME>/<i>.png + dba/<NAME>.json   HUD bitmaps / arrays ({count, sizes, scale}); 8-bit palette-index PNGs,
                                         index 0 transparent (STRCIRCLE holds ring segment numbers 1..48)
  fonts/<NAME>.png + .json               hud_high*.pft glyph atlases ({height, chars: {code: [x, y, w]}, scale})
  palettes/palette.json                  256 x [r,g,b]: Mars.d.ppl screen palette + HUD slots (scheme 0)
  hud.json                               decoded default HUD (meters, schemes, eye rule, cockpit mesh)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import darkstar_gfx as G  # noqa: E402
import siege_paths as P  # noqa: E402
import starsiege_hud as H  # noqa: E402
from PIL import Image  # noqa: E402

SHELL = P.work('starsiege', 'extracted', 'shell')
WORLD_PPL = P.work('starsiege', 'extracted', 'Mars.Sim', 'Mars.d.ppl')   # pack default palette world
STARSIEGE_EXE = P.work('starsiege', 'original', 'installed', 'Starsiege.exe')   # HUD colour tables
SCALE = 1
PALETTE_FILE = 'palettes/palette.json'
VARIANTS = ('human', 'cybrid')       # same HUD colours and art (starsiege_hud docstring section 3)
MOCKUP_BACKGROUND = (96, 96, 96)


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def save_indexed(pixels, size, path):
    """8-bit palette-index PNG (index 0 = transparent)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    n = size[0] * size[1]
    Image.frombytes('L', size, bytes(pixels[:n]).ljust(n, b'\0')).save(path)


def load_art():
    return {name: H.read_art(SHELL, fname) for name, fname in H.HIGH_ART.items()}


def load_fonts():
    fonts = {}
    for name, fname in H.HIGH_FONTS.items():
        with open(os.path.join(SHELL, fname), 'rb') as f:
            fonts[name] = H.read_pft(f.read())
    return fonts


def export_art(out, art):
    for name, frames in art.items():
        for i, b in enumerate(frames):
            save_indexed(b['pixels'], (b['w'], b['h']), os.path.join(out, 'dba', name, '%d.png' % i))
        write_json(os.path.join(out, 'dba', name + '.json'),
                   {'count': len(frames), 'sizes': [[b['w'], b['h']] for b in frames], 'scale': SCALE})


def export_fonts(out, fonts):
    for name, font in fonts.items():
        pixels, w, h, chars = H.make_font_atlas(font)
        save_indexed(pixels, (w, h), os.path.join(out, 'fonts', name + '.png'))
        write_json(os.path.join(out, 'fonts', name + '.json'),
                   {'height': font['height'], 'baseline': font['baseline'], 'chars': chars, 'scale': SCALE})


def make_palette(hud_colors):
    with open(WORLD_PPL, 'rb') as f:
        ppl = G.read_ppl(f.read())
    return H.make_hud_palette(G.palette_for(ppl, H.SCREEN_PALETTE_ID)['colors'], hud_colors)


def export_hud(out, art, fonts, hud_colors):
    hud = H.make_hud(art, fonts, hud_colors)
    hud['variants'] = {v: {'palette': PALETTE_FILE, 'scheme': H.DEFAULT_SCHEME, 'art': 'shared'} for v in VARIANTS}
    write_json(os.path.join(out, 'hud.json'), hud, 1)
    return hud


def export(out):
    art, fonts, hud_colors = load_art(), load_fonts(), H.read_hud_colors(STARSIEGE_EXE)
    export_art(out, art)
    export_fonts(out, fonts)
    write_json(os.path.join(out, PALETTE_FILE), make_palette(hud_colors))
    hud = export_hud(out, art, fonts, hud_colors)
    print('starsiege hud: %d bitmaps, %d fonts, %d meters -> %s' % (len(art), len(fonts), len(hud['meters']), out))


# ---------------------------------------------------------------------------------------------- mock-up
class Mockup:
    """Draws the default HUD from the exported files (hud.json, dba/, fonts/, palettes/) onto a grey canvas."""

    def __init__(self, cockpit_dir, variant):
        self.dir = cockpit_dir
        with open(os.path.join(cockpit_dir, 'hud.json'), encoding='utf-8') as f:
            self.hud = json.load(f)
        with open(os.path.join(cockpit_dir, self.hud['variants'][variant]['palette']), encoding='utf-8') as f:
            self.palette = [tuple(c) for c in json.load(f)]
        self.canvas = Image.new('RGB', tuple(self.hud['canvas']), MOCKUP_BACKGROUND)

    def colorize(self, img, alpha=1.0):
        rgba = Image.new('RGBA', img.size)
        src, dst = img.load(), rgba.load()
        for y in range(img.height):
            for x in range(img.width):
                v = src[x, y]
                if v:
                    dst[x, y] = self.palette[v] + (int(255 * alpha),)
        return rgba

    def frame(self, name, i):
        return Image.open(os.path.join(self.dir, 'dba', name, '%d.png' % i))

    def blit(self, img, pos, alpha=1.0):
        rgba = self.colorize(img, alpha)
        self.canvas.paste(rgba, tuple(pos), rgba)

    def text(self, font, pos, s):
        with open(os.path.join(self.dir, 'fonts', font + '.json'), encoding='utf-8') as f:
            meta = json.load(f)
        atlas = Image.open(os.path.join(self.dir, 'fonts', font + '.png'))
        x = pos[0]
        for ch in s:
            gx, gy, w = meta['chars'].get(str(ord(ch)), [0, 0, 0])
            self.blit(atlas.crop((gx, gy, gx + w, gy + meta['height'])), (x, pos[1]))
            x += w
        return x - pos[0]

    def text_width(self, font, s):
        with open(os.path.join(self.dir, 'fonts', font + '.json'), encoding='utf-8') as f:
            chars = json.load(f)['chars']
        return sum(chars.get(str(ord(ch)), [0, 0, 0])[2] for ch in s)

    def render(self):
        for m in self.hud['meters']:
            getattr(self, 'draw_' + m['kind'], lambda _m: None)(m)
        return self.canvas

    def draw_reticle(self, m):
        self.blit(self.frame(m['dba'], m['frames']['idle']), m['rect'][:2], m['alpha'])

    def draw_lead(self, m):
        x, y = m['rect'][0] + 60, m['rect'][1] - 40
        self.blit(self.frame(m['dba'], m['frames']['in_range']), (x, y), m['alpha'])
        lead_x, lead_y = x - m['offset_from_lead_point'][0], y - m['offset_from_lead_point'][1]
        s = '412m'
        self.text(m['font'], (lead_x + m['range_text_offset'][0] - self.text_width(m['font'], s),
                              lead_y + m['range_text_offset'][1]), s)

    def draw_radar(self, m):
        ax, ay = m['rect'][0] + m['art_offset'][0], m['rect'][1] + m['art_offset'][1]
        self.blit(self.frame(m['dba'], m['frames']['default']), (ax, ay), m['alpha'])
        title = 'ACTIVE 1000m'
        cx, cy = ax + m['title']['centre'][0], ay + m['title']['centre'][1]
        self.text(m['font'], (cx - self.text_width(m['font'], title) // 2, cy), title)
        self.text(m['font'], (m['rect'][0], m['rect'][3] - 12), '42Kph')
        self.draw_contacts(ax, ay, m['colors'])

    def draw_contacts(self, ax, ay, colors):
        for (dx, dy), key in (((95, 40), 'enemy'), ((120, 55), 'team_2'), ((80, 30), 'neutral')):
            self.canvas.paste(self.palette[colors[key]], (ax + dx, ay + dy, ax + dx + 3, ay + dy + 3))

    def draw_weapons(self, m):
        names = ['ATC 40', 'ELF', 'Blaster', 'SRM 6']
        x0, y = m['rect'][0], m['rect'][1] + m['row_pad']
        for i, name in enumerate(names[:m['weapons']]):
            font = m['fonts']['selected'] if i == 0 else m['fonts']['ready']
            self.text(font, (x0 + m['group_column_width'], y), name)
            self.draw_group_circles(m, x0 + m['group_column_width'] + m['name_width'] + 16, y + 3, i)
            self.text(font, (m['rect'][2] - 20, y), str(30 * (i + 1)) if i % 2 == 0 else '')
            y += m['row_height']

    def draw_group_circles(self, m, x, y, weapon):
        for k in range(m['groups']):
            name = m['dba'] if k == weapon % m['groups'] else m['dba_open']
            self.blit(self.frame(name, 0), (x + k * m['group_column_width'], y))

    def draw_shields(self, m):
        from starsiege_hud import make_shield_ring_lut
        art = self.frame(m['dba'], 0).copy()
        ring = self.frame(m['ring_dba'], 0)
        lut = make_shield_ring_lut(0.6, 0.6, 1.0)
        self.paint_ring(art, ring, lut, m['ring_offset'])
        self.blit(art, m['rect'][:2], m['alpha'])
        self.text(m['font'], (m['rect'][0] + 40, m['rect'][1] + 40), '100%')

    @staticmethod
    def paint_ring(art, ring, lut, offset):
        a, r = art.load(), ring.load()
        for y in range(ring.height):
            for x in range(ring.width):
                tx, ty = x + offset[0], y + offset[1]
                if r[x, y] and 0 <= tx < art.width and 0 <= ty < art.height:
                    a[tx, ty] = lut[r[x, y]]

    def draw_damage_self(self, m):
        x, y = m['rect'][:2]
        self.text(m['font'], (x + m['label_offset'][0], y + m['label_offset'][1]), m['label'])
        self.blit(self.frame(m['dba'], 0), (x + m['art_offset'][0], y + m['art_offset'][1]), m['alpha'])

    draw_damage_target = draw_damage_self

    def draw_internal_damage(self, m):
        lines = [m['title'], 'ENGINE: OK', 'REACTOR: OK', 'SHIELDS: OK', 'SENSORS: OK']
        for i, s in enumerate(lines):
            self.text(m['font'], (m['rect'][0], m['rect'][1] + i * 13), s)

    def draw_messages(self, m):
        self.text(m['font'], (m['rect'][0] + 4, m['rect'][1] + 2), 'Harabec: Hold the line, pilot.')


def render_mockups(cockpit_dir, render_dir):
    os.makedirs(render_dir, exist_ok=True)
    for variant in VARIANTS:
        path = os.path.join(render_dir, 'starsiege_hud_mockup_%s.png' % variant)
        Mockup(cockpit_dir, variant).render().save(path)
        print('mock-up ->', path)


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)[1:]
    mockup_dir = None
    if '--mockup' in argv:
        i = argv.index('--mockup')
        mockup_dir = argv[i + 1]
        del argv[i:i + 2]
    out = argv[0] if argv else P.pack('starsiege', 'cockpit')
    export(out)
    if mockup_dir:
        render_mockups(out, mockup_dir)


if __name__ == '__main__':
    main()
