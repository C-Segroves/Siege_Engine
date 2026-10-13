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

var rt: TribesMissionRuntime
var _items: Array = []
var _shapes: Array = []
var _triggers: Array = []
var _touching := {}             # shape id -> true while the player stays within reach
var _inside := {}               # trigger id -> true while the player is inside
var _in_area := true
var _area := Rect2()
var _rescan_t := 0.0


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime


## The mission area in the original frame (x east, y north): set by the game when the mission defines one.
func set_area(area: Rect2) -> void:
	_area = area


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
	for id in _triggers:
		if not rt.sim.exists(id):
			continue
		var inside := _is_in_trigger(id, p)
		if inside != _inside.has(id):
			if inside:
				_inside[id] = true
			else:
				_inside.erase(id)
			rt.on_trigger(id, pid, inside)


## Tribes trigger: boundingBox "x0 y0 z0 x1 y1 z1" around its position, a sphere when isSphere is true.
func _is_in_trigger(id: int, p: Vector3) -> bool:
	var f: Dictionary = rt.sim.objects[id].fields
	var o := TribesSimObjects.to_original(p) - TribesSimObjects.to_original(rt.sim.position_of(id))
	var box := DarkstarStdLib.make_parts(DarkstarScript.to_str(f.get("boundingbox", "")), " ")
	if box.size() < 6:
		return false
	var lo := Vector3(float(box[0]), float(box[1]), float(box[2]))
	var hi := Vector3(float(box[3]), float(box[4]), float(box[5]))
	if DarkstarScript.truthy(f.get("issphere", false)):
		var r := (hi - lo).x * 0.5
		return (o - (lo + hi) * 0.5).length() <= r
	return o.x >= lo.x and o.y >= lo.y and o.z >= lo.z and o.x <= hi.x and o.y <= hi.y and o.z <= hi.z


func _check_area(pid: int, p: Vector3) -> void:
	if _area.size == Vector2.ZERO:
		return
	var o := TribesSimObjects.to_original(p)
	var inside := _area.has_point(Vector2(o.x, o.y))
	if inside != _in_area:
		_in_area = inside
		rt.on_mission_area(pid, inside)
