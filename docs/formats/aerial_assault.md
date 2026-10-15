# Tribes: Aerial Assault (PS2, 2002) - feasibility

Status: identified only (`siege_import.py identify` names it, "not yet importable"; module `tools/siege_games/tribes_aa.py`).
Source image: `TribesAerialAssault.iso` (630 MB, volume label `SLUS`, ISO9660 + UDF, 74 files). Developer: Inevitable Entertainment.

## Key finding: it is NOT Tribes 2 data
Tribes 2 is Torque (`.vl2` zips, `.dts`, `.dif`, `.cs`, `.mis`, `.ter`). Aerial Assault is a separate Inevitable engine (project name
"T2", `xCore` library, a `ConvertMission` tool that turned Torque `.mis` files into text missions). The disc has none of the Torque
containers or formats, so **tribes2-pack assets cannot be reused directly**; only mission/map *design*, names and themes echo Tribes 2.
Treat AA as its own import with its own readers.

## Disc inventory (counts and sizes)
| Item | Size | Format |
|---|---|---|
| `SLUS_201.49` | 3.3 MB | MIPS R5900 ELF (`7F 45 4C 46`) with C++ symbols and source paths readable (campaign_logic, dlg_campaign, Campaign.bin, ...) |
| `TRIBES/FILES.DAT` | 475 MB | one virtual-filesystem archive, ~8683 records, magic `SFDC` (below) |
| `TRIBES/DATA/AUDIO/{EFFECTS,MUSIC,TRAINING,VOICE}.PKG` | 3 / 36 / 33 / 44 MB | Inevitable audio banks, magic `inevaud` + bank number (PS2 SPU sample data expected, not decoded) |
| `MODULES/*.IRX`, `NETGUI/*`, `CNF/*` | ~6 MB | Sony IOP drivers, network GUI ELF, icons: ignore |

### FILES.DAT layout (decoded, little endian)
- Header u32 words: magic `SFDC` (0x43444653), version 1, sector size 2048, ?, **data base offset 186368**, ?, **name table offset 138960**, record count ~8685.
- Records start at byte 40, 16 bytes each: `name_off, dir_off, start_sector, size`. Name = NUL string at `139000 + name_off`; `dir_off` indexes the same string table (backslash paths). File data at `186368 + start_sector * 2048`. Many names repeat (same file listed per section).
- Files are stored **uncompressed** (BMP/TGA/TXT/PSS read as-is), so no decompression is needed.

### What FILES.DAT holds (463 MB)
- `DATA\MISSIONS`: 57 mission folders (~140 MB) plus 4 index files.
- `DATA\INTERIORS`: 898 `.BIN` interiors (141 MB) + 2132 textures in `PS2TEX` (103 MB).
- `DATA\TERRAIN`: 182 files / 16 MB (+ 49 detail textures); per-mission `.TER` (49).
- `...\DEMO1\DATA\SHAPES\PS2`: 733 files, 12 MB (193 `.SHP` models, 876 `.XBMP` skins across the disc). Armours (light/medium/heavy, male/female/bio), weapons, vehicles (`DATA\VEHICLES\*.VD` text definitions).
- `DATA\SKY` (lush, desert, desert2, ice, badlands; 245 tiles), `PARTICLES`, `PROJECTILES\PS2`, `HUD\PS2` (66), `UI`, `CHARACTERS` (armour define `.TXT`), `MOVIES` (4 `.PSS`, 36 MB).

## Formats and magic bytes
| Ext | Meaning | Notes |
|---|---|---|
| `.TXT` (mission, fog, defines) | plain ASCII | mission text script |
| `.BIN` string tables (Campaign, MissionNames, Objectives, Communique, UI_STRINGS, per-mission Strings) | u32 count, count x u32 offsets, then UTF-16LE strings | |
| `.TER` | heightfield, starts `02 6B` | packed; reader needed |
| `.SHP` | Inevitable shape: u32 node count, node names, geometry | not DTS; reader needed |
| `.XBM` / `.XBMP` | Inevitable bitmap, PS2 oriented (not TIM2) | header of width/height/format words; swizzle/CLUT decode needed. `.TGA` (32 bpp) and `.BMP` also present |
| `.GPH`, `.LIT`, `.ASS` | nav graph, lightmap data (64 KB), per-mission binary | meaning unconfirmed |
| `.PSS` | MPEG-2 program stream (`00 00 01 BA`) | ffmpeg |
| `.HPP` | ASCII C++ header listing shape types | free Rosetta stone |
| `.VD` | `BEGIN ... END` text vehicle definition | |
| `.PKG` | `inevaud` audio banks | SPU-ADPCM likely |

