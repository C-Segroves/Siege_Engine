"""Starsiege (1999, 2 CDs) -> pack "starsiege" (proof-of-life: Herc shapes + skins, script catalogue).

Disc 1 holds the InstallShield cabinet with every game file (setup/data1.cab); disc 2 is not needed for the
content converted so far. Uses tools/installshield_cab.py, tools/darkstar_lzh.py, tools/export_starsiege.py and
tools/catalog_starsiege.py (paths redirected with siege_games.relocate).
"""
import os

from siege_games import Step, relocate, call_main

GAME = {
    'game': 'starsiege', 'pack': 'starsiege', 'name': 'Starsiege', 'discs': 2, 'required_discs': [1],
    'main_exe': {'work': 'starsiege/original/installed/Starsiege.exe'},   # from the cabinet (tools/disc_version.py)
    'needs': {2: [1]}, 'cd_audio': True,          # the soundtrack is Red Book audio (tracks 2-17)
    'pack_json': {'name': 'Starsiege', 'default_palette': 'Mars_d_1', 'engine': 'darkstar', 'unit_scale': 256.0,
                  'weapon_families': ['herc'],
                  'era': 4, 'year': 2829},
}
SHAPES = ['tr_apoc', 'tr_talon']
VOLS = ['gameObjects.vol', 'Mars.Sim.vol', 'scripts.vol']
VOLS += [p + '.Sim.vol' for p in ('Desert', 'Europa', 'Ice', 'Mercury', 'Moon', 'Pluto', 'Temperate', 'Titan',
                                 'Venus')] + ['sound.vol', 'shell.vol']   # gameplay export: planet sets + weapon sounds
VOLS += ['generic.vol', 'taunts.vol']   # mission radio voices (tools/export_starsiege_voice.py)


def identify(disc):
    if not disc.exists('starsiege.url') and not disc.label.upper().startswith('STARSIEGE'):
        return 0
    if disc.exists('setup/data1.hdr') and disc.exists('setup/data1.cab'):
        return 1
    if disc.label.upper().startswith('STARSIEGE'):
        return 2
    return 0


def _extract(ctx):
    for f in ('data1.hdr', 'data1.cab'):
        ctx.extract(1, 'setup/' + f, ctx.work_path('starsiege', 'original', 'disc1', 'setup', f), 'Copying the game cabinet')
    # Smacker cinematics (tools/export_movies.py)
    ctx.extract(1, 'data/movies', ctx.work_path('starsiege', 'original', 'disc1', 'data', 'movies'), 'Copying the cinematics')


def _cab(ctx):
    import installshield_cab
    installshield_cab.extract(ctx.work_path('starsiege', 'original', 'disc1', 'setup', 'data1.hdr'),
                              ctx.work_path('starsiege', 'original', 'installed'))
    os.remove(ctx.work_path('starsiege', 'original', 'disc1', 'setup', 'data1.cab'))   # free 200 MB early


def _vols(ctx):
    import darkstar_lzh
    inst = ctx.work_path('starsiege', 'original', 'installed')
    names = {f.lower(): f for f in os.listdir(inst)}
    for i, v in enumerate(VOLS):
        ctx.message('Unpacking %s' % v, i / len(VOLS))
        darkstar_lzh.extract(os.path.join(inst, names.get(v.lower(), v)), ctx.work_path('starsiege', 'extracted'))


def _shapes(ctx):
    import export_starsiege as ES
    root = ES.ROOT                    # (relocate rewrites ES.ROOT itself)
    relocate(ES.ET, root)             # export_starsiege points export_tribes at the repository tree
    relocate(ES, root)
    call_main(ES, *SHAPES)


def _catalog(ctx):
    try:
        import catalog_starsiege as C
        relocate(C)
        call_main(C)
    except Exception as e:  # noqa: BLE001 - the catalogue is informational
        ctx.note('Starsiege catalogue skipped (%s: %s)' % (type(e).__name__, e))


def _gameplay(ctx):
    """tools/export_starsiege_gameplay.py: weapons_engine.json, hercs.json (engine_schema), ids.json, sounds, all DTS."""
    import export_starsiege_gameplay as GP
    relocate(GP)
    call_main(GP)


def _ted(ctx):
    """Mission terrain volumes (campaign/*/<M>.ted.vol, training, multiplayer) -> extracted/ted/<M>.ted/."""
    import darkstar_lzh
    inst = ctx.work_path('starsiege', 'original', 'installed')
    out = ctx.work_path('starsiege', 'extracted', 'ted')
    vols = []
    for d, _dirs, files in os.walk(inst):
        vols += [os.path.join(d, f) for f in files if f.lower().endswith('.ted.vol')]
    for i, v in enumerate(sorted(vols)):
        ctx.message('Unpacking terrain %s' % os.path.basename(v), i / max(1, len(vols)))
        darkstar_lzh.extract(v, out)


