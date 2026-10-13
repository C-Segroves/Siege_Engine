# Multiplayer game modes

Which multiplayer modes each original game had, how the remake finds out which modes a map supports, and how the
modes run. Rule values (points, timers, limits) are **not** copied here or into the code: the importer reads them
from the user's own scripts (`tools/export_game_modes.py` → `gamedata/<pack>/gameplay/game_modes.json` and each
map's `mode_settings`). The remake's own defaults and labels are in `game/engine/game_modes/game_modes.json`.

## 1. Inventory per game

| game | modes | evidence (user's disc) |
|---|---|---|
| Earthsiege 1, Earthsiege 2 | no multiplayer | the shells offer campaign, training and instant action only (docs/formats/shell.md, es2_campaign_flow.md) |
| Battledrome | **Arena duel**: two players (modem, null modem, IPX) or one player against the AI ladder; the challenge's *victory terms* (practice, 25/50/75 % damage, crippled, destroyed), arena size, lighting, obstacles, turrets, allowed weapon classes, a wager; a referee drone polices penalties | README, WATEXT.BIN / MSGTEXT.BIN, SHELL strings (docs/formats/battledrome.md §8) |
| Starsiege | **Deathmatch** and **Team Deathmatch** (the same `DM_` maps; the server's team-play switch), **Capture the Flag** (`CTF_` maps, Hercs only), **Football** (`Starsiege_Football`), **WAR** (`WAR_Martian_Standoff`) | `multiplayer/*.mis` + `*.cs`, `DMstdLib.cs`, `CTFstdLib.cs`, `Starsiege_Football.cs`, `WAR_Martian_Standoff.cs`, `multiplayerStdLib.cs` |
| Tribes 1 | **Capture the Flag**, **Capture and Hold**, **Defend and Destroy**, **Find and Retrieve**, **Deathmatch**; "Multiple Team" missions are the same rules with 3-4 teams (CTF where the teams have flags, otherwise C&H) | `scripts/objectives.cs`, `scripts/dm.cs`, `scripts/game.cs`; each mission's `.dsc` `$MDESC::Type` and `.mis` `$Game::missionType`, `$teamScoreLimit` |
| Tribes 2 | **CTF**, **Capture and Hold (CnH)**, **Deathmatch**, **Hunters**, **Team Hunters**, **Rabbit**, **Bounty**, **Siege**, **Defend and Destroy** (script only, no shipped mission), SinglePlayer (training) | `scripts/<Type>Game.cs`, `defaultGame.cs`, `item.cs`, `player.cs`; mission header `// MissionTypes = …` |

### Rules (what the remake reimplements)

* **Kills** (all modes unless noted): kill +, suicide −, team kill −; Tribes 2 CTF / CnH / Hunters use a kill
  efficiency formula (`recalcScore`), the remake counts plain kill points. Respawn: the battle's own respawn
  (BattleRules, 6 s); Tribes 2 respawns on a trigger after 2 s (10 s after a suicide), Tribes 1 manually.
* **CTF.** Touching the enemy flag takes it (T1 only players, T2 `Flag::onCollision` ignores mounted players,
  Starsiege by driving the Herc into the enemy base trigger). Capturing = touching your own flag (T1/T2) or driving
  into your own base trigger (Starsiege) **while your own flag is at home**. Team gets a capture point, the carrier
  bonus points. A killed carrier drops the flag; it returns home after a delay (T1 `$flagReturnTime`, T2
  `FLAG_RETURN_DELAY`) or at once when a team mate touches it. Starsiege: the flag never lies on the ground (it
  goes home when its carrier dies) and a carrier holding it longer than `$flagTime` loses it. Killing an enemy
  carrier gives a bonus. Win: team score limit (T1 per mission, T2 `CTF_scoreLimit`, Starsiege `$maxFlagCount`) or the
  best score at the time limit.
* **Capture and Hold.** Touching a switch of another team claims it (T1 TowerSwitch: the whole tower group changes
  team at once; T2 FlipFlop: the capture counts after a capture timer). The holder scores over time (T1: the tower's
  `deltaTeamScore` per minute, paid every 5 s; T2: a point per short interval). Win: score limit (T1 per mission,
  T2 per switch × `SCORE_LIMIT_PER_TOWER` unless the mission sets one) or the time limit.
* **Defend and Destroy.** Objectives are the objects with a `scoreValue` (generators, command stations, sensors,
  turrets). Destroying an enemy one scores its value; destroying your own gives the points to the enemy. T1: at the
  time limit surviving objectives score for their owners; T2: the match ends when a team has lost them all.
* **Find and Retrieve** (T1). Neutral flags lie around the map, each team has flag stands. A flag placed on an empty
  stand of your team scores its value; an enemy taking it off removes the points; dropped flags return after the
  flag delay.
* **Hunters / Team Hunters** (T2). Each player carries his own flag; a dead player drops everything he carried plus
  his own, in denominations 1/2/4/8 (`throwFlags`). Touching the Nexus banks the carried flags: *n* flags score
  *n(n+1)/2*. Greed mode needs a minimum number of flags; dropped flags fade. Team Hunters banks for the team and a
  suicide / team kill does not drop the own flag. Time limit decides.
* **Rabbit** (T2). One flag; its carrier is the rabbit and scores a point per interval held (plus a grab point);
  killing him drops the flag (returns after the flag delay). Score limit (`Rabbit_scoreLimit`) or time limit.
* **Bounty** (T2). Each player hunts a random target; target kill +, streak bonus, killing your hunter 0, bystander
  −; a suicide credits everyone hunting the victim; the first with no target left gets the completion bonus and wins.
* **Siege** (T2). Offence attacks, defence holds a switch; an offence touch ends the half with the time it took. The
  sides swap at halftime (everyone re-dropped); the second half lasts as long as the first capture. Faster capture
  wins; a team that captured beats one that did not.
* **Football** (Starsiege). The ball is a state of a Herc, not an object: the first Herc gets it; killing the carrier
  hands it to the killer; carrying it into the enemy goal trigger scores a touchdown (team and player points),
  everyone respawns and the team that conceded gets the ball. Entering a goal without the ball or the out-of-bounds
  triggers is a foul (the Herc is destroyed; three fouls = penalty box). First to the win score.
* **WAR** (Starsiege). Each base has five generators and an HQ (`<colour>Gen1..5`, `<colour>HQ`) guarded by AI Hercs
  and turrets; destroying a generator shuts its turret; the first side to destroy `$BUILDINGS_TO_DESTROY` enemy
  structures wins.
* **Deathmatch.** Starsiege: kills × `$killPoints` − deaths × `$deathPoints`, the server frag / time limit ends it;
  Tribes: time limit only. Team Deathmatch (Starsiege team play): the team sums its pilots' points.
* **Arena duel** (Battledrome): one on one; the fight ends when a Herc reaches the agreed victory terms (damage level).

**Also reproduced** (values from the scripts at import): defence bonuses (T1: a kill within 80 m of your flag,
your carrier or your tower; T2: within 20 m of your flag or generator, near a held switch), the T1 tower-hold bonus
(capturer +5 when the tower is still his team's 60 s later), the T2 CTF stalemate (both flags away 60 s: carriers
revealed 6 s every 15 s, a light pillar in the remake), Hunters hoard mode, greed mode, the Nexus anti-spam guard,
camping (warning, second warning, then damage per second) and the flag-hoarder line, Football fumbles (1 in n per
hit, the taker scores) and the penalty box (the third foul: the Herc comes back in its box on a penalty team for 60 s),
WAR's AI base defenders (re-dropped after 60 s, 120 s once their HQ is down), and Capture-and-Hold switch groups
(turrets, stations, generators of the switch's group change team with it; `mode_objects` switch `group`).

**Not reproduced** (documented gaps): T2 escort assists (the script clears its own mark at once, so they never
score in the original either), Bounty / Rabbit waypoint pulses, Hunters out-of-bounds flag throwing, WAR generator /
turret pairs (the Starsiege map turrets are scenery in the remake), the Battledrome referee, wagers and banned-weapon
penalties, the T2 AI repair / deploy / mortar objectives.

## 2. Which modes a map supports (from its own data)

`tools/export_game_modes.py` (importer step `modes`, after `maps`) writes into every exported map:

```jsonc
"original_modes": ["CTF"],                // what the mission declares
"modes": ["ctf"],                         // engine mode ids it supports (declared AND its objects present)
"mode_objects": [{"id": 1, "kind": "flag", "team": 0, "pos": [x, y, z], "yaw": 0, "shape": "tribes2:flag",
                  "modes": ["ctf"],       // empty = every mode of the map; T2 missionTypesList
                  "value": 1,             // scoreValue (D&D objectives, F&R flags)
                  "points_per_minute": 12,// T1 tower deltaTeamScore
                  "half_extents": [x, y, z], "name": "RedGoal", "datablock": "Flag"}],
"mode_settings": {"ctf": {"score_limit": 8}}   // the mission's own values
```

and `"modes"` plus `"mode_objects"` counts per kind into `maps/_index.json`. Kinds: `flag`, `flag_stand` (T1/T2
stands, Starsiege `<Colour>FlagTrigger` boxes), `switch` (TowerSwitch, FlipFlop), `nexus`, `objective`
(scoreValue objects), `generator`, `structure` (WAR), `goal`, `out_of_bounds` (Football trigger boxes).
Detection: T2 header `MissionTypes` + per-object `missionTypesList` (inherited from groups); T1 `.dsc` type (+ team
flags decide CTF vs C&H for "Multiple Team"); Starsiege file prefix + map script. A declared mode is dropped (note
in `notes`) when its objects are missing (`REQUIRES`: CTF two team flags, C&H a switch, D&D two team objectives,
F&R a flag and two team stands, Hunters a Nexus, Rabbit a flag, Siege a switch, Football two goals, WAR two team
structures).

**Remake modes** (`GameModes.make_mode_ids_for_map`): every map offers `deathmatch` (the default) and `coop_ai`;
`team_deathmatch` with at least two starts; `extraction` when both sides of the map are at least
`extraction_min_side_m` (1000 m: room for three exfil zones and spread-out loot areas). Battledrome arenas: `duel`
+ the remake modes. Earthsiege battlefields: deathmatch, team deathmatch, co-op, extraction.

## 3. Engine (`game/engine/game_modes/`)

| file | role |
|---|---|
| `game_modes.json` | registry: id, label, family, team_based, min/max teams, description, the remake's default rules; aliases (`dm`, `cnh`, `teamhunters` …) |
| `game_modes.gd` `GameModes` | lobby API, config keys, rule settings (defaults ← pack `gameplay/game_modes.json` ← map `mode_settings` ← config `score_limit` / `time_limit_s`), `make_rules` |
| `game_mode_rules.gd` `GameModeRules` | pure rules base: scores (`ModeScore`), objects (`ModeObject`), kill points, carrying, time limit, state for the peers, HUD lines |
| `deathmatch_rules.gd`, `duel_rules.gd`, `ctf_rules.gd`, `capture_hold_rules.gd`, `defend_destroy_rules.gd` (also WAR), `find_retrieve_rules.gd`, `hunters_rules.gd` (also Team Hunters), `rabbit_rules.gd`, `bounty_rules.gd`, `siege_rules.gd`, `football_rules.gd` | one class per mode family |
| `game_mode_director.gd` `GameModeDirector` | Battle child `GameModes`: host feeds kills / touches / destroyed objectives / time to the rules, broadcasts messages, ends the match, sends the state (reliable RPC on change, every second); D&D / WAR objectives become `Structure`s (Tribes maps: H's `TribesBase.object_destroyed`) |
| `game_mode_visuals.gd` | every peer: flags with the original shapes (Tribes `flag`, T2 `flag` / `huntersflag`, Starsiege team flags; a pole stand-in when a shape is missing) at home, dropped or on the carrier; switch beacons in the holder's colour; the stalemate pillar |
| `game_mode_resources.gd` | every peer: a switch's group joins the holder's team (H's TribesBase objects, TribesStations records) |
| `game_mode_ai.gd`, `game_mode_brains.gd` | host: the AI's goals per mode, handed to InfantryBot / AIPilot `objective` every second (§3a) |
| `game_mode_defenders.gd` | host: WAR base defenders and their re-drops |

The mode's state is shown in the shared objectives panel (ObjectivesPanel, `MissionObjectives` → `GameModeDirector.make_objective_lines`:
the goal line plus the score / flag / switch / time lines as plain "info" lines).

Battle hookup: `Battle._ready` calls `GameModes.apply_to_config` (mode → `vs`/`coop`/`extraction`, teams, respawn,
and `frag_limit = NO_FRAG_LIMIT` so BattleRules only respawns) and adds the director when `config.game_mode` is a
director mode. Co-op and extraction keep BattleRules / ExtractionDirector. Test flags: `--game_mode=<id>
--team_count=<n>`.

**Who may touch / carry** (decision): soldiers on foot always; **Hercs and other non-Tribes vehicles carry flags**
(Starsiege CTF and Football are Hercs-only, so a Herc carrying the flag is the original rule for Hercs, and the remake
applies it to every Herc on every map; a Herc's reach is `herc_touch_radius_m`); riders and pilots of Tribes vehicles
cannot touch (T2 `Flag::onCollision` returns for mounted players), but a carrier who boards keeps the flag (neither
Tribes drops it on mount) and drops it when killed.

### 3a. The AI plays the objectives

`GameModeAI` plans like the Tribes 2 AI objective queue: each team has objectives with a weight per taker
(weightLevel1..4); the highest weight left goes to the nearest free bot of the team. Tribes 2 maps use their own
`AIObjective` markers (exported as map.json `ai_objectives`: FlagGrab, FlagDropped, FlagCarrier, TouchFlipFlop,
DefendLocation, AttackObject; Siege by side); other maps get the same roles made from the mode's objects: grab /
return / defend the flag / hunt the carrier (CTF), claim / hold switches (C&H, Siege offence and defence), attack /
guard objectives (D&D, WAR), fetch flags / hold stands (F&R), hunt the ball carrier or escort him (Football). A
carrier always runs home (CTF, F&R stand, Football goal). Free-for-all: Hunters bank once they carry 3 (greed: the
minimum) and otherwise collect nearby flags, the rabbit flees and the others chase the flag, Bounty hunters chase
their target. Brains: `InfantryBot.objective` (task OBJECTIVE: urgent goals before any fight, others once nobody is in
fight range; holds at defend points; shoots an objective's structure) and `AIPilot.objective` (vehicles, including
a bot's vehicle). WAR defenders keep their guard orders.

Herc starts on map files are turned away from walls (`SpawnClearance.make_open_facing`: kept when 40 m ahead are
clear of buildings, else the most open of 16 directions, ties toward the map centre).

## 4. Earthsiege arenas (generated spawns)

ES1 and ES2 had no multiplayer, so `tools/export_es_arenas.py` (importer step `arenas`) makes arena maps of their
battlefields with generated spawn areas (the remake's own rule; nothing copied): ES1 = the four terrain zones × day /
dusk / night (flat ground, the zone's features avoided), ES2 = every zone heightmap in the day world of the first
campaign theatre on it (slope ≤ 0.35 between samples). Each map: 32 free-for-all starts by farthest-point sampling
(≥ 60 m apart), 4 team areas (the farthest valid pair first, then farthest from those) of 12 starts 22 m apart,
all ≥ 320 m inside the bounds (BattleBounds warns at the edge). `map.json` has `"world": {pack, index, zone}`;
`MapBuilder.build` builds it with `WorldBuilder`.

## 5. Lobby API (D)

`GameModes.make_modes_for_map(entry)` → `[{id, label, team_based, min_teams, max_teams, description}]` (entry: a
MapPicker entry, a `MapBuilder.list_maps` row or an index row); `GameModes.DEFAULT` = `"deathmatch"`; the choice goes
into the battle config as `GameModes.CONFIG_KEY` = `"game_mode"` (optionally `team_count`, `score_limit`,
`time_limit_s`).

## 6. Tests

`game/tests/game_modes_check.tscn` (maps → modes, Earthsiege spawns, every family's rules, state sync, a CTF capture
in a real battle; `--shots=<dir>` → `modes_*.png`), `game/tests/game_modes_lan.tscn` (two processes, `--role=host` /
`--role=client`: the client sees the host carry the flag and capture it).
