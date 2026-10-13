"""Proof-of-life exporter: Tribes 2 (Torque V12) shapes -> gamedata/tribes2/.

Input:  tribes2/extracted/<vl2 name>/... (the .vl2 archives are plain ZIP; unzip each into a folder of the
        same name, see docs/formats/tribes2.md)
Output (export_es1 / export_tribes shape schema; additions marked [+]):
  pack.json, units.json                        (written by hand / tools/catalog_tribes2.py)
  textures/tribes2_<shape>/<i>.png             truecolour RGBA PNG of material i (copied from the .png in
                                               skins.vl2 / textures.vl2; the .bm8 8-bit twins are ignored)
  textures/tribes2_<shape>.json                [{w, h, file, format: "rgba", path, flags}] per material index;
                                               path = "textures/tribes2_<shape>/<i>.png" relative to the pack
  shapes/<shape>.json:
      lods[]   one per renderable Torque detail level (size >= 0), most detailed first:
               {radius, center, size, name [+], pieces[], cells: []}
      piece    {node, id (1000 + object index), name, cell -1, state 0, polys[]}
      poly     {v: [[x,y,z] x3] node space (metres), n, t: "torque_tri",
                m: {kind: "rgba", index: <material index>}   -> look the texture up in shape.materials[index].texture
                     (or textures/tribes2_<shape>.json[index].path); kind "none" for untextured faces,
                uv [+]: [[u,v] x3] explicit texture coordinates, 0..1, v down (Torque tverts are already top-down)}
      nodes[]  {parent, default, name}; default = transform index of the default pose
      transforms[] [rx, ry, rz, tx, ty, tz] (1/65536 turn Euler, R = Rz*Ry*Rx, same as export_tribes)
      materials [+] [{name, texture, flags, w, h}]   flags = Torque material flags (1 S-wrap, 2 T-wrap,
                     4 translucent, 8 additive, 0x20 self-illuminating, 0x40 never-env-map ...)
      ds_sequences [+] in-shape sequences, then the armour animations of the TSShapeConstructor (<name>.cs:
                     the .dsq files, named as it names them: root, run, back, side, fall, jet, land, jump,
                     death1-11 ...) {name, cyclic, duration, priority, tracks [{node, keys [[pos, tf]]}],
                     triggers [[pos, state]] (footsteps: 1 left, 2 right), ground [x, y, z] (travel per cycle)}
      bounds [+]  {header: [min, max]}
  Objects whose default visibility is 0 (e.g. Jetfire, the Spinfusor's loaded disc) are exported with
  "hidden": true (a sequence's `vis` track shows them); decal meshes (bullet holes / damage decals) are skipped.

Usage: python tools/export_tribes2.py [shape ...]   (default: light_male vehicle_grav_scout)
"""
import json, math, os, re, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torque_dts as T
from export_tribes import mat_to_euler

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SRC = os.path.join(ROOT, 'tribes2', 'extracted')
OUT = os.path.join(ROOT, 'gamedata', 'tribes2')
_index = None


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, separators=(',', ':'))


def index():
    global _index
    if _index is None:
        _index = {}
        for dp, dn, fn in os.walk(SRC):
            for f in fn:
                _index.setdefault(f.lower(), os.path.join(dp, f))
    return _index


def find_texture(name):
    base = name.replace('\\', '/').split('/')[-1].lower()
    for ext in ('.png', '.jpg', '.bmp'):
        p = index().get(base + ext)
        if p:
            return p
    return None


def tf_list(q, t):
    return mat_to_euler(T.quat_to_mat(q)) + [round(x, 5) for x in t]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


IFL_MATERIAL = 0x08000000      # Torque TSMaterialList::IflMaterial: the name is an image file list (.ifl)
IFL_FPS = 30.0                 # one IFL duration unit = 1/30 s (fx_tribes2_torque)


def save_rgba(src, texset, stem):
    from PIL import Image
    img = Image.open(src).convert('RGBA')
    rel = 'textures/%s/%s.png' % (texset, stem)
    img.save(os.path.join(OUT, *rel.split('/')))
    return rel, img


