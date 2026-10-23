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
- Per mission: `MISSION.TXT` (+ `SOLO-MISSION.TXT`: the same script plus `#TAG "NAME"` lines that name the objects the mission logic uses, see "Mission logic"), `STRINGS.BIN`, `FOGSETTINGS.TXT`, `<NAME>.TER`, `.GPH`, `.LIT`, `.ASS`, many `*_LM####.TGA/.XBM` lightmaps.
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

Game side: `AAMissionRuntime` (game/games/tribes_aa) plays the numbered missions from campaign/logic.json (see "Mission logic") and any map without a logic record with one fallback rule, "reach and destroy": the enemy generators
(Tribes 2 base equipment through `TribesBase.SPEC_PACK_FALLBACK`), else the waypoints in order, else survive 300 s. Buildings and
scenery are grey marker boxes (`MapPlaceholder`, pack flag `placeholder_shapes`); the player is a Tribes 2 medium armour. The enemy
waves are the disc's own bioderms, the allies its human soldiers; the numbered missions and the trainings run their state machines. The campaign is a standalone provider (`Saga.STANDALONE`), listed in New campaign when Tribes 2 is installed.
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
  positions V4-16 (int16 / scale, control word bit 15 = strip restart, bit 14 = odd triangle: checked against the stored vertex normals over every shape, 49593 faces agree and 100 do not, where alternating winding gets 12079 wrong; the interiors' float words are different, see below). Scale is the float after the (1.0, 0) pair
  of the object header. Materials are recognised by layout (4 colour floats, 0x0c, 1, base texture, lum texture) and own the batches
  after them; a shape that repeats its texture list holds a damaged copy, which is dropped. Shapes with moving parts (turrets,
  sensors, stations, vehicles, weapons, soldiers) are the (1.0, 1, scale) variant; see "Moving-part shapes" below.
- Interiors (`tools/aa_interior.py`, `DATA/INTERIORS/<NAME>.BIN`, "BILD006A"): VIF batches of (V2-32 count/texture, V4-32 float
  positions with the same control bits, V2-16 two UV pairs per vertex); texture number is 1-based into the path list (assumed);
  UV = value / 256 (assumed); lightmaps are not applied. Strips: the first two vertices of each strip carry ADC (bit 15); the triangle winding ALTERNATES along the strip (bit 14 of the word is float noise here, not a hint; using it made buildings look shredded). Triangle order is flipped globally so faces point away from the centre.
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
- In the importer: sensor_pulse_medium is used for the disc's SENSOR placements; turrets use the disc's own rigged shapes (below).
- Soldiers (`light/medium/heavy_male`, `light/medium_female`: 16 bones; `light/medium_bioderm` 16 bones and `heavy_bioderm` 15 with
  a different skeleton, see below): rigid parts, no per-vertex weights. Decoded (`aa_shape.bones`, `batch_groups`, `skeleton_pose`):
  - The VIF stream starts a new part wherever it issues MSCAL 4 (VIF code 0x14, immediate 4); there are exactly as many parts as
    bones, in bone order, each part's vertices in its bone's local space (limbs along +X).
  - After the geometry: "<name>_root", a name hash, 1.0, 30.0 (frames per second), 1, 0, the bone count, then 0x30-byte records
    (-0.0, 1.0, 1, quaternion x y z w, 1, translation x y z, 0): the node default pose, local to the parent. Parents are not
    stored; the order is pelvis (root, 1.2 m up), 2 spine bones, head, arm (3 bones), arm, leg (3), leg, i.e. parents
    (-1,0,1,2,2,4,5,2,7,8,0,10,11,0,13,14) (a distance heuristic against the parts failed; this table assembles correctly).
    Forward kinematics with these gives a 2.2 to 2.6 m human in a ready stance (one leg striding, arms forward), facing +Z.
    The importer exports the human soldiers (and the bioderms, see below) rigged.
  - Sequences follow the bone list as "<name>_<seq>" records (`aa_anim.sequences`): root (static), idlepda, idle, forward, back,
    side, jet, jumpup/jump, fall, land, cycle, sitting, die* (dieforward, dieback, diechest, diehead, dieknees, dieleglf, dielegrt,
    diesidelf, diesidert, dieslump, diespin), recoilde, lookms*, head, headside. Heavy has no sitting, light male no jet.
    Header 20 bytes before the first bone record: 1.0f, fps (10, or 30 for single poses), frame count, 0, bone count.
    Each bone record = u32 flags (often 0x8000000n, sometimes a stray float), 1.0f (or 0.0), then two sections, rotation and
    translation, each opened by a marker word:
      * 1: static - 4 floats (quaternion x y z w, or translation x y z + pad);
      * n (32..4096): animated, n bytes follow = A (4 floats) + S (4 floats) + one byte per channel per frame (4 channels of
        quaternion, 3 of translation); value = A + byte * S (the quaternion is renormalised). The bytes are the quantised
        per-channel range, so a smooth curve is a ramp up and back;
      * = the frame count: raw floats, one vector per frame (the additive recoil / look / head sequences: deltas, identity rotation
        and zero translation = no change; decoded, exported as additive sequences, see below).
    Zero pad words may sit between records (`_skip_header`). Check: frame 0 of idle equals the node default pose of the bone list
    to 1e-5, and the decoded run/die cycles render plausibly (res://tests/aa_soldier_check.tscn writes frames with AA_SHOT_DIR).
  - Export (`aa_soldier.rigged_json`): 16 bone nodes + `mount0` (the right hand, forward along the limb) with each part in its own
    bone's space, a transforms table of keyframes (rx ry rz in 1/65536 turn, x y z) and ds_sequences named like Tribes 2's:
    root, run, back, side, jet (the light male reuses fall), jump, fall, land, sitting, pda and death1..11, cyclic ones with a
    wrap key, ground travel per cycle from the feet's swing against the pelvis (run about 2.7 m per 0.8 s) and foot triggers at
    each foot's forward-most frame. The soldier is turned to face the engine's forward: file (X, Y, Z) -> (-X, Z, Y).
    InfantryCatalog.make_bodies adds the animated AA bodies (labels "Aerial Assault" / "Aerial Assault Female") to every armour of
    the same size; `AAMissionRuntime` puts the player and the allies in them.
  - Additive sequences (`recoilde`, `lookde` / `lookms` / `lookms_rocket` / `rocketpose_looksn`, `head`, `headside`; 7 to 11 frames
    at 30 fps): the delta of each moved bone against its rest pose (frame 5 of a look / head sequence is the neutral one, the ends are the
    extremes, a recoil is 0 -> peak -> 0). The exporter writes the bone's rest pose with the delta composed on top (local rotation
    rest x delta, translation rest + delta), only for the bones a sequence moves, as ds_sequences named recoil, look / lookms /
    looksn, head, headside with `additive: true` and Torque flags 40 (the engine's InfantryAnimation does not play them yet;
    `ShapeCycles.pose` poses their nodes absolutely, over the standing pose).
  - Bioderm skeletons (`aa_shape.BIODERM_PARENTS`, `HEAVY_BIODERM_PARENTS`): light and medium (16 bones) = pelvis, spine, chest, head
    (a neck pointing forward: the hunched alien stance), two arms of two bones from the chest, two legs of four (hip, thigh, ankle,
    foot: reverse-jointed); heavy (15 bones) = pelvis, three spine bones, head, two arms of two, two legs of three, with 14 parts:
    the part list skips bone 2, a pivot between belly and chest (`HEAVY_PART_BONES`; skipping bone 1 or 3 assembles almost the same,
    this keeps the chest part on the bone the arms and head hang from). The rest pose is the `root` sequence's single frame
    (identical to the bone list's records; in the medium bioderm the list's fps word is 10.0 not 30.0 and the list sits up to 10 KB
    after the `_root` name, `aa_shape.bones` searches for it). Sequence names differ: `bioderm_<size>_<seq>` with `death_forward`
    / `idle_PDA` spellings (`aa_soldier._key` normalises them). `InfantryCatalog.make_aa_bodies` offers them as "Aerial Assault
    Bioderm" bodies (flag `bioderm`), and the runtime's enemy waves wear them.
- Mirrored parts: `aa_shape.decode` puts every inverted part (found by its batches lying inside the inverted node's box, not by equal
  boxes) back by a half turn about the axis the shape mirrors across (`lateral_axis`: X, or Z for the scout, whose hull is centred on Z).
- Vehicles (`tools/aa_vehicles.py`): scout, bombscout and grav_scout assemble cleanly. Each is turned about its up axis to face the
  engine's forward (`aa_shape.face_nose`: scout nose -X, bombscout and grav scout +Z), and is written to `gameplay/hercs.json` as
  AA_SCOUT / AA_BOMBSCOUT / AA_GRAV_SCOUT with the Tribes 2 Shrike / Thundersword / Wildcat stats and Tribes 2 weapon ids (unarmed
  without that pack; the bomb scout is a one-seat bomber, no belly turret). turrettrans_vehicle (the Tribes 2 Havoc) is a node-table shape like the turrets
  (14 root nodes, each part in its node's frame; the pose block with the node positions comes AFTER the 21-frame wing fold sequence,
  its last frame equals the pose, which has the wings out; the nose is at +y of the Tribes 2 frame like the Tribes 2 Havoc's (an earlier
  export turned it half a turn and flew it tail first: `res://tests/vehicle_facing_check.tscn` compares the tail weight of every AA vehicle
  with its Tribes 2 twin), so `aa_turret.rigged_json` keeps the frame). Its material records are in a looser layout (no lum texture: `aa_shape._materials(loose)`
  and the texture list keeps repeated entries, the indices count them). Offered as AA_TRANSPORT with the Havoc stats, six seats,
  AI-only and unarmed. Check: `res://tests/aa_vehicle_check.tscn`.
