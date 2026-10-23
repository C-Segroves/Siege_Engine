class_name CallinSweep
extends RefCounted
## The radar sweep call-in: the host finds the hostile units near the caller twice a second and tells him; on his machine
## each one is marked swept on its real radar contact (ContactTable.apply_swept: the unit's node, or the far bot's
## RadarProxy), so every radar, the command map and T-targeting show it for as long as the sweep lasts.

const STEP_SECONDS := 0.5
## A mark outlasts one step a little, so a lost message does not make a contact blink.
const MARK_SECONDS := 0.8

var callins: CallinDirector
## The caller's view: [{id, pos, soldier}] and the seconds the sweep still shows.
var contacts: Array = []
var left := 0.0
var _clock := MissionClock.new()
var _told := {}   # peers who got a contact list and must be told when it ends


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## Host: the runner of the sweep (CallinDirector.register_runner): it is centred on the designated point (order.lz).
func apply_start(order: CallinOrder, _request: CallinRequest) -> void:
	order.ttl_left = float(CallinRules.rule(CallinRules.KIND_RADAR).get("duration_s", 20.0))
	order.apply_state(CallinOrder.State.ACTIVE)
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(order.kind), order.team)


## Host, every physics frame of an ACTIVE sweep.
func apply_tick(order: CallinOrder, delta: float) -> void:
	order.ttl_left -= delta
	if _clock.make_step(delta, STEP_SECONDS) > 0.0 or order.state_time <= delta:
		var found := make_contacts(order)
		for peer in make_audience(order):
			_told[peer] = true
			callins.send_to(int(peer), callins, "_sweep", [found, maxf(order.ttl_left, 0.0)])
	if order.ttl_left <= 0.0:
		for peer in _told:
			callins.send_to(int(peer), callins, "_sweep", [[], 0.0])
		_told.clear()
		order.apply_state(CallinOrder.State.DONE)
		callins.apply_broadcast(order)


## The caller and his team (raid players, late joiners included, as every step is sent afresh); enemies get nothing.
func make_audience(order: CallinOrder) -> Array:
	var out := [order.peer]
	for peer in callins.director.make_raid_peers():
		var soldier := callins.battle.occupancy.soldier_of(int(peer))
		if int(peer) != order.peer and soldier != null and TeamRelations.is_allied(soldier.team, order.team):
			out.append(int(peer))
	return out


## The hostile units within the sweep's range of its centre (the designated point): [{id, pos, soldier}] (every radar contact, far bots included).
func make_contacts(order: CallinOrder) -> Array:
	var origin := order.lz
	var reach := float(CallinRules.rule(CallinRules.KIND_RADAR).get("range_m", 300.0))
	var out := []
	for unit in RadarContacts.make_units(callins.battle.get_tree()):
		if is_instance_valid(unit) and _is_sweepable(unit) and TeamRelations.is_hostile(order.team, unit.team) \
				and unit.global_position.distance_to(origin) <= reach:
			out.append({"id": int(unit.net_id), "pos": unit.global_position, "soldier": _is_soldier(unit)})
	return out


## Every peer that is told: shows `new_contacts` for `seconds`.
func apply_contacts(new_contacts: Array, seconds: float) -> void:
	contacts = new_contacts
	left = seconds
	for c in contacts:
		var unit := _find_unit(int(c.id))
		if unit != null:
			ContactTable.apply_swept(unit, MARK_SECONDS)


func _find_unit(id: int) -> Node3D:
	var node = callins.battle.vehicles.get(id)
	if is_instance_valid(node):
		return node
	var far = callins.battle.get("far_units")
	return far.make_contact(id) if far != null else null


static func _is_sweepable(unit: Node3D) -> bool:
	if unit is RadarProxy:
		return (unit as RadarProxy).alive
	return unit is Herc and (unit as Herc).alive and not unit.has_meta("transport") and not (unit is Infantry and (unit as Infantry).stowed)


static func _is_soldier(unit: Node3D) -> bool:
	return (unit as RadarProxy).is_soldier if unit is RadarProxy else unit is Infantry
