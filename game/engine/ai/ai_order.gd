class_name AIOrder
extends RefCounted
## One order for an AI unit, whatever game gives it (mission script, command map, wingman radio, game mode) and
## whichever brain carries it out (AIPilot, InfantryBot). Two families of kinds:
##   commands  attack, move, defend, hold, escort, formation, regroup (docs/COMMAND_MAP.md section 2): become the brains'
##             `objective` dictionary ({point, urgent, radius, hold, target}) through to_objective();
##   pilot     search, guard, patrol, travel, sleep, ram: the Earthsiege order set (docs/formats/es2.md 10.8, DBSIM
##             order types; Starsiege order() maps onto the same six), set on an AIPilot through apply_to_pilot().
## `formation` is the follower's slot index in its commander's formation (Formation), -1 when none.

const ATTACK := "attack"
const MOVE := "move"
const DEFEND := "defend"
const HOLD := "hold"
const ESCORT := "escort"
const FORMATION := "formation"
const REGROUP := "regroup"
const SEARCH := "search"
const GUARD := "guard"
const PATROL := "patrol"
const TRAVEL := "travel"
const SLEEP := "sleep"
const RAM := "ram"
const COMMAND_KINDS := [ATTACK, MOVE, DEFEND, HOLD, ESCORT, FORMATION, REGROUP]
const PILOT_KINDS := [SEARCH, GUARD, PATROL, TRAVEL, SLEEP, RAM]

## How close a place counts as reached (metres): soldiers and vehicles.
const ARRIVE_RADIUS := 15.0
const ESCORT_RADIUS := 10.0

var kind := ""
var target: Node3D = null
var point := Vector3.ZERO
var radius := ARRIVE_RADIUS
var urgent := false
var hold := false
var formation := -1
## Pilot kinds: the route (patrol / travel), whether it repeats (when `sets_loop`), and a point to hold (guard here).
var path: Array[Vector3] = []
var loop := true
var sets_loop := false
var anchored := false
## The speed the order asks for (m/s; 0 = the brain's own pace): a flyer's cruise, a ground vehicle's speed on its route.
var speed := 0.0
## The game's own name for the order's target (a script tag) and its source record, for the game's completion rule.
var tag := ""
var source: Variant = null


## A command order of `kind` at `point` against `target`: the arrival radius and urgency of each kind.
static func make(p_kind: String, p_point: Vector3, p_target: Node3D = null) -> AIOrder:
	var o := AIOrder.new()
	o.kind = p_kind
	o.point = p_point
	o.target = p_target
	match p_kind:
		MOVE, REGROUP:
			o.urgent = true
			o.hold = true
		ATTACK, DEFEND, HOLD:
			o.hold = true
		ESCORT:
			o.hold = true
			o.radius = ESCORT_RADIUS
	return o


## An order with its own numbers (a game mode's goal, a mission script's task).
static func make_plan(p_kind: String, p_point: Vector3, p_urgent: bool, p_radius: float, p_hold: bool,
		p_target: Node3D = null) -> AIOrder:
	var o := AIOrder.new()
	o.kind = p_kind
	o.point = p_point
	o.urgent = p_urgent
	o.radius = p_radius
	o.hold = p_hold
	o.target = p_target
	return o


## A pilot order of `kind` along `p_path` (empty: stays where it is).
static func make_route(p_kind: String, p_path: Array[Vector3], p_loop: bool) -> AIOrder:
	var o := AIOrder.new()
	o.kind = p_kind
	o.path = p_path.duplicate()
	o.loop = p_loop
	o.sets_loop = true
	return o


## Hold position at `p_point`: guard it, no route.
static func make_hold_at(p_point: Vector3) -> AIOrder:
	var o := AIOrder.new()
	o.kind = GUARD
	o.point = p_point
	o.anchored = true
	return o


## This order at `p_speed` m/s (0 = the brain's own pace); returns the order.
func with_speed(p_speed: float) -> AIOrder:
	speed = maxf(p_speed, 0.0)
	return self


static func is_command_kind(p_kind: String) -> bool:
	return COMMAND_KINDS.has(p_kind)


## The AIPilot.Order of a pilot kind (patrol for anything else).
static func make_pilot_order(p_kind: String) -> int:
	match p_kind:
		SEARCH: return AIPilot.Order.SEARCH
		GUARD: return AIPilot.Order.GUARD
		TRAVEL: return AIPilot.Order.TRAVEL
		SLEEP: return AIPilot.Order.SLEEP
		RAM: return AIPilot.Order.RAM
	return AIPilot.Order.PATROL


## The brains' objective of a command order ({} for formation: the leader does it, and for pilot kinds).
func to_objective() -> Dictionary:
	if not is_command_kind(kind) or kind == FORMATION:
		return {}
	var out := {"point": point, "urgent": urgent, "radius": radius, "hold": hold}
	if target != null:
		out["target"] = target
	return out


## Sets a pilot order on `pilot`: its order, and the route or hold point when the order has one.
func apply_to_pilot(pilot: AIPilot) -> void:
	pilot.order = make_pilot_order(kind)
	if not path.is_empty():
		pilot.patrol_points = path.duplicate()
		pilot.patrol_index = 0
	if anchored:
		pilot.guard_point = point
		pilot.patrol_points.clear()
	if sets_loop:
		pilot.loop_path = loop


## Makes `pilot` fight `foe` now.
static func apply_engage(pilot: AIPilot, foe: Node3D) -> void:
	pilot.herc.target = foe
	pilot.engaging = true
