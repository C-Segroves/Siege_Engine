# Tribes and Tribes 2 vehicles: original fixed weapons

User (2026-10-09): "vehicles from tribes weren't modifiable that I remember, so you'll have to see how their
weapons are defined." Confirmed by the scripts: neither game has a vehicle loadout. Tribes 1 puts one projectile
type in the vehicle's `FlierData`; Tribes 2 mounts weapon images in each vehicle's `onAdd` script. Nothing a
player does changes them. The remake therefore marks every Tribes vehicle `"fixed_loadout": true`.

Exporter: `tools/export_tribes_vehicles.py tribes|tribes2`, importer step `vehicles` in
`tools/siege_games/tribes.py` and `tribes2.py`. It writes:

- `gamedata/<pack>/gameplay/hercs.json`: vehicles, engine schema;
- `gamedata/<pack>/gameplay/weapons_engine.json`: weapons, `"category": "vehicle"`;
- `gamedata/<pack>/audio/sfx/sim/*.wav`: fire sounds.

Test: `game/tests/tribes_vehicle_check.tscn`.

## 1. Tribes 1 (`tribes/extracted/scripts/vehicle.cs`, `baseProjData.cs`, `nsound.cs`)

| vehicle | FlierData | shape | weapon | pilot / seats | catalog |
|---|---|---|---|---|---|
| Scout | `Scout` | `flyer` (6.5 m) | `projectileType = FlierRocket; reloadDelay = 2.0; fireSound = SoundFireFlierRocket` | light armour pilot only, no passengers (`Vehicle::onCollision`) | `tribes:SCOUT`, **armed, selectable** |
| LPC | `LAPC` | `hover_apc_sml` (9.4 m) | none: `fireSound` and `reloadDelay` but no `projectileType` | pilot + 2 passengers (`Vehicle::findEmptySeat`) who fire their own hand weapons | `tribes:LAPC`, unarmed, AI only |
| HPC | `HAPC` | `hover_apc` (12.7 m) | none, as LPC | pilot + 4 passengers | `tribes:HAPC`, unarmed, AI only |

**FlierRocket** (`RocketData`):

| field | value |
|---|---|
| `damageClass` | 1 (radius only) |
| `explosionRadius` | 9.5 |
| `muzzleVelocity` | 65 |

Example fields; the exporter reads the whole datablock (damage, acceleration, terminal velocity, lifetime,
inherited velocity, shape, trail) from the user's `baseProjData.cs` into the catalog weapon.

The rocket is unguided, uses no ammo and no energy, and the pilot fires it. The shape has two muzzle nodes,
`dummy muzzle1` and `dummy muzzle2`. The scripts don't say which one the Darkstar engine uses, so the remake
fires from `muzzle1`.

Other values:

- Hull: `maxDamage` 0.6 / 1.5 / 2.0.
- Shields: none (`Vehicle::onAdd`: `shieldStrength = 0`).
- Flight: the `FlierData` values, flown by `HoverFlightModel` with `flight_preset` = the datablock name
  (flight_model.md §2).

## 2. Tribes 2 (`tribes2/extracted/scripts/scripts/vehicles/*.cs`, `weapTurretCode.cs`, `weapons/chaingun.cs`)

### Shrike (`ScoutFlyer`, `vehicle_air_scout`)

- **Mounting.** `ScoutFlyer::onAdd` mounts `ScoutChaingunImage` and `ScoutChaingunPairImage` on mount point 10,
  offset ±0.73 m (`weapon_energy_vehicle.dts`). It also mounts `ScoutChaingunParam`, which doesn't fire.
- **Who fires.** The pilot. `ScoutFlyer::onTrigger` and `fireNextGun` alternate the two guns every `fireTimeout`,
  so each barrel fires at half the pair's rate.
- **Projectile.** `ScoutChaingunBullet` (TracerProjectile): `directDamage`, muzzle speed and `lifetimeMS`
  (range = speed × lifetime; e.g. 425 m/s).
- **Energy.** `fireEnergy` / `minEnergy` from the vehicle pool (`useMountEnergy`; pool `maxEnergy`, `rechargeRate`
  per tick).
- **Remake.** Weapon `SHRIKE_BLASTER` ×2, fire group 1. Selectable.

