# Mechanics unification: one set of mission building blocks

Every game keeps its original behaviour (timings, messages, win and fail rules), but they all run on one set of
mission primitives, the way rendering was unified (`docs/RENDER_UNIFICATION.md`). The rule is in
`docs/CODING_STANDARDS.md` section 4. Phase 1 covers missions and campaigns; phase 2 (section 5) covers damage,
sensors, targeting and AI. Paths are relative to `game/`; line numbers are approximate (audit of 2026-10-18).

## 0. What exists today

`engine/mission_runtime_base.gd` (`MissionRuntimeBase`) is already the shared contract the Battle uses: setup,
spawn_units, on_unit_destroyed, make_objective_lines, make_rules_step, end_mission and the end hooks.
`engine/mission_kinds.gd` picks the runtime per game, and `engine/mission_outcome.gd` is the result shape. Below that
contract everything is per game: timers, area tests, objective evaluation, messages, end grace and spawn triggers.

Open points:
- **Layering (done in C13):** `engine/mission_kinds.gd` holds a registry; the games register in `games/games_boot.gd` (autoload `GamesBoot`).
- **AA timing (fixed 2026-10-18):** `AAMissionRuntime._physics_process` passed the frame delta, not the accumulated rules dt, to the
  script and arena steps. Script timers therefore ran at about a quarter of real time. It now passes the rules step.

## 1. Inventory

| Mechanic | Where (game: file) | Notes |
|---|---|---|
| Rules tick | ES1 `es1/mission_runtime.gd`, ES2 `es1/mission_runtime_es2.gd`, SS `starsiege/starsiege_mission_runtime.gd`, Tribes `tribes/tribes_mission_runtime.gd`, AA `tribes_aa/aa_mission_runtime.gd`, TV `tribes_v/tv_mission_runtime.gd`, extraction `extraction_director.gd` + `site_spawner.gd`, modes `game_mode_director.gd` | Most use `make_rules_step`; extraction and the game modes hand-roll `_tick_t` style accumulators |
| Timers | ES2 region-armed countdowns; SS `schedule(code, s)`; Tribes `tribes_schedules.gd` (absolute time, ids); AA named timers in `aa_script_vm.gd` (accumulate while a condition holds); TV `Task.wait` + countdown; extraction reinforcement timers; game-mode time limit; AA survive 300 s and arena respawns; BD `arena_announcer.gd`; T1 respawn; SS 8 s death debrief | 7 implementations, 3 semantics: one-shot, accumulate-while, absolute time |
| Areas, waypoints | ES1 regions (circle/box, 30 m minimum) and nav reach 40 m; ES2 regions; SS `ss_sensors.gd` boxes (enter/contact/leave, 20 m height slack); TV cylinders (2.5 m slack, max_enter); AA waypoints 15 m, `_near_tag`, switch/board radii; Tribes `on_trigger`/`on_mission_area`; game-mode touch; extraction `raid_tasks.gd` BASE_REACH, `exit_safety.gd` | 7 point-in-area tests |
| Destroy | ES1 `es1/mission/es1_win_rules.gd`; ES2 `es1/mission/es2_objectives.gd`; SS script status; AA generators; extraction raid tasks; `defend_destroy_rules.gd` | |
| Protect, escort | ES1 protect/escort; ES2; SS and Tribes via script | |
| Reach, nav | ES1 nav; AA waypoints; TV markers; SS `refresh_nav`; Tribes `tribes_mission_output.gd` | |
| Datalink, recon, scan | ES1 datalink (stages [5000, 5000, -25536, 0] ms + texts, abort), recon; ES2 scan (4 s, 60 m, 45 degree cone); SS scan (2 s, 600 m) | 3 scan-for-N-seconds implementations |
| Survive, score | AA survive and arena score; game-mode score/time limits; BD frag limit and coop end in `battle_rules.gd` | |
| Script-state objectives | SS `MissionBriefObjective`; T2 HUD lines; TV `on_objective` (0 add, 1 done, 2 failed, 3 removed); AA `vm_objective` | |
| Objective panel | 10 `make_objective_lines` implementations, all returning `[{text, done}]` | |
| Waves, spawns | ES1 dormant groups woken by regions; ES2 `ARRIVALS` table; SS `ss_unit_director.gd`; AA waves and arena respawn; TV NPCs by distance (170 m, 4 per tick); T1 `create_ai`; extraction batches, patrols, raids; game-mode defenders | 5+ ways to say "spawn this group now" |
| Fail rules | ES1 player dead / left map (4.9 s grace) / guarded lost; ES2 status 6/7/8 + 4.9 s grace; SS and Tribes `debrief`; AA `vm.fail`; TV `on_fail`; game-mode limits; extraction `_check_end` | |
| Messages, voice | ES1/ES2 `battle.fx("message")` (ES2 queue with a first-message delay); SS `say` to `battle.radio`; Tribes text+voice pairing; AA voice queue (a newer waiting prompt replaces an older one; closing prompt cuts); TV speak returns its duration and the script waits; BD timed voices; game-mode announce | 5 queue disciplines |
| Mission end | `MissionRuntimeBase.end_mission` is shared (good); grace/delay logic is per game (ES1 left-map, ES2 countdown, AA voice-wait up to 15 s + 2 s, SS 8 s, extraction end_delay_s) | |
| Mission variables | ES1 and ES2 `_var_op` with different op tables | |
| Script engines | SS `ss_script.gd`, Tribes `engine/script/darkstar_script.gd` (real languages, stay interpreters); AA `aa_script_vm.gd` (JSON state machine); TV `tv_script_run.gd` (JSON task runner) | |

