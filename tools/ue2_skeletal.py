"""Unreal Engine 2.5 skeletal meshes and mesh animations (Tribes: Vengeance, package version 130).

SkeletalMesh export (after the 12-byte object prefix and the tagged properties):
  FBox (min, max, valid byte) + FSphere (centre, radius)            41 bytes
  u32 version?, u32 point count, u8, materials (compact count + object refs),
  FVector MeshScale, FVector MeshOrigin, 3 x i32 RotOrigin,
  ... LOD collapse data, sockets (names + bone indices + transforms) ...
  compact count + FMeshBone[count]  (name, u32 flags, FQuat orientation (x y z w), FVector position, f32 length,
                                      FVector size, i32 child count, i32 parent)        57 bytes each
  ... then, found by validation (the stream between them is the progressive-mesh data of this engine):
  wedges      compact count n + n x (u16 point, f32 U, f32 V)         10 bytes
  u32
  triangles   compact count m + m x (u16 wedge a, b, c, u16 material)  8 bytes
  u32
  points      compact count p + p x FVector                            12 bytes (mesh space, Unreal units)
  influences  compact count k + k x (f32 weight, u16 point, u16 bone)  8 bytes (far behind the points)
Rotations: the bone quaternions are stored with w negated for every bone but the root (the usual Unreal skeletal
convention); with that, forward kinematics puts each bone inside the vertices it moves (checked: mean distance 7 units).

MeshAnimation export: u32 version (6), compact count + FNamedBone[count] (name, u32 flags, i32 parent, 9 bytes),
compact count of motion chunks, each: FVector root speed, f32 track time, i32 start bone, u32 flags, compact count +
i32 bone indices, compact count + FAnalogTrack (u32 flags, compact count + FQuat keys, compact count + FVector keys,
compact count + f32 key times), the root track (same layout) and one spare byte; then compact count + FMeshAnimSeq:
16 bytes of unknown data, name, compact group count (+ names), i32 start frame, i32 frame count, compact notify count
(+ (f32 time, compact function name, compact object ref) each), f32 rate. Sequence i uses motion chunk i.
See docs/formats/tribes_vengeance.md.
"""
import struct

import numpy as np

import ue2_package as U

BONE_SIZE = 57
EXPORT_PREFIX = 12


class MeshError(Exception):
    pass


def _encode_index(v):
    out = []
    first = v & 0x3F
    v >>= 6
    if v:
        first |= 0x40
    out.append(first)
    while v:
        b = v & 0x7F
        v >>= 7
        if v:
            b |= 0x80
        out.append(b)
    return bytes(out)


def _try_index(d, p):
    """(value, next position) of a non-negative compact index at p, or None."""
    try:
        b = d[p]
        if b & 0x80:
            return None
        v = b & 0x3F
        q = p + 1
        if b & 0x40:
            shift = 6
            while True:
                b = d[q]
                q += 1
                v |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
        return v, q
    except IndexError:
        return None


# ------------------------------------------------------------------------------------------------ skeletal mesh
def _read_bones(pkg, d, pos):
    """(bones, end) of the bone array whose count is at pos, or None when it does not validate."""
    head = _try_index(d, pos)
    if head is None or not 1 <= head[0] <= 400:
        return None
    n, q = head
    if q + n * BONE_SIZE > len(d):
        return None
    bones = []
    r = U.Reader(d, q)
    for i in range(n):
        ni = r.index()
        if not 0 <= ni < len(pkg.names):
            return None
        flags = r.u32()
        quat = struct.unpack_from('<4f', d, r.p)
        position = struct.unpack_from('<3f', d, r.p + 16)
        r.p += 44
        children, parent = r.i32(), r.i32()
        norm = sum(c * c for c in quat)
        if flags > 0xFF or not 0.9 < norm < 1.1 or not 0 <= children <= n or not (0 <= parent < max(i, 1)):
            return None
        if i == 0 and parent != 0:
            return None
        if not all(abs(c) < 1e5 for c in position):
            return None
        bones.append({'name': pkg.names[ni], 'quat': quat, 'pos': position, 'parent': parent if i else -1})
    return bones, r.p


