"""Edit the social clips into media/videos/<date>_social{,_vertical}.mp4 (+ contact sheet via sheet_final.py).
usage: python tools/promo/compose_social.py [landscape|vertical|all]   (ffmpeg only writes files; nothing is played)
"""
import json, pathlib, re, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import promo_paths as PP

WORK = pathlib.Path(PP.work("social"))
DATE = PP.today()
OUT = pathlib.Path(PP.VIDEOS)
MUSIC = pathlib.Path(PP.MUSIC) / "machine_liturgy.wav"
FONT = PP.font_path()
FPS = 60
XFADE = 0.25
SIZES = {"landscape": (1920, 1080), "vertical": (1080, 1920)}
TEAL = (66, 229, 244)
TEAL_BRIGHT = (173, 255, 250)
AMBER = (255, 222, 0)
TEXT = (226, 240, 240)
BG = (4, 12, 14)
VERT_TOP = 560          # top of the gameplay band in the vertical cut
REPO = PP.REPO_URL

# clip, from, to (s in the AVI), caption (headline, sub) or None, options
SHOTS = [
    {"card": "title", "len": 3.0},
    {"clip": "menus", "from": 1.2, "to": 3.8, "mute": True, "cap": ("YOUR LIBRARY", "Import your own discs; every installed game shows up"),
     "vcrop": (0, 0, 1300, 731)},
    {"clip": "menus", "from": 5.3, "to": 8.9, "mute": True, "cap": ("HOST A LAN GAME", "Each map offers its original game modes"),
     "vcrop": (0, 0, 1300, 731)},
    {"clip": "menus", "from": 11.4, "to": 14.6, "mute": True, "cap": ("TEAMS & BOTS", "Infantry bots and AI Hercs fill the teams")},
    {"clip": "ctf", "from": 0.75, "to": 4.3, "cap": ("CAPTURE THE FLAG", "Tribes 2 - Katabatic: a bot grabs the enemy flag")},
    {"clip": "ctf", "from": 5.9, "to": 8.8, "cap": ("SOLDIERS & HERCS", "Infantry and Hercs on the same battlefield")},
    {"clip": "dm", "from": 1.9, "to": 6.0, "cap": ("TEAM DEATHMATCH", "Earthsiege desert - the original cockpit")},
    {"clip": "dm", "from": 6.3, "to": 10.2, "cap": ("CHASE VIEW", "Same fight, third person")},
    {"clip": "cmdmap", "from": 2.0, "to": 7.4, "zoom": (0, 0, 1280, 720), "smooth": True, "cap": ("COMMAND MAP", "Pick a spot, order your wingmen")},
    {"clip": "missile", "from": 1.5, "to": 2.5, "cap_cont": True, "cap": ("MISSILE CAM", "Earthsiege EO missile, live on the MFD")},
    {"clip": "missile", "from": 2.5, "to": 3.85, "zoom": (560, 640, 1160, 978), "cap": ("MISSILE CAM", "Earthsiege EO missile, live on the MFD"), "cap_hold": True},
    {"clip": "ss", "from": 2.0, "to": 8.0, "cap": ("STARSIEGE", "Deathmatch on a Starsiege map, Hercs from every game")},
    {"card": "end", "len": 4.5},
]


def run(args):
    return PP.run_ffmpeg(args, quiet=False)


