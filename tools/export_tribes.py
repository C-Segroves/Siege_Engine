"""Proof-of-life exporter: Starsiege: Tribes (Darkstar) assets -> gamedata/tribes/.

Input:  tribes/extracted/<vol>/... (tools/darkstar_vol.py extract tribes/original/Tribes/base tribes/extracted)
Output (same layout/schema as tools/export_es1.py, with the additions marked [+]):
  pack.json, units.json
  palettes/<NAME>.json           256 x [r,g,b] (8-bit); NAME = "<world>_<paletteId>", e.g. lush_day_1136
  textures/<SET>/<i>.png         8-bit palette-index images (mode "L"), i = material index
  textures/<SET>/<i>_rgba.png    [+] the same texture resolved through its palette (convenience/preview)
  textures/<SET>.json            [{w, h, file, palette}] per material index   ([+] file, palette)
  shapes/<NAME>.json             export_es1.shape_to_json schema:
      lods[]: {radius, center, pieces[], cells[]}  (LOD 0 = most detailed Darkstar detail level)
      piece: {node, id (1000 + object index, avoids ShapeInstance locator ids), name [+], cell -1, state 0, polys[]}
      poly : {v: [[x,y,z] x3] (node space, metres), n: [nx,ny,nz], m: {kind:"tex", index},
              t: "darkstar_tri", uv [+]: [[u,v] x3] explicit texture coordinates (0..1, v down)}
      nodes[]: {parent, default, name [+]}  default = transform index of the "root" sequence pose
      transforms[]: [rx, ry, rz, tx, ty, tz]  rotations in 1/65536 turn (floats), same Euler
                    convention as ES (R = Rz*Ry*Rx, x right / y forward / z up), translations in metres
      ds_sequences [+]: [{name, cyclic, duration (s), priority,
                          tracks: [{node, keys: [[position 0..1, transform index], ...]}],
                          triggers: [[position, value]] (frame triggers; armour footsteps 1 / 2)}]
      bounds [+]: {min, max} from the shape header and the "bounds" collision box object
  previews/<NAME>.png            matplotlib render (tools/preview_gamedata.py)

Usage: python tools/export_tribes.py [shape ...]   (default: larmor)
"""
import json, math, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import darkstar_dts as D
import darkstar_gfx as G

import siege_paths as P  # noqa: E402
from pack_json import merge_pack_json  # noqa: E402
SRC = P.work('tribes', 'extracted')
OUT = P.pack('tribes')
WORLD_PPL = ('lushWorld', 'lush.day.ppl')   # Raindance etc.; entity palette ids are shared by all worlds


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, separators=(',', ':'))


def find_file(name):
    low = name.lower()
    for d in os.listdir(SRC):
        p = os.path.join(SRC, d)
        if not os.path.isdir(p):
            continue
        for f in os.listdir(p):
            if f.lower() == low:
                return os.path.join(p, f)
    return None


def key_position(pos):
    """A keyframe's 0..1 position; zero-length sequences of some shapes (marmor 'Fall controlled') store NaN,
    which JSON can't carry: 0."""
    return round(pos, 4) if math.isfinite(pos) else 0.0


def mat_to_euler(R):
    """R = Rz(c) Ry(b) Rx(a) -> (a, b, c) in 1/65536 turn."""
    sb = max(-1.0, min(1.0, -R[2][0]))
    b = math.asin(sb)
    if abs(sb) < 0.99999:
        a = math.atan2(R[2][1], R[2][2])
        c = math.atan2(R[1][0], R[0][0])
    else:
        a = math.atan2(-R[1][2], R[1][1])
        c = 0.0
    k = 65536.0 / (2 * math.pi)
    return [round(a * k, 3), round(b * k, 3), round(c * k, 3)]


def tf_to_list(t):
    return mat_to_euler(D.quat_to_mat(t['q'])) + [round(x, 5) for x in t['t']]


def root_pose(s, seq=0):
    tf = []
    for nd in s['nodes']:
        t = nd['default']
        for k in range(nd['firstsub'], nd['firstsub'] + nd['nsub']):
            ss = s['subsequences'][k]
            if ss['seq'] == seq and ss['nkf'] > 0:
                t = s['keyframes'][ss['firstkf']]['tf']
        tf.append(t)
    return tf


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


# Darkstar TS::Shape object flag 1: the object starts invisible (every "hide ..." object on the Tribes disc has it
# and no other: the weapons' muzzle flashes); its sequences' keyframes then switch it on and off.
OBJECT_HIDDEN = 1
# Darkstar keyframe material word: 0x4000 = the key sets visibility, 0x8000 = visible.
KEY_SETS_VISIBILITY, KEY_VISIBLE = 0x4000, 0x8000