Repeated constants: the ES1/ES2 detect and safe ranges (50000/80000/100000 units), the 45 degree datalink/scan cone, the
4.9 s end grace, and `CODE_SUCCESS`/`CODE_FAILED` in SS, Tribes, AA and TV.

## 2. Shared API: `engine/mission/`

No game class names inside `engine/mission/`. The repo style applies: `class_name`, `##` docs, `make_`/`apply_`/`is_`,
named consts with evidence. All classes are `RefCounted` (testable without a scene tree), and each file stays under 300 lines.

- **Contract (C0):**
  - `MissionWorld`: what blocks may ask of the battle (living players, player position, target nodes, is_target_destroyed, is_unit_alive, out-of-area seconds, sink).
  - `MissionSink`: the output port: apply_message, apply_voice, apply_objectives_changed, apply_nav, is_voice_playing.
  - `MissionVerdict`: success, code, text, delay, wait_for_voice; `make_win` / `make_loss`.
  - `MissionClock`: elapsed and `make_step(delta, interval)` (the body of `make_rules_step`).
- **Timers (C1):**
  - `MissionTimer`: modes ONE_SHOT, REPEATING and WHILE; armed flag; payload; apply_tick returns true when it runs out.
  - `MissionTimers`: add, cancel, is_pending, make_time_left, apply_tick returns the fired payloads in order, and apply_advance fast-forwards for cut-scenes.
  - `TribesSchedules` becomes a thin wrapper over these and keeps its API.
- **Areas (C1):**
  - `AreaShape`: circle (with a minimum radius), box (with height slack) or cylinder (with slack).
  - `AreaTrigger`: entered, contact and left signals; a filter callable; max_enter; one_shot; apply_scan (edge detection); is_occupied.
  - `WaypointChain`: ordered reach list with a reach radius and an index.
- **Vars (C1):** `MissionVars`: an interpreter over named op tables (the tables themselves are data owned by the ES adapters).
- **Objectives (C3):**
  - `Objective` base: id, text, required, primary, state (PENDING, ACTIVE, DONE, FAILED, AT_RISK), apply_tick, make_line.
  - `ObjectiveSet`: is_complete, has_failed, make_lines.
  - Kinds in `engine/mission/objectives/`: Destroy, KillCount, Protect, Reach, Escort, Scan (stages of {seconds, text}, range, cone, abort text), Survive, Score, Carry, Script (state set from outside).
