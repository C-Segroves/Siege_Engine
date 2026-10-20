# Cockpit instruments (DBSIM: mechview / panel / pgauge / phdd* / phud / pradar / pmfd / pstatus / alert)

Sections 1-7: Earthsiege 1. Section 8: Earthsiege 2 (the same panel code, grown up). Section 9: which cockpit
every pilotable vehicle gets (Battledrome, Starsiege, Tribes HUDs; best fits). Remake: one
`CockpitDisplay` (`game/games/es1/cockpit/`) draws both from the exported layout and `CockpitSkin` (8.8).

Decoder / exporter / mock-up renderer: `tools/cockpit.py` (`python tools/cockpit.py all` →
`extracted/cockpit/`). Fonts reuse `tools/shell.py` (`read_dfn`, `Font`).
Addresses are DBSIM.EXE VAs. Confidence: **H** = read in code, **M** = code seen, meaning inferred,
**L** = guess from values / looks.

Verification: `extracted/cockpit/mockup/<HERC>.png` (labelled) and `<HERC>_clean.png` draw every decoded
rect plus sample bitmaps/fonts onto DB0+DB1; all 8 Hercs line up with the grey panel cut-outs.
`<HERC>_views.png` shows the 4 views with their ED0..ED3 3D-window regions tinted.

## 1. Coordinate system and per-Herc files

* Panel space is **320×400**: y 0..199 = front view overlay `DB0/<HERC>.DB0`, y 200..399 = look-down
  panel `DB1/<HERC>.DB1` (the GAU header rect is `(0,0,319,399)`). `DB2/<HERC>.DB2` = side view
  (left; the right view is DB2 mirrored - **L**: Earthsiege 2 draws its DB2 as the RIGHT view and mirrors it for
  the left, section 8.9). Palette `DPL/COCKPIT.DPL`. Index 0 = transparent (3D window).
* `<HERC>` is the 8-char file name from the Herc type (`mt+0x56`, mechview ctor 0x21dd4); loaded by
  mechview 0x21fb0: `VUE`, `ED0..ED3`, then panel ctor 0x2c9d8 (`GAU`, cockpit TTM).

### VUE (H layout, M meaning) — loader 0x21fb0
`u32 n (4)`, `n × { s32 x0,y0,x1,y1 (3D viewport, x1/y1 exclusive); s32 cx,cy (= −projection
centre, e.g. −160,−72 → centre 160,72); s32 panX, panY }`. Views: 0 front, 1 look-down, 2 / 3 side
views (pan ±320, i.e. 320 px = 90° if a full turn is 1280 px — **L**), look-down pan (0,197) (pitch, **L**).
Look-down viewports are empty/3 px high (no 3D) except Roadrunner. Defaults when no VUE:
(0,30,319,170, −160,−75) (0x21e19, = MECHVIEW.BND words 6..11).

### ED0..ED3 / EDG edge-table regions (H) — loader 0x24d44
No Dynamix header. `s16 nBands; nBands × {s16 y0, s16 y1}` (full-width rows x 0..319, inclusive),
then `s16 nRuns; nRuns × {s16 y0, s16 nRows, nRows × {s16 xL, s16 xR}}` (one span per scanline,
inclusive). Trailing bytes are ignored (COLOSSUS.ED1 has some). `EDn` = where the 3D world is visible
in view n (window shape). `EDG/ENG_CLP1..4.EDG` = clip shapes for the engine bar (§3.3).

## 2. Panel object and shared resources

Panel ctor `0x2c9d8` (`panel.cpp`): loads GAU via 0x2b5c4 into global `[0x92d3c]`, then builds gauges and
stores them in the panel object: `+0x1dd` indicators, `+0x1e1` engine bar, `+0x1e5` brightness, `+0x1e9` MFD,
`+0x1ed` throttle, `+0x1f1` HUD, `+0x1f5` HDD, `+0x1f9` clock, `+0x203` view message line,
`+0x207` panel message line; weapon gauges are created by the weapons (0xa97c/0xab20/0xabec →
panel helpers 0x2cbbc/0x2cc18/0x2cc74), index = weapon `+0x18 → +7` (hardpoint slot).
Shared resources (0x2aecc): fonts `DFN/CP*.DFN` in globals `0x92d40..0x92d64` =
cpblue, cpgreen, cpred, cpylw, cpon, cppress, cpoff, cpgrey, cpblack, cporange (table 0x92dc4);
cursors (DCI) at 0x92d20; `DBA/PBUTTONS.DBA` at `[0x92d68]`; strings `STR/STRINGS0.STR` (0x2fe84; groups
dumped in `extracted/cockpit/strings0.json`).

### PBUTTONS.DBA (64 bitmaps) — indices used (H unless noted)
| idx | use |
|---|---|
| 0–2 | small 16×9 key caps (L) |
| 3,4,5 | MFD wide option button (normal/pressed/disabled) |
| 6,7,8 | indicator button (LINK/TRACK) states |
| 10/11 … 20/21 | MFD F1..F6 (off/on) ; 22/23, 24/25 = HDD F7, F8 |
| 26 | 2×8 bar cursor (weapon charge bar) |
| 27 | throttle lever marker (GAU `+0x44`) ; 28 alt lever (L) |
| 29–31 / 32–34 | MFD up / down arrows (3 states) |
| 35–42 | HDD diamond scroll pad (up, down, left, right × normal/pressed); 43–50 square-arrow variant |
| 51/52, 53/54 | HDD zoom out / zoom in |
| 55, 56, 57 | weapon status LEDs (2×7): 55 = state `+0xa1`, 56 = `+0x9f/+0xa0`, 57 = selected `+0x9c` (0x38464) |
| 58–60 / 61–63 | small up / down buttons (brightness) |

## 3. GAU — `GAU/<HERC>.GAU` (1700 = 0x6a4 bytes of s32; read whole by 0x2b5c4) (H)

All rects are `x0,y0,x1,y1` (inclusive for drawing). Every section starts with a 16-byte rect whose
first point is the section **origin**; sub-rects are relative to it (origin may be (0,0) and the sub-rects
absolute, e.g. RAPTOR). The file header point (`+0`, always 0,0) is added to every section origin and to
the weapon slots (post-load fixup 0x2c710). The C++ ctor sequence in 0x2b5c4 gives the sub-struct sizes.

| off | size | gauge (ctor) | layout |
|---|---|---|---|
| 0x000 | 0x10 | header | rect (0,0,319,399): +0/+4 global offset |
| 0x010 | 4+9×16 | weapon slots | `s32 count` (≤9; = number of hardpoints: Raptor 4, Herc 8, Colossus 9), `rect slot[9]` absolute |
| 0x0a4 | 0x50 | weapon gauge "ammo/text" (0x373a4, via 0x2cc18) | bounds (replaced by slot rect), `+0x10` label rect, `+0x20` value text rect |
| 0x0f4 | 0x60 | weapon gauge "bar" (0x3700c, via 0x2cbbc) | bounds, `+0x10` label, `+0x20` bar rect, `+0x30` params (2,9), `+0x3c` bar param |
| 0x154 | 0x70 | ECM gauge (0x37810, via 0x2cc74) | bounds, `+0x10` button/LED rect (0,0,9,7), `+0x20` label rect ("ECM", cpred) |
| 0x1c4 | 0x60 | indicators (0x37bd0) | bounds, 5 rects |
| 0x224 | 0x44 | engine bar (0x39818) | bounds, `+0x10` bar rect, `+0x20` type (3/4), `+0x24` ENG_CLP index (0 = none), `+0x28,+0x2c` params |
| 0x268 | 0x70 | brightness (0x38f34) | bounds, `+0x10` up button, `+0x20` down button, `+0x30`,`+0x40` text rects |
| 0x2d8 | 0x110 | MFD (0x39c64) | bounds, 13 button rects `+0x10..+0xe0`, `+0xe0` display rect |
| 0x3e8 | 0x68 | throttle (0x3b0d4) | bounds, `+0x10` lever track, `+0x20` forward LED bar, `+0x30` reverse LED bar, `+0x40` type (1 vertical / 2 horizontal), `+0x44` lever PBUTTONS index (27) |
| 0x450 | 0x6c | HUD (0x34aec) | bounds (3D area), `+0x10` heading tape, `+0x20` pitch slider, `+0x30` s32 x,y screen centre, `+0x38` reticle half-size, `+0x3c` target/text area |
| 0x4bc | 0x188 | HDD (0x3c258) | bounds, `+0x10` screen, `+0x20` map aux rect, `+0x30` damage aux rect, `+0x40` small rect, `+0x50` 15 button rects, `+0x140` 3 wingman LED rects, `+0x170` first arrow-pad PBUTTONS index (35), `+0x174..` misc (0,1,0,0,0) |
| 0x644 | 0x40 | mission clock (0x433cc) | bounds (0), `+0x10` clock text rect, `+0x20` point (TTM anim position? **L**) |
| 0x684 | 0x10 | message line in 3D view (0x2f3d8) | absolute rect (0,100,320,110) |
| 0x694 | 0x10 | panel message line (0x2eb80) | absolute rect (e.g. Herc 84,9,235,18 top strip) |