def font(size, style="Bold"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(style)      # bahnschrift is a variable font; others have no named variations
    except (OSError, AttributeError, ValueError):
        pass
    return f


def tw(d, s, f):
    b = d.textbbox((0, 0), s, font=f)
    return b[2] - b[0]


def centered(d, w, y, s, f, fill):
    d.text(((w - tw(d, s, f)) // 2, y), s, font=f, fill=fill)
    b = d.textbbox((0, 0), s, font=f)
    return b[3]


def avi(clip):
    return pathlib.Path(PP.clip(clip + "_1920x1080"))


# ------------------------------------------------------------------ overlays

def caption_png(head, sub, o):
    w, h = SIZES[o]
    v = o == "vertical"
    fh, fs = (font(76), font(46, "SemiBold")) if v else (font(64), font(40, "SemiBold"))
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad, bar, gap = 26, 12, 12
    maxw = w - 2 * 60 - 2 * pad - bar
    words, lines, cur = sub.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if tw(d, t, fs) > maxw and cur:
            lines.append(cur)
            cur = wd
        else:
            cur = t
    lines.append(cur)
    hh = d.textbbox((0, 0), head, font=fh)[3]
    sh = d.textbbox((0, 0), "Ag", font=fs)[3] + 8
    ph = pad + hh + gap + sh * len(lines) + pad - 8
    pw = max([tw(d, head, fh)] + [tw(d, l, fs) for l in lines]) + 2 * pad + bar
    if v:
        x0, y0 = (w - pw) // 2, VERT_TOP + 608 + 70
    else:
        x0, y0 = 70, h - 80 - ph
    d.rounded_rectangle((x0, y0, x0 + pw, y0 + ph), 10, fill=BG + (215,), outline=TEAL + (200,), width=2)
    d.rectangle((x0 + 2, y0 + 10, x0 + 2 + bar, y0 + ph - 10), fill=AMBER + (255,))
    tx = x0 + bar + pad
    d.text((tx, y0 + pad - 8), head, font=fh, fill=AMBER + (255,))
    y = y0 + pad + hh + gap
    for l in lines:
        d.text((tx, y), l, font=fs, fill=TEXT + (255,))
        y += sh
    p = WORK / ("cap_%s_%s_%s.png" % (o, re.sub(r"\W", "", head), re.sub(r"\W", "", sub)[:20]))
    img.save(p)
    return p


def brand_png(o):
    w, h = SIZES[o]
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if o == "vertical":
        d = ImageDraw.Draw(img)
        y = VERT_TOP - 250
        y += centered(d, w, y, "SIEGE ENGINE", font(96), AMBER + (255,)) + 24
        d.line(((w - 420) // 2, y, (w + 420) // 2, y), fill=TEAL + (255,), width=5)
        centered(d, w, y + 26, "Earthsiege · Starsiege · Tribes", font(44, "SemiBold"), TEAL_BRIGHT + (255,))
    p = WORK / ("brand_%s.png" % o)
    img.save(p)
    return p


def backdrop(o, clip, at, darken):
    w, h = SIZES[o]
    f = WORK / ("bg_%s_%.1f.png" % (clip, at))
    run(["-ss", "%.2f" % at, "-i", str(avi(clip)), "-frames:v", "1", str(f)])
    img = Image.open(f).convert("RGB")
    s = max(w / img.width, h / img.height)
    img = img.resize((int(img.width * s) + 1, int(img.height * s) + 1))
    l, t = (img.width - w) // 2, (img.height - h) // 2
    img = img.crop((l, t, l + w, t + h)).filter(ImageFilter.GaussianBlur(14))
    return Image.blend(img, Image.new("RGB", (w, h), BG), darken)


def title_png(o):
    w, h = SIZES[o]
    v = o == "vertical"
    img = backdrop(o, "ss", 5.2, 0.55)
    d = ImageDraw.Draw(img)
    y = 700 if v else 330
    y += centered(d, w, y, "SIEGE ENGINE", font(150 if v else 170), AMBER) + 44
    d.line(((w - 560) // 2, y, (w + 560) // 2, y), fill=TEAL, width=6)
    y += 50
    y += centered(d, w, y, "Earthsiege · Starsiege · Tribes", font(64 if v else 66, "SemiBold"), TEAL_BRIGHT) + 24
    centered(d, w, y, "rebuilt in Godot, from your own discs", font(52 if v else 50, "SemiBold"), TEXT)
    p = WORK / ("title_%s.png" % o)
    img.save(p)
    return p


def end_png(o):
    w, h = SIZES[o]
    v = o == "vertical"
    img = backdrop(o, "dm", 8.8, 0.7)
    d = ImageDraw.Draw(img)
    y = 620 if v else 250
    y += centered(d, w, y, "SIEGE ENGINE", font(130 if v else 140), AMBER) + 40
    d.line(((w - 520) // 2, y, (w + 520) // 2, y), fill=TEAL, width=6)
    y += 46
    if v:
        y += centered(d, w, y, "Free & open source", font(62, "SemiBold"), TEXT) + 18
        y += centered(d, w, y, "bring your own discs", font(62, "SemiBold"), TEXT) + 70
        y += centered(d, w, y, "github.com/C-Segroves/", font(58), TEAL_BRIGHT) + 12
        y += centered(d, w, y, "Siege_Engine", font(58), TEAL_BRIGHT) + 60
    else:
        y += centered(d, w, y, "Free & open source — bring your own discs", font(60, "SemiBold"), TEXT) + 60
        y += centered(d, w, y, REPO, font(66), TEAL_BRIGHT) + 60
    y += centered(d, w, y, "ko-fi.com/csegroves", font(34, "SemiBold"), (150, 200, 200)) + 26
    centered(d, w, h - (220 if v else 70), "Unofficial fan project; not affiliated with the rights holders.",
             font(30 if v else 28, "Regular"), (160, 175, 175))
    p = WORK / ("end_%s.png" % o)
    img.save(p)
    return p


# ------------------------------------------------------------------ segments

def enc(n):
    return ["-c:v", "libx264", "-preset", "medium", "-crf", "14", "-pix_fmt", "yuv420p", "-r", str(FPS),
            "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", "-t", "%.3f" % n]


def card_seg(png, n, o, tag):
    out = WORK / ("seg_%s_%s.mkv" % (o, tag))
    w, h = SIZES[o]
    fade = "fade=in:st=0:d=0.5" if tag == "title" else "fade=out:st=%.2f:d=0.8" % (n - 0.8)
    run(["-loop", "1", "-framerate", str(FPS), "-t", "%.3f" % n, "-i", str(png),
         "-f", "lavfi", "-t", "%.3f" % n, "-i", "anullsrc=r=48000:cl=stereo",
         "-filter_complex", "[0:v]scale=%d:%d,zoompan=z='1+0.03*on/%d':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=%dx%d:fps=%d,%s,format=yuv420p[v]"
         % (w * 2, h * 2, int(n * FPS), w, h, FPS, fade),
         "-map", "[v]", "-map", "1:a"] + enc(n) + [str(out)])
    return out


def game_seg(i, s, o):
    out = WORK / ("seg_%s_%02d.mkv" % (o, i))
    n = s["to"] - s["from"]
    w, h = SIZES[o]
    base = "[0:v]trim=start=%.3f:duration=%.3f,setpts=PTS-STARTPTS,fps=%d" % (s["from"], n, FPS)
    if "zoom" in s:
        x0, y0, x1, y1 = s["zoom"]
        base += ",crop=%d:%d:%d:%d,scale=1920:1080:flags=%s" % (x1 - x0, y1 - y0, x0, y0, "lanczos" if s.get("smooth") else "neighbor")
    if o == "landscape":
        vf = base + ",scale=1920:1080[v0]"
    else:
        crop = s.get("vcrop")
        fg = base + (",crop=%d:%d:%d:%d" % (crop[2] - crop[0], crop[3] - crop[1], crop[0], crop[1]) if crop else "")
        vf = (base + ",scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=30:2,"
              "eq=brightness=-0.25:saturation=0.7[bg];" + fg + ",scale=1080:-2:flags=lanczos[fg];[bg][fg]overlay=0:%d[v0]" % VERT_TOP)
    inputs = ["-i", str(avi(s["clip"]))]
    last = "[v0]"
    k = 1
    if s.get("cap"):
        inputs += ["-loop", "1", "-framerate", str(FPS), "-t", "%.3f" % n, "-i", str(caption_png(*s["cap"], o))]
        fin = "" if s.get("cap_hold") else "fade=in:st=0.15:d=0.3:alpha=1,"
        fout = "null" if s.get("cap_cont") else "fade=out:st=%.2f:d=0.3:alpha=1" % (n - 0.45)
        vf += ";[1:v]format=rgba,%s%s[c];%s[c]overlay=0:0[v1]" % (fin, fout, last)
        last = "[v1]"
        k = 2
    inputs += ["-loop", "1", "-framerate", str(FPS), "-t", "%.3f" % n, "-i", str(brand_png(o))]
    vf += ";[%d:v]format=rgba[br];%s[br]overlay=0:0,format=yuv420p[v]" % (k, last)
    if s.get("mute"):
        af = "anullsrc=r=48000:cl=stereo,atrim=duration=%.3f[a]" % n
    else:
        af = ("[0:a]atrim=start=%.3f:duration=%.3f,asetpts=PTS-STARTPTS,aresample=48000,aformat=channel_layouts=stereo,"
              "volume=0.8,afade=in:d=0.05,afade=out:st=%.3f:d=0.15[a]" % (s["from"], n, n - 0.15))
    run(inputs + ["-filter_complex", vf + ";" + af, "-map", "[v]", "-map", "[a]"] + enc(n) + [str(out)])
    return out, n


def assemble(o):
    segs, lens = [], []
    for i, s in enumerate(SHOTS):
        if "card" in s:
            png = title_png(o) if s["card"] == "title" else end_png(o)
            segs.append(card_seg(png, s["len"], o, s["card"]))
            lens.append(s["len"])
        else:
            p, n = game_seg(i, s, o)
            segs.append(p)
            lens.append(n)
    inputs, vf, af = [], [], []
    for p in segs:
        inputs += ["-i", str(p)]
    vprev, aprev, t = "[0:v]", "[0:a]", lens[0]
    for i in range(1, len(segs)):
        off = t - XFADE
        vf.append("%s[%d:v]xfade=transition=fade:duration=%.3f:offset=%.3f[vx%d]" % (vprev, i, XFADE, off, i))
        af.append("%s[%d:a]acrossfade=d=%.3f[ax%d]" % (aprev, i, XFADE, i))
        vprev, aprev, t = "[vx%d]" % i, "[ax%d]" % i, off + lens[i]
    seq = WORK / ("seq_%s.mkv" % o)
    run(inputs + ["-filter_complex", ";".join(vf + af), "-map", vprev, "-map", aprev] + enc(t) + [str(seq)])
    return finish(seq, t, o)


def finish(seq, total, o):
    music = ("[1:a]atrim=duration=%.3f,aresample=48000,aformat=channel_layouts=stereo,loudnorm=I=-17:TP=-2,"
             "afade=in:d=0.5,afade=out:st=%.3f:d=2.5[m]" % (total, total - 2.5))
    duck = "[0:a]asplit[sfx][key];[m][key]sidechaincompress=threshold=0.06:ratio=3:attack=30:release=350[md]"
    mixed = "[sfx][md]amix=inputs=2:weights='0.9 1':normalize=0[mx]"
    base = music + ";" + duck + ";" + mixed
    probe = run(["-i", str(seq), "-i", str(MUSIC), "-filter_complex",
                 base + ";[mx]loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json[o]", "-map", "[o]", "-f", "null", "-"])
    m = json.loads(probe[probe.rindex("{"):probe.rindex("}") + 1])
    ln = ("loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true"
          % (m["input_i"], m["input_tp"], m["input_lra"], m["input_thresh"], m["target_offset"]))
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / ("%s_social%s.mp4" % (DATE, "" if o == "landscape" else "_vertical"))
    run(["-i", str(seq), "-i", str(MUSIC), "-filter_complex", base + ";[mx]" + ln + ",aresample=48000[o]",
         "-map", "0:v", "-map", "[o]", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-profile:v", "high",
         "-pix_fmt", "yuv420p", "-r", str(FPS), "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
         "-movflags", "+faststart", "-t", "%.3f" % total, str(out)])
    print(o, "->", out, "%.2f s" % total)
    return out


if __name__ == "__main__":
    WORK.mkdir(parents=True, exist_ok=True)
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    for o in SIZES:
        if what in (o, "all"):
            assemble(o)
