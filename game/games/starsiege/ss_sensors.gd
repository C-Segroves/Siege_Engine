class_name SSSensors
extends RefCounted
## Proximity events of a Starsiege mission: trigger boxes (trigger::onEnter / onContact / onLeave)
## and the scan approximation (onScan = the player keeps a target locked within SCAN_RANGE for SCAN_TIME).

const SCAN_RANGE := 600.0
const SCAN_TIME := 2.0
## Vertical slack of trigger boxes (the .mis boxes are often flat; vehicles stand above them).
const TRIGGER_HEIGHT_SLACK := 20.0
const DEFAULT_BOX_MIN := [-10, -10, -10]
const DEFAULT_BOX_MAX := [10, 10, 10]

var rt: StarsiegeMissionRuntime
var tree: SSObjectTree
var _inside := {}          # trigger id -> {vehicle obj id: true}
var _scan := {"target": 0, "t": 0.0, "done": {}}


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime
	tree = runtime.tree


func check_triggers() -> void:
	for id in tree.ids_of_kind("trigger"):
		_check_trigger(id)


func _check_trigger(id: int) -> void:
	var o: Dictionary = tree.objects[id]
	var centre: Vector3 = (o.node as Node3D).global_position
	var inside: Dictionary = _inside.get(id, {})
	var now := {}
	for nid in rt.battle.vehicles:
		var h: Herc = rt.battle.vehicles[nid]
		if not h.alive:
			continue
		var vid := SSObjectTree.id_of_node(h)
		if vid == 0 or not _in_box(o.def, h.global_position - centre):
			continue
		now[vid] = true
		var event := "oncontact" if inside.has(vid) else "onenter"
		rt.raise_object_callback(id, "trigger", event, [id, vid])
	for vid in inside:
		if not now.has(vid):
			rt.raise_object_callback(id, "trigger", "onleave", [id, vid])
	_inside[id] = now


## Box test in the original frame (x east, y north, z up) around the trigger position.
static func _in_box(d: Dictionary, rel: Vector3) -> bool:
	var mn: Array = d.get("box_min", DEFAULT_BOX_MIN)
	var mx: Array = d.get("box_max", DEFAULT_BOX_MAX)
	var orig := StarsiegeMissionRuntime.eng_to_orig(rel)
	return orig.x >= float(mn[0]) and orig.x <= float(mx[0]) and orig.y >= float(mn[1]) and orig.y <= float(mx[1]) \
		and orig.z >= float(mn[2]) - TRIGGER_HEIGHT_SLACK and orig.z <= float(mx[2]) + TRIGGER_HEIGHT_SLACK


func check_scan(dt: float) -> void:
	var pl: Herc = rt.battle.player
	if pl == null or not is_instance_valid(pl) or not pl.alive or not is_instance_valid(pl.target):
		_scan.t = 0.0
		return
	var tid := SSObjectTree.id_of_node(pl.target)
	if tid == 0 or pl.global_position.distance_to(pl.target.global_position) > SCAN_RANGE:
		_scan.t = 0.0
		return
	if tid != int(_scan.target):
		_scan.target = tid
		_scan.t = 0.0
	_scan.t += dt
	if _scan.t >= SCAN_TIME and not _scan.done.has(tid):
		_scan.done[tid] = true
		rt.raise_object_callback(tid, tree.callback_kind(tid), "onscan", [tid, SSObjectTree.id_of_node(pl), ""])
