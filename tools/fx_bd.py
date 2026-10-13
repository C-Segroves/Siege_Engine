"""Metaltech: Battledrome weapon visual effects -> gamedata/bd/fx/effects.json + an `fx` block per weapon
(docs/formats/weapon_fx.md sections 1 and 4).

    python tools/fx_bd.py [--sheet renders/weapon_fx_bd_sprites.png]

Reads bd/installed/ (tools/bd_unchunk.py): the bitmap effect shapes DTS/<FX>.DTS (a cell_anim_part of
bitmap_parts) with their DBA bitmaps, the arena palette DTS/NRMPAL.DPL (exported as palettes/NRMPAL.json by
export_bd), and SIM.EXE tables / instructions (VA = file offset - 0x69CD; Release 1.3.2, checked first):

* Explosion types: table 0x762a8, 0x2c bytes per type {sound id, light intensity, light inner / outer radius,
  shape count, shape name list}; Explosion ctor 0x11358 picks one shape at random (0x114d9), advances one
  cell-anim frame per 25 sim ticks = 100 ms (0x1173e) and dies after the last frame; its light fades as
  127*(frames-f)/frames (0x11776).
* Bitmap parts (TSBitmapPart render 0x30c4c): one bitmap pixel = radius/64 world units (scale =
  project(4*radius) applied as v*scale>>8), anchored at the hotspot (xo, yo) on the part's centre;
  opaque palette pixels with index 0 transparent (8-bit renderer, no blending).
* Laser beam render 0xc738: a screen-space quad from muzzle to beam end, half width = the class row's beam
  radius (projected, capped at that many pixels). High detail: a core of half that width in palette colour
  read at 0xcb74 plus side strips in the colour read at 0xca4c; low detail one quad in the colour at 0xc9ce.
* Shield hits: Herc::absorbShield 0x80cc spawns explosion type 3 at the hit point when the shield lost
  more than 15 points (0x8125).
* Plasma ball frame 0xdd81: (t/100 ms) % 7 + 7 * min(2, t / (lifetime/3)) - 3 shrinking phases of 7 frames.
* Mine spin 0x1044a: yaw += 0x200 (65536 = 360 deg) per mine update.

Nothing here embeds an original value: names, colours, sizes and timings are read from the user's files.
"""
import argparse
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dts  # noqa: E402
import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
import gfx  # noqa: E402
import siege_paths as P  # noqa: E402
from export_bd_weapons import Sim, explosions, sound_list, MPU, TICK, UPDATE, ANGLE_DEG  # noqa: E402

PACK = 'bd'
BD = P.work('bd', 'installed')
PALETTE = 'NRMPAL'                 # ArenaPalette::loadFile 0x2c18c: the arena palette
TRANSPARENT = 0
PIXELS_PER_RADIUS = 64             # 0x30d05..0x30d4d: pixel = radius*4 projected, >> 8
EXPLOSION_TYPES = 8                # rows in the 0x762a8 table
FRAME_SECONDS = UPDATE * TICK      # 0x1173e: explosion frame = elapsed / 25 ticks
LIGHT_FULL = 127                   # 0x11776: light fade numerator
PLASMA_BALL = 'PLASMBAL'
ENGINE_WEAPONS = 'gameplay/weapons_engine.json'   # attach_weapon_fx visits it before the raw dump

