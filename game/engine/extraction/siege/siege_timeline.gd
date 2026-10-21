class_name SiegeTimeline
extends RefCounted
## The clock of the siege on MissionTimers (host). Before the siege it runs the warning countdown (announcements at
## announce_at_s); once the Cybrids arrive it counts the siege time (the safe area reads it) and fires the exfil closings
## and the final stand at the rules' times. Everything it fires comes out as a signal; CybridSiege acts on them.

signal announced(seconds_left: int)
signal arrived
signal exfil_closing(zone: int, is_last: bool)
signal last_exfil_open(zone: int, seconds_left: float)
signal final_stand

const PAYLOAD_ARRIVE := "arrive"
const PAYLOAD_FINAL := "final"
const PREFIX_ANNOUNCE := "announce:"
const PREFIX_CLOSE := "close:"

## Seconds into the siege (0 during the warning).
var siege_s := 0.0
var in_siege := false
## [{zone, at_s, last}] in closing order, set by apply_siege_start.
var closings: Array = []
var last_zone := -1
var _timers := MissionTimers.new()


## The countdown to the arrival starts: announcements at the rules' seconds, then the arrival.
func apply_warning(countdown_s: float) -> void:
	_timers.apply_add(PAYLOAD_ARRIVE, MissionTimer.make_timer(countdown_s, MissionTimer.Mode.ONE_SHOT, PAYLOAD_ARRIVE))
	for at in CybridRules.section("warning").get("announce_at_s", []):
		if float(at) < countdown_s:
			var id := PREFIX_ANNOUNCE + str(int(at))
			_timers.apply_add(id, MissionTimer.make_timer(countdown_s - float(at), MissionTimer.Mode.ONE_SHOT, id))


func make_warning_left() -> float:
	return _timers.make_time_left(PAYLOAD_ARRIVE)


## The Cybrids arrived. `zones` are the exfil zone points, `last_zone` the one that stays open longest.
func apply_siege_start(zones: Array, p_last_zone: int) -> void:
	in_siege = true
	siege_s = 0.0
	last_zone = p_last_zone
	closings = make_closings(zones, p_last_zone)
	for c in closings:
		var id := PREFIX_CLOSE + str(int(c.zone))
		_timers.apply_add(id, MissionTimer.make_timer(float(c.at_s), MissionTimer.Mode.ONE_SHOT, id))
	_timers.apply_add(PAYLOAD_FINAL, MissionTimer.make_timer(float(CybridRules.section("final").get("after_s", 1260.0)), MissionTimer.Mode.ONE_SHOT, PAYLOAD_FINAL))


## [{zone, at_s, last}]: the zones farthest from `last_zone` close first, interval_s apart from first_close_s; the last
## zone closes at last_close_s.
static func make_closings(zones: Array, last_zone: int) -> Array:
	var rules := CybridRules.section("exfil")
	var order := []
	for i in zones.size():
		if i != last_zone:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return (zones[a] as Vector3).distance_to(zones[last_zone]) > (zones[b] as Vector3).distance_to(zones[last_zone]))
	var out := []
	for k in order.size():
		out.append({"zone": int(order[k]), "at_s": float(rules.get("first_close_s", 120.0)) + float(rules.get("interval_s", 130.0)) * k, "last": false})
	out.append({"zone": last_zone, "at_s": float(rules.get("last_close_s", 1140.0)), "last": true})
	return out


func make_next_closing() -> Dictionary:
	for c in closings:
		if float(c.at_s) > siege_s:
			return c
	return {}


## Seconds until the final stand (0 outside the siege).
func make_final_left() -> float:
	return _timers.make_time_left(PAYLOAD_FINAL)


func apply_tick(dt: float) -> void:
	if in_siege:
		siege_s += dt
	for payload in _timers.apply_tick(dt):
		_apply_payload(str(payload))


func _apply_payload(payload: String) -> void:
	if payload == PAYLOAD_ARRIVE:
		arrived.emit()
	elif payload == PAYLOAD_FINAL:
		final_stand.emit()
	elif payload.begins_with(PREFIX_ANNOUNCE):
		announced.emit(int(payload.trim_prefix(PREFIX_ANNOUNCE)))
	elif payload.begins_with(PREFIX_CLOSE):
		_apply_closing(int(payload.trim_prefix(PREFIX_CLOSE)))


func _apply_closing(zone: int) -> void:
	var is_last := zone == last_zone
	exfil_closing.emit(zone, is_last)
	var next := make_next_closing()
	if not is_last and not next.is_empty() and bool(next.last):
		last_exfil_open.emit(last_zone, float(next.at_s) - siege_s)
