class_name TribesContacts
extends RefCounted
## What the player's soldier touches in a training mission (host, every TribesMissionRuntime.CHECK_INTERVAL), the
## engine's collision callbacks of the originals (only the player: the training bots take no items or objectives):
##   items      an Item within ITEM_REACH                      -> runtime.on_item_touched(item, player)
##   shapes     a shape with a touch callback within SHAPE_REACH (switches, flags, flag stands, flip-flops)
##                                                             -> runtime.on_shape_touched(shape, player), once
##                                                                per approach
##   triggers   a Trigger whose box / sphere holds the soldier  -> runtime.on_trigger(trigger, player, entered)
##   area       the mission area (Tribes MissionCenterPos x y w h, Tribes 2 MissionArea area "x y w h")
##                                                             -> runtime.on_mission_area(player, inside)
## Candidate objects are re-listed every RESCAN_SECONDS (scripts make and delete objects).
## The interact action (InfantryInteraction offer, make_interact_offer) does the same for the nearest item or touch
## shape within reach plus INTERACT_EXTRA_REACH: an explicit pickup / switch press.

## Horizontal / vertical reach of an item pickup (metres; the soldier's capsule against the item's box).
const ITEM_REACH := Vector2(2.0, 2.5)
## Reach of a shape's touch: a tower switch or flag stand is a few metres across.
const SHAPE_REACH := Vector2(3.0, 3.5)
const RESCAN_SECONDS := 1.0
const INTERACT_EXTRA_REACH := 1.0
## The player's key in the area triggers' candidate lists (the id of his soldier changes with every respawn).
const PLAYER_KEY := "player"

var rt: TribesMissionRuntime
var _items: Array = []
var _shapes: Array = []
var _triggers: Array = []
var _touching := {}             # shape id -> true while the player stays within reach
var _trigger_areas := {}         # trigger id -> AreaTrigger (holds whether the player is inside)
var _mission_area: AreaTrigger
var _rescan_t := 0.0
var _has_area := false
var _scan_pid := 0          # the player's id during the checks the area triggers answer in


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime
	_mission_area = AreaTrigger.new(AreaShape.make_box(Vector3.ZERO, Vector3.ZERO))
	_mission_area.apply_assume_inside(PLAYER_KEY)   # the player starts inside: only leaving and returning are told
	_mission_area.entered.connect(func(_who: Variant) -> void: rt.on_mission_area(_scan_pid, true))
	_mission_area.left.connect(func(_who: Variant) -> void: rt.on_mission_area(_scan_pid, false))


## The mission area in the original frame (x east, y north): set by the game when the mission defines one.
func set_area(area: Rect2) -> void:
	_has_area = area.size != Vector2.ZERO
	var middle := area.get_center()
	_mission_area.shape = AreaShape.make_box(Vector3(middle.x, 0.0, middle.y), Vector3(area.size.x, 0.0, area.size.y))


func update() -> void:
	var pid := rt.actors.player_of(rt.actors.human_client)
	var s := rt.actors.soldier_of(pid)
	if s == null or not s.alive:
		return
	_rescan_t -= TribesMissionRuntime.CHECK_INTERVAL
	if _rescan_t <= 0.0:
		_rescan_t = RESCAN_SECONDS
		_rescan()
	var p := s.global_position
	_check_items(pid, p)
	_check_shapes(pid, p)
	_check_triggers(pid, p)
	_check_area(pid, p)


func _rescan() -> void:
	_items.clear()
	_shapes.clear()
	_triggers.clear()
	for id in rt.sim.objects:
		var rec: Dictionary = rt.sim.objects[id]
		if rec.get("is_datablock", false) or rec.get("hidden", false):
			continue
		var cls := String(rec.class).to_lower()
		if cls == "item" and not rt.is_carried(id):
			_items.append(id)
		elif cls == "trigger":
			_triggers.append(id)
		if rt.is_touchable(id):
			_shapes.append(id)


