class_name CallinBombingRun
extends CallinAirRunner
## The bombing run call-in (host; the Tribes 2 Thundersword where installed, else the best installed bomber or flyer, else the
## engine's plain flyer). The caller designates a point and, with a second mark, a direction: a bomber appears at the map edge,
## flies the straight line through the point at height and lets a stick of bombs go along it, then leaves at the far edge.
##   MARKED      the flare and ring at the point and the countdown (marker_s); hostile AI nearby hears it
##   INBOUND     the bomber flies in; allies near the line are told, and told again "danger close" warn_lead_s before the
##               first release
##   DELIVERING  the bombs fall (catalog bombs: the shared weapon/projectile system, damage and splash as any bomb, the bomber
##               their shooter, so a kill credits the caller)
##   DONE        the last bomb is away; the bomber flies on out and is removed
## Friendly fire is the shared system's: the bombs hurt whatever they land near (the raid pays nothing for allies killed).
## The bomber is untouchable and ignored by the AI (like the transports) but shows on every radar.

## Straight flight before the first release, beyond the lead, so the bomber is on the line (m).
const RUNWAY_M := 150.0
## Flight past the last bomb at least (m).
const EXIT_MARGIN_M := 120.0
const GROUND_SAMPLE_STEP_M := 100.0
const NOTICE_TEXT := "BOMBING RUN inbound (%s) along the marked line - keep clear."
const DANGER_TEXT := "DANGER CLOSE: bombs on your position in seconds - get off the line!"
const PROTECTION_S := 100000.0
const FLIGHT_SECONDS_SLACK := 20.0
## Peer slot of the "danger close" warning in CallinAirFlight.warned (a real peer id is positive).
const DANGER_SLOT := -1
## Size of the flash a bomb without a catalog definition makes (share of the ring).
const PLAIN_FLASH_SHARE := 0.3


func get_kind() -> String:
	return CallinRules.KIND_BOMBING


func apply_start(order: CallinOrder, request: CallinRequest) -> void:
	var rule := make_rule()
	var flight := CallinAirFlight.new()
	flight.order_id = order.id
	flight.request = request
	flight.direction = make_direction(request)
	flight.point = make_on_ground(request.point)
	flight.airframe_id = CallinAirframes.pick(rule, true)
	_plan_line(flight, rule)
	order.lz = flight.point
	order.radius = float(rule.get("ring_radius_m", 30.0))
	order.marker_s = CallinRules.marker_seconds(callins.battle.config, get_kind())
	order.eta = order.marker_s + make_release_seconds(flight, rule)
	order.apply_state(CallinOrder.State.MARKED)
	flights[order.id] = flight
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(get_kind()), order.team)


## The impact points of the stick on the ground along the line, first to last.
func make_stick(flight: CallinAirFlight, rule: Dictionary) -> PackedVector3Array:
	var stick := CallinAirLine.make_stick(flight.point, flight.direction, int(rule.get("bombs", 6)), float(rule.get("spacing_m", 24.0)))
	for i in stick.size():
		stick[i] = make_on_ground(stick[i])
	return stick


## Where the line starts and ends, and the height it is flown at.
func _plan_line(flight: CallinAirFlight, rule: Dictionary) -> void:
	var area := make_area(float(rule.get("edge_inset_m", 40.0)))
	var half_stick := make_half_stick(rule)
	var altitude := float(rule.get("altitude_m", 110.0))
	var runway := float(rule.get("speed_mps", 60.0)) * sqrt(2.0 * altitude / CallinBomberPilot.GRAVITY) + half_stick + RUNWAY_M
	var back := maxf(CallinAirLine.make_edge_distance(area, flight.point, flight.direction, -1.0, float(rule.get("approach_m", 1000.0))), runway)
	var ahead := maxf(CallinAirLine.make_edge_distance(area, flight.point, flight.direction, 1.0, float(rule.get("leave_m", 900.0))),
		half_stick + EXIT_MARGIN_M)
	var height := _make_highest_ground(flight, back, ahead) + altitude
	flight.entry = flight.point - flight.direction * back
	flight.exit = flight.point + flight.direction * ahead
	flight.entry.y = height
	flight.exit.y = height


## Half the length of the stick (m).
static func make_half_stick(rule: Dictionary) -> float:
	return float(int(rule.get("bombs", 6)) - 1) * 0.5 * float(rule.get("spacing_m", 24.0))


func _make_highest_ground(flight: CallinAirFlight, back: float, ahead: float) -> float:
	var top := flight.point.y
	var d := -back
	while d <= ahead:
		top = maxf(top, make_on_ground(flight.point + flight.direction * d).y)
		d += GROUND_SAMPLE_STEP_M
	return top


## Seconds from the bomber's appearance to its first release.
func make_release_seconds(flight: CallinAirFlight, rule: Dictionary) -> float:
	var speed := float(rule.get("speed_mps", 60.0))
	var fall := sqrt(2.0 * maxf(flight.entry.y - flight.point.y, 1.0) / CallinBomberPilot.GRAVITY)
	var first_impact := CallinAirLine.make_along(flight.entry, flight.direction, flight.point) - make_half_stick(rule)
	return make_seconds(first_impact - speed * fall, speed)


