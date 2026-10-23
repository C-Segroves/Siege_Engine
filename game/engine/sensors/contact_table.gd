class_name ContactTable
extends RefCounted
## What a side knows about the enemy units, in one place (docs/MECHANICS_UNIFICATION.md section 5, Sensors):
##   detected   per team, the units its sensors find right now (a sensor net rewrites the set every refresh);
##   last seen  per team and unit, when it was last detected (engine msec), kept for FORGET_MSEC;
##   reveals    shared by the team: a working com tower's reach (SensorTowers) and the call-in sweep, which marks a unit
##              that every radar of the machine then shows (apply_swept / is_swept);
##   hidden     a unit a mission script took off every radar (apply_hidden).
## The per-team detected sets are an instance (a battle's sensor net owns one); sweeps and hidden marks live on the
## unit, which is also what far bots without a node (RadarProxy) carry.

const HIDDEN_META := "radar_hidden"
## A unit the call-in radar sweep marks carries the time (engine msec) until which every radar of this machine shows it.
const SWEPT_META := "radar_swept_until_msec"
## How long a last-seen time is remembered after the unit was last detected.
const FORGET_MSEC := 60000

var _detected := {}    # team -> {instance id: true}
var _last_seen := {}   # team -> {instance id: msec}


## Starts a refresh: forgets what every team detects now (last-seen times stay).
func apply_clear() -> void:
	_detected.clear()


## Registers a team that detects nothing yet (is_detected answers false for it).
func apply_team(team: int) -> void:
	if not _detected.has(team):
		_detected[team] = {}
	if not _last_seen.has(team):
		_last_seen[team] = {}


## `team` detects the unit with `unit_id` at `now_msec`.
func apply_detected(team: int, unit_id: int, now_msec: int) -> void:
	apply_team(team)
	_detected[team][unit_id] = true
	_last_seen[team][unit_id] = now_msec


## Drops last-seen times older than FORGET_MSEC.
func apply_forget(now_msec: int) -> void:
	for team in _last_seen:
		var seen: Dictionary = _last_seen[team]
		for id in seen.keys():
			if now_msec - int(seen[id]) > FORGET_MSEC:
				seen.erase(id)


func is_detected(team: int, unit: Node) -> bool:
	return (_detected.get(team, {}) as Dictionary).has(unit.get_instance_id())


## Engine msec `team` last detected `unit`; -1 when never (or forgotten).
func make_last_seen_msec(team: int, unit: Node) -> int:
	return int((_last_seen.get(team, {}) as Dictionary).get(unit.get_instance_id(), -1))


## True when `unit` is revealed to `viewer`'s radar apart from any sensor of his own: the call-in sweep, or a working
## com tower of his side that reaches it.
static func is_revealed(viewer: Node, unit: Node) -> bool:
	return is_swept(unit) or SensorTowers.is_revealed_by(viewer, unit)


## Hides (or shows again) one unit from every radar and the command map.
static func apply_hidden(unit: Node, hidden: bool) -> void:
	unit.set_meta(HIDDEN_META, hidden)


static func is_hidden(unit: Node) -> bool:
	return bool(unit.get_meta(HIDDEN_META, false))


## The call-in radar sweep marks `unit` for `seconds`: it shows on every radar and the command map, and T can target it,
## whatever the range, the radar mode or the sensor net say.
static func apply_swept(unit: Node, seconds: float) -> void:
	unit.set_meta(SWEPT_META, Time.get_ticks_msec() + int(seconds * 1000.0))


static func is_swept(unit: Node) -> bool:
	return Time.get_ticks_msec() < int(unit.get_meta(SWEPT_META, 0))
