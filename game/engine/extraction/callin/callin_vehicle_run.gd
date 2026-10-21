class_name CallinVehicleRun
extends RefCounted
## The vehicle delivery call-in (host; docs/design/lobby_loadout_economy.md section 9.5): the caller's saved vehicle is flown in by an AI
## transport and set down at his landing zone.
##   MARKED      flare and ring; the countdown is the preparation time
##   INBOUND     the transport (ExtractionTransports.spawn_delivery_transport) flies in, the vehicle slung under its belly
##               (kinematic, carried every frame, untouchable; the sling is as long as the vehicle is tall, so a Herc hangs
##               clear of a 33 m dropship hull instead of sinking into it); the HUD counts down the flight
##   DELIVERING  the transport hovers over the zone (TransportFlight HOVER_DROP), releases the vehicle, which falls the
##               last hover_height_m and settles; the transport departs and is removed
##   ACTIVE      the vehicle is empty, parked, of the caller's team; for owner_claim_s only he may board it (BoardingRules
##               refuses the others with a message); the owner is told to put it at risk (OperatorProfile, open question O4). With no occupant and
##               no friend near for abandon_s it is recalled: removed, no loss.
## With no transport installed a drop pod brings it instead (CallinPods, a slower fall), so the call-in works on every pack set.

const CRUISE_SHARE := 0.7
const FALLBACK_CRUISE := 40.0
## How long a flight takes, for the ETA: the average approach speed is this share of the speed the braking law
## (TransportFlight.APPROACH_BRAKE) allows, the descent goes at about DESCENT_RATE (m/s).
const APPROACH_AVERAGE_SHARE := 0.7
const DESCENT_RATE := 5.0
const FLY_SETTLE_S := 0.5
const SETTLE_TIMEOUT_S := 6.0
const CARRIED_META := "carried_by"
## The vehicle hangs this far (m) below the transport's lowest point.
const SLING_CLEARANCE_M := 1.5
## Spawn protection of a carried vehicle beyond its trip (s).
const CARRY_PROTECTION_PAD := 20.0

var callins: CallinDirector
## Host: cargo net id -> {peer, left} while only the caller may board the delivered vehicle.
var claims := {}
## Host: order id -> length (m) of the sling that carries its vehicle, from the transport's origin to the vehicle's feet.
var _slings := {}
var _departing: Array = []


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


# ------------------------------------------------------------------ planning

## The transport that flies `cargo_id` in ("" when none: a pod brings it): a Starsiege dropship for a Herc, a Cybrid or a
## heavy vehicle, a Tribes troop transport for the Tribes vehicles and raiders (ExtractionTransports.pick_delivery_transport_id).
## With no cargo named, the first usable transport of the rule's list.
static func pick_transport_id(cargo_id := "") -> String:
	return ExtractionTransports.pick_delivery_transport_id(cargo_id, CallinRules.rule(CallinRules.KIND_VEHICLE).get("transport_ids", []))


static func make_cruise_speed(transport_id: String) -> float:
	var v := Packs.vehicle(transport_id)
	return float(v.get("max_speed", FALLBACK_CRUISE / CRUISE_SHARE)) * CRUISE_SHARE if not v.is_empty() else FALLBACK_CRUISE


## Seconds a delivery transport needs to cover `distance` metres and sink `drop` metres to its hover spot, then settle.
static func make_flight_seconds(distance: float, cruise: float, drop: float) -> float:
	var top := minf(cruise, sqrt(2.0 * TransportFlight.APPROACH_BRAKE * maxf(distance, 0.0)))
	return distance / maxf(top * APPROACH_AVERAGE_SHARE, 1.0) + maxf(drop, 0.0) / DESCENT_RATE + TransportFlight.HOVER_SETTLE


## Length of the sling (m) from the transport's origin to the feet of a vehicle `cargo_height_m` tall: the vehicle hangs
## SLING_CLEARANCE_M under the transport's lowest point (`belly_m`, relative to its origin), and never shorter than the rule's sling_m.
static func make_sling_m(belly_m: float, cargo_height_m: float) -> float:
	var minimum := float(CallinRules.rule(CallinRules.KIND_VEHICLE).get("sling_m", 8.0))
	return maxf(cargo_height_m + SLING_CLEARANCE_M - minf(belly_m, 0.0), minimum)


