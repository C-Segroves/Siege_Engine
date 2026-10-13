"""Builds Tribes 2 sprites and effects (explosions, splashes, emitter puffs, shield flashes) into an
fx_common.Library from the Torque datablocks (rules: tools/fx_tribes2_torque.py, docs/formats/weapon_fx.md
section 7). Effects are named after their datablock; sprites after their texture (+ "_alpha" when drawn
alpha-blended)."""
import os

from fx_tribes2_torque import (DEFAULT_EXPLOSION_MS, IFL_FPS, MAX_PARTICLES,
                               TORQUE_GRAVITY, AUDIO, ShapeFile, indexed, is_true, mesh_extent, mesh_materials,
                               numbers, read_ifl, rgba)

ADDITIVE_MATERIAL = 0x8           # Torque material flag: additive
SHIELD_TEXTURE = 'special/shieldenvmap'   # the engine's shield-effect texture (not named in the scripts)
WHITE = [1.0, 1.0, 1.0, 1.0]


def _num(f, key, default=0.0):
    v = numbers(f.get(key, ''))
    return v[0] if v else default


def key_at(times, values, t):
    """Torque keyframe lookup: linear between the bracketing keys, clamped at the last key."""
    for i in range(1, len(times)):
        if t <= times[i]:
            span = times[i] - times[i - 1]
            k = (t - times[i - 1]) / span if span > 0 else 1.0
            a, b = values[i - 1], values[i]
            return [round(x + (y - x) * k, 3) for x, y in zip(a, b)] if isinstance(a, list) else round(a + (b - a) * k, 3)
    return values[-1]


def particle_keys(p):
    """(times, colours, sizes) of a ParticleData; missing keys take the engine defaults (white, 1.0, times 0,1,2...)."""
    colors = [rgba(c) or WHITE for c in indexed(p, 'colors')]
    sizes = [_num({'s': s}, 's', 1.0) for s in indexed(p, 'sizes')]
    times = [_num({'t': t}, 't') for t in indexed(p, 'times')]
    n = max(len(times), len(colors), len(sizes), 1)
    times = (times + [float(i) for i in range(len(times), n)])[:n]
    colors = (colors + [colors[-1] if colors else WHITE] * n)[:n]
    sizes = (sizes + [sizes[-1] if sizes else 1.0] * n)[:n]
    return times, colors, sizes