- Turrets (`tools/aa_turret.py`, `aa_anim.node_blocks`): turret_base_large, the five barrels (aa, fusion = plasma, missile, mortar,
  elf) and the sentry are the Tribes 2 turrets. Their parts are in the node's own local frame; after the geometry come blocks
  in the soldier record layout (a marker 0 = no keys, marker + pad word), one record per node of the node table: block 0 is
  the default pose (deployed), then the sequences in file order. A node without a parent is in the file frame (= the Tribes 2
  frame, x right, y forward, z up, turned by M = (-X, Z, Y)); a child's local transform equals Tribes 2's (DumTurn
  (-0.0064, -0.79, 0.0026) in both). The base's blocks: pose, folded pose, Activate (21 frames: platform and elevate nodes), Elevate
  (3), Turn (5, one node through a full revolution); a barrel's: pose, Deploy, Fire1. The exporter re-centred some parts (their node
  origin is shifted against Tribes 2), which the records account for. The barrel's origin is its mount; on the base it hangs on a
  `Mount0` node the exporter adds at the sleeve centre. `aa_import` writes the rigged shapes and gives every turret placement
  `shape` / `barrel_shape` / `barrel_mount` (TribesBase.make_spec lays them over the Tribes 2 block it still borrows).
  Check: `res://tests/aa_turret_check.tscn` (heading and elevation follow the commands).