# VA -> (hex bytes, meaning): instructions this decoder relies on beyond export_bd_weapons.EVIDENCE.
EVIDENCE = {
    0x1173E: ('b919000000', 'Explosion::update: frame = elapsed / 25 ticks'),
    0x114D9: ('48506808', 'Explosion ctor: random shape index among the row\'s shapes'),
    0x30D05: ('668b4b080fbfc9c1e10251', 'TSBitmapPart::render: scale = project(radius*4)'),
    0x8125: ('83f90f7e2b6a03', 'Herc shield absorb: explosion type 3 when the shield lost > 15 points'),
    0xC9CE: ('c745a4', 'laser beam, low detail: one quad, colour dword follows'),
    0xCA4C: ('c745bc', 'laser beam, high detail: side strip colour dword follows'),
    0xCB74: ('c745bc', 'laser beam, high detail: core colour dword follows'),
    0xC9BE: ('833d0a63090002', 'laser beam: detail level >= 2 draws core + side strips'),
    0xDD92: ('b919000000', 'plasma ball: frame time 25 ticks'),
    0xDD9D: ('b107', 'plasma ball: 7 frames per phase'),
    0xDDAE: ('b103', 'plasma ball: phase = t / (lifetime / 3)'),
    0x1044A: ('668145d4', 'mine: yaw increment (word follows) per update'),
    0xFA38: ('b907000000', 'missile at/below the floor -> explosion type 7, else 1'),
}
LASER_CORE_COLOUR_VA = 0xCB77
LASER_EDGE_COLOUR_VA = 0xCA4F
LASER_LOW_DETAIL_COLOUR_VA = 0xC9D1
MINE_YAW_STEP_VA = 0x1044E
SHIELD_FLASH_MIN_VA = 0x8127

# Which explosion type each weapon class spawns (call sites of the Explosion ctor 0x11358).
CLASS_EXPLOSION = {
    'laser': 4,              # 0xc061 beam end on the floor/wall/range, 0xc485 hit object
    'blaster': 5,            # 0xd4f2 hit object, 0xd553 expired
    'autocannon': 6,         # 0x1123e, 0x1129b
    'plasma': 1,             # 0xe035
    'missile_launcher': 1,   # 0xfa65 (type 7 when it reaches the floor)
    'mine_launcher': 7,      # 0x1064c
}
MISSILE_FLOOR_EXPLOSION = 7
SHIELD_EXPLOSION = 3


