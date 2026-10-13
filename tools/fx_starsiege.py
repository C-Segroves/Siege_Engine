"""Starsiege weapon visual effects -> gamedata/starsiege/fx/effects.json + an `fx` block per weapon
(docs/formats/weapon_fx.md sections 1 and 5).

    python tools/fx_starsiege.py [--sheet renders/weapon_fx_starsiege_sprites.png]

Reads starsiege/extracted/ (tools/darkstar_lzh.py):
* scripts/datProjectile.cs tables newBullet / newMissile / NewEnergy / NewBeam / newMine / newBomb: shape and
  "Transparent Shape" (the translucent *T.dts variant, drawn here), glow range + colour, energy "Face Camera",
  beam length / segment length / jitter / velocity / near + far width / bitmap + trans bitmap / glow colour /
  alpha, ImpactId / Shield ImpactId / TerrainImpactId (IDDTS_* tags);
* scripts/datWeapon.cs weaponMuzzle(shape, trans shape, face camera, flash colour, flash range) and
  weaponEnergy / weaponAmmo (projectile id of each weapon);
* scripts/Sim.Strings.cs IDDTS_<X> = id, "<file>.dts" (and IDDTS_<X>_T for the translucent variant);
* gameObjects/*.dts effect shapes with their bitmaps, resolved through Mars.Sim/Mars.d.ppl (fx_darkstar.py).
Effects play face-on to the camera; missiles trail IDDTS_SMOKE_TR puffs (named in Sim.Strings.cs, used by the
executable). Nothing here embeds an original value: every name, colour, size and time is read at import.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
import fx_darkstar as X  # noqa: E402
import siege_paths as P  # noqa: E402
from export_starsiege_gameplay import calls_text  # noqa: E402

PACK = 'starsiege'
SRC = P.work('starsiege', 'extracted')
WORLD_PPL = 'Mars.d.ppl'                # the pack's default palette world (pack.json default_palette Mars_d_1)
# datProjectile.cs column of each field per table function (the header comment row above each table)
COLUMNS = {
    'newBullet': {'glow_range': 5, 'glow_rgb': 6, 'shape': 19, 'trans_shape': 20, 'impact': 21,
                  'shield_impact': 22, 'terrain_impact': 23},
    'newMissile': {'glow_range': 8, 'glow_rgb': 9, 'shape': 31, 'trans_shape': 32, 'impact': 33,
                   'shield_impact': 34},
    'NewEnergy': {'glow_range': 5, 'glow_rgb': 6, 'face_camera': 19, 'shape': 20, 'trans_shape': 21,
                  'impact': 22, 'shield_impact': 23, 'terrain_impact': 24},
    'NewBeam': {'range': 2, 'beam_length': 3, 'segment_length': 4, 'jitter': 7, 'speed': 8, 'face_camera': 21,
                'near_width': 22, 'far_width': 23, 'bitmap': 24, 'trans_bitmap': 25, 'glow_rgb': 26, 'alpha': 29,
                'impact': 30, 'shield_impact': 31, 'terrain_impact': 32},
    'newMine': {'shape': 21, 'trans_shape': 22, 'impact': 23, 'shield_impact': 24},
    'newBomb': {'shape': 15, 'trans_shape': 16, 'impact': 17, 'shield_impact': 18},
}
PROJECTILE_CLASS = {'newBullet': 'bullet', 'newMissile': 'missile', 'NewEnergy': 'energy', 'NewBeam': 'beam',
                    'newMine': 'mine', 'newBomb': 'bomb'}
NO_IMPACT = 'none'
TRAIL_TAG = 'IDDTS_SMOKE_TR'
DUST_TAG = 'IDDTS_DUST'          # terrain hit of a projectile whose TerrainImpactId is "none" (approximation)
DUST_SHAPE = 'fx_dust.dts'       # gameObjects/fx_dust.dts: the neutral dust puff (no IDDTS tag)
# IDDTS_IMP_BULLET names no file (the executable draws bullet hits itself): nearest scripted impact instead
STAND_IN = {'IDDTS_IMP_BULLET': 'IDDTS_IMP_TN'}
SIZE_STEPS = ('_L', '_M', '_S', '_TN')   # a missing shape falls back to the next smaller one of its family
LARGER_FALLBACK_SCALE = 1.5               # ... drawn this much larger (approximation)
TRAIL_INTERVAL = 0.05                     # s between missile smoke puffs (not in the scripts; approximation)
TRANSLUCENT_SUFFIX = '_T'
GLOW_SCALE = 255.0


# ------------------------------------------------------------------ script tables

def read_script(files, name):
    return files.read(name).decode('latin1')


def load_projectiles(files):
    """{projectile id: {'class', 'abbr', 'function', <COLUMNS fields>}}."""
    out = {}
    for fn, args in calls_text(read_script(files, 'datProjectile.cs')):
        cols = COLUMNS.get(fn)
        if not cols or len(args) < 2:
            continue
        rec = {'class': PROJECTILE_CLASS[fn], 'abbr': str(args[0]), 'function': fn}
        for key, col in cols.items():
            rec[key] = (args[col:col + 3] if key.endswith('_rgb') else args[col]) if col < len(args) else None
        out[int(args[1])] = rec
    return out


def load_weapon_links(files):
    """{weapon id: {'projectile': id, 'muzzle': weaponMuzzle args}} from datWeapon.cs."""
    out, cur = {}, None
    for fn, args in calls_text(read_script(files, 'datWeapon.cs')):
        if fn == 'newWeapon':
            cur = out.setdefault(int(args[0]), {})
        elif cur is not None and fn in ('weaponEnergy', 'weaponAmmo'):
            cur['projectile'] = int(args[0])
        elif cur is not None and fn == 'weaponMuzzle':
            cur['muzzle'] = args
    return out


def load_shape_tags(files):
    """IDDTS_* tag -> dts file name (Sim.Strings.cs)."""
    text = read_script(files, 'Sim.Strings.cs')
    return {m.group(1): m.group(2) for m in re.finditer(r'^\s*(IDDTS_\w+)\s*=\s*\d+\s*,\s*"([^"]*)"', text, re.M)}


# ------------------------------------------------------------------ effect library

class StarsiegeEffects:
    """Builds sprites + effects on demand (each shape rendered once)."""

    def __init__(self, files, library):
        self.files, self.lib = files, library
        self.renderer = X.ShapeRenderer(files, X.Bitmaps(files, WORLD_PPL))
        self.tags = load_shape_tags(files)
        self.tags[DUST_TAG] = DUST_SHAPE
        self.flips = {}
        self.rows = []

    def flipbook(self, dts):
        """(sprite name, Flipbook) of a dts, preferring its translucent variant; None when missing."""
        key = dts.lower()
        if key not in self.flips:
            self.flips[key] = None
            if self.files.find(dts):
                flip = self.renderer.render(dts)
                stem = os.path.splitext(key)[0]
                name = X.add_flipbook_sprite(self.lib, stem, flip, self.rows) if flip.images else None
                self.flips[key] = (name, flip) if name else None
        return self.flips[key]

    def tag_shape(self, tag):
        """The drawn dts of an IDDTS tag: its _T variant when present, else the plain one ('' when none)."""
        for t in (tag + TRANSLUCENT_SUFFIX, tag):
            name = self.tags.get(t, '')
            if name and self.files.find(name):
                return name
        return ''

    def resolve_tag(self, tag):
        """(tag actually drawn, size scale) after stand-ins and smaller-size fallbacks."""
        tag = STAND_IN.get(tag, tag)
        if self.tag_shape(tag):
            return tag, 1.0
        for i, suffix in enumerate(SIZE_STEPS[:-1]):
            if tag.endswith(suffix):
                smaller = tag[:-len(suffix)] + SIZE_STEPS[i + 1]
                if self.tag_shape(smaller):
                    return smaller, LARGER_FALLBACK_SCALE
        return None, 1.0

    def impact(self, tag):
        """Effect name for an IDDTS impact / explosion tag (built once); None when nothing can be drawn."""
        drawn, scale = self.resolve_tag(str(tag))
        if not drawn:
            return None
        name = str(tag).replace('IDDTS_', '').lower()
        if name not in self.lib.effects:
            sprite, flip = self.flipbook(self.tag_shape(drawn))
            layer = {'sprite': sprite, 'duration': round(flip.duration, 4),
                     'face': 'ground' if flip.is_ground_flat else 'camera'}
            if scale != 1.0:
                layer['size'] = round(flip.height_m * scale, 3)
            note = '' if drawn == tag else ' (stand-in %s x%g: %s has no shape file)' % (drawn, scale, tag)
            self.lib.add_effect(name, [layer], source='Sim.Strings.cs %s -> %s%s' % (tag, flip.source, note))
        return name

    def muzzle(self, args):
        """Effect for weaponMuzzle(shape, trans shape, face camera, R, G, B, flash range)."""
        shape, trans, face, rgb, flash_range = args[0], args[1], args[2], args[3:6], float(args[6])
        dts = trans if self.files.find(trans) else shape
        got = self.flipbook(dts)
        if not got:
            return None
        sprite, flip = got
        color = X.unit_rgb(rgb, GLOW_SCALE)
        name = 'muzzle_%s_%02x%02x%02x' % ((os.path.splitext(dts)[0].lower(),) + tuple(int(c) for c in rgb))
        light = {'color': color, 'range': flash_range, 'duration': round(flip.duration, 4)} if flash_range > 0 else None
        layer = {'sprite': sprite, 'duration': round(flip.duration, 4),
                 'face': 'camera' if X.is_true(face) else 'muzzle'}
        self.lib.add_effect(name, [layer], light=light,
                            source='datWeapon.cs weaponMuzzle(%s, %s, face camera %s, flash colour, range) -> %s'
                                   % (shape, trans, face, flip.source))
        return name

    def smoke_trail(self):
        name = self.impact(TRAIL_TAG)
        sprite, flip = self.flipbook(self.tag_shape(TRAIL_TAG))
        return {'effect': name, 'interval': TRAIL_INTERVAL, 'style': 'puffs', 'color': [1, 1, 1, 1],
                'size': round(flip.height_m, 3), 'lifetime': round(flip.duration, 4)}


# ------------------------------------------------------------------ per-weapon fx blocks

def shape_ref(dts):
    """Exported shape id of a projectile dts (translucent variant preferred by the caller)."""
    stem = os.path.splitext(os.path.basename(str(dts)))[0].lower()
    return '%s:%s' % (PACK, stem) if os.path.exists(P.pack(PACK, 'shapes', stem + '.json')) else None


def glow_light(rec):
    rng = float(rec.get('glow_range') or 0)
    rgb = rec.get('glow_rgb') or [0, 0, 0]
    if rng <= 0 or not any(float(c) for c in rgb):
        return None
    return {'color': X.unit_rgb(rgb, GLOW_SCALE), 'range': rng}


def make_projectile(fx, rec):
    if rec['class'] == 'beam':
        return None
    light = glow_light(rec)
    color = (light['color'] + [1.0]) if light else [1.0, 1.0, 1.0, 1.0]
    trans = rec.get('trans_shape')
    if rec['class'] == 'energy' and X.is_true(rec.get('face_camera')):
        got = fx.flipbook(trans) or fx.flipbook(rec['shape'])
        if got:
            return {'sprite': got[0], 'shape': None, 'size': round(got[1].height_m, 3), 'color': color,
                    'spin_dps': 0.0, 'face': 'billboard', 'light': light}
    shape = shape_ref(trans) or shape_ref(rec['shape'])
    return {'sprite': None, 'shape': shape, 'size': 1.0, 'color': color, 'spin_dps': 0.0, 'face': 'velocity',
            'light': light}


def make_beam(fx, rec):
    if rec['class'] != 'beam' or not rec.get('speed'):
        return None
    names = [b for b in (rec.get('trans_bitmap'), rec.get('bitmap')) if b and str(b).lower() != NO_IMPACT]
    texture, blend = X.beam_texture(fx.lib, fx.renderer.bitmaps, names, 'beam_' + rec['abbr'].lower())
    speed, length, rng = float(rec['speed']), float(rec['beam_length']), float(rec['range'])
    jitter = float(rec.get('jitter') or 0)
    return {'texture': texture, 'texture_format': 'rgba', 'palette': None, 'blend': blend,
            'texture_length_axis': 'v',
            'color': X.unit_rgb(rec['glow_rgb'], GLOW_SCALE) + [float(rec.get('alpha') or 1.0)],
            'width': float(rec['near_width']), 'width_far': float(rec['far_width']),
            'duration': round((rng + length) / speed, 4), 'style': 'lightning' if jitter > 0 else 'bolt',
            'glow': True, 'length': length, 'speed': speed, 'segment_length': float(rec['segment_length']),
            'jitter': jitter, 'face_camera': X.is_true(rec.get('face_camera'))}


def make_impacts(fx, rec):
    armor = fx.impact(rec['impact'])
    shield = fx.impact(rec.get('shield_impact') or rec['impact']) or armor
    terrain = rec.get('terrain_impact')
    if terrain is None:
        miss = armor
    elif str(terrain).lower() == NO_IMPACT:
        miss = fx.impact(DUST_TAG)
    else:
        miss = fx.impact(terrain)
    return {'miss': [miss or armor], 'shield': [shield], 'armor': [armor]}


def make_fx(fx, weapon, links, projectiles):
    link = links.get(weapon.get('ss_id'), {})
    rec = projectiles.get(link.get('projectile'))
    if rec is None:
        return X.passive_fx('datWeapon.cs newWeapon(%s): no projectile' % weapon.get('ss_id'))
    trail = fx.smoke_trail() if rec['class'] == 'missile' else None
    muzzle = fx.muzzle(link['muzzle']) if link.get('muzzle') else None
    notes = ['translucent (*T.dts) variants drawn', 'impacts play face-on to the camera']
    if rec['class'] == 'missile':
        notes.append('smoke puff interval approximated')
    if str(rec.get('terrain_impact')).lower() == NO_IMPACT:
        notes.append('TerrainImpactId none: dust puff stand-in')
    return {'source': 'datProjectile.cs %s(%s) + datWeapon.cs newWeapon(%s) weaponMuzzle + Sim.Strings.cs IDDTS'
                      % (rec['function'], rec['abbr'], weapon.get('ss_id')),
            'projectile': make_projectile(fx, rec), 'beam': make_beam(fx, rec), 'trail': trail, 'muzzle': muzzle,
            'impact': make_impacts(fx, rec), 'notes': '; '.join(notes)}


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--sheet', help='write a contact sheet of every sprite to this PNG')
    args = ap.parse_args()
    files = X.SourceFiles(SRC, prefer=('gameObjects', 'scripts'))
    lib = fx_common.Library(PACK, 'starsiege/extracted scripts/datProjectile.cs, datWeapon.cs, Sim.Strings.cs; '
                                  'gameObjects effect shapes via tools/fx_darkstar.py (%s)' % WORLD_PPL)
    fx = StarsiegeEffects(files, lib)
    projectiles, links = load_projectiles(files), load_weapon_links(files)
    missing = fx_common.attach_weapon_fx(PACK, lambda w, _rel: make_fx(fx, w, links, projectiles))
    fx_deaths.apply_deaths(lib, fx_deaths.starsiege_deaths(fx))
    print('starsiege fx: %d sprites, %d effects -> %s' % (len(lib.sprites), len(lib.effects), lib.write()))
    if missing:
        sys.exit('weapons without fx: %s' % ', '.join(missing))
    if args.sheet:
        print('contact sheet ->', fx_common.contact_sheet(fx.rows, args.sheet))


if __name__ == '__main__':
    main()