def _find_bones(pkg, d, start):
    for pos in range(start, min(len(d) - BONE_SIZE, start + 40000)):
        got = _read_bones(pkg, d, pos)
        if got is not None:
            return got
    return None


def _find_geometry(d, start):
    """(wedges, triangles, points, end, wedge offset) found from `start`: wedge array, dword, triangle array, dword, point array."""
    size = len(d)
    wedge_dt = np.dtype([('i', '<u2'), ('u', '<f4'), ('v', '<f4')])
    tri_dt = np.dtype([('w', '<u2', 3), ('m', '<u2')])
    pos = start
    while pos < size - 100:
        head = _try_index(d, pos)
        if head is None or not 100 <= head[0] <= 30000:
            pos += 1
            continue
        n, q = head
        wend = q + 10 * n
        if wend + 6 > size:
            pos += 1
            continue
        w0 = struct.unpack_from('<Hff', d, q)
        if w0[0] > n or not (abs(w0[1]) < 1e4 and abs(w0[2]) < 1e4):
            pos += 1
            continue
        thead = _try_index(d, wend + 4)
        if thead is None or not 10 <= thead[0] <= 60000:
            pos += 1
            continue
        m, tq = thead
        tend = tq + 8 * m
        if tend + 5 > size:
            pos += 1
            continue
        phead = _try_index(d, tend + 4)
        if phead is None or not 10 <= phead[0] <= n:
            pos += 1
            continue
        p, pq = phead
        if pq + 12 * p > size:
            pos += 1
            continue
        wedges = np.frombuffer(d, wedge_dt, count=n, offset=q)
        tris = np.frombuffer(d, tri_dt, count=m, offset=tq)
        points = np.frombuffer(d, '<f4', count=p * 3, offset=pq).reshape(-1, 3)
        if (wedges['i'].max() < p and tris['w'].max() < n and tris['m'].max() < 32 and np.isfinite(points).all()
                and np.abs(points).max() < 1e5 and np.isfinite(wedges['u']).all() and np.isfinite(wedges['v']).all()):
            return wedges, tris, points, pq + 12 * p, q
        pos += 1
    return None


def _find_influences(d, start, point_count, bone_count, stop=None):
    """Rigid / smooth vertex influences: the first count k >= point_count of (f32 weight, u16 point, u16 bone) records
    after `start` (and before `stop`) that cover every point with sane weights."""
    dt = np.dtype([('w', '<f4'), ('p', '<u2'), ('b', '<u2')])
    size = len(d) if stop is None else min(len(d), stop)
    pos = start
    while pos < size - 8 * point_count:
        head = _try_index(d, pos)
        if head is None or not point_count <= head[0] <= point_count * 8:
            pos += 1
            continue
        k, q = head
        if q + 8 * k > size:
            pos += 1
            continue
        # cheap first-record test
        w, pt, bone = struct.unpack_from('<fHH', d, q)
        if not (0.0 < w <= 1.0001 and pt < point_count and bone < bone_count):
            pos += 1
            continue
        arr = np.frombuffer(d, dt, count=k, offset=q)
        if (arr['w'] > 0).all() and (arr['w'] <= 1.0001).all() and arr['p'].max() < point_count and arr['b'].max() < bone_count \
                and len(np.unique(arr['p'])) == point_count:
            return arr, q + 8 * k
        pos += 1
    return None


