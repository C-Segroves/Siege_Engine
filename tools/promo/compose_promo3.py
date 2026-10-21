"""compose_promo3.py : promo video 2 (Varuna's Fall: call it in). Reuses compose_promo2.build."""
import promo_paths as PP
import compose_promo2 as C

_orig = C.clip_part

def clip_part(tag, t0, t1, out, crop=None, speed=1.0):
    if crop == "panel":   # the command map: the panel is cropped and centred on a blurred copy of the frame
        fc = ("[0:v]split[a][b];[a]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,boxblur=30:5,eq=brightness=-0.2[bg];"
              "[b]crop=1300:1010:0:0,scale=-2:780[fg];[bg][fg]overlay=(W-w)/2:8,scale=%d:%d,setsar=1,fps=%d,format=yuv420p[v]" % (C.W, C.H, C.W, C.H, C.W, C.H, C.FPS))
        C.run(["-ss", t0, "-i", PP.clip(tag), "-t", t1 - t0, "-filter_complex", fc, "-map", "[v]", "-an",
               "-c:v", "libx264", "-crf", "14", "-preset", "fast", out])
    else:
        _orig(tag, t0, t1, out, crop, speed)

C.clip_part = clip_part

segs = [
    (("VARUNA'S FALL", "Extraction raid: the intro transport", "It flies you in over the mountains and banks onto the drop zone"),
     [("c_intro", 9.0, 13.0)]),
    (("TARGETING LASER", "Paint a spot to call it in", "Green means clear; red refuses, with the reason"),
     [("c_laser", 11.0, 14.8), ("c_laser", 17.0, 19.2)]),
    (("ORBITAL DROP", "Armour pods and temporary stations from orbit", "A pod falls, impacts, and leaves a crate; stations land the same way"),
     [("c_pod", 10.8, 13.8), ("c_pod", 23.1, 26.1)]),
    (("VEHICLE DELIVERY", "A dropship brings your Herc", "Slung under the transport, released just above the ground"),
     [("c_dropship", 11.5, 17.0)]),
    (("AIR SUPPORT", "Bombing run and attack craft", "A bomber lays a stick of bombs; a Shrike strafes the target"),
     [("c_bomb", 13.0, 17.8), ("c_strafe", 13.7, 16.4)]),
    (("COMMAND MAP", "Order a call-in from the map", "Refused where a unit stands, accepted on open ground"),
     [("c_map", 10.4, 12.4, "panel"), ("c_map", 14.0, 16.5, "panel")]),
    (("LASER RIFLE", "Scope zoom, 2x to 20x", "Step the magnification and watch the soldiers run"),
     [("c_scope", 14.6, 18.6)]),
]
if __name__ == "__main__":
    C.build("call_it_in", segs, PP.music("orbital_drop"), 0.0, "")
