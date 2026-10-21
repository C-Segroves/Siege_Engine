"""compose_promo2.py <video> ; video = choose | tribes. Builds media/videos/<date>_<slug>{,_vertical}.mp4 + contact sheet.

Needs the raw clips (media/clips, see render_seg.py) and the music (media/music).
build() is shared with compose_promo3.py.
"""
import pathlib, sys
import promo_paths as PP
from PIL import Image, ImageDraw, ImageFont
OUT = pathlib.Path(PP.VIDEOS)
FONT = PP.font_path()
AMBER = (255, 222, 0); TEAL = (173, 255, 250); BG = (4, 18, 22)
W, H, FPS = 1920, 1080, 60
DATE = PP.today()


def run(args):
    PP.run_ffmpeg(args)


def font(sz):
    return ImageFont.truetype(FONT, sz)


def lower_third(name, tag, line, path):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.rectangle((0, 800, 1250, 1010), fill=(4, 28, 32, 205)); d.rectangle((0, 800, 12, 1010), fill=AMBER + (255,))
    d.text((60, 820), name, font=font(74), fill=AMBER)
    d.text((64, 910), tag, font=font(40), fill=TEAL)
    d.text((64, 958), line, font=font(34), fill=(220, 245, 245))
    im.save(path)


def card(lines, path):
    im = Image.new("RGB", (W, H), BG); d = ImageDraw.Draw(im); y = 300
    for txt, sz, col in lines:
        w = d.textlength(txt, font=font(sz)); d.text(((W - w) / 2, y), txt, font=font(sz), fill=col); y += int(sz * 1.5)
    im.save(path)


def clip_part(tag, t0, t1, out, crop=None, speed=1.0):
    vf = ""
    if crop:  # crop = (x0,y0,x1,y1,x0b,y0b,x1b,y1b) animated linear zoom from box a to box b over the part
        w, h, x0, y0, x1, y1 = crop; dur = t1 - t0
        vf += "crop=w=%d:h=%d:x='%f+(%f)*t/%f':y='%f+(%f)*t/%f'," % (w, h, x0, x1 - x0, dur, y0, y1 - y0, dur)
    vf += "scale=%d:%d:flags=lanczos,setsar=1,fps=%d,format=yuv420p" % (W, H, FPS)
    run(["-ss", t0, "-i", PP.clip(tag), "-t", t1 - t0, "-vf", vf, "-an", "-c:v", "libx264", "-crf", "14", "-preset", "fast", out])


def concat(parts, out, work):
    lst = work / "list.txt"
    lst.write_text("".join("file '%s'\n" % str(p).replace("\\", "/") for p in parts), encoding="utf-8")
    run(["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", out])


def overlay_seg(src, ov, out, dur, fade_in=0.3, fade_out=0.3):
    run(["-i", src, "-loop", "1", "-i", ov, "-filter_complex",
         "[1:v]format=rgba,fade=t=in:st=0.3:d=0.5:alpha=1,fade=t=out:st=%.2f:d=0.5:alpha=1[o];[0:v][o]overlay=shortest=1,format=yuv420p" % (min(dur, 4.2) - 0.9),
         "-t", dur, "-r", FPS, "-c:v", "libx264", "-crf", "14", "-preset", "fast", out])


