class_name RaidTaskBoard
extends RefCounted
## The pre-raid task board (playtest X8; docs/design/extraction.md section 5; rules "tasks"). Before a raid the stash
## screen offers board_size tasks, made from the rules' templates against the AI factions the installed packs field;
## a pilot takes up to max_picked (ExtractionProfile.tasks). A task:
##   {id, kind, faction, count, reward}
##   kind      kill_infantry (count of the faction's soldiers), kill_vehicles (its vehicles), destroy_generator (the
##             base generator nearest its area), steal_flag (the map flag nearest its area, carried out)
##   reward    credits paid on extraction when done: reward_per x count x the faction kind's difficulty
## Generator and flag tasks need a Tribes base / a flag on the raid's map: where the map has none the host voids them
## (RaidTasks), no gain, no loss.

const KIND_KILL_INFANTRY := "kill_infantry"
const KIND_KILL_VEHICLES := "kill_vehicles"
const KIND_GENERATOR := "destroy_generator"
const KIND_FLAG := "steal_flag"


static func rules() -> Dictionary:
	return ExtractionRules.data().get("tasks", {})


static func make_max_picked() -> int:
	return int(rules().get("max_picked", 2))


## A fresh board of board_size tasks from `seed_value` (each a different template / faction pair).
static func make_board(seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var choices := make_choices()
	var out := []
	var size := int(rules().get("board_size", 4))
	while out.size() < size and not choices.is_empty():
		var pick: Dictionary = choices.pop_at(rng.randi_range(0, choices.size() - 1))
		out.append(make_task(pick.template, pick.faction, rng, "t%d_%d" % [seed_value % 100000, out.size()]))
	return out


## Every [template, faction] pair a faction can serve: {template, faction}.
static func make_choices() -> Array:
	var out := []
	for t in rules().get("templates", []):
		for f in ExtractionFactions.make_available():
			if _can_serve(t, f):
				out.append({"template": t, "faction": f})
	return out


static func _can_serve(template: Dictionary, faction: Dictionary) -> bool:
	match str(template.get("needs", "")):
		"infantry":
			return ExtractionFactions.make_infantry_pack(faction) != ""
		"vehicles":
			return not ExtractionFactions.make_vehicle_pool(faction).is_empty()
		"base":
			return ExtractionFactions.make_infantry_pack(faction) != ""   # bases are held by soldiers
	return false


static func make_task(template: Dictionary, faction: Dictionary, rng: RandomNumberGenerator, id: String) -> Dictionary:
	var count := maxi(ExtractionRules.roll_range(rng, template.get("count", [1, 1])), 1)
	var task := {"id": id, "kind": str(template.kind), "faction": str(faction.id), "count": count}
	task["reward"] = make_reward(task)
	return task


## Credits `task` pays: reward_per x count x the faction kind's difficulty.
static func make_reward(task: Dictionary) -> int:
	var per := float(find_template(str(task.kind)).get("reward_per", 0))
	var difficulty := float((rules().get("difficulty", {}) as Dictionary).get(ExtractionFactions.kind_of(str(task.faction)), 1.0))
	return int(round(per * int(task.count) * difficulty))


static func find_template(kind: String) -> Dictionary:
	for t in rules().get("templates", []):
		if str(t.kind) == kind:
			return t
	return {}


## "Kill 4 Blood Eagle soldiers".
static func make_text(task: Dictionary) -> String:
	var template := find_template(str(task.kind))
	var faction_name := str(ExtractionFactions.find(str(task.faction)).get("name", task.faction))
	var text := str(template.get("text", task.kind))
	return text % [int(task.count), faction_name] if text.count("%") >= 2 else text % faction_name


## "Kill 4 Blood Eagle soldiers  -  1 200 cr".
static func make_offer_text(task: Dictionary) -> String:
	return "%s  -  %s" % [make_text(task), ExtractionRules.make_money_text(int(task.reward))]
