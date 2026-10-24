extends Node
## Tribes: Vengeance mission scripts (tools/tv_script.py -> maps/<id>/script.json, run by TVScriptHost on a MissionTask) against a recording host:
## every map's level-start scripts run for a simulated minute without error, speak and add objectives; a hand-made script checks
## the interpreter (waits, ifs, variables, loops, blocking calls, messages); Revenge-Ascent's flow ends the mission on the
## target's death.
##   TV_TEST_ROOT=<data folder with tribes_v/> godot --headless --audio-driver Dummy --path game res://tests/tv_script_check.tscn
const PACK := "tribes_v"
const SOLDIER_OP_TICKS := 1800
const MIN_SOLDIER_ROOKS := 50
## Places two rooks name that the original maps do not have (SP-Prison-Interior, SP-Truth-Hunt): the original has nowhere to put them either.
const MISSING_ROOK_PLACES := ["NoteConsolSpawnPoint2", "NoteAmbush3Spawn"]
var _fails := 0
var _speech := AudioStreamPlayer.new()


## What the script machine reaches in the game, recorded: the radio overlay's lines and the calls on the soldiers.
class Host:
	extends RefCounted
	var spoken: Array = []
	var events: Array = []
	var ended := -1
	var nav_points: Array[Vector3] = []
	var nav_index := 0
	var battle := Overlay.new()
	var host: TVScriptHost
	func _init(scripts: Array, player: AudioStreamPlayer, actors := {}) -> void:
		battle.owner_host = self
		host = TVScriptHost.new(self, scripts, actors, player)
	func has_overlay() -> bool:
		return true
	func make_speaker_name(label: String) -> String:
		return label
	func apply_enable(label: String, on: bool) -> void:
		events.append(["enable" if on else "disable", label])
	func apply_destroy(label: String) -> void:
		events.append(["destroy", label])
	func apply_spawn_point(label: String, on: bool) -> void:
		events.append(["spawn_on" if on else "spawn_off", label])
	func apply_teleport(label: String, to: String) -> void:
		events.append(["teleport", label, to])
	func apply_damage(label: String, amount: float) -> void:
		events.append(["damage", label, amount])
	func apply_goal(label: String, mode: String, name: String, goal: Dictionary) -> void:
		events.append(["goal", label, mode, name, goal])
	func apply_spawn_npc(rook: Dictionary, at: Array) -> void:
		events.append(["spawn_npc", rook, at])
	func apply_spawn_vehicle(vehicle_class: String, label: String, team: String, at: Array) -> void:
		events.append(["spawn_vehicle", vehicle_class, label, team, at])
	func apply_enter_vehicle(character: String, vehicle: String) -> void:
		events.append(["enter_vehicle", character, vehicle])
	func apply_end(success: bool) -> void:
		ended = 1 if success else 0


class Overlay:
	extends RefCounted
	var owner_host: Host
	var overlay := self
	var player = null
	func show_radio(_speaker: String, text: String) -> void:
		owner_host.spoken.append(text)
	func show_message(text: String, _seconds: float) -> void:
		owner_host.events.append(["prompt", text])


