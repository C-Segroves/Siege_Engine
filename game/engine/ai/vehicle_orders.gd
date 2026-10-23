class_name VehicleOrders
extends RefCounted
## Gives a crewed vehicle an AIOrder whatever it is: a flyer (its FlyerAI flies the `patrol` path and hunts `target`) or a ground vehicle
## (its AIPilot child follows the route, goes to the objective or holds). A game that orders its vehicles (a mission script's goals, a
## command, a wingman radio) builds an AIOrder and calls apply(); the brains differ, the order does not.

## A flyer told to hold a place circles it: this many points on this radius (m).
const HOLD_POINTS := 4
const HOLD_RADIUS := 60.0


## Sets `order` on the AI of `h`. Returns false when `h` has no AI to take it.
static func apply(h: Herc, order: AIOrder) -> bool:
	if h is Flyer:
		return _apply_to_flyer(h as Flyer, order)
	var pilot := find_pilot(h)
	if pilot == null:
		return false
	_apply_to_pilot(pilot, order)
	return true


static func find_pilot(h: Herc) -> AIPilot:
	for c in h.get_children():
		if c is AIPilot:
			return c
	return null


## The flyer's circle round `at`.
static func make_hold_circle(at: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in HOLD_POINTS:
		var a := TAU * float(i) / HOLD_POINTS
		out.append(at + Vector3(cos(a), 0.0, sin(a)) * HOLD_RADIUS)
	return out


static func _apply_to_pilot(p: AIPilot, order: AIOrder) -> void:
	p.objective = order.to_objective()
	if not AIOrder.is_command_kind(order.kind):
		order.apply_to_pilot(p)
	if order.kind == AIOrder.ATTACK and order.target is Herc:
		AIOrder.apply_engage(p, order.target as Herc)


static func _apply_to_flyer(f: Flyer, order: AIOrder) -> bool:
	if f.ai == null:
		return false
	var route: Array[Vector3] = _make_flyer_route(order)
	if not route.is_empty():
		f.patrol.clear()
		for v in route:
			f.patrol.append(v + Vector3.UP * f.altitude)
		f.patrol_i = 0
	if order.kind == AIOrder.ATTACK and order.target is Herc:
		f.target = order.target as Herc
	return true


## The points a flyer flies for `order`: its route, a command's place (a hold circles it), none for an attack.
static func _make_flyer_route(order: AIOrder) -> Array[Vector3]:
	if not order.path.is_empty():
		return order.path
	if order.kind == AIOrder.MOVE or order.kind == AIOrder.REGROUP:
		return [order.point] as Array[Vector3]
	if order.kind == AIOrder.GUARD or order.kind == AIOrder.DEFEND or order.kind == AIOrder.HOLD:
		return make_hold_circle(order.point)
	return [] as Array[Vector3]
