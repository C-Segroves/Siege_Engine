"""Earthsiege 2 mission files: MSN (compiled mission script, MC version 5, ES2 layout), ENG text
tables, and the shell's per-play compile step.  Earthsiege 1 lives in tools/mission.py (unchanged);
this module reuses its random generator policy (mission.Rng) and evaluation rules.

Format spec: docs/formats/es2.md section 10.  Layout derived from VSHELL.EXE (Win32 PE, image base
0x400000): src/msn_gen.cpp mission compiler 0x417b67, ENG table loader 0x41768c, debrief re-reader
0x41ca4e, lookup helpers 0x415a7c (text) / 0x415ae3 (value) / 0x415b44 (point) / 0x415bab (heading) /
0x415c12 (path) / 0x415c79 (area) / 0x415ce0 (region) / 0x415d47 (timer) / 0x415db6 (group) /
0x415e1d (herc) / 0x415e87 (flyer) / 0x415eed (structure) / 0x415f5c (order), duplicate-id mergers
0x416864 (herc) 0x416c17 (flyer) 0x416e7a (structure) 0x4170e8 (order) 0x417286 (group)
0x416521 (region) 0x416768 (timer) 0x4164a5 (text).

MSN (all s16 little-endian; every section = s16 count + records), in file order:
  cond 14     id, parent, kind, a, b, c, d (ES1 rules; compare ops 0x119 == 0x11a != 0x11b < 0x11c <=
              0x11d > 0x11e >=, VSHELL 0x41cbfc)
  hdr 82      cond, f[40]: f[0] applied if != 1, f[1..9] if != 0, f[10..39] if != -1 (0x416379)
  value 8     id, cond, pick, value               (pick -99 marks an override of an earlier id)
  briefing 144  cond, objective texts[10], briefing texts[30], intel texts[30], value id
  debrief 64  cond, texts[30], value id           (not compiled here; read again after the sim)
  point 22, heading 10, path 10+2n, area 12      (Earthsiege 1 layouts)
  region 82   id, cond, pick, type, param, areas[8], n_actions, actions[10][var, op], texts[5],
              message, target (object of table type-7: herc/flyer/structure/group)
  timer 30    id, cond, pick, trigger region, delay, fire regions[10]
  herc 144    id, cond, pick, u6, block[20], type, weapons[10], point, heading, n_actions,
              actions[10][2], ammo[10], f88, alert_region, death_region, health
  flyer 102   id, cond, pick, u6, block[20], point, heading, type, n_actions, actions[10][2],
              alert_region, death_region, health
  struct 62   id, cond, pick, u6, type, point, heading, n_actions, actions[10][2], alert_region,
              death_region, health
  order 22    id, cond, pick, u6, type, arg, point, path, target_kind, target, region
  group 164   id, cond, u4, block[20], kind, formation, point, heading, path, members[20], orders[10],
              team, spawn_region, n_actions, actions[10][2], w81
  objective 58  cond, required, type, target_kind, target, point, path, text, n_actions, actions[10][2]
ENG: u16 n, n x {s16 id, s16 cond, s16 pick, u16 len, char text[len]}; a later entry with the same id
and a kept condition replaces the text (pick -99).

CLI:
  python tools/mission_es2.py json <NAME> [--seed N] [-o out.json]
  python tools/mission_es2.py all [--out out/missions_es2]
"""
import argparse, glob, json, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
import mission as M1     # noqa: E402

MSN_DIR = P.work('es2', 'extracted', 'ZONES', 'MSN')
NVARS = 1000            # ES2 mission variables reach index ~830 (conditions / actions)

HERC_TYPES = ['OUTLAW', 'RAPTOR2', 'TOMAHAWK', 'SAMSON', 'COLOSSUS', 'APOCA', 'OGRE', 'MAVERICK', 'RAZOR',
              'MONGOOSE', 'STINGRAY', 'MIRIMAC', 'RAMSES', 'ACHILLES', 'HYPERION', 'PITBULL', 'SPIDER',
              'DIABLO', 'HEADHUNT', 'SCARAB', 'CERBERUS']      # SIMVOL0/NAM/MECHS.NAM (herc.type)
FLYER_TYPES = ['SKIMMER', 'HOVTANK', 'DROPSHIP']                # SIMVOL0/NAM/FLYERS.NAM (flyer.type)
COND_OPS = {0x119: '==', 0x11a: '!=', 0x11b: '<', 0x11c: '<=', 0x11d: '>', 0x11e: '>='}
GROUP_KINDS = {0: 'herc', 1: 'flyer', 2: 'structure'}
TARGET_KINDS = {0: 'group', 1: 'herc', 2: 'flyer', 3: 'structure'}
REGION_TARGET_TYPES = {7: 'herc', 8: 'flyer', 9: 'structure', 10: 'group'}   # region.type -> target table

SECTIONS = ['cond', 'hdr', 'value', 'briefing', 'debrief', 'point', 'heading', 'path', 'area', 'region',
            'timer', 'herc', 'flyer', 'struct', 'order', 'group', 'objective']
SIZES = dict(cond=14, hdr=82, value=8, briefing=144, debrief=64, point=22, heading=10, path=None, area=12,
             region=82, timer=30, herc=144, flyer=102, struct=62, order=22, group=164, objective=58)


