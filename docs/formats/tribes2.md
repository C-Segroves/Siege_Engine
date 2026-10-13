# Tribes 2 (Dynamix / Sierra, 2001, Torque V12) — disc catalogue, formats, units

Disc: `<iso dir>\tribes_2.iso` (ISO 9660 + Joliet, volume `T2_INSTALL`, "TRIBES 2 Version 1.0, 04/01/01"),
one disc. Tools (all new):

| tool | job |
|---|---|
| `tools/extract_iso.py` (existing) | ISO → `tribes2/original/` (208 files, `_tree.txt`) |
| zip (Python `zipfile`) | the 14 `.vl2` archives are **plain ZIP** → `tribes2/extracted/<vl2 name>/...` (9142 files) |
| `tools/torque_dts.py` | **Torque DTS reader** (v18-26; every Tribes 2 shape the scripts and missions use verified) |
| `tools/catalog_tribes2.py` | TorqueScript datablocks + missions → `gamedata/tribes2/catalog.json` |
| `tools/export_tribes2.py` | proof-of-life shapes → `gamedata/tribes2/` (truecolour `rgba` materials) |
| `tools/scale_lineup2.py` | textured lineup / 3-view previews (palette `tex` and `rgba` materials) |

Reproduce: `extract_iso.py <iso dir>\tribes_2.iso tribes2/original` → unzip every
`tribes2/original/Tribes2/GameData/base/*.vl2` into `tribes2/extracted/<name>/` → `catalog_tribes2.py` →
`export_tribes2.py light_male heavy_male vehicle_grav_scout vehicle_air_scout`.

## 1. Disc layout

The game is not packed in an installer: `Tribes2/GameData/` is the installed tree.

| path | contents |
|---|---|
| `GameData/Tribes2.exe` (4.1 MB), `ispawn.exe` (dedicated), `TribesLogin.exe`, Miles (`Mss32.dll`, `.asi/.m3d`), `OpenGL2D3D.dll`, card profiles `*.cs` | engine |
| `base/shapes.vl2` | 217 DTS (armors, vehicles, weapons, packs, turrets, stations, flags, organics `borg/porg/dorg/sorg/xorg*`), **302 `.dsq` sequence files** (armor animations), 8 `TSShapeConstructor` `.cs` |
| `base/skins.vl2`, `textures.vl2` | truecolour **PNG** (+ `.bm8` 8-bit twins), JPG sky/terrain, 67 `.dml` material lists, `.ifl` animated-texture lists |
| `base/interiors.vl2` | 241 **`.dif`** interiors (version 44) |
| `base/missions.vl2` | 52 `.mis` (text), 54 `.ter` terrains, 49 `.spn` + 28 `.nav` (AI nav graphs), 61 mission `.cs` |
| `base/scripts.vl2` | 170 `.cs` (**TorqueScript source**, not compiled `.dso`) + 133 `.gui` |
| `base/audio.vl2`, `voice.vl2` | 411 + 2374 WAV |
| `base/lush|desert|ice|lava|badlands.vl2` | world texture sets (terrain tiles, skies, `.dml`) |
| `base/lighting/*.ml` | 50 precomputed mission light maps |
| `base/music/*.mp3` | 5 world music tracks (badlands, desert, ice, lush, volcanic) |
| `base/textures/T2IntroC15.avi` | intro movie |
| `EmpireEarth/`, `TheCell/`, `AT&T/`, `DirectX/`, `GLSetup/` | third-party / demos |

## 2. Formats (Torque V12 — a new engine generation vs Darkstar)