## The lowest point (m, relative to its origin) of a transport's model; 0 when it has none (a server without models).
static func make_belly_m(transport: Flyer) -> float:
	if transport.shape == null:
		return 0.0
	return make_model_belly_m(transport.shape, transport.global_position.y)


## The lowest point of `model` (m) relative to an origin at height `origin_y`.
static func make_model_belly_m(model: ShapeInstance, origin_y: float) -> float:
	return LootContainer._make_world_box(model).position.y - origin_y


## The sling (m) of `order`'s vehicle.
func make_sling_of(order: CallinOrder) -> float:
	return float(_slings.get(order.id, CallinRules.rule(CallinRules.KIND_VEHICLE).get("sling_m", 8.0)))


## Host, when the order is made: the transport (or the fallback pod), and the times of the sequence. The flight is
## shortened or the preparation lengthened so the whole wait lands in the eta clamp.
func apply_plan(order: CallinOrder) -> void:
	var rule := CallinRules.rule(CallinRules.KIND_VEHICLE)
	var config := callins.battle.config
	var prep := CallinRules.number(config, rule, "prep_s", 8.0)
	order.transport_vehicle = pick_transport_id(order.vehicle_id)
	if order.transport_vehicle == "":
		order.fall_s = CallinRules.make_slow_fall_seconds(config)
		order.marker_s = prep
		order.eta = prep + order.fall_s
		return
	var cruise := make_cruise_speed(order.transport_vehicle)
	var clamp := CallinRules.make_eta_clamp(config, rule)
	var approach := ExtractionRules.approach_distance(config)
	var drop := float(ExtractionRules.transport().get("altitude_m", 45.0)) - float(rule.get("hover_height_m", 6.0)) - float(rule.get("sling_m", 8.0))
	var flight := make_flight_seconds(approach, cruise, drop)
	var total := clampf(prep + flight, clamp[0], clamp[1])
	if total > prep + flight:
		prep = total - flight
	else:
		approach *= maxf(total - prep, 1.0) / flight
		flight = total - prep
	order.marker_s = prep
	order.flight_s = flight
	order.approach_m = approach
	order.eta = prep + flight


# ------------------------------------------------------------------ the sequence

## Host: MARKED ended: the transport flies (or the pod falls).
func apply_launch(order: CallinOrder) -> void:
	if order.transport_vehicle == "":
		order.apply_state(CallinOrder.State.INBOUND)
		order.eta = order.fall_s
		return
	var rule := CallinRules.rule(CallinRules.KIND_VEHICLE)
	var release_m := float(rule.get("hover_height_m", 6.0))
	var fl := callins.director.transports.spawn_delivery_transport(order.transport_vehicle, order.lz, order.approach_m, release_m)
	if fl != null:
		_apply_sling(order, fl, release_m)
	var cargo := _spawn_cargo(order, fl) if fl != null else null
	if cargo == null:
		if fl != null:
			callins.battle.remove_vehicle(fl.net_id)
		order.transport_vehicle = ""
		order.fall_s = CallinRules.make_slow_fall_seconds(callins.battle.config)   # the transport would not fly: the pod
		order.eta = order.fall_s
		order.apply_state(CallinOrder.State.INBOUND)
		return
	order.transport_id = fl.net_id
	order.cargo_net_id = cargo.net_id
	order.apply_state(CallinOrder.State.INBOUND)
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(order.kind), order.team)


## The transport holds the vehicle's release height (`release_m`) over the ground plus the sling that carries it.
func _apply_sling(order: CallinOrder, fl: Flyer, release_m: float) -> void:
	var sling := make_sling_m(make_belly_m(fl), float(Packs.vehicle(order.vehicle_id).get("height_m", 0.0)))
	_slings[order.id] = sling
	(fl.ai as TransportFlight).hover_height = release_m + sling


func _spawn_cargo(order: CallinOrder, fl: Flyer) -> Herc:
	var xf := Transform3D(Basis(Vector3.UP, fl.global_rotation.y), fl.global_position + Vector3.DOWN * make_sling_of(order))
	var spec := _make_cargo_spec(order, xf, order.eta + CARRY_PROTECTION_PAD)
	callins.battle.send_spawn(spec)
	var cargo := callins.battle.vehicles.get(int(spec.net_id)) as Herc
	if cargo == null:
		return null
	cargo.set_meta(CARRIED_META, fl.net_id)
	cargo.add_collision_exception_with(fl)
	fl.add_collision_exception_with(cargo)
	return cargo