## Where the campaign lives
- `DATA\MISSIONS\CAMPAIGN.BIN` (40 KB, 201 UTF-16 strings; the part read is control hints), `MISSIONNAMES.BIN` (49 names), `OBJECTIVES.BIN` (23 KB), `COMMUNIQUE.BIN` (30 KB; briefings/radio text).
- Campaign mission folders: `MISSION01..13` (01-08, 10, 11, 13 present; 09 and 12 absent) and `TRAINING1..5`. About 38 more named arena maps share the layout (Katabatic, Avalon, Damnation, Overreach, Rimehold, ...).
- Per mission: `MISSION.TXT` (+ identical `SOLO-MISSION.TXT`), `STRINGS.BIN`, `FOGSETTINGS.TXT`, `<NAME>.TER`, `.GPH`, `.LIT`, `.ASS`, many `*_LM####.TGA/.XBM` lightmaps.
- `MISSION.TXT` is a readable ~52 KB script: `MISSION "name"`, `MUSIC`, `ENVIRONMENT`, `SUN`, `FOG`, `SKY`, `BOUNDS`, `TERRAIN`, then `SCENERY`, `BUILDING`, `PICKUP`, `CAMERA`, `SPAWN`, `POWER`, `SWITCH` lines. The easiest campaign data to import.
- The ELF has a `campaign_logic` class (AddBot, AddSpawnPoint, AddWaypoint, AddVehiclePoint, AdvanceTime): scripted AI/objectives beyond the text are compiled in the ELF or `.ASS` (MIPS reverse engineering, L). Order of missions to be confirmed from `MissionNames` plus ELF.

## Reuse vs Tribes 2
Shared in spirit: armour classes, weapon list, mission names/themes (lush/desert/ice/badlands), vehicle roles, base layouts. Different: every container and format. PS2-specific: swizzled paletted bitmaps, SPU audio, PSS video, baked per-section lightmaps, ELF-compiled game logic. No TIM2 and no compiled TorqueScript (`.dso`) found.

## Import plan (effort)
1. S: FILES.DAT reader (parse records, read on demand from the ISO via pycdlib extents; no full extraction).
2. S: `.BIN` string-table reader -> campaign texts, mission names, objectives, briefings.
3. S/M: `MISSION.TXT` parser -> mission schema (spawns, pickups, power/switch, sun/fog/environment); order from names and folder numbers.
4. M: `.TER` decode + detail textures, sky tiles.
5. M: `.XBM/.XBMP` decoder; `.TGA/.BMP` trivial.
6. L: `.SHP` shapes (armours, weapons, vehicles) with skins; `SHAPETYPES.HPP` and `.VD` give names and stats.
7. L: interiors (`.BIN`, 898) and `.GPH/.LIT/.ASS`.
8. M: audio `.PKG` banks (SPU-ADPCM to ogg); `.PSS` via ffmpeg.
9. L: campaign logic from the ELF only if the text scripts prove insufficient.
Recommended first slice: steps 1-3 (all briefings, objectives and object placement for every mission, no model or texture work).

## Legal
The repo holds code and format notes only. All data is read from the user's own disc image at import time; no extracted text, tables or assets are committed.

## Import status (first slice)
Done: `tools/aa_files.py` (FILES.DAT reader, in place from the ISO), `aa_strings.py` (.BIN tables), `aa_mission.py` (MISSION.TXT
parser, all 49 scripts), `aa_import.py` (engine map schema + campaign JSON), `siege_games/tribes_aa.py` (supported). Pack output:
`pack.json`, `campaign/campaign.json`, `maps/<id>/map.json` (49) and `maps/_index.json` (33 arena maps; the 16 campaign maps are
left out like Tribes training maps). Not converted: .TER terrain, .SHP shapes, .XBM bitmaps, interiors, audio, the ELF logic.

MISSION.TXT grammar (keyword then values, `//` comments): `MISSION "n"`, `MUSIC`, `ENVIRONMENT`, `SUN dir(3) color(3) ambient(3)`,
`FOG` (15 numbers + n volumes of 3), `SKY` 5 paths, `CAMERA x y z`, `BOUNDS min(3) max(3)`, `TERRAIN "f"`, `EMPTYSQUARES n..`,
`BUILDING power x y z / pitch yaw roll / sx sy sz / "shape"`, `SCENERY` (same without power), `GENERATOR|INVEN|VEHICLEPAD switch power x y z
name / rot`, `TURRET` (+ barrel word), `SENSOR [type]`, `FORCEFIELD switch power pos rot scale`, `FLIPFLOP|PROJECTOR switch pos rot`,
`WAYPOINT switch pos name`, `NEXUS pos height`, `POWER`/`SWITCH` 16 ints, `SPAWN team pos radius pitch yaw`, `FLAG_HOME team pos yaw`,
`PICKUP pos KIND`.

