# Starsiege (Dynamix / Sierra, 1999, Darkstar engine) — disc catalogue, formats, units

Discs: `<iso dir>\starseige_disc_1.iso`, `<iso dir>\starseige_disc_2.iso` (ISO 9660 + Joliet).
Tools (all new, nothing existing was modified):

| tool | job |
|---|---|
| `tools/extract_iso.py` (existing) | ISO → `starsiege/original/disc1/` (`_tree.txt`, 524 files) |
| `tools/installshield_cab.py` | **InstallShield 5 cabinet** (`setup/data1.hdr` + `data1.cab`) → `starsiege/original/installed/` (753 files = the installed game) |
| `tools/darkstar_vol.py` (existing) | VOL → `starsiege/extracted/<vol>/` (`*.ted.vol` mission terrain → `starsiege/extracted/ted/<mission>.ted/`) |
| `tools/darkstar_lzh.py` | VOL compression type 3 (**LZH**, used by `scripts.vol`) → `starsiege/extracted/scripts/` (134 `.cs`) |
| `tools/catalog_starsiege.py` | scripts → `gamedata/starsiege/catalog.json` (vehicles, weapons, projectiles, components, missions) |
| `tools/export_starsiege.py` | proof-of-life shapes (re-uses `export_tribes.py`) → `gamedata/starsiege/` |
| `tools/scale_lineup2.py` | textured cross-pack lineup / 3-view previews (also handles `rgba` materials) |

Reproduce: `extract_iso.py <iso> starsiege/original/disc1` → `installshield_cab.py extract
starsiege/original/disc1/setup/data1.hdr starsiege/original/installed` → `darkstar_vol.py extract
starsiege/original/installed starsiege/extracted` (moves: `*.ted` dirs into `extracted/ted/`) →
`darkstar_lzh.py starsiege/original/installed/scripts.vol starsiege/extracted` → `catalog_starsiege.py` →
`export_starsiege.py tr_apoc tr_talon`.

## 1. Discs — which file is where

**`starseige_disc_2.iso` is a byte-identical copy of disc 1** (same MD5 `2a2a4bc6…`, same volume label
`STARSIEGE1`, same 524-file tree). Only `starsiege/original/disc2/_tree.txt` is kept as the record; the real
second disc was not provided. Nothing is missing for the game itself: disc 1 holds the complete install
(`data1.cab`, 200 MB → 314 MB), including `cinematic.vol`, all campaigns, multiplayer maps and the
cut-scenes. What is not on either image: **the music**. `scripts/cdAudioTracks.cs` registers Red Book CD
audio tracks 2-17 (`Yougot`, `Newtech`, `CloudBurst`, `SS1-4`, `Purge`, `Mechsoul`, ...); an ISO only carries
the data track, so a BIN/CUE (or ripped tracks) of the retail disc(s) is needed for music.

| disc 1 path | contents |
|---|---|
| `setup/data1.cab/.hdr` (InstallShield 5, zlib-deflate chunks) | **the game**: `Starsiege.exe`, `InfiniteSpawn.exe` (dedicated server), 33 VOLs, `campaign/Human` (25 missions + cinematics), `campaign/Cybrid (Advanced)` (22), `training/` (4), `multiplayer/` (24 maps), `Server_*.cs` (12 server presets), `vehicles/*.fvh` (saved loadouts), `skins/` (team/custom skins), `keyMaps/`, `faces/`, `logos/`, `movies/` |
| `setup/_user1.cab`, `_sys1.cab` | installer art/DLLs (Install.avi, EULA) |
| `data/movies/*.smk` | Smacker video: intro, story, Credits, Dynamix logo, tutorial1-6 |
| `Extras/Skins` | 24-bit BMP / PSD skin templates (artist sources of the in-game PBMP skins) |
| `Extras/Miscellaneous` | 2 extra TDM maps (`.cs/.mis`), 2 demo `.rec` |
| `DirectX/`, `At&t/`, `Extras/Riva TNT…`, `WONswap` | third-party |

Installed VOLs: `gameObjects` (43 MB: 645 DTS, 1056 PBMP skins, 556 `.dig`/706 `.dil`/141 `.dis` interiors,
142 `.dml`), `scripts` (LZH), `shell` (UI), `sound` (248 WAV), `taunts`, `cinematic` (cut-scene audio/data),
`generic`, `Darkstar`, `Editor`, `ted`, `guiToolbar`, `tr1-4` (training), 24 `sm_*` voice-pilot sets, and
**10 planet world sets** `<Planet>.Sim.vol`: Desert, Europa, Ice, Mars, Mercury, Moon, Pluto, Temperate,
Titan, Venus (each: `.d/.n/.t.ppl` day/night/? palettes, terrain DML + tile bitmaps, sky DML, `Grid/Rules/
Terrain.dat` generation data).

