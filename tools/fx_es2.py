"""Earthsiege 2 weapon visual effects -> gamedata/es2/fx/effects.json, sprite frames, beam texture and an
`fx` block on every weapon of gameplay/weapons_engine.json (docs/formats/weapon_fx.md sections 1 and 3).

    python tools/fx_es2.py            (after export_es2 and export_es2_weapons)
    python tools/fx_es2.py --sheet    also renders renders/weapon_fx_es2_sprites.png

Sources (es2/extracted/SIMVOL0); addresses are DBSIM.EXE 1.0 VAs (PE image base 0x400000):
  DAT/EXPLOS.DAT   u16 n_shapes, n_shapes x (s16 cell part, s16 EXPLO<d>.DBA index), u16 n, n x 40-byte
                   explosion records (loader 0x407b54; EXPLOS2.DAT + EXPLO<d>S.DBA = low-memory set, flag [0x4d2704])
  DTS/EXPLOS.DTS   one shape per table entry: a cell_anim_part of bitmap_parts (frame = bmp_tag into the DBA)
  DTS/BULLETS.DTS  bullet shapes; shapes made of bitmap_parts are animated billboards from DBA/BULLETS.DBA
  DTS/SMOKE.DTS    smoke columns (SMOKE.DBA), loader 0x409030
  DBA/BEAMTEX.DBA  the beam texture (BEAM.CPP 0x40b7c2)
  DAT/PROJ.DAT, BULLETS.DAT, ROCKETS.DAT, BEAM.DAT  via gameplay/weapons_raw.json (tools/export_es2_weapons.py)
Rendering rules decoded from DBSIM: see the constants below and docs/formats/weapon_fx.md section 3.
"""
import json
import os
import re
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
import dts  # noqa: E402
import gfx  # noqa: E402
import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
from export_es2_weapons import parse_sounds  # noqa: E402

PACK = 'es2'
SIM = P.work('es2', 'extracted', 'SIMVOL0')
SOUND_DIRS = [P.work('es2', 'extracted', 'SIMSOUND', d) for d in ('HMI', 'HMX')]
PALETTE = 'WORLD0'           # pack default; sprites, the beam texture and beam colours follow the mission's WORLD<n>
MPU = 1.0 / 256.0            # metres per unit (game/engine/packs.gd WORLD_SCALE es2)
TIMER_PER_S = 2048.0         # timers count down by the frame scale: 2048 units per second (docs/formats/es2.md 9)

# TSBitmapPart render 0x4762e8: screen scale = (radius*4 << focal) / depth (0x48c4c0, the point projection of
# 0x48c4f0), pixel extents = scale * pixels >> 8 (0x47df94)  ->  radius/64 world units per bitmap pixel;
# anchor = (s8 xo, s8 yo) pixels from the top-left (object +0x12/+0x13).
BITMAP_RADIUS_PER_PIXEL = 64.0
# Explosion frames advance when the record's frame delay (timer units, +2) runs out (0x40813c); every record
# uses delay 1, i.e. one frame per rendered sim frame (40..125 ms, 0x4677c9 / nominal 0x46774c). The remake
# needs a fixed rate: a typical 1996 frame rate is used (approximation, see notes).
EXPLOSION_FPS = 15.0
SMOKE_FRAME_DELAY = 200      # smoke ball: next frame every 200 timer units (0x409205)
BEAM_LIFETIME = 0x38         # beam object timer (0x40b9ed): visible for about one frame
ELF_SEGMENT_UNITS = 1024     # ELF/ELF2 bolts: one segment per 1024 units (0x40b874 sar 10)
ELF_JITTER_UNITS = 0x7f      # random 0..127 units added to every inner vertex (0x40b938)
EXPLOSION_SOUND_BASE = 10    # sound id = record +0x24 + 10 (0x4080c5)
FX_LIST_INDEX = {'miss': 0, 'shield': 1, 'armor': 2}   # 0x418b2d: fx[list*4 + rand&3], list 1/2 = 0x41898c/0x41899d
GRENADE_BULLET_ROW = 3       # L: grenade rows read BULLETS.DAT rows 3.. (unused in DBSIM 1.0)
LOCUST_PROJ_ROW, MINE_PROJ_ROW, MINE_RECORD = 9, 8, 27   # tools/export_es2_weapons.py (unused grenade rows)
PASSIVE_CLASSES = ('ecm', 'targeting_pod', 'shield_pod', 'turbo_pod', 'energy_pod')


