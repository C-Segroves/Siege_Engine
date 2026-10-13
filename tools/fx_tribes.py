"""Starsiege: Tribes weapon visual effects -> gamedata/tribes/fx/effects.json + an `fx` block per weapon
(docs/formats/weapon_fx.md sections 1 and 6).

    python tools/fx_tribes.py [--sheet renders/weapon_fx_tribes_sprites.png]

Reads tribes/extracted/ (tools/darkstar_vol.py):
* scripts/baseExpData.cs ExplosionData: shapeName, faceCamera, randomSpin, shiftPosition, hasLight, lightRange,
  timeScale, timeZero / timeOne, colors[0..2], radFactors, soundId (-> scripts/nsound.cs SoundData wavFileName);
* scripts/baseProjData.cs BulletData / RocketData / GrenadeData / SeekingMissileData: bulletShapeName,
  explosionTag + expRandCycle, lightRange / lightColor, rotationPeriod, isVisible + tracerLength, trailType /
  trailLength / trailWidth / trailString / smokeDist, smokeName + projSpecialTime;
  LaserData: laserBitmapName, hitName, beamTime, light; LightningData: bitmapName, beamWidth, boltLength,
  numSegments, segmentDivisions, updateTime, skipPercent, displaceBias, light;
* scripts/item.cs ItemImageData lightType 3 ("Weapon Fire") lightRadius / lightColor: the muzzle light;
* Entities/*.dts effect shapes and bitmaps through lushWorld/lush.day.ppl (fx_darkstar.py), shield.dts (the
  ShieldPack hit, GameBase::activateShield in scripts/player.cs).
Nothing here embeds an original value: every name, colour, size and time is read at import.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
import fx_darkstar as X  # noqa: E402
import siege_paths as P  # noqa: E402
from export_tribes_vehicles import T1_VEHICLES, copy_sound  # noqa: E402

PACK = 'tribes'
SRC = P.work('tribes', 'extracted')
SOUNDS = P.work('tribes', 'extracted', 'sound')
WORLD_PPL = 'lush.day.ppl'          # entity palette ids are shared by all worlds (tools/export_tribes.py)
SHIELD_SHAPE = 'shield.dts'
TRACER_SHAPE = 'tracer'
WEAPON_FIRE_LIGHT = 3               # ItemImageData lightType: 3 = weapon fire (item.cs comments)
MUZZLE_LIGHT_SECONDS = 0.1          # how long the fire light shows (lightTime is not a duration; approximation)
LASER_WIDTH = 0.3                   # m: LaserData carries no width (approximation)
TRAIL_PUFFS, TRAIL_RIBBON = 2, 1    # RocketData trailType
PROJECTILE_RX = re.compile(r'\b(BulletData|RocketData|GrenadeData|SeekingMissileData|LaserData|TargetLaserData|'
                           r'LightningData|RepairEffectData)\s+(\w+)')
IMAGE_RX = re.compile(r'ItemImageData\s+(\w+)')


def load_datablocks(files):
    out = {}
    for name in sorted(files.index):
        if name.endswith('.cs') and os.path.basename(os.path.dirname(files.index[name])).lower() == 'scripts':
            out.update(X.parse_datablocks(files.read(name).decode('latin1'), 'scripts/' + name))
    return out


def field(block, key, default=None):
    return block['fields'].get(key.lower(), default) if block else default


def num(block, key, default=0.0):
    value = field(block, key, default)
    return float(value) if isinstance(value, (int, float)) else default


class TribesEffects:
    """Builds sprites + effects on demand from the datablocks."""

    def __init__(self, files, library, blocks):
        self.files, self.lib, self.db = files, library, blocks
        self.renderer = X.ShapeRenderer(files, X.Bitmaps(files, WORLD_PPL))
        self.flips, self.rows = {}, []

    def flipbook(self, dts):
        key = dts.lower()
        if key not in self.flips:
            self.flips[key] = None
            if self.files.find(dts):
                flip = self.renderer.render(dts)
                if flip.images:
                    self.flips[key] = (X.add_flipbook_sprite(self.lib, os.path.splitext(key)[0], flip, self.rows),
                                       flip)
        return self.flips[key]

    def sound(self, sound_block):
        wav = field(self.db.get(str(sound_block).lower()), 'wavFileName', '')
        path = self.files.find(wav) if wav else None
        return copy_sound(PACK, path) or None if path else None

    def explosion(self, tag):
        """Effect for an ExplosionData (name kept); None when it has no drawable shape."""
        block = self.db.get(str(tag).lower())
        if not block or block['class'] != 'ExplosionData':
            return None
        name = block['name']
        if name not in self.lib.effects:
            got = self.flipbook(field(block, 'shapeName', ''))
            if not got:
                return None
            sprite, flip = got
            life = flip.duration * num(block, 'timeScale', 1.0)
            layer = {'sprite': sprite, 'duration': round(life, 4),
                     'face': 'camera' if X.is_true(field(block, 'faceCamera')) else 'surface',
                     'random_spin': X.is_true(field(block, 'randomSpin')),
                     'shift_toward_camera': X.is_true(field(block, 'shiftPosition'))}
            self.lib.add_effect(name, [layer], light=self.explosion_light(block, life),
                                sound=self.sound(field(block, 'soundId')),
                                source='%s ExplosionData %s -> %s' % (block['source'], name, flip.source))
        return name

    @staticmethod
    def explosion_light(block, life):
        """Light curve: colors[0] at 0, colors[1] at timeZero, colors[2] at timeOne (radius = lightRange x
        radFactors[i]); fades out at the end (approximation)."""
        if not X.is_true(field(block, 'hasLight')):
            return None
        rng = num(block, 'lightRange')
        colors = field(block, 'colors', {})
        factors = field(block, 'radFactors', [1.0, 1.0, 1.0])
        times = [0.0, num(block, 'timeZero'), num(block, 'timeOne')]
        curve = [{'t': t, 'color': X.unit_rgb(colors.get(i, [1, 1, 1])), 'range': round(rng * factors[i], 3)}
                 for i, t in enumerate(times)]
        curve.append({'t': 1.0, 'color': curve[-1]['color'], 'range': 0.0})
        peak = max(curve, key=lambda k: k['range'])
        return {'color': peak['color'], 'range': peak['range'], 'duration': round(life, 4), 'curve': curve}

    def impacts(self, proj):
        """explosionTag + expRandCycle variants (tag with its trailing digit counted 0..n-1)."""
        tag = str(field(proj, 'explosionTag', ''))
        cycle = int(num(proj, 'expRandCycle', 0))
        tags = [tag]
        if cycle > 1 and tag[-1:].isdigit():
            tags = ['%s%d' % (tag.rstrip('0123456789'), i) for i in range(cycle)]
        return [n for n in (self.explosion(t) for t in tags) if n]

    def shielded(self, impact):
        """The impact plus the ShieldPack flash (shield.dts) on the shielded target."""
        name = impact + '_shielded'
        got = self.flipbook(SHIELD_SHAPE)
        if name not in self.lib.effects and got:
            base = self.lib.effects[impact]
            layer = {'sprite': got[0], 'duration': round(got[1].duration, 4), 'face': 'camera'}
            self.lib.add_effect(name, base['layers'] + [layer], light=base['light'], sound=base['sound'],
                                source=base['source'] + ' + shield flash ' + got[1].source)
        return name if got else impact

    def point_flash(self, name, color, rng, seconds, source):
        """Light-only effect (weapon fire light, lightning hit)."""
        if name not in self.lib.effects:
            self.lib.add_effect(name, [{'flash': {'color': color + [1.0], 'size': rng * 0.25},
                                        'duration': seconds, 'grow': 1.0}],
                                light={'color': color, 'range': rng, 'duration': seconds}, source=source)
        return name


# ------------------------------------------------------------------ per-weapon fx blocks

def light_of(block):
    rng = num(block, 'lightRange')
    color = field(block, 'lightColor')
    return {'color': X.unit_rgb(color), 'range': rng} if rng > 0 and color else None


def shape_ref(dts):
    stem = os.path.splitext(str(dts))[0].lower()
    return '%s:%s' % (PACK, stem) if os.path.exists(P.pack(PACK, 'shapes', stem + '.json')) else None


def make_projectile(fx, proj):
    light = light_of(proj)
    color = (light['color'] + [1.0]) if light else [1.0, 1.0, 1.0, 1.0]
    period = num(proj, 'rotationPeriod')
    spin = round(360.0 / period, 3) if period > 0 else 0.0
    dts = str(field(proj, 'bulletShapeName', ''))
    if proj['class'] == 'BulletData' and not X.is_true(field(proj, 'isVisible', 'true')):
        return {'sprite': None, 'shape': shape_ref(TRACER_SHAPE), 'size': 1.0, 'color': color, 'spin_dps': 0.0,
                'face': 'velocity', 'light': light, 'tracer_length': num(proj, 'tracerLength')}
    if proj['class'] == 'BulletData':
        got = fx.flipbook(dts)
        if got:
            return {'sprite': got[0], 'shape': None, 'size': round(got[1].height_m, 3), 'color': color,
                    'spin_dps': spin, 'face': 'billboard', 'light': light}
    return {'sprite': None, 'shape': shape_ref(dts), 'size': 1.0, 'color': color, 'spin_dps': spin,
            'face': 'velocity', 'light': light}


def make_trail(fx, proj):
    speed = num(proj, 'muzzleVelocity') or num(proj, 'terminalVelocity')
    trail_type = int(num(proj, 'trailType'))
    puff = field(proj, 'trailString') if trail_type == TRAIL_PUFFS else field(proj, 'smokeName')
    if puff:
        got = fx.flipbook(str(puff))
        if not got:
            return None
        sprite, flip = got
        name = 'trail_' + sprite
        if name not in fx.lib.effects:
            fx.lib.add_effect(name, [{'sprite': sprite, 'duration': round(flip.duration, 4), 'face': 'camera'}],
                              source='puff ' + flip.source)
        dist = num(proj, 'smokeDist')
        interval = dist / speed if dist > 0 and speed > 0 else num(proj, 'projSpecialTime')
        return {'effect': name, 'interval': round(interval, 4), 'style': 'puffs', 'color': [1, 1, 1, 1],
                'size': round(flip.height_m, 3), 'lifetime': round(flip.duration, 4)}
    if trail_type == TRAIL_RIBBON:
        light = light_of(proj)
        return {'effect': None, 'interval': 0.0, 'style': 'ribbon',
                'color': (light['color'] if light else [1, 1, 1]) + [0.5], 'size': num(proj, 'trailWidth'),
                'lifetime': round(num(proj, 'trailLength') / speed, 4) if speed else 0.2}
    return None


def make_beam(fx, proj):
    light = light_of(proj)
    color = (light['color'] if light else [1, 1, 1]) + [1.0]
    if proj['class'] in ('LaserData', 'TargetLaserData'):
        texture, blend = X.beam_texture(fx.lib, fx.renderer.bitmaps, [field(proj, 'laserBitmapName')],
                                        'beam_' + proj['name'].lower())
        return {'texture': texture, 'texture_format': 'rgba', 'palette': None, 'blend': blend,
                'texture_length_axis': 'u', 'color': color, 'width': LASER_WIDTH,
                'duration': num(proj, 'beamTime', 0.1), 'style': 'textured', 'glow': True}
    texture, blend = X.beam_texture(fx.lib, fx.renderer.bitmaps, [field(proj, 'bitmapName')],
                                    'beam_' + proj['name'].lower())
    return {'texture': texture, 'texture_format': 'rgba', 'palette': None, 'blend': blend,
            'texture_length_axis': 'v', 'color': color, 'width': num(proj, 'beamWidth'),
            'duration': num(proj, 'updateTime') / 1000.0, 'style': 'lightning', 'glow': True,
            'length': num(proj, 'boltLength'),
            'lightning': {'cone_deg': num(proj, 'coneAngle'), 'segments': int(num(proj, 'numSegments')),
                          'divisions': int(num(proj, 'segmentDivisions')),
                          'update_s': num(proj, 'updateTime') / 1000.0, 'skip': num(proj, 'skipPercent'),
                          'displace': num(proj, 'displaceBias')}}


def timed_light(light, seconds):
    return dict(light, duration=round(seconds, 4)) if light else None


def make_beam_impacts(fx, proj):
    hit = field(proj, 'hitName')
    got = fx.flipbook(str(hit)) if hit else None
    if got:
        name = 'hit_' + got[0]
        if name not in fx.lib.effects:
            fx.lib.add_effect(name, [{'sprite': got[0], 'duration': round(got[1].duration, 4), 'face': 'camera'}],
                              light=timed_light(light_of(proj), got[1].duration),
                              source='%s %s hitName -> %s' % (proj['source'], proj['name'], got[1].source))
        return [name]
    light = light_of(proj) or {'color': [1, 1, 1], 'range': 1.0}
    return [fx.point_flash('hit_' + proj['name'].lower(), light['color'], light['range'], MUZZLE_LIGHT_SECONDS,
                           '%s %s: no hit shape, light colour flash (approximation)' % (proj['source'], proj['name']))]


def make_muzzle(fx, image):
    if not image or int(num(image, 'lightType')) != WEAPON_FIRE_LIGHT:
        return None
    color = X.unit_rgb(field(image, 'lightColor', [1, 1, 1]))
    return fx.point_flash('muzzle_' + image['name'].lower(), color, num(image, 'lightRadius'), MUZZLE_LIGHT_SECONDS,
                          '%s ItemImageData %s lightType 3 lightRadius / lightColor' % (image['source'], image['name']))


def make_fx(fx, weapon):
    src = weapon.get('source', '')
    m = PROJECTILE_RX.search(src)
    proj = fx.db.get(m.group(2).lower()) if m else None
    if proj is None:
        return X.passive_fx('no projectile datablock in source: %s' % src)
    im = IMAGE_RX.search(src)
    image = fx.db.get(im.group(1).lower()) if im else None
    beam_like = proj['class'] in ('LaserData', 'TargetLaserData', 'LightningData', 'RepairEffectData')
    impacts = make_beam_impacts(fx, proj) if beam_like else fx.impacts(proj)
    notes = ['explosions face the camera; light curve end fade approximated', 'muzzle = weapon fire light only']
    if beam_like:
        notes.append('laser width approximated' if proj['class'] != 'LightningData' else 'lightning arc parameters')
    return {'source': '%s %s %s + baseExpData.cs' % (proj['source'], proj['class'], proj['name']),
            'projectile': None if beam_like else make_projectile(fx, proj),
            'beam': make_beam(fx, proj) if beam_like else None,
            'trail': None if beam_like else make_trail(fx, proj), 'muzzle': make_muzzle(fx, image),
            'impact': {'miss': impacts, 'armor': impacts, 'shield': [fx.shielded(i) for i in impacts]},
            'notes': '; '.join(notes)}


def build_explosion_library(fx):
    """Every ExplosionData, used or not (debris and flash explosions for later use)."""
    for block in fx.db.values():
        if block['class'] == 'ExplosionData':
            fx.explosion(block['name'])


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--sheet', help='write a contact sheet of every sprite to this PNG')
    args = ap.parse_args()
    files = X.SourceFiles(SRC, prefer=('Entities', 'scripts', 'lushWorld'))
    lib = fx_common.Library(PACK, 'tribes/extracted scripts/baseProjData.cs, baseExpData.cs, item.cs, nsound.cs; '
                                  'Entities effect shapes via tools/fx_darkstar.py (%s)' % WORLD_PPL)
    fx = TribesEffects(files, lib, load_datablocks(files))
    missing = fx_common.attach_weapon_fx(PACK, lambda w, _rel: make_fx(fx, w))
    build_explosion_library(fx)
    fx_deaths.apply_deaths(lib, fx_deaths.tribes_deaths(fx, T1_VEHICLES))
    missing += fx_deaths.attach_gear_bursts(PACK, fx_deaths.tribes_gear_burst(fx))
    print('tribes fx: %d sprites, %d effects -> %s' % (len(lib.sprites), len(lib.effects), lib.write()))
    if missing:
        sys.exit('weapons without fx: %s' % ', '.join(missing))
    if args.sheet:
        print('contact sheet ->', fx_common.contact_sheet(fx.rows, args.sheet))


if __name__ == '__main__':
    main()
