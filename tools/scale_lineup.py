"""Side-by-side lineup of shapes from different packs, converted to metres with each pack's scale
(units.json metres_per_unit, else pack.json unit_scale / 256 as game/engine/packs.gd does).

Usage: python tools/scale_lineup.py out.png pack:SHAPE [pack:SHAPE ...]
"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from preview_gamedata import ROOT, MARKER_IDS, node_worlds


def mpu(pack):
    u = os.path.join(ROOT, 'gamedata', pack, 'units.json')
    if os.path.exists(u):
        return json.load(open(u))['metres_per_unit']
    p = json.load(open(os.path.join(ROOT, 'gamedata', pack, 'pack.json')))
    return p.get('unit_scale', 1.0) / 256.0


def shape_polys(pack, name):
    s = json.load(open(os.path.join(ROOT, 'gamedata', pack, 'shapes', name + '.json')))
    W = node_worlds(s)
    k = mpu(pack)
    out = []
    for pc in s['lods'][0]['pieces']:
        if int(pc.get('state', 0)) != 0 or (s.get('units') != 'metres' and int(pc.get('id', 0)) in MARKER_IDS):
            continue
        R, T = W.get(pc['node'], (np.eye(3), np.zeros(3)))
        for p in pc['polys']:
            out.append((np.array(p['v'], float) @ R.T + T) * k)
    return out, k


def main(argv):
    out, items = argv[0], argv[1:]
    import matplotlib; matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    fig, ax = plt.subplots(figsize=(14, 6))
    x0 = 0.0
    hmax = 0.0
    for it in items:
        pack, name = it.split(':')
        P, k = shape_polys(pack, name)
        allv = np.concatenate(P)
        zmin = allv[:, 2].min()
        xmin, xmax = allv[:, 0].min(), allv[:, 0].max()
        segs = [np.c_[p[:, 0] - xmin + x0, p[:, 2] - zmin] for p in P]
        ax.add_collection(PolyCollection(segs, facecolors=(0.35, 0.4, 0.5, 0.35), edgecolors=(0, 0, 0, 0.3), linewidths=0.3))
        h = allv[:, 2].max() - zmin
        hmax = max(hmax, h)
        ax.text(x0 + (xmax - xmin) / 2, h + 0.3, '%s\n%s\n%.2f m' % (pack, name, h), ha='center', fontsize=9)
        print('%-8s %-10s metres/unit %.6f  height %.2f m  width %.2f m' % (pack, name, k, h, xmax - xmin))
        x0 += (xmax - xmin) + 1.5
    ax.set_xlim(-1, x0); ax.set_ylim(0, hmax + 1.5); ax.set_aspect('equal')
    ax.set_ylabel('metres'); ax.set_title('Scale lineup (front view, each pack converted with its own metres_per_unit)')
    ax.grid(alpha=0.3)
    plt.tight_layout(); plt.savefig(out, dpi=80)
    print('wrote', out)


if __name__ == '__main__':
    main(sys.argv[1:])
