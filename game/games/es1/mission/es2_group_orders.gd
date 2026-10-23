class_name ES2GroupOrders
extends RefCounted
## Earthsiege 2 per-group order lists (docs/formats/es2.md 10.8): each group works through its
## order records; an order ends when it completes or its activation region fires, then the next
## one is applied to the group's AI pilots.

## ES2 order type -> Earthsiege 1 order code understood by AIPilot.order_from_original (battle spawn info):
## 0 search/destroy, 1 ramming, 2 guarding, 3 patrolling, 4 sleeping, 5 travelling, 6 following
const ORDER_CODES := [1, 3, 6, 8, 10, 11, 11]
const DEFAULT_ORDER_CODE := 8
## The same types as shared pilot order kinds.
const TYPE_KINDS := [AIOrder.SEARCH, AIOrder.RAM, AIOrder.GUARD, AIOrder.PATROL, AIOrder.SLEEP, AIOrder.TRAVEL, AIOrder.TRAVEL]
const ORDER_PATROL := 3
## Distance at which a group member counts as at the end of its path.
const PATH_END_RADIUS := 40.0

var rt: MissionRuntimeES2
var queues := {}                  # group index -> OrderQueue of its order list (AIOrder per record, source = the record)
var group_done_paths := {}        # group index -> [path index of each completed order]


func _init(runtime: MissionRuntimeES2) -> void:
	rt = runtime


func orders_of(gi: int) -> Array:
	return MissionRuntime._arr(rt.m.groups[gi].get("order_list"))


## The group's order list, made on first use: an entry per listed record (null for one the mission does not have).
func queue_of(gi: int) -> OrderQueue:
	if not queues.has(gi):
		var queue := OrderQueue.new()
		var records: Array = MissionRuntime._arr(rt.m.get("orders"))
		for idx in orders_of(gi):
			queue.push(make_ai_order(records[int(idx)]) if int(idx) < records.size() else null)
		queues[gi] = queue
	return queues[gi]


## The group's current order record, or null when its list is done.
func current_order(gi: int) -> Variant:
	var order := queue_of(gi).current()
	return order.source if order != null else null


## The AIOrder of an order record (its path on the ground; patrol repeats its path, the others complete at its end);
## a missing record is the default patrol.
func make_ai_order(o) -> AIOrder:
	var pts: Array[Vector3] = []
	var t := ORDER_PATROL
	if o is Dictionary:
		for p in MissionRuntime._arr(o.get("path_points")):
			pts.append(rt.on_ground(MissionRuntime.to_godot(p)))
		if pts.is_empty() and o.get("position") != null:
			pts.append(rt.on_ground(MissionRuntime.to_godot(o.position)))
		t = int(o.get("type", ORDER_PATROL))
	var order := AIOrder.make_route(TYPE_KINDS[t] if t >= 0 and t < TYPE_KINDS.size() else AIOrder.PATROL, pts, t == ORDER_PATROL)
	order.source = o if o is Dictionary else {"type": -1}
	return order


## The Earthsiege 1 order code of an order made by make_ai_order (the battle's spawn info).
static func make_es1_code(order: AIOrder) -> int:
	var t := int(order.source.get("type", -1))
	return ORDER_CODES[t] if t >= 0 and t < ORDER_CODES.size() else DEFAULT_ORDER_CODE


## Starts a group's list at its first order (or keeps its position).
func start_group(gi: int) -> void:
	apply_order(gi)


func apply_order(gi: int) -> void:
	var order := queue_of(gi).current()
	if order == null:
		return
	var targets: Array = rt.target_nodes(order.source.get("target")) if order.source.get("target") is Dictionary else []
	for u in rt.group_units.get(gi, []):
		if not is_instance_valid(u) or not u.alive:
			continue
		if u is Flyer:
			_route_flyer(u, order.path)
			continue
		for p in u.get_children():
			if p is AIPilot:
				_apply_to_pilot(u, p, order, targets)


static func _route_flyer(u: Flyer, path: Array[Vector3]) -> void:
	if path.is_empty():
		return
	u.patrol.clear()
	for v in path:
		u.patrol.append(v + Vector3.UP * u.altitude)


static func _apply_to_pilot(u: Node, p: AIPilot, order: AIOrder, targets: Array) -> void:
	order.apply_to_pilot(p)
	for t in targets:
		if is_instance_valid(t) and t.alive and t is Herc and t.team != u.team:
			AIOrder.apply_engage(p, t)
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
			queue_of(gi).advance()
			if current_order(gi) != null:
				apply_order(gi)
