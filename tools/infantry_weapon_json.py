"""Shared writer of the hand-weapon files of Aerial Assault and Vengeance (tools/aa_weapons.py, tools/tv_weapons.py).

Neither game has a Tribes-style script table: each exporter decodes its own weapon data (the PS2 executable's tables,
the UE2 class defaults) and hands the numbers to the builders below, which write
  gamedata/<pack>/gameplay/weapons_infantry.json   the weapon schema of docs/formats/weapon_schema.md, "category": "infantry"
  gamedata/<pack>/gameplay/infantry_rules.json     what each armour size may carry (weapons, rounds, slots, default kit):
                                                   read by InfantryCatalog for weapons of a pack that has no armours
  gamedata/<pack>/fx/effects.json                  impact and muzzle effects of the weapons (engine-default looks sized
                                                   from the decoded blast radius; the decoded data has no particle art)
Nothing here knows either game's values.
"""
import json
import math
import os


CATEGORY = 'infantry'
# One game health unit -> Earthsiege damage points. Tribes: 3000 per damage unit, so the light armour (0.66) is 1980 hp;
# every hand weapon of the Tribes games and of these two packs is scaled to the same light armour.
LIGHT_ARMOR_HP = 1980.0
WEAPON_FILE = 'gameplay/weapons_infantry.json'
RULES_FILE = 'gameplay/infantry_rules.json'
EFFECTS_FILE = 'fx/effects.json'
ANIMATION_ROLES = ('activate', 'ready', 'fire', 'reload', 'no_ammo', 'ambient', 'spin', 'spin_on')
MUZZLE_FLASH_SECONDS = 0.1
MUZZLE_FLASH_RANGE_M = 3.0
IMPACT_SECONDS = 0.7
SMALL_IMPACT_M = 1.5
SMOKE_COLOR = [0.25, 0.25, 0.25, 0.7]


def r(x, n=3):
    return round(float(x), n)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1)