def _pairs(w):
    return [[w[2 * i], w[2 * i + 1]] for i in range(len(w) // 2)]


def dec(name, b):
    w = list(struct.unpack('<%dh' % (len(b) // 2), b))
    if name == 'cond':
        return dict(id=w[0], parent=w[1], kind=w[2], a=w[3], b=w[4], c=w[5], d=w[6])
    if name == 'hdr':
        return dict(cond=w[0], f=w[1:41])
    if name == 'value':
        return dict(id=w[0], cond=w[1], pick=w[2], value=w[3])
    if name == 'briefing':
        return dict(cond=w[0], objectives=w[1:11], briefing=w[11:41], intel=w[41:71], value=w[71])
    if name == 'debrief':
        return dict(cond=w[0], texts=w[1:31], value=w[31])
    if name == 'point':
        x, y, z = struct.unpack_from('<3i', b, 10)
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], rel=w[4], x=x, y=y, z=z)
    if name == 'heading':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], value=w[4])
    if name == 'path':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], points=w[5:5 + w[4]])
    if name == 'area':
        return dict(id=w[0], cond=w[1], pick=w[2], kind=w[3], p1=w[4], p2=w[5])
    if name == 'region':
        return dict(id=w[0], cond=w[1], pick=w[2], type=w[3], param=w[4], areas=w[5:13], n_actions=w[13],
                    actions=_pairs(w[14:34]), texts=w[34:39], message=w[39], target=w[40])
    if name == 'timer':
        return dict(id=w[0], cond=w[1], pick=w[2], trigger=w[3], delay=w[4], fire=w[5:15])
    if name == 'herc':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], block=w[4:24], type=w[24], weapons=w[25:35],
                    point=w[35], heading=w[36], n_actions=w[37], actions=_pairs(w[38:58]), ammo=w[58:68],
                    f88=w[68], alert_region=w[69], death_region=w[70], health=w[71])
    if name == 'flyer':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], block=w[4:24], point=w[24], heading=w[25],
                    type=w[26], n_actions=w[27], actions=_pairs(w[28:48]), alert_region=w[48],
                    death_region=w[49], health=w[50])
    if name == 'struct':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], type=w[4], point=w[5], heading=w[6], n_actions=w[7],
                    actions=_pairs(w[8:28]), alert_region=w[28], death_region=w[29], health=w[30])
    if name == 'order':
        return dict(id=w[0], cond=w[1], pick=w[2], u6=w[3], type=w[4], arg=w[5], point=w[6], path=w[7],
                    target_kind=w[8], target=w[9], region=w[10])
    if name == 'group':
        return dict(id=w[0], cond=w[1], u4=w[2], block=w[3:23], kind=w[23], formation=w[24], point=w[25],
                    heading=w[26], path=w[27], members=w[28:48], orders=w[48:58], team=w[58],
                    spawn_region=w[59], n_actions=w[60], actions=_pairs(w[61:81]), w81=w[81])
    if name == 'objective':
        return dict(cond=w[0], required=w[1], type=w[2], target_kind=w[3], target=w[4], point=w[5], path=w[6],
                    text=w[7], n_actions=w[8], actions=_pairs(w[9:29]))
    raise KeyError(name)


def parse_msn(data):
    """Parse an ES2 MSN into raw (unevaluated) record lists (export_missions schema, pack es2)."""
    ver = struct.unpack_from('<h', data, 0)[0]
    if ver != 5:
        raise ValueError('MC version %d (expected 5)' % ver)
    o = 2
    m = dict(version=5, format='es2')
    for name in SECTIONS:
        n = struct.unpack_from('<h', data, o)[0]
        o += 2
        if n < 0 or n > 5000:
            raise ValueError('bad count %d for %s' % (n, name))
        recs = []
        for _ in range(n):
            if name == 'path':
                k = struct.unpack_from('<h', data, o + 8)[0]
                size = 10 + 2 * max(k, 0)
            else:
                size = SIZES[name]
            if o + size > len(data):
                raise ValueError('truncated %s at 0x%x' % (name, o))
            recs.append(dec(name, data[o:o + size]))
            o += size
        m[name] = recs
    m['trailing'] = len(data) - o       # DEMO2.MSN: an older build, 42 bytes short (not playable)
    if m['trailing'] < 0:
        raise ValueError('%d bytes short' % -m['trailing'])
    return m


def parse_eng(data):
    """ES2 ENG text table: [{id, cond, pick, text}]."""
    n = struct.unpack_from('<H', data, 0)[0]
    o, out = 2, []
    for _ in range(n):
        tid, cond, pick, ln = struct.unpack_from('<hhhH', data, o)
        o += 8
        out.append(dict(id=tid, cond=cond, pick=pick, text=data[o:o + ln].rstrip(b'\0').decode('latin1')))
        o += ln
    return out


# ---------------------------------------------------------------------------------------- compiler

def default_mission_vars(campaign=None, slot=0, rng=None):
    """Mission vars before compiling.  ES2 keeps up to NVARS variables; var1 = campaign (1..5, 99 =
    single/instant action), var2 = mission slot (same convention as Earthsiege 1, M)."""
    rng = rng or M1.Rng(None)
    v = [0] * NVARS
    v[1] = campaign if campaign is not None else 99
    v[2] = slot
    v[4], v[5], v[6] = rng(12), rng(12), rng(12)
    return v


