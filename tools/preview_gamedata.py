"""Render a converted gamedata shape JSON (any pack) with matplotlib, the way ShapeInstance builds it.

Node transforms: [rx, ry, rz (1/65536 turn), tx, ty, tz], R = Rz*Ry*Rx (ES axes: x right, y forward,
z up), node world = parent world * local.  Poly colours:
  tex + uv  -> texture sampled at the UV centroid (palette-index PNG + palette JSON)
  tex       -> mean colour of the texture
  solid     -> palette[index]
  shade     -> grey
then lit with a fixed light by the poly normal.  Also prints the posed extents in metres.

Usage: python tools/preview_gamedata.py <pack> <shape> [out.png] [--lod N] [--palette NAME]
"""
import json, math, os, sys
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MARKER_IDS = (8, 9, 10, 11, 18, 66, 77)   # ShapeInstance.MARKER_IDS
UNDRAWN_POLY_TYPE = 'poly'                 # ShapeInstance.UNDRAWN_POLY_TYPE: colourless TSPoly, never drawn


def euler(t):
    k = 2 * math.pi / 65536.0
    a, b, c = t[0] * k, t[1] * k, t[2] * k
    Rx = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
    Ry = np.array([[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]])
    Rz = np.array([[math.cos(c), -math.sin(c), 0], [math.sin(c), math.cos(c), 0], [0, 0, 1]])
    return Rz @ Ry @ Rx, np.array(t[3:6], dtype=float)


def node_worlds(shape):
    nodes, tfs = shape.get('nodes', []), shape.get('transforms', [])
    out = {}

    def get(i):
        if i in out:
            return out[i]
        R, T = euler(tfs[nodes[i]['default']])
        p = nodes[i]['parent']
        if 0 <= p < len(nodes) and p != i:
            PR, PT = get(p)
            out[i] = (PR @ R, PT + PR @ T)
        else:
            out[i] = (R, T)
        return out[i]

    for i in range(len(nodes)):
        get(i)
    return out


def load(pack, rel):
    with open(os.path.join(ROOT, 'gamedata', pack, rel)) as f:
        return json.load(f)


def main(argv):
    pack, name = argv[0], argv[1]
    out = argv[2] if len(argv) > 2 and not argv[2].startswith('--') else os.path.join(ROOT, 'gamedata', pack, 'previews', name + '.png')
    lod = int(argv[argv.index('--lod') + 1]) if '--lod' in argv else 0
    shape = load(pack, 'shapes/%s.json' % name)
    packj = load(pack, 'pack.json')
    units = load(pack, 'units.json') if os.path.exists(os.path.join(ROOT, 'gamedata', pack, 'units.json')) else {}
    mpu = units.get('metres_per_unit', 1.0)
    palname = argv[argv.index('--palette') + 1] if '--palette' in argv else packj.get('default_palette')
    pal = np.array(load(pack, 'palettes/%s.json' % palname), dtype=float) / 255.0

    from PIL import Image
    texcache = {}
    texmeta = load(pack, 'textures/%s.json' % shape['texset']) if shape.get('texset') else []

    def tex(i):
        if i not in texcache:
            p = os.path.join(ROOT, 'gamedata', pack, 'textures', shape['texset'], '%d.png' % i)
            if not os.path.exists(p):
                texcache[i] = None
            else:
                tp = pal
                if i < len(texmeta) and texmeta[i].get('palette'):
                    tp = np.array(load(pack, 'palettes/%s.json' % texmeta[i]['palette']), dtype=float) / 255.0
                idx = np.array(Image.open(p))
                texcache[i] = (idx, tp)
        return texcache[i]

    def colour(poly):
        m = poly['m']
        if m['kind'] == 'tex':
            t = tex(int(m['index']))
            if t is None:
                return np.array([0.8, 0.2, 0.8])
            idx, tp = t
            if 'uv' in poly:
                u = sum(c[0] for c in poly['uv']) / len(poly['uv'])
                v = sum(c[1] for c in poly['uv']) / len(poly['uv'])
                x = int(min(max(u, 0), 0.9999) * idx.shape[1]); y = int(min(max(v, 0), 0.9999) * idx.shape[0])
                return tp[idx[y, x]]
            nz = idx[idx != 0]
            return tp[nz].mean(0) if nz.size else np.array([0.5, 0.5, 0.5])
        if m['kind'] == 'solid':
            return pal[int(m['index']) & 255]
        return np.array([0.6, 0.6, 0.62])

    W = node_worlds(shape)
    light = np.array([0.4, -0.6, 0.7]); light /= np.linalg.norm(light)
    polys, cols = [], []
    for pc in shape['lods'][lod]['pieces']:
        # like ShapeInstance: only the intact cell state, no invisible locator parts (3Space packs)
        if int(pc.get('state', 0)) != 0 or (shape.get('units') != 'metres' and int(pc.get('id', 0)) in MARKER_IDS):
            continue
        R, T = W.get(pc['node'], (np.eye(3), np.zeros(3)))
        for p in pc['polys']:
            if p.get('t') == UNDRAWN_POLY_TYPE:
                continue
            V = np.array(p['v'], dtype=float) @ R.T + T
            n = R @ np.array(p['n'], dtype=float)
            shade = 0.45 + 0.55 * abs(float(n @ light))
            polys.append(V * mpu)
            cols.append(np.clip(colour(p) * shade, 0, 1))
    allv = np.concatenate(polys)
    mn, mx = allv.min(0), allv.max(0)
    print('%s:%s lod %d  polys %d  extents (m) x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f  height %.2f m' % (
        pack, name, lod, len(polys), mn[0], mx[0], mn[1], mx[1], mn[2], mx[2], mx[2] - mn[2]))

    import matplotlib; matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    c = (mn + mx) / 2; r = (mx - mn).max() / 2
    fig = plt.figure(figsize=(15, 5.5))
    for k, (el, az, title) in enumerate([(5, -90, 'front (-y)'), (5, 0, 'side (+x)'), (25, -60, '3/4')]):
        ax = fig.add_subplot(1, 3, k + 1, projection='3d')
        ax.add_collection3d(Poly3DCollection(polys, facecolors=cols, edgecolors=(0, 0, 0, 0.15), linewidths=0.2))
        ax.set_xlim(c[0] - r, c[0] + r); ax.set_ylim(c[1] - r, c[1] + r); ax.set_zlim(c[2] - r, c[2] + r)
        ax.view_init(el, az); ax.set_title(title); ax.set_xlabel('x m'); ax.set_ylabel('y m'); ax.set_zlabel('z m')
    fig.suptitle('%s:%s  LOD %d  height %.2f m' % (pack, name, lod, mx[2] - mn[2]))
    plt.tight_layout()
    os.makedirs(os.path.dirname(out), exist_ok=True)
    plt.savefig(out, dpi=80)
    print('wrote', out)


if __name__ == '__main__':
    main(sys.argv[1:])
