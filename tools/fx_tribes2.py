"""Tribes 2 weapon visual effects -> gamedata/tribes2/fx/effects.json + an `fx` block on every weapon of
gameplay/weapons_engine.json and gameplay/weapons_infantry.json (docs/formats/weapon_fx.md sections 1 and 7).

Each weapon's ShapeBaseImageData / TurretImageData names its projectile datablock; the projectile class
decides the look:
  TracerProjectileData        stretched tracer bitmap + cross bitmap seen head-on (chaingun, Shrike, tank)
  EnergyProjectileData        stretched bolt bitmap + motion-blur ribbon (blaster)
  LinearFlareProjectileData   flare glow (base + rotating mod flares), optional IFL-textured bolt (plasma, fusion)
  Linear/Grenade/Seeker/Bomb  DTS model + baseEmitter / delayEmitter smoke trail
  Sniper/ShockLance/ELF       instant beams (textures saved to fx/textures)
Impacts: explosion (miss / armour), explosion + shield flash (shield), splash (water), underwaterExplosion.
Muzzle: the flash meshes of the weapon shape's fire sequence, or the missile launcher's exhaust emitter.

Usage: python tools/fx_tribes2.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fx_common  # noqa: E402
import fx_deaths  # noqa: E402
import siege_paths as P  # noqa: E402
from fx_tribes2_effects import EffectBuilder  # noqa: E402
from fx_tribes2_torque import (Datablocks, ShapeFile, TextureFiles, indexed, is_true, mesh_extent,  # noqa: E402
                               mesh_materials, numbers, rgba)

PACK = 'tribes2'
FLASH_OBJECTS = r'muzzle_?flash|fireeffect'       # flash meshes shown by the weapon shapes' fire sequences
FALLBACK_MUZZLE_SIZE = 0.5                        # m, flash meshes of shapes the DTS reader cannot open
FALLBACK_MUZZLE_SECONDS = 0.1
ELF_IMPACT_SIZE = 1.0                             # m, the ELF beam's end sprite (drawn by the engine, size not in data)
WHITE = [1.0, 1.0, 1.0, 1.0]
SHEET = os.path.join(P.ROOT, 'renders', 'weapon_fx_tribes2_sprites.png')


def _num(f, key, default=0.0):
    v = numbers(f.get(key, '')) if f else []
    return v[0] if v else default


def weapon_images():
    """Weapon key -> image datablock, from the exporters that wrote the weapon files."""
    import export_tribes_infantry as I
    import export_tribes_vehicles as V
    images = {key: spec['image'] for key, spec in V.T2_WEAPONS.items()}
    images.update({key: image for _, key, _, image, _ in I.T2_WEAPONS})
    images.update(turret_barrel_images())
    return images


def turret_barrel_images():
    """Turret gun key -> barrel image datablock of the base turrets (tools/export_tribes_base.py names each gun
    after its barrel)."""
    path = P.pack(PACK, 'gameplay', 'base_equipment.json')
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        blocks = json.load(f).get('blocks', {})
    return {str(b['turret']['barrel']).upper(): b['turret'].get('fx_image', b['turret']['barrel'])
            for b in blocks.values() if (b.get('turret') or {}).get('barrel')}


def vehicle_blocks():
    """(vehicle key, VehicleData datablock) of the exported Tribes 2 vehicles."""
    import export_tribes_vehicles as V
    return [(key, spec['block']) for key, spec in V.T2_VEHICLES.items()]


def vehicle_shield_impact(db):
    """The ShieldImpactData the vehicles name (shieldImpact)."""
    import export_tribes_vehicles as V
    for spec in V.T2_VEHICLES.values():
        v = db.get(spec['block'])
        if v and v.get('shieldImpact'):
            return v['shieldImpact']
    return None


class WeaponFx:
    def __init__(self, lib):
        self.db = Datablocks()
        self.fx = EffectBuilder(lib, self.db, TextureFiles())
        self.lib = lib
        self.shield = self.fx.shield_effect(vehicle_shield_impact(self.db))

    def block(self, image_name):
        img = self.db.get(image_name)
        p = self.db.get(img.get('projectile')) if img else None
        if not p:
            return None
        cls = p['_class']
        beam = self.beam(p)
        return {
            'source': '%s -> %s' % (self.db.evidence(img), self.db.evidence(p)),
            'projectile': None if beam else self.projectile(p),
            'beam': beam, 'trail': self.trail(p), 'muzzle': self.muzzle(img, p), 'impact': self.impact(p),
            'notes': NOTES.get(cls, ''),
        }

    # ---- projectile ------------------------------------------------------------------------------------
    def projectile(self, p):
        cls = p['_class']
        if cls == 'TracerProjectileData':
            return self.tracer(p)
        if cls == 'EnergyProjectileData':
            return self.energy_bolt(p)
        if cls == 'LinearFlareProjectileData':
            return self.flare(p)
        return self.modelled(p)

    def tracer(self, p):
        tex = indexed(p, 'tracerTex')
        alpha = is_true(p.get('tracerAlpha'))
        cross = None
        if is_true(p.get('renderCross')) and len(tex) > 1:
            cross = {'sprite': self.fx.texture_sprite(tex[1], alpha), 'size': _num(p, 'crossSize'),
                     'view_cos': _num(p, 'crossViewAng')}
        return {'sprite': self.fx.texture_sprite(tex[0], alpha) if tex else None, 'shape': None,
                'size': _num(p, 'tracerWidth'), 'length': _num(p, 'tracerLength'),
                'min_pixels': _num(p, 'tracerMinPixels'), 'color': rgba(p.get('tracerColor', '')) or WHITE,
                'spin_dps': 0.0, 'face': 'velocity', 'cross': cross, 'light': self.light(p)}

    def energy_bolt(self, p):
        tex = indexed(p, 'texture')
        scale = numbers(p.get('scale', '')) or [1.0, 1.0, 1.0]
        cross = {'sprite': self.fx.texture_sprite(tex[1]), 'size': _num(p, 'crossSize'),
                 'view_cos': _num(p, 'crossViewAng')} if len(tex) > 1 else None
        return {'sprite': self.fx.texture_sprite(tex[0]) if tex else None, 'shape': None,
                'size': scale[0], 'length': scale[1], 'color': WHITE, 'spin_dps': 0.0, 'face': 'velocity',
                'cross': cross, 'light': self.light(p)}

    def flare(self, p):
        sizes = [numbers(s)[0] for s in indexed(p, 'size') if numbers(s)] or [_num(p, 'size', 0.5)]
        color = rgba(p.get('flareColor', '')) or WHITE
        flare = {'base': self.fx.texture_sprite(p.get('flareBaseTexture', '')),
                 'mod': self.fx.texture_sprite(p.get('flareModTexture', '')),
                 'count': int(_num(p, 'numFlares')), 'sizes': sizes, 'color': color}
        out = {'sprite': flare['base'], 'shape': None, 'size': round(2.0 * sizes[0], 3), 'color': color,
               'spin_dps': 0.0, 'face': 'billboard', 'flare': flare, 'light': self.light(p)}
        bolt = self.ifl_bolt(p)
        if bolt:
            out.update(bolt)
        return out

    def ifl_bolt(self, p):
        """A bolt model drawn with an animated IFL texture -> a looping sprite of the model's size."""
        shape = ShapeFile(p.get('projectileShapeName', '')) if p.get('projectileShapeName') else None
        if not shape or not shape.exists or not shape.ifl_names():
            return None
        sprite, _ = self.fx.ifl_sprite(shape.ifl_names()[0])
        if not sprite:
            return None
        self.lib.sprites[sprite]['loop'] = True
        scale = (numbers(p.get('scale', '')) or [1.0])[0]
        return {'sprite': sprite, 'size': round(shape.header_extent() * scale, 3), 'shape_file': shape.name + '.dts'}

    def modelled(self, p):
        name = os.path.splitext(str(p.get('projectileShapeName', '')))[0].lower()
        shape = 'tribes2:' + name if name and os.path.exists(P.pack(PACK, 'shapes', name + '.json')) else None
        light = self.light(p)
        color = (light['color'] + [1.0]) if light else WHITE
        return {'sprite': None, 'shape': shape, 'size': 1.0, 'color': color, 'spin_dps': 0.0,
                'face': 'velocity', 'shape_file': name + '.dts' if name else None, 'light': light,
                'sequences': 'cyclic'}

    @staticmethod
    def light(p):
        if not is_true(p.get('hasLight')):
            return None
        return {'color': (rgba(p.get('lightColor', '')) or WHITE)[:3], 'range': _num(p, 'lightRadius')}

    # ---- beams -----------------------------------------------------------------------------------------
    def beam(self, p):
        cls = p['_class']
        if cls == 'SniperProjectileData':
            return self.sniper_beam(p)
        if cls == 'ShockLanceProjectileData':
            return self.shock_beam(p)
        if cls == 'ELFProjectileData':
            return self.elf_beam(p)
        return None

    def sniper_beam(self, p):
        tex = indexed(p, 'textureName')
        return {'texture': self.fx.ring_texture(tex[1]) if len(tex) > 1 else None, 'texture_format': 'rgba',
                'color': rgba(p.get('beamColor', '')) or WHITE, 'width': _num(p, 'startBeamWidth'),
                'width_end': _num(p, 'endBeamWidth'), 'pulse_width': _num(p, 'pulseBeamWidth'),
                'pulse_speed': _num(p, 'pulseSpeed'), 'pulse_length': _num(p, 'pulseLength'),
                'duration': _num(p, 'fadeTime', 0.5), 'style': 'textured', 'glow': True,
                'frames': [self.fx.ring_texture(t) for t in tex[2:-1]],
                'ramp': self.fx.ring_texture(tex[-1]) if len(tex) > 2 else None,
                'flare': {'sprite': self.fx.texture_sprite(tex[0]) if tex else None,
                          'angle_deg': _num(p, 'beamFlareAngle'), 'min_size': _num(p, 'minFlareSize'),
                          'max_size': _num(p, 'maxFlareSize')},
                'light': {'color': (rgba(p.get('lightColor', '')) or WHITE)[:3], 'range': _num(p, 'lightRadius')}}

    def shock_beam(self, p):
        tex = [self.fx.ring_texture(t) for t in indexed(p, 'texture')]
        return {'texture': tex[0] if tex else None, 'texture_format': 'rgba', 'color': WHITE,
                'width': _num(p, 'startWidth[0]'), 'width_end': _num(p, 'endWidth[0]'),
                'length': _num(p, 'boltLength'), 'duration': _num(p, 'zapDuration', 0.5), 'style': 'textured',
                'glow': True, 'frames': tex[:-1], 'core_texture': tex[-1] if len(tex) > 1 else None,
                'bolt_speed': [numbers(v)[0] for v in indexed(p, 'boltSpeed') if numbers(v)],
                'tex_wrap': [numbers(v)[0] for v in indexed(p, 'texWrap') if numbers(v)],
                'lightning': {'frequency': _num(p, 'lightningFreq'), 'density': _num(p, 'lightningDensity'),
                              'amplitude': _num(p, 'lightningAmp'), 'width': _num(p, 'lightningWidth')}}

    def elf_beam(self, p):
        tex = [self.fx.ring_texture(t) for t in indexed(p, 'textures')]
        return {'texture': tex[0] if tex else None, 'texture_format': 'rgba', 'color': WHITE,
                'width': _num(p, 'mainBeamWidth'), 'duration': FALLBACK_MUZZLE_SECONDS, 'continuous': True,
                'style': 'textured', 'glow': True, 'range': _num(p, 'beamRange'),
                'scroll_speed': _num(p, 'mainBeamSpeed'), 'repeat': _num(p, 'mainBeamRepeat'),
                'lightning_texture': tex[1] if len(tex) > 1 else None,
                'lightning': {'width': _num(p, 'lightningWidth'), 'spacing': _num(p, 'lightningDist')},
                'control_points': int(_num(p, 'numControlPoints')),
                'physics': {k: _num(p, k) for k in ('restorativeFactor', 'dragFactor', 'endFactor',
                                                    'randForceFactor', 'randForceTime')}}

    # ---- trail / muzzle --------------------------------------------------------------------------------
    def trail(self, p):
        if p.get('blurColor'):
            color = rgba(p['blurColor']) or WHITE
            return {'effect': None, 'interval': 0.0, 'style': 'ribbon', 'color': color,
                    'size': _num(p, 'blurWidth'), 'lifetime': _num(p, 'blurLifetime')}
        emitters = [(k, p[k]) for k in ('baseEmitter', 'delayEmitter', 'puffEmitter') if self.db.get(p.get(k))]
        if not emitters:
            return None
        puffs = [self.trail_puffs(k, name) for k, name in emitters]
        main = dict(puffs[0])
        main['also'] = puffs[1:]
        return main

    def trail_puffs(self, field, emitter_name):
        e = self.db.get(emitter_name)
        effect = self.fx.emitter_effect(emitter_name)
        layer = self.lib.effects[effect]['layers'][0]['particles'] if self.lib.effects[effect]['layers'] else {}
        return {'effect': effect, 'interval': _num(e, 'ejectionPeriodMS', 100.0) / 1000.0, 'style': 'puffs',
                'color': layer.get('color', WHITE), 'size': layer.get('size', 1.0),
                'lifetime': layer.get('lifetime', 1.0), 'field': field}

    def muzzle(self, img, p):
        if p.get('exhaustEmitter'):
            return self.fx.emitter_effect(p['exhaustEmitter'], _num(p, 'exhaustTimeMs', 300.0))
        shape = ShapeFile(img.get('shapeFile', ''))
        flash = self.flash_from_meshes(shape) or self.flash_from_strings(shape)
        if not flash:
            return None
        sprite, size, seconds = flash
        name = img['_name'] + '_MUZZLE'
        self.lib.add_effect(name, [{'sprite': sprite, 'size': round(size, 3), 'duration': round(seconds, 3),
                                    'fade': False, 'face': 'camera'}],
                            source='%s flash meshes of %s' % (self.db.evidence(img), shape.name + '.dts'))
        return name

    def flash_from_meshes(self, shape):
        parts = shape.objects(FLASH_OBJECTS)
        if not parts:
            return None
        front = next((m for n, m in parts if 'front' in n.lower()), parts[0][1])
        mats = [shape.material(i) for i in mesh_materials(front)]
        skin = mats[0]['name'] if mats and mats[0] else ''
        sprite = self.fx.ifl_sprite(skin)[0] if self.fx.files.ifl(skin) else self.fx.skin_sprite(skin)
        seconds = shape.sequence_seconds('fire_vis') or shape.sequence_seconds('fire') or FALLBACK_MUZZLE_SECONDS
        return (sprite, max(mesh_extent(m) for _, m in parts), seconds) if sprite else None

    def flash_from_strings(self, shape):
        names = [n for n in shape.ifl_names() if 'muzzle' in n.lower() and 'side' not in n.lower()]
        sprite = self.fx.ifl_sprite(names[0])[0] if names else None
        return (sprite, FALLBACK_MUZZLE_SIZE, FALLBACK_MUZZLE_SECONDS) if sprite else None

    # ---- impacts ---------------------------------------------------------------------------------------
    def impact(self, p):
        hit = self.hit_effect(p)
        water = self.fx.splash_effect(p.get('splash')) or self.fx.explosion_effect(p.get('underwaterExplosion'))
        under = self.fx.explosion_effect(p.get('underwaterExplosion'))
        out = {'miss': [hit], 'armor': [hit], 'shield': [self.shielded(hit)], 'water': [water or hit]}
        if under:
            out['underwater'] = [under]
        return out

    def hit_effect(self, p):
        expl = self.fx.explosion_effect(p.get('explosion'))
        if expl:
            return expl
        name = p['_name'] + '_IMPACT'
        if name not in self.lib.effects:
            self.lib.add_effect(name, self.beam_hit_layers(p), source=self.db.evidence(p) + ' (no ExplosionData)')
        return name

    def beam_hit_layers(self, p):
        layers = []
        if p.get('shockwave'):
            ring = self.fx.ring_layer(self.db.get(p['shockwave']), 'shockwave')
            layers += [ring] if ring else []
        for em in indexed(p, 'emitter'):
            layers += self.fx.particle_layers(em, _num(p, 'zapDuration', 0.5) * 1000.0)
        tex = indexed(p, 'textures')
        if p['_class'] == 'ELFProjectileData' and len(tex) > 2:
            layers.append({'sprite': self.fx.texture_sprite(tex[2]), 'size': ELF_IMPACT_SIZE,
                           'duration': FALLBACK_MUZZLE_SECONDS, 'fade': True, 'face': 'camera'})
        if not layers:
            layers.append({'flash': {'color': WHITE, 'size': 0.5}, 'duration': FALLBACK_MUZZLE_SECONDS, 'grow': 1.0})
        return layers

    def shielded(self, hit):
        """The hit effect plus the target's shield flash (playShieldEffect with the ShieldImpactData)."""
        if not self.shield:
            return hit
        name = hit + '_SHIELDED'
        if name not in self.lib.effects:
            base = self.lib.effects[hit]
            self.lib.add_effect(name, base['layers'] + self.lib.effects[self.shield]['layers'], light=base['light'],
                                sound=base['sound'], source=base['source'] + ' + ' + self.lib.effects[self.shield]['source'])
        return name


