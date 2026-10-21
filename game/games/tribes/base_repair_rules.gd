class_name BaseRepairRules
extends RefCounted
## The remake's rules for repairing and capturing base objects (res://games/tribes/base_repair_rules.json): how long
## a repairer holds an object he took, what a faction's repair crew does, how the repair is shown.

const FILE := "res://games/tribes/base_repair_rules.json"

static var _data := {}


static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("BaseRepairRules: cannot read %s" % FILE)
			d = {}
		_data = d
	return _data


static func capture() -> Dictionary:
	return data().get("capture", {})


static func faction() -> Dictionary:
	return data().get("faction_repair", {})


static func feedback() -> Dictionary:
	return data().get("feedback", {})


## True when repairing an object of a team that is not allied to the repairer captures it.
static func is_capture_on() -> bool:
	return bool(capture().get("enabled", false))


static func make_capture_seconds() -> float:
	return float(capture().get("seconds", 0.0))
