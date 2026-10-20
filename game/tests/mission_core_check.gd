extends Node
## The mission contract (engine/mission/): MissionWorld defaults, MissionSink, MissionVerdict, MissionClock.
##   godot --headless --audio-driver Dummy --path game res://tests/mission_core_check.tscn

const WATCHDOG_SECONDS := 30.0

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	_check_verdict()
	_check_clock()
	_check_world_defaults()
	_check_sink_port()
	print("mission_core_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _check_verdict() -> void:
	var w := MissionVerdict.make_win(7, "done", 2.5, true)
	_expect(w.success and w.code == 7 and w.text == "done" and w.delay == 2.5 and w.wait_for_voice, "make_win carries every field")
	var l := MissionVerdict.make_loss(3)
	_expect(not l.success and l.code == 3 and l.text == "" and l.delay == 0.0 and not l.wait_for_voice, "make_loss defaults: no text, no delay")


func _check_clock() -> void:
	var c := MissionClock.new()
	# the first step always ticks; then one tick per interval of whole physics steps, carrying the elapsed time
	var dts := []
	for _i in 12:
		c.apply_advance(0.1)
		dts.append(snappedf(c.make_step(0.1, 0.25), 0.001))
	var ticks := dts.filter(func(x: float) -> bool: return x > 0.0)
	_expect(is_equal_approx(dts[0], 0.1) and ticks.size() >= 4 and ticks.size() <= 6 and _ticks_total(dts) <= 1.2 and _ticks_total(dts) >= 1.0,
		"the rules tick spans whole physics steps and loses no time (%s)" % str(dts))
	_expect(is_equal_approx(c.elapsed, 1.2), "elapsed is the sum of the advances")
	var d := MissionClock.new()
	_expect(is_equal_approx(d.make_step(0.016, 0.0), 0.016), "an interval of 0 ticks every step")


func _ticks_total(dts: Array) -> float:
	var sum := 0.0
	for d in dts:
		sum += float(d)
	return snappedf(sum, 0.001)


func _check_world_defaults() -> void:
	var w := MissionWorld.new()
	_expect(w.is_player_alive() and w.get_living_count(1) == 0 and not w.is_target_destroyed("x"), "the empty world has a living player and no foes")
	_expect(w.get_out_of_area_seconds() == 0.0 and w.get_score(0) == 0 and w.get_kill_count("") == 0, "the empty world counts nothing")
	_expect(w.sink != null and not w.sink.is_voice_playing(), "a world always has a sink")
	var near := _WorldAt.new()
	_expect(is_equal_approx(near.make_player_distance("t"), 5.0), "make_player_distance is player to target (%f)" % near.make_player_distance("t"))


class _WorldAt:
	extends MissionWorld
	func get_target_position(_id: String) -> Vector3:
		return Vector3(3, 0, 4)


class _LoudSink:
	extends MissionSink
	var seen: Array = []
	func apply_message(m: MissionMessage) -> void:
		seen.append(m.text)
	func apply_nav(id: String, on: bool) -> void:
		seen.append("%s:%s" % [id, on])
	func is_voice_playing() -> bool:
		return true


func _check_sink_port() -> void:
	var w := MissionWorld.new()
	w.sink = _LoudSink.new()
	w.sink.apply_message(MissionMessage.make_message("hi"))
	w.sink.apply_nav("wp", true)
	_expect((w.sink as _LoudSink).seen == ["hi", "wp:true"] and w.sink.is_voice_playing(), "a sink subclass receives what the blocks send")