# ------------------------------------------------------------------------------------------- read
def read_bytes(*parts):
    with open(os.path.join(SIM, *parts), 'rb') as f:
        return f.read()


def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def parse_explos(b):
    """EXPLOS.DAT -> (shape table [(cell part, dba)], records)."""
    n = struct.unpack_from('<H', b, 0)[0]
    table = [struct.unpack_from('<hh', b, 2 + 4 * i) for i in range(n)]
    p = 2 + 4 * n
    count = struct.unpack_from('<H', b, p)[0]
    return table, [make_explosion_record(b, p + 2 + 40 * i) for i in range(count)]


def make_explosion_record(b, p):
    w = struct.unpack_from('<20h', b, p)
    return {'shape': w[0], 'frame_delay': w[1], 'companion': w[2], 'light_kind': w[3],
            'light_curve': [v & 0xff for v in w[4:16]], 'near_radius': struct.unpack_from('<I', b, p + 32)[0],
            'sound': w[18], 'big': w[19]}


def bitmap_frames(shape):
    """bitmap_parts of a shape in draw order -> [(bmp_tag, xo, yo, radius)]: TSBitmapPart render reads xo as a
    signed byte (0x47655d movsx) and yo unsigned (0x47653c: xor eax, eax; mov al, [part+0x13]), so the anchor of a
    tall bitmap (the 160-pixel base explosion column) can sit at its foot."""
    out = []

    def walk(o):
        if o['type'] == 'bitmap_part':
            out.append((o['bmp_tag'], signed_byte(o['xo']), o['yo'], o['radius']))
        for c in o.get('parts', []):
            walk(c)
    walk(shape)
    return out


def signed_byte(v):
    return v - 256 if v > 127 else v


def read_shapes(name):
    return dts.read_file(read_bytes('DTS', name + '.DTS'))


def read_dba(name):
    return gfx.read_any(read_bytes('DBA', name + '.DBA'))


# ---------------------------------------------------------------------------------------- sprites
def add_shape_sprite(lib, name, frames, dba, meta):
    """One sprite from a bitmap shape: frames (bmp_tag, xo, yo, radius) drawn from the DBA bitmaps."""
    images = [(dba[tag]['w'], dba[tag]['h'], dba[tag]['pixels']) for tag, _, _, _ in frames]
    radius = frames[0][3]
    entry = dict(meta, metres_per_pixel=round(radius / BITMAP_RADIUS_PER_PIXEL * MPU, 6),
                 origins=[[xo, yo] for _, xo, yo, _ in frames], blend='alpha', palette_per_world=True)
    lib.add_indexed_sprite(name, images, PALETTE, **entry)
    return entry


def add_explosion_sprites(lib, table):
    shapes = read_shapes('EXPLOS')
    sprites = {}
    for k, (part, dba_index) in enumerate(table):
        frames = bitmap_frames(shapes[k])
        if part < 0 or not frames:
            continue
        dba = read_dba('EXPLO%d' % dba_index)
        sprites[k] = 'explo_shape_%d' % k
        add_shape_sprite(lib, sprites[k], frames, dba, {
            'fps': EXPLOSION_FPS, 'loop': False,
            'source': 'EXPLOS.DTS shape %d (radius %d) frames from EXPLO%d.DBA (EXPLOS.DAT shape table, 0x407e14); '
                      'one frame per sim frame (0x40813c), fps approximated' % (k, frames[0][3], dba_index)})
    return sprites