### 3.1 Weapon gauges (H structure, M meaning)
One per hardpoint, placed in `weapon_slots[slot]` using one of the three templates.
* Label: sub-gauge 0x38335 — weapon name (12 chars from the weapon, `+0x7a`) in **cpgreen**; selected
  (`+0x9c`) → **cpylw** + LED PBUTTONS 57; `+0x9f` → cpylw colour 0x35; LEDs 55/56 for other states;
  no LED → 2×7 rect filled colour 0x3f at label x−? (0x385c7).
* "bar" template (guns/beams, vtables 0x9136a / 0x91496): `+0x20` = horizontal slider 0..256
  (class 0x439d4, cursor PBUTTONS 26); max set from weapon `+0x7b` (beam capacitor cap 960) → shows
  charge / ammo (M).
* "ammo/text" template (vtables 0x913de / 0x9157e — missile racks / grenade, **M**): `+0x20` text field
  (count, or STRINGS0 "OFFLINE").
* ECM: button + label "ECM".

### 3.2 Indicators (0x1c4) — 5 items, labels STRINGS0 group 4: `I, II, III, LINK, TRACK` (H labels, L meaning)
Items 0–2: text lamps (cpylw when on `+0x3c`, cpblue when off); items 3–4: buttons drawn with
PBUTTONS 6+state, text cpon / cppress (0x38d90).

### 3.3 Engine bar (0x224) (H drawing, M meaning)
Value = `mech+0x228 × 1024 / 10000` (0x155b5) — a 0..10000 level starting at 10000 that fluctuates every
update (0x14ee0; random noise + regulation; likely engine/reactor output). Type 3 = horizontal fill bar
(0x31e28: fills `rect` proportionally in colour 0x3f, restores background when shrinking); type 4 =
second bar class 0x3216c, used with an `ENG_CLPn` edge-table clip (non-rectangular fill shape). Params
`+0x28/+0x2c` (53/56, 50/48) are copied into the bar (`+0x2c/+0x30`) — probably colours/thresholds (L).

### 3.4 Brightness (0x268) (M)
Two up/down buttons (PBUTTONS 58–60 / 61–63) and two cpgreen text fields. The value (0..512, shown as
%) dims a green ramp built from base RGB (25,59,23) (`0x93e04..0c`) written into palette entries from
0x50 (0x3933e → 0x27e98) → display/HUD intensity.

### 3.5 Throttle (0x3e8) (H)
LED bars from `THR_LED1.DBA` (vertical, 3 × 8×29) or `THR_LED2.DBA` (horizontal, 3 × 32×2) (type 0 would
be WPN_LED1, not on disc). Range −0x400..+0x400: forward bar `+0x20` uses LED frames [1]/[0], reverse
bar `+0x30` frames [1]/[2] (lit vs. unlit). Bar value = current speed `mech+0x224 ×1024 / max`
(max = DAT speed_forward/reverse), set by 0x155a8 → 0x3b200. The lever marker (PBUTTONS 27) slides along
`+0x10` and is the throttle command (read back with 0x3b250 → `mech+0x226`; mouse-draggable).

### 3.6 HUD (0x450) (H) — drawn in the 3D view, PHUD.BND has the same constants
* Heading tape: `+0x10` rect, `HUDHTICK.DBA` (9 strips 128×8, each 40°, labels 0..340): window ±20°
  (±0x0e38, 1/65536 turn) → 3.2 px/deg.
* Torso-twist slider: rect `+0x10` inset by (15,10)/(−15,+10), `HUDHSLID.DBA` [0] 96×3 track,
  [1]/[2] 32×2 marker, range ±80° (±0x38e3) (0x33968).
* Pitch slider: `+0x20` rect, `HUDVSLID.DBA` [0] 8×29 track, [1]/[2] 8×15 marker, range ±0x1f40 (≈±44°).
* Reticle / target box classes 0x33f1c, 0x3403c, 0x34710 centred on `+0x30` (160,72) ± `+0x38`;
  the same point is the 3D projection centre (0x55bc2).
* Waypoint/target marker on the tape 0x3475c (±20°) with text `"WP n: dddd M."` (0x34800);
  `"[ nn% ]"` text (0x336b0); HUD text font cpblack colour 0x38 at target box + (−3,10).
* `+0x3c` rect = area for target brackets / text (M).

### 3.7 MFD (0x2d8) (H structure)
Buttons 0–5 = mode buttons F1..F6 (PBUTTONS 10..21, labels cpred) selecting the display page drawn in
`display` rect (`+0xe0`); STRINGS0 group 5 gives the labels:
| mode | label | page class |
|---|---|---|
| F1 | STATUS | 0x32f74 (PSTATUS: 5 text lines at y +0,8,21,28,35, x +30/+60, cpred; can show `BASES.DBA`/`FLYERS.DBA` / unit DBA image) |
| F2 | FLASH COMM | 0x35c04 |
| F3 | NAV MAP | 0x36b18 |
| F4 | SCANNER | 0x35298 radar: `RADAR.DBA` 72×46 scope; ranges 30000/80000/120000 (default index 2; PMFD.BND) |
| F5 | TARGET | 0x32f74 (target info, "TARGET:", "STATUS:", "RNG:", "DST:") |
| F6 | MISSILE CAM | 0x360c0 (uses `SMLWLD0..2.DBA` 72-px horizon silhouettes per world type) |
Button 6 = title text field (cpred, e.g. mode name); 7–10 = option buttons (PBUTTONS 3/4/5, labels from
group 5: MODE, MODE, RANGE, TARGET, XMIT…); 11/12 = up/down (PBUTTONS 29–31 / 32–34). Page mapping of
F2/F3 is from label order (M).

### 3.8 HDD — look-down display (0x4bc, "HDDGauge", phdd.cpp) (H structure, M semantics)
* `screen` (+0x10) = main display; two pages: **MAP** (0x3ee58, `ICONS.DBA` unit/nav icons, squad numbers,
  `+0x20` aux rect) and **DAMAGE** (0x42164, `+0x30` aux rect; "STRUCT/INTERN/WEAPON DAMAGE",
  component names and %, PDG diagrams §4). STRINGS0 group 10 = "MAP","DAMAGE".
* Buttons: 0/1 = F7/F8 (PBUTTONS 22–25), 2–5 = scroll pad (PBUTTONS base `+0x170`: 35.. diamond / 43..
  square), 6/7 = zoom out/in (51–54), 8, 9 (title/mode text, hazard-striped bar), 13, 14 = text buttons,
  10–12 = the three **wingman comm windows** (58×51): `STATIC.DBA` noise (5 × 64×51) or the pilot video,
  `wingman_leds` (+0x140) = 1×3 lamp beside each window (transmit indicator, L).
* Wingman commands (STRINGS0 group 0, "ATTACK MY TARGET"…, "RED1..3", "XMIT/CANCEL/EXIT") are issued here.

