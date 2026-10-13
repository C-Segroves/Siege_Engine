extends Node
## Trailer capture check (tools/video): every VideoShots shot names vehicles and maps that exist,
## the hangar loadouts really use weapons from other games, and ScriptedInputs holds each action
## exactly inside its window.
##   godot --headless --audio-driver Dummy --path game res://tests/video_director_check.tscn

const KINDS := ["hangar", "battle", "lineup", "duel"]   # the shot kinds VideoDirector plays

var _failures := 0


func _ready() -> void:
	_check_shots()
	_check_foreign_loadouts()
	_check_scripted_inputs()
	print("video_director_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_shots() -> void:
	print("shots:")
	for shot_name in VideoShots.names():
		var spec := VideoShots.make_spec(shot_name)
		_expect(String(spec.get("kind", "")) in KINDS and float(spec.get("seconds", 0.0)) > 0.0, "%s: kind and length" % shot_name)
		var ids: Array = spec.get("hercs", [])
		if spec.has("herc"):
			ids = ids + [spec.herc]
		for a in spec.get("ai", []):
			ids.append(a.vehicle)
		for id in ids:
			_expect(not Packs.vehicle(String(id)).is_empty(), "%s: vehicle %s exists" % [shot_name, id])
		var map_id := String(spec.get("config", {}).get("map", ""))
		if map_id != "":
			var parts := Assets.split_id(map_id)
			_expect(FileAccess.file_exists(Assets.path("maps/%s/map.json" % parts[1], parts[0])), "%s: map %s exists" % [shot_name, map_id])


func _check_foreign_loadouts() -> void:
	print("foreign loadouts:")
	for id in VideoShots.make_spec("hangar").hercs:
		var own := String(Packs.vehicle(id).pack)
		var picks := VideoShots.make_foreign_loadout(id).filter(func(w): return w != "")
		var foreign := picks.all(func(w): return String(Packs.weapon(w).pack) != own)
		_expect(not picks.is_empty() and foreign, "%s: %d weapons, none from %s" % [id, picks.size(), own])


func _check_scripted_inputs() -> void:
	print("scripted inputs:")
	var inputs := ScriptedInputs.new([[0.0, 1.0, ["throttle_up"]], [0.5, 2.0, ["turn_left", "fire_group_1"]]])
	_expect(inputs.make_held_actions(0.2).keys() == ["throttle_up"], "only the first window at 0.2 s")
	_expect(inputs.make_held_actions(0.7).size() == 3, "overlapping windows at 0.7 s")
	_expect(not inputs.make_held_actions(1.0).has("throttle_up"), "a window ends at its end time")
	_expect(inputs.make_held_actions(2.5).is_empty(), "nothing after the last window")
	var analog := ScriptedInputs.new([[0.0, 1.0, ["aim_left:0.5", "throttle_up"]]])
	_expect(analog.make_held_actions(0.5) == {"aim_left": 0.5, "throttle_up": 1.0}, "action:strength holds at that strength")
	var taps := ScriptedInputs.new([], [[2.0, "vehicle_enter_exit"], [1.0, "view_toggle"]])
	_expect(taps.take_due_taps(0.5).is_empty(), "no tap before its time")
	_expect(taps.take_due_taps(2.5) == ["view_toggle", "vehicle_enter_exit"], "due taps fire in time order")
	_expect(taps.take_due_taps(3.0).is_empty(), "each tap fires once")
	var ev := ScriptedInputs.make_tap_event("view_toggle", true)
	_expect(ev.is_action_pressed("view_toggle"), "a tap is a pressed InputEventAction (read by _unhandled_input)")
