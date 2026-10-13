"""Shared writer for the weapon visual-effects export (docs/formats/weapon_fx.md section 1).

Each game has its own decoder (tools/fx_<pack>.py) that reads the original data and builds
  * a pack effect library: sprites (animated bitmaps) and effects (explosions, puffs, flashes), and
  * one `fx` block per weapon,
then calls the helpers below to write `gamedata/<pack>/fx/effects.json`, the sprite frames and to
attach the `fx` blocks to the pack's weapon files. Nothing here knows any game's values.
"""
import json
import os

import siege_paths as P

FX_DIR = 'fx'
LIBRARY_FILE = 'effects.json'
WEAPON_FILES = ('gameplay/weapons_engine.json', 'gameplay/weapons_infantry.json', 'gameplay/weapons.json',
                'gameplay/weapons_turret.json')


class Library:
    """A pack's effect library under construction: sprites (frame files written on add) and effects."""

    def __init__(self, pack, source):
        self.pack = pack
        self.source = source
        self.sprites = {}
        self.effects = {}
        self.deaths = {}      # death effects (tools/fx_deaths.py, weapon_fx.md section 9)

    def sprite_dir(self, name):
        return P.pack(self.pack, FX_DIR, 'sprites', name)

    def add_indexed_sprite(self, name, frames, palette, **meta):
        """frames: list of (width, height, index bytes); written as 8-bit L PNGs (value = palette index)."""
        from PIL import Image
        paths = []
        os.makedirs(self.sprite_dir(name), exist_ok=True)
        for i, (w, h, pixels) in enumerate(frames):
            raw = bytes(pixels[:w * h]).ljust(w * h, b'\0')
            Image.frombytes('L', (w, h), raw).save(os.path.join(self.sprite_dir(name), '%d.png' % i))
            paths.append('%s/sprites/%s/%d.png' % (FX_DIR, name, i))
        entry = {'frames': paths, 'format': 'indexed', 'palette': palette, 'transparent_index': 0}
        entry.update(meta)
        self.sprites[name] = entry
        return entry

    def add_rgba_sprite(self, name, images, **meta):
        """images: list of PIL images (converted to RGBA)."""
        paths = []
        os.makedirs(self.sprite_dir(name), exist_ok=True)
        for i, img in enumerate(images):
            img.convert('RGBA').save(os.path.join(self.sprite_dir(name), '%d.png' % i))
            paths.append('%s/sprites/%s/%d.png' % (FX_DIR, name, i))
        entry = {'frames': paths, 'format': 'rgba'}
        entry.update(meta)
        self.sprites[name] = entry
        return entry

    def save_texture(self, name, img):
        """A beam / trail texture (PIL image) -> fx/textures/<name>.png; returns the pack-relative path."""
        d = P.pack(self.pack, FX_DIR, 'textures')
        os.makedirs(d, exist_ok=True)
        img.save(os.path.join(d, name + '.png'))
        return '%s/textures/%s.png' % (FX_DIR, name)

    def add_effect(self, name, layers, light=None, sound=None, source=''):
        self.effects[name] = {'layers': layers, 'light': light, 'sound': sound, 'source': source}
        return name

    def write(self):
        path = P.pack(self.pack, FX_DIR, LIBRARY_FILE)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            json.dump({'pack': self.pack, 'source': self.source, 'sprites': self.sprites,
                       'effects': self.effects, 'deaths': self.deaths}, f, indent=1)
        return path


# 3Space light manager, identical in Earthsiege 1 (0x55c6 -> 0x4da8 with 2000 / 10, radius 0x5274, brightness
# 0x5015) and Earthsiege 2 (0x407734, 0x40735c, 0x407125): constructed with B = 2000 >> 5 = 62, A = 10 >> 5 = 0.
#   radius     = (B << 5) * I / 10 + (A << 5) units          (recomputed whenever the intensity I changes)
#   brightness = I * min(255, (B << 8) / ((d >> 5) + A)) / 256   -> full within 1991 units, then 1 / distance
# A light is a scalar: it raises the shade / light level of the polygons it reaches (their own palette ramps), so
# it has no colour of its own.
LIGHT_B = 2000 >> 5
LIGHT_FULL_UNITS = (LIGHT_B << 8) * 32 / 255.0
LIGHT_RANGE_FACTOR = 4.0     # engine range = distance where the 1/d light has fallen to 25 % of full
LIGHT_COLOR = [1.0, 1.0, 1.0]


def make_3space_light(curve, frame_s, metres_per_unit):
    """Engine light of a 3Space explosion: `curve` = per-frame intensity 0..255, one frame every `frame_s` s.
    `range` follows the peak intensity; `range_follows_energy` makes the engine scale it per frame as the
    original radius does; `full_range` is the radius of full brightness (1991 units)."""
    peak = max(curve) if curve and max(curve) else 255
    full = LIGHT_FULL_UNITS * metres_per_unit
    return {'color': LIGHT_COLOR, 'range': round(full * LIGHT_RANGE_FACTOR * peak / 255.0, 2),
            'full_range': round(full, 2), 'falloff': 'inverse_distance', 'range_follows_energy': True,
            'cutoff': round(peak * LIGHT_B * 32 / 10.0 * metres_per_unit, 1),
            'energy': [round(v / 255.0, 3) for v in curve], 'frame_s': round(frame_s, 4),
            'duration': round(len(curve) * frame_s, 3)}


def attach_weapon_fx(pack, fx_for_weapon):
    """Adds an `fx` block to every weapon of the pack's weapon files.

    fx_for_weapon(weapon dict, file name) -> fx block dict (or None to leave the weapon unchanged).
    Returns the names of weapons that got no block (the caller should report / fail on them).
    """
    missing = []
    for rel in WEAPON_FILES:
        path = P.pack(pack, *rel.split('/'))
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
        for w in data.get('weapons', []):
            block = fx_for_weapon(w, rel)
            if block is None:
                missing.append(w.get('name', '?'))
                continue
            w['fx'] = block
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=1)
    return missing


def contact_sheet(sprite_images, out_path, cell=96, columns=12, background=(40, 40, 48, 255)):
    """Debug sheet: rows of (label, [PIL RGBA frames]) -> one PNG (for eyeballing the export)."""
    from PIL import Image, ImageDraw
    rows = [(label, frames[:columns]) for label, frames in sprite_images]
    sheet = Image.new('RGBA', (cell * (columns + 1), cell * max(1, len(rows))), background)
    draw = ImageDraw.Draw(sheet)
    for r, (label, frames) in enumerate(rows):
        draw.text((4, r * cell + 4), str(label)[:14], fill=(255, 255, 255, 255))
        for c, img in enumerate(frames):
            im = img.convert('RGBA')
            scale = min(1.0, (cell - 4) / max(im.width, im.height, 1))
            if scale < 1.0 or max(im.width, im.height) < cell // 3:
                scale = min((cell - 4) / max(im.width, im.height, 1), 4.0)
            im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))), Image.NEAREST)
            sheet.alpha_composite(im, ((c + 1) * cell + (cell - im.width) // 2, r * cell + (cell - im.height) // 2))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    sheet.save(out_path)
    return out_path
