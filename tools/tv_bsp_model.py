"""Tribes: Vengeance compiled BSP: the level's Model export -> render sections, polygons and lightmap pages.

The level Model is the largest `Model` export of a map (4 to 20 MB for the campaign maps). Layout (all little endian, `ci` =
compact index; every bulk array and struct list starts with a 12-byte header of three u32, e.g. (3, 0, 5) before the vectors):
  object header 13 bytes, bounding box + sphere 41 bytes (zeros), header (3,0,5), Vectors ci count x 12 bytes, Points ci count x 12 bytes,
  Nodes ci count x {head u32 x3 (3,2,2), plane 16, zone mask 8, flags 1, 7 ci (iVertPool, iSurf, iBack, iFront, iPlane, ...),
    sphere 16, 40 bytes: ..., NumVertices u8 at +18, 8 x 0xff, u32 section, u32 first vertex in the section, u32 ..., 1},
  Surfs ci count x {head u32 x3 (3,1,1), Material ci, PolyFlags u32, pBase / vNormal / vTextureU / vTextureV / iBrushPoly ci, Actor ci,
    plane 16, LightMapScale f32 (32 uu per texel)},
  Verts (2 ci each), shared sides u32, zones u32, zones x 21 bytes, Polys ref, bounds, hulls, leaves ...,
  Sections ci count x {header (3,0,2), ci vertex count, vertices x 40 (position 12, texture uv 8, lightmap uv 8, normal 12),
    u32 nodes, Material ci, u32 nodes, u32 flags (256 = not lightmapped), u32 lightmap page (0xffffffff none), header (3,0,1), ci 450,
    u32 vertex count, u32 section number, header (3,0,1), ci count, count x 8 bytes (vertex colour + packed normal), u32 nodes},
  ... per surface lightmap descriptors, then the lightmap pages: for each page and mip level {u32, ci byte size, DXT3 blocks}.
A node is one convex polygon: its vertices are `first vertex` .. `+ NumVertices` of its section (a triangle fan). Verified on every
campaign map: the nodes of each section sum to its vertex and node counts, and every section vertex's lightmap UV lies on an
opaque texel of its page. Lightmap pages are DXT3 (the alpha is texel coverage), 512 x 512 in the campaign maps, with a mip
level of a quarter the size after each.
"""
import re
import struct
from dataclasses import dataclass, field

import numpy as np

import ue2_package as U

HEADER_SECTION_VERTICES = bytes.fromhex('030000000000000002000000')
HEADER_SECTION_ARRAY = bytes.fromhex('030000000000000001000000')
VERTEX_BYTES = 40
COLOUR_BYTES = 8
NODE_HEAD_BYTES = 12
NODE_PLANE_ZONE_FLAGS_BYTES = 16 + 8 + 1
NODE_COMPACTS = 7
NODE_SPHERE_BYTES = 16
NODE_TAIL_BYTES = 40
NODE_TAIL_VERTEX_COUNT = 18
NODE_TAIL_SECTION = 27
SURF_HEAD_BYTES = 12
SURF_COMPACTS = 6
SURF_TAIL_BYTES = 16 + 4
VECTORS_OFFSET = 0x36
BULK_HEADER_BYTES = 12
SECTION_NO_PAGE = 0xFFFFFFFF
FLAG_NOT_LIGHTMAPPED = 256
PAGE_LEVEL_GAP = 4
MIN_PAGE_BYTES = 4096
MAX_PAGE_BYTES = 4 * 1024 * 1024
PAGE_START = re.compile(rb'[\x40\x50\x60\x70][\x80-\xff][\x80-\xff]?[\x01-\x7f]', re.S)


@dataclass
class Section:
    material: int                      # compact object reference (negative = import)
    page: int                          # lightmap page index, SECTION_NO_PAGE when the section has none
    flags: int
    vertices: np.ndarray               # (n, 10) float32: position 3, uv 2, lightmap uv 2, normal 3
    node_count: int


@dataclass
class Node:
    surf: int
    section: int
    first_vertex: int
    vertex_count: int


@dataclass
class BspModel:
    surfs: list = field(default_factory=list)       # [{'flags': u32, 'material': ref}]
    nodes: list = field(default_factory=list)       # [Node]
    sections: list = field(default_factory=list)    # [Section]
    pages: list = field(default_factory=list)       # [(offset, byte size)] of each page's first (largest) mip level
    raw: bytes = b''
    after_surfs: int = 0


def read_model(pkg):
    """The BspModel of a map package; None when it has no compiled BSP or the layout does not check out."""
    exports = [e for e in pkg.exports if pkg.class_name(e) == 'Model']
    if not exports:
        return None
    raw = bytes(pkg.raw(max(exports, key=lambda e: e['size'])))
    if len(raw) < 4096:
        return None
    try:
        model = _read_head(raw)
        _read_sections_and_pages(model)
    except (IndexError, struct.error, AssertionError, ValueError):
        return None
    return model if model.sections and model.pages else None


def polygon_vertices(model, node):
    """(k, 10) vertex rows of a node's polygon."""
    verts = model.sections[node.section].vertices
    return verts[node.first_vertex:node.first_vertex + node.vertex_count]


