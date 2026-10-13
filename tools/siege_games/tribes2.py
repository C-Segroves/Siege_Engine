"""Tribes 2 (2001) -> pack "tribes2" (armor and vehicle shapes with RGBA skins, script catalogue, the six vehicles
with their fixed weapons - tools/export_tribes_vehicles.py - and the 52 missions as arena maps: terrain, interiors,
stations, spawns - tools/export_tribes2_maps.py; the training missions' scripts and voice -
tools/export_tribes_missions.py).

The .vl2 archives on the disc (Tribes2/GameData/base) are plain ZIP files. Uses tools/export_tribes2.py and
tools/catalog_tribes2.py (paths redirected with siege_games.relocate).
"""
import os
import zipfile

from siege_games import Step, relocate, call_main

GAME = {
    'game': 'tribes2', 'pack': 'tribes2', 'name': 'Tribes 2', 'discs': 1,
    'main_exe': {'disc': 'Tribes2/GameData/Tribes2.exe'}, 'version_file': 'Readme.txt',   # tools/disc_version.py
    'pack_json': {'name': 'Tribes 2', 'engine': 'torque_v12', 'unit_scale': 256.0, 'texture_format': 'rgba',
                  'weapon_families': ['infantry', 'vehicle', 'turret'],
                  'era': 5, 'year': 3941},
}
BASE = 'Tribes2/GameData/base'
VL2 = ['shapes', 'skins', 'textures', 'scripts', 'missions', 'interiors', 'lush', 'desert', 'ice', 'lava', 'badlands',
       'audio', 'voice', 'base']   # base.vl2: the GUI fonts (tools/export_tribes_cockpit.py)
# armors; the six vehicles (scripts/vehicles/*.cs shapeFile) with their turrets, weapon models and bomb
SHAPES = ['light_male', 'heavy_male', 'vehicle_grav_scout', 'vehicle_air_scout', 'vehicle_air_bomber',
          'vehicle_air_hapc', 'vehicle_grav_tank', 'vehicle_land_mpbase', 'turret_tank_base', 'turret_tank_barrelchain',
          'turret_tank_barrelmortar', 'turret_belly_base', 'turret_belly_barrell', 'turret_belly_barrelr',
          'weapon_energy_vehicle', 'bomb']
# infantry: the medium armour, the hand weapons' models (scripts/weapons/*.cs shapeFile; weapon_energy = the
# blaster, DTS v21) and the projectile models (projectileShapeName: disc, v18 grenade / mortar, v19 missile)
SHAPES += ['medium_male', 'weapon_energy', 'weapon_chaingun', 'weapon_disc', 'weapon_grenade_launcher', 'weapon_mortar',
           'weapon_plasma', 'weapon_missile', 'weapon_sniper', 'weapon_shocklance', 'weapon_elf', 'disc',
           'grenade_projectile', 'mortar_projectile', 'weapon_missile_projectile']
# the Bioderm bodies (the extraction mode's Bioderm faction wears them over the Tribes 2 armour stats)
SHAPES += ['bioderm_light', 'bioderm_medium', 'bioderm_heavy']
# the female bodies (a player's choice of body over the same armour, InfantryCatalog.make_bodies)
SHAPES += ['light_female', 'medium_female']


def identify(disc):
    if disc.exists(BASE + '/shapes.vl2') and disc.exists(BASE + '/scripts.vl2'):
        return 1
    return 0


def _extract(ctx):
    for i, n in enumerate(VL2):
        ctx.extract(1, '%s/%s.vl2' % (BASE, n), ctx.work_path('tribes2', 'original', n + '.vl2'), 'Copying %s.vl2' % n)
    # the engine's projectile gravity (export_tribes_vehicles.t2_gravity) is read from the executable
    ctx.extract(1, 'Tribes2/GameData/Tribes2.exe', ctx.work_path('tribes2', 'original', 'Tribes2', 'GameData', 'Tribes2.exe'),
                'Copying Tribes2.exe')


def _unzip(ctx):
    for i, n in enumerate(VL2):
        ctx.message('Unpacking %s.vl2' % n, i / len(VL2))
        src = ctx.work_path('tribes2', 'original', n + '.vl2')
        with zipfile.ZipFile(src) as z:
            z.extractall(ctx.work_path('tribes2', 'extracted', n))
        os.remove(src)


def _shapes(ctx):
    import export_tribes2 as T
    relocate(T)
    call_main(T, *SHAPES)


def _catalog(ctx):
    try:
        import catalog_tribes2 as C
        relocate(C)
        call_main(C)
    except Exception as e:  # noqa: BLE001 - the catalogue is informational
        ctx.note('Tribes 2 catalogue skipped (%s: %s)' % (type(e).__name__, e))


def _vehicles(ctx):
    import export_tribes_vehicles as V
    call_main(V, 'tribes2')


def _infantry(ctx):
    import export_tribes_infantry as I
    call_main(I, 'tribes2')


def _maps(ctx):
    import export_tribes2_maps as M
    call_main(M)


def steps(ctx):
    return [
        Step('extract', 'Copying game archives from the disc...', 20, _extract),
        Step('archives', 'Unpacking .vl2 archives...', 20, _unzip),
        Step('assets', 'Converting armor and vehicle shapes...', 10, _shapes),
        Step('catalog', 'Cataloguing weapons and vehicles...', 5, _catalog),
        Step('vehicles', 'Converting the vehicles and their weapons...', 3, _vehicles),
        Step('infantry', 'Converting the armors and hand weapons...', 2, _infantry),
        Step('maps', 'Converting missions to arena maps (terrain, interiors, stations)...', 300, _maps),
        Step('base', 'Reading the bases (turrets, generators, sensors, stations)...', 2,
             lambda c: c.run_tool('export_tribes_base', 'tribes2')),
        # after the base: the turret guns get their effects too
        Step('weapon_fx', 'Decoding weapon effects (projectiles, beams, explosions)...', 3,
             lambda c: c.run_tool('fx_tribes2')),
        Step('modes', 'Reading the multiplayer game modes of every map...', 3, lambda c: c.run_tool('export_game_modes', 'tribes2')),
        Step('items', 'Placing the items lying in the maps (weapons, ammo, packs)...', 3,
             lambda c: c.run_tool('export_tribes_items', 'tribes2')),
        Step('cockpit', 'Exporting the HUD / cockpit instruments...', 2,
             lambda c: (c.run_tool('export_tribes_cockpit', 'tribes2'), c.run_tool('cockpit_hud_layouts', 'tribes2'))),
        Step('music', 'Reading which music plays where...', 0.5, lambda c: c.run_tool('music_situations', 'tribes2')),
        Step('training', 'Converting the training missions (scripts, voice)...', 15,
             lambda c: c.run_tool('export_tribes_missions', 'tribes2')),
        Step('map_icons', 'Converting the command map icons...', 0.5, lambda c: c.run_tool('export_map_icons', 'tribes2')),
    ]