| ext | format | status |
|---|---|---|
| `.vl2` | ZIP | **done** (`zipfile`) |
| `.dts` | Torque shape: header word (version 15-23 on this disc; exporter version in the high 16 bits), then one memory buffer with **three interleaved streams** (32-bit / 16-bit / 8-bit, start offsets in the header) separated by running **guard counters**, then sequences and the material list as a plain stream. Details in `tools/torque_dts.py` docstring | **done for v18-v23 = 214 of 216 shapes, every one consumed exactly** (all 133 shapes the scripts name, all mission statics). v19-21 (organics, `weapon_energy` = the blaster, `weapon_missile_projectile`, flares, wrecks): one node-state count incl. the default pose, sequences without a flags word (3 bool bytes, one base state, one rot/trans bitset), pre-v20 decal meshes with an empty mesh header. v18 (`grenade_projectile`, `mortar_projectile`, `plasmabolt`, `disc_explosion`, `octahedron`): the old plain-stream layout (every array counted, sequences before meshes, meshes without bounds/parent, i32-length names) — `read_old_shape`. Not read: `chaingun_shot` v15 and `borg3` v16 (per-node flag byte, other node-state layout; referenced by nothing) and the empty `xorg2.dts` |
| ↳ notes | nodes = 5×i32 (name, parent, firstObject, firstChild, nextSibling); objects = 6×i32 (name, numMeshes, startMesh, node, nextSibling, firstDecal); detail = (name, subShape, objectDetail, size, avgErr, maxErr, polys) — size < 0 = collision/LOS details; mesh *k* of an object belongs to detail with objectDetail *k*; default node transforms = int16 quaternion + float translation (**same conjugated quaternion convention as Darkstar**, verified: armor and vehicle parts assemble correctly); primitives are strips/lists/fans with a material word (bits 30-31 type, 0x10000000 no-material, low 28 bits index); mesh types 0 standard, 1 skin, 2 **decal** (v22/23 still use them for bullet holes/damage decals: 47-58 per shape), 3 sorted, 4 null; meshes may share vertex data with `parentMesh`. **Tribes 2 writes no padding at `align32()` points** (aligning breaks every guard). Armors are rigid per-bone meshes (no skin meshes), ~1600 triangles at LOD 0 |
| `.dsq` | external sequences (armor `root/run/back/side/jump/jet/fall/land/ski/death1-11/cel*`), referenced from `<armor>.cs` `TSShapeConstructor` | **done** (`torque_dts.read_dsq`: all 301 files on the disc (v22) consume exactly; layout in its docstring; `export_tribes2.py` merges the constructor's sequences into the armour shapes under the constructor's names, with their foot triggers and ground travel; `medium_male_dieslump.dsq` is empty on the disc) |
| `.png/.jpg` | truecolour textures (material name `skins\base.lmale` → `skins.vl2/textures/skins/base.lmale.png`; team skins replace the `base.` prefix) | native |
| `.dml` | text material lists for terrain/interiors | trivial |
| `.ter` | terrain v2: u8 version, 256×256 u16 heights (**/32 = metres**, e.g. Katabatic 50-275 m), 256×256 material/flags bytes, material names, alpha maps | **done** (`export_tribes2_maps.py`: heights, per-material alpha maps → baked albedo, empty squares) |
| `.dif` | Torque interiors v44 (BSP, surfaces, light maps, zones, portals, collision hulls) | **done for geometry** (`tools/torque_dif.py`: detail 0 planes/points/texgens/materials/windings (triangle strips)/surfaces; all 241 parse; zones have no flags word in T2; lightmaps, hulls, sub-objects not read) |
| `.mis` | **text** `new SimGroup(MissionGroup) { ... }` object tree; header comments `// MissionTypes = CTF`, quote, mission string; `TerrainBlock` (terrainFile, squareSize 8, position −1024 −1024), `Sky`, `MissionArea` (flightCeiling), teams, spawn spheres, `InteriorInstance`, `StaticShape`, `Turret`, `Item`, vehicle stations | **done** (`export_tribes2_maps.py` → engine maps; rotation "ax ay az deg" turns by −deg, Torque writes the transposed quaternion matrix — verified: 64/65 stations land on interior floors) |
| `.cs` | TorqueScript source; gameplay = `datablock Class(Name) : Parent { field = value; };` | **done** (datablock parser with inheritance + arithmetic) |
| `.nav/.spn` | AI navigation graph / spawn graph | low priority |
| `.ifl` | image-file lists (animated textures: jets, flares) | trivial |
| `.wav/.mp3/.avi` | audio / intro | native / ffmpeg |

