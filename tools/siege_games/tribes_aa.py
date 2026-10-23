"""Tribes: Aerial Assault (2002, PS2) -> pack "tribes_aa": the campaign structure (mission order, names, objectives,
communique text) and every mission as an engine map (spawns, buildings, scenery, stations, flags, switches, sun, fog).

Not converted yet: animated/skinned shapes (soldiers, vehicles). The scripted mission logic is in
the ELF and is not read. The disc holds the executable SLUS_201.49 and one archive, TRIBES/FILES.DAT (magic "SFDC"),
read in place by tools/aa_files.py (docs/formats/aerial_assault.md). Not a Torque game: nothing of Tribes 2 is reusable
except as a look-alike stand-in.
"""
from siege_games import Step

GAME = {
    'game': 'tribes_aa', 'pack': 'tribes_aa', 'name': 'Tribes: Aerial Assault (PS2)', 'discs': 1, 'supported': True,
    'main_exe': {'disc': 'SLUS_201.49'},   # the PS2 ELF at the ISO root (tools/disc_version.py)
    'pack_json': {'name': 'Tribes: Aerial Assault', 'engine': 'inevitable_ps2', 'unit_scale': 1.0, 'world_metres_per_unit': 1.0, 'placeholder_shapes': True, 'era': 5, 'year': 3945},
}


def identify(disc):
    if disc.exists('TRIBES/FILES.DAT') and disc.exists('TRIBES/DATA/AUDIO/VOICE.PKG'):
        return 1
    return 0


def _import(ctx):
    import aa_files
    import aa_import
    files = aa_files.IsoFilesDat(ctx.disc(1).path)
    try:
        res = aa_import.import_all(files, ctx.pack_path(),
                                   lambda name, f: ctx.message('Converting mission %s' % name, f))
    finally:
        files.close()
    ctx.note('Aerial Assault: %(maps)d missions (%(arena_maps)d arena maps, %(campaign_missions)d campaign) imported '
             'without terrain or models yet.' % res)


def _audio(ctx):
    import aa_audio
    out = ctx.pack_path('audio')
    n = aa_audio.export_bank(ctx.disc(1).path, 'EFFECTS', out)
    voice = sum(aa_audio.export_bank(ctx.disc(1).path, b, out, ogg=True, by_records=True) for b in ('VOICE', 'TRAINING'))
    music = aa_audio.export_bank(ctx.disc(1).path, 'MUSIC', out, ogg=True, by_records=True)
    ctx.note('Aerial Assault: %d sound effects, %d voice/training lines and %d music tracks converted (numbered; the '
             'names live in the executable).' % (n, voice, music))


def _weapons(ctx):
    import aa_weapons
    n = aa_weapons.export(ctx.disc(1).path, ctx.pack_path())
    ctx.note('Aerial Assault: %d hand weapons (damage, rate, ammo, speed, energy from the executable) with their rules per armour size.' % n)


def steps(_ctx):
    return [Step('missions', 'Reading the campaign and converting the missions...', 120, _import),
            Step('audio', 'Converting the sounds and music...', 90, _audio),
            Step('weapons', 'Reading the hand weapons...', 20, _weapons)]
