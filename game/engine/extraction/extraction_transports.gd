class_name ExtractionTransports
extends RefCounted
## The raid's AI transports (host; docs/design/extraction.md section 2): the drop-in and the exfil flights.
##   drop-in  the players start aboard the first installed transport of the rules' list (Tribes 2 Havoc, Tribes
##            HPC / LPC, a Starsiege dropship) in its passenger seats (OccupancyDirector); it flies a short path
##            to the insertion point, lands, lets everybody out and leaves. Without a transport that has passenger
##            seats the players start at the map edge.
##   exfil    exfil_call: after exfil_delay_s a transport flies to the extraction zone nearest the caller and
##            waits exfil_wait_s on the ground; players board it by touching it (Tribes vehicles) and are
##            extracted when it lifts off (depart_after_board_s after the first one boards, or when the wait ends).
##            A transport without passenger seats, or none at all, opens the zone instead: standing in it for
##            zone_hold_s extracts.
## Transports are untouchable (spawn protection) and ignored by the AI (meta "dormant").

const STATE_CALLED := "called"
const STATE_FLYING := "flying"
const STATE_LANDED := "landed"
const STATE_OPEN := "open"
const STATE_DEPARTING := "departing"
const TRANSPORT_PROTECTION := 100000.0
const TRANSPORT_SKILL := 0.5
const DROP_LANDING_SPACING := 35.0
## A transport appears this far beyond the map edge.
const EDGE_MARGIN_M := 60.0
const DELIVERY_DROPSHIP := "dropship"
const DELIVERY_TROOP := "troop"
const STATE_CLOSED := "closed"

var director: ExtractionDirector
var battle: Battle
## zone index -> {zone, state, t, net_id, depart_t}
var exfils := {}
## [{net_id, state ("inbound" / "unloading" / "departing"), t}]
var drops := []
## Zones the Cybrid siege closed for good (CybridSiege): no exfil is called to them any more.
var closed: Array[int] = []
## Multiplies the exfil call delay (the siege shortens it).
var delay_factor := 1.0
var _holds := {}          # peer -> seconds standing in an open zone


static func make(p_director: ExtractionDirector) -> ExtractionTransports:
	var t := ExtractionTransports.new()
	t.director = p_director
	t.battle = p_director.battle
	return t


## The first installed transport of the rules' list ("" when none).
static func pick_transport_id() -> String:
	for id in ExtractionRules.transport().get("ids", []):
		var v := Packs.vehicle(str(id))
		if not v.is_empty() and Packs.is_enabled(str(v.pack), "vehicles" if str(v.get("category", "")) == "vehicle" else "hercs"):
			return str(id)
	return ""


## The class of transport that flies `cargo_id` in: DELIVERY_DROPSHIP for Hercs, Cybrids and heavy vehicles,
## DELIVERY_TROOP for the Tribes vehicles and raiders (anything unknown too).
static func make_delivery_class(cargo_id: String) -> String:
	var v := Packs.vehicle(cargo_id)
	if v.is_empty():
		return DELIVERY_TROOP
	if str(v.get("category", "")) == "herc":
		return DELIVERY_DROPSHIP
	var large := str(ExtractionRules.transport().get("delivery", {}).get("large_class", CallinRules.CLASS_HEAVY))
	return DELIVERY_DROPSHIP if CallinRules.make_vehicle_class(v) == large else DELIVERY_TROOP


## The transports that may fly `cargo_id` in, best first: its class's own (a dropship by faction, then side, then the
## default list), then the other class as the fallback for a missing pack.
static func make_delivery_candidates(cargo_id: String) -> Array:
	var rules: Dictionary = ExtractionRules.transport().get("delivery", {})
	var v := Packs.vehicle(cargo_id)
	var dropships: Array = []
	var table: Dictionary = rules.get("dropships", {})
	dropships.append_array((table.get("by_faction", {}) as Dictionary).get(str(v.get("faction", "")), []))
	dropships.append_array((table.get("by_side", {}) as Dictionary).get(str(v.get("side", "")), []))
	dropships.append_array(table.get("default", []))
	var troop: Array = rules.get("troop", [])
	var ordered := dropships + troop if make_delivery_class(cargo_id) == DELIVERY_DROPSHIP else troop + dropships
	var out: Array = []
	for id in ordered:
		if not out.has(id):
			out.append(id)
	return out