def read_json(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def make_animation(**roles):
    """The model.animation block: every role empty unless given."""
    out = {k: '' for k in ANIMATION_ROLES}
    out.update({'spin_up_s': 0.0, 'spin_down_s': 0.0})
    out.update(roles)
    return out


def make_weapon(name, display, source, kind, **f):
    """One weapon record. Required: refire, damage (hp), range. Optional keyword fields of the schema:
    energy (min_charge, per_shot), splash (fraction), splash_radius, damage_type, projectile (dict), beam (dict),
    effects, spread_deg, burst, burst_interval, model_shape, animation (dict), fire_sound, notes, tribes (the
    game's own damage number for the record)."""
    damage = {'shield': r(f['damage'], 1), 'armor': r(f['damage'], 1), 'splash': r(f.get('splash', 0.0)),
              'splash_radius': r(f.get('splash_radius', 0.0)), 'type': f.get('damage_type', '')}
    if 'tribes' in f:
        damage['tribes'] = f['tribes']
    energy = f.get('energy', (0, 0))
    out = {'name': name, 'display_name': display, 'category': CATEGORY, 'source': source, 'size_class': 'special',
           'hardpoint_mask': 0, 'kind': kind, 'fire_group': 1, 'refire': r(f['refire'], 4), 'burst': f.get('burst', 1),
           'burst_interval': f.get('burst_interval', 0.0), 'spread_deg': r(f.get('spread_deg', 0.0)), 'ammo': -1,
           'energy': {'min_charge': int(round(energy[0])), 'per_shot': int(round(energy[1]))}, 'heat': None, 'damage': damage,
           'effects': f.get('effects', {}), 'projectile': f.get('projectile'), 'beam': f.get('beam'),
           'model': {'mount_shapes': [f['model_shape']] if f.get('model_shape') else [],
                     'animation': f.get('animation') or make_animation()},
           'sounds': {'fire': f['fire_sound']} if f.get('fire_sound') else {}, 'range': r(f['range'], 1)}
    if f.get('notes'):
        out['notes'] = f['notes']
    return out


def make_projectile(speed, lifetime, gravity=0.0, shape=None, color=(1.0, 1.0, 1.0), guidance='none', turn_rate_deg=0.0,
                    inherit=0.5, trail='glow', arm_delay=0.0, proximity=0.0):
    return {'speed': r(speed, 2), 'gravity': r(gravity, 2), 'lifetime': r(lifetime, 2), 'guidance': guidance,
            'turn_rate_deg': turn_rate_deg, 'arm_delay': arm_delay, 'proximity': proximity, 'shape': shape, 'trail': trail,
            'inherit_velocity': inherit, 'color': list(color)}


def make_beam(color, width=0.1, duration=0.12):
    return {'color': list(color), 'width': width, 'duration': duration, 'count': 1}


# ------------------------------------------------------------------ effects (engine-default looks)

def make_flash_effect(color, size, source):
    """A muzzle or impact flash: one flash layer and a light."""
    return {'layers': [{'flash': {'color': list(color) + [1.0], 'size': r(size, 2)}, 'duration': MUZZLE_FLASH_SECONDS, 'grow': 1.0}],
            'light': {'color': list(color), 'range': MUZZLE_FLASH_RANGE_M, 'duration': MUZZLE_FLASH_SECONDS},
            'sound': None, 'source': source}


def make_blast_effect(color, radius, source, sound=None):
    """An explosion whose size follows the decoded damage radius: a flash, sparks in the weapon's colour and smoke."""
    size = max(radius, SMALL_IMPACT_M)
    sparks = {'count': int(8 + 4 * size), 'sprite': None, 'color': list(color) + [1.0], 'color_end': list(color) + [0.0],
              'speed': r(size * 1.5, 2), 'speed_variance': r(size * 0.5, 2), 'spread_deg': 180.0, 'lifetime': 0.8,
              'size': r(size * 0.06, 3), 'size_end': r(size * 0.12, 3), 'gravity': 3.0, 'drag': 0.0, 'emit_time': 0.08,
              'blend': 'additive'}
    smoke = {'count': int(4 + 2 * size), 'sprite': None, 'color': SMOKE_COLOR, 'color_end': [0.05, 0.05, 0.05, 0.0],
             'speed': r(size * 0.5, 2), 'speed_variance': r(size * 0.2, 2), 'spread_deg': 120.0, 'lifetime': 1.6,
             'size': r(size * 0.15, 3), 'size_end': r(size * 0.4, 3), 'gravity': -1.0, 'drag': 0.0, 'emit_time': 0.3,
             'blend': 'alpha'}
    return {'layers': [{'flash': {'color': list(color) + [1.0], 'size': r(size * 1.6, 2)}, 'duration': IMPACT_SECONDS * 0.6, 'grow': 2.0},
                       {'particles': sparks, 'duration': 0.9, 'delay': 0.0},
                       {'particles': smoke, 'duration': 2.0, 'delay': 0.1}],
            'light': {'color': list(color), 'range': r(size * 2.0, 2), 'duration': IMPACT_SECONDS * 0.6},
            'sound': sound, 'source': source}


def make_fx(weapon, effect_prefix, color, impact_radius, source, projectile_shape=None, projectile_size=0.6, muzzle=True,
            impact_sound=None):
    """The weapon's fx block and the effects it names: (fx block, {effect name: effect}).
    The looks are engine defaults sized from the decoded numbers; `source` says what was decoded."""
    effects = {}
    impact = '%s_impact' % effect_prefix
    effects[impact] = make_blast_effect(color, impact_radius, 'engine default sized from the decoded blast radius (%s)' % source, impact_sound)
    muzzle_name = None
    if muzzle:
        muzzle_name = '%s_muzzle' % effect_prefix
        effects[muzzle_name] = make_flash_effect(color, 0.5, 'engine default muzzle flash (%s)' % source)
    block = {'source': source, 'projectile': None, 'beam': None, 'trail': None, 'muzzle': muzzle_name,
             'impact': {'miss': [impact], 'armor': [impact], 'shield': [impact]},
             'notes': 'looks are engine defaults sized from the decoded data; the original particle and sprite art is not decoded'}
    if weapon.get('beam') is not None:
        b = weapon['beam']
        block['beam'] = {'texture': None, 'texture_format': 'rgba', 'palette': None, 'blend': 'additive',
                         'texture_length_axis': 'u', 'color': list(b['color']) + [1.0], 'width': b['width'],
                         'duration': b['duration'], 'style': 'solid', 'glow': True}
    else:
        block['projectile'] = {'sprite': None, 'shape': projectile_shape, 'size': projectile_size, 'color': list(color) + [1.0],
                               'spin_dps': 0.0, 'face': 'velocity', 'light': {'color': list(color), 'range': 3.0}}
        if weapon['kind'] == 'cannon' and projectile_shape is None:
            block['projectile']['tracer_length'] = 8.0
        if (weapon.get('projectile') or {}).get('trail') == 'smoke':
            block['trail'] = {'effect': None, 'interval': 0.0, 'style': 'ribbon', 'color': [0.6, 0.6, 0.6, 0.5], 'size': 0.3, 'lifetime': 0.4}
    return block, effects


def write_effects(pack_dir, pack, effects, source):
    """Merges `effects` into the pack's fx/effects.json (created when the pack has none)."""
    path = os.path.join(pack_dir, EFFECTS_FILE)
    lib = read_json(path) or {'pack': pack, 'source': source, 'sprites': {}, 'effects': {}}
    lib.setdefault('effects', {}).update(effects)
    write_json(path, lib)


def keep_known_fx(pack_dir, weapons):
    """Re-runs keep the fx blocks a later tool attached (the same rule as the Tribes exporters)."""
    old = read_json(os.path.join(pack_dir, WEAPON_FILE))
    if not old:
        return
    known = {w['name']: w.get('fx') for w in old.get('weapons', [])}
    for w in weapons:
        if 'fx' not in w and known.get(w['name']) is not None:
            w['fx'] = known[w['name']]


def write_weapons(pack_dir, pack, weapons, note):
    keep_known_fx(pack_dir, weapons)
    write_json(os.path.join(pack_dir, WEAPON_FILE), {'pack': pack, 'damage_scale_note': note, 'weapons': weapons})
    print('%s: %d infantry weapons' % (pack, len(weapons)))


def write_rules(pack_dir, pack, rules):
    """rules: {SIZE: {max_weapons, weapons [ids], ammo {id: rounds}, default_loadout [ids], hp, max_energy}}."""
    write_json(os.path.join(pack_dir, RULES_FILE), {'pack': pack, 'engine_schema': 1, 'sizes': rules})


def degrees(rad):
    return math.degrees(rad)
