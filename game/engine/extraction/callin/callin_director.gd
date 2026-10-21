class_name CallinDirector
extends Node
## The call-ins of an extraction raid (child "Callins" of the ExtractionDirector; every peer;
## docs/design/lobby_loadout_economy.md section 9). Host authoritative:
##   request   the caller designates a point with the Targeting Laser (CallinDesignator; menu key L, or LB + RB on a pad)
##             or on the command map (source "map"); the host judges it (CallinChecks), takes the raid points and makes a
##             CallinOrder (CallinOrders) for the runner registered for its kind (register_runner); a runner never picks a point
##   orders    REQUESTED -> MARKED -> INBOUND -> DELIVERING -> ACTIVE -> EXPIRING -> DONE (or CANCELLED with a refund): pods fall
##             from orbit (CallinPods), a vehicle is flown in (CallinVehicleRun), a sweep marks the hostile units near the
##             caller; the crates give armour and ammunition (CallinSupplies)
##   telling   state changes and, twice a second, the countdowns go to the caller's team (full view) and to the players within
##             sight of the zone (marker view); impacts to everybody; balances and cooldowns to the owner (CallinTelling)
##   noise     every call-in is loud (CallinAlert): hostile AI within its radius investigates, sleepers wake
## Transports, vehicles, crates and stations are normal battle entities, built the same on every peer.

const NODE_NAME := "Callins"
const ALL_PEERS := -1

var director: ExtractionDirector
var battle: Battle
var points: RaidPoints
var fx: CallinFx
var alert: CallinAlert
var pods: CallinPods
var vehicles: CallinVehicleRun
var supplies: CallinSupplies
var cooldowns := CallinCooldowns.new()
var checks: CallinChecks
var telling: CallinTelling
var sweep: CallinSweep
var content: CallinContent
var delivery: CallinDelivery
var air: CallinAir
var designator: CallinDesignator
var laser_sync: CallinLaserSync
## kind -> Callable(order: CallinOrder, request: CallinRequest): starts the order of that kind at the designated point.
var runners := {}
## kind -> Callable(request: CallinRequest) -> String: what only that kind can refuse beyond the shared checks ("" = fine).
var refusers := {}
## Host: order id -> CallinOrder (open orders and, for one tick, finished ones).
var orders := {}
## Every peer: order id -> the last view told ({kind, state, lz, ...}; "peer" present in the full view).
var views := {}
## Every peer: crate id -> CallinCrate; station id -> TempStation.
var crates := {}
var stations := {}
## The owner's mirror of his cooldowns: {cool: {kind: s}, shared: s, used: {kind: n}, at_msec}.
var my_state := {}
## The caller's radar sweep, as CallinSweep shows it (the HUD and the markers read them).
var sweep_contacts: Array:
	get: return sweep.contacts
var sweep_left: float:
	get: return sweep.left
var input: CallinInput
var order_maker: CallinOrders
## Tests: called as tap(peer or ALL_PEERS, method, args) for every message the host sends.
var tap := Callable()


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	battle = p_director.battle
	name = NODE_NAME
	points = RaidPoints.new(p_director, self)
	pods = CallinPods.new(self)
	vehicles = CallinVehicleRun.new(self)
	supplies = CallinSupplies.new(self)
	checks = CallinChecks.new(self)
	telling = CallinTelling.new(self)
	sweep = CallinSweep.new(self)
	content = CallinContent.new(self)
	delivery = CallinDelivery.new(self)
	designator = CallinDesignator.new(self)
	input = CallinInput.new(self)
	order_maker = CallinOrders.new(self)
	laser_sync = CallinLaserSync.new(self)
	for pod_kind in CallinRules.POD_KINDS + [CallinRules.KIND_VEHICLE]:
		register_runner(pod_kind, delivery.apply_start_marked)
	register_runner(CallinRules.KIND_RADAR, sweep.apply_start)
	air = CallinAir.new(self)


func _ready() -> void:
	add_child(points)
	fx = CallinFx.new()
	battle.add_child(fx)
	alert = CallinAlert.new(battle)
	var interaction := InfantryInteraction.of(battle)
	if interaction:
		interaction.add_provider(make_offer)
	designator.apply_setup()
	points.apply_local_start()


func _process(delta: float) -> void:
	apply_chord_frame(CallinInput.make_pad_reader())
	telling.apply_forget_stale_views()
	laser_sync.apply_forget_stale()
	designator.apply_frame(delta)


func _unhandled_input(event: InputEvent) -> void:
	if input.apply_event(event):
		get_viewport().set_input_as_handled()


## One frame of the pad chord (LB + RB): `is_down` answers "is this pad button held?".
func apply_chord_frame(is_down: Callable) -> void:
	input.apply_chord_frame(is_down)


## Opens the call-in menu (the laser comes up with it), or closes it when it is open (the laser goes down).
func toggle_menu() -> void:
	CallinMenu.toggle(director)


