# Earthsiege 2 (Dynamix / Sierra, 1995-96) — disc catalogue, formats, units

Disc: `<iso dir>\earth_siege_2.iso` (plain ISO 9660, no Joliet), "EarthSiege II version 1.0".
Tools: `tools/extract_iso.py` (→ `es2/original/`, tree in `es2/original/_tree.txt`, 711 files),
`tools/es2_vol.py` (→ `es2/extracted/<VOL>/<DIR>/<FILE>`, 3004 files),
`tools/export_es2.py` (→ `gamedata/es2/`, proof of life), `tools/preview_gamedata.py`, `tools/scale_lineup.py`.

**Summary: ES2 is still 3Space v2.** VOLN archives, DTS/DGS shapes, DBA/DBM bitmaps and DPL palettes are
the Earthsiege 1 formats; `tools/vol.py`, `tools/dts.py`, `tools/gfx.py` and `export_es1.shape_to_json`
work unchanged. What changed: Win32 executables, heightmap terrain, WAV audio, AVI video, longer unit/weapon
records, new mission records, flyers.

## 1. Disc layout

| path | contents |
|---|---|
| `ES.EXE` (launcher), `VSHELL.EXE` (shell, Win32, `src\vshell.cpp`, `src\volume.cpp`), `DBSIM.EXE` (sim, Win32 PE, 724 KB; asserts `base.cpp`, `rocket.cpp`, `BEAM.CPP`...) | Borland C++ 4.x runtime (`CW3220.DLL`, `BWCC32.DLL`), HMI SOS audio (`SOS9503.DLL`, `SOSLIBS3.DLL`, `HMI*.WIN`), `DDRAW.DLL` |
| `VOL/` | `SIMVOL0` (30.8 MB, 1300 files), `SHELL0` (170), `ZONES` (202), `SIMSOUND` (641), `SIMVOICE/F/G` (213 each, English/French/German), `SIMALERT` (23), `SIMPATCH` (3: RESULTS.BND, FLYERS.HBA, SPIDER.PDG), `SHLSOUND` (5), `LANG0` (ENG/FRE/GER string tables) |
| `AVI/` | 93 cut-scenes/briefings (C1-C5 campaign intros, INTR_PT1/2, CREDITS, VICTORY, DROPSHIP, sector fly-ins `ALPHA/BRAVO/DELTA/OMICRON/LUNA`, per-event clips). Indeo 3.2 video (fourcc `IV32`, decodable by ffmpeg) |
| `SIMVOICE/` | loose WAV radio chatter (TM1_*, TM2_* ...) |
| `TAPES/DEMO1-3.TAP` | recorded demo playbacks (cf. ES1 demo tapes) |
| `DATA/`, `SAV/` | default config (`KEYJOY.CFG`, `PREFS.CFG`, `SOUND.CFG`), `MAT0.DAT`, `MFORMS.DAT`, `MISSION.STR`, `MAPLABEL.STR`, `GAMEFILE.STR` |
| `ENGLISH|FRENCH|GERMAN/` | `ES2GUIDE.HLP` (WinHelp manual — **source of Herc heights/speeds in metres/KPH**), `README.WRI`, `ES2TS.TXT`, `BILLBRD/LOAD1.BMP` |
| `DEMOS/` | other Sierra products (A-10, Bass, 3D Ultra Pinball, movie trailers) — not ES2 |
| `DIRECTX/`, `DRIVERS/DIAMOND/`, `INDEO/`, `AUTORUN/` | third-party installers |
| `ES2_FLCS/TQS/WCS.*` | ThrustMaster programming files |

All VOL entries are type 0x02 (stored); headers differ from ES1 only in the 4 flag bytes.

## 2. SIMVOL0 contents (vs ES1)

| dir | ES2 | notes |
|---|---|---|
| `DTS` (55) + `DGS` (BASES, BHULKS) | Hercs, Cybrids, flyers, `*_DEB` debris, bases, weapons (`MECHWPNS/MECHWPN2`), effects | **`dts.py` parses all 57 with no errors.** Hercs = 7 top-level `an_shape` LODs, 12 nodes, 8 sequences (ES1 layout); Pitbull 20 nodes; Razor 2 nodes/1 seq; Skimmer static |
| `DBA` (126), `DBM`, `DPL` (32 sim + 33 shell) | `gfx.read_any` / `gfx.read_dpl` read all of them | texture sets: `LIGHT`(24) `MEDIUM`(36) `HEAVY`(41) `NEWHERCS`(44) `APOCATEX`(53) `ENEMY`(45) `RAZORTEX` `VEHTEX` `WPNTEX` `BASETEX` `BEAMTEX` |
| `DAT` | unit DATs are **216 bytes** (ES1 192), `WEAPONS.DAT` 3790 bytes / 33 records (ES1 17), `PROJ.DAT`, `ROCKETS.DAT`, `BULLETS.DAT`, `BEAM.DAT`, `BFORMS/FFORMS/MFORMS` (formations), `TEX.DAT`, `SHADES.DAT`, `STYLES.DAT`, `COLORS.DAT` | first 0x56 bytes of unit DAT match the ES1 table in `docs/formats/gameplay.md` (0x04 speed_forward_max, 0x4c mass, 0x56 name) |
| `GL`, `DMG`, `COL`, `PDG`, `NAM` | per-unit gun lists, damage, collision, ... | same families as ES1 |
| `WLD` (10) | ~312-byte world files, v2 layout (§3.2) | `tools/export_es2_world.py` (`parse_wld2`) |
| `RMP` (10) | per-world textured-ground remap tables, 12 haze rows x 32 light levels (§3.3) | new |
| `FM` (RAZOR, SKIMMER) | 54-byte flight-model parameters | new (flyers) |
| `DB0-2`, `ED0-3`, `GAU`, `VUE`, `OFS`, `EDG`, `HD0-3`, `HB0-2`, `HBA`, `HFN`, `DFN`, `DCI` | cockpit overlays, gauges, views, HUD fonts/bitmaps for the 9 pilotable Hercs | same families as ES1 cockpit (`docs/formats/cockpit.md`) + HD/HB (HUD) |
| `SNC` (556) | 30-byte lip-sync/subtitle cue lists for radio voice (`PA_xxxxx`) | new |
| `STR` | pilot/command/system string tables | |
| `BND` (83) | parameter blocks as ES1 | |

## 3. Terrain — now a heightmap

Exporter: `python tools/export_es2_world.py` → `gamedata/es2/worlds/world<n>.json` (+ `es2_ground_<n>_<m>.png`,
`es2_rmp_<n>.png`, `_index.json`) and `gamedata/es2/terrain/<zone>/{terrain.json, heights.r32, materials.png,
preview.png}` + `terrain/_index.json`. It checks the DBSIM code bytes it relies on. Godot side:
`WorldBuilder.build(parent, world, zone, "es2")` (`game/games/es1/world_builder.gd`), shader
`game/engine/shaders/es2_terrain.gdshader`, test `game/tests/es2_world_shot.tscn`.
VAs are DBSIM.EXE 1.0 (image base 0x400000; CODE file offset = VA − 0x400A00, DATA = VA − 0x401000).

### 3.1 World / zone selection (H)

The script loader (`0x424647..0x4246c9`) reads the first **20 bytes of `data\script.dat`** (10 s16 words,
the same header the mission compiler emits as `mission.header.raw`) into `0x4a9ed2`, zeroes word 2, then
calls `world_load(&hdr)` `0x42e010`, which copies it to `0x4cfd48` and computes

    n = word0 * 2 + word9          (0x42e042: ax = [W+0]; dx = [W+0x12]; bx = ax+ax+dx)