def add_bullet_sprites(lib, bullets_dat):
    """Bullet shapes built from bitmap_parts (EMP balls) -> looping billboards; the rest are 3D shapes.
    A bullet advances its frame every BULLETS.DAT +6 timer units (0x40b13f..0x40b180)."""
    dba = read_dba('BULLETS')
    delays = {b['shape']: b['trail_interval'] for b in bullets_dat if b['trail_interval']}
    sprites = {}
    for k, shape in enumerate(read_shapes('BULLETS')):
        frames = bitmap_frames(shape)
        if frames:
            sprites[k] = 'bullet_shape_%d' % k
            fps = TIMER_PER_S / delays[k] if k in delays else 0.0
            add_shape_sprite(lib, sprites[k], frames, dba, {
                'fps': round(fps, 3), 'loop': True,
                'source': 'BULLETS.DTS shape %d (radius %d), BULLETS.DBA; frame every BULLETS.DAT +6 = %s timer '
                          'units (0x40b13f)' % (k, frames[0][3], delays.get(k))})
    return sprites


def add_smoke(lib):
    """SMOKE.DTS columns (wreck smoke: the emitter 0x40923c has no caller in DBSIM 1.0, so weapons use none)."""
    dba = read_dba('SMOKE')
    fps = TIMER_PER_S / SMOKE_FRAME_DELAY
    for k, shape in enumerate(read_shapes('SMOKE')):
        frames = bitmap_frames(shape)
        name = 'smoke_%d' % k
        add_shape_sprite(lib, name, frames, dba, {
            'fps': round(fps, 3), 'loop': False,
            'source': 'SMOKE.DTS shape %d (radius %d), SMOKE.DBA; frame every %d timer units (0x409205); '
                      'emitter kind = shape // 4, variant = rand & 3 (0x4092a7)' % (k, frames[0][3], SMOKE_FRAME_DELAY)})
        lib.add_effect(name, [{'sprite': name}], source='smoke ball 0x409178 (not spawned by weapons)')


def save_beam_texture(lib):
    bmp = read_dba('BEAMTEX')[0]
    from PIL import Image
    img = Image.frombytes('L', (bmp['w'], bmp['h']), bytes(bmp['pixels'][:bmp['w'] * bmp['h']]))
    return lib.save_texture('beamtex', img)


# ---------------------------------------------------------------------------------------- effects
def add_explosion_effects(lib, records, sprites, sounds):
    names = {}
    for i, rec in enumerate(records):
        sprite = sprites.get(rec['shape'])
        if sprite is None:
            continue
        frame_count = len(lib.sprites[sprite]['frames'])
        names[i] = lib.add_effect('explo_%d' % i, [{'sprite': sprite}],
                                  light=make_light(rec, frame_count),
                                  sound=sound_stem(sounds, rec['sound'] + EXPLOSION_SOUND_BASE),
                                  source='EXPLOS.DAT record %d: shape %d, light kind %d, sound %d+10%s'
                                         % (i, rec['shape'], rec['light_kind'], rec['sound'],
                                            ', large (object kind 8, +0x26)' if rec['big'] else ''))
    return names


def make_light(rec, frame_count):
    """Record +6 != 0 spawns a point light (manager 0x406ee4) whose intensity follows the per-frame curve +8
    (0x4081d7); kind 2 also queries objects within +0x20 units (0x408100), which changes nothing visible."""
    if not rec['light_kind']:
        return None
    light = fx_common.make_3space_light(rec['light_curve'][:frame_count], 1.0 / EXPLOSION_FPS, MPU)
    light['kind'] = rec['light_kind']
    return light


def sound_stem(sounds, sound_id):
    """SOUNDS.STR id -> 'sim/<stem>', copying the WAV into the pack when the weapons step did not."""
    if not 0 <= sound_id < len(sounds):
        return None
    stem = os.path.splitext(sounds[sound_id]['file'])[0].lower()
    target = P.pack(PACK, 'audio', 'sfx', 'sim', stem + '.wav')
    if not os.path.exists(target):
        source = next((os.path.join(d, stem.upper() + '.WAV') for d in SOUND_DIRS
                       if os.path.exists(os.path.join(d, stem.upper() + '.WAV'))), None)
        if source is None:
            return None
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(source, target)
    return 'sim/' + stem