func _ready() -> void:
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	add_child(_speech)
	var root := OS.get_environment("TV_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	_check_interpreter()
	_check_goals()
	if Assets.has_pack(PACK):
		_check_maps()
	print("tv_script_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _check_interpreter() -> void:
	var scripts := [
		{"label": "Global", "name": "S0", "message": "MessageLevelStart", "by": ["all"], "enabled": true, "actions": [
			{"op": "var", "kind": "init", "name": "n", "value": "0"},
			{"op": "exec", "script": "main", "block": true},
			{"op": "speak", "tag": "AFTER", "text": "AFTER", "target": "", "wait": false}]},
		{"label": "main", "name": "S1", "message": "", "by": [], "enabled": true, "actions": [
			{"op": "var", "kind": "inc", "name": "n", "value": "1"},
			{"op": "wait", "s": 1.0},
			{"op": "if", "tests": [{"lhs": {"var": "n"}, "rhs": {"lit": "1"}}], "then": [{"op": "speak", "tag": "ONE", "text": "ONE", "wait": true}],
				"else": [{"op": "speak", "tag": "OTHER", "text": "OTHER", "wait": true}]},
			{"op": "loop", "actions": [{"op": "var", "kind": "inc", "name": "n", "value": "1"}, {"op": "if", "tests": [{"lhs": {"var": "n"}, "rhs": {"lit": "4"}}],
				"then": [{"op": "exit_loop"}], "else": []}, {"op": "wait", "s": 0.1}]}]},
		{"label": "onDeath", "name": "S2", "message": "MessageDeath", "by": ["Boss"], "enabled": true, "actions": [
			{"op": "obj_add", "name": "o", "text": "Kill", "markers": []}, {"op": "obj_status", "name": "o", "status": 1}, {"op": "next"}]},
		{"label": "never", "name": "S3", "message": "MessageDeath", "by": ["Other"], "enabled": true, "actions": [{"op": "fail"}]}]
	var h := Host.new(scripts, _speech)
	var run := h.host.tasks
	run.fire("MessageLevelStart", "all")
	run.tick(0.1)
	_expect(h.spoken.is_empty(), "the blocking call holds the caller (and the wait holds the callee)")
	for _i in 30:
		run.tick(0.1)
	_expect(h.spoken.has("ONE") and h.spoken.has("AFTER"), "if / else, wait and the caller's continuation run: %s" % str(h.spoken))
	_expect(not h.spoken.has("OTHER"), "the false branch does not run")
	_expect(str(h.host.vars.get("n")) == "4", "variables increment and the loop exits (n = %s)" % str(h.host.vars.get("n")))
	_expect(not run.is_running(), "every task finished")
	run.fire("MessageDeath", "Other2")
	_expect(h.ended == -1, "a death of another label starts nothing")
	run.fire("MessageDeath", "Boss")
	run.tick(0.1)
	_expect(h.ended == 1 and h.host.make_objective_records().map(func(o: Dictionary) -> int: return o.state) == [1], "the target's death completes the objective and ends the mission")


## TVNpcGoals: the goal of highest priority steers a brain (a recording stand-in), replace / remove, patrols.
class FakeBrain:
	extends Node
	var soldier := Node3D.new()
	var objective := {}
	var guard_point := Vector3.ZERO
	var guard_radius := 0.0


func _check_goals() -> void:
	var brain := FakeBrain.new()
	add_child(brain)
	brain.soldier.name = "Soldier"
	add_child(brain.soldier)
	var e := {"brain": brain, "goals": {}}
	var spawn := Vector3(10, 0, 10)
	var actors := {"NodeA": [50.0, 0.0, 0.0], "NodeB": [60.0, 0.0, 0.0]}
	var player := Vector3(5, 0, 5)
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.guard_point == spawn and brain.guard_radius == TVNpcGoals.GUARD_RADIUS and brain.objective.is_empty(), "no goal: guard the spawn")
	TVNpcGoals.apply(e, "replace", TVNpcGoals.DEFAULT_GOAL, {"kind": "move", "name": "Move", "priority": 100, "dest": "NodeA"})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.objective.get("point") == Vector3(50, 0, 0) and bool(brain.objective.urgent), "a move goal walks to its node (urgent at priority 100)")
	TVNpcGoals.apply(e, "add", "", {"kind": "guard", "name": "Guard", "priority": 30, "center": "Player", "radius": 28.0})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.objective.has("point"), "the higher priority goal wins")
	TVNpcGoals.apply(e, "remove", "Move", {})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.objective.is_empty() and brain.guard_point == player and brain.guard_radius == 28.0, "removing it leaves the player-centred guard area")
	TVNpcGoals.apply(e, "remove", "Guard", {})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.guard_radius == TVNpcGoals.IDLE_RADIUS, "default removed and nothing left: hold still")
	TVNpcGoals.apply(e, "add", "", {"kind": "patrol", "name": "Patrol", "priority": 50, "points": ["NodeA", "NodeB"], "once": true})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.objective.get("point") == Vector3(50, 0, 0), "a patrol starts at its first node")
	brain.soldier.global_position = Vector3(50, 0, 0)
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.objective.get("point") == Vector3(60, 0, 0), "reaching a node sends the patrol to the next")
	brain.soldier.global_position = Vector3(60, 0, 0)
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect((e.goals as Dictionary).is_empty(), "a once-only patrol ends at its last node")
	TVNpcGoals.apply(e, "add", "", {"kind": "attack", "name": "A", "priority": 52, "target": "Player"})
	TVNpcGoals.steer(e, actors, player, spawn)
	_expect(brain.guard_radius == 0.0, "an attack goal hunts the enemy across the map")
	_check_enter_goal(brain)
	_check_goal_orders()


## The enter-vehicle goal walks the soldier to the vehicle (the vehicle's script position when it is not in the world) through an AIOrder.
func _check_enter_goal(brain: FakeBrain) -> void:
	var e := {"brain": brain, "goals": {}}
	var actors := {"Pod1": [30.0, 0.0, 40.0]}
	TVNpcGoals.apply(e, "add", "", {"kind": "enter_vehicle", "name": "Enter", "priority": 75, "vehicle": "Pod1", "seat": 0})
	TVNpcGoals.steer(e, actors, Vector3.ZERO, Vector3.ZERO)
	_expect(brain.objective.get("point") == Vector3(30, 0, 40) and bool(brain.objective.urgent) and brain.objective.radius == TVNpcGoals.BOARD_POINT_RADIUS_M,
		"an enter-vehicle goal walks, urgently, to the vehicle's place %s" % [brain.objective])
	TVNpcGoals.steer(e, {}, Vector3.ZERO, Vector3.ZERO)
	_expect(brain.objective.is_empty(), "a vehicle the script knows nothing of gives no order")
	_expect(TVNpcGoals.make_boarding_goal(e, func(_label: String) -> Herc: return null).is_empty(), "he does not board a vehicle that is not there")


