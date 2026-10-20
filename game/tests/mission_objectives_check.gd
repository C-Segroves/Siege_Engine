extends Node
## Objective kinds, ObjectiveSet, fail rules and WaveDirector (engine/mission/).
##   godot --headless --audio-driver Dummy --path game res://tests/mission_objectives_check.tscn

const WATCHDOG_SECONDS := 30.0

var _fails := 0


class Sink:
	extends MissionSink
	var texts: Array = []
	var changes := 0
	func apply_message(m: MissionMessage) -> void:
		texts.append(m.text)
	func apply_objectives_changed() -> void:
		changes += 1


class World:
	extends MissionWorld
	var player := Vector3.ZERO
	var forward := Vector3.FORWARD
	var alive := true
	var destroyed := {}
	var dead_units := {}
	var positions := {}
	var kills := 0
	var scores := {0: 0, 1: 0}
	var carried := false
	var out_seconds := 0.0
	var living := [0, 0]
	func get_player_position() -> Vector3:
		return player
	func get_player_forward() -> Vector3:
		return forward
	func is_player_alive() -> bool:
		return alive
	func is_target_destroyed(id: String) -> bool:
		return destroyed.has(id)
	func is_unit_alive(id: String) -> bool:
		return not dead_units.has(id)
	func get_target_position(id: String) -> Vector3:
		return positions.get(id, Vector3.ZERO)
	func get_kill_count(_g: String) -> int:
		return kills
	func get_score(team: int) -> int:
		return scores[team]
	func is_item_carried(_id: String) -> bool:
		return carried
	func get_out_of_area_seconds() -> float:
		return out_seconds
	func get_living_count(team: int) -> int:
		return living[team]


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
	_check_simple_kinds()
	_check_protect_and_escort()
	_check_scan()
	_check_scan_lines()
	_check_placed_wave()
	_check_relay_scan()
	_check_condition()
	_check_code_source()
	_check_set()
	_check_fail_rules()
	_check_waves()
	print("mission_objectives_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _world() -> World:
	var w := World.new()
	w.sink = Sink.new()
	return w


func _check_simple_kinds() -> void:
	var w := _world()
	var d := DestroyObjective.new("d", "Destroy both", ["g1", "g2"])
	w.destroyed = {"g1": true}
	d.apply_tick(w, 0.25)
	_expect(not d.is_done(), "destroy: one of two is not done")
	w.destroyed["g2"] = true
	_expect(d.apply_tick(w, 0.25) and d.is_done(), "destroy: both destroyed is done, and the tick says it changed")
	w.destroyed.clear()
	d.apply_tick(w, 0.25)
	_expect(d.is_done(), "a done objective stays done")
	var k := KillCountObjective.new("k", "Kill 3", "", 3)
	w.kills = 2
	k.apply_tick(w, 0.25)
	w.kills = 3
	k.apply_tick(w, 0.25)
	_expect(k.is_done(), "kill count reaches its count")
	var r := ReachObjective.new("r", "Reach", AreaShape.make_circle(Vector3(100, 0, 0), 15.0))
	r.apply_tick(w, 0.25)
	w.player = Vector3(90, 0, 0)
	r.apply_tick(w, 0.25)
	_expect(r.is_done(), "reach: inside the area")
	var s := SurviveObjective.new("s", "Survive", 10.0)
	for _i in 39:
		s.apply_tick(w, 0.25)
	_expect(not s.is_done() and is_equal_approx(s.make_time_left(), 0.25), "survive: 9.75 s is not 10")
	s.apply_tick(w, 0.25)
	_expect(s.is_done(), "survive: done at the time")
	var sc := ScoreObjective.new("sc", "Frags", 1, 5)
	w.scores[1] = 4
	sc.apply_tick(w, 0.25)
	w.scores[1] = 5
	sc.apply_tick(w, 0.25)
	_expect(sc.is_done(), "score: the limit of the team")
	var named := ScoreObjective.new("named", "Frags", "Ann", 9.5)
	named.source = func(key: String) -> float: return 9.25 if key == "Ann" else 0.0
	named.apply_tick(w, 0.25)
	_expect(not named.is_done(), "score: a source in fractions, below a fractional limit")
	named.source = func(_key: String) -> float: return 9.5
	named.apply_tick(w, 0.25)
	_expect(named.is_done(), "score: a source in fractions, at the limit")
	var c := CarryObjective.new("c", "Carry", "flag", AreaShape.make_circle(Vector3.ZERO, 10.0))
	w.player = Vector3(1, 0, 1)
	c.apply_tick(w, 0.25)
	w.carried = true
	c.apply_tick(w, 0.25)
	_expect(c.is_done(), "carry: the item inside the area")
	var sx := ScriptObjective.new("x", "from the script")
	sx.apply_state(Objective.State.DONE)
	sx.apply_text("done now")
	_expect(sx.is_done() and sx.make_line() == {"text": "done now", "done": true}, "script: its state and text are set from outside")


func _check_protect_and_escort() -> void:
	var w := _world()
	var p := ProtectObjective.new("p", "Guard", ["base"])
	p.apply_risk(true)
	p.apply_tick(w, 0.25)
	_expect(p.state == Objective.State.AT_RISK, "protect: at risk while in danger")
	p.apply_risk(false)
	p.apply_tick(w, 0.25)
	p.apply_release()
	p.apply_tick(w, 0.25)
	_expect(p.is_done(), "protect: released with the unit alive is done")
	var q := ProtectObjective.new("q", "Guard", ["base"])
	w.dead_units["base"] = true
	q.apply_tick(w, 0.25)
	_expect(q.is_failed(), "protect: a lost unit fails it")
	w.dead_units.clear()
	var e := EscortObjective.new("e", "Escort", "convoy", AreaShape.make_circle(Vector3(50, 0, 0), 10.0))
	w.positions["convoy"] = Vector3(30, 0, 0)
	e.apply_tick(w, 0.25)
	_expect(e.state == Objective.State.ACTIVE, "escort: on the way")
	w.positions["convoy"] = Vector3(45, 0, 0)
	e.apply_tick(w, 0.25)
	_expect(e.is_done(), "escort: arrived")
	var f := EscortObjective.new("f", "Escort", "convoy", AreaShape.make_circle(Vector3(50, 0, 0), 10.0))
	w.dead_units["convoy"] = true
	f.apply_tick(w, 0.25)
	_expect(f.is_failed(), "escort: the unit died")


func _check_scan() -> void:
	var w := _world()
	var sink := w.sink as Sink
	w.positions["relay"] = Vector3(0, 0, -50)
	var stages := [{"seconds": 2.0, "text": "scanning"}, {"seconds": 2.0, "text": "uploading"}]
	var sc := ScanObjective.new("scan", "Scan", "relay", 60.0, stages)
	sc.abort_text = "lost the link"
	for _i in 4:
		sc.apply_tick(w, 0.25)
	_expect(sink.texts == ["scanning"], "scan: the first stage text goes out when it begins (%s)" % str(sink.texts))
	w.forward = Vector3.RIGHT
	sc.apply_tick(w, 0.25)
	_expect(sink.texts == ["scanning", "lost the link"], "scan: looking away aborts it (%s)" % str(sink.texts))
	w.forward = Vector3.FORWARD
	for _i in 15:
		sc.apply_tick(w, 0.25)
	_expect(not sc.is_done(), "scan: it started over, 3.75 s is not 4")
	_expect(sink.texts.slice(2) == ["scanning", "uploading"], "scan: both stage texts again (%s)" % str(sink.texts))
	sc.apply_tick(w, 0.25)
	_expect(sc.is_done(), "scan: the whole time held is done")
	var far := ScanObjective.new("s2", "Scan", "relay", 20.0, stages)
	for _i in 40:
		far.apply_tick(w, 0.25)
	_expect(not far.is_done(), "scan: out of range never finishes")


func _check_scan_lines() -> void:
	var w := _world()
	var sink := w.sink as Sink
	w.positions["relay"] = Vector3(0, 0, -50)
	var sc := ScanObjective.new("scan", "", "relay", 60.0, [{"seconds": 4.0, "text": ""}])
	sc.progress_format = "Scanning... %d%%"
	sc.progress_every = 4
	sc.complete_text = "Scan complete."
	for _i in 16:
		sc.apply_tick(w, 0.25)
	_expect(sink.texts == ["Scanning... 6%", "Scanning... 31%", "Scanning... 56%", "Scanning... 81%", "Scan complete."],
		"scan lines: a progress line every 4th tick, then the completion, a textless stage says nothing (%s)" % str(sink.texts))
	_expect(sc.is_done(), "scan lines: done after the four seconds")


func _check_placed_wave() -> void:
	var plain := SpawnWave.make_wave("g")
	var placed := SpawnWave.make_placed_wave("g", "arrival:2", 300.0, 0.5, 1.0)
	_expect(plain.placement.is_empty() and placed.placement == {"distance": 300.0, "spread": 0.5, "bearing": 1.0}
		and placed.trigger == "arrival:2", "a placed wave names where it appears around the player")


func _check_relay_scan() -> void:
	var w := _world()
	var sink := w.sink as Sink
	w.positions["link"] = Vector3(0, 0, -50)
	var stages := [{"seconds": 1.0, "text": "a"}, {"seconds": 1.0, "text": "b"}, {"seconds": -25.5, "text": "c"}, {"seconds": 0.0, "text": "d"}]
	var r := RelayScanObjective.new("link", "Link", "link", 60.0, stages)
	r.abort_text = "aborted"
	r.apply_tick(w, 0.25)
	_expect(sink.texts == ["a"] and r.get_fired_count() == 1, "relay: stage 0 shows on the first tick (%s)" % str(sink.texts))
	for _i in 3:
		r.apply_tick(w, 0.25)
	_expect(sink.texts == ["a"], "relay: stage 1 waits for the countdown (%s)" % str(sink.texts))
	r.apply_tick(w, 0.25)
	_expect(sink.texts == ["a", "b"], "relay: stage 1 shows when the countdown is out (%s)" % str(sink.texts))
	w.forward = Vector3.RIGHT
	r.apply_tick(w, 0.25)
	_expect(sink.texts == ["a", "b", "aborted"] and r.get_fired_count() == 0, "relay: looking away aborts and restarts (%s)" % str(sink.texts))
	r.apply_tick(w, 0.25)
	_expect(sink.texts.count("aborted") == 1, "relay: the abort is announced once")
	w.forward = Vector3.FORWARD
	for _i in 9:
		r.apply_tick(w, 0.25)
	_expect(not r.is_done() and r.get_fired_count() == 3, "relay: a negative stage is out on the next tick, the last stage has not shown")
	r.apply_tick(w, 0.25)
	_expect(r.is_done() and sink.texts.back() == "d", "relay: the last stage completes the scan (%s)" % str(sink.texts))


func _check_condition() -> void:
	var w := _world()
	var on := [false]
	var c := ConditionObjective.new("c", "Safe", func() -> bool: return on[0])
	c.apply_tick(w, 0.25)
	_expect(not c.is_done(), "condition: open while the condition fails")
	on[0] = true
	_expect(c.apply_tick(w, 0.25) and c.is_done(), "condition: done while it holds")
	on[0] = false
	c.apply_tick(w, 0.25)
	_expect(not c.is_done(), "condition: open again when it stops holding")


func _check_code_source() -> void:
	var w := _world()
	w.alive = false
	var level := [1]
	var rule := PlayerKilledRule.new(5, "killed")
	_expect(rule.make_verdict(w, 0.25).code == 5, "fail rule: the fixed code")
	rule.code_source = func() -> int: return 5 + level[0]
	_expect(rule.make_verdict(w, 0.25).code == 6, "fail rule: a code source gives the code at verdict time")


func _check_set() -> void:
	var w := _world()
	var set := ObjectiveSet.new()
	var a := DestroyObjective.new("a", "Destroy", ["t"])
	var side := ScriptObjective.new("side", "Bonus")
	side.primary = false
	side.required = false
	var late := ScriptObjective.new("late", "Later")
	late.state = Objective.State.PENDING
	late.required = false
	set.apply_add(side)
	set.apply_add(a)
	set.apply_add(late)
	_expect(set.make_lines().map(func(l: Dictionary) -> String: return l.text) == ["Destroy", "Bonus"], "lines: primary first, pending hidden")
	_expect(not set.is_complete() and not set.has_failed(), "not complete, not failed at the start")
	w.destroyed["t"] = true
	set.apply_tick(w, 0.25)
	_expect(set.is_complete() and (w.sink as MissionSink) != null, "complete when the required ones are done")
	_expect(set.get_objective("a").is_done() and set.get_objective("zz") == null, "objectives are found by id")
	late.apply_activate()
	_expect(set.make_lines().size() == 3, "an activated objective shows")
	_expect(set.get_objectives().size() == 3 and set.get_objectives()[0] == side, "objectives are listed in the order added")
	_expect(set.apply_remove("side") and not set.apply_remove("side") and set.get_count() == 2, "an objective can be removed once")
	var failing := ObjectiveSet.new()
	var p := ProtectObjective.new("p", "Guard", ["u"])
	failing.apply_add(p)
	w.dead_units["u"] = true
	failing.apply_tick(w, 0.25)
	_expect(failing.has_failed() and not failing.is_complete(), "a required objective failing fails the set")


class CountingSink:
	extends MissionSink
	var changes := 0
	func apply_objectives_changed() -> void:
		changes += 1


func _check_fail_rules() -> void:
	var w := _world()
	var rules := [
		PlayerKilledRule.new(1, "killed", 8.0),
		LeftAreaRule.new(2, "left", 4.9),
		ProtectedLostRule.new(3, "guard lost", ["base"]),
	]
	_expect(FailRule.make_first_verdict(rules, w, 0.25) == null, "no rule has anything to say")
	w.out_seconds = 5.0
	var v := FailRule.make_first_verdict(rules, w, 0.25)
	_expect(v != null and v.code == 2 and not v.success, "left area after the grace")
	w.alive = false
	v = FailRule.make_first_verdict(rules, w, 0.25)
	_expect(v.code == 1 and v.delay == 8.0, "the first rule in order wins, with its debrief delay")
	w.alive = true
	w.out_seconds = 0.0
	w.dead_units["base"] = true
	_expect(FailRule.make_first_verdict(rules, w, 0.25).code == 3, "a lost guarded unit")
	var lim := TimeLimitRule.new(4, "time", 1.0)
	_expect(lim.make_verdict(w, 0.5) == null and lim.make_verdict(w, 0.5).code == 4, "time limit runs out")
	var win := TimeLimitRule.new(5, "held", 1.0, true)
	_expect(win.make_verdict(w, 1.0).success, "a survival time limit wins")
	var obj := ScriptObjective.new("o", "x")
	var hit := ObjectiveHitRule.new(6, "obj lost", obj)
	_expect(hit.make_verdict(w, 0.0) == null, "objective hit: nothing yet")
	obj.apply_state(Objective.State.FAILED)
	_expect(hit.make_verdict(w, 0.0).code == 6, "objective hit: failed")
	var stale := StalemateRule.new(7, "draw")
	w.living = [1, 0]
	_expect(stale.make_verdict(w, 0.0) == null, "stalemate: someone lives")
	w.living = [0, 0]
	_expect(stale.make_verdict(w, 0.0).code == 7, "stalemate: nobody lives")


func _check_waves() -> void:
	var spawned := []
	var alive := {"g1": 0}
	var wd := WaveDirector.new(
		func(group: String, count: int) -> void:
			spawned.append("%s x%d" % [group, count])
			alive[group] = int(alive.get(group, 0)) + count,
		func(group: String) -> int: return int(alive.get(group, 0)))
	wd.apply_add(SpawnWave.make_wave("g1", "start", 4))
	wd.apply_add(SpawnWave.make_wave("g2", "region:3", 2, 5.0))
	wd.apply_add(SpawnWave.make_wave("g3", "timer:a", 1, 0.0, 10.0))
	_expect(not wd.is_group_wiped_out("g1"), "a group that has not come is not wiped out")
	wd.apply_trigger("start")
	_expect(spawned == ["g1 x4"], "start brings its wave at once")
	wd.apply_trigger("region:3")
	wd.apply_tick(4.0)
	_expect(spawned.size() == 1, "an arrival waits for its delay")
	wd.apply_tick(1.5)
	_expect(spawned == ["g1 x4", "g2 x2"], "then it comes (%s)" % str(spawned))
	wd.apply_trigger("timer:a")
	wd.apply_tick(10.5)
	wd.apply_tick(10.0)
	_expect(spawned.count("g3 x1") == 3, "repeat_every brings batches again (%s)" % str(spawned))
	alive["g1"] = 0
	_expect(wd.is_group_wiped_out("g1"), "a group that came and died is wiped out")
	alive["g1"] = 1
	_expect(not wd.is_group_wiped_out("g1"), "one alive is not")
