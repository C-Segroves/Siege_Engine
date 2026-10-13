"""Compare the GDScript Earthsiege 2 mission compiler (game/games/es1/mission/mission_compiler_es2.gd)
with tools/mission_es2.py mission_json() for every ES2 MSN, several seeds and mission-var sets.

    python tools/tests/test_mission_port_es2.py [--godot PATH] [--keep]

Requires gamedata/es2/missions (python tools/mission_es2.py export). Uses the Godot test scene
res://tests/test_mission_compiler.tscn (MissionCompiler.load_mission delegates "es2:" names).
"""
import argparse, glob, json, os, random, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, HERE)
import mission_es2 as M2  # noqa: E402
from test_mission_port import GODOT, OUT, diff  # noqa: E402

SEEDS = [None, 0, 1, 12345, 2 ** 31 - 1]


def var_sets():
    r = random.Random(7)
    a = [0] * M2.NVARS
    for i in range(100, 900):
        a[i] = r.randrange(3)
    b = [r.randrange(5) for _ in range(M2.NVARS)]
    return [a, b]


def build_cases():
    idx = json.load(open(os.path.join(ROOT, 'gamedata', 'es2', 'missions', 'index.json')))
    cases = []
    for n in idx['missions']:
        for s in SEEDS:
            cases.append(dict(name=n, seed=s, mvars=None, campaign='auto'))
        for i, v in enumerate(var_sets()):
            cases.append(dict(name=n, seed=[3, None][i], mvars=v, campaign='auto'))
        cases.append(dict(name=n, seed=5, mvars=None, campaign=None))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--godot', default=GODOT)
    ap.add_argument('--keep', action='store_true')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    cases = build_cases()
    py = [M2.mission_json(c['name'], c['seed'], c['mvars'], c['campaign']) for c in cases]
    py = json.loads(json.dumps(py))
    gd_cases = [dict(name='es2:' + c['name'], seed=c['seed'], mvars=c['mvars'], options=None,
                     campaign=-1 if c['campaign'] == 'auto' else (-2 if c['campaign'] is None else c['campaign']))
                for c in cases]
    cp = os.path.join(OUT, 'es2_cases.json')
    gp = os.path.join(OUT, 'es2_gd.json')
    json.dump(gd_cases, open(cp, 'w'))
    r = subprocess.run([a.godot, '--headless', '--audio-driver', 'Dummy', '--path', os.path.join(ROOT, 'game'), 'res://tests/test_mission_compiler.tscn',
                        '--', '--cases=' + cp, '--out=' + gp], capture_output=True, text=True)
    print(r.stdout[-2000:], r.stderr[-3000:])
    gd = json.load(open(gp))
    bad = 0
    for c, p, g in zip(cases, py, gd):
        out = []
        diff(p, g, c['name'], out)
        if out:
            bad += 1
            if bad <= 10:
                print('MISMATCH', c['name'], c['seed'], '\n  ' + '\n  '.join(out))
    print('%d cases, %d mismatches' % (len(cases), bad))
    if not a.keep:
        for f in (cp, gp):
            os.remove(f)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
