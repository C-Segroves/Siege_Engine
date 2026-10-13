"""Metaltech: Earthsiege (1994) -> pack "es1" (the steps of tools/import_disc.py)."""
import glob
import os
import shutil

from siege_games import Step

GAME = {
    'game': 'es1', 'pack': 'es1', 'name': 'Metaltech: Earthsiege', 'discs': 1,
    'main_exe': {'disc': 'DBSIM.EXE'},          # release identification (tools/disc_version.py)
    'pack_json': {'name': 'Metaltech: Earthsiege', 'default_palette': 'WORLD0', 'unit_scale': 1.0,
                  'era': 1, 'year': 2471},
}


def identify(disc):
    if disc.exists('GO.EXE') and disc.exists('DBSIM.EXE') and disc.exists('VOL/SIMVOL0.VOL'):
        return 1
    return 0


def _extract(ctx):
    ctx.extract(1, '', ctx.work_path('original'), 'Copying the Earthsiege disc')


def _vols(ctx):
    import vol
    vols = sorted(glob.glob(ctx.work_path('original', 'VOL', '*.VOL')))
    for i, p in enumerate(vols):
        ctx.message('Unpacking %s' % os.path.basename(p), i / max(1, len(vols)))
        vol.extract(p, ctx.work_path('extracted'))


def _assets(ctx):
    ctx.run_tool('export_es1')


def _gameplay(ctx):
    ctx.run_tool('units')                               # -> <work>/extracted/gameplay
    gp = ctx.pack_path('gameplay')
    os.makedirs(gp, exist_ok=True)
    for f in glob.glob(ctx.work_path('extracted', 'gameplay', '*.json')):
        shutil.copy(f, gp)


def _music(ctx):
    render_fm_music(ctx, 'es1')


def render_fm_music(ctx, pack):
    """tools/render_music.py for a pack (needs pyopl + ffmpeg in the importer build)."""
    try:
        import pyopl  # noqa: F401
        import video
        if not video.ffmpeg_exe():
            raise ImportError('ffmpeg')
    except ImportError as e:
        ctx.note('Music skipped: the FM synthesiser (%s) is not available in this importer build.' % e)
        return
    ctx.run_tool('render_music', 'all', pack, ctx.pack_path('audio', 'music'))


def steps(ctx):
    out = ctx.pack_path
    return [
        Step('extract', 'Copying the disc...', 3, _extract),
        Step('archives', 'Unpacking VOL archives...', 1.5, _vols),
        Step('assets', 'Converting shapes, textures, worlds and terrain...', 11, _assets),
        Step('gameplay', 'Reading unit and weapon tables...', 1, _gameplay),
        Step('weapon_fx', 'Exporting weapon effects...', 0.5, lambda c: c.run_tool('fx_es1')),
        Step('missions', 'Exporting missions and campaign...', 2.5, lambda c: c.run_tool('export_missions', out('missions'))),
        Step('arenas', 'Laying out deathmatch spawn areas on the battlefields...', 2, lambda c: c.run_tool('export_es_arenas', 'es1')),
        Step('audio', 'Converting sound effects and voices...', 5, lambda c: c.run_tool('audio', 'all', out('audio'))),
        Step('music', 'Rendering the FM music (Sound Blaster and AdLib)...', 70, _music),
        Step('video', 'Converting cinematics...', 35, lambda c: c.run_tool('video', 'all', out('video'))),
        Step('shell', 'Exporting the front-end menus...', 8, lambda c: c.run_tool('export_shell', out('shell'))),
        Step('cockpit', 'Exporting cockpit instruments...', 3, lambda c: c.run_tool('export_cockpit', out('cockpit'))),
        Step('units', 'Calibrating real-world units...', 0.5, lambda c: c.run_tool('units_calib', 'es1')),
        Step('economy', 'Reading salvage prices and the pilot roster...', 0.2, lambda c: c.run_tool('export_economy', 'es1')),
    ]
