"""Which music the CD-audio / streamed-music games play in each situation, read from the user's own disc data.

    python tools/music_situations.py <starsiege|tribes|tribes2|es2>

Writes <pack>/audio/music_situations.json (and copies the games' own streamed music files into
<pack>/audio/music/).  CD tracks are disc numbers (track 1 = data); the files come from the user's rips
(Soundtracks.cd_track_file).  Evidence (exe addresses: image base 0x400000):
  starsiege  Missions call cdAudioCycle(names|numbers) (campaign onMissionStart, multiplayer onMissionLoad,
             training_fns.cs): each track plays once to its end, then the next, the list repeats forever
             (CDAudio::cycle 0x55a69c, next 0x55a8f8, MCI notify 0x55a79c).  Tracks outside 2..13 are dropped
             (0x55a6f8) -- the script's SS1 = 14 is never heard.  A change fades the CD out (+0.05 attenuation
             every 0.1 s, 0x55a930) before the new list starts.  Shell: SHELL1.WAV looped (sound.cs:33/104);
             returning to the shell fades the CD out (0x419e3a).
  tribes     Main menu: CD track 2 looped (GUI.CS:179); a mission sets $cdTrack / $cdPlayMode (1 = loop,
             other values = play once) and the client switches with a hard cut (client.cs:473-497).
  tribes2    base/music/<musicTrack>.mp3 from the mission (server.cs:724, client.cs:1641), looped
             (clientAudio.cs:144), hard cuts; the shell is silent.
  es2        Shell: HMI\\SHELL2.WAV while prefs byte 5 (0x4824bd) is 0, the default, else SHELL1.WAV, looped
             by VSHELL (0x42ec7c / 0x42ed97).  Each shell start then toggles that byte and saves the prefs
             (0x42ee1b: 0x40d87d(5), 0x40d752), so the two alternate per shell start (VSHELL runs again
             after every sim); the menus never set it.  Fades out when the sim starts.  Sim: CD track (launch counter mod 5) + 2 looped,
             i.e. 2, 3, 4, 5, 6, 2, ... per sim launch in a session (DBSIM 0x461c86, ES.EXE -R<n> 0x4012e3);
             training missions are silent.
"""
import glob, json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402

STARSIEGE_LAST_TRACK = 13
STARSIEGE_FADE_SECONDS = 2.0        # 20 steps of 0.05 attenuation every 0.1 s
TRIBES_MENU_TRACK = 2
TRIBES_LOOP_MODE = 1
ES2_SIM_TRACKS = [2, 3, 4, 5, 6]
ES2_SHELL_ALTERNATES = ['shell2', 'shell1']   # prefs byte 5 = 0 (default), 1
CYCLE_CALL = re.compile(r'^\s*(?:schedule\s*\(\s*")?cdAudioCycle\s*\(([^)]*)\)', re.I | re.M)   # CC1 schedules it
TRACK_NAME = re.compile(r'^\s*registerCdAudioTrack\s*\(\s*(\d+)\s*,\s*"(\w+)"\s*\)', re.I | re.M)


def starsiege():
    names = {}
    for f in glob.glob(P.work('starsiege', 'extracted', 'scripts', '*.cs')):
        for track, name in TRACK_NAME.findall(read(f)):
            names[name.lower()] = int(track)
    installed = P.work('starsiege', 'original', 'installed')
    missions = {}
    for f in glob.glob(os.path.join(installed, '**', '*.cs'), recursive=True):
        tracks = first_cycle(read(f), names)
        if tracks is not None:
            missions[os.path.splitext(os.path.basename(f))[0].upper()] = tracks
    training = missions.pop('TRAINING_FNS', None)
    copy_music('starsiege', P.work('starsiege', 'extracted', 'sound', 'SHELL1.WAV'), 'shell1')
    return dict(kind='cd_cycle', shell={'file': 'shell1', 'loop': True}, missions=missions,
                training=training, valid_tracks=[2, STARSIEGE_LAST_TRACK], fade_out_seconds=STARSIEGE_FADE_SECONDS,
                track_names=names, change='fade out, then the new list (no cross-fade)')


