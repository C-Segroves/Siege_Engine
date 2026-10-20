# QA report: end-to-end pass (2026-10-09)

Every mode was played through the real screens (mouse clicks, InputEventAction and joypad events) by
the new driver `game/tests/e2e_driver.gd` / `.tscn`. It survives scene changes because it lives under the tree root.

```
G="$SIEGE_GODOT"
"$G" --path game --audio-driver Dummy res://tests/e2e_driver.tscn -- --flow=<flow> --shots=<dir> [flags]
```

Flows: `library`, `es1_shell [--resume]`, `es1_launcher`, `es2`, `starsiege_human`, `starsiege_cybrid`,
`saga`, `skirmish --mapname=<picker text> --veh=<id>`, `battle <battle flags> [--watch=s]`, `gamepad`,
`continue`, and the LAN pair `lan_host --mode=coop|vs|campaign [--mapname= --ai=]` + `lan_join`
(start the host, wait 5 s, then start the join). The script prints `E2E FAIL:` lines and ends with `E2E DONE <n> failures`.

Screenshots: `<local path>`
(below this is `QA\`; sub-folders `sk\<run>\`, `bt\<run>\`, `coop\<mode>\`, `pad\`, logs in `logs\`).
User save files were backed up and restored afterwards (only `es1_careers.json` existed before).

## Fix status (UI / flow pass, 2026-10-09)

Fixed with regression tests: **#3, #5, #6, #8, #9, #13, #15, #16, #17** (and the salvage part of #23 on
the new results screen). New headless tests: `battle_menu_check` (in-battle menu, leave / abort,
results, rematch, objective texts on all 130 picker maps), `campaign_save_check` (every game's
campaign save / load / continue, legacy saves, co-op client offer, Build defaults, launcher Back /
Quit), `shell_check` (#9, #15); `input_check` (#16) and `ui_nav_check` (three-answer dialog) were
extended. New e2e flows: `pause`, `abort --game=`, `continue --expect_pack=`, `lan_host/lan_join
--leave=host|client`, and the co-op campaign client check inside `lan_join --mode=campaign`. Every
flow now passes through the results screen (`pass_results`).

---

## P1: blocks play or affects every session

### 1. 3D sound effects break after the first battle of a session (FIXED)
**Fixed:** the positional pool is owned by the `Sfx` autoload (engine/sfx.gd), so it survives scene changes. Test: `qa_fix_check` plays sounds in two battles in a row and checks every pooled player (`res://tests/qa_fix_check.tscn -- --page=options`). Re-run: `--flow=es2` (two missions) and a LAN vs pair log no "previously freed" errors.

`Sfx._free_positional_player()` (engine/sfx.gd:96) keeps its pooled `AudioStreamPlayer3D`s as children of
the *current scene*. When the first battle is freed, the pool holds freed instances. In every later battle,
each `play_at` (footsteps, weapon fire, explosions) raises a SCRIPT ERROR before a player is found, so no
positional sound plays. This happened 446 times across the runs: in the 2nd mission of the ES1 career, ES2 and the saga, and in every LAN match end.
```
SCRIPT ERROR: Invalid access to property or key 'playing' on a base object of type 'previously freed'.
   at: _free_positional_player (res://engine/sfx.gd:96)
       [1] play_at (res://engine/sfx.gd:84)
       [2] _play_footstep (res://games/es1/herc.gd:343)
```
Repro: `--flow=es2` (two missions in a row). Grep the log after "scene -> Battle" for the second time.

### 2. Tribes 2 vehicle pads trap vehicles (tribes2:Caldera) (FIXED)
**Fixed:** the pad spawn sat 3 m under the pad deck (pad station origin, inside `vehicle_pad` and `int_dvpad1`). New `SpawnClearance` (engine/spawn_clearance.gd) lifts every vehicle spawn out of solid trimesh geometry (T2 creates vehicles 4 m above the pad). Every T2 pad interior (dvpad, svpad, pvpad, bvpad, pvbay) has a rim a walker cannot leave, so `MapBuilder` now returns pads separately (`pad_spawns`): flying vehicles start on them, everything else on ground spawns; infantry fallbacks inside a base move to open ground next to it. Test: `qa_fix_check` (pad spawns on Caldera, Katabatic, IceBound; Shrike and Outlaw drive off Caldera's start). Re-run: Caldera with Shrike, Thundersword, Outlaw all move; AI units fight.

- The Shrike and Thundersword spawn on the Caldera pad and **never move**. Velocity stays 0 at full throttle and lift for 6 s,
  colliding with `tribes2_vehicle_pad` / `tribes2_int_dvpad1`. The HUD still shows 24-80 KPH.
- A walking Herc (es2:OUTLAW) spawned on the same pad walks about 20 m, then sticks on the pad rim (`tribes2_int_dvpad1`) for good.
- The two AI units on that pad never damaged anyone in 30 s.
- The Shrike on tribes2:Abominable flies normally (170 m in 6 s), so the problem is the Caldera pad geometry or spawn height.
```
--flow=battle --herc=tribes2:SHRIKE --map=tribes2:Caldera
E2E: drive samples: ["0.0m/s@(-222.2, 146.7, 239.2)", ... x6]   collides with tribes2_vehicle_pad
--flow=battle --herc=es2:OUTLAW --map=tribes2:Caldera --watch=30
E2E: drive samples: ["16.1m/s@...", "0.0m/s@(-232.5, 151.3, 245.4)" x5]  collides with tribes2_int_dvpad1
```
Shots: `qa\sk\t2_shrike\skirmish_02_battle.png`, `qa\bt\herc_t2_caldera\battle_03_chase.png`.

### 3. A battle can't be left mid-match  — FIXED
`menu_pause` (Esc / pad Start) opens `BattleMenu` (engine/ui/battle_menu.gd, page screens/pause_screen.gd),
the same in every game and mode: Resume, Options, Abort mission / Leave match (confirmed), Quit to
desktop (confirmed). Single player pauses the tree (menu layer `PROCESS_MODE_ALWAYS`); LAN does not
pause and the pilot's controls are held. The mouse is released while open and captured on Resume.
Abort mission = a failed mission with the campaign's own consequences (ES1: failure variant of the next
slot; ES2: next mission, a must-win loss ends the war; Starsiege: replay), documented in
games/es1/battle/battle_exit.gd. LAN: a client leaving is removed from the battle on every peer; the host
leaving ends the match and clients' launcher says "The host left the match."
Tests: battle_menu_check; e2e `pause`, `abort --game=es1|es2|starsiege`, `lan_* --leave=host|client`.
No battle script handles `menu_pause` / `menu_back` beyond releasing the mouse (player_pilot.gd:49).
There is no pause menu, abort mission or quit to menu. A player can only finish the match, die in a mission, or kill the
window. This also applies to gamepad-only players (Start just frees the mouse: `qa\pad\gamepad_05_start.png`).

---

## P2: wrong behaviour in a mode

### 4. Tribes 2 Beowulf mortar never fires (data) (FIXED)
**Fixed:** tools/export_tribes_vehicles.py derives a lifetime when the datablock has no lifetimeMS (GrenadeProjectile: 45-degree ballistic flight time x 1.5; mortar 6.89 s), gamedata regenerated. `Weapon.make_projectile` falls back to `LIFETIME_FROM_RANGE` for any null projectile number and warns once per weapon field. Tests: `qa_fix_check` and tribes_vehicle_check (mortar fires on fire_group_2); `--flow=skirmish --veh=tribes2:BEOWULF` clean.

`gamedata/tribes2/gameplay/weapons_engine.json` has `TANK_MORTAR.projectile.lifetime = null`.
`Weapon.make_projectile` runs `float(null)` on it (weapon.gd:241), and every shot fails:
```
SCRIPT ERROR: Invalid call. Nonexistent 'float' constructor.   at: make_projectile (res://games/es1/weapon.gd:241)
ERROR: Required object "rp_child" is null.                      at: _spawn_projectile (weapon.gd:223)
```
Repro: `--flow=skirmish --mapname=Abominable --veh=tribes2:BEOWULF` (the driver fires all weapons). No other weapon in any pack has a null projectile number.

### 5. Co-op campaign client uses its own single-player save  — FIXED
The launcher menu no longer loads the autosave (Continue campaign loads it when chosen). A joining
client clears its own campaign (`Session.clear_campaign`); the host publishes its campaign's garage
and mission Herc in the lobby settings (`MatchFlow.publish_campaign_offer`), and the client's lobby picks
only from that offer (GaragePicker without a Hangar button). Tests: campaign_save_check; e2e
`lan_join --mode=campaign` (client choices == host offer, no own campaign).
Opening `launcher_menu` calls `Session.load_campaign("autosave")` as a side effect. A LAN client that has a
single-player autosave therefore has `Session.has_campaign()`. After the first co-op campaign mission, its lobby shows a
GaragePicker for **its own** campaign and announces that Herc to the host. In the test, a Starsiege
"Mission Herc: Outrider Emancipator" appeared in an ES1 co-op campaign lobby.
Opening the menu also silently replaces whatever campaign was active in Session.
Repro: run `--flow=saga` (leaves a saga autosave), then `lan_host --mode=campaign` + `lan_join`.
Shot: `qa\coop\campaign\lan_join_06_end_client.png`.

### 6. Standalone ES2 / Starsiege campaign saves load as Earthsiege 1  — FIXED
Saves record the provider (`"pack"`, each campaign's `pack_id()`); loading restores it through
`Saga.PROVIDERS` (older saves are recognised by their fields). The launcher menu lists the saga plus
each game's own campaign (Earthsiege, Earthsiege 2, Starsiege Human / Cybrid; "(not installed)" when
missing). Tests: campaign_save_check; e2e `es2` / `starsiege_human` then `continue --expect_pack=`.
`Session.load_campaign()` handles a non-saga save with `Campaign.from_dict()`, which is the ES1 provider.
For an ES2 save, **Continue campaign** opens an empty briefing ("Campaign 1 - mission C1_03", no text or objectives).
Launching then logs `ERROR: MissionCompiler: mission C1_03 not found` and plays ES1 B0_C0_0A against Scorpions.
Repro: `--flow=es2`, then `--flow=continue`. Shot: `qa\continue_continue.png`.
Related gap: the UI has no entry for a standalone ES2 or Starsiege human/cybrid campaign. They are reachable only
through the saga or `--page=briefing:<game>`. "Campaign (single player)" always starts ES1.

### 7. Spawns too close on Tribes maps (FIXED)
**Fixed:** map spawns now go to the first free spawn at least `MIN_OPPONENT_SEPARATION` (150 m) from every opponent already placed, else the farthest; respawns pick a point away from the living vehicles (battle_spawner.gd). Remake addition: 3 s spawn protection in arena / versus (`SPAWN_PROTECTION_SECONDS`, not in missions), ended early when the vehicle fires. Test: `qa_fix_check` (Broadside nearest opponent 161 m, protection). Re-run `--flow=battle --map=tribes:Broadside`: 0 failures.

On tribes:Broadside, the player Raptor was "destroyed by Raptor" (AI) within 3 s of spawning. Both spawned on the
same pad cluster. Repro: `--flow=battle --herc=es1:RAPTOR --map=tribes:Broadside`. Shot: `qa\bt\herc_tribes\battle_01_start.png`.

### 8. Skirmish on arenas / pack maps never ends as described; no results screen  — FIXED
`BattleRules.make_objective_text` states the rule that really ends the match (frag limit wherever
vehicles respawn: versus, arenas, pack maps; "destroy all Cybrids" on ES1 worlds). Every match now ends
on `MatchResults` (headline / winner, time, per-pilot kills / deaths / score, a won mission's salvage;
Continue to the front end - launcher, debriefing, lobby or the original shell; Rematch for skirmish /
versus / co-op, on LAN by the host). Tests: battle_menu_check; e2e results in every flow.
- The skirmish intro says "destroy all Cybrids", but on Battledrome arenas and every pack map the map config
  forces `respawn: true`. Destroying every Cybrid does not end the match; they respawn until someone has 10 kills.
  On ES1 worlds the match ends correctly ("All Cybrids destroyed").
- No mode has a results or scoreboard screen. After the 10 s end message the launcher goes straight to the main
  menu (skirmish, versus) or the lobby (LAN).
Repro: `--flow=skirmish --mapname="arena - MED" --veh=bd:STRYDER`.

### 9. ES1 shell debriefing officer loses his head when the talk is skipped  — FIXED
C<c>_BLNK's set-up frame (loads + a wait, nothing drawn) showed the bare REGN5000 body for its wait
whenever MENU1520 opened; `TTMScene.apply_setup_frame` runs it at once. Test: shell_check.
Skipping the debriefing officer's talk with ui_accept leaves a headless body behind the DEBRIEFING panel (MENU1520).
When the talk plays to the end, the head is there.
Shots: `qa\es1_shell_14_debrief.png` (skipped) vs `qa\talk_D0_6s_window.png` (played through).

### 10. Black sky on some Starsiege maps
The sky is pure black on the Cybrid campaign CA0 and on DM_Avalanche (on the same run, HA0 and DM_Impact have skies).
Check against the originals. Shots: `qa\starsiege_cybrid_m1_05_battle.png`, `qa\sk\ss_apoc\skirmish_03_moving.png`.

### 11. Starsiege human HA0 message log prints bare "0" lines (FIXED)
**Fixed:** the "0"s were the ambient wind `say3D(0, %source, "", "sfx_windgust.wav", ...)` calls (missionStdLib.cs): `_say` read say3D's text from argument 1 (the source). Both say and say3D take the text at argument 2 (`SAY_TEXT_ARG`). Test: `qa_fix_check` (HA0 say vs ambient say3D).

Two lines containing only "0" appear above the TAC-COM text, probably a script say/echo of a number.
Shot: `qa\starsiege_human_m1_05_battle.png`.

---

## P3: polish

12. **HUD weapon list shows raw ids** for non-ES1 vehicles: `MOSQUITO_15 15`, `HATC 190`, `SHRIKE_BLASTER`, `TANK_MORTAR`. **Fixed:** the HUD shows the catalog `display_name` (ES1 keeps LAS100 etc.); the speed readout moved above THR. Test: `qa_fix_check`.
    The "0 KPH" readout overlaps the THR bar. Shot: `qa\sheet_02_battle.png`.
13. **FIXED** (Back says "Back to library" / "Back to original shell" by `Session.launcher_home`; Quit asks
    first) **Launcher back button says "Original shell"** when the launcher was opened from the library (it goes back to the library).
    The launcher's **Quit has no confirmation**, unlike the library's. Shot: `qa\library_09_launcher_menu.png`.
14. Library **"Arena / versus" opens the LAN host lobby**, not skirmish. Skirmish is in the launcher menu ("Skirmish").
15. **FIXED** (refused with "A PILOT NAMED ... IS ALREADY REGISTERED") **Duplicate ES1 career names** are accepted (two "QATEST" careers after two runs).
16. **FIXED** (`BindingContexts` + options dialog Swap / Clear / Cancel; keyboard listed before pad) **Rebinding allows conflicts**: throttle_stop could be bound to Z while Z is already a default binding of another action
    ("Z, Pad RS click"). There is no warning. Bindings are re-listed as "Pad LS click, Z" (pad first).
17. **FIXED** (Build defaults to the campaign's own first offered Herc) **Hangar Build picker defaults to Battledrome "Stryder (older design)"** in the ES2 and Starsiege human
    campaigns, not to the campaign's own Herc. Shot: `qa\es2_m1_03_built.png`.
18. **Mission heading numbering**: the ES1 campaign shows "Campaign 0 - mission B0_C0_0A", ES2 shows "Campaign 1".
19. **LAN match end on the host**: `SCRIPT ERROR: Cannot call method 'get_remote_sender_id' on a null value` at
    battle_net_sync.gd:57. A client input RPC arrives while the Battle is leaving the tree. Happens on every LAN match. **Fixed:** BattleNetSync drops RPCs once the battle is out of the tree (`is_receiving`). Test: `qa_fix_check`; LAN vs pair re-run: no error.
20. **Chase camera clips into buildings** and the view goes black: Apocalypse on DM_Avalanche, `qa\sk\ss_apoc\skirmish_05_chase.png`. **Fixed:** spring-arm sphere cast from the Herc to the camera (`BattleCameras.make_unobstructed_position`). Test: `qa_fix_check` (wall behind the Herc).
21. The HUD speed readout shows speed while the vehicle is blocked (48 KPH while stuck on the Caldera pad).
22. The ES1 cockpit marquee text is clipped at both ends ("ARE PILOTING: GUNSLINGER (ATC35, ATC3"). It may just be mid-scroll.
    Shot: `qa\es1_shell_11_battle.png`.
23. (The results screen now lists a won mission's salvage.) The debriefing doesn't list recovered salvage. Salvage *is* applied to the armory stock.
24. The ES1 shell main menu HANGAR button (1700) does nothing when no career is selected after a restart. The code
    intends to open CAREER (`_run_main`).

## Tooling / process

- **New `class_name` files break command-line runs until the class cache is refreshed.** TorsoRig, WeaponMount and
  WeaponLookalike were added during this pass. Until `.godot/global_script_class_cache.cfg` is regenerated, `herc.gd`
  fails to parse, Session/Packs fail to load, and battles start with 0 vehicles. I regenerated the cache twice with
  `"$G" --headless --path game --import`. Agents that add a class_name should run that before testing.
  Runs affected by this were repeated after the refresh.
- `LauncherAutomation` runs again on **every** Launcher instance. `--page=briefing:es2` starts a new campaign after each
  battle. `--autohost` hosts again after a match ("ERROR: Couldn't create an ENet host") and starts a second match.
  **Fixed:** the arguments are consumed by the first launcher of the process. Test: `qa_fix_check` (`res://tests/qa_fix_check.tscn -- --page=options`).

## Checked and working

- **Library:** pack toggles flip and persist, the jukebox plays and stops, options change master volume (persisted),
  rebind and reset-with-confirm work, the quit dialog's Cancel and Quit work, and Arena/versus leads to the launcher.
- **ES1 shell:**
  - Boot leads to MAIN.
  - New career: REGISTER, typed name, PROCEED (general and briefing talk), then the hub.
  - ARMING opens the Hangar screen: Build, arm and Scrap (with confirm) all work.
  - BEGIN MISSION: mission won by its own rules. The debrief (MENU1520) leads to the hub, then NEXT MISSION (B0_C0_1A) and a second battle.
  - The career is saved, and is listed and resumed after a restart.
- **Campaigns:**
  - ES2: two missions in a row (C1_01 to C1_03); salvage joins the armory stock and the chosen Herc is the one flown.
  - Starsiege human (HA0 to HA1) and cybrid (CA0 to CA1): briefing, hangar build, launch, debrief, continue.
- **Saga:** ES1 mission, then the ES1 garage carries into ES2, ES2 mission, Starsiege choice, Human, mission, then Save and quit, then Continue campaign resumes at Starsiege.
- **Skirmish via the armory:**
  - Played on ES1 world, BD arena, Tribes, Tribes 2 and Starsiege MP.
  - Vehicles: Herc, tank (Paladin), flyers (Banshee, Razor, Tribes Scout, Shrike on Abominable) and the Beowulf.
  - Every match returned to the launcher, and AI units fight in arena and Starsiege DM.
- **LAN (two processes, via the real UI):**
  - Host LAN game, mode, Create lobby; the client finds it by LAN discovery, joins and sets Ready.
  - Coop, versus (BD arena, FFA teams) and co-op campaign all start. Both sides spawn, see each other by name, and puppets move from snapshots.
  - The host sees the client's pad-RB fire triggers, a kill made on the host replicates to the client, the match ends, and both return to the lobby.
  - Co-op campaign (2026-10-10): the first ES1 mission (B0_C0_0A, mission type 2 "player group reached the end of its
    path", mission.md section 5) does not end when the enemies die, in the original or the remake. The e2e host
    expected it to and timed out: it now also walks the remaining nav points (`visit_remaining_navs`), then the
    mission ends on its own ("MISSION SUCCESSFUL"), and the host passes the campaign debriefing before the lobby.
    The runtime was right; `lan_host --mode=campaign` + `lan_join --mode=campaign` both pass with 0 failures.
- **Gamepad only:** d-pad (39 presses) to "Arena / versus", A, then B to the menu, Skirmish, Start skirmish. In battle, RT drives, the left stick turns and RB fires.
- **Existing suites:** ui_nav, input, saga, garage, hangar, availability, es2_mission, tribes_vehicle, weapon_fit,
  flight and animation_check all pass, and compile_all reports 182 scripts with 0 failures.
