extends RefCounted
## Standalone campaign provider for Tribes: Aerial Assault (game/engine/saga.gd STANDALONE; not part of the Earthsiege
## saga). Data: gamedata/tribes_aa/campaign/campaign.json (tools/aa_import.py): the five training missions, then the
## eleven numbered missions, each with its name, briefing (communique) text and map "tribes_aa:<Id>".
## On foot only: no garage, no Herc choice (on_foot()); the shared briefing screen skips the Herc picker.
## Missions are played by AAMissionRuntime; a failed mission is flown again.

const PACK := "tribes_aa"
const DATA_FILE := "campaign/campaign.json"
const RUNTIME_KEY := "tribes_aa"
const TITLE := "Tribes: Aerial Assault"
const NO_MISSIONS := "Aerial Assault: no missions imported."


class AACampaign:
	extends RefCounted
	var missions: Array = []
	var index := 0
	var over := false
	var victory := false
	var results: Array = []

	func current_mission() -> String:
		return String(missions[index].get("folder", "")) if index < missions.size() else ""

	func load_current(_options := {}) -> Dictionary:
		if index >= missions.size():
			return {}
		var e: Dictionary = missions[index]
		var objectives := String(e.get("objectives_text", ""))
		var notes := PackedStringArray()
		for line in objectives.split("\n", false):
			if line.strip_edges().begins_with("-"):
				notes.append(line.strip_edges().trim_prefix("-").strip_edges())
		return {"pack": PACK, "runtime": RUNTIME_KEY, "id": String(e.folder), "name": String(e.name),
			"map": "%s:%s" % [PACK, String(e.map)], "mission_name": "%s:%s" % [PACK, String(e.map)],
			"kind": String(e.get("kind", "mission")),
			"texts": {"briefing": "%s\n\n%s" % [String(e.name).to_upper(), String(e.get("briefing", ""))],
				"objectives": Array(notes), "objective_notes": "\n".join(notes), "debriefings": ["Mission complete.", "Mission failed."]}}

	func prepared_vars(_options := {}) -> PackedInt32Array:
		var v := PackedInt32Array()
		v.resize(MissionRuntimeBase.MISSION_VAR_COUNT)
		return v

	func record_result(success: bool, _vars := PackedInt32Array()) -> void:
		results.append({"mission": current_mission(), "success": success})
		if success:
			index += 1
			if index >= missions.size():
				over = true
				victory = true

	func is_over() -> bool:
		return over

	func is_victory() -> bool:
		return victory

	func replays_failed_missions() -> bool:
		return true

	## No garage and no Herc pick: the player is a soldier.
	func on_foot() -> bool:
		return true

	func pack_id() -> String:
		return PACK

	func make_heading() -> String:
		return "%s  -  mission %d of %d" % [TITLE, index + 1, missions.size()]

	func make_presentation() -> Dictionary:
		return {"killed_prompt": "Mission failed.", "victory_text": "VICTORY - the campaign is complete.",
			"defeat_text": "GAME OVER"}

	func to_dict() -> Dictionary:
		return {"index": index, "over": over, "victory": victory, "results": results}


static func _make() -> AACampaign:
	var c := AACampaign.new()
	var d = Assets.load_json(DATA_FILE, PACK)
	if d is Dictionary:
		c.missions = d.get("missions", [])
	return c


static func start(_variant: String) -> Object:
	return _make()


static func restore(d: Dictionary) -> Object:
	var c := _make()
	c.index = clampi(int(d.get("index", 0)), 0, maxi(0, c.missions.size() - 1))
	c.over = bool(d.get("over", false))
	c.victory = bool(d.get("victory", false))
	c.results = d.get("results", [])
	return c