# ------------------------------------------------------------------------------------ weapon blocks
class WeaponFx:
    """Builds the per-weapon fx block from the PROJ row the weapon fires."""

    def __init__(self, lib, raw, explosions, bullet_sprites, beam_texture, palette):
        self.lib = lib
        self.raw = raw
        self.explosions = explosions
        self.bullet_sprites = bullet_sprites
        self.beam_texture = beam_texture
        self.palette = palette

    def block(self, weapon, _file):
        record = int(re.search(r'WEAPONS\.DAT rec (\d+)', weapon['source']).group(1))
        cls = self.raw['weapons'][record]['class']
        if cls in PASSIVE_CLASSES:
            return make_passive_block(cls)
        row = self.raw['projectiles'][self.proj_row(weapon, record, cls)]
        maker = {'bullet': self.bullet_block, 'grenade': self.grenade_block, 'missile': self.missile_block,
                 'bolt': self.beam_block}[row['type_name']]
        fx = maker(row)
        fx['impact'] = self.impact_lists(row)
        fx['muzzle'] = None
        fx['source'] = 'PROJ.DAT row %d (%s sub %d); %s' % (row['index'], row['type_name'], row['sub'], fx['source'])
        if cls == 'locust' or record == MINE_RECORD:
            fx['notes'] = ('L: the weapon does nothing in DBSIM 1.0; look taken from the unused grenade row; '
                           + fx['notes'])
        return fx

    @staticmethod
    def proj_row(weapon, record, cls):
        if cls == 'locust':
            return LOCUST_PROJ_ROW
        if record == MINE_RECORD:
            return MINE_PROJ_ROW
        return int(re.search(r'PROJ\.DAT row (\d+)', weapon['source']).group(1))

    def impact_lists(self, row):
        lists = {'miss': row['fx_miss'], 'shield': row['fx_shield_hit'], 'armor': row['fx_armor_hit']}
        return {k: [self.explosions[i] for i in ids if i in self.explosions] for k, ids in lists.items()}

    def bullet_block(self, row):
        bullet = self.raw['bullets'][row['sub']]
        return self.bullet_shape_block(bullet, 'BULLETS.DAT[%d]' % row['sub'], '')

    def grenade_block(self, row):
        index = GRENADE_BULLET_ROW + row['sub']
        bullet = self.raw['bullets'][index]
        return self.bullet_shape_block(bullet, 'BULLETS.DAT[%d]' % index,
                                       'L: grenade look = BULLETS.DAT row 3+sub (no grenade class in DBSIM 1.0)')

    def bullet_shape_block(self, bullet, where, note):
        shape = bullet['shape']
        sprite = self.bullet_sprites.get(shape)
        projectile = {'sprite': sprite, 'shape': None if sprite else 'es2:BULLETS_%d' % shape,
                      'size': self.sprite_height(sprite) if sprite else 1.0, 'color': None, 'spin_dps': 0.0,
                      'face': 'billboard' if sprite else 'velocity', 'light': None}
        notes = [note] if note else []
        notes.append('no muzzle flash, smoke or projectile light in DBSIM 1.0 (bullet.cpp spawns none)')
        return {'projectile': projectile, 'beam': None, 'trail': None,
                'source': '%s shape %d%s' % (where, shape, ' (bitmap billboard)' if sprite else ''),
                'notes': '; '.join(notes)}

    def sprite_height(self, sprite):
        entry = self.lib.sprites[sprite]
        return round(entry['metres_per_pixel'] * max(frame_height(f) for f in entry['frames']), 3)

    def missile_block(self, row):
        rocket = self.raw['rockets'][row['sub']]
        return {'projectile': {'sprite': None, 'shape': 'es2:ROCKETS_%d' % rocket['shape'], 'size': 1.0,
                               'color': None, 'spin_dps': 0.0, 'face': 'velocity', 'light': None},
                'beam': None, 'trail': None,
                'source': 'ROCKETS.DAT[%d] shape %d; exhaust = the shape\'s cell part %d cycling every %d timer units '
                          '(0x40a553)' % (row['sub'], rocket['shape'], rocket['w5'], rocket['w4']),
                'notes': 'no smoke trail: rocket.cpp (0x40a300..0x40adc0) spawns no smoke or explosion objects '
                         'while flying; the flame is part of the missile shape'}

    def beam_block(self, row):
        """BEAM.CPP render 0x40bc20.  The textured quad goes through poly 0x468310 mode 0, whose span drawer
        0x46ab10 copies BEAMTEX texels unchanged (texture table [0x4a988c] entry = BEAM.DAT +4): no tint.  The
        BEAM.DAT +2 colour is installed as the gfx fill descriptor {type 0 = flat colour} (ctx [0x6c5ff4] + 0x22c =
        surface [0x4a362c] + 0x228, read by the fill dispatch 0x483e1d); only the ELF's stippled zig-zag polygons
        (0x40bcb4: 0x48c964 / 0x48ce14 / 0x48d4b4) are filled through it."""
        beam_dat = self.raw['beams'][row['sub']]
        colour = beam_dat['palette_colour']
        beam = {'texture': self.beam_texture, 'texture_format': 'indexed', 'palette': PALETTE,
                'palette_per_world': True, 'color': [1.0, 1.0, 1.0, 1.0],
                'width': round(2 * beam_dat['width'] * MPU, 3), 'duration': round(BEAM_LIFETIME / TIMER_PER_S, 3),
                'style': 'textured', 'stretch': True, 'glow': False, 'min_pixels': 4}
        notes = ['instant textured quad facing the camera, half width BEAM.DAT +0 units on each side (at least '
                 '2 px, 0x40bdc8); texture u0..u1 runs once from muzzle to end, v0..v1 across the width '
                 '(0x40bef1: BEAMTEX rows are the cross profile), drawn untinted (span drawer 0x46ab10)']
        if row['sub'] in elf_subs(self.raw):
            beam.update({'texture': None, 'texture_format': None, 'style': 'solid', 'palette_index': colour,
                         'color': [round(c / 255.0, 3) for c in self.palette[colour]] + [1.0], 'stipple': True,
                         'jagged': {'segment': round(ELF_SEGMENT_UNITS * MPU, 3),
                                    'jitter': round(ELF_JITTER_UNITS * MPU, 3),
                                    'lift': round(beam_dat['width'] * MPU, 3), 'stipple': True}})
            notes = ['ELF: zig-zag of one segment per 4 m with 0..0.5 m random vertex offsets (0x40b862..0x40b9da), '
                     'stippled flat polygons in the BEAM.DAT +2 palette colour (fill descriptor type 0, 0x40bcb4), '
                     'redrawn every frame while the trigger is held; the BEAMTEX quad the same loop draws over the '
                     'first segment is omitted']
        return {'projectile': None, 'beam': beam, 'trail': None,
                'source': 'BEAM.DAT[%d] (BEAM.CPP render 0x40bc20)' % row['sub'], 'notes': '; '.join(notes)}


