"""Earthsiege 2 (1996) -> pack "es2": palettes, weapons, Hercs/Cybrids/bases, cockpits, worlds + heightmap
terrain, missions + campaign (docs/formats/es2.md, docs/formats/cockpit.md section 8)."""
from siege_games import Step

GAME = {
    'game': 'es2', 'pack': 'es2', 'name': 'Earthsiege 2', 'discs': 1,
    'main_exe': {'disc': 'DBSIM.EXE'}, 'version_file': 'VERSION.TXT',   # tools/disc_version.py
    'cd_audio': True,        # DBSIM.EXE plays music through the MCI 'cdaudio' device (track table not decoded)
    'pack_json': {'name': 'Earthsiege 2', 'default_palette': 'WORLD0', 'unit_scale': 1.0,
                  'era': 3, 'year': 2495},
}
# Herc / vehicle shapes whose texture set is known (tools/export_es2.py SHAPE_TEXSET)
SHAPES = ['RAPTOR2']


def identify(disc):
    if disc.exists('ES.EXE') and disc.exists('DBSIM.EXE') and disc.exists('VOL/SIMVOL0.VOL'):
        return 1
    return 0


def _extract(ctx):
    ctx.extract(1, 'VOL', ctx.work_path('es2', 'original', 'VOL'), 'Copying the Earthsiege 2 archives')
    ctx.extract(1, 'DBSIM.EXE', ctx.work_path('es2', 'original', 'DBSIM.EXE'))
    # loose training voices TM<lesson>_<nnnn>.WAV (tools/export_es2_radio.py)
    ctx.extract(1, 'SIMVOICE', ctx.work_path('es2', 'original', 'SIMVOICE'), 'Copying the training voices')
    # cinematics and the shell's clip table (tools/export_movies.py)
    ctx.extract(1, 'AVI', ctx.work_path('es2', 'original', 'AVI'), 'Copying the cinematics')
    ctx.extract(1, 'VSHELL.EXE', ctx.work_path('es2', 'original', 'VSHELL.EXE'))


def cd_audio_uses(ctx, numbers):
    return {n: {'use': 'music'} for n in numbers}


def steps(ctx):
    return [
        Step('extract', 'Copying the disc archives...', 12, _extract),
        Step('archives', 'Unpacking VOL archives...', 8, lambda c: c.run_tool('es2_vol')),
        Step('assets', 'Converting palettes, textures and shapes...', 5, lambda c: c.run_tool('export_es2', *SHAPES)),
        Step('weapons', 'Decoding weapons, their shapes and sounds...', 8, lambda c: c.run_tool('export_es2_weapons')),
        # after the weapons: adds the fx block to gameplay/weapons_engine.json
        Step('weapon_fx', 'Decoding weapon effects and explosions...', 1, lambda c: c.run_tool('fx_es2')),
        # after the weapons: reads gameplay/weapons_engine.json
        Step('units', 'Converting Hercs, Cybrids, bases and formations...', 6, lambda c: c.run_tool('export_es2_units')),
        # after the units: reads gameplay/hercs.json (weapon slot of each hardpoint)
        Step('cockpit', 'Exporting cockpit instruments...', 3, lambda c: c.run_tool('export_es2_cockpit')),
        Step('worlds', 'Converting worlds and heightmap terrain...', 20, lambda c: c.run_tool('export_es2_world')),
        Step('missions', 'Converting missions and the campaign...', 3, lambda c: c.run_tool('mission_es2', 'export')),
        Step('arenas', 'Laying out deathmatch spawn areas on the battlefields...', 2, lambda c: c.run_tool('export_es_arenas', 'es2')),
        Step('radio', 'Reading wingman and training radio lines and voices...', 1,
             lambda c: c.run_tool('export_es2_radio')),
        Step('movies', 'Converting the cinematics...', 6, lambda c: c.run_tool('export_movies', 'es2')),
        Step('economy', 'Reading salvage prices and the pilot roster...', 0.2, lambda c: c.run_tool('export_economy', 'es2')),
        Step('music', 'Reading which music plays where...', 0.5, lambda c: c.run_tool('music_situations', 'es2')),
    ]