NOTES = {
    'TracerProjectileData': 'Tracer: tracerTex[0] stretched over `length` along the velocity, `size` wide; the cross '
                            'bitmap is drawn instead when the view is within acos(view_cos) of the flight axis.',
    'EnergyProjectileData': 'Bolt: texture[0] stretched along the velocity (scale x = width, y = length, role of y '
                            'inferred); blur ribbon from blurColor / blurWidth / blurLifetime.',
    'LinearFlareProjectileData': 'Flare: flareBaseTexture glow tinted flareColor (size[0] taken as radius) plus numFlares '
                                 'rotating flareModTexture quads; a plasma bolt model is replaced by its IFL as a sprite.',
    'GrenadeProjectileData': 'Model = projectileShapeName (DTS v18), its cyclic ambient sequence (spin / wobble) '
                             'played in flight; trail = baseEmitter puffs.',
    'SeekerProjectileData': 'Model = projectileShapeName (DTS v19). Trail = baseEmitter smoke, also delayEmitter fire '
                            'and puffEmitter puffs. Flechette casing debris omitted.',
    'SniperProjectileData': 'Beam: textureName[1] core, [2..n-1] animated rip textures, last = colour ramp, [0] end '
                            'flare (texture roles inferred from names).',
    'ShockLanceProjectileData': 'Lightning bolts of boltLength from the muzzle; target shockwave + particle zap.',
    'ELFProjectileData': 'Continuous beam while firing (8 control points, spring physics); BlueImpact at the target.',
}


