# Tribes and Tribes 2 infantry: armours, hand weapons, stations, starting on foot

User (2026-10-09): "there should be states for the non-tribes vehicles to know if a pilot is in it or not, any
light armor infantry should be able to pilot those vehicles if not occupied. Assume when you start you are in
light armor. There should be a button to exit and enter (when empty) any herc, flier, or tank that isn't from
tribes. Tribes and Tribes II vehicles should work as normal."

Boarding rules and vehicle occupancy: tribes_vehicles.md section 6. Tests: `game/tests/infantry_check.tscn` and
`game/tests/infantry2_check.tscn` (seats, gunners, passengers, falling, gear, damage types, bots; headless;
`-- --shots=<dir>` with a window writes `infantry_*.png` / `infantry2_*.png`); LAN: `tests/e2e_driver.tscn` flows
`lan_host` / `lan_join` (co-op starts on foot; the client boards, drives and leaves his Herc; with `--bots=4` on the
host also bots, a grenade and a client gunner seat over the LAN).

## 1. Data (`tools/export_tribes_infantry.py tribes|tribes2`, importer step `infantry`)

Writes:

- `gamedata/<pack>/gameplay/armors.json`: the three armours (`"engine_schema": 1`), read by `InfantryCatalog`.
  Armours are not in the vehicle catalog: no picker, hangar or campaign ever offers them.
- `gamedata/<pack>/gameplay/weapons_infantry.json`: hand weapons, weapon schema, `"category": "infantry"`, loaded by
  `PackWeaponLoader` next to `weapons_engine.json`. A re-run keeps each weapon's `fx` block (written by
  `tools/fx_tribes*.py`).
- `gamedata/<pack>/gameplay/infantry_gear.json` and `vehicle_seats.json` (`tools/export_tribes_gear.py`, called by
  the same exporter): hand items, packs, throw rules (section 6) and vehicle seat roles (tribes_vehicles.md
  section 6).
- Sounds under `audio/sfx/sim/`: fire, jet, the left / right footsteps on soft ground and on hard floors (T1
  ArmorData.cs l/rFootSounds [0] / [1], T2 L/RFootSoftSound, L/RFootHardSound) with their sound profiles'
  distances (`footstep_range`, `footstep_hard_range`: T1 nsound.cs Profile3dFoot 2-30 m, T2 serverAudio.cs
  AudioClosest3d 5-30 m and AudioClose3d 10-60 m), mount and dismount.
