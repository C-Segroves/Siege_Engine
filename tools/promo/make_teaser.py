"""Cut a vertical (1080x1920) music teaser into media/teasers/<post-date>_<track>_<subject>.mp4.

usage: python tools/promo/make_teaser.py <post-date> <track> <subject> <source> <start> <duration> [--music-start=S]
  post-date  the day it will be posted, yyyy-mm-dd (it is the first part of the file name)
  track      a track in media/music (e.g. machine_liturgy)
  subject    what the footage shows, snake_case (e.g. lobby, cloak, bioderm_wave)
  source     a finished video (path, or a name under media/videos) or a raw clip tag from media/clips
  start      seconds into the source where the footage begins; duration in seconds (10 to 15 suits Reels and TikTok)
A horizontal source is centred on a blurred copy of itself; a vertical one fills the frame. Music fades in and out.
Example: python tools/promo/make_teaser.py 2026-10-21 machine_liturgy lobby 2026-10-20_choose_your_operator 1.4 15
"""
import glob, os, sys
import promo_paths as PP

FPS = 60


def resolve(src):
    if os.path.exists(src):
        return src
    hits = sorted(glob.glob(os.path.join(PP.VIDEOS, src + "*.mp4")) + glob.glob(os.path.join(PP.VIDEOS, src)))
    return hits[0] if hits else PP.clip(src)


def make(post_date, track, subject, source, start, dur, music_start=0.0):
    os.makedirs(PP.TEASERS, exist_ok=True)
    out = os.path.join(PP.TEASERS, "%s_%s_%s.mp4" % (post_date, track, subject))
    fc = ("[0:v]split[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=30:5,eq=brightness=-0.15[bg];"
          "[b]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,fps=%d,fade=t=in:st=0:d=0.4,fade=t=out:st=%.2f:d=0.6,format=yuv420p[v];"
          "[1:a]aresample=48000,afade=t=in:st=0:d=0.8,afade=t=out:st=%.2f:d=1.5[a]" % (FPS, dur - 0.6, dur - 1.5))
    PP.run_ffmpeg(["-ss", start, "-t", dur, "-i", resolve(source), "-ss", music_start, "-t", dur, "-i", PP.music(track),
                   "-filter_complex", fc, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "18", "-preset", "slow",
                   "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", dur, out])
    print(out)
    return out


if __name__ == "__main__":
    pos = [a for a in sys.argv[1:] if not a.startswith("--")]
    opt = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if len(pos) != 6:
        raise SystemExit(__doc__)
    make(pos[0], pos[1], pos[2], pos[3], float(pos[4]), float(pos[5]), float(opt.get("music-start", 0)))
