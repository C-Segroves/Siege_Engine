"""Metaltech: Earthsiege weapon visual effects -> gamedata/es1/fx/effects.json + an `fx` block per weapon
(docs/formats/weapon_fx.md sections 1 and 2).

    python tools/fx_es1.py [--sheet renders/weapon_fx_es1_sprites.png]

Reads <work>/extracted/SIMVOL0 (DTS EXPLOS/BULLETS/SMOKE/ROCKETS/FLAT, DBA EXPLO0..8/BULLETS/SMOKE,
STR/SOUNDS.STR), the gameplay tables the importer already wrote (gamedata/es1/gameplay/projectiles.json,
weapons.json, bnd.json) and DBSIM.EXE (VA = file offset - 0x48FD; instruction bytes checked first):

* explo.cpp loader 0x5764: DBAs "explo0".."explo8"; EXPLOS.DAT rows of 22 words; shape_list[row.w0] gets
  the bitmap array dba[row.w2] (0x58ff..0x5924).  Explosion ctor 0x5af0 / update 0x5d74: w1 = cell-anim
  sequence (-1 static), w3 = frame period in timer units (0x6410c: 2560 per s), the sequence plays once;
  w4 != 0 adds FLAT/FLAT2 shape 1 (ground blast ring) cycling with the frames (0x5c06); w5 != 0 adds a
  light whose intensity is the low byte of word 6+frame (0x54b0, 0x5e0c); sound id = w20 + 10 (0x5c8d).
* Impact pick: Mech::onHit 0x13fd4 uses fx[group*4 + rand&3]: group 0 when the shield absorbed the whole
  hit (effect on the shield sphere, 0x13ce3), 1 when an armour hit did not lower the component's integrity
  step, 2 when it did (0x13e61 / 0x13e70); terrain hits use group 1 (0x1f603).
* Bitmap parts (TSBitmapPart render 0x52b90): one bitmap pixel = radius*4/256 world units, anchored at
  (xo, yo); opaque palette pixels, index 0 transparent, no blending.
* Bullets (bullet.cpp 0x7bb0..0x8134): BULLETS.DAT[sub] {shape, lifetime, hit size, frame period, sound}.
* Bolts (lasers / PBEAM / ELF, 0x88cc, 0x8268, render 0x87e0): instant ray, drawn for one sim frame from
  muzzle to hit as two crossed quads of half width table[sub] in solid palette colour table[sub];
  the ELF (sub with jitter) is a zig-zag ribbon of segments with random offsets.
* Rockets (rocket.cpp 0x73d0, update 0x7198): ROCKETS.DAT[sub].w0 = shape; no smoke trail is spawned.

Nothing here embeds an original value: colours, sizes, timings and sounds are read from the user's files.
"""
import argparse
import json
import math
import os
import statistics
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dts  # noqa: E402
import export_es1  # noqa: E402
import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
import gfx  # noqa: E402
import siege_paths as P  # noqa: E402

PACK = 'es1'
SIM = P.work('extracted', 'SIMVOL0')
EXE = ('original/DBSIM.EXE', 0x48fd)
TRANSPARENT = 0
TIMER_UNITS_PER_S = 2560.0          # 0x6410c counts timers down by the frame scale (256 = 100 ms)
NOMINAL_FRAME_S = 0.1               # sim frame scale normalised to 100 ms (docs/formats/units.md)
PIXEL_SCALE_SHIFT = 8               # 0x5e7f8: v*scale >> 8
RADIUS_PROJECTION = 4               # 0x52c13: scale = project(radius << 2)
METRES_PER_UNIT = 1.0 / 256.0       # project scale policy for es1 (scale-policy, units.md); pack.json may override
SOUND_ID_BASE = 10                  # 0x5c8d / 0x81bc: sound id = table value + 10
FLAT_SHAPE = 1                      # 0x5c18: explosion ground ring = FLAT shape list entry 1
EXPLO_DBAS = 'EXPLO%d'
EXPLO_DBA_COUNT = 9                 # 0x57db: loop over "explo0".."explo8"
ELF_SPEC = 'lightning'