## The transport that flies `cargo_id` in, from the allowed `pool` (a flyer the pack set enables); "" when there is none
## (a drop pod brings it). With no cargo named the first usable of the pool.
static func pick_delivery_transport_id(cargo_id: String, pool: Array) -> String:
	var candidates: Array = make_delivery_candidates(cargo_id) if cargo_id != "" else pool
	for id in candidates:
		if pool.has(id) and CallinAirframes.is_usable(str(id)):
			return str(id)
	for id in pool:
		if CallinAirframes.is_usable(str(id)):
			return str(id)
	return ""


## Passenger seats of transport `vehicle_id` (its seats but the pilot's).
static func make_passenger_seats(vehicle_id: String) -> int:
	return BoardingRules.make_seat_count(Packs.vehicle(vehicle_id)) - 1


# ------------------------------------------------------------------ drop-in

## Host: puts `peers`' soldiers aboard transports flying to the insertion point, or at the map edge.
func start_drop_in(peers: Array) -> void:
	var vid := pick_transport_id()
	var drop := director.map.make_drop_point()
	if vid == "" or make_passenger_seats(vid) <= 0:
		_place_at_edge(peers, drop)
		return
	var waiting := peers.duplicate()
	var k := 0
	while not waiting.is_empty():
		var landing := battle.infantry.make_on_ground(drop + Vector3(DROP_LANDING_SPACING * k, 0.0, 0.0))
		var before := waiting.size()
		var fl := spawn_transport(vid, landing)
		if fl == null:
			break
		_board_all(fl, waiting)
		if waiting.size() == before:
			battle.remove_vehicle(fl.net_id)   # nobody here may sit in it
			break
		drops.append({"net_id": fl.net_id, "state": "inbound", "t": 0.0})
		k += 1
	if not waiting.is_empty():
		_place_at_edge(waiting, drop)


## Seats as many of `waiting` as `fl` takes (removing them from `waiting`).
func _board_all(fl: Flyer, waiting: Array) -> void:
	for peer in waiting.duplicate():
		var soldier := battle.occupancy.soldier_of(int(peer))
		if soldier == null:
			waiting.erase(peer)
			continue
		var seat := OccupancyDirector.make_next_seat(soldier, fl, VehicleOccupancy.PILOT_SEAT)
		if seat < 0:
			return
		battle.occupancy.apply_board(int(peer), fl, seat)
		waiting.erase(peer)


## No transport: everybody starts on the ground at the edge of the map nearest the insertion point.
func _place_at_edge(peers: Array, drop: Vector3) -> void:
	var edge := director.map.make_approach_point(drop, 0.0)
	var c := director.map.make_center()
	var out := (Vector2(edge.x, edge.z) - c).normalized() * director.map.make_inner_half()
	var spread := float(ExtractionRules.map_rules().get("drop_spread_m", 8.0))
	for i in peers.size():
		var soldier := battle.occupancy.soldier_of(int(peers[i]))
		if soldier:
			var p := director.map.make_ground(c + out + Vector2(spread * i, 0.0))
			soldier.global_position = p
			soldier.velocity = Vector3.ZERO


# ------------------------------------------------------------------ spawning a transport

## A transport of `vehicle_id` appearing approach_m out from `landing`, flying in to land there.
func spawn_transport(vehicle_id: String, landing: Vector3) -> Flyer:
	return _spawn_flight(vehicle_id, landing, ExtractionRules.approach_distance(battle.config), 0.0)


## A delivery transport (call-ins): appears `approach_m` out from `landing` and flies in to hold `hover_height` metres
## above the ground over it (TransportFlight HOVER_DROP) until released.
func spawn_delivery_transport(vehicle_id: String, landing: Vector3, approach_m: float, hover_height: float) -> Flyer:
	return _spawn_flight(vehicle_id, landing, approach_m, hover_height)


func _spawn_flight(vehicle_id: String, landing: Vector3, approach_m: float, hover_height: float) -> Flyer:
	var rules := ExtractionRules.transport()
	var height := float(rules.get("altitude_m", 45.0))
	var from := director.map.make_approach_point(landing, make_entry_distance(landing, approach_m))
	from.y = MapBuilder.ground_height(battle, from) + height
	var to := landing - from
	var exit := landing + Vector3(to.x, 0.0, to.z).normalized() * float(rules.get("leave_m", 500.0))
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": vehicle_id, "team": director.make_transport_team(),
		"owner": 1, "xf": Transform3D(Basis(Vector3.UP, atan2(-to.x, -to.z)), from), "loadout": [],
		"name": "Transport (%s)" % str(Packs.vehicle(vehicle_id).get("name", vehicle_id)),
		"ai": {"skill": TRANSPORT_SKILL, "flyer": true}, "protection": TRANSPORT_PROTECTION}
	battle.send_spawn(spec)
	var fl := battle.vehicles.get(int(spec.net_id)) as Flyer
	if fl == null:
		push_error("ExtractionTransports: transport %s did not spawn" % vehicle_id)
		return null
	fl.set_meta("dormant", true)
	fl.set_meta("transport", true)
	SupportCraft.mark(fl)
	var flight := TransportFlight.make(fl, landing, exit, height)
	flight.hover_height = hover_height
	fl.ai = flight
	return fl