class SimFx(Sim):
    """SIM.EXE with the effect-specific evidence."""

    def check_fx(self):
        bad = [(hex(va), m) for va, (h, m) in EVIDENCE.items() if self.b(va, len(h) // 2).hex() != h]
        if bad:
            raise SystemExit('SIM.EXE does not match the decoded build (Release 1.3.2): %s' % bad)

    def u8(self, va):
        return self.b(va, 1)[0]

    def i16(self, va):
        return struct.unpack('<h', self.b(va, 2))[0]


# ---------------------------------------------------------------- sprites

def load_palette():
    with open(P.pack(PACK, 'palettes', PALETTE + '.json'), encoding='utf-8') as f:
        return json.load(f)


def read_bitmap_parts(name):
    """The bitmap_parts of DTS/<name>.DTS in cell-anim order: [{bmp_tag, xo, yo, radius}]."""
    with open(os.path.join(BD, 'DTS', name + '.DTS'), 'rb') as f:
        shape = dts.read_obj(dts.Reader(f.read(), 0))
    parts = []

    def walk(p):
        if p['type'] == 'bitmap_part':
            parts.append(p)
        for c in p.get('parts', []):
            walk(c)
    walk(shape)
    return parts


def read_bitmaps(name):
    with open(os.path.join(BD, 'DTS', name + '.DBA'), 'rb') as f:
        return gfx.read_dba(f.read())


def signed_byte(v):
    return v - 256 if v > 127 else v


def make_sprite_frames(name):
    """-> (frames [(w, h, pixels)], origins, metres per pixel per frame)."""
    bitmaps = read_bitmaps(name)
    frames, origins, mpp = [], [], []
    for part in read_bitmap_parts(name):
        bmp = bitmaps[part['bmp_tag']]
        frames.append((bmp['w'], bmp['h'], bmp['pixels']))
        origins.append([signed_byte(part['xo']), signed_byte(part['yo'])])   # read as signed bytes (0x30d32)
        mpp.append(round(part['radius'] / PIXELS_PER_RADIUS * MPU, 5))
    return frames, origins, mpp


def add_sprite(lib, name, loop=False, **meta):
    frames, origins, mpp = make_sprite_frames(name)
    largest = max(range(len(frames)), key=lambda i: frames[i][1] * mpp[i])
    lib.add_indexed_sprite(
        name, frames, PALETTE, fps=round(1.0 / FRAME_SECONDS, 3), loop=loop,
        metres_per_pixel=mpp[largest], frame_metres_per_pixel=mpp, origins=origins, blend='alpha',
        source='DTS/%s.DTS bitmap_parts (cell_anim_part) + DTS/%s.DBA; pixel = radius/%d units (SIM 0x30c4c), '
               'one frame per 100 ms (0x1173e)' % (name, name, PIXELS_PER_RADIUS), **meta)
    return max(h * m for (_, h, _), m in zip(frames, mpp))


def sprite_names(expl):
    names = []
    for row in expl:
        names += [s for s in row['shapes'] if s not in names]
    return names + [PLASMA_BALL]


# ---------------------------------------------------------------- effects

def explosion_effect_name(etype, shape):
    return 'expl%d_%s' % (etype, shape)


def make_light(row, frames):
    intensity, inner, outer = row['light']
    if intensity <= 0:
        return None
    k = round(min(1.0, intensity / LIGHT_FULL), 3)
    return {'color': [k, k, k], 'range': round(outer * MPU, 2), 'inner_range': round(inner * MPU, 2),
            'duration': round(frames * FRAME_SECONDS, 3), 'fade': 'linear'}


def make_sprite_layer(lib, shape):
    frames = len(lib.sprites[shape]['frames'])
    return {'sprite': shape, 'duration': round(frames * FRAME_SECONDS, 3), 'delay': 0.0,
            'offset': [0, 0, 0], 'grow': 1.0, 'fade': False}


def add_explosions(lib, expl, sounds):
    """One effect per (explosion type, shape): BD picks one of the row's shapes at random."""
    for row in expl:
        for shape in row['shapes']:
            frames = len(lib.sprites[shape]['frames'])
            lib.add_effect(
                explosion_effect_name(row['type'], shape), [make_sprite_layer(lib, shape)],
                light=make_light(row, frames), sound=sounds[row['sound_index']],
                source='SIM explosion type %d (table 0x762a8 row %d), shape %s; %d frames x 100 ms; light '
                       'intensity/127 fading linearly, inner/outer radius' % (row['type'], row['type'], shape, frames))


def add_shield_combos(lib, expl, sounds):
    """Shield hit = the projectile's own explosion plus the SHLDHIT2 flash at the hit point."""
    flash = expl[SHIELD_EXPLOSION]['shapes'][0]
    for etype in sorted(set(CLASS_EXPLOSION.values())):
        for shape in expl[etype]['shapes']:
            base = lib.effects[explosion_effect_name(etype, shape)]
            lib.add_effect(
                'shield_' + explosion_effect_name(etype, shape),
                [make_sprite_layer(lib, flash)] + base['layers'], light=base['light'],
                sound=sounds[expl[SHIELD_EXPLOSION]['sound_index']],
                source='Herc shield absorb 0x80cc: explosion type %d (%s) at the hit point when the shield lost '
                       'more than 15 points, plus the projectile\'s own type %d explosion' % (SHIELD_EXPLOSION, flash, etype))


# ---------------------------------------------------------------- per-weapon fx

def palette_rgba(palette, index):
    r, g, b = palette[index][:3]
    return [round(r / 255.0, 3), round(g / 255.0, 3), round(b / 255.0, 3), 1.0]


def make_beam(w, sim, palette):
    radius_units = w['native']['row']['radius']
    return {
        'texture': None, 'texture_format': None, 'palette': PALETTE,
        'color': palette_rgba(palette, sim.u8(LASER_EDGE_COLOUR_VA)),
        'core_color': palette_rgba(palette, sim.u8(LASER_CORE_COLOUR_VA)),
        'low_detail_color': palette_rgba(palette, sim.u8(LASER_LOW_DETAIL_COLOUR_VA)),
        'color_index': sim.u8(LASER_EDGE_COLOUR_VA), 'core_color_index': sim.u8(LASER_CORE_COLOUR_VA),
        'width': round(2 * radius_units * MPU, 4), 'core_width_ratio': 0.5,
        'max_half_width_px': radius_units, 'duration': w['beam']['duration'],
        'style': 'solid', 'glow': False,
    }


def make_projectile(w, sim, plasma_height):
    shape = w['projectile']['shape']
    p = {'sprite': None, 'shape': shape, 'size': 1.0, 'color': None, 'spin_dps': 0.0,
         'face': 'velocity', 'light': None}
    if shape == 'bd:' + PLASMA_BALL:
        p.update(sprite=PLASMA_BALL, shape=None, size=round(plasma_height, 3), face='billboard')
    elif w['kind'] == 'mine':
        step = sim.i16(MINE_YAW_STEP_VA) * ANGLE_DEG
        p['spin_dps'] = [0.0, round(step / (w['native']['row']['update_ticks'] * TICK), 1), 0.0]
    return p


def explosion_variants(expl, etype):
    return [explosion_effect_name(etype, s) for s in expl[etype]['shapes']]


def impact_lists(expl, cls):
    armour = explosion_variants(expl, CLASS_EXPLOSION[cls])
    miss = armour + (explosion_variants(expl, MISSILE_FLOOR_EXPLOSION) if cls == 'missile_launcher' else [])
    shield = armour if cls == 'mine_launcher' else ['shield_' + n for n in armour]
    return {'miss': miss, 'shield': shield, 'armor': armour}


def weapon_class(w):
    if w.get('beam'):
        return 'laser'
    shape = (w.get('projectile') or {}).get('shape')
    return {'bd:BLASTER': 'blaster', 'bd:CANON': 'autocannon', 'bd:' + PLASMA_BALL: 'plasma',
            'bd:MISSILE': 'missile_launcher', 'bd:MINE': 'mine_launcher'}.get(shape)


NOTES = {
    'laser': 'Beam drawn as a flat screen-space quad (no texture, no glow, opaque palette colours): side strips '
             'in `color`, a half-width core in `core_color` (low detail: one quad in `low_detail_color`). Half '
             'width = class row beam radius, capped at that many pixels on screen. Hit sprite RDLASER or LSRHIT '
             'at the beam end, whether it hit or not.',
    'blaster': 'Bolt = BLASTER polygon shape (solid palette colours) flying along its velocity; no light/trail.',
    'autocannon': 'Shell = CANON polygon shape; the hit uses the laser hit sprites (explosion type 6).',
    'plasma': 'Ball = PLASMBAL billboard: frame = (t/100ms)%7 + 7*min(2, t/(lifetime/3)) (sprite phases), so '
              'it shrinks in 3 steps as its damage decays.',
    'missile_launcher': 'MISSILE polygon shape; BD draws no smoke trail. Explodes EXPLD1/EXPLD2 in the air or '
                        'on a target, SHROOM when it reaches the floor (`miss` lists both).',
    'mine_launcher': 'MINE polygon shape spinning about the vertical axis while it hovers; SHROOM on '
                     'detonation. Mines bypass shields, so no shield flash.',
}


def make_fx(w, expl, sim, palette, plasma_height):
    cls = weapon_class(w)
    if cls is None:
        return None
    return {
        'source': 'SIM.EXE explosion type %d (table 0x762a8), spawned by the class code; see weapon_fx.md section 4'
                  % CLASS_EXPLOSION[cls],
        'projectile': None if cls == 'laser' else make_projectile(w, sim, plasma_height),
        'beam': make_beam(w, sim, palette) if cls == 'laser' else None,
        'trail': None,
        'muzzle': None,
        'impact': impact_lists(expl, cls),
        'pod_cell_states': make_pod_cell_states() if fires_from_pod(w, cls) else None,
        'notes': NOTES[cls] + (POD_NOTE if fires_from_pod(w, cls) else NO_POD_NOTE),
    }


POD_NOTE = ' No muzzle flash: the pod cell steps through firing states 1-4, one per 100 ms (SIM 0x7904).'
NO_POD_NOTE = ' No muzzle flash and no launcher model: BD draws nothing at mine / missile mounts or turret barrels.'


def fires_from_pod(w, cls):
    """Bay weapons sit in a Herc pod cell; launchers and the arena turret have none."""
    return cls in ('laser', 'blaster', 'autocannon', 'plasma') and w.get('category') != 'turret'


def make_pod_cell_states():
    return {'idle': 0, 'firing': [1, 2, 3, 4], 'damaged_offset': 6, 'destroyed': 12, 'frame_time': FRAME_SECONDS}


# ---------------------------------------------------------------- checks / debug sheet

def check_output(lib, missing):
    if missing:
        raise SystemExit('weapons without an fx block: %s' % missing)
    for name, s in lib.sprites.items():
        for f in s['frames']:
            if not os.path.exists(P.pack(PACK, *f.split('/'))):
                raise SystemExit('missing frame %s of %s' % (f, name))
    for name, e in lib.effects.items():
        for layer in e['layers']:
            if layer.get('sprite') and layer['sprite'] not in lib.sprites:
                raise SystemExit('effect %s uses unknown sprite %s' % (name, layer['sprite']))
    with open(P.pack(PACK, *ENGINE_WEAPONS.split('/')), encoding='utf-8') as f:
        for w in json.load(f)['weapons']:
            fx = w['fx']
            for surface, names in fx['impact'].items():
                bad = [n for n in names if n not in lib.effects]
                if not names or bad:
                    raise SystemExit('%s impact.%s empty or unknown: %s' % (w['name'], surface, bad))
            sprite = (fx['projectile'] or {}).get('sprite')
            if sprite and sprite not in lib.sprites:
                raise SystemExit('%s projectile sprite %s unknown' % (w['name'], sprite))


def write_contact_sheet(lib, palette, out_path):
    from PIL import Image
    pal = [tuple(c[:3]) for c in palette]
    rows = []
    for name, s in lib.sprites.items():
        images = []
        for f, (ox, oy) in zip(s['frames'], s['origins']):
            img = Image.open(P.pack(PACK, *f.split('/')))
            bmp = {'w': img.width, 'h': img.height, 'pixels': img.tobytes()}
            rgba = gfx.to_image(bmp, pal, transparent0=True)
            if 0 <= ox < rgba.width and 0 <= oy < rgba.height:
                rgba.putpixel((ox, oy), (255, 0, 255, 255))   # anchor marker
            images.append(rgba)
        rows.append((name, images))
    return fx_common.contact_sheet(rows, out_path, columns=21)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--sheet', help='also write a debug contact sheet of every sprite (PNG path)')
    args = ap.parse_args()
    sim = SimFx(os.path.join(BD, 'SIM.EXE'))
    sim.check()
    sim.check_fx()
    expl = explosions(sim)[:EXPLOSION_TYPES]
    sounds = sound_list(sim)
    palette = load_palette()

    lib = fx_common.Library(PACK, 'Battledrome SIM.EXE explosion table 0x762a8, bitmap effect shapes DTS/*.DTS + '
                                  '*.DBA, arena palette NRMPAL; docs/formats/weapon_fx.md section 4')
    heights = {}
    for name in sprite_names(expl):
        meta = {}
        if name == PLASMA_BALL:
            meta = {'loop': True, 'phases': 3, 'phase_frames': 7,
                    'phase_rule': 'frame = (t/frame_time) % phase_frames + phase_frames * min(phases-1, '
                                  'floor(t * phases / lifetime)) (SIM 0xdd81)'}
        heights[name] = add_sprite(lib, name, **meta)
    add_explosions(lib, expl, sounds)
    add_shield_combos(lib, expl, sounds)
    fx_deaths.apply_deaths(lib, fx_deaths.bd_deaths(lib))
    path = lib.write()

    by_record_name = {}

    def fx_for_weapon(w, rel):
        if rel == ENGINE_WEAPONS:
            fx = make_fx(w, expl, sim, palette, heights[PLASMA_BALL])
            if fx and 'native' in w:
                by_record_name[w['native']['record']['name']] = fx
            return fx
        return by_record_name.get(w.get('name'))      # export_bd's raw record dump: same record name

    check_output(lib, fx_common.attach_weapon_fx(PACK, fx_for_weapon))
    print('bd fx: %d sprites, %d effects -> %s' % (len(lib.sprites), len(lib.effects), path))
    if args.sheet:
        print('contact sheet ->', write_contact_sheet(lib, palette, args.sheet))


if __name__ == '__main__':
    main()
