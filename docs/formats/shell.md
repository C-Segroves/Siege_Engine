# Front-end shell (GO.EXE) — presentation formats & screen flow

Tool: `tools/shell.py` (`python tools/shell.py all <outdir>` converts everything; see its docstring).
GO.EXE addresses are VAs (`Exe('GO')`, VA = file offset − 0x48FD). Confidence: **[H]** verified in code
and/or visually, **[M]** strong inference, **[L]** guess.

All shell screens are **320×200, 8-bit palettised** (VGA mode 13h). Coordinates below are in that space.

---------------------------------------------------------------------------------------------------
## 1. Palettes & the UI colour convention [H]

`REGN<r>.DPL` (RES32) is loaded with each region (§6). In every shell palette **indices 0–31 are a fixed
UI palette** (identical across all REGN*.DPL except REGN1610, which keeps only 0–15): 0 black/transparent,
1–3 greens, 4–6 yellows/ambers, 7–9 reds, 10–12 blues, 13–15 grey-green, 16–31 grey ramp (231→32).
Fonts, buttons and STYLES.DAT only use indices 0–31, so UI art is palette-independent. 32–255 belong
to the screen art. REGN3000 has four palettes (REGN3000..3003 = campaign 0..3, same DBM); REGN1000.DBM
is also shown with REGN1610.DPL (crew screen). MENU9995–9999.DBA (loading panels) use REGN9999.DPL.

## 2. Fonts — `DFN\*.DFN` (class 0x28, type 0x05) [H]

```
0x00 u16 type=5, u16 class=0x28, u32 size(excl. 8-byte header)
0x08 u32 nChars (223)        0x0c u16 firstChar (0x20)     0x0e u16 height
0x10 s16 -1 [?]              0x12 u16 lineHeight (=height) 0x14 u16 maxWidth
0x16 u16 8 [?]  0x18 u16 0   0x1a u16 7 [?]  0x1c u16 0
0x1e u32 pixelBytes ; pixels[pixelBytes]       8bpp palette indices, 0 = transparent
     u32 offset[nChars]  (relative to pixels)
     u8  width[nChars]
glyph c: width[c-first] × height bytes, row-major, at pixels+offset; xadvance = width (spacing is in the glyph)
```
Character codes are bytes (DOS CP437 above 0x7F: Ç ü é … present). Glyphs are multi-colour (emboss
highlight/shadow), e.g. ACTIVE uses 0x1c/0x14, GRAY 0x0d/0x0e, NM_GREEN 1/2, TITLE 0x14/0x1c/0x1f.
GO.EXE loads (0x7fd20, in order): title, gray, active, pushed, inactive, nm_green, nm_red1, cstats_1,
cstats_2, nm_white, nm_blue, nm_ylw, big_red. Text buttons use active/pushed/inactive (globals
0xaacce/d2/d6, stored by MTButton ctor 0x1cde8 at +0x24..+0x2c; its +0x30..+0x38 are STYLES.DAT entries, §5) [H];
window titles use TITLE [M].
Export: `fonts/<shell|sim>/<NAME>.png` (RGBA, REGN1000 or COCKPIT palette), `_idx.png` (raw indices,
for palette-swap shaders), `.fnt` (BMFont text — Godot 4 imports it directly as FontFile), `.json`.

## 3. String tables

**`ENG\*.BIN`, `CFG\FILENAME.BIN` ("Text", Text::getString)** [H]
`u32 count, u32 dataSize, u16 offset[count], char data[dataSize]` (NUL-terminated, offsets relative to
data). The `C?_TEXT/D?_TEXT/G0_TEXT/T1_TEXT` files have an extra leading `u16 2`. `MENU<n>.BIN` holds the
labels of `DLG\MENU<n>.DLG`; `C/D/G/T*_TEXT` are subtitles of the talking-head speeches (§7);
WATEXT = weapon/armory texts.

**`STR\*.STR`** [H] `u32 size; repeat { u16 count; count × { u16 len; char s[len] (incl. NUL); u8 0 } }`
— groups of strings (alert dialogs CAL_ALRT/CTL_ALRT, MAPLABEL = map legend).

