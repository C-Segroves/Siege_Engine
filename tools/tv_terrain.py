"""Tribes: Vengeance terrain -> engine map terrain (docs/formats/tribes_vengeance.md "Terrain").

A TerrainInfo actor holds TerrainMap (a G16 Texture in the map's *Textures package), TerrainScale (x/y spacing in
units, z = height range per 256 steps) and the layer list; the grid is centred on the actor's Location (verified:
static meshes sit on it). height = Location.z + (value - 32768) / 256 * scale.z. DrawScale is ignored. The albedo is
the finalised macro texture. Output (engine metres, x = Unreal y, z = -Unreal x): height.r32, albedo.png and the
"terrain" dictionary of map.json.

A map without a macro texture (SP-Captured) has only terrain layers: each TerrainInfo Layers entry is a tiling
Texture plus an AlphaMap (an RGBA8 texture over the whole grid, 256 x 256 for a 512 grid; the weight is its ALPHA channel,
the colour channels are a constant grey). Layer 0 is the base, every later layer is blended over the result by its alpha.
A texture tiles every UScale * 128 units (TerrainMatrix holds 1/1024 for UScale 8) and TextureRotation turns it
(65536 = a full turn). The layers are baked into one albedo of LAYERED_ALBEDO pixels.

  python tools/tv_terrain.py <game root> <pack folder>     bakes the layered albedo of the maps that lack one
"""
import math
import os

import numpy as np
from PIL import Image

import ue2_package as U
import ue2_texture as T

MAX_ALBEDO = 2048
LAYERED_ALBEDO = 4096
TILE_UNITS_PER_USCALE = 128.0
TILE_SAMPLES = 64                  # a tile is baked from this many texels per side (the albedo shows about 40 per tile)
TURN = 65536.0


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


def _best_terrain(idx, pkg):
    """(height grid, TerrainInfo properties) of the TerrainInfo with the biggest heightmap, or None."""
    best = None
    for e in pkg.find('TerrainInfo'):
        props, _ = U.object_with_trailing(pkg, e)
        tex = _texture(idx, pkg, props.get('TerrainMap'))
        h = T.to_height16(tex) if tex else None
        if h is not None and (best is None or h.size > best[0].size):
            best = (h, props)
    return best


def export_terrain(idx, pkg, out_dir, metres_per_unit):
    """Writes height.r32 and albedo.png into out_dir; returns the map "terrain" dict (None without a heightmap)."""
    best = _best_terrain(idx, pkg)
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
    if export_albedo(idx, pkg, props, h.shape, out_dir):
        terrain['albedo'] = 'albedo.png'
    return terrain


def export_albedo(idx, pkg, props, grid_shape, out_dir):
    """Writes albedo.png: the finalised macro texture, else the baked terrain layers. False when the map has neither."""
    macro = _texture(idx, pkg, props.get('FinalisedMacroTexture')) or _texture(idx, pkg, props.get('MacroTexture'))
    rgba = T.to_rgba(macro) if macro else None
    if rgba is not None:
        img = Image.fromarray(np.ascontiguousarray(_to_engine(rgba[:, :, :3])))
        if max(img.size) > MAX_ALBEDO:
            img = img.resize((MAX_ALBEDO, MAX_ALBEDO), Image.LANCZOS)
    else:
        baked = bake_layers(idx, pkg, props, grid_shape)
        if baked is None:
            return False
        img = Image.fromarray(np.ascontiguousarray(_to_engine(baked)))
    img.save(os.path.join(out_dir, 'albedo.png'))
    return True


def read_layers(idx, pkg, props):
    """[{'rgb' (h, w, 3), 'alpha' (h, w) or None, 'uscale', 'vscale', 'rotation' (turns)}] of the TerrainInfo layers, base first."""
    keys = [k for k in props if k == 'Layers' or k.startswith('Layers[')]
    keys.sort(key=lambda k: int(k[7:-1]) if '[' in k else 0)
    out = []
    for key in keys:
        sub = U.read_properties(pkg, U.Reader(bytes(props[key]), 0))
        tex = _layer_texture(idx, pkg, sub.refs.get('Texture'))
        if tex is None:
            continue
        alpha = _layer_texture(idx, pkg, sub.refs.get('AlphaMap'))
        out.append({'rgb': tex[:, :, :3], 'alpha': alpha[:, :, 3] if alpha is not None else None,
                    'uscale': float(sub.get('UScale', 8.0)), 'vscale': float(sub.get('VScale', 8.0)),
                    'rotation': float(sub.get('TextureRotation', 0.0)) / TURN})
    return out


