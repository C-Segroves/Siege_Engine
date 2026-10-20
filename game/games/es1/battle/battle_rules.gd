class_name BattleRules
extends RefCounted
## Host-side match rules without a mission: kill announcements, respawning (versus / respawn modes),
## the frag limit and the co-op end conditions. Missions decide their own outcome; destroyed enemies'
## intact weapons are collected as salvage (BattleSalvage) for the mission result.
##
## Which rule ends a match (also the objective text shown when it starts, make_objective_text):
##   versus, and every mode on a map that respawns (Battledrome arenas, pack maps: MapPicker sets
##   "respawn"): the first pilot to `frag_limit` kills wins; destroyed vehicles respawn.
##   skirmish / co-op on an Earthsiege world (no respawn): destroy all Cybrids (team 1); the match is
##   lost when the player's team is destroyed.

const RESPAWN_TIME := 6.0           # seconds
const KILL_MESSAGE_SECONDS := 4.0
const PLAYER_TEAM := 0
const CYBRID_TEAM := 1
const DEFAULT_FRAG_LIMIT := 10
const MODE_NAMES := {"skirmish": "Skirmish", "coop": "Co-op", "vs": "Versus"}
const FRAG_OBJECTIVE := "%s: first pilot to %d kills wins (destroyed vehicles respawn)."
const TEAM_FRAG_OBJECTIVE := "%s: first of %d teams to %d kills wins (destroyed vehicles respawn)."
const TEAM_WIN := "Team %s wins the match!"
const DESTROY_OBJECTIVES := {"skirmish": "Skirmish: destroy all Cybrids.", "coop": "Co-op: destroy all Cybrids together."}
const EXTRACTION_OBJECTIVE := "Extraction raid: loot what you can (%s), call an exfil transport (%s) and get out alive. Inventory: %s."
const SQUAD_WINNER := "Your squad"
const CYBRID_WINNER := "The Cybrids"
## Verdict codes of the match rules (the match end carries the text and the winner; the codes only name the rule).
const CODE_FRAG_LIMIT := 1
const CODE_CYBRIDS_DESTROYED := 2
const CODE_SQUAD_DESTROYED := 3

var battle: Battle
var _respawn_queue := []            # [net_id, seconds left]
var salvage := BattleSalvage.new()
var _score_world := MissionWorld.new()   # the frag limit reads its points from the objective's source, not from a world


func _init(p_battle: Battle) -> void:
	battle = p_battle


func on_destroyed(h: Herc, killer: Node) -> void:
	if not battle.multiplayer.is_server():
		return
	battle.fx("message", [KillText.make_kill_text(h, killer), KILL_MESSAGE_SECONDS], true)
	if is_decided_by_mode(battle.config):
		return   # the extraction mode decides its own end and nobody respawns (ExtractionDirector)
	if battle.mission:
		salvage.apply_destroyed(h, PLAYER_TEAM, GarageEconomy.make_for_pack(str(battle.config.get("economy_pack", ""))))
		battle.mission.on_unit_destroyed(h)
		return
	var config := battle.config
	if uses_frag_limit(config):
		if not h.has_meta(GameModes.RESPAWNED_BY_MODE_META):   # a mode's own unit (WAR defenders) comes back its way
			_respawn_queue.append([h.net_id, RESPAWN_TIME])
		_check_frag_limit(killer)
	else:
		_check_coop_end()


## The frag limit: reached by the killer (free for all) or by the killer's team's kills together (team match).
func _check_frag_limit(killer: Node) -> void:
	if not (killer is Herc):
		return
	var by_team := plays_in_teams(battle.config)
	var objective := ScoreObjective.new("frag_limit", "", killer.team if by_team else killer.display_name, frag_limit(battle.config))
	if by_team:
		objective.source = func(team: int) -> float: return make_team_kills(battle.vehicles.values(), team)
	else:
		objective.source = func(_pilot: String) -> float: return killer.kills
	objective.apply_tick(_score_world, 0.0)
	if not objective.is_done():
		return
	var winner: String = MapTeams.make_team_name(killer.team, battle.config) if by_team else killer.display_name
	var verdict := MissionVerdict.make_win(CODE_FRAG_LIMIT, TEAM_WIN % winner if by_team else "%s wins the match!" % winner)
	battle.end_match(verdict.text, {}, winner)


