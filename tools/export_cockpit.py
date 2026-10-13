"""Export the Earth Siege cockpit instruments to gamedata/es1/cockpit/ for the Godot remake.

    python tools/export_cockpit.py [outdir]      (default gamedata/es1/cockpit)

Reuses tools/cockpit.py (GAU / VUE / ED / PDG / OFS decoders, spec docs/formats/cockpit.md),
tools/shell.py (DFN fonts) and tools/world.py (runtime palette composition).

Output (all bitmaps RGBA, index 0 transparent):
  palette.json                 256 x [r,g,b] runtime cockpit palette (WORLD0 + cockpit scheme, docs/formats/world.md 3.2)
  layout/<HERC>.json           decoded GAU layout (absolute 320x400 panel coords) + views + window spans
                               (ED0..ED3 as [y, xL, xR] lists) + engine clip spans + guns display_index
  panels/<HERC>_DB0/1/2.png    front overlay / look-down panel / side view
  dba/<NAME>/<i>.png + dba/<NAME>.json   instrument bitmaps (PBUTTONS, RADAR, HUD*, THR_LED*, ICONS, ...)
  fonts/<NAME>.png + .json     DFN font atlases ({height, chars: {code: [x, y, w]}})
  pdg/<UNIT>.json + pdg/<UNIT>_<i>.png    damage diagrams (regions) + unit DBA images
  pilots/<PILOTn[S]>_<i>.png + pilots/<PILOTn>.json   comm-video parts + OFS offsets
  strings0.json                STRINGS0 label groups
"""
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cockpit  # noqa: E402
import gfx  # noqa: E402

import siege_paths as P  # noqa: E402
SIM = cockpit.SIM

DBAS = ['PBUTTONS', 'ICONS', 'HUDHSLID', 'HUDHTICK', 'HUDVSLID', 'RADAR', 'STATIC', 'THR_LED1', 'THR_LED2',
        'SMLWLD0', 'SMLWLD1', 'SMLWLD2', 'WEAPONS', 'CORNERS', 'BASES', 'FLYERS']
FONTS = ['CPBLACK', 'CPBLUE', 'CPGREEN', 'CPGREY', 'CPOFF', 'CPON', 'CPORANGE', 'CPPRESS', 'CPRED', 'CPYLW',
         'GREEN6X8', 'RED6X8']
# Cockpit colour scheme (COCKPIT.DPL block, VUE object +0x23; source not traced). 0 = olive.
SCHEME = 0
# brightness ramp 0x50..0x55 (base RGB (25,59,23), docs/formats/cockpit.md 3.4) at ~75 %
GREEN_BASE = (25, 59, 23)


def runtime_palette(scheme=SCHEME):
    import world
    w = world.World(0, scheme)
    pal = [list(c[:3]) for c in w.palette]
    for i in range(6):
        f = 1.0 + i * 0.55
        pal[0x50 + i] = [min(255, int(c * f)) for c in GREEN_BASE]
    return pal


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(obj, f, indent=indent)