- Each armour's `bodies` [{shape, label, bioderm}]: its own body first, then the female and (Tribes 2) Bioderm bodies
  of the same size (they share the armour's values). Each hand weapon's `model.animation`: the weapon image's
  sequences by role (section 2, weapon images).
- Shapes: armours and weapon models through `export_tribes.py` / `export_tribes2.py` (Tribes 2 armours with their
  `.dsq` animations, tribes2.md section 2; Darkstar frame triggers and Torque sequence triggers as `triggers`).
- `gameplay/items.json` and `maps/<id>/items.json` (`tools/export_tribes_items.py`, importer step `items` after
  `maps`): the item datablocks (model, pickup name, class, pickup radius, amount) and the items each mission
  places (section 8).

Units are metres and seconds (tribes.md section 4). Damage uses the vehicles' factor, one Tribes unit = 3000
Earthsiege points.

### Armour fields

| field | Tribes 1 (`scripts/ArmorData.cs` PlayerData) | Tribes 2 (`scripts/player.cs` PlayerData) |
|---|---|---|
| `max_forward/backward/side_speed` | maxForwardSpeed / maxBackwardSpeed / maxSideSpeed | same |
| `ground_accel` | groundForce / mass (`40 * 9.0` / 9 = 40) | runForce / mass |
| `jump_speed` | jumpImpulse / mass (75 / 9 = 8.33) | jumpForce / mass |
| `jet_accel` | jetForce / mass (236 / 9 = 26.2) | jetForce / mass |
| `jet_energy_per_s` | jetEnergyDrain x 31.25 ticks/s | same |
| `jet_side_factor`, `max_jet_forward_speed` | maxJetSideForceFactor, maxJetForwardVelocity | maxJetHorizontalPercentage, maxJetForwardSpeed |
| `max_energy`, `energy_recharge_per_s` | maxEnergy; 8 / s (Player::onAdd setRechargeRate 8) | maxEnergy; rechargeRate x 31.25 |
| `hp` | maxDamage x 3000 | same |
| `max_weapons`, `weapons`, `ammo` | $MaxWeapons, $ItemMax > 0, $ItemMax[ammo item] | maxWeapons, max[] |
| `default_loadout` | $spawnBuyList (game.cs): blaster, chaingun, disc launcher | DefaultGame::equip: blaster, disc, chaingun |
| `damage_scale` | $DamageScale[armour, type], applied per hit | the armour's damage profile `damageScale[$DamageType::X]` (damageTypes.cs), applied per hit |
| `fall_min_speed`, `fall_damage_per_mps`, `fall_damage_type` | minDamageSpeed, damageScale x 3000, "landing" | minImpactSpeed, speedDamageScale x 3000, "ground" |
| `hand_items`, `default_items`, `packs`, `max_grenade_types` | $ItemMax of Grenade, MineAmmo, RepairKit, Beacon, the packs; $spawnBuyList | max[] of the same; DefaultGame::equip; maxGrenades |
| `shield_energy_per_damage` | (the pack's shieldStrength) | energyPerDamagePoint / 3000 |
| `height_m`, `eye_height_m` | shape root pose; `dummy eye` node | shape; `Eye` node |
| `capsule_radius` | T2 boundingBox / 2 by size (T1 PlayerData has none) | boundingBox / 2 |
| `can_pilot` | light only (Vehicle::onCollision) | light and medium |

| armour | speed m/s | jump m/s | jet m/s^2 | energy | hp | weapons |
|---|---|---|---|---|---|---|
| T1 light | 11 | 8.3 | 26.2 | 60 | 1980 | 3 |
| T2 light (Scout) | 14 | 8.3 | 26.2 | 60 | 1980 | 3 |

Example rows; the exporter writes every armour to `gamedata/<pack>/gameplay/armors.json`.

The female armours (lfemale, mfemale, T2 female and bioderm) share the male values, except a few ammo and
damage-scale entries. They aren't exported.

### Hand weapons (`category: "infantry"`)

Tribes 1: `item.cs` ItemImageData plus the `baseProjData.cs` projectile.

- Refire is fireTime + reloadTime.
- Energy: minEnergy is needed to fire, maxEnergy is spent per shot.
- BulletData and RocketData keep their speed and lifetime. The disc is flown at its mean speed so the range matches.
- GrenadeData has no muzzle velocity. The launch speed is sqrt(maxLevelFlightDist x g), and the shell bursts on
  impact. Bounces and the fuse aren't modelled.
- LaserData damage is damageConversion x the energy spent (60 at most).
- Lightning (ELF) is a beam in 0.2 s pulses that drains the target's energy.

Tribes 2: `weapons/*.cs` image state machines (refire = Fire back to Ready, as for the vehicle weapons) and their
projectile datablocks.

- The missile homes (SeekerProjectile) and flies at maxVelocity.
- The laser rifle range is maxRifleRange 1000 m.
- The shocklance reach (14 m) is a guess.
- The ELF range is beamRange.

Targeting laser and repair gun aren't hand weapons here (the repair pack repairs its wearer, section 6). The T1
laser rifle's Energy Pack requirement is dropped.

Every hand weapon carries its damage type (`damage.type`, the armours' scale key: T1 `$BulletDamageType` -> `bullet`,
T2 `$DamageType::Disc` -> `disc`; the T2 shocklance has only a radiusDamageType, which is used).

Families never mix (weapon_schema.md):

- `Infantry.equip` takes only `infantry` weapons the armour allows.
- `Herc.equip` refuses them.
- `Packs.weapons_for_mask(..., "herc")` never returns them.

## 2. The soldier (`engine/infantry/`)

| code | role |
|---|---|
| `infantry_catalog.gd` | `InfantryCatalog`: armours by id (`tribes:LIGHT`), the default pack; the match screens' choices: `make_infantry_packs()`, `make_armors(pack)`, `make_bodies(armor_id)` (incl. Bioderm), `make_skins(body_id)` (SkinCatalog) |
| `infantry.gd` | `Infantry` (extends Herc: a combat unit the whole battle already handles: damage, kills, snapshots, respawn) |
| `infantry_weapon.gd` | `InfantryWeapon`: ammo per armour, energy per shot |
| `infantry_held_weapon.gd` | `InfantryHeldWeapon`: the weapon model on the hand node (third person) and at the eye (first person, the local player only), animated by `InfantryWeaponAnimation` (weapon images, below) |
| `infantry_pilot.gd` | `InfantryPilot`: actions to controls |
| `infantry_animation.gd` | the armour sequences by movement state (both games), the foot triggers, the deaths |
| `infantry_weapon_animation.gd` | `InfantryWeaponAnimation`: the weapon image's sequences (draw, fire, reload, ambient, spin) on both models |
| `infantry_interaction.gd` | `InfantryInteraction`: the one `interact` action (the nearest offer of items, loot, switches, stations, hatches) |
| `infantry_sounds.gd` | footsteps on the foot triggers, the jet loop |
| `infantry_hud.gd` | energy, health, weapon / ammo, the boarding hint |
| `station_menu.gd` | the inventory and vehicle station menus (shared widgets) |
| `infantry_motion.gd` | running, ground speed limits, the jetpack |
| `damage_types.gd` | the damage type of the hit being applied, the armour scale |
| `infantry_gear.gd`, `infantry_kit.gd`, `infantry_pack.gd` | gear catalog (and seat data), what a soldier carries, what the pack does |
| `thrown_item.gd`, `infantry_gear_director.gd` | grenades and mines in flight; throws, packs and repair kits (host-authoritative) |
| `infantry_bots.gd`, `infantry_bot.gd` | the match's AI soldiers and their brain (section 7) |
| `engine/occupancy/vehicle_seats.gd`, `infantry_seat.gd`, `turret_crew.gd`, `gunner_pilot.gd`, `vehicle_exit.gd` | seat roles, a rider's seat and arc, the gunner seat, its controls, where riders get out |

### Movement (Tribes gravity 20 m/s^2)

- **Ground.** On the ground the horizontal velocity approaches the wanted one at `ground_accel`. Forward, backward
  and side limits combine elliptically.
- **Jump and ski.** `ascend` jumps (`jump_speed`). Held, it also skips ground friction, so jumping down slopes keeps
  the speed (skiing).
- **Jet.** `jet` thrusts at `jet_accel` while energy is above `min_jet_energy`. With movement input up to
  `jet_side_factor` of it goes horizontal, none beyond `max_jet_forward_speed`, and the rest goes up as
  sqrt(1 - side^2). Remake approximation: the Darkstar / Torque player physics are engine code.
- **Energy.** Energy recharges at `energy_recharge_per_s`. The jet and energy weapons spend it.
- **Damage.** A worn, switched-on shield pack takes the hit out of the energy first (section 6). The rest is scaled by
  the armour's damage scale of the hit's type (T1 Player::onDamage `$DamageScale[%armor, %type]`, T2
  Armor::damageObject `damageScale[%damageType]`) and comes off health; the soldier dies at 0. Shooters name the type
  through `DamageTypes.apply_typed_hit` (projectiles, beams, grenade bursts, falls). Untyped hits (Earthsiege and
  Starsiege weapons, and the Tribes vehicle weapons, whose type the vehicle exporter doesn't record) are not scaled.
- **Falling.** Hitting the ground or a wall faster than `fall_min_speed` (along the surface normal) does
  speed x `fall_damage_per_mps` of the fall type (T2 Armor::onImpact: vecLen x speedDamageScale above
  minImpactSpeed). Tribes 1 counts only the speed above minDamageSpeed: (speed - minDamageSpeed) x damageScale
  (tribes.exe 0x4162d2; armour field `fall_damage_above_min`). From rest a light armour is hurt from a 15.6 m (T1) /
  50.6 m (T2) drop. A blast's kickBackStrength / armour mass pushes soldiers (T2 grenades).
- **View.** First person at `eye_height_m` (`view_toggle`: chase). The weapon in hand is drawn at the eye
  (view model) and fires from there.

### Animation, footsteps and deaths (`InfantryAnimation`, `InfantrySounds`)

- **Sequences.** Tribes 1 plays the PlayerData animData names (`root`, `run`, `runback`, `side left` backwards for a
  step right, `jet`, `fall`, `landing`, the `die ...` sequences); Tribes 2 the TSShapeConstructor names of its `.dsq`
  files (`root`, `run`, `back`, `side`, `jet`, `fall`, `land`, `death1`..`death11`). A landing plays `land` once.
- **Speed.** A move cycle plays at the soldier's speed over the speed it was authored for (its ground travel per cycle
  over its duration: T2 ground frames, T1 the `bounds` node), at most 1.5 times as fast (Torque PlayerData
  `maxTimeScale` default; Tribes 2 sets none; Tribes 1 assumed the same). A light Tribes 2 armour at 14 m/s: run
  cycle 4.02 m in 0.767 s, played 1.5 x.
- **Footsteps.** One per foot trigger the cycle crosses (T1 frame triggers 1 / 2, T2 sequence triggers 1 / 2: the
  originals' Player plays the left / right foot sound there): about 3.9 a second at full run (the remake's old rule,
  one per 1.6 m, gave 8.75). Soft sounds on terrain, hard ones on anything else, at the profile's full volume within
  its minimum distance and inverse-distance quieter to its maximum (`Sfx.play_at_range`).
- **Death.** A dead soldier plays one of his body's death sequences, held on its last frame; every peer picks the same
  one (net id + death count). The originals choose by where the killing hit struck; the remake doesn't track hit
  locations on soldiers.

### Weapon images (`InfantryHeldWeapon`, `InfantryWeaponAnimation`)

Both weapon models (the world model on the hand, the first-person view model) play the weapon image's sequences at
their authored speed (Tribes 2 never sets stateScaleAnimation; Darkstar has no scaling), by role
(`model.animation` of the weapon record):

| role | Tribes 1 (Darkstar ItemImageData) | Tribes 2 (ShapeBaseImageData state machine) |
|---|---|---|
| activate | `activation` when drawn; the shape then rests at its last key | the Activate state's stateSequence (the disc's "Activated" is not in its shape: no draw, as in the original) |
| ready | the disc spins while ready (weaponType 3) | the Ready state's (the disc's `DiscSpin` loop) |
| fire / reload | `fire` per shot, then `reload` | the Fire state's (mortar `Recoil`), then the Reload state's |
| no_ammo | - | the NoAmmo state's, held while empty |
| ambient | `ambient` loops | the image's `ambient` loops |
| spin | the chaingun's `spin` while firing (spinUpTime / spinDownTime) | `spin` by stateSpinThread (Spinup 0.5 s, Spindown 1 s timeouts) |