- **Fail rules (C3):**
  - `FailRule.make_verdict(world, dt)` returns a verdict and never ends the mission itself.
  - Rules: PlayerKilled(delay), LeftArea(grace), ProtectedLost, TimeLimit, ObjectiveHit, Stalemate.
- **Messages (C2):**
  - `MissionMessage`: text, seconds, channel, speaker, voice.
  - `MissionVoice`: id, interrupt.
  - `MissionAnnouncer`: disciplines REPLACE_WAITING (AA), FIFO with first_delay (ES2) and CUT; make_busy_seconds (TV waits on it); is_idle.
  - Battle adapter: `games/es1/battle/battle_mission_sink.gd`.
- **End (C2):**
  - `MissionEnder`: the first verdict wins. It owns the grace and the wait for voice (max 15 s), and makes the one call to `end_mission`.
  - `MissionRuntimeBase.end_mission` and `MissionOutcome` are unchanged (saves and LAN carry them).
- **Waves (C3):**
  - `SpawnWave`: group, trigger ("start", "region:id", "timer:id" or "script:action"), arrival, count, repeat_every.
  - `WaveDirector`: takes the game's spawn callable; apply_trigger, apply_tick, is_group_wiped_out.
  - The spawning itself stays game-specific.
- **Script core (C4):**
  - `MissionScript`: a data state machine generalised from `AAScriptVM`. Built-in conditions: time, timer, flag, counter, and/or/not, comparisons. Built-in actions: state, flag, unflag, reset, min_time, add, success, fail, prompt, audio, objective, info, error.
  - `MissionScriptHost`: games register their own conditions and actions.
  - `MissionTask`: the sequential executor from `TVScriptRun` (wait, child, loop, if); `["run", label]` starts one.
  - SS and Tribes stay real interpreters, but their engine functions are re-pointed at the shared blocks.
- **Composition:**
  - `MissionKit` holds clock, timers, triggers, objectives, fail rules, waves, announcer, ender, script and vars.
  - Its `apply_tick` runs in a fixed order: timers, triggers, script, objectives, fail rules, announcer, ender.

## 3. Per-game adapters

Parity rule: each adapter starts with a recorded golden trace of the current code (time, event, text, code). It is
done only when the trace matches, with times within one rules tick. Original constants stay as named consts next to
their data.

- **ES1:**
  - Regions become one-shot AreaTriggers, with the 30 m minimum and the type filter.
  - `objective_met` becomes a factory per mission type. Datalink is a ScanObjective with the original stages, the -25536 wrap kept with its evidence comment.
  - The `_check_end` order becomes ordered fail rules plus the win condition.
- **ES2:**
  - Region-armed MissionTimers; FIFO announcer with the first-message delay.
  - Statuses stay as a function over ObjectiveSet; the 4.9 s grace goes into MissionEnder with LeftArea.
  - `ARRIVALS` becomes the SpawnWave arrival table.
- **Starsiege:**
  - `schedule` becomes MissionTimers (script code as the payload); sensor boxes become AreaTriggers mapped to onenter, oncontact and onleave.
  - `check_scan` becomes a ScanObjective (600 m, 2 s); the 8 s death debrief becomes PlayerKilled(8).
  - `say` goes through the announcer; `MissionBriefObjective` becomes a ScriptObjective.
- **Tribes 1/2:**
  - TribesSchedules sits over MissionTimers; trigger geometry uses AreaTrigger.
  - Objective lines become ScriptObjective; the output goes through the announcer plus apply_nav.
  - `debrief` goes through the Ender; the respawn and task loops become repeating timers.
