# Tribes: Vengeance (PC, 2004, Unreal Engine 2.5)

Status: campaign imported (pack `tribes_v`): 16 chapters, 33 maps in story order, objective text, player and NPC
spawns, terrain (19 maps), textured static meshes and brush shells, **sounds and speech, skeletal armour/character bodies with
animations (offered as infantry bodies, worn by the mission's soldiers), vehicle and base-object shapes, and the mission scripts
(objectives, speech, triggers, spawns, mission end) run by the game**, and the lighting (sun, zone ambient, distance fog, placed point lights; no lightmaps).
Code: `tools/tv_unpack.py`, `tools/ue2_package.py`, `tools/ue2_texture.py`, `tools/ue2_skeletal.py`, `tools/tv_assets.py`,
`tools/tv_terrain.py`, `tools/tv_statics.py`, `tools/tv_bsp.py`, `tools/tv_audio.py`, `tools/tv_skeletal.py`, `tools/tv_script.py`,
`tools/tv_import.py`, `tools/siege_games/tribes_vengeance.py` (generic importer: supported).
Game side: `game/games/tribes_v/` (provider, `TVMissionRuntime` on top of the Aerial Assault runtime, `TVScriptHost` (on `MissionTask`) the script
interpreter), `InfantryCatalog.make_tv_bodies`; checks `res://tests/tv_campaign_check.tscn`, `tv_script_check.tscn`,
`tv_soldier_check.tscn` (bodies; shots with `TV_SHOT_DIR`), `tv_npc_shots.tscn` (`TV_TEST_ROOT` = scratch data folder).

## Container (verified)
`TribesVengeance.zip` (3.09 GB): `setup.exe` (1.0 MB), `setup-1.bin` (2.10 GB), `setup-2.bin` (0.99 GB), all deflate64
(zip method 9: read with the `inflate64` package). They form an Inno Setup installer, unencrypted; `innoextract` 1.9
(zlib license, downloaded and SHA-256 checked by `tv_unpack.py`) extracts it in ~minutes to **11 GB** (6353 ogg speech
files dominate). Use a SHORT scratch path (`C:	vs2`): the speech files exceed Windows MAX_PATH under a deep one.

## Installed file tree (`app/Tribes Vengeance/`)
- `Content/Maps/`: `.tvm` map packages (SP-* campaign 29 files, MP-* 140+, Prefab*, Entry, AUTOPLAY) and `*Textures.pkg`
  texture packages. Same UE2 package format, magic `C1832A9E`.
- `Content/Art` (+ `Environments`, `SkyBoxes`): `.pkg` art (weapons, armours, vehicles, FX, HUD, GUI), 44+19+18 files.
- `Content/Classes/*.pkg` (19): game class data packages; `Content/Sounds/*.pkg` (54); `Content/Skins`;
  `Content/Cutscenes`: `.tvm` cutscene maps, `.umj` scripts; `Content/HavokData`.
- `Content/System/`: `.int` text (108), `Campaign.ini`, `*.ini`, `Localisation/**` (6353 `.ogg` speech, `Maps/text files/SP-NN*.int`
  objective and dialogue text, `Cutscenes/text files`).
- `Program/Bin/`: 48 `.u` UnrealScript packages (Engine, Gameplay, TribesTVClient...; includes community mods), exes, dlls.
- No `.utx/.usx/.ukx/.uax` extensions: everything is `.pkg` (art, sounds) or `.tvm` (maps).

## Package format (verified on 89 packages)
`tools/ue2_package.py`: version **130**, licensee **27** (a few `.u` are 129 and 126/21), header 64 bytes then name table
(compact-index length string + u32 flags), import table, export table, one generation. No package-level compression
(flags 0x1 or 0x0). Export serial data holds tagged properties after a variable state header for actors (flag
0x02000000); `object_properties` finds the start by trying offsets and requiring a clean stream ending in `None` at the
export end. Rotators are three int32 (65536 per turn). Decoded elsewhere: Texture (`ue2_texture.py`), StaticMesh (`tv_statics.py`), Polys (`tv_bsp.py`), Sound (`tv_audio.py`),
SkeletalMesh / MeshAnimation (`ue2_skeletal.py`). Not decoded: compiled Model/BSP, TerrainSector.

## Campaign (verified)
Order from `Content/System/Campaign.ini` (`missions=(...)` lines, `; NN-Name` chapter comments):
01 Spaceship (SP-Spaceship); 02 Captured (SP-Captured, SP-Captured-Towers); 03 Coliseum (Coliseum, Coliseum-Fuel, Coliseum-Arena);
04 Firstblood (FirstBlood, -Interior, -Arena); 05 Palace (Palace-Base, Palace-Attack); 06 Rescue (Rescue-Exterior, -Victoria, -Daniel);
07 Mercy (Mercy-Escape); 08 Assassinate (-Exterior, -Interior); 09 Prison (-Exterior, -Interior, -Junkyard); 10 Assault (-Sewers, -Interior);
11 Proof; 12 Regicide; 13 Revenge (-Descent, -UnderCity, -Ascent); 14 Trials (Trials-Nexus); 15 Truth (Truth, -Hunt, -Bunker);
16 War (War-Ski, War-Spaceship). Each has start/end cutscene maps (`CS-*.tvm`). Titles: `Content/System/SP-<map>.int` `[LevelSummary]`
(for example "Victoria: The Past - Captured": the chapters alternate protagonists and timelines).
Objective text: `Localisation/Maps/text files/SP-NN*.int` `[Objectives]` (`OBJ_02CAP_n`) and `[Mission Text]` (spoken lines
`MIS_02CAP_DAN_96`). There is **no written briefing**; the importer uses the first spoken lines of the map script as a stand-in.
Mission logic is UnrealScript actions placed in the map (`Script` actors with `ActionObjectiveAdd`, `ActionSpeak`,
`ActionEnableAISpawnPoint`...). The importer reads the actors: `SPStartDefault`/`SinglePlayerStart` (player start),
`AISpawnPoint` and placed `AI*` actors (NPCs), `TriggerRadius` objmarker_* (objective positions via `ObjectiveActors`).
Objective text is matched only where `ActionObjectiveAdd.Description` is an `OBJ_` key (25 of 33 maps).

## Scale and coordinates (verified)
Unreal units; 1/70 m per unit. Evidence: `Engine.u` Pawn defaults CollisionHeight 78 / CollisionRadius 34 (156 units tall,
read from the class defaults), the engine's medium soldier is 2.2 m tall, so 0.0141 m/unit; 1/70 is used (the usual
50 units/m would make the soldier 3.1 m). Frame: UE (x forward, y right, z up) -> engine (y, z, -x) metres; yaw = -UE yaw;
rotators are three int32, 65536 per turn.