## The goals that walk become AIOrders of the shared kind and objective.
func _check_goal_orders() -> void:
	var order := TVNpcGoals.make_move_order({"dest": "NodeA", "priority": 100}, {"NodeA": [1.0, 2.0, 3.0]}, Vector3.ZERO)
	_expect(order != null and order.kind == AIOrder.MOVE and order.urgent and order.to_objective().point == Vector3(1, 2, 3), "a move goal is a MOVE AIOrder")
	_expect(TVNpcGoals.make_move_order({"dest": "Nowhere"}, {}, Vector3.ZERO) == null, "an unknown node gives no order")


func _check_maps() -> void:
	var idx = Assets.load_json("maps/_index.json", PACK)
	if not (idx is Array):
		return
	var scripted := 0
	var with_end := 0
	var with_objectives := 0
	var goal_ops := 0
	for e in idx:
		var path := Assets.path("maps/%s/script.json" % e.id, PACK)
		if not FileAccess.file_exists(path):
			continue
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (data is Dictionary):
			continue
		scripted += 1
		var h := Host.new(data.scripts, _speech, data.get("actors", {}))
		var run := h.host.tasks
		run.fire("MessageLevelStart", "all")
		run.fire("MessagePlayerStart", "all")
		for _i in 600:
			run.tick(0.1)
		goal_ops += h.events.filter(func(ev: Array) -> bool: return ev[0] == "goal").size()
		if not h.host.make_objective_records().is_empty():
			with_objectives += 1
		else:
			print("note  %s adds no objective in its first minute (spoken %d, events %d, still running %s)" % [e.id, h.spoken.size(), h.events.size(), str(run.running_labels())])
		var ends := JSON.stringify(data.scripts).contains("\"op\":\"next\"")
		if ends:
			with_end += 1
	_expect(goal_ops > 0, "%d AI goal ops reached the host in the first minutes" % goal_ops)
	_check_soldier_ops(idx)
	_expect(scripted >= 29, "%d maps carry scripts" % scripted)
	_expect(with_end == scripted, "every scripted map has a mission end (%d of %d)" % [with_end, scripted])
	_expect(with_objectives >= scripted / 3, "%d maps add an objective in their first minute" % with_objectives)
	var m := Assets.path("maps/SP-Revenge-Ascent/script.json", PACK)
	if FileAccess.file_exists(m):
		var data = JSON.parse_string(FileAccess.get_file_as_string(m))
		var h := Host.new(data.scripts, _speech, data.get("actors", {}))
		var run := h.host.tasks
		run.fire("MessagePlayerStart", "all")
		for _i in 80:
			run.tick(0.1)
		_expect(h.host.make_objective_records().any(func(o: Dictionary) -> bool: return str(o.name) == "objCaptureDaniel"), "Revenge-Ascent: the first objective appears after the 5 s wait")
		run.fire("MessageDeath", "AIDaniel")
		for _i in 50:
			run.tick(0.1)
		_expect(h.ended == 1, "Revenge-Ascent: Daniel's death wins the mission")


## The soldier ActionSpawnRook ops of the maps: a body of the pack, a team, a place; the host receives them when the script runs.
func _check_soldier_ops(idx: Array) -> void:
	var bodies := {}
	for b in InfantryCatalog.make_tv_all_bodies():
		bodies[str(b.id)] = true
	var found := 0
	var bad := 0
	var reached := 0
	for e in idx:
		var path := Assets.path("maps/%s/script.json" % e.id, PACK)
		var data = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		if not (data is Dictionary):
			continue
		var ops := _collect_ops(data.scripts, "spawn_npc")
		for op in ops:
			found += 1
			var placed: bool = (data.get("actors", {}) as Dictionary).has(str(op.get("at", ""))) or MISSING_ROOK_PLACES.has(str(op.get("at", "")))
			if not bodies.has(str(op.get("body", ""))) or str(op.get("team", "")) == "" or not placed or float(op.get("health", 0.0)) <= 0.0:
				bad += 1
		if ops.is_empty():
			continue
		var h := Host.new(data.scripts, _speech, data.get("actors", {}))
		var run := h.host.tasks
		run.fire("MessageLevelStart", "all")
		run.fire("MessagePlayerStart", "all")
		for _i in SOLDIER_OP_TICKS:
			run.tick(0.1)
		reached += h.events.filter(func(ev: Array) -> bool: return ev[0] == "spawn_npc").size()
	_expect(found >= MIN_SOLDIER_ROOKS and bad == 0, "%d soldier rooks in the scripts, each with a pack body, a team, a place and a health (%d bad)" % [found, bad])
	_expect(reached > 0, "%d of them reached the host when the first minutes of the scripts ran" % reached)


## Every action of `op` in the action trees `actions`.
static func _collect_ops(actions: Variant, op: String) -> Array:
	var out := []
	if actions is Array:
		for a in actions:
			out.append_array(_collect_ops(a, op))
	elif actions is Dictionary:
		if str(actions.get("op", "")) == op:
			out.append(actions)
		for key in ["actions", "then", "else"]:
			out.append_array(_collect_ops(actions.get(key, []), op))
		if actions.has("scripts"):
			out.append_array(_collect_ops(actions.scripts, op))
	return out