Assumptions: 1 file unit = 1 m (BOUNDS span ~630 m, as Tribes 2); axes settled by the terrain (see below): X north, Y up, Z east,
engine (x, y, z) = (file Z, Y, -file X), yaw zero faces file +Z (unverified); maps whose .TER cannot be read keep `terrain: null`
and `ground_y`; station team = power group 1/2 -> team 0/1 (heuristic); campaign order = TRAINING1..5 then MISSION01..08,10,11,13 with
MISSIONNAMES 15..25 for the numbered ones (folder 10 = "Death From Above"), communique i = mission i, OBJECTIVES 59..63 = training
notes. Mission texts for the numbered missions come from the communiques; their OBJECTIVES lists (26..31) are exported unassigned
(`objective_lists`) because the mapping lives in the ELF.

Game side: `AAMissionRuntime` (game/games/tribes_aa) plays a map with one fallback rule, "reach and destroy": the enemy generators
(Tribes 2 base equipment through `TribesBase.SPEC_PACK_FALLBACK`), else the waypoints in order, else survive 300 s. Buildings and
scenery are grey marker boxes (`MapPlaceholder`, pack flag `placeholder_shapes`); the player is a Tribes 2 medium armour. No enemy
soldiers yet. The campaign is a standalone provider (`Saga.STANDALONE`), listed in New campaign when Tribes 2 is installed.
Test: `res://tests/aa_campaign_check.tscn` (`AA_TEST_ROOT` for a scratch data folder).


## Decoded since (terrain, bitmaps, shapes, interiors)
- `.TER` (`tools/aa_terrain.py`): u8 version 2, u16 heights[256x256] (row = file X, column = file Z; metres = value / 32), u8 flags[256x256],
  Pascal-string material names ("LushWorld.Lakebed"), then one u8 blend layer per material (they sum to ~255). Squares are 8 m, the
  grid starts at file (0, 0). Axis proof: placements sit on the terrain within a few metres only with row = X, column = Z, and the
  Tribes 2 heightfields of the 33 maps both games share correlate (0.4 to 0.9) only when file X = north and Z = east, a
  right-handed system, so no mirroring. The importer bakes an 8 px/square albedo from the layers and the `DATA/TERRAIN/<MATERIAL>.XBMP`
  textures (one tile = 32 m, assumed), plus `detail.png`, and exports 5-face skies (side tiles are the upper half of a square face).
- `.XBM` / `.XBMP` (`tools/aa_bitmap.py`): header 8 u32 (pixel bytes, CLUT bytes, w, h, stride, format, mip levels - 1, 0x27/0x28);
  CLUT 1024 bytes = 8 bit, 64 = 4 bit (low nibble first), 0 = direct RGBA32; 8-bit CLUTs are in PS2 CSM1 order (swap entries 8-15 with
  16-23 of every 32) and alpha 0x80 is opaque. Pixel data is NOT swizzled (checked against the `.TGA` twin of a lightmap).
  XBMP with mips: block = u32 data offset, then (dims, end offset) pairs, indices of every level.
- `.SHP` (`tools/aa_shape.py`): an object dump with VIF1 packets per batch of up to 63 vertices: UV V2-16 (/4096), normals V3-8,
  positions V4-16 (int16 / scale, control word bit 15 = strip restart, bit 14 = odd triangle). Scale is the float after the (1.0, 0) pair
  of the object header. Materials are recognised by layout (4 colour floats, 0x0c, 1, base texture, lum texture) and own the batches
  after them; a shape that repeats its texture list holds a damaged copy, which is dropped. Shapes with moving parts (turrets,
  sensors, stations, vehicles, weapons, soldiers) are the (1.0, 1, scale) variant; see "Moving-part shapes" below.
- Interiors (`tools/aa_interior.py`, `DATA/INTERIORS/<NAME>.BIN`, "BILD006A"): VIF batches of (V2-32 count/texture, V4-32 float
  positions with the same control bits, V2-16 two UV pairs per vertex); texture number is 1-based into the path list (assumed);
  UV = value / 256 (assumed); lightmaps are not applied. Triangle order is flipped globally so faces point away from the centre.
- Sun: the file's direction points TO the sun; the map stores the light's travel direction.
- Windowed check: `res://tests/aa_shots.tscn` (`AA_TEST_ROOT`, `AA_SHOT_DIR`, `AA_MISSION`) writes overview / ground / mid / sky PNGs.