- **Aerial Assault:**
  - `AAScriptVM` becomes a shim of MissionScript plus an AA host; the logic.json format is unchanged.
  - The goals map to Destroy, Reach, Survive and Score objectives.
  - The ending goes to MissionEnder (voice wait); the voice queue goes to the REPLACE_WAITING announcer.
- **Vengeance** (after AA, since it extends AA):
  - The task executor moves to MissionTask, and the `on_*` hooks become registered actions.
  - Triggers become cylinders; the countdown becomes a MissionTimer plus TimeLimit; objectives become ScriptObjective.
  - Speak returns the announcer's busy seconds.
- **Battledrome:** the timed end voices go into an announcer list; the frag limit and coop end become Score and a loss verdict.
- **Game modes:** time and score limits use MissionTimer, ScoreObjective and MissionVerdict; announce goes through the announcer.
- **Extraction:**
  - SiteSpawner timers use MissionTimers, and batches use WaveDirector with repeat_every.
  - Raid tasks map to KillCount, Destroy and Carry; `_check_end` goes to MissionEnder. Payout and network sync are unchanged.

## 4. Migration plan

| Chunk | Touches | Protected by | Depends on |
|---|---|---|---|
| C0 contract | new `engine/mission/` world, sink, verdict, clock; `tests/mission_core_check` | compile_all | - |
| G1-G7 golden traces | new `tests/trace_{es1,es2,ss,tribes,aa,tv,modes_extraction}_check` | existing game checks | - |
| C1 timers, areas, vars | new files + `tests/mission_timers_check` | that check | C0 |
| C2 messages, end | new files + `tests/mission_messages_check` | that check | C0 |
| C3 objectives, fail rules, waves | new files + `tests/mission_objectives_check` | that check | C0 |
| C4 script core | new files + `tests/mission_script_check` (AA fixtures vs AAScriptVM) | that check, aa_script_check | C0 |
| A5 AA | `games/tribes_aa/aa_script_vm.gd`, `aa_mission_runtime.gd`, new `aa_script_host.gd` | aa_script/campaign/bounds checks, trace_aa | C1-C4 |
| A6 TV | `games/tribes_v/tv_script_run.gd`, `tv_mission_runtime.gd`, new host | tv checks, trace_tv | A5 |
| A7 ES1 | `games/es1/mission_runtime.gd`, `mission/es1_win_rules.gd`, new battle sink | es1_mission_end_check, campaign checks, standardization_check, trace_es1 | C1-C3 |
| A8 ES2 | `mission_runtime_es2.gd`, `mission/es2_objectives.gd`, `es2_command_radio.gd` | es2_mission_check, trace_es2 | A7 |
| A9 Starsiege | `starsiege_mission_runtime.gd`, `ss_engine_functions.gd`, `ss_sensors.gd` | starsiege tests, trace_ss | C1-C3 |
| A10 Tribes | `tribes_mission_runtime.gd`, `tribes_schedules.gd`, `tribes_mission_output.gd`, `tribes1/2_mission_runtime.gd` | tribes checks, trace_tribes | C1-C3 |
| A11 modes + BD | `engine/game_modes/game_mode_rules.gd`, `games/es1/battle/battle_rules.gd`, `games/bd/arena_announcer.gd` | game_modes checks, bd_voices_check | C1-C3 |
| A12 extraction | `site_spawner.gd`, `raid_tasks.gd`, `extraction_director.gd` (`_check_end`) | extraction_check, varuna_check | C1-C3 |
| C13 hoist | `mission_runtime_base.gd` (kit + default tick), `mission_kinds.gd` (registry), dead code, docs | full suite | all adapters |

Parallelism:
- Wave 0: C0 + G1-G7.
- Wave 1: C1-C4.
- Wave 2: A5, A7, A9, A10, A11 and A12 together. A6 follows A5, and A8 follows A7.
- Wave 3: C13 alone.

The old path is deleted in the same chunk once its trace passes.

## 5. Phase 2: other mechanics

