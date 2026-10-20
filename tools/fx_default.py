"""Engine-default death effects for packs that carry no effect data of their own (docs/formats/weapon_fx.md section 9).

Tribes: Aerial Assault (PS2 build: the vehicles are the Tribes 2 art with Tribes 2 stats, the sound bank has no names) and
Tribes: Vengeance (Unreal Engine 2.5: its explosions are ParticleEmitter actors of the Unreal packages, not decoded) have no
explosion library, so a destroyed vehicle, structure or turret of theirs would fall back to the generic explosion. This
module writes a small library `fx/effects.json` for such a pack: flash + fire + smoke layers drawn by the engine, plus what the
pack does own, the shape of Aerial Assault's disc explosion and Vengeance's explosion sound files (audio/sfx/tv_dyn/Explo_*).
Every size, count and time here is an engine default (nothing is read from a disc); the entry `source` says so.

    python tools/fx_default.py tribes_aa|tribes_v [pack folder]
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FLASH_COLOR = [1.0, 0.78, 0.4, 1.0]
FIRE_COLOR = [1.0, 0.55, 0.15, 1.0]
SMOKE_COLOR = [0.25, 0.25, 0.25, 0.7]
ENGINE_DEFAULT = 'engine default (no explosion data in the pack): '
# Per-kind effect scale: (flash size m, fire particle count, speed m/s, smoke count, duration s)
SIZES = {'vehicle': (9.0, 36, 11.0, 14, 1.4), 'structure': (14.0, 50, 14.0, 20, 1.8), 'turret': (7.0, 26, 9.0, 10, 1.2)}
STRUCTURE_BLASTS = 4
STRUCTURE_BLAST_INTERVAL_S = 0.3

# pack -> {"shape": own explosion shape id or None, "sounds": {kind: sound stem of the pack or None}, "note": ...}
PACKS = {
    'tribes_aa': {
        'shape': 'tribes_aa:explosion',
        'sounds': {},
        'note': 'Aerial Assault: the disc explosion shape (explosion4bit) of its own art; its sounds are numbered, not named, '
                'so none is assigned',
    },
    'tribes_v': {
        'shape': None,
        'sounds': {'vehicle': 'tv_dyn/Explo_MetalLg1', 'structure': 'tv_dyn/Explo_StorageLg1', 'turret': 'tv_dyn/Explo_MetalLg2'},
        'note': 'Vengeance: Explo_* sound files of its own audio/sfx/tv_dyn',
    },
}


def _fire(kind):
    flash, count, speed, _smoke, _t = SIZES[kind]
    return {'count': count, 'sprite': None, 'color': FIRE_COLOR, 'color_end': [0.3, 0.1, 0.05, 0.0], 'speed': speed,
            'speed_variance': speed * 0.4, 'spread_deg': 180.0, 'lifetime': 1.0, 'size': flash * 0.12, 'size_end': flash * 0.25,
            'gravity': -4.0, 'drag': 0.0, 'emit_time': 0.1, 'blend': 'additive'}


def _smoke(kind):
    flash, _count, speed, count, _t = SIZES[kind]
    return {'count': count, 'sprite': None, 'color': SMOKE_COLOR, 'color_end': [0.05, 0.05, 0.05, 0.0], 'speed': speed * 0.35,
            'speed_variance': speed * 0.15, 'spread_deg': 120.0, 'lifetime': 2.2, 'size': flash * 0.2, 'size_end': flash * 0.5,
            'gravity': 1.2, 'drag': 0.0, 'emit_time': 0.4, 'blend': 'alpha'}


def make_effect(kind, spec):
    flash, _count, _speed, _smoke_count, duration = SIZES[kind]
    layers = [{'flash': {'color': FLASH_COLOR, 'size': flash}, 'duration': 0.5, 'grow': 2.0, 'delay': 0.0},
              {'particles': _fire(kind), 'duration': duration, 'delay': 0.0},
              {'particles': _smoke(kind), 'duration': 2.6, 'delay': 0.1}]
    if spec['shape'] and kind != 'turret':
        layers.insert(0, {'shape': spec['shape'], 'duration': 0.6, 'grow': flash * 1.2, 'delay': 0.0})
    return {'layers': layers, 'light': {'color': [1.0, 0.7, 0.3], 'range': flash * 2.5, 'duration': 0.5},
            'sound': spec['sounds'].get(kind), 'source': ENGINE_DEFAULT + spec['note']}


def make_step(effect, **opts):
    step = {'effects': [effect], 'delay': 0.0, 'count': 1, 'interval': 0.0, 'scatter': 0.0, 'height': 0.5}
    step.update(opts)
    return step


def make_deaths(spec):
    note = ENGINE_DEFAULT + spec['note']
    blasts = make_step('DefaultStructureExplosion', count=STRUCTURE_BLASTS, interval=STRUCTURE_BLAST_INTERVAL_S, scatter=0.8)
    return {
        'source': note,
        'vehicle': {'steps': [make_step('DefaultVehicleExplosion')], 'source': note},
        'structure': {'steps': [blasts, make_step('DefaultStructureExplosion', delay=STRUCTURE_BLASTS * STRUCTURE_BLAST_INTERVAL_S)],
                      'source': note},
        'turret': {'steps': [make_step('DefaultTurretExplosion')], 'source': note},
        'infantry': {'steps': [], 'source': 'a killed soldier only plays its death animation (as in the Tribes games)'},
    }


def export(pack, pack_dir):
    """Writes <pack_dir>/fx/effects.json for `pack` (a key of PACKS)."""
    spec = PACKS[pack]
    lib = {'pack': pack, 'source': ENGINE_DEFAULT + spec['note'], 'sprites': {},
           'effects': {'Default%sExplosion' % k.capitalize(): make_effect(k, spec) for k in SIZES},
           'deaths': make_deaths(spec)}
    path = os.path.join(pack_dir, 'fx', 'effects.json')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(lib, f, indent=1)
    return path


def main(argv):
    if not argv or argv[0] not in PACKS:
        sys.exit(__doc__)
    import siege_paths as P
    print(export(argv[0], argv[1] if len(argv) > 1 else P.pack(argv[0])))


if __name__ == '__main__':
    main(sys.argv[1:])
