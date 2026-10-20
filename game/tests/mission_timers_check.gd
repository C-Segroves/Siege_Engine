extends Node
## MissionTimer, MissionTimers, AreaShape, AreaTrigger, WaypointChain, MissionVars (engine/mission/).
##   godot --headless --audio-driver Dummy --path game res://tests/mission_timers_check.tscn

const WATCHDOG_SECONDS := 30.0

var _fails := 0
var _events: Array = []


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
	_check_one_shot()
	_check_repeating()
	_check_while()
	_check_timers()
	_check_shapes()
	_check_trigger()
	_check_chain()
	_check_vars()
	print("mission_timers_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _check_one_shot() -> void:
	var t := MissionTimer.make_timer(1.0)
	_expect(not t.apply_tick(0.5) and is_equal_approx(t.make_time_left(), 0.5), "a one-shot timer counts down")
	_expect(t.apply_tick(0.5) and t.is_finished(), "it runs out at its time")
	_expect(not t.apply_tick(5.0), "and never again")
	var u := MissionTimer.make_timer(1.0)
	u.armed = false
	_expect(not u.apply_tick(5.0), "an unarmed timer does not count")
	u.apply_arm()
	_expect(not u.apply_tick(0.9) and u.apply_tick(0.2), "armed, it counts from zero")


func _check_repeating() -> void:
	var t := MissionTimer.make_timer(1.0, MissionTimer.Mode.REPEATING)
	var runs := 0
	for _i in 10:
		if t.apply_tick(0.35):
			runs += 1
	_expect(runs == 3, "a repeating timer runs out every period (3.5 s / 1 s = %d)" % runs)
	_expect(not t.is_finished(), "and is never finished")


func _check_while() -> void:
	var on := [true]
	var t := MissionTimer.make_timer(3.0, MissionTimer.Mode.WHILE)
	t.condition = func() -> bool: return on[0]
	t.apply_tick(2.0)
	on[0] = false
	t.apply_tick(1.0)
	on[0] = true
	_expect(not t.apply_tick(2.0), "a WHILE timer starts over when its condition breaks")
	_expect(t.apply_tick(1.0), "it runs out after a whole stretch")
	_expect(not t.apply_tick(1.0), "once per stretch")
	on[0] = false
	t.apply_tick(0.1)
	on[0] = true
	_expect(t.apply_tick(3.0), "and again after the next stretch")


func _check_timers() -> void:
	var ts := MissionTimers.new()
	ts.apply_add("a", MissionTimer.make_timer(2.0, MissionTimer.Mode.ONE_SHOT, "pa"))
	ts.apply_add("b", MissionTimer.make_timer(1.0, MissionTimer.Mode.ONE_SHOT, "pb"))
	ts.apply_add("c", MissionTimer.make_timer(5.0, MissionTimer.Mode.ONE_SHOT, "pc"))
	_expect(ts.is_pending("a") and is_equal_approx(ts.make_time_left("c"), 5.0), "timers are pending with their time left")
	ts.apply_cancel("c")
	_expect(not ts.is_pending("c") and ts.make_time_left("c") == 0.0, "a cancelled timer is gone")
	_expect(ts.apply_tick(1.5) == ["pb"], "the payload of the timer that ran out comes back")
	_expect(not ts.is_pending("b") and ts.is_pending("a"), "a finished timer is removed")
	_expect(ts.apply_tick(1.0) == ["pa"], "in time order of adding when several run out")
	ts.apply_add("r", MissionTimer.make_timer(1.0, MissionTimer.Mode.REPEATING, "pr"))
	ts.apply_add("o", MissionTimer.make_timer(2.5, MissionTimer.Mode.ONE_SHOT, "po"))
	var fired := ts.apply_advance(3.0)
	_expect(fired.count("pr") == 3 and fired.count("po") == 1, "apply_advance fast-forwards a cut-scene (%s)" % str(fired))
	_expect(ts.make_ids() == ["r"], "make_ids lists the timers held in adding order (%s)" % str(ts.make_ids()))
	ts.apply_clear()
	_expect(not ts.is_pending("r") and ts.make_ids().is_empty(), "apply_clear drops everything")


func _check_shapes() -> void:
	var c := AreaShape.make_circle(Vector3(10, 0, 0), 5.0, 30.0)
	_expect(c.is_inside(Vector3(39, 100, 0)) and not c.is_inside(Vector3(41, 0, 0)), "a circle keeps its minimum radius and ignores height")
	var b := AreaShape.make_box(Vector3.ZERO, Vector3(10, 4, 20), 20.0)
	_expect(b.is_inside(Vector3(4.9, 21.9, 9.9)) and not b.is_inside(Vector3(5.1, 0, 0)) and not b.is_inside(Vector3(0, 22.1, 0)),
		"a box has its extents and its height slack")
	var y := AreaShape.make_cylinder(Vector3.ZERO, 3.0, 4.0, 2.5)
	_expect(y.is_inside(Vector3(2.9, 4.4, 0)) and not y.is_inside(Vector3(0, 4.6, 0)) and not y.is_inside(Vector3(3.1, 0, 0)),
		"a cylinder has its radius and its height slack")
	var ball := AreaShape.make_sphere(Vector3(0, 10, 0), 3.0)
	_expect(ball.is_inside(Vector3(0, 12.9, 0)) and not ball.is_inside(Vector3(0, 13.1, 0)) and not ball.is_inside(Vector3(2.5, 12, 0)),
		"a sphere reaches its radius in every direction")


func _on_event(id: Variant, tag: String) -> void:
	_events.append("%s:%s" % [tag, str(id)])


func _check_trigger() -> void:
	var trig := AreaTrigger.new(AreaShape.make_circle(Vector3.ZERO, 10.0))
	trig.entered.connect(_on_event.bind("in"))
	trig.contact.connect(_on_event.bind("touch"))
	trig.left.connect(_on_event.bind("out"))
	trig.apply_scan({"a": Vector3(50, 0, 0)})
	_expect(_events.is_empty() and not trig.is_occupied(), "nothing inside, nothing said")
	trig.apply_scan({"a": Vector3(5, 0, 0)})
	trig.apply_scan({"a": Vector3(6, 0, 0)})
	_expect(_events == ["in:a", "touch:a", "touch:a"], "entered once, contact every tick (%s)" % str(_events))
	_events.clear()
	trig.apply_scan({"a": Vector3(60, 0, 0)})
	_expect(_events == ["out:a"] and not trig.is_occupied(), "left on the tick it is outside")
	_events.clear()
	trig.apply_scan({"a": Vector3(1, 0, 0)})
	trig.apply_scan({})
	_expect(_events == ["in:a", "touch:a", "out:a"], "a thing that disappears has left (%s)" % str(_events))
	_events.clear()
	var primed := AreaTrigger.new(AreaShape.make_circle(Vector3.ZERO, 10.0))
	primed.entered.connect(_on_event.bind("in"))
	primed.left.connect(_on_event.bind("out"))
	primed.apply_assume_inside("a")
	primed.apply_scan({"a": Vector3(1, 0, 0)})
	primed.apply_scan({"a": Vector3(60, 0, 0)})
	primed.apply_scan({"a": Vector3(1, 0, 0)})
	_expect(_events == ["out:a", "in:a"], "a thing assumed inside only tells its leaving, then its return (%s)" % str(_events))
	_events.clear()
	var picky := AreaTrigger.new(AreaShape.make_circle(Vector3.ZERO, 10.0))
	picky.filter = func(id: Variant) -> bool: return str(id).begins_with("x")
	picky.entered.connect(_on_event.bind("in"))
	picky.apply_scan({"y1": Vector3.ZERO, "x1": Vector3.ZERO})
	_expect(_events == ["in:x1"], "a filter picks who counts")
	_events.clear()
	var once := AreaTrigger.new(AreaShape.make_circle(Vector3.ZERO, 10.0))
	once.one_shot = true
	once.entered.connect(_on_event.bind("in"))
	once.apply_scan({"a": Vector3.ZERO})
	once.apply_scan({"a": Vector3(99, 0, 0)})
	once.apply_scan({"a": Vector3.ZERO})
	_expect(_events == ["in:a"] and once.is_spent(), "a one-shot trigger fires once")
	_events.clear()
	var capped := AreaTrigger.new(AreaShape.make_circle(Vector3.ZERO, 10.0))
	capped.max_enter = 2
	capped.entered.connect(_on_event.bind("in"))
	capped.apply_scan({"a": Vector3.ZERO, "b": Vector3.ZERO, "c": Vector3.ZERO})
	_expect(_events.size() == 2, "max_enter limits the entries (%d)" % _events.size())
	_events.clear()
	capped.left.connect(_on_event.bind("out"))
	capped.apply_scan({})
	_expect(_events.size() == 3 and _events.has("out:c"), "a thing past max_enter is still told when it leaves (%s)" % str(_events))


func _check_chain() -> void:
	var pts: Array[Vector3] = [Vector3(0, 0, 0), Vector3(100, 0, 0)]
	var ch := WaypointChain.new(pts, 15.0)
	_expect(not ch.apply_reach(Vector3(50, 0, 0)) and ch.index == 0, "too far reaches nothing")
	_expect(ch.apply_reach(Vector3(10, 0, 0)) and ch.index == 1 and ch.make_current() == pts[1], "within the radius moves on to the next point")
	_expect(not ch.apply_reach(Vector3(0, 0, 0)), "points are reached in order")
	_expect(ch.apply_reach(Vector3(100, 0, 10)) and ch.is_complete() and ch.make_remaining() == 0, "the last point completes the chain")
	_expect(ch.make_current() == pts[1] and not ch.apply_reach(pts[1]), "a complete chain stays on its last point")


func _check_vars() -> void:
	var ops := {1: "set", 2: "add", 3: "sub", 4: "copy", 5: "max", 6: "div"}
	var tests := {1: "eq", 2: "gt", 3: "le"}
	var v := MissionVars.new(10, ops, tests)
	v.apply_op(1, 3, 7)
	v.apply_op(2, 3, 5)
	v.apply_op(3, 3, 2)
	_expect(v.get_value(3) == 10, "set, add and sub run through the table (%d)" % v.get_value(3))
	v.apply_op(4, 4, 3)
	v.apply_op(5, 4, 99)
	v.apply_op(6, 4, 0)
	_expect(v.get_value(4) == 99, "copy, max, and divide by zero changes nothing (%d)" % v.get_value(4))
	_expect(not v.apply_op(77, 0, 1) and v.get_value(0) == 0, "an opcode the table lacks does nothing")
	_expect(v.make_test(1, 3, 10) and v.make_test(2, 3, 9) and v.make_test(3, 3, 10) and not v.make_test(9, 3, 10), "tests run through their table")
	_expect(v.get_value(99) == 0, "an index out of range reads 0")