def elf_subs(raw):
    """Bolt subs fired by the continuous-beam (ELF) weapons; their bolts are drawn jagged (0x40b851)."""
    rows = {w['projectile'] for w in raw['weapons'] if w['class'] == 'beam_continuous'}
    return {raw['projectiles'][r]['sub'] for r in rows}


def frame_height(frame):
    from PIL import Image
    with Image.open(P.pack(PACK, *frame.split('/'))) as im:
        return im.height


def make_passive_block(cls):
    return {'source': 'passive equipment (%s): fires nothing' % cls, 'projectile': None, 'beam': None,
            'trail': None, 'muzzle': None, 'impact': {'miss': [], 'shield': [], 'armor': []}, 'notes': 'passive'}


# --------------------------------------------------------------------------------------- checks
def check_library(lib):
    for name, s in lib.sprites.items():
        for f in s['frames']:
            assert os.path.exists(P.pack(PACK, *f.split('/'))), f
    for name, e in lib.effects.items():
        for layer in e['layers']:
            assert layer.get('sprite') in lib.sprites, (name, layer)
        if e['sound']:
            assert os.path.exists(P.pack(PACK, 'audio', 'sfx', e['sound'] + '.wav')), e['sound']


def check_weapons(lib):
    data = load_json(P.pack(PACK, 'gameplay', 'weapons_engine.json'))
    for w in data['weapons']:
        fx = w.get('fx')
        assert fx, w['name']
        if fx['notes'] != 'passive':
            assert all(fx['impact'][k] for k in FX_LIST_INDEX), w['name']
        for names in fx['impact'].values():
            assert all(n in lib.effects for n in names), w['name']
        proj = fx['projectile'] or {}
        assert proj.get('sprite') in (None, *lib.sprites), w['name']
        shape = proj.get('shape')
        assert not shape or os.path.exists(P.pack(PACK, 'shapes', shape.split(':')[1] + '.json')), shape
        if fx['beam'] and fx['beam']['texture']:
            assert os.path.exists(P.pack(PACK, *fx['beam']['texture'].split('/'))), w['name']
    return len(data['weapons'])


