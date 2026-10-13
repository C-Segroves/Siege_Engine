# Starsiege: Tribes (Dynamix, 1998, Darkstar engine) — disc catalogue, formats, units

Disc: `<iso dir>\tribes.iso` (ISO 9660 + Joliet; Joliet names used). Tools:
`tools/extract_iso.py` (→ `tribes/original/`, tree `tribes/original/_tree.txt`, 542 files),
`tools/darkstar_vol.py` (PVOL reader; `extract tribes/original/Tribes/base tribes/extracted` → 89 VOLs,
all entries uncompressed), `tools/darkstar_dts.py` (DTS v2-v8), `tools/darkstar_gfx.py` (PBMP/PBMA/PPL),
`tools/export_tribes.py` (proof of life → `gamedata/tribes/`), `tools/preview_gamedata.py`,
`tools/scale_lineup.py`.

Tribes is **infantry**: players are 2 m tall people in light/medium/heavy powered armour with jetpacks,
plus three hover vehicles. Different engine generation from the 3Space v2 games (ES1/BD/ES2): every
format below is new, but all are documented by open-siege/siege-studio (MIT) except interiors and terrain
blocks.

## 1. Disc layout

| path | contents |
|---|---|
| `Tribes/tribes.exe` (2.4 MB, Win95/NT, DirectX 5, Glide via `3dfx/`), `InfiniteSpawn.exe` (dedicated server), `unTribes.exe` | engine |
| `Tribes/base/*.vol` (34) | `Entities` (966 files: 197 DTS + 768 skins/bitmaps), `scripts` (71 `.cs`), `sound` (147 WAV), `Shell`/`ShellCommon`/`Interface`/`gui`/`fonts` (UI, PBA/PFT), world sets `<w>World` (sky/DML/palettes), `<w>Terrain` (terrain material lists + generation rules), `<w>DML` (terrain + interior textures, `human1DML` = base interiors 28 MB), `Darkstar`, `Editor`, `edit`, `ted` (editor) |
| `Tribes/base/missions/` | 45 missions: `<name>.mis` (plain-text object tree), `.dsc` (description script), `.ted` (PVOL with terrain `.dtf` + `.dtb`), `<name>.vol` (mission-lit interiors `.dis/.dil`) |
| `Tribes/base/voices/` | `male1-5`, `female1-5` voice-pack VOLs (~115 WAV each) |
| `Tribes/config/*.cs`, `console.cs` | default prefs/keymaps (TorqueScript-style text) |
| `Tribes/recordings/*.rec` | 15 demo recordings |
| `Demo/`, `WorldNet/IE`, `DirectX/`, `3dfx/`, `Utils/` | installers / extras |

(There is also `<iso dir>\starseige_disc_1.iso` — Starsiege, the 1999 Herc game on the same Darkstar
engine — not processed here; same VOL/DTS/PBMP formats, DTS v7/v8.)

## 2. Formats