### Thundersword (`BomberFlyer`, `vehicle_air_bomber`)

- **Mounting.** `BomberFlyer::onAdd` puts a `BomberTurret` (`turret_belly_base.dts`) on mount point 10. The turret
  carries these images:

  | slot | image | weapon |
  |---|---|---|
  | 2 | `BomberTurretBarrel` | right barrel |
  | 3 | `BomberTurretBarrelPair` | left barrel |
  | 4 | `BomberBombImage` | bomb bay |
  | 5 | `BomberBombPairImage` | bomb bay |
  | 6 | `BomberTargetingImage` | targeting laser |

  `AIAimingTurretBarrel` doesn't fire.
- **Who fires.** The bombardier, seat 1 (`BomberFlyer::playerMounted`), picks the weapon with
  `BomberTurret::onTrigger`. The pilot, seat 0, flies unarmed. The tail gunner, seat 2, is a passenger.
- **Fusion gun.** `BomberFusionBolt` (LinearFlareProjectile): `directDamage`, speed, lifetime. Each barrel's
  state machine runs Fire + Reload state times (shot interval = their sum); the pair barrel starts later.
  `fireEnergy`, `minEnergy`. Turret arc `thetaMin` / `thetaMax` (level to straight down).
- **Bombs.** `BomberBomb` (BombProjectileData): `indirectDamage`, damage radius (e.g. 30 m), `muzzleVelocity`,
  `velInheritFactor` (e.g. 1.0: the bomb keeps the bomber's velocity), `armingDelayMS`. One bomb per Fire + Reload;
  the pair bay starts later. `fireEnergy`. Offsets from the turret's mount 10.
- **Targeting laser.** `BomberTargeter` does no damage: it places a beacon for the bombsight. It isn't exported.
- **Remake.** Weapons `BOMBER_FUSION_GUN` ×2 (fire group 1) and `BOMBER_BOMB` ×2 (fire group 2). Selectable.

### Havoc (`HAPCFlyer`, `vehicle_air_hapc`)

Six mount points, all passengers. `HAPCFlyer::onAdd` mounts no images. Unarmed, so AI only.

### Beowulf (`AssaultVehicle`, `vehicle_grav_tank`)

- **Mounting.** `AssaultVehicle::onAdd` puts an `AssaultPlasmaTurret` (`turret_tank_base.dts`) on mount point 10,
  with `AssaultPlasmaTurretBarrel` on slot 2 and `AssaultMortarTurretBarrel` on slot 4.
- **Who fires.** The turreteer, seat 1, switches between the two (`AssaultPlasmaTurret::onTrigger`). The driver,
  seat 0, is unarmed.
- **Chaingun.** `AssaultChaingunBullet`: damage, speed, lifetime. The Fire state loops while the trigger is
  held. `projectileSpread`, `fireEnergy`.
- **Mortar.** `AssaultMortar` (GrenadeProjectile): `indirectDamage`, damage radius, speed (e.g. 65 m/s). Shot
  interval = Fire + Reload. `fireEnergy`.
- **Turret arc.** `thetaMin` / `thetaMax` (straight up to a little below level), turn rate
  `degPerSecTheta` / `degPerSecPhi`.
- **Remake.** Weapons `TANK_CHAINGUN` (fire group 1) and `TANK_MORTAR` (fire group 2). The turret is the torso:
  `torso_node` = the vehicle's `Mount10`, a full turn, pitch +90° / −10°. Selectable.

The importer reads every value above from the user's scripts into `gameplay/hercs.json` and
`gameplay/weapons_engine.json` (`tools/export_tribes_vehicles.py tribes2`).

### Wildcat (`ScoutVehicle`, `vehicle_grav_scout`)

One rider and no images. The script notes there is no vehicle.cs entry for it. Unarmed, so AI only.

### Jericho (`MobileBaseVehicle`, `vehicle_land_mpbase`)

The driver only, with no images while it drives. Deployed and standing still, `vehicleDeploy` raises an
inventory station and a `MissileBarrelLarge` turret (`turret_base_mpb`). The remake doesn't model the deployed
form, so the Jericho is unarmed and AI only.

## 3. Engine records

**Vehicles** (`hercs.json`, `"engine_schema": 1`):

- `category: "vehicle"`.
- `kind`: `flyer` / `tank` / `cycle` / `wheeled`.
- `fixed_loadout: true`.
- `default_loadout`: one weapon per gun.
- `guns[]`:
  - `attach_node`: the vehicle node the mount hangs on.
  - `muzzle_units`: position in that node's frame, metres. This is the image's mount point on the vehicle or
    turret, plus the image `offset`, minus the image model's own `mountPoint` node: the weapon model's origin (hardpoint frame).
    Mount rotations cancel in the rest pose (turret_belly_base and its barrels carry 180° X rotations that
    cancel). Projectiles start at the image shape's `muzzlePoint` node (getMuzzlePoint; weapon_mounts.md
    section 4), not at this point.
  - `mount_group`: which of the weapon's `model.mount_shapes` to show.
  - `hardpoint_mask: 0`.
