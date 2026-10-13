"""Render Earthsiege / Battledrome HMI music (HMP) to OGG Vorbis the way the DOS games played it.

    python tools/render_music.py all <es1|bd> [<outdir>]          # default outdir gamedata/<pack>/audio/music
    python tools/render_music.py one <es1|bd> <in.hmp> <out.ogg> [--variant sb|adlib]
    python tools/render_music.py check <outdir>                    # levels + loop seams from music.json
    python tools/render_music.py spectrogram <outdir> <png dir> <track> [<track> ...]

Variants (one emulated OPL chip each, shared by all channels, with the driver's own 9-voice stealing):
  sb     Sound Blaster (the default; the user's card): fmmidi.com (0xA002) on the card's OPL3 in OPL2 mode
         with 16-bit output, plus HMP tracks routed to 0xA005 played from DRUM32.DIG on the DSP (8 voices).
  adlib  AdLib (OPL2): the same FM driver on a YM3812 whose YM3014 DAC quantises to a 10-bit mantissa;
         0xA005-only tracks have no device and stay silent (as on the real card).
Driver behaviour: tools/hmi_fm.py (FM), tools/hmi_digi.py (digital drums), tools/hmi_song.py (sequencer);
which song plays when: tools/music_games.py.  Output is mono (the OPL2 driver ignores cc10 and the OPL3 in
OPL2 mode sends every voice to both sides); FM and DSP are mixed at equal full scale (as DOSBox / an SB16
mixer at equal FM and voice levels), DC-blocked (output capacitor) and given one fixed gain per game so the
songs keep their relative loudness.

Files: <outdir>/<variant>/<track>.ogg + <outdir>/music.json.  A looping song's file is its first pass
followed by one loop pass; loop_start/loop_end (seconds) mark the loop pass, so playback starts from
silence like the original and wraps seamlessly ([loop_end, ...) equals [loop_start, ...) up to the chip's
free-running LFO/noise phase -- `seam_error_db` measures it).
"""
import glob, hashlib, json, math, os, subprocess, sys, tempfile, wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
import hmi_digi  # noqa: E402
import hmi_fm  # noqa: E402
import hmi_song  # noqa: E402
import music_games  # noqa: E402

RATE = 44100
PYOPL_CHUNK = 512                   # most samples one getSamples call returns
INT16_SCALE = 32768.0
DC_BLOCK_HZ = 15.0
MASTER_GAIN = 0.55                  # one gain for every song and game (loudest, BD ROCK2 on SB, peaks at -0.9 dBFS)
ONCE_TAIL_SECONDS = 3.0             # release tail rendered after a song that ends
SILENCE_DB = -60.0
SEAM_WINDOW_SECONDS = 0.25
ENVELOPE_WINDOW_SECONDS = 0.01
MAX_SEAM_ENVELOPE_DB = 3.0
ENVELOPE_FLOOR_DB = 15.0            # envelope windows this far below the song's RMS are ignored
LOOP_PASSES = 3                     # passes rendered after the first; the kept loop pass is followed by one more
VARIANTS = {
    'sb': {'label': 'Sound Blaster (OPL3)', 'drivers': (hmi_fm.DEVICE_FM_OPL2, hmi_digi.DEVICE_DIGI), 'dac': None},
    'adlib': {'label': 'AdLib (OPL2)', 'drivers': (hmi_fm.DEVICE_FM_OPL2,), 'dac': 'ym3014'},
}
DEFAULT_VARIANT = 'sb'
YM3014_MANTISSA_BITS = 10


# ------------------------------------------------------------------ chip

