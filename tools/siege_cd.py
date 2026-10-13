"""CD images with Red Book audio for the importer: BIN/CUE images and .iso + ripped-track folders.

A WinCDEmu .iso holds only the data track. Games such as Starsiege keep their soundtrack as CD-audio
tracks, so the importer also accepts
  (A) <name>.iso plus a sibling folder <name>/ with the ripped audio tracks (FLAC/WAV/MP3/OGG/...; file names
      carry the track number: "Track 02.flac", "02 - Track 2.wav", "starsiege (Track 03).flac", ...), or
  (B) a BIN/CUE image (CDRWIN/ImgBurn cue sheet; one .bin for the whole disc or one .bin per track) with a
      MODE1/2352, MODE2/2352 (or /2048, /2336) data track and AUDIO tracks (raw 16-bit 44.1 kHz stereo LE).

    img = open_image('starsiege.cue')        # or a .bin (its .cue is found), or a raw 2352-byte image
    img.data                                 # file object: the data track as 2048-byte sectors (for pycdlib)
    img.audio                                # [AudioTrack]
    sibling_audio('starseige_disc_1.iso')    # [AudioTrack] from the folder next to an .iso
    t.write_wav('t02.wav'); t.encode_ogg(ffmpeg, 'track_02.ogg')

    python tools/siege_cd.py <image.cue|.bin|.iso>            list the tracks
    python tools/siege_cd.py <image> --wav <dir>               extract every audio track to WAV
"""
import io
import os
import re
import subprocess
import sys
import wave

SECTOR = 2048
RAW = 2352
CD_RATE = 44100
AUDIO_EXTS = ('.flac', '.wav', '.mp3', '.ogg', '.oga', '.opus', '.m4a', '.ape', '.wv', '.aif', '.aiff', '.wma')
SYNC = b'\x00' + b'\xff' * 10 + b'\x00'

# cue track mode -> (bytes per sector in the file, offset of the 2048 user bytes; None = probe header)
MODES = {
    'MODE1/2048': (2048, 0), 'MODE1/2352': (2352, 16), 'MODE1/2448': (2448, 16),
    'MODE2/2048': (2048, 0), 'MODE2/2336': (2336, 8), 'MODE2/2352': (2352, None), 'MODE2/2448': (2448, None),
    'CDI/2336': (2336, 8), 'CDI/2352': (2352, None),
    'AUDIO': (2352, 0), 'AUDIO/2352': (2352, 0), 'AUDIO/2448': (2448, 0),
}


class CueError(Exception):
    pass


def msf(s):
    m, sec, f = (int(x) for x in s.split(':'))
    return (m * 60 + sec) * 75 + f