- `fixtures`: the turret bases `{shape, attach_node}`, drawn by `HercModel.build_fixtures` in battle and in the
  `HangarBay`.
- `torso_node` / `cockpit_node`: −1 = none. A vehicle with no cockpit node starts in the chase view.
- `crew`: seats and which seat fires.
- `energy`.
- Fliers: `flight_preset` (Tribes 1) or `flier_data` (Tribes 2), read by `FlightPresets.make_tribes_datablock`.
- Ground vehicles: `hover` (stabiliser and thrust values, recorded only).

**Weapons** (`weapons_engine.json`):

- `category: "vehicle"` and `size_class: "special"` with no hardpoint size, so `WeaponFit` never fits them on a
  Herc hardpoint. `Packs.weapons_for_mask(..., "herc")` never returns them.
- `fire_group`: 1 or 2.
- `projectile.inherit_velocity`: from `velInheritFactor`.
- `projectile.color`: from the tracer, flare or light colour.
- `energy`: in the original units; see §5.
- `damage.tribes`: the original damage value.

| vehicle | speed | hull / shield (ES points) | weapons |
|---|---|---|---|
| Scout (T1) | 50 m/s | 1800 / 0 | FLIER_ROCKET: 1500 radius 9.5 m, every 2 s, 778 m |
| Beowulf | 25 m/s | 9450 / 8889 | chaingun 480 every 0.15 s; mortar 3000 radius 25 m every 1.8 s |

Example rows; the values for every vehicle are in the generated `gamedata/<pack>/gameplay/hercs.json` and
`weapons_engine.json`.

## 4. Selectability and campaigns (campaign_availability.md §2)

- **Armed rule.** `PackVehicleLoader.is_armed` decides who is selectable. The Scout, Shrike, Thundersword and
  Beowulf are pilotable. The LPC, HPC, Havoc, Wildcat and Jericho stay AI only.
- **Arena, skirmish and versus.** All four armed vehicles are offered (`CampaignAvailability.FIELDED_CATEGORIES`
  = herc + vehicle).
- **Campaigns.** Tribes is era 5, later than every Herc game, so the "older design" rule never applies. A Tribes
  vehicle is offered only by the "equivalent" rule. `CombatRating` rates the Tribes vehicles within their own pack:
  fliers with the Hercs, the Beowulf with the tanks. With every Earthsiege Herc unlocked, the Scout, Shrike and
  Beowulf come out "equivalent to Tomahawk / Roadrunner", and the Thundersword isn't offered.
- **Garage, hangar and salvage.** A garage entry always holds the standard armament (`Garage.make_entry`).
  `can_arm` is false, so nothing can be armed or unarmed. Fixed weapons never count as armory stock.
  `LoadoutEditor` shows "Standard armament - fixed" read-only, with no pickers. `BattleSalvage` never recovers
  fixed weapons. `Herc.equip` always fits the standard loadout. Speed balancing (`Packs._compute_balance`) leaves
  Tribes vehicles at their own speeds.

## 5. Approximations

