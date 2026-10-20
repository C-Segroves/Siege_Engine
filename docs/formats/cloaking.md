# Cloaking: what each game has, and the shared mechanic

Researched 2026-10-19 from each game's own data (installed scripts, datablocks, string tables, the PS2 disc, the
Vengeance install), not from memory. The remake has one cloak (`engine/stealth/`: `CloakProfile`, `CloakState`,
`CloakRules`, `CloakVisual`, `engine/shaders/cloak.gdshader`); each game plugs its numbers in as data
(`gamedata/<pack>/gameplay/cloak.json`, written by `tools/export_tribes_gear.py` and
`tools/export_starsiege_gameplay.py`). Test: `tests/cloak_check.tscn`.

## 1. Which games have a cloak

| Game | Cloak? | Evidence |
|---|---|---|
| Earthsiege 1, Battledrome, Earthsiege 2 | no | a byte search of the extracted data and the installers (`es2/extracted`, `es2/original`, `original`, `bd/original`) finds no `cloak`, `stealth` or `camoufl` (only Diamond Stealth video-card drivers and a French line about an invisible enemy in the Battledrome readme). ES2 has only ECM pods. |
| Starsiege | yes: two cloak components, an AI order, a player action | section 6 |
| Tribes 1 | no | `tribes/extracted` has one hit for `cloak`: `scripts/fear.strings.cs:1400` `IDDTS_CLOAKPACK = 00210532, "cloakpack"`, a shape id with no pack, item, armour entry or script behind it (`ArmorData.cs` `$ItemMax[larmor, ...]` lists energy, repair, shield, sensor jammer, motion/pulse sensor, camera, ammo packs: no cloak). The only other occurrence in the whole install is the same string in `scripts.vol`. The `setCloaked` calls the remake lists in `games/tribes/tribes_presentation.gd` belong to the Tribes 2 scripts. |
| Tribes 2 | yes: the cloaking pack (light armour), plus timed cloaks on spawn | section 2 |
| Tribes: Aerial Assault (PS2) | an inventory slot only | section 4 |
| Tribes: Vengeance | assets only, no playable cloak | section 5 |

## 2. Tribes 2 (scripts in `tribes2/extracted/scripts/scripts/`)

`packs/cloakingpack.cs`, the header comment: "cloaks the user from all visual detection by other players and
cameras. This is a local effect only (someone standing next to the cloaked player will still be visible). Motion
sensors will still detect a (moving) cloaked player. When not activated, the pack creates a localized passive sensor
dampening field. The user will not be visible to any non-motion-detecting sensor. Only light armors may equip it."

- **Who:** light armour only. `player.cs:1310` `max[CloakingPack] = 1` (light); `:1557` and `:1801` `= 0` (medium,
  heavy). `CloakingPackImage::onActivate` refuses other armours ("Cloaking available for light armors only"). Vehicles
  have no cloak pack; `item.cs:289` marks items `cloakable = false`.
- **Energy:** `CloakingPackImage` `usesEnergy = true; minEnergy = 3;` and `stateEnergyDrain[1] = 12` per second while
  the Activate state runs; it falls back to Deactivate with no energy (`stateTransitionOnNoAmmo`). The light armour has
  `maxEnergy = 60`, `rechargeRate = 0.256` per 32 ms tick (8.2/s): a full pack lasts about 16 s with the recharge.
  No fixed duration.