def build(slug, segs, music, title, end_extra):
    """segs: [(lower third (name, tag, line) or None, [parts])] parts: (clip, t0, t1[, crop])"""
    work = pathlib.Path(PP.work("promo_" + slug)); work.mkdir(parents=True, exist_ok=True)
    out_segs = []
    for i, (lt, parts) in enumerate(segs):
        files = []; dur = 0.0
        for j, p in enumerate(parts):
            f = work / ("s%d_%d.mp4" % (i, j))
            clip_part(p[0], p[1], p[2], f, p[3] if len(p) > 3 else None)
            files.append(f); dur += p[2] - p[1]
        cat = work / ("s%d_cat.mp4" % i); concat(files, cat, work)
        if lt:
            ov = work / ("s%d_ov.png" % i); lower_third(*lt, ov)
            o = work / ("s%d.mp4" % i); overlay_seg(cat, ov, o, dur)
        else:
            o = cat
        out_segs.append((o, dur)); print("seg", i, round(dur, 1))
    e = work / "end.png"
    card([("Siege Engine", 120, AMBER), ("free, open source. Bring your own discs.", 56, TEAL), ("", 20, TEAL),
          (PP.REPO_URL, 48, (255, 255, 255)), (PP.KOFI_URL, 40, TEAL), ("", 20, TEAL),
          ("Unofficial fan project; not affiliated with the rights holders.", 24, (150, 190, 190))], e)
    ep = work / "end_raw.mp4"
    n = int(6.0 * FPS)
    run(["-loop", "1", "-i", e, "-vf", "scale=3840:-1,zoompan=z='min(1.0+0.0005*on,1.06)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=%d:s=%dx%d:fps=%d,format=yuv420p,fade=t=in:st=0:d=0.5,fade=t=out:st=5.2:d=0.8" % (n, W, H, FPS),
         "-frames:v", n, "-c:v", "libx264", "-crf", "14", "-preset", "fast", "-r", FPS, ep])
    out_segs.append((ep, 6.0))
    total = sum(d for _, d in out_segs)
    silent = work / "silent.mp4"
    # video fades: in at start; segment boundaries are hard cuts on the music
    concat([s for s, _ in out_segs], silent, work)
    OUT.mkdir(parents=True, exist_ok=True)
    final = OUT / ("%s_%s.mp4" % (DATE, slug))
    run(["-i", silent, "-i", music, "-filter_complex",
         "[0:v]fade=t=in:st=0:d=0.5,format=yuv420p[v];[1:a]atrim=%.2f:%.2f,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=1.2,afade=t=out:st=%.2f:d=2.5,aresample=48000[a]" % (title, title + total, total - 2.5),
         "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "18", "-preset", "slow", "-pix_fmt", "yuv420p", "-r", FPS, "-c:a", "aac", "-b:a", "192k",
         "-movflags", "+faststart", "-t", total, final])
    vert = OUT / ("%s_%s_vertical.mp4" % (DATE, slug))
    run(["-i", final, "-filter_complex",
         "[0:v]split[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=30:5,eq=brightness=-0.15[bg];"
         "[b]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]",
         "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-r", FPS, "-c:a", "copy", "-movflags", "+faststart", vert])
    nf = int(total // 4) + 1
    frames = []
    for k in range(nf):
        f = work / ("cs%02d.png" % k)
        run(["-ss", min(k * 4 + 1.5, total - 0.5), "-i", final, "-frames:v", 1, "-vf", "scale=480:270", f]); frames.append(f)
    cols = 5; rows = (nf + cols - 1) // cols
    sheet = Image.new("RGB", (480 * cols, 270 * rows)); dr = ImageDraw.Draw(sheet)
    for k, f in enumerate(frames):
        sheet.paste(Image.open(f), ((k % cols) * 480, (k // cols) * 270)); dr.text(((k % cols) * 480 + 6, (k // cols) * 270 + 4), "%.1fs" % (k * 4 + 1.5), fill=(255, 255, 0))
    sheet.save(OUT / ("%s_%s_contact_sheet.jpg" % (DATE, slug)), quality=85)
    print("total", total, final, vert)


Z1 = (760, 428, 548, 182, 566, 190)
Z2 = (760, 428, 566, 190, 548, 182)

if __name__ == "__main__":
    which = sys.argv[1]
    if which == "choose":
        segs = [
            (("CHOOSE YOUR OPERATOR", "The new squad lobby", "Your team on a 3D carousel: soldiers or vehicles, one spotlight"),
             [("choose", 1.4, 4.4), ("choose", 4.4, 9.9, Z1), ("choose", 9.9, 13.0, Z2), ("choose", 13.85, 17.6, Z1), ("choose", 17.6, 19.8)]),
            (("OPERATOR SETUP", "Slots, store and equipping", "Three loadout slots, a store, a live armour preview"),
             [("choose", 20.6, 24.0), ("choose", 24.0, 30.0), ("choose", 31.0, 36.6)]),
        ]
        build("choose_your_operator", segs, PP.music("machine_liturgy"), 0.0, "")
    elif which in ("tribes", "tribes_v2"):
        v2 = which == "tribes_v2"
        segs = [
            (("TWO MORE TRIBES JOIN", "Aerial Assault", "Training missions, scouts and transports, waves of Bioderm"),
             [("aat2", 3.5, 8.0), ("aav_scout", 2.5, 6.0), ("aav_trans", 3.0, 6.5), ("aa_wave", 3.9, 9.9)]),
            (("CLOAKING PACK", "Tribes 2 light armour", "Turn nearly invisible to sensors and turrets"),
             [("cloak_v2", 1.95, 6.95)]) if v2 else
            (("COMING THROUGH THE SHIMMER", "Cloaking pack", "Walk past unseen: the shared cloak, plain to cloaked"),
             [("cloak", 2.0, 7.0)]),
            (("TRIBES: VENGEANCE", "Campaign missions, NPC voices and subtitles", "Characters, jetpacks and a story told over the radio"),
             [("tvt3", 3.5, 9.0), ("tvu11", 4.0, 9.0), ("tv17", 3.2, 7.7)]),
        ]
        build("two_more_tribes_v2" if v2 else "two_more_tribes", segs, PP.music("ashes_of_varuna"), 0.0, "")