## 3. Content (`gamedata/tribes2/catalog.json`)

**Armors — infantry family** (`scripts/player.cs`, `PlayerData`):

| datablock | shape | mass | maxForwardSpeed m/s | jump m/s | jet m/s² | boundingBox | maxDamage | maxEnergy | shape height |
|---|---|---|---|---|---|---|---|---|---|
| LightMaleHumanArmor (+LightFemale, LightMaleBioderm) | light_male / light_female / bioderm_light | 90 | 14 | 8.3 | 26.2 | 1.2×1.2×2.3 | 0.66 | 60 | 2.28 / 2.34 / 2.29 m |

Example row; all armours are in `gamedata/tribes2/gameplay/armors.json` (`tools/export_tribes_infantry.py`).

**Infantry weapons** (`scripts/weapons/*.cs`, `ShapeBaseImageData` → projectile datablock): Blaster,
Chaingun, Spinfusor/Disc (e.g. linear 90 m/s, 0.5, splash r 7.5 m), Grenade Launcher, Mortar, Plasma Rifle,
Missile Launcher, Laser/Sniper Rifle, Shocklance, ELF gun, Targeting Laser, Repair gun
(`gamedata/tribes2/gameplay/weapons_infantry.json`); hand items: grenades (frag, concussion, flash,
flare, camera), mines, beacon, repair kit. **Packs**: ammo, energy, repair, shield, cloaking, sensor
jammer, satchel charge, deployables (inventory station, motion/pulse sensors, indoor/outdoor turret) and
turret barrels (AA, ELF, missile, mortar, plasma). Damage scale: armour `maxDamage` 0.66-1.32 (fractions
of a "unit" of health), projectile damage 0.08-1.1 — convert to the ES scale per weapon_schema.md.

**Vehicles — vehicle family** (`scripts/vehicles/*.cs`):

| datablock | name | class | shape | mass | size L×W×H m | mounts / weapons |
|---|---|---|---|---|---|---|
| ScoutVehicle | **Wildcat** grav cycle | HoverVehicleData | vehicle_grav_scout | 400 | 3.6 × 1.9 × 1.6 | 1 rider, unarmed |
| ScoutFlyer | **Shrike** scout flier | FlyingVehicleData | vehicle_air_scout | 150 | 11.1 × 5.5 × 3.7 | twin nose guns (ScoutChaingunBullet tracer 425 m/s, 0.125) |

Example rows of the six vehicles (Wildcat, Beowulf, Jericho, Shrike, Thundersword, Havoc); all are in the
generated `gamedata/tribes2/gameplay/hercs.json` (`tools/export_tribes_vehicles.py`).

In the catalog with their fixed weapons (mounts, fire rates, crew): tribes_vehicles.md.
(Vehicle stations `vehicle_pad`/`vehicle_pad_station` spawn them.) Turret family: base turrets (`turret_base_large` +
barrels AA/ELF/fusion/missile/mortar/plasma), sentry, deployables.

**Maps** (52 missions, `missions.vl2`) and **game modes** (scripts `*Game.cs`): CTF (17, e.g. Katabatic), Capture-and-Hold CnH (9),
Deathmatch DM (14), Hunters (12), Team Hunters (5), Bounty (8), Rabbit (3), Siege (7), single-player
Training1-5; the converted list is `gamedata/tribes2/maps/`. World sets: lush, desert, ice,
lava (volcanic), badlands.

## 4. Units (`gamedata/tribes2/units.json`): 1 unit = 1 m, speeds m/s, `*MS` fields in ms

1. **Shapes**: armor heights 2.28 (light male) … 2.65 m (bioderm heavy); the script `boundingBox` heights
   2.3 / 2.4 / 2.6 match. Vehicles 3.6 m (Wildcat) to 15.4 m (Havoc) long.
2. **Terrain**: `squareSize = "8"` in every mission's `TerrainBlock`, 256×256 heightfield → 2048 m block,
   placed at −1024 −1024; heights u16/32 in metres. Same 8 m / 2048 m grid as Tribes 1 (and the 2048 m block
   of Starsiege).
