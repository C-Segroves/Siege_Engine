class_name MissionObjectives
## The battle's objectives as lines for the objectives panel: [{text, done}]. Whatever runs the battle answers
## through make_objective_lines():
##   a mission         its game's MissionRuntime (Earthsiege 1: ES1WinRules, the mission type's goal and the nav
##                     progress; Earthsiege 2: the briefing's lines and the mission status; Starsiege: the
##                     MissionBriefObjective objects; Tribes / Tribes 2: the objective page / HUD lines)
##   extraction raid   loot, call an exfil transport, extract
##   game modes        the mode's goal and its state: scores, flags, switches, time (GameModeDirector)
##   other matches     the match rule (BattleRules.make_objective_text)
## In a LAN mission the host's lines reach the clients (ObjectivesPanel, battle effect "objectives").

const OWN_LINES := "make_objective_lines"


static func make_lines(battle: Battle) -> Array:
	if battle == null:
		return []
	if battle.extraction != null:
		return _make_extraction_lines(battle.extraction)
	if battle.game_mode != null:
		return battle.game_mode.make_objective_lines()
	var rt: Node = battle.mission
	if rt == null:
		var rule := BattleRules.make_objective_text(battle.config)
		return [{"text": rule, "done": false}] if rule != "" else []
	if rt.has_method(OWN_LINES):
		return rt.call(OWN_LINES)
	return []


static func _make_extraction_lines(director: Node) -> Array:
	if director.has_method(OWN_LINES):
		return director.call(OWN_LINES)
	var d := director as ExtractionDirector
	var extracted := d.my_status == ExtractionDirector.STATUS_EXTRACTED
	return [
		{"text": "Loot caches and bags (%s)" % InfantryInteraction.make_key_text(), "done": not d.my_inventory.is_empty() or extracted},
		{"text": "Call an exfil transport (%s)" % OccupancyHint.make_key_text("exfil_call"), "done": not d.exfil_states.is_empty() or extracted},
		{"text": "Reach the extraction zone and get out alive", "done": extracted},
	]
