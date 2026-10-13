"""Import user-ripped soundtracks (MP3/FLAC/WAV/OGG folders) into the app's soundtrack store.

    python tools/siege_soundtrack.py --out <packs_dir> <folder> [<folder> ...]

A folder may hold one game's tracks or one sub-folder per game (e.g. <iso dir>\\soundtracks).
Each file is assigned to a game by its folder name and its ID3 album tag (a folder can hold
several albums, e.g. Tribes + Tribes II), then converted to Ogg Vorbis into
    <packs_dir>/_soundtracks/<pack>/track_NN.ogg   + tracks.json
The store is separate from the disc packs so re-importing a disc never deletes its music.
Prints JSON lines like siege_import.py: {"stage","progress","message"} ... {"done": true, "packs": [...]}.
"""
import argparse, json, os, re, subprocess, sys

AUDIO_EXT = ('.mp3', '.flac', '.wav', '.ogg', '.m4a', '.wma')

# game identification: (pack, display name, folder-name regex, album-tag regex)
GAMES = [
    ('tribes2', 'Tribes 2', r'tribes\s*(ii|2)\b', r'tribes\s*(ii|2)\b'),
    ('tribes', 'Starsiege: Tribes', r'tribes', r'^tribes$|starsiege\s*:?\s*tribes'),
    ('starsiege', 'Starsiege', r'stars[ie]{2}ge', r'stars[ie]{2}ge'),
    ('es2', 'Earthsiege 2', r'earths[ie]{2}ge\s*2|es2', r'earths[ie]{2}ge\s*2'),
    ('es1', 'Metaltech: Earthsiege', r'earths[ie]{2}ge(?!\s*2)', r'earths[ie]{2}ge(?!\s*2)'),
    ('bd', 'Metaltech: Battledrome', r'battledrome', r'battledrome'),
    ('cyberstorm2', 'MissionForce: CyberStorm 2', r'cyberstorm\s*2', r'cyberstorm\s*2'),
    ('cyberstorm', 'MissionForce: CyberStorm', r'cyberstorm', r'cyberstorm'),
]

# Starsiege: active table from scripts/cdAudioTracks.cs. The script registers "SS1" as track 14,
# which is a typo for 11 (the list runs ...10, 14, 12, 13 and track 11 is otherwise unused);
# the game's requests for track 14 are therefore redirected to 11 (see "aliases").
STARSIEGE_NAMES = {2: 'Yougot', 3: 'Newtech', 4: 'CloudBurst', 5: 'SS4', 6: 'Purge', 7: 'Mechsoul',
                   8: 'SS3', 9: 'Watching', 10: 'Terror', 11: 'SS1', 12: 'Gnash', 13: 'Cyberntx'}

# how ripped track numbers map to the disc's CD-audio track numbers (track 1 = data track)
CD_OFFSET = {'starsiege': 1, 'tribes': 1, 'es2': 1}


def emit(**kw):
    print(json.dumps(kw), flush=True)


def ffmpeg():
    from video import ffmpeg_exe
    return ffmpeg_exe() or 'ffmpeg'


def probe(ff, path):
    out = subprocess.run([ff, '-hide_banner', '-i', path], capture_output=True, text=True,
                         encoding='utf-8', errors='replace').stderr
    tags = {k.lower(): v.strip() for k, v in re.findall(r'^\s+(\w+)\s*:\s*(.*)$', out, re.M)}
    m = re.search(r'Duration: (\d+):(\d+):([\d.]+)', out)
    tags['_seconds'] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0
    return tags


def identify(folder_name, album):
    for pack, name, frx, arx in GAMES:
        if album and re.search(arx, album, re.I):
            return pack, name
    for pack, name, frx, arx in GAMES:
        if re.search(frx, folder_name, re.I):
            return pack, name
    return None, None


def track_number(fname, tags):
    t = tags.get('track', '')
    m = re.match(r'(\d+)', t)
    if m:
        return int(m.group(1))
    m = re.match(r'\s*(\d+)', fname)
    return int(m.group(1)) if m else None


def collect(paths):
    files = []
    for root in paths:
        for dirpath, _dirs, names in os.walk(root):
            for n in sorted(names):
                if n.lower().endswith(AUDIO_EXT):
                    files.append(os.path.join(dirpath, n))
    return files


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('folders', nargs='+')
    a = ap.parse_args(argv)
    ff = ffmpeg()
    files = collect(a.folders)
    if not files:
        emit(error='No audio files found in the chosen folder.')
        return 1
    groups = {}
    for f in files:
        tags = probe(ff, f)
        pack, name = identify(os.path.basename(os.path.dirname(f)), tags.get('album', ''))
        if pack is None:
            emit(stage='skip', progress=-1, message='Could not tell which game %s belongs to - skipped' % os.path.basename(f))
            continue
        n = track_number(os.path.basename(f), tags)
        groups.setdefault(pack, {'name': name, 'files': []})['files'].append((n, f, tags))
    store = os.path.join(a.out, '_soundtracks')
    total = sum(len(g['files']) for g in groups.values())
    done = 0
    for pack, g in groups.items():
        d = os.path.join(store, pack)
        os.makedirs(d, exist_ok=True)
        entries = []
        g['files'].sort(key=lambda x: (x[0] is None, x[0] or 0, x[1]))
        for i, (n, f, tags) in enumerate(g['files']):
            n = n if n is not None else i + 1
            cd = n + CD_OFFSET[pack] if pack in CD_OFFSET else None
            out_name = 'track_%02d.ogg' % (cd if cd is not None else n)
            emit(stage='soundtrack', progress=done / max(total, 1),
                 message='%s: converting %s' % (g['name'], os.path.basename(f)))
            subprocess.run([ff, '-hide_banner', '-loglevel', 'error', '-y', '-i', f, '-vn', '-map_metadata', '-1',
                            '-c:a', 'libvorbis', '-q:a', '6', os.path.join(d, out_name)], check=True)
            e = {'file': out_name, 'source': os.path.basename(f), 'album_track': n,
                 'seconds': round(tags.get('_seconds', 0.0), 2), 'title': tags.get('title', '')}
            if cd is not None:
                e['cd_track'] = cd
            if pack == 'starsiege' and cd in STARSIEGE_NAMES:
                e['name'] = STARSIEGE_NAMES[cd]
            if pack == 'tribes' and cd == 2:
                e['use'] = 'main menu'
            entries.append(e)
            done += 1
        meta = {'pack': pack, 'name': g['name'], 'tracks': entries}
        if pack == 'starsiege':
            meta['aliases'] = {'14': 11}   # script typo: SS1 registered as track 14
        if pack == 'tribes2':
            meta['note'] = ('Tribes 2 soundtrack album (7 tracks); the game also ships its own '
                            'environment music (base/music/*.mp3) in the disc pack.')
        with open(os.path.join(d, 'tracks.json'), 'w') as fh:
            json.dump(meta, fh, indent=1)
    emit(done=True, packs=sorted(groups))
    return 0


if __name__ == '__main__':
    sys.exit(main())
