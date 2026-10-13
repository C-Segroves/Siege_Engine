"""Converts a game's cinematics to Theora (.ogv, what Godot plays) at import: pack/video/<stem>.ogv plus
pack/video/clips.json.

  python tools/export_movies.py es2        Earthsiege 2: work/es2/original/AVI/*.AVI; clip index table read from
                                           VSHELL.EXE (0x470e74, 86 string pointers; docs/formats/es2_campaign_flow.md)
  python tools/export_movies.py starsiege  Starsiege: work/starsiege/original/disc1/data/movies/*.smk

clips.json: {"clips": [stem by the game's clip index] (ES2; [] when there is no table), "files": [every stem]}.
Nothing of the game is copied into this script: names, indices and frames come from the user's disc.
"""
import json
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
from video import ffmpeg_exe  # noqa: E402

ES2_CLIP_TABLE_VA = 0x470e74
ES2_CLIP_COUNT = 86
SOURCES = {
    'es2': (('es2', 'original', 'AVI'), '.avi'),
    'starsiege': (('starsiege', 'original', 'disc1', 'data', 'movies'), '.smk'),
}
# Theora / Vorbis quality (0..10): close to the sources, which are 320x200 .. 640x480 at low bit rates.
VIDEO_QUALITY = '7'
AUDIO_QUALITY = '4'


def pe_va_reader(data):
    """Returns f(va) -> file offset for a PE image (None outside every section)."""
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    opt = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<I', data, pe + 24 + 28)[0]
    secs = [struct.unpack_from('<8sIIII', data, pe + 24 + opt + 40 * i)[1:5] for i in range(nsec)]

    def off(va):
        rva = va - base
        for vsize, vaddr, rsize, raddr in secs:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                return rva - vaddr + raddr
        return None
    return off


def read_es2_clip_table(exe_path):
    """The shell's clip names by index ('avi\\pt1.avi' -> 'pt1'), [] when the executable is missing."""
    if not os.path.exists(exe_path):
        return []
    data = open(exe_path, 'rb').read()
    off = pe_va_reader(data)
    table = off(ES2_CLIP_TABLE_VA)
    out = []
    for i in range(ES2_CLIP_COUNT):
        so = off(struct.unpack_from('<I', data, table + 4 * i)[0])
        name = data[so:data.index(b'\0', so)].decode('latin1') if so is not None else ''
        out.append(os.path.splitext(name.replace('\\', '/').split('/')[-1])[0].lower())
    return out


def convert(ff, src, dst):
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        return
    subprocess.check_call([ff, '-y', '-loglevel', 'error', '-i', src, '-c:v', 'libtheora', '-q:v', VIDEO_QUALITY,
                           '-c:a', 'libvorbis', '-q:a', AUDIO_QUALITY, dst])


def main(pack):
    rel, ext = SOURCES[pack]
    src_dir = P.work(*rel)
    if not os.path.isdir(src_dir):
        print('no %s movies at %s' % (pack, src_dir))
        return
    ff = ffmpeg_exe()
    if not ff:
        print('ffmpeg is missing - %s movies skipped' % pack)
        return
    out_dir = P.pack(pack, 'video')
    os.makedirs(out_dir, exist_ok=True)
    stems = []
    for f in sorted(os.listdir(src_dir)):
        if f.lower().endswith(ext):
            stem = os.path.splitext(f)[0].lower()
            print('  %s' % f, flush=True)
            convert(ff, os.path.join(src_dir, f), os.path.join(out_dir, stem + '.ogv'))
            stems.append(stem)
    clips = read_es2_clip_table(P.work('es2', 'original', 'VSHELL.EXE')) if pack == 'es2' else []
    with open(os.path.join(out_dir, 'clips.json'), 'w') as fp:
        json.dump({'clips': clips, 'files': stems}, fp, indent=1)
    print('%s: %d movies, %d indexed clips' % (pack, len(stems), len(clips)))


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in SOURCES:
        sys.exit(__doc__)
    main(sys.argv[1])
