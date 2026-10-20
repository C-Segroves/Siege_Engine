"""Animated Aerial Assault turrets (.SHP with a node table: turret bases, barrels, the sentry) -> engine shape JSON with a node
tree, default pose and the Activate / Turn / Elevate / Deploy / Fire sequences the Tribes turret rig drives (TribesTurretRig).

What the file holds (the shapes are the Tribes 2 turrets, rebuilt for the PS2):
  * the node table (aa_shape.node_boxes): parent index and the bounds of the part's VIF batches, which are in the NODE's own
    local frame (the parts are not pre-transformed; a mirrored part is stored point-inverted);
  * after the geometry, blocks (aa_anim.node_blocks) of the soldier layout, one record per node (quaternion + translation,
    local to the parent): first the default pose (deployed), then the sequences in file order. A node without a parent is
    in the file frame, which is the Tribes 2 frame turned by M (T2 x right, y forward, z up -> file (-X, Z, Y)); a child's
    local transform equals the Tribes 2 one;
  * the exporter re-centred some parts, so a node's origin is not always where Tribes 2 has it; the records account for it.
The result is expressed in the Tribes 2 frame (right, forward, up): a root node's local transform is M times its record, a
child's is the record itself, and the parts keep their own local coordinates.
Sequences are named by what moves: one node turning through a full revolution = Turn, any other single node = Elevate, several
nodes = Activate (a barrel: Deploy, then Fire1, Fire2).
"""
import numpy as np

import aa_anim
import aa_shape
import aa_soldier

M = aa_soldier.M          # file axes (X, Y up, Z) -> Tribes 2 frame (right, forward, up); its own inverse
MOUNT = 'Mount0'          # where a barrel shape sits on a base (the base's own node, as in Tribes 2)


def sequence_blocks(data, nodes):
    """The pose block and the sequence blocks of the first state (before the shape's damaged copy)."""
    blocks = aa_anim.node_blocks(data, nodes)
    cut = data.rfind(b'_damage')
    return [b for b in blocks if cut < 0 or b['at'] < cut]


def _angle(q0, q1):
    return 2 * np.degrees(np.arccos(min(1.0, abs(float(np.dot(q0, q1))))))


def _moving(block, tol=1e-4):
    return [k for k in range(block['rot'].shape[1])
            if np.ptp(block['rot'][:, k], axis=0).max() > tol or np.ptp(block['pos'][:, k], axis=0).max() > tol]