## Terrain (done, `tools/tv_terrain.py`; 19 of 33 maps)
`TerrainInfo` actor: `TerrainMap` = G16 Texture (512 x 512) in the map's `*Textures.pkg`, `TerrainScale` (208, 208, z range per
256 steps), grid centred on the actor `Location`, `height = Location.z + (v - 32768) / 256 * scale.z`, `DrawScale` ignored
(checked by comparing static-mesh heights with the grid: median offset 0 to 20 units). Albedo = the finalised macro texture
(DXT1 2048). A map with no macro texture (SP-Captured, SP-FirstBlood-Interior) gets its albedo baked from the `Layers`: each is
a `Texture` plus an `AlphaMap` (RGBA8 over the grid; the weight is the ALPHA channel), layer 0 the base and each later layer
blended over by its alpha; a texture tiles every UScale * 128 units and `TextureRotation` (65536 = a turn) turns it
(`tv_terrain.bake_layers`, 4096 px; `python tools/tv_terrain.py <game root> <pack>` bakes it for the maps that lack one). Detail
textures, decoration layers and the quad visibility bitmap (holes) are not converted; maps
with several TerrainInfo actors (cave pieces) use the one with the biggest heightmap. `tools/ue2_texture.py` decodes
DXT1/3/5, G16, L8, RGBA8, P8 (palette objects not read).

