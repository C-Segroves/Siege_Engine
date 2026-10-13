"""Earthsiege mission files: MSN (compiled mission script), ENG (mission texts),
script.dat (what the shell hands to the sim), campaign battle sets.

Format spec: docs/formats/mission.md.  Everything here was derived from
GO.EXE (shell, mission compiler at 0x3276c, script.dat writer at 0x3445b) and
DBSIM.EXE (script.dat reader 0x1d850 / 0x1e638).

CLI:
  python tools/mission.py json  <MSN name|path> [--seed N] [--var i=v ...] [-o out.json]
  python tools/mission.py all   [--out out/missions]      # every MSN -> JSON (+ sanity report)
  python tools/mission.py plot  <MSN name> [-o out.png]   # positions / paths / regions
  python tools/mission.py campaign                          # battle-set / campaign tree
  python tools/mission.py tape  <TAP file>                  # dump script.dat embedded in a demo tape
  python tools/mission.py script <MSN name> -o script.dat   # compile like the shell does
"""
import argparse, glob, json, os, random, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
ROOT = P.WORK        # source tree; see tools/siege_paths.py
MSN_DIR = os.path.join(ROOT, 'extracted', 'ZONES', 'MSN')
BST_DIR = os.path.join(ROOT, 'extracted', 'ZONES', 'BST')

# ---------------------------------------------------------------------------
# enums / names
HERC_TYPES = ['ROADRUNNER', 'GUNSLINGER', 'RAPTOR', 'TOMAHAWK', 'PATRIOT', 'PANTHER', 'HERCULES',
              'COLOSSUS', 'MONGOOSE', 'SCORPION', 'MIRIMAC', 'RAMSES', 'ACHILLES', 'APOLLO',
              'BULLDOG', 'SPIDER']            # SIMVOL0/NAM/MECHS.NAM  (objA.type)
FLYER_TYPES = ['SKIMMER', 'HOVTANK']          # SIMVOL0/NAM/FLYERS.NAM (objB.type)
COND_OPS = {0x114: '==', 0x115: '!=', 0x116: '<', 0x117: '>'}
GROUP_KINDS = {0: 'herc', 1: 'flyer', 2: 'structure'}
TARGET_KINDS = {0: 'group', 1: 'herc', 2: 'flyer', 3: 'structure'}
# group.orders (MSN group +0x32) -> initial AI state (DBSIM 0x1892c table 0x91d14 for hercs,
# 0x1c46c table 0x92084 for flyers).  Values not listed leave the default state.
HERC_ORDERS = {1: 'search/destroy', 3: 'ramming', 6: 'guarding', 7: 'patrolling', 8: 'patrolling',
               10: 'sleeping', 11: 'travelling'}
FLYER_ORDERS = {1: 'search and destroy', 6: 'sleeping', 7: 'scouting', 8: 'patrolling',
                10: 'sleeping', 11: 'scouting'}
# mission-variable actions on unit/group death (DBSIM 0xd77c table 0x91640, 0x1d524 table 0x9222c)
DEATH_OPS = {1: 'var=0', 2: 'var+=1', 13: 'var=1', 14: 'var=2', 15: 'var=3', 16: 'var=4'}
# mission-variable actions when a region (trigger) fires (DBSIM 0x1cc5c)
REGION_OPS = {5: 'var=0', 6: 'var+=1'}
# region.type (DBSIM 0x1f87c switch table 0x923c0): who has to be inside one of the areas
REGION_TYPES = {0: 'player', 1: 'player squad', 2: 'any human-side unit', 3: 'any cybrid-side unit',
                4: 'any herc', 5: 'any flyer'}
# header.mission_type (script header word 3) -> DBSIM 0xf4e8 win test (table 0x9173c)
MISSION_TYPES = {0: 'flag 0x8c+0xd (special objective flag)', 1: 'player group reached end of its path',
                 2: 'player group reached end of its path', 3: 'flag 0x8c+0xe (special objective flag)',
                 4: 'target group check (0xf99a)', 5: 'target group check (0xf99a)',
                 6: 'target group status == 4 (0xee84)', 7: 'escort: target reached end of path && 0xf99a',
                 8: 'target group status == 4 (0xee84)', 9: 'target group status == 4 (0xee84)'}

# ---------------------------------------------------------------------------
# MSN layout (version 5).  Record sizes from GO.EXE 0x3276c.
V5_SIZES = dict(cond=14, hdr=22, point=22, heading=10, area=12, region=30,
                herc=106, flyer=64, struct=24, group=88)
LEGACY_SIZES = dict(V5_SIZES, herc=88)   # B0_C1_20 / B0_C1_30: no header section, fixed hdr, short herc


def _w(b, o):
    return struct.unpack_from('<h', b, o)[0]


def _ws(b, o, n):
    return list(struct.unpack_from('<%dh' % n, b, o))


def _i(b, o):
    return struct.unpack_from('<i', b, o)[0]


class Reader:
    def __init__(self, d, o=0):
        self.d, self.o = d, o

    def h(self):
        v = _w(self.d, self.o); self.o += 2; return v

    def take(self, n):
        if self.o + n > len(self.d):
            raise ValueError('truncated at 0x%x (+%d)' % (self.o, n))
        b = self.d[self.o:self.o + n]; self.o += n; return b


def dec_cond(b):
    w = _ws(b, 0, 7)
    return dict(id=w[0], parent=w[1], kind=w[2], a=w[3], b=w[4], c=w[5], d=w[6])


def dec_hdr(b):
    w = _ws(b, 0, 11)
    return dict(cond=w[0], f=w[1:])


def dec_point(b):
    w = _ws(b, 0, 5)
    return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], rel=w[4], x=_i(b, 10), y=_i(b, 14), z=_i(b, 18))


def dec_heading(b):
    w = _ws(b, 0, 5)
    return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], value=w[4])


def dec_area(b):
    w = _ws(b, 0, 6)
    return dict(id=w[0], cond=w[1], pick=w[2], kind=w[3], p1=w[4], p2=w[5])


