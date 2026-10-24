"""Tribes: Vengeance lit BSP: the compiled level geometry and its baked lightmaps -> one engine shape per map.

`tv_bsp.py` approximates the level from its editor brushes (no CSG, no lightmaps). This module reads the compiled BSP
(`tv_bsp_model.py`): every node is one convex polygon of the final, CSG-cut level with its texture coordinates and its
lightmap coordinates, and every section names the lightmap page (a 512 x 512 DXT3 atlas) its polygons sample. Output:
  shapes/bspl_<map>.json   the polygons (shape frame like bsp_<map>), `uv` = texture coordinates in repeats (v negated as
                           for the brush shells), `uv2` = lightmap coordinates; the materials carry a `lightmap` file
  textures/tv/lm_<map>_<page>.png   the lightmap pages as RGB (the DXT3 alpha is texel coverage: uncovered texels take the
                           colour of their covered neighbours so bilinear filtering shows no seams)
The brush shell stays the collision of the level (`drawn: false` in map.json); this shape is only drawn.
"""
import json
import os

import numpy as np
from PIL import Image

import tv_bsp
import tv_bsp_model as M
import ue2_package as U
import ue2_texture as T

PF_INVISIBLE = 0x1
PF_TWO_SIDED = 0x100
DILATE_STEPS = 4
SHAPE_DECIMALS = 4
UV_DECIMALS = 5


def export_lit_bsp(idx, pkg, out_dir, map_id, mpu):
    """Writes shapes/bspl_<map>.json and the lightmap pages; returns the statics entry for the shape or None."""
    model = M.read_model(pkg)
    if model is None:
        return None
    bank = tv_bsp.MaterialBank(idx, pkg, out_dir)
    pages = _write_pages(model, out_dir, map_id)
    materials, slots, polys = [], {}, []
    for node in model.nodes:
        surf = model.surfs[node.surf]
        section = model.sections[node.section]
        if surf['flags'] & PF_INVISIBLE or node.vertex_count < 3:
            continue
        name = bank.name_of(section.material)
        if not name:
            continue                                           # editor placeholders
        lightmapped = section.page != M.SECTION_NO_PAGE and not section.flags & M.FLAG_NOT_LIGHTMAPPED
        key = (section.material, section.page if lightmapped else None)
        if key not in slots:
            slots[key] = len(materials)
            materials.append(_material_entry(name, pages[section.page] if lightmapped else ''))
        polys.extend(_polygon_entries(M.polygon_vertices(model, node), slots[key], surf['flags'], mpu, lightmapped))
    if not polys:
        return None
    shape = tv_bsp.make_shape_json(polys, materials, mpu, 'bspl_' + map_id)
    os.makedirs(os.path.join(out_dir, 'shapes'), exist_ok=True)
    with open(os.path.join(out_dir, 'shapes', 'bspl_%s.json' % map_id), 'w', encoding='utf-8') as f:
        json.dump(shape, f, separators=(',', ':'))
    return {'shape': 'tribes_v:bspl_' + map_id, 'pos': [0.0, 0.0, 0.0], 'basis': [[1, 0, 0], [0, 1, 0], [0, 0, 1]], 'collide': False, 'visual_only': True}


def export_bsp_entries(idx, pkg, out_dir, map_id, mpu):
    """The statics entries of a map's BSP: the brush shell (collision; drawn only when there is no lit twin) and the lit shape."""
    shell = tv_bsp.export_bsp(idx, pkg, out_dir, map_id, mpu)
    lit = export_lit_bsp(idx, pkg, out_dir, map_id, mpu)
    if shell and lit:
        shell['drawn'] = False
    return [e for e in (lit, shell) if e]


def rebuild(game_root, pack_dir, only=None, log=print):
    """Adds the lit BSP shapes and lightmap pages to an imported pack without redoing the rest of the import: writes
    shapes/bspl_<map>.json and patches each map.json (the lit shape is drawn, the brush shell only collides)."""
    import tv_assets
    import tv_import
    idx = tv_assets.PackageIndex(game_root)
    content = os.path.join(game_root, 'Content')
    chapters = tv_import.parse_campaign_ini(tv_import.read_text(os.path.join(content, 'System', 'Campaign.ini')))
    for ch in chapters:
        for entry in ch['maps']:
            path = tv_import._ci_file(os.path.join(content, 'Maps'), entry['map'] + '.tvm')
            map_id = entry['map'].lower()
            map_file = _find_map_file(pack_dir, map_id)
            if not path or not map_file or (only and map_id not in only):
                continue
            pkg = U.load(path)
            pkg.stem = map_id
            lit = export_lit_bsp(idx, pkg, pack_dir, map_id, tv_import.METRES_PER_UU)
            _patch_map(map_file, map_id, lit)
            log('%-26s %s' % (entry['map'], 'lit shape written' if lit else 'no compiled BSP: brush shell stays drawn'))


def _find_map_file(pack_dir, map_id):
    """maps/<folder>/map.json of a map whose folder name matches `map_id` ignoring case; '' when there is none."""
    maps_dir = os.path.join(pack_dir, 'maps')
    for folder in os.listdir(maps_dir) if os.path.isdir(maps_dir) else []:
        path = os.path.join(maps_dir, folder, 'map.json')
        if folder.lower() == map_id and os.path.isfile(path):
            return path
    return ''