func apply_tick_order(order: CallinOrder, _delta: float) -> void:
	var flight := make_flight(order)
	if flight == null:
		return
	match order.state:
		CallinOrder.State.MARKED:
			if order.state_time >= order.marker_s:
				_launch(order, flight)
		CallinOrder.State.INBOUND:
			_tick_inbound(order, flight)
		CallinOrder.State.DELIVERING:
			_tick_delivering(order, flight)


## MARKED ended: the bomber appears at the start of the line.
func _launch(order: CallinOrder, flight: CallinAirFlight) -> void:
	var craft := CallinAirframes.build(callins.battle, flight.airframe_id, order.team, order.peer, get_kind(), flight.entry,
		CallinAirLine.make_yaw_of_direction(flight.direction), [], PROTECTION_S)
	if craft == null:
		callins.apply_cancel(order, "No bomber could be launched.", true)
		return
	craft.set_meta("dormant", true)
	craft.set_meta("transport", true)
	flight.craft_id = craft.net_id
	var pilot := _make_pilot(craft, flight)
	flight.pilot = pilot
	craft.ai = pilot
	order.apply_state(CallinOrder.State.INBOUND)
	order.eta = pilot.make_seconds_to_release()
	apply_warning(order, flight, NOTICE_TEXT % CallinAirframes.make_name_of(flight.airframe_id))
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(get_kind()), order.team)
	callins.apply_broadcast(order)


func _make_pilot(craft: Flyer, flight: CallinAirFlight) -> CallinBomberPilot:
	var rule := make_rule()
	var flat_length := Vector2(flight.exit.x - flight.entry.x, flight.exit.z - flight.entry.z).length()
	var pilot := CallinBomberPilot.make(craft, flight.entry, flight.direction, flat_length)
	pilot.cruise_y = flight.entry.y
	pilot.speed = float(rule.get("speed_mps", 60.0))
	pilot.bomb_def = CallinAirframes.make_bomb_def(flight.airframe_id, rule)
	pilot.plan = make_stick(flight, rule)
	if str(pilot.bomb_def.get("id", "")) == "":
		pilot.on_impact = _on_plain_bomb_landed
	return pilot


func _tick_inbound(order: CallinOrder, flight: CallinAirFlight) -> void:
	var pilot := flight.pilot as CallinBomberPilot
	if make_craft(flight) == null:
		callins.apply_cancel(order, "The bomber was lost.", true)
		return
	order.eta = pilot.make_seconds_to_release()
	if order.eta <= float(make_rule().get("warn_lead_s", 5.0)) and not flight.warned.has(DANGER_SLOT):
		flight.warned[DANGER_SLOT] = true
		apply_warning(order, flight, DANGER_TEXT)
	if pilot.released > 0:
		order.eta = -1.0
		order.apply_state(CallinOrder.State.DELIVERING)
		callins.apply_broadcast(order)


func _tick_delivering(order: CallinOrder, flight: CallinAirFlight) -> void:
	var pilot := flight.pilot as CallinBomberPilot
	if not pilot.has_dropped_all() and make_craft(flight) != null:
		return
	order.apply_state(CallinOrder.State.DONE)
	callins.apply_broadcast(order)
	apply_leaving(flight, make_seconds(flight.entry.distance_to(flight.exit), float(make_rule().get("speed_mps", 60.0))) + FLIGHT_SECONDS_SLACK)


## Tells the raid players allied to the caller who stand near the line (`text`); counts what each was told.
func apply_warning(order: CallinOrder, flight: CallinAirFlight, text: String) -> void:
	for peer in make_endangered_allies(order, flight):
		apply_tell(int(peer), text)
		flight.warned[int(peer)] = int(flight.warned.get(int(peer), 0)) + 1


## The raid peers allied to the caller whose soldier or vehicle is within danger_half_width_m of the stick.
func make_endangered_allies(order: CallinOrder, flight: CallinAirFlight) -> Array:
	var rule := make_rule()
	var stick := make_stick(flight, rule)
	var reach := float(rule.get("danger_half_width_m", 45.0))
	var out := []
	for peer in callins.director.make_raid_peers():
		var unit := _make_unit_of(int(peer))
		if unit != null and unit.alive and TeamRelations.is_allied(unit.team, order.team) \
				and CallinAirLine.make_segment_distance(unit.global_position, stick[0], stick[stick.size() - 1]) <= reach:
			out.append(int(peer))
	return out


## The unit a peer is in right now: his vehicle, else his soldier (null when he has none).
func _make_unit_of(peer: int) -> Herc:
	var vehicle = callins.battle.occupancy.vehicle_of(peer)
	if is_instance_valid(vehicle):
		return vehicle as Herc
	var soldier = callins.battle.occupancy.soldier_of(peer)
	return soldier as Herc if is_instance_valid(soldier) else null


## A bomb without a catalog definition has no look of its own on the clients: the pod's flash stands in for it.
func _on_plain_bomb_landed(at: Vector3) -> void:
	callins.send_all("_impact", [at, float(make_rule().get("ring_radius_m", 30.0)) * PLAIN_FLASH_SHARE])