class OplChip:
    """DOSBox's OPL emulator (pyopl) at RATE; register writes land at the current render position."""

    def __init__(self):
        import pyopl
        self._opl = pyopl.opl(RATE, 2, 1)
        self._buf = bytearray(PYOPL_CHUNK * 2)
        self._carry = None
        self.writes = 0

    def write(self, register, value):
        self._opl.writeReg(register, value)
        self.writes += 1

    def render(self, n):
        out = np.empty(n, np.float32)
        p = 0
        if self._carry is not None and n > 0:
            out[0], self._carry, p = self._carry, None, 1
        while p < n:
            k = min(PYOPL_CHUNK, n - p)
            buf = self._buf if k == PYOPL_CHUNK else bytearray(max(k, 2) * 2)
            self._opl.getSamples(buf)
            s = np.frombuffer(buf, np.int16)
            out[p:p + k] = s[:k]
            if k == 1:
                self._carry = float(s[1])
            p += k
        return out


def ym3014(int16):
    """YM3014B floating-point DAC: 10-bit mantissa, 3-bit exponent -> low bits dropped on loud samples."""
    x = np.asarray(int16, np.int32)
    out = x.copy()
    limit = 1 << (YM3014_MANTISSA_BITS - 1)
    for shift in range(1, 7):
        big = (np.abs(x) >= limit << (shift - 1))
        out[big] = (x[big] >> shift) << shift
    return out.astype(np.float32)


# ------------------------------------------------------------------ timeline

class Timeline:
    """Tick -> output sample, periodic across loop passes so every loop pass is rendered identically."""

    def __init__(self, ticks_per_second, jumps):
        self.tps, self.jumps = ticks_per_second, jumps
        self.period = round((jumps[1] - jumps[0]) * RATE / self.tps) if len(jumps) > 1 else 0

    def sample(self, tick):
        k = sum(1 for j in self.jumps if tick >= j)
        if k == 0:
            return round(tick * RATE / self.tps)
        start = round(self.jumps[0] * RATE / self.tps) + (k - 1) * self.period
        return start + round((tick - self.jumps[k - 1]) * RATE / self.tps)


def schedule(song, policy):
    """-> (events [(tick, track, status, d1, d2)], loop jump ticks).  A restarted song is scheduled as the
    same sequence again from its end tick (driver state carries over, as when the game restarts it)."""
    if policy == music_games.LOOP:
        play = hmi_song.Playback(song, max_jumps=LOOP_PASSES + 1)
        return list(play.events()), play.jumps[:LOOP_PASSES + 1]
    one = list(hmi_song.Playback(song, max_jumps=0).events())
    if policy == music_games.ONCE:
        return one, []
    length = song.end_tick()
    events = [(t + k * length, tr, s, a, b) for k in range(LOOP_PASSES + 1) for (t, tr, s, a, b) in one]
    return events, [length * (k + 1) for k in range(LOOP_PASSES + 1)]


# ------------------------------------------------------------------ render

class SosDrivers:
    """The drivers a variant loads, from the game's own SOS files."""

    def __init__(self, game, variant):
        root = P.WORK
        self.devices = VARIANTS[variant]['drivers']
        self.image = hmi_fm.FmDriverImage(game.driver_file(root, 'HMIMDRV.386'))
        self.melodic = hmi_fm.FmBank(game.driver_file(root, 'MELODIC.BNK'))
        self.drums = hmi_fm.FmBank(game.driver_file(root, 'DRUM.BNK'))
        self.kit = hmi_digi.DigKit(game.driver_file(root, 'DRUM32.DIG')) if hmi_digi.DEVICE_DIGI in self.devices else None


