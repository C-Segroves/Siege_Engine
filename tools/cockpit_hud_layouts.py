"""Turn a decoded HUD (gamedata/<pack>/cockpit/hud.json, written by the pack's HUD exporter) into the engine's
cockpit layouts and the pack's cockpit choice table (docs/formats/cockpit.md section 9).

    python tools/cockpit_hud_layouts.py <pack> [cockpit_dir]       (pack: starsiege, bd, tribes, tribes2)

Output, next to hud.json:
  layout/<NAME>.json   {"canvas": {"size", "look_down_top"}, "palette"?, "gauges": {"hud": {"center"}}, "meters": [...]}
                       one per UI the game gives a kind of vehicle; read by game/games/es1/cockpit/ (CockpitDisplay,
                       CockpitMeters: a layout with "meters" and no "panels" is a HUD over the whole view)
  fit.json             {"by_vehicle", "by_kind_side", "by_side", "by_kind", "default"}: which layout a vehicle of the
                       pack gets (CockpitFit rule 2)

Remake decisions (documented in cockpit.md section 9):
  * Starsiege: one HUD for Hercs and tanks (both were player vehicles in the original; the same meters,
    Starsiege.exe 0x49b4d8 / 0x42f76d) and one for flyers (no internals meter, 0x437e19). Human and Cybrid pilots
    share the HUD art and colours (0x50be7c): the only faction difference is the 3D cockpit interior.
    The mission timers and the commander's order meter are left out (no script timers / commander role yet).
  * Tribes 2: the Thundersword pilot and the Beowulf driver get their gunner seat's reticle, because the remake's
    pilot fires the gunner weapons (docs/formats/tribes_vehicles.md section 5).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
from PIL import Image  # noqa: E402

STARSIEGE_SKIPPED_KINDS = {'timer', 'command'}
STARSIEGE_FLYER_SKIPPED_KINDS = STARSIEGE_SKIPPED_KINDS | {'internal_damage'}
STARSIEGE_RADAR_SCOPE_INDEX = 247       # the dark scope disc of radar_high.pba frame 2 (index 247, 'background')
STARSIEGE_RADAR_SCOPE_FRAME = 2
# Vehicle kinds the original let the player pilot (fit.json "native_kinds"): Starsiege Hercs, and tanks in
# multiplayer (Server_DM_TANKS.cs); every Tribes vehicle the remake lets a player pilot.
STARSIEGE_PLAYER_KINDS = ['herc', 'tank']
TRIBES_PLAYER_KINDS = ['herc', 'tank', 'flyer']
TRIBES2_PILOT_EXTRA = {'THUNDERSWORD': ['t2_reticle_bombardier'], 'BEOWULF': ['t2_reticle_tank']}


def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1)


def make_layout(hud, meters, palette=None, centre=None):
    w, h = hud['canvas']
    out = {'canvas': {'size': [w, h], 'look_down_top': h},
           'gauges': {'hud': {'center': centre or [w // 2, h // 2]}},
           'meters': meters, 'source': 'hud.json'}
    if palette:
        out['palette'] = palette
    return out


# ------------------------------------------------------------------ Starsiege

def make_radar_scope(cockpit_dir, radar):
    """Bounds [x0, y0, x1, y1] of the radar's scope disc inside the radar art (contacts are drawn in it)."""
    img = Image.open(os.path.join(cockpit_dir, 'dba', radar['dba'], '%d.png' % STARSIEGE_RADAR_SCOPE_FRAME))
    px = img.load()
    xs, ys = [], []
    for y in range(img.height):
        for x in range(img.width):
            if px[x, y] == STARSIEGE_RADAR_SCOPE_INDEX:
                xs.append(x)
                ys.append(y)
    return [min(xs), min(ys), max(xs), max(ys)] if xs else [0, 0, img.width - 1, img.height - 1]


def starsiege_layouts(cockpit_dir, hud):
    meters = [dict(m) for m in hud['meters']]
    for m in meters:
        if m['kind'] == 'radar':
            m['scope'] = make_radar_scope(cockpit_dir, m)
    palette = hud['variants']['human']['palette']
    walker = [m for m in meters if m['kind'] not in STARSIEGE_SKIPPED_KINDS]
    flyer = [m for m in meters if m['kind'] not in STARSIEGE_FLYER_SKIPPED_KINDS]
    layouts = {'HUD': make_layout(hud, walker, palette), 'HUD_FLYER': make_layout(hud, flyer, palette)}
    fit = {'by_kind': {'herc': 'HUD', 'tank': 'HUD', 'flyer': 'HUD_FLYER'}, 'default': 'HUD',
           'native_kinds': STARSIEGE_PLAYER_KINDS}
    return layouts, fit


# ------------------------------------------------------------------ Tribes / Tribes 2

def per_vehicle_layouts(hud, extra=None):
    by_id = {m['id']: m for m in hud['meters']}
    layouts = {}
    for vid, ids in hud['per_vehicle'].items():
        if '/' in vid or vid == 'INFANTRY':
            continue
        ids = list(ids) + (extra or {}).get(vid, [])
        layouts[vid] = make_layout(hud, [by_id[i] for i in ids if i in by_id], hud.get('palette'))
    return layouts


def tribes_layouts(cockpit_dir, hud):
    layouts = per_vehicle_layouts(hud)
    first = sorted(layouts)[0]
    return layouts, {'by_vehicle': {k: k for k in layouts}, 'default': first, 'native_kinds': TRIBES_PLAYER_KINDS}


def tribes2_layouts(cockpit_dir, hud):
    layouts = per_vehicle_layouts(hud, TRIBES2_PILOT_EXTRA)
    fit = {'by_vehicle': {k: k for k in layouts}, 'by_kind': {'flyer': 'SHRIKE', 'tank': 'BEOWULF'}, 'default': 'SHRIKE',
           'native_kinds': TRIBES_PLAYER_KINDS}
    return layouts, fit


# ------------------------------------------------------------------ Battledrome

def bd_layouts(cockpit_dir, hud):
    view = hud.get('view', {})
    centre = None
    if 'centre_row' in view:
        centre = [hud['canvas'][0] // 2, int(view['centre_row'])]
    meters = [dict(m) for m in hud['meters'] if m.get('visible', True)]
    hercs = load_json(os.path.join(cockpit_dir, '..', 'gameplay', 'hercs.json'))
    for m in meters:
        if m['kind'] == 'shields':
            m['herc_order'] = list(hercs)       # SIM.EXE Herc table order = the diagram list's order
    return {'HUD': make_layout(hud, meters, 'palette.json', centre)}, {'default': 'HUD', 'native_kinds': ['herc']}


BUILDERS = {'starsiege': starsiege_layouts, 'tribes': tribes_layouts, 'tribes2': tribes2_layouts, 'bd': bd_layouts}


def export(pack, cockpit_dir=None):
    cockpit_dir = cockpit_dir or P.pack(pack, 'cockpit')
    hud = load_json(os.path.join(cockpit_dir, 'hud.json'))
    layouts, fit = BUILDERS[pack](cockpit_dir, hud)
    for name, layout in layouts.items():
        write_json(os.path.join(cockpit_dir, 'layout', name + '.json'), layout)
    write_json(os.path.join(cockpit_dir, 'fit.json'), fit)
    print('%s cockpit layouts: %s' % (pack, ', '.join(sorted(layouts))))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    export(argv[0], argv[1] if len(argv) > 1 else None)


if __name__ == '__main__':
    main()