- **Multi-crew weapons belong to the gunner seat.** The bomber's belly turret and bombs belong to the bombardier
  (seat 1), the tank turret to the turreteer (seat 1): a second soldier in that seat aims (mouse / right stick) and
  fires them (fire group 1 the turret gun, fire group 2 the bombs or mortar) while the pilot drives or flies
  (`TurretCrew`, section 6). The aim stays within the turret's arc: TurretData thetaMin / thetaMax (BomberTurret
  90°-180°: level to straight down, turning all the way round; AssaultPlasmaTurret 0°-100° within the tank's torso
  limit). With nobody in the gunner seat the pilot fires them as before: on the Beowulf the turret follows the
  pilot's torso aim, on the Thundersword the belly guns fire along the pilot's aim. AI vehicles aim at their target.
  There are no auto-turrets: the originals turn auto-fire off (`setAutoFire(false)`). The weapon choice by the
  number keys (`setVehicleWeapon`) is the two fire groups.
- **Energy.** Vehicle weapons aren't limited by the energy pool, only by their refire. The pool's damage absorption
  becomes the shield: `maxEnergy / energyPerDamagePoint × 3000`, recharged at
  `rechargeRate × 31.25 / energyPerDamagePoint × 3000` per second. Afterburner and turbo aren't modelled.
- **Damage scale.** One Tribes damage unit = 3000 Earthsiege points, for shields and armour alike. The per-target
  damage-type scales (`$DamageScale`, `*DamageProfile`) aren't applied. The originals have one damage level, so
  the hull is a single fatal component.
- **Tribes 2 flight** (`flier_data`). These are derived from the `FlyingVehicleData` forces:

  | value | derivation |
  |---|---|
  | `maxSpeed` | `maneuveringForce / minDrag`, the terminal speed |
  | `accel` | `minDrag / mass`, as a fraction of maxSpeed per second |
  | `lift` | `jetForce × vertThrustMultiple / mass / 20` |
  | `maxAlt` | 300 m, the usual mission `flightCeiling` |
  | `maxVertical`, `minSpeed` | the Tribes 1 Scout's ratios to its maxSpeed |
  | `maxBank`, `maxPitch` | the Tribes 1 flier of the same role (Shrike = Scout; bomber and Havoc = HAPC) |
  | `hoverHeight` | from the datablock |

- **Ground vehicles.** These drive with the Herc controller: throttle, turn, gravity and floor contact. A
  hover-vehicle model wasn't needed, because they never leave the ground.
  - Hover vehicles: top speed `mainThrustForce / dragForce`; reverse `reverseThrustForce / dragForce`; a linear
    ramp to top speed in 3 time constants (1 / `dragForce`); turn rate `steeringForce × 0.08` rad/s.
  - The Jericho: `maxWheelSpeed` 20 m/s; acceleration `engineTorque / (tireRadius × mass)`; turn rate from the
    bicycle model, `v · tan(maxSteeringAngle) / wheelbase`.
  - Hover height, `floatingGravMag` and the turbo are recorded under `hover`, not simulated.
- **Fire timing.** Paired barrels and bomb bays fire together; the originals stagger them by 125–500 ms.
- **Weapon behaviour.**
  - Bombs drop straight down with the bomber's velocity and Tribes gravity (20 m/s²). AI bombers release them
    within 300 m of the target, a remake value. A bomb that hits nothing is removed after 20 s.
  - The mortar shell's shape is DTS v18, which the exporter can't read, so the projectile is a stand-in.
  - The Shrike's muzzle-flash spin and the turret activation animations aren't played.

## 6. Pilots, seats and boarding (`engine/occupancy/`)

Every vehicle of every pack has a `VehicleOccupancy` (the child node "Occupancy"). It holds one entry per seat,
seat 0 = pilot:

- a player's peer id;
- `AI_PILOT` (-1);
- `EMPTY` (0).

AI vehicles start AI-piloted. An empty vehicle has no brain: it stands where it was parked, idle (no throttle, no
fire), until someone boards it. The host decides every change (`OccupancyDirector`). The exporter writes each
Tribes vehicle's `crew` seat rules: `rules` (`tribes` / `tribes2`), `seats`, `sitting`, `light_only`,
`no_enemy_control` and `min_mount_dist`. `tools/export_tribes_gear.py` writes each seat's role and shape node to
`gamedata/<pack>/gameplay/vehicle_seats.json` (`VehicleSeats`):

