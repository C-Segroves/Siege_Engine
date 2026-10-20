class_name CallinAirRunner
extends RefCounted
## What every air call-in runner shares (host). A runner is handed a validated CallinRequest by CallinAir and owns the
## sequence of its kind: it never picks a point of its own. It drives the CallinOrder through its states, spawns the
## aircraft as an AI flyer (CallinAirframes: a normal battle vehicle, so it goes through EntityTable and the snapshots
## like any other), and takes it out of the battle when it is gone. Subclasses: CallinBombingRun, CallinAttackCraft.

## The aircraft is taken out this many seconds after the order, however far it got (s): a stuck autopilot must not stay.
const LEAVING_SLACK_S := 25.0
const MIN_SPEED_MPS := 1.0
## Half the side of the rect used when the battlefield has no playable area (m).
const NO_AREA_HALF_M := 100000.0

var callins: CallinDirector
## order id -> CallinAirFlight.
var flights := {}


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## The call-in kind this runner runs (CallinRules.KIND_*).
func get_kind() -> String:
	return ""


## "" when the runner can fly `request`, else the HUD reason (what the shared checks leave open).
func make_refusal(_request: CallinRequest) -> String:
	return ""


## Host: the order is made; the runner plans the flight. Subclasses extend it.
func apply_start(_order: CallinOrder, _request: CallinRequest) -> void:
	pass


## Host, every physics frame of an open order.
func apply_tick_order(_order: CallinOrder, _delta: float) -> void:
	pass


## Host: the caller is dead or gone from the raid.
func apply_caller_gone(_peer: int) -> void:
	pass


## Tells `peer` a line on his screen (through the call-in telling, so a test tap sees it).
func apply_tell(peer: int, text: String) -> void:
	callins.send_to(peer, callins.director, "_notify", [text])


func make_rule() -> Dictionary:
	return CallinRules.rule(get_kind())


func make_flight(order: CallinOrder) -> CallinAirFlight:
	return flights.get(order.id)


## The aircraft of `flight` (null before it appears and after it left or was destroyed and removed).
func make_craft(flight: CallinAirFlight) -> Flyer:
	if flight.craft_id < 0:
		return null
	var craft = callins.battle.vehicles.get(flight.craft_id)
	return craft as Flyer if is_instance_valid(craft) else null


## Host: the order was cancelled: the aircraft goes at once.
func apply_cancel(order: CallinOrder) -> void:
	var flight := make_flight(order)
	if flight == null:
		return
	_remove_craft(flight)
	flights.erase(order.id)


## Host, every physics frame: aircraft whose order is over leave the battle when their flight is done.
func apply_tick(delta: float) -> void:
	for id in flights.keys():
		var flight: CallinAirFlight = flights[id]
		if not flight.is_leaving:
			continue
		flight.leaving_left -= delta
		var craft := make_craft(flight)
		if craft == null or flight.leaving_left <= 0.0 or (flight.pilot != null and flight.pilot.call("is_done")):
			_remove_craft(flight)
			flights.erase(id)


## The order is over: the aircraft flies on (or lies as a wreck) for at most `seconds`, then it is removed.
func apply_leaving(flight: CallinAirFlight, seconds: float) -> void:
	flight.is_leaving = true
	flight.leaving_left = seconds


func _remove_craft(flight: CallinAirFlight) -> void:
	if flight.craft_id >= 0 and callins.battle.vehicles.has(flight.craft_id):
		callins.battle.remove_vehicle(flight.craft_id)
	flight.craft_id = -1


## The playable area as a rect shrunk by `inset` metres (the whole battlefield when the map says nothing).
func make_area(inset: float) -> Rect2:
	var map := callins.director.map
	if map != null:
		return Rect2(map.bounds_min, map.bounds_max - map.bounds_min).grow(-inset)
	var bounds := callins.battle.bounds
	if bounds != null and bounds.bounds.has_area:
		return bounds.bounds.area.grow(-inset)
	return Rect2(-NO_AREA_HALF_M, -NO_AREA_HALF_M, NO_AREA_HALF_M * 2.0, NO_AREA_HALF_M * 2.0)


## The flat unit direction of `request`: its own, else the way the caller faces.
func make_direction(request: CallinRequest) -> Vector3:
	var caller := callins.battle.occupancy.soldier_of(request.peer)
	return request.make_direction(-caller.global_basis.z if caller != null else Vector3.ZERO)


## `point` with y on the ground.
func make_on_ground(point: Vector3) -> Vector3:
	return Vector3(point.x, MapBuilder.ground_height(callins.battle, point), point.z)


## Seconds for `metres` at `speed` m/s.
static func make_seconds(metres: float, speed: float) -> float:
	return metres / maxf(speed, MIN_SPEED_MPS)
