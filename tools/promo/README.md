# tools/promo

Scripts that capture the game and cut the promo videos, teasers and stills. Everything is written under `media/`
(git-ignored; layout in `media/README.md`). Run them from anywhere: `python tools/promo/<script>.py`.

Needs: Python with Pillow and `imageio-ffmpeg` (ffmpeg comes from it), a Godot 4 console executable in the `GODOT`
environment variable, and the game set up with its content packs (the captures run the real game, `--test-store`).
Optional: `SIEGE_FONT` for another caption font. All paths are in `promo_paths.py`. Godot runs use `--audio-driver Dummy`.

## Make a video

1. Capture raw clips (one scripted segment each) into `media/clips/<today>/<tag>.mp4`:
   `python tools/promo/render_seg.py choose 1920x1080 60 --tag=choose`
   The segment script is a "director" (`*_director.gd`), chosen with the `DRIVER` environment variable:
   `promo2_director.gd` (default: choose, cloak, aa, aa2, train, veng), `promo2c_director.gd` (call-ins on Varuna's Fall:
   intro, laser, pod, dropship, bomb, strafe, map, scope), `social_director.gd` (menus, ctf, dm, missile, cmdmap, riders).
   `boot.gd` loads the director once the game autoloads exist. Check a take: `python tools/promo/frames.py choose 12`.
2. Compose: each `compose_*.py` holds the shot list (clip tag, in/out seconds, lower-third text, music track) and writes
   `media/videos/<today>_<slug>.mp4`, `..._vertical.mp4` and `..._contact_sheet.jpg`:
   - `compose_promo2.py choose` / `tribes` : "Choose your operator", "Two more Tribes join"
   - `compose_promo3.py` : "Varuna's Fall: call it in"
   - `compose_promo.py` : the first promo, "Eight games, one engine" (uses `media/stills/roster`)
   - `compose_social.py [landscape|vertical|all]`, then `sheet_final.py <landscape|vertical>` : the 2026-10-13 social cut
   To make a new video: copy the nearest compose script, change the `segs` list and the slug, and capture any new clips first.
   Compose reads the newest `media/clips/*/<tag>.mp4`; `sheet.py <video|tag> out.jpg t1 t2 ...` makes ad hoc contact sheets.
3. Roster stills (grids for the first promo): `bash tools/promo/stills_all.sh` (or `run_still.py` for one).

## Make a teaser

`python tools/promo/make_teaser.py <post-date> <track> <subject> <source> <start> <duration>`
cuts a vertical 1080x1920 clip with music from `media/music/<track>.mp3` into
`media/teasers/<post-date>_<track>_<subject>.mp4`. The source is a finished video (a name under `media/videos`) or a
raw clip tag; a horizontal source is centred on a blurred copy of itself. Example:
`python tools/promo/make_teaser.py 2026-10-21 machine_liturgy lobby 2026-10-20_choose_your_operator 1.4 15`
Then add the post to `media/social/post_schedule.md`.