## 2. Formats — same engine generation as Starsiege: Tribes

| ext | format | status |
|---|---|---|
| InstallShield 5 `.cab/.hdr` | file table in `.hdr`; data = `{u16 n, raw deflate}` chunks | **done** (`installshield_cab.py`) |
| `.vol` | `PVOL` (ted.vol, mission `.ted.vol`) and **` VOL`** (most) — both read by `darkstar_vol.py`; compression 0 everywhere except `scripts.vol` = **3 (LZH)** | **done** (`darkstar_lzh.py`: LZHUF, 4 KB ring pre-filled with spaces, F=60, adaptive Huffman; no length header) |
| `.dts` | `PERS TS::Shape` **v7** (618), v6 (14), v5 (24), v2 (1) | **done** — `darkstar_dts.py` reads all 657 unchanged. v7 = int16 quaternion + translation + scale (scale is 1 on the Hercs). Hercs: ~73 nodes, 7 detail levels (64/32/16/8/4 + collision), 12 sequences `Seq00_walk, Seq01_run, Seq02_stand, Seq04_squat, Seq05_t22, Seq06_t45, Seq07_cockpit, Seq08_frun, Seq09_fall, Seq10_land, Seq11_LLeg, Seq12_RLeg`; low poly (Apocalypse LOD 0 = 210 textured triangles) |
| `.bmp` (PBMP) / `.ppl` | Phoenix bitmaps (8-bit, `PiDX` palette id; Herc skins use id 1) + `PL98` world palettes | **done** (`darkstar_gfx.py`). Team skins: `<HERC>_tr/kn/rb/ha/pirate.bmp`, custom skins in `installed/skins/` |
| `.cs` (in scripts.vol) | **not datablocks** (unlike Tribes): table-style function calls `newWeapon(101, "wg_las.dts", S, IDSFX_LAS, 800, A, IDSPEC_WEA_LAS);` with column headers in comments; tags resolved via `*.Strings.cs` | **done** (`catalog_starsiege.py`) |
| `.mis` | **binary** `SIMG`/`SVol` persistent-object stream (Tribes 1 `.mis` was text): terrain/ted volume refs, `STER` terrain, sky, planet, objects (`Marsrock2.dts` …), drop points | TBD (~2-3 days; companion `<mission>.cs` holds the script logic, briefing tags, pilots, objectives) |
| `.dtf` / `.dtb` | `GFIL` header (as Tribes): block count 32, detail 7, **scale shift 5 (32 m squares)**, height range, 12x12 block map; `GBLK` blocks 64x64 squares | header decoded; GBLK payload (compressed heights + materials) TBD — same coder as Tribes |
| `.dis/.dig/.dil` | interiors (ITR shape / BSP geometry / light maps) | TBD — same as Tribes |
| `.fvh` | saved vehicle loadouts (`vehicles/`) | TBD (small binary) |
| `.ddb` | campaign encyclopedia / ScanX database | TBD |
| `.smk`, `.rec`, `.wav` | Smacker video, demo recordings, PCM | video: ffmpeg decodes Smacker |

## 3. Content (`gamedata/starsiege/catalog.json`)

**All Starsiege combat content is the Herc weapon family** (`category: "herc"`): weapons are mounted on
Hercs, tanks and flyers alike through size-classed hardpoints (S/M/L/X), so Starsiege tanks/flyers are
Herc-scale platforms that use Herc weapons — they must not offer Tribes "vehicle" weapons, and Tribes
infantry/vehicle weapons must not appear on them.

**Hercs** (33 records; `datHerc_<faction>_<herc>.cs`, shape `<faction>_<herc>.dts`). Factions by prefix: `tr`
Terran Empire (Imperial), `kn` Knights, `rb` Rebels, `pi` Pirates/Outriders, `ha` Harabec's Weasels, `ca`
Caanan, `cy` Cybrid, `mg` Metagen (Cybrid), `pl` Platinum Guard (Cybrid), `cin` cut-scene only.

| Herc | side | chassis t | max fwd m/s (km/h) | height m | hardpoints |
|---|---|---|---|---|---|
| Talon | human | 6 | 38.5 (139) | 7.3 | 2 |
| Apocalypse | human | 15 | 25 (90) | 11.1 | 6 |
| Seeker | Cybrid | 4 | 45 | 8.2 | 2 |

Example rows only. Every Herc (and its faction variants) is in `gamedata/starsiege/gameplay/hercs.json`,
written at import by `tools/export_starsiege_gameplay.py` from the user's `datHerc_*.cs`.

