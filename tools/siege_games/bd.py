"""Metaltech: Battledrome (1995) -> pack "bd".

The disc's installer unpacks INSTALL/ENGLISH/RESOURCE.000 with UNCHUNK.EXE; tools/bd_unchunk.py does the same,
then export_bd / export_bd_weapons / export_looks / units_calib convert the installed tree.
"""
from siege_games import Step
from siege_games.es1 import render_fm_music

GAME = {
    'game': 'bd', 'pack': 'bd', 'name': 'Metaltech: Battledrome', 'discs': 1,
    'main_exe': {'work': 'bd/installed/SIM.EXE'},   # unpacked from RESOURCE.000 (tools/disc_version.py)
    'pack_json': {'name': 'Metaltech: Battledrome', 'default_palette': 'NRMPAL', 'unit_scale': 0.5,
                  'weapon_pack': 'es1',
                  'era': 2, 'year': 2480},
}
RESOURCE = 'INSTALL/ENGLISH/RESOURCE.000'


def identify(disc):
    if disc.exists(RESOURCE) and disc.exists('INSTALL/ENGLISH/UNCHUNK.EXE') and not disc.exists('DBSIM.EXE'):
        return 1
    return 0


def _extract(ctx):
    ctx.extract(1, RESOURCE, ctx.work_path('bd', 'original', *RESOURCE.split('/')), 'Copying the Battledrome archive')


def _unchunk(ctx):
    import bd_unchunk
    bd_unchunk.unchunk(ctx.work_path('bd', 'original', *RESOURCE.split('/')), ctx.work_path('bd', 'installed'))


def _looks(ctx):
    dts = ctx.work_path('bd', 'installed', 'DTS')
    import os
    ctx.run_tool('export_looks', 'bd', os.path.join(dts, 'NRMPAL.DPL'), os.path.join(dts, 'TEXTURES.DPL'))


def steps(ctx):
    return [
        Step('extract', 'Copying the install archive from the disc...', 1, _extract),
        Step('archives', 'Unpacking the Battledrome install archive...', 8, _unchunk),
        Step('assets', 'Converting shapes, textures, arenas and unit tables...', 10, lambda c: c.run_tool('export_bd')),
        Step('weapons', 'Decoding weapons, loadouts and sounds...', 6, lambda c: c.run_tool('export_bd_weapons')),
        Step('weapon_fx', 'Decoding weapon effects (explosions, beams, shield hits)...', 2,
             lambda c: c.run_tool('fx_bd')),
        Step('looks', 'Building palette lighting tables...', 1, _looks),
        Step('units', 'Calibrating real-world units...', 2, lambda c: c.run_tool('units_calib', 'bd')),
        Step('music', 'Rendering the FM music (Sound Blaster and AdLib)...', 50,
             lambda c: render_fm_music(c, 'bd')),
        Step('cockpit', 'Exporting the HUD / cockpit instruments...', 2,
             lambda c: (c.run_tool('export_bd_cockpit'), c.run_tool('cockpit_hud_layouts', 'bd'))),
    ]