A shot is seen as the weapon's refire timer restarting.

### Controls

See CODING_STANDARDS.md section 2 (binding context `infantry`).

| action | does |
|---|---|
| W / S | run forward / back |
| A / D | strafe |
| mouse | look |
| Space | jump |
| mouse right | jet |
| mouse left | fire |
| Q (pad Y) | next weapon |
| E (pad X) | `interact`: the nearest thing in reach (an item, a loot cache, a switch, a station, a vehicle's hatch) |
| pad B | `vehicle_enter_exit` (board by the hatch; inside: get out) |
| Space in a Tribes vehicle | get out (the originals' jump trigger) |
| F | `seat_next` (in a vehicle) |
| G (hold, release) | `grenade_throw` |
| B (hold, release) | `mine_drop` |
| R, P | `pack_use`: switch a toggled pack (shield, repair, jammer, cloak) or place a deploy pack; with nothing to switch, a mode's reload (`InfantryGearDirector.reload_hook`: the extraction mode loads carried ammo at once). R is Tribes 2's useBackpack (controlDefaults.cs), P Tribes 1's `use("BackPack")` (config.cs) |
| H | `repair_kit_use` (Tribes 1's `use("Repair Kit")`; Tribes 2's own Q is the next weapon here, so it stays `weapon_next`) |

The other originals' keys that do not clash are kept: G grenade (both), B mine (Tribes 2; Tribes 1 uses M, which is the missile camera here), beacons are not modelled. Every press is answered: a line over the health bar
(green for what happened, amber for a refusal: "Shield Pack ON", "No Repair Kit left", "Health is full - Repair Kit
kept", "Shield Pack: not enough energy", "No backpack worn ..."), a sound (the pack's own: shield_on, repair, jammer_on,
cloak_on ...; the originals' failpack / misc.error for a refusal; health_patch / Pku_hlth for a kit, written to
`infantry_gear.json` "sounds" and each pack's `use_sound` by tools/export_tribes_gear.py), a green wash for a kit, and the
HUD kit line shows each item with its key and count ("[G] Grenade 5  [H] Repair Kit 1  [R] Shield Pack ON").
The line is `InfantryGearDirector.notice_text`, told to the pressing player only (`report`).

## 3. Starting on foot: mode defaults (decided while the user was away; please review)

| mode | start | respawn |
|---|---|---|
| Skirmish, co-op, versus, arena and every map from the front end (`MatchFlow` sets `config.start = "on_foot"`) | On foot in **light armour**, beside the Herc / vehicle chosen in the lobby. The vehicle stands **parked and empty** on the player's spawn (jets parked on the ground). | Soldiers always respawn in light armour with the spawn loadout. In frag modes BattleRules respawns them like vehicles; otherwise BattleInfantry does it after 6 s. |
| Missions (ES1 / ES2 / Starsiege campaigns, LAN campaign) | **Inside** the mission / garage Herc, as in the originals; the player's peer is its pilot. | `vehicle_enter_exit` works. The first exit creates the light-armour soldier beside the hatch. A soldier killed in a mission doesn't respawn: the mission decides. |
| Command-line / test config (`BattleSetup.make_default_config`) | Inside the vehicle (`--start=on_foot` to test). Keeps the existing tests and tools valid. | |
| No infantry pack installed (or both switched off in the library) | Inside the vehicle, every mode. Pilots cannot get out: there is no soldier to be (`OccupancyDirector.can_leave_vehicle`); the exit hint is not shown. | |

Other defaults:

- **Armour pack.** The map's pack when it is Tribes or Tribes 2, otherwise Tribes 1 (the first installed and
  enabled; with only one of the two, that one). `config.infantry_pack` overrides it.
- **The player's choice.** The roster entry's `infantry_armor`, `infantry_body` and `infantry_skin` (the match
  screens offer `InfantryCatalog.make_armors / make_bodies / make_skins`) become the soldier spec's `armor`,
  `body_shape` and `skin`; he spawns and respawns in that armour (else light), and a station's new armour keeps the
  kind of body (female, Bioderm). The roster's loadout slot also gives the kit (`SpawnLoadout.make_kit`: the slot's
  backpack, grenade type and hand-item counts up to the armour's limits, `InfantryKit.apply_slot`), on the spawn and
  again on every respawn in that armour; before this a backpack chosen in the loadout never reached the battle and R
  had nothing to switch.
- **AI.** AI pilots stay in their vehicles. AI soldiers are the match's infantry bots (section 7).
- **Co-op end.** A squad counts as destroyed when its vehicles are destroyed. Soldiers respawn, so they don't
  keep a lost match going.
- **Kill credit.** Kills scored by a piloted vehicle count for its pilot's soldier (frag limit included).

## 4. Stations (`games/tribes/tribes_stations.gd`, maps' `stations[]`)

A soldier uses a station of his own team, a neutral one, or any station in a free-for-all. He uses it by standing
on it (within 2.5 m), as Station::onCollision activates it. Everything is free: there is no team energy yet.

- **Inventory.** Opens the menu: armour, one weapon row per `max_weapons`, the grenade type and the backpack. Only
  weapons, grenades and packs the armour allows are kept; only packs whose effect the remake models are offered. The
  new kit comes full (health, energy, ammo, hand items; one grenade type, as T2 maxGrenades 1).
- **Ammo.** Every 0.5 s adds AmmoStation::onResupply amounts: bullets 20, plasma 5, grenades, discs and mortar
  shells 2, anything else 1; hand items (grenades, mines, repair kits) 1 each.
- **Vehicle.** Opens the menu with the station's game's vehicles. The chosen one appears empty on the nearest clear
  vehicle pad (within 80 m). The pad must have no vehicle within 8 m, as serverCmdBuyVehicle requires. $VehicleMax
  limits aren't applied.

The host decides purchases.

## 5. LAN

The host simulates everything.

- **Client to host.** Each client sends its controls: BattleNetSync `make_controls` adds
  `"infantry": [jet, jump, weapon slot]`. A gunner's controls (his vehicle's torso, pitch and trigger bits) go to the
  vehicle's TurretCrew (`OccupancyDirector.apply_crew_controls`); a passenger's to his own soldier.
- **Snapshots.** Snapshots append, after the damage block (index 15, `Infantry.SNAP_INFANTRY`):
  `[jetting, weapon slot, stowed, rounds per weapon, kit]` (kit: `[grenade id, pack id, pack on, counts]`).
- **Gear.** Throws, pack switches and repair kits are reliable requests to the host (`InfantryGearDirector`, child
  "Gear" of the Battle). A thrown item appears on every peer (`_spawn_item`); the clients' copies fly by themselves
  and vanish on the host's burst message (`_show_burst`), which also plays the explosion.
- **Bots.** Bot soldiers are ordinary soldiers in the snapshots; their seats travel in the occupancy messages.
- **Occupancy.** Changes travel as one reliable `OccupancyDirector._apply_state` message: seats, the soldier's
  place and visibility, and ownership (`owner_peer` routes input to the vehicle while its pilot drives).
- **Requests.** Boarding requests and station purchases are reliable RPCs to the host.
- **Own soldier.** A client's own soldier turns with the mouse at once. Its position follows the host.

## 6. Gear: grenades, mines, repair kits, backpacks (`InfantryGear`, `InfantryKit`, `InfantryPack`, `ThrownItem`)

`tools/export_tribes_gear.py` reads, per game:

| item | Tribes 1 | Tribes 2 |
|---|---|---|
| grenade | Mine.cs MineData Handgrenade (damageValue, explosionRadius, $ShrapnelDamageType, mass, elasticity, friction); fuse: Handgrenade::onAdd schedules Mine::Detonate; throw: item.cs Grenade::onUse `GameBase::throw(.., 9 x throwStrength)` | weapons/grenade.cs GrenadeThrown (indirectDamage, damageRadius, radiusDamageType, mass, elasticity, friction, kickBackStrength); fuse: weapTurretCode.cs GrenadeThrown::onThrow schedule |
| other grenades | - | Concussion (no damage, kickBackStrength 3500), Flash (damage; the white-out isn't modelled); Flare and Camera grenades recorded, not thrown |
| mine | AntipersonelMine (triggerRadius, damageValue); armed at rest (deployCheck every 3 s); thrown by MineAmmo::onUse | MineDeployed (proximity, armTime, indirectDamage) |
| repair kit | RepairKit::onUse repairDamage 0.2 (at once) | RepairKit::onUse applyRepair 0.2 (only when hurt; the remake uses that rule for both): the reserve heals at the armour's repairRate 0.0033 per 32 ms tick, 1.94 s for 0.2 (`repair_s`; `InfantryKit.apply_heal`) |
| beacon | recorded, not used (no targeting system to feed) | same |
| throw strength | throwRelease: the key held up to 1 s gives 0.3 + 0.7 x hold (remoteThrowItem); 0.5 s between throws | startThrowCount / endThrowCount: hold / 300 ms within 0.5 .. 1.5, / 2; impulse = eye x strength x 20 + up x 4 x (1 - abs(eye.z)) + velocity x 0.4, over the item's mass; 0.8 s between throws |

Thrown items fly under Tribes gravity, bounce (normal speed x elasticity, the speed along the surface reduced by
friction x 0.3 per bounce; the Torque item physics are engine code) and rest when slower than 2 m/s on a floor. The
burst does the item's damage of its type, falling off linearly to the radius, to every vehicle and soldier, and
pushes soldiers. A T1 grenade's launch speed is the throw value over its mass, plus the thrower's velocity (assumed).
A mine bursts when anyone (any team, as in the originals) comes within its proximity. Items without an exported
shape (mines, T2 grenades) are drawn as a small dark ball. The burst plays the item's own explosion, `burst_fx` of
`infantry_gear.json` (written by the weapon_fx step, tools/fx_deaths.py): T1 the MineData explosionId (grenadeExp,
mineExp), T2 the thrown ItemData `explosion` (HandGrenadeExplosion, ConcussionGrenadeExplosion,
FlashGrenadeExplosion, MineExplosion).

**Death.** A killed soldier plays only his death animation in both games (weapon_fx.md section 9): T1
Player::onDamage blows a soldier apart on explosive damage with spillover > 0.5 (Player::blowUp, playerDebris
pieces that name no explosion; the remake keeps the corpse), and the T2 blowup() calls in Armor::damageObject are
commented out.

| pack | effect | evidence |
|---|---|---|
| Energy | more recharge: T1 +3 /s (EnergyPackImage maxEnergy -3), T2 + rechargeRateBoost x 31.25 | item.cs, packs/energypack.cs |
| Repair | `pack_use` on: repairs its wearer (T1 RepairBolt::onAcquire repairRate 0.05 /s; T2 repairFactorPlayer per tick), spending the repair gun's energy | item.cs, baseProjData.cs, packs/repairpack.cs |
| Shield | `pack_use` on: energy absorbs hits (T1 shieldStrength 0.012, shrapnel and mortar x0.75; T2 energyPerDamagePoint), spends 9 /s | player.cs Player::onDamage, staticShape.cs checkShields |
| Sensor jammer | `pack_use` on: bots don't see the wearer beyond the jam radius (T1 sensor suppression 20, T2 jamRadius 30); homing missiles turn off by the Earthsiege 2 ECM pod's angle (a stand-in) | item.cs, packs/sensorjammerpack.cs |
| Ammo | extra rounds per weapon and hand item ($AmmoPackMax, AmmoPack max[]) | item.cs, packs/ammopack.cs |
| Cloak (T2, light armour only) | `pack_use` on: cloaked, 12 energy/s, a shot (above 20 energy) or a hit over 0.1 breaks it for 0.5 s; enemies lose him on radar, T-targeting, turrets and bot search unless within 8 m or a motion sensor sees him moving; wearing it jams sensors | packs/cloakingpack.cs, projectiles.cs, player.cs, ai.cs; docs/formats/cloaking.md |
| not modelled | deployables (inventory / ammo stations, sensors, cameras, turrets, turret barrels), the satchel charge | recorded with `"mapped": false` |

A toggled pack switches off when the energy falls below its minEnergy. The repair pack also mends the nearest hurt
teammate, allied vehicle or damaged structure in its beam's reach before it heals its wearer (`RepairDirector`,
`engine/repair/`; the remake takes the nearest, not the aimed one); the T2 "large pack" seat rule (hasLargePack: no deployable packs in sitting seats) and dropping or
throwing packs and weapons aren't modelled.

## 7. Infantry bots (`InfantryBots`, `InfantryBot`)

The match setup's "Infantry bots" row (armory / skirmish and the host's LAN game screen; config `infantry_bots`, up
to 16) adds AI soldiers. Their behaviour is the remake's (the T2 bot AI is a task system over the maps' navigation
graphs, which the remake doesn't load):