Each record: `hercBase` (mass/max mass t, radar cross-section, tech
level, combat value), `hercPos` (m/s), `hercRot` (deg/s), `hercAnim` (walk/run transition speeds),
`hercCpit`, `hercColl` (sphere), `newHardPoint` (size, side, damage parent, offset m on head0, yaw/pitch limits; the side rolls the gun, see weapon_mounts.md section 3),
`newMountPoint` (internal component slots), `newComponent` (damage model: Armor + servos + 11 external
parts with HP), `newConfiguration` (armor distribution), `defaultWeapons`, `defaultMountables`.

**Tanks / hover tanks** (18, e.g. Paladin), **flyers** (11, AI/scripted, e.g. Banshee), **drones** (19:
convoy trucks, carriers) and **turrets** (34 in `datTurret.cs`); all in the generated catalog.

**Herc weapons** (53 `newWeapon` records, joined to 40 projectile records in `datProjectile.cs`): lasers,
blasters, autocannons, EMP/ELF, missiles, mines, bombs, artillery and turret-only variants
(`gamedata/starsiege/gameplay/weapons_engine.json`). Stats per weapon: size,
tech base (all/human/cybrid/alien), tech level, mass t, reload s, lock time, fire offsets, energy
(charge limit/rate) or ammo (max/start/rounds per volley); projectile: class (beam/energy/bullet/missile/
mine/bomb), speed m/s, range m, damage, blast radius, damage mix (concussion/electric/thermal/special),
effect vs shield/armor, tracking type + turn rate. Example: Laser — S, reload 1.0 s, beam 750 m, damage 175.

**Components** (installable): 32 engines (`newEngine` velocity/accel ratings), 12 reactors (output,
battery, meltdown), 16 shields (charge limit/rate, decay), 18 sensors (active/passive modes, ranges
500-1200 m), 6 armours, 27 internal mountables (computers, ECM, thermal diffuser, cloaks, shield
modulator/capacitor/amplifier, laser targeting, battery, capacitor, field stabilizer, rocket/turbine
booster, nano-repair, life support, anti-grav, electrohull, ammo pack).

**Campaigns**: Human (Rebel) 18 missions on Mars → Venus → Titan → Pluto + 7 cut-scene missions; Cybrid
"Advanced" 17 missions on Mercury → Moon → Ice → Temperate → Desert + 5 cut-scenes; training 4. Each
mission = `.mis` (binary world) + `.cs` (script, briefing tags, pilots, objectives) + `.ted.vol` (terrain).
Titles come from the user's scripts at import (`gamedata/starsiege/campaigns/`).
**Multiplayer**: 24 maps (CTF, DM, Football, WAR, TDM) and the server presets that select them; the map
list is the generated `gamedata/starsiege/maps/`.

## 4. Units (`gamedata/starsiege/units.json`): 1 unit = 1 m, speeds m/s, masses t, time s

