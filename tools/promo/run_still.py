"""Render one roster still (a grid of every vehicle/soldier of a game) to media/stills/roster/<name>.png.
usage: python tools/promo/run_still.py <game> <cat> <title> <subtitle> [per-row] [name]      (see stills_all.sh)
env:   GODOT = Godot 4 console executable
"""
import pathlib, subprocess, sys
import promo_paths as PP

PROJECT = pathlib.Path(PP.GAME)
HERE = pathlib.Path(PP.HERE)
OUT = pathlib.Path(PP.STILLS) / "roster"


def run(game, cat, title, sub, per=7, name=None):
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / ((name or "%s_%s" % (game, cat)) + ".png")
    ov = PROJECT / "override.cfg"
    ov.write_text("[display]\n\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\nwindow/size/no_focus=true\nwindow/size/borderless=true\n", encoding="utf-8")
    try:
        r = subprocess.run([PP.godot(), "--audio-driver", "Dummy", "--path", str(PROJECT), "-s", str(HERE / "boot.gd"), "--", "--test-store",
                            "--driver=" + str(HERE / "stills.gd").replace("\\", "/"), "--game=" + game, "--cat=" + cat,
                            "--out=" + str(out).replace("\\", "/"), "--title=" + title, "--sub=" + sub, "--per=%d" % per],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", timeout=300).stdout
    finally:
        ov.unlink(missing_ok=True)
    for l in r.splitlines():
        if l.startswith("stills") or "SCRIPT ERROR" in l:
            print(l[:400])


if __name__ == "__main__":
    a = sys.argv[1:]
    run(a[0], a[1], a[2], a[3], int(a[4]) if len(a) > 4 else 7, a[5] if len(a) > 5 else None)