def dec_region(b):
    w = _ws(b, 0, 15)
    return dict(id=w[0], cond=w[1], pick=w[2], type=w[3], param=w[4], areas=w[5:13], var=w[13], op=w[14])


def dec_herc(b, legacy=False):
    w = _ws(b, 0, len(b) // 2)
    r = dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], block=w[4:24], type=w[24], weapons=w[25:35],
             point=w[35], heading=w[36], var=w[37], op=w[38])
    if legacy:   # 88 bytes: ... +0x4e u4e, +0x50 f62, regions, health
        r.update(ammo=[5] * 10, u4e=w[39], f62=w[40], alert_region=w[41], death_region=w[42], health=w[43])
    else:
        r.update(ammo=w[39:49], f62=w[49], alert_region=w[50], death_region=w[51], health=w[52])
    return r


def dec_flyer(b):
    w = _ws(b, 0, 32)
    return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], block=w[4:24], point=w[24], heading=w[25],
                type=w[26], var=w[27], op=w[28], alert_region=w[29], death_region=w[30], health=w[31])


def dec_struct(b):
    w = _ws(b, 0, 12)
    return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], type=w[4], point=w[5], heading=w[6], var=w[7],
                op=w[8], alert_region=w[9], death_region=w[10], health=w[11])


def dec_group(b):
    w = _ws(b, 0, 44)
    return dict(id=w[0], cond=w[1], u4=w[2], block=w[3:23], kind=w[23], formation=w[24], orders=w[25],
                point=w[26], heading=w[27], path=w[28], members=w[29:37], team=w[37], target_kind=w[38],
                target=w[39], spawn_region=w[40], u52=w[41], var=w[42], op=w[43])


def parse_msn(data):
    """Parse an MSN file into raw (unevaluated) record lists."""
    r = Reader(data)
    ver = r.h()
    if ver != 5:
        raise ValueError('MC version %d (expected 5)' % ver)
    try:
        return _parse_body(data, legacy=False)
    except ValueError:
        return _parse_body(data, legacy=True)


def _parse_body(data, legacy):
    r = Reader(data, 2)
    sz = LEGACY_SIZES if legacy else V5_SIZES
    m = dict(version=5, legacy=legacy)
    if legacy:
        m['fixed_header'] = _ws(r.take(20), 0, 10)

    def sect(name, dec):
        n = r.h()
        if n < 0 or n > 5000:
            raise ValueError('bad count %d for %s' % (n, name))
        m[name] = [dec(r.take(sz[name])) for _ in range(n)]

    sect('cond', dec_cond)
    if legacy:
        m['hdr'] = []
    else:
        sect('hdr', dec_hdr)
    sect('point', dec_point)
    sect('heading', dec_heading)
    n = r.h()
    paths = []
    for _ in range(n):
        w = _ws(r.take(10), 0, 5)
        pts = _ws(r.take(2 * w[4]), 0, w[4]) if w[4] > 0 else []
        paths.append(dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], points=pts))
    m['path'] = paths
    sect('area', dec_area)
    sect('region', dec_region)
    n = r.h()
    m['herc'] = [dec_herc(r.take(sz['herc']), legacy) for _ in range(n)]
    sect('flyer', dec_flyer)
    sect('struct', dec_struct)
    sect('group', dec_group)
    if r.o != len(data):
        raise ValueError('%d trailing bytes' % (len(data) - r.o))
    return m


# ---------------------------------------------------------------------------
# Shell mission compiler emulation (GO.EXE 0x3276c).  Produces the script.dat
# content: conditions evaluated against mission.var, random picks rolled,
# overrides merged and id references turned into script indices.

class Rng:
    """Policy for the shell's random(n) (GO 0x38774).  seed=None -> always 0."""

    def __init__(self, seed=None):
        self.r = random.Random(seed) if seed is not None else None

    def __call__(self, n):
        if n <= 0:
            return 0
        return self.r.randrange(n) if self.r else 0


CAMPAIGN_TERRAIN = [1, 2, 2, 0, 0, 3, 3, 3]          # GO table 0x80f14 (campaign index -> terrain)
DEFAULT_OPTIONS = dict(ammo=1, damage=1, difficulty=2, visibility=0, time_of_day=0)   # values seen in demo tapes


def default_mission_vars(campaign=None, slot=0, options=None, rng=None):
    """mission.var as the shell prepares it before compiling (GO 0x359d9..0x35a9f):
    campaign mode: var1 = campaign index, var2 = mission slot (from the pilot record);
    single mode:   all zero, var1 = 99;
    both:          var3 = time-of-day option (aacc4), var4..var6 = random(12)."""
    rng = rng or Rng(None)
    opts = dict(DEFAULT_OPTIONS, **(options or {}))
    v = [0] * 100
    if campaign is not None:
        v[1], v[2] = campaign, slot
    else:
        v[1] = 99
    v[3] = opts['time_of_day']
    v[4], v[5], v[6] = rng(12), rng(12), rng(12)
    return v