## 4. Dialog layouts — `DLG\MENU<n>.DLG` [H] (loader 0x3a1f7)

```
u16 count
count × 13 bytes: s16 x1, y1, x2, y2 ; u8 type ; u8 flags ; u8 hotkey (PC scancode) ; u16 id
```
* Record 0 = the window; its rect is in screen coords. Other records are relative to the window origin.
* Label of record *i* = string *i* of `ENG\MENU<n>.BIN` (index = record index, 0x3a7d7). Surplus
  strings are alternates chosen by code (e.g. MENU1300 "RETURN TO MAIN/MISSION/CAREER", 0x3a832).
  For types 0/1/4/5 a few ids (0x4bb, 0x15b4–6, 0x4c7) are replaced by runtime text.
* Window (type 0): flags 0 → MTWindow drawing the pre-rendered panel `RES32\MENU<id>.DBA` at the window
  origin (panel = window size; id may differ from the file, e.g. MENU1250 uses MENU1240.DBA, alerts use
  MENU999.DBA). flags 1 → plain, panel-less window (MENU1500/1501/1700/1710 overlays).
* Types (dispatch table 0x81994):

| type | class / meaning |
|---|---|
| 0 | window (see above) |
| 1 | static text, justify 0 (left) [H] |
| 2 | MTEditBox (text entry) [H] |
| 3 | flags 0: MTButton — text button drawn from STYLES.DAT/CORNERS; flags 1: MTBmpButton [H] |
| 4 | static text, justify 1 (right) [L] |
| 5 | static text, justify 2 (centred) [M, visually consistent] |
| 14 | custom-drawn info gadget; content chosen by id (callbacks 0x17a19…) [M] |
| 15 | MTStrListBox fed by id (table 0x81a00); flags passed to ctor (1 = borderless value field) [M] |
| 16 | MTGfxListBox [H] |
| 17 | MTAnimListBox [H] |
| 18 | separator line (flags 1) [M] |

* `hotkey` = keyboard scancode: 1 Esc, 57 Space, 72/80 Up/Down, 75/77 Left/Right, 73/81 PgUp/PgDn,
  78/74 keypad +/−, 23/18/17 I/E/W.
* `id` of a button = command: if a `MENU<id>.DLG` exists it is the target screen; otherwise
  99 cancel/back, 100 accept/proceed (context dependent), 101/102 list scroll up/down, 106/107 prev/next,
  108/109 zoom in/out, 1003 exit to DOS [L], 1499 briefing-transmission → launch (§6) [M],
  1503–1506 map pan up/down/left/right, other 1xxx/2xxx = in-screen actions.
* Bitmap-button images (MTBmpButton ctor 0x1d47d) are frames of `RES32\CORNERS.DBA`, chosen by hotkey
  (+ id): Up/PgUp 20/22 (id 1503: 36/37), Down/PgDn 21/23 (1504: 38/39), Right 24/26 (1506: 42/43,
  2004: 45/47), Left 25/27 (1505: 40/41, 2003: 44/46), KP+ 28/30 (108: 32/33), KP− 29/31 (109: 34/35),
  ids 1806/2003 48/50, 1807/2004 48/49 (normal/pressed; disabled 51). Bitmap buttons with a hotkey get no
  text label.

`render_menu()` in shell.py composes background + panel + buttons + labels; the decoded rects land
exactly on the panel art for every menu (verified visually: MENU1000/1100/1200/1500/1610/1700/1800/1900/1510/999).

## 5. Other UI resources