`sprintf("world%d")` → palette `WORLD<n>.DPL` (`0x42e093`), `WORLD<n>.WLD`, optional `WORLD<n>.CYC` (none
ship), `SHADES.DAT`, `WORLD<n>.RMP`. By content: word0 = world type (0 `urban`, 1 `bsnow`, 2 `volcan`,
3 `ice`, 4 `moon` — the WLD ground texture), word9 = 0 day / 1 night (odd WLDs: 15 sky bands, ground 0xe0,
haze target = ramp start i.e. dark; WORLD8/9 are both black-sky moon). GDScript: `WorldBuilder.es2_world_index(raw)`.
The zone is word1: `zone_load(word1)` `0x42789c` (called from `0x4252f7`); word1 < 0 → no terrain.
The MSN header records seen so far carry `(1, zone, 0, …, 0)`: word0 = 1 is the compiler's "unset" default
(cf. ES1, where the shell overrides word0 per campaign) — the ES2 shell must supply word0/word9 (not traced).

### 3.2 WLD v2 (H layout; read order of `0x42e0f8..0x42e520`)

| off | type | use |
|---|---|---|
| 00 | s16 | horizon_offset → horizon+0x6c (2) |
| 02 | s16 | sky_first (0xd0) — arg of `0x42ebbc` |
| 04 | s16 | sky_band_px → +0x54 (6) |
| 06 | s16 | sky_count → +0x58 (16 day / 15 night): bands `sky_first+count-1` (horizon) … `sky_first` (zenith) |
| 08 | s16 | ground_first (0xef day / 0xe0 night); `[0x49aee8]` = first+count−1 |
| 0a,0c | s16 | ground_band_px, ground_count (1, 1) |
| 0e | s16 | horizon field (0), arg of `0x42ebbc` |
| 10 | s16 | read, unused (0xe9) |
| 12 | s16 | flat variant → `[0x49aeea]` → `0x4097a8` (1) |
| 14,16 | s16 | cockpit ambient low/high palette index → `0x4cfd76/78` (0x2f, 0xdf) |
| 18,1a | s16 | **new in v2** (6000, 7): read into locals and dropped |
| 1c | u32 n + n×u32 | object haze thresholds → `[0x4cfd84]` (16: 60000…126000 step 4400) |
| … | u32 n + n×u32 | terrain haze thresholds → `[0x4cfd88]` (same values) |
| … | u16 | haze levels (16) |
| … | u16 nr + nr×(u16,u16), u16 nt + nt×(u16,u16) | 11 lit ramps + haze targets (ES1 had 8) → `0x430d08` |
| … | 4×u16 | glow ramp 0x56/16 → 0x66 |
| … | s16, s16 | (20, 250) ES1 cloud/decal counts — read into locals, **unused** |
| … | s32, s32 | haze offsets low/high → `0x4cfd6c/70` (−10000) |
| … | 5 cstr | `world24`, `clouds2` (both **read and dropped** — the `if` around them was compiled out, and neither DBA ships: ES2 has no panorama strips and no cloud layer), impact palette (`impact<n>`, `0x474ba4`), ground texture DBA (`urban`, `bsnow`, `volcan`, `ice`, `moon` → `0x46bc98`), `tex` (dropped) |

Sun (`0x461240`, H): one directional light, intensity 0x100, vector (0, 0x1000, 0) rotated by euler
(0xe890, 0, 0x5208) (`0x47eaac`/`0x47ffb4`); assuming Rz·Ry·Rx (as ES1) L ≈ (−0.758, −0.359, −0.544) (M).
Flat ground: I = 256(1 − n·L)/2 = 197.

### 3.3 Ground texturing: MAT0.DAT + ground DBA + RMP (H unless noted)

* `<ground>.DBA`: 13 bitmaps 256×256 (texture 0/1 = plain ground, 2..12 = pads, foundations, craters).
* `DAT\MAT0.DAT` (`0x46c69d`): u32 n (13), n × (u32 texture, u32 b) — material m uses texture m with
  texel = 2^(13−b) units (b = 6 → 128 u = 0.5 m, one texture repeat = 128 m; b = 5/4 → 1 / 2 m texels).
  UV per cell (`0x46bcf4`): shift = k + b − 13, u = (cx << shift) & 255, v = −(cy << shift) & 255, i.e.
  u = x / texel, v = −y / texel (engine: v = +z / texel). 136 trailing bytes are not read here.
* Cell material (cell+0xf >> 2, `0x46c4e9..0x46c5cf`): one random choice per texture tile
  (2^(21−b−k) cells): `rand() & 0xfff < 0x4ce` (30 %) → material 1, else 0. Structures later stamp their
  own material over the cells under them (`0x405db0` → `0x471260(terrain, pos, mat, mask, size)`, from the
  base type table at `0x4a9630`: +8 material (−1 none), +0x14 mask bitmap, +0x18 size) — not exported.
* `WORLD<n>.RMP` (`0x42e60c`): u32 32 (light levels), u32 12 (haze rows), then 384 × 256-byte remap tables,
  256-aligned at `[0x4a09b0]`. Textured polys use table `((32−1)·I) & ~0xff` (`0x475133`) = light level
  (31·I)>>8 (flat ground → 23, ≈ identity) in haze row 0; row 11 maps everything to the haze colour (≈ the
  sky horizon colour; night/moon: dark). Row-vs-distance mapping of the 12 haze rows not traced (L): the
  engine uses linear depth fog from the first to the last terrain threshold (234 → 492 m) in the row-11 colour.
* Engine (`es2_terrain.gdshader`): textures 0/1 baked through RMP[row 0][level 23] to RGB; brightness for other
  slopes = `light_curve[(31·I)>>8]` (luminance ratio of the RMP tables over the texels in use).

### 3.3a Shape colours: shade lists, RMP light, cockpit block (H unless noted)

How Herc and Cybrid skins are coloured; the engine reads the same lookup images as for Earthsiege 1
(`Palette.look`, `gamedata/es2/worlds/shade_<n>.png` and `texlight_<n>.png`, written by
`tools/export_es2_world.py`).

* **Shaded polys** (colour dword `{u16 slot, u8 I, u8 4}`): `WORLD<n>.DPL` carries the ES1 tail of 256 shade
  slot lists (`world.read_dpl_full`), and `SHADES.DAT` has the ES1 layout. Slot 2 = 0x70–0x7f (brown),
  4 = 0x84–0x93 (olive), 8 = 0xac–0xbb (blue-grey), 12 = 0xc0–0xc6 (dark grey), 0 = 0xc4–0xcb (grey).
  Colour = `palette[list[(I·len) >> 8]]` as in ES1 (`docs/formats/world.md` §4; M: the ES2 shaded-poly
  rasteriser itself was not re-traced, the data is identical in form and fits the ramps).
* **Textured polys**: no ES1-style 8 remap tables (no `0x28a` builder in ES2). The rasteriser picks
  `RMP + (((levels − 1)·I + haze_row) & ~0xff)` (`0x468054`; levels `[0x4d3d38]` = 32, haze offset `[0x4a08c8]`),
  so an unfogged shape uses RMP haze row 0, light level `(31·I) >> 8`. The engine's `indexed.gdshader`
  takes the level count from the texlight image height (ES1 8, ES2 32).