class Compiler:
    def __init__(self, msn, mvars=None, rng=None, campaign=None, options=None):
        self.m = msn
        self.rng = rng or Rng(None)
        self.campaign = campaign
        self.mode = 1 if campaign is not None else 0   # header word 2: 1 = campaign, 0 = single mission
        self.options = dict(DEFAULT_OPTIONS, **(options or {}))
        self.vars = list(mvars) if mvars is not None else default_mission_vars(campaign, 0, options, self.rng)
        self.log = []

    # -- conditions
    def run(self):
        K = []      # kept conds
        for c in self.m['cond']:
            c = dict(c)
            k = c['kind']
            if k == 0:
                if self.cond_ok(c['parent'], K):
                    v = self.vars[c['a']] if 0 <= c['a'] < 100 else 0
                    op = c['b']
                    res = {0x114: v == c['c'], 0x115: v != c['c'], 0x116: v < c['c'], 0x117: v > c['c']}.get(op, False)
                    if res:
                        K.append(c)
            elif k == 1:
                if self.cond_ok(c['parent'], K):
                    c['b'] = self.rng(c['a'])
                    K.append(c)
            elif k == 2:
                v = -1
                for p in K:
                    if p['id'] == c['parent']:
                        if p['kind'] == 1:
                            v = p['b']; break
                        if p['kind'] == 3:
                            v = -99; break
                if v == -99 or (c['a'] & 0xffff) <= v <= (c['b'] & 0xffff):
                    K.append(c)
            elif k == 3:
                if self.cond_ok(c['parent'], K):
                    K.append(c)
        self.K = K
        self.do_header()
        self.do_points()
        self.do_headings()
        self.do_paths()
        self.do_areas()
        self.do_regions()
        self.do_hercs()
        self.do_flyers()
        self.do_structs()
        self.do_groups()
        self.finish_header()
        return self

    def cond_ok(self, cid, K=None):
        if cid == -1:
            return True
        return any(c['id'] == cid for c in (self.K if K is None else K))

    def pick_case(self, key):
        """GO 0x318d5: roll a type-3 'pick' cond with c-key `key`; return the chosen case id."""
        for c in self.K:
            if c['kind'] == 3 and c['a'] == key:
                roll = self.rng(c['c'])
                for k in self.K:
                    if k['kind'] == 2 and k['parent'] == c['id'] and (k['a'] & 0xffff) <= roll <= (k['b'] & 0xffff):
                        return k['id']
                self.log.append('pick %d: no case for roll %d' % (key, roll))
                return None
        self.log.append('pick key %d not found' % key)
        return None

    def pick_rec(self, arr, n, key):
        case = self.pick_case(key)
        if case is None:
            return None
        for i in range(n):
            if arr[i]['cond'] == case:
                return i
        self.log.append('pick key %d case %d: no record' % (key, case))
        return None

    @staticmethod
    def sidx(arr, n, rid):
        """script index of id (records with id -1 are skipped): GO 0x313f1 & friends."""
        if rid == -1:
            return -1
        k = 0
        for i in range(n):
            if arr[i]['id'] == -1:
                continue
            if arr[i]['id'] == rid:
                return k
            k += 1
        return -1

    @staticmethod
    def aidx(arr, n, rid):
        """array index of id (flag 0 of GO 0x31711 etc.)"""
        if rid == -1:
            return -1
        for i in range(n):
            if arr[i]['id'] == rid:
                return i
        return -1

    def _store(self, arr, rec, dup):
        if dup is not None and dup != -1 and dup < len(arr):
            arr[dup] = rec
        else:
            arr.append(rec)

    def do_header(self):
        f = [1] + [0] * 9
        for h in self.m['hdr']:
            if self.cond_ok(h['cond']):
                v = h['f']
                if v[0] != 1:
                    f[0] = v[0]
                for i in range(1, 10):
                    if v[i] != 0:
                        f[i] = v[i]
        if self.m.get('legacy'):
            f = list(self.m['fixed_header'])
        self.msn_header = list(f)
        self.header = f

    def finish_header(self):
        f = self.header
        # GO 0x35ad1: shell overrides after compiling
        if self.mode == 1:
            f[5], f[6], f[7] = 0, 0, 2            # ammo, damage, difficulty fixed in the campaign
            c = self.campaign
            f[0] = CAMPAIGN_TERRAIN[c] if 0 <= c < 8 else f[0]
        else:
            o = self.options
            f[5], f[6], f[7], f[8], f[9] = o['ammo'], o['damage'], o['difficulty'], o['visibility'], o['time_of_day']
            f[0] = self.rng(4)                    # random terrain for single missions
        f[2] = self.mode     # GO 0x3445b writes aad56 (1 campaign / 0 single) as word 2
        self.header = f

    def do_points(self):
        P = []
        for p in self.m['point']:
            p = dict(p)
            if not self.cond_ok(p['cond']):
                continue
            n = len(P)
            if p['pick'] != -1:
                j = self.pick_rec(P, n, p['pick'])
                if j is not None:
                    p['x'], p['y'], p['z'] = P[j]['x'], P[j]['y'], P[j]['z']
            if p['rel']:
                a = self.sidx(P, n, p['x']); b = self.sidx(P, n, p['y'])
                if a < 0 or b < 0:
                    self.log.append('point %d: bad rel refs' % p['id'])
                else:
                    p['x'] = P[a]['x'] + P[b]['x']; p['y'] = P[a]['y'] + P[b]['y']; p['z'] = P[a]['z'] + P[b]['z']
            self._store(P, p, self.sidx(P, n, p['id']))
        self.P = P

    def do_headings(self):
        H = []
        for h in self.m['heading']:
            h = dict(h)
            if not self.cond_ok(h['cond']):
                continue
            n = len(H)
            if h['pick'] != -1:
                j = self.pick_rec(H, n, h['pick'])
                if j is not None:
                    h['value'] = H[j]['value']
            self._store(H, h, self.sidx(H, n, h['id']))
        self.H = H

    def do_paths(self):
        T = []
        np_ = len(self.P)
        for t in self.m['path']:
            t = dict(t)
            t['idx'] = [self.sidx(self.P, np_, i) for i in t['points']]
            if not self.cond_ok(t['cond']):
                continue
            n = len(T)
            if t['pick'] != -1:
                j = self.pick_rec(T, n, t['pick'])
                if j is not None:
                    t['idx'] = list(T[j]['idx'])
            self._store(T, t, self.sidx(T, n, t['id']))
        self.T = T

    def do_areas(self):
        A = []
        np_ = len(self.P)
        for a in self.m['area']:
            a = dict(a)
            if not self.cond_ok(a['cond']):
                continue
            n = len(A)
            a['p1i'] = self.sidx(self.P, np_, a['p1'])
            a['p2i'] = self.sidx(self.P, np_, a['p2']) if a['kind'] == 0 else a['p2']
            self._store(A, a, self.sidx(A, n, a['id']))
        self.A = A

    def do_regions(self):
        R = []
        na = len(self.A)
        for r in self.m['region']:
            r = dict(r)
            if not self.cond_ok(r['cond']):
                continue
            n = len(R)
            r['ai'] = [self.sidx(self.A, na, x) if x != -1 else -1 for x in r['areas']]
            dup = self.sidx(R, n, r['id'])
            if dup != -1 and dup < n:     # GO 0x31d67: patch fields that are not -1
                o = R[dup]
                for k in ('type', 'param', 'var', 'op'):
                    if r[k] != -1:
                        o[k] = r[k]
                o['ai'] = [b if b != -1 else a for a, b in zip(o['ai'], r['ai'])]
            else:
                R.append(r)
        self.R = R

    def _objs(self, src, ref_fields, copy_fields, merge):
        O = []
        for o in src:
            o = dict(o)
            if not self.cond_ok(o['cond']):
                continue
            n = len(O)
            if o['pick'] == -1:
                for f, tbl in ref_fields:
                    o[f + '_i'] = self.sidx(tbl, len(tbl), o[f])
            else:
                j = self.pick_rec(O, n, o['pick'])
                if j is not None:
                    for f in copy_fields:
                        o[f] = O[j][f]
                    for f, _ in ref_fields:
                        o[f + '_i'] = O[j][f + '_i']
                else:
                    for f, _ in ref_fields:
                        o[f + '_i'] = -1
            dup = self.aidx(O, n, o['id'])
            if dup != -1:
                merge(O[dup], o)
            else:
                O.append(o)
        return O

    @staticmethod
    def _merge(dst, src, skip_vals):
        for f, sk in skip_vals.items():
            v = src[f]
            if isinstance(v, list):
                dst[f] = [b if b != sk else a for a, b in zip(dst[f], v)]
            elif v != sk:
                dst[f] = v
                if f + '_i' in src:
                    dst[f + '_i'] = src[f + '_i']

    def do_hercs(self):
        refs = [('point', self.P), ('heading', self.H), ('alert_region', self.R), ('death_region', self.R)]
        copy = ['block', 'weapons', 'type', 'var', 'op', 'ammo', 'f62', 'health', 'point', 'heading',
                'alert_region', 'death_region']
        skip = dict(block=0, weapons=-1, ammo=5, type=-1, point=-1, heading=-1, var=-1, op=-1, f62=2,
                    alert_region=-1, death_region=-1, health=100)
        self.OA = self._objs(self.m['herc'], refs, copy, lambda d, s: self._merge(d, s, skip))

    def do_flyers(self):
        refs = [('point', self.P), ('heading', self.H), ('alert_region', self.R), ('death_region', self.R)]
        copy = ['block', 'point', 'heading', 'type', 'var', 'op', 'alert_region', 'death_region', 'health']
        skip = dict(block=0, type=-1, point=-1, heading=-1, var=-1, op=-1, alert_region=-1, death_region=-1,
                    health=100)
        self.OB = self._objs(self.m['flyer'], refs, copy, lambda d, s: self._merge(d, s, skip))

    def do_structs(self):
        refs = [('point', self.P), ('heading', self.H), ('alert_region', self.R), ('death_region', self.R)]
        copy = ['type', 'point', 'heading', 'var', 'op', 'alert_region', 'death_region', 'health']
        skip = dict(type=-1, point=-1, heading=-1, var=-1, op=-1, alert_region=-1, death_region=-1, health=100)
        self.OC = self._objs(self.m['struct'], refs, copy, lambda d, s: self._merge(d, s, skip))

    def do_groups(self):
        G = []
        tables = {0: self.OA, 1: self.OB, 2: self.OC}
        for g in self.m['group']:
            g = dict(g)
            if not self.cond_ok(g['cond']):
                continue
            n = len(G)
            g['point_i'] = self.sidx(self.P, len(self.P), g['point'])
            g['heading_i'] = self.sidx(self.H, len(self.H), g['heading'])
            g['path_i'] = self.sidx(self.T, len(self.T), g['path'])
            g['spawn_region_i'] = self.sidx(self.R, len(self.R), g['spawn_region'])
            tk = g['target_kind']
            if tk == 0:
                g['target_i'] = self.sidx(G, n, g['target'])
            elif tk in (1, 2, 3):
                t = tables[tk - 1]
                g['target_i'] = self.sidx(t, len(t), g['target'])
            else:
                g['target_i'] = g['target']
            mt = tables.get(g['kind'])
            g['members_i'] = [self.sidx(mt, len(mt), x) if (x != -1 and mt is not None) else -1
                              for x in g['members']]
            dup = self.sidx(G, n, g['id'])
            if dup != -1 and dup < n:     # GO 0x3242a
                o = G[dup]
                o['block'] = [b if b != 0 else a for a, b in zip(o['block'], g['block'])]
                o['members_i'] = [b if b != -1 else a for a, b in zip(o['members_i'], g['members_i'])]
                o['members'] = [b if b != -1 else a for a, b in zip(o['members'], g['members'])]
                for f in ('kind', 'formation', 'orders', 'point', 'heading', 'path', 'team', 'target_kind',
                          'target', 'spawn_region', 'u52', 'var', 'op'):
                    if g[f] != -1:
                        o[f] = g[f]
                        if f + '_i' in g:
                            o[f + '_i'] = g[f + '_i']
                if g['target_kind'] != -1 or g['target'] != -1:
                    o['target_i'] = g['target_i'] if g['target'] != -1 else o.get('target_i', -1)
            else:
                G.append(g)
        self.G = G

    # -- output
    def script(self):
        """script.dat content as python structures (only records with id != -1, in order)."""
        keep = lambda arr: [x for x in arr if x['id'] != -1]
        return dict(
            header=self.header,
            points=[(p['x'], p['y'], p['z']) for p in keep(self.P)],
            headings=[h['value'] for h in keep(self.H)],
            paths=[t['idx'] for t in keep(self.T)],
            areas=[(a['kind'], a['p1i'], a['p2i']) for a in keep(self.A)],
            regions=[(r['type'], r['param'], r['ai'], r['var'], r['op']) for r in keep(self.R)],
            hercs=keep(self.OA), flyers=keep(self.OB), structs=keep(self.OC), groups=keep(self.G))

    def script_dat(self):
        s = self.script()
        o = bytearray(struct.pack('<10h', *[v & 0xffff if v < 0x8000 else v - 0x10000 for v in s['header']]))
        H = lambda *v: o.extend(struct.pack('<%dh' % len(v), *v))
        H(len(s['points']))
        for p in s['points']:
            o.extend(struct.pack('<3i', *p))
        H(len(s['headings'])); H(*s['headings']) if s['headings'] else None
        H(len(s['paths']))
        for t in s['paths']:
            H(len(t))
            if t:
                H(*t)
        H(len(s['areas']))
        for a in s['areas']:
            H(*a)
        H(len(s['regions']))
        for (ty, pa, ai, va, op) in s['regions']:
            H(ty, pa, *ai, va, op)
        H(len(s['hercs']))
        for h in s['hercs']:
            H(*h['block'], h['type'], *h['weapons'], h['point_i'], h['heading_i'], h['var'], h['op'],
              *h['ammo'], h['f62'], h['alert_region_i'], h['death_region_i'], h['health'])
        H(len(s['flyers']))
        for f in s['flyers']:
            H(*f['block'], f['point_i'], f['heading_i'], f['type'], f['var'], f['op'], f['alert_region_i'],
              f['death_region_i'], f['health'])
        H(len(s['structs']))
        for c in s['structs']:
            H(c['type'], c['point_i'], c['heading_i'], c['var'], c['op'], c['alert_region_i'],
              c['death_region_i'], c['health'])
        H(len(s['groups']))
        for g in s['groups']:
            H(*g['block'], g['kind'], g['formation'], g['orders'], g['point_i'], g['heading_i'], g['path_i'],
              *g['members_i'], g['team'], g['target_kind'], g['target_i'], g['spawn_region_i'], g['u52'],
              g['var'], g['op'])
        return bytes(o)