* **`CFG\STYLES.DAT`** [H] `u16 n(4); n × { u32 colour[13]; u16 cornerIdx[4]; u16 bw, bh }` (64 bytes),
  loaded with `res32\corners.dba` at startup (0x7e97c). Drawn by the style-box routine 0x44b86:
  - `colour[0]` = **face**, filled over the rect inset by 3;
  - `colour[1..4]`, `[5..8]`, `[9..12]` = three 1-px rings at inset 0 / 1 / 2 (0x44dc8), each in the order
    left, top, right, bottom, without the corner pixels; colour 0 = not drawn;
  - `cornerIdx` = CORNERS.DBA frames (3×3) top-left, top-right, bottom-left, bottom-right at
    (x1 | x2−bw, y1 | y2−bh) (0x451c1). Rects are inclusive (x2, y2 are the last column / row).

  | style | face | use |
  |---|---|---|
  | 0 | 0x15 light grey | MTButton normal, panel-less window |
  | 1 | 0x1b dark grey (sunken rings) | MTButton pushed |
  | 2 | 0x19 mid grey | MTButton inactive (disabled) |
  | 3 | 0x1f near black | text fields (remake: edit-box frame, hangar info plate) [M] |

* **MTButton** (ctor 0x1cde8, draw 0x1d200) [H]: state +0x19 (0 normal, 1 pushed, 2 inactive) picks the
  style (`[0x82654] + 0x40·state`) and the font (ACTIVE / PUSHED / INACTIVE, +0x24..+0x2c). The label is
  centred over x2 − x1 (0x520d8, justify 2) with its baseline at y2 − (h − fontHeight)/2 − 2; pushed text
  is 1 px lower (same x). ACTIVE letters are 0x1c (dark) with a 0x14 highlight row under them (engraved
  text on the light face); INACTIVE 0x1d / 0x18 on the mid-grey face; PUSHED 0x1e. A "selected" button
  (+0x94) also gets a 1-px rectangle in UI colour 10 (blue) round its whole rect (0x4b867, fill type 4 =
  outline); the remake shows it on the highlighted button (mouse / keyboard / gamepad).
* **Fixed bug (remake, 2026-10):** "button labels look like broken stripes, dim grey on dark grey". The
  DFN decode was right (8bpp, row-major, width × height, all glyphs solid — checked at 8× for every
  font). The shell filled buttons with `colour[1]` (0x1d, the dark outer ring) instead of `colour[0]`
  (0x15 face), so the dark 0x1c letter rows vanished into the face and only the light 0x14 highlight
  rows showed — every other row of each glyph. Fixed in `ShellStyle` / `ShellButton`
  (games/es1/shell) and in `render_menu()` (tools/shell.py).
* **Remake CRT gamma** (not an original setting): `DisplaySettings` (`crt_gamma` in user://settings.json,
  default 1.2, Options → Display) shows each palette colour as c^(1/gamma). VGA DAC values looked
  brighter on a CRT than on an sRGB LCD; 1.0 shows the raw DPL values. The frame buffer and palettes stay
  exact (ShellScreen applies it when building the palette texture); the cockpit can use the same key.
* **`RES32\CORNERS.DBA`** 52 frames: 0–19 bevel corner pieces, 20–51 bitmap-button images (§4).
* **`RES32\TEXTBOX.DBA`** 288×29 text box frame (dialog.cpp, `res32\textbox.dba`). CONTROLS.DBA, CHECK.DBA,
  BLUEBAR.DBA: control-screen icons, check box, bar graph.
* **Cursors `*.DCI`** [H] header(type 0x0b, class 0x28), `s32 hotX, s32 hotY`, then a DBM.
* **`BND\*.BND`** [M] per-class persisted parameter blocks: `u32 stamp` (class version) + packed
  class-specific fields (u16 mostly; e.g. CTL_ALRT/CAL_ALRT alert layouts, MAP/SHELLMAP map-gadget
  zoom/scale constants, MAIN). Exported raw as words; field meanings not decoded.
* **`SNC\??_FILES.DAT`** [H] 256-byte buffer: `u8 n; char ttm[]; n × { u8 k; k × char name[] }` —
  the sync TTM + (SNC, RAW) pairs of a speaker (only the first entries fit). (SNC itself: see audio_video.md.)
* **`CFG\TM_FILES.DAT`** whitespace list of TTMs preloaded by the shell.

## 6. Backgrounds and screen flow