## How far out from `landing` a transport appears: the map edge plus EDGE_MARGIN_M (no more than `approach_m`), so it
## spends as little time outside the playable area as it can.
func make_entry_distance(landing: Vector3, approach_m: float) -> float:
	if battle.bounds == null or not battle.bounds.bounds.has_area:
		return approach_m
	var out := Vector2(landing.x, landing.z) - director.map.make_center()
	if out.length() < 1.0:
		out = Vector2.RIGHT
	var dir := Vector3(out.x, 0.0, out.y).normalized()
	var to_edge := CallinAirLine.make_edge_distance(battle.bounds.bounds.area, landing, dir, 1.0, approach_m)
	return minf(approach_m, to_edge + EDGE_MARGIN_M)


func _flight_of(net_id: int) -> TransportFlight:
	var fl := battle.vehicles.get(net_id) as Flyer
	return fl.ai as TransportFlight if fl and is_instance_valid(fl) and fl.ai is TransportFlight else null


# ------------------------------------------------------------------ exfil

## Host: `peer` calls an exfil to the zone nearest him; returns the message for him.
func request_exfil(peer: int) -> String:
	var soldier := battle.occupancy.soldier_of(peer)
	if soldier == null or not soldier.alive or soldier.stowed:
		return "Exfil can only be called on foot."
	var zone := find_nearest_open_zone(soldier.global_position)
	if zone < 0:
		return "Every exfil is closed."
	if exfils.has(zone):
		return "Exfil to zone %s is already %s." % [make_zone_name(zone), str(exfils[zone].state)]
	exfils[zone] = {"zone": zone, "state": STATE_CALLED, "t": ExtractionRules.timer(battle.config, "exfil_delay_s") * delay_factor,
		"net_id": -1, "depart_t": -1.0}
	return "Exfil called to zone %s: %d s." % [make_zone_name(zone), int(exfils[zone].t)]


## Index of the zone nearest `p` that is not closed (-1 when all are).
func find_nearest_open_zone(p: Vector3) -> int:
	var best := -1
	for i in director.map.zones.size():
		if not closed.has(i) and (best < 0 or director.map.zones[i].distance_to(p) < director.map.zones[best].distance_to(p)):
			best = i
	return best


## Host: zone `zone` closes for good. A transport on its way leaves, one on the ground lifts off with whoever boarded,
## a call or an open zone simply ends.
func apply_close(zone: int) -> void:
	if closed.has(zone):
		return
	closed.append(zone)
	if not exfils.has(zone):
		return
	var e: Dictionary = exfils[zone]
	match str(e.state):
		STATE_LANDED:
			e.t = 0.0
		STATE_FLYING:
			var flight := _flight_of(int(e.net_id))
			if flight == null:
				exfils.erase(zone)
			else:
				flight.depart()
				e.state = STATE_DEPARTING
		STATE_DEPARTING:
			pass
		_:
			exfils.erase(zone)


static func make_zone_name(zone: int) -> String:
	return String.chr(65 + zone)


## Host, every physics frame.
func update(delta: float) -> void:
	for d in drops.duplicate():
		_update_drop(d, delta)
	for zone in exfils.keys():
		_update_exfil(exfils[zone], delta)
	_update_zone_holds(delta)


func _update_drop(d: Dictionary, delta: float) -> void:
	var flight := _flight_of(int(d.net_id))
	if flight == null:
		drops.erase(d)
		return
	match str(d.state):
		"inbound":
			if flight.is_holding():
				_unload(battle.vehicles.get(int(d.net_id)))
				d.state = "unloading"
				d.t = ExtractionRules.timer(battle.config, "drop_hold_s")
		"unloading":
			d.t = float(d.t) - delta
			if float(d.t) <= 0.0:
				flight.depart()
				d.state = "departing"
		"departing":
			if flight.is_done():
				battle.remove_vehicle(int(d.net_id))
				drops.erase(d)


func _unload(fl: Herc) -> void:
	for peer in VehicleOccupancy.of(fl).make_occupants():
		battle.occupancy.apply_exit(peer, fl)