def compile_msn(msn, mvars=None, seed=None, campaign=None, options=None):
    return Compiler(msn, mvars, Rng(seed), campaign, options).run()


# ---------------------------------------------------------------------------
# script.dat reader (DBSIM 0x1d850) - also used for the copies embedded in demo tapes

def parse_script_dat(d):
    r = Reader(d)
    s = dict(header=_ws(r.take(20), 0, 10))
    n = r.h(); s['points'] = [struct.unpack('<3i', r.take(12)) for _ in range(n)]
    n = r.h(); s['headings'] = [r.h() for _ in range(n)]
    n = r.h(); s['paths'] = []
    for _ in range(n):
        k = r.h(); s['paths'].append([r.h() for _ in range(k)])
    n = r.h(); s['areas'] = [tuple(_ws(r.take(6), 0, 3)) for _ in range(n)]
    n = r.h(); s['regions'] = []
    for _ in range(n):
        w = _ws(r.take(24), 0, 12); s['regions'].append((w[0], w[1], w[2:10], w[10], w[11]))
    n = r.h(); s['hercs'] = [_ws(r.take(98), 0, 49) for _ in range(n)]
    n = r.h(); s['flyers'] = [_ws(r.take(56), 0, 28) for _ in range(n)]
    n = r.h(); s['structs'] = [_ws(r.take(16), 0, 8) for _ in range(n)]
    n = r.h(); s['groups'] = [_ws(r.take(82), 0, 41) for _ in range(n)]
    s['_consumed'] = r.o
    return s


