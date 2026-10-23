class_name RepairRules
extends RefCounted
## The data of the one repair mechanic (res://engine/repair/repair_rules.json), per game: the capture-by-repair rule
## (BaseCapture), the hold-repair of a Herc without a pack (RepairDirector), how a repair pack's rate reaches a
## teammate, the faction repair crew and the beam's look. A game's block (key = the pack of the object or the
## soldier's gear: "tribes", "es1" ...) overrides single keys of "default".

const FILE := "res://engine/repair/repair_rules.json"
const BASE_EQUIPMENT_FILE := "gameplay/base_equipment.json"
## Which repair rate a pack gives a teammate: its own (RepairGunImage repairFactorPlayer) or the object rate.
const UNIT_RATE_PACK := "pack"

static var _data := {}
static var _beams := {}        # pack -> the repair block of its base_equipment.json


static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("RepairRules: cannot read %s" % FILE)
			d = {}
		_data = d
	return _data


## The pack whose block rules `pack_id` ("tribes2", "tribes2:REPAIR_PACK", "tribes_aa:..."): aliases resolved.
static func make_game(pack_id: String) -> String:
	var game := pack_id.get_slice(":", 0)
	return str((data().get("pack_alias", {}) as Dictionary).get(game, game))


## Block `section` of the game of `pack_id` over the default.
static func section(pack_id: String, key: String) -> Dictionary:
	var out: Dictionary = (data().get("default", {}).get(key, {}) as Dictionary).duplicate()
	var game_block: Dictionary = data().get("games", {}).get(make_game(pack_id), {})
	if game_block.get(key) is Dictionary:
		out.merge(game_block[key], true)
	return out


static func capture(pack_id: String) -> Dictionary:
	return section(pack_id, "capture")


static func hold(pack_id: String) -> Dictionary:
	return section(pack_id, "hold")


static func faction() -> Dictionary:
	return data().get("faction_repair", {})


static func feedback() -> Dictionary:
	return data().get("feedback", {})


## "object" or UNIT_RATE_PACK: whose rate a repair pack of `pack_id` gives a teammate.
static func make_unit_rate_source(pack_id: String) -> String:
	var game_block: Dictionary = data().get("games", {}).get(make_game(pack_id), {})
	return str(game_block.get("pack_unit_rate", data().get("default", {}).get("pack_unit_rate", "object")))


## The repair block of the game's base_equipment.json ({per_s, range, source}; {} when the game has none): the
## repair pack's rate on objects and vehicles and its beam's reach.
static func make_beam(pack_id: String) -> Dictionary:
	var game := make_game(pack_id)
	if not _beams.has(game):
		var spec = Assets.load_json(BASE_EQUIPMENT_FILE, game)
		_beams[game] = (spec as Dictionary).get("repair", {}) if spec is Dictionary else {}
	return _beams[game]
