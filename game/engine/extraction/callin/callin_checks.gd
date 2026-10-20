class_name CallinChecks
extends RefCounted
## What decides whether a call-in may be made (the validation half of CallinDirector): the facts about the caller
## (CallinRefusals judges them), then the designated point (CallinPlacement judges it in the physics world), plus the sizes
## and the saved vehicle those depend on.

## Metres past the footprint a scripted request is set in front of the caller (his own body is a unit on the ground).
const FEET_MARGIN_M := 1.5
const FEET_RINGS: Array[float] = [0.0, 8.0, 16.0]
const FEET_DIRECTIONS := 8

var callins: CallinDirector


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## The facts about `peer` that decide a call-in without the physics world (CallinRefusals).
func make_facts(peer: int, kind: String, variant: String) -> Dictionary:
	var soldier := callins.battle.occupancy.soldier_of(peer)
	var vehicle_id := make_vehicle_id(peer)
	var cooldowns := callins.cooldowns
	var facts := {"in_raid": callins.director.is_in_raid(peer), "downed": soldier != null and DownedState.is_downed(soldier),
		"balance": callins.points.get_balance(peer), "cost": CallinRules.make_cost(kind, variant, vehicle_id),
		"shared_left": cooldowns.make_shared_left(peer), "cool_left": cooldowns.make_cool_left(peer, kind),
		"used": cooldowns.make_used(peer, kind), "cap": int(CallinRules.rule(kind).get("max_per_raid", 0)),
		"in_flight": _count_in_flight(peer), "vehicle_id": vehicle_id, "installed": not Packs.vehicle(vehicle_id).is_empty(),
		"owned": true, "lost": false}
	if peer == callins.multiplayer.get_unique_id() and vehicle_id != "":
		facts.owned = RaidOperator.is_vehicle_owned(Net.player_name, vehicle_id)
		facts.lost = RaidOperator.is_vehicle_lost(Net.player_name, vehicle_id)
	return facts


## The same facts for the local player from what the host told him (the menu's "not available" text).
func make_local_facts(kind: String, variant: String) -> Dictionary:
	var peer := callins.multiplayer.get_unique_id()
	var vehicle_id := make_vehicle_id(peer)
	var my_state := callins.my_state
	var elapsed := 0.0
	if my_state.has("at_msec"):
		elapsed = float(Time.get_ticks_msec() - int(my_state.at_msec)) / 1000.0
	var cool := maxf(float(my_state.get("cool", {}).get(kind, 0.0)) - elapsed, 0.0)
	return {"in_raid": callins.director.my_status == ExtractionDirector.STATUS_IN_RAID, "downed": DownedState.is_downed(callins.battle.player),
		"balance": callins.points.mine, "cost": CallinRules.make_cost(kind, variant, vehicle_id),
		"shared_left": maxf(float(my_state.get("shared", 0.0)) - elapsed, 0.0), "cool_left": cool,
		"used": int(my_state.get("used", {}).get(kind, 0)), "cap": int(CallinRules.rule(kind).get("max_per_raid", 0)),
		"in_flight": _count_my_views(), "vehicle_id": vehicle_id, "installed": not Packs.vehicle(vehicle_id).is_empty(),
		"owned": vehicle_id == "" or RaidOperator.is_vehicle_owned(Net.player_name, vehicle_id),
		"lost": vehicle_id != "" and RaidOperator.is_vehicle_lost(Net.player_name, vehicle_id)}


## "" when the local player may call `kind` in, else why not (the menu).
func make_local_refusal(kind: String, variant: String) -> String:
	return CallinRefusals.make(kind, variant, make_local_facts(kind, variant))


## Host: "" when `peer` may make the call-in at his own feet, else the HUD reason (scripts and tests; players designate).
func make_refusal(peer: int, kind: String, variant: String) -> String:
	return make_plan(make_feet_request(peer, kind, variant)).reason


## The request of a script or a test: near `peer`'s soldier but clear of his own body: the first spot of a few rings round him
## (in front first) where the call-in can land, else just in front of him. Players designate; this is the old "my feet".
func make_feet_request(peer: int, kind: String, variant: String) -> CallinRequest:
	var soldier := callins.battle.occupancy.soldier_of(peer)
	var footprint := make_footprint(kind, make_vehicle_id(peer))
	var first := CallinRequest.make_at_feet(kind, variant, peer, soldier, footprint + FEET_MARGIN_M)
	if soldier == null or not bool(CallinPlacement.make_needs(kind).ground):
		return first
	var facing := first.point - soldier.global_position
	facing.y = 0.0
	for ring in FEET_RINGS:
		for i in FEET_DIRECTIONS:
			var at := soldier.global_position + facing.normalized().rotated(Vector3.UP, TAU * float(i) / FEET_DIRECTIONS) * (footprint + FEET_MARGIN_M + ring)
			var found := CallinSafety.make_reason_at(callins.battle, at, footprint, soldier.team)
			if found.reason == "" and not CallinSafety.is_covered(callins.battle, found.pos) and not _is_taken_by_order(found.pos, footprint):
				return CallinRequest.make(kind, variant, peer, found.pos)
	return first


