"""Top-down preview of an exported Starsiege mission: terrain (map albedo + relief), units by team,
structures, nav markers, drop points, triggers.

Usage: python tools/preview_starsiege_mission.py HA0 [CA0 ...]   -> gamedata/starsiege/previews/mission_<ID>.png
"""
import json
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'gamedata', 'starsiege')
COL = {'yellow': (255, 230, 40), 'red': (255, 50, 40), 'blue': (60, 140, 255), 'purple': (200, 80, 255),
       'neutral': (220, 220, 220)}


def render(mid, size=1024, margin=600.0):
    m = json.load(open(os.path.join(OUT, 'missions', mid + '.json')))
    pts = [o['pos'] for o in m['objects'] if 'pos' in o] + [d['pos'] for d in m['drop_points']]
    xs = [p[0] for p in pts]
    zs = [p[2] for p in pts]
    x0, x1 = min(xs) - margin, max(xs) + margin
    z0, z1 = min(zs) - margin, max(zs) + margin
    span = max(x1 - x0, z1 - z0)
    x1, z1 = x0 + span, z0 + span
    img = Image.new('RGB', (size, size), (40, 40, 40))
    mp = json.load(open(os.path.join(OUT, 'maps', mid, 'map.json')))
    t = mp.get('terrain')
    if t:
        d = os.path.join(OUT, 'maps', mid)
        w, h = t['size']
        H = np.fromfile(os.path.join(d, t['heights']), dtype='<f4').reshape(h, w)
        tx0, tz0 = t['origin']
        sq = t['square']
        gx = np.linspace(x0, x1, size)
        gz = np.linspace(z0, z1, size)
        ci = np.clip(((gx - tx0) / sq).astype(int), 0, w - 1)
        ri = np.clip(((gz - tz0) / sq).astype(int), 0, h - 1)
        hh = H[ri[:, None], ci[None, :]]
        shade = np.clip(0.75 + (np.roll(hh, 1, 1) - hh) * 0.02 + (np.roll(hh, 1, 0) - hh) * 0.02, 0.35, 1.3)
        try:
            alb = Image.open(os.path.join(d, t['albedo'])).convert('RGB')
            A = np.asarray(alb).astype(float)
            ar = np.clip((ri * A.shape[0] / h).astype(int), 0, A.shape[0] - 1)
            ac = np.clip((ci * A.shape[1] / w).astype(int), 0, A.shape[1] - 1)
            rgb = A[ar[:, None], ac[None, :]]
        except OSError:
            n = (hh - hh.min()) / max(1e-3, hh.max() - hh.min())
            rgb = np.stack([n * 200 + 40] * 3, -1)
        img = Image.fromarray(np.clip(rgb * shade[..., None], 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(img)

    def P(p):
        return ((p[0] - x0) / span * size, (p[2] - z0) / span * size)

    for o in m['objects']:
        if 'pos' not in o:
            continue
        x, y = P(o['pos'])
        k = o['kind']
        if k in ('static', 'turret', 'interior'):
            c = COL.get(o.get('team') or 'neutral', (200, 200, 200)) if k != 'interior' else (150, 120, 90)
            r = 5 if k == 'interior' else 3
            dr.rectangle([x - r, y - r, x + r, y + r], outline=c)
        elif k in ('herc', 'tank', 'flyer'):
            c = COL.get(o.get('team'), (255, 255, 255))
            r = 6 if k == 'herc' else 4
            dr.ellipse([x - r, y - r, x + r, y + r], fill=c, outline=(0, 0, 0))
            dr.text((x + 7, y - 6), o['name'][:12], fill=c)
        elif k == 'nav_marker':
            dr.polygon([(x, y - 9), (x + 8, y + 6), (x - 8, y + 6)], outline=(80, 255, 120))
            dr.text((x + 9, y), o['name'], fill=(80, 255, 120))
        elif k == 'marker':
            dr.point((x, y), fill=(255, 255, 255))
        elif k == 'trigger':
            a = o['box_max'][0] / span * size
            dr.rectangle([x - a, y - a, x + a, y + a], outline=(255, 140, 0))
    for d in m['drop_points']:
        x, y = P(d['pos'])
        dr.ellipse([x - 9, y - 9, x + 9, y + 9], outline=(255, 255, 255), width=2)
        dr.text((x + 10, y + 4), 'DROP', fill=(255, 255, 255))
    dr.text((8, 8), '%s %s (%s)  %.0f m across' % (mid, m['title'], m['planet'], span), fill=(255, 255, 255))
    os.makedirs(os.path.join(OUT, 'previews'), exist_ok=True)
    p = os.path.join(OUT, 'previews', 'mission_%s.png' % mid)
    img.save(p)
    return p


if __name__ == '__main__':
    for a in sys.argv[1:] or ['HA0', 'CA0']:
        print(render(a.upper()))