Shell backgrounds are `RES32\REGN<r>.DBM` (320×200) with `REGN<r>.DPL`. GO.EXE 0x40afa maps the menu id to a
region (table 0x821a8); menus not listed (popups) keep the current region. Region change (0x395a0) also
picks music (table 0x817d0: region/1000 → sound ids 1,1,3,4,3,3,1 = menu, menu, shella, shellb, shella, shella, menu;
see audio_video.md §3) and for 3000 adds the campaign index to the
palette (REGN300c) (0x3950a).

| region | picture | menus |
|---|---|---|
| 1000 | EARTHSIEGE/METALTECH plate | 1000 main, 1100 single mission, 1200 career, 1310 prefs, 1320 controls, 9999 loading (+ popups 1110,1210–1270,1300,1330,999) |
| 3000 (+c) | war room, commander C<c> | 1499 campaign briefing transmission |
| 4000 | herc hangar | 1700/1710 hub bars, 1800/1820 arming, 1900 repair, 2000 build, 1610 crew (full-screen panel, REGN1610 pal), 5555 tech release |
| 5000+c | debriefing officer D<c> at desk | 1510/1520 debriefing |
| 6000 | tactical map console | 1500/1501 mission briefing map (MapGadget, pan/zoom) |
| 7000 | video monitor | 1490 general (G0) transmission |
| 2000 | herc arm in dark bay | not referenced by the menu table (unused?) [M] |

Screen flow (from DLG targets + GO.EXE 0x3ba47 / menu dispatch table 0x82060):

```
startup (mode 0): intro\dynamix.ttm → lead_in.ttm → iintro.ttm → earth_w.ttm → anm\esiege2.anm
   → MENU1000 MAIN (REGN1000)          [mode 6 skips the TTM intro]
MAIN: INSTANT ACTION → 1499 (briefing transmission → sim) | SINGLE MISSION → 1100 | RESUME → 1700
      | CAREER → 1200 | OPTIONS → 1300 | EXIT TO DOS → 999 confirm
1100 SINGLE MISSION: MISSION PARAMS → 1110 popup | OPTIONS → 1300 | RETURN → 1000 | BRIEFING → 1501
1200 CAREER: NEW → 1210 registration | STATS → 1230 | DELETE → 1270 | OPTIONS → 1300
      | SAVE/RESTORE → 1220 | MAIN → 1000 | PROCEED → 1700
1300 OPTIONS: PREFERENCES 1310 | CONTROLS 1320 (CTL_ALRT) | LOAD BATTLESET 1330 | VIEW DEMO | CREDITS
      (intro\credit_a.ttm, credit_b.ttm)
1700 hub (bottom bar over hangar): MAIN | ARMING 1800 | CREW 1610 | BRIEFING 1500 | BEGIN MISSION
1500/1501 briefing map: SERVICE BAY → 1700 / ARMING → 1800 | CANCEL | BEGIN MISSION
   (warnings before launch: 3000 unarmed, 3333 no herc, 7770/7771 disabled herc)
launch → GO writes data\script.dat etc. and runs DBSIM
return from sim (modes 3/4, 0x3ba93; career): pilot killed → endfa.ttm; campaign won → end_win1..3.ttm +
   intro\earth.ttm; campaign lost → failed.ttm + intro\earth.ttm (each then main menu; songs in audio_video.md §3);
   else region 5000 → 1510 (single) / 1520 (career) DEBRIEFING
1520 → PROCEED → 1710 career hub: CAREER 1200 | REPAIR 1900 (→1910 prefs, 1920 per-system, 4444 scrap)
   | BUILD 2000 (→2010 salvage) | NEXT MISSION → 1499
```
`out/dlg/menu_graph.json` has the full machine-readable graph.