# ------------------------------------------------------------------ requests

## The menu's pick: the laser goes on to aim for it (the call-in is made when the spot is designated).
func begin_designation(kind: String, variant: String) -> bool:
	return designator.begin(kind, variant)


## A designated request (laser or command map): asks the host (or runs here on the host).
func request_designated(request: CallinRequest) -> void:
	request.peer = multiplayer.get_unique_id()
	_request("_request_callin", request.make_args())


## A script's request at the caller's own feet (the e2e driver; players designate).
func request(kind: String, variant: String) -> void:
	request_designated(checks.make_feet_request(multiplayer.get_unique_id(), kind, variant))


## The interact offer's crate use.
func request_use_crate(crate_id: int) -> void:
	_request("_request_crate", [crate_id])


func _request(method: String, args: Array) -> void:
	if multiplayer.is_server():
		callv("_apply" + method.trim_prefix("_request"), [multiplayer.get_unique_id()] + args)
	else:
		callv("rpc_id", [1, method] + args)


@rpc("any_peer", "reliable")
func _request_callin(kind: String, variant: String, point: Vector3, direction: Vector3, source: String) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_callin(multiplayer.get_remote_sender_id(), kind, variant, point, direction, source)


@rpc("any_peer", "reliable")
func _request_crate(crate_id: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_crate(multiplayer.get_remote_sender_id(), crate_id)


func _apply_callin(peer: int, kind: String, variant: String, point: Vector3, direction: Vector3, source: String) -> void:
	apply_order(CallinRequest.from_args(peer, [kind, variant, point, direction, source]))


# ------------------------------------------------------------------ the laser dots of the team

## Host: a painter's laser dot (or its turning off) comes from his machine; the team is told.
@rpc("any_peer", "unreliable_ordered")
func _laser_paint(on: bool, point: Vector3, ok: bool) -> void:
	if is_inside_tree() and multiplayer.is_server():
		laser_sync.apply_relay(multiplayer.get_remote_sender_id(), on, point, ok)


## Every teammate: the dot of `painter`.
@rpc("authority", "unreliable_ordered")
func _laser_seen(painter: int, on: bool, point: Vector3, ok: bool) -> void:
	laser_sync.apply_seen(painter, on, point, ok)


func _apply_crate(peer: int, crate_id: int) -> void:
	apply_use_crate(peer, crate_id)


# ------------------------------------------------------------------ host: deciding

## Host: "" when `peer` may make the call-in, else the HUD reason (CallinChecks).
func make_refusal(peer: int, kind: String, variant: String) -> String:
	return checks.make_refusal(peer, kind, variant)


## "" when the local player may call `kind` in, else why not (the menu).
func make_local_refusal(kind: String, variant: String) -> String:
	return checks.make_local_refusal(kind, variant)


static func make_footprint(kind: String, vehicle_id: String) -> float:
	return CallinChecks.make_footprint(kind, vehicle_id)


## The vehicle id saved in `peer`'s character slot ("" when none).
func make_vehicle_id(peer: int) -> String:
	return checks.make_vehicle_id(peer)


## The yaw `peer`'s soldier faces.
func make_heading(peer: int) -> float:
	var soldier := battle.occupancy.soldier_of(peer)
	return soldier.global_rotation.y if soldier != null else 0.0


## Host: `peer` asks for a call-in at his own feet (tests and scripts). Returns the order, null when it was refused.
func apply_request(peer: int, kind: String, variant: String) -> CallinOrder:
	return apply_order(checks.make_feet_request(peer, kind, variant))


## Host: judges a request and makes its order (CallinOrders). Returns the order, null when it was refused.
func apply_order(request: CallinRequest) -> CallinOrder:
	return order_maker.apply_order(request)


## Registers the runner of a call-in kind: `start` is called as start(order, request) once the order is made, with the
## order's `lz` already the validated point. A kind with no runner cannot be called in. `refuse` (optional) is called as
## refuse(request) -> String after the shared checks passed: the HUD reason the kind alone knows, else "".
func register_runner(kind: String, start: Callable, refuse := Callable()) -> void:
	runners[kind] = start
	if refuse.is_valid():
		refusers[kind] = refuse
	else:
		refusers.erase(kind)


## Host (tests): the cooldowns of `peer` are over.
func apply_clear_cooldowns(peer: int) -> void:
	cooldowns.apply_clear(peer)
	telling.send_player_state(peer)



## Host: cancels an order that is on its way (CallinOrders); with `refund` the raid points and the use come back.
func apply_cancel(order: CallinOrder, reason: String, refund: bool) -> void:
	order_maker.apply_cancel(order, reason, refund)


## Host: the orders of `peer` on their way are cancelled with a refund (he extracted: the points stay with him).
func apply_peer_extracted(peer: int) -> void:
	order_maker.apply_peer_extracted(peer)


## Host: `peer` died or left: his orders on their way are cancelled and his points are gone.
func apply_peer_dead(peer: int) -> void:
	order_maker.apply_peer_dead(peer)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or director.transports == null or battle.is_over():
		return
	order_maker.apply_tick(delta)


# ------------------------------------------------------------------ the radar sweep

@rpc("authority", "reliable", "call_local")
func _sweep(contacts: Array, left: float) -> void:
	sweep.apply_contacts(contacts, left)


# ------------------------------------------------------------------ the crates and stations

## Host: `peer` uses crate `crate_id`: the armour change or the ammunition refill.
func apply_use_crate(peer: int, crate_id: int) -> void:
	content.apply_use_crate(peer, crate_id)


## The order whose pod content is object `object_id` (null when none).
func find_order_of_object(object_id: int) -> CallinOrder:
	return content.find_order_of_object(object_id)


func make_object_id() -> int:
	return content.make_object_id()


## Host: the content of `order` starts to blink (its last seconds).
func apply_content_expiring(order: CallinOrder) -> void:
	content.apply_content_expiring(order)


@rpc("authority", "reliable", "call_local")
func _crate_add(record: Dictionary) -> void:
	crates[int(record.id)] = CallinCrate.create_crate(battle, record)


@rpc("authority", "reliable", "call_local")
func _crate_state(id: int, uses: int, expiring: bool) -> void:
	var c := crates.get(id) as CallinCrate
	if c != null:
		c.uses_left = uses
		c.expiring = expiring


@rpc("authority", "reliable", "call_local")
func _crate_remove(id: int) -> void:
	var c := crates.get(id) as CallinCrate
	if c != null and is_instance_valid(c):
		c.queue_free()
	crates.erase(id)


@rpc("authority", "reliable", "call_local")
func _station_add(record: Dictionary) -> void:
	stations[int(record.id)] = TempStation.create_station(battle, record)


@rpc("authority", "reliable", "call_local")
func _station_state(id: int, expiring: bool) -> void:
	var st := stations.get(id) as TempStation
	if st != null:
		st.expiring = expiring


@rpc("authority", "reliable", "call_local")
func _station_remove(id: int) -> void:
	var st := stations.get(id) as TempStation
	if st != null:
		st.queue_free()
	stations.erase(id)


@rpc("authority", "reliable", "call_local")
func _armor_changed(net_id: int, armor_id: String, state: Dictionary) -> void:
	CallinSupplies.apply_armor_change(battle, net_id, armor_id, state)


@rpc("authority", "reliable", "call_local")
func _impact(pos: Vector3, radius: float) -> void:
	fx.apply_impact(pos, radius)


## Every peer: true when `soldier` stands at a working call-in inventory station of his side (ExtractionStation asks).
func is_at_inventory_station(soldier: Infantry) -> bool:
	return content.find_inventory_station(soldier) != null


## InfantryInteraction provider: a crate within reach, or the call-in inventory station underfoot.
func make_offer(soldier: Infantry) -> Dictionary:
	return content.make_offer(soldier)


# ------------------------------------------------------------------ telling the peers

## Host: tells who needs to know the state of `order` (CallinTelling).
func apply_broadcast(order: CallinOrder) -> void:
	telling.apply_broadcast(order)


## peer -> true when he gets the full view, false the marker only.
func make_audience(order: CallinOrder) -> Dictionary:
	return telling.make_audience(order)


@rpc("authority", "reliable", "call_local")
func _order_view(view: Dictionary) -> void:
	telling.apply_view(view)


@rpc("authority", "reliable", "call_local")
func _player_state(state: Dictionary) -> void:
	my_state = state
	my_state["at_msec"] = Time.get_ticks_msec()


## The owner of a delivered vehicle: it is at risk until the raid ends (OperatorProfile, question O4).
@rpc("authority", "reliable", "call_local")
func _vehicle_called(vehicle_ref: String) -> void:
	RaidOperator.apply_vehicle_risk(Net.player_name, vehicle_ref)


## The owner of a vehicle that was recalled: it is not at risk any more.
@rpc("authority", "reliable", "call_local")
func _vehicle_recalled(vehicle_ref: String) -> void:
	RaidOperator.apply_vehicle_recalled(Net.player_name, vehicle_ref)


func send_to(peer: int, node: Node, method: String, args: Array) -> void:
	telling.send_to(peer, node, method, args)


func send_all(method: String, args: Array) -> void:
	telling.send_all(method, args)


# ------------------------------------------------------------------ the HUD

## The call-in lines of the raid HUD: the balance, the caller's own orders and a running sweep ([text]).
func make_hud_lines() -> Array:
	return CallinHud.make_lines(self)


## World markers: the caller's zones with their countdown: [{pos, label, contact}].
func make_markers() -> Array:
	return CallinHud.make_markers(self)