def read_tape(path):
    """Demo tape (vcr.cpp, DBSIM 0x58e74): u32 len + file for script.dat, player.mec, mission.var,
    prefs.cfg, restore.dat, object.str, keyjoy.cfg; then the recorded input stream."""
    d = open(path, 'rb').read()
    o = 0; files = {}
    for name in ('script.dat', 'player.mec', 'mission.var', 'prefs.cfg', 'restore.dat', 'object.str',
                 'keyjoy.cfg'):
        n = struct.unpack_from('<I', d, o)[0]
        files[name] = d[o + 4:o + 4 + n]
        o += 4 + n
    files['_stream_offset'] = o
    return files


# ---------------------------------------------------------------------------
# ENG text files (GO 0x19453)

def parse_eng(d):
    """Returns list of chunks {tag, segments}.  segment = str, or
    {'switch_var': v, 'cases': [{'lo','hi','text'}], 'extra': (lo,hi)} for conditional text."""
    o = 2
    chunks = []
    while o + 8 <= len(d):
        tag = d[o:o + 4].decode('latin1')
        size = struct.unpack_from('<I', d, o + 4)[0]
        body = d[o + 8:o + 8 + size]
        q = 2   # u16 text size (buffer size)
        ch = dict(tag=tag.rstrip(':'), segments=[])
        if tag == 'OBJ:':
            ch['count'] = _w(body, 2); q = 4
        while q < len(body):
            m = body[q]; q += 1
            if m == 0x10:
                break
            if m == 1:
                n = _w(body, q)
                ch['segments'].append(body[q + 2:q + 2 + n].rstrip(b'\0').decode('latin1'))
                q += 2 + n
            elif m == 2:
                var = _w(body, q); n = _w(body, q + 2)
                offs = _ws(body, q + 4, n)
                p = q + 4 + 2 * n
                ranges = [tuple(_ws(body, p + 4 * i, 2)) for i in range(n)]
                base = p + 4 * n
                cases = []
                for i in range(n - 1):
                    t0 = base + offs[i]
                    tl = _w(body, t0)
                    cases.append(dict(lo=ranges[i][0], hi=ranges[i][1],
                                      text=body[t0 + 2:t0 + 2 + tl].rstrip(b'\0').decode('latin1')))
                ch['segments'].append(dict(switch_var=var, cases=cases, extra=ranges[n - 1]))
                q = base + offs[n - 1]
            else:
                raise ValueError('ENG %s: unknown marker 0x%x at %d' % (tag, m, q - 1))
        chunks.append(ch)
        o += 8 + size
    return chunks


