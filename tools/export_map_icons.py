"""The games' own command-map icons -> the engine's command map (docs/COMMAND_MAP.md section 4).

From the user's install:
  Tribes 1   Interface/M_<kind>_green.bmp / _red.bmp (Darkstar PBMP, resolved through the world palette like the
             HUD bitmaps, tools/export_tribes_cockpit.py T1Palette): own side green, the enemy red - kept as drawn;
  Tribes 2   textures/commander/Icons/com_icon_*.png, com_player_grey_24x.png, com_waypoint_1.png (the grey
             CommanderIconData baseImages of scripts/commanderMapIcons.cs; the game tints them by side);
  Starsiege  shell/mapIcon<Kind>.pba (PBMA, frame 0): fill index 240.. (a team colour the sim sets at run time,
             its palette entries are blank in every .ppl) and outline 247 -> a white fill to tint by side and a
             black outline.

Writes gamedata/<pack>/command_map/icons/<name>.png and command_map/icons.json
  {"source": ..., "icons": {kind: {"friend": file, "enemy": file, "tint": bool}}}
for the remake's kinds: self, soldier, herc, tank, flyer, drone, turret, generator, sensor, station, vehicle_station,
camera, flag, nav (a game without a kind leaves it out; the map draws its neutral shape).

Usage: python tools/export_map_icons.py [tribes|tribes2|starsiege|all]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import darkstar_gfx as gfx  # noqa: E402
import siege_paths as P  # noqa: E402
from PIL import Image  # noqa: E402

# Remake kind -> Tribes 1 Interface stem (M_<stem>_green / _red), or a single bitmap (self).
T1_ICONS = {'soldier': 'player', 'herc': 'vehicle', 'tank': 'vehicle', 'flyer': 'vehicle', 'turret': 'turret',
            'generator': 'generator', 'sensor': 'radar', 'station': 'station', 'vehicle_station': 'station',
            'camera': 'camera', 'nav': 'marker'}
T1_SELF = 'M_WhereAmI'
# Remake kind -> Tribes 2 icon (commanderMapIcons.cs datablocks: CMDPlayerIcon, CMDGroundTankIcon, ...).
T2_ICONS = {'soldier': 'com_player_grey_24x', 'herc': 'com_icon_tank', 'tank': 'com_icon_tank',
            'flyer': 'com_icon_scout', 'turret': 'com_icon_turret', 'generator': 'com_icon_generator',
            'sensor': 'com_icon_sensor', 'station': 'com_icon_inventory', 'vehicle_station': 'com_icon_vehicle_inventory',
            'camera': 'com_icon_camera', 'flag': 'com_icon_flag_outside', 'nav': 'com_waypoint_1'}
T2_UNTINTED = {'nav'}          # the waypoint is drawn in its own colours
# Remake kind -> Starsiege shell/mapIcon<Name>.pba.
SS_ICONS = {'herc': 'Herc', 'tank': 'Tank', 'flyer': 'Flyer', 'drone': 'Drone', 'turret': 'Turret', 'nav': 'Nav'}
SS_FILL_FIRST = 240
SS_FILL_LAST = 246
SS_OUTLINE = 247


def write_pack(pack, icons, images, source):
    out = P.pack(pack, 'command_map', 'icons')
    os.makedirs(out, exist_ok=True)
    for name, im in images.items():
        im.save(os.path.join(out, name + '.png'))
    with open(P.pack(pack, 'command_map', 'icons.json'), 'w', encoding='utf-8') as f:
        json.dump({'source': source, 'icons': icons}, f, indent=1)
    print('%s map icons: %d kinds, %d images' % (pack, len(icons), len(images)))


def export_tribes():
    import export_tribes_cockpit as C
    root = P.work('tribes', 'extracted', 'Interface')
    palette = C.T1Palette()

    def load(stem):
        with open(os.path.join(root, stem + '.bmp'), 'rb') as f:
            return palette.image(gfx.read_pbmp(f.read()))
    icons, images = {}, {}
    for kind, stem in T1_ICONS.items():
        for side, colour in (('friend', 'green'), ('enemy', 'red')):
            name = 'M_%s_%s' % (stem, colour)
            if name not in images:
                images[name] = load(name)
        icons[kind] = {'friend': 'M_%s_green.png' % stem, 'enemy': 'M_%s_red.png' % stem, 'tint': False}
    images[T1_SELF] = load(T1_SELF)
    icons['self'] = {'friend': T1_SELF + '.png', 'enemy': T1_SELF + '.png', 'tint': False}
    write_pack('tribes', icons, images, 'Interface/M_*.bmp (green: own side, red: enemy)')


def export_tribes2():
    root = P.work('tribes2', 'extracted', 'textures', 'textures', 'commander', 'Icons')
    icons, images = {}, {}
    for kind, stem in T2_ICONS.items():
        path = os.path.join(root, stem + '.png')
        if os.path.exists(path):
            images[stem] = Image.open(path).convert('RGBA')
            icons[kind] = {'friend': stem + '.png', 'enemy': stem + '.png', 'tint': kind not in T2_UNTINTED}
    write_pack('tribes2', icons, images, 'textures/commander/Icons (scripts/commanderMapIcons.cs baseImage)')


def ss_image(bmp):
    im = Image.new('RGBA', (bmp['w'], bmp['h']))
    table = [(0, 0, 0, 0)] * 256
    for i in range(SS_FILL_FIRST, SS_FILL_LAST + 1):
        table[i] = (255, 255, 255, 255)
    table[SS_OUTLINE] = (0, 0, 0, 255)
    im.putdata([table[p] for p in bmp['pixels'][:bmp['w'] * bmp['h']]])
    return im


def export_starsiege():
    root = P.work('starsiege', 'extracted', 'shell')
    icons, images = {}, {}
    for kind, name in SS_ICONS.items():
        path = os.path.join(root, 'mapIcon%s.pba' % name)
        if os.path.exists(path):
            with open(path, 'rb') as f:
                frames = gfx.read_pba(f.read())
            stem = 'mapIcon' + name
            images[stem] = ss_image(frames[0])
            icons[kind] = {'friend': stem + '.png', 'enemy': stem + '.png', 'tint': True}
    write_pack('starsiege', icons, images, 'shell/mapIcon*.pba frame 0 (fill 240..: team colour, outline 247)')


EXPORTS = {'tribes': export_tribes, 'tribes2': export_tribes2, 'starsiege': export_starsiege}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    which = argv[0] if argv else 'all'
    for pack, fn in EXPORTS.items():
        if which in ('all', pack):
            fn()
    return 0


if __name__ == '__main__':
    sys.exit(main())