# EXPLOS.DAT row word indices (docs/formats/gameplay.md section 6)
W_SHAPE, W_SEQUENCE, W_DBA, W_PERIOD, W_RING, W_LIGHT, W_LIGHT_RAMP, W_SOUND = 0, 1, 2, 3, 4, 5, 6, 20
LIGHT_RAMP_WORDS = 12               # words 6..17: per-frame light intensity (low byte)

# VA -> (hex bytes, meaning): the instructions this decoder relies on.
EVIDENCE = {
    0x58FF: ('668b1f0fbfdbc1e302', 'explosion shape <- row.w0'),
    0x5910: ('668b5f040fbfdbc1e302', 'explosion bitmap array <- explo<row.w2>'),
    0x52C0C: ('668b4b080fbfc9c1e102', 'TSBitmapPart::render: scale = project(radius << 2)'),
    0x8807: ('668b0c4d', 'bolt render: colour = table[sub]'),
    0x84CA: ('668b0445', 'bolt ctor: half width = table[sub]'),
    0x8369: ('68', 'ELF bolt: push segment length (direction scaled to it)'),
    0x8993: ('6a', 'bolt fire: push sound id'),
    0x83D8: ('6625', 'ELF bolt: random offset mask'),
    0x67AB: ('c74301', 'smoke puff frame period'),
}


# ------------------------------------------------------------------ inputs