class EffectBuilder:
    def __init__(self, lib, db, files):
        self.lib, self.db, self.files = lib, db, files

    # ---- sprites ---------------------------------------------------------------------------------------
    def texture_sprite(self, texture, alpha_blend=False):
        """Sprite of one textureName (None when the file is missing)."""
        path = self.files.texture(texture)
        if not path:
            return None
        name = os.path.basename(str(texture)).lower() + ('_alpha' if alpha_blend else '')
        if name not in self.lib.sprites:
            self._add_sprite(name, [path], 0.0, alpha_blend, 'textures/' + str(texture))
        return name

    def skin_sprite(self, skin):
        """Sprite of a shape material bitmap (skins.vl2), e.g. a muzzle-flash mesh texture."""
        path = self.files.skin(skin)
        if not path:
            return None
        name = os.path.splitext(os.path.basename(path))[0].lower()
        if name not in self.lib.sprites:
            self._add_sprite(name, [path], 0.0, False, 'skins/' + os.path.basename(path))
        return name

    def frames_sprite(self, name, textures, fps, alpha_blend=False):
        """Animated sprite of animTexName[] textures."""
        paths = [p for p in (self.files.texture(t) for t in textures) if p]
        if not paths:
            return None
        if name not in self.lib.sprites:
            self._add_sprite(name, paths, fps, alpha_blend, 'animTexName[] %s..%s' % (textures[0], textures[-1]))
        return name

    def ifl_sprite(self, ifl_name, seconds=None, additive=True):
        """Animated sprite of an IFL (frames repeated by their 1/30 s units, cut at `seconds`); -> (name, seconds)."""
        path = self.files.ifl(ifl_name)
        if not path:
            return None, 0.0
        units = []
        for frame, count in read_ifl(path):
            units += [frame] * max(1, count)
        if seconds:
            units = units[:max(1, int(round(seconds * IFL_FPS)))]
        name = os.path.splitext(os.path.basename(path))[0].lower()
        if name not in self.lib.sprites:
            unique = list(dict.fromkeys(units))
            files = [self.files.skin(u) for u in unique]
            if not all(files):
                return None, 0.0
            entry = self._add_sprite(name, files, IFL_FPS, not additive, 'skins/' + os.path.basename(path))
            by_frame = dict(zip(unique, entry['frames']))
            entry['frames'] = [by_frame[u] for u in units]
        return name, len(units) / IFL_FPS

    def _add_sprite(self, name, paths, fps, alpha_blend, source):
        from PIL import Image
        images = [Image.open(p).convert('RGBA') for p in paths]
        return self.lib.add_rgba_sprite(name, images, fps=fps, loop=False,
                                         blend='alpha' if alpha_blend else 'additive', source=source)

    def ifl_frame_images(self, sprite):
        from PIL import Image
        import siege_paths as P
        return [Image.open(P.pack(self.lib.pack, *f.split('/'))) for f in self.lib.sprites[sprite]['frames']]

    # ---- particles -------------------------------------------------------------------------------------
    def particle_layers(self, emitter_name, emit_ms, burst=0, radius=0.0):
        """One particles layer per particle type of an emitter; burst > 0 emits that many at once."""
        e = self.db.get(emitter_name)
        if not e:
            return []
        types = [t for t in str(e.get('particles', '')).replace('\t', ' ').split() if self.db.get(t)]
        layers = []
        for t in types:
            period = max(_num(e, 'ejectionPeriodMS', 100.0), 1.0)
            count = burst or max(1, int(round(emit_ms / period)))
            layer = self._particle_layer(e, self.db.get(t), max(1, min(MAX_PARTICLES, count // len(types))),
                                         0.0 if burst else emit_ms / 1000.0)
            layer['particles']['radius'] = radius
            layers.append(layer)
        return layers

    def _particle_layer(self, e, p, count, emit_s):
        times, colors, sizes = particle_keys(p)
        life = _num(p, 'lifetimeMS', 1000.0) / 1000.0
        life_var = _num(p, 'lifetimeVarianceMS') / 1000.0
        alpha = is_true(p.get('useInvAlpha'))
        sprite = self._particle_sprite(p, alpha)
        body = {
            'count': count, 'sprite': sprite, 'color': colors[0], 'color_end': key_at(times, colors, 1.0),
            'speed': _num(e, 'ejectionVelocity', 2.0), 'speed_variance': _num(e, 'velocityVariance', 1.0),
            'spread_deg': _num(e, 'thetaMax', 90.0), 'theta_min_deg': _num(e, 'thetaMin'),
            'lifetime': life, 'lifetime_variance': life_var, 'size': sizes[0], 'size_end': key_at(times, sizes, 1.0),
            'gravity': round(-TORQUE_GRAVITY * _num(p, 'gravityCoefficient'), 3),
            'drag': _num(p, 'dragCoefficient'), 'accel': _num(p, 'constantAcceleration'),
            'inherit': _num(p, 'inheritedVelFactor'), 'offset': _num(e, 'ejectionOffset'),
            'spin_dps': [_num(p, 'spinRandomMin'), _num(p, 'spinRandomMax')],
            'orient': is_true(e.get('orientParticles')), 'emit_time': round(emit_s, 3),
            'blend': 'alpha' if alpha else 'additive',
            'keys': {'times': times, 'colors': colors, 'sizes': sizes},
            'source': '%s / %s' % (self.db.evidence(e), self.db.evidence(p)),
        }
        return {'particles': body, 'duration': round(emit_s + life + life_var, 3)}

    def _particle_sprite(self, p, alpha):
        frames = indexed(p, 'animTexName')
        if is_true(p.get('animateTexture')) and frames:
            name = (p['_name'].lower() + '_frames') + ('_alpha' if alpha else '')
            return self.frames_sprite(name, frames, _num(p, 'framesPerSec', IFL_FPS), alpha)
        return self.texture_sprite(p.get('textureName', ''), alpha) if p.get('textureName') else None

    # ---- explosions ------------------------------------------------------------------------------------
    def explosion_effect(self, name):
        f = self.db.get(name)
        if not f:
            return None
        if f['_name'] not in self.lib.effects:
            layers = self._explosion_layers(f, 0.0)
            self.lib.add_effect(f['_name'], layers, light=self._explosion_light(f),
                                sound=self.sound(f.get('soundProfile')), source=self.db.evidence(f))
            self._add_shake(f['_name'], f)
        return f['_name']

    def _explosion_layers(self, f, delay):
        delay += _num(f, 'delayMS') / 1000.0
        life_ms, layers = self._explosion_life_ms(f), []
        shape = self._shape_layer(f) if f.get('explosionShape') else None
        if shape:
            layers.append(shape)
        if f.get('particleEmitter'):
            layers += self.particle_layers(f['particleEmitter'], life_ms, burst=int(_num(f, 'particleDensity', 10)),
                                           radius=_num(f, 'particleRadius'))
        for em in indexed(f, 'emitter'):
            e = self.db.get(em)
            layers += self.particle_layers(em, _num(e, 'lifetimeMS') or life_ms) if e else []
        if f.get('debris'):
            layers += self._debris_layers(f)
        if f.get('shockwave'):
            layers += [x for x in [self.ring_layer(self.db.get(f['shockwave']), 'shockwave')] if x]
        for layer in layers:
            layer['delay'] = round(layer.get('delay', 0.0) + delay, 3)
        for sub in indexed(f, 'subExplosion'):
            s = self.db.get(sub)
            layers += self._explosion_layers(s, delay) if s else []
        return layers

    def _explosion_life_ms(self, f):
        if f.get('lifetimeMS'):
            return _num(f, 'lifetimeMS')
        shape = ShapeFile(f['explosionShape']) if f.get('explosionShape') else None
        seconds = shape.sequence_seconds('ambient') if shape and shape.exists else None
        return seconds * 1000.0 / (_num(f, 'playSpeed', 1.0) or 1.0) if seconds else DEFAULT_EXPLOSION_MS

    def _shape_layer(self, f):
        shape = ShapeFile(f['explosionShape'])
        ifls = shape.ifl_names()
        if not shape.exists or not ifls:
            return None
        fireball = self._fireball(shape)
        if not fireball:
            return None
        start, end, additive = fireball
        seconds = shape.sequence_seconds('ambient')
        sprite, seconds = self.ifl_sprite(ifls[0], seconds, additive)
        if not sprite:
            return None
        sizes = [numbers(s)[0] for s in indexed(f, 'sizes') if numbers(s)] or [1.0]
        scale = (numbers(f.get('explosionScale', '')) or [1.0])[0]
        play = _num(f, 'playSpeed', 1.0) or 1.0
        return {'sprite': sprite, 'size': round(start * sizes[0] * scale, 3),
                'grow': round(end / start * sizes[-1] / sizes[0], 3), 'duration': round(seconds / play, 3),
                'fade': False, 'face': 'camera' if is_true(f.get('faceViewer')) else 'normal',
                'offset_random': _num(f, 'offset'), 'shape_file': shape.name + '.dts'}

    @staticmethod
    def _fireball(shape):
        """(start size, end size, additive) of the explosion shape's main animated mesh (m)."""
        parts = shape.objects(r'fiery') or shape.objects(r'.')
        if not parts:
            return None
        mesh = parts[0][1]
        mats = [shape.material(i) for i in mesh_materials(mesh)]
        additive = all(m['flags'] & ADDITIVE_MATERIAL for m in mats if m) if mats else True
        return mesh_extent(mesh, 0), mesh_extent(mesh, max(0, mesh['num_frames'] - 1)), additive

    def _debris_layers(self, f):
        """Debris pieces are invisible emitter carriers: drawn as their trail particles flying out."""
        d = self.db.get(f['debris'])
        emitters = indexed(d, 'emitters') if d else []
        if not emitters:
            return []
        life = _num(d, 'lifetime', 1.0)
        layers = self.particle_layers(emitters[0], life * 1000.0)[:1]
        for layer in layers:
            body = layer['particles']
            body.update({'count': int(_num(f, 'debrisNum', 1)), 'speed': _num(f, 'debrisVelocity'),
                         'speed_variance': _num(f, 'debrisVelocityVariance'), 'spread_deg': _num(f, 'debrisThetaMax', 90),
                         'theta_min_deg': _num(f, 'debrisThetaMin'), 'lifetime': round(life + body['lifetime'], 3),
                         'emit_time': 0.0, 'debris': self.db.evidence(d)})
            layer['duration'] = round(body['lifetime'] + body['lifetime_variance'], 3)
        return layers

    def ring_layer(self, w, kind):
        """ShockwaveData / SplashData ring -> a `ring` layer (engine FxRing); its `flash` is the look for engines
        without rings."""
        if not w:
            return None
        texture = (indexed(w, 'texture') or [w.get('texture', '')])[0]
        times = [_num({'t': t}, 't') for t in indexed(w, 'times')] or [0.0, 1.0]
        colors = [rgba(c) or WHITE for c in indexed(w, 'colors')] or [WHITE]
        life = _num(w, 'lifetimeMS', 500.0) / 1000.0 if kind == 'shockwave' else _num(w, 'ringLifetime', 0.5)
        v, a, r0 = _num(w, 'velocity'), _num(w, 'acceleration'), _num(w, 'startRadius')
        width = _num(w, 'width', 0.5) if kind == 'shockwave' else max(_num(w, 'height', 0.0), 0.25)
        r1 = max(r0 + v * life + 0.5 * a * life * life, r0)
        ring = {'kind': kind, 'texture': self.ring_texture(texture), 'radius_start': r0, 'velocity': v,
                'segments': int(_num(w, 'numSegments', 16)), 'tex_wrap': _num(w, 'texWrap', 1.0) or 1.0,
                'acceleration': a, 'width': width, 'height': _num(w, 'height', 0.0), 'lifetime': life,
                'times': times, 'colors': colors, 'orient_to_normal': is_true(w.get('orientToNormal')),
                'map_to_terrain': is_true(w.get('mapToTerrain')), 'source': self.db.evidence(w)}
        start = 2.0 * r0 + width
        return {'flash': {'color': colors[0], 'size': round(start, 3)}, 'duration': round(life, 3),
                'grow': round((2.0 * r1 + width) / start, 3), 'fade': True, 'ring': ring}

    def ring_texture(self, texture):
        path = self.files.texture(texture)
        if not path:
            return None
        from PIL import Image
        return self.lib.save_texture(os.path.basename(str(texture)).lower(), Image.open(path).convert('RGBA'))

    def _explosion_light(self, f):
        if not f.get('lightStartRadius') and not f.get('lightEndRadius'):
            return None
        color = rgba(f.get('lightStartColor', '1 1 1')) or WHITE
        return {'color': color[:3], 'range': _num(f, 'lightStartRadius'), 'range_end': _num(f, 'lightEndRadius'),
                'color_end': (rgba(f.get('lightEndColor', '0 0 0')) or WHITE)[:3],
                'duration': self._explosion_life_ms(f) / 1000.0}

    def _add_shake(self, effect, f):
        if is_true(f.get('shakeCamera')):
            self.lib.effects[effect]['shake'] = {
                'frequency': numbers(f.get('camShakeFreq', '')), 'amplitude': numbers(f.get('camShakeAmp', '')),
                'duration': _num(f, 'camShakeDuration'), 'radius': _num(f, 'camShakeRadius')}

    # ---- other effects ---------------------------------------------------------------------------------
    def splash_effect(self, name):
        s = self.db.get(name)
        if not s:
            return None
        if s['_name'] not in self.lib.effects:
            life_ms = _num(s, 'lifetimeMS', 400.0)
            layers = []
            for em in indexed(s, 'emitter'):
                e = self.db.get(em)
                layers += self.particle_layers(em, _num(e, 'lifetimeMS') or life_ms) if e else []
            ring = self.ring_layer(s, 'splash')
            layers += [ring] if ring else []
            expl = self.db.get(s.get('explosion'))
            layers += self._explosion_layers(expl, 0.0) if expl else []
            self.lib.add_effect(s['_name'], layers, sound=self.sound(s.get('soundProfile')), source=self.db.evidence(s))
        return s['_name']

    def emitter_effect(self, name, emit_ms=0.0):
        """One spawn of an emitter (a trail puff) or, with emit_ms, a short continuous emission (muzzle exhaust)."""
        e = self.db.get(name)
        if not e:
            return None
        key = e['_name'] + ('_%dms' % emit_ms if emit_ms else '')
        if key not in self.lib.effects:
            layers = self.particle_layers(e['_name'], emit_ms) if emit_ms else self.particle_layers(e['_name'], 0, burst=1)
            self.lib.add_effect(key, layers, source=self.db.evidence(e))
        return key

    def shield_effect(self, name):
        s = self.db.get(name)
        sprite = self.texture_sprite(SHIELD_TEXTURE)
        if not s or not sprite:
            return None
        if s['_name'] not in self.lib.effects:
            start, end = _num(s, 'startScale', 1.0), _num(s, 'endScale', 1.0)
            layer = {'sprite': sprite, 'size': 1.0, 'duration': _num(s, 'lifetimeMS', 300.0) / 1000.0,
                     'grow': round(end / start, 3) if start else 1.0, 'fade': True,
                     'shell': {'scale_start': start, 'scale_end': end}}
            self.lib.add_effect(s['_name'], [layer], source=self.db.evidence(s) + ' + engine texture ' + SHIELD_TEXTURE)
        return s['_name']

    def sound(self, profile_name):
        p = self.db.get(profile_name)
        if not p or not p.get('filename'):
            return None
        import export_tribes_vehicles as V
        return V.copy_sound('tribes2', os.path.join(AUDIO, *str(p['filename']).split('/'))) or None