### 3.9 Clock (0x644) (H)
`"00:00"` mission time string (0xbd504) in cpblue in `+0x10`. Same ctor loads `TTM/<HERC>.TTM`
(cockpit animation, e.g. COLOSSUS.TTM) and `cpwincrk` (window-crack animation).

### 3.10 Message lines (0x684 / 0x694) (H)
Class 0x2eb80 (size 0x469): scrolling radio/system messages; sender prefixes from `STR/SYSTEM.STR`,
`COMMANDR.STR`, `PILOTn.STR` (0x2f1ec). 0x694 = panel strip, 0x684 = line in the 3D view (y 100..110).

## 4. Damage diagrams — `PDG/<UNIT>.PDG` + `DBA/<UNIT>.DBA` (H format, M meaning) — loader 0x30388
`s32 nImages` (3, = entries of the unit DBA: [0] structure/armour view 48×73, [1] internal view,
[2] small 24×37 icon); per image: `s32 ox, oy, w, h` (w,h = true size; ox,oy = placement, L),
`s32 nRegions`, `nRegions × {s32 component, x0, y0, x1, y1, colour (51/54/57 palette index), flag}`.
Component ids index STRINGS0 group 12 (armour: F/R cockpit, L/R weapon bracket, shoulders, torso, legs,
feet) for image 0, group 13 (actuators, sensor, engine, hydraulics, gyro, life support, pilot) for image 1.
Then `s32 nMounts`, `nMounts × 5 s32` (weapon hardpoints on the diagram: x, y, ?, ?, ? — count matches GAU
weapon slots; L). `WEAPONS.PDG`: `s32 12`, `12 × {w, h}` true sizes of `WEAPONS.DBA` icons (0x30288).
Exports: `extracted/cockpit/pdg/*.json|png`.

### 4.1 The target / status picture and its damage colours (H unless noted)
**Where:** the MFD display rect (GAU `+0x2d8+0xe0`, e.g. Raptor `(109,128)-(177,172)`, 69×45), pages
F1 STATUS (own Herc) and F5 TARGET (the selected target), page class PSTATUS (ctor 0x32f74, vtable
0x935fe, update 0x330b4). Text column at x + 30 (`PSTATUS.BND`; the remake uses 26), picture left of it.
**What, by unit kind** (`unit+0x162`, 0x33135):
* 0 = Herc / Cybrid: `DBA/<UNIT>.DBA` image 2 (the small 15..36 × 16..42 front diagram) blitted at the
  display origin + PDG image-2 origin (0x331e2), then each PDG image-2 region recoloured by damage.
