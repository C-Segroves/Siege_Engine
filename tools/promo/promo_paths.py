"""Shared paths and helpers for the promo tools. Everything is written under <repo>/media/ (git-ignored).

Environment (all optional):
  GODOT        Godot 4 console executable (default: looked up on PATH as godot / godot4 / Godot*console*)
  SIEGE_FONT   TTF used for captions (default: bahnschrift on Windows, DejaVu Sans elsewhere)
"""
import datetime
import glob
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import siege_paths as P  # noqa: E402

ROOT = P.ROOT
MEDIA = os.path.join(ROOT, 'media')
GAME = os.path.join(ROOT, 'game')
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = HERE
CLIPS = os.path.join(MEDIA, 'clips')
STILLS = os.path.join(MEDIA, 'stills')
VIDEOS = os.path.join(MEDIA, 'videos')
TEASERS = os.path.join(MEDIA, 'teasers')
MUSIC = os.path.join(MEDIA, 'music')
SOCIAL = os.path.join(MEDIA, 'social')
WORK = os.path.join(MEDIA, '_work')       # scratch: intermediates, raw AVI captures

REPO_URL = 'github.com/C-Segroves/Siege_Engine'
KOFI_URL = 'ko-fi.com/csegroves'


def today():
    return datetime.date.today().isoformat()


def work(*parts):
    path = os.path.join(WORK, *parts)
    os.makedirs(path if not os.path.splitext(path)[1] else os.path.dirname(path), exist_ok=True)
    return path


def ffmpeg():
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def run_ffmpeg(args, quiet=True):
    """Runs ffmpeg with args (anything is str()-ed); raises SystemExit with its output on failure."""
    cmd = [ffmpeg(), '-hide_banner', '-y'] + (['-v', 'error'] if quiet else []) + [str(a) for a in args]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
    if r.returncode:
        raise SystemExit(r.stdout[-3000:])
    return r.stdout


def font_path():
    env = os.environ.get('SIEGE_FONT')
    if env:
        return env
    for c in (r'C:/Windows/Fonts/bahnschrift.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'):
        if os.path.exists(c):
            return c
    raise SystemExit('no caption font found; set SIEGE_FONT to a .ttf file')


def godot():
    env = os.environ.get('GODOT')
    if env:
        return env
    for name in ('godot', 'godot4'):
        hit = shutil.which(name)
        if hit:
            return hit
    raise SystemExit('set GODOT to the Godot 4 console executable')


def clip(tag):
    """Newest media/clips/<date>/<tag>.mp4."""
    hits = sorted(glob.glob(os.path.join(CLIPS, '*', tag + '.mp4')))
    if not hits:
        raise SystemExit('no clip %r under %s (capture it with render_seg.py)' % (tag, CLIPS))
    return hits[-1]


def clip_marks(tag):
    """Path of the <tag>.json frame marks written next to the clip."""
    return os.path.splitext(clip(tag))[0] + '.json'


def music(track):
    """media/music/<track>.mp3 (falls back to .wav)."""
    for ext in ('.mp3', '.wav'):
        p = os.path.join(MUSIC, track + ext)
        if os.path.exists(p):
            return p
    raise SystemExit('no track %r in %s' % (track, MUSIC))