def render_song(path, game, variant, drivers=None):
    """-> (mono float32 audio, meta)."""
    drivers = drivers or SosDrivers(game, variant)
    song = hmi_song.HmpSong(path)
    name = os.path.splitext(os.path.basename(path))[0].lower()
    has_loop = any(e.is_controller(hmi_song.CC_LOOP_START) for t in song.tracks for e in t.events)
    policy = game.policy(name, has_loop)
    events, jumps = schedule(song, policy)
    timeline = Timeline(song.ticks_per_second, jumps)
    total = timeline.sample(jumps[-1]) if jumps else timeline.sample(song.end_tick()) + int(ONCE_TAIL_SECONDS * RATE)
    chip = OplChip()
    fm = hmi_fm.FmDriver(drivers.image, drivers.melodic, drivers.drums, chip)
    digi = hmi_digi.DigiDriver(drivers.kit, RATE) if drivers.kit else None
    routes = {t.index: song.driver_for(t, drivers.devices) for t in song.tracks}
    audio = play_events(events, routes, fm, digi, chip, total, timeline)
    if VARIANTS[variant]['dac'] == 'ym3014':
        audio = ym3014(audio)
    mix = audio / INT16_SCALE
    if digi:
        mix = mix + digi.render(total)
    mix = highpass1(mix, DC_BLOCK_HZ / (RATE / 2)).astype(np.float32)
    meta = dict(policy=policy, ticks_per_second=song.ticks_per_second,
                fm_tracks=[t for t, d in routes.items() if d == hmi_fm.DEVICE_FM_OPL2],
                digi_tracks=[t for t, d in routes.items() if d == hmi_digi.DEVICE_DIGI],
                dropped_notes=fm.dropped_notes, max_voices=fm.peak_voices)
    return finish(mix, policy, jumps, timeline, meta)


def play_events(events, routes, fm, digi, chip, total, timeline):
    out = np.zeros(total, np.float32)
    pos = 0
    for tick, track, status, d1, d2 in events:
        at = timeline.sample(tick)
        if at >= total:
            break
        if at > pos:
            out[pos:at] = chip.render(at - pos)
            pos = at
        if status & 0xf0 == 0xb0 and d1 == hmi_song.CC_VOLUME:
            d2 = hmi_song.scale_volume(d2)
        device = routes.get(track)
        if device == hmi_fm.DEVICE_FM_OPL2:
            fm.send(status, d1, d2)
        elif device == hmi_digi.DEVICE_DIGI and digi:
            digi.send(at, status, d1, d2)
    if pos < total:
        out[pos:] = chip.render(total - pos)
    return out


def finish(mix, policy, jumps, timeline, meta):
    if policy == music_games.ONCE:
        mix = trim_tail(mix)
        meta.update(loop=False, loop_start=None, loop_end=None, seam_error_db=None, seam_envelope_db=None)
        return mix, meta
    start, end = best_loop_pass(mix, [timeline.sample(j) for j in jumps])
    meta.update(loop=True, loop_start=round(start / RATE, 6), loop_end=round(end / RATE, 6),
                seam_error_db=seam_error_db(mix, start, end), seam_envelope_db=seam_envelope_db(mix, start, end))
    return mix[:end], meta


def best_loop_pass(mix, bounds):
    """The earliest loop pass whose wrap keeps the level (passes can differ while voices are starved);
    else the pass with the smallest jump.  -> (start, end) samples."""
    candidates = [(bounds[k], bounds[k + 1]) for k in range(len(bounds) - 2)]
    for start, end in candidates:
        if seam_envelope_db(mix, start, end) <= MAX_SEAM_ENVELOPE_DB:
            return start, end
    return min(candidates, key=lambda c: seam_envelope_db(mix, *c))


def trim_tail(mix):
    level = 10 ** (SILENCE_DB / 20)
    loud = np.nonzero(np.abs(mix) > level)[0]
    return mix[:int(loud[-1]) + 1] if len(loud) else mix[:1]


def seam_error_db(mix, start, end):
    """What plays after the wrap ([start..]) vs what the next pass really plays ([end..]): RMS of the
    difference relative to the RMS of the music there, in dB (-inf = identical)."""
    n = min(int(SEAM_WINDOW_SECONDS * RATE), len(mix) - end)
    a, b = mix[start:start + n].astype(np.float64), mix[end:end + n].astype(np.float64)
    ref = math.sqrt(float((b ** 2).mean()) or 1e-20)
    diff = math.sqrt(float(((a - b) ** 2).mean()))
    return round(20 * math.log10(max(diff, 1e-12) / ref), 2)