* 1 = base: `BASES.DBA[type word unit+0x188→+0]` at (x + 2, bottom − h − 5) (0x334d9); no damage colours.
* 2 = flyer: `FLYERS.DBA[0]` at (x + 2, bottom − h − 5) (0x335ad); no damage colours.
* No target: STRINGS0 "NO TARGET SELECTED" (`0xbd3f0` / `0xbd464`).
**Damage values:** 0x1583c → 0x109bc fills a word array: `[0]` = Herc type, `[1 + i]` = damage of DMG
component i (i < 19) = `accumulated × 256 / hp`, 256 when destroyed (accumulator sign bit).
**Regions → components** (jump table 0x9361c on the region's component id; the region shows the mean):
| region id | components averaged |
|---|---|
| 0 | 0, 1 (front + rear cockpit) |
| 4 / 5 | 4 / 5 (shoulders) |
| 6 | 6 (crotch) |
| 7 / 8 | 7, 9, 11 / 8, 10, 12 (left / right quad + shin + foot) |
| 13 / 14 | 13, 15, 17 / 14, 16, 18 (extra leg parts, Bulldog) |
| others | none (never used by an image-2 region) |
**Colour level** (0x30dc4, region flag 0 — every shipped region): health % = `(256 − damage) × 100 >> 8`;
≥ 90 → ramp 0x36 (green), ≥ 74 → 0x39 (yellow), ≥ 51 → 0x5c (orange), ≥ 1 → 0x33 (red), else 0x3e
(destroyed: dark grey 0x3e/0x3f/0x40). Flag 1 (unused) derives the ramp from the region's own colour.
**Recolour** (0x30818 → 0x308f0): inside the region rect, every pixel in `[region colour, +2]` becomes
`pixel + (new − old)`; regions are applied in order on the same freshly blitted bitmap, so of two regions
on one rect (front / rear cockpit in image 0) the first that changes the colour wins. No flashing, no
range or scan condition in the page code: the picture updates with the page every frame (M). The HDD
DAMAGE diagram (image 0) uses the same colour rule per component.
Remake: `CockpitAssets.diagram` / `make_component_health`, levels in `engine/target_view/damage_levels.gd`.

### 4.2 Remake: other games' targets (`engine/target_view/`, `CockpitTargetImage`)
A target without original art in the host cockpit (any other game's vehicle) is drawn as its live 3D
model in the same spot: `PICTURE_AREA` = display + (1,1), 24×43 (the area the native image-2 origins
use). `TargetView` (a SubViewport with its own world) holds `TargetModelCopy`, a duplicate of the target's
ShapeInstance tree (cells, fixtures, weapon pods) whose node transforms and visibility are copied from
the target at 10 Hz (pose, torso twist, damaged cells), seen by an orthographic camera from the front
three-quarter (30° right, 15° up) framed to fill the area, rendered at 1:1 cockpit pixels without
anti-aliasing. `TargetRampPaint` draws each part only in the three palette shades of its damage level's
ramp (§4.1 levels; key-light shading picks the shade), so the picture uses exactly the colours of the 2D
diagrams. The plain HUD (`hud.gd`: soldiers, vehicles without cockpit data) shows the same view at 160×180,
untextured, each part in three shades of its level's `DamageLevels.COLORS` (`TargetFlatPaint`, the remake's
standard picture). Starsiege's STATUS / TARGET meters keep their own look (`TargetLitPaint`: the shape's own
materials, grey ambient 0.7 (0x522646) and a white light (0x5226dd), no damage tint). Battledrome and Tribes HUDs
had no target picture and get none. Any target with a model is shown, structures and turrets included (one part,
their overall health); an own-game base on the Earthsiege TARGET page shows its BASES.DBA picture (0x334d9; type =
the BASES_<n> shape index, M).
Rendering only runs while the TARGET page (HUD: any target) shows a target.
**Part → component mapping** (`TargetDamageMap`; a part shows its components' worst health):
| pack | mapping | confidence / approximation |
|---|---|---|
| ES1 / ES2 (3Space) | DMG `shape_part` = the shape's cell **slot** (`set_slot_state`): cell meshes of slot s show the components with `shape_part` s (Raptor: 7 cockpit, 9/8 shoulders, 3/4 quads, 1/2 shins, 6/5 feet); other meshes take their node's cells' component (inherited down the node tree); weapon pods on hardpoint n show component `WEAPON n+1`; the rest the first fatal component (front cockpit) | M (slot meaning from the Raptor cells/node layout; COL `node` ids are another numbering and unused) |
| Starsiege (Darkstar) | component `ss_name` = DTS node name without `_` and detail digits (`LeftCalf` = `Left_Calf0`); unnamed nodes inherit; root = first fatal (pelvis / head) | M |
| Battledrome | no DMG decoded: one HULL component colours the whole model | approximation |
| Tribes / Tribes 2 vehicles | one HULL component: whole model | data has only a hull |
Cybrid DMG records carry no component names (only the index layout of §5 gameplay.md).
**LAN:** puppets get component health and cell states from the host's snapshots
(`HercSnapshots.make_damage_block`: one byte per component + one per cell, ~30 bytes, sent only for 1 s
after a change and every 3 s as keepalive) and the weapon trigger bits (snapshot index 13).
**ES2:** the Earthsiege 2 cockpit (section 8) shows its own units' PDG diagrams and every other game's
vehicle as a 3D model in its picture box, in the ES2 damage colours (one colour per level; the 3D model gets
three darkened shades of it, `TargetRampPaint`).

## 5. Pilot comm video — `DBA/PILOTn.DBA`, `PILOTnS.DBA`, `OFS/PILOTn.OFS` (H format, M composition)
Loader 0x3dab4 (`HDDGauge::Couldn't load anim offset/bitmap array`). OFS = `n × {s32 dbaIndex, dx, dy}`.
PILOTn.DBA: 24 face frames (56×59 / 64×60), 3 mouth/shoulder strips, last = torso/background (80×54).
PILOTnS.DBA = short set (6 faces, 1 strip, torso). Composite = torso at its offset (default 0,0) + face
frame + strip at their OFS offsets (faces typically (8,−6), strips (−13,38)), clipped to the 58×51 window.
`extracted/cockpit/pilots/`.

## 6. Other bitmaps (all exported, COCKPIT palette)
`ICONS.DBA` (76: squad digits 1–9, unit icons with heading arrows, nav markers), `CORNERS.DBA`
(alert-box corners/arrows), `*_ALRT.DBA` alert/popup panels (alert.cpp 0x45de8, fonts green6x8 /
red6x8 / title / active / pushed / inactive, `ALERT.DCI` cursor) — dialog contents belong to the alert
modules (GNL/CAL/CTL/HST/PRF/OBJ_ALRT.BND hold their layout numbers; not decoded).

## 7. BND blocks (raw words in `extracted/cockpit/layout/bnd_cockpit.json`)
Not read by the shipping exe (see gameplay.md §7) but they mirror the compiled constants:
PHUD (±3640 tape, ±14563 torso, ±8000 pitch, 15/10 insets, −3/10 text offset), PMFD (30000/80000/120000
radar ranges), PSTATUS (x 30/60, y 0/8/21/28/35), MECHVIEW (default view 0,30,319,170,−160,−75),
PHDDMAP (map scales 50000…5000000), PHDDDAMG, PRADAR, PANEL, PGAUGE.

## Unknown / TODO
* Exact drawing of MFD pages FLASH COMM / NAV MAP / MISSILE CAM and HDD map scaling; radar blip colours.
* Engine-bar quantity name (mech+0x228) and params; GAU `+0x30` params of the bar template; PDG mount fields.
* Indicators I/II/III meaning (ECM level? sensor mode?) and LINK/TRACK actions.
* HDD `small_rect`, clock `+0x20` point, VUE pan units; pilot window composition offsets.


## 8. Earthsiege 2 cockpits (ES2 DBSIM.EXE, Win32, VAs with image base 0x400000)

Decoder `tools/cockpit_es2.py`, exporter `tools/export_es2_cockpit.py` (importer step `cockpit` of
`tools/siege_games/es2.py`, after `units`) -> `gamedata/es2/cockpit/`. The exporter checks the code constants
it relies on against DBSIM.EXE (`cockpit_es2.EVIDENCE`). Class names come from the exe's RTTI strings
(`EnergyWeaponGauge`, `ProjectileWeaponGauge`, `WeaponRangeGauge`, `EnergyPoolGauge`, `ShieldsGauge`,
`MFDGauge`, `ThrottleGauge`, `HUDGauge`, `HDDGauge`, `HUDCrosshairGunsight`, `HUDLockingGunsight`, ...).
Verification: `game/tests/cockpit_es2_check.tscn`, screenshots `renders/es2_cockpit*`.

### 8.1 Files, resolutions, palette (H unless noted)
* Nine cockpits: OUTLAW RAPTOR2 TOMAHAWK SAMSON COLOSSUS APOCA OGRE MAVERICK and the Razor flyer (RAZOR),
  named like the Herc file. Per Herc: `DB0/DB1/DB2` (320x240), `HB0/HB1/HB2` (640x480), `ED0..3` / `HD0..3`
  (3D-window regions, low / high resolution), `GAU`, `VUE`. Shared: `DBA` + `HBA` bitmaps, `DFN` + `HFN`
  fonts, `EDG/MFDCLIP|HDDCLIP`.
* Resolution: `[0x4d25bb] == 3` is the 640x480 mode: the loaders pick `hba` / `hfn` / `hd<n>` (0x429968,
  0x4310ae, 0x43c833, 0x44084b). **Every GAU / VUE value and every code offset is in 320x240 pixels**, shifted
  left by `[0x4d25be]` / `[0x4d25c0]` in 640x480 mode (e.g. 0x431cb1, the fixups 0x442f18..0x44bed0). The
  remake draws the 640x480 art on the 320x240 layout (layout `canvas`: size 320x240, `art_scale` 2; per
  bitmap `scale` in `dba/<NAME>.json` and `fonts/<NAME>.json`). STATIC, FLYERS and the pilot pictures have no
  HBA (scale 1). HFN fonts are 13 px high (6.5 layout px), not twice the DFN.
* Edge regions: as Earthsiege 1, but each full-width band also carries its x range (`s16 y0, y1, xL, xR`).
* Palette (0x429ac4): the sim palette is `WORLD<n>.DPL`; slots 0x2A-0x41 come from `COCKPIT.DPL[0x20 + 24k]`,
  k = word +0x52 of the unit record = DAT word +0x50 (the shell Herc type, 0..8): one colour scheme per Herc.
  The record starts 2 bytes before the DAT data (the panel's flyer test 0x431f87 reads +0x50 = DAT +0x4e).
  Panels use 0x2A-0x47, the instruments world colours (0x0a-0x23, 0x48-0x4d). Export: `palettes/<HERC>.json`
  = WORLD0 + the Herc's block; bitmaps, fonts and panels are 8-bit index PNGs that the engine colours with the
  cockpit's palette (CRT gamma applied like Earthsiege 1).

### 8.2 GAU (1700 bytes of s32, read by 0x431778)
Section -> builder -> ctor. Sub-rects are absolute (section origins are 0). Front-view rects are DB0 pixels;
the HDD's are DB1 pixels (its origin (0, 197) is not applied: the rects match the DB1 art); the exporter moves
them to y + 240 (below the front view, like the Earthsiege 1 layout).
* 0x010 weapon slots: `s32 count`, 10 slot rects of 55x6 (panel weapon array of 10 entries, 0x431fb4).
* 0x0b4 / 0x104 / 0x164: ProjectileWeapon / EnergyWeapon / pod templates (0x432124 / 0x432074 / 0x4321d4);
  all zero on the disc: the code places the parts (8.3).
* 0x1d4 indicators (0x432340 -> 0x441dd0): 4 text-button rects of 24x7; STRINGS0 group 4 = I, LINK, TRACK
  (the evolved Earthsiege 1 I / II / III / LINK / TRACK gauge; lamp meanings M).
* 0x224 energy pool (0x4323e0 -> 0x444d5c): one bar rect (BarGraphH 0x4395c4, maximum 0x400).
* 0x268 shields (0x432454 -> 0x4434fc): front bar, rear bar, two 12x5 lamp rects (ShieldsSelectGadget).
* 0x2d8 MFD (0x4324c8 -> 0x445218): only the display rect `+0xe0` is set (button rects are zero).
* 0x3e8 throttle (0x43254c -> 0x447b84): lever track, forward and reverse bars (1 px wide), `+0x40` 1 =
  vertical.
* 0x440 HUD (0x4325c0 -> 0x43c7d8, fixup 0x43e118): heading tape `+0x10`, clock text point `+0x20`, speed
  text point `+0x28`, centre `+0x30`, half size `+0x38`, target area `+0x3c`, two text rects `+0x4c` / `+0x5c`
  (contents unknown), point `+0x6c`.
* 0x4bc HDD (0x432634 -> 0x448cc8, fixup 0x44bed0): the Earthsiege 1 layout (screen, map / damage areas,
  15 buttons, 3 wingman LEDs).
* 0x684 / 0x694 message lines: a line at the bottom of the 3D view / the message port at its top (the remake
  shows the port in every view).
There is no brightness gauge and no clock gauge (the clock is a HUD text).

### 8.3 Weapon slots (H geometry)
WeaponSelectGadget 0x442488: status LED at x + 6..9, name at x + 11..35 (font GRAY, WHITE when selected,
0x4427e1); EnergyWeaponGauge 0x440a68 puts the charge bar and ProjectileWeaponGauge 0x440f78 the ammo count at
x + 36..53. A per-slot flag (template +0x40 bit, zero on the disc) mirrors the slot. LED (PWEAPONS frames):
destroyed weapon 6; selected / linked weapon 4 (ready) or 5 (charging); else none (0x4427ba). Frame 0
(selected) / 1 (other) outlines the slot at (x - 1, y - 1) (0x44287b). Remake: selected = trigger held (as
Earthsiege 1), the LED always shown; bar colours 0x20 / 0x22 (slider parameters 0x442ae3; fill vs. empty: L).

### 8.4 HUD (H unless noted)
* Heading tape: HUDHTICK (the Earthsiege 1 strips), window +-0xe38.
* Torso slider (HFixRotationGauge): rect = tape + (15, -10), 90x4 (0x43ca46); track HUD frame 11; marker
  frame 13 within +-300 angle units of straight ahead, else 12 (0x43b525); range +-0x38e3.
* Crosshair (HUDCrosshairGunsight 0x43b7e0), centred on `+0x30`: frame 0; with the target projected within
  +-5 px of the centre frame 1 if `+0x39` (remake: hostile) else 2.
* Target brackets (HUDLockingGunsight 0x43bbd0): pipper frame 3 (green) / 7 (red) with corner pieces 4..6 /
  8..10. Remake: the corner frame mirrored into the four corners of the Earthsiege 1 target box; red = hostile
  (M).
* Texts (font hud2): speed "nnn K/H" at `+0x28` (0x43dc78) and the mission clock "MM:SS" at `+0x20`
  (0x43dcac). Alignment not decoded (remake: centred on the point).
* Flyers only (0x43dd70, unit flag DAT +0x4e): the altimeter at `+0x6c`: caps (frames 15 / 16), dotted
  scale 18 and marker 17, the marker moving over 36 px between the ground height (bottom) and the ceiling +
  5000 units (top). Hercs: the remake writes the waypoint text there (font hud3, M).

### 8.5 Energy pool, shields, throttle (H structure, L colours)
Energy pool bar = the beam capacitor (remake). Shields: front bar fills upwards, rear bar downwards (L).
Throttle (ThrottleVSliderGadget 0x447e24): the lever is THROTTLE frame 1 (0x447ef7), centred on the track; the
speed bars are BarGraphV (0x439344) fills.

### 8.6 MFD (H unless noted)
* Page area = GAU display + 18 px to the right (0x44536d). The 13 buttons are placed by four word tables
  (0x49cacc x0, 0x49cae6 y0, 0x49cb00 x1, 0x49cb1a y1; = PMFD.BND words) relative to the page area: 0-5 page
  buttons in a column left of the page (MFD frames 3 off / 4 on, no label), 6 title (empty), 7-12 options.
* Option kinds (jump table 0x44552a): 7 / 10 wide (MFD frame 5), 8 / 9 frame 7, 11 / 12 frame 9; labels =
  STRINGS0 group 5, item = button number (SELECT, RANGE, TARGET, XMIT, PASS, ACTIVE), font white. Shown per
  page (byte table 0x49cbd8): STATUS 7, COMM 10, SCANNER 8, 9, 11, 12, TARGET 7.
* Page background (0x4461f7): STATUS / COMM / TARGET frame 1, SCANNER frame 2, NAV / MISSILE none. Title text
  at page + (4, 0) (font dark).
* Pages: MFDStatus 0x43a2e0 (STATUS and TARGET), MFDRadar 0x43f5d8, MFDFlashComm 0x440494, MFDNavMap 0x43e70c,
  MFDMissileView 0x43facc. RADAR.HBA = 10 frames of a ping ring (remake: cycled, right of the option buttons;
  L). STATUS / TARGET picture box (2, 13)-(45, 58), text from x 45 (PSTATUS.BND); remake rows y 16, 23, 32,
  40, 49 (L).
* Damage colours (0x438624; DAT/COLORS.DAT = 27 palette indices loaded to 0x4d3c00 by 0x467a60): the
  Earthsiege 1 thresholds (90 / 74 / 51 / 1 %), level colours = COLORS words 12, 15, 20, 9, 18 (green, yellow,
  orange, red, grey), one colour each. PDG region colours are COLORS entries too (region colour 12 = the green
  the unit bitmaps are drawn in; M). The recolour 0x437e94 (flag 0) replaces exactly that colour inside the
  region rect (scaled by the resolution shift for the HBA diagrams).

### 8.7 HDD (M frames)
Buttons 0 / 1 = MAP / DAMAGE lamps (HDD frames 25 off / 26 on), 2-5 scroll pad (frames 5, 7, 9, 11), 6 / 7
zoom out / in (frames 21 / 23, the "-" / "+" art), 9 page title, 10-12 wingman windows (STATIC / PILOTn).
Map icons (ICONS.HBA, 90 frames): groups of nine per unit kind (directions NE, SE, SW, NW, N, E, S, W, none):
small blue 6, small red 15, red 24, blue 33, white 42, green 51, yellow 60, purple 69; digits 1..9, 0 = 78..87.
Remake: self white, friend blue, enemy red, target yellow, nav points the digit boxes.

### 8.8 Remake (`game/games/es1/cockpit/`)
`CockpitDisplay` reads the layout's `canvas` (size, `look_down_top`, `art_scale`), `palette` and `panels`.
`CockpitSkin` says which bitmaps, frames, fonts, colours and STRINGS0 groups each instrument uses: Earthsiege 1
values are its defaults, `cockpit/skin.json` (written by the ES2 exporter) overrides them. Painters:
`CockpitHud`, `CockpitWeapons`, `CockpitGauges` (indicators, engine / energy bar, throttle, clock, message
lines), `CockpitShields`, `CockpitMfd`, `CockpitHdd`, `CockpitTargetImage`. Each element picks its variant from
the data (e.g. the bitmap crosshair when the skin names its frames, the drawn Earthsiege 1 cross otherwise).
The cockpit camera's projection centre follows the HUD centre row (`BattleCameras.apply_centre_row`;
Earthsiege 1: row 72 of 200 as before). Earthsiege 1 output is pixel-identical (`cockpit_es2_check
--es1-reference`).

**Not done / unknown:** the original drawing of the NAV MAP, FLASH COMM and MISSILE CAM pages (the remake reuses its Earthsiege 1 pages);
the MFD / HDD clip shapes (MFDCLIP / HDDCLIP); the MFD_DMG / WPN_DMG damage frames; the HUD `+0x4c` / `+0x5c`
texts; the pod (ECM) gauge parts; the shield lamps; the radar ping timing.

### 8.9 Side views (look left / look right)
Mechview (VUE loader 0x429834): `+0x14` current view, `+8` panel bitmap per view (0x429c2c: the extension digit is
the view index, minus 1 from view 3, so view 3 loads DB2 / HB2 too; 0x429dc2 copies view 2's bitmap into slot 3).
* Views (H): 2 = look RIGHT (pan +320, ED2 / HD2, DB2 drawn as stored), 3 = look LEFT (pan -320, ED3 / HD3, DB2
  drawn mirrored: blit flag 2 for view 3, 0x42a261..0x42a26b). The exported data agrees (ED3 = 319 - x of ED2;
  HB2's window matches ED2 unmirrored). Side = which: M (pan sign, frustum maths 0x49497a, key order).
* Keys (panel key handler 0x432bc8; request table 0x42a3f4, executor 0x42a4c4 / 0x42a768): F9 (scan 0x43) from the
  front view -> view 3, from view 2 -> front; F10 (0x44) from the front -> view 2, from view 3 -> front; the same
  key again does nothing. Look-down (0x432ddf) and the MFD keys F1-F6 (0x432ceb) return to the front view; side
  keys are ignored while looking down (H). Joystick hat (0x432b14): up / down / left / right (M); panel hotspots
  0x433a88 toggle the same views.
* Camera (H): no turn. setView 0x42a1a7 sets the 3D port origin to VUE centre offset + pan, so the side view is the
  same camera with its projection centre 320 px to the side (off-axis, one panorama of three screens). A real
  +-75.9 deg yaw (0x3600 at 0x42a873..0x42a974) runs only in a mode byte `[0x4d25bb]` == 1 the game never sets.
* Drawn (M): only the side art and the 3D window (ED2 / ED3). setView scrolls the whole panel by the pan (0x43271c
  gadgets, canvas origin and gauge list; 0x435574 the message line / port): every gauge, the HUD and the messages
  are off-screen. No gauge tests views 2 / 3.
* Remake (`CockpitSideView`, Earthsiege 2 only): `look_left` / `look_right` (keypad 4 / 6; F10 is the remake's
  `debug_toggle`) with the toggles above; the frustum camera's `frustum_offset.x` = pan in layout pixels
  (`cockpit_es2_check` section 3).

## 9. Cockpit per vehicle (every pilotable vehicle; remake)

### 9.1 Audit (2026-10-10, before this section)
Only the 8 Earthsiege 1 Hercs and the 9 Earthsiege 2 cockpits (8 Hercs + Razor) had their original instruments
(`CockpitDisplay` then required `def.cockpit` and side "herc"). Every other pilotable vehicle -- the Earthsiege 1 / 2
Cybrids, the Landskimmer, all Battledrome Hercs, every Starsiege Herc / tank / flyer and the Tribes / Tribes 2
vehicles -- got the remake's plain HUD (`hud.gd`); tanks and flyers started in the chase view. Nothing was broken or
empty, but none of them looked like their game. Battle screenshots (`--herc=<id> --screenshot=<png>`):
`renders/cockpit_audit_before/`, after: `renders/cockpit_audit_after/`.

### 9.2 What each game had (decoded)
* **Battledrome** (`tools/bd_hud.py`, `tools/export_bd_cockpit.py`, SIM.EXE `code\hud.cpp`, Hud::render 0x23a40): no
  panel art. The whole 320x200 screen is the 3D view (projection centre (160, 100)) and the HUD is vector-drawn by
  code: 15 draggable windows placed by `DTS\HUD.DAT` (u32 tag 0x01F40000, u32 size, 15 x {s32 x, y}, 13 visible
  flags), lines / fills / ellipses / polygons in NRMPAL colours and a stroke font built into SIM.EXE (SFont 0x9b568,
  3x5 cells, 4 px advance, placed by baseline). Windows: energy split (SHIELDS / ENGINE / WEAPONS), MechSpinners
  (compass pointers + throttle), CameraSpinners, weapons list (name in the pod's damage colour, charge ticks / ammo),
  shield bar + the Herc's front diagram (per Herc, record +0xf4), TARGET / DIST, control / camera lines, camera list,
  chat line, reticle cross (a diamond from a probe), the WINNER.DBA banners. Hidden by default: the damage list and
  the twist / pitch tracks.
* **Starsiege** (`tools/starsiege_hud.py`, `tools/export_starsiege_cockpit.py`, Starsiege.exe SimGui::HudMtr*): meters
  drawn over the view from `shell.vol` art (retical / lead / radar_high / shields + strCircle / dam_self / dam_tar /
  hud_circle, PFT fonts hud_high*), palette slots 240-253 filled from 8 colour schemes (scheme 0 green, 0x50be7c),
  every meter at alpha 0.7. Default positions are screen fractions (0x508b70; top-left = (screen - size) x fraction).
  Herc and tank: reticle, lead, radar, weapons, shields (if shielded), STATUS / TARGET pictures (a live 3D model),
  internals, chat, timers, commander orders; flyer: the same without internals and orders.
  **Human vs Cybrid:** the HUD art and colours are the same for both; the faction difference is the **3D cockpit
  interior**: the first-person view sets Seq07_cockpit / Seq01_cockpit, which hides head0..4 and shows the shape's
  `cockpit`, `cockpit1`, `cockpit2` objects (0x481fc0), textured tr_cpit / cy_cpit / rb_cpit / ha_cpit (human metal
  frames, Cybrid organic spikes). Eye (H, 0x4a33c6 / 0x471520): node "cam" / "camera" / "cockpit" / "head0" (Hercs;
  tanks and flyers "cockpit" / "head0") + the vehicle's hercCpit / tankCpit / flyerCpit offset (x right, y forward,
  z up, metres) in that node's frame. Field of view: Darkstar games look 90 degrees across their 4:3 screen (Tribes `$pref::PlayerFov = 90`;
  Starsiege `fov` console command 0x4a6590 -> camera +0x43c, default assumed the engine's, M); the remake keeps that
  view's vertical angle (73.7 degrees) on any screen (`BattleCameras.make_cockpit_fov_deg`); Earthsiege keeps the VUE
  view's 62. The Cybrid interiors (e.g. Metagen Seeker `cockpit`: organic spikes) frame the view by design; nothing
  else of the own model shows (`cockpit_view_check`).
* **Tribes** (`tools/tribes_vehicle_hud.py`, `tools/export_tribes_cockpit.py`): no vehicle HUD -- the Scout pilot keeps
  the standard play.gui HUD (health / energy bars of the controlled object, compass, sensor ping, clock, an empty
  weapon slot, crosshair with friend / foe marker, chat).
* **Tribes 2**: piloting sets HUD mode "Pilot": the top-right cluster (pilot armour / energy / heat, compass, sensor,
  clock), chat, and a vehicle dashboard (dash art, vehicle icon, vehicle energy and damage bars, speed in KPH; Shrike
  and Thundersword altitude; Shrike weapon box and reticle; seat dots). The remake's Thundersword / Beowulf pilot also
  gets the gunner seat's reticle (bombardier / tank): the remake's pilot fires the gunner weapons.

### 9.3 Data and engine
`tools/cockpit_hud_layouts.py <pack>` turns a decoded `hud.json` into engine layouts
(`gamedata/<pack>/cockpit/layout/<NAME>.json`: `canvas`, `palette`, `gauges.hud.center`, `meters`) and `fit.json`
(by_vehicle / by_kind_side / by_side / by_kind / default, `native_kinds`). Importer step `cockpit` of
`tools/siege_games/{bd,starsiege,tribes,tribes2}.py` runs the exporter, then the layouts (Starsiege now also unpacks
shell.vol). A layout with `meters` and no `panels` is a HUD over the whole view: `CockpitDisplay` draws no panel art
and has no look-down panel; `CockpitMeters` hands each meter to `CockpitMeterBasic` (art layers, bars, texts,
compass, messages: Tribes / Tribes 2), `CockpitMeterAim` (reticle, lead), `CockpitMeterRadar`, `CockpitMeterStatus`
(Starsiege shield ring, weapons, STATUS / TARGET models via TargetView, internals) or `CockpitMeterVector`
(Battledrome shapes). `CockpitEye` puts the cockpit camera at the game's eye point and shows the cockpit interior
meshes to it (`BattleCameras.build_cockpit_camera`); other vehicles keep `make_eye_position` over their cockpit node
(Herc torso, tank turret, flyer root). The projection centre follows the layout's HUD centre row (Starsiege / Tribes
240 of 480, Battledrome 100 of 200; `BattleCameras.apply_centre_row`).

### 9.4 The rule (`CockpitFit.make_choice`, first match wins)
1. **native**: the vehicle's own cockpit (`def.cockpit` has a layout).
2. **native HUD / game UI**: its game's UI for it from `fit.json` (by vehicle, kind + side, side, kind, default);
   "native HUD" for the kinds the original let the player pilot (Battledrome Hercs, Starsiege Hercs and tanks, the
   Tribes vehicles), "game UI" otherwise (Starsiege flyers: the Starsiege flyer HUD).
3. **same-game best fit**: the same game's vehicle with a native cockpit closest in mass, a flyer preferring flyers
   (Earthsiege 1 / 2 Cybrids -> a Herc cockpit, the Landskimmer -> the Razor's).
4. **plain HUD** (`hud.gd`): only when the game's cockpit data is not installed. Soldiers keep the infantry HUD.

A flyer whose UI has no altimeter gets the remake's "ALT M" readout (`CockpitMeters.make_flight_meter`).
Test: `game/tests/cockpit_coverage_check.tscn` (window): every vehicle resolves a cockpit, its instruments follow the
state, the eye sits inside the upper part of the vehicle, the view centre is on the HUD centre row; contact sheets
`renders/cockpit_coverage_<n>.png` (`--shots=<dir>`: full frames).

### 9.5 Per vehicle (`cockpit_coverage_check` output)
| vehicle | side / kind | before (audit) | rule | cockpit (pack:layout) | why |
|---|---|---|---|---|---|
| bd:STRYDER | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:BARETTA | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:AVENGER | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:VIPER | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:NOMAD | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:TALON | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:PHANTOM | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:SLAYER | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:VNDICTR | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| bd:THOR | herc / herc | plain HUD | native HUD | bd:HUD | the game's UI |
| es1:ROADRUNN | herc / herc | original cockpit | native | es1:ROADRUNN | its own cockpit |
| es1:GUNSLING | herc / herc | original cockpit | native | es1:GUNSLING | its own cockpit |
| es1:SCORPION | cybrid / herc | plain HUD | same-game best fit | es1:GUNSLING | closest Herc of its game: Gunslinger |
| es1:MONGOOSE | cybrid / herc | plain HUD | same-game best fit | es1:GUNSLING | closest Herc of its game: Gunslinger |
| es1:RAPTOR | herc / herc | original cockpit | native | es1:RAPTOR | its own cockpit |
| es1:TOMAHAWK | herc / herc | original cockpit | native | es1:TOMAHAWK | its own cockpit |
| es1:RAMSES | cybrid / herc | plain HUD | same-game best fit | es1:RAPTOR | closest Herc of its game: Raptor |
| es1:PATRIOT | herc / herc | original cockpit | native | es1:PATRIOT | its own cockpit |
| es1:MIRIMAC | cybrid / herc | plain HUD | same-game best fit | es1:PATRIOT | closest Herc of its game: Patriot |
| es1:PANTHER | herc / herc | original cockpit | native | es1:PANTHER | its own cockpit |
| es1:HERCULES | herc / herc | original cockpit | native | es1:HERCULES | its own cockpit |
| es1:ACHILLES | cybrid / herc | plain HUD | same-game best fit | es1:HERCULES | closest Herc of its game: Hercules |
| es1:APOLLO | cybrid / herc | plain HUD | same-game best fit | es1:HERCULES | closest Herc of its game: Hercules |
| es1:COLOSSUS | herc / herc | original cockpit | native | es1:COLOSSUS | its own cockpit |
| es1:BULLDOG | cybrid / herc | plain HUD | same-game best fit | es1:COLOSSUS | closest Herc of its game: Colossus |
| es2:SKIMMER | cybrid / flyer | plain HUD, chase view | same-game best fit | es2:RAZOR | closest flyer of its game: Razor |
| es2:STINGRAY | cybrid / herc | plain HUD | same-game best fit | es2:MAVERICK | closest Herc of its game: Maverick |
| es2:MONGOOSE | cybrid / herc | plain HUD | same-game best fit | es2:MAVERICK | closest Herc of its game: Maverick |
| es2:RAZOR | herc / flyer | original cockpit | native | es2:RAZOR | its own cockpit |
| es2:MAVERICK | herc / herc | original cockpit | native | es2:MAVERICK | its own cockpit |
| es2:OUTLAW | herc / herc | original cockpit | native | es2:OUTLAW | its own cockpit |
| es2:TOMAHAWK | herc / herc | original cockpit | native | es2:TOMAHAWK | its own cockpit |
| es2:RAPTOR2 | herc / herc | original cockpit | native | es2:RAPTOR2 | its own cockpit |
| es2:RAMSES | cybrid / herc | plain HUD | same-game best fit | es2:RAPTOR2 | closest Herc of its game: Raptor II |
| es2:MIRIMAC | cybrid / herc | plain HUD | same-game best fit | es2:OGRE | closest Herc of its game: Ogre |
| es2:OGRE | herc / herc | original cockpit | native | es2:OGRE | its own cockpit |
| es2:SAMSON | herc / herc | original cockpit | native | es2:SAMSON | its own cockpit |
| es2:ACHILLES | cybrid / herc | plain HUD | same-game best fit | es2:SAMSON | closest Herc of its game: Samson |
| es2:HYPERION | cybrid / herc | plain HUD | same-game best fit | es2:SAMSON | closest Herc of its game: Samson |
| es2:CERBERUS | cybrid / herc | plain HUD | same-game best fit | es2:APOCA | closest Herc of its game: Apocalypse |
| es2:SCARAB | cybrid / herc | plain HUD | same-game best fit | es2:APOCA | closest Herc of its game: Apocalypse |
| es2:HEADHUNT | cybrid / herc | plain HUD | same-game best fit | es2:APOCA | closest Herc of its game: Apocalypse |
| es2:DIABLO | cybrid / herc | plain HUD | same-game best fit | es2:APOCA | closest Herc of its game: Apocalypse |
| es2:COLOSSUS | herc / herc | original cockpit | native | es2:COLOSSUS | its own cockpit |
| es2:APOCA | herc / herc | original cockpit | native | es2:APOCA | its own cockpit |
| es2:PITBULL | cybrid / herc | plain HUD | same-game best fit | es2:APOCA | closest Herc of its game: Apocalypse |
| starsiege:mg_seek | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_talo | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_seek | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:rb_aven | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:rb_bike | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:kn_talo | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_bans | herc / flyer | plain HUD, chase view | game UI | starsiege:HUD_FLYER | the game's flyer UI |
| starsiege:tr_mino | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_goad | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_bolo | cybrid / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:kn_bans | herc / flyer | plain HUD, chase view | game UI | starsiege:HUD_FLYER | the game's flyer UI |
| starsiege:mg_goad | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:pi_eman | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_supr | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:cy_recl | cybrid / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:kn_mino | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:rb_eman | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_shep | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_basl | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:rb_drea | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:tr_basl | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_nike | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:tr_pala | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:pi_drea | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:ca_basl | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_artl | cybrid / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:mg_shep | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_disr | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:cin_basl | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cin_apoc | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_disr | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:pl_adju2 | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:pl_adju | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_apoc | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_pala | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:pi_apoc | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_apoc | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:ha_pred | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:rb_artl | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:ha_apoc | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_adju | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:mg_adju | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:superpred | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:rb_oly | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_gorg | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:ss_bus | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:tr_gorg | herc / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:kn_myrm | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:cy_prom | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:tr_myrm | herc / tank | plain HUD, chase view | native HUD | starsiege:HUD | the game's tank UI |
| starsiege:pl_exec2 | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:pl_exec | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:mg_exec | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| starsiege:cy_exec | cybrid / herc | plain HUD | native HUD | starsiege:HUD | the game's herc UI |
| tribes:SCOUT | herc / flyer | plain HUD, chase view | native HUD | tribes:SCOUT | the game's UI for this vehicle |
| tribes2:SHRIKE | herc / flyer | plain HUD, chase view | native HUD | tribes2:SHRIKE | the game's UI for this vehicle |
| tribes2:THUNDERSWORD | herc / flyer | plain HUD, chase view | native HUD | tribes2:THUNDERSWORD | the game's UI for this vehicle |
| tribes2:BEOWULF | herc / tank | plain HUD, chase view | native HUD | tribes2:BEOWULF | the game's UI for this vehicle |

**Not done / approximations:** Starsiege radar ranges (500 / 1000 / 2000 m, L), the throttle / shield arcs and the
lead's off-screen arrow; Tribes compass letter placement (L) and the Tribes 1 weapon box contents; Battledrome
MechSpinners pointer assignment (L), the energy split (the remake has none: 85 each) and probes; the remake's pilot
inside a vehicle has no separate body, so the Tribes pilot bars read full.

### 9.5a Sight, radar frame, compass and friend-or-foe (remake, playtest 2026-10-11 group A)
* **Sight:** the crosshair is the cockpit camera's projection centre (the HUD centre row, `apply_centre_row`); the
  camera sits at the eye (`Herc.eye_mount`: CockpitEye, else in front of the cockpit node's meshes) and is turned to
  `Herc.sight_basis` every frame (`BattleCameras.apply_sight`): chassis + torso twist + pitch (a flyer: its pitched
  and banked model; the bank leaves the crosshair on the nose). Weapons fire from their muzzles at the first thing on
  that ray (`Weapon.make_aim_point`), so they converge on the crosshair (`aim_convergence_check`).
* **Radar / heading frame:** `HeadingFrame` gives the view heading (yaw of the sight), compass bearings (0 = north =
  -Z, clockwise) and radar offsets (x right, y behind) for every radar and tape: the plain HUD, the Earthsiege MFD
  scanner / NAV, the Starsiege scope, the Earthsiege heading tapes, the Tribes compass dial.
* **Compass waypoints:** Earthsiege tapes keep their marker; the Tribes dial gets a waypoint dot; a meter HUD without
  a compass (Starsiege) gets the remake's `heading_tape` meter (`HudCompass`, below the message window), and the plain
  HUD (soldiers on foot, vehicles without a layout) draws the same tape at the top centre. Waypoint: the mission's
  current nav point, else the nearest `nav_points` marker (`HeadingFrame.make_current_waypoint`).
* **Friend-or-foe:** `TargetInfo` (FRIEND green / ENEMY red / NEUTRAL yellow, TeamRelations) colours radar blips, the
  plain HUD target box, the Earthsiege 1 target box (hostile: the original yellow; friend / neutral: its colour and
  "[ FRIEND 100% ]"), the MFD target page name and the Tribes marker; `Nameplates` puts allied units' names over their
  heads. Targets may be vehicles, soldiers or structures (group "targetables").

### 9.6 The remake's messages and the start view
The remake's own overlay texts (the objective and controls, "You are piloting: ...", seat roles, kill / end
messages, and the OccupancyDirector's standing hint "E: get out of the ...") go to the active cockpit's own message
area in that HUD's font and colours (`CockpitMessageArea`), never over its windows: Earthsiege 1 / 2 message line
and the Battledrome chat line (one line: the newest message, else the hint, scrolling through the window when too
long, clipped inside the window border); the Starsiege chat, Tribes and Tribes 2 message windows (word-wrapped, the
newest lines, the hint last). `InfantryHud` hands the hint to `CockpitDisplay.hint` and draws it itself only while
no cockpit shows (chase view, soldiers, the plain HUD). A HUD layout without a message window gets the remake's
two-line window in the first free band from the top clear of every meter rect (`CockpitMessageArea.make_free_rect`).
Every vehicle with a cockpit or HUD (`CockpitFit.has_cockpit`) starts in its cockpit view, tanks and flyers too
(`Herc.prefers_chase_view` / `Flyer.prefers_chase_view`); V toggles the chase view; soldiers start in first person.
Test: `cockpit_coverage_check` (message area clear of the windows, a long message plus hint changes no pixel outside
it, start view). Screenshots: `renders/hud_msg_*.png` (before: `renders/hud_msg_before/`).

**The chat panel (remake, breaks the original HUD limits on purpose).** The original message lines keep showing
the newest system or radio message (radio as "SPEAKER: TEXT"); the full history lives in one chat panel that is the
same in every game, cockpit, HUD and on foot (`engine/chat/`, `games/es1/battle/battle_chat.gd`):
* Channels (`ChatChannels`, own colours, filter tabs): **system** (objective, hints, kills, "Nav point reached",
  everything `BattleOverlay.show_message` posts), **radio** (the campaigns' wingmen, commanders and bases with the
  speaker's name, `Battle.radio` → `RadioVoice`: each line shows when its voice clip starts; per game see
  audio_video.md / es2.md / the Starsiege script notes), **all** and **team** (players).
* Closed: the newest `visible_lines` (default 6) word-wrapped lines, each fading out `fade_seconds` (12 s) after it
  arrived. Open (`chat_all` Enter / `chat_team` Y typing, `chat_quick` K / pad Share the quick-chat menu,
  `chat_history` U the history): `history_lines` (14) of history with scrollback (wheel, PgUp / PgDn, right
  stick), the filter tabs, optional "HH:MM" timestamps; the history mode is the edit mode (drag the title strip
  to move the panel, the corner grip to resize it; saved as the "custom" position). While open the player's
  controls are held (no pause), every key goes to the chat, the mouse is free and is captured again on close.
* Quick chat: the Tribes 1 chat menu (`scripts/chatmenu.cs` PlayChatMenu: headings with team / global lines and
  command responses; animations and local sounds left out), extracted at import by
  `tools/export_tribes_quickchat.py` to `gamedata/tribes/gameplay/quick_chat.json`; without Tribes installed the
  remake's own short list (`QuickChat.OWN_MENU`).
* LAN (host-authoritative): a client asks the host; the host cleans the line (control characters, 160 characters
  max), applies the flood guard (4 lines per 5 s per sender, the sender is told), names the sender from the roster
  and sends it to everybody (all) or to the peers on the sender's team (team: the team of the peer's vehicle, else
  his roster team).
* Placement (`ChatPlacement`): presets auto / corners / custom, width, opacity, font size in the options screen's
  Chat section (`ChatOptions`), saved in `user://settings.json` ("chat"). **Auto** searches from the bottom-left
  corner upwards, column by column, for the first spot clear of every rect of the HUD in use and narrows the panel
  (down to 240 px) when only a narrow spot is free: `CockpitOccupancy` (HUD layouts: every meter window plus the
  message window; Earthsiege panel cockpits: every instrument rect of the layout in the front view, the 3D-view
  message line and the panel below the front view's 3D viewport, without the HUD gauge's whole-view bounds), the
  plain HUD's meters (`HUD.make_occupied_rects`) and the soldier's bars (`InfantryHud.make_occupied_rects`). The
  open panel is at least 480 px wide and may cover windows while open. The panel sits on its own canvas layer
  (40) above the cockpit.
Tests: `chat_check` (history / scrollback, filters, typing holds the controls and restores the mouse mode, quick
chat, team routing, flood guard and length cap, radio, settings persist), `cockpit_coverage_check` (the default
panel is clear of every cockpit's windows), the LAN pair `e2e_driver --flow=lan_host` / `lan_join` (all and team
lines both ways). Screenshots: `renders/chat_*.png` (`tests/chat_shots.tscn`).

### 9.5b Radar pages, active / passive radar, comm faces (remake, 2026-10-16)
* **ES1 F4 SCANNER** (class 0x35298, draw 0x355a4): a rotating scope, bearings rotated by the view yaw (heading up), RANGE
  steps 30000 / 80000 / 120000; shows the page's ACT / PASS label (STRINGS0 group 25) and the RNG distance of the target.
  **F3 NAV MAP** (0x36b18) is not a scope: it renders the terrain from straight above (camera 200000 up, view angles).
  The remake draws the command map's top-down render under a north-up scope for F3 (`CockpitMfd._draw_nav_terrain`)
  and titles F4 "SCANNER HDG UP".
* **Active / passive:** per-unit "emitting" byte (unit + 0x90); toggled by 0x157f4 only on units with radar gear (+0x9d),
  cue sound 0x1a / 0x1b; the EMCON wingman order and an AI target criterion ("emitting", 0x1c950) read it. Decoded: the
  flag, its toggle, its label. NOT decoded (remake numbers, L): passive hides non-emitting hostiles beyond a third of
  the range (`RadarMode.PASSIVE_NEAR_SHARE`), the AI sees passive units from half the sensor range
  (`SIGNATURE_PASSIVE`), key `;` (`radar_mode_toggle`) and the click on the SCANNER's first option button.
* **Comm faces:** PILOTn.DBA has 24 face frames (mouth / brow positions); the remake plays frames 2..23 at 10 fps in a
  fixed pseudo-random order while the wingman's radio line plays (`CockpitHdd.make_face_frame`; the original's frame
  order is not traced, L), frames 0 / 1 (blink) when idle.
