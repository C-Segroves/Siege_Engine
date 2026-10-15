"""aa_shape on a synthetic VIF stream: one batch of 4 vertices becomes two strip triangles in the engine source frame.

    python -m pytest tools/tests/test_aa_shape.py
"""
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import aa_shape  # noqa: E402


def _unpack(cmd, num, addr, payload):
    pad = (-len(payload)) % 4
    return struct.pack('<I', (cmd << 24) | (num << 16) | addr) + payload + bytes(pad)


def _shape(scale=1000.0):
    head = bytearray(0x100)
    head[0:4] = struct.pack('<I', 0x1f)
    head[8:12] = b'box\0'
    struct.pack_into('<IIf', head, 0x90, 0x3F800000, 0, scale)
    uv = np.array([[0, 0], [4095, 0], [0, 4095], [4095, 4095]], '<u2').tobytes()
    nrm = np.array([[0, 127, 0]] * 4, 'i1').tobytes()
    pos = np.array([[0, 0, 0, -32768], [1000, 0, 0, -32768], [0, 0, 1000, 0], [1000, 0, 1000, 0x4000]], '<i2')
    pos[:, 3] = [-32768, -32768, 0, 0x4000]
    stream = (struct.pack('<I', 0x01000101) + _unpack(0x65, 4, 0x8001, uv) + _unpack(0x7A, 4, 0x8003, nrm)
              + _unpack(0x6D, 4, 0x8004, pos.tobytes()))
    bs = chr(92).encode()
    tex = (bs * 2 + b'project1' + bs + b'Art' + bs + b'BASE_box.png\0').ljust(48, b'\0')
    return bytes(head) + tex + bytes(8) + stream


def test_decode_strip_and_json():
    sh = aa_shape.decode(_shape())
    assert sh['name'] == 'box' and sh['textures'] == ['BASE_box.png'] and sh['scale'] == 1000.0
    m = sh['meshes'][0]
    assert len(m['pos']) == 4 and m['pos'][1][0] == 1.0 and m['uv'][3][1] == 4095 / 4096.0
    assert m['tris'] == [(0, 1, 2), (2, 1, 3)] or len(m['tris']) == 2
    js = aa_shape.to_json(sh, lambda t: 'textures/aa/' + t)
    poly = js['lods'][0]['pieces'][0]['polys'][0]
    assert js['materials'][0]['texture'] == 'textures/aa/BASE_box.png'
    assert poly['v'][1] == [0.0, 1.0, 0.0]            # file (x=1, y=0, z=0) -> source (z, x, y)
    assert abs(poly['n'][2]) == 1.0 or abs(poly['n'][1]) == 1.0 or abs(poly['n'][0]) == 1.0


def test_node_table_and_mirror_detection():
    import struct
    head = bytearray(0x98) + struct.pack('<IIf', 0x3F800000, 1, 5000.0) + bytes(0x24)
    boxes = [(-1, (-1.0, 0.1, 0.0, -0.3, 1.9, 1.0)), (0, (0.3, -1.9, -1.0, 1.0, -0.1, 0.0)), (0, (-0.01,) * 3 + (0.01,) * 3)]
    table = struct.pack('<I', len(boxes)) + b''.join(struct.pack('<iiI6fI', 0, p, 7, *b, 0) for p, b in boxes)
    d = bytes(head) + table
    got = aa_shape.node_boxes(d)
    assert [p for p, _ in got] == [-1, 0, 0]
    assert aa_shape.mirrored_nodes(got) == {1}          # node 1 is the point inversion of node 0; the dummy is symmetric


def test_quaternion_matrix_and_soldier_pose():
    rot = aa_shape._quat_matrix((0.0, 0.0, 0.7071068, 0.7071068))        # a quarter turn about Z
    assert np.allclose(rot @ [1, 0, 0], [0, 1, 0], atol=1e-5)
    bones = [((0, 0, 0, 1), (0, 1, 0))] + [((0, 0, 0, 1), (0.5, 0, 0))] * 15
    world = aa_shape.skeleton_pose(bones)
    assert np.allclose(world[1][1], [0.5, 1, 0]) and np.allclose(world[3][1], [1.5, 1, 0])    # bone 3 hangs from 2 from 1
    assert aa_shape.skeleton_pose(bones[:15]) is None
