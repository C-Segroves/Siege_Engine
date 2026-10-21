"""sheet_final.py <landscape|vertical> : contact sheet of a compose_social.py video, next to it."""
import sys
from PIL import Image, ImageDraw
import compose_social as C
o = sys.argv[1]
src = C.OUT / ("%s_social%s.mp4" % (C.DATE, "" if o == "landscape" else "_vertical"))
lens = [s.get("len", s.get("to", 0) - s.get("from", 0)) for s in C.SHOTS]
t, mids = 0.0, []
for i, n in enumerate(lens):
    start = t if i == 0 else t - C.XFADE
    mids += [start + n * 0.35, start + n * 0.75]
    t = start + n
ims = []
for k, m in enumerate(mids):
    f = C.WORK / ("cs_%d.png" % k)
    C.run(["-ss", "%.3f" % m, "-i", str(src), "-frames:v", "1", "-vf", "scale=%s" % ("640:-1" if o == "landscape" else "300:-1"), str(f)])
    im = Image.open(f).convert("RGB"); ImageDraw.Draw(im).text((6, 6), "%.1fs" % m, fill=(255, 255, 0)); ims.append(im)
cols = 4 if o == "landscape" else 9
W, H = ims[0].size; rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (W * cols, H * rows), (0, 0, 0))
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * W, (i // cols) * H))
out = C.OUT / ("%s_social%s_contact_sheet.png" % (C.DATE, "" if o == "landscape" else "_vertical")); sheet.save(out); print(out)
