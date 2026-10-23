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
`bExecuteOnce`). Converted kinds: move, guard, wander, patrol, attack, follow, and the crewed vehicles' (below). Not converted (no engine
counterpart yet): turret goals (GunnerGuard / GunnerFireAt, FireAt), animation / turn / ski goals, dodge / react / get-out-of-way (reflexes
the bot brain has).
Vehicle goals (`TVVehicleGoals`, host side): the same ops with the vehicle's label as Target. `AI_VehiclePatrolGoal` -> `vehicle_patrol`
(`patrolPointNames`, `bExecuteOnce`, `attackTargetName`, `DesiredSpeed` uu/s), `AI_VehicleMoveToGoal` -> `vehicle_move` (`destinationName`,
`DesiredSpeed`), `AI_VehicleAttackGoal` -> `vehicle_attack` (`targetName`), `AI_VehicleGuardGoal` -> `vehicle_guard` (holds where the vehicle
stands), `AI_EnterVehicleGoal` -> `enter_vehicle` (`vehicleOrTurretName`, `VehiclePosition`), `AI_VehicleExpellOccupantGoal` -> `expel`
(`occupantName`). The goal of highest Priority steers: it becomes an `AIOrder` (patrol = PATROL route, or TRAVEL when done once; move = MOVE
plan; attack = ATTACK on the target; guard = hold) that `VehicleOrders` gives the vehicle's FlyerAI (its `patrol` path and `target`, a flyer
flies the goal's DesiredSpeed as its cruise) or AIPilot (route, objective); an achieved goal (node reached, target dead, a once-patrol's last
node) is dropped and the next one takes over, then the vehicle holds where it stopped (a flyer circles). At equal Priority the goal done once
(move, attack) comes before the one that repeats (patrol, guard). A vehicle that is given a goal is crewed even when it is the player's side's
(the Mercy-Escape supply rover drives itself until the script has its pilot expelled). `ActionEnterVehicle` (a soldier takes the pilot's seat:
he leaves the world, the vehicle is crewed) and `ActionSpawnRook` with a `Vehicle*` SpawnClass (a crewed vehicle appears at the
`locationByActor` node, in the air for an air node, as `rookLabel`, of the team named by `teamLabel`; Mercy-Escape's two fighters) are the
script ops `enter_vehicle` and `spawn_vehicle`. Verified on the 11 SP maps that use them: 47 VehiclePatrol, 37 VehicleMoveTo, 7 VehicleAttack,
2 VehicleGuard, 4 EnterVehicle, 2 ExpellOccupant goal objects. Not decoded: `EnterVehicle` / `ExpellOccupant` goals of soldiers (the soldier
brain has no seat of its own), the speed of a ground vehicle's goal.

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
stands (the class -> mesh table `PROP_CLASSES`; the real assignment is in class defaults). The base objects and deployables are scenery:
no animation. The four vehicles are drivable (next section).

## Drivable vehicles (`tools/tv_vehicles.py`, `game/games/tribes_v/tv_vehicle_fleet.gd`)
Pod ("fighter"), Tank ("jump tank"), AssaultShip and Buggy ("rover") are catalog vehicles of the pack (`tribes_v:POD`, `TANK`,
`ASSAULT_SHIP`, `BUGGY`; `gameplay/hercs.json`, engine schema 1, category "vehicle", fixed loadout, crew rules "tribes2": a soldier boards
by touching the hull, heavy armour may not pilot), run by the shared Flyer / Herc code. Everything below is read from the UnrealScript class
defaults (`ue2_classes.py`: VehicleClasses.pkg over Gameplay.u; 1/70 m per unit, 65536 rotation units per turn, one health point = 26.4
Earthsiege points):

| | Pod | Tank | AssaultShip | Buggy |
|---|---|---|---|---|
| class | VehiclePod | VehicleTank | VehicleAssaultShip | VehicleBuggy |
| Health -> hull | 140 -> 3696 hp | 800 -> 21120 | 550 -> 14520 | 450 -> 11880 |
| kind (engine) | flyer | tank | flyer | wheeled |
| TopSpeed | 4400 uu/s = 62.9 m/s | 5000 uu/s, scaled to 17.0 m/s | 2100 = 30.0 m/s | 13250, scaled to 45 m/s |
| mass | HavokDataPod hkMass 1500 | ChassisMass 3000 | hkMass 10000 | ChassisMass 3000 |
| seats (`positions`) | 1 | 2: driver, gunner | 3: pilot, 2 gunners | 6: driver, gunner, 4 passengers |
| turret | none | cannon: +54.9 / -27.5 deg, 132 deg/s (cannonMaximum / MinimumPitch, cannonClientTurnRate 24000) | none (guns fixed to the crew aim) | gun: +65.9 / -16.5 deg, 165 deg/s (gunnerClientTurnRate 30000) |

Aircraft (`flier_data` for `FlightPresets.make_tribes_datablock`): maxSpeed = TopSpeed; accel = forward force x ForceScale (250) / hkMass as
a share of the top speed per second (Pod 9.5 m/s^2, ship 7.9); lift from the up thrust force the same way; maxPitch = maximumAircraftPitch
(Pod 4000 = 0.38 rad, ship 5000); hoverHeight half of gearTraceLength (600 uu); bank 0.5 rad x angularBankScale (clamped 0.15..0.5).
The cars (Havok wheel physics, no speed limit in the defaults): the Rover's TopSpeed is capped at the Tribes 2 Wildcat's 45 m/s and the
tank's scaled by the same factor; reversing at 0.4 x, full speed in 5 s, turn rates those of the Beowulf (1.2 rad/s) and the Wildcat (2.0).
These four numbers are remake choices, not decoded.
Weapons (`gameplay/weapons_engine.json`, category "vehicle", no energy use; the fields of the hand weapons, `tv_weapons.py`):
FIGHTER rockets (WeaponVehicleFighterRocket 2.2/s, 13000 uu/s, radius 300 uu, 35 dmg; two guns share the rate), TANK_CANNON
(WeaponVehicleTank 0.32/s, 8000 uu/s, radius 1600, 140), TANK_CHAINGUN (the gunner's WeaponVehicleTurretSentry 16/s, 30000 uu/s, 14),
SHIP_BOMB (WeaponVehicleAssaultShipBomb 0.32/s, a lobbed 4000 uu/s bomb, gravity 1.2x level, radius 1600, 150), SHIP_AA (the two turrets,
ProjectileAntiAircraft 2.2/s, radius 900, 25), BUGGY_AA (3/s). Fire groups: group 1 the guns (rockets, chaingun, AA), group 2 the cannon and
the bomb (the Beowulf's arrangement). A gunner aboard works every weapon of the vehicle (`TurretCrew`); alone the pilot fires them.
Shapes: the rest-pose props get a second-root `turret` node (tank, buggy: yaw about the world's up axis), `muzzlepoint` nodes at the barrel
tips of the turret models (`tv_prop_tankcannon`, `tankgunner`, `assaultshipgun`, and `tv_prop_turretbuggy` exported from Weapons.pkg) and the
guns hang on them as weapon models.
Moving parts and riders (`tools/tv_vehicle_parts.py`, `game/engine/vehicle_parts.gd`): the vehicle meshes keep their vertex influences in front
of each level of detail (influences, wedges, triangles, points; `ue2_skeletal` looks there when the usual place behind the points has none).
Only the Rover's list is in step with its points (no triangle spans two bones); the Pod's, Tank's and Assault Ship's list is not (44 / 90 / 76
per cent of their triangles span bones, wings of both sides among them), so for those the connected parts of the mesh (points that share
triangles: a wing disc, a leg, an engine, a track) follow the bone nearest their centre, the root when none is within 1.2 part radii. The
shapes now have every part on its own node and the sequences of the MeshAnimation of the same package as `ds_sequences`: AssaultShip
GearDown / GearUp, WingsOpen / WingsClosed / WingsLeft / WingsRight, Hatch*; Tank leftforward / rightforward / ...backward (10 frames, the
track teeth move 1.07 m per cycle), jetopen / jetclose; Pod Idle (201 frames) and the engine poses thrust / dive / throttleForward / Back /
strafeLeft / Right; Buggy Hatch*. GearDown, WingsOpen and the Idle first frame are the rest pose, so every sequence is a pose relative to the
rest pose and `VehicleParts` stacks them by weight: wheels (the Rover's four, radius = WheelRadius 0.857 m) turn by the distance driven and the
front pair steers (SteeringMaxAngle 6500 = 35.7 degrees, by the heading change); the ship's gear folds as it climbs from half its
gearTraceLength (4.3 m, where it hovers) to the whole (8.6 m), its wings are folded while it stands and open in flight and bank with the turn;
the tank's tracks run by each side's speed (one tooth pitch per cycle); the pod's engines idle and tilt with throttle, climb and strafe. The
motion is read from the replicated position and heading, so every peer shows the same. Not done: the tank's turret mesh does not turn with its
gun (the `tankturret` part stays on the hull), the Rover's shocks do not compress, the mirrored back legs of the ship share one bone (a pitch
about the lateral axis folds both alike).
Seats: the `positions` struct array of each vehicle class (read with the class's own name table: the Rover's is in `Buggy`) says who is drawn:
`hideOccupant` false only for the Pod's pilot (`occupantConnection` Character, `occupantAnimation` Pod_Stand), the Rover's driver (Character,
Buggy_Stand) and the Assault Ship's two gunners (gunnerleft / gunnerright, AShipGunner_Stand); the Tank's crew, the ship's pilot, the Rover's
gunner and its four passengers are hidden. The animation's `Character` / `CharacterLeft` / `CharacterRight` bone is where the rider's body
stands, so the shape gets a `seat<i>` node there and `vehicle_seats.json` lists `{node, shown, pose}` for the shared rider code
(`InfantrySeat`); the seat poses are added to the soldier bodies (`tv_phoenixmedium` ... have `pod_stand`, `buggy_stand`, `ashipgunner_stand`,
`aship_stand`; the heavy armour has only the gunner's). The riders keep no weapon in hand.
Maps: a placed `Vehicle*` actor becomes a record of `map.json` "vehicles" ({vehicle, actor, label, pos, basis, yaw, team_name,
health_modifier, ai_goals}); the vehicle meshes are no longer scenery statics (54 in the 33 maps). `TVVehicleFleet` makes each appear within 450 m
of the player, standing on the floor under the actor: parked and empty (boardable) when it is the player's side's or nobody's, crewed by the
AI pilot (`FlyerAI` loop of 150 m, `AIPilot` to and fro; they attack what they meet) when it is the enemy's and the actor has AI goals, and
steered by the goals its script gives it (see "AI goals"). A script label addresses the vehicle: ActionDestroy / ActionEnable and MessageDeath
work as for soldiers, and the seats raise MessageDriverEnter / DriverLeave / GunnerEnter / GunnerLeave (10 + 4 + 1 + 5 scripts use them).
Vehicle pads: `BaseObjectVehicleSpawn{Fighter,Buggy,Tank,AssaultShip}` (one in SP-Proof, the Assault Ship's) become `map.json` "vehicle_pads"
({vehicle, shape (the class's Mesh: `tv_prop_vehiclespawn*`), spawn_s (spawnDuration 90 / 90 / 180 / 210 s), offset_m (spawnOffsetHeight 40 uu),
abandon_radius_m / abandon_s (abandonmentDesturctionStartRadius 5000 uu and Period 60 / 90 s)}), also as "stations" of kind vehicle with a
`vehicle` field. The pad holds its vehicle, which scripts call by the pad's label + "vehicle" (the objective markers and goals of SP-Proof
and SP-Prison-Exterior do): it appears like a placed vehicle, a new one is built `spawn_s` after it is gone, and an empty one left
`abandon_radius_m` away for `abandon_s` is destroyed. The shared `TribesStations` sells the pad's own vehicle to a soldier standing on it
(`make_station_vehicles`, `find_own_pad`: the same menu and the same clear-pad rule as the Tribes 2 vehicle stations; one vehicle on the
pad at a time). Vengeance has no vehicle-pad cloak (its pack has no timed cloak profile), so no flash.
Tests: `tests/tv_vehicles_check` (catalog, maps, boarding, driving, firing, destruction, AI crews, riders, wheels / gear / wings / treads,
pad, pad station, abandonment, VehiclePatrol, VehicleMoveTo, script-spawned vehicle), windowed `tests/tv_vehicle_shots` (`TV_SHOT_DIR`: riders
and pads too), the facing is `vehicle_facing_check`'s.

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
- Weapon first-person skeletal meshes and the vehicle wheel / wing / track animations (L); the unplayed speech (about half of the 6353 files, MP quick chat).
- AI goals, cinematics and the remaining script messages (M); the class defaults (real meshes, sounds, weapons per character) (M).
- Baked lightmaps (BSP, terrain) and vertex lighting, water, sky boxes (`Content/Art/SkyBoxes`), particle emitters.

## Legal
Code and format notes only; no game data in the repo; everything is read from the user's own copy. innoextract is a
separate program (zlib license); see THIRD_PARTY_NOTICES.md.

## Infantry weapons (`tools/tv_weapons.py`, `tools/ue2_classes.py`)
Weapons are UnrealScript classes; their `defaultproperties` are a tagged-property stream at the end of each Class export
(`ue2_classes.read_class_defaults` takes the longest clean stream ending at the export end), merged along the super chain
(EquipmentClasses.pkg over Program/Bin/Gameplay.u). Eight weapons are exported to `gameplay/weapons_infantry.json`: Spinfusor,
Chaingun, Blaster, Grenade Launcher, Mortar, Sniper Rifle, Rocket Pod, Burner (EnergyBlade, Grappler and Buckler are melee / no
damage). Fields used: `roundsPerSecond`, `projectileVelocity`, `numberOfBullets`, `energyUsage`, `Spread`, `minSpread/maxSpread`,
`numProjectiles`, `launchDelay`; projectile class `damageAmt`, `radiusDamageAmt/Size`, `LifeSpan`, `MaxVelocity`,
`AccelerationMagtitude`, `GravityScale`, `postSpreadVelocity`; `LevelInfo.DefaultGravity` -1160 uu/s^2 (x GravityScale 1.2 = 19.9
m/s^2, the same as Aerial Assault's -20).
Units: 1/70 m per uu (a 4700 uu/s spinfusor = 67 m/s, the Tribes 2 disc speed). Damage: the light armour `Health` 75 = 1980 hp,
26.4 hp per health point (spinfusor 58 -> 1531, close to the Tribes disc 1500). Energy x 0.6 (pool 100 -> 60). The armours' `AllowedWeapons`
struct array ({typeClass, quantity}) gives the weapons and rounds per size, `maxCarriedWeapons` the slots, Health 75/100/195 and
energy 100/105/125 (`infantry_rules.json`). The multiplayer loadout classes are not decoded: the default kit is Blaster, Chaingun,
Spinfusor where allowed. Held models are the `*Held` static meshes of Content/Art/Weapons.pkg (`gameplay` shapes `weapons__*`),
projectile meshes Disc, Grenade, Rocket; fire and impact sounds from `audio/sounds.json` (tv_weapons). Not modelled: chaingun
heat, blaster bounce, burner burning area, rocket steering, sniper charge damage.
Check: `res://tests/aa_tv_weapons_check.tscn` (shared with Aerial Assault).