1. **The data say so**: every vehicle table header ends in `(all_m/s)` / `(all_deg/s)`.
2. **Geometry**: Herc heights at LOD 0 in the `Seq02_stand` pose — Talon 7.3 m, Minotaur 7.7, Basilisk
   9.9, Gorgon 10.4, Apocalypse 11.1 (ES2's Apocalypse is 9.5 m by the ES2 manual), Executioner 14.2; tanks
   7-11 m long, dropship 67 m. Hardpoint offsets (Apocalypse pods at z 1.9-3.7 m) and collision spheres
   (r 3 m) fit the same scale.
3. **Weapons**: ranges 500-1200 m, artillery 5000 m, projectile speeds 300-1000 m/s, beams 2000.
4. **Terrain**: 32 m squares × 64-square blocks = **2048 m per block** — the same block size as Tribes
   (8 m × 256). Height ranges in metres (HA1 Mars 6.5-793 m).
5. Gravity is per planet inside the binary `.mis` — not yet decoded (`gravity_mps2: null`).

Engine integration: add `"starsiege": 1.0` to `WORLD_SCALE` in `game/engine/packs.gd` (until then
`metres_per_unit()` falls back to units.json = 1.0 — same result). Lineup:
`gamedata/starsiege/previews/scale_lineup2.png` (Starsiege Talon 7.3 m ≈ ES1 Tomahawk 7.2 m / ES2 Raptor II
7.7 m; Apocalypse 11 m).

## 5. Proof of life (`python tools/export_starsiege.py tr_apoc tr_talon`)

`gamedata/starsiege/`: `pack.json` (`{"name": "Starsiege", "default_palette": "Mars_d_1", "engine":
"darkstar", "unit_scale": 256.0, "weapon_families": ["herc"]}`), `units.json`, `palettes/Mars_d_1.json`,
`textures/tribes_<shape>/<i>.png` (8-bit palette-index, `<i>_rgba.png` resolved), `textures/tribes_<shape>.json`,
`shapes/tr_apoc.json`, `shapes/tr_talon.json` — **exactly the Tribes schema** (docs/formats/tribes.md §5:
`lods/pieces/polys` with explicit per-triangle `uv`, `m.kind "tex"`, `t "darkstar_tri"`, `nodes`,
`transforms` (ES Euler), `ds_sequences`, `bounds`, `materials`) with the standing pose taken from sequence
`Seq02_stand`. Untextured materials keep their `rgb` in the texture-set JSON. Previews:
`previews/tr_apoc.png`, `previews/scale_lineup2.png`. The Godot runtime items listed for Tribes (use
`poly.uv`, pack scale, a `ds_sequences` player) apply unchanged.

## 6. Plan for a full Starsiege importer module (estimate ~3-4 weeks to playable Herc combat)

| step | work | effort |
|---|---|---|
| 1 | Install/VOL/LZH/DTS/PBMP/PPL extraction + catalogue (**done**) | — |
| 2 | Export all Herc/tank/flyer/weapon/projectile/effect shapes + team skins (loop over `catalog.json`) | 0.5 day |
| 3 | `gameplay/weapons_engine.json` (weapon_schema.md, `category: herc`): from `catalog.json` weapons + projectiles. Damage conversion: Starsiege Herc armour 9-11 k HP + shields ~1000 charge vs ES1 3500/bank → scale factor to decide (≈ ES1 armor / SS armor per weight class); keep shield/armor effect multipliers | 1-2 days |
| 4 | Vehicle definitions (hardpoint sizes S/M/L/X → hardpoint_mask, mountpoints/components, damage tree, engine/reactor/shield maths from the summary comments: "Vel_Rating/tons = % of chassis top speed") | 2-3 days |
| 5 | Herc animation: `ds_sequences` player (**done**: walk/run/frun/stand, turn in place `Seq05_t22/t45`; animation.md) | — |
| 6 | **Terrain**: decode `GBLK` (shared with Tribes; LZH-style or RLE height+material grids), 64×64 blocks × 32 m, 12×12 block maps, planet DML tiles → heightfield | 3-5 days |
| 7 | **Binary `.mis`** (`SIMG` object stream: SimTerrain, sky/planet, object placements, drop points, nav) + `<mission>.cs` script semantics (objectives, triggers, AI orders) | 3-5 days for placement; campaign scripting 1-2 weeks |
| 8 | Interiors `.dis/.dig/.dil` (bases, bunkers) — shared with Tribes, not in siege-studio | 1-2 weeks |
| 9 | Music: needs Red Book tracks from a BIN/CUE or ripped audio; video: `.smk` via ffmpeg | 0.5 day |

Missing decoders, in priority order (terrain: done, section 7): binary `.mis`, interiors, `.fvh` loadouts, `.ddb`.

## 7. Terrain (DTF/DTB)

Decoder: `tools/starsiege_terrain.py` (shared Darkstar decoder, also reads Tribes `.ted` contents).
Each mission terrain volume (`<mission>.ted`, a VOL) holds one `<name>.dtf` grid file and
`<name>#k.dtb` blocks. All 73 Starsiege `.ted` volumes decode; decoded height ranges equal the
GFIL min/max exactly (cin_CB within 0.1 m, see v3 below).

**`.dtf` GFIL** (little endian): `"GFIL" u32 size, u32 version=1, u32 n + n chars DML name`
(`Mars.terrain.dml`, no NUL), `u32 blockCount` (distinct blocks = .dtb files, 32), `u32 detailCount`
(7; Tribes 9), `u32 scaleShift` (square = 1<<shift m: Starsiege 5 = **32 m**, Tribes 3 = 8 m),
32 bytes unknown (0 or 0x64 bytes — lighting?), `f32 minHeight, f32 maxHeight, u32 mapW, u32 mapH`
(12x12; Tribes 3x3), `u32 unknown` (2; Tribes 0), `mapW*mapH u32` block ids (row-major, x fastest,
**row index = +y**), `u32 n, n x {u32 blockId, u32 0}` (block id k is in file `#k.dtb`).
Starsiege maps are 12x12 blocks of 64 squares = 768 squares = 24 576 m, but only 32 distinct blocks:
e.g. HA0 repeats a 4x4-block (8 km) tile 3x3 and the centre copy (map rows/cols 4-7) uses blocks
16-31 (a unique 4x4 centre), so the unique, playable mission area is the centre. The mission `STER` record /
Tribes `SimTerrain` position places sample [0,0] at `-(size*square)/2` (-12288, -12288 in Starsiege;
-3072 in Tribes).

**`.dtb` GBLK**: `"GBLK" u32 size, u32 version (3, 4 or 5), char name[16]` (`block-<k>`; v3: four
u32 pointers), `u32 detailCount, u32 0, f32 minHeight, f32 maxHeight, u32 sizeX, u32 sizeY`
(64x64 squares; Tribes 256), then:
- v4/v5: a chain of `{u32 rawSize, LZHUF stream}` (the VOL compression-3 coder,
  `tools/darkstar_lzh.py`): (1) heights `(sizeX+1)*(sizeY+1) f32` metres, x fastest, row = +y;
  (2) materials `sizeX*sizeY x {u8 flags, u8 index}`; (3) more streams (pin maps / light map, not
  decoded). A stream may end 0-3 bytes before the next size header (encoder flush), so the reader
  matches the next header by its expected size.
- v3 (only `cin_CB.ted`): uncompressed. Row 0 and row sizeY are raw `f32[sizeX+1]`; rows 1..sizeY-1
  are `{f32 step, f32 h[0], int8 delta[sizeX-1], f32 h[sizeX]}` with `h[c] = h[c-1] + step*delta`;
  then the raw material map, then a light map.
- Heights are absolute metres; neighbouring blocks share their edge row/column (identical values),
  so the assembled grid is `mapW*sizeX+1` samples (769) with no seams.
- Material `index` selects an entry of the world DML (`<Planet>.Sim/<planet>.terrain.dml`, a
  `PERS TS::MaterialList` v4, bitmaps `<planet>.*.bmp` PBMP with palette `<Planet>.d.ppl`; file names
  match case-insensitively). `flags` bits 0-2 orient the tile (best seam fit on HA0: flip x (2),
  flip y (4), then rotate 90 deg clockwise (1), bitmap row 0 at the square's north edge); bit 0x40
  occurs rarely, meaning unknown.

Engine export (`export_map_terrain`): heights flipped to rows = +z (engine row 0 = northern edge),
origin `[x0, -(y0 + (rows-1)*square)]`, albedo baked from the tiles (2 px/square for a full 24 km map,
up to 8 px/square for crops); tile orientation and the absent light map are the approximations.

## 8. Campaign missions (.mis + .cs) and the mission runtime

Tools: `tools/starsiege_mis.py` (binary .mis reader), `tools/export_starsiege_missions.py` (campaign export),
`tools/darkstar_weather.py` (Snowfall), `tools/preview_starsiege_mission.py` (top-down PNG). Runtime:
`game/games/starsiege/` (`ss_script.gd` = the shared Darkstar script runtime of `game/engine/script/`
(DarkstarLexer / DarkstarParser / DarkstarScript, also used by Tribes and Tribes 2, see tribes.md section 8) in its
Darkstar dialect; `ss_engine_functions.gd` = Starsiege's function table (a DarkstarFunctionTable),
`starsiege_mission_runtime.gd`, `ss_structure.gd`, `campaign_provider.gd` = Saga provider).

**.mis** = Darkstar persistent stream: `u32 tag, u32 size, payload, pad to even`. Groups (`SIMG`, `ESDP`, `Ssgp`,
`SCPG`): `u32 version, u32 count, children, count x pstring names` (root = `MissionGroup`; names give the script paths
`MissionGroup/patrolGroup/patrol1`). Leaves: 24-byte net header, then
- `SVol` file, `ESpt` palette, `STER` 12 f32 (origin x,y = -12288,-12288 ...) + dtf name + footer (gravity -9.8)
- `DPNT`/`mark`/`ESNM`: u32 flags, f32 rot[9] (rows = axis images, row 1 = forward), f32 pos[3] (+12 bytes for ESNM)
- `trgr`: pstring script name, u8 u8, f32, u32, u32 flags, rot[9], pos[3], box min/max[6]
- `0x100` static shape / `TRRT` turret: SimShape **damage block** @16 (`read_damage`; field order and tags from the
  Starsiege.exe inspect function 0x674f40, `IDITG_SSP_*` in commonEditor.strings.cs): u32 flags (bit 0
  indestructible, bit 1 "is destroyed", bit 2 locally conserve damage), u32 damage distribution tag
  (`IDSIMOBJ_SSP_DAMAGETONONE` ...), u32 destruction event tag, **f32 sustainable damage** (= hit points: 4000 for
  most buildings and turrets, 1 - 250000 overall), f32 current damage (pre-damage; = sustainable for wrecks such as
  the HQ in Cin_HE), u32 explosion tag (`IDDTS_EXP_*`), f32 forward attenuation; pos f32[3] @48, euler f32[3] @60,
  u32 len + .dts @121, then `07 00 00 00 01 01 <team bits> <pstring script name>`. Static-base **fire block**
  (Starsiege.exe read 0x456a0a; inspect 0x4536e9 `IDITG_FIREDAMAGETHRESH` / `IDITG_FIREDAMAGERATE`): f32 fire
  threshold (catches fire with this much damage left, 1000), f32 burn rate (damage/s on fire, 100), u8, f32 =
  the last 13 bytes of a static record. `0x10c` interior: pos at name-73, .dis name
- `TRRT` tail (`read_turret`; Turret::read 0x443cc8, inspect 0x444100 `IDITG_TURRET_*`), found backwards from the
  AI file string: fire block, `u32 turret type (datTurret.cs newTurret id), f32 rotational velocity (rad/s; -1 in a
  few records = the type's), f32 skill, f32 activation distance (m: 200-1500 per instance), f32 target selection
  period, u32 n, u32 weapon tag[n]` (string tags of the IDWEA_* short names, e.g. 301712 = IDWEA_TUR_HATC -> weapon
  `starsiege:TUR_HATC`; 0 = empty slot), `u32 len + "turretFire.ai"`, f32 accuracy, track period, fire period,
  (unnamed +0xf90, 7), **reload/rearm period** (s: 5, 9 or 60), deactivation buffer (m: 50 - 400). Every turret
  record holds weapons (the 8 "unarmed" turrets of the earlier reader had empty slots after their count).
- `SCPG` camera path group (name = the path the scripts focus, `path4`) = `SCPR` (header + u32 1) + `SCPW` waypoints in
  flight order: u32 flags, f32 rot[9] (rows = axis images, row 1 = view direction, row 2 = up), f32 pos[3], pos[3]
  again, f32 quaternion[4], f32 0.6, **f32 speed** (m/s at the waypoint: HE1 path2 follows a drop pod 1.3 km down in
  4.5 s at 300; 1e-6 holds the camera, HE1 path1).
- `HERC`/`TANK`/`FLYR`: u32 version + **LZH stream** (same coder as scripts.vol): 20-byte header, u8 6, u8 vehicle id
  (datVehicle.cs), u8 n + u16 mountables[n], 3 flag bytes, u32 team bits (1 yellow, 2 blue, 4 red, 8 purple),
  pstring script name, u8 n + u8 weapon ids (datWeapon.cs; 0 = empty), f32 pos[3], f32 yaw, u8 k + 3k+1 link bytes,
  u32 len + skin, u32 pilot id (Pilot objects in the mission .cs). `.fvh` loadout files are the same record.
- `SNOW` = Snowfall (`tools/darkstar_weather.py`; RegisterObjects.cs: the editor's "Rain" is the same class with
  the last argument 1): net(24) + f32 intensity, f32 wind[3] (x, y, z: the fall velocity; snow -35, rain -85,
  CTF_Winter_Wasteland's blizzard 100 20 -35), u8 suspendRendering, u8 rain. Snow: CC1, CC3, training2,
  DM_Avalanche, CTF_Winter_Wasteland, DM_Requiem_for_Gen_Lanz; rain: CD1, CTF_Stab_n_Grab. Both exporters write
  it to the map's `environment.weather` (docs/formats/map_schema.md); Tribes' text `Snowfall` decodes the same.
- `SGRE` kept raw. Sky records (decoded by `tools/darkstar_sky.py` -> map `environment.darkstar_sky`, used by
  both the multiplayer and the campaign map export): `SKYT` net(24) + f32 skyColor[3], u32 DML tag
  (Mission.Strings.cs `IDDML_SKY_*`, e.g. 252091 = temperate.t.sky.dml; 0 = no panels), f32 featurePosition, size,
  distance (ring radius, 20000 everywhere), u8 textures[16]; `SKPL` net + u32 bitmap tag (`IDBMP_SKY_*`, 0 = light
  only), f32 azimuth (from north toward west), incidence, u16 flags, f32 intensity[3], ambient[3], size, distance;
  `SKSF` net + u8 inFrontOfSky + f32 colors[3][3]. Panels run from the horizon up to atan(size / distance)
  (Starsiege.exe 0x573454 / 0x573514).
All 75 .mis files (campaigns, training, multiplayer) parse; 0 errors. Static/turret team & script name are found
in ~70 % of records (others: neutral, no name).

**Export** (`gamedata/starsiege/`): `campaigns/{human,cybrid}.json` (order from campaign.cs `curMission` + each
briefing's `nextMission`: Human HA0..HE3 = 18, Cybrid CA0..CE4 = 17; linear, failure = replay; start vehicle from
*_planet_init.cs: Outrider Emancipator / Goad), `missions/<ID>.json` (briefing, debriefings, objectives, pilots,
music, drop points, nav markers, every object with engine-frame `pos` = (x, z, -y), `yaw` = original z rotation,
team, vehicle `starsiege:<key>`, weapons, script name), `missions/<ID>.cs` (original script), `scripts/` (strings.json
from *.Strings.cs, missionStdLib.cs, pilots, planet inventories), `maps/<ID>/map.json` + height.r32 + albedo.png
(section 7; terrain matches object heights, median error 1 m; `holes.png` = squares with material flag 0x08,
openings into interiors below the surface, as for the multiplayer maps). Turret objects carry `turret_type`,
`turret_weapons`, `turret_range` and the datTurret.cs type (`activate_range` 500, `turn_rate` turretVel 1.0 rad/s,
`check_interval` checkFreq 0.2 s, `hardpoints`: offset on node head0, `pitch_deg` = X_rot_rnge, `yaw_deg` =
Z_rot_rnge; shared `humanLaser()`/`humanMissile()` bodies expanded) plus the record's `turret_velocity`, `skill`,
`target_period` and `turret_ai` {accuracy, track_period, fire_period, unknown_f90, reload_period,
deactivate_buffer}. Statics and turrets carry the damage block in original units: `hit_points`, `current_damage`,
`indestructible`, `damage_flags`, `fire_threshold`, `burn_rate`, `explosion_tag`. Interiors are exported as
`shapes/itr_<name>.json` with the multiplayer-map interior decoder (`tools/darkstar_itr.py` via
`export_darkstar_maps.ShapeExporter`) and listed in the map's `interiors` (collide true; MapBuilder builds them);
the mission object keeps `shape` + `in_map`. `camera_paths`: `{<name>: {path, waypoints: [{pos, forward, up, speed}]}}`
(engine frame). `--no-terrain` re-exports objects/interiors/camera paths and keeps the previous terrain.

**Runtime**: Battle runs `--mission=starsiege:HA0` (or a Saga Starsiege stage) with `StarsiegeMissionRuntime`:
builds structures/markers, spawns vehicles through `Battle.spawn_ai`, runs missionStdLib.cs + the mission .cs in
`SSScript` and calls (`SSScriptEvents`) onMissionStart, onSPClientInit, player::onAdd, vehicle::onAdd, `<script>::vehicle::onDestroyed /
onAttacked / onArrived / onScan`, `structure::*`, `turret::*`, `trigger::onEnter/onLeave/onContact`. Engine functions:
order (Attack, Guard route/point/unit, Speed, Formation/newFormation, MakeLeader, HoldFire, ShutDown, HoldPosition,
Clear), schedule, getObjectId/Name, getGroup, GetNextObject, get/setPosition, getDistance, getTerrainHeight,
setNavMarker, say, getTeam/setTeam, isSafe, isGroupDestroyed, pick, damageObject/damageArea, forceToDebrief
(success = every primary MissionBriefObjective status "Completed"), playerManager::*, Inventory* (recorded for the
campaign), focusCamera / setPlayerCamera / lockUserInput / setDominantCamera / setFlybyCamera / setTowerCamera /
setOrbitCamera (`SSCameraFunctions` -> `SSCutscene`). Other camera calls (setCombatCamera, cameraLockFocus), sound,
HUD-timer and reloadObject calls are no-ops. The runtime's collaborators: `SSObjectTree`, `SSScenery`,
`SSStartPositions`, `SSUnitDirector`, `SSSensors`, `SSScriptEvents`, `SSEngineFunctions` (+ `SSCameraFunctions`).

- **Turrets** (`SSTurret` + `SSTurretGun`, host): every check interval the nearest hostile vehicle within
  min(record range, weapon range) is the target; the head (shape node `head0`, turned visibly) swings toward it at
  turretVel; each gun fires when its hardpoint arc holds the target (yaw on the head; pitch too, except for guided
  missiles whose hardpoints have pitch 0..0), at the weapon's own reload, through `Weapon.make_projectile` / beams on
  the battle fx channel. Ammunition from the catalog weapon (datWeapon.cs weaponAmmo maxAmmo; energy weapons
  unlimited); an empty gun is rearmed after the record's reload/rearm period. The record's rotational velocity
  turns the head (else turretVel); a target is kept until it leaves the activation distance + deactivation buffer.
- **Structures** (`SSStructure`, statics and turrets): hit points = sustainable damage x the damage scale (3),
  pre-damage from current damage (wrecks start destroyed), the indestructible flag (perimeter walls, rocks) ignores
  hits but still reports onAttacked; with fire_threshold or less hit points left the shape burns burn_rate x 3
  per second (fire and smoke puffs) until it is destroyed (killer = its last attacker).
- **Interiors**: placed by the map (trimesh collision). Vehicle starts (`make_start_position`) sit on the terrain,
  except positions below it inside an interior (HA0 starts in its mole tunnel), then `SpawnClearance` lifts them out
  of any building.
- **Camera paths** (`SSCutscene`, `SSCameraPath`): a Catmull-Rom flight through the waypoints, view slerped, speed
  interpolated per segment (min 0.01 m/s); `<path>::camera::waypoint<k>` fires on reaching waypoint k (k = 1 at the
  start; CA4's path1 waypoint4 = its last). The camera is made current over the battle's, the HUD hidden, letterbox
  shown; lockUserInput disables the player's pilot. ui_accept / menu_back skips: script timers and the flight are
  fast-forwarded until control returns (HE1 intro: 33.75 s). Host screen only (campaign missions are single player).
- **Object cameras** (`SSObjectCamera`; usage strings and defaults in the Starsiege.exe console handlers
  0x4a7a1c - 0x4a80fc; offsets in the object's frame, x right, y forward, z up): setDominantCamera(object0, object1,
  [x y z]) follows object0 at the offset (default 0 -25 12) looking at object1 (+4 m); setFlybyCamera(object,
  [camera offset, object offset]) leaves the camera at object + offset (default -6 40 2, ahead) watching object +
  (default 0 0 5) pass; setTowerCamera(object, x y z, [object offset]) watches from a mission position;
  setOrbitCamera(object, [distance, azimuth, incidence]) sits on a sphere around it (40 m / 0 / 20 deg when
  omitted; azimuth from behind its heading). Shown like a cut-scene (letterbox, HUD hidden) until setPlayerCamera or
  the next camera call; the game keeps running under it, so a skip just returns to the player's view. A camera
  whose object is gone holds its last view.
- **Radio** (`SSRadio`, `SSEngineFunctions._say`): say(channel, who, text, wav) / say3D(...) speak on the campaign
  radio channel through `Battle.radio(speaker, text, "starsiege:<wav stem>")` (the line shows when the clip starts).
  Speaker: the name leading the string ("<NAME>: <words>": 193 of the 219 string ids the missions say carry one)
  [H, data], else the AI vehicle `who` names (actorTalks(actor, ...) passes the actor) [M], else none ($playerId as
  `who` addresses the player). Font codes `<F<n>>` are dropped. A wav in place of the text (voice-only line) and
  say3D without text (ambient sound) stay silent; playSound too. Clips: `tools/export_starsiege_voice.py` copies
  every wav the mission scripts / missionStdLib.cs name (case-insensitive) from the unpacked volumes, then from every
  .vol of the install (campaign .ted.vol, sm_*, tr*, cinematic too) to `audio/voice/`; 126 of 218 never shipped and
  are listed with the reason in `audio/voice/_missing.json` (their text still shows): the 33 `<MISSION>_Debriefing`
  success narrations and 93 mission lines (e.g. HA1_1SQ01, CA0_NEX01). Checked: the install cabinet holds the
  whole game, no volume entry, loose file or movie holds them under another name or case, no mission-prefixed clip
  exists except HE2_CAANON_CN1..4, and the user's disc 2 image is byte-identical to disc 1. The runtime has no squad
  command menu, so squadmate acknowledgements (sm_*.vol voice sets in DatPilot_*.cs) and messageBox are not
  produced. Objective status texts stay on the system channel.
- **Weather**: `environment.weather` -> `MapWeather` (engine/map_weather.gd), GPU particles in a box around and
  upwind of the camera (world space), count = intensity x 6000 snow / 5000 rain, velocity = wind x 0.2 m/s (snow
  falls 7 m/s, rain 17 m/s; a literal -35 m/s would cross the box in a second), snow flutters with turbulence,
  rain is drawn as vertical streaks.
- **Teams**: neutral (team 9) units are marked `dormant` (AIPilot / FlyerAI skip them as targets) and look for no
  targets themselves (`SSTeams`); setTeam re-applies it. Turrets ignore neutrals and neutral turrets hold fire.
- **Flyers** spawn as `Flyer` (FlightModel, FlyerAI). Placed < 40 m above the terrain = parked (landed, no AI) until
  order(guard route / attack) launches it; higher = airborne, circling its spawn point.

Approximations: scan = target locked 2 s within 600 m, damageArea has linear falloff, script damage x3 (gameplay
damage scale), turret accuracy / skill / track and fire periods are decoded but not applied, orbit camera defaults
(the original keeps the orbit camera's previous settings), weather particle speed scale. Tests:
`godot --headless --path game res://tests/test_starsiege_mission.tscn -- HA0 --ss-debug` (plays HA0 to a
successful debrief), `--script res://tests/test_ss_script.gd` (parses every script),
`res://tests/test_ss_campaign_features.tscn` (interiors + collision, turret in range / out of arc / out of range,
record hit points / ammunition / rearm / fire / indestructible walls, dominant and flyby cameras + skip, destroyed,
HE1 cut-scene timing and control hand-back, skip, CC1 snow around the camera, CD1 rain, Winter Wasteland blizzard).