def eng_texts(chunks, mvars=None):
    """Flatten: brief text, objective strings, debrief list (switches resolved with mvars or listed)."""
    def flat(ch):
        out = []
        for s in ch['segments']:
            if isinstance(s, str):
                out.append(s)
            elif mvars is not None:
                v = mvars[s['switch_var']]
                for c in s['cases']:
                    if c['lo'] <= v <= c['hi']:
                        out.append(c['text'])
            else:
                out.append('{var%d: %s}' % (s['switch_var'], ' | '.join(
                    '%d..%d: %s' % (c['lo'], c['hi'], c['text']) for c in s['cases'])))
        return out
    brief = [' '.join(flat(c)) for c in chunks if c['tag'] == 'BRF']
    obj = [flat(c) for c in chunks if c['tag'] == 'OBJ']
    deb = [' '.join(flat(c)) for c in chunks if c['tag'] == 'DEB']
    return dict(briefing=brief[0] if brief else '', objectives=obj[0] if obj else [], debriefings=deb)


# ---------------------------------------------------------------------------
# campaign / battle sets

def _cstr(d, o):
    e = d.index(b'\0', o)
    return d[o:e].decode('latin1'), e + 1


def parse_btlset(d):
    """BTLSET_n.DAT: u8 ncampaigns; per campaign u8 nslots; per slot u8 nvariants + NUL strings."""
    o = 1; camps = []
    for _ in range(d[0]):
        slots = []
        n = d[o]; o += 1
        for _ in range(n):
            k = d[o]; o += 1
            v = []
            for _ in range(k):
                s, o = _cstr(d, o); v.append(s)
            slots.append(v)
        camps.append(slots)
    return camps


def parse_any(d):
    o = 1; out = []
    for _ in range(d[0]):
        s, o = _cstr(d, o); out.append(s)
    return out


def parse_batlsets(d):
    """BATLSETS.BIN: u32 n, u32 string pool size, u16 offs[n], NUL strings."""
    n, pool = struct.unpack_from('<2I', d, 0)
    offs = _ws(d, 8, n)
    base = 8 + 2 * n
    return [_cstr(d, base + x)[0] for x in offs]


# next campaign after the last slot, by outcome (GO table 0x7ead0: [campaign][win, lose]; -1 = game over,
# 99 = game won).  Outcome "lose" when mission.var[0] > threshold[mission type] (GO 0x159e9, table 0x7ec80).
CAMPAIGN_NEXT = {0: (1, 2), 1: (3, 4), 2: (3, -1), 3: (5, 6), 4: (5, -1), 5: (7, -1), 6: (7, -1), 7: (99, -1)}
CAMPAIGN_KIND = [0, 1, 2, 3, 1, 2, 3, 1]      # GO 0x7ea94 (stored per campaign)
OUTCOME_THRESHOLD = [4, 4, 4, 3, 3, 3, 4, 3, 3, 3]   # GO 0x7ec80, indexed by mission type


def campaign_info():
    sets = parse_batlsets(open(os.path.join(BST_DIR, 'BATLSETS.BIN'), 'rb').read())
    res = dict(battle_sets={}, any_lists={}, next_campaign=CAMPAIGN_NEXT)
    for s in sets + ['test_btl.dat']:
        p = os.path.join(BST_DIR, s.upper())
        if os.path.exists(p):
            res['battle_sets'][s] = parse_btlset(open(p, 'rb').read())
    for p in sorted(glob.glob(os.path.join(BST_DIR, 'ANY_*.DAT'))):
        res['any_lists'][os.path.basename(p).lower()] = parse_any(open(p, 'rb').read())
    sm = os.path.join(MSN_DIR, 'SING_MSN.DAT')
    if os.path.exists(sm):
        d = open(sm, 'rb').read()
        o = 1; groups = []
        for _ in range(d[0]):
            k = d[o]; o += 1; g = []
            for _ in range(k):
                s, o = _cstr(d, o); g.append(s)
            groups.append(g)
        res['single_missions'] = groups
    return res


# ---------------------------------------------------------------------------
# JSON export

def _name(tbl, i):
    return tbl[i] if 0 <= i < len(tbl) else None


def msn_path(name):
    if os.path.exists(name):
        return name
    p = os.path.join(MSN_DIR, name.upper())
    if not p.endswith('.MSN'):
        p += '.MSN'
    return p


ZONE_DIRS = [os.path.join(ROOT, 'extracted', 'ZONES', 'DAT'), os.path.join(ROOT, 'extracted', 'SIMVOL0', 'DAT')]
TERRAIN_NAMES = ['desert', 'temper', 'ice', 'urban']      # DBSIM table 0x924a0 (<name>.DGS / <name>.DAT)


def read_zone(num):
    """ZONEn.DAT (DBSIM 0x20238): u16 unknown, u16 n, n x {s16 shape, i32 x, i32 y, i32 z, u16 rot[3]}.
    shape indexes the terrain's grid-shape file (DESERT/TEMPER/ICE/URBAN.DGS)."""
    for d in ZONE_DIRS:
        p = os.path.join(d, 'ZONE%d.DAT' % num)
        if os.path.exists(p):
            z = open(p, 'rb').read()
            u0, n = struct.unpack_from('<2h', z, 0)
            feats = [struct.unpack_from('<h3i3H', z, 4 + 20 * i) for i in range(n)]
            return dict(file=os.path.relpath(p, ROOT).replace(os.sep, '/'), u0=u0,
                        features=[dict(shape=f[0], position=list(f[1:4]), rotation=list(f[4:7])) for f in feats])
    return None


def guess_campaign(name):
    m = re.match(r'B\d_C(\d)_', os.path.basename(name).upper())
    return int(m.group(1)) if m else None