## {ok, pos, reason} for `request`: the facts about the caller first (CallinRefusals), then the designated point
## (CallinPlacement: reach, area, open sky, the exact footprint, the approach). `pos` is the floor point the order lands on.
## `local` judges for the local player from what the host told him (the laser's live colour); the host judges from its tables.
func make_plan(request: CallinRequest, local := false) -> Dictionary:
	var kind := request.kind
	var facts := make_local_facts(kind, request.variant) if local else make_facts(request.peer, kind, request.variant)
	var why := CallinRefusals.make(kind, request.variant, facts)
	if why != "":
		return {"ok": false, "pos": request.point, "reason": why}
	var soldier := _make_local_soldier() if local else callins.battle.occupancy.soldier_of(request.peer)
	var footprint := make_footprint(kind, str(facts.vehicle_id))
	var plan := CallinPlacement.make_judgement(callins.battle, request, soldier, footprint, make_approach_from(request.kind, request.point))
	if bool(plan.ok) and bool(CallinPlacement.make_needs(kind).ground) and _is_taken_by_order(plan.pos, footprint):
		return {"ok": false, "pos": plan.pos, "reason": CallinPlacement.REASON_TAKEN}
	if bool(plan.ok) and callins.refusers.has(kind):
		why = str((callins.refusers[kind] as Callable).call(request))
		if why != "":
			return {"ok": false, "pos": plan.pos, "reason": why}
	return plan


## True when another call-in that lands on the ground is already coming down (or stands) on `pos`.
func _is_taken_by_order(pos: Vector3, footprint: float) -> bool:
	for o in callins.orders.values():
		var order := o as CallinOrder
		var gap := Vector2(order.lz.x - pos.x, order.lz.z - pos.z).length()
		if order.is_open() and bool(CallinPlacement.make_needs(order.kind).ground) and gap < order.radius + footprint:
			return true
	return false


## The local player's soldier: the one he walks, else (riding, on the command map) the one the occupancy keeps for him.
func _make_local_soldier() -> Infantry:
	if callins.battle.player is Infantry:
		return callins.battle.player as Infantry
	return callins.battle.occupancy.soldier_of(callins.multiplayer.get_unique_id())


## The point the flight in to `zone` starts from for a kind that needs a line of sight to it (Vector3.INF: none).
func make_approach_from(kind: String, zone: Vector3) -> Vector3:
	if not bool(CallinPlacement.make_needs(kind).approach) or callins.director.map == null:
		return Vector3.INF
	if kind == CallinRules.KIND_VEHICLE and CallinVehicleRun.pick_transport_id() == "":
		return Vector3.INF   # a pod brings it
	return callins.director.map.make_approach_point(zone, ExtractionRules.approach_distance(callins.battle.config))


## Metres of clear ground a call-in needs: a pod's, or a vehicle's hull and margin.
static func make_footprint(kind: String, vehicle_id: String) -> float:
	var table := CallinRules.lz()
	if kind != CallinRules.KIND_VEHICLE:
		return float(table.get("pod_radius_m", 3.0))
	var hull := clampf(float(Packs.vehicle(vehicle_id).get("height_m", 8.0)) * Herc.CAPSULE_RADIUS_FACTOR,
		Herc.CAPSULE_MIN_RADIUS, Herc.CAPSULE_MAX_RADIUS)
	return hull + float(table.get("vehicle_margin_m", 8.0))


## The vehicle id saved in `peer`'s character slot ("" when none): the roster's slot snapshot ("v"), else its
## "vehicle" key, and for the local player his active slot.
func make_vehicle_id(peer: int) -> String:
	var entry: Dictionary = callins.battle.config.get("roster", {}).get(peer, {})
	var slot = entry.get("slot")
	if slot is Dictionary and str(slot.get("v", "")) != "":
		return str(slot.v)
	if not Packs.vehicle(str(entry.get("vehicle", ""))).is_empty():
		return str(entry.vehicle)
	if peer == callins.multiplayer.get_unique_id():
		return OperatorProfile.load_for(Net.player_name).make_active_slot().vehicle
	return ""


func _count_in_flight(peer: int) -> int:
	return callins.orders.values().filter(func(o: CallinOrder) -> bool: return o.peer == peer and o.is_in_flight()).size()


func _count_my_views() -> int:
	var me := callins.multiplayer.get_unique_id()
	return callins.views.values().filter(func(v: Dictionary) -> bool:
		return int(v.get("peer", -1)) == me and int(v.state) <= CallinOrder.State.DELIVERING).size()
