"""Earthsiege 1 / Earthsiege 2 worlds as arena maps for deathmatch and team deathmatch (docs/formats/game_modes.md
section 4). Neither game had multiplayer, so the spawn areas are generated here (the remake's own rule, no original
data copied): from the already exported worlds, zones and heightmaps of the user's discs.

Per map:
  * free-for-all points: FFA_POINTS starts spread over the playable area by farthest-point sampling (each at least
    FFA_MIN_SPACING_M from the others), on walkable ground (heightmap slope check), EDGE_MARGIN_M inside the map
    bounds (the out-of-bounds kill zone stays far away) and clear of the zone's terrain features;
  * team areas: MAX_TEAMS cluster centres placed far apart (the first two are the farthest valid pair, the others
    farthest from those), each a cluster of TEAM_POINTS starts TEAM_SPACING_M apart within TEAM_RADIUS_M.
Every start is written twice, as a "herc" and an "infantry" spawn (players may start on foot); team -1 = free for
all. MapTeams.make_team_count then offers 2..4 teams, GameModes deathmatch and team deathmatch.

Earthsiege 1: the four MapPicker battlefields (terrain zone x day/dusk/night world): flat ground, bounds = the zone's
features plus a margin, at least MIN_SIDE_M a side. Earthsiege 2: every exported zone heightmap in the day world of
the first campaign theatre that uses it (script header word0 = theatre, word1 = zone; docs/formats/es2_campaign_flow.md).

Output: gamedata/<es1|es2>/maps/<id>/map.json (engine map schema plus "world": {pack, index, zone}) and
maps/_index.json.
Usage: python tools/export_es_arenas.py [es1] [es2]
"""
import glob
import json
import math
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import siege_paths as P  # noqa: E402

UNIT = 1.0 / 256.0                  # original world units -> metres
FFA_POINTS = 32                     # >= 24 players (Net.MAX_PLAYERS)
FFA_MIN_SPACING_M = 60.0
MAX_TEAMS = 4
TEAM_POINTS = 12                    # 24 players in two teams
TEAM_SPACING_M = 22.0
TEAM_RADIUS_M = 160.0
EDGE_MARGIN_M = 320.0                # BattleBounds warns at the edge: keep starts well inside
MIN_SIDE_M = 2400.0
FEATURE_CLEARANCE_M = 12.0          # beyond a terrain feature's own radius
MAX_SLOPE = 0.35                    # rise over run between neighbouring height samples (~19 degrees)
CANDIDATE_STEP_M = 20.0
ES1_TERRAINS = [("desert", "Desert", 0), ("temperate", "Temperate", 1000), ("ice", "Ice", 1100), ("urban", "Urban", 1500)]
ES1_TIMES = [("day", 0), ("dusk", 2), ("night", 4)]
ES1_WORLDS_PER_TERRAIN = 6
ES2_THEATRES = ["Urban", "Snow", "Volcanic", "Ice", "Moon"]


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


# ---------------------------------------------------------------------------------------------- ground
class FlatGround:
    """Earthsiege 1: flat ground (y = 0) with the zone's features as round obstacles."""

    def __init__(self, obstacles):
        self.obstacles = obstacles      # [(x, z, radius)]

    def height(self, x, z):
        return 0.0

    def is_walkable(self, x, z):
        return all(math.hypot(x - ox, z - oz) > r + FEATURE_CLEARANCE_M for ox, oz, r in self.obstacles)


class HeightGround:
    """Earthsiege 2: a zone heightmap (gamedata/es2/terrain/<zone>, rows = +z)."""

    def __init__(self, t, heights):
        self.t = t
        self.h = heights
        self.sq = float(t['square'])
        self.x0, self.z0 = float(t['origin'][0]), float(t['origin'][1])

    def _cell(self, x, z):
        return (x - self.x0) / self.sq, (z - self.z0) / self.sq

    def height(self, x, z):
        fx, fz = self._cell(x, z)
        rows, cols = self.h.shape
        cx, cz = min(max(int(fx), 0), cols - 2), min(max(int(fz), 0), rows - 2)
        ax, az = min(max(fx - cx, 0.0), 1.0), min(max(fz - cz, 0.0), 1.0)
        top = self.h[cz, cx] * (1 - ax) + self.h[cz, cx + 1] * ax
        bottom = self.h[cz + 1, cx] * (1 - ax) + self.h[cz + 1, cx + 1] * ax
        return float(top * (1 - az) + bottom * az)

    def is_walkable(self, x, z):
        fx, fz = self._cell(x, z)
        rows, cols = self.h.shape
        cx, cz = int(round(fx)), int(round(fz))
        if not (1 <= cx < cols - 1 and 1 <= cz < rows - 1):
            return False
        patch = self.h[cz - 1:cz + 2, cx - 1:cx + 2]
        return float(patch.max() - patch.min()) / (2.0 * self.sq) <= MAX_SLOPE


