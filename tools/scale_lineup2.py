"""Textured scale lineup across packs (palette-index "tex" materials and truecolour "rgba" materials).

Like tools/scale_lineup.py (front view, each pack converted to metres with its own metres_per_unit from
units.json, else pack.json unit_scale/256), but every polygon is coloured from its texture at the UV
centroid (rgba: shape.materials[index].texture or textures/<texset>.json[index].path; tex: palette-index
PNG + palette JSON) and lit, drawn back-to-front.  With --views it renders 3 views of one shape instead.

Usage: python tools/scale_lineup2.py out.png pack:SHAPE [pack:SHAPE ...]
       python tools/scale_lineup2.py out.png --views pack:SHAPE
"""
import json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from preview_gamedata import ROOT, MARKER_IDS, node_worlds

# Same precedence as game/engine/packs.gd metres_per_unit(): pack.json world_metres_per_unit, then the
# WORLD_SCALE policy table, then units.json metres_per_unit (starsiege / tribes2 are not in WORLD_SCALE yet:
# their units.json say 1.0, which is what WORLD_SCALE should list for them).
WORLD_SCALE = {'es1': 1.0 / 256.0, 'es2': 1.0 / 256.0, 'bd': 0.00215, 'tribes': 1.0, 'starsiege': 1.0, 'tribes2': 1.0}


def mpu(pack):
    pj = os.path.join(ROOT, 'gamedata', pack, 'pack.json')
    meta = json.load(open(pj)) if os.path.exists(pj) else {}
    if 'world_metres_per_unit' in meta:
        return float(meta['world_metres_per_unit'])
    if pack in WORLD_SCALE:
        return WORLD_SCALE[pack]
    u = os.path.join(ROOT, 'gamedata', pack, 'units.json')
    if os.path.exists(u):
        return json.load(open(u))['metres_per_unit']
    return meta.get('unit_scale', 1.0) / 256.0


def load(pack, rel):
    with open(os.path.join(ROOT, 'gamedata', pack, rel)) as f:
        return json.load(f)


