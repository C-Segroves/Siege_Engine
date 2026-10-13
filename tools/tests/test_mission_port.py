"""Compare the GDScript mission compiler port (game/games/es1/mission/mission_compiler.gd) with
tools/mission.py mission_json() for every MSN, several seeds and mission-var sets.

    python tools/tests/test_mission_port.py [--godot PATH] [--keep]

Writes the cases and both result sets to out/tests/, runs the Godot test scene
res://tests/test_mission_compiler.tscn headless, and diffs the results field by field.
Requires gamedata/es1/missions (python tools/export_missions.py).
"""
import argparse, glob, json, os, random, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import mission as M  # noqa: E402

GODOT = os.environ.get('SIEGE_GODOT', 'godot')   # path to the Godot 4.6.3 console exe
OUT = os.path.join(ROOT, 'out', 'tests')
SEEDS = [None, 0, 1, 7, 12345, 2 ** 31 - 1, 2 ** 40 + 3]


def var_sets():
    """A couple of non-trivial mission.var sets (campaign progress flags, time of day...)."""
    a = [0] * 100
    a[1], a[2], a[3] = 3, 4, 1
    for i in range(15, 94, 2):
        a[i] = 1
    r = random.Random(99)
    b = [r.randrange(4) for _ in range(100)]
    b[1] = 5
    c = [0] * 100
    c[1], c[3], c[4], c[5], c[6] = 99, 2, 11, 5, 3
    for i in range(7, 100):
        c[i] = (i * 7) % 5
    return [a, b, c]


def build_cases():
    names = [os.path.splitext(os.path.basename(p))[0] for p in sorted(glob.glob(os.path.join(M.MSN_DIR, '*.MSN')))]
    vs = var_sets()
    cases = []
    for n in names:
        for s in SEEDS:
            cases.append(dict(name=n, seed=s, mvars=None, campaign='auto', options=None))
        for i, v in enumerate(vs):
            cases.append(dict(name=n, seed=[3, 1000, None][i], mvars=v, campaign='auto', options=None))
        # forced modes: single mission with options / explicit campaign index
        cases.append(dict(name=n, seed=5, mvars=None, campaign=None,
                          options=dict(ammo=0, damage=0, difficulty=3, visibility=1, time_of_day=2)))
        cases.append(dict(name=n, seed=11, mvars=vs[0], campaign=6, options=None))
    return cases


def py_result(c):
    return M.mission_json(c['name'], c['seed'], c['mvars'], c['campaign'], c['options'],
                          with_raw=False, with_zone=True)


def gd_case(c):
    camp = c['campaign']
    return dict(name=c['name'], seed=c['seed'], mvars=c['mvars'], options=c['options'],
                campaign=-1 if camp == 'auto' else (-2 if camp is None else camp))


def diff(a, b, path, out, limit=10):
    if len(out) >= limit:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b), key=str):
            if k not in a or k not in b:
                out.append('%s.%s: only in %s' % (path, k, 'python' if k in a else 'godot'))
            else:
                diff(a[k], b[k], '%s.%s' % (path, k), out, limit)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append('%s: length %d != %d' % (path, len(a), len(b)))
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, '%s[%d]' % (path, i), out, limit)
    elif a != b or type(a) != type(b):
        if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) \
                and not isinstance(b, bool) and a == b:
            return
        out.append('%s: python %r != godot %r' % (path, a, b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--godot', default=os.environ.get('GODOT', GODOT))
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    cases = build_cases()
    cases_p = os.path.join(OUT, 'mission_cases.json')
    py_p = os.path.join(OUT, 'mission_py.json')
    gd_p = os.path.join(OUT, 'mission_gd.json')
    json.dump([gd_case(c) for c in cases], open(cases_p, 'w'))
    py = [json.loads(json.dumps(py_result(c))) for c in cases]    # normalise like a JSON round trip
    json.dump(py, open(py_p, 'w', encoding='utf-8'), ensure_ascii=False)
    if os.path.exists(gd_p):
        os.remove(gd_p)
    r = subprocess.run([args.godot, '--headless', '--audio-driver', 'Dummy', '--path', os.path.join(ROOT, 'game'),
                        'res://tests/test_mission_compiler.tscn', '--', '--cases=' + cases_p, '--out=' + gd_p],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    print(r.stdout.strip())
    if r.returncode != 0 or not os.path.exists(gd_p):
        print(r.stderr[-4000:])
        print('godot run failed (exit %d)' % r.returncode)
        return 1
    gd = json.load(open(gd_p, encoding='utf-8'))
    if len(gd) != len(py):
        print('result count %d != %d' % (len(gd), len(py)))
        return 1
    bad = 0
    for c, a, b in zip(cases, py, gd):
        d = []
        diff(a, b, '', d)
        if d:
            bad += 1
            if bad <= 15:
                print('MISMATCH %s seed=%s campaign=%s vars=%s' % (c['name'], c['seed'], c['campaign'],
                                                                 'set' if c['mvars'] else 'default'))
                for x in d:
                    print('   ', x)
    print('%d cases (%d missions), %d mismatches' % (len(cases), len({c["name"] for c in cases}), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
