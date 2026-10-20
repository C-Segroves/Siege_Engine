"""Aerial Assault soldier animation sequences (.SHP "<name>_<seq>" records after the bone list).

Layout of one sequence, after its name string and a small header:
    1.0f, fps f, frame count, 0, bone count      (the 20 bytes before the first bone record)
    per bone: u32 flags|0x80000000, 1.0f, then two sections - rotation, then translation:
        u32 1          static: 4 floats (quaternion x y z w, or translation x y z + 0)
        u32 n > 1      animated: n bytes follow = A (4 floats) + S (4 floats) + one byte per channel per frame
                       (4 channels for rotation, 3 for translation); value = A + byte * S per channel
A bone's rotation is renormalised after decoding. Values are local to the parent bone like the default pose in aa_shape.bones.
"""
import re
import struct

import numpy as np

NAME_RE = re.compile(rb'(?:[A-Za-z]+_(?:male|female|bioderm)|bioderm_(?:light|medium|heavy))_[A-Za-z_]+\x00')
START_RE = re.compile(rb'\x00\x00\x80\x3f\x00\x00(?:\x20\x41|\xf0\x41)........[\x0f\x10]\x00\x00\x00', re.S)


def _section(d, p, channels, frames):
    """-> (array (frames, channels), next offset)."""
    m = struct.unpack_from('<I', d, p)[0]
    if m == 0:                                      # no keys: the zero vector / identity (a marker and a pad word)
        v = np.zeros(channels)
        if channels == 4:
            v[3] = 1.0
        return np.tile(v, (frames, 1)), p + 8
    if m == 1:
        v = np.array(struct.unpack_from('<%df' % channels, d, p + 4), 'f8')
        return np.tile(v, (frames, 1)), p + 4 + 16
    if m == frames and m > 1:                       # raw floats, one vector per frame
        v = np.array(struct.unpack_from('<%df' % (m * channels), d, p + 4), 'f8').reshape(m, channels)
        return v, p + 4 + 4 * m * channels
    if m < 32 or m > 4096:
        raise ValueError('section marker 0x%x at %d' % (m, p))
    a = np.array(struct.unpack_from('<%df' % channels, d, p + 4), 'f8')
    s = np.array(struct.unpack_from('<%df' % channels, d, p + 4 + (16 if channels == 4 else 16)), 'f8')
    # translation: A is 3 floats + pad, S is 3 floats + int; quaternion: A and S are 4 floats each
    if channels == 3:
        a = np.array(struct.unpack_from('<3f', d, p + 4), 'f8')
        s = np.array(struct.unpack_from('<3f', d, p + 20), 'f8')
    stream_at = p + 4 + 32
    n = m - 32
    if n != channels * frames:
        raise ValueError('stream %d bytes for %d frames x %d' % (n, frames, channels))
    b = np.frombuffer(d, 'u1', n, stream_at).reshape(frames, channels).astype('f8')
    return a + b * s, stream_at + n


def _skip_header(d, p, frames):
    """Offset of the next section marker. A record starts (after an optional zero pad word) with a flags word and 1.0f or 0.0f;
    the marker is 1, a byte count (32..4096) or the frame count (raw floats)."""
    for q in (8, 12, 16):
        one, m = struct.unpack_from('<2I', d, p + q - 4)
        if one in (0x3F800000, 0) and (m == 1 or 32 <= m <= 4096 or m == frames):
            return p + q
    raise ValueError('record header at %d' % p)


def sequences(d):
    """-> [{'name', 'fps', 'frames', 'rot': (frames, bones, 4), 'pos': (frames, bones, 3)}] of a soldier shape."""
    names = [(m.start(), m.group()[:-1].decode()) for m in NAME_RE.finditer(d, 0x1000)]
    starts = [m.start() + 20 for m in START_RE.finditer(d, 0x1000)]
    out = []
    for k, (at, name) in enumerate(names):
        end = names[k + 1][0] if k + 1 < len(names) else len(d)
        first = [s for s in starts if at < s < end]
        if not first:
            continue
        p0 = first[0]
        one, fps, frames, zero, nb = struct.unpack_from('<ffIII', d, p0 - 20)
        if one != 1.0 or not 1 <= nb <= 32 or not 1 <= frames <= 2000:
            continue
        rot = np.zeros((frames, nb, 4))
        pos = np.zeros((frames, nb, 3))
        p = p0
        try:
            for b in range(nb):
                p = _skip_header(d, p, frames)
                r, p = _section(d, p, 4, frames)
                t, p = _section(d, p, 3, frames)
                rot[:, b] = r / np.maximum(np.linalg.norm(r, axis=1, keepdims=True), 1e-9)
                pos[:, b] = t
        except (ValueError, struct.error) as e:
            out.append({'name': name, 'error': '%s (bone %d)' % (e, b)})
            continue
        out.append({'name': name, 'fps': fps, 'frames': frames, 'rot': rot, 'pos': pos})
    return out


def node_blocks(d, nb):
    """-> [{'at', 'fps', 'frames', 'rot': (frames, nb, 4), 'pos': (frames, nb, 3)}] of a shape with a node table of `nb` nodes
    (turrets, sensors: no soldier names). The records are the soldier layout; a block starts with (1.0f, fps, frames, k, nb)
    and holds one record per node, in node-table order. Blocks come in file order: the node default pose first (one frame),
    then the shape's sequences; a shape that stores a damaged copy repeats them, so only blocks before the first repeat of
    the first block's name are meaningful to the caller."""
    out = []
    for p in range(0x100, len(d) - 20, 4):
        one, fps, frames, k, n = struct.unpack_from('<ffIII', d, p)
        if one != 1.0 or not 1.0 <= fps <= 60.0 or not 1 <= frames <= 2000 or k >= 64 or n != nb:
            continue
        rot, pos, q = np.zeros((frames, nb, 4)), np.zeros((frames, nb, 3)), p + 20
        try:
            for b in range(nb):
                q = _skip_header(d, q, frames)
                r, q = _section(d, q, 4, frames)
                t, q = _section(d, q, 3, frames)
                rot[:, b] = r / np.maximum(np.linalg.norm(r, axis=1, keepdims=True), 1e-9)
                pos[:, b] = t
        except (ValueError, struct.error):
            continue
        out.append({'at': p, 'fps': fps, 'frames': frames, 'rot': rot, 'pos': pos})
    return out