# object sections: (ref fields resolved to script indices, fields copied by a random pick,
# merge "unset" values for duplicate ids)
OBJ_SPEC = {
    'herc': (['point', 'heading', 'alert_region', 'death_region'],
             ['block', 'weapons', 'point', 'heading', 'type', 'n_actions', 'actions', 'ammo', 'f88', 'alert_region',
              'death_region', 'health'],
             dict(block=0, weapons=-1, ammo=5, type=-1, point=-1, heading=-1, actions=-1, f88=2, alert_region=-1,
                  death_region=-1, health=100)),
    'flyer': (['point', 'heading', 'alert_region', 'death_region'],
              ['block', 'point', 'heading', 'type', 'n_actions', 'actions', 'alert_region', 'death_region', 'health'],
              dict(block=0, type=-1, point=-1, heading=-1, actions=-1, alert_region=-1, death_region=-1,
                   health=100)),
    'struct': (['point', 'heading', 'alert_region', 'death_region'],
               ['type', 'point', 'heading', 'n_actions', 'actions', 'alert_region', 'death_region', 'health'],
               dict(type=-1, point=-1, heading=-1, actions=-1, alert_region=-1, death_region=-1, health=100)),
}
REF_TABLE = dict(point='P', heading='H', alert_region='R', death_region='R')


