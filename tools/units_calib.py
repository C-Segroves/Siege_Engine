"""Real-world unit calibration for Earthsiege (ES1, DBSIM.EXE) and Battledrome (BD, SIM.EXE).

    python tools/units_calib.py [es1] [bd]  -> gamedata/es1/units.json, gamedata/bd/units.json

Every constant below is code-derived. The derivation (with addresses) is in docs/formats/units.md.
If the executables are present, the script first checks the instruction bytes that the constants
come from, so a wrong exe/version is reported instead of silently producing wrong numbers.
Per-Herc numbers (height, walk/run ground speed, top speed) are computed from the exported shape
animations (gamedata/<game>/shapes/*.json) and unit tables (gamedata/<game>/gameplay/hercs.json).
Either game is skipped if its gamedata is missing.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402  (source tree = P.WORK, packs = P.PACKS)
TURN = 65536                      # angle units per full turn (both games)
RAD_PER_ANGLE_UNIT = 2 * math.pi / TURN

# ---------------------------------------------------------------- ES1 (DBSIM.EXE, VA = file - 0x48FD)
ES1_EXE = ('original/DBSIM.EXE', 0x48fd)
ES1_CHECKS = [                                     # (va, bytes, meaning)
    (0x5a9f7, '68d3260000', 'push 0x26d3: PIT divisor 9939 -> 120 Hz timer'),
    (0x63eab, '68a1350000', 'push 0x35a1: 13729/16384 us per PIT count'),
    (0x63ed2, 'b90a000000', 'Hz/10 -> ticks per 100 ms'),
    (0x63f1c, '66b9c201', 'frame scale clamp max 450 (/256 * 100 ms)'),
    (0x63f29, '66b84000', 'frame scale clamp min 64'),
    (0x2e2a4, 'b9e8030000', 'metres = units / 1000 ...'),
    (0x2e2ac, '8d044003c0', '... * 6 (lea eax,[eax+eax*2]; add eax,eax)'),
    (0x6274b, 'f7e9c1', 'anim time += dt_ms * rate >> 8'),
    (0xfb51, 'b804000000', 'shield recharge max 4 per Mech::update'),
    (0xb531, 'b914000000', 'beam capacitor +20 per update'),
    (0x14eef, '6a0f', 'engine energy +15 per 100 ms'),
    (0x12458, 'b83c000000', 'minimum walk animation rate 60'),
]
ES1_M_PER_UNIT = 6.0 / 1000.0          # 0x2e2a0: shown metres = units/1000*6  (WP "dddd M.", RNG:, DST:)
ES1_FRAME_SCALE_PER_S = 2560.0         # [0xbdbd0] = 256 per 100 ms of real time (0x63f40/0x63f04)
ES1_NOMINAL_FRAME_S = 0.1              # the frame scale is normalised to a 100 ms update
ES1_ANIM_TICK_S = 0.001                # anim time += 0x63fa4(100) (= dt in ms) * rate/256 (0x14148, 0x62718)

# ---------------------------------------------------------------- BD (SIM.EXE, VA = file - 0x69CD)
BD_EXE = ('bd/installed/SIM.EXE', 0x69cd)
BD_CHECKS = [
    (0xfb5, '68d3260000', 'push 0x26d3: PIT divisor 9939 -> 120 Hz, [0xa13a2]++ per IRQ (0xfa0)'),
    (0x1013, 'b90a000000', 'Hz/10 = 12 PIT ticks per 100 ms'),
    (0x1596, 'b919000000', 'lock-step frame = 25 sim time units'),
    (0x15ae, 'b819000000', 'sim step clamp max 25 units per frame'),
    (0x15b9, 'b008', 'sim step clamp min 8 units per frame'),
    (0x7370, '83c019', 'Herc WakeUp every 25 units (100 ms)'),
    (0x2a574, '69d1d0070000', 'anim ticks = dt * (rate*2000>>8) >> 8'),
    (0x2a8c7, '69c1d0070000', 'anim rate = speed*2000/V_walk*256/2000'),
    (0x2b7f5, 'c1f908', 'LinMove: pos = p0 + v*dt >> 8'),
    (0x61d0, 'b9e8030000', 'target DIST: readout = |d| / 1000'),
    (0x2a896, '83fb06', 'Animate rate switch on the current sequence 0..6 (jump table 0x7955c)'),
    (0x2a962, '8b4718', 'seq 6 plays at the fixed rate w25 (Animate+0x18)'),
]
# Animate sequence ids (rate switch at 0x2a896 over the current sequence, jump table 0x7955c):
# 0 walk / 2 run -> rate from speed (0x2a8c4), 1 -> rate 0 = standing still (0x2a8a6), 5 -> turn in place
# at turn/80 (0x2a926), 6 -> fixed rate w25 (0x2a962) = the collapse (hips drop 2300 -> 650 units).
BD_SEQ = {'stand_seq': 1, 'walk_seq': 0, 'run_seq': 2, 'turn_seq': 5, 'death_seq': 6}
BD_TIME_UNIT_S = 0.004                 # 25 units per 12 PIT ticks at 120 Hz = 100 ms (0x1544)
BD_RATE_TIME_UNITS = 256               # speeds/turn rates are per 256 time units (>>8 of dt)
BD_ANIM_TICKS_PER_UNIT_AT_1X = 2000.0 / 256.0   # 0x2a574: rate 256 -> 7.8125 anim ticks per 4 ms
BD_M_PER_UNIT_DIST = 1.0 / 1000.0      # 0x61c8: DIST = |d|/1000, read as metres (label has no unit)


def check_exe(spec, checks):
    path, base = spec
    p = P.work(path)
    if not os.path.exists(p):
        return 'not checked (%s missing)' % path
    d = open(p, 'rb').read()
    bad = []
    for va, hexb, what in checks:
        got = d[va + base:va + base + len(hexb) // 2].hex()
        if got != hexb:
            bad.append('%x: expected %s got %s (%s)' % (va, hexb, got, what))
    if bad:
        raise SystemExit('units_calib: %s does not match the analysed build:\n  ' % path + '\n  '.join(bad))
    return 'verified %d code sites in %s' % (len(checks), path)


# ---------------------------------------------------------------- shape helpers
def _rot(rx, ry, rz):
    ax, ay, az = rx * RAD_PER_ANGLE_UNIT, ry * RAD_PER_ANGLE_UNIT, rz * RAD_PER_ANGLE_UNIT
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    rxm = [[1, 0, 0], [0, cx, -sx], [0, sx, cx]]
    rym = [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]]
    rzm = [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]]
    mul = lambda a, b: [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    return mul(rzm, mul(rym, rxm))


def shape_extent(shape):
    """(min_xyz, max_xyz) of LOD0, intact state, posed with the default node transforms."""
    T, nodes = shape['transforms'], shape['nodes']
    cache = {}

    def g(i):
        if i in cache:
            return cache[i]
        t = T[nodes[i]['default']]
        r, tr = _rot(*t[:3]), t[3:6]
        p = nodes[i]['parent']
        if p >= 0:
            pr, pt = g(p)
            r2 = [[sum(pr[a][k] * r[k][b] for k in range(3)) for b in range(3)] for a in range(3)]
            t2 = [pt[a] + sum(pr[a][k] * tr[k] for k in range(3)) for a in range(3)]
            r, tr = r2, t2
        cache[i] = (r, tr)
        return cache[i]
    lo, hi = [1e18] * 3, [-1e18] * 3
    for pc in shape['lods'][0]['pieces']:
        if int(pc.get('state', 0)) != 0:
            continue
        n = int(pc['node'])
        r, tr = g(n) if 0 <= n < len(nodes) else ([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [0, 0, 0])
        for poly in pc['polys']:
            for v in poly['v']:
                w = [tr[a] + sum(r[a][k] * v[k] for k in range(3)) for a in range(3)]
                lo = [min(lo[a], w[a]) for a in range(3)]
                hi = [max(hi[a], w[a]) for a in range(3)]
    return lo, hi


def seq_ground(shape, s):
    """(forward displacement per cycle, cycle ticks) of sequence s: node-0 per-frame deltas
    (ES1 0x61c4c / 0x61da8, BD 0x2aaf4 sum the ground node transform of each frame)."""
    seq = shape['sequences'][s]
    npart = len(seq['parts'])
    T = shape['transforms']
    if not seq['gm'] or not npart or seq['parts'][0] != 0:
        return 0, sum(f[0] for f in seq['frames'])
    d = sum(T[seq['tf'][f * npart]][4] for f in range(len(seq['frames'])))
    return d, sum(f[0] for f in seq['frames'])


def seq_turn_per_tick(shape, s):
    """Ground-node z rotation (angle units) per anim tick of sequence s (BD seq 5 = turn in place)."""
    seq = shape['sequences'][s]
    npart = len(seq['parts'])
    T = shape['transforms']
    if not seq['gm'] or not npart:
        return 0.0
    rz = sum(T[seq['tf'][f * npart]][2] for f in range(len(seq['frames'])))
    return rz / float(sum(f[0] for f in seq['frames']))


def load(p):
    with open(p, encoding='utf-8') as f:
        return json.load(f)


# ---------------------------------------------------------------- ES1
def es1():
    gp = P.pack('es1', 'gameplay', 'hercs.json')
    if not os.path.exists(gp):
        return None
    verified = check_exe(ES1_EXE, ES1_CHECKS)
    m = ES1_M_PER_UNIT
    hercs = load(gp)
    table = []
    for key, h in hercs.items():
        sp = P.pack('es1', 'shapes', key + '.json')
        if not os.path.exists(sp):
            continue
        shape = load(sp)
        lo, hi = shape_extent(shape)
        walk_seq, run_seq = h['anim_seq_stand'], h['anim_seq_start']   # DAT 0x0c / 0x0e (0x12547, 0x125ba)
        dw, tw = seq_ground(shape, walk_seq)
        dr, tr = seq_ground(shape, run_seq)
        # velocity (units/s) per speed unit: anim plays rate/256 x real time, 1 tick = 1 ms
        kw = dw / tw * 1000.0 / 256.0
        kr = dr / tr * 1000.0 / 256.0
        vmax = h['speed_forward_max']
        k_top = kr if vmax > h['walk_seq_speed_cap'] else kw
        table.append({
            'unit': key, 'name': h['name'], 'side': h['side'],
            'height_m': round((hi[2] - lo[2]) * m, 2), 'height_units': round(hi[2] - lo[2]),
            'walk_seq': walk_seq, 'walk_mps_per_speed_unit': round(kw * m, 5),
            'run_seq': run_seq, 'run_mps_per_speed_unit': round(kr * m, 5),
            'walk_run_switch_speed': h['walk_seq_speed_cap'],
            'speed_forward_max': vmax, 'speed_reverse_max': h['speed_reverse_max'],
            'top_speed_mps': round(vmax * k_top * m, 2), 'top_speed_kmh': round(vmax * k_top * m * 3.6, 1),
            'reverse_kmh': round(abs(h['speed_reverse_max']) * kw * m * 3.6, 1),
            'accel_mps2': round(h['acceleration'] / ES1_NOMINAL_FRAME_S * k_top * m, 2),
            'turn_rate_max_deg_s': round(h['turn_rate_max'] / ES1_NOMINAL_FRAME_S * 360.0 / TURN, 1),
            'torso_yaw_rate_deg_s': round(h['torso_yaw_rate'] * 10 * 360.0 / TURN, 1),
            'torso_pitch_rate_deg_s': round(h['torso_pitch_rate'] * 10 * 360.0 / TURN, 1),
            'shield_radius_m': round(h['shield_radius'] * m, 2),
            'mass_raw': h['mass'], 'shield_max': h['shield_max'],
        })
    herc_rows = [r for r in table if r['side'] == 'herc']
    mean_k = sum(r['run_mps_per_speed_unit'] for r in herc_rows) / max(1, len(herc_rows))
    weapons = []
    wp = P.pack('es1', 'gameplay', 'weapons.json')
    if os.path.exists(wp):
        for w in load(wp)['weapons']:
            row = w.get('projectile_row')
            row = row if isinstance(row, dict) else {'type_name': row}
            sp = row.get('speed_or_limit')
            weapons.append({
                'name': w['name'], 'range_m': round(w['range'] * m, 1), 'refire_s': round(w['refire_delay'] / ES1_FRAME_SCALE_PER_S, 3),
                'projectile': row.get('type_name'),
                'projectile_speed_mps': round(sp * 10 * m, 1) if sp and row.get('type_name') in ('bullet', 'bolt', 'missile') else None,
                'shield_damage': row.get('shield_damage'), 'armor_damage': row.get('armor_damage')})
    return {
        'game': 'Metaltech: Earthsiege (DBSIM.EXE)',
        'verified': verified,
        'metres_per_unit': m,
        'units_per_metre': 1.0 / m,
        'seconds_per_tick': ES1_NOMINAL_FRAME_S,
        'tick_notes': 'Variable frame rate. Real dt is measured with a 120 Hz PIT timer and turned into a '
                      'frame scale ([0xbdbd0], 256 = 100 ms, clamped 64..450 = 25..176 ms). Quantities that '
                      'are multiplied by that scale (0x63fa4) are exact per-100-ms rates; quantities applied once '
                      'per Mech::update without scaling (legs speed/accel/yaw rate, shields, beam charge, '
                      'bullet lifetime) are per frame and are converted with the nominal 0.1 s frame.',
        'angle_units_per_turn': TURN,
        'timer_units_per_second': ES1_FRAME_SCALE_PER_S,
        'speed': {
            'field_units': 'animation rate, 256 = walk/run cycle at authored speed (1 anim tick = 1 ms); '
                           'ground speed comes from the node-0 deltas of the playing sequence, so the m/s per '
                           'speed unit is per Herc and per sequence (see hercs[].walk/run_mps_per_speed_unit)',
            'to_mps': round(mean_k, 5),
            'to_mps_note': 'mean run-sequence factor over the 8 Hercs; use the per-Herc factor for exact values',
            'walk_min_anim_rate': 60,
        },
        'accel': {'field_units': 'speed units per frame', 'to_mps2': round(mean_k / ES1_NOMINAL_FRAME_S, 5),
                  'note': 'per Herc: hercs[].accel_mps2 (acceleration / 0.1 s * run factor)'},
        'turn_rate': {'field_units': 'angle units per frame (Mech yaw rate +0x222, 0x12a71/0x12a9b)',
                      'to_rad_per_s': RAD_PER_ANGLE_UNIT / ES1_NOMINAL_FRAME_S,
                      'turn_accel_to_rad_per_s2': RAD_PER_ANGLE_UNIT / ES1_NOMINAL_FRAME_S ** 2},
        'torso_rate': {'field_units': 'angle units per 100 ms (0x149ac, scaled by 0x63fa4)',
                       'to_rad_per_s': RAD_PER_ANGLE_UNIT * 10, 'accel_to_rad_per_s2': RAD_PER_ANGLE_UNIT * 100},
        'projectile_speed': {'field_units': 'world units per 100 ms (0x8041/0x72f6: move = 0x63fa4(speed))',
                             'to_mps': 10 * m},
        'refire': {'field_units': 'timer units, decremented by the frame scale (0x6410c at 0xb44f)',
                   'to_seconds': 1.0 / ES1_FRAME_SCALE_PER_S},
        'timers': {'to_seconds': 1.0 / ES1_FRAME_SCALE_PER_S,
                   'examples': {'emp_shield_down_6000': round(6000 / ES1_FRAME_SCALE_PER_S, 3)}},
        'anim_tick_seconds': ES1_ANIM_TICK_S,
        'shield_recharge': {'field_units': 'shield points per frame (max 4, 0xfb51)', 'to_per_second': 1 / ES1_NOMINAL_FRAME_S},
        'beam_charge': {'field_units': 'capacitor points per frame (20, 0xb531; 60 fast)', 'to_per_second': 1 / ES1_NOMINAL_FRAME_S},
        'energy_regen': {'field_units': 'engine energy per 100 ms (15, 0x14eef)', 'per_second': 150,
                         'note': 'shields and beams draw from this pool, so their sustained rate is time-correct'},
        'bullet_lifetime': {'field_units': 'frames (BULLETS.DAT, 0x800b)', 'to_seconds': ES1_NOMINAL_FRAME_S},
        'damage_scale': 1.0,
        'notes': 'Distance scale from the cockpit readouts: 0x2e2a0 returns units*6/1000 and its result is '
                 'printed with " M." (waypoint, 0x34a5b) and on the scanner (RNG:/DST:, 0x355a4). '
                 'So 1 m = 166.67 units; Hercs are 10-15 m tall.',
        'hercs': table,
        'weapons': weapons,
    }


# ---------------------------------------------------------------- BD
def bd(es1_res):
    gp = P.pack('bd', 'gameplay', 'hercs.json')
    if not os.path.exists(gp):
        return None
    verified = check_exe(BD_EXE, BD_CHECKS)
    m = BD_M_PER_UNIT_DIST
    ups = 1.0 / BD_TIME_UNIT_S                         # 250 time units per second
    k_speed = ups / BD_RATE_TIME_UNITS                 # units/s per speed unit (walk sequence, exact)
    hercs = load(gp)
    table = []
    for key, h in hercs.items():
        sp = P.pack('bd', 'shapes', key + '.json')
        if not os.path.exists(sp):
            continue
        w = h['raw_words']
        shape = load(sp)
        lo, hi = shape_extent(shape)
        dw, tw = seq_ground(shape, 0)                  # seq 0 = walk (V_walk at 0x2a3f0)
        dr, tr = seq_ground(shape, 2)                  # seq 2 = run (switch when anim rate >= w24)
        v_walk = dw * 2000.0 / tw
        v_run = dr * 2000.0 / tr
        run_ratio = v_run / v_walk if v_walk else 1.0
        vmax = w[7]                                     # throttle table (+0x00): (-127,w1) (-5,w3) (5,w5) (127,w7)
        rate_max = vmax * 256.0 / v_walk if v_walk else 0
        running = rate_max >= w[24]
        top_nominal = vmax * k_speed * m
        top_actual = top_nominal * (run_ratio if running else 1.0)
        table.append({
            'unit': key, 'name': h['name'], 'height_m': round((hi[2] - lo[2]) * m, 2),
            'height_units': round(hi[2] - lo[2]),
            'throttle_speed_table': [[w[0], w[1]], [w[2], w[3]], [w[4], w[5]], [w[6], w[7]]],
            'turn_rate_vs_speed_table': [[w[8], w[9]], [w[10], w[11]], [w[12], w[13]], [w[14], w[15]]],
            'turn_rate_in_place': w[16], 'mass_raw': w[17],
            'anim_rate_min': w[22], 'anim_rate_run_threshold': w[24], 'anim_rate_seq6': w[25], **BD_SEQ,
            'walk_speed_units_per_2000_ticks': round(v_walk), 'run_speed_units_per_2000_ticks': round(v_run),
            'speed_forward_max': vmax, 'speed_reverse_max': w[1],
            'top_speed_kmh_nominal': round(top_nominal * 3.6, 1),
            'top_speed_kmh_animated': round(top_actual * 3.6, 1),
            'runs_at_top_speed': running,
            'reverse_kmh': round(abs(w[1]) * k_speed * m * 3.6, 1),
            'turn_rate_moving_deg_s': round(w[12 + 1] * ups / 256 * 360.0 / TURN, 1),
            'turn_rate_in_place_deg_s': round(max(w[16] / 80.0, w[22]) * BD_ANIM_TICKS_PER_UNIT_AT_1X / 256 * ups *
                                               seq_turn_per_tick(shape, 5) * 360.0 / TURN, 1),
        })
    hs = [r['height_units'] for r in table]
    es1_h = [r['height_units'] * es1_res['metres_per_unit'] for r in es1_res['hercs'] if r['side'] == 'herc'] if es1_res else []
    es1_mean = sum(es1_h) / len(es1_h) if es1_h else ES1_MEAN_HERC_HEIGHT_M   # packs are imported independently
    lore = es1_mean / (sum(hs) / len(hs)) if hs else None
    return {
        'game': 'Metaltech: Battledrome (SIM.EXE 1.3.2)',
        'verified': verified,
        'metres_per_unit': m,
        'units_per_metre': 1.0 / m,
        'metres_per_unit_confidence': 'M: DIST readout = |d|/1000 is certain (0x61c8-0x61e4); the label has no unit, '
                                      'metres is assumed (ES1 prints its target/waypoint distances in metres).',
        'metres_per_unit_alternatives': {
            'same_as_es1': ES1_M_PER_UNIT,
            'lore_matched_herc_height': round(lore, 6) if lore else None,
            'note': 'lore_matched makes the mean BD Herc as tall as the mean ES1 Herc (no code basis).',
        },
        'seconds_per_tick': BD_TIME_UNIT_S,
        'tick_notes': 'Event-driven sim clock [0x954b4] in 4 ms units (25 per 100 ms; per frame 8..25 units, '
                      'fixed 25 in network lock-step). Each Herc wakes every 25 units (100 ms, 0x7370) and '
                      'integrates with the exact elapsed dt, so every rate below is frame-rate independent.',
        'sim_update_seconds': 0.1,
        'angle_units_per_turn': TURN,
        'speed': {
            'field_units': 'world units per 256 time units (1.024 s); +0x1a5, throttle table at Herc +0x00',
            'to_mps': k_speed * m,
            'note': 'exact while the walk sequence plays (anim rate = speed*256/V_walk, 0x2a8c4). The run '
                    'sequence is driven with the same rate, so true ground speed while running is '
                    'speed * to_mps * V_run/V_walk (hercs[].top_speed_kmh_animated).',
        },
        'accel': {'field_units': 'engine force (engine record +0x00, table 0x85a24) / total mass per 1.024 s',
                  'to_mps2': k_speed * m / (BD_RATE_TIME_UNITS * BD_TIME_UNIT_S),
                  'note': 'accel_mps2 = force/mass * to_mps2; doubled when reversing direction (0x89a1)'},
        'turn_rate': {'field_units': 'angle units per 256 time units (Animate +0x30, 0x2a5b3)',
                      'to_rad_per_s': RAD_PER_ANGLE_UNIT * ups / BD_RATE_TIME_UNITS},
        'projectile_speed': {'field_units': 'world units per 256 time units (1.024 s): bolts/shells/missiles move '
                                            'p0 + v*dt>>8 (0x10fd8); docs/formats/bd_weapons.md',
                             'to_mps': k_speed * m},
        'refire': {'field_units': 'time units (4 ms), weapon record +0x0c; tested now-last > refire in the 100 ms '
                                 'Herc update, so effective = (refire//25+1)*0.1 s',
                   'to_seconds': BD_TIME_UNIT_S},
        'anim_tick_seconds': BD_TIME_UNIT_S / BD_ANIM_TICKS_PER_UNIT_AT_1X,
        'anim_notes': 'anim ticks advance dt*rate*2000/65536 (0x2a574): at rate 256 one tick = 0.512 ms',
        'damage_scale': 0.5,
        'damage_notes': 'BD damage and per-part armour x 0.5 = ES1 points; BD shield points map 1:1 (area damage '
                        'costs 1 shield point per 2 damage). See docs/formats/bd_weapons.md section 5.',
        'notes': 'Turning in place plays sequence 5 at anim rate turn/80 (0x2a926) and the Animate turn term is '
                 'zeroed (0x2a65c), so in-place rotation comes from the 1820-per-frame ground rotation.',
        'hercs': table,
    }


# mean ES1 Herc height (m) from es1(): used for BD's informational lore-matched scale when ES1 is not imported
ES1_MEAN_HERC_HEIGHT_M = 12.5235


def main(argv=None):
    games = [a for a in (sys.argv[1:] if argv is None else argv) if not a.startswith('-')] or ['es1', 'bd']
    e = es1() if 'es1' in games or os.path.exists(P.pack('es1', 'gameplay', 'hercs.json')) else None
    b = bd(e) if 'bd' in games else None
    for game, res in (('es1', e), ('bd', b)):
        if game not in games:
            continue
        if res is None:
            print('units_calib: %s gamedata missing, skipped' % game)
            continue
        out = P.pack(game, 'units.json')
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(res, f, indent=1)
        print('units_calib: wrote %s (%s)' % (out, res['verified']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