def _layer_texture(idx, pkg, ref):
    if not ref:
        return None
    home, ex = idx.object(pkg, ref)
    tex = T.read_texture(home, ex) if home is not None else None
    return T.to_rgba(tex) if tex else None


def bake_layers(idx, pkg, props, grid_shape):
    """The layered terrain as one RGB image (LAYERED_ALBEDO square) in the grid's own orientation; None without layers."""
    layers = read_layers(idx, pkg, props)
    if not layers:
        return None
    scale = U.vec3(props['TerrainScale'])
    n = LAYERED_ALBEDO
    rows, cols = grid_shape
    ys, xs = np.meshgrid((np.arange(n) + 0.5) / n * rows * scale[1], (np.arange(n) + 0.5) / n * cols * scale[0], indexing='ij')
    result = None
    for layer in layers:
        colour = _sample_tile(layer, xs, ys)
        if result is None:
            result = colour
        elif layer['alpha'] is not None:
            a = np.asarray(Image.fromarray(layer['alpha']).resize((n, n), Image.BILINEAR), dtype=np.float32)[:, :, None] / 255.0
            result = result + (colour - result) * a
    return np.clip(result, 0, 255).astype(np.uint8)


def _sample_tile(layer, xs, ys):
    """float32 (n, n, 3): the layer's texture tiled over the unit coordinates xs, ys (nearest texel of a prefiltered tile)."""
    tile = np.asarray(Image.fromarray(layer['rgb']).resize((TILE_SAMPLES, TILE_SAMPLES), Image.BOX), dtype=np.float32)
    a = layer['rotation'] * 2.0 * math.pi
    u = (xs * math.cos(a) + ys * math.sin(a)) / (layer['uscale'] * TILE_UNITS_PER_USCALE)
    v = (ys * math.cos(a) - xs * math.sin(a)) / (layer['vscale'] * TILE_UNITS_PER_USCALE)
    iu = np.floor((u % 1.0) * TILE_SAMPLES).astype(np.int32) % TILE_SAMPLES
    iv = np.floor((v % 1.0) * TILE_SAMPLES).astype(np.int32) % TILE_SAMPLES
    return tile[iv, iu]


def retexture(game_root, pack_dir, log=print):
    """Bakes albedo.png (and sets the map's "terrain.albedo") for the pack's campaign maps that have a terrain but no
    albedo, from the game's own packages, without redoing the rest of the import."""
    import json
    import tv_assets
    import tv_import
    idx = tv_assets.PackageIndex(game_root)
    content = os.path.join(game_root, 'Content')
    chapters = tv_import.parse_campaign_ini(tv_import.read_text(os.path.join(content, 'System', 'Campaign.ini')))
    for ch in chapters:
        for entry in ch['maps']:
            path = tv_import._ci_file(os.path.join(content, 'Maps'), entry['map'] + '.tvm')
            if not path:
                continue
            map_dir = os.path.join(pack_dir, 'maps', os.path.splitext(os.path.basename(path))[0])
            map_path = os.path.join(map_dir, 'map.json')
            if not os.path.isfile(map_path):
                continue
            with open(map_path, encoding='utf-8') as f:
                m = json.load(f)
            if 'terrain' not in m or 'albedo' in m['terrain']:
                continue
            pkg = U.load(path)
            best = _best_terrain(idx, pkg)
            if best is not None and export_albedo(idx, pkg, best[1], best[0].shape, map_dir):
                m['terrain']['albedo'] = 'albedo.png'
                with open(map_path, 'w', encoding='utf-8') as f:
                    json.dump(m, f, indent=1, ensure_ascii=False)
                log('%-26s albedo baked from the terrain layers' % entry['map'])


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 3:
        sys.exit('python tools/tv_terrain.py <game root: the unpacked "Tribes Vengeance" folder> <pack folder>')
    retexture(sys.argv[1], sys.argv[2])