def ifl_frames(name):
    """[(frame bitmap path, duration units)] of the material's image file list, [] if it has none."""
    base = name.replace('\\', '/').split('/')[-1].lower()
    path = index().get(os.path.splitext(base)[0] + '.ifl')
    if not path:
        return []
    frames = []
    with open(path, encoding='latin1') as f:
        for line in f:
            parts = line.split()
            src = find_texture(os.path.splitext(parts[0])[0]) if parts else None
            if src:
                frames.append((src, int(float(parts[1])) if len(parts) > 1 else 1))
    return frames


def export_material(texset, i, m):
    """Material i: the bitmap as texture; an IFL material (flag 0x08000000) shows its first frame and lists
    every frame under `ifl` {frames, durations, fps} (old shapes such as plasmabolt name the .ifl)."""
    ent = {'name': m['name'], 'flags': m['flags'], 'texture': None, 'w': 0, 'h': 0}
    frames = ifl_frames(m['name']) if m['flags'] & IFL_MATERIAL else []
    src = frames[0][0] if frames else find_texture(m['name'])
    if not src:
        return ent
    rel, img = save_rgba(src, texset, str(i))
    ent.update(texture=rel, w=img.width, h=img.height)
    if frames:
        ent['ifl'] = {'frames': [save_rgba(f, texset, '%d_%d' % (i, k))[0] for k, (f, _) in enumerate(frames)],
                      'durations': [d for _, d in frames], 'fps': IFL_FPS}
    return ent


# An object whose default visibility is at most this starts hidden (a sequence's visibility track may show it:
# the Spinfusor's loaded disc in DiscSpin / Reload; the armours' jet flames).
HIDDEN_VISIBILITY = 0.01
TRIGGER_STATE_ON = 0x80000000          # TSShape::Trigger StateOn
TRIGGER_STATE_MASK = 0x3FFFFFFF        # the trigger's state bits (1 left foot, 2 right foot: Player footsteps)


def keys_pos(j, nk, cyclic):
    """Cycle position of key j of nk: a cyclic sequence spreads its keys over the whole cycle."""
    return round(j / (nk if cyclic else max(nk - 1, 1)), 4)


def make_sequence(shape, q, seq_name, src, node_map, transforms):
    """One sequence for shapes/<name>.json: tracks of [[pos, transform index]] per shape node.  `src` holds the
    keyframe arrays (the shape itself, or a .dsq) and `node_map` maps src node indices to shape nodes (-1: none).
    A cyclic sequence spreads its keys over the whole cycle and wraps back to the first (Torque interpolates the
    last key into the first); others end on their last key.  Extra fields: `triggers` [[pos, state]] (the
    StateOn triggers: footsteps), `ground` [x, y, z] the ground travel of one cycle (metres, shape frame), `vis`
    [{piece, keys [[pos, visibility]]}] the objects whose visibility the sequence animates."""
    nk = q['num_keyframes']
    cyclic = bool(q['flags'] & T.SEQUENCE_FLAG_CYCLIC)
    rm, tm = q['rot_matters'], q['trans_matters']
    tracks = []
    for si in sorted(set(rm) | set(tm)):
        ni = node_map[si] if si < len(node_map) else -1
        if ni < 0:
            continue
        keys = []
        for j in range(nk):
            rot = src['node_rotations'][q['base_rotation'] + rm.index(si) * nk + j] if si in rm else shape['default_rotations'][ni]
            tr = src['node_translations'][q['base_translation'] + tm.index(si) * nk + j] if si in tm else shape['default_translations'][ni]
            transforms.append(tf_list(rot, tr))
            keys.append([keys_pos(j, nk, cyclic), len(transforms) - 1])
        if cyclic and nk > 1:
            keys.append([1.0, keys[0][1]])
        tracks.append({'node': ni, 'keys': keys})
    out = {'name': seq_name, 'cyclic': cyclic or None, 'flags': q['flags'], 'duration': q['duration'],
           'priority': q['priority'], 'tracks': tracks}
    states = src.get('object_states', [])
    vis = []
    for k, oi in enumerate(q.get('vis_matters', [])):
        first = q['base_object_state'] + k * nk
        if oi < len(shape['objects']) and first + nk <= len(states):
            vis.append({'piece': shape['names'][shape['objects'][oi]['name']],
                        'keys': [[keys_pos(j, nk, cyclic), round(states[first + j][0], 3)] for j in range(nk)]})
    if vis:
        out['vis'] = vis
    trig = src.get('triggers', [])[q['first_trigger']:q['first_trigger'] + q['num_triggers']]
    if trig:
        out['triggers'] = [[round(pos, 4), state & TRIGGER_STATE_MASK] for state, pos in trig if state & TRIGGER_STATE_ON]
    ground = src.get('ground_translations', [])
    if q['num_ground'] > 0 and q['first_ground'] + q['num_ground'] <= len(ground):
        out['ground'] = [round(v, 4) for v in ground[q['first_ground'] + q['num_ground'] - 1]]
    return out