def read_page_dxt3(model, page):
    """(side, DXT3 block bytes) of a lightmap page's largest mip level (pages are square)."""
    offset, size = model.pages[page]
    side = int(round(size ** 0.5))
    assert side * side == size
    return side, model.raw[offset:offset + size]


def _read_head(raw):
    reader = U.Reader(raw, VECTORS_OFFSET + BULK_HEADER_BYTES)
    for _ in range(2):                                   # vectors, points
        count = reader.index()
        reader.p += count * 12
    model = BspModel(raw=raw)
    model.nodes = _read_nodes(raw, reader)
    model.surfs = _read_surfs(raw, reader)
    model.after_surfs = reader.p
    return model


def _read_nodes(raw, reader):
    nodes = []
    for _ in range(reader.index()):
        reader.p += NODE_HEAD_BYTES + NODE_PLANE_ZONE_FLAGS_BYTES
        compacts = [reader.index() for _ in range(NODE_COMPACTS)]
        tail = reader.p + NODE_SPHERE_BYTES
        count = raw[tail + NODE_TAIL_VERTEX_COUNT]
        section, first = struct.unpack_from('<2I', raw, tail + NODE_TAIL_SECTION)
        nodes.append(Node(compacts[1], section, first, count))
        reader.p = tail + NODE_TAIL_BYTES
    return nodes


def _read_surfs(raw, reader):
    surfs = []
    for _ in range(reader.index()):
        reader.p += SURF_HEAD_BYTES
        material = reader.index()
        flags = reader.u32()
        for _ in range(SURF_COMPACTS):
            reader.index()
        reader.p += SURF_TAIL_BYTES
        surfs.append({'flags': flags, 'material': material})
    return surfs


def _read_sections_and_pages(model):
    wanted = max((n.section for n in model.nodes), default=-1) + 1
    assert wanted > 0
    start = _find_section_array(model, wanted)
    sections, end = _read_sections(model.raw, start)
    _check_sections(model, sections)
    model.sections = sections
    model.pages = _find_pages(model.raw, end, 1 + max((s.page for s in sections if s.page != SECTION_NO_PAGE), default=-1))


def _find_section_array(model, wanted):
    """Offset of the section count: the (3,0,2) header whose preceding compact count equals `wanted` and that parses."""
    raw = model.raw
    pos = raw.find(HEADER_SECTION_VERTICES, model.after_surfs)
    while pos >= 0:
        for width in (1, 2, 3):
            count_at = pos - width
            reader = U.Reader(raw, count_at)
            try:
                if reader.index() == wanted and reader.p == pos:
                    _read_sections(raw, count_at)
                    return count_at
            except (IndexError, AssertionError, struct.error):
                pass
        pos = raw.find(HEADER_SECTION_VERTICES, pos + 1)
    raise ValueError('no section array')


def _read_sections(raw, start):
    reader = U.Reader(raw, start)
    sections = []
    for _ in range(reader.index()):
        assert raw[reader.p:reader.p + BULK_HEADER_BYTES] == HEADER_SECTION_VERTICES
        reader.p += BULK_HEADER_BYTES
        count = reader.index()
        vertices = np.frombuffer(raw, dtype='<f4', count=count * 10, offset=reader.p).reshape(count, 10)
        reader.p += VERTEX_BYTES * count
        nodes = reader.u32()
        material = reader.index()
        assert reader.u32() == nodes
        flags, page = reader.u32(), reader.u32()
        assert raw[reader.p:reader.p + BULK_HEADER_BYTES] == HEADER_SECTION_ARRAY
        reader.p += BULK_HEADER_BYTES
        reader.index()
        assert reader.u32() == count
        reader.u32()
        assert raw[reader.p:reader.p + BULK_HEADER_BYTES] == HEADER_SECTION_ARRAY
        reader.p += BULK_HEADER_BYTES
        colours = reader.index()                          # 0 for the invisible (portal) sections
        assert colours in (0, count)
        reader.p += COLOUR_BYTES * colours
        reader.u32()                                      # the node count again
        sections.append(Section(material, page, flags, vertices, nodes))
    return sections, reader.p


def _check_sections(model, sections):
    """Each section's nodes must account for exactly its polygons and vertices."""
    nodes = [0] * len(sections)
    verts = [0] * len(sections)
    for n in model.nodes:
        assert n.section < len(sections)
        nodes[n.section] += 1
        verts[n.section] += n.vertex_count
    for i, s in enumerate(sections):
        assert nodes[i] == s.node_count and verts[i] == len(s.vertices)


def _find_pages(raw, start, wanted):
    """Offsets and byte sizes of the lightmap pages (first mip level): a compact byte size followed, after the data and a u32,
    by the next level's size (a quarter)."""
    pages, floor = [], 0
    for m in PAGE_START.finditer(raw, start):
        if m.start() < floor:
            continue
        reader = U.Reader(raw, m.start())
        size = reader.index()
        if size % 16 or not MIN_PAGE_BYTES <= size <= MAX_PAGE_BYTES:
            continue
        follow = reader.p + size + PAGE_LEVEL_GAP
        if follow + 4 > len(raw) or U.Reader(raw, follow).index() != size // 4:
            continue
        pages.append((reader.p, size))
        floor = reader.p + size
    assert len(pages) >= wanted
    return pages[:wanted]