Remake (saves, `campaign_availability.md` §9): careers and CAREER BACKUPS (1220: SAVE 1221 / RESTORE 1222,
list 1223; 1240 warns that a backup of that name exists, OVERWRITE) live in the shared save store (`SaveGames`;
`ShellCareers`, `ShellBackups`), so the app's Save / Load sees the same saves. DELETE (1201) asks with 1270
first. A killed pilot no longer ends the career: after death + ENDFA the career goes back to the restore
point written at launch and 1250 (the killed-in-action notice asking for a backup restore)
shows over the main menu with an added REPLAY (flies the mission again) next to DONE (main menu; the career
stays at its last save). PROCEED / RESUME with a won or lost career shows 1260 CAREER OVER.

Other full-screen art (palette = same-name DPL unless noted): `INTRO\IA..IM.DBM` (intro slides, INTRO.DPL),
DYNAMIX, EARTHSG, CREDIT_A/B (CREDITS.DPL), `A/B/D/G_BG.DBM` + `x_PAL.DPL` (campaign-intro "camni"
scenes, a/b/d/g_camni.ttm, one per campaign world), CAMLOSE, CAM_WLD1, END_WIN, FAILED,
ENDF_MON/ENDF_SCN (ENDF.DPL). `palette_assignment.json` records the palette used for every exported image.

## 7. TTM scene scripts (Dynamix TTM 4.14) [H unless marked]

Same family as ScummVM `dgds`. Chunked file (`tag[4]`, `u32 size`, bit31 = container):
`VER:` "4.14\0" · `PAG:` u16 frameCount · `TT3:` u8 compression (1 = RLE: b&0x80 → repeat next byte
b&0x7F times, else copy b bytes; all ES files use 1), u32 unpackedSize, data · `TTI:` container ·
`TAG:` u16 n, n × {u16 labelId, char name[]}.

Bytecode: `u16 op`; low nibble = number of s16 args; nibble 0xF = one NUL-terminated string padded to even
length. Opcode→name table at GO 0x833b0 (names `TOKEN_*`, full list in `TTM_OPS`). The script is split into
**frames** at each `ENDFRAME 0x0ff0` (index built at 0x480d1; PAG = number of frames). Interpreter:
0x48218 (`run frame`), dispatch tables 0x83880 (control) and 0x839b8 (graphics, handler 0x4a213).

Runtime model (verified by rendering intro/briefing scripts):
* Two layers: **background** and **screen**. Every frame the screen is rebuilt from the background, then
  the frame's draw ops are applied. `FIX_RECT(x,y,w,h)` (0x4204) copies that screen rect *into* the
  background (makes drawing permanent); `FIXBACK` (0x0020) commits the whole screen; `SCRNLOAD` sets the
  background. Fix ops only run on a frame's first execution (flag +0x42).
* Timing: `WAIT n` (0x1021) sets the frame delay to n ticks; the delay **persists** for following frames
  until changed (reload value +0x1ba, 0x4701e). Tick = **1/30 s** (TTM manager timer every 2 ticks of the
  60.02 Hz PIT, divisor 0x4da6; 0x4670e(2)) [M]. `RANDOM_WAIT min,max` (0x2022) = random delay.
* Flow: frames run sequentially; `LLABEL/GLABEL id` (0x1101/0x1111) mark frames (no-op);
  `JUMP_LABEL id` (0x1201) → next frame = frame of label; `ENDLABEL` (0x0110) stops the script (state 3);
  `CALL_LABEL dx,dy,id` (0x3003) runs the label's frame as a subroutine with a draw offset (added to x,y of
  all 0xAxxx ops, and to x2,y2 of LINE/POLY/NEW_PUT); `CALL_START id` + `CALL_OFFSET dx,dy,n` run frame
  base+n at an offset. `HOTSPOT` (0x5005) is a **weighted random branch**: the first HOTSPOT stores 5
  cumulative weights, the next one gives 5 labels; one is picked (`rand(sum)`) as the next frame
  (e.g. C0_BRD: weights 20,20,20 → "pos 1"/"pos 2"/"nothing").
* Resources (slot selected first with SHAPESELECT/PALSELECT/FONTSELECT): `SHAPELOAD "x.BMP"` → `x.DBA`,
  `SCRNLOAD "x.SCR"` → `x.DBM`, `PALLOAD "x.PAL"` → `x.DPL`, `FONTLOAD "x.FNT"` (IINTRO only; file absent).