- **Teams.** Skirmish / co-op: alternately the enemy (team 1) and the player's squad, enemy first. Versus with teams:
  alternately team 0 / 1; free-for-all: a team each. Every third bot wears medium armour, the rest light.
- **On foot.** Head for the nearest enemy; fight at about the weapon's good range, strafing; aim leading the target
  and lobbing shells; pick the weapon with the most damage per second in range with rounds or energy; throw a
  grenade at 12-40 m. Hurt below 40 %: a crude cover spot the enemy can't see. Below 50 % health, or out of
  ammunition: walk onto the nearest usable inventory (refit, heal) or ammo station.
- **Terrain.** In the open straight at the goal, running, skiing and jetting as the Tribes bots did. Where a
  building stands in the way (the line ahead meets an interior or structure, not the terrain) or the goal is under
  a roof, along a walkable path (`InfantryBotRoute` over `BattleNavigation`, engine/navigation: a navigation mesh
  baked asynchronously from the battlefield's static colliders, in 96 m tiles where paths are asked for and round
  the stations as soon as a match has bots, for a soldier 0.6 m wide who gets up 8 m ledges - a jetpack climb, as
  the originals' bots took their graphs' jet edges; Tribes 1 bases open inner rooms only to jet shafts - and
  60-degree slopes). A path that stops shortening the way left for 6 s is given up for 5 s (straight again). Between
  points it still jumps and jets over a knee-high obstacle ahead, up to goals above and when stuck, keeping an energy
  reserve. Why not the originals' data: Tribes 2's AI graphs (.nav / .spn) cover 28 of its 52 missions in an
  undocumented format; Tribes 1 has none (its bots follow mission path markers); the baked mesh fits every map and
  agrees with the physics. Test: `tests/bot_path_check.tscn` (from 70 m outside to a station's side inside the base
  on Katabatic and Raindance).