def mission_json(name, seed=None, mvars=None, campaign='auto', options=None, with_raw=True, with_zone=True):
    """Compile an MSN the way the shell does and describe the result.
    campaign: 'auto' (from the B?_C<n>_ file name; SM_* -> single mission), an index 0..7, or None (single)."""
    path = msn_path(name)
    raw = parse_msn(open(path, 'rb').read())
    if campaign == 'auto':
        campaign = guess_campaign(path)
    comp = compile_msn(raw, mvars, seed, campaign, options)
    s = comp.script()
    hdr = s['header']
    P = s['points']

    def pt(i):
        return list(P[i]) if 0 <= i < len(P) else None

    def head(i):
        return s['headings'][i] if 0 <= i < len(s['headings']) else None

    def obj_common(o):
        return dict(id=o['id'], point=o['point_i'], position=pt(o['point_i']), heading=head(o['heading_i']),
                    on_death=dict(var=o['var'], op=DEATH_OPS.get(o['op'], o['op'])) if o['var'] != -1 else None,
                    alert_region=o['alert_region_i'], death_region=o['death_region_i'], health=o['health'],
                    flag0=o['block'][0] if 'block' in o else None)
    hercs = []
    for o in s['hercs']:
        d = obj_common(o)
        d.update(type=o['type'], type_name=_name(HERC_TYPES, o['type']), weapons=o['weapons'], ammo=o['ammo'],
                 block_rest=o['block'][1:] if any(o['block'][1:]) else None, f62=o['f62'])
        hercs.append(d)
    flyers = []
    for o in s['flyers']:
        d = obj_common(o)
        d.update(type=o['type'], type_name=_name(FLYER_TYPES, o['type']))
        flyers.append(d)
    structs = []
    for o in s['structs']:
        d = obj_common(o)
        d.update(type=o['type'])
        structs.append(d)
    groups = []
    for gi, g in enumerate(s['groups']):
        kind = GROUP_KINDS.get(g['kind'], g['kind'])
        orders_tbl = FLYER_ORDERS if g['kind'] == 1 else HERC_ORDERS
        gpath = s['paths'][g['path_i']] if 0 <= g['path_i'] < len(s['paths']) else None
        groups.append(dict(
            index=gi, id=g['id'], kind=kind, team=g['team'], team_name={0: 'human', 1: 'cybrid'}.get(g['team']),
            formation=g['formation'], orders=g['orders'], orders_name=orders_tbl.get(g['orders']),
            point=g['point_i'], position=pt(g['point_i']), heading=head(g['heading_i']),
            path=g['path_i'], path_points=[pt(i) for i in gpath] if gpath else None,
            members=[m for m in g['members_i'] if m != -1],
            target=dict(kind=TARGET_KINDS.get(g['target_kind'], g['target_kind']), index=g['target_i'])
            if g['target'] != -1 else None,
            spawn_region=g['spawn_region_i'] if g['spawn_region_i'] != -1 else None,
            on_destroyed=dict(var=g['var'], op=DEATH_OPS.get(g['op'], g['op'])) if g['var'] != -1 else None,
            u4=g['u4'], u52=g['u52'], flag0=g['block'][0],
            note='player squad: members come from player.mec, MSN members ignored' if gi == 0 else None))

    def refs(attr, ri):
        return ([['herc', i] for i, o in enumerate(hercs) if o[attr] == ri] +
                [['flyer', i] for i, o in enumerate(flyers) if o[attr] == ri] +
                [['structure', i] for i, o in enumerate(structs) if o[attr] == ri])
    regions = []
    for ri, (ty, pa, ai, va, op) in enumerate(s['regions']):
        areas = []
        for a in ai:
            if a == -1:
                continue
            k, p1, p2 = s['areas'][a]
            if k == 0:
                areas.append(dict(shape='rect', corner1=pt(p1), corner2=pt(p2)))
            else:
                areas.append(dict(shape='circle', center=pt(p1), radius=p2 * 10))
        regions.append(dict(index=ri, type=ty, type_name=REGION_TYPES.get(ty), param=pa, areas=areas,
                            on_fire=dict(var=va, op=REGION_OPS.get(op, op)) if va != -1 else None,
                            activates_groups=[g['index'] for g in groups if g['spawn_region'] == ri],
                            fired_by_alert_of=refs('alert_region', ri), fired_by_death_of=refs('death_region', ri)))
    base = os.path.splitext(path)[0]
    texts = None
    if os.path.exists(base + '.ENG'):
        texts = eng_texts(parse_eng(open(base + '.ENG', 'rb').read()))
    world = hdr[0] * 6 + hdr[9] * 2 + hdr[8]
    out = dict(
        name=os.path.basename(base),
        legacy_format=raw['legacy'],
        header=dict(raw=hdr, msn_raw=comp.msn_header,
                    terrain=hdr[0], terrain_name=_name(TERRAIN_NAMES, hdr[0]),
                    zone=hdr[1], mode={1: 'campaign', 0: 'single'}.get(hdr[2], hdr[2]),
                    mission_type=hdr[3], win_test=MISSION_TYPES.get(hdr[3]), h4=hdr[4],
                    ammo=hdr[5], damage=hdr[6], difficulty=hdr[7], visibility=hdr[8], time_of_day=hdr[9],
                    world_file='WORLD%d.WLD' % world, palette_world='world%d' % (hdr[0] * 6 + hdr[9] * 2)),
        evaluation=dict(seed=seed, campaign=campaign,
                        mission_vars_nonzero={i: v for i, v in enumerate(comp.vars) if v}, log=comp.log),
        player_start=None,
        points=[list(p) for p in P], headings=s['headings'], paths=s['paths'],
        regions=regions, groups=groups, hercs=hercs, flyers=flyers, structures=structs,
        texts=texts,
    )
    if groups:
        g0 = groups[0]
        out['player_start'] = dict(group=0, position=g0['position'] or (g0['path_points'] or [None])[0],
                                   waypoints=g0['path_points'])
    if with_zone and hdr[1] >= 0:
        out['zone'] = read_zone(hdr[1])
    if with_raw:
        out['raw'] = raw
    return out