def _missions(ctx):
    """Human + Cybrid campaigns: decoded .mis object trees, scripts, briefings, terrain maps
    (tools/export_starsiege_missions.py, tools/starsiege_terrain.py)."""
    import starsiege_terrain as T
    import export_starsiege_missions as M
    relocate(T)
    relocate(M)
    call_main(M)


def _maps(ctx):
    """Multiplayer maps (multiplayer/*.mis + .ted.vol) -> maps/<id>/ in the engine map schema, interiors and props
    -> shapes/ (tools/export_darkstar_maps.py; adds Tribes inventory/ammo stations + infantry spawns per team)."""
    ctx.run_tool('export_darkstar_maps', 'starsiege')


def cd_audio_uses(ctx, numbers):
    """Track descriptions from the game's own scripts: scripts/cdAudioTracks.cs registers names for the Red Book
    tracks (registerCdAudioTrack(n, "Name")), and missions/cut-scenes pick music with cdAudioCycle(Name, ...)."""
    import re
    reg = {}
    p = ctx.work_path('starsiege', 'extracted', 'scripts', 'cdAudioTracks.cs')
    if os.path.exists(p):
        for line in open(p, encoding='latin-1'):
            m = re.match(r'\s*registerCdAudioTrack\s*\(\s*(\d+)\s*,\s*"([^"]+)"', line)
            if m:
                reg[int(m.group(1))] = m.group(2)
    by_name = {v.lower(): k for k, v in reg.items()}
    used = {}
    inst = ctx.work_path('starsiege', 'original', 'installed')
    for d, _dirs, files in os.walk(inst):
        for f in files:
            if not f.lower().endswith('.cs'):
                continue
            rel = os.path.relpath(os.path.join(d, f), inst).replace(os.sep, '/')[:-3]
            for line in open(os.path.join(d, f), encoding='latin-1'):
                code = line.split('//')[0]
                for m in re.finditer(r'cdAudioCycle\s*\(([^)]*)\)', code, re.I):
                    for a in m.group(1).split(','):
                        n = by_name.get(a.strip().strip('"').lower())
                        if n:
                            used.setdefault(n, set()).add(rel)
    out = {}
    for n in numbers:
        if n in reg:
            out[n] = {'use': 'music', 'name': reg[n], 'played_by': sorted(used.get(n, ()))}
        else:
            out[n] = {'use': 'music (not registered in cdAudioTracks.cs)'}
    return out


def steps(ctx):
    return [
        Step('extract', 'Copying the install cabinet from disc 1...', 15, _extract),
        Step('archives', 'Unpacking the InstallShield cabinet...', 25, _cab),
        Step('volumes', 'Unpacking Darkstar volumes...', 15, _vols),
        Step('assets', 'Converting Herc shapes and skins...', 10, _shapes),
        Step('gameplay', 'Converting vehicles, weapons and all shapes...', 240, _gameplay),
        Step('weapon_fx', 'Converting weapon effects (explosions, muzzle flashes, beams)...', 5,
             lambda c: c.run_tool('fx_starsiege')),
        Step('catalog', 'Cataloguing vehicles and weapons...', 5, _catalog),
        Step('terrain', 'Unpacking mission terrain...', 20, _ted),
        Step('missions', 'Converting the Human and Cybrid campaigns...', 120, _missions),
        # after the missions: reads the exported mission scripts for the clips they name
        Step('voice', 'Copying the mission radio voices...', 2, lambda c: c.run_tool('export_starsiege_voice')),
        Step('squad', "Reading the squad orders and the squadmates' replies...", 1,
             lambda c: c.run_tool('export_starsiege_squad')),
        Step('map_icons', 'Converting the map screen icons...', 0.5, lambda c: c.run_tool('export_map_icons', 'starsiege')),
        Step('maps', 'Converting the multiplayer maps...', 130, _maps),
        Step('modes', 'Reading the multiplayer game modes of every map...', 3, lambda c: c.run_tool('export_game_modes', 'starsiege')),
        Step('cockpit', 'Exporting the HUD / cockpit instruments...', 2,
             lambda c: (c.run_tool('export_starsiege_cockpit'), c.run_tool('cockpit_hud_layouts', 'starsiege'))),
        Step('music', 'Reading which music plays where...', 0.5, lambda c: c.run_tool('music_situations', 'starsiege')),
        Step('movies', 'Converting the cinematics...', 4, lambda c: c.run_tool('export_movies', 'starsiege')),
    ]
