"""Proof-of-life exporter: Earthsiege 2 (1995/96) assets -> gamedata/es2/ (export_es1 schema, unchanged).

ES2 still uses the 3Space v2 formats of Earthsiege 1: VOLN archives (tools/es2_vol.py), DTS/DGS shapes
(tools/dts.py parses all 57 ES2 DTS/DGS files), DBA/DBM bitmaps and DPL palettes (tools/gfx.py).
So export_es1.shape_to_json is reused as-is.

Output (identical schema to gamedata/es1/):
  pack.json, units.json (units.json is hand-written, see docs/formats/es2.md)
  palettes/<NAME>.json      every SIMVOL0 DPL (WORLD0..9, COCKPIT, IMPACT*, LD_*)
                            (WORLD*: runtime cockpit block 0x2A-0x41 filled, make_world_palette)
  textures/<SET>/<i>.png    8-bit palette-index PNGs + textures/<SET>.json [{w,h}]
  shapes/<NAME>.json        export_es1.shape_to_json + texset
  previews/<NAME>.png       tools/preview_gamedata.py

Texture-set per shape: chosen so the shape's highest texture index fits exactly in the set
(OUTLAW 0..23 -> LIGHT(24), TOMAHAWK 0..35 -> MEDIUM(36), SAMSON/COLOSSUS 0..40 -> HEAVY(41),
APOCA 0..51 -> APOCATEX(53), RAPTOR2/MAVERICK/OGRE -> NEWHERCS(44), Cybrids 0..43 -> ENEMY(45),
RAZOR -> RAZORTEX, PITBULL/SKIMMER -> ENEMY). Verified in DBSIM: the unit DAT +0x94 indexes the texture-set
table (tools/export_es2_units.py exports every unit, debris and base shape with the code-derived set).

Usage: python tools/export_es2.py [SHAPE ...]   (default RAPTOR2; --all for every DTS)
"""
import glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dts, gfx, export_es1

import siege_paths as P  # noqa: E402
from pack_json import merge_pack_json  # noqa: E402
SRC = P.work('es2', 'extracted', 'SIMVOL0')
OUT = P.pack('es2')

SHAPE_TEXSET = {
    'OUTLAW': 'LIGHT', 'TOMAHAWK': 'MEDIUM', 'SAMSON': 'HEAVY', 'COLOSSUS': 'HEAVY',
    'APOCA': 'APOCATEX', 'RAPTOR2': 'NEWHERCS', 'MAVERICK': 'NEWHERCS', 'OGRE': 'NEWHERCS',
    'RAZOR': 'RAZORTEX', 'PITBULL': 'ENEMY', 'SKIMMER': 'ENEMY',   # verified: tools/export_es2_units.py
    'ACHILLES': 'ENEMY', 'CERBERUS': 'ENEMY', 'DIABLO': 'ENEMY', 'HEADHUNT': 'ENEMY', 'HYPERION': 'ENEMY',
    'MIRIMAC': 'ENEMY', 'MONGOOSE': 'ENEMY', 'RAMSES': 'ENEMY', 'SCARAB': 'ENEMY', 'STINGRAY': 'ENEMY',
    'SPIDER': 'ENEMY', 'BASES_AN': 'BASETEX', 'MECHWPNS': 'WPNTEX', 'MECHWPN2': 'WPNTEX',
}


# Runtime cockpit colour block (DBSIM 0x429ac4..0x429af3): palette slots 0x2A..0x41 (24 entries) come from
# COCKPIT.DPL[0x20 + 24 * scheme], scheme = word +0x52 of the Herc's unit record. The external view uses scheme 0.
COCKPIT_RANGE_FIRST = 0x2a
COCKPIT_RANGE_COUNT = 0x18
COCKPIT_SCHEME_FIRST = 0x20
DEFAULT_COCKPIT_SCHEME = 0


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, separators=(',', ':'))


def read_palette(name):
    """DPL -> 256 x [r, g, b] (8-bit)."""
    return [list(c[:3]) for c in gfx.read_dpl(open(os.path.join(SRC, 'DPL', name + '.DPL'), 'rb').read())]


def make_world_palette(name, cockpit_scheme=DEFAULT_COCKPIT_SCHEME):
    """WORLD<n>.DPL with the slots DBSIM fills at runtime: 0x429ad1 copies COCKPIT.DPL
    [0x20 + 24*scheme ...] into 0x2A..0x41 via 0x4303c4(first, count, src). The DPL itself holds bright green
    placeholders there, and the WORLD<n>.RMP light tables map some Herc texels into that range."""
    pal = read_palette(name)
    cockpit = read_palette('COCKPIT')
    src = COCKPIT_SCHEME_FIRST + COCKPIT_RANGE_COUNT * cockpit_scheme
    pal[COCKPIT_RANGE_FIRST:COCKPIT_RANGE_FIRST + COCKPIT_RANGE_COUNT] = cockpit[src:src + COCKPIT_RANGE_COUNT]
    return pal


def export_palettes():
    for f in glob.glob(os.path.join(SRC, 'DPL', '*.DPL')):
        name = os.path.splitext(os.path.basename(f))[0].upper()
        pal = make_world_palette(name) if name.startswith('WORLD') else read_palette(name)
        write_json(os.path.join(OUT, 'palettes', name + '.json'), pal)


def export_texture_set(name):
    from PIL import Image
    bmps = gfx.read_any(open(os.path.join(SRC, 'DBA', name + '.DBA'), 'rb').read())
    d = os.path.join(OUT, 'textures', name)
    os.makedirs(d, exist_ok=True)
    meta = []
    for i, b in enumerate(bmps):
        n = b['w'] * b['h']
        Image.frombytes('L', (b['w'], b['h']), bytes(b['pixels'][:n]).ljust(n, b'\0')).save(os.path.join(d, '%d.png' % i))
        meta.append({'w': b['w'], 'h': b['h']})
    write_json(os.path.join(OUT, 'textures', name + '.json'), meta)


def export_shape(name):
    objs = dts.read_file(open(os.path.join(SRC, 'DTS', name + '.DTS'), 'rb').read())
    j = export_es1.shape_to_json(objs, name)
    j['texset'] = SHAPE_TEXSET.get(name)
    write_json(os.path.join(OUT, 'shapes', name + '.json'), j)
    return j


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if '--all' in sys.argv:
        args = sorted(os.path.splitext(os.path.basename(f))[0] for f in glob.glob(os.path.join(SRC, 'DTS', '*.DTS')))
    names = args or ['RAPTOR2']
    write_json(os.path.join(OUT, 'pack.json'), merge_pack_json(OUT, {'name': 'Earthsiege 2', 'default_palette': 'WORLD0', 'unit_scale': 1.0}))
    export_palettes()
    for ts in sorted({SHAPE_TEXSET[n] for n in names if SHAPE_TEXSET.get(n)}):
        export_texture_set(ts)
    for n in names:
        j = export_shape(n)
        print(n, 'texset', j['texset'], 'lods', len(j['lods']), 'nodes', len(j['nodes']),
              'polys(lod0)', sum(len(p['polys']) for p in j['lods'][0]['pieces']))


if __name__ == '__main__':
    main()