def constructor_sequences(name):
    """[(dsq file, sequence name)] of the shape's TSShapeConstructor (<name>.cs: sequenceN = "file.dsq name")."""
    path = index().get(name.lower() + '.cs')
    if not path:
        return []
    out = []
    with open(path, encoding='latin1') as f:
        for line in f:
            m = re.match(r'\s*sequence(\d+)\s*=\s*"([^"\s]+)\s+([^"]+)"', line)
            if m:
                out.append((int(m.group(1)), m.group(2), m.group(3).strip()))
    return [(dsq, seq) for _, dsq, seq in sorted(out)]


def external_sequences(name, shape, names, transforms):
    """The armour animations of the TSShapeConstructor (root, run, back, side, fall, jet, land, jump, death1-11,
    ...): each .dsq read with torque_dts.read_dsq, its nodes matched to the shape's by name (case-insensitive),
    named as the constructor names it.  Missing or empty .dsq files are skipped."""
    by_name = {names[nd['name']].lower(): i for i, nd in enumerate(shape['nodes'])}
    seqs = []
    for dsq, seq_name in constructor_sequences(name):
        path = index().get(dsq.lower())
        data = open(path, 'rb').read() if path else b''
        if not data:
            print('  %s: %s missing or empty, skipped' % (name, dsq))
            continue
        d = T.read_dsq(data)
        node_map = [by_name.get(n.lower(), -1) for n in d['nodes']]
        seqs += [make_sequence(shape, q, seq_name, d, node_map, transforms) for q in d['sequences']]
    return seqs