def save(b, pal, path, transparent=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    gfx.to_image(b, [tuple(c) for c in pal], transparent).save(path)


def export(out):
    os.makedirs(out, exist_ok=True)
    pal = runtime_palette()
    write_json(os.path.join(out, 'palette.json'), pal)

    # ---- instrument bitmaps
    for n in DBAS:
        try:
            bs = cockpit.dba(n)
        except FileNotFoundError:
            continue
        for i, b in enumerate(bs):
            save(b, pal, os.path.join(out, 'dba', n, '%d.png' % i))
        write_json(os.path.join(out, 'dba', n + '.json'), {'count': len(bs), 'sizes': [[b['w'], b['h']] for b in bs]})

    # ---- fonts
    import shell
    for n in FONTS:
        f = shell.read_dfn(cockpit._rd('DFN', n + '.DFN'))
        rgba, _idx, rects = shell.font_atlas(f, [tuple(c) for c in pal])
        os.makedirs(os.path.join(out, 'fonts'), exist_ok=True)
        rgba.save(os.path.join(out, 'fonts', n + '.png'))
        chars = {str(g['code']): [x, y, w] for g, (x, y, w, h) in zip(f['glyphs'], rects)}
        write_json(os.path.join(out, 'fonts', n + '.json'), {'height': f['height'], 'chars': chars})

    # ---- edge regions
    edg = {}
    for p in sorted(glob.glob(os.path.join(SIM, 'EDG', '*.EDG'))):
        edg[os.path.splitext(os.path.basename(p))[0]] = [list(s) for s in cockpit.read_edges(open(p, 'rb').read())]

    # ---- per-Herc layouts + panels
    hercs = json.load(open(P.work('extracted', 'gameplay', 'hercs.json')))
    for h in cockpit.HERCS:
        lay = cockpit.read_gau(cockpit._rd('GAU', h + '.GAU'))
        lay['herc'] = h
        lay['views'] = cockpit.read_vue(cockpit._rd('VUE', h + '.VUE'))
        lay['windows'] = [[list(s) for s in cockpit.read_edges(cockpit._rd('ED%d' % k, '%s.ED%d' % (h, k)))]
                          for k in range(4)]
        eb = lay['gauges']['engine_bar']
        eb['clip_spans'] = edg.get(eb['edg_clip']) if eb['edg_clip'] else None
        lay['gun_slots'] = [g.get('display_index', i) for i, g in enumerate(hercs.get(h, {}).get('guns', []))]
        lay['palette_scheme'] = SCHEME
        lay['panels'] = {'front': 'panels/%s_DB0.png' % h, 'look_down': 'panels/%s_DB1.png' % h,
                         'side': 'panels/%s_DB2.png' % h}
        write_json(os.path.join(out, 'layout', h + '.json'), lay)
        for k in '012':
            b = gfx.read_any(cockpit._rd('DB' + k, '%s.DB%s' % (h, k)))[0]
            save(b, pal, os.path.join(out, 'panels', '%s_DB%s.png' % (h, k)))

    # ---- damage diagrams
    write_json(os.path.join(out, 'pdg', 'WEAPONS.json'),
               {'sizes_wh': cockpit.read_weapons_pdg(cockpit._rd('PDG', 'WEAPONS.PDG'))})
    for p in sorted(glob.glob(os.path.join(SIM, 'PDG', '*.PDG'))):
        name = os.path.splitext(os.path.basename(p))[0]
        if name == 'WEAPONS':
            continue
        pdg = cockpit.read_pdg(open(p, 'rb').read())
        try:
            bs = cockpit.dba(name)
        except FileNotFoundError:
            bs = []
        for i, b in enumerate(bs):
            save(b, pal, os.path.join(out, 'pdg', '%s_%d.png' % (name, i)))
        pdg['image_count'] = len(bs)
        write_json(os.path.join(out, 'pdg', name + '.json'), pdg)

    # ---- pilot comm video parts
    for p in sorted(glob.glob(os.path.join(SIM, 'OFS', '*.OFS'))):
        name = os.path.splitext(os.path.basename(p))[0]
        meta = {'ofs': cockpit.read_ofs(open(p, 'rb').read()), 'format': '(dba_index, dx, dy)', 'sets': {}}
        for suf in ('', 'S'):
            try:
                bs = cockpit.dba(name + suf)
            except FileNotFoundError:
                continue
            for i, b in enumerate(bs):
                save(b, pal, os.path.join(out, 'pilots', '%s%s_%d.png' % (name, suf, i)))
            meta['sets'][name + suf] = [[b['w'], b['h']] for b in bs]
        write_json(os.path.join(out, 'pilots', name + '.json'), meta)

    # ---- strings
    write_json(os.path.join(out, 'strings0.json'), cockpit.read_strings0(cockpit._rd('STR', 'STRINGS0.STR')), 1)
    print('wrote', out)


def main(argv):
    export(argv[1] if len(argv) > 1 else P.pack('es1', 'cockpit'))


if __name__ == '__main__':
    main(sys.argv)
