class_name CallinOrders
extends RefCounted
## The host's making and ending of call-in orders (CallinDirector hands its apply_order / apply_cancel / apply_peer_* to it):
## judge a request, take the raid points, start the cooldown and hand the order to its kind's runner; cancel an order on its
## way (with or without a refund); settle the orders of a player who extracted, died or left.

const VIEW_SECONDS := 0.5

var _callins: CallinDirector
var _next_order := 1
var _view_clock := MissionClock.new()


func _init(callins: CallinDirector) -> void:
	_callins = callins


## Host: judges `request` (CallinChecks.make_plan: the facts, then the designated point) and, when it passes, takes the raid
## points, starts the cooldown and hands the order to the runner of its kind. Returns the order, null when it was refused
## (the caller is told why).
func apply_order(request: CallinRequest) -> CallinOrder:
	var c := _callins
	var plan := c.checks.make_plan(request)
	if bool(plan.ok) and not c.runners.has(request.kind):
		plan = {"ok": false, "pos": request.point, "reason": CallinRefusals.NO_COST}
	if not bool(plan.ok):
		c.director.notify(request.peer, str(plan.reason))
		return null
	var soldier := c.battle.occupancy.soldier_of(request.peer)
	var order := CallinOrder.new()
	order.id = _next_order
	_next_order += 1
	order.kind = request.kind
	order.variant = request.variant
	order.peer = request.peer
	order.team = soldier.team
	order.source = request.source
	order.lz = plan.pos
	order.direction = request.make_direction(-soldier.global_basis.z)
	order.vehicle_id = c.checks.make_vehicle_id(request.peer) if request.kind == CallinRules.KIND_VEHICLE else ""
	order.cost = CallinRules.make_cost(request.kind, request.variant, order.vehicle_id)
	c.points.apply_spend(request.peer, order.cost)
	c.cooldowns.apply_use(request.peer, request.kind, c.battle.config)
	c.orders[order.id] = order
	(c.runners[request.kind] as Callable).call(order, request)
	c.apply_broadcast(order)
	c.telling.send_player_state(request.peer)
	c.director.notify(request.peer, "%s called in (%d RP)." % [CallinRules.make_label(request.kind), order.cost])
	return order


## Host: cancels an order that is on its way: the pod, the transport and the load go, and with `refund` the raid points
## and the use come back.
func apply_cancel(order: CallinOrder, reason: String, refund: bool) -> void:
	if not order.is_open():
		return
	var c := _callins
	if order.kind == CallinRules.KIND_VEHICLE:
		c.vehicles.apply_cancel(order)
	c.air.apply_cancel(order)
	if refund:
		c.points.apply_refund(order.peer, order.cost)
		c.cooldowns.apply_unuse(order.peer, order.kind)
		c.telling.send_player_state(order.peer)
	order.cancel_reason = reason
	order.apply_state(CallinOrder.State.CANCELLED)
	c.director.notify(order.peer, "%s cancelled: %s%s" % [CallinRules.make_label(order.kind), reason, "  Raid points refunded." if refund else ""])
	c.apply_broadcast(order)


## Host: the orders of `peer` on their way are cancelled with a refund (he extracted: the points stay with him).
func apply_peer_extracted(peer: int) -> void:
	var c := _callins
	for o in c.orders.values():
		if (o as CallinOrder).peer == peer and (o as CallinOrder).is_in_flight():
			apply_cancel(o, "You left the raid.", true)
	c.air.apply_caller_gone(peer)
	c.supplies.apply_forget(peer)


## Host: `peer` died or left: his orders on their way are cancelled and his points are gone.
func apply_peer_dead(peer: int) -> void:
	var c := _callins
	for o in c.orders.values():
		var order := o as CallinOrder
		if order.peer != peer:
			continue
		if order.is_in_flight():
			apply_cancel(order, "The operator is gone.", false)
		elif order.kind == CallinRules.KIND_RADAR and order.is_open():
			order.apply_state(CallinOrder.State.DONE)   # a sweep shows its caller only
			c.apply_broadcast(order)
	c.air.apply_caller_gone(peer)
	c.supplies.apply_forget(peer)
	c.points.apply_clear(peer)


## Host, every physics frame of a raid: the cooldowns, the noise, the crates, the stations, the flights and every order's
## state; twice a second each open order is told to those who need to know.
func apply_tick(delta: float) -> void:
	var c := _callins
	c.cooldowns.apply_tick(delta)
	c.alert.apply_tick(delta)
	c.supplies.apply_tick(delta)
	c.pods.apply_station_tick(delta)
	c.vehicles.apply_departures()
	c.air.apply_tick(delta)
	for o in c.orders.values().duplicate():
		c.delivery.apply_tick_order(o as CallinOrder, delta)
	if _view_clock.make_step(delta, VIEW_SECONDS) > 0.0:
		for o in c.orders.values():
			if (o as CallinOrder).is_open():
				c.apply_broadcast(o)
