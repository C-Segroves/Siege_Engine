class_name BattleStats
extends RefCounted
## The host's per-pilot match statistics beyond kills and deaths (docs/design/lobby_loadout_economy.md sections 2.5 and
## 5.4): assists, bot and vehicle kills, damage dealt, time alive, flag captures / returns and extractions. BattleSummary
## copies them into each pilot's row, so the credits ledger and the goal board work from the host's numbers only.
## A pilot is keyed by the name he plays under, which follows him from soldier to vehicle and through respawns.

## A pilot who damaged a unit that was then destroyed within this long assisted the kill.
const ASSIST_WINDOW_MS := 10000
const MSEC_PER_SECOND := 1000.0

var _battle: Battle
var _bot_kills := {}
var _vehicle_kills := {}
var _assists := {}
var _damage := {}
var _seconds_alive := {}
var _extractions := {}
var _last_hp := {}       # net id -> the unit's total component hp at its last damage report
var _hits := {}          # net id -> {pilot key -> msec of his last hit}


func _init(p_battle: Battle) -> void:
	_battle = p_battle


## Host: follows `h` (its damage and its destruction).
func watch(h: Herc) -> void:
	_last_hp[h.net_id] = _total_hp(h)
	h.damaged.connect(_on_damaged)
	h.destroyed.connect(_on_destroyed)


## Host: counts the time every living pilot spends alive.
func update(delta: float) -> void:
	var alive_keys := {}
	for h in _battle.vehicles.values():
		if is_instance_valid(h) and h.alive:
			alive_keys[make_pilot_key(h)] = true
	alive_keys.erase("")
	for key in alive_keys:
		_seconds_alive[key] = float(_seconds_alive.get(key, 0.0)) + delta


## Host: `key` got out of an extraction raid.
func note_extraction(key: String) -> void:
	_extractions[key] = int(_extractions.get(key, 0)) + 1


## The name of the human who plays `h` ("" for a bot, an empty vehicle or nobody).
func make_pilot_key(h: Node) -> String:
	if not (h is Herc) or h.has_meta("ai"):
		return ""
	if h is Infantry:
		return h.display_name
	var occupancy := h.get_node_or_null(VehicleOccupancy.NODE_NAME) as VehicleOccupancy
	if occupancy == null:
		return h.display_name
	if not occupancy.has_pilot():
		return ""
	var pilot := occupancy.pilot()
	var soldier := _battle.occupancy.soldier_of(pilot) if pilot != VehicleOccupancy.AI_PILOT and _battle.occupancy != null else null
	return soldier.display_name if soldier != null else h.display_name


## The stats of the pilot named `key`: {bot_kills, vehicle_kills, assists, damage, seconds_alive, objectives, flag_captures,
## extractions}. Objectives are the flags he captured or returned, plus (a mission) the objectives the team completed.
func make_stats(key: String) -> Dictionary:
	var captures := _mode_events(key, ModeScore.EVENT_FLAG_CAPTURE)
	return {"bot_kills": int(_bot_kills.get(key, 0)), "vehicle_kills": int(_vehicle_kills.get(key, 0)),
		"assists": int(_assists.get(key, 0)), "damage": int(round(float(_damage.get(key, 0.0)))),
		"seconds_alive": float(_seconds_alive.get(key, 0.0)), "flag_captures": captures,
		"objectives": captures + _mode_events(key, ModeScore.EVENT_FLAG_RETURN) + _mission_objectives_done(),
		"extractions": int(_extractions.get(key, 0))}


func _on_damaged(victim: Herc, attacker: Node) -> void:
	var hp := _total_hp(victim)
	var lost := float(_last_hp.get(victim.net_id, hp)) - hp
	_last_hp[victim.net_id] = hp
	var key := make_pilot_key(attacker)
	if key == "" or attacker == victim or attacker.team == victim.team:
		return
	if lost > 0.0:
		_damage[key] = float(_damage.get(key, 0.0)) + lost
	var hits: Dictionary = _hits.get(victim.net_id, {})
	hits[key] = Time.get_ticks_msec()
	_hits[victim.net_id] = hits


func _on_destroyed(victim: Herc, killer: Node) -> void:
	var killer_key := make_pilot_key(killer)
	if killer_key != "" and killer != victim and killer.team != victim.team:
		if victim.has_meta("ai"):
			_add(_bot_kills, killer_key)
		if not (victim is Infantry):
			_add(_vehicle_kills, killer_key)
	var now := Time.get_ticks_msec()
	for key in _hits.get(victim.net_id, {}):
		if key != killer_key and now - int(_hits[victim.net_id][key]) <= ASSIST_WINDOW_MS:
			_add(_assists, key)
	_hits.erase(victim.net_id)
	_last_hp[victim.net_id] = 0.0


static func _add(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1


static func _total_hp(h: Herc) -> float:
	var total := 0.0
	for c in h.components:
		total += float(c.hp)
	return total


func _mode_events(key: String, event: String) -> int:
	return _battle.game_mode.rules.score.event_count(key, event) if _battle.game_mode != null else 0


func _mission_objectives_done() -> int:
	if _battle.mission == null:
		return 0
	var done := 0
	for o in _battle.mission.kit.objectives.get_objectives():
		if o.is_done():
			done += 1
	return done