- Not done: the sensors' spin block (66 frames at 10 fps, no pose block).

## Mission logic (SLUS_201.49)
The executable keeps its symbols: `campaign_logic` (the base of the scripted missions), `game_logic` / `ctf_logic` / `hunt_logic` /
`cnh_logic` (the game modes) and one class per mission, `c01_logic` .. `c13_logic` (no c09 / c12, as on the disc) and `ct1..5_logic`
(trainings). `tools/aa_elf.py` reads the ELF (sections, symbols, capstone MIPS64 disassembly word by word because the R5900 has
opcodes capstone lacks, and `trace`: a pseudo listing with constants and string arguments followed through registers and
delay slots). `tools/aa_logic.py` extracts per mission, written to `campaign/logic.json`:
- `SetCampaignObjectives(n)` in BeginGame: the objective list shown = OBJECTIVES.BIN string n: missions 1..5 = 21..25, 6, 7, 8, 10,
  11, 13 = 26..31 (the "objective_lists" of campaign.json are these).
- missions 1..5 are arena modes: c01 deathmatch (limit 15), c02 and c05 CTF (600), c03 Hunters (250), c04 Capture and Hold (1000);
  AdvanceTime compares the player's score (game_mgr +0x13c) with the limit and the remaining time (+0x1308), `SetPlayerLimits(32, 6, 1)`.
  The runtime plays them as kills x points against 6 respawning bots (a kill is 1 point in mission 1 and, assumed, 40 in the others:
  the mode scoring (flag captures, tags) is not modelled).