def first_cycle(text, names):
    """The first cdAudioCycle(...) call that is not commented out -> [track numbers] (unknown names skipped)."""
    for args in CYCLE_CALL.findall(strip_comments(text)):
        out = []
        for a in (x.strip().strip('"').lower() for x in args.split(',')):
            if a.isdigit():
                out.append(int(a))
            elif a in names:
                out.append(names[a])
        return out
    return None


def strip_comments(text):
    return re.sub(r'//[^\n]*', '', text)


def tribes():
    missions = {}
    for f in glob.glob(P.work('tribes', 'original', 'Tribes', 'base', 'missions', '*.MIS')) + \
            glob.glob(P.work('tribes', 'original', 'Tribes', 'base', 'missions', '*.mis')):
        text = read(f)
        track = re.search(r'\$cdTrack\s*=\s*(\d+)', text)
        mode = re.search(r'\$cdPlayMode\s*=\s*(\d+)', text)
        if track:
            missions[os.path.splitext(os.path.basename(f))[0]] = {
                'track': int(track.group(1)), 'loop': int(mode.group(1)) == TRIBES_LOOP_MODE if mode else True}
    return dict(kind='cd_track', menu={'track': TRIBES_MENU_TRACK, 'loop': True}, missions=missions,
                change='hard cut')


def tribes2():
    music = glob.glob(P.work('tribes2', 'original', 'Tribes2', 'GameData', 'base', 'music', '*.mp3'))
    for f in music:
        copy_music('tribes2', f, os.path.splitext(os.path.basename(f))[0].lower())
    missions = {}
    for f in glob.glob(P.work('tribes2', 'extracted', 'missions', 'missions', '*.mis')):
        m = re.search(r'musicTrack\s*=\s*"(\w+)"', read(f))
        if m:
            missions[os.path.splitext(os.path.basename(f))[0]] = m.group(1).lower()
    return dict(kind='file', menu=None, missions=missions, loop=True, change='hard cut',
                credits='random of badlands, desert, ice, lush, volcanic')


def es2():
    for name in ('SHELL1', 'SHELL2'):
        copy_music('es2', P.work('es2', 'extracted', 'SHLSOUND', 'HMI', name + '.WAV'), name.lower())
    return dict(kind='cd_rotation', shell={'file': 'shell2', 'loop': True}, shell_alternates=ES2_SHELL_ALTERNATES,
                sim_tracks=ES2_SIM_TRACKS,
                sim_loop=True, training_silent=True,
                change='shell music fades out at sim start; CD track starts with a hard cut')


def copy_music(pack, src, stem):
    """Converts a game's own music file to <pack>/audio/music/<stem>.ogg (WAV) or copies it (MP3)."""
    if not os.path.exists(src):
        return
    out = P.pack(pack, 'audio', 'music')
    os.makedirs(out, exist_ok=True)
    if src.lower().endswith('.mp3'):
        shutil.copyfile(src, os.path.join(out, stem + '.mp3'))
        return
    from video import ffmpeg_exe
    subprocess.check_call([ffmpeg_exe(), '-y', '-loglevel', 'error', '-i', src, '-c:a', 'libvorbis', '-q:a', '5',
                           os.path.join(out, stem + '.ogg')])


def read(path):
    return open(path, 'rb').read().decode('latin-1')


BUILDERS = {'starsiege': starsiege, 'tribes': tribes, 'tribes2': tribes2, 'es2': es2}


def main(argv):
    if len(argv) < 2 or argv[1] not in BUILDERS:
        print(__doc__)
        return 1
    pack = argv[1]
    doc = BUILDERS[pack]()
    doc['pack'] = pack
    dst = P.pack(pack, 'audio', 'music_situations.json')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
    print('%s: %d missions -> %s' % (pack, len(doc.get('missions', {})), dst))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