# ---------------------------------------------------------------------------
# plotting

def plot(name, out_png, seed=None):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    j = mission_json(name, seed)
    fig, ax = plt.subplots(figsize=(10, 10))
    P = j['points']
    if P:
        ax.scatter([p[0] for p in P], [p[1] for p in P], s=6, c='#bbbbbb', zorder=1)
        for i, p in enumerate(P):
            ax.annotate(str(i), (p[0], p[1]), fontsize=6, color='#999999')
    for r in j['regions']:
        for a in r['areas']:
            if a['shape'] == 'circle' and a['center']:
                ax.add_patch(plt.Circle(a['center'][:2], max(a['radius'], 2000), fill=False, ec='#e0a000', lw=1))
            elif a['shape'] == 'rect' and a['corner1'] and a['corner2']:
                x0, y0 = a['corner1'][:2]; x1, y1 = a['corner2'][:2]
                ax.add_patch(plt.Rectangle((min(x0, x1), min(y0, y1)), abs(x1 - x0), abs(y1 - y0), fill=False,
                                           ec='#e0a000', lw=1))
    colors = {0: '#1f6feb', 1: '#d1242f'}
    for gi, g in enumerate(j['groups']):
        c = colors.get(g['team'], '#2da44e')
        if g['path_points']:
            xs = [p[0] for p in g['path_points'] if p]; ys = [p[1] for p in g['path_points'] if p]
            ax.plot(xs, ys, '-', color=c, lw=1, alpha=0.6)
        pos = g['position'] or (g['path_points'][0] if g['path_points'] else None)
        if pos:
            mk = {'herc': 'o', 'flyer': '^', 'structure': 's'}.get(g['kind'], 'x')
            ax.scatter([pos[0]], [pos[1]], marker=mk, c=c, s=60 if gi else 140, zorder=3,
                       edgecolors='k' if gi == 0 else None)
            lbl = 'G%d %s %s' % (gi, g['kind'], g['orders_name'] or g['orders'])
            ax.annotate(lbl, (pos[0], pos[1]), fontsize=7, color=c)
    ax.set_aspect('equal')
    ax.set_title('%s  terrain=%d zone=%d type=%d' % (j['name'], j['header']['terrain'], j['header']['zone'],
                                                      j['header']['mission_type']))
    fig.savefig(out_png, dpi=90)
    plt.close(fig)


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd')
    a = sub.add_parser('json'); a.add_argument('name'); a.add_argument('--seed', type=int)
    a.add_argument('--campaign', type=int, help='campaign index (default: from name; -1 = single mission)')
    a.add_argument('--var', action='append', default=[]); a.add_argument('-o')
    a = sub.add_parser('all'); a.add_argument('--out', default=os.path.join(ROOT, 'out', 'missions'))
    a = sub.add_parser('plot'); a.add_argument('name'); a.add_argument('-o'); a.add_argument('--seed', type=int)
    sub.add_parser('campaign')
    a = sub.add_parser('tape'); a.add_argument('path')
    a = sub.add_parser('script'); a.add_argument('name'); a.add_argument('-o', required=True)
    a.add_argument('--seed', type=int)
    args = ap.parse_args()
    if args.cmd == 'json':
        camp = guess_campaign(args.name) if args.campaign is None else (None if args.campaign < 0 else args.campaign)
        mv = default_mission_vars(camp)
        for kv in args.var:
            k, v = kv.split('='); mv[int(k)] = int(v)
        j = mission_json(args.name, args.seed, mv, camp)
        s = json.dumps(j, indent=1)
        if args.o:
            open(args.o, 'w').write(s)
        else:
            print(s)
    elif args.cmd == 'all':
        os.makedirs(args.out, exist_ok=True)
        bad = 0
        for p in sorted(glob.glob(os.path.join(MSN_DIR, '*.MSN'))):
            n = os.path.splitext(os.path.basename(p))[0]
            try:
                j = mission_json(p)
                open(os.path.join(args.out, n + '.json'), 'w').write(json.dumps(j, indent=1))
                print('%-10s %s terr=%d zone=%-5d type=%d pts=%3d paths=%2d regions=%2d groups=%2d hercs=%2d '
                      'flyers=%2d structs=%2d log=%d' % (
                          n, 'L' if j['legacy_format'] else ' ', j['header']['terrain'], j['header']['zone'],
                          j['header']['mission_type'], len(j['points']), len(j['paths']), len(j['regions']),
                          len(j['groups']), len(j['hercs']), len(j['flyers']), len(j['structures']),
                          len(j['evaluation']['log'])))
            except Exception as e:
                bad += 1
                print('%-10s ERROR %r' % (n, e))
        for p in sorted(glob.glob(os.path.join(MSN_DIR, '*.ENG'))):
            try:
                parse_eng(open(p, 'rb').read())
            except Exception as e:
                bad += 1
                print('%s ERROR %r' % (os.path.basename(p), e))
        print('errors:', bad)
    elif args.cmd == 'plot':
        plot(args.name, args.o or os.path.join(ROOT, 'out', 'missions', args.name + '.png'), args.seed)
    elif args.cmd == 'campaign':
        print(json.dumps(campaign_info(), indent=1))
    elif args.cmd == 'tape':
        f = read_tape(args.path)
        s = parse_script_dat(f['script.dat'])
        print('script.dat %d bytes, consumed %d' % (len(f['script.dat']), s.pop('_consumed')))
        print('mission.var', _ws(f['mission.var'], 0, 100) if len(f['mission.var']) == 200 else f['mission.var'])
        print(json.dumps(s))
    elif args.cmd == 'script':
        raw = parse_msn(open(msn_path(args.name), 'rb').read())
        open(args.o, 'wb').write(compile_msn(raw, None, args.seed).script_dat())
    else:
        ap.print_help()


if __name__ == '__main__':
    main()