def object_visibility(s, qi):
    """[{piece, keys [[pos, 0 / 1]]}] of sequence qi: the objects whose visibility its keyframes set (the
    Chaingun's three muzzle flashes in "fire"). Same form as export_tribes2's `vis` tracks (ShapeCycles)."""
    names = s['names']
    out = []
    for o in s['objects']:
        for k in range(o.get('firstsub', 0), o.get('firstsub', 0) + o.get('nsub', 0)):
            ss = s['subsequences'][k]
            if ss['seq'] != qi:
                continue
            keys = [s['keyframes'][ss['firstkf'] + j] for j in range(ss['nkf'])]
            keys = [[key_position(kf['pos']), 1 if kf.get('mat', 0) & KEY_VISIBLE else 0]
                    for kf in keys if kf.get('mat', 0) & KEY_SETS_VISIBILITY]
            if keys:
                out.append({'piece': names[o['name']], 'keys': keys})
    return out


def frame_triggers(s, q):
    """[[pos, value]] of a sequence's Darkstar frame triggers (TS::Shape frame trigger: f32 position, i32 value;
    darkstar_dts reads both words as floats).  Armour run cycles carry two, value 1 / 2 = the feet (footsteps)."""
    out = []
    for pos, raw in s.get('triggers', [])[q.get('first_trigger', 0):q.get('first_trigger', 0) + q.get('n_triggers', 0)]:
        value, = struct.unpack('<i', struct.pack('<f', raw))
        out.append([round(pos, 4), value])
    return out


