"""sheet.py <video or clip tag> <out.jpg> t1 t2 ... : 3-column contact sheet (640 px wide) of frames at the given seconds."""
import pathlib, sys
from PIL import Image, ImageDraw
import promo_paths as PP

src = sys.argv[1] if pathlib.Path(sys.argv[1]).exists() else PP.clip(sys.argv[1])
out = sys.argv[2]; ts = [float(x) for x in sys.argv[3:]]
tmp = pathlib.Path(PP.work("frames")) / "_s.png"
ims = []
for t in ts:
    PP.run_ffmpeg(["-ss", "%.3f" % t, "-i", src, "-frames:v", "1", "-vf", "scale=640:-1", tmp])
    ims.append((t, Image.open(tmp).copy()))
cols = 3; rows = (len(ims) + 2) // 3
W, H = ims[0][1].size
sh = Image.new("RGB", (W * cols, H * rows))
for i, (t, im) in enumerate(ims):
    ImageDraw.Draw(im).text((6, 6), "%.2f" % t, fill=(255, 255, 0))
    sh.paste(im, ((i % cols) * W, (i // cols) * H))
sh.save(out, quality=85); print(out)