def name_sequences(blocks):
    """-> [(name, block)] for the multi-frame blocks after the pose blocks. A base or sentry has a full revolution of one node
    (Turn); then a single other node is Elevate and the first block that moves several is Activate. A barrel has no Turn: its
    first block is Deploy and the rest are Fire1, Fire2."""
    seqs = [b for b in blocks[1:] if b['frames'] > 1]

    def is_turn(b):
        mv = _moving(b)
        return len(mv) == 1 and _angle(b['rot'][0, mv[0]], b['rot'][b['frames'] // 2, mv[0]]) > 150.0
    has_turn = any(is_turn(b) for b in seqs)
    out, fires = [], 0
    activated = False
    for b in seqs:
        single = len(_moving(b)) == 1
        if has_turn and single:
            out.append(('Turn' if is_turn(b) else 'Elevate', b))
        elif not activated:
            activated = True
            out.append(('Activate' if has_turn else 'Deploy', b))
        else:
            fires += 1
            out.append(('Fire%d' % fires, b))
    return out


def _local(quat, trans, root, frame=M):
    """Node-local transform in the Tribes 2 frame -> [rx, ry, rz in 1/65536 turn, x, y, z]."""
    r = aa_shape._quat_matrix(quat)
    t = np.asarray(trans, float)
    if root:
        r, t = frame @ r, frame @ t
    return [round(v, 4) for v in aa_soldier._euler(r)] + [round(float(v), 5) for v in t]


def _assign(meshes, boxes):
    """Node of every mesh (a batch): the smallest node box that holds it; equal boxes (a part and its twin) in node order."""
    cur = 0
    out = []
    for m in meshes:
        lo, hi = m['pos'].min(0), m['pos'].max(0)
        tol = 0.04 + 0.01 * float(abs(hi - lo).max())
        fits = sorted((float(np.prod(np.array(b[3:]) - np.array(b[:3]) + 1e-3)), k) for k, (_p, b) in enumerate(boxes)
                      if np.all(lo >= np.array(b[:3]) - tol) and np.all(hi <= np.array(b[3:]) + tol))
        if not fits:
            raise ValueError('a part lies in no node')
        best = [k for v, k in fits if v <= fits[0][0] * 1.01]
        node = next((k for k in best if k >= cur), best[0])
        out.append(node)
        cur = node
    return out


def _world(pose, parents):
    out = []
    for k in range(len(parents)):
        r = aa_shape._quat_matrix(pose['rot'][0, k])
        t = np.asarray(pose['pos'][0, k], float)
        if parents[k] < 0:
            out.append((r, t))
        else:
            rp, tp = out[parents[k]]
            out.append((rp @ r, tp + rp @ t))
    return out


def _add_mount(nodes, transforms, owner, meshes, pose, elevate, parents):
    """The barrel mount: a child of the elevating node at the middle of the sleeve (the first part hanging on it), turned like it."""
    sleeve = next((k for k in range(len(parents)) if parents[k] == elevate and k in owner), None)
    if sleeve is None:
        return
    pts = np.vstack([m['pos'] for m, k in zip(meshes, owner) if k == sleeve])
    centre = (pts.min(0) + pts.max(0)) / 2
    r = aa_shape._quat_matrix(pose['rot'][0, sleeve])
    t = np.asarray(pose['pos'][0, sleeve], float) + r @ centre
    transforms.append([0.0, 0.0, 0.0] + [round(float(v), 5) for v in t])
    nodes.append({'parent': elevate, 'default': len(transforms) - 1, 'name': MOUNT})


def rigged_json(data, texture_path, nose=None):
    """Turret .SHP bytes -> engine shape JSON with nodes, default pose and sequences. ValueError when it has no pose block or
    no sequences (not a rigged shape). `nose` = 'back' for a shape whose nose is at the Tribes 2 frame's -y (the transport): it is turned
    half a turn about the up axis so that it faces +y. The pose block is the first single-frame block (the transport stores it
    after its sequence)."""
    boxes = aa_shape.node_boxes(data)
    if not boxes:
        raise ValueError('no node table')
    n = len(boxes)
    blocks = sequence_blocks(data, n)
    first = next((b for b in blocks if b['frames'] == 1), None)
    if first is None:
        raise ValueError('no node pose block')
    blocks = [first] + [b for b in blocks if b is not first]
    frame = M if nose is None else np.diag([-1.0, -1.0, 1.0]) @ M
    seqs = name_sequences(blocks)
    if not seqs:
        raise ValueError('no sequences')
    sh = aa_shape.decode(data, assemble=False, loose=True)
    owner = _assign(sh['meshes'], boxes)
    for m, node in zip(sh['meshes'], owner):
        p = m['pos']
        m['bone'] = node
        m['local_override'] = np.stack([p[:, 1], p[:, 2], p[:, 0]], 1)     # to_json maps (x, y, z) -> (z, x, y): keep the frame
    js = aa_shape.to_json(sh, texture_path)
    pose = blocks[0]
    parents = [p for p, _b in boxes]
    transforms = [_local(pose['rot'][0, k], pose['pos'][0, k], parents[k] < 0, frame) for k in range(n)]
    nodes = [{'parent': parents[k], 'default': k, 'name': 'node%d' % k} for k in range(n)]
    out_seqs = []
    elevate = turn = None
    for name, b in seqs:
        mv = _moving(b)
        if name == 'Elevate':
            elevate = mv[0]
        if name == 'Turn':
            turn = mv[0]
        tracks = []
        for k in mv:
            keys = []
            for f in range(b['frames']):
                transforms.append(_local(b['rot'][f, k], b['pos'][f, k], parents[k] < 0, frame))
                keys.append([round(f / (b['frames'] - 1), 5), len(transforms) - 1])
            tracks.append({'node': k, 'keys': keys})
        out_seqs.append({'name': name, 'cyclic': None, 'flags': 0, 'duration': (b['frames'] - 1) / b['fps'], 'priority': 0,
                         'tracks': tracks})
    if turn is not None:
        nodes[turn]['name'] = 'DumTurn'
    if elevate is not None:
        nodes[elevate]['name'] = 'DumElevate'
        _add_mount(nodes, transforms, owner, sh['meshes'], pose, elevate, parents)
    world = _world(pose, parents)             # bounds and radius in the Tribes 2 frame at the default pose
    pts = []
    for m, node in zip(sh['meshes'], owner):
        r, t = world[node]
        pts.append((m['pos'] @ r.T + t) @ frame.T)
    pts = np.vstack(pts)
    lo, hi = pts.min(0), pts.max(0)
    js['nodes'], js['transforms'], js['ds_sequences'] = nodes, transforms, out_seqs
    js['source'] = 'aa_shp_rigged'
    js['bounds'] = {'header': [[float(v) for v in lo], [float(v) for v in hi]]}
    lod = js['lods'][0]
    lod['radius'] = float(np.linalg.norm(hi - lo) / 2)
    lod['center'] = [float(v) for v in (lo + hi) / 2]
    return js
