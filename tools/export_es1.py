"""Convert Earth Siege 1 assets into the engine-neutral format read by the Godot runtime.

Output layout (under gamedata/es1/):
  palettes/<NAME>.json            256 x [r,g,b] (8-bit)
  textures/<SET>/<i>.png          8-bit palette-index images (mode "L": value == palette index)
  textures/<SET>.json             [{w,h}] per index
  shapes/<NAME>.json              see shape_to_json()

Engine coordinate conventions are left to the runtime: shapes are emitted in original
units and axes (x right, y forward, z up).
"""
import json, os, sys, glob
sys.path.insert(0, os.path.dirname(__file__))
import dts, gfx

import siege_paths as P  # noqa: E402
EXTRACTED = P.work('extracted')
OUT = P.pack('es1')

TEXTURE_SETS = ['LIGHT', 'MEDIUM', 'HEAVY', 'ENEMY', 'BASETEX', 'WPNTEX', 'CLOUDS2'] + [
    'WORLD%d' % i for i in range(0, 24, 2)]

SHAPE_TEXSET = {
    'ROADRUNN': 'LIGHT', 'GUNSLING': 'LIGHT',
    'RAPTOR': 'MEDIUM', 'TOMAHAWK': 'MEDIUM', 'PATRIOT': 'MEDIUM',
    'PANTHER': 'HEAVY', 'HERCULES': 'HEAVY', 'COLOSSUS': 'HEAVY',
    'ACHILLES': 'ENEMY', 'APOLLO': 'ENEMY', 'BULLDOG': 'ENEMY', 'MIRIMAC': 'ENEMY',
    'MONGOOSE': 'ENEMY', 'RAMSES': 'ENEMY', 'SCORPION': 'ENEMY', 'SPIDER': 'ENEMY',
    'SKIMMER': 'ENEMY',
    'BASES': 'BASETEX', 'BASES_E': 'BASETEX', 'BASES_AE': 'BASETEX', 'BASES_AN': 'BASETEX',
    'BHULKS': 'BASETEX',
    'MECHWPNS': 'WPNTEX', 'MECHWPN2': 'WPNTEX', 'MWPNSB': 'WPNTEX', 'MWPN2B': 'WPNTEX',
}


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, separators=(',', ':'))


# ---------------------------------------------------------------- palettes / textures

def export_palettes():
    for f in glob.glob(os.path.join(EXTRACTED, '*', '*', '*.DPL')):
        name = os.path.splitext(os.path.basename(f))[0]
        try:
            pal = gfx.read_dpl(open(f, 'rb').read())
        except AssertionError:
            continue
        write_json(os.path.join(OUT, 'palettes', name + '.json'), [list(c[:3]) for c in pal])


def export_texture_set(name):
    from PIL import Image
    bmps = gfx.read_any(open(os.path.join(EXTRACTED, 'SIMVOL0', 'DBA', name + '.DBA'), 'rb').read())
    d = os.path.join(OUT, 'textures', name)
    os.makedirs(d, exist_ok=True)
    meta = []
    for i, b in enumerate(bmps):
        img = Image.frombytes('L', (b['w'], b['h']), bytes(b['pixels'][:b['w'] * b['h']]).ljust(b['w'] * b['h'], b'\0'))
        img.save(os.path.join(d, '%d.png' % i))
        meta.append({'w': b['w'], 'h': b['h']})
    write_json(os.path.join(OUT, 'textures', name + '.json'), meta)


# ---------------------------------------------------------------- shapes

def material_of(group, poly):
    c = group['colors'][poly['color']] if poly.get('color') is not None and poly['color'] < len(group['colors']) else b'\0\0\0\0'
    t = poly['type']
    if t == 'texture_for_poly':
        return {'kind': 'tex', 'index': c[0]}
    if t in ('shaded_poly', 'gouraud_poly', 'alias_shaded_poly', 'alias_gouraud_poly'):
        return {'kind': 'shade', 'index': c[0], 'flags': c[3]}
    return {'kind': 'solid', 'index': c[0], 'flags': c[3]}