def seam_envelope_db(mix, start, end):
    """Largest level jump at the wrap: 10 ms RMS envelopes of [start..] vs [end..] (dB, loud windows only).
    Passes differ in phase (the chip's LFO and noise run freely) but must not differ in loudness."""
    w = int(ENVELOPE_WINDOW_SECONDS * RATE)
    n = min(int(SEAM_WINDOW_SECONDS * RATE), len(mix) - end) // w * w
    if n <= 0:
        return 0.0

    def env(x):
        return 20 * np.log10(np.sqrt((x.astype(np.float64).reshape(-1, w) ** 2).mean(1)) + 1e-9)
    a, b = env(mix[start:start + n]), env(mix[end:end + n])
    floor = 20 * math.log10(math.sqrt(float((mix[start:end].astype(np.float64) ** 2).mean())) + 1e-9) - ENVELOPE_FLOOR_DB
    live = np.maximum(a, b) > floor
    return round(float(np.abs(a - b)[live].max()), 2) if live.any() else 0.0


def highpass1(x, wn, block=1024):
    """First-order Butterworth high-pass (bilinear, zero initial state) in numpy:
    y[n] = p*y[n-1] + g*(x[n] - x[n-1]), evaluated block-wise."""
    t = math.tan(math.pi * wn / 2)
    p, g = (1 - t) / (1 + t), 1 / (1 + t)
    x = np.asarray(x, np.float64)
    d = np.diff(x, prepend=0.0)
    y = np.empty_like(d)
    i = np.arange(block, dtype=np.float64)
    up, down = p ** i, p ** -i
    prev = 0.0
    for s in range(0, len(d), block):
        n = min(block, len(d) - s)
        acc = np.cumsum(d[s:s + n] * down[:n]) * g
        y[s:s + n] = up[:n] * (p * prev + acc)
        prev = y[s + n - 1]
    return y


# ------------------------------------------------------------------ output

def pcm16(mono):
    return (np.clip(mono * MASTER_GAIN, -1, 1) * 32767).astype('<i2')


def write_ogg(mono, dst):
    fd, tmp = tempfile.mkstemp(suffix='.wav')
    os.close(fd)
    try:
        with wave.open(tmp, 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm16(mono).tobytes())
        subprocess.check_call([ffmpeg(), '-y', '-loglevel', 'error', '-i', tmp, '-c:a', 'libvorbis', '-q:a', '5', dst])
    finally:
        os.remove(tmp)


def ffmpeg():
    from video import ffmpeg_exe
    exe = ffmpeg_exe()
    if not exe:
        raise RuntimeError('ffmpeg not available (pip install imageio-ffmpeg)')
    return exe


def song_paths(game):
    out = []
    for group, pattern in game.sources:
        for f in sorted(glob.glob(os.path.join(P.WORK, pattern), recursive=True)):
            out.append((os.path.splitext(os.path.basename(f))[0].lower(), group, f))
    return out