# ---------------------------------------------------------------------------------------------- data track
class SectorReader(io.RawIOBase):
    """The 2048-byte user data of a run of raw sectors, as a seekable binary stream."""

    def __init__(self, path, byte_start, sector_size, user_offset, n_sectors):
        super().__init__()
        self.f = open(path, 'rb')
        self.start, self.ss, self.off, self.n = byte_start, sector_size, user_offset, n_sectors
        self.size = n_sectors * SECTOR
        self.pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, pos, whence=0):
        self.pos = max(0, pos if whence == 0 else self.pos + pos if whence == 1 else self.size + pos)
        return self.pos

    def readinto(self, b):
        want = min(len(b), self.size - self.pos)
        if want <= 0:
            return 0
        first, skip = divmod(self.pos, SECTOR)
        count = (skip + want + SECTOR - 1) // SECTOR
        self.f.seek(self.start + first * self.ss)
        raw = self.f.read(count * self.ss)
        if self.ss == SECTOR and self.off == 0:
            data = raw
        else:
            mv = memoryview(raw)
            data = b''.join(mv[i * self.ss + self.off:i * self.ss + self.off + SECTOR]
                            for i in range(len(raw) // self.ss))
        data = data[skip:skip + want]
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)

    def close(self):
        try:
            self.f.close()
        finally:
            super().close()


def _user_offset(path, byte_start, sector_size, mode):
    """MODE2 images: Form 1 data after the 8-byte subheader (24); some 'MODE2' images really hold mode 1."""
    ss, off = MODES[mode]
    if off is not None:
        return off
    with open(path, 'rb') as f:
        f.seek(byte_start + 16 * sector_size)              # the primary volume descriptor sector
        hdr = f.read(16)
    if hdr[:12] == SYNC and hdr[15] == 1:
        return 16
    return 24


# ---------------------------------------------------------------------------------------------- audio tracks
class AudioTrack:
    """One CD-audio track: raw PCM inside a BIN (kind 'pcm') or a ripped/decoded file (kind 'file')."""

    def __init__(self, number, path, kind, offset=0, length=None, big_endian=False, start_s=0.0, dur_s=None):
        self.number, self.path, self.kind = number, path, kind
        self.offset, self.length, self.big_endian = offset, length, big_endian       # pcm: bytes
        self.start_s, self.dur_s = start_s, dur_s                                   # file: seconds (cue WAVE)

    @property
    def seconds(self):
        if self.kind == 'pcm':
            return self.length / (CD_RATE * 4)
        return self.dur_s

    def __repr__(self):
        return 'AudioTrack(%d, %s, %s%s)' % (self.number, os.path.basename(self.path), self.kind,
                                             ', %.1fs' % self.seconds if self.seconds else '')

    def _pcm_chunks(self, chunk=1 << 20):
        with open(self.path, 'rb') as f:
            f.seek(self.offset)
            left = self.length
            while left > 0:
                data = f.read(min(chunk, left))
                if not data:
                    break
                left -= len(data)
                if self.big_endian:
                    a = bytearray(data)
                    a[0::2], a[1::2] = data[1::2], data[0::2]
                    data = bytes(a)
                yield data

    def write_wav(self, dst, ffmpeg=None):
        """16-bit 44.1 kHz stereo WAV. File tracks need ffmpeg (unless they are such a WAV already)."""
        os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
        if self.kind == 'pcm':
            with wave.open(dst, 'wb') as w:
                w.setnchannels(2)
                w.setsampwidth(2)
                w.setframerate(CD_RATE)
                for data in self._pcm_chunks():
                    w.writeframes(data)
            return dst
        if not ffmpeg:
            raise RuntimeError('ffmpeg is needed to decode %s' % self.path)
        _run([ffmpeg, '-y', '-loglevel', 'error'] + self._file_input() +
             ['-map', '0:a:0', '-vn', '-c:a', 'pcm_s16le', '-ar', str(CD_RATE), '-ac', '2', dst])
        return dst

    def _file_input(self):
        a = []
        if self.start_s:
            a += ['-ss', '%.4f' % self.start_s]
        if self.dur_s:                       # a track inside a cue-sheet WAVE file that holds several tracks
            a += ['-t', '%.4f' % self.dur_s]
        return a + ['-i', self.path]

    def encode_ogg(self, ffmpeg, dst, quality=6):
        """Ogg Vorbis (q6) at dst; returns the track length in seconds."""
        os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
        enc = ['-map', '0:a:0', '-vn', '-map_metadata', '-1', '-c:a', 'libvorbis', '-q:a', str(quality), dst]
        if self.kind == 'pcm':
            tmp = dst + '.wav'
            try:
                self.write_wav(tmp)
                _run([ffmpeg, '-y', '-loglevel', 'error', '-i', tmp] + enc)
            finally:
                if os.path.exists(tmp):
                    os.remove(tmp)
            return round(self.seconds, 2)
        _run([ffmpeg, '-y', '-loglevel', 'error'] + self._file_input() + enc)
        s = probe_seconds(ffmpeg, dst)
        return round(s, 2) if s is not None else None


def _run(cmd):
    r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError('ffmpeg failed (%s): %s' % (r.returncode, r.stderr.decode('utf-8', 'replace')[-400:]))


def probe_seconds(ffmpeg, path):
    r = subprocess.run([ffmpeg, '-hide_banner', '-i', path], stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    m = re.search(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)', r.stderr.decode('utf-8', 'replace'))
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


# ---------------------------------------------------------------------------------------------- cue sheets
class CueTrack:
    def __init__(self, number, mode, file, ftype):
        self.number, self.mode, self.file, self.ftype = number, mode.upper(), file, ftype.upper()
        self.indexes = {}           # index number -> sector position within the file
        self.end = None             # sector position within the file (exclusive) or None = end of file
        self.byte_base = 0          # byte offset of sector self.first in the file

    @property
    def audio(self):
        return self.mode.startswith('AUDIO')

    @property
    def sector_size(self):
        return MODES.get(self.mode, (RAW, 0))[0]

    @property
    def first(self):
        return min(self.indexes.values())

    @property
    def start(self):
        return self.indexes.get(1, self.first)

    def byte_at(self, sector):
        return self.byte_base + (sector - self.first) * self.sector_size


def _read_text(path):
    raw = open(path, 'rb').read()
    for enc in ('utf-8-sig', 'cp1252', 'latin-1'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('latin-1', 'replace')


def _find_file(cue_dir, name, cue_path):
    """A FILE entry: relative to the cue, or just its base name next to the cue (cues often keep the ripping
    machine's absolute path), case-insensitively."""
    name = name.strip().strip('"')
    cands = [name if os.path.isabs(name) else os.path.join(cue_dir, name),
             os.path.join(cue_dir, re.split(r'[\\/]', name)[-1])]
    for c in cands:
        if os.path.isfile(c):
            return c
    base = re.split(r'[\\/]', name)[-1].lower()
    try:
        for f in os.listdir(cue_dir):
            if f.lower() == base:
                return os.path.join(cue_dir, f)
    except OSError:
        pass
    raise CueError('%s refers to "%s", which is not next to it - keep the .bin files in the same folder as the .cue'
                   % (os.path.basename(cue_path), base))


def parse_cue(path):
    """-> [CueTrack] with indexes, end and byte_base resolved per file."""
    cue_dir = os.path.dirname(os.path.abspath(path))
    tracks, cur_file, cur_type, files = [], None, None, []
    for line in _read_text(path).splitlines():
        line = line.strip()
        if not line:
            continue
        kw = line.split(None, 1)[0].upper()
        if kw == 'FILE':
            m = re.match(r'FILE\s+"(.*)"\s+(\S+)\s*$', line, re.I) or re.match(r'FILE\s+(.*\S)\s+(\S+)\s*$', line, re.I)
            if not m:
                raise CueError('bad FILE line in %s: %s' % (os.path.basename(path), line))
            cur_file, cur_type = _find_file(cue_dir, m.group(1), path), m.group(2)
            files.append(cur_file)
        elif kw == 'TRACK':
            p = line.split()
            if cur_file is None or len(p) < 3:
                raise CueError('bad TRACK line in %s: %s' % (os.path.basename(path), line))
            tracks.append(CueTrack(int(p[1]), p[2], cur_file, cur_type))
        elif kw == 'INDEX' and tracks:
            p = line.split()
            tracks[-1].indexes[int(p[1])] = msf(p[2])
    tracks = [t for t in tracks if t.indexes]
    if not tracks:
        raise CueError('%s lists no tracks' % os.path.basename(path))
    for f in files:
        ft = [t for t in tracks if t.file == f]
        for i, t in enumerate(ft):
            if i:
                p = ft[i - 1]
                t.byte_base = p.byte_base + (t.first - p.first) * p.sector_size
                p.end = t.first             # the pregap (INDEX 00) of a track is not part of the previous one
    return tracks


def find_cue_for_bin(bin_path):
    """The .cue that references bin_path: <same name>.cue first, else any .cue in the folder that lists it."""
    d = os.path.dirname(os.path.abspath(bin_path))
    stem = os.path.splitext(os.path.basename(bin_path))[0].lower()
    try:
        names = os.listdir(d)
    except OSError:
        return None
    cues = [f for f in names if f.lower().endswith('.cue')]
    for f in cues:
        if os.path.splitext(f)[0].lower() == stem:
            return os.path.join(d, f)
    target = os.path.normcase(os.path.abspath(bin_path))
    for f in cues:
        try:
            if any(os.path.normcase(os.path.abspath(t.file)) == target for t in parse_cue(os.path.join(d, f))):
                return os.path.join(d, f)
        except (CueError, OSError, ValueError):
            continue
    return None


def canonical(path):
    """Same key for every file of one image (.bin -> its .cue), for de-duplicating dropped files."""
    p = os.path.abspath(path)
    if p.lower().endswith('.bin'):
        p = find_cue_for_bin(p) or p
    return os.path.normcase(os.path.normpath(p))


def is_raw_image(path):
    """A 2352-byte-sector image without cue sheet (sync pattern at the start)."""
    try:
        with open(path, 'rb') as f:
            return f.read(12) == SYNC
    except OSError:
        return False


class Image:
    """An opened CD image: .data (2048-byte sector stream of the first data track) and .audio."""

    def __init__(self, path, data, audio, kind):
        self.path, self.data, self.audio, self.kind = path, data, audio, kind

    def close(self):
        if self.data is not None:
            self.data.close()


def _audio_from_cue(tracks):
    out = []
    for t in tracks:
        if not t.audio:
            continue
        if t.ftype in ('BINARY', 'MOTOROLA'):
            end = t.end
            if end is None:
                size = os.path.getsize(t.file)
                end = t.first + (size - t.byte_base) // t.sector_size
            n = max(0, end - t.start)
            if t.sector_size != RAW:
                continue                     # audio with subchannel data: not supported
            out.append(AudioTrack(t.number, t.file, 'pcm', t.byte_at(t.start), n * RAW, t.ftype == 'MOTOROLA'))
        else:                                # WAVE / MP3 / AIFF / FLAC: decoded by ffmpeg, positions in time
            dur = (t.end - t.start) / 75.0 if t.end is not None else None
            out.append(AudioTrack(t.number, t.file, 'file', start_s=t.start / 75.0, dur_s=dur))
    return out


def open_image(path):
    """.cue, .bin (finds its .cue) or a cue-less raw image -> Image. Raises CueError."""
    ext = os.path.splitext(path)[1].lower()
    cue = path if ext == '.cue' else None
    if ext == '.bin':
        cue = find_cue_for_bin(path)
    if cue is None:
        if is_raw_image(path):
            with open(path, 'rb') as f:
                f.seek(15)
                mode = 'MODE1/2352' if f.read(1) == b'\x01' else 'MODE2/2352'
            off = _user_offset(path, 0, RAW, mode)
            n = os.path.getsize(path) // RAW
            return Image(path, io.BufferedReader(SectorReader(path, 0, RAW, off, n), 1 << 20), [], 'raw')
        raise CueError('%s has no cue sheet (.cue) next to it - keep the .cue from the BIN/CUE image with it'
                       % os.path.basename(path))
    tracks = parse_cue(cue)
    data_t = next((t for t in tracks if not t.audio), None)
    data = None
    if data_t is not None:
        if data_t.mode not in MODES or data_t.ftype not in ('BINARY', 'MOTOROLA'):
            raise CueError('%s: track %d has an unsupported mode %s' % (os.path.basename(cue), data_t.number, data_t.mode))
        start = data_t.byte_at(data_t.start)
        end = data_t.end
        if end is None:
            n = (os.path.getsize(data_t.file) - start) // data_t.sector_size
        else:
            n = end - data_t.start
        off = _user_offset(data_t.file, start, data_t.sector_size, data_t.mode)
        data = io.BufferedReader(SectorReader(data_t.file, start, data_t.sector_size, off, n), 1 << 20)
    return Image(cue, data, _audio_from_cue(tracks), 'cue')


# ---------------------------------------------------------------------------------------------- .iso + folder
def _norm(s):
    return re.sub(r'[\s_\-\.]+', ' ', s.lower()).strip()


def audio_folder(iso_path):
    """The folder of ripped tracks next to an .iso: named like the .iso without extension (case, spaces,
    '_' and '-' ignored), or '<name> audio'."""
    d = os.path.dirname(os.path.abspath(iso_path))
    stem = _norm(os.path.splitext(os.path.basename(iso_path))[0])
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for want in (stem, stem + ' audio', stem + ' music'):
        for n in names:
            if _norm(n) == want and os.path.isdir(os.path.join(d, n)):
                return os.path.join(d, n)
    return None


def track_number(name):
    """Track number from a ripped file name, or None."""
    stem = os.path.splitext(os.path.basename(name))[0]
    m = re.search(r'(?i)\btrack\s*[-_#.]?\s*0*(\d{1,2})(?!\d)', stem) or re.search(r'(?i)track0*(\d{1,2})(?!\d)', stem)
    if m:
        return int(m.group(1))
    m = re.match(r'\s*0*(\d{1,2})(?!\d)', stem)
    if m:
        return int(m.group(1))
    nums = re.findall(r'(?<!\d)(\d{1,2})(?!\d)', stem)
    return int(nums[-1]) if nums else None


def map_tracks(files):
    """[file paths] -> {track number: path}. Data is track 1 on these discs, so a set numbered from 1 (a ripper
    that counted audio tracks only) is shifted to start at 2; files without a number fill up in name order."""
    nums = {f: track_number(f) for f in files}
    numbered = {f: n for f, n in nums.items() if n}
    if numbered and min(numbered.values()) == 1 and 1 in numbered.values():
        numbered = {f: n + 1 for f, n in numbered.items()}
    out = {}
    for f in sorted(numbered, key=lambda f: (numbered[f], f.lower())):
        out.setdefault(numbered[f], f)            # duplicates (e.g. .flac and .wav of one track): first wins
    nxt = max(out) + 1 if out else 2
    for f in sorted((f for f in files if f not in numbered), key=str.lower):
        out[nxt] = f
        nxt += 1
    return out


def sibling_audio(iso_path):
    d = audio_folder(iso_path)
    if not d:
        return []
    files = [os.path.join(d, f) for f in os.listdir(d)
             if f.lower().endswith(AUDIO_EXTS) and os.path.isfile(os.path.join(d, f))]
    # prefer lossless when a track exists in several formats
    rank = {e: i for i, e in enumerate(('.flac', '.wav', '.wv', '.ape', '.aiff', '.aif', '.ogg', '.opus', '.m4a', '.mp3', '.oga', '.wma'))}
    files.sort(key=lambda f: (rank.get(os.path.splitext(f)[1].lower(), 99), f.lower()))
    by_track = map_tracks(files)
    return [AudioTrack(n, f, 'file') for n, f in sorted(by_track.items())]


def audio_for(path):
    """Audio tracks for any accepted disc file, without opening the data track."""
    ext = os.path.splitext(path)[1].lower()
    if ext in ('.cue', '.bin'):
        try:
            return open_image(path).audio
        except CueError:
            return []
    return sibling_audio(path)


def main(argv):
    if not argv:
        print(__doc__)
        return 0
    path = argv[0]
    ext = os.path.splitext(path)[1].lower()
    if ext == '.iso' and not is_raw_image(path):
        audio, src = sibling_audio(path), audio_folder(path)
        print('ISO data track; audio folder: %s' % (src or 'none'))
    else:
        img = open_image(path)
        audio = img.audio
        print('%s image %s: data track %s' % (img.kind, img.path, '%d sectors' % img.data.raw.n if img.data else 'none'))
        img.close()
    for t in audio:
        print('  track %02d  %s' % (t.number, t))
    if '--wav' in argv:
        out = argv[argv.index('--wav') + 1]
        from video import ffmpeg_exe
        for t in audio:
            print('  ->', t.write_wav(os.path.join(out, 'track_%02d.wav' % t.number), ffmpeg_exe()))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