| ext | format | status |
|---|---|---|
| `.vol` | `PVOL` u32 footer; `VBLK` u24 size + 0x80 blocks; footer `vols` names + `voli` 17-byte index {id, nameOfs, blockOfs, size, comp} | **done** (`darkstar_vol.py`); comp 0 only on this disc |
| `.dts` | `PERS` objects: `TS::Shape` v5/v6/v7/**v8** (150 of 209 are v8), `TS::CelAnimMesh` v3, `TS::MaterialList` v3/v4. Quaternion (int16/32767) + translation node transforms, keyframed sub-sequences per node, detail levels with their own root node, packed vertices (u8 x,y,z,normal) x frame scale + origin, triangle faces with UV indices | **done** (`darkstar_dts.py`, all 209 consume exactly). Note: v8 object record is 28 bytes (2 pad bytes after the int16 node index) |
| `.bmp` (Phoenix) | `PBMP` chunks `head` (v3, w, h, bpp 8), `data` (+ mips), `DETL`, `PiDX` (palette id; trails the declared size) | **done** (`darkstar_gfx.py`); 8-bit indexed |
| `.pba` | `PBMA` array of PBMP | done (basic) |
| `.ppl` | `PL98`: count, shade shift, haze level, haze colour, 32-byte match table, count x (256 x RGBX, u32 id, u32 type) | **done**; each world has `.day/.night` PPLs with 14 palettes; entity skins reference shared ids (1135/1136 ...) |
| `.dml` | `TS::MaterialList` (texture names + friction/elasticity) for terrain tiles, sky, interiors | parser shared with DTS materials |
| `.dtf` / `.dtb` | terrain: `GFIL` (version 1, DML name, detail count 9, **scale shift 3 = 8 m squares**, height range, map w/h, one unknown u32, then the block map: 3x3 ids) + `GBLK` v5 (`block-0`, 256x256 squares): sections `u32 size` + **Darkstar LZH stream** (`darkstar_lzh.py`, +1 pad byte): (1) (W+1)² float32 heights (row 0 = south, metres), (2) W x H `{u8 flags, u8 DML index}` (flags&7 tile rotate/flipX/flipY, **0x08 = empty square = hole** over underground bases), (3+) pin/light maps | **done** (`darkstar_terrain.py`; verified against object placements on every map). Blocks tile/wrap: Tribes maps use one block repeated 3x3; the base terrain is a 64-square-periodic fractal plus a hand-edited mission area |
| `.dis` / `.dig` / `.dil` | interiors: `ITRs` shape (string table: per detail `.dig` + `.dil`, `.dml`), `PERS ITRGeometry` v7 (texture scale, box, 9 counts, 20-byte surfaces, BSP nodes/leaves, vertices {point, texcoord}, points, texcoords, planes), `PERS ITRLighting` (light maps, not used) | geometry + textures **done** (`darkstar_itr.py`, layout and UV formula in its docstring; polygon loops wind clockwise from the visible side) |
| `.mis` | text object tree (`instant SimGroup ... { field = "value"; }`, field names case-insensitive): volumes, palette, sky, `SimTerrain` (position, `contGravity "0 0 -20"`), lights, teams, drop points, interiors (`InteriorShape`), static shapes, items, turrets, AI paths. `rotation` = Euler radians, z = counter-clockwise yaw (checked against floor polygons of rotated bases) | **done** (`darkstar_mis.py`) |
| `.cs` | TorqueScript-like scripts: **all gameplay data are datablocks** (`PlayerData`, `ItemData`, `ItemImageData`, `BulletData`, `RocketData`, `GrenadeData`, `LaserData`, `FlierData`, `TurretData`, `StaticShapeData`, `MoveableData`, `SensorData`, `MineData`) | readable text; datablock parser = 1 day |
| `.wav` | RIFF PCM | native |
| `.pft`, `.gui`, `.rec`, `.smk` | fonts, GUI layouts, demo recordings, Smacker video (`dynlogoF.smk`) | low priority |

## 3. Content

**Armours** (`scripts/ArmorData.cs`, shapes `Entities/<shape>.dts`, skins `<team>.<shape>.bmp`,
damage skins `dskinN_armor`):

| datablock | shape | height (root pose) | maxForwardSpeed | mass | jetForce | jumpImpulse | maxEnergy |
|---|---|---|---|---|---|---|---|
| larmor (light, male) | larmor | 2.14 m | 11 m/s | 9 | 236 | 75 | 60 |
| harmor (heavy) | harmor | 2.56 m | 5 | 18 | 385 | 150 | 110 |

Example rows; every armour is in `gamedata/tribes/gameplay/armors.json` (`tools/export_tribes_infantry.py`).

Armour shapes: ~100 nodes, 38-45 sequences (`root`, `run`, `runback`, `side left`, `jump`, `jet`,
`fall`, `crouch *`, `apc pilot`, `pda access`, taunts, deaths), 3 detail levels.

**Vehicles** (`scripts/vehicle.cs`, `FlierData`): Scout (`flyer`, 4.2 x 6.5 x 1.2 m, maxSpeed 50),
LAPC (`hover_apc_sml`, 7.6 x 9.4 x 2.3 m), HAPC (`hover_apc`, 10.6 x 12.7 x 3.0 m). In the catalog with
their fixed weapons (the Scout's FlierRocket; LPC/HPC unarmed): tribes_vehicles.md.

**Weapons** (`item.cs`, `baseProjData.cs`): Blaster, Chaingun (425 m/s), Disc Launcher (65 m/s rocket),
Plasma Gun (55), Grenade Launcher, Mortar, Laser Rifle (sniper), ELF gun (EnergyRifle, lightning), Repair
gun, Targeting Laser; mines, hand grenades; packs (ammo, energy, repair, shield, sensor jammer, deployable
inventory/ammo/sensors/turret/camera), beacons. Turrets: plasma, rocket, mortar, ELF, indoor, deployable.
Base objects: generators, inventory/ammo/vehicle/command stations, sensors, force fields, doors,
elevators, flags.

**Maps** (`missions/*.mis`): training, CTF, C&H, D&D, DM, F&R and multi-team missions (e.g.
Raindance, CTF, lush); the converted list is `gamedata/tribes/maps/`. World sets: lush, desert, ice, mars, mud, alien (+ savana, titan DML sets).

## 4. Units (`gamedata/tribes/units.json`): **1 unit = 1 metre**, time in seconds

Evidence from the data on this disc (not just folklore):
1. **Shapes**: armour heights in their `root` pose at detail 0 — light 2.14 m, light female 1.97 m,
   medium 2.27 m, medium female 2.17 m, heavy 2.56 m (collision `bounds` boxes 2.2-3.0 m). Flag 2.0 m,
   generator 3.0 m, scout flyer 6.5 m long, HAPC 12.7 m long.
2. **Terrain**: `GFIL` scale shift 3 → 8 units per grid square; blocks of 256 squares = 2048; missions
   place `SimTerrain` at `-3072 -3072` (3 blocks, centred). Raindance heights 6.6-76.9 units.
3. **Scripts**: speeds are units/second — light armour 11 (40 km/h), heavy 5 (18 km/h), jump
   75/9 = 8.3 m/s, scout 50 (180 km/h), chaingun 425 m/s.
4. **Gravity** `contGravity = "0 0 -20"` in every mission — a stylised 20 m/s² (≈2 g), deliberately
   not 9.81. Keep it per pack; do not rescale distances to "fix" it.

So `metres_per_unit = 1.0`, `speed.to_mps = 1.0`, `seconds_per_tick = null` (Darkstar physics is
time-based, script values are per second). In the shared engine a Tribes soldier (2.1 m) stands next to
an ES1/ES2 Herc (7.7-10.4 m at 1/256 m/u) and a Battledrome Herc (6.6-8.8 m at 1/512 m/u) at the
correct ratio — see `gamedata/tribes/previews/scale_lineup.png`.

## 5. Proof of life (`python tools/export_tribes.py larmor harmor lfemale`)

Emitted under `gamedata/tribes/`:
* `pack.json` `{"name": "Starsiege: Tribes", "default_palette": "lush_day_1136", "engine": "darkstar",
  "unit_scale": 256.0}` (unit_scale only matters if units.json is missing: 256/256 = 1 m).
* `palettes/lush_day_<id>.json` — the PPL palette selected by each skin's `PiDX` id (256 x [r,g,b]).
* `textures/tribes_<shape>/<i>.png` — **8-bit palette-index PNG** (mode "L", same as ES texture sets),
  one per material index `i`; `<i>_rgba.png` = the same resolved through its palette (convenience);
  `textures/tribes_<shape>.json` = `[{w, h, file, palette}]` (`palette` names the palette JSON to use;
  for larmor it is the pack default).
* `shapes/<shape>.json` — **export_es1 schema**: `lods[]` (3 Darkstar detail levels, most detailed
  first) → `pieces[]` {node, id = 1000 + object index (keeps clear of the 3Space locator ids), name, cell -1, state 0, polys} → `polys[]` {`v` 3 vertices in node
  space (metres), `n` face normal, `m` {kind "tex", index = material}, `t` "darkstar_tri"} **plus `uv`
  [[u,v] x3]** (0..1, v down). `nodes[]` {parent, default, name} with `default` = the `root` sequence pose
  (the stored default pose of the female models is not standing); `transforms[]` = `[rx, ry, rz, tx, ty,
  tz]` converted from Darkstar quaternions to the ES Euler convention (R = Rz·Ry·Rx, 1/65536 turn,
  floats) so `ShapeInstance.tf_to_transform` builds the hierarchy unchanged. Extra keys:
  `ds_sequences` (name, cyclic, duration s, tracks {node, keys [[pos 0..1, transform index]]}),
  `bounds` (header box + collision box), `materials`, `winding_flipped`. No ES `sequences` key.
* `previews/larmor.png` (2.16 m), `previews/scale_lineup.png`.

Runtime changes needed in Godot to show it exactly: (a) `ShapeInstance._build_piece_mesh` should use
`poly.uv` when present instead of the quad-corner UVs; (b) scale the instance by
`Packs.metres_per_unit("tribes") / Assets.UNIT` (as `arena_turret.gd` does for BD); (c) a small
`ds_sequences` player (per-node keyframe tracks, positions 0..1 x duration).

## 6. Recommended conversion plan / effort

1. (done) VOL, DTS (all versions on disc), PBMP/PPL, proof-of-life exporter.
2. Export all 197 entity shapes + skins + team skins (trivial now) — 0.5 day.
3. `.cs` datablock parser → `gameplay/{armors,weapons,projectiles,vehicles,turrets,items}.json` — 1-2 days.
4. `.mis` parser → mission JSON (terrain placement, interiors, objects, teams, drop points) — 1 day.
5. Terrain: decode GBLK (heights + material indices; likely Darkstar LZH/RLE), map materials through the
   world DML → textured heightfield mesh (8 m squares) — 3-5 days.
6. Interiors (`.dis/.dig/.dil` ITR BSP + light maps) — the largest unknown, 1-2 weeks.
7. Gameplay: first-person/third-person armour controller with jetpack (20 m/s² gravity, jetForce,
   energy), projectiles, inventory stations, CTF/C&H/D&D rules, bots (`ai.cs`) — weeks, and a design
   decision on how far to emulate the script layer vs. re-implementing it in GDScript.

Estimate: **~1 week** for all static assets (shapes, skins, scripts-as-data, missions), **+2-3 weeks**
for terrain + interiors (walkable maps), then gameplay on top.

## 7. Multiplayer maps (`python tools/export_darkstar_maps.py tribes|starsiege [mission ...]`)

Writes `gamedata/<pack>/maps/<id>/` in the engine map schema (`docs/formats/map_schema.md`): `map.json`,
`height.r32` (the mission area + margin sampled from the wrapping block map, north row first), `albedo.png`
(terrain tiles from the world DML through the world palette, 4 px per square), `holes.png` (optional, Darkstar
empty squares: entrances to bases built below the terrain surface; 1 px per square, rows = +z), `preview.png`
(top-down check: hillshade x albedo, interior footprints, spawns = circles, stations = squares, added items
white-outlined), `maps/_index.json` (merged); interiors -> `shapes/itr_<name>.json` (one LOD, `rgba` materials,
`textures/itr_<name>/<i>.png`), statics/stations -> `shapes/<dts>.json` via `export_tribes.export_shape`.
Tribes: 37 non-training missions; Herc spawns = vehicle pads (`vehicle_pad` + `herc`, or a team's vehicle
station when it has no pad; only 10 maps have vehicles), infantry = drop points (team = `TeamGroup teamN`, -1
neutral). Station kinds: inventory, ammo, vehicle, generator (incl. solar/portable), sensor, turret, flag,
objective (tower switch), `command` (command station). Items other than flags are left out; doors/force
fields are statics with `collide: false`. Starsiege: see `docs/formats/starsiege.md` (binary `.mis`); drop
point group N = colour (1 red, 2 blue, 3 yellow, 4 purple) -> engine teams 0.. in colour order; per team an
inventory + ammo station (`tribes:inventory_sta`, `tribes:ammounit`, exported by the Tribes import) and 3
infantry spawns are **added** on flat open ground near the team's drop points (`added: true`, listed in notes).
Sky: `environment.darkstar_sky` (map_schema.md) from the mission `Sky` (dmlName, textures[16], featurePosition,
size), `Planet` (fileName billboard, azimuth from north toward **west**, incidence, size/distance) and `StarField`
objects; ring geometry and the tribes.exe addresses are in the `tools/darkstar_sky.py` docstring (panel ring radius
= 1.5 x SimTerrain visibleDistance, panels from -size/8 to +0.75 size). Maps with an empty dmlName show skyColor
above the ring and the haze colour in it.
Engine notes: spawns keep their original height (bases, pads, underground rooms) — `MapBuilder.build` currently
snaps every spawn to the terrain height, which is wrong for Tribes drop points inside elevated or underground
bases; terrain holes need support (collision + rendering) for 18 maps.

## 8. Training missions and the mission runtime

**Export** (`python tools/export_tribes_missions.py tribes`, importer step `training`): the 8 training missions
`base/missions/<n>_<Name>.mis` (+ `.dsc`) -> `gamedata/tribes/missions/<id>.mis` / `.dsc` as they are (UTF-8), the
`Training_*.cs` each `.mis` execs plus the `Training_*.cs` those exec (Training_AI.cs) -> `missions/scripts/`,
`missions/_index.json` `[{id, name (from the id), order, map, mission, scripts, briefing ($MDESC::Text, font codes
dropped), armor}]`, `missions/datablocks.json` (every `<Type>Data <name> { field = value; };` of scripts/*.cs:
`{lower name: {type, name, fields}}`). Maps: `export_darkstar_maps.py tribes --training` writes `maps/<id>/` like
the multiplayer maps but leaves them out of `maps/_index.json` (not arena maps). The base scripts (game.cs,
objectives.cs, item.cs ...) are not copied: the remake's engine plays their part.

**Script runtime** (shared with Starsiege and Tribes 2): `game/engine/script/` - `DarkstarLexer`, `DarkstarParser`,
`DarkstarScript` (the VM) and `DarkstarFunctionTable` (a game's engine functions by lower-case name;
`DarkstarStdLib` = getWord / String:: / floor / getRandom / Time:: / vectors / echo). The Darkstar dialect reads
Starsiege and Tribes scripts; Tribes adds `instant Class "name" { fields; nested instant objects };` (the `.mis`
object tree, built when the statement runs) and the bit operators `| ^ &` (type masks). Per game: Starsiege
`SSEngineFunctions`, Tribes `Tribes1Functions`, Tribes 2 `Tribes2Functions` + `Tribes2Methods`.

**Runtime** (`game/games/tribes/`): Battle runs `--mission=tribes:<id>` (launcher: Tribes training screen) with
`Tribes1MissionRuntime` (base `TribesMissionRuntime`; collaborators `TribesSimObjects` (ids, names, group paths
with `/` or `\`), `TribesActors` (clients, soldiers, bots, inventory, script vehicles), `TribesContacts`
(touches, triggers, mission area), `TribesSchedules`, `TribesItems` (item names -> weapons / ammo / gear / armour /
vehicles), `TribesMissionOutput` (radio lines, objective lines, the waypoint, messages), `TribesBot` (InfantryBot under script orders), `TribesText` (font codes, `~w` sound cues, `%1`)).
Positions: original (x east, y north, z up) -> engine (x, z, -y); a marker's `rotation = "0 0 rz"` (radians) ->
engine yaw rz. Flow (the original server's): the `.mis` runs (objects, then `exec(Training_x)`); `Mission::init()`;
the player's client (id **2049**, the scripts' `remoteEval(2049, ...)`) gets `Game::initialMissionDrop(2049)`;
`Game::playerSpawn(client, respawn)` (native unless the script defines it): the team's
`DropPoints/Start` marker (`Random` on a respawn) -> `Game::playerSpawned(player, client, armor, respawn)`.
Callbacks are looked up `<datablock>::<event>`, then the datablock's `className`, then the object's class:
`onCollision` for shapes the player touches (within 3 m: tower switches, flags, flag stands) and items (within
2 m; without a script callback the item is picked up natively: weapon / ammo (`count` field, else 10) / pack /
hand item into the inventory, a `Repair` item heals 19 %), `GroupTrigger::onEnter / onLeave` (`boundingBox` around
the position, a sphere when `isSphere`), `Player::enterMissionArea / leaveMissionArea` (`MissionCenterPos` x y w
h), `AI::onDroneKilled(name)` when an AI dies. The player respawns 3 s after dying. `EndGame()` ends the mission
successfully (Training::missionComplete -> remoteEval -> remoteTrainingEndMission -> EndGame).
Engine functions (Tribes1Functions): bottomprint / centerprint / topprint / messageAll / Client::sendMessage ->
radio (speaker "Training"; text without codes), Team::setObjective(team, line, text) -> the objective page (line 0
= picture; its first "-" bullet line is the goal: announced when it changes, and the debriefing text), issueCommand (waypoint at x y on the ground) / issueTargCommand
(waypoint on client 2048 + index), schedule(code, s), remoteEval, createAI(name, path group, armour, display name):
an AI client (team 1) whose bot walks the group's path markers round and round, AI::getId / DirectiveTarget (hunt
the client) / callWithId("*" | name, function, args), Player::setItemCount / getItemCount / inc / dec / mountItem /
getMountedItem / getClient / isDead / getArmor, Client::getFirst / getNext / getTeam / getName / getOwnedObject,
GameBase::get/setPosition / getTeam / setTeam / getDataName / damage and energy, Group::getObject / objectCount,
nameToId, newObject / deleteObject / addToSet / Item::hide / pop, containerBoxFillSet (soldiers in the box),
calcRadiusDamage (soldiers in the radius, Tribes damage x3000), spawnPlayer (the player's soldier there),
getSimTime (seconds). Presentation-only calls (HUD icons, GUI modes, sounds, shield and damage flashes:
`TribesPresentation.TRIBES_FUNCTIONS`) do nothing; any other unknown function is a script error.

Approximations: the objective page is kept, not shown (only its goal is announced); `~w` sound cues and
AI::setVar / soundHelper are silent; AI bots carry what the scripts give them (createAI drones are unarmed until
AI::callWithId arms them); static shapes (generators, sensors, turrets) are the map's and take no damage, so the
Defend & Destroy and Commander missions cannot be finished by destroying them; Player::onDamage overrides are not
called (the remake applies damage itself). Test: `res://tests/tribes_training_check.tscn` (every mission 60 s
without script errors, radio lines and objectives posted; 1_Welcome finished by standing on the tower switch).