3. **Scripts**: light/medium/heavy max forward 14/11/6.5 m/s (50/40/23 km/h); jump 8.3 m/s; muzzle
   velocities 47-425 m/s; damage radii 4-30 m.
4. **Gravity**: not set in data; Torque's engine default −20 m/s² (Tribes 1 missions set the same value
   explicitly); jet accelerations 21-26 m/s² exceed it so armors can hover — consistent. `gravity_mps2: 20`.
   Ballistic projectiles (GrenadeProjectile, BombProjectile) do not use it: their tick (Tribes2.exe 0x61655b)
   falls at the engine constant at 0x779c54 (9.81) times the datablock's `gravityMod` (default 1.0). The
   importer reads that constant from the user's Tribes2.exe (`export_tribes_vehicles.t2_gravity`).

Engine integration: add `"tribes2": 1.0` to `WORLD_SCALE` in `game/engine/packs.gd` (units.json gives the
same 1.0 meanwhile). Lineup: `gamedata/tribes2/previews/scale_lineup2.png` (T2 light male 2.28 m vs Tribes 1
larmor 2.16 m; Shrike 11 m vs Starsiege Apocalypse 11 m tall).

## 5. Proof of life (`python tools/export_tribes2.py light_male heavy_male vehicle_grav_scout vehicle_air_scout`)

`gamedata/tribes2/`: `pack.json` (`{"name": "Tribes 2", "engine": "torque_v12", "unit_scale": 256.0,
"texture_format": "rgba", "weapon_families": ["infantry", "vehicle", "turret"]}`), `units.json`, and per shape:

* `textures/tribes2_<shape>/<i>.png` — **truecolour RGBA PNG** of material *i* (copied from the shipped PNG).
* `textures/tribes2_<shape>.json` — `[{w, h, file, format: "rgba", path, flags}]` per material index;
  `path` is relative to the pack (`textures/tribes2_light_male/0.png`), `null` if the texture is missing.
* `shapes/<shape>.json` — export_es1/export_tribes schema:
  * `lods[]`: one per renderable Torque detail (size ≥ 0), most detailed first, `{radius, center, size,
    name, pieces, cells: []}`; collision/LOS details are dropped.
  * piece `{node, id: 1000 + object index, name, cell: -1, state: 0, polys}`; objects with default
    visibility 0 (e.g. `Jetfire`) and decal meshes are skipped.
  * poly `{v: [[x,y,z]×3]` node space metres, `n`, `t: "torque_tri"`, **`m: {kind: "rgba", index: i}`**
    (or `kind: "none"` if untextured), **`uv: [[u,v]×3]`** (0..1, v down)}. The texture of `index` is
    `shape.materials[index].texture` (same path as in the texture-set JSON). Shapes mix `rgba` with nothing
    else; palette packs keep `kind: "tex"`.
  * `materials[]` `{name, texture, flags, w, h}` — Torque flags: 1 S-wrap, 2 T-wrap, 4 translucent, 8
    additive, 0x10 subtractive, 0x20 self-illuminating, 0x40 never env-map, 0x80 no mip-map, 0x08000000 IFL
    material: `texture` = the IFL's first frame and `ifl` `{frames: [paths], durations: [1/30 s units], fps: 30}`
    (frames saved as `textures/tribes2_<shape>/<i>_<k>.png`).
  * `nodes[]` `{parent, default, name}` + `transforms[]` `[rx, ry, rz (1/65536 turn, R = Rz·Ry·Rx), tx, ty,
    tz]` — default pose (armors stand in their weapon-holding default pose; the `root` animation is in
    `light_male_root.dsq`).
  * `ds_sequences[]` in-shape sequences (`JetFlare`, `Damage`, vehicle `MaintainBack/ActivateBack`, projectile
    `ambient` spin), then the armours' `.dsq` animations named by the TSShapeConstructor (`root`, `run`, `back`,
    `side`, `fall`, `jet`, `land`, `jump`, `death1`..`death11`, ...; `triggers` [[pos, state]] = the StateOn
    sequence triggers, 1 left foot / 2 right foot; `ground` = the ground travel of one cycle, metres), keys
    `[[pos 0..1, transform index]]` as in Tribes (a cyclic sequence spreads its keys over the cycle and wraps to
    the first); `cyclic` = Torque sequence flag Cyclic
    0x10 (Blend 0x08, MakePath 0x20); `bounds.header`; `winding_flipped` (true: Torque front
    faces are the opposite winding, normals were flipped to point outward).