class Compiler:
    def __init__(self, msn, eng=None, mvars=None, rng=None, campaign=None):
        self.m = msn
        self.eng = eng or []
        self.rng = rng or M1.Rng(None)
        self.campaign = campaign
        self.mode = 1 if campaign is not None else 0
        self.vars = list(mvars) if mvars is not None else default_mission_vars(campaign, 0, self.rng)
        self.vars += [0] * (NVARS - len(self.vars))
        self.log = []

    def var(self, i):
        return self.vars[i] if 0 <= i < len(self.vars) else 0

    def run(self):
        K = []
        for c in self.m['cond']:
            c = dict(c)
            k = c['kind']
            if k == 0:
                if self.cond_ok(c['parent'], K):
                    v, x = self.var(c['a']), c['c']
                    res = {0x119: v == x, 0x11a: v != x, 0x11b: v < x, 0x11c: v <= x, 0x11d: v > x,
                           0x11e: v >= x}.get(c['b'], False)
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
        self.do_texts()
        self.do_values()
        self.do_briefing()
        self.do_points()
        self.do_headings()
        self.do_paths()
        self.do_areas()
        self.do_regions()
        self.do_timers()
        self.OA = self._objs('herc')
        self.OB = self._objs('flyer')
        self.OC = self._objs('struct')
        self.do_orders()
        self.do_groups()
        self.do_deferred_targets()
        self.do_objectives()
        self.do_debrief()
        return self

    def cond_ok(self, cid, K=None):
        if cid == -1:
            return True
        return any(c['id'] == cid for c in (self.K if K is None else K))

    # same helpers as Earthsiege 1 (GO 0x318d5, 0x313f1)
    pick_case = M1.Compiler.pick_case
    pick_rec = M1.Compiler.pick_rec
    sidx = staticmethod(M1.Compiler.sidx)
    aidx = staticmethod(M1.Compiler.aidx)
    _store = M1.Compiler._store

    def do_header(self):
        f = [1] + [0] * 9 + [-1] * 30
        for h in self.m['hdr']:
            if self.cond_ok(h['cond']):
                v = h['f']
                if v[0] != 1:
                    f[0] = v[0]
                for i in range(1, 10):
                    if v[i] != 0:
                        f[i] = v[i]
                for i in range(10, 40):
                    if v[i] != -1:
                        f[i] = v[i]
        self.msn_header = list(f)
        # shell overrides (VSHELL 0x41c73d): campaign mode word0 = the career's theater (C1..C5 -> 0..4),
        # words 5/6 = 0; other modes word0 = 1
        if self.mode == 1:
            f[0] = min(max(self.campaign - 1, 0), 4) if self.campaign else f[0]
            f[5] = f[6] = 0
        else:
            f[0] = 1
        self.header = f

    def _keyed(self, src, fields):
        """Records with an id and a condition; a later kept record with the same id replaces the data
        (value table 0x41823a, ENG table 0x41797b)."""
        out = []
        for r in src:
            if not self.cond_ok(r['cond']):
                continue
            dup = self.sidx(out, len(out), r['id'])
            rec = {k: r[k] for k in ['id'] + fields}
            if dup != -1:
                out[dup] = rec
            else:
                out.append(rec)
        return out

    def do_texts(self):
        self.TX = self._keyed(self.eng, ['text'])
        self.text_by_id = {t['id']: t['text'] for t in self.TX}

    def text(self, tid):
        return self.text_by_id.get(tid) if tid != -1 else None

    def do_values(self):
        self.VAL = self._keyed(self.m['value'], ['value'])
        self.value_by_id = {v['id']: v['value'] for v in self.VAL}

    def _texts(self, ids):
        return [self.text(t) for t in ids if t != -1 and self.text(t) is not None]

    def do_briefing(self):
        self.brief = None
        for b in self.m['briefing']:
            if self.cond_ok(b['cond']):
                self.brief = b

    def do_debrief(self):
        self.deb = None
        for d in self.m['debrief']:
            if self.cond_ok(d['cond']):
                self.deb = d

    def do_points(self):
        M1.Compiler.do_points(self)

    def do_headings(self):
        M1.Compiler.do_headings(self)

    def do_paths(self):
        M1.Compiler.do_paths(self)

    def do_areas(self):
        M1.Compiler.do_areas(self)

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
            if dup != -1 and dup < n:     # 0x416521: patch fields that are not -1
                o = R[dup]
                for k in ('type', 'param', 'target'):
                    if r[k] != -1:
                        o[k] = r[k]
                o['message'] = r['message']
                o['ai'] = [b if b != -1 else a for a, b in zip(o['ai'], r['ai'])]
                o['actions'] = [b if b[0] != -1 else a for a, b in zip(o['actions'], r['actions'])]
                o['texts'] = [b if b != -1 else a for a, b in zip(o['texts'], r['texts'])]
                o['n_actions'] = max(o['n_actions'], r['n_actions'])
            else:
                R.append(r)
        self.R = R

    def do_timers(self):
        T = []
        nr = len(self.R)
        for t in self.m['timer']:
            t = dict(t)
            if not self.cond_ok(t['cond']):
                continue
            n = len(T)
            t['trigger_i'] = self.sidx(self.R, nr, t['trigger'])
            t['fire_i'] = [self.sidx(self.R, nr, x) if x != -1 else -1 for x in t['fire']]
            dup = self.aidx(T, n, t['id'])
            if dup != -1:
                o = T[dup]
                for k in ('trigger', 'delay'):
                    if t[k] != -1:
                        o[k] = t[k]
                if t['trigger'] != -1:
                    o['trigger_i'] = t['trigger_i']
                o['fire_i'] = [b if b != -1 else a for a, b in zip(o['fire_i'], t['fire_i'])]
            else:
                T.append(t)
        self.TM = T

    def _tbl(self, key):
        return {'P': self.P, 'H': self.H, 'R': self.R}[key]

    def _objs(self, section):
        refs, copy, skip = OBJ_SPEC[section]
        O = []
        for o in self.m[section]:
            o = dict(o)
            if not self.cond_ok(o['cond']):
                continue
            n = len(O)
            if o['pick'] == -1 or o['pick'] == -99:
                for f in refs:
                    t = self._tbl(REF_TABLE[f])
                    o[f + '_i'] = self.sidx(t, len(t), o[f])
            else:
                j = self.pick_rec(O, n, o['pick'])
                if j is not None:
                    for f in copy:
                        o[f] = O[j][f]
                    for f in refs:
                        o[f + '_i'] = O[j][f + '_i']
                else:
                    for f in refs:
                        o[f + '_i'] = -1
            dup = self.aidx(O, n, o['id'])
            if dup != -1:
                self._merge(O[dup], o, skip)
            else:
                O.append(o)
        return O

    @staticmethod
    def _merge(dst, src, skip_vals):
        for f, sk in skip_vals.items():
            v = src[f]
            if f == 'actions':
                dst[f] = [b if b[0] != sk else a for a, b in zip(dst[f], v)]
                dst['n_actions'] = max(dst['n_actions'], src['n_actions'])
            elif isinstance(v, list):
                dst[f] = [b if b != sk else a for a, b in zip(dst[f], v)]
            elif v != sk:
                dst[f] = v
                if f + '_i' in src:
                    dst[f + '_i'] = src[f + '_i']

    def _target_i(self, kind, tid):
        tables = {1: self.OA, 2: self.OB, 3: self.OC}
        if tid == -1:
            return -1
        if kind in tables:
            t = tables[kind]
            return self.sidx(t, len(t), tid)
        return None      # group: resolved after the groups (0x41a854)

    def do_orders(self):
        D = []
        for r in self.m['order']:
            r = dict(r)
            if not self.cond_ok(r['cond']):
                continue
            n = len(D)
            r['point_i'] = self.sidx(self.P, len(self.P), r['point'])
            r['path_i'] = self.sidx(self.T, len(self.T), r['path'])
            r['region_i'] = self.sidx(self.R, len(self.R), r['region'])
            r['target_i'] = self._target_i(r['target_kind'], r['target'])
            dup = self.aidx(D, n, r['id'])
            if dup != -1:       # 0x4170e8
                o = D[dup]
                for f in ('type', 'arg', 'point', 'path', 'target_kind', 'target', 'region'):
                    if r[f] != -1:
                        o[f] = r[f]
                        if f + '_i' in r:
                            o[f + '_i'] = r[f + '_i']
                if r['target'] != -1:
                    o['target_i'] = r['target_i']
            else:
                D.append(r)
        self.D = D

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
            mt = tables.get(g['kind'])
            g['members_i'] = [self.sidx(mt, len(mt), x) if (x != -1 and mt is not None) else -1
                              for x in g['members']]
            g['orders_i'] = [self.sidx(self.D, len(self.D), x) if x != -1 else -1 for x in g['orders']]
            dup = self.sidx(G, n, g['id'])
            if dup != -1 and dup < n:     # 0x417286
                o = G[dup]
                o['block'] = [b if b != 0 else a for a, b in zip(o['block'], g['block'])]
                for f in ('members', 'members_i', 'orders', 'orders_i'):
                    o[f] = [b if b != -1 else a for a, b in zip(o[f], g[f])]
                for f in ('kind', 'formation', 'point', 'heading', 'path', 'team', 'spawn_region', 'w81'):
                    if g[f] != -1:
                        o[f] = g[f]
                        if f + '_i' in g:
                            o[f + '_i'] = g[f + '_i']
                o['actions'] = [b if b[0] != -1 else a for a, b in zip(o['actions'], g['actions'])]
                o['n_actions'] = max(o['n_actions'], g['n_actions'])
            else:
                G.append(g)
        self.G = G

    def do_deferred_targets(self):
        for r in self.D:
            if r['target_kind'] == 0:
                r['target_i'] = self.sidx(self.G, len(self.G), r['target'])
        tables = {7: self.OA, 8: self.OB, 9: self.OC, 10: self.G}
        for r in self.R:
            t = tables.get(r['type'])
            r['target_i'] = self.sidx(t, len(t), r['target']) if t is not None else -1

    def do_objectives(self):
        J = []
        for r in self.m['objective']:
            r = dict(r)
            if not self.cond_ok(r['cond']):
                continue
            r['point_i'] = self.sidx(self.P, len(self.P), r['point'])
            r['path_i'] = self.sidx(self.T, len(self.T), r['path'])
            if r['target_kind'] == 0:
                r['target_i'] = self.sidx(self.G, len(self.G), r['target'])
            else:
                r['target_i'] = self._target_i(r['target_kind'], r['target'])
            J.append(r)
        self.J = J

    def script(self):
        keep = lambda arr: [x for x in arr if x['id'] != -1]
        return dict(
            header=self.header,
            points=[(p['x'], p['y'], p['z']) for p in keep(self.P)],
            headings=[h['value'] for h in keep(self.H)],
            paths=[t['idx'] for t in keep(self.T)],
            areas=[(a['kind'], a['p1i'], a['p2i']) for a in keep(self.A)],
            regions=keep(self.R), timers=keep(self.TM), hercs=keep(self.OA), flyers=keep(self.OB),
            structs=keep(self.OC), orders=keep(self.D), groups=keep(self.G), objectives=self.J)


