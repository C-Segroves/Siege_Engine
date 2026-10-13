"""Proof-of-life exporter: Starsiege (1999, Darkstar) shapes -> gamedata/starsiege/.

Starsiege uses the same Darkstar formats as Starsiege: Tribes (DTS v7 for most entities, PBMP 8-bit skins
selected by PiDX palette id, PL98 world palettes), so this re-uses tools/export_tribes.py unchanged by
pointing its module globals at the Starsiege tree:
  SRC      = starsiege/extracted          (tools/darkstar_vol.py + tools/darkstar_lzh.py output)
  OUT      = gamedata/starsiege
  WORLD_PPL= Mars.Sim/Mars.d.ppl          (entity skins use the shared low palette ids, like Tribes)
and choosing the standing pose: Herc shapes have no "root" sequence; sequence "Seq02_stand" is used
(Tribes: sequence 0 "root").  Output schema = export_tribes (palette-index PNGs, explicit per-triangle uv,
nodes/transforms, ds_sequences, bounds), see docs/formats/tribes.md section 5.

Usage: python tools/export_starsiege.py [shape ...]     (default: tr_apoc)
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import export_tribes as ET

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
ET.SRC = os.path.join(ROOT, 'starsiege', 'extracted')
ET.OUT = os.path.join(ROOT, 'gamedata', 'starsiege')
ET.WORLD_PPL = ('Mars.Sim', 'Mars.d.ppl')
_root_pose = ET.root_pose


def stand_pose(s, seq=0):
    names = s['names']
    for i, q in enumerate(s['sequences']):
        if names[q['name']].lower() in ('seq02_stand', 'root', 'stand'):
            return _root_pose(s, i)
    return _root_pose(s, seq) if s['sequences'] else [nd['default'] for nd in s['nodes']]


ET.root_pose = stand_pose


def main():
    import darkstar_gfx as G
    names = sys.argv[1:] or ['tr_apoc']
    ppl = G.read_ppl(open(os.path.join(ET.SRC, *ET.WORLD_PPL), 'rb').read())
    for n in names:
        j = ET.export_shape(n, ppl)
        print(n, 'lods', len(j['lods']), 'pieces', len(j['lods'][0]['pieces']),
              'polys', sum(len(p['polys']) for p in j['lods'][0]['pieces']), 'flip', j['winding_flipped'])
    # export_tribes.main writes a Tribes pack.json; write the Starsiege one here instead
    ET.write_json(os.path.join(ET.OUT, 'pack.json'), {
        'name': 'Starsiege', 'default_palette': 'Mars_d_1', 'engine': 'darkstar',   # skins carry PiDX 1
        'unit_scale': 256.0, 'weapon_families': ['herc']})


if __name__ == '__main__':
    main()
