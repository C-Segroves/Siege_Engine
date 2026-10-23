class_name SSSensors
extends RefCounted
## Proximity events of a Starsiege mission: trigger boxes (AreaTrigger: trigger::onEnter / onContact / onLeave)
## and the scan approximation (ScanObjective: onScan = the player keeps a target locked within the profile's scan range
## for its scan time).

## Remake approximation of onScan (no original value): 600 m, 2 s. The lock is the aim, so no view cone
## (SSMissionWorld.is_target_in_view).
const SCAN_RANGE_M := 600.0
const SCAN_SECONDS := 2.0
## Vertical slack of trigger boxes (the .mis boxes are often flat; vehicles stand above them).
const TRIGGER_HEIGHT_SLACK := 20.0
const DEFAULT_BOX_MIN := [-10, -10, -10]
const DEFAULT_BOX_MAX := [10, 10, 10]

var rt: StarsiegeMissionRuntime
var tree: SSObjectTree
var _areas := {}           # trigger id -> AreaTrigger
var _presence := []        # [vehicle obj id, callback event] of the scan in progress, in order
var _entered := {}         # vehicle obj ids that entered in the scan in progress (their first contact is the enter)
var _left := []            # vehicle obj ids that left in the scan in progress
var _world: SSMissionWorld
var _scan: ScanObjective = null
var _scanned := {}         # target obj id -> true once its onScan was raised
var _profile := SSSensors.make_profile()


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime
	tree = runtime.tree
	_world = SSMissionWorld.new(runtime)


## Starsiege's sensor numbers.
static func make_profile() -> SensorProfile:
	var profile := SensorProfile.make_default()
	profile.scan_range_m = SCAN_RANGE_M
	profile.scan_seconds = SCAN_SECONDS
	return profile


func check_triggers() -> void:
	for id in tree.ids_of_kind("trigger"):
		_check_trigger(id)


## Scans trigger `id` for the living vehicles: enter / contact events in vehicle order, then the leave events.
func _check_trigger(id: int) -> void:
	var o: Dictionary = tree.objects[id]
	var area := _get_area(id)
	area.shape = _make_shape(o.def, (o.node as Node3D).global_position)
	var candidates := {}
	for nid in rt.battle.vehicles:
		var h: Herc = rt.battle.vehicles[nid]
		var vid := SSObjectTree.id_of_node(h)
		if h.alive and vid != 0:
			candidates[vid] = h.global_position
	_presence.clear()
	_entered.clear()
	_left.clear()
	area.apply_scan(candidates)
	for p in _presence:
		rt.raise_object_callback(id, "trigger", p[1], [id, p[0]])
	for vid in _left:
		rt.raise_object_callback(id, "trigger", "onleave", [id, vid])


func _get_area(id: int) -> AreaTrigger:
	if not _areas.has(id):
		var area := AreaTrigger.new(null)
		area.entered.connect(func(vid) -> void:
			_entered[vid] = true
			_presence.append([vid, "onenter"]))
		area.contact.connect(func(vid) -> void:
			if not _entered.has(vid):
				_presence.append([vid, "oncontact"]))
		area.left.connect(func(vid) -> void: _left.append(vid))
		_areas[id] = area
	return _areas[id]


## The trigger's box (corners in the original frame: x east, y north, z up) around its position, as an engine-frame box.
static func _make_shape(d: Dictionary, position: Vector3) -> AreaShape:
	var mn: Array = d.get("box_min", DEFAULT_BOX_MIN)
	var mx: Array = d.get("box_max", DEFAULT_BOX_MAX)
	var mid := Vector3(float(mn[0]) + float(mx[0]), float(mn[1]) + float(mx[1]), float(mn[2]) + float(mx[2])) * 0.5
	var size := Vector3(float(mx[0]) - float(mn[0]), float(mx[1]) - float(mn[1]), float(mx[2]) - float(mn[2]))
	return AreaShape.make_box(position + StarsiegeMissionRuntime.orig_to_eng(mid.x, mid.y, mid.z),
		StarsiegeMissionRuntime.orig_to_eng(size.x, size.y, size.z).abs(), TRIGGER_HEIGHT_SLACK)


## Raises onScan once per target the player has kept locked in range for the scan time.
func check_scan(dt: float) -> void:
	var pl: Herc = rt.battle.player
	if pl == null or not is_instance_valid(pl) or not pl.alive or not is_instance_valid(pl.target):
		_scan = null
		return
	var tid := SSObjectTree.id_of_node(pl.target)
	if tid == 0:
		_scan = null
		return
	if _scan == null or _scan.target != str(tid):
		_scan = ScanObjective.new("scan", "", str(tid), _profile.scan_range_m, [{"seconds": _profile.scan_seconds, "text": ""}])
		_scan.cone_degrees = _profile.scan_cone_degrees
	_world.locked_target = pl.target
	if not _scanned.has(tid) and _scan.apply_tick(_world, dt):
		_scanned[tid] = true
		rt.raise_object_callback(tid, tree.callback_kind(tid), "onscan", [tid, SSObjectTree.id_of_node(pl), ""])
