"""Compose the first Siege Engine promo (eight games, one engine) into media/videos/<date>_promo{,_vertical}.mp4.
usage: python tools/promo/compose_promo.py      (needs media/clips, media/stills/roster, media/music)
"""
import pathlib
from PIL import Image, ImageDraw, ImageFont
import promo_paths as PP

CL = pathlib.Path(PP.CLIPS)
WORK = pathlib.Path(PP.work("promo_first"))
ST = pathlib.Path(PP.STILLS) / "roster"
OUT = pathlib.Path(PP.VIDEOS)
OUT.mkdir(parents=True, exist_ok=True)
MUSIC = pathlib.Path(PP.MUSIC) / "machine_liturgy.wav"
FONT = PP.font_path()
AMBER = (255, 222, 0)
TEAL = (173, 255, 250)
BG = (4, 18, 22)
W, H, FPS = 1920, 1080, 60


def run(args):
    PP.run_ffmpeg(args)


def font(sz):
    return ImageFont.truetype(FONT, sz)


def lower_third(name, year, line, path):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 800, 1250, 1010), fill=(4, 28, 32, 205))
    d.rectangle((0, 800, 12, 1010), fill=AMBER + (255,))
    d.text((60, 820), name, font=font(74), fill=AMBER)
    d.text((64, 910), year, font=font(40), fill=TEAL)
    d.text((64, 958), line, font=font(34), fill=(220, 245, 245))
    im.save(path)


def card(lines, path, bg=BG):
    im = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(im)
    y = 330
    for txt, sz, col in lines:
        w = d.textlength(txt, font=font(sz))
        d.text(((W - w) / 2, y), txt, font=font(sz), fill=col)
        y += int(sz * 1.45)
    im.save(path)


def still_part(png, dur, out, zoom_in=True):
    n = int(dur * FPS)
    z = "min(1.0+0.0007*on,1.12)" if zoom_in else "max(1.12-0.0007*on,1.0)"
    run(["-loop", "1", "-i", png, "-vf",
         "scale=3840:-1,zoompan=z='%s':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=%d:s=%dx%d:fps=%d,format=yuv420p" % (z, n, W, H, FPS),
         "-frames:v", n, "-c:v", "libx264", "-crf", "14", "-preset", "fast", "-r", FPS, out])


def clip_part(tag, t0, t1, out):
    run(["-ss", t0, "-i", PP.clip(tag), "-t", t1 - t0, "-vf", "scale=%d:%d:flags=lanczos,fps=%d,format=yuv420p" % (W, H, FPS),
         "-an", "-c:v", "libx264", "-crf", "14", "-preset", "fast", out])