def export_shape(name):
    path = index()[name.lower() + '.dts']
    s = T.read_shape(open(path, 'rb').read())
    names = s['names']
    texset = 'tribes2_' + name
    tdir = os.path.join(OUT, 'textures', texset)
    os.makedirs(tdir, exist_ok=True)
    mats = [export_material(texset, i, m) for i, m in enumerate(s['materials'])]
    write_json(os.path.join(OUT, 'textures', texset + '.json'),
               [{'w': m['w'], 'h': m['h'], 'file': m['name'], 'format': 'rgba', 'path': m['texture'],
                 'flags': m['flags']} for m in mats])

    W = T.world_matrices(s)
    nobj = len(s['objects'])
    vis = [s['object_states'][i][0] if i < len(s['object_states']) else 1.0 for i in range(nobj)]

    def mesh_polys(mesh):
        v = mesh['verts']
        tv = mesh['tverts']
        nv = len(v) // 3
        out = []
        for a, b, c, mi in T.mesh_triangles(mesh):
            if max(a, b, c) >= nv:
                continue
            P = [v[3 * k:3 * k + 3] for k in (a, b, c)]
            n = cross([P[1][j] - P[0][j] for j in range(3)], [P[2][j] - P[0][j] for j in range(3)])
            ln = math.sqrt(sum(x * x for x in n)) or 1.0
            uv = [[round(tv[2 * k], 5), round(tv[2 * k + 1], 5)] if 2 * k + 1 < len(tv) else [0, 0] for k in (a, b, c)]
            out.append({'v': [[round(x, 5) for x in p] for p in P], 'n': [x / ln for x in n],
                        'm': {'kind': 'rgba' if 0 <= mi < len(mats) and mats[mi]['texture'] else 'none',
                              'index': mi},
                        't': 'torque_tri', 'uv': uv})
        return out

    lods = []
    score = 0
    for d in s['details']:
        if d['size'] < 0:
            continue
        ss = d['subshape']
        o0 = s['subshape_first_object'][ss]
        pieces = []
        for oi in range(o0, o0 + s['subshape_num_objects'][ss]):
            o = s['objects'][oi]
            k = d['object_detail']
            if k >= o['num_meshes']:
                continue
            mesh = s['meshes'][o['start_mesh'] + k]
            if mesh['type'] not in (0, 1, 3) or not mesh.get('verts'):
                continue
            polys = mesh_polys(mesh)
            if not polys:
                continue
            if not lods:
                R, Tt = W[o['node']] if o['node'] >= 0 else ([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [0, 0, 0])
                for p in polys[:300]:
                    cen = [sum(v[j] for v in p['v']) / 3 for j in range(3)]
                    wc = [Tt[a] + sum(R[a][j] * cen[j] for j in range(3)) for a in range(3)]
                    wn = [sum(R[a][j] * p['n'][j] for j in range(3)) for a in range(3)]
                    score += 1 if sum(wn[a] * (wc[a] - s['center'][a]) for a in range(3)) > 0 else -1
            piece = {'node': max(o['node'], 0), 'id': 1000 + oi, 'name': names[o['name']], 'cell': -1,
                     'state': 0, 'polys': polys}
            if vis[oi] <= HIDDEN_VISIBILITY:
                piece['hidden'] = True
            pieces.append(piece)
        lods.append({'radius': s['radius'], 'center': s['center'], 'size': d['size'], 'name': names[d['name']],
                     'pieces': pieces, 'cells': []})
    flip = score < 0
    if flip:
        for l in lods:
            for pc in l['pieces']:
                for p in pc['polys']:
                    p['n'] = [-x for x in p['n']]
    lods.sort(key=lambda l: -l['size'])

    nn = len(s['nodes'])
    transforms = [tf_list(s['default_rotations'][i], s['default_translations'][i]) for i in range(nn)]
    seqs = [make_sequence(s, q, names[q['name']], s, list(range(nn)), transforms) for q in s['sequences']]
    seqs += external_sequences(name, s, names, transforms)

    b = s['bounds']
    out = {
        'name': name, 'texset': texset, 'source': 'torque_dts_v%d' % s['version'], 'units': 'metres',
        'lods': lods,
        'nodes': [{'parent': nd['parent'], 'default': i, 'name': names[nd['name']]} for i, nd in enumerate(s['nodes'])],
        'transforms': transforms,
        'ds_sequences': seqs,
        'bounds': {'header': [b[0:3], b[3:6]]},
        'materials': mats,
        'winding_flipped': flip,
    }
    write_json(os.path.join(OUT, 'shapes', name + '.json'), out)
    return out


def main():
    names = sys.argv[1:] or ['light_male', 'vehicle_grav_scout']
    if not os.path.exists(os.path.join(OUT, 'pack.json')):
        write_json(os.path.join(OUT, 'pack.json'), {'name': 'Tribes 2', 'engine': 'torque_v12', 'unit_scale': 256.0,
                                                    'texture_format': 'rgba'})
    for n in names:
        j = export_shape(n)
        l0 = j['lods'][0]
        print(n, 'lods', len(j['lods']), 'pieces', len(l0['pieces']), 'polys', sum(len(p['polys']) for p in l0['pieces']),
              'flip', j['winding_flipped'])


if __name__ == '__main__':
    main()
