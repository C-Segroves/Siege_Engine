"""Which HMP songs Earthsiege and Battledrome have, where their SOS driver files are, and when each song plays.

Situations were decoded from the executables (Earthsiege VA = file offset - 0x48fd; Battledrome - 0x69cd):
Earthsiege GO.EXE (shell)
  * Sound table 0x828c0 (ids): 1/2 menu, 3 shella, 4 shellb, 5 shellc, 6 shella, 7 death, 8 win2, 12 intro1,
    13 intro2, 15 rubble, 16 ice, 17 desert, 18 volcano, 19 losing (9-11, 14 are sound effects).
  * 0x395a0 region change: table 0x817d0[region/1000 - 1] = 1,1,3,4,3,3,1 -> a new id only restarts the music
    when it differs from the previous region's.  Played by the main loop (0x129c7 -> 0x20a70, loops forever).
  * 0x37f1e general (G0) transmission: id 15 + table 0x814d8[campaign] (0,1,1,2,2,3,3,3).
  * 0x3bdef start-up: intro1 under DYNAMIX/LEAD_IN.TTM, intro2 under IINTRO/EARTH_W.TTM (also 0x3c98d).
  * 0x3bc94 career ended by the pilot's death: death (ENDFA.TTM); 0x3bce6 campaign won: intro2 (END_WIN1-3,
    EARTH.TTM); 0x3bd30 campaign lost: losing (FAILED.TTM).  No code path plays win2 or shellc.
Earthsiege DBSIM.EXE (sim): SOUNDS.STR ids 0-5 = battle1a..3b (volume 100, loop 255); 0x585dc picks theme
  rand(3) "A" at mission start and switches id +-3 (A<->B): to B when an enemy is targeted / visible or within
  25000 units, back to A once no enemy is engaged and every live Herc is within 18928 units; no scan for 300 clock
  units (5 s, clock 0x981c4 = 60 Hz) after the start and each switch (fade -15 volume per frame, the new song
  starts at full volume from its beginning).
Battledrome SIM.EXE: sound table 0x78998 ids 15-23 = rock1-3, techno1-3, sndtrak1-3; Preferences "MUSIC TYPE"
  selects (first id, count) from 0x78af4: rock (15,3), techno (18,3), soundtrack (21,3), variety (15,9) (default),
  none (4: no music, 0x5e5); 0x28486
  plays a random track of the set, never the one just played, once (no loop count).
Battledrome SHELL.EXE: sound table 0x7ccb0: 0 title, 1-3 s1/s2/s3 (identical files); the shell restarts its
  track whenever neither it nor the title is playing (0x2fc2, 0x5e05), i.e. loops it by restarting.
  battle, footfall, shell2 and techno4 are not referenced by any of the three executables.
"""
import os

LOOP = 'loop'           # HMI loop controllers (cc110/cc111): file = first pass + one loop pass
RESTART = 'restart'     # no loop controllers; the game restarts the song when it ends
ONCE = 'once'           # played to the end once

ES1_TRACKS = {
    'battle1a': ('sim', 'battle theme 1, calm "A" variant (SOUNDS.STR id 0, ids 6-9 alias it); picked at random at mission start'),
    'battle2a': ('sim', 'battle theme 2, calm "A" variant (SOUNDS.STR id 1)'),
    'battle3a': ('sim', 'battle theme 3, calm "A" variant (SOUNDS.STR id 2)'),
    'battle1b': ('sim', 'battle theme 1, combat "B" variant (SOUNDS.STR id 3); replaces 1a while enemies are engaged'),
    'battle2b': ('sim', 'battle theme 2, combat "B" variant (SOUNDS.STR id 4)'),
    'battle3b': ('sim', 'battle theme 3, combat "B" variant (SOUNDS.STR id 5)'),
    'menu': ('shell', 'main menu, single mission, career, preferences (regions 1000/2000) and the video monitor (7000)'),
    'shella': ('shell', 'war room (3000), debriefing (5000) and mission briefing map (6000)'),
    'shellb': ('shell', 'herc hangar (4000): hub, arming, repair, build, crew'),
    'shellc': ('shell', 'in the sound table but never played by GO.EXE'),
    'death': ('shell', 'career over: pilot killed (ENDFA.TTM)'),
    'win2': ('shell', 'in the sound table but never played by GO.EXE'),
    'losing': ('shell', 'campaign lost (FAILED.TTM)'),
    'intro1': ('shell', 'start-up: Dynamix logo and lead-in (DYNAMIX/LEAD_IN.TTM)'),
    'intro2': ('shell', 'start-up intro (IINTRO/EARTH_W.TTM); also the campaign-won ending (END_WIN1-3.TTM)'),
    'rubble': ('shell', "general's transmission, campaign 0 (city ruins)"),
    'ice': ('shell', "general's transmission, campaigns 1-2 (ice)"),
    'desert': ('shell', "general's transmission, campaigns 3-4 (desert)"),
    'volcano': ('shell', "general's transmission, campaigns 5-7 (volcanic)"),
    'soundset': ('soundset', 'SOUNDSET.EXE sound-card test song (same tune as Battledrome ROCK1), not used by the game'),
}