* `previews/<shape>.png` (3 views), `previews/scale_lineup2.png`.

Godot runtime changes needed (beyond the Tribes list: use `poly.uv`, pack scale, `ds_sequences` player):
`ShapeInstance` must build a `StandardMaterial3D` with the PNG as albedo for `m.kind == "rgba"` (no palette
shader), honour flags 4/8 (alpha / additive blend) and 0x20 (unshaded), and support team skins by
swapping the `base.` texture prefix.

## 6. Plan for a full Tribes 2 importer module (~4-6 weeks to playable maps)

| step | work | effort |
|---|---|---|
| 1 | ZIP, DTS v22/23, PNG materials, datablock catalogue (**done**) | — |
| 2 | DTS v18-21 layouts (organics, projectiles, blaster) (**done**; v15/16 unused) | — |
| 3 | `.dsq` external sequences + `TSShapeConstructor` merge; armor animation player (blend run/side/back by velocity, look/head) | 2-3 days |
| 4 | Export all shapes; `gameplay/weapons_engine.json` with `category` infantry / vehicle / turret (vehicle images from `vehicles/*.cs`, armor images from `weapons/*.cs`); damage scale conversion (T2 armor 0.66-1.32 → ES HP) | 2 days |
| 5 | Armors + vehicles as engine units: jetpack (jetForce, energy drain, 20 m/s² gravity, skiing), hover/flying/wheeled vehicle physics from the datablock forces (`mainThrustForce`, `dragForce`, `hoverHeight` …) | 1-2 weeks |
| 6 | **Terrain** `.ter` (heights done; materials/alpha maps + `.dml` + detail textures) → 2048 m heightfield, wrap-around | 2-3 days |
| 7 | **Interiors `.dif` v44** (BSP geometry + surfaces + light maps + collision) — required for bases | 1.5-2 weeks |
| 8 | `.mis` object tree → mission JSON (teams, spawns, objects, interiors, turrets, stations, flags); game-mode rules CTF/CnH/DM/Hunters/Siege | 3-5 days + rules |
| 9 | Optional: AI from `ai*.cs` + `.nav` graphs; TorqueScript interpreter vs. GDScript re-implementation decision | weeks |

Missing decoders, in priority order: `.nav/.spn` (`.dsq`, `.dif` and `.ter` materials are done).

## 7. Arena maps (`python tools/export_tribes2_maps.py [--preview] [mission ...]`, importer step `maps`)

All 52 missions → `maps/<id>/` (map_schema.md): `height.r32` (mission area + 320 m, wrap-around sampled),
`albedo.png` (1 texel/m; material textures `textures/terrain/<name>.png` repeating every 64 m, blended by
the bilinear alpha maps; unlit), `detail.png`, `sky_*.png` (sky DML faces front/right/back/left/top/bottom;
`skybox` in engine +x,−x,+y,−y,+z,−z order), environment (SkySolidColor, fogColor, fogDistance →
visibleDistance, Sun, `water[]` from WaterBlocks), interiors `shapes/int_<dif>.json` (shared textures in
`textures/tribes2_interiors/`), TSStatics and station shapes through `export_tribes2.py`. Spawns: SpawnSpheres
→ `infantry` (`radius`, `indoor` when outdoorWeight 0, `above_terrain`); every `StationVehiclePad` →
`vehicle_pad` + `herc` (pad heading). Teams: Team1 → 0, Team2 → 1, neutral −1. The v19/v21 organics
(borg/porg/sorg/xorg) and `vehicle_air_scout_wreck` convert since the reader handles them. Not converted: force fields,
turret barrels, interior lightmaps.

## 8. Training missions and the mission runtime