- **Worn, not only on:** `onMount` calls `setPassiveJammed(true)`: the wearer is invisible to every sensor that does
  not detect jammed units (`detectsPassiveJammed`), switched on or not. `PlayerSensor` (soldiers' eyes) and
  `DeployMotionSensorObj` / `SentryMotionSensor` do detect jammed units; pulse sensors and base turret sensors do not.
- **Sensors:** `detectsCloaked = true` only on the deployable motion sensor (`deployables.cs:181`, `detectRadius 60`,
  `detectMinVelocity 2`) and the sentry turret's motion sensor (`turrets/sentryTurret.cs:117`, same numbers). The pulse
  sensor (`deployables.cs:259`), the base turrets, the MPB and the vehicle sensors say `false`. `PlayerSensor` has no
  `detectsCloaked`, so a soldier's own sensor does not see a cloaked enemy.
- **AI:** `ai.cs:618-632` (`AIFindClosestEnemy`) and `aiHunters.cs:397-415`: a client with a cloaking pack in the
  active image state is ignored unless `%distance < 8`. The stock AI defines `LightCloakSet`
  (`aiInventory.cs:1417`, light armour, cloaking pack, plasma, disc, grenade launcher ...) but no objective table
  (`serverTasks.cs`, `aiDefaultTasks.cs`) lists it, and nothing in the AI scripts presses the pack (shield and repair
  packs are switched by `use("Backpack")`; the cloak never): **the original bots never cloak**, they only respect
  a player's cloak.
- **What breaks it:**
  - firing any weapon (`projectiles.cs:61` `ShapeBaseImageData::onFire`, the shock lance `:273`, the Thundersword bomb
    `vehicles/vehicle_bomber.cs:743`): `setCloaked(false)` then `schedule(500, "setCloaked", true)`, **only if
    `getEnergyLevel() > 20`**; at 20 energy or less the shot does not break it. Firing during the respawn cloak
    (below) cancels that cloak for good;
  - damage: `player.cs:2526` `else if (%amount > 0.1)`: uncloak and re-cloak 500 ms later (0.1 = 300 engine points
    at the project's x3000 scale), unless the player stands in a station;
  - a jammer: `Armor::onForceUncloak` ("Cloaking pack off. Jammed.") and `onActivate` ("Jamming field prevents
    cloaking"): `canCloak()` is engine code; the remake blocks the cloak inside any sensor-jammer pack's field
    (inferred from the messages);
  - the pack is switched off with the same key, or on death.
- **Timed cloaks (script `setCloaked` calls):** a respawn cloaks for `$InvincibleTime = 6` s
  (`defaultGame.cs:446`, `player.cs:4`, ended early by firing); the inventory station flashes the buyer cloaked for
  0.5 s / 0.9 s (`station.cs:275,563`); a vehicle leaving its pad is cloaked 4.8 s with the appear sound at 3.7 s
  (`vehicles/serverVehicleHud.cs:140-148`). These use the engine's cloak shader, not data.
- **Visual:** engine code (Torque `setCloaked`), no shader in the data. The only cloak art is the pack's own
  (`pack_upgrade_cloaking.dts`, `skins/cloak_core*.png` + `cloak_core.ifl` 20-frame core glow, `lite_pack_cloak.ifl`).
  The remake draws a screen-refraction shimmer (section 8).
- **Sounds:** `CloakingPackActivateSound` = `fx/packs/cloak_on.wav`, `description = CloseLooping3d`, played from the
  Activate state (a loop while the pack is on). There is no off sound.

## 3. Tribes 1

None (section 1). Tribes 1 sensors carry no cloak rules; `TribesSensorNet` keeps its Tribes 1 jammer-only rules.

## 4. Tribes: Aerial Assault (PS2 disc `TribesAerialAssault.iso`, `TRIBES/FILES.DAT`)

The character define files (`LightDefaultDefines.hpp`, `MediumDefaultDefines.hpp`, `HeavyDefaultDefines.hpp`, and the
female / bioderm variants) hold `INVENT_MAX[INVENT_TYPE_ARMOR_PACK_CLOAKING]`: **1 for light armour, 0 for medium and
heavy** (three light, three medium, three heavy sets), next to the ammo, energy, repair, sensor jammer and shield
packs (`DEFINE_ATTRIBUTE_ARRAY_S32_ENTRY(...)`), and `LABEL(SHAPE_TYPE_ARMOR_PACK_CLOAKING, "Armor Pack - Cloaking")`.
There is no other cloak string on the disc (the behaviour is in the MIPS executable, not in data): the same rule as
Tribes 2, light armour only. The remake's Aerial Assault soldier is a Tribes 2 medium armour, so nothing more is
wired; the T2 profile applies to any light-armour pack soldier.

## 5. Tribes: Vengeance (installed to `tvs/game/app/Tribes Vengeance/Content`)

The packs are energy, shield, repair and speed (`System/EquipmentClasses.int`: `PackEnergy`, `PackShield`,
`PackRepair`, `PackSpeed`). Left over in the data: `Art/Packs.pkg` has `CloakPack` and `CloakPackdropped` meshes,
`Sounds/TV_packs.pkg` has `cloakpack_loop1`, and `System/SoundEffects.ini` has `[CloakPack_Active]`
(`Volume=75`, `OuterRadius=1000`). The class packages and the loadout menu have no cloak: **not playable**, so the
remake offers none (the sound is converted as `tv_packs/cloakpack_loop1`).

## 6. Starsiege (`starsiege/extracted/scripts/`)

- **Components** (`datIntMounts.cs:160-180`, `newCloak(id, rating, dmg_amt_glitch, glitch_coef, dmg_amt_fail,
  fail_coef)`):

  | id | name | rating | glitch | glitch coef | fail | fail coef | mount | mass | tech |
  |---|---|---|---|---|---|---|---|---|---|
  | 830 | Chameleon Cloak | 12000 (shown as Mask Rating 1200) | 0.50 | 1.0 | 0.20 | 5 | M | 1.0 t | 4 |
  | 831 | Cuttlefish Cloak | 16000 (1600) | 0.50 | 1.0 | 0.20 | 5 | L | 3.5 t | 5 |

  `Sim.Strings.cs:1394`: "Makes vehicle very hard to detect visually or with sensors" (mask rating shown).
  The glitch / fail fields are read as health fractions (glitch below 50 %, dead below 20 %, a lower threshold being
  the failure); the coefficients' exact meaning is engine code, the remake uses glitch_coef as a flicker rate and
  does not use fail_coef.
- **Who:** every vehicle with a `Cloak` entry in its `newMountPoint` allowed list: 33 vehicle scripts (most Hercs and
  tanks, the Cybrid / Knight / Tribes flyers `cy_advo`, `kn_bans`, `tr_bans`). Default fits: Chameleon on `cin_apoc`,
  `ha_apoc`, `mg_seek`, `rb_eman`, `cy_artl`, `cy_bolo`, `cy_recl`, `pi_drea`, `rb_artl`, `rb_bike`, `rb_drea`,
  `tr_nike`; Cuttlefish on `ha_pred`, `ss_bus`, `tr_supr`. Missions list a unit's mountables (`HA5` has 830 in a unit's
  list). The campaigns hand out stock with `InventoryComponentSet` (`hu_planet_init.cs`, `cy_planet_init.cs`: 1 to 4
  of each per planet; the first cloaks arrive on Mars / Mercury).
- **Energy and duration:** no field in the data. Starsiege has no per-second cloak drain in any script; the cloak is a
  toggle (`actionTable.cs:100,269` `IDACTION_CAMOUFLAGE`, "Cloak on/off", Ctrl+X or key 7 per
  `Mission.Strings.cs` `IDSTR_TR4_HNTR08/12/47`, "Some components are always on, while others require you to activate
  them").
- **Sensors:** `datSensor.cs` `sensorMode(a|p, base, range, shutdown, squat, stop, slow, fast, activ, camo, jam,
  shld, tjam)`: a target's detection chance is the base plus the modifiers that apply; **`camo` applies to a
  cloaked target**: -2.0 against 12 of the 18 sensors' active mode and -0.6 for the passive mode of 11 (e.g. the
  Standard Sensor: active base 0.6, passive 0.35), so a stopped cloaked unit is invisible to a standard active
  sensor. The counter-sensors: Infiltrator and Cybrid Enhanced Passive (active camo -1.0), Bloodhound and Cybrid
  Enhanced Tracker (-1.5), **Emission Scanning and Cybrid Motion (-0.5)**, matching `Mission.Strings.cs`
  `IDSTR_HB1_LONGBRIEF`: "the Knights compensated for our cloaks".
- **Turrets and targeting:** turrets use the same sensor tables; no turret record has its own cloak field.
- **AI:** `order(<group>, cloak, true|false)` is used by 7 missions: HA2 (Harabec slows and cloaks to let an Imperial
  patrol pass, then uncloaks), HA5 (`surprise()` cloaks two Imperial Hercs), CA0 (an attack group cloaks then holds
  fire), CD4 (an ambush group), CE3 (`startAmbush`), HC2 (the Recluse trap). Training 4 (`IDSTR_TR4_HNTR08-12`): when
  the player cloaks, his squadmates "also cloak" while following and stop their radio chatter.
- **What breaks it:** nothing in the data; a cloak order on a vehicle without the component does nothing.
- **Sounds:** the action plays `bc_mfd.wav` 2D (`sound.cs:94` `IDSFX_CAMOUFLAGE`); the voice lines `IDCV_CLOAK_ON/OFF`,
  `IDCV_DAM_CLOAK`, `IDCV_DES_CLOAK` are commented out.
- **Visual:** engine code. The cloak is a shimmer in the cockpit's external view, invisible at range.

## 7. Earthsiege 1, Battledrome, Earthsiege 2

No cloak. Their `ECM` is a missile jammer (`RadarMode`, `Projectile` ECM): it is not a stealth device.

## 8. What the remake does

One mechanic, per-game data:

| Piece | Where | Rule |
|---|---|---|
| `CloakProfile` | `engine/stealth/cloak_profile.gd` | `gameplay/cloak.json` per pack: energy/s, minimum energy, recloak delay and energy gate, breaks (fire, damage over a threshold), reveal range, jams-sensors-when-worn, jam-field block, timed cloaks, sensor modes, glitch/fail health, AI use, sounds. Fade times are the remake's (0.8 s in, 0.5 s out) because the originals' are engine code. |
| `CloakState` | `engine/stealth/cloak_state.gd` | `Herc.cloak` (every vehicle and soldier): `apply_wanted` / `apply_follow` / `apply_forced`, `apply_fired`, `apply_damaged`, drain, glitch, fade; a puppet follows the host's flag. |
| `CloakRules` | `engine/stealth/cloak_rules.gd` | eyes: hidden beyond `reveal_range_m` (Tribes 2: 8 m); sensors: also hidden unless `detects_cloaked` and moving at `min_velocity` (Tribes 2 motion sensors, exported in `base_equipment.json`); radar without a sensor net (Starsiege): a per-sweep roll against base + camo + speed class + `activ` of the looking Herc's own sensor; allies always see each other. |
| `CloakVisual` + `cloak.gdshader` | `engine/stealth/cloak_visual.gd`, `engine/shaders/cloak.gdshader` | a per-unit shader override on the body and the held weapon: the scene behind it, bent by the surface normal and shimmering, plain again within the reveal range of the camera. Under `render_unified` or not (the override replaces the shape's material). No ally outline: no original shows one (`outline_strength` is 0 and a game's data may turn it on). |
| Radar, command map, T-targeting | `RadarContacts.is_shown` (`is_cloak_hidden`), `Targeting` through `is_on_scope` | a hostile cloaked unit is not on the scope; a call-in radar sweep still shows it. |
| Tribes sensor net | `TribesSensorNet` | the worn pack jams; `_senses` / `_soldier_sees` ask `CloakRules.is_hidden_from_sensor`. |
| Turrets | `TurretTargeting.find_nearest` (`sensor` in the spec); `TribesTurret`, `SSTurret` | a cloaked unit is skipped unless the turret's sensor is a motion sensor. |
| Bots | `InfantryBot._find_target` (eyes), `AIPilot` / `FlyerAI` (radar rules) | Tribes 2 bots never switch the pack on (the original AI does not either). Starsiege pilots obey `order(cloak)` and copy their leader's cloak wish (training 4). |
| Soldiers | `InfantryPack` (`effect: cloak`), `tribes2:CLOAKING_PACK` offered to light armour | `pack_use` switches it. |
| Vehicles | `Herc.cloak_input`; `cloak_toggle` action (Ctrl+X) in `PlayerPilot`; `SSUnitDirector._order_cloak`, mission mountables installed on spawn | host authoritative: the wish rides in the controls (`BattleNetSync.make_controls`) and in `InputFrame` flag 8. |
| Network | `SnapshotCodec.IDX_CLOAKED` (bit 1 of the status byte), `HercSnapshots.SNAP_CLOAK` | observers draw and hide the unit from the host's flag. |

Assumptions (flagged, not in the data): fade times and the shimmer's look; speed classes of Starsiege's sensor modes
(stop below 5 % of top speed, slow below 50 %); health glitch / fail read from the unit's integrity; the jam-field block
applies to any sensor jammer field; Starsiege cloaks cost no energy and nothing breaks them. Done for Tribes 2 soldiers: the script cloaks (`tribes2:timed_cloak`): a respawn cloaks the soldier for
`$InvincibleTime` (6 s, a shot ends it) with no pack, and a mission script's `setCloaked(on)` / `isCloaked()` are real
(`Tribes2Methods`, no longer ignored presentation calls). Not done: the vehicle-pad (4.8 s) and inventory-station
(0.5 / 0.9 s) flashes are in the profile (`vehicle_pad_cloak_s`) but not started by the station code; Starsiege
components cannot be bought in the garage (components are not modelled there); the Aerial Assault and Vengeance
soldiers have no pack kit. Tests: `tests/cloak_check.tscn` (headless), `tests/cloak_shots.tscn` (windowed renders:
`cloak_soldier_plain / cloaked / close`, `cloak_herc_plain / cloaked`).