ES1_SITUATIONS = {
    'region_music': {'1000': 'menu', '2000': 'menu', '3000': 'shella', '4000': 'shellb', '5000': 'shella',
                     '6000': 'shella', '7000': 'menu'},
    'general_transmission_by_campaign': ['rubble', 'ice', 'ice', 'desert', 'desert', 'volcano', 'volcano', 'volcano'],
    'intro_logo': 'intro1', 'intro': 'intro2', 'campaign_won': 'intro2', 'campaign_lost': 'losing',
    'pilot_killed': 'death',
    'battle_themes': [['battle1a', 'battle1b'], ['battle2a', 'battle2b'], ['battle3a', 'battle3b']],
    'battle_switch': {'hold_after_switch_clock': 300, 'clock_hz': 60, 'fade_volume_per_frame': 15,
                      'engage_units': 25000, 'calm_units': 18928, 'new_track_starts_at_full_volume': True},
}

BD_TRACKS = {
    'title': ('shell', 'title screen; when it ends the shell track takes over'),
    's1': ('shell', 'shell screens (S1 = S2 = S3), restarted whenever it ends'),
    's2': ('shell', 'identical to s1'),
    's3': ('shell', 'identical to s1'),
    'rock1': ('sim', "arena music, ROCK 'N ROLL set"), 'rock2': ('sim', "arena music, ROCK 'N ROLL set"),
    'rock3': ('sim', "arena music, ROCK 'N ROLL set"),
    'techno1': ('sim', 'arena music, TECHNO set'), 'techno2': ('sim', 'arena music, TECHNO set'),
    'techno3': ('sim', 'arena music, TECHNO set'),
    'sndtrak1': ('sim', 'arena music, SOUNDTRACK set'), 'sndtrak2': ('sim', 'arena music, SOUNDTRACK set'),
    'sndtrak3': ('sim', 'arena music, SOUNDTRACK set'),
    'techno4': ('unused', 'not referenced by SIM/SHELL/BD.EXE'),
    'battle': ('unused', 'not referenced by SIM/SHELL/BD.EXE'),
    'shell2': ('unused', 'not referenced by SIM/SHELL/BD.EXE'),
    'footfall': ('unused', 'not referenced by SIM/SHELL/BD.EXE (a single note)'),
}

BD_SITUATIONS = {
    'title': 'title', 'shell': 's1',
    'arena_sets': {'rock': ['rock1', 'rock2', 'rock3'], 'techno': ['techno1', 'techno2', 'techno3'],
                   'soundtrack': ['sndtrak1', 'sndtrak2', 'sndtrak3'],
                   'variety': ['rock1', 'rock2', 'rock3', 'techno1', 'techno2', 'techno3',
                               'sndtrak1', 'sndtrak2', 'sndtrak3']},
    'arena_default_set': 'variety',   # SoundManager ctor 0x27deb sets 3; shipped STORAGE.DAT music type 3
    'arena_pick': 'random from the set, never the track just played; next pick when the track ends',
}


class MusicGame:
    """A game's music sources: SOS driver directory, HMP globs, track notes, playback policy per track."""

    def __init__(self, pack, sos_dir, sources, tracks, situations, restart_tracks=()):
        self.pack, self.sos_dir, self.sources = pack, sos_dir, sources
        self.tracks, self.situations = tracks, situations
        self.restart_tracks = restart_tracks

    def driver_file(self, root, name):
        return os.path.join(root, self.sos_dir, name)

    def policy(self, name, has_loop):
        if has_loop:
            return LOOP
        return RESTART if name in self.restart_tracks else ONCE


GAMES = {
    'es1': MusicGame('es1', os.path.join('original', 'SOS'),
                     [('sim', os.path.join('extracted', 'SIMSOUND', '**', '*.HMP')),
                      ('shell', os.path.join('extracted', 'SHELL0', 'RES32', '*.HMP')),
                      ('soundset', os.path.join('original', 'SSET', 'SOUNDSET.HMP'))],
                     ES1_TRACKS, ES1_SITUATIONS),
    'bd': MusicGame('bd', os.path.join('bd', 'installed', 'SOUND'),
                    [('bd', os.path.join('bd', 'installed', 'SOUND', '*.HMP'))],
                    BD_TRACKS, BD_SITUATIONS, restart_tracks=('s1', 's2', 's3')),
}