def polys_of_group(g):
    out = []
    for it in g['items']:
        if 'vlist' not in it:
            continue
        idx = g['indexes'][it['vlist']:it['vlist'] + it['vcount']]
        verts = [list(g['points'][i]) for i in idx]
        n = g['points'][it['normal']] if it['normal'] < len(g['points']) else (0, 0, 2048)
        out.append({
            'v': verts,
            'n': [n[0] / 2048.0, n[1] / 2048.0, n[2] / 2048.0],
            'm': material_of(g, it),
            't': it['type'],
        })
    return out


def flatten_lod(shape):
    """Turn the part tree of one detail level into a flat list of pieces.

    piece = {node, cell (cell_anim_part index or -1), state (child index), polys}
    cells = [{slot (anim_sequence), node, states (count), id (the cell part's own part id: DBSIM findPart
    matches it like any other part, e.g. the ES2 Headhunter's weapon mount part 5 is a cell part)}]
    """
    pieces, cells = [], []

    def walk(o, cell, state):
        t = o['type']
        if t in ('group', 'bsp_group'):
            pieces.append({'node': o['transform'], 'id': o['id'], 'cell': cell, 'state': state, 'polys': polys_of_group(o)})
            return
        if t == 'cell_anim_part':
            ci = len(cells)
            cells.append({'slot': o['anim_sequence'], 'node': o['transform'], 'states': len(o['parts']), 'id': o['id']})
            for si, c in enumerate(o['parts']):
                walk(c, ci, si)
            return
        if t == 'detail_part':
            # detail levels are ordered low -> high (size thresholds ascending): keep the most detailed
            if o['parts']:
                walk(o['parts'][-1], cell, state)
            return
        for c in o.get('parts', []):
            walk(c, cell, state)

    walk(shape, -1, 0)
    return pieces, cells


def shape_to_json(objs, name):
    shapes = [o for o in objs if o['type'] in ('shape', 'an_shape', 'grid_shape')]
    lods = []
    anim = None
    for s in shapes:
        pieces, cells = flatten_lod(s)
        lods.append({'radius': s['radius'], 'center': list(s['center']), 'pieces': pieces, 'cells': cells})
        if anim is None:
            al = [e for e in s.get('extra', []) if e['type'] == 'an_anim_list']
            if al:
                anim = al[0]
    out = {'name': name, 'texset': SHAPE_TEXSET.get(name), 'lods': lods}
    if anim:
        rel = {d: p for p, d in anim['relations']}
        out['nodes'] = [{'parent': rel.get(i, -1), 'default': anim['default_transforms'][i]}
                        for i in range(len(anim['default_transforms']))]
        out['transforms'] = [list(t) for t in anim['transforms']]
        out['sequences'] = [{
            'tick': s['tick'], 'priority': s['priority'], 'gm': s['gm'],
            'frames': [list(f) for f in s['frames']],
            'parts': s['part_list'],
            'tf': s['transform_index'],
        } for s in anim['sequences']]
        out['transitions'] = [list(t) for t in anim['transitions']]
        out['sequence_list'] = shapes[0].get('sequence_list', [])
    else:
        out['nodes'] = []
    return out


def export_shapes():
    files = glob.glob(os.path.join(EXTRACTED, 'SIMVOL0', 'DTS', '*.DTS')) + \
        glob.glob(os.path.join(EXTRACTED, 'SIMVOL0', 'DGS', '*.DGS'))
    index = []
    for f in sorted(files):
        name, ext = os.path.splitext(os.path.basename(f))
        objs = dts.read_file(open(f, 'rb').read())
        if ext.upper() == '.DGS' or name in ('MECHWPNS', 'MECHWPN2', 'MWPNSB', 'MWPN2B'):
            # a DGS is a library of independent objects (terrain features, base buildings)
            groups = [('%s_%d' % (name, i), [o]) for i, o in enumerate(objs)]
        else:
            groups = [(name, objs)]
        for shape_name, o in groups:
            j = shape_to_json(o, shape_name)
            j['texset'] = SHAPE_TEXSET.get(name)
            write_json(os.path.join(OUT, 'shapes', shape_name + '.json'), j)
            index.append({'name': shape_name, 'lods': len(j['lods']), 'kind': ext[1:].lower()})
    write_json(os.path.join(OUT, 'shapes', '_index.json'), index)


