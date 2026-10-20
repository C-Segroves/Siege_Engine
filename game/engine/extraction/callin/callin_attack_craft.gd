class_name CallinAttackCraft
extends CallinAirRunner
## The fast attack craft call-in (host; the Tribes 2 Shrike where installed, else the strongest armed flyer, else the engine's
## plain flyer). An AI gunship flies to the designated point and works it for loiter_s seconds: strafing runs at the hostile
## units near the point (CallinAttackPilot), orbiting while there are none. It is a real battle vehicle: hostile AI targets it,
## it takes damage, and when it is shot down it crashes. It leaves when its time or its ammunition is gone. Its kills (and
## assists) credit the caller for raid points (ExtractionDirector.peer_of_unit reads the caller on the aircraft).
##   MARKED      the flare and ring and the countdown (marker_s); hostile AI nearby hears it
##   INBOUND     the craft flies in from the map edge along the designated direction
##   ACTIVE      on station: attacking; the HUD shows the time left
##   EXPIRING    its time or ammunition ended: it flies out
##   DONE        it left, or it was shot down (its wreck lies wreck_s seconds)

const MIN_LOITER_S := 1.0
const LOST_TEXT := "Your attack craft was shot down."
const LEFT_TEXT := "Your attack craft is leaving the area."
## Seconds the craft's flight out may take beyond its length at the cruise speed (s).
const FLIGHT_SECONDS_SLACK := 20.0


func get_kind() -> String:
	return CallinRules.KIND_ATTACK


func apply_start(order: CallinOrder, request: CallinRequest) -> void:
	var rule := make_rule()
	var flight := CallinAirFlight.new()
	flight.order_id = order.id
	flight.request = request
	flight.direction = make_direction(request)
	flight.point = make_on_ground(request.point)
	flight.airframe_id = CallinAirframes.pick(rule, false)
	var area := make_area(float(rule.get("edge_inset_m", 40.0)))
	flight.entry = CallinAirLine.make_entry(area, flight.point, flight.direction, float(rule.get("approach_m", 900.0)))
	flight.exit = CallinAirLine.make_exit(area, flight.point, flight.direction, float(rule.get("leave_m", 700.0)))
	order.lz = flight.point
	order.radius = float(rule.get("engage_radius_m", 200.0)) * 0.3
	order.marker_s = CallinRules.marker_seconds(callins.battle.config, get_kind())
	order.eta = order.marker_s + make_seconds(flight.entry.distance_to(flight.point), _make_speed(flight))
	order.apply_state(CallinOrder.State.MARKED)
	flights[order.id] = flight
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(get_kind()), order.team)


## The craft's cruise speed (m/s): the pack's flyer, else the rule's guess.
func _make_speed(flight: CallinAirFlight) -> float:
	return CallinVehicleRun.make_cruise_speed(flight.airframe_id)


## Seconds the station is worked (callins.fast does not shorten it: the tests set it).
func make_loiter_seconds() -> float:
	return maxf(float(make_rule().get("loiter_s", 45.0)), MIN_LOITER_S)


func apply_tick_order(order: CallinOrder, _delta: float) -> void:
	var flight := make_flight(order)
	if flight == null:
		return
	match order.state:
		CallinOrder.State.MARKED:
			if order.state_time >= order.marker_s:
				_launch(order, flight)
		CallinOrder.State.INBOUND, CallinOrder.State.ACTIVE, CallinOrder.State.EXPIRING:
			_tick_flying(order, flight)


## MARKED ended: the craft appears at the start of its approach.
func _launch(order: CallinOrder, flight: CallinAirFlight) -> void:
	var rule := make_rule()
	var craft := CallinAirframes.build(callins.battle, flight.airframe_id, order.team, order.peer, get_kind(), flight.entry,
		CallinAirLine.make_yaw_of_direction(flight.direction), CallinAirframes.make_loadout(flight.airframe_id, rule),
		float(rule.get("protection_s", 3.0)))
	if craft == null:
		callins.apply_cancel(order, "No gunship could be launched.", true)
		return
	flight.craft_id = craft.net_id
	_apply_ammunition(craft, int(rule.get("ammo_rounds", 300)))
	var pilot := CallinAttackPilot.make(craft, flight.point, flight.exit, rule, make_loiter_seconds())
	flight.pilot = pilot
	craft.ai = pilot
	order.apply_state(CallinOrder.State.INBOUND)
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(get_kind()), order.team)
	callins.apply_broadcast(order)


## The craft carries `rounds` for each of its guns.
func _apply_ammunition(craft: Flyer, rounds: int) -> void:
	for w in craft.weapons:
		if not (w as Weapon).is_passive():
			(w as Weapon).ammo_max = rounds
			(w as Weapon).ammo = rounds


func _tick_flying(order: CallinOrder, flight: CallinAirFlight) -> void:
	var craft := make_craft(flight)
	var pilot := flight.pilot as CallinAttackPilot
	if craft == null or not craft.alive:
		_apply_lost(order, flight, craft)
		return
	match order.state:
		CallinOrder.State.INBOUND:
			order.eta = make_seconds(Vector2(craft.global_position.x - flight.point.x, craft.global_position.z - flight.point.z).length(), _make_speed(flight))
			if pilot.is_on_station():
				order.eta = -1.0
				order.ttl_left = pilot.loiter_left
				order.apply_state(CallinOrder.State.ACTIVE)
				callins.apply_broadcast(order)
		CallinOrder.State.ACTIVE:
			order.ttl_left = pilot.loiter_left
			if pilot.is_leaving():
				order.apply_state(CallinOrder.State.EXPIRING)
				apply_tell(order.peer, LEFT_TEXT)
				callins.apply_broadcast(order)
		CallinOrder.State.EXPIRING:
			if pilot.is_done():
				_apply_finished(order, flight)


## The craft is gone (shot down, or removed): the order is over; a wreck lies a while.
func _apply_lost(order: CallinOrder, flight: CallinAirFlight, craft: Flyer) -> void:
	if craft != null:
		apply_tell(order.peer, LOST_TEXT)
	order.apply_state(CallinOrder.State.DONE)
	callins.apply_broadcast(order)
	apply_leaving(flight, float(make_rule().get("wreck_s", 8.0)))
	flight.pilot = null


func _apply_finished(order: CallinOrder, flight: CallinAirFlight) -> void:
	order.apply_state(CallinOrder.State.DONE)
	callins.apply_broadcast(order)
	apply_leaving(flight, 0.0)


## The caller is dead or gone: the craft leaves its station (its time paid for, but nobody is credited any more).
func apply_caller_gone(peer: int) -> void:
	for id in flights:
		var flight: CallinAirFlight = flights[id]
		if flight.request.peer == peer and flight.pilot != null:
			(flight.pilot as CallinAttackPilot).apply_leave()
