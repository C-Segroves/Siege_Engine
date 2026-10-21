"""Capture one scripted segment of the game with Godot Movie Maker into media/clips/<date>/<tag>.mp4.

usage: python tools/promo/render_seg.py <seg> [WxH] [fps] [--tag=<subject>] [--<director args>]
env:   DRIVER = director script in this folder (default promo2_director.gd; promo2c_director.gd for the
                call-in clips on Varuna's Fall; social_director.gd for the original social clips)
       GODOT  = Godot 4 console executable

The director (a Node script loaded by boot.gd) prints "social: mark <name> frame=<n>" lines; they are saved as
<tag>.json next to the clip (seconds into the clip), which frames.py uses. The raw AVI is a scratch file under
media/_work/capture and is deleted once the mp4 is made. Audio is off (Dummy driver); music is added by compose_*.py.
"""
import json, os, pathlib, re, subprocess, sys
import promo_paths as PP

PROJECT = pathlib.Path(PP.GAME)
HERE = pathlib.Path(PP.HERE)
MARK = re.compile(r"social: mark (\w+) frame=(\d+)")


def main(seg, size="1920x1080", fps=60, extra=(), tag=None):
    w, h = (int(v) for v in size.split("x"))
    tag = tag or "%s_%s" % (seg, size)
    driver = os.environ.get("DRIVER", "promo2_director.gd")
    scratch = pathlib.Path(PP.work("capture"))
    avi = scratch / (tag + ".avi")
    ov = PROJECT / "override.cfg"
    ov.write_text("[display]\n\nwindow/size/viewport_width=%d\nwindow/size/viewport_height=%d\nwindow/size/no_focus=true\n"
                  "window/size/borderless=true\nwindow/size/initial_position_type=0\nwindow/size/initial_position=Vector2i(0, 0)\n\n"
                  "[editor]\n\nmovie_writer/mjpeg_quality=0.95\n" % (w, h), encoding="utf-8")
    args = [PP.godot(), "--audio-driver", "Dummy", "--path", str(PROJECT), "--write-movie", str(avi), "--fixed-fps", str(fps),
            "-s", str(HERE / "boot.gd"), "--", "--test-store", "--driver=" + str(HERE / driver).replace("\\", "/"), "--seg=" + seg] + list(extra)
    try:
        out = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", timeout=3300).stdout
    finally:
        ov.unlink(missing_ok=True)
    marks = {m.group(1): int(m.group(2)) / fps for m in MARK.finditer(out)}
    dest = pathlib.Path(PP.CLIPS) / PP.today()
    dest.mkdir(parents=True, exist_ok=True)
    (dest / (tag + ".json")).write_text(json.dumps(marks), encoding="utf-8")
    (scratch / (tag + ".log")).write_text(out, encoding="utf-8")
    if avi.exists():
        PP.run_ffmpeg(["-i", avi, "-an", "-c:v", "libx264", "-crf", "14", "-preset", "veryfast", "-pix_fmt", "yuv420p", dest / (tag + ".mp4")])
        avi.unlink()
    print(seg, "->", dest / (tag + ".mp4"), marks)
    for line in out.splitlines():
        if ("ERROR" in line or "social:" in line) and "leaked" not in line and "BUG" not in line:
            print("  ", line.strip()[:200])


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    ex = [x for x in sys.argv[1:] if x.startswith("--") and not x.startswith("--tag=")]
    tg = [x[6:] for x in sys.argv[1:] if x.startswith("--tag=")]
    main(a[0], a[1] if len(a) > 1 else "1920x1080", int(a[2]) if len(a) > 2 else 60, ex, tg[0] if tg else None)
