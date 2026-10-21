"""frames.py <tag> [n] : a contact sheet of n frames between the 'action'/'home' mark and 'end' of a clip.
Writes media/_work/<tag>_sheet.jpg (clip and marks come from media/clips/<date>/<tag>.{mp4,json})."""
import json, pathlib, sys
from PIL import Image, ImageDraw
import promo_paths as PP

tag = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
m = json.loads(pathlib.Path(PP.clip_marks(tag)).read_text())
a = m.get("action", m.get("home", 0)); e = m.get("end", a + 10)
tmp = pathlib.Path(PP.work("frames")) / "_f.png"
ims = []
for i in range(n):
    t = a + (e - a) * i / (n - 1) - (0.05 if i == n - 1 else 0)
    PP.run_ffmpeg(["-ss", "%.3f" % t, "-i", PP.clip(tag), "-frames:v", "1", "-vf", "scale=640:-1", tmp])
    ims.append((t, Image.open(tmp).copy()))
cols = 3; rows = (n + cols - 1) // cols
W, H = ims[0][1].size
sheet = Image.new("RGB", (W * cols, H * rows))
for i, (t, im) in enumerate(ims):
    ImageDraw.Draw(im).text((6, 6), "%.2f" % t, fill=(255, 255, 0))
    sheet.paste(im, ((i % cols) * W, (i // cols) * H))
out = pathlib.Path(PP.work("frames")) / (tag + "_sheet.jpg"); sheet.save(out, quality=85); print(out)
