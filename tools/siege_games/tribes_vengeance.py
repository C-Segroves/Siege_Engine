"""Tribes: Vengeance (2004, PC, Unreal Engine 2.5) -> pack "tribes_v": the campaign (33 maps, 16 chapters) with objective
text, player and NPC spawns, terrain and meshes, sounds and speech, skeletal bodies, vehicle shapes and the mission
scripts (docs/formats/tribes_vengeance.md).

The user's copy is a zip holding an Inno Setup installer: setup.exe + setup-1.bin + setup-2.bin (disk slices,
magic "idska32"). identify_zip() in siege_import.py asks this module about the zip's member names.
siege_import.py opens a zip as siege_iso.ZipSource; the single step unpacks it (tools/tv_unpack.py, about 14 GB of
scratch space at its peak) into a short temp folder, converts (tools/tv_import.py) and deletes the scratch. The same
converter runs standalone: python tools/tv_import.py <TribesVengeance.zip> <pack folder>.
"""
from siege_games import Step

GAME = {
    'game': 'tribes_vengeance', 'pack': 'tribes_v', 'name': 'Tribes: Vengeance', 'discs': 1, 'supported': True,
    'pack_json': {'name': 'Tribes: Vengeance', 'engine': 'unreal_2_5', 'unit_scale': 1.0, 'world_metres_per_unit': 1.0,
                  'placeholder_shapes': True, 'era': 5},
}
ZIP_MEMBERS = ('setup.exe', 'setup-1.bin')


def identify(_disc):
    return 0     # no disc form is known; the zip is recognised by identify_zip()


def identify_zip(names):
    lower = {n.lower() for n in names}
    return 1 if all(m in lower for m in ZIP_MEMBERS) else 0


def _import(ctx):
    import shutil
    import tempfile
    import tv_import
    import tv_unpack
    scratch = tempfile.mkdtemp(prefix='tv')          # short path: the game's file names break Windows MAX_PATH deeper down
    try:
        ctx.message('Unpacking the installer (a few minutes)...', 0.0)
        root = tv_import.find_game_root(tv_unpack.unpack(ctx.disc(1).path, scratch))
        ctx.message('Converting the campaign maps...', 0.4)
        res = tv_import.import_campaign(root, ctx.pack_path(), log=lambda line: ctx.message(line.strip(), 0.7))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    ctx.note('Tribes: Vengeance: %(missions)d maps in %(chapters)d chapters imported (terrain, static meshes and brushes; '
             'no skeletal models or audio yet).' % res)


def steps(_ctx):
    return [Step('campaign', 'Unpacking and converting Tribes: Vengeance...', 1500, _import)]