# ---------------------------------------------------------------------------------------- sheet
def render_sheet(lib, out_path):
    from PIL import Image
    pal = load_json(P.pack(PACK, 'palettes', PALETTE + '.json'))
    flat = [c for rgb in pal for c in rgb[:3]]
    rows = []
    for name, s in lib.sprites.items():
        frames = []
        for f in s['frames']:
            with Image.open(P.pack(PACK, *f.split('/'))) as im:
                frames.append(indexed_to_rgba(im, flat, s['transparent_index']))
        rows.append((name, frames))
    with Image.open(P.pack(PACK, *'fx/textures/beamtex.png'.split('/'))) as im:
        rows.append(('beamtex', [indexed_to_rgba(im, flat, -1)]))
    return fx_common.contact_sheet(rows, out_path)


def indexed_to_rgba(im, flat_palette, transparent):
    p = im.convert('L').convert('P')
    p.putpalette(flat_palette)
    rgba = p.convert('RGBA')
    if transparent >= 0:
        mask = im.convert('L').point(lambda v: 0 if v == transparent else 255)
        rgba.putalpha(mask)
    return rgba


# ----------------------------------------------------------------------------------------- main
def build_library(raw):
    lib = fx_common.Library(PACK, 'Earthsiege 2 DBSIM 1.0: EXPLOS.DAT/DTS + EXPLO<d>.DBA explosions, BULLETS.DTS/DBA '
                                  'billboards, SMOKE.DTS/DBA, BEAMTEX.DBA (tools/fx_es2.py)')
    shutil.rmtree(lib.sprite_dir(''), ignore_errors=True)
    table, records = parse_explos(read_bytes('DAT', 'EXPLOS.DAT'))
    sounds = parse_sounds(open(os.path.join(SIM, 'STR', 'SOUNDS.STR'), 'rb').read())
    explosions = add_explosion_effects(lib, records, add_explosion_sprites(lib, table), sounds)
    bullet_sprites = add_bullet_sprites(lib, raw['bullets'])
    add_smoke(lib)
    return lib, explosions, bullet_sprites, save_beam_texture(lib)


def main(argv=()):
    raw = load_json(P.pack(PACK, 'gameplay', 'weapons_raw.json'))
    lib, explosions, bullet_sprites, beam_texture = build_library(raw)
    fx_deaths.apply_deaths(lib, fx_deaths.es2_deaths(lib))
    lib.write()
    palette = load_json(P.pack(PACK, 'palettes', PALETTE + '.json'))
    builder = WeaponFx(lib, raw, explosions, bullet_sprites, beam_texture, palette)
    missing = fx_common.attach_weapon_fx(PACK, builder.block)
    if missing:
        raise SystemExit('weapons without fx: %s' % missing)
    check_library(lib)
    count = check_weapons(lib)
    print('  es2 fx: %d sprites, %d effects, %d weapons' % (len(lib.sprites), len(lib.effects), count))
    if '--sheet' in argv:
        print('  sheet:', render_sheet(lib, os.path.join(P.ROOT, 'renders', 'weapon_fx_es2_sprites.png')))


if __name__ == '__main__':
    main(sys.argv[1:])