func _update_exfil(e: Dictionary, delta: float) -> void:
	e.t = float(e.t) - delta
	match str(e.state):
		STATE_CALLED:
			if float(e.t) <= 0.0:
				_launch_exfil(e)
		STATE_FLYING:
			var flight := _flight_of(int(e.net_id))
			if flight == null:
				_open_zone(e)
			elif flight.is_holding():
				e.state = STATE_LANDED
				e.t = ExtractionRules.timer(battle.config, "exfil_wait_s")
		STATE_LANDED:
			_update_landed(e, delta)
		STATE_OPEN:
			if float(e.t) <= 0.0:
				exfils.erase(int(e.zone))
		STATE_DEPARTING:
			var flight := _flight_of(int(e.net_id))
			if flight == null or flight.is_done():
				battle.remove_vehicle(int(e.net_id))
				exfils.erase(int(e.zone))


func _launch_exfil(e: Dictionary) -> void:
	var vid := pick_transport_id()
	if vid == "":
		_open_zone(e)
		return
	var fl := spawn_transport(vid, director.map.zones[int(e.zone)])
	if fl == null:
		_open_zone(e)
		return
	e.net_id = fl.net_id
	e.state = STATE_FLYING
	director.notify_all("Exfil transport inbound to zone %s." % make_zone_name(int(e.zone)))


func _open_zone(e: Dictionary) -> void:
	e.state = STATE_OPEN
	e.t = ExtractionRules.timer(battle.config, "exfil_wait_s")
	director.notify_all("Extraction zone %s is open: hold inside it." % make_zone_name(int(e.zone)))


## A landed transport: riders leave with it after depart_after_board_s (or when the wait ends).
func _update_landed(e: Dictionary, delta: float) -> void:
	var fl: Herc = battle.vehicles.get(int(e.net_id))
	if fl == null or not is_instance_valid(fl):
		exfils.erase(int(e.zone))
		return
	var riders := make_player_riders(fl)
	if not riders.is_empty() and float(e.depart_t) < 0.0:
		e.depart_t = ExtractionRules.timer(battle.config, "depart_after_board_s")
	if float(e.depart_t) >= 0.0:
		e.depart_t = float(e.depart_t) - delta
	if (float(e.depart_t) < 0.0 and not riders.is_empty()) or float(e.t) <= 0.0:
		for peer in make_player_riders(fl):
			director.apply_extract(peer)
		((fl as Flyer).ai as TransportFlight).depart()
		e.state = STATE_DEPARTING


## The players (not bots) aboard `fl`.
func make_player_riders(fl: Herc) -> Array:
	return Array(VehicleOccupancy.of(fl).make_occupants()).filter(func(p: int) -> bool:
		return not InfantryBots.is_bot(p) and director.is_in_raid(p))


## Zones that extract by standing in them: open zones, and zones whose transport has no passenger seats.
func _update_zone_holds(delta: float) -> void:
	var radius := float(ExtractionRules.map_rules().get("zone_radius_m", 18.0))
	var hold := ExtractionRules.timer(battle.config, "zone_hold_s")
	for peer in director.make_raid_peers():
		var soldier := battle.occupancy.soldier_of(int(peer))
		var inside := soldier != null and soldier.alive and not soldier.stowed and _is_in_hold_zone(soldier, radius)
		_holds[peer] = float(_holds.get(peer, 0.0)) + delta if inside else 0.0
		if float(_holds[peer]) >= hold:
			_holds.erase(peer)
			director.apply_extract(int(peer))


func _is_in_hold_zone(soldier: Infantry, radius: float) -> bool:
	for zone in exfils:
		var e: Dictionary = exfils[zone]
		var seatless: bool = e.state == STATE_LANDED and make_passenger_seats(str(_vehicle_id_of(int(e.net_id)))) <= 0
		if (e.state == STATE_OPEN or seatless) and soldier.global_position.distance_to(director.map.zones[int(zone)]) <= radius:
			return true
	return false


func _vehicle_id_of(net_id: int) -> String:
	var h: Herc = battle.vehicles.get(net_id)
	return h.vehicle_id if h and is_instance_valid(h) else ""


## The exfil states for the HUDs: [{zone, state, seconds}].
func make_states() -> Array:
	var out := []
	for zone in exfils:
		var e: Dictionary = exfils[zone]
		out.append({"zone": int(zone), "state": str(e.state), "seconds": maxf(float(e.t), 0.0), "net_id": int(e.net_id)})
	for zone in closed:
		out.append({"zone": int(zone), "state": STATE_CLOSED, "seconds": 0.0, "net_id": -1})
	return out
