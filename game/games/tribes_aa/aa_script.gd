class_name AAScript
extends RefCounted
## The data side of Aerial Assault's mission logic (docs/formats/aerial_assault.md, "Mission logic"): the object tags of a map
## (`#TAG` lines of SOLO-MISSION.TXT: GEN1, WAYPT1, DERM_2L_1M_1W ...) and the mission record of campaign/logic.json
## (tools/aa_logic.py, read from the PS2 executable), run by AAScriptVM. No nodes in here.

const LOGIC_FILE := "campaign/logic.json"
const PACK := "tribes_aa"
const ENEMY_PREFIX := "DERM_"
const ALLY_PREFIX := "BOT_"
const SIZES := ["LIGHT", "MEDIUM", "HEAVY"]
const TYPE_ARENA := "arena"
const TYPE_SCRIPTED := "scripted"
const TYPE_TRAINING := "training"


## The logic record of campaign folder `folder` ("MISSION06"); {} when the pack has none (trainings, old imports).
static func make_logic(folder: String) -> Dictionary:
	var j = Assets.load_json(LOGIC_FILE, PACK)
	if not (j is Dictionary):
		return {}
	return (j.get("missions", {}) as Dictionary).get(folder, {})


## The CAMPAIGN.BIN strings the scripts show ({"<number>": text}).
static func make_texts() -> Dictionary:
	var j = Assets.load_json(LOGIC_FILE, PACK)
	return (j.get("texts", {}) as Dictionary) if j is Dictionary else {}


## Counts of a spawn tag: {team: 0 allies | 1 enemies, light, medium, heavy, wave}; {} when `tag` is not a spawn tag. "DERM_1L_1M_2W" =
## one light and one medium bioderm of wave 1 (the second: W counts from 1); a tag without W is wave 0 (campaign_logic::ParseTag).
static func parse_spawn_tag(tag: String) -> Dictionary:
	var team := -1
	var rest := ""
	if tag.begins_with(ENEMY_PREFIX):
		team = 1
		rest = tag.substr(ENEMY_PREFIX.length())
	elif tag.begins_with(ALLY_PREFIX):
		team = 0
		rest = tag.substr(ALLY_PREFIX.length())
	else:
		return {}
	var out := {"team": team, "light": 0, "medium": 0, "heavy": 0, "wave": 0}
	for part in rest.split("_", false):
		if part.length() < 2 or not part.substr(0, part.length() - 1).is_valid_int():
			return {}
		var n := int(part.substr(0, part.length() - 1))
		match part[part.length() - 1]:
			"L":
				out.light = n
			"M":
				out.medium = n
			"H":
				out.heavy = n
			"W":
				out.wave = n - 1                   # ParseTag: the wave is the number minus one (no W = wave 0)
			_:
				return {}
	return out


## Every spawn point of the map: [{pos: Vector3, team, light, medium, heavy, wave}].
static func make_spawn_points(map: Dictionary) -> Array:
	var out := []
	for w in map.get("waypoints", []):
		var rec := parse_spawn_tag(str(w.get("tag", "")))
		if rec.is_empty():
			continue
		var p: Array = w.pos
		rec["pos"] = Vector3(float(p[0]), float(p[1]), float(p[2]))
		out.append(rec)
	return out


## The position(s) of the object(s) tagged `tag` anywhere in the map (waypoints, stations, spawn pads, switches).
static func make_tag_positions(map: Dictionary, tag: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for key in ["waypoints", "stations", "spawns", "mode_objects"]:
		for o in map.get(key, []):
			if str(o.get("tag", "")) == tag:
				var p: Array = o.pos
				out.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	return out


## Soldiers of wave `wave` for `team` as [{pos, size}] (size = LIGHT / MEDIUM / HEAVY), one entry per soldier.
static func make_wave_soldiers(points: Array, team: int, wave: int) -> Array:
	var out := []
	for p in points:
		if int(p.team) != team or int(p.wave) != wave:
			continue
		for size_key in ["light", "medium", "heavy"]:
			for _k in int(p[size_key]):
				out.append({"pos": p.pos, "size": SIZES[["light", "medium", "heavy"].find(size_key)]})
	return out


## The waves that exist for `team`, ascending.
static func make_waves(points: Array, team: int) -> Array:
	var seen := {}
	for p in points:
		if int(p.team) == team:
			seen[int(p.wave)] = true
	var out := seen.keys()
	out.sort()
	return out