* Drawing: `DRAWBRUSHm x,y,frame,slot` (0xa504 + 0x10·m) draws DBA frame; m = flip mode 0..3
  (bit0 h-flip, bit1 v-flip [M]). `RECTFILL x,y,w,h` / `LINE x1,y1,x2,y2` use colour from
  `PALETTE fg,bg` (0x2002) [M]. `FADE_IN/FADE_OUT first,count,colour,speed` [L arg meaning].
  `HDS_LOAD/PLAY`, `VOLUME_SX` = sound (6 uses).
* Ops used by ES: ENDFRAME, DRAWBRUSH0/2, PALETTE, CALL_LABEL, WAIT, LINE, RECTFILL, GLABEL, RANDOM_WAIT,
  SHAPESELECT/LOAD, HOTSPOT, ENDLABEL, FIX_RECT, JUMP_LABEL, LLABEL, FADE_IN/OUT, SCRNLOAD, PALSELECT/LOAD,
  FIXBACK, NEW_PUT(3), GET(2), PUTSELECT(2), FREESHAPE(2), FONTSELECT/LOAD(1), GETTEXTSTART(1), HDS_*.

Talking heads (speech + subtitle sequences, GO 0x37eac with modes → `eng\G0/C%d/T1/D%d_text.bin`):
`<X>_SYNC.TTM` has one frame per mouth/pose shape (frame index = SNC tag) drawn over a region background:
C0–C3 campaign commanders on REGN3000 + REGN300c palette (with C?_BRD/BRJ ambient staff), D0–D3 debrief
officers on REGN5000+c, G0 on REGN7000 monitor, T1 hangar chief on REGN4000 (all verified visually).
General Gierling (MENU1490, region 7000): at the start of every campaign c (0..7) GO.EXE 0x37f1e plays G0_TEXT lines
from table 0x814ec until -1: [0,1,2,3,5,54] [6,8,9,54] [10..18,54] [19..26,54] [27..32,54] [33..41,54] [42..47,54]
[48..53,54] (54 = "Gierling Out."), over that campaign's world song. G0_ON / G0_OFF / G0_STAT are not referenced
by GO.EXE (leftovers): the monitor shows him at once. (`ShellSequences.play_general_for_campaign`.)
Other TTMs: A/B/D/G_CAMNI (campaign intro with caption DBAs), PILOT_n (crew portraits, REGN1610), *WELD*,
*WLK*, FLIP*, ELEV_*, LIT*, NUMBERS, SOUNDS (hangar ambience), W1800* (arming weapon anims), END*/FAILED/CAMLOSE.

## 7b. Career hangar (inventor.cpp / mechman.cpp) [H unless marked]

