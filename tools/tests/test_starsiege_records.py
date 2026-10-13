"""Decoders of the Starsiege .mis records added for the campaign polish (tools/starsiege_mis.py,
tools/darkstar_weather.py):

    python tools/tests/test_starsiege_records.py

Synthetic records check the SNOW / Tribes Snowfall decode (rain flag, suspendRendering, frame change of
the wind) and the SimShape damage + fire block of a static record. With the original files in the work
tree it also checks known values: HA4 turret1 (8000 hit points, 2 x TUR_HATC tags, 800 m, rearm 5 s),
every turret record decodes its type, CD1 is rain and CC1 snow.
"""
import glob
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.normpath(os.path.join(HERE, '..'))
sys.path.insert(0, TOOLS)
import darkstar_weather as W  # noqa: E402
import starsiege_mis as SM  # noqa: E402

INSTALLED = os.path.join(TOOLS, '..', 'starsiege', 'original', 'installed')
NET_HEADER = bytes(24)
IDWEA_TUR_HATC = 301712
failures = []


def check(ok, what):
    print('%s %s' % ('PASS' if ok else 'FAIL', what))
    if not ok:
        failures.append(what)


def snow_record(intensity, wind, suspend, rain):
    return NET_HEADER + struct.pack('<4f', intensity, *wind) + bytes([suspend, rain])


def test_weather():
    w = W.starsiege_weather(snow_record(0.5, (20.0, 10.0, -85.0), 0, 1))
    check(w['kind'] == 'rain' and w['intensity'] == 0.5, 'SNOW rain flag and intensity')
    check(w['wind'] == [20.0, -85.0, -10.0], 'SNOW wind to the engine frame (x, z, -y)')
    check(W.starsiege_weather(snow_record(1.0, (0.0, 0.0, -35.0), 1, 0)) is None, 'suspendRendering hides it')
    t = W.tribes_weather({'intensity': '1', 'wind': '1 2 -35', 'suspendRendering': 'False', 'rain': 'False'})
    check(t['kind'] == 'snow' and t['wind'] == [1.0, -35.0, -2.0], 'Tribes Snowfall fields')


def test_static_damage_block():
    body = bytearray(200)
    struct.pack_into('<3I2fIf', body, SM.DAMAGE_AT, SM.FLAG_INDESTRUCTIBLE, 1050011, 1050021, 6000.0, 1500.0,
                     351262, 0.1)
    struct.pack_into('<2fBf', body, len(body) - SM.FIRE_BLOCK_SIZE, 1000.0, 100.0, 1, 1000.0)
    d = dict(SM.read_damage(bytes(body)), **SM.read_fire_block(bytes(body), len(body) - SM.FIRE_BLOCK_SIZE))
    check(d['hit_points'] == 6000.0 and d['current_damage'] == 1500.0 and d['indestructible'],
          'damage block: hit points, current damage, indestructible flag')
    check(d['fire_threshold'] == 1000.0 and d['burn_rate'] == 100.0, 'fire block: threshold and burn rate')


def find_mis(rel_dir, stem):
    for f in glob.glob(os.path.join(INSTALLED, rel_dir, '*')):
        base, ext = os.path.splitext(os.path.basename(f))
        if base.lower() == stem.lower() and ext.lower() == '.mis':
            return f
    return None


def test_original_records():
    ha4 = find_mis(os.path.join('campaign', 'Human'), 'HA4')
    if not ha4:
        print('SKIP original records (no starsiege/original/installed)')
        return
    nodes = {p: n for p, n in SM.walk(SM.read_mis(ha4))}
    t = nodes['MissionGroup/base/Turrets/turret1']
    check(t['hit_points'] == 8000.0 and t['weapon_tags'] == [IDWEA_TUR_HATC] * 2 and t['range'] == 800.0,
          'HA4 turret1: hit points, weapons, activation distance')
    check(t['turret_ai']['reload_period'] == 5.0 and t['fire_threshold'] == 1000.0, 'HA4 turret1: rearm period, fire')
    untyped = 0
    for f in glob.glob(os.path.join(INSTALLED, '**', '*.*'), recursive=True):
        if f.lower().endswith('.mis'):
            untyped += sum(1 for _p, n in SM.walk(SM.read_mis(f)) if n['kind'] == 'turret' and not n.get('turret_type'))
    check(untyped == 0, 'every turret record decodes its type (%d without)' % untyped)
    for stem, kind in (('CD1', 'rain'), ('CC1', 'snow')):
        f = find_mis(os.path.join('campaign', 'Cybrid (Advanced)'), stem)
        snow = [n['weather'] for _p, n in SM.walk(SM.read_mis(f)) if n['kind'] == 'snow']
        check(len(snow) == 1 and snow[0]['kind'] == kind, '%s weather is %s' % (stem, kind))


if __name__ == '__main__':
    test_weather()
    test_static_damage_block()
    test_original_records()
    print('%d failed' % len(failures))
    sys.exit(1 if failures else 0)