def compile_msn(msn, eng=None, mvars=None, seed=None, campaign=None):
    return Compiler(msn, eng, mvars, M1.Rng(seed), campaign).run()


# ---------------------------------------------------------------------------------------- resolve

def guess_campaign(name):
    m = re.match(r'C(\d)_\d+', os.path.basename(name).upper())
    return int(m.group(1)) if m else None


def msn_path(name):
    if os.path.exists(name):
        return name
    p = os.path.join(MSN_DIR, name.upper())
    return p if p.endswith('.MSN') else p + '.MSN'


def _acts(n, pairs):
    return [list(p) for p in pairs[:max(0, min(n, 10))] if p[0] != -1]


def resolve(name, raw, comp, seed=None, camp=None):
    """mission_json-style description of a compiled ES2 mission (see tools/mission.py mission_json);
    ES2 additions: objectives, orders, timers, values, briefing/debriefing text lists."""
    s = comp.script()
    hdr = s['header']
    P = s['points']

    def pt(i):
        return list(P[i]) if 0 <= i < len(P) else None

    def head(i):
        return s['headings'][i] if 0 <= i < len(s['headings']) else None

    def common(o):
        return dict(id=o['id'], point=o['point_i'], position=pt(o['point_i']), heading=head(o['heading_i']),
                    on_death=_acts(o['n_actions'], o['actions']), alert_region=o['alert_region_i'],
                    death_region=o['death_region_i'], health=o['health'],
                    flag0=o['block'][0] if 'block' in o else None)
    hercs = []
    for o in s['hercs']:
        d = common(o)
        d.update(type=o['type'], type_name=M1._name(HERC_TYPES, o['type']), weapons=o['weapons'], ammo=o['ammo'],
                 skill=o['block'][1], f88=o['f88'])
        hercs.append(d)
    flyers = []
    for o in s['flyers']:
        d = common(o)
        d.update(type=o['type'], type_name=M1._name(FLYER_TYPES, o['type']))
        flyers.append(d)
    structs = []
    for o in s['structs']:
        d = common(o)
        d.update(type=o['type'])
        structs.append(d)

    def path_pts(i):
        p = s['paths'][i] if 0 <= i < len(s['paths']) else None
        return [pt(k) for k in p] if p else None
    orders = []
    for r in s['orders']:
        orders.append(dict(id=r['id'], type=r['type'], arg=r['arg'], point=r['point_i'], position=pt(r['point_i']),
                           path=r['path_i'], path_points=path_pts(r['path_i']),
                           target=dict(kind=TARGET_KINDS.get(r['target_kind'], r['target_kind']), index=r['target_i'])
                           if r['target'] != -1 else None,
                           region=r['region_i'] if r['region_i'] != -1 else None))
    groups = []
    for gi, g in enumerate(s['groups']):
        olist = [i for i in g['orders_i'] if i != -1]
        first = orders[olist[0]] if olist else None
        gpath = g['path_i'] if g['path_i'] != -1 else (first['path'] if first else -1)
        groups.append(dict(
            index=gi, id=g['id'], kind=GROUP_KINDS.get(g['kind'], g['kind']), team=g['team'],
            team_name={0: 'human', 1: 'cybrid'}.get(g['team']), formation=g['formation'],
            orders=first['type'] if first else -1, order_list=olist,
            point=g['point_i'], position=pt(g['point_i']), heading=head(g['heading_i']),
            path=gpath, path_points=path_pts(gpath),
            members=[m for m in g['members_i'] if m != -1],
            target=first['target'] if first else None,
            spawn_region=g['spawn_region_i'] if g['spawn_region_i'] != -1 else None,
            on_destroyed=_acts(g['n_actions'], g['actions']), u4=g['u4'], flag0=g['block'][0], w81=g['w81']))

    def refs(attr, ri):
        return ([['herc', i] for i, o in enumerate(hercs) if o[attr] == ri] +
                [['flyer', i] for i, o in enumerate(flyers) if o[attr] == ri] +
                [['structure', i] for i, o in enumerate(structs) if o[attr] == ri])
    regions = []
    for ri, r in enumerate(s['regions']):
        areas = []
        for a in r['ai']:
            if a == -1 or a >= len(s['areas']):
                continue
            k, p1, p2 = s['areas'][a]
            if k == 0:
                areas.append(dict(shape='rect', corner1=pt(p1), corner2=pt(p2)))
            else:
                areas.append(dict(shape='circle', center=pt(p1), radius=p2 * 10))
        regions.append(dict(
            index=ri, id=r['id'], type=r['type'], param=r['param'], areas=areas,
            on_fire=_acts(r['n_actions'], r['actions']),
            texts=[comp.text(t) for t in r['texts'] if t != -1 and comp.text(t) is not None],
            message=r['message'],
            target=dict(kind=REGION_TARGET_TYPES.get(r['type']), index=r['target_i']) if r['target_i'] != -1 else None,
            activates_groups=[g['index'] for g in groups if g['spawn_region'] == ri],
            activates_orders=[i for i, o in enumerate(orders) if o['region'] == ri],
            fired_by_alert_of=refs('alert_region', ri), fired_by_death_of=refs('death_region', ri)))
    timers = [dict(id=t['id'], trigger=t['trigger_i'] if t['trigger'] != -1 else None, delay=t['delay'],
                   fire=[i for i in t['fire_i'] if i != -1]) for t in s['timers']]
    objectives = [dict(required=bool(r['required']), type=r['type'],
                       target=dict(kind=TARGET_KINDS.get(r['target_kind'], r['target_kind']), index=r['target_i'])
                       if r['target'] != -1 else None,
                       point=r['point_i'], position=pt(r['point_i']), path=r['path_i'], path_points=path_pts(r['path_i']),
                       text=comp.text(r['text']), actions=_acts(r['n_actions'], r['actions'])) for r in s['objectives']]
    b, d = comp.brief, comp.deb
    texts = dict(
        briefing=' '.join(comp._texts(b['briefing'])) if b else '',
        intel=' '.join(comp._texts(b['intel'])) if b else '',
        objectives=comp._texts(b['objectives']) if b else [],
        debriefings=[''.join(comp._texts(d['texts']))] if d else [],
        score=comp.value_by_id.get(d['value']) if d else None)
    out = dict(
        name=name, pack='es2', format='es2',
        header=dict(raw=hdr[:10], extra=hdr[10:], msn_raw=comp.msn_header, terrain=hdr[0], zone=hdr[1],
                    mode={1: 'campaign', 0: 'single'}[comp.mode], mission_type=hdr[3], h4=hdr[4],
                    world=None),
        evaluation=dict(seed=seed, campaign=camp, mission_vars_nonzero={i: v for i, v in enumerate(comp.vars) if v},
                        log=comp.log),
        player_start=None,
        points=[list(p) for p in P], headings=s['headings'], paths=s['paths'],
        regions=regions, timers=timers, groups=groups, orders=orders, hercs=hercs, flyers=flyers,
        structures=structs, objectives=objectives, values={str(v['id']): v['value'] for v in comp.VAL},
        texts=texts)
    # player squad: group 0 (as Earthsiege 1); its first order's path is the nav route
    if groups:
        g0 = groups[0]
        out['player_start'] = dict(group=0, position=g0['position'] or (g0['path_points'] or [None])[0],
                                   waypoints=g0['path_points'],
                                   herc=hercs[g0['members'][0]] if g0['members'] and g0['kind'] == 'herc' else None)
    return out