def concat(parts, out):
    lst = WORK / "list.txt"
    lst.write_text("".join("file '%s'\n" % str(p).replace("\\", "/") for p in parts), encoding="utf-8")
    run(["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out])


def overlay_seg(src, ov, out, dur):
    run(["-i", src, "-loop", "1", "-i", ov, "-filter_complex",
         "[1:v]format=rgba,fade=t=in:st=0.3:d=0.5:alpha=1,fade=t=out:st=%.2f:d=0.5:alpha=1[o];[0:v][o]overlay=shortest=1,fade=t=in:st=0:d=0.3,fade=t=out:st=%.2f:d=0.3,format=yuv420p" % (dur - 0.9, dur - 0.3),
         "-t", dur, "-r", FPS, "-c:v", "libx264", "-crf", "14", "-preset", "fast", out])


SEGS = [
    ("EARTHSIEGE", "1994", "The original Herc campaign", [("still", "es1_vehicles", 3.0), ("clip", "dm_1920x1080", 1.3, 8.3)]),
    ("BATTLEDROME", "1995", "Arena duels with the Herc pilots", [("still", "bd_vehicles", 3.0), ("clip", "bd", 3.5, 10.0)]),
    ("EARTHSIEGE 2", "1996", "The Cybrid war: bigger Hercs, new terrain", [("still", "es2_vehicles", 3.0), ("clip", "es2", 1.3, 8.3)]),
    ("STARSIEGE", "1999", "Cybrid war in full 3D: tanks, flyers and Hercs", [("still", "starsiege_vehicles", 3.0), ("clip", "ss_1920x1080", 0.5, 7.5)]),
    ("STARSIEGE: TRIBES", "1998", "Infantry, jetpacks and capture the flag", [("still", "tribes_vehicles", 1.5), ("still", "tribes_infantry", 1.5), ("clip", "tribes1", 3.3, 7.8)]),
    ("TRIBES 2", "2001", "Huge outdoor maps, vehicles and big bases", [("still", "tribes2_vehicles", 1.5), ("still", "tribes2_infantry", 1.5), ("clip", "ctf_1920x1080", 0.7, 4.9), ("clip", "ctf_1920x1080", 5.8, 8.8)]),
    ("TRIBES: AERIAL ASSAULT", "2002", "More armour, more skies, more maps", [("still", "tribes_aa_infantry", 4.5, False)]),
    ("TRIBES: VENGEANCE", "2004", "The single-player campaign across three eras", [("clip", "veng", 0.7, 9.0)]),
]


def main():
    date = PP.today()
    segs = []
    # title
    t = WORK / "title.png"
    card([("SIEGE ENGINE", 150, AMBER), ("Eight games. One open-source engine.", 52, TEAL),
          ("Earthsiege  Battledrome  Earthsiege 2  Starsiege  Tribes  Tribes 2  Aerial Assault  Vengeance", 30, (190, 230, 230))], t)
    mix = Image.open(ST / "everything_mix.png").convert("RGB")
    dark = Image.blend(mix, Image.new("RGB", mix.size, BG), 0.8)
    dark.save(WORK / "title_bg.png")
    t_ov = Image.open(t).convert("RGB")
    comp = Image.blend(dark, t_ov, 0.0)
    comp = Image.composite(t_ov, dark, Image.eval(t_ov.convert("L"), lambda v: 255 if v > 40 else 0))
    comp.save(WORK / "title_final.png")
    p = WORK / "title.mp4"
    still_part(str(WORK / "title_final.png"), 5.0, p)
    q = WORK / "title_f.mp4"
    run(["-i", p, "-vf", "fade=t=in:st=0:d=0.5,fade=t=out:st=4.5:d=0.5", "-c:v", "libx264", "-crf", "14", "-preset", "fast", q])
    segs.append((q, 5.0))
    for i, (name, year, line, parts) in enumerate(SEGS):
        files = []
        dur = 0.0
        for j, pt in enumerate(parts):
            f = WORK / ("s%d_%d.mp4" % (i, j))
            if pt[0] == "still":
                zi = pt[3] if len(pt) > 3 else (j % 2 == 0)
                still_part(str(ST / (pt[1] + ".png")), pt[2], f, zi)
                dur += pt[2]
            else:
                clip_part(pt[1], pt[2], pt[3], f)
                dur += pt[3] - pt[2]
            files.append(f)
        cat = WORK / ("s%d_cat.mp4" % i)
        concat(files, cat)
        ov = WORK / ("s%d_ov.png" % i)
        lower_third(name, year, line, ov)
        out = WORK / ("s%d.mp4" % i)
        overlay_seg(cat, ov, out, dur)
        segs.append((out, dur))
        print("seg", name, round(dur, 1))
    # finale
    fi = WORK / "fin_still.mp4"
    still_part(str(ST / "everything_mix.png"), 3.0, fi, True)
    fc = WORK / "fin_clip.mp4"
    clip_part("finale", 0.7, 9.2, fc)
    fcat = WORK / "fin_cat.mp4"
    concat([fi, fc], fcat)
    ov = WORK / "fin_ov.png"
    lower_third("EVERY GAME, ONE BATTLEFIELD", "Varuna's Fall", "Hercs, Cybrids, tanks, flyers and armour fighting together", ov)
    fo = WORK / "fin.mp4"
    overlay_seg(fcat, ov, fo, 11.5)
    segs.append((fo, 11.5))
    # end card
    e = WORK / "end.png"
    card([("Free & open source", 90, AMBER), ("Bring your own discs", 58, TEAL), (PP.REPO_URL, 48, (255, 255, 255)),
          ("", 30, TEAL), (PP.KOFI_URL, 30, TEAL), ("Unofficial fan project; not affiliated with the rights holders.", 26, (150, 190, 190))], e)
    ep = WORK / "end_raw.mp4"
    still_part(str(e), 7.0, ep, True)
    ef = WORK / "end_f.mp4"
    run(["-i", ep, "-vf", "fade=t=in:st=0:d=0.5,fade=t=out:st=6.2:d=0.8", "-c:v", "libx264", "-crf", "14", "-preset", "fast", ef])
    segs.append((ef, 7.0))
    total = sum(d for _, d in segs)
    silent = WORK / "silent.mp4"
    concat([s for s, _ in segs], silent)
    final = OUT / ("%s_promo.mp4" % date)
    run(["-i", silent, "-i", MUSIC, "-filter_complex", "[1:a]atrim=0:%.2f,afade=t=in:st=0:d=1.5,afade=t=out:st=%.2f:d=3,aresample=48000[a]" % (total, total - 3),
         "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-crf", "18", "-preset", "slow", "-pix_fmt", "yuv420p", "-r", FPS, "-c:a", "aac", "-b:a", "192k",
         "-movflags", "+faststart", "-t", total, final])
    vert = OUT / ("%s_promo_vertical.mp4" % date)
    run(["-i", final, "-filter_complex",
         "[0:v]split[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=30:5,eq=brightness=-0.15[bg];"
         "[b]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]",
         "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-r", FPS, "-c:a", "copy", "-movflags", "+faststart", vert])
    # contact sheet: one frame per 6 s
    n = int(total // 6) + 1
    frames = []
    for k in range(n):
        f = WORK / ("cs%02d.png" % k)
        run(["-ss", min(k * 6 + 2, total - 0.5), "-i", final, "-frames:v", 1, "-vf", "scale=480:270", f])
        frames.append(f)
    cols = 5
    rows = (n + cols - 1) // cols
    sheet = Image.new("RGB", (480 * cols, 270 * rows))
    dr = ImageDraw.Draw(sheet)
    for k, f in enumerate(frames):
        sheet.paste(Image.open(f), ((k % cols) * 480, (k // cols) * 270))
        dr.text(((k % cols) * 480 + 6, (k // cols) * 270 + 4), "%ds" % (k * 6 + 2), fill=(255, 255, 0))
    sheet.save(OUT / ("%s_promo_contact_sheet.jpg" % date), quality=85)
    print("total", total, final, vert)


if __name__ == "__main__":
    main()