def export_shape(name, ppl):
    path = find_file(name + '.dts')
    s = D.read_shape(open(path, 'rb').read())
    names = s['names']
    pose = root_pose(s)
    ml = s['material_list']['materials'] if s['material_list'] else []
    nmat = s['material_list']['count'] if s['material_list'] else 0

    # ---- textures: one set per shape, entry i = material i of detail 0
    from PIL import Image
    texset = 'tribes_' + name
    tdir = os.path.join(OUT, 'textures', texset)
    os.makedirs(tdir, exist_ok=True)
    meta, pal_names = [], set()
    for i, m in enumerate(ml[:nmat]):
        f = find_file(m['file']) if m['file'] else None
        if not f or (m['flags'] & 0xF) != 3:
            meta.append({'w': 0, 'h': 0, 'file': m['file'], 'palette': None, 'rgb': m['rgb']})
            continue
        b = G.read_pbmp(open(f, 'rb').read())
        pal = G.palette_for(ppl, b['palette_id'])
        pname = '%s_%d' % (WORLD_PPL[1].replace('.ppl', '').replace('.', '_'), pal['id'])
        if pname not in pal_names:
            write_json(os.path.join(OUT, 'palettes', pname + '.json'), [list(c) for c in pal['colors']])
            pal_names.add(pname)
        img = Image.frombytes('L', (b['w'], b['h']), b['pixels'])
        img.save(os.path.join(tdir, '%d.png' % i))
        pimg = Image.frombytes('P', (b['w'], b['h']), b['pixels'])
        pimg.putpalette([c for col in pal['colors'] for c in col])
        pimg.convert('RGBA').save(os.path.join(tdir, '%d_rgba.png' % i))
        meta.append({'w': b['w'], 'h': b['h'], 'file': m['file'], 'palette': pname})
    write_json(os.path.join(OUT, 'textures', texset + '.json'), meta)

    # ---- geometry: winding orientation decided once per shape (outward = majority)
    W = D.world_matrices(dict(s, nodes=[dict(nd, default=pose[i]) for i, nd in enumerate(s['nodes'])]))

    def object_polys(o):
        mesh = s['meshes'][o['mesh']]
        vs = D.mesh_frame_verts(mesh)
        tv = mesh['tverts']
        polys = []
        for f in mesh['faces']:
            vi, ti = (f[0], f[2], f[4]), (f[1], f[3], f[5])
            P = [vs[k] for k in vi]
            n = cross(sub(P[1], P[0]), sub(P[2], P[0]))
            ln = math.sqrt(sum(c * c for c in n)) or 1.0
            polys.append({'v': [[round(c, 5) for c in p] for p in P],
                          'n': [n[0] / ln, n[1] / ln, n[2] / ln],
                          'm': {'kind': 'tex', 'index': f[6] % max(nmat, 1)},
                          't': 'darkstar_tri',
                          'uv': [[round(tv[k][0], 5), round(tv[k][1], 5)] if k < len(tv) else [0, 0] for k in ti]})
        return polys

    # outward test in shape space against the shape centre
    score = 0
    c0 = s['center']
    for o in s['objects']:
        if names[o['name']] == 'bounds':
            continue
        R, T = W[o['node']]
        for p in object_polys(o)[:200]:
            cen = [sum(v[a] for v in p['v']) / 3 for a in range(3)]
            wc = [T[a] + sum(R[a][k] * cen[k] for k in range(3)) for a in range(3)]
            wn = [sum(R[a][k] * p['n'][k] for k in range(3)) for a in range(3)]
            score += 1 if sum(wn[a] * (wc[a] - c0[a]) for a in range(3)) > 0 else -1
    flip = score < 0

    lods = []
    bounds_obj = None
    for di, det in enumerate(s['details']):
        nodes = set(D.detail_nodes(s, di))
        pieces = []
        for oi, o in enumerate(s['objects']):
            if o['node'] not in nodes:
                continue
            if names[o['name']] == 'bounds':
                if bounds_obj is None:
                    R, T = W[o['node']]
                    pts = [[T[a] + sum(R[a][k] * v[k] for k in range(3)) for a in range(3)]
                           for v in D.mesh_frame_verts(s['meshes'][o['mesh']])]
                    bounds_obj = {'min': [round(min(p[a] for p in pts), 4) for a in range(3)],
                                  'max': [round(max(p[a] for p in pts), 4) for a in range(3)]}
                continue
            polys = object_polys(o)
            if flip:
                for p in polys:
                    p['n'] = [-c for c in p['n']]
            # id offset 1000: ShapeInstance treats ids 8-11,18,66,77 as 3Space locator polygons
            piece = {'node': o['node'], 'id': 1000 + oi, 'name': names[o['name']], 'cell': -1, 'state': 0,
                     'polys': polys}
            if o['flags'] & OBJECT_HIDDEN:
                piece['hidden'] = True
            pieces.append(piece)
        lods.append({'radius': s['radius'], 'center': list(s['center']), 'size': det['size'],
                     'root': det['root'], 'pieces': pieces, 'cells': []})
    lods.sort(key=lambda l: -l['size'])

    seqs = []
    for qi, q in enumerate(s['sequences']):
        tracks = []
        for ni, nd in enumerate(s['nodes']):
            for k in range(nd['firstsub'], nd['firstsub'] + nd['nsub']):
                ss = s['subsequences'][k]
                if ss['seq'] == qi:
                    tracks.append({'node': ni, 'keys': [[key_position(s['keyframes'][ss['firstkf'] + j]['pos']),
                                                         s['keyframes'][ss['firstkf'] + j]['tf']]
                                                        for j in range(ss['nkf'])]})
        seq = {'name': names[q['name']], 'cyclic': q['cyclic'], 'duration': q['duration'],
               'priority': q['priority'], 'tracks': tracks}
        vis = object_visibility(s, qi)
        if vis:
            seq['vis'] = vis
        trig = frame_triggers(s, q)
        if trig:
            seq['triggers'] = trig
        seqs.append(seq)

    out = {
        'name': name, 'texset': texset, 'source': 'darkstar_dts_v%d' % s['version'],
        'units': 'metres', 'lods': lods,
        'nodes': [{'parent': nd['parent'], 'default': pose[i], 'name': names[nd['name']]}
                  for i, nd in enumerate(s['nodes'])],
        'transforms': [tf_to_list(t) for t in s['transforms']],
        'ds_sequences': seqs,
        'bounds': {'header': [list(s['bounds'][0]), list(s['bounds'][1])] if s['bounds'] else None,
                   'collision_box': bounds_obj},
        'materials': [{'file': m['file'], 'flags': m['flags'], 'rgb': m['rgb'], 'type': m['type']} for m in ml[:nmat]],
        'winding_flipped': flip,
    }
    write_json(os.path.join(OUT, 'shapes', name + '.json'), out)
    return out


def make_pack_json():
    """The pack's own keys over an existing pack.json (keeps what the importer added, e.g. era / year)."""
    return merge_pack_json(OUT, {'name': 'Starsiege: Tribes', 'default_palette': 'lush_day_1136',
                                 'engine': 'darkstar', 'unit_scale': 256.0})


def main():
    names = sys.argv[1:] or ['larmor']
    ppl = G.read_ppl(open(os.path.join(SRC, *WORLD_PPL), 'rb').read())
    write_json(os.path.join(OUT, 'pack.json'), make_pack_json())
    for n in names:
        j = export_shape(n, ppl)
        print(n, 'lods', len(j['lods']), 'pieces', len(j['lods'][0]['pieces']),
              'polys', sum(len(p['polys']) for p in j['lods'][0]['pieces']), 'flip', j['winding_flipped'])


if __name__ == '__main__':
    main()