def sample_frames(fx, sprite, n=12):
    images = fx.fx.ifl_frame_images(sprite)
    step = max(1, len(images) // n)
    return images[::step][:n]


def check(lib):
    problems = []
    for name, s in lib.sprites.items():
        problems += ['missing frame %s' % f for f in s['frames'] if not os.path.exists(P.pack(PACK, *f.split('/')))]
    for name, e in lib.effects.items():
        for layer in e['layers']:
            sprite = layer.get('sprite') or (layer.get('particles') or {}).get('sprite')
            if sprite and sprite not in lib.sprites:
                problems.append('effect %s: unknown sprite %s' % (name, sprite))
    return problems


def check_weapon(w, lib):
    fx = w.get('fx') or {}
    problems = ['%s: empty impact %s' % (w['name'], k) for k in ('miss', 'armor', 'shield')
                if not (fx.get('impact') or {}).get(k)]
    names = [n for lst in (fx.get('impact') or {}).values() for n in lst] + [fx.get('muzzle')]
    names += [t.get('effect') for t in [fx.get('trail') or {}] + (fx.get('trail') or {}).get('also', [])]
    problems += ['%s: unknown effect %s' % (w['name'], n) for n in names if n and n not in lib.effects]
    return problems


def main():
    lib = fx_common.Library(PACK, 'Tribes 2 scripts (scripts.vl2 weapons/*.cs, vehicles/*.cs datablocks), '
                                  'textures.vl2 / skins.vl2 bitmaps and IFLs, shapes.vl2 explosion shapes')
    wfx = WeaponFx(lib)
    images = weapon_images()
    missing = fx_common.attach_weapon_fx(PACK, lambda w, rel: wfx.block(images[w['name']]) if w['name'] in images else None)
    fx_deaths.apply_deaths(lib, fx_deaths.tribes2_deaths(wfx.fx, wfx.db, vehicle_blocks()))
    missing += fx_deaths.attach_gear_bursts(PACK, fx_deaths.tribes2_gear_burst(wfx.fx, wfx.db))
    lib.write()
    if os.path.isdir(os.path.dirname(SHEET)):      # developer checkout only, not the frozen importer
        rows = [(name, sample_frames(wfx, name)) for name in sorted(lib.sprites)]
        fx_common.contact_sheet(rows, SHEET)
    problems = check(lib) + ['weapon without fx: %s' % m for m in missing]
    for rel in fx_common.WEAPON_FILES:
        path = P.pack(PACK, *rel.split('/'))
        if os.path.exists(path):
            with open(path, encoding='utf-8') as f:
                weapons = json.load(f)['weapons']
            problems += [x for w in weapons for x in check_weapon(w, lib)]
    print('tribes2 fx: %d sprites, %d effects, sheet %s' % (len(lib.sprites), len(lib.effects), SHEET))
    for p in problems:
        print('PROBLEM', p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
