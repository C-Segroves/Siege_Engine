extends Node
## The shared sensor primitives (engine/sensors/), on stub units (no pack needed):
##   godot --headless --audio-driver Dummy --path game res://tests/sensors_check.tscn
## SensorSource (range, cone, spec parsing), ContactTable (per-team detection, last seen, forgetting, sweep and hidden
## marks), ProximityAlert with the Earthsiege profile (ES1 SIM@e722 / DBSIM 0xf744 ranges). Prints "sensors_check: OK".


class Stub extends Node3D:
	var alive := true
	var team := 1
	var target: Node3D = null
	var integrity := 1.0


var _failures := 0


func _ready() -> void:
	_check_source()
	_check_table()
	_check_alert()
	print("sensors_check: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _stub(pos: Vector3, team := 1) -> Stub:
	var u := Stub.new()
	u.team = team
	u.position = pos
	add_child(u)
	return u


func _check_source() -> void:
	var source := SensorSource.make_from_spec({"range": 100.0, "fov_only": true, "fov_deg": 90.0, "fov_percent": 1.0, "detects_cloaked": true, "min_velocity": 3.0})
	_expect(source.range_m == 100.0 and source.cone_degrees == 90.0 and source.detects_cloaked and source.min_velocity == 3.0, "the spec fills the source")
	_expect(SensorSource.make_from_spec({}).range_m == 0.0 and SensorSource.make_from_spec({}).cone_degrees == SensorSource.ALL_ROUND_DEGREES, "an empty spec sees nothing, all round")
	var eye := _stub(Vector3.ZERO)
	var ahead := _stub(Vector3(0, 0, -60))
	var behind := _stub(Vector3(0, 0, 60))
	var far := _stub(Vector3(0, 0, -150))
	var facing := Vector3(0, 0, -1)
	_expect(source.senses(eye, ahead, facing), "a unit ahead inside the range is sensed")
	_expect(not source.senses(eye, behind, facing), "a unit behind is outside a 90 degree cone")
	_expect(not source.senses(eye, far, facing), "a unit beyond the range is not sensed")
	source.cone_degrees = SensorSource.ALL_ROUND_DEGREES
	_expect(source.senses(eye, behind, facing), "all round, the facing does not matter")


func _check_table() -> void:
	var table := ContactTable.new()
	var unit := _stub(Vector3(5, 0, 0), 2)
	_expect(not table.is_detected(1, unit) and table.make_last_seen_msec(1, unit) == -1, "nothing is known at first")
	table.apply_detected(1, unit.get_instance_id(), 1000)
	_expect(table.is_detected(1, unit) and not table.is_detected(3, unit), "a team detects what its sensors found, not another team")
	table.apply_clear()
	_expect(not table.is_detected(1, unit) and table.make_last_seen_msec(1, unit) == 1000, "a refresh forgets the detection, not the last-seen time")
	table.apply_forget(1000 + ContactTable.FORGET_MSEC + 1)
	_expect(table.make_last_seen_msec(1, unit) == -1, "an old last-seen time is dropped")
	_expect(not ContactTable.is_swept(unit), "no sweep mark at first")
	ContactTable.apply_swept(unit, 5.0)
	_expect(ContactTable.is_swept(unit) and ContactTable.is_revealed(unit, unit), "a swept unit is revealed to every radar")
	ContactTable.apply_hidden(unit, true)
	_expect(ContactTable.is_hidden(unit), "a script can hide a unit")
	ContactTable.apply_hidden(unit, false)
	_expect(not ContactTable.is_hidden(unit), "and show it again")


func _check_alert() -> void:
	var profile := EsSensorProfile.make()
	var unit := _stub(Vector3.ZERO, 2)
	var close := _stub(Vector3(profile.detect_range_m - 1.0, 0, 0), 1)
	var mid := _stub(Vector3(profile.detect_range_m + 1.0, 0, 0), 1)
	_expect(ProximityAlert.is_noticed(unit, [close], profile), "an enemy inside the detect range notices the unit")
	_expect(not ProximityAlert.is_noticed(unit, [mid], profile), "one just beyond does not")
	mid.target = unit
	_expect(ProximityAlert.is_noticed(unit, [mid], profile), "one that targets it does, at any range")
	var edge := _stub(Vector3(profile.safe_range_m + 1.0, 0, 0), 1)
	_expect(not ProximityAlert.is_unsafe_from(edge, unit, profile), "an enemy beyond the safe range leaves the unit safe")
	edge.target = unit
	_expect(ProximityAlert.is_unsafe_from(edge, unit, profile), "closer than the targeting range it does not when it targets the unit")


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("sensors_check FAIL: %s" % what)
