class_name ES2GroupOrders
extends RefCounted
## Earthsiege 2 per-group order lists (docs/formats/es2.md 10.8): each group works through its
## order records; an order ends when it completes or its activation region fires, then the next
## one is applied to the group's AI pilots.

## ES2 order type -> Earthsiege 1 order code understood by AIPilot.order_from_original:
## 0 search/destroy, 1 ramming, 2 guarding, 3 patrolling, 4 sleeping, 5 travelling, 6 following
const ORDER_CODES := [1, 3, 6, 8, 10, 11, 11]
const DEFAULT_ORDER_CODE := 8
const ORDER_PATROL := 3
## Distance at which a group member counts as at the end of its path.
const PATH_END_RADIUS := 40.0

var rt: MissionRuntimeES2
var group_order := {}             # group index -> position in its order list
var group_done_paths := {}        # group index -> [path index of each completed order]


func _init(runtime: MissionRuntimeES2) -> void:
	rt = runtime


func orders_of(gi: int) -> Array:
	return MissionRuntime._arr(rt.m.groups[gi].get("order_list"))


## The group's current order record, or null when its list is done.
func current_order(gi: int) -> Variant:
	var ol := orders_of(gi)
	var k := int(group_order.get(gi, 0))
	var orders: Array = MissionRuntime._arr(rt.m.get("orders"))
	if k < ol.size() and int(ol[k]) < orders.size():
		return orders[int(ol[k])]
	return null


## AI settings of an order record: {order (ES1 code), path (Array[Vector3]), loop, type}.
func make_ai_settings(o) -> Dictionary:
	var out := {"order": DEFAULT_ORDER_CODE, "path": [], "loop": true, "type": -1}
	if not o is Dictionary:
		return out
	var pts := []
	for p in MissionRuntime._arr(o.get("path_points")):
		pts.append(rt.on_ground(MissionRuntime.to_godot(p)))
	if pts.is_empty() and o.get("position") != null:
		pts.append(rt.on_ground(MissionRuntime.to_godot(o.position)))
	out.path = pts
	var t := int(o.get("type", ORDER_PATROL))
	out.type = t
	out.order = ORDER_CODES[t] if t >= 0 and t < ORDER_CODES.size() else DEFAULT_ORDER_CODE
	# patrol completes at the end of its path (then the next order); without one keep looping
	out.loop = t == ORDER_PATROL
	return out


## Starts a group's list at its first order (or keeps its position).
func start_group(gi: int) -> void:
	group_order[gi] = int(group_order.get(gi, 0))
	apply_order(gi)


func apply_order(gi: int) -> void:
	var o = current_order(gi)
	if o == null:
		return
	var ai := make_ai_settings(o)
	var tnodes: Array = rt.target_nodes(o.get("target")) if o.get("target") is Dictionary else []
	var path: Array[Vector3] = []
	for p in ai.path:
		path.append(p)
	for u in rt.group_units.get(gi, []):
		if not is_instance_valid(u) or not u.alive:
			continue
		if u is Flyer:
			_route_flyer(u, path)
			continue
		for p in u.get_children():
			if p is AIPilot:
				_apply_to_pilot(u, p, ai, path, tnodes)


static func _route_flyer(u: Flyer, path: Array[Vector3]) -> void:
	if path.is_empty():
		return
	u.patrol.clear()
	for v in path:
		u.patrol.append(v + Vector3.UP * u.altitude)


static func _apply_to_pilot(u: Node, p: AIPilot, ai: Dictionary, path: Array[Vector3], targets: Array) -> void:
	p.order = AIPilot.order_from_original(int(ai.order))
	if not path.is_empty():
		p.patrol_points = path.duplicate()
		p.patrol_index = 0
	p.loop_path = ai.loop
	for t in targets:
		if is_instance_valid(t) and t.alive and t is Herc and t.team != u.team:
			u.target = t
			p.engaging = true
			break


## Order completion (DBSIM 0x4239fc): 0/2 target destroyed, 3/5/6 end of path reached, 1/4 never.
func is_complete(gi: int, o: Dictionary) -> bool:
	match int(o.get("type", ORDER_PATROL)):
		0, 2:
			return o.get("target") is Dictionary and rt.target_state(o.target) == "dead"
		3, 5, 6:
			return _path_end_reached(gi, o)
	return false


func _path_end_reached(gi: int, o: Dictionary) -> bool:
	var pts: Array = MissionRuntime._arr(o.get("path_points"))
	if pts.is_empty():
		return false
	var goal := MissionRuntime.to_godot(pts[-1])
	if gi == 0:
		return rt.nav_index >= rt.nav_points.size()
	for u in rt.group_units.get(gi, []):
		if is_instance_valid(u) and u.alive \
				and Vector2(u.global_position.x - goal.x, u.global_position.z - goal.z).length() < PATH_END_RADIUS:
			return true
	return false


## Advances every group whose current order completed (or was skipped by its region firing).
func update() -> void:
	for gi in rt.group_units:
		var o = current_order(gi)
		if o == null:
			continue
		var done := is_complete(gi, o)
		var skipped: bool = o.get("region") != null and int(o.region) < rt.regions.size() and rt.regions[int(o.region)].fired
		if done:
			if not group_done_paths.has(gi):
				group_done_paths[gi] = []
			group_done_paths[gi].append(int(o.get("path", -1)))
		if done or skipped:
			group_order[gi] = int(group_order.get(gi, 0)) + 1
			if current_order(gi) != null:
				apply_order(gi)