def render_all(pack, outdir):
    game = music_games.GAMES[pack]
    tracks, digests = {}, {}
    for variant in VARIANTS:
        drivers = SosDrivers(game, variant)
        os.makedirs(os.path.join(outdir, variant), exist_ok=True)
        for name, group, path in song_paths(game):
            print('rendering %s (%s) ...' % (name, variant), flush=True)
            mono, meta = render_song(path, game, variant, drivers)
            write_ogg(mono, os.path.join(outdir, variant, name + '.ogg'))
            entry = tracks.setdefault(name, track_entry(game, name, group, path, meta))
            entry['files'][variant] = '%s/%s.ogg' % (variant, name)
            entry['seam_error_db'][variant] = meta['seam_error_db']
            entry['seam_envelope_db'][variant] = meta['seam_envelope_db']
            entry['duration'][variant] = round(len(mono) / RATE, 4)
            entry['pcm_sha1'][variant] = hashlib.sha1(pcm16(mono).tobytes()).hexdigest()
            digests.setdefault(variant, {})[name] = entry['pcm_sha1'][variant]
    doc = music_doc(game, tracks)
    with open(os.path.join(outdir, 'music.json'), 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
    return doc


def track_entry(game, name, group, path, meta):
    info = game.tracks.get(name, (group, ''))
    return dict(group=info[0], context=info[1], source=os.path.relpath(path, P.WORK).replace('\\', '/'),
                policy=meta['policy'], loop=meta['loop'], loop_start=meta['loop_start'], loop_end=meta['loop_end'],
                fm_tracks=meta['fm_tracks'], digi_drum_tracks=meta['digi_tracks'],
                max_fm_voices=meta['max_voices'], dropped_notes=meta['dropped_notes'],
                files={}, duration={}, seam_error_db={}, seam_envelope_db={}, pcm_sha1={})


def music_doc(game, tracks):
    return dict(format='OGG Vorbis q5 44.1 kHz mono, emulated HMI SOS drivers (see tools/render_music.py)',
                variants={k: v['label'] for k, v in VARIANTS.items()}, default_variant=DEFAULT_VARIANT,
                gain=MASTER_GAIN,
                looping='loop=true: play from 0, wrap from loop_end back to loop_start (seconds)',
                situations=game.situations, tracks=tracks)


# ------------------------------------------------------------------ check / pictures

def decode(path):
    raw = subprocess.check_output([ffmpeg(), '-loglevel', 'error', '-i', path, '-f', 's16le', '-ac', '1',
                                   '-ar', str(RATE), '-'])
    return np.frombuffer(raw, np.int16).astype(np.float32) / INT16_SCALE


def check(outdir):
    doc = json.load(open(os.path.join(outdir, 'music.json'), encoding='utf-8'))
    ok = True
    print('%-10s %-6s %7s %6s %7s %6s %8s  %s' % ('track', 'var', 'dur s', 'peak', 'rms dB', 'clip', 'seam env', 'status'))
    for name, t in sorted(doc['tracks'].items()):
        for variant, rel in sorted(t['files'].items()):
            a = decode(os.path.join(outdir, rel))
            peak, rms = float(np.abs(a).max()), float(np.sqrt((a ** 2).mean()))
            clip = int((np.abs(a) >= 0.999).sum())
            seam = t['seam_envelope_db'].get(variant)
            status = 'OK'
            if rms < 1e-3:
                status = 'SILENT?'
            if clip > 10:
                status = 'CLIPPING'
            if seam is not None and seam > MAX_SEAM_ENVELOPE_DB:
                status = 'SEAM?'
            ok &= status == 'OK'
            print('%-10s %-6s %7.2f %6.3f %7.1f %6d %8s  %s' % (name, variant, len(a) / RATE, peak,
                  20 * math.log10(max(rms, 1e-9)), clip, seam, status))
    return ok


def spectrogram(outdir, pngdir, names):
    os.makedirs(pngdir, exist_ok=True)
    doc = json.load(open(os.path.join(outdir, 'music.json'), encoding='utf-8'))
    for name in names:
        for variant, rel in doc['tracks'][name]['files'].items():
            dst = os.path.join(pngdir, 'music_%s_%s.png' % (name, variant))
            subprocess.check_call([ffmpeg(), '-y', '-loglevel', 'error', '-t', '30', '-i', os.path.join(outdir, rel),
                                   '-lavfi', 'showspectrumpic=s=1024x512:scale=log:legend=1', dst])
            print(dst)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd = argv[1]
    if cmd == 'all':
        pack = argv[2]
        doc = render_all(pack, argv[3] if len(argv) > 3 else P.pack(pack, 'audio', 'music'))
        print('%d tracks x %d variants' % (len(doc['tracks']), len(VARIANTS)))
    elif cmd == 'one':
        variant = argv[argv.index('--variant') + 1] if '--variant' in argv else DEFAULT_VARIANT
        mono, meta = render_song(argv[3], music_games.GAMES[argv[2]], variant)
        write_ogg(mono, argv[4])
        print(json.dumps(meta, indent=1))
    elif cmd == 'check':
        return 0 if check(argv[2]) else 2
    elif cmd == 'spectrogram':
        spectrogram(argv[2], argv[3], argv[4:])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