def mission_json(name, seed=None, mvars=None, campaign='auto'):
    path = msn_path(name)
    raw = parse_msn(open(path, 'rb').read())
    base = os.path.splitext(path)[0]
    eng = parse_eng(open(base + '.ENG', 'rb').read()) if os.path.exists(base + '.ENG') else []
    if campaign == 'auto':
        campaign = guess_campaign(path)
    comp = compile_msn(raw, eng, mvars, seed, campaign)
    return resolve(os.path.basename(base).upper(), raw, comp, seed, campaign)


# ---------------------------------------------------------------------------------------- export

def _dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, separators=(',', ':'), ensure_ascii=False)


def tables_json():
    s = lambda d: {str(k): v for k, v in d.items()}
    return dict(format='es2', herc_types=HERC_TYPES, flyer_types=FLYER_TYPES, cond_ops=s(COND_OPS),
                group_kinds=s(GROUP_KINDS), target_kinds=s(TARGET_KINDS),
                region_target_types=s(REGION_TARGET_TYPES), nvars=NVARS)


GAM_DIR = P.work('es2', 'extracted', 'SHELL0', 'GAM')
LANG_DIR = P.work('es2', 'extracted', 'LANG0', 'ENG')
THEATERS = ['Alpha', 'Delta', 'Omicron', 'Bravo', 'Luna']        # ESTEXT 0x77..0x7b by CAREER.DAT w0


