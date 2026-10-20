extends Node
## Async path queue (BattleNavigation.request_path, NavPathQueue, InfantryBotRoute), headless, on a flat test floor:
## 200 requests are answered, no more than PATHS_PER_TICK leave the queue per tick, and a route with a path request
## out goes straight at its goal meanwhile (the fallback of a map without navigation).
##   godot --headless --audio-driver Dummy --path game res://tests/nav_async_check.tscn

const ASKERS := 200
const FLOOR_SIZE := 160.0
const LIMIT_FRAMES := 1200

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	var world := _make_world()
	var nav := BattleNavigation.of(world)
	await _check_requests_answered(nav)
	_check_route_goes_straight_while_waiting(world, nav)
	world.queue_free()
	print("nav_async_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _make_world() -> Node3D:
	var world := Node3D.new()
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(FLOOR_SIZE, 1.0, FLOOR_SIZE)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0, -0.5, 0)
	world.add_child(floor_body)
	add_child(world)
	return world


func _check_requests_answered(nav: BattleNavigation) -> void:
	for i in ASKERS:
		nav.request_path(i, Vector3(-40 + i % 20, 0.2, -30), Vector3(40, 0.2, 20 - i % 7))
	_expect(nav.waiting_path_count() == ASKERS, "%d requests wait in the queue" % ASKERS)
	var answered := 0
	var empty_answers := 0
	var max_left_per_tick := 0
	var frames := 0
	var waiting := nav.waiting_path_count()
	while answered < ASKERS and frames < LIMIT_FRAMES:
		await get_tree().physics_frame
		frames += 1
		max_left_per_tick = maxi(max_left_per_tick, waiting - nav.waiting_path_count())
		waiting = nav.waiting_path_count()
		for i in ASKERS:
			if nav.has_path_answer(i):
				if nav.take_path_answer(i).size() >= 2:
					answered += 1
				else:
					empty_answers += 1
					# asked while the map was still taking tiles in: asks again, as the route does
					nav.request_path(i, Vector3(-40 + i % 20, 0.2, -30), Vector3(40, 0.2, 20 - i % 7))
	print("  answered %d (%d asked again) in %d frames, at most %d left the queue in one tick" % [answered, empty_answers, frames, max_left_per_tick])
	_expect(answered == ASKERS, "every request is answered with a path")
	_expect(max_left_per_tick <= BattleNavigation.PATHS_PER_TICK, "no more than %d requests leave the queue per tick" % BattleNavigation.PATHS_PER_TICK)


func _check_route_goes_straight_while_waiting(world: Node3D, nav: BattleNavigation) -> void:
	var route := InfantryBotRoute.new()
	var goal := Vector3(60, 0, 0)
	var point := route.make_next_point(world, Vector3(-50, 0.2, 0), goal, InfantryBotRoute.SPENT_REPATH_SECONDS + 0.1)
	_expect(point == goal, "with no path yet the route heads straight for the goal")
	_expect(route.make_path().is_empty() and nav.waiting_path_count() <= 1, "no path is adopted without an answer")
