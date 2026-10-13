"""Death effects of every pack -> the `deaths` block of gamedata/<pack>/fx/effects.json
(docs/formats/weapon_fx.md section 9).

What each game shows when a unit, a damage component, a structure, a turret or a soldier is destroyed, as a
list of steps over the pack's own library effects:

    "deaths": {
      "vehicle":    {"steps": [...], "source": "..."},        default unit death
      "vehicles":   {"<vehicle key>": {...}},                 per vehicle id / class (herc, tank, SHRIKE ...)
      "component":  {...}, "component_big": {...},            a destroyed damage component (3Space units)
      "structure":  {...}, "structures": {"<tag>": {...}},    mission structures (Starsiege: by explosion tag)
      "turret":     {...},
      "infantry":   {...}                                     a soldier killed
    }
    step = {"effects": [names, one picked at random], "delay": s, "count": n, "interval": s,
            "scatter": 0..1 of the body's half size, "height": 0..1 of the body height}

Each game's exporter (tools/fx_<pack>.py) calls its function below after building its library, so every
effect a step names exists. Code constants (explosion ids, counts, timers) are checked against the original
executable when it is present (the bytes in each EVIDENCE table); every effect, size and time comes from the
user's disc through the library.
"""
import os
import re
import struct

import siege_paths as P

ES1_EXE = (P.work('original', 'DBSIM.EXE'), 0x48fd)            # VA = file offset - 0x48FD
ES1_TIMER_PER_S = 2560.0
ES2_EXE = P.work('es2', 'original', 'DBSIM.EXE')               # PE, image base 0x400000
BD_EXE = (P.work('bd', 'installed', 'SIM.EXE'), 0x69cd)          # VA = file offset - 0x69CD
SS_EXE = P.work('starsiege', 'original', 'installed', 'Starsiege.exe')

# The scatter of the steps that stand for pieces flying off (debris that explodes where it lands): the
# originals throw debris objects; the remake plays their explosions around the wreck (approximation).
DEBRIS_SCATTER = 1.0
DEBRIS_DELAY_S = 0.4
DEBRIS_INTERVAL_S = 0.25
BODY_MIDDLE = 0.5
GROUND = 0.0


def make_step(effects, **opts):
    """One step: `effects` (a name or a list of variants) with delay / count / interval / scatter / height."""
    names = [effects] if isinstance(effects, str) else list(effects)
    step = {'effects': names, 'delay': 0.0, 'count': 1, 'interval': 0.0, 'scatter': 0.0, 'height': BODY_MIDDLE}
    step.update({k: (round(v, 4) if isinstance(v, float) else v) for k, v in opts.items()})
    return step


def make_entry(steps, source):
    return {'steps': steps, 'source': source}


def check_effects(lib, deaths):
    """Names every step uses that the library lacks (exporters fail on them)."""
    missing = []

    def walk(entry):
        for step in entry.get('steps', []):
            missing.extend(n for n in step['effects'] if n not in lib.effects)
    for key, value in deaths.items():
        if key in ('vehicles', 'structures'):
            for entry in value.values():
                walk(entry)
        elif isinstance(value, dict):
            walk(value)
    return missing


def apply_deaths(lib, deaths):
    missing = check_effects(lib, deaths)
    if missing:
        raise SystemExit('%s deaths: unknown effects %s' % (lib.pack, sorted(set(missing))))
    lib.deaths = deaths