def read_careers():
    """SHELL0/GAM/CAREER.DAT: s16 n; n x {s16 theater, s16 count, s16 MISSIONS.BIN ids[count]};
    LANG0/ENG/MISSIONS.BIN: s32 n, s32 size, u16 offs[n], NUL strings "MSN/C1_01.MSN" (VSHELL, see
    docs/formats/es2_campaign_flow.md).  Record 0 = training, 1..5 = campaigns C1..C5."""
    d = open(os.path.join(GAM_DIR, 'CAREER.DAT'), 'rb').read()
    b = open(os.path.join(LANG_DIR, 'MISSIONS.BIN'), 'rb').read()
    n, _ = struct.unpack_from('<ii', b, 0)
    offs = struct.unpack_from('<%dH' % n, b, 8)
    base = 8 + 2 * n
    names = []
    for o in offs:
        s = b[base + o:b.index(bytes(1), base + o)].decode('latin1').replace(chr(92), '/')
        names.append(os.path.splitext(os.path.basename(s))[0].upper())
    w = struct.unpack('<%dh' % (len(d) // 2), d)
    o, out = 1, []
    for _ in range(w[0]):
        th, k = w[o], w[o + 1]
        out.append(dict(theater=th, missions=[names[i] for i in w[o + 2:o + 2 + k]]))
        o += 2 + k
    return out


# VSHELL tech unlocks after a campaign mission (docs/formats/es2_campaign_flow.md "After the sim"):
# var -> [unlocked item, value the var must hold]. Hercs 0x4118c5 (value 2; Razor 1, the campaign's
# objectives raise var63 only once - M), weapons 0x4126be.
TECH_HERC_VARS = {'60': ['RAPTOR2', 2], '61': ['MAVERICK', 2], '62': ['OGRE', 2], '63': ['RAZOR', 1]}
TECH_WEAPON_VARS = {'50': ['LAS400', 1], '51': ['LAS500', 1], '52': ['ATC75', 2], '53': ['ATC100', 1],
                    '56': ['SHIELD', 1], '57': ['TARG', 1], '58': ['TURBO', 2], '59': ['ENERGY', 1]}
# Script-awarded weapons (0x412760): var k adds var[k] copies at 100 % (engine weapon names; racks = all guidance).
SCRIPT_AWARD_VARS = {'21': 'ECM', '22': 'ATC50', '23': 'ATC75', '24': 'ATC100', '25': 'LAS300', '26': 'LAS400',
                     '27': 'LAS500', '28': 'MSL10', '29': 'MINE', '30': 'LAEW', '31': 'PBEAM', '32': 'EMP',
                     '33': 'ELF', '34': 'PBW2', '35': 'EMP2', '36': 'ELF2', '37': 'PLAS', '38': 'MAGN',
                     '39': 'TARG', '40': 'SHIELD', '41': 'TURBO', '42': 'ENERGY'}
# exe weapon name table 0x498eb0 (index -> engine name; 13..16 = missile racks 6/8/10/Razor) for HERCS.DAT
EXE_WEAPONS = ['', 'ATC20', 'ATC35', 'ATC50', 'ATC75', 'ATC100', 'ELF', 'EMP', 'LAS100', 'LAS200', 'LAS300',
               'LAS400', 'LAS500', 'MSL6', 'MSL8', 'MSL10', 'FLYMSL', 'PBEAM', 'ECM', 'EMP_BULL', 'PBEAM_BULL',
               'MISSL_BULL', 'ELF2', 'EMP2', 'PBW2', 'PLAS', 'LAEW', 'MINE', 'MAGN', 'TARG', 'SHIELD', 'TURBO',
               'ENERGY']


def read_start_hangar():
    """SHELL0/GAM/HERCS.DAT (new campaign hangar, mode 1 only): s16 n; n x {s16 hangar slot, s16 herc type
    (MECHS order), s16 condition %, s16 ?, s16 k, k x {s16 GL loadout slot, s16 weapon (exe table), s16 %,
    s16 missile type}} (the INI_*.DAT layout behind a slot word). A record with condition 0 and no weapons
    (slot 4) is a placeholder the campaign fills later (c1 m3 -> player herc slot 4) [M]."""
    try:
        w = struct.unpack('<%dh' % (os.path.getsize(os.path.join(GAM_DIR, 'HERCS.DAT')) // 2),
                          open(os.path.join(GAM_DIR, 'HERCS.DAT'), 'rb').read())
    except OSError:
        return []
    out, o = [], 1
    for _ in range(w[0]):
        if o + 5 > len(w):
            break
        slot, typ, cond, _unk, k = w[o:o + 5]
        o += 5
        weapons = []
        for j in range(k):
            gl, wi, _pct, mt = w[o + 4 * j:o + 4 * j + 4]
            weapons.append({'slot': gl, 'weapon': EXE_WEAPONS[wi] if 0 <= wi < len(EXE_WEAPONS) else None,
                            'missile_type': mt})
        o += 4 * k
        out.append({'slot': slot, 'herc': HERC_TYPES[typ] if 0 <= typ < len(HERC_TYPES) else None,
                    'condition': cond, 'weapons': weapons})
    return out


def campaign_json():
    """Campaign structure and progression rules (VSHELL 0x412dc7, docs/formats/es2_campaign_flow.md):
    careers 1..5 played in order, ten missions each; after every mission m++ (wrapping to the next
    career); a failed mission is NOT replayed, except that failing a must-win mission (each career's
    last, and every Luna/C5 mission) loses the war (offer replay); success after the last career = victory.
    Mission vars persist: var0 = success flag, var1 = career (1..5), var2 = mission (0..9), var4..6 = rand(12)."""
    try:
        careers = read_careers()
    except OSError:
        careers = []
    if not careers:     # fallback: from the file names
        names = sorted(os.path.splitext(os.path.basename(p))[0].upper() for p in glob.glob(os.path.join(MSN_DIR, 'C*_*.MSN')))
        careers = [dict(theater=5, missions=[])] + [dict(theater=c - 1, missions=[n for n in names if n.startswith('C%d_' % c)])
                                                     for c in range(1, 6)]
    camps = []
    for i, c in enumerate(careers[1:], 1):
        camps.append(dict(index=i, theater=c['theater'],
                          theater_name=THEATERS[c['theater']] if 0 <= c['theater'] < len(THEATERS) else None,
                          missions=c['missions'], must_win=[len(c['missions']) - 1] if i < 5 else list(range(len(c['missions'])))))
    return dict(format='es2', campaigns=camps, training=careers[0]['missions'] if careers else [],
                retry_on_failure=False, war_lost_on_must_win_failure=True, replay_on_death=True,
                tech_unlocks=dict(hercs={'60': 'RAPTOR2', '62': 'OGRE', '61': 'MAVERICK', '63': 'RAZOR'},
                                  weapons={'52': 'ATC75', '53': 'ATC100', '50': 'LAS400', '51': 'LAS500', '57': 'TARG',
                                           '56': 'SHIELD', '58': 'TURBO', '59': 'ENERGY'}),
                tech_unlock_rules=dict(hercs=TECH_HERC_VARS, weapons=TECH_WEAPON_VARS),
                script_awards=SCRIPT_AWARD_VARS, start_hangar=read_start_hangar(),
                notes='See docs/formats/es2_campaign_flow.md and docs/formats/campaign_availability.md.')


def export(out=None):
    out = out or P.pack('es2', 'missions')
    os.makedirs(out, exist_ok=True)
    msns, engs = [], []
    for p in sorted(glob.glob(os.path.join(MSN_DIR, '*.MSN'))):
        n = os.path.splitext(os.path.basename(p))[0].upper()
        try:
            raw = parse_msn(open(p, 'rb').read())
        except Exception as e:
            print('MSN %s skipped: %r' % (n, e))
            continue
        _dump(os.path.join(out, 'msn', n + '.json'), raw)
        msns.append(n)
    for p in sorted(glob.glob(os.path.join(MSN_DIR, '*.ENG'))):
        n = os.path.splitext(os.path.basename(p))[0].upper()
        _dump(os.path.join(out, 'eng', n + '.json'), parse_eng(open(p, 'rb').read()))
        engs.append(n)
    _dump(os.path.join(out, 'index.json'), dict(missions=msns, eng=engs, format='es2'))
    _dump(os.path.join(out, 'tables.json'), tables_json())
    _dump(os.path.join(out, 'campaign.json'), campaign_json())
    print('es2 missions: %d MSN, %d ENG -> %s' % (len(msns), len(engs), out))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd')
    a = sub.add_parser('json'); a.add_argument('name'); a.add_argument('--seed', type=int); a.add_argument('-o')
    a = sub.add_parser('all'); a.add_argument('--out', default=os.path.join(P.ROOT, 'out', 'missions_es2'))
    a = sub.add_parser('export'); a.add_argument('--out')
    args = ap.parse_args()
    if args.cmd == 'export':
        export(args.out)
    elif args.cmd == 'json':
        s = json.dumps(mission_json(args.name, args.seed), indent=1)
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
                print('%-8s zone=%-5s type=%s pts=%3d regions=%2d groups=%2d hercs=%2d flyers=%2d structs=%2d '
                      'orders=%2d objectives=%d log=%d' % (
                          n, j['header']['zone'], j['header']['mission_type'], len(j['points']), len(j['regions']),
                          len(j['groups']), len(j['hercs']), len(j['flyers']), len(j['structures']), len(j['orders']),
                          len(j['objectives']), len(j['evaluation']['log'])))
            except Exception as e:
                bad += 1
                print('%-8s ERROR %r' % (n, e))
        print('errors:', bad)
    else:
        ap.print_help()


if __name__ == '__main__':
    main()