func _make_cargo_spec(order: CallinOrder, xf: Transform3D, protection: float) -> Dictionary:
	var v := Packs.vehicle(order.vehicle_id)
	return {"net_id": callins.battle.spawner.allocate_id(), "vehicle": order.vehicle_id, "team": order.team,
		"owner": VehicleOccupancy.EMPTY, "xf": xf, "loadout": v.get("loadout", []), "name": str(v.get("name", order.vehicle_id)),
		"ai": {}, "parked": true, "protection": protection}


## Host, INBOUND by transport: the load hangs under the transport; released when the transport hovers.
func apply_inbound_tick(order: CallinOrder) -> void:
	var fl := callins.battle.vehicles.get(order.transport_id) as Flyer
	var cargo := callins.battle.vehicles.get(order.cargo_net_id) as Herc
	if not is_instance_valid(fl) or not is_instance_valid(cargo) or not fl.ai is TransportFlight:
		callins.apply_cancel(order, "The transport was lost.", true)
		return
	_carry(order, fl, cargo)
	order.eta = make_flight_seconds(Vector2(fl.global_position.x - order.lz.x, fl.global_position.z - order.lz.z).length(),
		make_cruise_speed(order.transport_vehicle), fl.make_altitude() - float(CallinRules.rule(CallinRules.KIND_VEHICLE).get("hover_height_m", 6.0)) - make_sling_of(order))
	if (fl.ai as TransportFlight).is_hovering():
		_release(order, fl, cargo)


func _carry(order: CallinOrder, fl: Flyer, cargo: Herc) -> void:
	cargo.global_transform = Transform3D(Basis(Vector3.UP, fl.global_rotation.y), fl.global_position + Vector3.DOWN * make_sling_of(order))
	cargo.velocity = Vector3.ZERO


func _release(order: CallinOrder, fl: Flyer, cargo: Herc) -> void:
	_slings.erase(order.id)
	cargo.remove_meta(CARRIED_META)
	cargo.remove_collision_exception_with(fl)
	fl.remove_collision_exception_with(cargo)
	(fl.ai as TransportFlight).depart()
	_departing.append(fl.net_id)
	order.eta = -1.0
	order.apply_state(CallinOrder.State.DELIVERING)
	callins.apply_broadcast(order)


## Host, DELIVERING: the released vehicle falls and settles; then it is the caller's.
func apply_delivering_tick(order: CallinOrder) -> void:
	var cargo := callins.battle.vehicles.get(order.cargo_net_id) as Herc
	if not is_instance_valid(cargo):
		callins.apply_cancel(order, "The vehicle was lost.", true)
		return
	var settled: bool = order.state_time > FLY_SETTLE_S and cargo.is_on_floor()
	if settled or order.state_time > SETTLE_TIMEOUT_S:
		_activate(order, cargo)


## Host: a pod brought the vehicle (no transport): it stands where the pod landed.
func apply_pod_delivery(order: CallinOrder) -> void:
	var at := SpawnClearance.make(callins.battle).make_clear_origin(callins.battle.infantry.make_on_ground(order.lz))
	var spec := _make_cargo_spec(order, Transform3D(Basis(Vector3.UP, callins.make_heading(order.peer)), at), 0.0)
	callins.battle.send_spawn(spec)
	var cargo := callins.battle.vehicles.get(int(spec.net_id)) as Herc
	if cargo == null:
		callins.apply_cancel(order, "The vehicle could not be set down.", true)
		return
	order.cargo_net_id = cargo.net_id
	_activate(order, cargo)


