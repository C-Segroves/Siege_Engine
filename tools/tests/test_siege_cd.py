"""Synthetic CD images for the importer's CD-audio support (tools/siege_cd.py, siege_iso.Disc, siege_import).

    python tools/tests/test_siege_cd.py [--keep] [--exe dist/siege-importer/siege-importer.exe]

Builds a tiny ISO 9660 volume with pycdlib, wraps it as
  * BIN/CUE, MODE1/2352 and MODE2/2352, single .bin (INDEX 00 pregaps stored) and one .bin per track
    (PREGAP directive / INDEX 00 in the track's own file),
  * .iso + a sibling folder of ripped WAV tracks with assorted names,
and checks: the data track reads back as the ISO, audio tracks extract bit-exactly (pregaps excluded),
identify (real Starsiege signature) reports "audio_tracks", and a full import through a fake game module
writes <pack>/audio/cd/track_NN.ogg + tracks.json (and the "no CD audio" message when there is none).
With --exe, the frozen importer identifies the synthetic .cue and extracts its tracks (`run siege_cd`).
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np
import pycdlib

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.normpath(os.path.join(HERE, '..'))
sys.path.insert(0, TOOLS)
import siege_cd  # noqa: E402
import siege_iso  # noqa: E402

RAW = 2352
FAILS = []


def check(cond, what):
    print(('  ok   ' if cond else '  FAIL ') + what)
    if not cond:
        FAILS.append(what)


# ---------------------------------------------------------------------------------------------- builders
def make_iso(label='STARSIEGE1', game_files=True):
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, vol_ident=label)

    def add(iso_path, joliet, data):
        iso.add_fp(io.BytesIO(data), len(data), iso_path, joliet_path=joliet)
    if game_files:
        add('/STARSIEG.URL;1', '/starsiege.url', b'[InternetShortcut]\r\n')
        iso.add_directory('/SETUP', joliet_path='/setup')
        add('/SETUP/DATA1.HDR;1', '/setup/data1.hdr', b'H' * 5000)
        add('/SETUP/DATA1.CAB;1', '/setup/data1.cab', bytes(range(256)) * 40)
    add('/PAYLOAD.BIN;1', '/payload.bin', os.urandom(70000))
    bio = io.BytesIO()
    iso.write_fp(bio)
    iso.close()
    return bio.getvalue()


def bcd(n):
    return ((n // 10) << 4) | (n % 10)


def raw_sectors(iso_bytes, mode):
    out = bytearray()
    for lba in range(len(iso_bytes) // 2048):
        a = lba + 150
        hdr = siege_cd.SYNC + bytes([bcd(a // 4500), bcd(a // 75 % 60), bcd(a % 75), mode])
        user = iso_bytes[lba * 2048:(lba + 1) * 2048]
        if mode == 1:
            s = hdr + user + b'\0' * 288
        else:                                                 # XA form 1: subheader x2, data, EDC/ECC
            s = hdr + b'\0\0\x08\0\0\0\x08\0' + user + b'\0' * 280
        assert len(s) == RAW
        out += s
    return bytes(out)


def tone(freq, seconds):
    t = np.arange(int(44100 * seconds)) / 44100.0
    l = (np.sin(2 * np.pi * freq * t) * 12000).astype('<i2')
    r = (np.sin(2 * np.pi * freq * 1.5 * t) * 9000).astype('<i2')
    return np.stack([l, r], 1).tobytes()


def gap(sectors, fill=0x11):
    return bytes([fill]) * (sectors * RAW)


def m(sectors):
    return '%02d:%02d:%02d' % (sectors // 4500, sectors // 75 % 60, sectors % 75)


TRACKS = {2: tone(440, 2.0), 3: tone(660, 1.0), 4: tone(330, 1.2)}       # whole sectors (2 s = 150 sectors)


def make_single_bin(d, name, mode, iso_bytes):
    data = raw_sectors(iso_bytes, mode)
    pos = len(data) // RAW
    blob = bytearray(data)
    cue = ['FILE "%s.bin" BINARY' % name, '  TRACK 01 MODE%d/2352' % mode, '    INDEX 01 00:00:00']
    for n, pcm in TRACKS.items():
        g = 150 if n == 2 else 33                            # INDEX 00 pregap stored in the bin (non-silent filler)
        cue += ['  TRACK %02d AUDIO' % n, '    INDEX 00 %s' % m(pos), '    INDEX 01 %s' % m(pos + g)]
        blob += gap(g, 0x20 + n) + pcm
        pos += g + len(pcm) // RAW
    open(os.path.join(d, name + '.bin'), 'wb').write(blob)
    open(os.path.join(d, name + '.cue'), 'w').write('\n'.join(cue) + '\n')
    return os.path.join(d, name + '.cue')


def make_multi_bin(d, name, mode, iso_bytes):
    open(os.path.join(d, '%s (Track 01).bin' % name), 'wb').write(raw_sectors(iso_bytes, mode))
    cue = ['FILE "%s (Track 01).bin" BINARY' % name, '  TRACK 01 MODE%d/2352' % mode, '    INDEX 01 00:00:00']
    for n, pcm in TRACKS.items():
        f = '%s (Track %02d).bin' % (name, n)
        cue.append('FILE "C:\\Users\\someone\\rips\\%s" BINARY' % f)    # absolute path from the ripping machine
        if n == 3:
            open(os.path.join(d, f), 'wb').write(pcm)
            cue += ['  TRACK %02d AUDIO' % n, '    PREGAP 00:02:00', '    INDEX 01 00:00:00']
        else:
            open(os.path.join(d, f), 'wb').write(gap(150, 0x30 + n) + pcm)
            cue += ['  TRACK %02d AUDIO' % n, '    INDEX 00 00:00:00', '    INDEX 01 00:02:00']
    open(os.path.join(d, name + '.cue'), 'w').write('\n'.join(cue) + '\n')
    return os.path.join(d, name + '.cue')


def write_wav(path, pcm):
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(pcm)


def make_iso_folder(d, name, iso_bytes, names):
    p = os.path.join(d, name + '.iso')
    open(p, 'wb').write(iso_bytes)
    folder = os.path.join(d, name)
    os.makedirs(folder, exist_ok=True)
    for (n, pcm), fn in zip(TRACKS.items(), names):
        write_wav(os.path.join(folder, fn), pcm)
    open(os.path.join(folder, 'cover.jpg'), 'wb').write(b'\xff\xd8 not audio')
    return p


# ---------------------------------------------------------------------------------------------- checks
def wav_pcm(path):
    with wave.open(path, 'rb') as w:
        return w.readframes(w.getnframes())


def check_image(path, iso_bytes, label, tmp):
    print('%s: %s' % (label, os.path.basename(path)))
    img = siege_cd.open_image(path)
    img.data.seek(0)
    check(img.data.read() == iso_bytes, 'data track reads back as the ISO (%d bytes)' % len(iso_bytes))
    img.close()
    with siege_iso.Disc(path) as d:
        check(d.label == 'STARSIEGE1' and d.exists('setup/data1.cab'), 'Disc reads the ISO directory')
        out = os.path.join(tmp, 'x.cab')
        d.extract('setup/data1.cab', out)
        check(open(out, 'rb').read() == bytes(range(256)) * 40, 'file extracted from the data track')
        check([t.number for t in d.audio] == [2, 3, 4], 'audio tracks 2,3,4 listed')
        for t in d.audio:
            w = t.write_wav(os.path.join(tmp, 't%02d.wav' % t.number))
            check(wav_pcm(w) == TRACKS[t.number], 'track %d extracts bit-exactly (%.2f s, pregap excluded)' % (t.number, t.seconds))


def run_import(paths, packs, fake=True):
    """Full import in a child process with a fake game module registered (label SIEGETEST)."""
    driver = r'''
import sys, os
sys.path.insert(0, %r)
import siege_games
from siege_games import Step
class Fake:
    GAME = {'game': 'fake', 'pack': 'fake', 'name': 'Fake Siege', 'discs': 1, 'cd_audio': True}
    @staticmethod
    def identify(disc):
        return 1 if disc.label.upper().startswith('SIEGETEST') else 0
    @staticmethod
    def cd_audio_uses(ctx, numbers):
        return {n: {'use': 'music', 'name': 'T%%d' %% n} for n in numbers}
    @staticmethod
    def steps(ctx):
        def x(c):
            c.extract(1, 'payload.bin', c.pack_path('payload.bin'))
        return [Step('extract', 'Copying...', 1, x)]
Fake.__name__ = 'fake'
siege_games.GAMES.insert(0, Fake)
import siege_import
sys.exit(siege_import.main(sys.argv[1:]))
''' % TOOLS
    r = subprocess.run([sys.executable, '-c', driver, 'import', '--out', packs] + paths,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    lines = [json.loads(x) for x in r.stdout.decode().splitlines() if x.strip().startswith('{')]
    return r.returncode, lines, r.stderr.decode('utf-8', 'replace')


def check_pack(packs, n_tracks):
    tj = os.path.join(packs, 'fake', 'audio', 'cd', 'tracks.json')
    check(os.path.exists(os.path.join(packs, 'fake', 'payload.bin')), 'pack payload installed')
    if not n_tracks:
        check(not os.path.exists(tj), 'no tracks.json without audio')
        return
    rows = json.load(open(tj)) if os.path.exists(tj) else []
    check([r['track'] for r in rows] == [2, 3, 4], 'tracks.json lists 2,3,4')
    for r in rows:
        f = os.path.join(packs, 'fake', 'audio', 'cd', r['file'])
        want = len(TRACKS[r['track']]) / 176400.0
        check(os.path.exists(f) and r['file'] == 'track_%02d.ogg' % r['track'], '%s written' % r['file'])
        check(r['seconds'] is not None and abs(r['seconds'] - want) < 0.1, '%s: %s s (want %.2f)' % (r['file'], r['seconds'], want))
        check(r['use'] == 'music' and r['name'] == 'T%d' % r['track'], '%s: use/name from cd_audio_uses' % r['file'])


def main():
    keep = '--keep' in sys.argv
    exe = os.path.abspath(sys.argv[sys.argv.index('--exe') + 1]) if '--exe' in sys.argv else None
    tmp = tempfile.mkdtemp(prefix='siege-cd-test-')
    try:
        print('map_tracks / track_number')
        cases = {'Track 02.flac': 2, '02 - Track 2.wav': 2, 'starsiege (Track 03).flac': 3, 'Track03.wav': 3,
                 '07 Yougot.mp3': 7, 'starseige_disc_1 - 12.flac': 12, 'track_9.ogg': 9, 'noname.flac': None}
        for k, v in cases.items():
            check(siege_cd.track_number(k) == v, 'track_number(%r) = %r' % (k, siege_cd.track_number(k)))
        check(siege_cd.map_tracks(['01 a.flac', '02 b.flac']) == {2: '01 a.flac', 3: '02 b.flac'},
              'audio-only numbering (01, 02) shifts to tracks 2, 3')
        check(siege_cd.map_tracks(['x.flac', 'Track 02.flac']) == {2: 'Track 02.flac', 3: 'x.flac'},
              'unnumbered files fill up after the numbered ones')

        iso_bytes = make_iso()
        for mode in (1, 2):
            d = os.path.join(tmp, 'single%d' % mode)
            os.makedirs(d)
            check_image(make_single_bin(d, 'starsiege_m%d' % mode, mode, iso_bytes), iso_bytes, 'single BIN MODE%d/2352' % mode, d)
            d = os.path.join(tmp, 'multi%d' % mode)
            os.makedirs(d)
            cue = make_multi_bin(d, 'Starsiege Disc 1', mode, iso_bytes)
            check_image(cue, iso_bytes, 'multi BIN MODE%d/2352' % mode, d)
            check_image(os.path.join(d, 'Starsiege Disc 1 (Track 03).bin'), iso_bytes, '.bin of a multi-bin set -> its .cue', d)
            check(siege_cd.canonical(os.path.join(d, 'Starsiege Disc 1 (Track 01).bin')) == siege_cd.canonical(cue),
                  'canonical(.bin) == canonical(.cue)')

        d = os.path.join(tmp, 'isofolder')
        os.makedirs(d)
        iso_p = make_iso_folder(d, 'starseige_disc_1', iso_bytes,
                                ['starsiege (Track 02).wav', '03 - Track 3.wav', 'Track 04.wav'])
        print('.iso + folder')
        with siege_iso.Disc(iso_p) as disc:
            check([t.number for t in disc.audio] == [2, 3, 4], 'folder tracks mapped to 2,3,4')
            check(os.path.basename(disc.audio_source) == 'starseige_disc_1', 'audio folder found')
            from video import ffmpeg_exe
            for t in disc.audio:
                w = t.write_wav(os.path.join(tmp, 'f%02d.wav' % t.number), ffmpeg_exe())
                check(wav_pcm(w) == TRACKS[t.number], 'folder track %d decodes bit-exactly' % t.number)

        print('identify (real Starsiege signature)')
        import siege_import
        for p, n in ((os.path.join(tmp, 'single2', 'starsiege_m2.cue'), 3), (iso_p, 3),
                     (os.path.join(tmp, 'multi1', 'Starsiege Disc 1 (Track 02).bin'), 3)):
            _g, info = siege_import.identify_disc(p)
            check(info['game'] == 'starsiege' and info['disc'] == 1 and info['audio_tracks'] == n,
                  'identify %s -> %s disc %s, audio_tracks %s' % (os.path.basename(p), info['game'], info['disc'], info['audio_tracks']))
        lone = os.path.join(tmp, 'lone')
        os.makedirs(lone)
        open(os.path.join(lone, 'plain.iso'), 'wb').write(iso_bytes)
        _g, info = siege_import.identify_disc(os.path.join(lone, 'plain.iso'))
        check(info['audio_tracks'] == 0, 'plain .iso without folder: audio_tracks 0')

        print('import (fake game module)')
        t_iso = make_iso('SIEGETEST', game_files=False)
        for kind in ('single', 'multi', 'folder', 'none'):
            d = os.path.join(tmp, 'imp_' + kind)
            os.makedirs(d)
            if kind == 'single':
                paths = [make_single_bin(d, 'siegetest', 2, t_iso)]
            elif kind == 'multi':
                cue = make_multi_bin(d, 'siegetest', 1, t_iso)
                paths = [cue] + [os.path.join(d, 'siegetest (Track %02d).bin' % n) for n in (1, 2, 3, 4)]   # all dropped
            elif kind == 'folder':
                paths = [make_iso_folder(d, 'siegetest', t_iso, ['Track 02.wav', 'Track 03.wav', 'Track 04.wav'])]
            else:
                paths = [os.path.join(d, 'siegetest.iso')]
                open(paths[0], 'wb').write(t_iso)
            packs = os.path.join(d, 'packs')
            rc, lines, err = run_import(paths, packs)
            done = [x for x in lines if x.get('done')]
            check(rc == 0 and done, 'import %s: rc %s %s' % (kind, rc, [x for x in lines if 'error' in x] or ''))
            if rc != 0:
                print(err[-2000:])
            check_pack(packs, 0 if kind == 'none' else 3)
            msgs = [x.get('message', '') for x in lines]
            if kind == 'none':
                check(siege_import.NO_CD_AUDIO in msgs, 'missing-audio message shown')
            else:
                check(not any('both disc 1' in s for s in msgs), 'dropped .cue + .bin files count as one disc')

        if exe:
            print('frozen importer: %s' % exe)
            cue = os.path.join(tmp, 'multi2', 'Starsiege Disc 1.cue')
            r = subprocess.run([exe, 'identify', cue], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            info = json.loads(r.stdout.decode().strip().splitlines()[-1])
            check(info.get('game') == 'starsiege' and info.get('audio_tracks') == 3, 'frozen identify .cue: %s' % info)
            out = os.path.join(tmp, 'frozen_wav')
            r = subprocess.run([exe, 'run', 'siege_cd', cue, '--wav', out], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            ok = all(os.path.exists(os.path.join(out, 'track_%02d.wav' % n)) and
                     wav_pcm(os.path.join(out, 'track_%02d.wav' % n)) == TRACKS[n] for n in TRACKS)
            check(ok, 'frozen run siege_cd --wav extracts the tracks bit-exactly')
            if not ok:
                print(r.stdout.decode(), r.stderr.decode()[-2000:])
            r = subprocess.run([exe, 'import', '--out', os.path.join(tmp, 'frozen_packs'), cue],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
            lines = [json.loads(x) for x in r.stdout.decode().splitlines() if x.strip().startswith('{')]
            check(any('message' in x for x in lines) and lines[0].get('stage') == 'identify',
                  'frozen import accepts the .cue (fails later on the fake cabinet as expected: %s)'
                  % ([x.get('error', '')[:80] for x in lines if 'error' in x] or 'no error'))
    finally:
        if keep:
            print('kept', tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    print('\n%s' % ('ALL OK' if not FAILS else '%d FAILED' % len(FAILS)))
    return 1 if FAILS else 0


if __name__ == '__main__':
    sys.exit(main())
