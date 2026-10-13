"""Flatten an Earth Siege DTS shape into posed polygon lists (for previews / export)."""
import math
import numpy as np
import dts

ANG = 2 * math.pi / 65536.0


def rot(rx, ry, rz):
    ax, ay, az = rx * ANG, ry * ANG, rz * ANG
    cx, sx, cy, sy, cz, sz = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay), math.cos(az), math.sin(az)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Rz @ Ry @ Rx


def tf_matrix(t, order='zyx'):
    m = np.eye(4)
    m[:3, :3] = rot(t[0], t[1], t[2])
    m[:3, 3] = t[3:6]
    return m


def node_globals(anim, tf_index_for_node):
    rel = {d: p for p, d in anim['relations']}
    n = len(anim['default_transforms'])
    cache = {}

    def g(i):
        if i in cache:
            return cache[i]
        local = tf_matrix(anim['transforms'][tf_index_for_node(i)])
        p = rel.get(i, -1)
        m = local if p < 0 else g(p) @ local
        cache[i] = m
        return m
    return [g(i) for i in range(n)]


def collect(o, out, state=0):
    """Yield (node, group, poly) for the visible geometry; cell anim parts pick `state` child."""
    if o['type'] in ('group', 'bsp_group'):
        for it in o['items']:
            if 'vlist' in it:
                out.append((o['transform'], o, it))
        return
    kids = o.get('parts', [])
    if o['type'] == 'cell_anim_part' and kids:
        kids = [kids[min(state, len(kids) - 1)]]
    elif o['type'] == 'detail_part' and kids:
        kids = kids[:1]
    for c in kids:
        collect(c, out, state)


def posed_polys(shape, anim, state=0):
    mats = node_globals(anim, lambda i: anim['default_transforms'][i])
    items = []
    collect(shape, items, state)
    res = []
    for node, grp, poly in items:
        m = mats[node] if 0 <= node < len(mats) else np.eye(4)
        idx = grp['indexes'][poly['vlist']:poly['vlist'] + poly['vcount']]
        pts = [(m @ np.array([*grp['points'][i], 1.0]))[:3] for i in idx]
        res.append((node, grp, poly, pts))
    return res
