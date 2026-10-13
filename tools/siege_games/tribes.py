"""Starsiege: Tribes (1998) -> pack "tribes": armor and vehicle shapes with skins and palette, the vehicles with their
fixed weapons (tools/export_tribes_vehicles.py), the infantry armours and hand weapons
(tools/export_tribes_infantry.py), multiplayer maps (terrain, interiors, stations, spawns;
tools/export_darkstar_maps.py), the training missions (scripts and maps; tools/export_tribes_missions.py)."""
import os

from siege_games import Step

GAME = {
    'game': 'tribes', 'pack': 'tribes', 'name': 'Starsiege: Tribes', 'discs': 1,
    'main_exe': {'disc': 'Tribes/tribes.exe'},   # release identification (tools/disc_version.py)
    'cd_audio': True,        # scripts play Red Book tracks (rbPlay(CD, $cdTrack)); the main menu plays track 2
    'pack_json': {'name': 'Starsiege: Tribes', 'default_palette': 'lush_day_1136', 'engine': 'darkstar',
                  'unit_scale': 256.0,
                  'era': 5, 'year': 3940},
}
# armors; the Scout / LPC / HPC fliers (scripts/vehicle.cs shapeFile) and the Scout's rocket (FlierRocket)
SHAPES = ['larmor', 'lfemale', 'mfemale', 'harmor', 'flyer', 'hover_apc_sml', 'hover_apc', 'rocket']
# the medium armour and the hand weapons' models (scripts/item.cs ItemImageData shapeFile; infantry)
SHAPES += ['marmor', 'energygun', 'chaingun', 'plasma', 'grenadel', 'mortargun', 'disc', 'sniper', 'shotgun']
# projectile models of the hand weapons (baseProjData.cs bulletShapeName; chaingun tracer) for tools/fx_tribes.py
SHAPES += ['discb', 'grenade', 'mortar', 'tracer']
# Darkstar volumes the exported shapes need (shapes/skins in Entities, the world palette in lushWorld); sound.vol
# holds the vehicle weapons' fire sounds
VOLS = ['Entities.vol', 'lushWorld.vol', 'sound.vol']
# multiplayer maps (tools/export_darkstar_maps.py): world sets (palettes/sky, terrain DML, tile + interior
# bitmaps and geometry) and the scripts (datablock -> shape); the missions folder is read in place
WORLDS = ['alien', 'desert', 'ice', 'lush', 'mars', 'mud']
VOLS += ['scripts.vol', 'human1DML.vol', 'savanaDML.vol', 'titanDML.vol']
VOLS += ['%s%s.vol' % (w, k) for w in WORLDS for k in ('World', 'Terrain', 'DML') if '%s%s' % (w, k) != 'lushWorld']
# HUD / cockpit and command map icons (tools/export_tribes_cockpit.py, export_map_icons.py): bitmaps, fonts, play.gui
VOLS += ['Interface.vol', 'fonts.vol', 'gui.vol']


def identify(disc):
    if disc.exists('Tribes/base/Entities.vol') and disc.exists('Tribes/tribes.exe'):
        return 1
    return 0


def _extract(ctx):
    for v in VOLS:
        ctx.extract(1, 'Tribes/base/' + v, ctx.work_path('tribes', 'original', 'Tribes', 'base', v), 'Copying ' + v)
    _extract_missions(ctx)


def _extract_missions(ctx):
    ctx.extract(1, 'Tribes/base/missions', ctx.work_path('tribes', 'original', 'Tribes', 'base', 'missions'),
                'Copying missions')


def _vols(ctx):
    import darkstar_vol
    for v in VOLS:
        darkstar_vol.extract(ctx.work_path('tribes', 'original', 'Tribes', 'base', v), ctx.work_path('tribes', 'extracted'))


def _base_equipment(ctx):
    """Turrets, generators, sensors and stations of the maps (tools/export_tribes_base.py); it reads the static
    shapes' disabled ratio from tribes.exe."""
    ctx.extract(1, 'Tribes/tribes.exe', ctx.work_path('tribes', 'original', 'Tribes', 'tribes.exe'), 'Copying tribes.exe')
    ctx.run_tool('export_tribes_base', 'tribes')


def cd_audio_uses(ctx, numbers):
    """scripts/GUI.CS: the main menu plays track 2 (gameCD() too); servers send their mission's $cdTrack to
    clients (remoteSetMusic), so every audio track is mission music."""
    return {n: {'use': 'music: main menu' if n == 2 else 'music: missions ($cdTrack)'} for n in numbers}


def steps(ctx):
    return [
        Step('extract', 'Copying game archives and missions from the disc...', 12, _extract),
        Step('archives', 'Unpacking Darkstar volumes...', 10, _vols),
        Step('assets', 'Converting armor and vehicle shapes and skins...', 8, lambda c: c.run_tool('export_tribes', *SHAPES)),
        Step('vehicles', 'Converting the vehicles and their weapons...', 2,
             lambda c: c.run_tool('export_tribes_vehicles', 'tribes')),
        Step('infantry', 'Converting the armors and hand weapons...', 2,
             lambda c: c.run_tool('export_tribes_infantry', 'tribes')),
        Step('quick_chat', 'Converting the chat menu...', 1, lambda c: c.run_tool('export_tribes_quickchat')),
        Step('maps', 'Converting the multiplayer maps (terrain, bases, stations)...', 110,
             lambda c: c.run_tool('export_darkstar_maps', 'tribes')),
        Step('modes', 'Reading the multiplayer game modes of every map...', 3, lambda c: c.run_tool('export_game_modes', 'tribes')),
        Step('items', 'Placing the items lying in the maps (weapons, ammo, packs)...', 3,
             lambda c: c.run_tool('export_tribes_items', 'tribes')),
        Step('cockpit', 'Exporting the HUD / cockpit instruments...', 2,
             lambda c: (c.run_tool('export_tribes_cockpit', 'tribes'), c.run_tool('cockpit_hud_layouts', 'tribes'))),
        Step('music', 'Reading which music plays where...', 0.5, lambda c: c.run_tool('music_situations', 'tribes')),
        Step('training', 'Converting the training missions (scripts, maps)...', 30,
             lambda c: c.run_tool('export_tribes_missions', 'tribes')),
        Step('base', 'Reading the bases (turrets, generators, sensors, stations)...', 2, _base_equipment),
        # after the base: the turret guns get their effects too
        Step('weapon_fx', 'Converting weapon effects (explosions, bolts, trails)...', 3,
             lambda c: c.run_tool('fx_tribes')),
        Step('map_icons', 'Converting the command map icons...', 0.5, lambda c: c.run_tool('export_map_icons', 'tribes')),
    ]


_ = os