class CodeCheck:
    """Instruction bytes the decoded constants rely on; reads nothing when the executable is absent."""

    def __init__(self, path, to_offset, evidence):
        self.data = open(path, 'rb').read() if os.path.exists(path) else None
        self.to_offset = to_offset
        if self.data is None:
            return
        bad = ['%x (%s)' % (va, why) for va, (hexb, why) in evidence.items()
               if self.at(va, len(hexb) // 2).hex() != hexb]
        if bad:
            raise SystemExit('%s does not match the analysed build at %s' % (os.path.basename(path), bad))

    def at(self, va, n):
        o = self.to_offset(va)
        return self.data[o:o + n]

    def u16(self, va):
        return struct.unpack('<H', self.at(va, 2))[0] if self.data else None


# ================================================================== Earthsiege 1 (DBSIM.EXE)

ES1_EVIDENCE = {
    0x9E36: ('66833d40f10a0000', 'component destroyed: explosion only while no big one played this hit'),
    0x9E40: ('be0a000000', 'component destroyed -> explosion 10'),
    0x9E4C: ('a804', 'component flag 4 = big explosion'),
    0x9E59: ('be11000000', 'big explosion -> explosion 17'),
    0x3A43: ('66c787a00100000800', 'base destroyed: blast counter 8'),
    0x2F78: ('6a0f', 'base blast -> explosion 15 at a random point of the base extents'),
    0x2F92: ('66c743012c01', 'next base blast after 0x12c timer units'),
    0x2EA9: ('6a10', 'counter 1 -> explosion 16 at the base centre'),
    0x2EBF: ('66c74301d007', 'wreck after 0x7d0 timer units'),
}
ES1_COMPONENT_EXPLOSION = 10
ES1_BIG_EXPLOSION = 17
ES1_BASE_BLAST = 15
ES1_BASE_FINAL = 16
ES1_BASE_COUNTER = 8
ES1_BASE_BLAST_PERIOD = 0x12c


def es1_deaths(lib):
    """Mech component destruction (damage.cpp 0x9cd4) and the base blast sequence (base.cpp 0x2df8)."""
    exe = CodeCheck(ES1_EXE[0], lambda va: va + ES1_EXE[1], ES1_EVIDENCE)
    period = (exe.u16(0x2F96) or ES1_BASE_BLAST_PERIOD) / ES1_TIMER_PER_S
    blasts = ES1_BASE_COUNTER - 2            # counter 7..2 blast, 1 = final explosion, 0 = wreck shape
    comp = 'explo_%d' % ES1_COMPONENT_EXPLOSION
    big = 'explo_%d' % ES1_BIG_EXPLOSION
    unit = make_entry([make_step(big)], 'DBSIM 0x9e4c/0x9e59: the destroyed cockpit (DMG flags 7 = fatal, debris, '
                                        'big) spawns explosion 17; every unit dies of its cockpit (0x13824)')
    return {
        'source': 'DBSIM.EXE damage.cpp 0x9cd4 (component destroyed), base.cpp 0x2df8 (base destroyed)',
        'vehicle': unit,
        'component': make_entry([make_step(comp)], 'DBSIM 0x9e40: each destroyed component spawns explosion 10 at '
                                                  'its part, unless a big explosion played in the same hit (0xaf140)'),
        'component_big': make_entry([make_step(big)], 'DBSIM 0x9e59: component flag 4 -> explosion 17 (and no '
                                                     'further component explosions in that hit)'),
        'structure': make_entry([
            make_step('explo_%d' % ES1_BASE_BLAST, count=blasts, interval=period, scatter=1.0),
            make_step('explo_%d' % ES1_BASE_FINAL, delay=blasts * period)],
            'DBSIM base.cpp 0x3a43 counter 8; 0x2f78 explosion 15 at a random point of the BASES.DAT extents every '
            '0x12c timer units (2560/s) while the counter > 1; 0x2ea9 explosion 16 at the base centre; the hulk '
            'shape 0x7d0 units later (the remake swaps the shape at once)'),
    }


# ================================================================== Earthsiege 2 (DBSIM.EXE 1.0, PE)

ES2_EVIDENCE = {
    0x40D6E2: ('66c7459a0a00', 'component destroyed -> explosion 10'),
    0x40D6E8: ('f6460504', 'component flag 4 = big explosion'),
    0x40D6F7: ('66c7459a1100', 'big explosion -> explosion 17'),
    0x4036D9: ('0fbf147dfc734900', 'base destroyed: explosion = table 0x4973fc[base class]'),
}
ES2_COMPONENT_EXPLOSION = 10
ES2_BIG_EXPLOSION = 17
ES2_BASE_TABLE = 0x4973FC
ES2_BASE_CLASS_COUNT = 2


def es2_deaths(lib):
    exe = CodeCheck(ES2_EXE, _pe_offset(ES2_EXE), ES2_EVIDENCE)
    base = [exe.u16(ES2_BASE_TABLE + 2 * k) for k in range(ES2_BASE_CLASS_COUNT)] if exe.data else [16, 21]
    comp = 'explo_%d' % ES2_COMPONENT_EXPLOSION
    big = 'explo_%d' % ES2_BIG_EXPLOSION
    return {
        'source': 'DBSIM.EXE 1.0 0x40d6e2 (component destroyed), 0x4036c0 (base destroyed)',
        'vehicle': make_entry([make_step(big)], 'DBSIM 0x40d6f7: the destroyed cockpit (flag 4) spawns explosion 17 '
                                                '(ES1 rule, unchanged)'),
        'component': make_entry([make_step(comp)], 'DBSIM 0x40d6e2: explosion 10 per destroyed component unless a big '
                                                  'one played in that hit ([0x4a98b0])'),
        'component_big': make_entry([make_step(big)], 'DBSIM 0x40d6f7: flag 4 -> explosion 17'),
        'structure': make_entry([make_step('explo_%d' % base[0], height=GROUND)],
                                'DBSIM 0x4036d9: explosion table 0x4973fc[class] = %s; class 0 used (the base record '
                                'class +0x10 is not exported)' % base),
    }


def _pe_offset(path):
    """VA -> file offset of a PE image (identity when the file is absent)."""
    if not os.path.exists(path):
        return lambda va: va
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    count = struct.unpack_from('<H', d, pe + 6)[0]
    opt = struct.unpack_from('<H', d, pe + 20)[0]
    base = struct.unpack_from('<I', d, pe + 52)[0]
    sections = []
    at = pe + 24 + opt
    for _ in range(count):
        size, va, raw_size, raw = struct.unpack_from('<IIII', d, at + 8)
        sections.append((va + base, max(size, raw_size), raw))
        at += 40

    def to_offset(va):
        for start, size, raw in sections:
            if start <= va < start + size:
                return va - start + raw
        return 0
    return to_offset


# ================================================================== Battledrome (SIM.EXE)

BD_EVIDENCE = {
    0xAF3B: ('6a01', 'Herc::explodePart (herc.cpp 0xad8c): explosion type 1 at the part'),
    0xAF67: ('6a06', 'Herc::explodePart: sound 6'),
    0x15359: ('6a07', 'turret destroyed (turret.cpp 0x1523c): sound 7'),
    0x15364: ('6a01', 'turret destroyed: explosion type 1'),
}
BD_PART_EXPLOSION = 1


def bd_deaths(lib):
    CodeCheck(BD_EXE[0], lambda va: va + BD_EXE[1], BD_EVIDENCE)
    variants = sorted(n for n in lib.effects if n.startswith('expl%d_' % BD_PART_EXPLOSION))
    parts = make_entry([make_step(variants), make_step(variants, delay=DEBRIS_DELAY_S, count=2,
                                                       interval=DEBRIS_INTERVAL_S, scatter=DEBRIS_SCATTER)],
                       'SIM herc.cpp 0xad8c Herc::explodePart: each exploding part spawns its debris and an '
                       'explosion of type 1 (EXPLD1 / EXPLD2 at random); a destroyed Herc explodes its parts '
                       '(0xabf4 cascade; the remake plays three of them)')
    return {
        'source': 'Battledrome SIM.EXE herc.cpp explodePart 0xad8c, turret.cpp 0x1537e',
        'vehicle': parts,
        'component': make_entry([make_step(variants)], 'SIM 0xaf55: an exploding part: explosion type 1'),
        'turret': make_entry([make_step(variants)], 'SIM turret.cpp 0x1537e: explosion type 1 at the turret'),
        'structure': make_entry([make_step(variants)], 'arena obstacles are not destructible; the turret rule'),
    }


# ================================================================== Starsiege (Starsiege.exe)

SS_EVIDENCE_TAGS = {     # instruction VA -> (bytes, meaning): the Herc death code 0x472f80
    0x47303B: ('b81e5c0500', 'herc blown apart: debris explosion IDDTS_EXP_L (351262) ...'),
    0x473048: ('83c04f', '... or +0x4f = IDDTS_SHOCK_M (351341)'),
    0x4739BC: ('c704246d5c0500', 'quick (small) herc death: debris explosion IDDTS_SHOCK_M'),
}


def starsiege_deaths(fx):
    """Herc / tank deaths (Starsiege.exe 0x472f80: debris pieces carrying IDDTS_EXP_L or IDDTS_SHOCK_M explode
    where they land) and structure deaths (each mission record names its own IDDTS_EXP_* explosion tag)."""
    CodeCheck(SS_EXE, _pe_offset(SS_EXE), SS_EVIDENCE_TAGS)
    large, shock = fx.impact('IDDTS_EXP_L'), fx.impact('IDDTS_SHOCK_M')
    blast = [make_step(large), make_step(shock, height=GROUND),
             make_step(large, delay=DEBRIS_DELAY_S, count=3, interval=DEBRIS_INTERVAL_S, scatter=DEBRIS_SCATTER,
                       height=GROUND)]
    source = ('Starsiege.exe 0x47303b: the Herc is blown into debris (tables IDDEF_HERC_*_DEBRIS 0x6c5b20..) whose '
              'pieces explode IDDTS_EXP_L or IDDTS_SHOCK_M (the choice flag at vehicle data +0x111 is not decoded: '
              'both play); the remake plays the blast at the hull and three debris blasts around it')
    tags = explosion_tag_ids(fx.files.read('Sim.Strings.cs').decode('latin1'))
    structures = {}
    for name, tag in tags.items():
        effect = fx.impact(name)
        if effect:
            structures[str(tag)] = make_entry([make_step(effect)], 'mission record explosion tag %s (%s)' % (tag, name))
    default = structures.get(str(tags.get('IDDTS_EXP_L')))
    return {
        'source': 'Starsiege.exe herc death 0x472f80; mission static-shape / turret records (explosion tag)',
        'vehicle': make_entry(blast, source),
        'structure': default or make_entry([make_step(large)], 'IDDTS_EXP_L (the most common record tag)'),
        'structures': structures,
        'turret': default or make_entry([make_step(large)], 'IDDTS_EXP_L'),
    }


def explosion_tag_ids(sim_strings):
    """IDDTS_EXP_<size> -> tag id (Sim.Strings.cs; the translucent _T variants are drawn by fx.impact)."""
    rx = re.compile(r'^\s*(IDDTS_EXP_[A-Z]+)\s*=\s*(\d+)\s*,', re.M)
    return {m.group(1): int(m.group(2)) for m in rx.finditer(sim_strings)}


# ================================================================== Tribes (scripts)

def tribes_deaths(fx, vehicle_blocks):
    """Vehicles: FlierData explosionId + debrisId (whose pieces spawn their spawnedExplosionID); turrets and
    static shapes: their explosionId; soldiers: no explosion (death animation), blown apart by explosive damage
    with spillover > 0.5 (player.cs Player::onDamage -> Player::blowUp: playerDebris)."""
    vehicles = {}
    for key, block_name in vehicle_blocks:
        block = fx.db.get(block_name.lower())
        vehicles[key] = _darkstar_blast(fx, block)
    turret = _darkstar_blast(fx, fx.db.get('plasmaturret'))
    structure = _darkstar_blast(fx, fx.db.get('generator'))
    return {
        'source': 'tribes/extracted scripts vehicle.cs, turret.cs, staticshape.cs, baseDebrisData.cs, player.cs',
        'vehicle': next(iter(vehicles.values())),
        'vehicles': vehicles,
        'turret': turret,
        'structure': structure,
        'infantry': make_entry([], 'player.cs Player::onDamage: a killed soldier plays a death animation; a '
                                   'blown-up one (explosive damage, spillover > 0.5) is thrown apart as playerDebris '
                                   'pieces, which name no spawnedExplosionID: no explosion either way'),
    }


def _darkstar_blast(fx, block):
    """explosionId at the body + the debrisId pieces' spawnedExplosionID around it (when either exists)."""
    if not block:
        return make_entry([], 'datablock missing')
    fields = block['fields']
    steps, notes = [], ['%s %s %s' % (block['source'], block['class'], block['name'])]
    explosion = fx.explosion(fields.get('explosionid', ''))
    if explosion:
        steps.append(make_step(explosion))
        notes.append('explosionId %s' % explosion)
    debris = fx.db.get(str(fields.get('debrisid', '')).lower())
    spawned = fx.explosion(debris['fields'].get('spawnedexplosionid', '')) if debris else None
    if spawned:
        steps.append(make_step(spawned, delay=DEBRIS_DELAY_S, count=3, interval=DEBRIS_INTERVAL_S,
                               scatter=DEBRIS_SCATTER, height=GROUND))
        notes.append('debrisId %s pieces explode %s on rest (played around the wreck)' % (debris['name'], spawned))
    return make_entry(steps, '; '.join(notes))


# ================================================================== Tribes 2 (scripts)

def tribes2_deaths(builder, db, vehicle_blocks):
    """Vehicles: VehicleData `explosion`; turrets TurretData(TurretBaseLarge) explosion; static shapes
    `explosion` (ShapeExplosion); soldiers: none (player.cs: the blowup() calls are commented out)."""
    vehicles = {}
    for key, block_name in vehicle_blocks:
        block = db.get(block_name)
        vehicles[key] = _torque_blast(builder, db, block)
    return {
        'source': 'tribes2 scripts vehicles/*.cs, turret.cs, staticShape.cs, player.cs',
        'vehicle': next(iter(vehicles.values())),
        'vehicles': vehicles,
        'turret': _torque_blast(builder, db, db.get('TurretBaseLarge')),
        'structure': _torque_blast(builder, db, db.get('GeneratorLarge')),
        'infantry': make_entry([], 'player.cs Armor::damageObject: the blowup() calls are commented out; a killed '
                                   'soldier only plays its death animation'),
    }


def _torque_blast(builder, db, block):
    if not block:
        return make_entry([], 'datablock missing')
    name = builder.explosion_effect(block.get('explosion'))
    steps = [make_step(name)] if name else []
    return make_entry(steps, '%s explosion %s' % (db.evidence(block), block.get('explosion')))


# ================================================================== thrown grenades and mines (Tribes 1 / 2)

GEAR_FILE = ('gameplay', 'infantry_gear.json')


def attach_gear_bursts(pack, burst_for_source):
    """Adds `burst_fx` (the effect a thrown grenade / mine plays when it bursts) to the pack's hand items.

    burst_for_source(item source evidence) -> effect name or None. Returns the ids of bursting items left
    without one (the exporter reports them)."""
    import json
    path = P.pack(pack, *GEAR_FILE)
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf-8') as f:
        gear = json.load(f)
    missing = []
    for item in gear.get('items', []):
        if item.get('kind') not in ('grenade', 'concussion', 'mine'):
            continue
        item['burst_fx'] = burst_for_source(str(item.get('source') or ''))
        if not item['burst_fx']:
            missing.append(item.get('id'))
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(gear, f, indent=1)
    return missing


def tribes_gear_burst(fx):
    """Tribes 1: 'Mine.cs MineData <name>, ...' -> that MineData's explosionId."""
    def burst(source):
        m = re.search(r'MineData (\w+)', source)
        block = fx.db.get(m.group(1).lower()) if m else None
        return fx.explosion(block['fields'].get('explosionid', '')) if block else None
    return burst


def tribes2_gear_burst(builder, db):
    """Tribes 2: 'scripts/weapons <Item> -> <Thrown datablock>' -> that ItemData's `explosion`."""
    def burst(source):
        m = re.search(r'->\s*(\w+)', source)
        block = db.get(m.group(1)) if m else None
        return builder.explosion_effect(block.get('explosion')) if block else None
    return burst
