# Cross-game standardization audit (playtest item C1)

Scope: how each game's runtime handles weapons, world objects, physics, lighting, wingmen/AI and radio,
briefings/debriefings and mission success/failure, where code is duplicated or diverges, and the shared
abstraction proposed for each. The goal is to standardize the code, not the behaviour: every game keeps
reproducing its own original data (docs/formats/*.md).

Paths are relative to `game/`. Risk: L / M / H. Size: S (< 100 lines touched), M (100-300), L (> 300).
Status: DONE (landed, tests listed in section 9), OPEN (proposed), HOT (waits for the agent that owns the files).

All games run inside one `Battle` (`games/es1/battle.gd`). Every vehicle is a `Herc`, every weapon a `Weapon`,
and every mission a `MissionRuntime` subclass. So "per game" usually means per-game data or a small subclass on
top of the Earthsiege 1 code, not separate engines.

---

## 1. Weapons and projectiles

| Game | Where | What | Distance from the original |
|---|---|---|---|
| ES1 | `engine/weapons/weapon.gd` (moved from games/es1; fire, capacitor, reload, bursts), `engine/weapons/projectile.gd` (ray-stepped, gravity, homing, ECM, splash), `missile_steering.gd`, `mine_runner.gd`/`mine_body.gd`, `self_destruct_charge.gd`; hits in `herc.gd:428` + `herc_damage.gd`; data from `engine/pack_weapon_loader.gd` | Shield banks first, then a component | gameplay.md section 5: splash should go to the *same* Herc's nearby components (A*splash/1024, radius 500u), the code splashes *other* vehicles (`projectile.gd:202`); component pick is random by height, not COL spheres (`herc_damage.gd:71`); extra death at integrity < 0.15 (`herc_damage.gd:110`); weapon knock-out and overflow cascade missing; EMP drains instead of switching shields off for 2.93 s (`weapon.gd:327`) |
| ES2 | same code, `es2:` weapon data | | es2.md section 9: ELF should tick per frame; EMP2 second bolt depends on the export's `burst` |
| BD | Herc weapons as ES1; `games/bd/arena_turret.gd` | Turret: fixed hp/refire, nearest Herc | bd_weapons.md 2/4: per-class shield rules, 3/4 + 1/4 damage spread, missile cruise/seeker/fuse, mine rear ejection (`weapon.gd:220` drops them), plasma decay: all missing. Turret ignores sides (`arena_turret.gd:65`) |
| Starsiege | `ss_turret.gd`, `ss_turret_gun.gd` (wraps a `Weapon`) | Head turn, arcs, rearm | Turret beams skip `DamageTypes` (`ss_turret_gun.gd:102`) |
| Tribes 1/2 | `engine/infantry/infantry_weapon.gd` (extends `Weapon`), `thrown_item.gd`, `tribes_turret*.gd`, `engine/occupancy/turret_crew.gd` | Energy weapons, grenades, turrets | Vehicles take hits as Hercs, so Tribes damage-type scales skip them; no splash kick from projectiles; client fx copies lose `inherit_velocity` (`battle_fx.gd:83`); turret beams pass no surface, so no impact fx (`tribes_turret_gun.gd:88`) |

| # | Duplication | Proposed shared code | Risk / size | Status |
|---|---|---|---|---|
| W1 | Instant beam (ray, fx, damage) x4: `weapon.gd:235`, `ss_turret_gun.gd:93`, `tribes_turret_gun.gd:80`, `arena_turret.gd:97` | `engine/weapons/weapon_shot.gd` `WeaponShot.fire_beam(shot)`: typed hit (Starsiege turret beams now typed too) and the impact surface always (Tribes turret beams had none) | L / S | DONE (the BD no-catalog fallback beam keeps its data-less path) |
| W2 | Projectile spawn + fx message x5 | `WeaponShot.launch_projectile(shot)`; the client copy (`battle_fx.gd:83`) still has no shooter | L / S | DONE |
| W3 | Turret brain x3 (`ss_turret.gd`, `tribes_turret.gd`, `arena_turret.gd`) | `engine/targeting/target_selector.gd` `TargetSelector.pick` / `is_live` (was `TurretTargeting`); each turret plugs in its hostility, aim point and arc / sight tests. Head turning stays per game | M / M | DONE (targeting) |
| W4 | Splash/blast x4 | `engine/weapons/blast.gd` `Blast` (unit radius damage with Tribes push; Earthsiege 0x13a7c component hits): projectile splash, ThrownItem, EsDamageModel, SelfDestructCharge, ramming | M / M | DONE |
| W5 | Damage receivers and the per-game hit rules | `engine/weapons/damage_model.gd` `DamageModel` + `EsDamageModel` (COL-sphere pick, in-unit splash, EMP shields off for the shield-down time) + `BdDamageModel` (class shield rules); weapon hits carry their weapon (`Herc.apply_weapon_hit`). Open: system overflow, weapon knock-out, Tribes vehicle damage scales | H / L | DONE (main) |
| W6 | Ammo / energy / rearm x4 | `Weapon.spend_shot` shared by vehicle weapons and Starsiege turret guns; Tribes energy and infantry stations keep their own | L / S | DONE (shots) |
| W7 | Temporary `Weapon` built only to read a colour (`weapon.gd:302`, `tribes_turret_gun.gd:86`); two fallback speeds (400 for the lead calculation, 300 for the flight) | static `Weapon.make_color(def)`; `DEFAULT_PROJECTILE_SPEED` for both | L / S | DONE |
| W8 | `Weapon`/`Projectile` lived in `games/es1` but serve every game | moved to `engine/weapons/` (class names and uids kept) | L / S | DONE |

## 2. World objects and structures

| Game | Where | Distance from the original |
|---|---|---|
| ES1/ES2 | `games/es1/structure.gd` (`Structure`, base of all below), `world_builder*.gd`, `mission_runtime*.gd` | world.md 7: Herc footing should use the grid bilinear height, the remake uses mesh triangles; mission.md:190 health thresholds 0..80 reduced to ruined / scaled hp (`structure.gd:84`). **Bug:** a destroyed structure keeps full-size collision, only the visual is squashed (`structure.gd:122`) |
| BD | `games/bd/arena_builder.gd`, `arena_turret.gd` | battledrome.md: turrets have a side and a wreck shape (TURHLK); the remake hides the turret and keeps its collision; not a `Structure`, so not targetable or synced |
| Starsiege | `ss_scenery.gd`, `ss_structure.gd`, `ss_turret*.gd`, `ss_fire.gd` | Close to starsiege.md 8 (damage block, burn) |
| Tribes | `tribes_base*.gd`, `tribes_turret*.gd`, `tribes_power_grid.gd`, movers | Closest to the data; inherits the kept-collision bug |

| # | Duplication | Proposed | Risk / size | Status |
|---|---|---|---|---|
| O1 | Trimesh collision from a shape x4, AABB x3, body construction x3 (`structure.gd:34-60,141`, `ss_structure.gd:34-86,122`, `tribes_base_object.gd:56-124`, `world_builder.gd:196`) | `engine/world/shape_body.gd` static helpers | L / S | HOT (B) |
| O2 | Wreck handling per game | `Structure.build_collision` (ruins collide flattened); BD turret shows its TURHLK wreck (arena turret_shapes "destroyed"); BD start pads alternate sides (SIM 0x2AC74) | L / S | DONE |

## 3. Physics

| Area | Where | Notes |
|---|---|---|
| Ground vehicles | `herc.gd:396 _drive`, `GRAVITY 9.8` (`herc.gd:17`) | units.md 2-3: ES1 movement is animation-driven, no gravity; Tribes vehicles should fall at 20 m/s2 (tribes.md 4); T2 hover height not simulated |
| Flyers | `engine/flight/*`, `flyer.gd` | Jet model follows flight_model.md 1.3; hard-landing damage is a remake addition |
| Infantry | `engine/infantry/infantry.gd`, `infantry_motion.gd` | Tribes gravity 20, jets, fall damage per tribes_infantry.md 2 |
| Collisions | `engine/collision_damage.gd` | Uses mean falloff 0.5 "components carry no positions", but `Herc.make_component_position` now exists: the real 1 - d/1200u falloff is possible |
| Gravity data | map field `gravity` (map_schema.md:37) | read by no code |

| # | Duplication | Proposed | Risk / size | Status |
|---|---|---|---|---|
| P1 | Ground plane x4, ground height x3, gravity constants x5, death fall x3 | `engine/physics/world_physics.gd` `WorldPhysics.gravity_of_pack` from each pack's units.json (Tribes vehicles now fall at 20 m/s2, the rest 9.8); ground and death-fall copies still open | M / M | PART |
| P2 | Impact damage x3 | ramming uses the real 0x13a7c falloff over 1200 units from the contact point (Blast; the mean only for units without component positions); fall / hard-landing rules unchanged | M / M | PART |
| P3 | One `_drive` for every game | `GroundLocomotion` profile per game | H / L | OPEN |

## 4. Lighting

| Game | Where | Distance from the original |
|---|---|---|
| ES1 | `world_builder.gd:35-75`, `engine/palette.gd`, `engine/shaders/indexed|shaded|ground.gdshader` | world.md 4 shading matches. Mismatches: textures get Godot fog although world.md:154 says textures get no haze (`indexed.gdshader` lacks `fog_disabled`); smooth fog vs 16-step per-object haze, `FOG_END_FACTOR` (`world_builder.gd:17`) unsourced; cockpit ambient gradient (world.md:103) and glow window (world.md:137) missing |
| ES2 | `world_builder_es2.gd`, `es2_terrain.gdshader` | es2.md:110: terrain light level should be the integer (31*I)>>8, the shader blends (`es2_terrain.gdshader:33`); own `sun_l` instead of global `sun_dir` |
| BD | `games/bd/arena_builder.gd` | BRIGHT/DIM/DARK changes ambient, which unshaded palette materials ignore (`arena_builder.gd:65`): the setting does nothing to shapes |
| Starsiege / Tribes | `engine/map_builder.gd`, `map_environment.gd`, `darkstar_sky.gd`, `map_weather.gd` | PBR approximation of palette lighting; .mis lights and interior light maps unused; sun colour clamped, `light_energy` never set |
| Weapon fx | `engine/fx/fx_player.gd:282` (cap 16), `fx_projectile_look.gd:162` (no cap) | Invisible on 3Space shapes (unshaded); world.md:125 adds type-2 point lights into I |

| # | Duplication | Proposed | Risk / size | Status |
|---|---|---|---|---|
| L1 | Environment built in 6 game places + ~12 tests/tools | `SceneLighting`: `build_palette_environment` (ES1 / ES2 worlds), `apply_sun_direction` (every builder), `add_studio_environment` (10 test scenes, shape viewer, line-up). Open: BD arena and MapEnvironment (FILMIC for Darkstar vs LINEAR for 3Space in mixed scenes) still build their own | M / M | PART |
| L2 | Global `sun_dir` written in 5 places; 3Space sun conversion copied (`world_builder.gd:44`, `world_builder_es2.gd:47`); the ES1/ES2 environments built twice | `engine/lighting/scene_lighting.gd` `SceneLighting.apply_sun_direction`, `make_3space_sun`, `build_palette_environment(spec)`; used by both world builders, the arena and MapEnvironment (hangar_bay.gd still sets its own; it was being edited) | L / S | DONE |
| L3 | Two dynamic-light builders, different energies, one cap | `engine/lighting/dynamic_lights.gd` `DynamicLights.make_light` / `make_transient` (one budget, MAX_TRANSIENT) for FxPlayer, FxProjectileLook and TribesBaseLights | L / S | DONE |
| L4 | Palette shaders ignore point lights | `engine/lighting/palette_lights.gd` `PaletteLights` + `palette_point_lights.gdshaderinc`: 3Space explosion lights raise I by I x min(1, full / d) within their cutoff (weapon_fx.md 2.1) in the indexed and shaded shaders | M / M | DONE |

## 5. Wingmen, AI animation and radio

All speech goes `Battle.radio` -> fx "radio" -> `engine/chat/radio_voice.gd` -> `battle_overlay.gd show_radio`.

| Game | Radio | AI | Animation |
|---|---|---|---|
| ES1 | `engine/crew/wingman_radio.gd` (event mapping [L], audio_video.md "Pilot radio"), `radio_table.gd` | `ai_pilot.gd`, `flyer_ai.gd` | `herc_animator.gd`, `shape_cycles.gd`, `pose_blend.gd`, `torso_rig.gd` |
| ES2 | WingmanRadio + `games/es1/mission/es2_command_radio.gd` (training [H], base attack [L]) | `es2_group_orders.gd` on AIPilot | as ES1 |
| Starsiege | `games/starsiege/ss_radio.gd` (script say()) | `ss_unit_director.gd`, `ss_flyer_orders.gd` | as ES1 + `walker_collapse.gd` |
| Tribes | `tribes_mission_output.gd` (training voice) | `tribes_bot.gd` on `engine/infantry/infantry_bot.gd` | `infantry_animation.gd`, weapon/turret rigs |

Fidelity: the HDD window k draws face PILOT(k+1) while the radio speaks table 1/2/4 (`cockpit_hdd.gd:182` vs
`wingman_radio.gd:24`); the HDD lists every living ally, not the squad (`cockpit_painter.gd:76`); faces only
blink (cockpit.md:240 has 24 frames + mouth strips); the transmit LED is always on (cockpit.md:159); no order
menu, so messages 7 and 10..42 are never spoken; ES1 flyer orders sleep/scout ignored (mission.md:215,
`battle_spawner.gd:316`); ES2 order 6 mapped to travel (`es2_group_orders.gd:9`); MECHIQ / ES2 difficulty
tables unused.

| # | Duplication | Proposed | Risk / size | Status |
|---|---|---|---|---|
| R1 | Voice-name builders x3 (`radio_table.gd:77`, `ss_radio.gd:33`, `tribes2_functions.gd:134`); speaker labels in 4 places | `engine/crew/radio_line.gd` `RadioLine.make_voice_name(pack, clip)`, `RadioLine.make(...)` | L / S | DONE (names); speaker labels open |
| R2 | Wingman identity from 3 disagreeing sources (radio spawn order, HDD team scan, PILOT index) | `WingmanRadio.pilot_number` / `slot_of` / `make_squad_first`: the comm windows list the squad in radio slot order with the voice's face; the transmit lamp follows `RadioVoice.is_speaker_talking` | M / M | DONE |
| R3 | Two voice players (RadioVoice, shell voice + mouth driver `shell_sequences.gd:158`) | `engine/chat/voice_player.gd` + `lip_sync.gd` | M / M | OPEN |
| R4 | Sequence-by-name lookup x5; five animation drivers | `ShapeCycles.find_named` (TribesTurretRig, InfantryHeldWeapon use it); a `ClipPlayer` from HercAnimator still open | L / S; H / L | PART |
| R5 | AI target scan x2 (`ai_pilot.gd:123`, `flyer_ai.gd:86`) + `has_meta("ai")` x8 | `engine/ai/ai_senses.gd`, `UnitKind.is_ai` | M / M | HOT (A: targeting) |

## 6. Briefing and debriefing presentation

| Game | Briefing | Debrief / killed | Distance from the original |
|---|---|---|---|
| ES1 shell (`games/es1/shell`) | Commander text + voice, lip-synced TTM talking head (`shell_sequences.gd:125`) | Officer talking head, death / won / lost scenes | Close to shell.md; career briefing line `slot % 9` vs "mission type" comment (`shell_missions.gd:73`), commander/officer index clamp 0..3 unverified |
| ES1 launcher | Plain text (the campaign lobby (`engine/ui/screens/lobby_screen.gd`)) | Text + debriefing by code | No talking heads |
| ES2 | Plain text (`es2_mission_resolver.gd:217`) | Debrief re-compiled with final vars (es2.md:595) | None of the 86 AVI clips play (es2_campaign_flow.md:28); `intel` resolved but not shown |
| Starsiege | short + long brief (`starsiege/campaign_provider.gd:42`) | Runtime `debrief()`; failed missions replay | `texts.debriefings` unused; .smk movies not played |
| Tribes | `training_screen.gd` | MatchResults only | Not a saga provider |

| # | Duplication / divergence | Proposed | Risk / size | Status |
|---|---|---|---|---|
| B1 | **Per-game branches in shared code:** `Session.mission_herc` (`session.gd:172`) and `BattleSetup.apply_mission_to_config` / `make_mission_runtime` (`battle_setup.gd:86-122`) each tested `is_tribes` / `is_starsiege` / `pack == "es2"` | `engine/mission_kinds.gd` `MissionKinds`: picks the game's `MissionRuntime` script; each runtime answers the static launch contract `apply_world_to_config`, `make_mission_herc`, `is_mission_herc_forced` | L / S | DONE |
| B2 | Killed prompts per game in a shared screen (`killed_screen.gd:8`), one victory / defeat text for every game (`match_flow.gd:288`, wrong for the Starsiege Cybrid side) | `engine/campaign_presentation.gd` `CampaignPresentation.of(campaign)`: providers answer `make_presentation()` {killed_prompt, victory_text, defeat_text}; Starsiege by side. Next: briefing voice / talking head / video descriptors in the same contract (B5) | L / S | DONE |
| B3 | Lost-campaign Replay never shown: `debrief_screen.gd:24` passed only `text`, dropping `next.replay` | pass `replay` to the end screen | L / S | DONE (agent D) |
| B4 | Mission result recorded twice: `mission_launch.gd:83` (shell) and `Session.finish_mission` | shell delegates to Session | M / S | OPEN |
| B5 | Talking head and video only in the ES1 shell | `tools/export_movies.py` (ES2 AVI + VSHELL clip table, Starsiege SMK -> .ogv); `CampaignPresentation.make_movies` / `make_talks`; ES2 briefing / debriefing / death / victory clips; ES1 commander and debriefing-officer heads in the launcher (`TalkingHead` shared with the shell, `ShellTalkPanel`). Open: Starsiege movie moments not decoded | H / L | DONE |

## 7. Mission success and failure

| Game | Objectives from | Decided by | Code / text |
|---|---|---|---|
| ES1 | MSN header `mission_type`, group 0 target/orders | `MissionRuntime._check_end` + `ES1WinRules` | 2 + damage level or failure code; `deb[code-1]` |
| ES2 | s58 objectives, timers | `ES2Objectives.check_end`, 4.9 s grace | status 2/6/9; debrief re-compiled |
| Starsiege | script `MissionBriefObjective` | script `forceToDebrief`; player death fails after 8 s | 1/6 |
| Tribes | objective page / HUD | `end_game` / `end_session` | 1/6 |
| BD / skirmish / modes | match config | `BattleRules`, `DuelRules`, `GameModeRules` | `{}` |

Fidelity: ES1 escort (type 7) tests the player's last nav point, not the escort reaching its path end
(`es1_win_rules.gd:71`, mission.md 5); ES1 codes 1, 2, 7, 8 never produced (mission.md:261); ES1 safe test
ignores "enemy knows" (mission.md:275); ES2 failure always 6, es2.md:454 says 10 with enemies near
(`es2_objectives.gd:245`); ES2 statuses 3/7/8 missing; ES2 group "dead" ignores damage > 192 and disabled
(`mission_targets.gd:84`); ES2 objectives panel marks every line from the overall status
(`mission_objectives.gd:73`).

| # | Duplication | Proposed | Risk / size | Status |
|---|---|---|---|---|
| M1a | Four `_finish`/`debrief` end paths in the runtimes | one template `MissionRuntime.end_mission(success, code, text)` with per-game `apply_end`, `make_end_var`, `make_debriefing_text` | L / S | DONE |
| M1b | `code` means something different per game; ~7 result dictionary shapes | `engine/mission_outcome.gd` `MissionOutcome.make_ended` / `make_aborted` / `make_headline` (Battle, BattleExit, BattleSummary, DebriefScreen); game-mode results still their own | L / S | DONE (missions) |
| M2 | Objective-line builders chosen by `is` checks (`mission_objectives.gd:31`); four copies of the rules-tick clock | every runtime answers `make_objective_lines()`; one `MissionRuntime.make_rules_step(delta, interval)` (simulation time since the last tick) for ES1, ES2, Starsiege, Tribes; leaving the area: `make_area_rule()` per runtime (BattleBounds.AREA_DAMAGE / AREA_MISSION / AREA_NONE) | L / M | DONE |
| M3 | Dead `result_extra()` (Starsiege, Tribes); `Campaign.is_failure` beside a hard-coded copy of the GO.EXE threshold table (`MissionRuntime.FAIL_THRESHOLD`, against docs/LEGAL_AUDIT.md) | `result_extra` removed; one rule `Campaign.is_failure` reading the imported `campaign.json` `outcome_threshold`; the static `last_inventory` side channel stays until M1b | L / S | DONE |
| M4 | Starsiege and Tribes inherited ES1 state (`win_rules`, `regions`, `dormant_groups`) and ES1 behaviour (on_unit_destroyed) from `MissionRuntime` | `engine/mission_runtime_base.gd` `MissionRuntimeBase`: the Battle / launch / rules contract only (setup, spawn_units, player_spawn, formation_offset_local, on_unit_destroyed, make_objective_lines, make_rules_step, end_mission + hooks, squad slots); `MissionRuntime` (ES1, and ES2 through it) extends it, Starsiege and Tribes extend the base | H / L | DONE |

## 8. Order of work

Done: L1 (tests/tools), B1, B2, B3, B5, L4, M1a, M1b, M2, M3, M4, W3, W4, W5, W6, P1 (gravity), P2 (ramming), L2, L3, O2 (collision), R1, R2, R4 (lookup), W1, W2, W7, W8.
Next, small: R4 sequence lookup, W6 magazine, O1 ShapeBody (after B), L3 dynamic lights (after H).
Then medium: M1b MissionOutcome, W3 turret brain, W4 blast, P1 world physics, L1 scene lighting for the Darkstar maps and tests, R2 registry, R3 voice player.
Large: W5 damage models (with the section 1 fidelity gaps), M4 ES1 runtime split, P3 locomotion, L4 palette point lights, B5 talking heads / video.

## 9. Fidelity bugs fixed

| Bug | Evidence | Fix | Test |
|---|---|---|---|
| ES1 textured polys were hazed by Godot fog | world.md 4: "Textures get no distance haze" (DBSIM 0x5410c). ES2 does haze them (RMP haze rows, es2.md 3.3) | `indexed_unhazed.gdshader` (fog_disabled) for es1 palettes, chosen by `Palette.make_texture_shader`; shared body in `indexed_body.gdshaderinc` | standardization_check "SceneLighting" |
| ES2 failure status ignored "enemies near" | es2.md 10.3: failed gives 6 when safe, 10 when enemies are near; only 6 and 9 end the mission | `ES2Objectives._status_for`; `is_complete()` now comes from the evaluation, not the status | standardization_check "ES2 objective status" |
| HDD wingman face did not match the voice | Radio tables are PILOT1/2/4 (audio_video.md "Pilot radio"); the face was PILOT(k+1) | `WingmanRadio.pilot_number`: face = voice table. Which face the original pairs with which voice is not traced [L] | standardization_check "Wingman faces" |
| Hard-coded copy of the GO.EXE outcome threshold table | docs/LEGAL_AUDIT.md: values come from the disc import | `Campaign.is_failure` reads campaign.json | es1_mission_end_check, campaign_failure_check |

| Rules ticks credited a fixed 0.25 s whatever the physics steps (timers ran slow) | simulation time | `make_rules_step` | standardization_check "Rules clock", es1_mission_end_check 5x under load |
| ES1 escort (type 7) was won by the player's nav point | mission.md 5: the target reached the end of its path alive | `ES1WinRules.escort_arrived` + `AIPilot.PATH_DONE_META` | es1_mission_end_check (the 5 escort missions played through), standardization_check |
| ES1 / ES2 missions took Tribes' out-of-bounds damage | mission.md 5 (code 7 warning, 8 left the map), es2.md 10.4 (status 7 outside, 8 more than 110000 u outside, auto-end after 4.9 s) | `make_area_rule`; ES1 ends with code 8 after the warning time (ES1's own time not traced [L]: the ES2 grace), ES2 with status 7 / 8 | standardization_check "Area rules" |
| Destroyed structures kept full collision | the ruin is drawn flattened (cells state 2) | collision rebuilt from the drawn ruin | standardization_check (ES1, ES2, Starsiege, Tribes) |
| BD turrets fired at their own side | battledrome.md 6/8: `side` = owner, penalty for shooting your own turret | `ArenaTurret.is_hostile` (side k = team k) | standardization_check "BD turret sides" |
| Original prompt strings hard-coded in code | LEGAL_AUDIT | ES1 killed / career-over pages from the imported MENU1250 / MENU1260 dialogs, Starsiege from IDSTR_PLAYER_KILLED; ES2's VSHELL prompt is not in the imported tables, so the remake words it | standardization_check |

| ES2 terrain blended between light levels and used its own sun | es2.md 3.3: level (31*I)>>8 per poly | `es2_terrain.gdshader`: face normal, integer level, global sun_dir | visual (no headless renderer; shader compiled by the ES2 world tests) |
| Escort wingman spawned inside a zone feature, trapped (B0_C4_50); followers stalled against obstacles | winnability | `MissionRuntime.make_clear_spawn` (SpawnClearance) for ES1 unit spawns; `AIPilot.make_detour_heading` (remake unstick rule) | es1_mission_end_check (5 escorts, none trapped), standardization_check "AI detour" |

Noted, not fixed (sizes as in the tables above):
- ES1 codes 1 (objective plus bonus; per-type formula not decoded) and 2 (ejected: the remake has no ejection); ES2 status 3 (disabled: no lasting disabled state). BD start pads per side are not used (spawns ignore pad sides).
- ES2 group "dead" ignores damage > 192 and disabled units.
- The ES2 objectives-panel lines are the briefing's lines. Nothing decoded links them to the objective records, so each line shows the overall status.
- Destroyed structures keep their full collision.
- BD turrets ignore sides.
- The splash, EMP and component-pick differences in section 1.
- The original strings in the killed prompts (now in each provider's `make_presentation`) should come from the imported STR tables (LEGAL_AUDIT).

## 10. Test harness

- `engine/testing/test_watchdog.gd` (autoload `TestWatchdog`): a test scene whose script failed to load exits 2, any
  test run past its wall-clock limit (`-- --test-timeout=<s>`, default 3600) exits 3, so no run hangs.
- `tests/compile_all` counts real failures (exit 1) and names every class_name not yet registered ("run --import").

## 11. Progress log

See item C1 in `docs/PLAYTEST_2026-10-11b.md` for the tests run per refactor.