## The vehicle is delivered: claimed for the caller, watched, put at risk on the owner's machine.
func _activate(order: CallinOrder, cargo: Herc) -> void:
	cargo.spawn_protection = 0.0
	cargo.apply_spawn_protection()
	var rule := CallinRules.rule(CallinRules.KIND_VEHICLE)
	var caller := callins.battle.occupancy.soldier_of(order.peer)
	var claim := {"peer": order.peer, "left": float(rule.get("owner_claim_s", 30.0)), "soldier_id": caller.net_id if caller != null else -1,
		"holder": callins.battle.make_pilot_name(order.peer)}
	claims[cargo.net_id] = claim
	BoardingRules.apply_claim(cargo, claim)
	order.ttl_left = float(rule.get("abandon_s", 300.0))
	order.eta = -1.0
	callins.director.watch(cargo)
	callins.send_to(order.peer, callins, "_vehicle_called", [order.vehicle_id])
	callins.director.notify(order.peer, "%s delivered." % str(Packs.vehicle(order.vehicle_id).get("name", order.vehicle_id)))
	order.apply_state(CallinOrder.State.ACTIVE)
	callins.apply_broadcast(order)


## Host, ACTIVE: the claim, the abandonment. True once the order is over (destroyed or recalled).
func apply_active_tick(order: CallinOrder, delta: float) -> bool:
	var cargo := callins.battle.vehicles.get(order.cargo_net_id) as Herc
	if not is_instance_valid(cargo) or not cargo.alive:
		claims.erase(order.cargo_net_id)
		return true
	_apply_claim(cargo, delta)
	var rule := CallinRules.rule(CallinRules.KIND_VEHICLE)
	if _is_in_use(order, cargo):
		order.ttl_left = float(rule.get("abandon_s", 300.0))
		return false
	order.ttl_left -= delta
	if order.ttl_left <= 0.0:
		_apply_recall(order, cargo)
		return true
	return false


## Counts the claim down; BoardingRules keeps everybody but the caller out while it lasts.
func _apply_claim(cargo: Herc, delta: float) -> void:
	var claim: Dictionary = claims.get(cargo.net_id, {})
	if claim.is_empty():
		return
	claim.left = float(claim.left) - delta
	if float(claim.left) <= 0.0:
		_end_claim(cargo)


func _end_claim(cargo: Herc) -> void:
	claims.erase(cargo.net_id)
	if is_instance_valid(cargo):
		BoardingRules.apply_release_claim(cargo)


## True while somebody sits in the vehicle or a friend is near it.
func _is_in_use(order: CallinOrder, cargo: Herc) -> bool:
	if not VehicleOccupancy.of(cargo).make_occupants().is_empty():
		return true
	var near := float(CallinRules.rule(CallinRules.KIND_VEHICLE).get("abandon_friendly_m", 150.0))
	for peer in callins.director.make_raid_peers():
		var s := callins.battle.occupancy.soldier_of(int(peer))
		if s != null and s.alive and TeamRelations.is_allied(s.team, order.team) and s.global_position.distance_to(cargo.global_position) <= near:
			return true
	return false


## Nobody came for it: it is taken back, not lost.
func _apply_recall(order: CallinOrder, cargo: Herc) -> void:
	claims.erase(cargo.net_id)
	callins.battle.remove_vehicle(cargo.net_id)
	callins.send_to(order.peer, callins, "_vehicle_recalled", [order.vehicle_id])
	callins.director.notify(order.peer, "Your %s was recalled: nobody came for it." % str(Packs.vehicle(order.vehicle_id).get("name", order.vehicle_id)))


# ------------------------------------------------------------------ ending

## Host: the order was cancelled before the vehicle was delivered: the transport and the load go.
func apply_cancel(order: CallinOrder) -> void:
	if order.state >= CallinOrder.State.ACTIVE:
		return
	if order.cargo_net_id >= 0 and callins.battle.vehicles.has(order.cargo_net_id):
		callins.battle.remove_vehicle(order.cargo_net_id)
	if order.transport_id >= 0 and callins.battle.vehicles.has(order.transport_id):
		callins.battle.remove_vehicle(order.transport_id)


## Host, every physics frame: transports that left are taken out of the battle.
func apply_departures() -> void:
	for net_id in _departing.duplicate():
		var fl := callins.battle.vehicles.get(net_id) as Flyer
		if not is_instance_valid(fl) or not fl.ai is TransportFlight or (fl.ai as TransportFlight).is_done():
			if is_instance_valid(fl):
				callins.battle.remove_vehicle(net_id)
			_departing.erase(net_id)
