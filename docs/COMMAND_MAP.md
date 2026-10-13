# Command map: orders to wingmen and teammates in every game

One engine feature (`game/engine/command_map/`) gives every battle a Tribes 2 style command map: a top-down map
of the battlefield, the units the player's side can see, and an order menu for whatever he picks on the map.
Each game plugs in its own orders, names, keys and replies through a provider. The values come from the user's
discs at import.

## 1. Goal

- **Per game.** Where the original had wingman or squad orders, the map offers exactly those, under the
  original names, with the original keys and the unit's own spoken reply. Games with no orders of their own
  (Battledrome arenas) get the remake's set: attack target, defend point, move to, escort me, regroup on me.
- **Who obeys.**
  - Campaign: the wingmen and squadmates.
  - Co-op and versus: AI teammates and bots. Human teammates get a message and a waypoint.
  - Extraction: squadmates.
- **LAN.** Host-authoritative and replicated.
- **Order lifetime.** An order lasts until it is done, replaced, or its target dies (`order_finished`).

## 2. Engine

| File | Role |
|---|---|
| `command_goal.gd` | Order kinds: attack, move, defend, hold, escort, formation, regroup. It turns a kind into the brain `objective` `{point, urgent, radius, hold, target}` (the exact keys InfantryBot and AIPilot read). It also has the done and failed tests (ground distance, `ARRIVE_RADIUS` 15 m). |
| `command_provider.gd` | Per-game API: `make_title`, `make_menus` (by pick: self, location, nav, player_friend, player_enemy, object_friend, object_enemy, flag_*, objective), `can_open_anywhere`, `can_command`, `resolve_order` (the original's checks), `acknowledge` / `make_ack_line`, `make_formation_offset`. The base class is the remake set. |
| `command_providers.gd` | Picks the provider from the battle's game: the mission's pack, else the map's pack, else the arena / world pack. Builds `CommandOrders` and `CommandMapInput`. |
| `command_orders.gd` | Node "CommandOrders" on the Battle. Request flow: `request_order` sends an RPC to the host; the host's `apply_order` checks `can_command`, then `resolve_order`, then acknowledges, then calls `_set_order`. `_receive_order` reaches every peer. `apply_to_brains` runs from the GameModeBrains hook after the director's plan, and from its own `_physics_process` when there is no director. `order_finished(net_id, order, success)` fires on done, failed, or the unit's death. Formation orders set `AIPilot.leader` and `formation_offset`, and the saved leader comes back when the order is cleared. Base defenders (`DEFENDER_META`) are never taken. |
| `command_map.gd`, `command_map_view.gd` | The map UI: ModalShade/ModalPanel and Widgets, a unit list with tick boxes (none ticked means all), and order buttons for the current pick with their original letters as keys. The view draws structures, nav points, units the radar shows (`RadarContacts`), order points and the cursor. |
| `command_map_background.gd` | Builds the map image (section 4). |
| `command_map_input.gd` | The `command_map` action, with refusals shown on the HUD (section 5). |
| `sensor_link.gd`, `engine/radar_contacts.gd` | Radar and command-map availability (section 6). |

Campaign wingmen keep their mission scripts. An order only overrides the brain objective while it lasts. The
mission's own `order()` calls replace it the way a new order does.

## 3. Orders per game

### 3.1 Earthsiege 1 and 2 (`games/es1/wingman_command_provider.gd`)

- **Names:** the cockpit's own strings (STRINGS0 group 0).
- **Keys:** the original hotkeys, from the DBSIM.EXE key tables:
  - FlashComm (ES1 0x94084): A G H O C E F.
  - Command Display (0x948a4): D A F T G O C E.
- **Replies:** each reply is the pilot's own table line (`audio/tables/pilot<n>_voice.json`, WingmanRadio slot). The line is chosen by the order handler (ES1 0x1a1cc, ES2 0x420aa0, same cases).

| Order (pick) | Goal | Reply (pilot table message) |
|---|---|---|
| ATTACK MY TARGET (self, A) | attack the player's target | 17; 18 when he has no live hostile target (refused) |
| HELP ME OUT! (self, H) | attack the nearest enemy targeting the player (60000 u) | 11; 29 when there is none (refused) |
| JOIN ON ME / DISENGAGE (self, O / D) | formation (MFORMS.DAT slot) | 30 within 25000 u, else 20 |
| ATTACK ENEMY (enemy, A) | attack it | 17; 29 when it is dead |
| DEFEND POSITION (place, F; ES2 also a friendly unit, ES2GUIDE.HLP) | defend / escort | 23 |
| PATROL GRIDPOINT (place, T) | defend there | 42 (the handler's line; 25 is never used) |
| GOTO GRIDPOINT (place, G) | move | 42 |

- **Not offered:** orders with no remake behaviour (Ignore my target, Fire at will / Hold your fire, Scan, EMCON).
- **Broadcast:** an order to the whole squad gets one acknowledgement, as in the original.

### 3.2 Starsiege (`games/starsiege/starsiege_command_provider.gd`)

- **Data:** `gameplay/squad_orders.json`, built by `tools/export_starsiege_squad.py` from:
  - missionStdLib.cs `addSquadmateOrders`;
  - Sim.Strings.cs `IDSTR_SQORDER_1..7`;
  - DatPilot_*.cs `soundVolName` (pilot to `sm_<set>.vol`).
- **Clips:** copied to `audio/voice/squad/<set>/<code>.wav`.
- **Pilot voice:** `ss_unit_director.gd` tags each spawned unit with its pilot (`ss_pilot`), so the reply is in that pilot's voice. Without a pilot it falls back to `hm1` (human) or `cy1` (Cybrid).
- **Keys:** F1-F3 pick a squadmate, F4 the whole squad. Then 1-7 give the order. Enter opens the map.
  - In the remake, `SquadKeys` (`engine/command_map/squad_keys.gd`) handles this outside the map, using the same keys (`cockpit_mode_1..4`). The cockpit leaves F1-F4 to it in Starsiege.
  - The called-up squadmate answers with his CR clip (host-side, through `CommandOrders.request_call_up`).
  - The HUD then lists the squad menu. The order's number key gives it, and the menu closes after 6 s or on Back.
  - Squad order is spawn order.
- **Pilot voice fallback:** mission-defined pilots without a voice set (HA1's Mary, for example) use `hm1`. No mission script sets `soundVolName`.

| Order (key) | Goal | Reply clip |
|---|---|---|
| Attack My Target (1) | attack the player's target | AT; WT when it is missing or friendly (refused) |
| Join On Me (2) | formation | FM |
| Defend My Target (3) | defend the player's target | GD |
| Go To Nav Point (4) | defend at the selected nav point | GO |
| Hold Fire (5) / Fire At Will (6) | not offered (no remake behaviour) | HF / FW |
| Halt! (7) | hold where he is | GN |
| Map: place / nav | guard the point | GO |
| Map: friendly | guard it | GD |
| Map: enemy | attack it | none (plain `order()`, no squawk, as in the original) |

A squadmate who is called up answers with his CR clip.

### 3.3 Tribes 1 and 2 (`games/tribes/tribes_command_provider.gd`)

- **Menus:** from `base_equipment.json` "commands" (`tools/export_tribes_commands.py`):
  - Tribes 1: chatmenu.cs Command Menu and Commander::StarCommand.
  - Tribes 2: commanderMap.cs `$CommandTask`.
- **Task tag to goal:** Attack to attack, Defend to defend, Meet to move, Escort to escort, Repair to move, Capture / Return to move. Deploy, laze, mortar, bomb and waypoint tasks are left out.
- **Opening:** C opens the map anywhere in both games:
  - T1: sae.cs:18 ToggleCommandMode, game.cs:204-213 remoteCommandMode.
  - T2: controlDefaults.cs toggleCommanderMap.
  - A Tribes 1 command station also forces the command GUI (CommandStation::onResupply), and the remake opens the map there too.
  - Turret control from a station is not modelled.
- **Replies:**
  - Tribes 1 bots say nothing (ai.cs AI::onCommand only sets the waypoint).
  - Tribes 2 bots accept a task at once (aiHumanTasks.cs), and the commander hears `voice/bot1/cmd.acknowledge.wav` (serverTasks.cs).
- **Title:** "COMMAND MAP" (T1) or "COMMAND CIRCUIT" (T2).
- **Map sounds:** gui/command_on, command_off and command_hum.wav.

### 3.4 Remake set (`engine/command_map/command_provider.gd`)

This set is used by Battledrome arenas and any battle whose game had no orders:

| Pick | Orders |
|---|---|
| Self | Escort me (E), Regroup on me (R) |
| Place / nav | Move to (M), Defend point (D) |
| Enemy | Attack target (A) |
| Friendly structure | Defend (D) |
| Friendly unit | Escort (E) |

The reply is a text line, "Acknowledged: ..." or "Unable to comply".

## 4. Map look

- **Area:** the battle's MapBounds. An area over 4000 m (an Earthsiege ground plane) is narrowed to the square around units, structures and nav points, plus 300 m.
- **Background, windowed:** an orthographic SubViewport render of the battle's own world from above (fog off, 1024 px). This shows the game's own terrain, palette and buildings: ES1/ES2 worlds, Starsiege terrain, Tribes maps.
  - The ES ground shader skips its distance haze bands for an orthographic camera, so the world palette's near colours show instead of the horizon haze.
  - The render is shaded with a relief from ray-cast heights: light from the north-west, slopes steepened 3x, at 512 px. Hills, rocks and buildings then stand out even in Earthsiege worlds, whose own lighting looks flat from above. ES1 worlds are a flat ground plane in the original, so only their terrain features (rocks, buildings) get shading.
- **Background, headless:** a ray-cast hillshade (160 x 160) in the Tribes 2 teal.
- **Look:** the Tribes 2 style for every game (siege theme, teal, translucent panel). Units are drawn in their team colours (enemies red), structures as squares (dark when not working), nav points as cyan squares.
- **Icons:** the games' own icons, converted at import by `tools/export_map_icons.py` (import step `map_icons`) and drawn by `CommandMapIcons` per remake kind: self, soldier, herc, flyer, turret, generator, sensor, station, vehicle_station, nav, and so on.
  - **Tribes 1:** `Interface/M_*_green/_red.bmp`, kept as drawn (own side green, enemy red), plus `M_WhereAmI` for the player.
  - **Tribes 2:** `textures/commander/Icons` grey art, as the `commanderMapIcons.cs` baseImages map it, tinted by side. The nav waypoint keeps its own colours.
  - **Starsiege:** `shell/mapIcon*.pba` frame 0. The fill uses palette indices 240+, a team colour the sim sets at run time (blank in every .ppl), so it becomes white and is tinted by side; the outline (247) is black.
  - **Earthsiege and Battledrome** had no map icons and use the neutral shapes.
- **Opening:**
  - The first commandable unit is ticked.
  - The player himself is picked only when his game has orders on him; otherwise nothing is picked and no message shows.

## 5. Input

- **Action:** `command_map`, key N, pad hold Back 0.5 s (`SiegeInput.HELD_ACTIONS`).
- **Registered in:** `siege_input.gd`, `binding_contexts.gd` (battle and infantry), the Options listing and the CODING_STANDARDS key table.
- **Map controls:** the same action or Back closes the map. Mouse or the ui directions move the cursor, accept picks, and an order's letter gives it.
- **Refusals (`CommandMapInput.make_refusal`), in order:**
  1. No orders, or no live unit: silent.
  2. The mission's script took the key: section 6.
  3. No sensor link: "Command map unavailable - no sensor link".
  4. A station-only game outside a station: none of the current games.

## 6. What the map shows, and radar availability

### 6.1 What the map shows (`CommandMapKnowledge`)

User rules: "only show what radar shows for enemies", and "buildings and waypoints can be shown if it aligns with the mission".

| What | Shown when |
|---|---|
| Friendly units and his side's structures | Always. |
| Enemy and neutral units | Only while his radar shows them now (`RadarContacts.is_on_scope`), which applies `is_shown` plus a range check. `is_shown` covers the sensor link, units a mission hid, and on Tribes maps the team's sensor net, including its jammer and range rules. In every game but Tribes, the unit must also be within the range his radar covers right now. Each radar display records its current range as it draws (HUD 1200 m, ES MFD SCANNER range, Starsiege/Tribes meter range); before any has drawn, 1200 m is used. |
| Tribes base objects (generators, turrets, sensors, stations) of every team | Always. The original command maps drew the enemy's too: Tribes 1 ships `M_*_red` variants of every base icon, and Tribes 2 puts a `cmdIcon` on every StaticShape datablock. An enemy's deployed objects are shown only when locked as his target, because only the sensor net would show them. |
| Other buildings and map features | Only when the mission makes them known: the target he has locked, or a mission target. For Earthsiege 1 that is the squad's order target (MSN group 0). For Earthsiege 2 it is the squad's current order target and every objective's target. Starsiege and Battledrome name none, so only his locked target shows. |
| Nav points | The mission's own only (group `nav_points`): Earthsiege's briefed waypoints, Starsiege's markers while `setNavMarker` has them on, and the Tribes training waypoint. |

### 6.2 Radar and command-map availability (campaign only)

The command map follows the radar. `RadarContacts.is_shown(viewer, unit)` is the one source for the HUD radar, the
cockpit MFD, the cockpit radar meter and the command map:

- It shows nothing while `SensorLink` is down. That is a battle flag a campaign story sets, and the map is refused and closed while it is down.
- A unit a mission hid is never shown (`RadarContacts.apply_hidden`).
- On Tribes maps it shows only what the team's sensor net detects (`TribesBase.is_on_radar`).

Multiplayer, arena and extraction battles never set these flags, so they keep the map. Tribes multiplayer keeps
the original station and sensor-net rules.

Missions the originals blind, checked in the scripts and executables:

| Game | Missions | Original | Remake |
|---|---|---|---|
| Tribes 2 | Training1, Training2, Training3 | The mission script redefines `toggleCommanderMap` (Training1.cs:89, Training2.cs:91, Training3.cs:87) to send `$player.miscMsg[noCC]`, a line saying the player is not cleared for the Command Circuit yet (spDialog.cs:534) | `Tribes2MissionRuntime.is_command_map_taken`: the map stays shut, and the key runs the script's own function, which prints the line. |
| Tribes 2 | Training4 | The player's own pulse sensors are destroyed (Training4.cs:93-94) | Sensor net: units outside it leave the radar and the map. The map itself still opens, as in the original. |
| Starsiege | HA1 (647/660), HA3 (145-241), ha6, HB1, HC2, CA0 (230/552), CD3 (438/465), CD4 (201-204/329-332), CE3 (213-215, 243-266) | `setVehicleRadarVisible(obj, false/true)` hides single units (ambushes, stealth flyers) | Handled in `SSEngineFunctions` (it used to be swallowed by the "set" ignore prefix). The unit leaves the radar and the map until the script shows it again. |
| Earthsiege 1 / 2 | none | No story radar-off flag in the mission scripts. Radar loss is damage only ("MY RADAR IS OFFLINE.", "SENSOR ARRAY DESTROYED"). | `SensorLink` remains the hook for such a story. No mission sets it. |
| Tribes 1 | none | Only a sensorHUD icon toggle. | None. |

## 7. Tests

`game/tests/command_map_check.tscn`, headless:

```
godot --headless --audio-driver Dummy --path game res://tests/command_map_check.tscn [-- --shots=<dir>]
```

**Battles:** ES1 B0_C0_0A and ES2 C1_01 (with career wingmen, as the garage squad), Starsiege HA1 (squadmates Mary and Harabec), Tribes Raindance, Tribes 2 Katabatic, a Battledrome arena.

For each battle it checks:

- **Provider:** the battle gets its game's provider, and the game's own order is offered.
- **Map:** it opens and closes, and the background has relief and holds the player. The campaign wingmen are listed and the first one is ticked. Opening shows no target message. The game's own icons are loaded (Tribes 1 and 2, Starsiege).
- **Order:** an AI teammate takes an order to a spot 50 m away on open ground (clear line at chest height, within 6 m of his level). His brain gets the objective, he moves, and `order_finished(success)` fires when he actually gets there. Nobody is teleported. The acknowledgement line is printed: ES pilot line and voice, Starsiege squad clip, T2 bot1 cmd.acknowledge, T1 none.
- **Sensor link:** with the link down, the map is refused and the radar shows no enemy. It opens again when the link is back.
- **What the map shows:**
  - Every enemy on it is on the radar now.
  - An enemy beyond the radar's range is hidden, and shown again within range (every game but Tribes).
  - No other side's building shows unless it is a Tribes base object, the locked target or a mission target.
  - The enemy Tribes base is shown.
  - Nav points are the mission's own.
- **Hidden unit:** a hidden unit (Starsiege through `setVehicleRadarVisible`) is off the radar.
- **Starsiege squad keys:** F1 calls up squadmate 1, who answers CR; 2 orders Join On Me; F4 calls up the squad.
- **LAN:** the host refuses an order for an enemy unit, and the replicated order carries kind, task, point, commander and text.

It also checks the Tribes 2 Training1 block, and that Training5 opens the map.

`--shots` (needs a window) saves `command_map_<game>.png`.

## 8. Progress

- [x] Engine feature, providers for ES1/ES2, Starsiege, Tribes 1/2 and the remake set
- [x] Orders from disc data, original keys and replies
- [x] `command_map` input, Tribes command station opening
- [x] Host-authoritative LAN orders
- [x] GameModeBrains hook, direct brains when there is no director, `order_finished`
- [x] Radar/command-map availability: SensorLink, Starsiege hidden units, T2 training command-circuit block
- [x] The games' own map icons (Starsiege mapIcon pba, T1 M_*.bmp, T2 com_icon png)
- [x] Starsiege squad call-up reply (CR) and the F1-F4 / 1-7 squad keys outside the map
- [x] Relief-shaded backgrounds, no distance haze in the top-down render
- [ ] Bots cannot path into or under a base's structures (InfantryBot walks straight; no T2 .nav graphs). This is C's area and is with the coordinator. "Move to" a spot inside a base can stall short of it.