Same method for each: golden trace, then a shared primitive in `engine/`, then per-game adapters.

- **Targeting (done 2026-10-22):**
  - `engine/targeting/target_selector.gd` (`TargetSelector.pick` / `keeps` / `is_live` / `is_hostile_live`) is the one AI target choice: native
    distance prefilter over the "vehicles" group, hostility (TeamRelations, or the profile's rule), strict range, cloak and radar
    visibility (`CloakRules`, `InfantryPack` jam radius, `RadarMode` signature), optional arc / line-of-sight veto tried nearest first,
    stickiness (`keeps`). `TargetProfile` is the per-game data: range, visibility mode, signature weighting, keep buffer, think period.
  - Profiles, each keeping its original rule: ES1 `AIPilot` (radar visibility, passive units seen from half as far, range by order: sensor_range,
    0.6x on GUARD, unlimited on SEARCH); soldier bots (`InfantryBot`, Tribes 2 ai.cs AIFindClosestEnemy: eyes, jam radius, cloak reveal range 8 m;
    `TribesBot._make_order_target` picks the reach: INF for ENGAGE, 60 m on hold); Tribes turrets (datablock range and sensor, 0.2 s think,
    arc + LOS veto); Starsiege turrets (SSTeams, `engage_range` held to `+ deactivate_buffer`, datablock check_interval); Battledrome turret (side as team).
  - Deleted: `TurretTargeting`, the `AIPilot` / `InfantryBot` search loops, the turret `is_hostile` lambdas, `WingmanRadio._is_hostile_alive`.
    `Targeting` (the player's T / C keys) shares `TargetSelector.is_live` for its candidates; its cone and cycling scoring is player UI and stays.
  - Candidates come from the "vehicles" group, not EntityTable / InterestGrid cells: those exist on the network server only and carry no
    dormant / stowed / cloak state. Swapping the candidate source is one function (the loop in `pick`) when the cells grow those flags.
  - Test: `tests/target_selector_check` (seeded layout against a brute-force reference, then each rule).
- **Sensors (done 2026-10-23):**
  - `engine/sensors/` holds the one detection code: `SensorSource` (range, view cone, line of sight, jams / detects-jammed / detects-cloaked + minimum
    speed; parsed from the Tribes `sensor` / `player_sensor` data blocks), `ContactTable` (per-team detected set with last-seen times;
    team-shared reveals: the call-in sweep `apply_swept` and the com tower reach; the script-hidden mark), `SensorProfile` (per-game data: alert
    range, safe ranges, scan range / cone / time, tower reach, passive-radar shares, the soldiers' own sensor), `ProximityAlert` (ES1/ES2
    "noticed" and "unsafe"), plus the moved `RadarContacts`, `RadarMode`, `SensorTowers`, `SensorLink`, `LineOfSight`.
  - Profiles: `EsSensorProfile` (DBSIM 0xf744 / 0x4137b4 detect 195 m, safe 312 / 390 m; ES2 scan 60 m +20 m structure, 45 degrees, 4 s), `SSSensors.make_profile`
    (scan 600 m, 2 s, remake approximation), Tribes = the pack's base_equipment.json blocks through `SensorSource.make_from_spec`; the remake defaults
    (tower 1500 m, passive 0.34 / 0.5) are `SensorProfile.DEFAULT_*`.
  - Deleted: `EsRanges`, `MissionTargets.is_noticed`, the duplicated `is_safe` range test of ES1 / ES2 (the order-target rule of ES1 stays in `Es1WinRules`),
    `TribesSensorNet._senses` / `_soldier_sees` / `_has_sight` (now `SensorSource.senses`), the sweep / hidden metas of `RadarContacts`, `SCAN_*` consts.
    `TargetSelector` RADAR visibility reads `ContactTable.is_swept`; `RadarContacts` reads `ContactTable` for hidden / swept / tower reveals.
  - Left as is: `tribes_contacts.gd` is trigger / item touch (the player's soldier touching things), not detection; `CloakRules` stays in `engine/stealth` (the
    cloak-side half of the same rules, called by `SensorSource`); `BotSleep` / `InterestProbes` keep their per-step tower cache (`SensorTowers.begin_cache`).
  - Known change: a base sensor's range is now measured from its eye (1 m up), as a soldier's always was.
  - Test: `tests/sensors_check` (source, table, alert), plus cloak / scope / command_map / bot_lod / tribes_base / callin checks.
- **AI orders (done 2026-10-23):**
  - `engine/ai/ai_order.gd` (`AIOrder`: kind, target, point, radius, urgent, hold, formation slot, path/loop, tag/source) is the one order. Command kinds
    (attack, move, defend, hold, escort, formation, regroup) become the brains' `objective` dictionary through `to_objective()` (`InfantryBot` and
    `AIPilot` still read that dictionary); pilot kinds (search, guard, patrol, travel, sleep, ram) are set on an `AIPilot` by `apply_to_pilot()`.
    `engine/ai/order_queue.gd` (`OrderQueue`) is a group's order list. `engine/ai/formation.gd` (`Formation`) holds the slot offsets.
  - Routed through it: the command map (`CommandOrders.make_ai_order`; `CommandGoal` keeps the done/failed rules and its kind names are `AIOrder`'s),
    game-mode goals (`GameModeBrains.make_objective`), ES2 group order lists (`ES2GroupOrders`: a queue of `AIOrder` per group, the record as `source`
    for its DBSIM completion rule), Starsiege `order()` (`SSUnitDirector`: attack, guard, travel, hold position, formation), AA `vm_order`
    (`AIOrder` per soldier, resolved each refresh) and the Tribes training bots (`TribesBot.apply_order`).
  - Formations, each keeping its original: Earthsiege 1/2 `formations.json` (ES2 clamps the formation and fans out-of-table Herc slots 30 m), Starsiege
    `newFormation` (first triple = leader slot; 12 x 16 m steps beyond the list; 15 x 20 m for the player's wingmen), the player squad's start slots
    (25 m, `Formation.squad_slot`), the command map's rows of three (remake addition, `Formation.rows_slot`).
  - Deleted: the three `_formation_offset` / `_slot_vector` table copies, `MissionRuntimeBase.squad_slot_offset` and `SQUAD_SPACING`, the SS formation
    arrays and step, the command provider's slot arithmetic, `ES2GroupOrders.group_order` / `make_ai_settings`, AA `ORDER_META` dictionaries.
  - Not moved: `InfantryBot` target search and REPAIR task; the Tribes 2 marker table in `game_mode_ai.gd` (it produces goals, which now convert through
    `AIOrder`); `AIPilot.order_from_original` (the ES1 spawn-info code); `SSFlyerOrders`.
- **Additive animations (done 2026-10-23):**
  - `engine/infantry/infantry_animation_layers.gd` (`InfantryAnimationLayers`, driven by `InfantryAnimation.apply_layers`) composes the look, head and recoil layers onto the base locomotion pose: arm sequence and head scrubbed by the look pitch, `headside` by the head yaw off the body, recoil once per shot. Keys are sampled once per (sequence, 1/64 cycle) and cached; nodes a layer moves that the base sequence does not key are restored first, so deltas never accumulate. `ShapeCycles.make_node_transforms` reads keys without posing.
  - Per-game data in `InfantryLayerSpec`: Tribes 1 "looks" (a pose, replaces the nodes it keys); Tribes 2 `look` / `lookms` (missile launcher) / `looksn` (laser rifle) / `looknw` (unarmed), `head`, `headside`, `light_recoil` for the spinfusor, grenade launcher, missile launcher, mortar and plasma only (weapons.cs, weapons/*.cs stateRecoil / armThread; Torque blend keys are identity-neutral deltas); Aerial Assault `look` / `lookms` / `looksn`, `head`, `headside`, `recoil` (rest pose with the delta composed on top, tools/aa_soldier.py). Vengeance skeletons carry no such sequences: no layers.
  - Assumptions to revisit: Aerial Assault's missile launcher uses `looksn` and every AA weapon recoils (no AA scripts to cite); the sequences run over the soldier's +-80 degree pitch (Torque +-1.4 rad); the head yaw is 0 because the remake's body turns with the aim; Tribes 1 `looks` is scrubbed like the Torque ones.
  - MID / FAR bots (`far_lod`) skip the layers. Test: `tests/infantry_additive_check` (head and arm bone turn up vs down against the sequence keys, hold, recoil, FAR skip); windowed `tests/infantry_additive_shots`.
- **Damage:**
  - Sources: the `apply_hit` copies in `es1/structure.gd`, `ss_structure.gd`, `tribes_base_object.gd`, `bd/arena_turret.gd`, `infantry.gd`, plus scripted damage in the Tribes, SS, TV and AA runtimes.
  - Becomes `DamageTarget` + `DamageEvent`. Damage goes last, because it crosses networking and killcam.
- **Later:** the SSScript and DarkstarScript lexer/parser share a shape.

Phase 2 order: targeting, sensors, orders, damage.

## 6. Final state (C13, 2026-10-19)

All games run on `engine/mission/`: ES1, ES2, Starsiege, Tribes 1/2, Aerial Assault, Vengeance, the match modes with
Battledrome, and extraction. Golden traces (`tests/trace_*_check`) hold and are never re-recorded.

**Shared**
- `MissionKit` (`engine/mission/mission_kit.gd`): clock, timers, triggers, objectives, fail rules, waves, announcer, ender, script, vars.
  `apply_tick(world, delta, dt)` runs timers, triggers, script, waves, objectives, fail rules, announcer, ender, in that order.
- `MissionRuntimeBase` owns `var kit`. `make_rules_step` is `kit.clock.make_step`. `apply_kit_tick` and the default `_physics_process`
  (with `make_world` and `make_rules_interval`) are the default tick. ES1, ES2, Starsiege, Tribes and Aerial Assault read their
  clock, timers, announcer, ender, fail rules, objectives and vars from `kit` and no longer wire their own copies.
- `MissionKinds` is a registry (`register`, `register_default`, `clear`); `games/games_boot.gd` registers every game in claim
  order (Tribes 2, Tribes 1, ES2, Vengeance, Aerial Assault, Starsiege; ES1 is the default). `engine/` names no game class here.
- `CODE_SUCCESS` (1) and `CODE_FAILED` (6) live once in `MissionRuntimeBase`; the Starsiege, Tribes and Aerial Assault copies are gone.
- Dead code removed: `MissionTimer.apply_restart`.

**Each adapter keeps**
- The original rules and data: ES1 region/win/fail-rule list and var op table, ES2 objectives/arrivals/status table and its
  second (briefing) announcer and two var tables, Starsiege and Tribes script interpreters and engine functions, AA logic.json
  host, Vengeance task host and its own speech announcer, the game-mode and extraction directors' own tick loops.
- Their own `_physics_process` (each game's tick has different physics-step versus rules-step needs); the area scans stay with the
  game because the candidates come from its own battle.

**Open notes** (from `USER_TODO.md`, "Found 2026-10-19")
- ES2 scan cone uses the signed `Vector2.angle_to`, so a target on the negative side always passes (kept for trace parity; check the original).
- ES2 status 7 to 8 does not restart the 4.9 s grace on one LeftAreaRule path (no trace mission covers it).
- Starsiege player-death debrief can land up to 0.25 s off the old frame-exact time.
- The AA trace covers one mission end; add a scripted closing-prompt ending.
- Not yet on the kit: `MissionKit.triggers`/`waves`/`mission_script` are filled by no runtime yet (games still own those instances).