- **Vehicles.** A light bot with no enemy within 120 m walks to an EMPTY, armed, sound vehicle of its own team within
  150 m whose pilot seat it may take (BoardingRules: the hatch for non-Tribes vehicles, touch for Tribes ones). The
  vehicle then gets the existing AI pilot (AIPilot with the SEARCH order, or the flyer's FlyerAI) until the bot
  leaves; the bot gets out below 30 % integrity. In a gunner seat it aims and fires the turret; in an armed
  passenger seat it fires within the arc; a seat that does nothing (no pilot, or a sitting passenger seat) it leaves.
- **LAN.** Host-authoritative: the brains run on the host; clients see the bots through the usual messages.

A bot may guard a post instead of roaming (`guard_point` / `guard_radius`): the extraction mode's faction squads
(docs/design/extraction.md section 3).

## 8. Items lying in the maps (`games/tribes/tribes_pickups.gd`, `tribes_item_grants.gd`)

`tools/export_tribes_items.py` (importer step `items`) writes the item catalog (`gameplay/items.json`: every ItemData
with a model, its pickup name, class, pickupRadius (T1: 2 m) and the amount one pickup gives (T2 weapons.cs
$AmmoIncrement)) and each map's placed items (`maps/<id>/items.json`, flags left out).

- **Drawn.** `TribesPickups` (child "Pickups" of the Battle, Tribes maps outside missions) draws every item the
  remake models (weapons, ammunition, hand items, the modelled packs, repair patches) with its own model; placed
  Tribes 2 items do not rotate (item.cs), a mission Item with `rotate` spins. A training mission draws its script's
  Items the same way (`TribesItemModels`, hidden while carried).
- **Touch.** A soldier on foot within the pickup radius takes an item when it gives him something (ItemData::
  onCollision -> Player::pickup): a weapon his armour allows into a free slot (in hand), rounds for a weapon he
  carries, hand items up to the armour's limit, a pack when he wears none, a repair patch's health when hurt
  (`TribesItemGrants`, names resolved by `TribesItems` as in the mission runtime).
- **Interact.** The nearest item within reach (+1 m) also swaps: the weapon in hand for the item's weapon when
  every slot is full, the worn pack for the item's pack (remake addition; the originals drop with a separate key).
  In a training mission interact touches the nearest item or switch for the script (TribesContacts).
- **Respawn.** A taken item comes back after 30 s ($ItemRespawnTime of both games). Host-authoritative; peers hear
  which items are gone.