def _patch_map(map_file, map_id, lit):
    with open(map_file, encoding='utf-8') as f:
        m = json.load(f)
    lit_shape, shell_shape = 'tribes_v:bspl_' + map_id, 'tribes_v:bsp_' + map_id
    statics = [e for e in m['statics'] if e.get('shape') != lit_shape]
    for e in statics:
        if e.get('shape') == shell_shape:
            if lit:
                e['drawn'] = False
            else:
                e.pop('drawn', None)
    if lit:
        statics.insert(0, lit)
    m['statics'] = statics
    with open(map_file, 'w', encoding='utf-8') as f:
        json.dump(m, f, indent=1, ensure_ascii=False)


def _material_entry(texture_name, lightmap_file):
    entry = {'name': texture_name, 'flags': 0, 'texture': 'textures/tv/%s.png' % texture_name, 'w': 0, 'h': 0}
    if lightmap_file:
        entry['lightmap'] = lightmap_file
    return entry


def _polygon_entries(rows, slot, surf_flags, mpu, lightmapped):
    """One poly dict (two for a two-sided surface) from a node's (k, 10) vertex rows."""
    columns = slice(0, 7) if lightmapped else slice(0, 5)
    if not np.isfinite(rows[:, columns]).all() or not np.isfinite(rows[:, 7:10]).all():
        return []                                                               # garbage vertices of an unused polygon
    with np.errstate(invalid='ignore'):                                         # unused columns may hold NaN bit patterns
        rows = rows.astype(np.float64)
    rows = _rotate_to_corner(rows)
    pos = np.stack([rows[:, 1], rows[:, 0], rows[:, 2]], axis=1) * mpu          # shape frame: x right, y forward, z up
    normal = np.array([rows[0, 8], rows[0, 7], rows[0, 9]])
    normal = normal / (np.linalg.norm(normal) or 1.0)
    uv = np.stack([rows[:, 3], -rows[:, 4]], axis=1)
    uv = uv - np.floor(uv.min(axis=0))                                          # small offsets keep float precision
    poly = {'v': pos.round(SHAPE_DECIMALS).tolist(), 'n': normal.round(SHAPE_DECIMALS).tolist(), 't': 'tri',
            'm': {'kind': 'rgba', 'index': slot}, 'uv': uv.round(UV_DECIMALS).tolist()}
    if lightmapped:
        poly['uv2'] = rows[:, 5:7].round(UV_DECIMALS).tolist()
    out = [poly]
    if surf_flags & PF_TWO_SIDED:
        back = dict(poly, v=poly['v'][::-1], uv=poly['uv'][::-1], n=(-normal).round(SHAPE_DECIMALS).tolist())
        if lightmapped:
            back['uv2'] = poly['uv2'][::-1]
        out.append(back)
    return out


def _rotate_to_corner(rows):
    """The vertex rows rotated to start where the next two vertices are not collinear: polygons carry vertices of the
    T-junctions along their edges, and the engine takes a polygon's winding from its first three vertices."""
    pos = rows[:, :3]
    count = len(rows)
    best, best_area = 0, -1.0
    for start in range(count):
        a, b, c = pos[start], pos[(start + 1) % count], pos[(start + 2) % count]
        area = float(np.linalg.norm(np.cross(b - a, c - a)))
        if area > best_area:
            best, best_area = start, area
    return np.roll(rows, -best, axis=0)


def _write_pages(model, out_dir, map_id):
    """Writes every lightmap page as textures/tv/lm_<map>_<n>.png; returns their pack-relative paths."""
    tex_dir = os.path.join(out_dir, 'textures', 'tv')
    os.makedirs(tex_dir, exist_ok=True)
    paths = []
    for page in range(len(model.pages)):
        rgb = make_page_rgb(model, page)
        rel = 'textures/tv/lm_%s_%d.png' % (map_id, page)
        Image.fromarray(rgb).save(os.path.join(out_dir, rel))
        paths.append(rel)
    return paths


def make_page_rgb(model, page):
    """(side, side, 3) uint8 lightmap of a page with the uncovered texels filled from their neighbours."""
    side, data = M.read_page_dxt3(model, page)
    rgba = T.to_rgba({'format': T.DXT3, 'width': side, 'height': side, 'data': data})
    return make_dilated(rgba[..., :3].copy(), rgba[..., 3] > 0)


def make_dilated(rgb, covered):
    """`rgb` with each uncovered texel next to covered ones set to their mean, repeated DILATE_STEPS times."""
    rgb = rgb.astype(np.float32)
    covered = covered.copy()
    for _ in range(DILATE_STEPS):
        total = np.zeros_like(rgb)
        count = np.zeros(covered.shape, dtype=np.float32)
        for axis, shift in ((0, 1), (0, -1), (1, 1), (1, -1)):
            total += np.roll(rgb * covered[..., None], shift, axis=axis)
            count += np.roll(covered, shift, axis=axis)
        fill = ~covered & (count > 0)
        rgb[fill] = total[fill] / count[fill][:, None]
        covered |= fill
    return np.clip(rgb + 0.5, 0, 255).astype(np.uint8)


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 3:
        sys.exit('python tools/tv_bsp_render.py <game root: the unpacked "Tribes Vengeance" folder> <pack folder> [map id ...]')
    rebuild(sys.argv[1], sys.argv[2], {a.lower() for a in sys.argv[3:]} or None)