* **Cockpit block 0x2A–0x41**: the DPLs hold bright green placeholders there. `0x429ac4` copies
  `COCKPIT.DPL[0x20 + 24·k …]` into those 24 slots (`0x4303c4(first 0x2a, count 0x18, src)`, k = word +0x52 of
  the Herc's unit record — L: field meaning), and again from `IMPACTCP.DPL` for the hit flash. The RMP light
  tables map a few Herc texels into this block, so `export_es2.make_world_palette` fills it with scheme 0.

**Bug this explains (fixed):** without `shade_<n>.png` the engine fell back to an identity table, so slot s
drew raw `palette[s]`: the VGA colours 0x00–0x0f (slot 2 → (0,130,0) green, 4 → blue, 12 → orange), the large
green patches on Outlaw / Apocalypse and blue ones on Ogre. `tests/hangar_check` (`_check_original_colours`)
guards it.

### 3.4 Heightmap terrain (H)

`ZONES/DBA/ZONE<n>.DBA` holds one 8-bit bitmap (128² or 256²) = the height field; `ZONES/DAT/ZONE<n>.DAT`
is 4 × i32 `(log2 w, log2 h, k, s)`. Zone loader `0x42789c`: reads log2 w/h, creates the terrain (`0x46bdf8`,
0x129 bytes), `+0x108 = k`, `+0x118 = s`, `+0x10c = k > 14 ? 10 >> (k−14) : 10` (draw radius in cells),
offset `+0xf4..+0xfc = 0`, then `0x46c650(terrain, "zone<n>.dba", 0)` → `0x46c3c0` builds the cells
(16 bytes each, row-major, `+0xec`) **taking w/h from the bitmap** (ZONE7000.DAT says 7,7 for a 256² bitmap).

* **Rows are flipped**: bitmap row r → cell row cy = h−1−r, so bitmap row 0 is the north edge (+y).
* Vertex (cx, cy) = (cx << k, cy << k, pixel·s + min(0)) + offset(0) (`0x46d953..0x46d9b7`): **k = log2 square
  size in units, s = units per height step** (k = 12..15 → 16/32/64/128 m squares; s = 90..256 → max 89..199 m).
  Normals use (Δh, Δh, (1 << k)/s) (`0x46c0f6`); each cell picks its diagonal from the corner sums (+0xf bits 0-1).
* **Anchored at the corner**: cell = position >> k (`0x470910`, no offset) → the grid spans original
  x, y ∈ [0, (w−1)·2^k]. Mission points fit (C1_01 on ZONE123: x 0.66M..3.27M, y −0.07M..3.0M of 4.18M).
* **No wrap/tiling**: cell lookups outside the grid return NULL, the draw rectangle is clamped to the grid
  (`0x46cb2a`); beyond it only the horizon ground band is drawn.
* Engine (`terrain.json`, map_schema "terrain"): square = 2^k/256 m, heights = pixel·s/256 m, origin
  [0, −(h−1)·square] (engine x = x/256, z = −y/256), heights.r32 rows = bitmap rows (row 0 = north = most
  negative z). WorldBuilder pads 2 km of edge-clamped heights around the grid (cosmetic + keeps strays on
  ground), adds a safety WorldBoundary at y = −100 m, and `WorldBuilder.ground_height(parent, pos)` samples
  the heightmap (0 outside). Approximation: MapBuilder triangulates every cell on the same diagonal.

39 zones; ES1's DGS terrain features are gone; bases still come from `BASES.DGS`.

## 4. Missions (`tools/mission_es2.py`, runtime `game/games/es1/mission/mission_compiler_es2.gd`)

`ZONES/MSN`: 62 `.MSN` + `.ENG`: campaigns `C1_01..C5_10` (5 x 10), `TRAIN1-8`, `DEMO*`. 61 parse exactly
to EOF; `DEMO2.MSN` is 42 bytes short (older build, skipped). Layout from VSHELL.EXE `src\msn_gen.cpp`
(compiler 0x417b67, ENG loader 0x41768c, debrief re-reader 0x41ca4e, lookup helpers 0x415a7c..0x415f5c,
duplicate mergers 0x4164a5..0x417286) (H for layout). All s16; each section = s16 count + records, in order:

| section | bytes | fields |
|---|---|---|
| cond | 14 | ES1 layout/rules; compare ops 0x119 `==` 0x11a `!=` 0x11b `<` 0x11c `<=` 0x11d `>` 0x11e `>=` (0x41cbfc); vars index up to ~830 (1000-var array assumed) |
| hdr | 82 | cond, f[40]: f0 if != 1, f1..9 if != 0, f10..39 if != -1. f0 world type, f1 zone, f3 mission type, f9 time of day (world = f0*2+f9, see §3) |
| value | 8 | id, cond, pick (-99 = override), value — numbers referenced by briefing/debrief (score) |
| briefing | 144 | cond, objective text ids[10], briefing text ids[30], intel text ids[30], value id |
| debrief | 64 | cond, text ids[30], value id — skipped by the compiler, re-read with the post-sim vars |
| point / heading / path / area | 22 / 10 / 10+2n / 12 | ES1 layouts. Points are in [0, zone extent] (grid corner = 0,0) |
| region | 82 | id, cond, pick, type, param, areas[8], n, (var, op)[10], text ids[5], message, target (table by type: 7 herc, 8 flyer, 9 structure, 10 group; 0x41a8b2) |
| timer | 30 | id, cond, pick, trigger region, delay, fire regions[10] (training region chains) |
| herc | 144 | id, cond, pick, u6, block[20] (w1 skill 0..256), type (MECHS.NAM), weapons[10] (WEAPONS.DAT rec, 0 none), point, heading, n, (var, op)[10], ammo[10], f88, alert region, death region, health |
| flyer | 102 | id, cond, pick, u6, block[20], point, heading, type (FLYERS.NAM), n, pairs[10], alert, death, health |
| struct | 62 | id, cond, pick, u6, type (BASES.DAT 0..64), point, heading, n, pairs[10], alert, death, health |
| order | 22 | id, cond, pick, u6, type, arg, point, path, target kind (0 group 1 herc 2 flyer 3 struct), target, region |
| group | 164 | id, cond, u4, block[20], kind, formation, point, heading, path, members[20], order ids[10], team, spawn region, n, pairs[10], w81 |
| objective | 58 | cond, required (1 goal / 0 failure condition), type, target kind, target, point, path, text id, n, pairs[10] |

ENG: `u16 n; n x {s16 id, s16 cond, s16 pick, u16 len, text}`; a later entry with the same id and a kept
condition replaces the text (0x4164a5). Records reference texts by id (briefing, debrief, regions, objectives).
Compile rules (conditions, random picks, duplicate-id patches, id -> script index) are the ES1 ones (mission.md §2)
with the per-section unset values of the ES2 mergers. Group 0 is the player squad; the player's Herc is its first
member (the herc the first objective targets); its first order's path is the nav route.
Export: `python tools/mission_es2.py export` -> `gamedata/es2/missions/{msn,eng}/*.json, index.json, tables.json,
campaign.json`; parity GDScript vs Python: `python tools/tests/test_mission_port_es2.py` (488 cases, 0 diffs).
Runtime: `MissionCompiler.load_mission("es2:C1_01", ...)` -> `MissionRuntimeES2` (Battle picks it for pack es2);
headless check `res://tests/es2_mission_check.tscn -- --missions=C1_01,... [--cheat]`. Semantics: §10.

## 5. Units

Pilotable Hercs (have cockpits: DB0/ED/GAU/VUE/HB0): **Outlaw, Raptor II, Tomahawk, Samson, Colossus,
Apocalypse, Ogre, Maverick** and the **Razor** flyer (`NAM/MECHS.NAM` order: OUTLAW RAPTOR2 TOMAHAWK
SAMSON COLOSSUS APOCA OGRE MAVERICK RAZOR ...). Cybrids: **Mongoose, Stingray, Mirimac, Ramses, Achilles,
Hyperion, Diablo, Headhunter, Scarab, Cerberus**, plus **Pitbull** (heavy walker, 20 nodes), **Arachnitron**
(SPIDER) and the **Skimmer** flyer. Shell `SHELL0/GAM` has per-Herc arming/repair/initial loadouts
(`ARM_*`, `RPR_*`, `INI_*`), `HERC_INF.DAT`, `CAREER.DAT`, `THEATER.DAT`, `MAP_*`.

**Exporter: `python tools/export_es2_units.py`** (needs `export_es2_weapons.py` output first) →
`gameplay/hercs.json` (21 MECHS.NAM units + SKIMMER, vehicle ids `es2:<NAME>`), `gameplay/bases.json`,
`gameplay/formations.json`, `units.json` (conversions + `hercs[]`), shapes, texture sets, cockpit overlays.
Verified in DBSIM.EXE (the exporter checks the bytes):

- **Unit DAT (216 b)** = ES1 192-byte table (`tools/units.py` field names) + `+0xc0..0xc4` (?) + `+0xcc` debris
  shape name (`outl_deb`). Changes: **`+0x94` is the texture-set index** into exe table 0x49a360 = LIGHT MEDIUM
  HEAVY ENEMY APOCATEX RAZORTEX NEWHERCS (0x41fe8f loads them; 0x420467 picks `[DAT+0x94]` for the shape and
  its debris) — so OUTLAW LIGHT, TOMAHAWK MEDIUM, SAMSON/COLOSSUS HEAVY, APOCA APOCATEX, RAZOR RAZORTEX,
  RAPTOR2/OGRE/MAVERICK NEWHERCS, all Cybrids incl. PITBULL and SPIDER ENEMY (H). Flyers (flyersys 0x422f38)
  use ENEMY. `+0x50` = shell Herc type (H?), `+0x4e` = 1 for RAZOR. Size class comes from
  `SHELL0/GAM/HERC_INF.DAT` (u16 9, 9 × {type, tons, shell km/h, hardpoints, salvage, ?, weight class 1..3, ?}).
- **Default loadouts:** `SHELL0/GAM/INI_<HERC>.DAT` = {herc type, 100, 0, n, n × (GL loadout slot, weapon index,
  100, missile type)}; missile type 5 → SARH (0x4100aa). Cybrid loadouts are not in the data (missions arm
  them); the exporter picks weapons by weight and hardpoint mask (L).
- **GL / DMG / COL:** ES1 layouts (`units.parse_gl/dmg/col` parse all 22). Mount nodes 66/77 are shape markers.
  STRINGS0 group 13/14 name the components (`F COCKPIT ARMOR` …, flyer `L NACELLE ARMOR` …).
- **Flyers:** `SKIMMER.DAT` 46 bytes (ES1 34 + name), `FM/<RAZOR|SKIMMER>.FM` 27 words (flight model,
  decoded in `flight_model.md` §1); RAZOR is a MECHS.NAM unit with a 216-byte DAT, no walk sequences (anim
  seq −1). Both exported with `"flyer": true` and flown with the shared flight model (pilotable).
- **Bases** (base.cpp 0x405fac): `BASES.DAT` = u16 65 + variable records {category, shape, hulk, animated,
  ?, …, n components × 15 words (hp, part, …), centre, …, 8 tail words}; `+6 != 0` → shape from `BASES_AN.DTS`
  (8 objects) else `BASES.DGS` (45 objects); texture set VEHTEX if tail word 7 ≠ 0 (type 52 RAZORTEX), else
  BASETEX; `BHULKS.DGS` (16 hulks) BASETEX (0x405ebc, H). Cybrid bases are separate types (no BASES_E).
  Names: tail word 2 → STRINGS0 group 23 (group 24 for the ground vehicles 45..64) (M).
  `BFORMS.DAT` changed: u32 17 × {u32 n, n × (s32 x, s32 y, s16 heading), u32 zone, 2 × s32, u32 rows,
  rows × (u8 len, bytes)}; MFORMS/FFORMS keep the ES1 layout.

Weapons (`LANG0/ENG/WPN_DESC.BIN`): ATC 20/35/50/75/100 mm, ELF / ELF 2, EMP / EMP 2, Laser 100-500 GW,
Particle Beam / PBW 2, Plasma Cannon, MLRS 6/8/10, Razor missile launcher, Locust AEW launcher, Mine
launcher, Magnetofusion Assault Cannon, ECM pod; missiles SARH, ARH, anti-radiation, electro-optical.

## 6. Units / scale (`gamedata/es2/units.json`)

**metres_per_unit = 1/256 (0.00390625)** — the same as ES1, from geometry:

| Herc | posed height (units, LOD 0) | manual height (m) | units per m |
|---|---|---|---|
| Outlaw | 1700 | 6.1 | 279 |
| Samson | 2364 | 9.2 | 257 |
| Colossus | 2460 | 10.4 | 237 |

Example rows; ten Hercs were measured. Mean 261 units/m (±8 %). ES2 re-uses ES1 geometry (Tomahawk, Colossus, Achilles, Spider identical
sizes; ES1 Hercules == ES2 Samson), so ES1 and ES2 must share one scale.

**Conflict to keep in mind:** weapon ranges in the shell text match `WEAPONS.DAT` range fields at exactly
**166.7 units per metre** for every weapon checked (e.g. ATC20 75000/450 m, ELF 20000/120; full ranges in
`gameplay/weapons_engine.json`, `tools/export_es2_weapons.py`). So the designers' range numbers are 1.54x the geometric scale.
Positions and shapes use 1/256; displayed ranges (if we want the shell text to be true) would use 0.006.

**Speed (verified, `tools/export_es2_units.py`).** Movement is ES1's animation-driven model
(`docs/formats/units.md` §2) on the 125 ms time base: anim rate = speed (walk min 60, 0x416e97), walk seq
DAT+0x0c, run seq DAT+0x0e above DAT+0x2c (0x416fb3), and the animation advances `scale(100)` per frame
(0x418f5e) = 100 ticks per 125 ms → **1 anim tick = 1.25 ms** (ES1 1 ms). Ground speed =
speed × (node-0 Δy per cycle / cycle ticks) / (256 × 1.25 ms) units/s, per Herc and sequence
(`units.json hercs[]`). Speed approach DAT+6 per frame (unscaled); yaw rate = ES1 curve × 1600/1024 (0x417427)
per frame → 600 = 41°/s; torso rates are per 125 ms (0x41a5e8) → 1000 = 44°/s; shields recharge ≤ 5 per
update (0x413b52) = 40/s, capacitor +20 per update = 160/s.

The manual's km/h use the **6 mm/unit designer scale** (like ES1's readouts and ES2's weapon-range texts): at
that scale the computed top speeds match the manual within ±12 % for the seven Hercs it lists (e.g. Outlaw
111/100, Samson 57/60; `top_speed_kmh_designer_scale`). In the
shared 1/256 m world (geometry, manual heights) the same original unit speeds are 0.651× those numbers
(e.g. Outlaw 72.6 km/h; every Herc in `units.json` `hercs[]`, `tools/export_es2_units.py`)
(`top_speed_mps`, what the engine uses — identical in world units to the original, and consistent with ES1,
whose packs are scaled the same way). The old fit `KPH = 0.306 × field` (designer scale) is kept as
`speed.manual_fit_to_mps_designer_scale`. `seconds_per_tick` = 0.125.

## 7. Proof of life

`python tools/export_es2.py RAPTOR2` → `gamedata/es2/{pack.json, palettes/*.json (all sim DPLs),
textures/NEWHERCS/*.png + NEWHERCS.json, shapes/RAPTOR2.json}`; preview
`gamedata/es2/previews/RAPTOR2.png` (7.73 m tall, intact cells only). The JSON is byte-for-byte the
`export_es1.shape_to_json` schema (lods/pieces/polys {v,n,m,t}, nodes/transforms/sequences/transitions),
so `ShapeInstance` can load it directly with pack `es2`. Texture set per shape is inferred from the
highest texture index (see `SHAPE_TEXSET` in the exporter); now confirmed in DBSIM (§5: unit DAT +0x94).
`--all` exports every DTS. Lineup with other packs: `gamedata/tribes/previews/scale_lineup.png`.

## 8. Conversion plan / effort

1. (done) VOL, shapes, bitmaps, palettes.
2. WLD v2 reader + RMP tables + palette dynamic ranges (compare with `world.read_dpl_full`) — 1-2 days.
3. Heightmap terrain from ZONE DBA/DAT (confirm k/s in DBSIM) + ground textures — 2-3 days.
4. Unit DAT (216 b), WEAPONS.DAT (33 records, ES1 record layout + extras), PROJ/ROCKETS, flyer FM — 3-4 days.
5. MSN parser extension for ES2 record types; campaign flow from `SHELL0/GAM` + `LANG0` — 1 week.
6. Cockpits/HUD (ES1 cockpit pipeline + HD/HB HUD sets), WAV audio (trivial), AVI (Indeo 3.2 `IV32` → transcode
   with ffmpeg) — 3-5 days.
7. DBSIM.EXE is a Win32 PE: `tools/exe.py` needs a PE section mapper (pefile-style VA = ImageBase + RVA)
   before code-level verification (tick rate, terrain scale, texture-set table).

Roughly **2-3 weeks** to reach ES1-level support.

## 9. Weapons (`tools/export_es2_weapons.py`)

Output: `gamedata/es2/gameplay/weapons_engine.json` (weapon_schema.md), `weapons_raw.json` (every field),
`shapes/MECHWPNS_<i>`, `MECHWPN2_<i>` (pods, texset WPNTEX), `BULLETS_<i>` (texset BULLETS), `ROCKETS_<i>`,
`audio/sfx/sim/*.wav` (SIMSOUND/HMI, 22 kHz 8-bit PCM, copied as is). Code addresses are DBSIM.EXE VAs
(PE image base 0x400000); the exporter checks the instruction bytes it depends on.

**Time base (H).** Frame scale = elapsed_ms·256/125 (0x46779b; nominal `[0x4d3bf4]`=1000/8; clamp 64..450;
frames ≥ 40 ms, 0x4677c9) → "per scale" rates are **per 125 ms** (ES1: 100 ms). Timers count down by the scale
(0x467944) → **2048 units/s** (refire 1200 = 0.586 s). Bullets/rockets move `scale(speed)` → speed field is
units per 125 ms → **m/s = v·8/256** (ATC 5000 → 156 m/s, missiles 6000 → 187.5, EMP 2000 → 62.5, plasma 1000 → 31).

**Files.** `WEAPONS.DAT` = u16 33 + ES1-layout records (DMG component, COL spheres, 0x30 params at object
0x22..0x52, same field meanings as ES1); record 0 "None"; the projectile table moved to `PROJ.DAT`
(u16 27 × 36-byte rows, ES1 layout; rows 19–26 new: EMP2, PBW2, ELF2, plasma, ATC75/100, LAS400/500).
Weapon `projectile` 33 = none, 34 = missile rack (row = type 0, sub = loadout missile type). `BULLETS.DAT`
12 × {shape, lifetime (125 ms ticks, 0x40b197), hit size, trail interval, sound−10, muzzle jitter, linear damage
falloff flag}; `ROCKETS.DAT` 5 × {shape, lifetime frames, accel/125 ms, ?, ?, ?, sound−10}; `BEAM.DAT`
10 × {width?, palette colour?, 0} by bolt sub (L); `SOUNDS.STR` = sound id → WAV; `LC_WPNS.DAT` = base turrets.
Names: exe table 0x498eb0, `LANG0/ENG/WEAPONS.BIN`; shell `SHELL0/GAM/WEAPONS.DAT` = names + salvage.

**Classes** (GunList::create jump table 0x4100fd): projectile gun (ATC, racks), beam/capacitor (lasers, PB,
EMP, plasma, MAGN, Cybrid EMP/PB), continuous beam (ELF, ELF2), ECM, Locust (charge-up launcher whose launch
routine 0x40acac is an empty stub), four pods (targeting/shield/turbo/energy), and **none for MINE** — mines and
the Locust do nothing in DBSIM 1.0 (records 26/27 blank; exported from the unused grenade rows 8/9, marked guess).

**Damage (H).** Same scale as ES1 (shared rows identical, Herc shields 3500). Capacitor (960 = 820·1200>>10,
+20 per update) weapons multiply the row by the charge spent/1024 (beam 0x40bfe6, charged bullet 0x40b28c):
lasers spend min(per_shot, charge) → LAS100 1500/600 → 117/47 per shot; EMP/PB/plasma dump the capacitor
(×0.94 at full charge); ELF ticks every frame with ×1200/1024 and −70 charge. The same min(charge, per_shot)
argument exists in ES1 (0xb08f → 0x88cc), so ES1 lasers probably scale the same way.
**New mechanics:** plasma/MAGN bolts home on the shooter's target (0x280/125 ms = 28°/s), proximity-fuse at
2000 u and blast 4000 u (15.6 m) (0x40b345); EMP2 fires a second bolt after refire/4; Cybrid EMP fires 3 bolts;
PLAS charges at half efficiency; missiles turn ≤ 0x500/125 ms (56°/s), live 80 frames, ECM deflects SARH/ARH
by ±16.9° (ARM and EO immune, 0x40a394), EO missiles can be steered by the player (docs/MISSILE_CAM.md); EMP hits switch shields off for 6000 timer
units = 2.93 s (0x418c4a). Hardpoint masks (31/15/7) come from the shell default loadouts (`INI_*.DAT` slot →
GL mask) where available, otherwise by analogy (marked in notes).

## 10. Missions (decoded)

Sources: `VSHELL.EXE` (`src\msn_gen.cpp`: MSN loader 0x417b67, compiler/header apply 0x416379, script.dat
writer 0x41ac54, mission.str writer 0x4179f0, "generate mission" 0x41c73d) and `DBSIM.EXE` (`WORLD.CPP`
preload 0x424308, object creation 0x4253d8, objective evaluator 0x413280, mission status 0x4135e8,
regions 0x426b70, timers 0x426b48, results writer 0x42412c). Addresses are VAs (image base 0x400000).
Confidence **H** = read from code and consistent with the data, **M** = code read, meaning partly inferred,
**L** = guess. Units: 1 u = 1/256 m, timers 2048 u/s (section 9).

### 10.1 MSN sections, script.dat and data flow (H)

MSN = `s16 5` then 17 sections, each `s16 n` + n records (all 62 files except the stale `DEMO2.MSN` parse to
EOF). Record prefixes and conditional/random/duplicate-id evaluation are the ES1 rules (`mission.md` 2.1/2.2,
compare ops now 0x119..0x11e). The shell keeps the evaluated records, converts ids to script indices and
writes `data\script.dat` (0x41ac54) — **only records with id != -1 are written; the `count` word in front of
every (var,op) block is never written**:

| # | MSN section (bytes) | script.dat record (shell writer VA) | sim reader |
|---|---|---|---|
| 1 | cond 14 | – | – |
| 2 | header 82 = `cond, f[10], extra[30]` | 10 words (0x41ac8c), word 2 written as constant 1 | 0x4246a8 → 0x4a9ed2 |
| 3 | values 8 `{id,cond,pick,value}` | – (shell only) | – |
| 4 | briefing 144 `{cond, obj_text[10], brief_text[30], text2[30], value_id}` | – (shell; campaign mode passes it to 0x412ece) | – |
| 5 | debrief 64 `{cond, text[30], value_id}` | – (skipped by loader 0x418553, read by debrief 0x41ca4e) | – |
| 6 | point 22 | `i32 x,y,z` | |
| 7 | heading 10 | `s16` | |
| 8 | path 10+2n | `s16 n, s16 pt[n]` | |
| 9 | area 12 | `kind, p1, p2` | 0x423358 |
| 10 | region 82 | `type, param, area[8], var[10], op[10], w34..w38 (10 bytes), w39, w40` (58 bytes) | 0x424a1a |
| 11 | timer 30 | `w3, w4, region[10]` (24 bytes) | 0x424b9d |
| 12 | herc 144 | `block[20], type, weapon[10], point, heading, var[10], op[10], ammo[10], f88, alert, death, health` (134) | 0x42564e |
| 13 | flyer 102 | `block[20], point, heading, type, var[10], op[10], alert, death, health` (92) | 0x425a2b |
| 14 | struct 62 | `type, point, heading, var[10], op[10], alert, death, health` (52) | 0x425c6c |
| 15 | order 22 | `type, w5, point, path, target_kind, target, region` (14) | 0x425ee1 |
| 16 | group 164 | `block[20], kind, formation, point, heading, path, member[20], order[10], team, spawn_region, var[10], op[10], w81` (156) | 0x426006 |
| 17 | objective 58 | `w1..w7, var[10], op[10]` (54; **all** records, no id) | 0x4262b5 |
| 18 | – | `s16 n, s16 text[n]` = the non -1 objective text ids of the (first kept) briefing record | 0x424f09 |

In the MSN the (var,op) pairs are interleaved `(var,op) x10` after a count word (herc @0x4a, flyer @0x36,
struct @0x0e, group w60, objective w8, region w13); script.dat stores all 10 vars, then all 10 ops.
Text ids (objective w7, region w34) are ENG ids; ENG entries `{id, cond, pick, len, text}` are evaluated like
records (`pick = -99` + kept cond = override of the same id, 0x4164a5) and the kept strings are written in order
to `data\mission.str` (0x4179f0: `u32 9999, u16 n, n × {u16 len, text, u8 0}`); the sim loads it as a 50-entry
string table at 0x4aa6e4 (0x4245db).

Sim globals: header 0x4a9ed2, groups 0x4a9e84 (122-byte runtime), orders 0x4a9eb4 (22), regions 0x4a9eac (58),
timers 0x4a9ebc (49), objectives 0x4a9ec4 (76), mission vars 0x4a9ef4 (**1000 × s16**, `data\mission.var` is
2000 bytes, read 0x4243e1 / written 0x42428a).

### 10.2 Header (82 bytes) (H unless noted)

`s16 cond; s16 f[10]; s16 extra[30]`. Defaults f[0]=1, f[1..9]=0 (0x418069). For every kept header record
(0x416379): `f[0]` is applied if != 1, `f[1..9]` if != 0, `extra[i]` if != -1. `extra[]` is a list of mission
variable indices that the shell **zeroes before compiling** (0x417659 → shell var array 0x482af8); all
shipped MSNs leave it empty. Then the shell overrides (0x41c73d): campaign mode (`[0x48260c]==1`): word0 =
campaign terrain table `[0x46fb14 + 8*[0x46fb18]]`, word5 = word6 = 0, word7 = difficulty `[0x482aa1]`;
other mode (training/instant, `0`): word0 = 1, word5/6/7/9 = option bytes 0x4824dd/de/df/e1, word8 = 0.
The writer always writes word2 = 1, and the sim clears word2 again after reading (0x4246bb).

| word | meaning (sim use) | shipped values |
|---|---|---|
|0| terrain set 0–4 → world file `WORLD<2*w0 + w9>.WLD` (0x42e042: `"world"+itoa(w0*2+w9)+".wld"`, palette/companion with the same number); also `w0==4` special cases in 0x408bf3/0x46b3b0 (L: C5 terrain) | C1 0, C2 1, C3 2, C4 3, C5 4, training 1/3 |
|1| zone → `ZONE<w1>.DAT/.DBA` (0x42789c, `"zone"+itoa(w1)`; w1 < 0 = no terrain file) | 123, 15, 1700, 22, 234, 3333, 39, 401–410, 501–510, 111…888, 7000 |
|2| mode; always 1 from the shell, forced to 0 by the sim | – |
|3| special objective mode (0x4a9ed8): 0 normal; **3 / 7 = scan mission**: the player's +0xe "scan complete" flag is set after 4 scan steps (timer table 0x49a318, cockpit voices 0x34+n) while facing (±45°) the player group's current order target within 10000 u (39 m); leaving aborts (voice 0x38). With 3, the player's AI/targeting refuses to fire on that target (0x411f5c). 5 / 0: set player +0xd when near 0x41dbcc / when the order target is selected (not used by objectives) (0x41c194, M) | 0; 3 in C1_08 C2_04 C3_03 C5_01 C5_03 C5_06 TRAIN2; 7 (conditional) C1_09; 2 TRAIN1/3/4 |
|4| training lesson 0–4 (0x4aa7ac): region messages play `SIMVOICE/TM<w4>_00<nn>.WAV` (0x4368fb, H); ≠0 also changes camera/music details (0x431cda, 0x461c8f, L) | 0; TRAIN1–4 = 1–4 |
|5| AMMO option: 1 = player never runs out (0x4107e4) | campaign 0 |
|6| DAMAGE option: 1 = player takes no damage (0x4240f4 used by damage 0x417e05) | campaign 0 |
|7| DIFFICULTY 0–3: scales tables 0x49a058 {400,800,1200,1600}/1024, 0x49a30c {1000,800,400,200}, 0x49a73c {3500,2800,2100,1400}, 0x49a744 {300,600,800,1000} (0x4194b7, 0x41f69e, 0x426b04) (L: AI accuracy/damage) | MSN 2/3 overridden by the campaign difficulty |
|8| VISIBILITY: 1 → 30000 u else 60000 u (0x426aec) | 0 |
|9| TIME OF DAY / world variant 0/1 (part of the WORLD number) | 0, C1_07 = 1 |

### 10.3 Objectives (s58) — win/lose logic (H)

MSN: `s16 cond; w1 required; w2 goal; w3 target_kind (0 group, 1 herc, 2 flyer, 3 struct); w4 target;
w5 point (not used by the sim); w6 path; w7 text id; w8 count; (var,op) x10`.
Runtime (0x4262b5, 76 bytes): +0 w1, +2 w2, +4 w3, +6 target ptr (0x425348 resolves kind/index; herc/flyer/
struct indices are remapped through the preload tables), +0xa point, +0xe path, +0x12 three string pointers
= `mission.str[w7], [w7+1], [w7+2]` (+ terminator), +0x22 done flag, +0x24 var[10], +0x38 op[10].

Goal test 0x413280 (jump tables 0x4132d6 group / 0x4133de object; kinds ≥ 4 → false). Unit flags are bytes at
`unit+0x92+n`: +7 destroyed, +0x12 disabled, +0xc "detected" (an enemy came within 50000 u, 0x412795, or it
was targeted, 0x42671f), +0x13 "harmless" (no usable weapon left, 0x41f56d — also fires the death region; flyers
on sleep/scout orders, 0x422d00; set for structures at creation, 0x4054e1), +0xe "scan complete" (player only).

| w2 | target = group G (kind 0) | target = single unit U (kind 1–3) |
|---|---|---|
|0| G finished the order of its order list whose path == w6 (G+0x70 done flag, 0x41324c): "reach end of route" | same test on U's group |
|1| G destroyed: damage state 0x412c8c ≥ 4 if G.team ≠ 0, ≥ 3 if G is human (team 0) | U destroyed or disabled (+0x12 / +7) |
|2| G not destroyed (as 1) **and** every living member has no enemy nearby (0x4137b4): "protect / secure" | no enemy near U (0x4137b4; does not test U alive) |
|3, 4| player's scan-complete flag (+0xe), see header word 3 | same |
|5| not implemented (keeps the previous result) | same |
|6| any member of G detected (+0xc) | U detected |
|7| all members of G harmless/disarmed (+0x13) | U harmless |
|8| no member of G detected (stealth) | U not detected |
|9, 10| player scan flag not set | same |

`0x4137b4(u)` = "u is safe": no living, armed (+0x13 clear), active (not dormant) unit of another team is within 80000 u (312 m),
or 100000 u if that enemy is targeting u (plus a line-of-sight style test 0x411c58/0x423b0c).
Group damage state 0x412c8c: 4 all members destroyed/disabled; 3 ≥ 63.5 % dead or mean damage > 192/256;
2 ≥ 24 % dead or > 128; 1 mean damage > 50; else 0.

Result (0x4134e2…0x4135df), evaluated over **all** objectives each time:
* `w1 = 1` (required): mission is complete only if every required test is true. The first false one stores its
  text (0x4d1f1c) — shown by the end-mission dialog for status 5 (the not-complete line + w7 lines).
* `w1 = 0` (failure condition): if any is true → failed.
* When a test is true for the first time (`+0x22` done flag) its (var,op) list is applied once (ops below).
* Status = failed → 6 (player safe) / 10 (enemies near); all required true → 9 / 10; otherwise 5 / 4
  (safe/not safe = 0x4137b4(player)).

### 10.4 Mission status, end and results (H code, M texts)

`0x4135e8(player)` returns, in priority order: 2 player destroyed (+7), 3 player disabled (+0x12), 8 player
more than 110000 u outside the mission rectangle 0x4aa6c4, 7 player outside the rectangle, else the objective
status above. Each status has a text line in `SIMALERT/STR/GNL_ALRT.STR`
(killed, disabled with a rescue or capture variant, incomplete and at risk, incomplete, failed, near the edge,
left the area, complete, still at risk). On a change to 6/7/8/9 a cockpit
voice event is posted (6→22, 7→30, 8→32, 9→23; 0x4136c1).

Auto end (0x4131ac, every 10000 timer units = 4.9 s, or immediately while outside the rectangle): statuses
with table 0x49935c set = {2, 3, 6, 7, 8, 9} end the mission: the first time a 4.9 s grace timer starts; at the
next check (status still auto-ending) the final status 0x4a9ed0 is set and the sim exits; status 2 ends at once.
4, 5 and 10 never end the mission automatically — the player can end it from the alert dialog (0x4604de, final
status = current status, 0x413180(player,1)).

`data\results.dat` (0x42412c): `s16 success` (= objective status **9** at the end, i.e. all required
objectives done, no failure objective, player safe), `i32 salvage` = Σ value of destroyed enemy Hercs
(0x418e60, weapons with < 50 % damage) × 2500/1024 + mission var 20 × 25000, `s16 n` + n × `{s16,s16}`
salvaged items (0x426ac8), then per player-group member 13 + 10 + 10 component health % words + 6 bytes
(0x423d68). Then `data\mission.var` (1000 vars) is written back (0x42428a).

### 10.5 Mission variable operations (H)

Three different op tables:

| where | when | op codes |
|---|---|---|
| objective (0x413510) | first time its test is true | 4 var = 1, 5 var = 0, 6 var += 1, 7 var -= 1 |
| region (0x423430) | when it fires (once) | 5 var = 0, 6 var += 1 |
| herc / flyer / struct (0x411bc8) | unit destroyed (0x418276, 0x418526, 0x421c41, 0x404eda) | 1 var = 0, 2 var += 1, 13..16 var = op − 12 (1..4) |
| group (0x423f30) | last living member destroyed | same as units |

Pairs with `var < 0` are skipped; other op values are ignored (data also uses 23 on 4 records → no effect).
Data: hercs mostly 13 (=1), structs 2 (+1), regions 6, objectives 6/7.

### 10.6 Regions (82) (H)

Runtime (58 bytes): +0 type, +2 param, +4 nAreas, +6 area ptrs, +0xa fired, +0xc var[10], +0x20 op[10],
+0x34 = w39 − 1 (message), +0x36 = w40 resolved object. w34–w38 are written to script.dat but discarded by the
sim (0x424a8e). Areas: kind 0 rectangle p1/p2, else circle around p1 with radius `p2*10` u (0x423358, 0x4233a4).

Per frame (0x426b70) each region tests (a region is tested again after firing, but fires only once):

| type | fires when inside any of its areas |
|---|---|
|0| the player |
|1| any member of the player's group |
|2| any member of an active (not dormant) team-0 (human) group |
|3| … active team-1 (Cybrid) group |
|4| … active Herc group (kind 0) |
|5| … active flyer group (kind 1) |
|6| … active structure group (kind 2) |
|7 / 8 / 9| the specific Herc / flyer / structure w40 |
|10| any member of group w40 |

w40 is resolved by type (table 0x426492: 7 herc, 8 flyer, 9 struct, 10 group; else ignored).
Regions also fire from units: **alert region** (unit +0x1b2) when an enemy unit comes within 50000 u (195 m)
of it (0x412704) or targets/attacks it (0x426528, 0x4128f8); **death region** (+0x1b6) when it is destroyed or loses its last usable weapon (0x41f571).
Firing (0x423430): set fired, apply (var,op) pairs; for every valid pair, if w39 > 0 post message/voice event
`w39 − 1` to the comm object (`[[0x49b088]+0x207]`), which plays the training voice `TM<header w4>_00<w39>.WAV`
(0x4368fb; e.g. TM1_0003.WAV) — only TRAIN1–4 use w39 (65 regions, each with one var pair, so the per-pair
quirk does not matter). Effects of a
fired region elsewhere: groups with this `spawn_region` activate, orders with this `region` are skipped
(10.8), timers with this trigger start (10.7).

**param (w4) = how a dormant group arrives** when its spawn region fires (0x4236c4, positions relative to the
player via 0x42354c: player pos + rotate(player heading + angle) × dist, pushed outward in 2000 u steps until
free):

| param | arrival |
|---|---|
| 0, 1 (other) | group simply becomes active at its scripted position |
| 2 | a dropship (flyer class 0x4a972e, 0x409b44) brings the group, landing 150000 u (586 m) away, angle ±90° (0x4000 − rnd(0x8000)) |
| 3 | dropship, 150000 u, angle ±22.5° around 22.5° (0x1000 − rnd(0x2000)) |
| 4 | group placed 90000 u (352 m) **behind** the player (0x9000 − rnd(0x2000) ≈ 180° ± 22.5°), facing him |
| 5 | group placed 150000 u ahead (±45°) |

(the dropship case runs once, group+0x13.)

### 10.7 Timers (30 bytes) (H)

`id, cond, pick, w3 trigger region, w4 delay (seconds), w5..w14 regions`. Runtime (49 bytes): +0 trigger ptr,
+4 region ptrs[10], +0x2c timer = `w4 << 11` (2048 u/s, 0x4679c0). Each frame (0x4230a4): if there is no
trigger or the trigger has fired, count down; at 0 fire all 10 regions and re-arm with 30000 s (effectively
once). Used to sequence the training missions (TRAIN1–4) and timed reinforcements.

### 10.8 Orders (22) and AI (H for mapping, M for behaviour names)

Runtime (22 bytes): +0 type (w4), +2 w5, +4 point, +8 path, +0xc target kind, +0xe target, +0x12 region.
A group holds an **order list** (group w48..w57 = up to 10 order ids, runtime group+0x44, current index +0x6c,
done flags +0x70). Each frame (0x423a74) the current order is tested for completion (0x4239fc); when done its
done flag is set, and when done **or its region has fired** the group advances to the next non-empty order
(members re-plan, 0x411cec). Initial group path = first order's path (group+4/+6); a group heading of -1 is
derived from that path's first two points.

| type | Herc AI state (0x41ed22 → state object; names from 0x413ec0 init) | flyer state (0x422d00) | complete when |
|---|---|---|---|
|0| search/destroy (0x49968c) | search and destroy | target destroyed (0x412dc4 state 4) |
|1| ramming (0x4997c2) | – | never |
|2| guarding (0x499746) | – | target destroyed, or no enemy group whose current order targets the same object is still alive (0x412e74) |
|3| patrolling (0x499594) along path | patrolling | end of path reached |
|4| sleeping (0x4996ca), sets unit +0x13 | sleeping (+0x13) | never |
|5| travelling (0x4995d2), "bulldog travel" (0x49964e) if unit DAT +0x22 > 32000 | scouting (+0x13) | end of path |
|6| following (0x499610) | – | end of path |

Other state objects: deciding, attacking, flanking, facing off, attacking base/flyer, skirting, driving off
enemy, fleeing, in limbo, dead, disabled. Player squadmates (group leader = player) follow wing commands
(+0x23e: 1/2 patrol, 6 guard, 4 attack +0x248) instead of orders. w5 is 0 in 95 % of orders (3 on 55; not
read by the code found, L).

### 10.9 Units, groups, player (H unless noted)

Herc (script 134 bytes, temp layout in 0x4253d8): block w0 ≠ 0 → unit +0x92+5 "starts alerted" (it always
has a target, 0x41da54; M); block w1 ≥ 0 → +0x252 cruise throttle /256 (default 0xaa when 0, 0x41fb01; values
220/256); type (MECHS.NAM), weapons/ammo per hardpoint; heading = heading record value used directly as a 16-bit yaw
(shipped values are only 0/1/10 ≈ 0°; units without heading take the group heading, 0x417aa8); point: position = point + terrain height + DAT +0x16
(+5000 for flyer-type DAT +0x50); heading stored as-is; alert/death regions; health (0x4178e8); **f88 is not
read** by the sim. Flyers/structs: same fields. Struct groups with block w0 = 1 flatten the terrain under the
base layout (formation index into the base-form table 0x4a9630, 0x405db0; M).

Group runtime (122 bytes, 0x423b34): +0 kind, +2 formation, +4/+6 path state, +0xa heading, +0xc members,
+0x10 n, +0x12 team (w58: 0 human, 1 Cybrid), +0x14 spawn region (dormant while not fired: no AI, not
counted by triggers/safety tests), +0x18 point, +0x1c var[10], +0x30 op[10], +0x44 orders[10], +0x6c current,
+0x70 done flags. MSN group u4 and w81 are not used by the sim. Members without a point are placed at the
group point, else at the current waypoint of the first order's path, offset by the formation slot (0x417aa8).

**Player:** the first group record in script order is the player's group. In the sim its member list is
replaced by the Hercs of `data\player.mec` (0x426024: `0x4aa812[script_count + i]`); the one with index
`[0x4aaae8]` is the player (unit +0x92+0x11, global 0x4a9c08). In campaign mode player.mec comes from the
career squad; in the other mode (training) the shell builds the squad from MSN group 0's members 1..n (type,
weapons, ammo; 0x41c8c5). The squad starts at the group point / first waypoint of the group's first order.