## Audio banks (VOICE / TRAINING / MUSIC / EFFECTS .PKG)
- Header: u32 sound count at 0x0c, data base at 0x18, then 0x48-byte records from 0x58 (u16 rate at -2, u16 id, u16 flags, u32 size,
  u32 offset from the data base; size/offset 0xFFFFFFFF = empty slot). `aa_audio.records()` reads them; the sounds are mono SPU-ADPCM
  (stereo splitting was tested on MUSIC: worse). Rates: 22050 almost everywhere, 11025 / 17640 in a few EFFECTS/VOICE slots.
  MUSIC = 6 tracks of 4.5 to 9.5 minutes. VOICE (1050 distinct) and TRAINING (188) and MUSIC are exported as OGG (`ogg=True`,
  tools/video.py ffmpeg_exe); EFFECTS keeps the older scan-based split to WAV (the record offsets of EFFECTS do not all land on
  decodable starts; not investigated). Names are not in the banks.

## Moving-part shapes (turrets, sensors, stations, vehicles, weapons, soldiers)
- Header: `(1.0f, 1, scale)` at 0x98 (static shapes: `(1.0f, 0, scale)`); `aa_shape._scale` reads both. Before this the bounding-box
  fallback scale made the parts come out ~13 % too large and the shapes look scrambled.
- Node table (`aa_shape.node_boxes`): u32 count 0x28 bytes after the scale float, then 0x28-byte records
  (u32 0, i32 parent, u32 tag, six float box bounds, u32 0). Mesh parts: the box is in SHAPE space and equals the bounds of the
  part's VIF batches (turrets, sensors assemble with no transform). Pivot/dummy nodes have a +-0.01 box (their positions are not in
  this record).
- Mirror copies are stored point-inverted: the right-hand part is (-x, -y, -z) of the left one (box == -box of an earlier node).
  Rotating those meshes half a turn about X (x, -y, -z) puts them in place (stored normals agree with the winding either way);
  `aa_shape.decode` does it. In the scout the mirrored node's batches are partly inverted and partly plain x-mirrors, so vehicles
  are not reliably assembled yet.
- In the importer: sensor_pulse_medium is used for the disc's SENSOR placements; turrets keep the Tribes 2 look-alikes because their
  barrels mount and turn through pivots/animations that are not decoded.
- Soldiers (`light/medium/heavy_male`, `light/medium_female`: 16 bones; `heavy_bioderm` 15 bones, `light/medium_bioderm` 16 but a
  different skeleton): rigid parts, no per-vertex weights. Decoded (`aa_shape.bones`, `batch_groups`, `skeleton_pose`):
  - The VIF stream starts a new part wherever it issues MSCAL 4 (VIF code 0x14, immediate 4); there are exactly as many parts as
    bones, in bone order, each part's vertices in its bone's local space (limbs along +X).
  - After the geometry: "<name>_root", a name hash, 1.0, 30.0 (frames per second), 1, 0, the bone count, then 0x30-byte records
    (-0.0, 1.0, 1, quaternion x y z w, 1, translation x y z, 0): the node default pose, local to the parent. Parents are not
    stored; the order is pelvis (root, 1.2 m up), 2 spine bones, head, arm (3 bones), arm, leg (3), leg, i.e. parents
    (-1,0,1,2,2,4,5,2,7,8,0,10,11,0,13,14) (a distance heuristic against the parts failed; this table assembles correctly).
    Forward kinematics with these gives a 2.2 to 2.6 m human in a ready stance (one leg striding, arms forward), facing +Z.
    The importer exports the human soldiers in that pose as static shapes. The bioderm skeletons (aliens) are not posed.
  - Sequences follow the bone list as "<name>_<seq>" records (idlepda, idle, forward, back, side, jet, jump, fall, land, cycle,
    sitting, die*, recoil*, lookms*, head, headside), each with a header (hash, 1.0, 30.0 fps, frame count, bone count) and one
    block per bone starting `02 00 00 80, 1.0f, 1, rest quaternion, 0x3e/0x48 (stream length?)` followed by per-channel floats
    (scale/offsets) and bit-packed delta streams (`ff 00 ..` byte patterns). The encoding is not decoded (one-hour budget, no
    convergence); needed for animation.
- Vehicles (scout, bombscout, grav_scout, turrettrans) have a node table of 8 to 17 nodes but no bone list of this kind; their
  node transforms/animations were not found, so they stay unassembled (mirror storage is mixed, see above).
