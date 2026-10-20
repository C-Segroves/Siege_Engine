"""Tribes: Vengeance terrain -> engine map terrain (docs/formats/tribes_vengeance.md "Terrain").

A TerrainInfo actor holds TerrainMap (a G16 Texture in the map's *Textures package), TerrainScale (x/y spacing in
units, z = height range per 256 steps) and the layer list; the grid is centred on the actor's Location (verified:
static meshes sit on it). height = Location.z + (value - 32768) / 256 * scale.z. DrawScale is ignored. The albedo is
the finalised macro texture. Output (engine metres, x = Unreal y, z = -Unreal x): height.r32, albedo.png and the
"terrain" dictionary of map.json.
"""
import os

import numpy as np
from PIL import Image

import ue2_package as U
import ue2_texture as T

MAX_ALBEDO = 2048


def _texture(idx, pkg, name):
    """Decoded RGBA of the imported/exported Texture called name, or None."""
    if not name or name == 'None':
        return None
    for k, im in enumerate(pkg.imports):
        if im['class_name'] == 'Texture' and im['name'] == name:
            home, ex = idx.object(pkg, -(k + 1))
            tex = T.read_texture(home, ex) if home is not None else None
            return tex
    for e in pkg.find('Texture', name):
        return T.read_texture(pkg, e)
    return None


def _to_engine(a):
    """Grid indexed [Unreal y row][Unreal x column] -> engine [z row][x column] (x = Unreal y, z = -Unreal x)."""
    return a.swapaxes(0, 1)[::-1]


def export_terrain(idx, pkg, out_dir, metres_per_unit):
    """Writes height.r32 and albedo.png into out_dir; returns the map "terrain" dict (None without a heightmap)."""
    best = None
    for e in pkg.find('TerrainInfo'):
        props, _ = U.object_with_trailing(pkg, e)
        tex = _texture(idx, pkg, props.get('TerrainMap'))
        h = T.to_height16(tex) if tex else None
        if h is not None and (best is None or h.size > best[0].size):
            best = (h, props)
    if best is None:
        return None
    h, props = best
    w = h.shape[1]
    scale = U.vec3(props['TerrainScale'])
    loc = U.vec3(props['Location'])
    m = metres_per_unit
    heights = ((h.astype(np.float32) - 32768.0) / 256.0 * scale[2] + loc[2]) * m
    heights = np.ascontiguousarray(_to_engine(heights), dtype='<f4')
    os.makedirs(out_dir, exist_ok=True)
    heights.tofile(os.path.join(out_dir, 'height.r32'))
    square = scale[0] * m
    terrain = {'heights': 'height.r32', 'size': [w, h.shape[0]], 'square': round(square, 4),
               'origin': [round((loc[1] - w / 2.0 * scale[1]) * m, 3), round(-(loc[0] + (w / 2.0 - 1) * scale[0]) * m, 3)],
               'height_scale': 1.0, 'albedo_repeat': 1.0, 'source': 'TerrainInfo', 'wraps': False}
    macro = _texture(idx, pkg, props.get('FinalisedMacroTexture')) or _texture(idx, pkg, props.get('MacroTexture'))
    rgba = T.to_rgba(macro) if macro else None
    if rgba is not None:
        img = Image.fromarray(np.ascontiguousarray(_to_engine(rgba[:, :, :3])))
        if max(img.size) > MAX_ALBEDO:
            img = img.resize((MAX_ALBEDO, MAX_ALBEDO), Image.LANCZOS)
        img.save(os.path.join(out_dir, 'albedo.png'))
        terrain['albedo'] = 'albedo.png'
    return terrain
