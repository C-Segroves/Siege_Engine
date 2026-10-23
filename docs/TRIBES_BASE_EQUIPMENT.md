# Tribes base equipment

Agent H, 2026-10-11. Covers the base objects that Tribes (1998) and Tribes 2 maps place in their mission data:
turrets, generators and solar panels, pulse sensors, and inventory, ammo, command and vehicle stations and pads.
It also covers how they behave in arena, versus, LAN and extraction matches.

## 1. Where the data comes from

All values are read from the user's own game files when the disc is imported. No game table is copied into the
repository.

| what | source (read by `tools/export_tribes_base.py`) |
|---|---|
| object kind | the datablock class and className (`TurretData`, `SensorData`, `Generator`, `Station`) |
| hit points | `maxDamage` (T1) and `destroyedLevel` (T2), times the Tribes damage scale of 3000 |
| disabled damage | T1: `maxDamage` times the engine's disabled ratio, read from the user's `tribes.exe` (StaticBaseData constructor at 0x44acc8, which is 0.5; `GameBase::getDisabledDamage` at 0x41c040). T2: `disabledLevel` |
| shield / energy | T1 turrets: `maxEnergy`, plus `setRechargeRate` and `shieldStrength` from `<Name>::onPower` or `onEnabled` (else `Turret::`) in `turret.cs`. T2: `isShielded`, `energyPerDamagePoint`, `maxEnergy`, `rechargeRate` |
| damage profile | T2 `damageScale[$DamageType::X]` of the block's damage profile, applied to each hit by its damage type |
| turret gun | T1 `projectileType` (BulletData, GrenadeData, SeekingMissileData, LightningData); T2 the mission's `initialBarrel` (or the turret's `barrel`) and its projectile. Converted with the infantry exporter's conversions into `gameplay/weapons_turret.json` (`category: turret`) |
| turret aim | T1 `range` (else `gunRange`), `reloadDelay`, `speed`, `minGunEnergy` / `maxGunEnergy`. T2 barrel `attackRadius`, the fire/reload state machine, `degPerSecTheta`, turret `thetaMin` / `thetaMax`, `activationMS`, `minEnergy` / `fireEnergy` |
| sensor range | T1 `SensorData.range`; T2 `sensorData.detectRadius` |
| repair | T1 `RepairBolt::onAcquire` repairRate for other objects and `boltLength`. T2 `RepairGunImage.repairFactorObject` per 32 ms tick and `DefaultRepairBeam.beamRange` |
| power groups | each base object's SimGroup in the `.mis` file: `map.json` gets `power_groups` (`name`, `parent`, `provides_power`), and every station gets `power_group` and `spec` |
| mission datablocks | the datablocks a mission file declares itself (Training3 `TrainingLongDetectTurret` and `LongAttackAABarrelLarge`; `%range` script values keep the parent's value) |

The output goes to `gamedata/<pack>/gameplay/base_equipment.json` and `weapons_turret.json`, and is added to
`maps/<id>/map.json`. The importer runs the step `base` after the maps: `siege_games/tribes.py` (which also copies
`tribes.exe`) and `siege_games/tribes2.py`.

### Power rule (both games)

A working generator powers every object in its own SimGroup and in every group below it. An object is powered while
any generator above it works, or while a group above it has `providesPower` (T2).
- T1 evidence: `GameBase::generatePower` (tribes.exe 0x41e19c, then 0x44417c) walks the generator's group and its
  subgroups and counts power up or down on each shape. `isPowered` means the count is above 0.
- T2 evidence: `SimGroup::powerInit` and `updatePowerCount` in `scripts/power.cs`.
- A generator stops powering when it is disabled (`Generator::isPowering`; T1 `Generator::onDisabled` calls
  `generatePower(false)`).
- Only 3 objects on all T1 arena maps have no power source above them: 1_Welcome's sensor, 6_Towers' turret and one
  FreeForAll indoor turret. In the originals these sit unpowered too.

## 2. Runtime

| piece | file | does |
|---|---|---|
| `TribesBase` | `game/games/tribes/tribes_base.gd` | Battle child `TribesBase`. It replaces every map station that has a spec with a base object, computes power on every peer (state check every 0.25 s), hands the faction repair crew its jobs, provides the sensor query, and handles neutral bases in free-for-all and extraction |
| `TribesBaseObject` | `tribes_base_object.gd` | A `Structure` (in groups `targetables` and `splash_targets`). It has the Enabled, Disabled and Destroyed states, an energy pool, a shield, the damage profile, the T1 team-damage cap (`StaticShape::onDamage`), and repairs back from destroyed (`repairs_ruins`). Repair, capture and the capture timer are `Structure`'s: the same code serves the Earthsiege and Starsiege structures. Repair is synced to clients by RPC |
| `RepairDirector`, `RepairWork`, `BaseCapture`, `RepairRules`, `RepairBeam` | `game/engine/repair/` | The one repair mechanic of every game. The pack beam mends the nearest damaged structure, teammate or vehicle in reach (T1 `RepairBolt::onAcquire`: 0.1 for any target but its user; T2 `RepairGunImage`: `repairFactorPlayer` for players, `repairFactorObject` for the rest; `DefaultRepairBeam.beamRange`) and heals its wearer only with nothing else to mend. A Herc with no pack holds `structure_repair` next to a structure (data: `hold` in `repair_rules.json`, remake values: the originals have no field repair for Hercs). `BaseCapture` is the capture-by-repair rule, per-game data in `repair_rules.json` (`capture`), used by Tribes base objects, `Structure` (Earthsiege 1/2) and `SSStructure` (Starsiege) alike |
| `TribesTurret` | `tribes_turret.gd` | Picks the nearest hostile target among the vehicles, Hercs and soldiers (`TeamRelations`; it skips `dormant` and stowed targets). The target must be in range, in the pitch arc and in line of sight (castLOS). The turret turns at its turn rate, waits out the barrel activation, leads the target, and pays energy per shot. It fires projectiles (shared `Projectile`, replicated through the fx channel) or beams (ELF) |
| `TribesPowerGrid` | `tribes_power_grid.gd` | The group power rule above |
| `TribesStations` (agent C's file, small additions) | `tribes_stations.gd` | Only real station specs count. Stations work only while their base object works. Use is through the interact action or by stepping on. Extraction rules (below) |
| weapon loader | `engine/pack_weapon_loader.gd` | Also loads `gameplay/weapons_turret.json` |
| projectile | `engine/weapons/projectile.gd` | Splash damage also hits the group `splash_targets` (a mortar next to a generator damages it) |
| MapBuilder | `engine/map_builder.gd` | Built stations carry their `record` (the map.json entry); `make_transform(entry)` |
| `TribesTurretRig` | `tribes_turret_rig.gd` | Poses the turret shape with its own sequences: `turn` (one revolution per cycle), `elevate` (one end of the barrel's range to the other), `power` / `Activate` / `Deploy` (deploying), `fire`. Applied in sequence priority order. The phase-to-angle mapping is measured from the shape. T2 mounts the barrel shape's `Mountpoint` on the base's `Mount0` |
| `TribesTurretGun` | `tribes_turret_gun.gd` | The turret's catalog gun: projectile or beam shots, and the low ballistic arc for shells |
| `TribesForceField` | `tribes_force_field.gd` | T2 `ForceFieldBare` (box from its corner over its scale) and the T1 StaticShape ForceField. Closed (solid, drawn in its datablock colour) while powered, open without power. `teamPermiable` / `otherPermiable` are kept as per-body collision exceptions |
| `TribesMover`, `TribesDoor`, `TribesElevator` | `tribes_mover.gd`, `tribes_door.gd`, `tribes_elevator.gd` | T1 Moveables along the SimPath beside them, at the MoveableData speed, with the `Door::*` and `Elevator::*` rules of `moveable.cs` (details below). The host decides the goal waypoint; every peer moves there |
| `TribesSensorNet` | `tribes_sensor_net.gd` | What each team's radar shows (rules below) |
| `TribesBaseLights` | `tribes_base_lights.gd` | The glowing parts and cast light of base objects; on only while the object works |

APIs for other agents:
- `TribesBase.of(battle)`
- signals `object_destroyed(obj, killer)` and `power_changed`
- `TribesBase.is_working(obj)`
- `TribesBase.is_on_radar(viewer, unit)`: used by the three radars (`hud.gd`, `cockpit_mfd.gd`,
  `cockpit_meter_radar.gd`). It is always true outside Tribes base battles and in extraction
- `objects_of(kind)`
- Objects expose `kind`, `datablock`, `team`, `alive`, `make_damage_state()`, `apply_repair(points)`, `powered`.

### Modes

- **Team arena, versus and LAN:** the base belongs to the map's team groups. Turrets shoot the other teams.
  Power, damage states and repair are the same on every peer.
- **Free-for-all** (`GameModes.is_free_for_all`) and **extraction:** the whole base is neutral (team -1). Turrets
  fire at everyone, and anyone may use a station.
- **Extraction** (agreed with agent F):
  - Inventory and ammo stations only refill health and energy: no armour change, no free ammunition or gear.
  - Vehicle stations are off; vehicles come from call-ins.
- **Inventory station:** opens the buy menu (StationMenu), with armour, weapons, grenade and pack limited by the
  armour. A purchase refills ammunition, health and energy.
- **Ammo station:** tops up ammunition only, every 0.5 s.
- **Vehicle station:** puts the chosen vehicle on the nearest clear pad. On T1 the VehicleStation panel is the buy
  point. On T2 the StationVehiclePad is.
- **Extraction shop (X2, with F):** using an inventory station calls `ExtractionDirector.open_station_shop(soldier)`
  on the local peer, after the host refill of health and energy.

### Turret look (follow-up 1)

- The aim is simulated on the host and sent to clients with `_receive_aim` at the think rate (0.2 s). Fire
  sequences are sent with `_play_fire`.
- Deploying takes `activationMS` / `deactivateDelayMS` (T2). T1 turrets have no activation time in their data, so
  their "power" sequence snaps.
- T2 barrel shapes (`turret_fusion_large`, `_aa_`, `_missile_`, `_mortar_`, `_elf_`) are exported by the base step
  and mounted on the base.

### Ballistics (follow-up 3)

- **Root cause:** every T2 grenade-type projectile used the missions' player gravity (20 m/s2). The T2 engine
  drops GrenadeProjectile and BombProjectile at its own constant (9.81, Tribes2.exe 0x61655b / 0x779c54) times
  `gravityMod`.
- **Fix:** the importer reads that constant from the user's Tribes2.exe (`export_tribes_vehicles.t2_gravity`; the
  importer now copies Tribes2.exe).
- **Result:**
  - turret mortar: 43.7 m/s reaches 195 m (attackRadius 160);
  - infantry mortar: 414 m;
  - grenade launcher: 225 m;
  - Beowulf mortar: 431 m;
  - bombs: fall at 9.81.
- T1 GrenadeData keeps the missions' 20 m/s2. Its launch speed is derived from `maxLevelFlightDist` at that
  gravity, so its range matches the data.
- Turrets lob shells on the low arc that reaches the target (`TribesTurretGun.make_fire_direction`).

### Projectile drag (round 3)

- `GrenadeProjectileData.drag` acts **only in water**. Tribes2.exe 0x6194b2: when the in-water test (0x615d80)
  holds, the force step adds −velocity × drag × 15.0 (the constant at 0x77a264). In air there is no drag.
- So the air ranges above are exact.
- The importer reads the factor from the exe into the projectile field `water_drag_per_s` (drag 0.1 → 1.5 /s).
- `Projectile` applies it inside the map's liquid volumes (`engine/map_water.gd`, from the T2 WaterBlocks that
  are already exported; 19 maps have them).
- Integration matches the engine's tick: velocity, then position (semi-implicit), as in the 32 ms tick at 0x619538.
- Tribes 1 projectile datablocks have no drag field.

### Deployables (round 3)

`tools/export_tribes_deployables.py` reads the rules from the scripts into base_equipment.json `deployables`.
`TribesDeployRules` checks them and `TribesDeployables` places the objects.

**Tribes 1** (`item.cs`):
- **Reach:** `getLOSInfo` 3 m. The aim must hit terrain or a building.
- **Flat items:** normal·up > 0.7.
- **Motion sensor and camera:** stick to any surface, snapped upright or upside down past 0.6.
- **Space:** `checkDeployArea` needs a 1 m box empty ("You're in the way" / "Item in the way").
- **Remote turret:** at most `$MaxNumTurretsInBox` (2) turrets in the 50 m box, and none in the 10 m box.
- **Team limits:** `$TeamItemMax` (turret 10, sensors 15, camera 15, jammer 8, inventory 5, ammo 7).

**Tribes 2** (`deployables.cs`):
- **Reach:** 4 m (`$MaxDeployableDistance`).
- **Slope:** `maxDepSlope`.
- **Outdoor turret (landspike):** terrain only.
- **Indoor turret (spider clamp):** buildings only, in a floor, wall or ceiling variant by surface angle
  (45° / 155°).
- **Space:** `$MinDeployableDistance` 0.5 m, for objects and for the deployer.
- **Turret spacing:** `$Turret*SpaceRadius` (20 / 25 m), and saturation of `MaxPerSphere` 4 within 50 / 60 m.
- **Team limits:** `$TeamDeployableMax`. Turrets get one per two players of the bigger team, clamped to
  min 4 / max 10.
- **Sensor packs:** hold `maxSensors` (2).

Common to both games:
- Deployed objects are base objects that power themselves. They are targetable, destructible and repairable,
  and are on the radar through the sensor net.
- Deployed inventory and ammo stations join the stations.
- A T1 deployed sensor jammer (SensorData `supression`) hides its side's units in its range from enemy sensors.
- Pack use (C's `InfantryGearDirector.apply_pack_toggle`) deploys. Gear packs with effect `deploy` are now offered
  at stations.
- Extraction (agreed with F): the packs are priced, sold and looted by F's item list, since they are mapped. A
  used-up pack leaves the raid inventory (`pack/<id>`). The squad limit is the original team limit. Deployed
  stations work like base stations, including F's shop.
- The T2 camera is a thrown grenade in the original, so it is not a pack. C declined it and it is not done.

### Doors (round 3)

- Doors whose mission marks them `destroyable` take damage at `$DoorScale[type]` (moveable.cs `Door::onDamage`;
  a type not in the table counts 0) up to their `maxDamage` × 3000. Destroyed, they stop where they are
  (`Door::onDestroyed`).
- T1 `triggerOpen` doors (Siege) open while a teammate's soldier or vehicle is inside a `GroupTrigger` box of
  their group, and close when the last one leaves (`onTrigEnter` / `onTrigLeave`). The exporter writes the trigger
  boxes into each mover.
- Force-field doors have maxDamage 10000, so they are effectively indestructible, as in the original.
- T2 ForceFieldBare objects take no damage in the original. They are knocked out through their generators.

### Command map (round 4)

- **Orders:** read from the scripts by `tools/export_tribes_commands.py` into base_equipment.json `commands`, as
  menus by target type: location, own or enemy combatant, own or enemy equipment, flag, objective.
  - **T1** (`chatmenu.cs`): the Command Menu's Attack (a), Defend (d) and Repair (r), with
    `Commander::StarCommand`'s message for each target ("Destroy enemy turret at waypoint", "Cover <name>" ...).
  - **T2** (`commanderMap.cs`): the `$CommandTask` table, with its hotkeys and the enemy-or-own split.
  - Only tasks the bots can carry out are offered: Attack, Defend, Meet, Escort, Repair, Capture and Return.
    Deploy, laze, mortar and bomb need bot skills that don't exist.
- **Opening it:** a working command station opens the command map (`TribesCommandMap`), by stepping onto it or
  through interact.
- **The map** (`TribesCommandMapView`) is drawn in the shared theme. It shows:
  - the mission terrain (the map's albedo over the playable area);
  - the base, in team colours, dark when not working;
  - teammates;
  - enemies the team's sensors see;
  - order waypoints.
- **Controls:** pick a place, combatant or object with the mouse, or with the ui-direction cursor and ui_accept.
  Select teammates, then give an order with its button or with the original's letter.
- **Order handling** (`TribesCommandOrders`, host): an order overrides a bot's game-mode objective until it is
  done, replaced, or its target is gone.
  - `GameModeBrains.apply_goals` calls `apply_to_brains` after the mode's plan. Without a game-mode director, the
    orders are applied directly. Base defenders are left alone.
  - Players get the message and a nav-point waypoint.

### Force fields, doors, elevators (follow-up 2)

- **T2:** 109 `ForceFieldBare` across the maps. Many sit in `providesPower` groups (always powered, as in the
  original).
- **T1 doors** (`moveable.cs`): closed at the centre waypoint (`onNewPath`). A teammate touching one (or within
  its `triggerRadius`) opens it. It closes 3 s after nobody touches it (`onFirst` / `onLast`). Without power it
  opens. Force-field doors (`$ForceFields`) fade instead of moving.
- **T1 elevators:** a teammate on the deck sends it up. It pauses 1.5 s at stopWayUp / stopWayDown waypoints and
  at the ends, then returns. `loop` elevators run on their own. Without power an elevator returns to its first
  waypoint.
- In total: 64 movers, plus 2 StaticShape force fields on T1.
- The originals open doors on contact, so the remake uses proximity rather than the interact key.

### Radar (follow-up 4; Tribes maps only, not extraction)

- **T1:** soldiers carry no SensorData. The radar is the team's sensor network alone: pulse sensors and turrets
  (`range`; `castLOS` needs a clear line).
- **T2:** team sensors (`detectRadius`, `detectsUsingLOS`), plus every teammate's `PlayerSensor` (2000 m, LOS,
  within `detectFOVPercent` 1.3 of the armour's 90 degree `cameraDefaultFov`).
- **Jammer packs:** a wearer with the pack on is seen only by sensors with `detectsPassiveJammed` (T2 soldiers;
  no T1 sensor).
- Teammates always show. Detection refreshes every 0.25 s on every peer.
- ES and Starsiege radars are unchanged.

### Lights (H2)

- The games' base equipment has no dynamic-light fields. T1 StaticShapeData and T2 StaticShapeData have no
  lightType, lightRadius or lightColor; T2 has only hum sounds.
- The games light it with self-illuminating materials: T2 DTS flag 32, including the IFL blink panels. The remake
  draws those unshaded.
- Those parts now go dark (shaded, dimmed) when the object is unpowered, disabled or destroyed.
- Each lit object also casts an OmniLight3D. This light is the remake's: average glow colour, range 1.5 x the
  shape's size.
- T1 mission `SimLight` point lights (23 placements, type 2) are placed with their own range and colour. They
  are always on, because a SimLight is not a GameBase object.

## 3. Audit (before, after)

**Before this work:**
- All turrets, generators, solar panels, sensors and command stations were static shapes: inert, not targetable,
  and not destructible.
- Inventory, ammo and vehicle stations worked by stepping on them, but there was no power and no destruction.
- T1 VehiclePads also acted as vehicle stations.
- On T2 maps the ammo items lying on racks (PlasmaAmmo and the like, 63 objects) were treated as ammo stations.

**After:**
- Every base object below is built as a working object. 100% of the base stations have a spec (`tribes_base_check`
  audit).
- "armed" counts turrets whose gun resolved in the weapon catalog. T2 turret bases without a barrel stay unarmed, as
  in the original.
- "unpowered at start" counts objects with no power source above them.
- Flags, switches and the Nexus are agent G's (game modes); repair-pack and ammo items on racks are agent C's
  (pickups). Neither is in this table.

| map | base objects | gen | turrets (armed) | sensors | inv | ammo | cmd | vehicle station / pad | unpowered at start |
|---|---|---|---|---|---|---|---|---|---|
| tribes:ADishBestServedCold | 26 | 4 | 6/6 | 4 | 4 | 2 | 2 | 2 / 2 | 0 |
| tribes:AntHill | 31 | 5 | 8/8 | 3 | 7 | 5 | 3 | 0 / 0 | 0 |
| tribes:BloodRunsCold | 0 | 0 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes:BloodyVengeance | 34 | 8 | 6/6 | 2 | 4 | 4 | 6 | 2 / 2 | 0 |
| tribes:Broadside | 30 | 6 | 6/6 | 2 | 8 | 6 | 2 | 0 / 0 | 0 |
| tribes:Citadels | 59 | 9 | 16/16 | 5 | 10 | 10 | 5 | 2 / 2 | 0 |
| tribes:CrissCross | 40 | 9 | 14/14 | 5 | 10 | 1 | 1 | 0 / 0 | 0 |
| tribes:DangerousCrossing | 20 | 4 | 6/6 | 4 | 4 | 2 | 0 | 0 / 0 | 0 |
| tribes:DeathKnell | 20 | 4 | 6/6 | 1 | 4 | 3 | 2 | 0 / 0 | 0 |
| tribes:Desert_Of_Death | 12 | 2 | 6/6 | 4 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes:Fallen | 18 | 2 | 2/2 | 2 | 6 | 4 | 2 | 0 / 0 | 0 |
| tribes:FogOfWar | 23 | 1 | 8/8 | 4 | 8 | 0 | 2 | 0 / 0 | 0 |
| tribes:FourWayDance | 42 | 5 | 11/11 | 11 | 4 | 5 | 4 | 1 / 1 | 0 |
| tribes:FreeForAll | 57 | 9 | 16/16 | 3 | 18 | 8 | 3 | 0 / 0 | 1 |
| tribes:HammerDown | 36 | 6 | 7/7 | 4 | 10 | 7 | 2 | 0 / 0 | 0 |
| tribes:IceRidge | 16 | 2 | 6/6 | 2 | 4 | 2 | 0 | 0 / 0 | 0 |
| tribes:KingUnderTheHill | 0 | 0 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes:LuckySeven | 37 | 1 | 14/14 | 7 | 5 | 5 | 5 | 0 / 0 | 0 |
| tribes:Mudslide | 33 | 5 | 7/7 | 3 | 6 | 8 | 4 | 0 / 0 | 0 |
| tribes:NoMan'sLand | 24 | 5 | 4/4 | 2 | 5 | 2 | 2 | 2 / 2 | 0 |
| tribes:NoQuarter | 48 | 6 | 20/20 | 4 | 8 | 2 | 8 | 0 / 0 | 0 |
| tribes:PeakPerformance | 12 | 1 | 0/0 | 5 | 4 | 2 | 0 | 0 / 0 | 0 |
| tribes:Peekaboo | 2 | 1 | 0/0 | 0 | 0 | 1 | 0 | 0 / 0 | 0 |
| tribes:Raindance | 20 | 2 | 6/6 | 2 | 2 | 2 | 2 | 2 / 2 | 0 |
| tribes:Rollercoaster | 18 | 4 | 4/4 | 2 | 4 | 0 | 0 | 2 / 2 | 0 |
| tribes:SandStorm | 0 | 0 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes:Scarabrae | 36 | 5 | 8/8 | 3 | 6 | 6 | 4 | 2 / 2 | 0 |
| tribes:SeekAndDestroy | 50 | 8 | 18/18 | 4 | 10 | 4 | 2 | 2 / 2 | 0 |
| tribes:Siege | 48 | 9 | 11/11 | 2 | 8 | 8 | 6 | 2 / 2 | 0 |
| tribes:Snowblind | 21 | 1 | 10/10 | 0 | 8 | 0 | 2 | 0 / 0 | 0 |
| tribes:Stonehenge | 14 | 2 | 6/6 | 2 | 4 | 0 | 0 | 0 / 0 | 0 |
| tribes:StrungOut | 22 | 7 | 0/0 | 2 | 6 | 5 | 2 | 0 / 0 | 0 |
| tribes:TempleOfDoom | 46 | 3 | 10/10 | 6 | 10 | 6 | 7 | 2 / 2 | 0 |
| tribes:TheRedSands | 0 | 0 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes:towers | 25 | 1 | 10/10 | 5 | 3 | 3 | 3 | 0 / 0 | 0 |
| tribes:TripleThreat | 25 | 1 | 10/10 | 5 | 3 | 3 | 3 | 0 / 0 | 0 |
| tribes:Valhalla | 36 | 1 | 13/13 | 6 | 7 | 7 | 2 | 0 / 0 | 0 |
| tribes2:Abominable | 13 | 3 | 4/4 | 1 | 5 | 0 | 0 | 0 / 0 | 0 |
| tribes2:AgentsOfFortune | 10 | 0 | 0/0 | 0 | 10 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Alcatraz | 16 | 5 | 5/5 | 0 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Archipelago | 24 | 4 | 2/2 | 4 | 12 | 0 | 0 | 0 / 2 | 0 |
| tribes2:AshesToAshes | 20 | 6 | 2/2 | 4 | 6 | 0 | 0 | 0 / 2 | 0 |
| tribes2:BeggarsRun | 12 | 0 | 4/4 | 2 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Caldera | 15 | 3 | 3/3 | 2 | 6 | 0 | 0 | 0 / 1 | 0 |
| tribes2:Casern_Cavite | 7 | 0 | 0/0 | 0 | 7 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Damnation | 22 | 4 | 2/2 | 2 | 14 | 0 | 0 | 0 / 0 | 0 |
| tribes2:DeathBirdsFly | 30 | 4 | 2/2 | 2 | 18 | 0 | 0 | 0 / 4 | 0 |
| tribes2:Desiccator | 18 | 6 | 2/2 | 2 | 6 | 0 | 0 | 0 / 2 | 0 |
| tribes2:DustToDust | 4 | 0 | 2/2 | 2 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Equinox | 7 | 0 | 0/0 | 0 | 7 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Escalade | 9 | 0 | 0/0 | 0 | 9 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Firestorm | 4 | 0 | 0/0 | 0 | 4 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Flashpoint | 18 | 3 | 4/4 | 1 | 8 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Fracas | 5 | 0 | 0/0 | 0 | 5 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Gauntlet | 31 | 5 | 3/3 | 0 | 22 | 0 | 0 | 0 / 1 | 0 |
| tribes2:Gehenna | 6 | 1 | 0/0 | 0 | 5 | 0 | 0 | 0 / 0 | 0 |
| tribes2:IceBound | 33 | 3 | 5/5 | 1 | 23 | 0 | 0 | 0 / 1 | 0 |
| tribes2:Insalubria | 42 | 0 | 20/20 | 0 | 20 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Invictus | 1 | 1 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes2:JacobsLadder | 26 | 0 | 7/7 | 3 | 16 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Katabatic | 32 | 4 | 6/6 | 2 | 18 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Masada | 12 | 4 | 2/2 | 1 | 4 | 0 | 0 | 0 / 1 | 0 |
| tribes2:Minotaur | 10 | 0 | 6/6 | 0 | 4 | 0 | 0 | 0 / 0 | 0 |
| tribes2:MyrkWood | 6 | 0 | 0/0 | 0 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Oasis | 9 | 3 | 0/0 | 0 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Overreach | 61 | 8 | 11/11 | 0 | 40 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Pyroclasm | 8 | 0 | 0/0 | 0 | 8 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Quagmire | 18 | 6 | 4/4 | 0 | 8 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Rasp | 5 | 0 | 0/0 | 0 | 5 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Recalescence | 42 | 6 | 12/12 | 0 | 22 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Respite | 11 | 3 | 2/2 | 0 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Reversion | 42 | 4 | 12/12 | 2 | 22 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Rimehold | 5 | 1 | 0/0 | 0 | 4 | 0 | 0 | 0 / 0 | 0 |
| tribes2:RiverDance | 22 | 2 | 6/6 | 0 | 14 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Sanctuary | 18 | 4 | 2/2 | 2 | 8 | 0 | 0 | 0 / 2 | 0 |
| tribes2:Sirocco | 12 | 4 | 0/0 | 2 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Slapdash | 20 | 4 | 6/6 | 4 | 4 | 0 | 0 | 0 / 2 | 0 |
| tribes2:SunDried | 12 | 0 | 0/0 | 0 | 12 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Talus | 12 | 0 | 0/0 | 0 | 12 | 0 | 0 | 0 / 0 | 0 |
| tribes2:ThinIce | 36 | 8 | 4/4 | 2 | 18 | 0 | 0 | 0 / 4 | 0 |
| tribes2:Tombstone | 20 | 4 | 8/8 | 2 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Training1 | 1 | 0 | 0/0 | 1 | 0 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Training2 | 11 | 3 | 2/2 | 4 | 2 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Training3 | 61 | 4 | 41/41 | 13 | 3 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Training4 | 7 | 2 | 0/1 | 2 | 2 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Training5 | 29 | 10 | 7/9 | 2 | 8 | 0 | 0 | 0 / 0 | 0 |
| tribes2:UltimaThule | 14 | 6 | 2/2 | 1 | 5 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Underhill | 6 | 0 | 0/0 | 0 | 6 | 0 | 0 | 0 / 0 | 0 |
| tribes2:Whiteout | 0 | 0 | 0/0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |

## 4. Not done / limits

- **Command map:**
  - No turret or camera control from the station.
  - The T1 Deploy submenu and the T2 deploy, laze, mortar and bomb tasks are not offered (bots can't do them).
  - Orders end only when replaced, when their target is gone, or (attack on an object) when the object is
    destroyed.
- **Deployables:**
  - T2 camera grenade: not done.
  - T1 cameras are sensors only; there is no remote view.
- **Doors:** destroyed doors are not repairable (no script repairs them). Elevators take no damage, as in the
  original.
- **T1 RocketTurret:** its `reloadDelay` is commented out in `turret.cs`. Its rate comes from energy (60 per shot
  against 14/s), which gives about one rocket every 4.3 s.
- **T1 turret energy:** reading `maxGunEnergy` as the energy a shot spends and `minGunEnergy` as the energy needed
  to fire is an interpretation (the engine code was not traced). The same applies to `setRechargeRate` being per
  second.
- **T1 repair rate:** read as damage per second (`setAutoRepairRate` units not traced).
- **T2 ELF turret:** it drains energy (`elf_leech`). Its small health drain (`drainHealth`) is not modelled.
- **T2 grenade drag:** GrenadeProjectileData `drag` (0.1) is not applied.
- **T2 vehicle pad:** the StationVehicle terminal that the pad spawns in the original is not a separate object. The
  pad itself is the station (invincible, needs power).
- **Parked vehicles on pads:** the player's parked Herc starts on a vehicle pad and keeps it "not clear" until it is
  moved. This was already the behaviour before this work.
- **Sensor jamming:** deployed T1 jammers (suppression) and T2 jammer packs jamming other sensors are not
  modelled; the pack only hides its wearer.
- **Turret weapon fx:** the turret guns get their projectile and impact effects from the fx exporters (the
  `weapon_fx` step now runs after `base`).
- **Light render check:** it is weak. The lit/unpowered brightness difference of a station view is small (0.175
  vs 0.171), because the glow panels are small.
- **T2 turret detection:** T2 turrets use their own attack radius. Team-sensor cueing beyond the turret's own sensor
  is not modelled.

## 5. Tests

- `game/tests/tribes_base_check.tscn` covers:
  - the audit of all maps;
  - power-grid unit checks;
  - on `tribes:Raindance` and `tribes2:Katabatic`:
    - the turret ignores a teammate, then targets, fires at and hits an enemy;
    - destroying the generators powers the turret and a station down;
    - repairing them powers both up again;
    - the repair pack repairs a damaged generator;
    - interact offers the inventory station;
    - a purchase changes the loadout and refills ammunition and health;
    - the vehicle station spawns a vehicle;
    - free-for-all makes the base neutral.
  - Result: OK, 0 failures.
- `game/tests/tribes_fixtures_check.tscn` covers:
  - ballistics data;
  - the turret rig: it turns, deploys, folds, and has its barrel mounted;
  - lights off and on with power;
  - force fields: power and permeability;
  - radar: sensor range, out of the net, teammates, T2 soldier sight; on T2 Katabatic and T1 Raindance;
  - T1 Siege trigger-opened doors (touch does not open, trigger opens, leaving closes), door damage by type,
    power cut, elevators;
  - deployables on Raindance (remote turret placed and self-powered, pack used up, frequency overload, out of range,
    pulse sensor, deployable inventory station) and Katabatic (landspike on terrain, space-radius interference,
    spider clamp refused off buildings and placed on a building floor as the floor variant, motion sensor pack
    with 2 uses);
  - with `-- --shots=<dir>` in a window: the render check of a station lit and unpowered.
  - Result: OK, 0 failures (headless and windowed).
- `compile_all`: 500 scripts, 0 failed.
- `fix_a_check`: OK.
- `weapon_fx_check`: OK (197 weapons).
- `infantry_check`: OK.

## 6. Progress

- [x] Audit of all T1 and T2 arena maps
- [x] Importer: specs, turret weapons, power groups (`tools/export_tribes_base.py`, import step `base`)
- [x] Power networks with T1 and T2 damage states
- [x] Turrets: targeting by team, data weapons, range, refire, energy, destroy and repair
- [x] Inventory, ammo and vehicle stations: power, interact, refill; extraction rules
- [x] Repair pack repairs base objects
- [x] Sensors gate the Tribes radars (TribesSensorNet)
- [x] Turret head animation, deploy and fire sequences, T2 barrels, client aim
- [x] Force fields, doors and elevators as powered objects
- [x] T2 ballistic projectile gravity from Tribes2.exe (mortar range)
- [x] Lights (H2): glowing parts and cast light follow power; T1 mission point lights
- [x] Extraction station shop hook (X2, with F)
- [x] Projectile drag from Tribes2.exe (water only)
- [x] Deployables (T1 and T2 packs, placement rules, team limits, jammer)
- [x] Destructible doors, T1 trigger-opened doors
- [x] Command map at command stations (orders from the games' menus to teammates and bots)