## True when the match is played in teams (versus "teams", or a team count chosen on the host screen).
static func plays_in_teams(config: Dictionary) -> bool:
	return bool(config.get("teams", false)) or int(config.get("team_count", MapTeams.MIN_TEAMS)) > MapTeams.MIN_TEAMS


## The kills of every pilot of `team` together.
static func make_team_kills(vehicles: Array, team: int) -> int:
	var total := 0
	for v in vehicles:
		if is_instance_valid(v) and v.team == team:
			total += int(v.kills)
	return total


## True when the mode itself ends the match and keeps the dead down (extraction raids).
static func is_decided_by_mode(config: Dictionary) -> bool:
	return ExtractionRules.is_extraction(config)


## True when the match is won by kills (versus, or a map whose vehicles respawn).
static func uses_frag_limit(config: Dictionary) -> bool:
	return config.get("mode") == "vs" or bool(config.get("respawn", false))


static func frag_limit(config: Dictionary) -> int:
	return int(config.get("frag_limit", DEFAULT_FRAG_LIMIT))


## The objective announced when a non-mission match starts; it states the rule that ends it.
static func make_objective_text(config: Dictionary) -> String:
	var mode := str(config.get("mode", "skirmish"))
	if mode == "mission":
		return ""
	if GameModes.uses_director(config):
		return GameModes.make_objective_text(config)
	if is_decided_by_mode(config):
		return EXTRACTION_OBJECTIVE % [InfantryInteraction.make_key_text(), OccupancyHint.make_key_text("exfil_call"),
			OccupancyHint.make_key_text("inventory_toggle")]
	if uses_frag_limit(config) and plays_in_teams(config):
		return TEAM_FRAG_OBJECTIVE % [MODE_NAMES.get(mode, MODE_NAMES.skirmish), int(config.get("team_count", MapTeams.MIN_TEAMS)),
			frag_limit(config)]
	if uses_frag_limit(config):
		return FRAG_OBJECTIVE % [MODE_NAMES.get(mode, MODE_NAMES.skirmish), frag_limit(config)]
	return str(DESTROY_OBJECTIVES.get(mode, DESTROY_OBJECTIVES.skirmish))


## The co-op rule: the verdict when one side is gone (a win when the Cybrids are), else null.
func _make_coop_verdict() -> MissionVerdict:
	var alive_teams := {}
	for id in battle.vehicles:
		var v: Herc = battle.vehicles[id]
		if v.alive and not (v is Infantry):   # soldiers always respawn: a squad is its vehicles
			alive_teams[v.team] = true
	if not alive_teams.has(CYBRID_TEAM):
		return MissionVerdict.make_win(CODE_CYBRIDS_DESTROYED, "All Cybrids destroyed. Mission complete.")
	if not alive_teams.has(PLAYER_TEAM):
		return MissionVerdict.make_loss(CODE_SQUAD_DESTROYED, "Your squad has been destroyed. Mission failed.")
	return null


func _check_coop_end() -> void:
	var verdict := _make_coop_verdict()
	if verdict != null:
		battle.end_match(verdict.text, {}, SQUAD_WINNER if verdict.success else CYBRID_WINNER)


## Counts down the respawn queue and respawns the Hercs whose time is up.
func update(delta: float) -> void:
	for r in _respawn_queue.duplicate():
		r[1] -= delta
		if r[1] > 0.0:
			continue
		_respawn_queue.erase(r)
		var h: Herc = battle.vehicles.get(r[0])
		if h and not battle.is_over():
			h.respawn(battle.spawner.make_respawn_point(h.team))