def export_ground_textures():
    from PIL import Image
    d = os.path.join(OUT, 'textures', 'ground')
    os.makedirs(d, exist_ok=True)
    for f in glob.glob(os.path.join(EXTRACTED, 'SIMVOL0', 'DBA', '*.64K')):
        raw = open(f, 'rb').read()
        Image.frombytes('L', (256, 256), raw[:65536]).save(
            os.path.join(d, os.path.splitext(os.path.basename(f))[0] + '.png'))


def export_cockpits():
    """Cockpit overlays: DB0 front view, DB1 look-down panel, DB2 side view (RGBA, index 0 transparent)."""
    import struct
    pal = gfx.read_dpl(open(os.path.join(EXTRACTED, 'SIMVOL0', 'DPL', 'COCKPIT.DPL'), 'rb').read())
    d = os.path.join(OUT, 'cockpits')
    os.makedirs(d, exist_ok=True)
    for f in glob.glob(os.path.join(EXTRACTED, 'SIMVOL0', 'VUE', '*.VUE')):
        name = os.path.splitext(os.path.basename(f))[0]
        raw = open(f, 'rb').read()
        v = struct.unpack('<%di' % (len(raw) // 4), raw)
        views = [list(v[1 + i * 8:9 + i * 8]) for i in range(v[0])]
        for k in range(3):
            src = os.path.join(EXTRACTED, 'SIMVOL0', 'DB%d' % k, '%s.DB%d' % (name, k))
            if os.path.exists(src):
                b = gfx.read_any(open(src, 'rb').read())[0]
                gfx.to_image(b, pal).save(os.path.join(d, '%s_%d.png' % (name, k)))
        write_json(os.path.join(d, name + '.json'), {'views': views})


def export_worlds():
    """World render settings (tools/world.py) and terrain zone placements."""
    import world
    from PIL import Image
    wdir = os.path.join(OUT, 'worlds')
    for i in range(24):
        w = world.World(i)
        world.dump_world(w, wdir)
        if i & 1:
            continue  # odd worlds are low-detail variants sharing the palette
        # palette with the runtime-filled cockpit range
        write_json(os.path.join(OUT, 'palettes', w.palette_name + '.json'), [list(c[:3]) for c in w.palette])
        world.make_shade_list_image(w.dpl_lists).save(os.path.join(wdir, 'shade_%d.png' % i))
        world.make_light_table_image(w.texture_light_tables()).save(os.path.join(wdir, 'texlight_%d.png' % i))
        gl = Image.new('L', (16, 15))
        for j, row in enumerate(w.ground_tables):
            for c, v in enumerate(row):
                gl.putpixel((c, j), v)
        gl.save(os.path.join(wdir, 'groundlut_%d.png' % i))
    world.dump_terrain(os.path.join(OUT, 'terrain'))
    zdir = os.path.join(OUT, 'zones')
    for f in glob.glob(os.path.join(EXTRACTED, '*', 'DAT', 'ZONE*.DAT')):
        n = int(os.path.splitext(os.path.basename(f))[0][4:])
        try:
            z = world.read_zone(n)
        except Exception as e:  # noqa: BLE001 - keep going, report
            print('zone', n, 'failed:', e)
            continue
        z.pop('file', None)
        write_json(os.path.join(zdir, '%d.json' % n), z)


def main():
    export_worlds()
    export_cockpits()
    export_palettes()
    export_ground_textures()
    for s in TEXTURE_SETS:
        export_texture_set(s)
    export_shapes()
    print('done ->', os.path.abspath(OUT))


if __name__ == '__main__':
    main()