- the scripted missions c06, c07, c08, c10, c11, c13 are state machines (`SetState(n)`, a state method per state called from
  AdvanceTime, the state's own time in this+0x10, its first-call flag in this+4): `GetReady/Travel/Siege`, `MovingIn/Infiltration`,
  `Transit/Bombardment`, `GettingReady/Travel/Attack`, `Preparation/Fight` (+ `StayNearGens`), `MovingOut/Battle`. They use
  `RegisterItem(id, "NAME")` for the object tags (GEN1, WAYPT1, TURRET3, SWITCH1, INVEN2, VSTATION1 ...), `GamePrompt(id)` (queued
  voice), `Failed(id)` / `Success(id)` (the closing voice, then the end 2.0 s after it), `SpawnEnemies(wave)` / `SpawnAllies()`,
  `OrderEnemies/OrderAllies(task, target, slot)` and the `CNN_Data` table of ints (timers in seconds, distances in metres, wave
  thresholds; `data` in logic.json). Order tasks: 0 attack, 1 and 3 roam, 2 defend, 4 mortar, 5 repair, 6 destroy, 7 deathmatch,
  8 antagonize.
- spawn points are tagged waypoints of SOLO-MISSION.TXT: `DERM_<n>L_<n>M_<n>H_<n>W` = n light / medium / heavy bioderms, `BOT_...` the
  same for allies (`AddSpawnPoint`, `ParseTag`, `SpawnBots`, which scatters them round the point). **The wave of a tag is W - 1**
  (`ParseTag` stores W - 1; a tag without W is wave 0): "2W" is the second wave, SpawnEnemies(1). `SpawnBots(team, wave)` spawns
  every point of that wave at once; a mission calls it for the waves its states name (c13 only wave 0, whatever its other tags say).
- Voice prompts: `GameAudio` / `GamePrompt` / `Failed` / `Success` ids are 0x05000000 | index: the high byte is the audio container's
  tag (the bank number in the PKG header, 5 = **TRAINING.PKG**, not VOICE), the low bits the sound index in steps of two, so the
  file is `audio/training/<(id & 0xFFFFFF) / 2>.ogg` (checked: the highest id used, 0x16C, is the last record, 182, of the bank).
  `GameInfo(n)` / `ErrorText(n)` / `PrintObjective(n)` show string n of CAMPAIGN.BIN ("Turret destroyed.", "Wrong loadout
  selected.", the training lessons); logic.json keeps the ones the scripts show ("texts", the pad's button glyphs written as the
  action they stand for).

### Exact scripts (`aa_logic.SCRIPTS`, run by `AAScriptVM`, host `AAMissionRuntime`)
Format in the aa_logic.py module doc. Facts read off the traces (numbers in brackets are Data indices; ids are the low bytes of the prompt):
- every scripted mission: the player's death fails with the mission's voice (c06 0xC8, c07/c10 0x110, c08 0x104, c11 0x144, c13 0x156);
  a failure or success plays its prompt, then the mission ends 2 s later; far outside the map (5120 m from the origin) the base
  class fails the mission (0x15A; the remake's own battle bounds do that).
- c06 Onslaught (vehicle pad, drive, siege): GetReady waypoint to VSTATION1; a warning after 1 s [5] and the failure after 20 s [6]
  more than 200 m [4] from it, the failure after 120 s [1], the reminder after 60 s [0]; boarding a vehicle -> Travel. Travel: waypoint
  WAYPT1; reached within 100 m [9] -> Siege; failure after 240 s [8], reminder after 180 s [7]. Siege: waypoint GEN1; the first wave
  after 185 s [10] + [11] (two deployed turrets raise the clock to 180 s), the next when 5 [12] and then 3 [13] enemies are left, a
  win when the third is dead. Not reproduced: repairing the generator / turrets and the vehicle (reaching the pad counts as boarding).
- c07 Dystopia: MovingIn spawns both enemy waves at once (one roams to WAYPT1, one hunts the player), waypoint WAYPT2; reminders at
  60 s [1] and 120 s [2], failure at 240 s [3], WAYPT1 within 200 m [0] -> Infiltration, which spawns the six allies; fewer than 3 [6]
  allies alive fails (0xF2), no enemy left wins (0xF6); a hurry prompt after 120 s [5] while more than 20 m [4] from WAYPT2.
- c08 Scorched Earth: Transit spawns both waves and the allies, the allies march on after 15 s [1] or when the player leaves the
  inventory station by 50 m [0]; more than 100 m [2] from the closest ally: a warning at once, another and then the failure at 10 s [3]
  intervals (all allies dead fails too); WAYPT1 within 150 m [4] -> Bombardment: waypoints at the five turrets, the allies mortar a
  random one every 5 s [6], win = the control switch and no enemy left. (Turrets are optional.)
- c10 Death From Above: three enemy waves at the start; vehicle pad, WAYPT1 within 200 m [4] (120 s [6] / 240 s [3] limits), then the
  turret base; win = the switch and no enemy left. Not reproduced: the enemy aircraft (its prompt only).
- c11 Gen Defender: the allies at the start; the first BioDerms after 90 s [5]; an enemy within 100 m [0] of GEN1 -> Fight; wave 1
  45 s [6] after at most 1 [3] enemy is left, wave 2 45 s [7] after at most 5 [4] are left; win = wave 2 dead. Fails when both
  generators are disabled, or when the player is more than 100 m [1] from either generator for 10 s [2] (warning), again 10 s
  (warning) and 10 s (failure); coming back resets the timer.
- c13 Bastion: allies and enemies spawn at once; more than 300 m [0] from the closest ally for 15 s [1] twice is a warning, then a
  failure; WAYPT1 within 200 m [2] -> Battle: win = the switch and no enemy left.
Disabled / destroyed generators are the base objects' `is_enabled()`; the control switch counts as pressed within 15 m of SWITCH1.
Tests: `res://tests/aa_script_check.tscn` (tags and prompt files of every script, the timers and fail rules above on a stub host)
and `aa_campaign_check.tscn` (a battle of Onslaught through its states).

### Trainings (`aa_training.py`)
ct1..ct5 are lists of lessons on a step variable: a voice line, then (once it has played) the lesson text, then the thing the lesson
asks. The sequence, ids, waypoints and success prompts are the executable's; the PS2 pad is mapped to the remake's input map
(`AAMissionRuntime.INPUT_ACTIONS`); lessons about loadouts and vehicles advance on a pause or on reaching the place. ct1: eight stick
and button lessons (voices 0x14 .. 0x0C), the five switches, then the HUD tour (voices 0x08, 0x00, 0x02, 0x20, 0x0A, 0x1E, 0x16),
success 0x22; ct2: weapons (the originals let the player pick the five weapons in any order), cycle and exchange lessons, the laser
rifle, the zoom and two training bots, success 0x3E; ct3: repair patch and kit, four throwables, mortar and missile launcher at five
turrets, success 0x40; ct4: repair pack, skiing, repairing the inventory station, shield pack, remote station, turret barrel,
turret, sensor, satchel, success 0x52; ct5: four vehicle lessons (grav cycle, transport, bomber, fighter), success 0x6E.

## Infantry weapons (`tools/aa_weapons.py`, importer step `weapons`)
The disc has no weapon script: the numbers are tables in the PS2 executable (symbols are present) and the character define files.
Output: `gameplay/weapons_infantry.json` (9 weapons, weapon schema, category infantry), `gameplay/infantry_rules.json` (what each armour
size carries), effects `aa_*_impact` / `aa_*_muzzle` in `fx/effects.json`, fire sounds `audio/sfx/sim/aa_<weapon>_fire.wav`.
Evidence:
- `player_object::s_WeaponInfo` (13 records x 28 bytes, indexed by invent_type): ammo type, minimum, cost, refire s, -, speed m/s,
  lifetime s. Fields read by `Weapon_Setup_FIRE` 0x241c80 (+0 ammo type, +4 minimum, +8 cost, +0xc refire), `disk::Setup` 0x174e20 /
  `bullet::Initialize` 0x2150e0 (+0x14 speed, +0x18 lifetime), `GrenadeLauncher_Setup_FIRE` 0x2ce1b0 (+0x14 speed). Types: 1 disk,
  2 plasma, 3 sniper (laser) rifle, 4 mortar, 5 grenade launcher, 6 chain gun, 7 blaster, 8 ELF, 9 missile launcher (10 repair gun,
  11 shocklance, 12 targeting laser are not exported: no health damage / no model); ammo 13 disk, 14 bullet, 15 grenade, 16 plasma,
  17 mortar, 18 missile.
- Damage: `GetWeaponPainType` (jump table 0x39f4e0) -> `g_PainBase` (68 x 28 bytes: id, flag, damage radii, impulse) ->
  `g_MetalDamageTable` (68 rows x 24 floats, columns 21/22/23 = light/medium/heavy armour: `ApplyPain` 0x1573d0 adds 0x15 to
  the armour type). `InflictPain` 0x156ce8 multiplies the row by the explosion scale and the falloff and **clamps the hit at 1.0**
  (0x157354), so the value is a fraction of the victim's health; the export keeps the light-armour fraction x 1980 hp and the three
  fractions in the weapon `notes`. Disc 0.35/0.18/0.11, chaingun 0.15, blaster 0.30, plasma 0.45, GL 0.73, mortar 1.97, missile 1.21,
  laser 0.68 (light/medium/heavy in notes).
- Other constants (addresses in `aa_weapons.py`, checked against the executable at export): chaingun 0.125 s period (0x29b024), spread
  +-0.03 rad, laser ray 800 m (0x1de7b8), missile 30 m/s +30 m/s^2 clamped at 200 m/s (0x1a3d84, 0x1a2820), gravity -20
  (`COMMONDEFINES.TXT`). Energy: MAX_ENERGY 1 = 60 (DEFAULTLIGHTDEFINES.TXT "from pc = 60").
- Per armour size (`DATA\CHARACTERS\DEFAULT{LIGHT,MEDIUM,HEAVY}DEFINES.TXT`): `MAX_WEAPONS` 3/4/5, `INVENT_MAX` weapons (light has the laser
  rifle, medium and heavy the missile launcher, heavy the mortar) and ammo (disc 25, bullet 100/150/200, grenade 10/12/15, plasma
  20/40/50, mortar 10, missile 4/8); default loadouts from `LoadoutList` (0x38cac8).
- Sounds: ids `0x02000000 | n` are indexes of the EFFECTS bank (`audio/effects/NNN.wav`), found in each weapon's OnAdd / Setup (plasma 0x1b,
  chaingun 0x27, mortar 0x13, grenade launcher 0x5f, blaster 0x77, laser 0x71, ELF 0x96, missile 0x86; the disc only sets its flight
  loop 9).
- Models: `weapon_*.shp` shapes of the pack, turned so the barrel points along the shape's +Y (`aa_weapons.BARREL_AXIS`, found from
  the geometry; disc and grenade launcher are ambiguous). The laser rifle and grenade launcher have no skin in the pack (drawn white).
- Estimates (marked in the notes): ELF reach and drain strength, missile lifetime, laser refire (recharge limited). The blaster's
  ricochet, the laser's charge scaling and the mortar auto-aim are not modelled.
Check: `res://tests/aa_tv_weapons_check.tscn`; renders `held_weapon_shots.tscn -- --game=tribes_aa --group=0..2`.