`tools/export_shell.py --hangar` exports the start hangar, armory and tech tables to `shell/hangar.json`
(used by `Es1Tech`: the career's garage seed and tech releases). The game draws the hangar in 3D and
uses the app's Hangar screen (campaign_availability.md section 6); the original 2D hangar art below
is documented but not exported or drawn.

* Herc types 0..7 = ROADRUNN, GUNSLING, RAPTOR, TOMAHAWK, PATRIOT, PANTHER, HERCULES, COLOSSUS (sim MECH order).
  Art prefixes `ROAD GUNS RAPT TOMA PATR PNTH HERC COLL` (`RES32\<p>WEP1/WEPD/OUTL.DBA`, name tables
  0x800f4/0x801ac/0x80264), CFG prefixes `ROAD GUNS RAPT TOMA PATR PANT HERC COLO` (0x804d0).
* **Bay Herc**: `<p>WEP1` frame 0 = body, drawn at a per-type point (static init 0x25090 → table 0xa0398,
  draw 0x23846): (77,99) (77,89) (83,64) (86,53) (75,57) (73,37) (72,37) (58,26) — every body ends on row 200.
* **`CFG\<HERC>.DAT`** weapon pieces: `u16 n_hardpoints`; per hardpoint `u16 k`, k × `{frame, weapon, x, y,
  outline_x, outline_y}` (s16). Entry 0 is the empty marker (weapon 17, `OUTL` frame 0 at outline_x/y);
  the others: `WEP1[frame]` at (x,y) when that weapon is mounted, `OUTL[frame]` at the outline point
  marks the selected hardpoint. Pieces are drawn from `WEPD[frame-1]` when the weapon's condition ≤ 50
  (0x22cee). Hardpoint index = GL loadout slot. Only some weapons have a piece per hardpoint (the list
  also reads like the original per-hardpoint weapon whitelist) [M].
* **`CFG\HOTSPOT.DAT`**: `u16 8`, per type `u16 n` + n × rect (x1,y1,x2,y2) = click areas of the hardpoints.
* **`CAR\CAR_INIT.DAT`** (new career) / **`SM_INIT.DAT`** (single missions): 14-byte header (word 6 = Herc
  count), per Herc `{slot, type, n, n × weapon (17 = none), n × missile type (0..3 SARH/ARH/ARM/EO, 5 = n/a),
  u16 (2) [L], 33 × condition %}`, weapons in loadout-slot order. A new career owns 2 Roadrunners
  (ATC20 ×2 / LAS100 ×2) and 2 Gunslingers (LAS200 ×2 / ATC35 ×2), large hardpoint empty.
* **`CAR\C_ARMORY.DAT`** / **`S_ARMORY.DAT`**: `u16 n`, n × `{weapon, count, count × condition %}` — the
  starting weapon stock (career example: ATC20 4, LAS100 5); the importer writes the full stock to
  `shell/hangar.json` `career_armory` / `single_armory` (`tools/export_shell.py`).
* **`ZONES\BST\TECH_0.DAT`** / `TECH_SNG.DAT`: tech releases by missions flown (GO.EXE 0x158ff, 0x1f78);
  layout and values in `docs/formats/campaign_availability.md` §5, exported to `hangar.json` `career_tech`.
* Shell weapon index = WEAPONS.DAT order (gameplay.md §4); `W1800W<nn>.TTM` / `W1800R0<t>.TTM` are the
  arming-screen weapon / missile-type animations, `BLUEHERX.DBA` (8 frames) the BUILD blueprints,
  `ALLWEAP.DBA` 18 weapon silhouettes. FabricationMenu prints `%d TONS`, `%d KPH`, `%d WEAPONS`.
* Salvage economy (decoded, campaign_availability.md section 7): new career pool 60000 kg (0x163ec);
  Herc tons / price / km/h / build time tables 0x808a8 / 0x808b8 / 0x808c8 / 0x808d8 (BUILD 0x29d68 takes
  price x 1000 from the pool `[0x7fcf0]`); `CFG/DAMAGE.DAT` repair costs (loader 0x387ac: factor,
  6 armour + 10 system weights, weapon factor, 18 weapon costs); after a mission the sim's salvage
  `[0x7fcf4]` joins the pool (0x390c9) and recovered weapons below 80 % are sold (0x24d5a).
  CREW (1610, CrewAssignMenu, `RES32/PILOTS.DBA` portraits): pilot names from `CAR/NAMES.DAT`
  (u8 12, 12 x {u8 k, k names}: the pilot and two replacements). Not decoded: the 1803 anim-list
  behaviour.

## 8. Unknown / open
* DFN header fields 0x10/0x16 (8 = bits per pixel? font+0x12 in memory)/0x1a (7, subtracted from the text
  y in 0x52004 — baseline offset? but TITLE is 18 high with 7 too); BND field layouts.
* Window title placement (composite uses centred text at y+4 — visually right but not traced).
* Types 4 vs 5 justification direction; type-14 gadget content per id; list data sources (table 0x81a00).
* Commands 1003/1490/1499 handlers only partially traced; demo/credits path; 1320 controls screen uses the
  CTL_ALRT alert class (STR + BND) instead of a DLG.
* FADE_* argument semantics; NEW_PUT/GET/PUTSELECT (used 2–3×).