| role | seats | does |
|---|---|---|
| pilot | seat 0 | drives / flies; fires the vehicle's weapons unless the gunner seat is manned |
| gunner | Thundersword 1, Beowulf 1 (`weapon_seat`) | works the turret (TurretCrew), with the turret's pitch range |
| armed | T1 LPC 1-2, HPC 1-4 (Vehicle::onCollision unmounts only the pilot's weapon); T2 seats without a mountPose: Havoc 1-5, Thundersword 2 (nodeIsSitting: the tail gunner) | fires his own hand weapons within the seat's view arc |
| passenger | other T2 sitting seats | rides |

An armed passenger keeps his soldier's controls (look, `fire_group_1`, `weapon_next`, `grenade_throw`): his look is
held inside the seat's arc, centred on the seat's outward side (side seats look out of their side, seats on the
centre line away from the pilot), 90° either way. Both games keep the arcs engine-side; the remake's arc is a
half-space. Riders sit at their seat node (T1 `dummy passenger<n>`, T2 `Mount<n>`); the view starts in the chase
camera, as the seat nodes sit inside the hulls.

Taking a seat announces it (`BattleOverlay.announce_player`): the pilot gets "You are piloting: NAME (weapons)", a
gunner "Gunner - Beowulf turret", a passenger "Passenger - Havoc" (an armed seat adds "(firing: his weapons)").

### Riders on their seats

Both Tribes games draw the players in their vehicles. The remake does the same; the Herc games never draw a pilot.

| game | original | remake |
|---|---|---|
| Tribes 1 | `FlierData visibleDriver = true` on the Scout, LPC and HPC. The pilot is posed with `driverPose`, an `animData` slot of his armour (`ArmorData.cs`): Scout 22 `"flyer root"`, LPC / HPC 23 `"apc root"`. Vehicle::onCollision unmounts the pilot's weapon only. | Pilot at `dummy pilot128` in that sequence, weapon put away. |
| Tribes 1 passengers | Mounted at `dummy passenger<n>`; the pose slot is engine-side. | `animData[24]` (`"apc pilot"`; the female armours name `"apc root"` there), weapon in hand. Confidence M: deduced from the one slot no datablock uses. |
| Tribes 2 | Armor::onMount puts the player on the mount node (`setTransform("0 0 0 0 0 1 0")` relative to it) and plays `mountPose[node]`, else `"root"`. The pilot (node 0) and the gunner (`<Vehicle>::playerMounted` node 1) unmount their weapon. | Same: Shrike, Thundersword pilot / bombardier, Beowulf driver / gunner and Jericho driver `"sitting"`, Wildcat rider `"scoutRoot"`, Havoc passengers and the Thundersword tail gunner `"root"` with their weapon. |

- **Data.** `tools/export_tribes_gear.py` writes `shown`, `pose` (sequence names, the first the body has wins) and
  `weapon_shown` per seat into `vehicle_seats.json`; `InfantrySeat` reads them.
- **Placement.** Every rendered frame, on every peer (host and clients), a rider is put on his seat node: turned
  like the node, an armed passenger upright and turned to his look (`Infantry._process`, `InfantrySeat.make_rider_transform`).
  He keeps his armour, body and skin, stays out of collision, targeting and splash, and holds the seat's pose.
- **Own view.** The local player's seated body is on the own-view layer: the vehicle's cockpit camera leaves it
  out, the chase camera draws it.
- **Name plates.** A teammate sees each rider's plate over his seat and none for the vehicle; the riders of the
  viewer's own vehicle get none.
- **Test.** `game/tests/vehicle_riders_check.tscn`; renders with `-- --shots=<dir>` (`renders/riders/`).

### Tribes 1 (`scripts/vehicle.cs`)

| what | original | remake |
|---|---|---|
| Board | Vehicle::onCollision: touching the hull. | A soldier on foot within 0.75 m of the hull footprint (capsule, or half the catalog length or width). |
| Pilot | Only `larmor` / `lfemale` take the pilot seat (`Player::setMountObject(.., 1)`, control passes to the vehicle). | Light armour, pilot seat free. |
| Passengers | Anyone else, or a light armour when the pilot seat is taken, gets a passenger seat from Vehicle::findEmptySeat: HPC 4, LPC 2, Scout none. A Scout without a pilot refuses with a message that only light armour may pilot. | Same; the LPC / HPC have 2 / 4 passenger seats. |
| Teams | No team test: enemy vehicles can be taken. | Same. |
| Leave | Vehicle::jump / dismount (the jump key), out at mount point 0. `newMountTime` = 3 s before the same soldier remounts the vehicle he left. | See "Remake decisions" below. |
| Destroyed | Vehicle::onDestroyed dismounts the pilot and every passenger. | Riders (players and bots) are thrown out, unharmed; the debris damage isn't applied. |

### Tribes 2 (`scripts/player.cs` Armor::onCollision, `vehicles/vehicle.cs` findEmptySeat / doDismount)

| what | original | remake |
|---|---|---|
| Board | Colliding with the vehicle while in the Move state, the vehicle `mountable`. The free seat nearest the soldier within `minMountDist` (4 m; Jericho 3 m). | Touching the hull footprint; of the allowed free seats, the lowest (seat node positions aren't exported). |
| Who may sit where | Light and medium: any seat. `lightOnly` (Wildcat): light pilots only (a refusal message names the scout armour). Heavy: only seats without a `mountPose` (findFirstHeavyNode); other seats refuse it with a message. So heavy armour can't drive or gun the Beowulf, fly the Shrike or Thundersword, ride the Wildcat or drive the Jericho; it rides in the Havoc's passenger seats. | Same seat rules. |
| Teams | `noEnemyControl` (Jericho) refuses the other team. | Same. |
| Seat switching | Not in the scripts: the passenger keys (clientCmdSetDefaultVehicleKeys) copy the move, weapon, pack and jump keys only; a seat change is jump out and touch again (findEmptySeat takes the nearest free seat). | `seat_next` (F / d-pad left, a remake addition) moves to the next free seat the armour may take (the seat rules above). |
| Leave | doDismount on the jump trigger: out 3 m above or beside the seat. setMountVehicle back after 4 s. | See "Remake decisions" below. |

### Non-Tribes vehicles (Earthsiege, Battledrome, Earthsiege 2, Starsiege Hercs, tanks and flyers)

This is a remake rule; those games have no infantry.

- **Boarding.** The vehicle must be empty. Only LIGHT armour boards, by pressing `vehicle_enter_exit` (E / pad B)
  within `BoardingRules.HATCH_REACH` = 3 m of the hull. "The hull" is the vehicle's collision capsule. The soldier
  must be at foot level: from 1 m below the vehicle's base to the top of the hull, at least 3 m. Medium and heavy
  armour see "Light armor required"; an occupied vehicle shows "Vehicle occupied".
- **Teams.** Any team, empty enemy vehicles included, following the Tribes 1 rule.
- **Inside.** Entering hides the soldier, takes him out of collision, targeting and splash, and gives his controls
  and view to the vehicle (cockpit, or chase for vehicles without one).
- **Exit.** Pressing again sets the soldier down beside the hull. The remake tries points 1.5 m out from the hull,
  right side first, then all round, on the floor below (terrain or deck). The first point with a free 0.7 m x
  2.4 m capsule wins, else the roof. Out of a flying jet he drops into the air with his jetpack. He keeps his
  armour (light) and kit, and the vehicle is left empty.

### Remake decisions

- **Leaving a Tribes vehicle.** The jump key (`ascend`, Space / pad A) gets out of a Tribes vehicle from any seat,
  as the originals' jump trigger does (T1 Vehicle::jump / Vehicle::passengerJump, T2 Armor::doDismount);
  `vehicle_enter_exit` works too, and is the only way out of the other vehicles, where `ascend` keeps its own
  meaning. A Tribes flier's pilot therefore climbs with the nose (mouse / stick) and sinks with `descend`, as the
  originals had no lift key either.
- **Remount delay.** A soldier who left a vehicle can't board that same vehicle by touch for 4 s (the Tribes 2
  time). Other vehicles he may board at once (the Tribes 1 `lastMount != %this` rule).
- **Passengers.** Riders show on their seats (below). Armed passengers fire their own weapons within their seat's arc; gunners work
  the turret; sitting passengers ride. The client's input reaches his soldier while he is a passenger, the vehicle
  while he pilots it and the TurretCrew while he guns it.
- **The pilot's team.** The vehicle takes its pilot's team (T2 Armor::onMount: setTargetSensorGroup to the pilot's).
- **Kill credit.** Kills scored by a piloted vehicle are credited to its pilot's soldier.