# ---------------------------------------------------------------------------------------------- placement
def make_candidates(ground, bounds, rng):
    (x0, z0), (x1, z1) = bounds['min'], bounds['max']
    out = []
    x = x0 + EDGE_MARGIN_M
    while x <= x1 - EDGE_MARGIN_M:
        z = z0 + EDGE_MARGIN_M
        while z <= z1 - EDGE_MARGIN_M:
            px, pz = x + rng.uniform(-5, 5), z + rng.uniform(-5, 5)
            if ground.is_walkable(px, pz):
                out.append((px, pz))
            z += CANDIDATE_STEP_M
        x += CANDIDATE_STEP_M
    return out


def farthest_points(candidates, n, seed_points=(), min_spacing=0.0):
    """Greedy farthest-point sampling: each pick is the candidate farthest from everything picked so far."""
    pts = np.array(candidates, float)
    picked = list(seed_points)
    dist = np.full(len(pts), np.inf)
    for p in picked:
        dist = np.minimum(dist, np.hypot(pts[:, 0] - p[0], pts[:, 1] - p[1]))
    out = []
    while len(out) < n and len(pts):
        i = int(np.argmax(dist)) if picked else len(pts) // 2
        if picked and dist[i] < min_spacing:
            break
        p = tuple(pts[i])
        out.append(p)
        picked.append(p)
        dist = np.minimum(dist, np.hypot(pts[:, 0] - p[0], pts[:, 1] - p[1]))
    return out


def make_team_centres(candidates):
    """MAX_TEAMS centres far apart: the farthest valid pair first, then farthest from those."""
    pts = np.array(candidates, float)
    hull = pts[np.argsort(pts[:, 0] + pts[:, 1])]
    ends = np.concatenate([hull[:200], hull[-200:]])
    d = np.hypot(ends[:, None, 0] - ends[None, :, 0], ends[:, None, 1] - ends[None, :, 1])
    i, j = np.unravel_index(int(np.argmax(d)), d.shape)
    first = [tuple(ends[i]), tuple(ends[j])]
    return first + farthest_points(candidates, MAX_TEAMS - 2, first)


def make_cluster(candidates, centre):
    near = [c for c in candidates if math.hypot(c[0] - centre[0], c[1] - centre[1]) <= TEAM_RADIUS_M]
    near.sort(key=lambda c: math.hypot(c[0] - centre[0], c[1] - centre[1]))
    out = []
    for c in near:
        if all(math.hypot(c[0] - o[0], c[1] - o[1]) >= TEAM_SPACING_M for o in out):
            out.append(c)
        if len(out) == TEAM_POINTS:
            break
    return out


def make_spawn(ground, p, team, centre, kind):
    yaw = math.degrees(math.atan2(-(centre[0] - p[0]), -(centre[1] - p[1])))   # -z forward: face the centre
    return {'kind': kind, 'pos': [round(p[0], 2), round(ground.height(*p), 2), round(p[1], 2)], 'yaw': round(yaw, 1),
            'team': team}


def make_spawns(ground, bounds, seed):
    rng = random.Random(seed)
    candidates = make_candidates(ground, bounds, rng)
    if len(candidates) < FFA_POINTS:
        raise ValueError('only %d walkable candidate points' % len(candidates))
    centre = ((bounds['min'][0] + bounds['max'][0]) / 2, (bounds['min'][1] + bounds['max'][1]) / 2)
    ffa = farthest_points(candidates, FFA_POINTS, min_spacing=FFA_MIN_SPACING_M)
    spawns = []
    for p in ffa:
        for kind in ('herc', 'infantry'):
            spawns.append(make_spawn(ground, p, -1, centre, kind))
    clusters = [make_cluster(candidates, c) for c in make_team_centres(candidates)]
    for team, cluster in enumerate(clusters):
        for p in cluster:
            for kind in ('herc', 'infantry'):
                spawns.append(make_spawn(ground, p, team, centre, kind))
    return spawns, {'ffa_points': len(ffa), 'team_points': [len(c) for c in clusters]}


def make_map(pack, mid, name, world, bounds, ground, notes):
    spawns, counts = make_spawns(ground, bounds, seed=mid)
    return {
        'pack': pack, 'id': mid, 'name': name, 'source': 'generated by tools/export_es_arenas.py', 'modes': [],
        'original_modes': [], 'world': world, 'bounds': bounds, 'terrain': None, 'environment': {},
        'interiors': [], 'statics': [], 'stations': [], 'spawns': spawns, 'mode_objects': [], 'mode_settings': {},
        'generated_spawns': counts,
        'notes': '; '.join(notes + ['spawns generated (no multiplayer in the original): %d free-for-all points, '
                                    'team areas %s' % (counts['ffa_points'], counts['team_points'])]),
    }