def shape_polys(pack, name):
    from PIL import Image
    s = load(pack, 'shapes/%s.json' % name)
    k = mpu(pack)
    W = node_worlds(s)
    packj = load(pack, 'pack.json')
    pal = None
    if packj.get('default_palette') and os.path.exists(os.path.join(ROOT, 'gamedata', pack, 'palettes', packj['default_palette'] + '.json')):
        pal = np.array(load(pack, 'palettes/%s.json' % packj['default_palette']), float) / 255.0
    meta = load(pack, 'textures/%s.json' % s['texset']) if s.get('texset') and os.path.exists(
        os.path.join(ROOT, 'gamedata', pack, 'textures', s['texset'] + '.json')) else []
    cache = {}

    def tex(kind, i):
        key = (kind, i)
        if key in cache:
            return cache[key]
        val = None
        if kind == 'rgba':
            rel = None
            if s.get('materials') and i < len(s['materials']):
                rel = s['materials'][i].get('texture')
            if not rel and i < len(meta):
                rel = meta[i].get('path')
            if rel:
                val = ('rgba', np.array(Image.open(os.path.join(ROOT, 'gamedata', pack, *rel.split('/'))).convert('RGB'), float) / 255.0)
        else:
            p = os.path.join(ROOT, 'gamedata', pack, 'textures', s.get('texset', ''), '%d.png' % i)
            if os.path.exists(p):
                tp = pal
                if i < len(meta) and meta[i].get('palette'):
                    tp = np.array(load(pack, 'palettes/%s.json' % meta[i]['palette']), float) / 255.0
                if tp is not None:
                    val = ('idx', np.array(Image.open(p)), tp)
        cache[key] = val
        return val

    def colour(p):
        m = p['m']
        if m['kind'] in ('tex', 'rgba'):
            t = tex(m['kind'], int(m['index']))
            if t is None:
                if m['kind'] == 'tex' and meta and int(m['index']) < len(meta) and meta[int(m['index'])].get('rgb'):
                    return np.array(meta[int(m['index'])]['rgb'], float) / 255.0
                return np.array([0.55, 0.55, 0.6])
            img = t[1]
            if 'uv' in p:
                u = sum(c[0] for c in p['uv']) / 3.0 % 1.0
                v = sum(c[1] for c in p['uv']) / 3.0 % 1.0
                x, y = int(u * img.shape[1]), int(v * img.shape[0])
                c = img[y, x]
            else:
                c = img[img.shape[0] // 2, img.shape[1] // 2]
            return c if t[0] == 'rgba' else t[2][int(c)]
        if m['kind'] == 'solid' and pal is not None:
            return pal[int(m['index']) & 255]
        return np.array([0.55, 0.55, 0.6])

    light = np.array([0.3, -0.7, 0.6]); light /= np.linalg.norm(light)
    out = []
    for pc in s['lods'][0]['pieces']:
        if int(pc.get('state', 0)) != 0 or (s.get('units') != 'metres' and int(pc.get('id', 0)) in MARKER_IDS):
            continue
        R, T = W.get(pc['node'], (np.eye(3), np.zeros(3)))
        for p in pc['polys']:
            V = (np.array(p['v'], float) @ R.T + T) * k
            n = R @ np.array(p['n'], float)
            shade = 0.4 + 0.6 * abs(float(n @ light))
            out.append((V, np.clip(np.asarray(colour(p))[:3] * shade, 0, 1)))
    return out, k


def lineup(out, items):
    import matplotlib; matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    fig, ax = plt.subplots(figsize=(20, 7))
    x0, hmax = 0.0, 0.0
    for it in items:
        pack, name = it.split(':')
        P, k = shape_polys(pack, name)
        allv = np.concatenate([p for p, _ in P])
        zmin = allv[:, 2].min()
        xmin, xmax = allv[:, 0].min(), allv[:, 0].max()
        P.sort(key=lambda pc: -pc[0][:, 1].mean())   # far (+y) first; we look from -y
        ax.add_collection(PolyCollection([np.c_[p[:, 0] - xmin + x0, p[:, 2] - zmin] for p, _ in P],
                                         facecolors=[c for _, c in P], edgecolors='none'))
        h = allv[:, 2].max() - zmin
        hmax = max(hmax, h)
        ax.text(x0 + (xmax - xmin) / 2, h + 0.3, '%s\n%s\n%.2f m' % (pack, name, h), ha='center', fontsize=8)
        print('%-10s %-22s metres/unit %.6f  height %.2f m  width %.2f m  length %.2f m' % (
            pack, name, k, h, xmax - xmin, allv[:, 1].max() - allv[:, 1].min()))
        x0 += (xmax - xmin) + 1.5
    ax.set_xlim(-1, x0); ax.set_ylim(0, hmax + 2); ax.set_aspect('equal')
    ax.set_ylabel('metres'); ax.grid(alpha=0.3)
    ax.set_title('Scale lineup, front view (packs.gd WORLD_SCALE policy: es1/es2 1/256, bd 0.00215, tribes/starsiege/tribes2 1.0 m per unit)')
    plt.tight_layout(); plt.savefig(out, dpi=90)
    print('wrote', out)


def views(out, item):
    import matplotlib; matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    pack, name = item.split(':')
    P, k = shape_polys(pack, name)
    allv = np.concatenate([p for p, _ in P])
    mn, mx = allv.min(0), allv.max(0)
    fig, axs = plt.subplots(1, 3, figsize=(16, 6))
    # (horizontal axis, vertical axis, depth axis, depth sign, title)
    for ax, (hx, vy, dz, sg, title) in zip(axs, [(0, 2, 1, 1, 'front (from -y)'), (1, 2, 0, -1, 'side (from +x)'),
                                                 (0, 1, 2, -1, 'top (from +z)')]):
        order = sorted(P, key=lambda pc: -sg * pc[0][:, dz].mean())
        ax.add_collection(PolyCollection([p[:, [hx, vy]] for p, _ in order], facecolors=[c for _, c in order],
                                         edgecolors=(0, 0, 0, 0.15), linewidths=0.2))
        ax.set_xlim(mn[hx] - 0.5, mx[hx] + 0.5); ax.set_ylim(mn[vy] - 0.5, mx[vy] + 0.5)
        ax.set_aspect('equal'); ax.set_title(title); ax.grid(alpha=0.3)
    fig.suptitle('%s:%s  extents %.2f x %.2f x %.2f m (x, y, z)' % (pack, name, *(mx - mn)))
    plt.tight_layout(); plt.savefig(out, dpi=80)
    print('wrote', out, 'extents', mx - mn)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[1] == '--views':
        views(a[0], a[2])
    else:
        lineup(a[0], a[1:])