## Static meshes (done, `tools/tv_statics.py`; about 98% of the meshes of the packages tested)
`StaticMeshActor` -> `StaticMesh` export (own package, usually `Content/Art/Environments/*.pkg`). Native layout after the tagged
properties: bounding box + sphere, section table, bounding box again, vertex stream (position + normal, 24 bytes), colour /
tangent streams that vary by mesh, UV stream, index buffer (u16); the module finds the UV stream and the index buffer by
validation. Section i uses `Materials[i]`; materials resolve Shader.Diffuse -> Texture; chains also follow
MaterialSwitch.Material, Tex* modifiers (Material), Shader.SelfIllumination and FallbackMaterial when Diffuse is absent. Shapes are written as engine shape
JSON in the shape frame (x right, y forward, z up = Unreal y, x, z; ShapeInstance converts it to the engine's frame itself, so shapes
must NOT be stored in the engine's frame: an earlier version did and laid every static and brush shell on its side) (`shapes/<package>__<mesh>.json`, textures `textures/tv/*.png`, limited to 512 px); instances use a basis built from the
rotator and DrawScale/DrawScale3D. Not done: LODs, vertex colours, second UV sets, collision proxies (the engine builds
trimesh collision), skeletal meshes, `Projector`/decal actors.

## Lighting (done as actors, `tools/tv_lights.py`)
Read from the placed actors; the engine map gets `environment` (`ambient`, `fog_color/start/end`, `sun_dir`, `sun_color`,
`horizon_color` when the zone clears to its fog colour) and `point_lights` (`MapLights`: a pool of 40 omni lights follows the
nearest of them). Verified facts:
- Colour of (Hue, Saturation, Brightness) bytes is Unreal's FGetHSV: `V = b*1.4/255; V *= 0.7/(0.01+sqrt(V))`; hue picks a point on
  the red-green-blue ring (0-85 red to green, 86-170 green to blue, 171-255 blue to red); saturation 255 is WHITE. It reproduces the
  zones' stored `AmbientVector` to 4 digits (SP-Captured zone 3: hsv(149,150,50) = 0.2116 0.2483 0.3232, stored 0.2117 0.2483 0.3233).
- Class defaults (Engine.u class exports, tagged defaults): Light brightness 64, radius 64, saturation 255, type steady;
  ZoneInfo ambient saturation 255, fog colour (128,128,128), start 3000, end 8000. `Sunlight` = Light + LightEffect sunlight.
- World radius of a light = 25 * (LightRadius + 1) units (the engine's WorldLightRadius); capped at 120 m.
- An actor's `Region` struct ends `04 01 <zone number> 00`; the ZoneInfo standing in the zone of the player start sets the map's
  ambient and fog (maps whose start has no ZoneInfo use the first terrain zone, else the first zone). Fog colour is a BGRA Color.
- The sun: the brightest `Sunlight` (the engine has one sun; Coliseum has a second, fainter blue one and Palace up to five); its
  `Rotation` (pitch, yaw, roll, 65536 per turn) points along the light. Maps without a Sunlight get a black sun.
- Light types: 1 steady, 2 pulse, 3 blink, 4 flicker, 5 strobe, 7 subtle pulse (animated by `MapLights.energy_scale`).
- No lightmaps, so the map's ambient never falls below `AMBIENT_FLOOR` (0.25): rooms whose zones have ambient 0 rely on the baked lightmaps, which are not decoded.
  A map without a sun (interiors) is lifted to the mean colour of its placed lights x 0.9, at most 0.5 (`tv_lights.interior_ambient`), so the
  rooms read between the lamps; the engine has one ambient per map, not one per zone.
- `DynLightHanging` / `DynLightStrip` are physics props (a mesh with no light), not lights.

## AI goals (`tools/tv_script.py` op `goal`, `game/games/tribes_v/tv_npc_goals.gd`)
`ActionAddGoal` / `ActionReplaceGoal` / `ActionRemoveGoal` (Target = AI actor, spawn point or `AISquad` label; `goal` names an
`AI_*Goal` export placed in the map) become `{op: goal, mode, target, name, goal}`. Verified on the 29 SP maps: 45 AddGoal, 45
ReplaceGoal, 4 RemoveGoal in the first five maps alone; every soldier has an implicit `DefaultGuardGoal` (ReplaceGoal's
`nameOfGoalToReplace`). Goal properties read: `goalName`, `Priority` (default 50), `destinationName` (a node label, MoveTo /
SquadMoveTo), `targetName` (Attack / Follow; `Player` is the player), `movementAreaCenterName` + `movementAreaRadius` (Guard /
SquadGuard, units), `proximity` (Follow), `patrolPointNames` (a compact-index array of name-table indices naming the nodes;
`bExecuteOnce`). Converted kinds: move, guard, wander, patrol, attack, follow. Not converted (no engine counterpart yet): vehicle
goals (VehicleMoveTo / Patrol / Attack / Guard, EnterVehicle, ExpellOccupant), turret goals (GunnerGuard / GunnerFireAt, FireAt),
animation / turn / ski goals, dodge / react / get-out-of-way (reflexes the bot brain has).

## Editor brushes (approximation, `tools/tv_bsp.py`)
The compiled BSP (`Model` exports of 4 to 20 MB) is not decoded. Instead every `Brush` actor with CsgOper add/subtract is read
through its Model's `Polys` export (polygon lists in brush space; trailer 13 bytes) and written as one shape per map
(`shapes/bsp_<map>.json`): additive faces point outward, subtractive ones inward, so rooms show their shells. No CSG
cut-outs, no zones, portals or invisible faces. Each polygon's material ref (Polys trailer) resolves through the shader chain to a
Texture; UVs = (vertex - Base) . TextureU/V divided by the texture size (shifted to start near 0, textures repeat). Polygons
whose material is an editor placeholder (engine `DefaultTexture`, `ConsoleBK`, both P8 without a palette) or absent are skipped,
which removes the big white volume boxes (the skip must look the name up per material ref: a stale name from the previous
material let those faces through and made SP-Captured a white sheet). Collision is the trimesh of the shell. `python tools/tv_bsp.py <game root> <pack>`
rebuilds the shells without the full import.

## Audio (done, `tools/tv_audio.py`)
`Content/Sounds/*.pkg`: every `Sound` export holds a complete RIFF/WAVE (PCM 16-bit, 22.05 or 44.1 kHz mono) after the tagged
properties; the RIFF length field gives the exact end, so the files are cut out as they are: `audio/sfx/<package>/<sound>.wav`
(1274 sounds, 164 MB; cutscene `TV_cs*` and `QuickChat*` packages skipped), played as `Sfx.stream("tribes_v:<package>/<sound>")`.
`audio/sounds.json` lists them with lengths and maps the weapons by the naming convention (`Spinfusor_Fired1`, `SpinfusorProj_Exp2`:
`{Weapon: {Event: [stems]}}`; the weapon classes' own sound references are compiled UnrealScript defaults, not read). Missions: a map
references sounds through `ActionPlaySound.SoundToPlay` (an import of a Sound; `script.json` op `sound`); ambient actors name theirs
only in class defaults (not read). Speech: `ActionSpeak.SpeechTag` is the file name of an Ogg Vorbis under
`Localisation/Maps/VO/SP-NN*/`; the lines the campaign speaks are copied to `audio/voice/<tag>.ogg` and `map.json` lists them
(`voice`) with the played sounds (`sounds`). Subtitles come from the chapter `.int` `[Mission Text]`.

## Skeletal meshes and animations (done for the armours and characters, `tools/ue2_skeletal.py`, `tools/tv_skeletal.py`)
`SkeletalMesh` (layout in the module docstring): bounding box and sphere, materials, mesh scale/origin, a progressive-mesh stream
this importer skips, then the bone array (57 bytes each: name, flags, orientation quaternion, position, length, size, child count,
parent), and later wedges (u16 point, u, v), triangles (3 wedge indices + material), points (Unreal units) and the vertex influences
(f32 weight, u16 point, u16 bone); the arrays are found by validation (104 of 128 meshes of `Content/Art` parse strictly, all the
armours and characters; the rest parse leniently for rest-pose use). Bone quaternions are stored with w negated for every bone but
the root (checked: forward kinematics then puts each bone inside the vertices bound to it). `MeshAnimation`: bones by name, one
motion chunk per sequence (per-bone tracks of quaternion / position / key-time arrays, key times in frames), and the sequence table
(name, frames, rate 25, footstep notifies). The light armour package holds 204 sequences (`Neutral_Run_Forward`, `Alert_Stand`,
`Female_Alert_Run_Left`, `A_Taunt1` ...); the armours are rigidly skinned (every influence weighs 1.0).
`tv_skeletal` writes one shape per body: a node per bone, every triangle riding the bone most of its vertices belong to (vertices in
that bone's frame), `ds_sequences` named root / run / back / side / jet / fall / land / death1 plus character poses, the stride
(`ground`) and footstep triggers measured from the feet, and a `mount0` node on the right hand for the weapon. 37 bodies
(`gameplay/bodies.json`): the three factions' light / medium / heavy soldiers, male and female, named characters (Daniel, Mercury,
Jericho, Julia, Victoria, Olivia ...), civilians and the Glorax. Offered bodies (`offer`) appear in the body picker of every armour of
their size (`InfantryCatalog.make_tv_bodies`, label "Vengeance Phoenix", "Vengeance Imperial Female" ...). Deaths: only the light
armour has one (`A_BeckonDie`); it is borrowed for the others.
NPC classes map to bodies by name (`tv_skeletal.npc_body`: faction Phoenix / Beagle (Blood Eagle) / Imperial, type -> size: Grunt1,
Ninja, Scout, Sniper1, Pilot light; Grunt3, Grenadier2, Spammer, Rocket, Boss, Protector heavy; the rest medium; `AICustom<Name>` the
named character; the class defaults that hold the real mesh are not read).

## Props and vehicles (rest pose only, `tv_skeletal.export_props`)
Pod, Tank, AssaultShip, Buggy and their gunners, base objects (turret, catapult, generator, resupply, sensor tower, inventory station,
spawn pads) and deployables are skeletal meshes: exported as rest-pose shapes `tv_prop_<mesh>` (`gameplay/props.json`), bound to the
root bone when their influence table is not found, and placed in the maps where a `Vehicle*`, `BaseTurret*`, `BaseCatapult` ... actor
stands (the class -> mesh table `PROP_CLASSES`; the real assignment is in class defaults). They are scenery: no driving, no turret
control, no animation.

## Mission scripts (done, `tools/tv_script.py`, `game/games/tribes_v/tv_script_run.gd`)
A map's logic is its `Script` actors. Each has a Label (the name `targetScript` uses), a MessageClass (the event) with TriggeredBy
(labels of the actors that raise it; "All" in any case = everyone) and an `Actions` array of compact object references to `Action*`
exports. Verified property layout (29 SP maps): array properties are a compact count then compact references (export index + 1);
`ActionIf` has `testsOr` (BooleanStatement refs, ORed), `trueActions`, `elseActions`; `ActionLoop.loopActions`, `ActionFor.forActions`;
`BooleanStatement` has `lhs`, `rhs` and a `resolveInfoList` byte record per side that is a variable (`0x1a 0x16 <name> 0x19 0x16
'lhs'|'rhs'`, names like `global.skiing01through`); the comparison is equality (no operator property is stored).
Message classes in the maps: TriggerEnter 708 scripts, Death 246, AISpawned 98, Watcher 68, SquadDeath 67, Used 67, LevelStart 66,
TriggerExit 40, Damaged 37, PlayerStart 30, Destroyed 26 ... The runtime handles LevelStart, PlayerStart, TriggerEnter/Exit (the
`TriggerRadius` actors, one cylinder per label), Death (the label of a placed soldier), SquadDeath, AISpawned and CountDownExpired;
Used, Watcher, Damaged, Territory*, Driver* and the inventory messages are not raised.
Actions executed: speak (plays the .ogg, subtitle, waits for its length), wait, objective add / complete / fail / remove (the panel and
the compass markers from `ObjectiveActors` labels), script calls (blocking or not; a non-blocking call of a script that already runs is
ignored: Regicide's crowd chant starts itself), if / loop / for, variables (one shared table; random sets `rand`), enable / disable /
destroy actors by label (scripts, triggers, soldiers), AISpawnPoint enable / disable (spawns the soldier), teleport, damage to the
player, prompts (`Localisation/GUI/Prompts.int`), sounds, countdown, **next mission = win, fail mission = loss**. Not executed: AI goals
(guard, move, fire-at: the soldiers use the standard bot brain on guard duty at their post), cameras, cinematics / talking heads, doors,
effects, vehicles entering or spawning, quakes, god mode, watchers. All 33 maps have a `next`.
Placed soldiers (`AI*` actors, `AISpawnPoint`s) appear when enabled and the player comes within 170 m, in the Vengeance body of their
class on a Tribes 2 armour of that body's size; the TeamInfo name decides ally (same as the player start's) or enemy. The player wears
the body of the start's pawn class (SPCharacterVictoria -> Victoria ...). Maps without a script keep the Aerial Assault fallback.

## Generic importer
`siege_import.py import <TribesVengeance.zip>` works: the zip is opened as `siege_iso.ZipSource`, the step unpacks into a
short `%TEMP%/tv*` folder (needs about 14 GB free at its peak: 3 GB inflated slices + 11 GB game), converts, deletes the scratch.
Run time is roughly 15 to 25 minutes (inflating 3 GB, innoextract, 33 maps).

## Remaining geometry work
- Compiled BSP (`Model`): points, vectors, nodes, surfaces, vertices to replace the brush shells (L).
- Terrain layers/detail/holes, `TerrainSector` visibility; decoration layers (grass, trees) (M).
- Weapon first-person skeletal meshes and the vehicle bindings / animations (L); the unplayed speech (about half of the 6353 files, MP quick chat).
- AI goals, cinematics and the remaining script messages (M); the class defaults (real meshes, sounds, weapons per character) (M).
- Baked lightmaps (BSP, terrain) and vertex lighting, water, sky boxes (`Content/Art/SkyBoxes`), particle emitters.

## Legal
Code and format notes only; no game data in the repo; everything is read from the user's own copy. innoextract is a
separate program (zlib license); see THIRD_PARTY_NOTICES.md.
