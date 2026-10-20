"""Animated Aerial Assault soldiers: the .SHP's bone-local parts, default pose and decoded sequences (aa_anim) -> engine shape JSON
with a 16-node skeleton, the transforms table and ds_sequences named as the engine's infantry animation expects
(root, run, back, side, jet, fall, land, death1..). The soldier is turned to face the engine's +y (forward): file (X, Y, Z) ->
shape frame (x, y, z) = (-X, Z, Y)."""
import numpy as np

import aa_anim
import aa_shape

M = np.array([[-1.0, 0, 0], [0, 0, 1.0], [0, 1.0, 0]])         # file axes -> shape frame (right, forward, up)
ROLE = {'idle': 'root', 'forward': 'run', 'back': 'back', 'side': 'side', 'jet': 'jet', 'jumpup': 'jump', 'jump': 'jump', 'fall': 'fall',
        'land': 'land', 'sitting': 'sitting', 'idlepda': 'pda'}
DEATHS = ('dieforward', 'dieback', 'diechest', 'diehead', 'dieknees', 'dieleglf', 'dielegrt', 'diesidelf', 'diesidert',
          'dieslump', 'diespin')
# additive sequences (deltas on top of the pose below: recoil, aim pitch, head turns): key -> exported name
ADDITIVE = {'recoilde': 'recoil', 'recoil': 'recoil', 'lookde': 'look', 'lookms': 'lookms', 'lookmsrocket': 'looksn',
            'rocketposelooksn': 'looksn', 'head': 'head', 'headside': 'headside'}
ONE_SHOT = ('jumpup', 'land', 'sitting') + DEATHS
ARMS, FEET = (6, 9), (12, 15)         # tip bones of the two arm and the two leg chains (humans)
TIPS = {aa_shape.BIODERM_PARENTS: ((5, 7), (11, 15)), aa_shape.HEAVY_BIODERM_PARENTS: ((6, 8), (11, 14))}


def _key(name):
    """Sequence name ('Medium_male_idle', 'bioderm_light_death_leglft') -> the soldiers' key ('idle', 'dieleglf')."""
    k = name.split('_', 2)[2].lower().replace('_', '')
    return k.replace('death', 'die').replace('lft', 'lf')


def _euler(r):
    """Rotation matrix (shape frame) -> (rx, ry, rz) in 1/65536 turn for R = Rz(c) Ry(b) Rx(a) (ShapeInstance.tf_to_transform)."""
    sy = -r[2, 0]
    b = np.arcsin(np.clip(sy, -1, 1))
    if abs(sy) < 0.99999:
        a, c = np.arctan2(r[2, 1], r[2, 2]), np.arctan2(r[1, 0], r[0, 0])
    else:
        a, c = 0.0, np.arctan2(-r[0, 1], r[1, 1])
    return [float(v) * 65536.0 / (2 * np.pi) for v in (a, b, c)]


def _tf(quat, trans):
    return _tf_matrix(aa_shape._quat_matrix(quat), trans)


def _tf_matrix(rot, trans):
    r = M @ rot @ M.T
    return [round(v, 4) for v in _euler(r)] + [round(float(v), 5) for v in M @ np.asarray(trans, float)]


def _world(rot, pos, parents=aa_shape.SOLDIER_PARENTS):
    """Bone world (R, t) in file axes for one frame; rot (bones, 4), pos (bones, 3)."""
    out = []
    for k in range(len(rot)):
        r = aa_shape._quat_matrix(rot[k])
        p = parents[k]
        if p < 0:
            out.append((r, np.asarray(pos[k], float)))
        else:
            rp, tp = out[p]
            out.append((rp @ r, tp + rp @ pos[k]))
    return out


def _right_first(bones, rot, pos, parents=aa_shape.SOLDIER_PARENTS):
    """The two bones ordered right (shape-frame +x) first."""
    w = _world(rot, pos, parents)
    return sorted(bones, key=lambda b: -(M @ w[b][1])[0])


def _ground_and_steps(seq, feet, axis=1, parents=aa_shape.SOLDIER_PARENTS):
    """Travel per cycle of a move sequence (both feet's backward swing relative to the pelvis, metres) and footstep triggers
    [[pos, 1 left | 2 right]] at each foot's forward-most frame. `feet` = (left, right)."""
    n = seq['frames']
    fwd = np.zeros((n, 2))
    for f in range(n):
        w = _world(seq['rot'][f], seq['pos'][f], parents)
        for j, b in enumerate(feet):
            fwd[f, j] = (M @ (w[b][1] - w[0][1]))[axis]
    travel = float((fwd.max(0) - fwd.min(0)).sum())
    steps = [[round(int(np.argmax(fwd[:, j])) / n, 4), 1 + j] for j in range(2)]
    return travel, sorted(steps)


def _rotation_between(d, y):
    axis = np.cross(d, y)
    ang = float(np.arccos(np.clip(d @ y, -1, 1)))
    if np.linalg.norm(axis) < 1e-6:
        axis, ang = np.array([0, 0, 1.0]), (0.0 if d @ y > 0 else np.pi)
    axis = axis / np.linalg.norm(axis)
    kx = np.array([[0, -axis[2], axis[1]], [axis[2], 0, -axis[0]], [-axis[1], axis[0], 0]])
    return np.eye(3) + np.sin(ang) * kx + (1 - np.cos(ang)) * kx @ kx