## Interact offer (InfantryInteraction provider) for the player's `soldier`: the nearest item or touch shape in reach.
func make_interact_offer(soldier: Infantry) -> Dictionary:
	var pid := rt.actors.player_of(rt.actors.human_client)
	if soldier != rt.actors.soldier_of(pid):
		return {}
	var p := soldier.global_position
	var best := {}
	for id in _items + _shapes:
		if not rt.sim.exists(id) or rt.sim.objects[id].get("hidden", false):
			continue
		var is_item := _items.has(id)
		var reach: Vector2 = (ITEM_REACH if is_item else SHAPE_REACH) + Vector2.ONE * INTERACT_EXTRA_REACH
		var q := rt.sim.position_of(id)
		if not is_within(p, q, reach) or (not best.is_empty() and p.distance_to(q) >= float(best.distance)):
			continue
		best = {"distance": p.distance_to(q), "text": _make_offer_text(id, is_item),
			"apply": (func() -> void: rt.on_item_touched(id, pid)) if is_item else (func() -> void: rt.on_shape_touched(id, pid))}
	return best


func _make_offer_text(id: int, is_item: bool) -> String:
	if is_item:
		return "pick up %s" % rt.item_models.make_item_name(id) if rt.item_models else "pick up"
	var shape_name := String(rt.sim.get_record(id).get("name", ""))
	return "use %s" % (shape_name if shape_name != "" else "the switch")


static func is_within(p: Vector3, q: Vector3, reach: Vector2) -> bool:
	return Vector2(p.x - q.x, p.z - q.z).length() <= reach.x and absf(p.y + 1.0 - q.y) <= reach.y


func _check_items(pid: int, p: Vector3) -> void:
	for id in _items.duplicate():
		if not rt.sim.exists(id) or rt.sim.objects[id].get("hidden", false):
			_items.erase(id)
		elif is_within(p, rt.sim.position_of(id), ITEM_REACH):
			rt.on_item_touched(id, pid)


func _check_shapes(pid: int, p: Vector3) -> void:
	for id in _shapes:
		if not rt.sim.exists(id):
			continue
		var near := is_within(p, rt.sim.position_of(id), SHAPE_REACH)
		if near and not _touching.has(id):
			_touching[id] = true
			rt.on_shape_touched(id, pid)
		elif not near:
			_touching.erase(id)


func _check_triggers(pid: int, p: Vector3) -> void:
	_scan_pid = pid
	var o := _make_area_frame(TribesSimObjects.to_original(p))
	for id in _triggers:
		if not rt.sim.exists(id):
			continue
		var area := _make_trigger_area(id)
		var shape := _make_trigger_shape(id)
		if shape != null:
			area.shape = shape
		area.apply_scan({PLAYER_KEY: o} if shape != null else {})


## The AreaTrigger of trigger `id` (made on first use; it remembers whether the player is inside).
func _make_trigger_area(id: int) -> AreaTrigger:
	if not _trigger_areas.has(id):
		var area := AreaTrigger.new(AreaShape.make_sphere(Vector3.ZERO, 0.0))
		area.entered.connect(func(_who: Variant) -> void: rt.on_trigger(id, _scan_pid, true))
		area.left.connect(func(_who: Variant) -> void: rt.on_trigger(id, _scan_pid, false))
		_trigger_areas[id] = area
	return _trigger_areas[id]


## Tribes trigger: boundingBox "x0 y0 z0 x1 y1 z1" around its position, a sphere when isSphere is true (null without a box).
func _make_trigger_shape(id: int) -> AreaShape:
	var f: Dictionary = rt.sim.objects[id].fields
	var box := DarkstarStdLib.make_parts(DarkstarScript.to_str(f.get("boundingbox", "")), " ")
	if box.size() < 6:
		return null
	var lo := Vector3(float(box[0]), float(box[1]), float(box[2]))
	var hi := Vector3(float(box[3]), float(box[4]), float(box[5]))
	var center := _make_area_frame(TribesSimObjects.to_original(rt.sim.position_of(id)) + (lo + hi) * 0.5)
	if DarkstarScript.truthy(f.get("issphere", false)):
		return AreaShape.make_sphere(center, (hi - lo).x * 0.5)
	return AreaShape.make_box(center, _make_area_frame(hi - lo))


## The original frame (x east, y north, z up) as the area shapes' (x, up, z): horizontal in x and z.
static func _make_area_frame(o: Vector3) -> Vector3:
	return Vector3(o.x, o.z, o.y)


func _check_area(pid: int, p: Vector3) -> void:
	if not _has_area:
		return
	_scan_pid = pid
	var o := TribesSimObjects.to_original(p)
	_mission_area.apply_scan({PLAYER_KEY: Vector3(o.x, 0.0, o.y)})
