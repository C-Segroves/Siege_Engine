class_name CallinDelivery
extends RefCounted
## The host's sequencing of an order through its states (CallinDirector ticks it every physics frame): MARKED, the zone
## checked again just before the delivery, INBOUND, DELIVERING, ACTIVE and EXPIRING; the pods and the vehicle run do the
## work of each step (CallinPods, CallinVehicleRun), the sweep has its own tick (CallinSweep).

var callins: CallinDirector


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


func apply_tick_order(order: CallinOrder, delta: float) -> void:
	if not order.is_open():
		callins.orders.erase(order.id)
		return
	order.apply_tick(delta)
	if order.is_in_flight() and order.age > CallinRules.order_timeout(callins.battle.config):
		callins.apply_cancel(order, "It took too long.", true)
		return
	if order.kind == CallinRules.KIND_RADAR:
		callins.sweep.apply_tick(order, delta)
		return
	if CallinRules.is_air_kind(order.kind):
		callins.air.apply_tick_order(order, delta)
		return
	match order.state:
		CallinOrder.State.MARKED:
			_tick_marked(order)
		CallinOrder.State.INBOUND:
			_tick_inbound(order)
		CallinOrder.State.DELIVERING:
			callins.vehicles.apply_delivering_tick(order)
		CallinOrder.State.ACTIVE, CallinOrder.State.EXPIRING:
			_tick_active(order, delta)


## Host: the runner of the pods and the vehicle (CallinDirector.register_runner): the zone is the designated point, already
## validated and put on the floor (order.lz); the marker starts.
func apply_start_marked(order: CallinOrder, _request: CallinRequest) -> void:
	order.radius = CallinChecks.make_footprint(order.kind, order.vehicle_id)
	if order.kind == CallinRules.KIND_VEHICLE:
		callins.vehicles.apply_plan(order)
	else:
		order.marker_s = CallinRules.marker_seconds(callins.battle.config, order.kind)
		order.fall_s = CallinRules.make_fall_seconds()
		order.eta = order.marker_s + order.fall_s
	order.apply_state(CallinOrder.State.MARKED)
	callins.alert.apply_noise(order.lz, float(CallinRules.data().get("marker", {}).get("alert_radius_m", 120.0)), order.team)


func _tick_marked(order: CallinOrder) -> void:
	var lead := CallinRules.number(callins.battle.config, CallinRules.lz(), "revalidate_s", 3.0)
	if not order.revalidated and order.state_time >= order.marker_s - lead:
		order.revalidated = true
		if not _revalidate(order):
			return
	if order.state_time < order.marker_s:
		return
	if order.kind == CallinRules.KIND_VEHICLE:
		callins.vehicles.apply_launch(order)
	else:
		order.apply_state(CallinOrder.State.INBOUND)
		order.eta = order.fall_s
	callins.apply_broadcast(order)


## The zone is checked again just before the delivery: it may shift lz.shift_m, else the order is cancelled.
func _revalidate(order: CallinOrder) -> bool:
	var plan := CallinSafety.find_landing(callins.battle, order.lz, order.radius, order.team)
	var shift := Vector2(plan.pos.x - order.lz.x, plan.pos.z - order.lz.z).length()
	if not bool(plan.ok) or shift > float(CallinRules.lz().get("shift_m", 15.0)):
		callins.apply_cancel(order, "The landing zone is no longer clear.", true)
		return false
	if shift > 0.1:
		order.lz = plan.pos
		callins.director.notify(order.peer, "Landing zone moved %d m." % int(round(shift)))
	return true


func _tick_inbound(order: CallinOrder) -> void:
	if order.kind == CallinRules.KIND_VEHICLE and order.transport_id >= 0:
		callins.vehicles.apply_inbound_tick(order)
	elif order.state_time >= order.fall_s:
		callins.pods.apply_land(order)


func _tick_active(order: CallinOrder, delta: float) -> void:
	var over := callins.vehicles.apply_active_tick(order, delta) if order.kind == CallinRules.KIND_VEHICLE else callins.pods.apply_active_tick(order, delta)
	if over:
		order.apply_state(CallinOrder.State.DONE)
		callins.apply_broadcast(order)