def make_bounds(xs, zs, min_side):
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    hw = max((max(xs) - min(xs)) / 2 + EDGE_MARGIN_M, min_side / 2)
    hd = max((max(zs) - min(zs)) / 2 + EDGE_MARGIN_M, min_side / 2)
    return {'min': [round(cx - hw, 1), round(cz - hd, 1)], 'max': [round(cx + hw, 1), round(cz + hd, 1)]}


# ---------------------------------------------------------------------------------------------- packs
def es1_maps():
    out = []
    for terrain_id, terrain_name, zone in ES1_TERRAINS:
        zpath = P.pack('es1', 'zones', '%d.json' % zone)
        if not os.path.exists(zpath):
            continue
        objs = json.load(open(zpath, encoding='utf-8')).get('objects', [])
        # original (x, y) -> engine (x, -y), metres
        obstacles = [(o['pos'][0] * UNIT, -o['pos'][1] * UNIT, o.get('radius', 0) * UNIT) for o in objs]
        xs = [o[0] for o in obstacles] or [0.0]
        zs = [o[1] for o in obstacles] or [0.0]
        bounds = make_bounds(xs, zs, MIN_SIDE_M)
        ground = FlatGround(obstacles)
        t = [i for i, e in enumerate(ES1_TERRAINS) if e[0] == terrain_id][0]
        for time_id, offset in ES1_TIMES:
            mid = '%s_%s' % (terrain_id, time_id)
            world = {'pack': 'es1', 'index': t * ES1_WORLDS_PER_TERRAIN + offset, 'zone': zone}
            out.append(make_map('es1', mid, '%s - %s' % (terrain_name, time_id), world, bounds, ground,
                                ['zone %d features avoided' % zone]))
    return out


def es2_zone_theatres():
    """zone -> theatre (script header word0) of the first campaign mission on it; training missions use 1."""
    out = {}
    for f in sorted(glob.glob(P.pack('es2', 'missions', 'msn', '*.json'))):
        hdr = json.load(open(f, encoding='utf-8')).get('hdr') or []
        words = hdr[0].get('f', []) if hdr else []
        if len(words) < 2:
            continue
        mt = re.match(r'C(\d)_', os.path.basename(f))
        theatre = int(mt.group(1)) - 1 if mt else int(words[0])
        out.setdefault(int(words[1]), theatre)
    return out


def es2_maps():
    index = P.pack('es2', 'terrain', '_index.json')
    if not os.path.exists(index):
        return []
    theatres = es2_zone_theatres()
    out = []
    for e in json.load(open(index, encoding='utf-8')):
        zone = int(e['zone'])
        t = json.load(open(P.pack('es2', 'terrain', str(zone), 'terrain.json'), encoding='utf-8'))
        cols, rows = t['size']
        heights = np.fromfile(P.pack('es2', 'terrain', str(zone), 'heights.r32'), '<f4').reshape(rows, cols)
        ground = HeightGround(t, heights)
        x0, z0 = t['origin']
        ext = [(cols - 1) * t['square'], (rows - 1) * t['square']]
        bounds = {'min': [x0, z0], 'max': [x0 + ext[0], z0 + ext[1]]}
        theatre = theatres.get(zone, 0)
        world = {'pack': 'es2', 'index': theatre * 2, 'zone': zone}
        name = '%s zone %d' % (ES2_THEATRES[theatre] if theatre < len(ES2_THEATRES) else 'Zone', zone)
        try:
            out.append(make_map('es2', 'zone_%d' % zone, name, world, bounds, ground,
                                ['world %d (theatre %d, day)' % (theatre * 2, theatre)]))
        except ValueError as ex:
            print('  es2 zone %d skipped: %s' % (zone, ex))
    return out


def export(pack, maps):
    index = []
    for m in maps:
        write_json(P.pack(pack, 'maps', m['id'], 'map.json'), m)
        b = m['bounds']
        counts = {}
        for s in m['spawns']:
            counts[s['kind']] = counts.get(s['kind'], 0) + 1
        index.append({'id': m['id'], 'name': m['name'], 'modes': m['modes'], 'terrain': pack == 'es2',
                      'spawns': counts, 'size_m': [round(b['max'][0] - b['min'][0]), round(b['max'][1] - b['min'][1])],
                      'generated_spawns': m['generated_spawns'], 'mode_objects': {}})
        print('  %-14s %-24s ffa %d teams %s' % (m['id'], m['name'], m['generated_spawns']['ffa_points'],
                                                m['generated_spawns']['team_points']))
    write_json(P.pack(pack, 'maps', '_index.json'), index, indent=1)


def main():
    wanted = [a for a in sys.argv[1:] if not a.startswith('--')] or ['es1', 'es2']
    for pack in wanted:
        print(pack)
        export(pack, es1_maps() if pack == 'es1' else es2_maps())
    return 0


if __name__ == '__main__':
    sys.exit(main())