class SimExe:
    """DBSIM.EXE bytes, checked against EVIDENCE; `None` reads when the exe is not present."""

    def __init__(self):
        path = P.work(EXE[0])
        self.data = open(path, 'rb').read() if os.path.exists(path) else None
        if self.data is None:
            return
        bad = [hex(va) for va, (hexb, _) in EVIDENCE.items() if self._bytes(va, len(hexb) // 2).hex() != hexb]
        if bad:
            raise SystemExit('fx_es1: DBSIM.EXE does not match the analysed build at ' + ', '.join(bad))

    def _bytes(self, va, n):
        return self.data[va + EXE[1]:va + EXE[1] + n]

    def u32_after(self, va):
        """The 32-bit operand that follows the checked opcode bytes at `va`."""
        if self.data is None:
            return None
        return struct.unpack_from('<I', self.data, va + EXE[1] + len(EVIDENCE[va][0]) // 2)[0]

    def u16_after(self, va):
        return None if self.data is None else self.u32_after(va) & 0xffff

    def u8_after(self, va):
        return None if self.data is None else self.u32_after(va) & 0xff

    def words(self, va, n):
        return list(struct.unpack_from('<%dh' % n, self.data, va + EXE[1]))


def load_json(*rel):
    with open(P.pack(PACK, *rel), encoding='utf-8') as f:
        return json.load(f)


def load_dts(name):
    return dts.read_file(open(os.path.join(SIM, 'DTS', name + '.DTS'), 'rb').read())


def load_dba(name):
    return gfx.read_any(open(os.path.join(SIM, 'DBA', name + '.DBA'), 'rb').read())


def load_sound_stems():
    import audio
    path = os.path.join(SIM, 'STR', 'SOUNDS.STR')
    if not os.path.exists(path):
        return {}
    return {r['id']: os.path.splitext(r['file'].replace('\\', '/').split('/')[-1])[0].lower()
            for r in audio.sounds_table(path)}


def metres_per_unit():
    meta = load_json('pack.json')
    return float(meta.get('world_metres_per_unit', METRES_PER_UNIT))


# ------------------------------------------------------------------ shape helpers

def bitmap_frames(shape):
    """The bitmap_parts a shape shows, in frame order (cell-anim children, or the single part)."""
    found = []

    def walk(o):
        if o.get('type') == 'cell_anim_part' and not found:
            found.extend(p for p in o['parts'] if p['type'] == 'bitmap_part')
            return
        if o.get('type') == 'bitmap_part':
            found.append(o)
            return
        for c in o.get('parts', []):
            walk(c)

    walk(shape)
    return found


def typical_part_radius(objs):
    """Median bitmap_part radius of a shape list (pixel size for shapes drawn without bitmaps)."""
    return statistics.median(p['radius'] for o in objs for p in bitmap_frames(o))


def make_metres_per_pixel(part, mpu):
    # 0x52c0c..0x52c89: screen px = bitmap px * project(radius << 2) >> 8
    return part['radius'] * RADIUS_PROJECTION / float(1 << PIXEL_SCALE_SHIFT) * mpu


def make_indexed_frames(parts, dba):
    return [(dba[p['bmp_tag']]['w'], dba[p['bmp_tag']]['h'], dba[p['bmp_tag']]['pixels']) for p in parts]


def make_rgba(frames, palette):
    out = []
    for w, h, pix in frames:
        out.append(gfx.to_image({'w': w, 'h': h, 'pixels': bytes(pix)}, [tuple(c) + (0,) for c in palette]))
    return out


def write_single_shape(objs, index, name):
    """One shape of a shape-list DTS as its own shape JSON (export_es1 schema) -> "es1:<name>"."""
    j = export_es1.shape_to_json([objs[index]], name)
    export_es1.write_json(P.pack(PACK, 'shapes', name + '.json'), j)
    return '%s:%s' % (PACK, name)


# ------------------------------------------------------------------ sprites

class SpriteBook:
    """Writes the pack's sprites and keeps RGBA copies for the contact sheet."""

    def __init__(self, lib, palette_name, palette, mpu):
        self.lib, self.palette_name, self.palette, self.mpu = lib, palette_name, palette, mpu
        self.sheet = []

    def add_bitmap_shape(self, name, shape, dba, fps, loop, source):
        parts = bitmap_frames(shape)
        if not parts:
            return None
        frames = make_indexed_frames(parts, dba)
        self.lib.add_indexed_sprite(name, frames, self.palette_name, fps=fps, loop=loop,
                                    metres_per_pixel=make_metres_per_pixel(parts[0], self.mpu),
                                    origins=[[p['xo'], p['yo']] for p in parts], blend='alpha',
                                    palette_per_world=True, source=source)
        self.sheet.append((name, make_rgba(frames, self.palette)))
        return name

    def add_raster(self, name, frames, fps, mpp, source):
        origins = [[w // 2, h // 2] for w, h, _ in frames]
        self.lib.add_indexed_sprite(name, frames, self.palette_name, fps=fps, loop=False, metres_per_pixel=mpp,
                                    origins=origins, blend='alpha', palette_per_world=True, source=source)
        self.sheet.append((name, make_rgba(frames, self.palette)))
        return name

    def height_m(self, name):
        s = self.lib.sprites[name]
        return max(img.height for img in dict(self.sheet)[name]) * s['metres_per_pixel']


def rasterise_line_cells(shape, colour, units_per_px):
    """Shape cells made of 2-point solid polys (EXPLOS line sparks, drawn in the x/z plane) -> frames."""
    from PIL import Image, ImageDraw
    cells = [c for c in shape['parts'][0]['parts'][0]['parts'] if c['type'] == 'group']
    half = int(math.ceil(shape['radius'] / units_per_px)) + 1
    frames = []
    for g in cells:
        img = Image.new('L', (half * 2, half * 2), TRANSPARENT)
        draw = ImageDraw.Draw(img)
        for poly in export_es1.polys_of_group(g):
            pts = [(half + v[0] / units_per_px, half - v[2] / units_per_px) for v in poly['v']]
            draw.line(pts, fill=colour)
        frames.append((img.width, img.height, img.tobytes()))
    return frames


# ------------------------------------------------------------------ explosions

def explosion_light(row, frames, period_s, mpu):
    """w5 != 0: a point light (0x54b0) whose intensity is the low byte of word 6+frame (0x5e0c)."""
    if not row[W_LIGHT]:
        return None
    ramp = [row[W_LIGHT_RAMP + min(f, LIGHT_RAMP_WORDS - 1)] & 0xff for f in range(frames)]
    light = fx_common.make_3space_light(ramp, period_s, mpu)
    light['kind'] = row[W_LIGHT]
    return light


def build_explosions(lib, book, rows, elf_colour, sounds, ring_shape):
    objs = load_dts('EXPLOS')
    dbas = [load_dba(EXPLO_DBAS % i) for i in range(EXPLO_DBA_COUNT)]
    for i, row in enumerate(rows):
        shape = objs[row[W_SHAPE]]
        period_s = row[W_PERIOD] / TIMER_UNITS_PER_S
        sprite = 'explos_%d' % row[W_SHAPE]
        src = 'EXPLOS.DAT row %d: EXPLOS.DTS shape %d, bitmaps %s (explo.cpp 0x58ff)' % (
            i, row[W_SHAPE], EXPLO_DBAS % row[W_DBA])
        if sprite not in lib.sprites:
            made = book.add_bitmap_shape(sprite, shape, dbas[row[W_DBA]], 1.0 / period_s, False, src)
            if made is None:
                units_per_px = typical_part_radius(objs) * RADIUS_PROJECTION / float(1 << PIXEL_SCALE_SHIFT)
                book.add_raster(sprite, rasterise_line_cells(shape, elf_colour, units_per_px), 1.0 / period_s,
                                units_per_px * book.mpu,
                                src + '; 2-point line cells rasterised in the x/z plane at the usual bitmap '
                                'pixel size, colour = the ELF bolt colour (the original uses a runtime '
                                'shade-ramp index)')
        frames = len(lib.sprites[sprite]['frames'])
        duration = round(frames * period_s, 3)
        layers = [{'sprite': sprite, 'duration': duration, 'fade': False}]
        if row[W_RING]:
            layers.append({'shape': ring_shape, 'duration': duration, 'cells_per_frame': True})
        light = explosion_light(row, frames, period_s, book.mpu)
        lib.add_effect('explo_%d' % i, layers, light=light, sound=sounds.get(row[W_SOUND] + SOUND_ID_BASE),
                       source=src + '; frame %.0f ms (w3/2560 s), sound id w20+10, light w5/w6..' % (period_s * 1000))


def build_smoke(lib, book, period_units):
    objs = load_dts('SMOKE')
    dba = load_dba('SMOKE')
    period_s = period_units / TIMER_UNITS_PER_S
    for i, shape in enumerate(objs):
        name = 'smoke_%d' % i
        book.add_bitmap_shape(name, shape, dba, 1.0 / period_s, False,
                              'SMOKE.DTS shape %d with SMOKE.DBA (smoke loader 0x6664); puff frame period 0x67ab' % i)
        frames = len(lib.sprites[name]['frames'])
        lib.add_effect(name, [{'sprite': name, 'duration': round(frames * period_s, 3), 'fade': False}],
                       source='smoke puff (0x6704 ctor, 0x693c update): one pass of the cells, drifting; '
                              'spawned by wreck smoke emitters (0x69ec), not by weapons')


# ------------------------------------------------------------------ weapons

def palette_colour(palette, index, alpha=1.0):
    r, g, b = palette[index]
    return [round(r / 255.0, 3), round(g / 255.0, 3), round(b / 255.0, 3), alpha]


def make_bolt_tables(exe, bnd_words, count):
    """Half width and colour index per bolt sub: from the exe tables, else the BEAM BND copy of them."""
    width_va, colour_va = exe.u32_after(0x84CA), exe.u32_after(0x8807)
    if width_va is not None:
        return exe.words(width_va, count), exe.words(colour_va, count), 'exe 0x84ca/0x8807'
    words = bnd_words[4:]
    return words[:count], words[6:6 + count], 'BEAM.BND words (same values as the exe tables)'


def impact_block(row):
    # weapons.json names the three fx groups miss / shield / armour; Mech::onHit shows that group 0 is the
    # shield-absorbed hit, group 1 armour (no integrity step) and terrain, group 2 armour (integrity step).
    to_names = lambda ids: ['explo_%d' % i for i in ids]  # noqa: E731
    return {'miss': to_names(row['fx_shield_hit']), 'shield': to_names(row['fx_miss']),
            'armor': to_names(row['fx_armor_hit']), 'armor_light': to_names(row['fx_shield_hit'])}


class WeaponFx:
    """Builds the per-weapon fx blocks from the projectile rows and the original projectile tables."""

    def __init__(self, ctx):
        self.ctx = ctx

    def block(self, w, _rel):
        row = self.row_for(w)
        if w.get('class') == 'ecm' or row is None:
            return self.passive(w)
        kind = row['type_name']
        build = {'bullet': self.bullet, 'bolt': self.bolt, 'missile': self.missile, 'grenade': self.grenade}[kind]
        fx = build(w, row)
        fx['impact'] = impact_block(row)
        return fx

    def row_for(self, w):
        row = w.get('projectile_row')
        if isinstance(row, dict):
            return row
        rows = self.ctx['rows']
        if w.get('class') == 'grenade':
            return next(r for r in rows if r['type_name'] == 'grenade')
        if isinstance(row, str):      # missile rack: the loadout picks the missile row (type 0, sub = type)
            return next(r for r in rows if r['type_name'] == 'missile' and r['sub'] == 0)
        return None

    @staticmethod
    def base(source, notes=''):
        return {'source': source, 'projectile': None, 'beam': None, 'trail': None, 'muzzle': None,
                'impact': {'miss': [], 'shield': [], 'armor': []}, 'notes': notes}

    def passive(self, w):
        return self.base('WEAPONS.DAT projectile field = none (ECM, 0xc421)', 'passive: no shot, no effects')

    def bullet(self, w, row):
        c = self.ctx
        b = c['bullets'][row['sub']]
        fx = self.base('bullet.cpp: BULLETS.DAT[%d] -> BULLETS.DTS shape %d (0x7d43), fire sound 0x81bc'
                       % (row['sub'], b['shape']))
        fx['fire_sound'] = c['sounds'].get(b['sound'] + SOUND_ID_BASE)
        sprite = c['bullet_sprites'].get(b['shape'])
        if sprite:
            fx['projectile'] = {'sprite': sprite, 'shape': None, 'size': round(c['book'].height_m(sprite), 3),
                                'color': None, 'spin_dps': 0.0, 'face': 'billboard', 'light': None}
            fx['notes'] = 'animated bitmap ball, frames advance every BULLETS.DAT frame-period timer units (0x7fa0)'
            return fx
        line = c['bullet_lines'][b['shape']]
        fx['projectile'] = {'sprite': None, 'shape': None, 'size': line['length_m'],
                            'color': palette_colour(c['palette'], line['index']), 'spin_dps': 0.0,
                            'face': 'velocity', 'light': None, 'palette_index': line['index']}
        fx['notes'] = 'original tracer is a one-pixel line of this length along the flight axis'
        return fx

    def bolt(self, w, row):
        c = self.ctx
        sub = row['sub']
        half, index = c['bolt_width'][sub], c['bolt_colour'][sub]
        fx = self.base('bolt 0x88cc/0x8268, render 0x87e0: half width and colour index per bolt sub (%s)'
                       % c['bolt_source'])
        fx['fire_sound'] = c['sounds'].get(c['bolt_sound'])
        fx['beam'] = {'texture': None, 'texture_format': None, 'palette': c['palette_name'],
                      'color': palette_colour(c['palette'], index), 'palette_index': index,
                      'width': round(2 * half * c['mpu'], 3), 'duration': NOMINAL_FRAME_S, 'style': 'solid',
                      'cross': True, 'glow': False}
        fx['notes'] = ('instant hit; drawn for one sim frame from muzzle to the hit point as two crossed quads '
                       '(vertical and horizontal) in one flat palette colour')
        if sub == c['elf_sub']:
            fx['beam'].update({'style': ELF_SPEC, 'cross': False,
                               'segment_length': round(c['elf_segment'] * c['mpu'], 3),
                               'jitter': round(c['elf_jitter'] * c['mpu'], 3)})
            fx['notes'] = ('instant hit; a zig-zag ribbon: a node every segment_length along the ray, each inner '
                           'node offset by a random 0..jitter on every axis, ribbon half width vertical')
        return fx

    def missile(self, w, row):
        c = self.ctx
        rocket = c['rockets'][row['sub']]
        fx = self.base('rocket.cpp: ROCKETS.DAT[%d].w0 = ROCKETS.DTS shape %d (0x750d)' % (row['sub'], rocket['shape']))
        fx['fire_sound'] = c['sounds'].get(rocket['w6'] + SOUND_ID_BASE)
        fx['projectile'] = {'sprite': None, 'shape': c['rocket_shapes'][rocket['shape']], 'size': 1.0, 'color': None,
                            'spin_dps': 0.0, 'face': 'velocity', 'light': None}
        fx['notes'] = ('no smoke trail in the original (rocket.cpp spawns none); the exhaust is the shape\'s '
                       'cell animation, advanced every ROCKETS.DAT w4 timer units (0x71c9)')
        return fx

    def grenade(self, w, row):
        fx = self.base('GREN: projectile field 22 is past the 19-row table and its fire hook 0x7b44 is an empty '
                       'stub; impacts from the first grenade row (type 3)')
        # the remake lobs a grenade: the EMP ball bitmap (the game's only round bitmap shot) stands in for it
        fx['projectile'] = {'sprite': GRENADE_STAND_IN_SPRITE, 'shape': None, 'size': GRENADE_STAND_IN_SIZE,
                            'color': None, 'spin_dps': 0.0, 'face': 'billboard', 'light': None}
        fx['notes'] = ('the shipping game launches nothing; the remake lobbed grenade borrows the EMP ball '
                       'bitmap; impacts are an approximation')
        return fx


GRENADE_STAND_IN_SPRITE = 'bullets_2'
GRENADE_STAND_IN_SIZE = 1.0


def make_bullet_lines(objs, mpu):
    """BULLETS.DTS poly shapes: a 2-point solid poly line -> {length_m, palette index}."""
    lines = {}
    for i, o in enumerate(objs):
        pieces = export_es1.flatten_lod(o)[0]
        polys = [p for piece in pieces for p in piece['polys']]
        if not polys:
            continue
        ys = [v[1] for v in polys[0]['v']]
        lines[i] = {'length_m': round((max(ys) - min(ys)) * mpu, 3), 'index': polys[0]['m']['index']}
    return lines


def elf_sub(rows, lightning_rows):
    # the bolt sub whose row references the line-spark explosion is the zig-zag one (0x82ed: sub 1)
    for r in rows:
        if r['type_name'] == 'bolt' and set(r['fx_miss']) & lightning_rows:
            return r['sub']
    return None


def build_bullet_sprites(book, bullets_dts, bullets):
    """BULLETS.DAT shapes drawn as bitmaps (EMP balls) -> {shape: sprite name}; looping at word 3's period."""
    dba = load_dba('BULLETS')
    sprites = {}
    for b in bullets:
        if b['shape'] in sprites or not bitmap_frames(bullets_dts[b['shape']]):
            continue
        fps = TIMER_UNITS_PER_S / b['flags'] if b['flags'] else 0.0
        sprites[b['shape']] = book.add_bitmap_shape(
            'bullets_%d' % b['shape'], bullets_dts[b['shape']], dba, fps, True,
            'BULLETS.DTS shape %d with BULLETS.DBA (0x7cc0); frame period = BULLETS.DAT word 3' % b['shape'])
    return sprites


# ------------------------------------------------------------------ main

def build(sheet_path):
    exe = SimExe()
    proj = load_json('gameplay', 'projectiles.json')
    weapons = load_json('gameplay', 'weapons.json')
    bnd = load_json('gameplay', 'bnd.json')['SIMVOL0']
    meta = load_json('pack.json')
    palette_name = meta.get('default_palette', 'WORLD0')
    palette = load_json('palettes', palette_name + '.json')
    mpu = metres_per_unit()
    rows = weapons['projectiles']
    lib = fx_common.Library(PACK, 'DBSIM.EXE explo.cpp/bullet.cpp/rocket.cpp/smoke + EXPLOS/BULLETS/SMOKE/ROCKETS '
                                  'DTS/DAT; see docs/formats/weapon_fx.md section 2')
    book = SpriteBook(lib, palette_name, palette, mpu)
    sounds = load_sound_stems()

    bolt_count = 1 + max(r['sub'] for r in rows if r['type_name'] == 'bolt')
    widths, colours, bolt_source = make_bolt_tables(exe, bnd['BEAM']['words'], bolt_count)
    explos = load_dts('EXPLOS')
    line_rows = {i for i, r in enumerate(proj['explosions']) if not bitmap_frames(explos[r[W_SHAPE]])}
    elf = elf_sub(rows, line_rows)
    ring = write_single_shape(load_dts('FLAT'), FLAT_SHAPE, 'FLAT_%d' % FLAT_SHAPE)
    build_explosions(lib, book, proj['explosions'], colours[elf] if elf is not None else 0, sounds, ring)
    smoke_period = exe.u32_after(0x67AB) or proj['explosions'][0][W_PERIOD]
    build_smoke(lib, book, smoke_period)
    fx_deaths.apply_deaths(lib, fx_deaths.es1_deaths(lib))

    bullets_dts = load_dts('BULLETS')
    bullet_sprites = build_bullet_sprites(book, bullets_dts, proj['bullets'])
    rockets_dts = load_dts('ROCKETS')
    ctx = {
        'rows': rows, 'palette': palette, 'palette_name': palette_name, 'mpu': mpu, 'book': book,
        'sounds': sounds, 'bullets': proj['bullets'], 'rockets': proj['rockets'],
        'bullet_sprites': bullet_sprites, 'bullet_lines': make_bullet_lines(bullets_dts, mpu),
        'rocket_shapes': {r['shape']: write_single_shape(rockets_dts, r['shape'], 'ROCKETS_%d' % r['shape'])
                          for r in proj['rockets']},
        'bolt_width': widths, 'bolt_colour': colours, 'bolt_source': bolt_source,
        'bolt_sound': exe.u8_after(0x8993),
        'elf_sub': elf,
        'elf_segment': exe.u32_after(0x8369) or 0, 'elf_jitter': exe.u16_after(0x83D8) or 0,
    }
    path = lib.write()
    missing = fx_common.attach_weapon_fx(PACK, WeaponFx(ctx).block)
    if missing:
        raise SystemExit('fx_es1: no fx block for ' + ', '.join(missing))
    if sheet_path:
        fx_common.contact_sheet(book.sheet, sheet_path)
    print('fx_es1: %d sprites, %d effects -> %s' % (len(lib.sprites), len(lib.effects), path))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--sheet', help='also write a contact sheet PNG of every sprite')
    args = ap.parse_args(argv)
    build(args.sheet)


if __name__ == '__main__':
    main()