def parse_skeletal_mesh(pkg, export, lenient=False):
    """{'bones': [{name, quat, pos, parent}], 'points': (p, 3), 'wedges', 'tris', 'influences', 'materials': [refs]} or
    raises MeshError. lenient: a mesh whose influences are not found is bound to its root bone (rest pose only)."""
    d = bytes(pkg.raw(export))
    got = _find_bones(pkg, d, 60)
    if got is None:
        raise MeshError('no bone array')
    bones, bend = got
    geo = _find_geometry(d, bend)
    if geo is None:
        raise MeshError('no wedge/triangle/point arrays')
    wedges, tris, points, gend, wedge_at = geo
    inf = _find_influences(d, gend, len(points), len(bones))
    if inf is None:                      # the vehicles' levels of detail are: influences, wedges, triangles, points
        inf = _find_influences(d, bend, len(points), len(bones), wedge_at)
    if inf is None:
        if not lenient:
            raise MeshError('no vertex influences')
        # a rest-pose use (props, vehicles) does not need the binding: every vertex rides the root bone
        dt = np.dtype([('w', '<f4'), ('p', '<u2'), ('b', '<u2')])
        arr = np.zeros(len(points), dt)
        arr['w'], arr['p'] = 1.0, np.arange(len(points))
        inf = (arr, gend)
    mats = []
    try:
        r = U.Reader(d, 63)
        count = r.index()
        if 0 <= count < 64:
            mats = [r.index() for _ in range(count)]
    except (IndexError, struct.error):
        mats = []
    return {'bones': bones, 'points': points, 'wedges': wedges, 'tris': tris, 'influences': inf[0], 'materials': mats}


# ------------------------------------------------------------------------------------------------ animation
def _read_track(r):
    flags = r.u32()
    nq = r.index()
    quats = np.frombuffer(r.d, '<f4', count=nq * 4, offset=r.p).reshape(-1, 4)
    r.p += 16 * nq
    npos = r.index()
    pos = np.frombuffer(r.d, '<f4', count=npos * 3, offset=r.p).reshape(-1, 3)
    r.p += 12 * npos
    nt = r.index()
    times = np.frombuffer(r.d, '<f4', count=nt, offset=r.p)
    r.p += 4 * nt
    return {'flags': flags, 'quats': quats, 'pos': pos, 'times': times}


def parse_animation(pkg, export, wanted=None):
    """{'bones': [(name, parent)], 'seqs': {name: {rate, frames, track_time, tracks {bone name: track}, notifies}}}.
    `wanted` (a set of sequence names) limits the tracks that are kept; the stream is parsed fully either way."""
    d = bytes(pkg.raw(export))
    r = U.Reader(d, EXPORT_PREFIX + 1)
    r.u32()
    nb = r.index()
    bones = []
    for _ in range(nb):
        name = pkg.name(r.index())
        r.u32()
        bones.append((name, r.i32()))
    moves = []
    for _ in range(r.index()):
        r.p += 12
        track_time = r.f32()
        r.p += 8
        idx = list(struct.unpack_from('<%di' % (nbi := r.index()), d, r.p))
        r.p += 4 * nbi
        tracks = [_read_track(r) for _ in range(r.index())]
        _read_track(r)
        r.p += 1
        moves.append((track_time, idx, tracks))
    seqs = {}
    for i in range(r.index()):
        r.p += 16
        name = pkg.name(r.index())
        for _ in range(r.index()):
            r.index()
        start, frames = r.i32(), r.i32()
        notifies = []
        for _ in range(r.index()):
            t = r.f32()
            r.index()
            notifies.append((t, r.index()))
        rate = r.f32()
        track_time, idx, tracks = moves[i]
        seq = {'rate': rate, 'frames': frames, 'start': start, 'track_time': track_time, 'notifies': notifies, 'tracks': {}}
        if wanted is None or name.lower() in wanted:
            if not idx:                                            # no index list (JuliaJnr): the tracks follow the bone order
                idx = list(range(len(tracks)))
            for bi, tr in zip(idx, tracks):
                if 0 <= bi < len(bones):
                    seq['tracks'][bones[bi][0].lower()] = tr
        if name not in seqs:
            seqs[name] = seq
    return {'bones': bones, 'seqs': seqs}