def rigged_json(data, texture_path):
    """Soldier .SHP bytes -> engine shape JSON with skeleton and animation; ValueError when it is not a 16-bone soldier."""
    sh = aa_shape.decode(data)
    if not any('local' in m for m in sh['meshes']):
        raise ValueError('not a 16-bone soldier')
    for m in sh['meshes']:
        if 'local' in m:
            p = m['local']
            m['local_override'] = np.stack([p[:, 2], p[:, 1], -p[:, 0]], 1)   # to_json maps (x, y, z) -> (z, x, y) = (-X, Z, Y)
    js = aa_shape.to_json(sh, texture_path)
    bl = aa_shape.bones(data)
    rest_rot = np.array([b[0] for b in bl])
    rest_pos = np.array([b[1] for b in bl])
    seqs = {_key(s['name']): s for s in aa_anim.sequences(data) if 'rot' in s}
    parents = aa_shape.skeleton_of(data, len(bl))
    arms, feet = TIPS.get(parents, (ARMS, FEET))
    rhand = _right_first(arms, rest_rot, rest_pos, parents)[0]
    rfoot, lfoot = _right_first(feet, rest_rot, rest_pos, parents)
    transforms = [_tf(rest_rot[k], rest_pos[k]) for k in range(len(bl))]
    nodes = [{'parent': parents[k], 'default': k, 'name': 'bone%d' % k} for k in range(len(bl))]
    # weapon mount on the right hand, its forward (+y) along the limb
    limb = np.array([0, 1.0, 0])
    for p in js['lods'][0]['pieces']:
        if p['node'] == rhand:
            pts = np.array([v for poly in p['polys'] for v in poly['v']])
            limb = pts.mean(0)
    d = limb / max(np.linalg.norm(limb), 1e-9)
    transforms.append([round(v, 4) for v in _euler(_rotation_between(d, np.array([0, 1.0, 0])))] + [0.0, 0.0, 0.0])
    nodes.append({'parent': rhand, 'default': len(transforms) - 1, 'name': 'mount0'})
    out_seqs = []

    def add(name, src, cyclic, move=False):
        n = src['frames']
        track_n = n + 1 if cyclic and n > 1 else n
        tracks = []
        for b in range(len(bl)):
            keys = []
            for i in range(track_n):
                f = i % n
                transforms.append(_tf(src['rot'][f, b], src['pos'][f, b]))
                keys.append([round(i / max(track_n - 1, 1), 5), len(transforms) - 1])
            tracks.append({'node': b, 'keys': keys})
        seconds = max(track_n - 1, 1) / src['fps'] if n > 1 else 1.0
        seq = {'name': name, 'cyclic': cyclic, 'flags': 0, 'duration': seconds, 'priority': 0, 'tracks': tracks,
               'ground': [0.0, 0.0, 0.0]}
        if move:
            travel, steps = _ground_and_steps(src, (lfoot, rfoot), 0 if name == 'side' else 1, parents)
            seq['ground'] = [-travel, 0.0, 0.0] if name == 'side' else [0.0, travel * (-1.0 if name == 'back' else 1.0), 0.0]
            seq['triggers'] = steps
        out_seqs.append(seq)

    def add_additive(name, src):
        """A delta sequence (identity rotation / zero translation = no change; the look, head and recoil poses): exported as the
        bone's rest pose with the delta composed on top, for the bones it moves only, flagged additive (Torque flags 40)."""
        n = src['frames']
        tracks = []
        for b in range(len(bl)):
            if np.ptp(src['rot'][:, b], axis=0).max() < 1e-5 and np.ptp(src['pos'][:, b], axis=0).max() < 1e-5:
                continue
            keys = []
            for f in range(n):
                rot = aa_shape._quat_matrix(rest_rot[b]) @ aa_shape._quat_matrix(src['rot'][f, b])
                transforms.append(_tf_matrix(rot, rest_pos[b] + src['pos'][f, b]))
                keys.append([round(f / max(n - 1, 1), 5), len(transforms) - 1])
            tracks.append({'node': b, 'keys': keys})
        out_seqs.append({'name': name, 'cyclic': False, 'flags': 40, 'additive': True, 'duration': max(n - 1, 1) / src['fps'],
                         'priority': 0, 'tracks': tracks, 'ground': [0.0, 0.0, 0.0]})

    for key, name in ROLE.items():
        if key in seqs:
            add(name, seqs[key], key not in ONE_SHOT, name in ('run', 'back', 'side'))
    if 'jet' not in seqs and 'fall' in seqs:          # the light male has no jet pose: it falls
        add('jet', seqs['fall'], True)
    k = 0
    for key in DEATHS:
        if key in seqs:
            k += 1
            add('death%d' % k, seqs[key], False)
    done = set()
    for key, name in ADDITIVE.items():
        if key in seqs and name not in done:
            done.add(name)
            add_additive(name, seqs[key])
    js['nodes'], js['transforms'], js['ds_sequences'] = nodes, transforms, out_seqs
    js['source'] = 'aa_shp_rigged'
    js['bounds'] = {'header': [[-1.0, -1.0, 0.0], [1.0, 1.0, 2.5]]}
    return js