**Export** (`python tools/export_tribes_missions.py tribes2`, importer step `training`; `voice.vl2` is unpacked
for it): `missions/missions/Training1-5.mis` -> `gamedata/tribes2/missions/<id>.mis` (UTF-8, as they are),
`scripts/TrainingN.cs`, `SinglePlayerGame.cs`, `spDialog.cs` -> `missions/scripts/`, `missions/_index.json`
(`[{id, name (// DisplayName), order, map, mission, scripts, briefing (the MISSION BRIEFING block), armor}]`),
`missions/datablocks.json` (catalog_tribes2: every `datablock Class(Name) [: Parent]`, parent fields merged:
`{lower name: {type, name, fields}}`), the voice clips `voice.vl2 audio/voice/Training/**` and the other clips the
scripts name (`"voice/derm2/gbl.woohoo.WAV"`) -> `audio/voice/<path, lower case>.wav` (IMA ADPCM decoded to PCM by
`tools/wav_pcm.py`). The maps are the arena maps (section 7: `maps/TrainingN/`).

**Script runtime**: the shared Darkstar runtime (`game/engine/script/`, see tribes.md section 8) in its TORQUE
dialect: `package` / activatePackage / deactivatePackage (a package's functions stack on top, `parent::` calls
the one below, else the same method in the parent namespace, else the engine's), `datablock Class(Name) [: Parent]
{}` (fields copied from the parent), `new Class(Name) { fields; nested new }` expressions, method calls
`obj.method(args)` (the first `<namespace>::<method>` along the object's name, script `class` / `superClass`, then
its engine class chain: `Tribes2Classes`), `switch` / `switch$` (case a or b:), `?:`, `do-while`, `$=` / `!$=`
(case-insensitive), `SPC` / `TAB` / `NL`, bit operators, `0x` numbers, `\c` colour codes dropped, `\xHH`;
numbers read the leading number of a string (atof), `==` is numeric, and a function that ends without `return`
yields its last expression's value (TorqueScript's behaviour: SinglePlayerGame::pickPlayerSpawn hands on
pickTeamSpawn's transform so).

**Runtime** (`Tribes2MissionRuntime`, base `TribesMissionRuntime`): the engine objects first - `Game`
(ScriptObject, class SinglePlayerGame, superClass DefaultGame), MissionCleanup, ClientGroup,
`$pref::TrainingDifficulty` = 1 (easy), `$currentMission` - then SinglePlayerGame.cs (execs spDialog.cs), then
the mission file (object tree, scriptlets such as deadArmor::onAdd, `exec("scripts/trainingN.cs")`: package
TrainingN activated). Every new object with a datablock gets `<datablock>.onAdd` when a script defines it. Start:
`Game.missionLoadDone()`, `Game.clientMissionDropReady(player's client)` (the script connects the enemies and
teammates - `AIConnect` -> `Game.spawnPlayer` -> `pickPlayerSpawn` -> `DefaultGame::createPlayer` (native: the soldier
at the transform) -> `playerSpawned` -> `DefaultGame::playerSpawned` -> `Game.equip(player)` - spawns the player and
calls startCurrentMission), then `PlayGui::onWake` when the script defines it (Training 1's intro). Teams: script
team 1 = the player's (battle team 0), team 2 the enemy. Drop points: `MissionGroup/Teams/team<N>/DropPoints`
(`/Respawns` for respawns); transforms (`Tribes2Transforms`) are `x y z ax ay az angle` (radians; engine yaw =
-angle for an upright axis; `.mis` rotations are in degrees). A single-player mission's map covers its drop
points too (`export_tribes2_maps.py`: Training3 starts 4 km outside its MissionArea, at the Shrike).
The voice: `doText` (SinglePlayerGame.cs) queues lines and `processText` plays them one after the other:
`messageClient($player, 0, text)` and `alxPlay(alxCreateSource(AudioChat, "voice/..."))` of the same step become one
radio line (speaker "Training", voice `tribes2:training/mission1/t1_01`, shown when the clip starts; voice-only
lines are only heard), timed by `alxGetWaveLen` (the exported clip's length). `messageClient(..,
'MsgSPCurrentObjective1' / '2', "", line)` -> objective lines 0 / 1 (announced), `'MsgClearObjHud'` clears them;
`addMessageCallback(tag, fn)` callbacks run. Message boxes (`messageBoxOk` / `MessageBoxYesNo`) show on the message
line and are answered after 4 s (OK; a Yes/No box's No): missionComplete's box (title "Victory") marks the mission
won, its forceFinish -> `Disconnect()` ends it; missionFailed's "No" ends it failed; the death box's OK respawns
(spawnSinglePlayer). AI tasks: `addTask(name)` makes a task object; when the script defines `<task>::assume` /
`weight` / `monitor` they run (assume once, then every 0.5 s) - Training 1's AITraining1Pilot flies the intro
bomber this way. `stepEngage(target)` / `stepMove(pos)` order the bot (TribesBot), `getStepName` answers.
Vehicles a script makes (`new HoverVehicle` / `FlyingVehicle`, datablock -> hercs.json `datablock`) are real
vehicles, parked and empty; `mountObject(player, slot)` hides the soldier in it and carries him along,
`setPilotDestination` flies it straight there (datablock maxForwardSpeed, else 60 m/s), `unmount` puts him back.
Touches: an item within 2 m -> `<datablock>.onCollision(item, player)` (scripts, else `ItemData::onCollision`:
weapon / ammo / pack / hand item into the inventory, RepairPatch heals 25 %); a shape whose datablock answers
onCollision (scripts, or FlipFlop: `playerTouch` -> the switch goes to the player's team) within 3 m; the mission
area (`MissionArea.area` x y w h) -> `Game.enterMissionArea / leaveMissionArea(datablock, player)`. A death ->
`Game.onClientKilled(victim, killer, ...)` (an AI victim then `Game.onAIKilled`). Engine methods
(`Tribes2Methods`): SimObject (getName, getId, getClassName, getGroup, delete, schedule, getDataBlock), SimSet
(getCount, getObject, add, remove, clear), SceneObject (get/setTransform, getPosition, getWorldBoxCenter),
ShapeBase (set/getInventory, clearInventory, use, getMountedImage, get/setDamageLevel, applyDamage, getState, hide,
isDisabled / isEnabled / isPowered, setDamageState, get/setVelocity, mountObject, unmount), Player.setArmor,
GameConnection / AIConnection (setTeam, isAIControlled, drop, stepEngage, stepMove, getStepName, addTask,
setPilotDestination), DefaultGame (createPlayer, playerSpawned, pickTeamSpawn, onClientKilled, cleanWord; the rest
no-ops). Functions (`Tribes2Functions`): nameToId, isObject, exec, schedule(ms, object, fn, args) / cancel /
isEventPending (an event bound to a deleted object is dropped), getSimTime (ms), messageClient / messageAll,
AIConnect, alxCreateSource / alxPlay / alxGetWaveLen, messageBoxOk / MessageBoxYesNo, Disconnect,
containerRayCast (physics ray), initContainerRadiusSearch / containerSearchNext (soldiers in the radius),
addTaggedString / detag; presentation-only functions and methods (skins, sensor masks, key maps, GUI controls,
cameras, HUD flashing, 2D sounds: `TribesPresentation`) do nothing. A method on a name that is no mission object is
one of the original's client-side objects (GUI) and does nothing; a method on a missing object (0 / "") is a
warning, as the original prints and goes on.

Approximations: the bomber intro of Training 1 is flown on rails (no flight model), its camera moves are not
shown; static shapes (generators, sensors, turrets, force fields) are the map's - script damage states are kept
but nothing is destroyed or repaired in the world (Training 2 / 4 / 5 objectives that need it cannot be reached by
play); the bots fight with the infantry AI under the orders above (the original AI's objectives queue,
`AIObjective`, and its chatter are not used); difficulty is always easy. Test: `res://tests/tribes_training_check.tscn`
(every mission 60 s without script errors, radio lines and objectives posted; Training1 finished at the MPB after
the script's own skipIntroCinematic()).