### 10.10 Campaign flow

Decoded in `docs/formats/es2_campaign_flow.md` (VSHELL). Implemented by `CampaignES2`
(`game/games/es1/mission/campaign_es2.gd`, saga provider `game/games/es2/campaign_provider.gd`) from
`gamedata/es2/missions/campaign.json` (CAREER.DAT order + MISSIONS.BIN names, must-win missions, tech-unlock vars).
Runtime notes (`MissionRuntimeES2`): objective statuses 6/9 end the mission after the 4.9 s grace, var0 = success
flag, the debrief is the MSN debrief record recompiled with the final vars; arrival params 2-5 place the group
relative to the player (no dropship model); scan missions = facing the squad's order target within ~60 m for 4 s.

## 11. Radio: wingmen, training command, base (`tools/export_es2_radio.py`)

Sources (`SIMVOL0/STR/*.STR` are Earthsiege-style Dynamix STR files, `tools/audio.read_str`; `extra[0]` =
message, `extra[1]` = variant):

| file | lines | voice clips |
|---|---|---|
| `PILOT0.STR` | 46 wingman lines (a veteran's) | none on the disc |
| `PILOT1/2/4.STR` | 45 each, same message numbers as Earthsiege's PILOT tables | `SIMVOICE.VOL` `P<n>_<mm><vvv>.WAV` (P1 also has 21xxx / 36000 clips no table names) |
| `COMMAND0.STR` | 3 base-under-attack lines (messages 0..2) | none found (`CVM_*.WAV` are the onboard computer, `SYSTEM.STR`) |
| `COMMAND1..4.STR` | training lessons 1..4; a message's variants are its successive sentences | loose `SIMVOICE/TM<lesson>_00<message+1>.WAV` on the disc |
| `SYSTEM.STR` | onboard computer status lines (CVM clips; `read_str` stops 4 bytes short) | not used yet |

The importer copies the disc's `SIMVOICE/` folder and writes `audio/tables/pilot{0,1,2,4}_voice.json`,
`audio/tables/command{0..4}_voice.json` (rows as the Earthsiege tables plus `voice`, the clip's Sfx stem) and the
clips to `audio/voice/sim/` and `audio/voice/training/` (PCM rewritten: many disc clips end in a bogus marker
chunk or lack the data chunk's pad byte, which Godot's WAV loader rejects).

Remake routing (all through `Battle.radio`, the chat's radio channel, line shown when its clip starts):
- **Training** (`ES2CommandRadio`): header word 4 = lesson (resolved header `h4`). A fired region with message word
  w39 > 0 speaks COMMAND<lesson> message w39 - 1 (all variants joined) with `TM<lesson>_00<w39>.WAV`, as the sim
  does (10.6, 0x423430 / 0x4368fb) [H]; speaker label "Training Command" (remake label).
- **Region texts** (w34..w38) are discarded by the sim (0x424a8e), so the remake no longer shows them (the only
  ones in the data are a designer's debug notes in C1_06).
- **Wingmen**: `WingmanRadio` with the pilot 1/2/4 tables, the group-0 Hercs besides the player (the campaign
  squad or the mission's own); event mapping as Earthsiege's (audio_video.md "Pilot radio") [L]. PILOT0 (no clips)
  is not used.
- **Base under attack**: trigger not traced; the remake has the base command (label "Base Command") say a random
  COMMAND0 line once per mission when a hostile unit first hits a team-0 structure [L].
