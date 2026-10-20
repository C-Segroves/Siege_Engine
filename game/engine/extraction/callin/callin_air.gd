class_name CallinAir
extends RefCounted
## The air call-ins of the director (host): a bombing run and a fast attack craft, both CallinRequests with a designated point.
## CallinDirector.apply_order validates the request (the raid, points, cooldown, cap, the point's reach and area), makes the
## CallinOrder and hands it to the runner registered for its kind (the two runners here); a runner never picks a point of its
## own. The order is a normal CallinOrder in CallinDirector.orders, so cancel / refund, the order views to the squad, the marker
## and the HUD line work as for every call-in; this class only adds what is air-specific.
##   CallinDelivery -> apply_tick_order     every physics frame of an open air order
##   CallinDirector.apply_cancel -> apply_cancel      the aircraft of a cancelled order goes
##   CallinDirector._physics_process -> apply_tick     aircraft whose order is over fly out, then leave the battle
##   CallinDirector.apply_peer_dead / extracted -> apply_caller_gone
## Each runner's aircraft is an AI flyer with the meta CallinAirframes.CALLER_META (his peer): kills credit the caller.

var callins: CallinDirector
var bombing: CallinBombingRun
var attack: CallinAttackCraft
var _runners := {}


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins
	bombing = CallinBombingRun.new(callins)
	attack = CallinAttackCraft.new(callins)
	_runners = {CallinRules.KIND_BOMBING: bombing, CallinRules.KIND_ATTACK: attack}
	for kind in _runners:
		var runner := _runners[kind] as CallinAirRunner
		callins.register_runner(kind, runner.apply_start, runner.make_refusal)


## The runner of `kind` (null for a kind that is not an air call-in).
func make_runner(kind: String) -> CallinAirRunner:
	return _runners.get(kind)


## Host, every physics frame of an open air order.
func apply_tick_order(order: CallinOrder, delta: float) -> void:
	var runner := make_runner(order.kind)
	if runner != null:
		runner.apply_tick_order(order, delta)


## Host: the aircraft of a cancelled order goes at once.
func apply_cancel(order: CallinOrder) -> void:
	var runner := make_runner(order.kind)
	if runner != null:
		runner.apply_cancel(order)


## Host, every physics frame.
func apply_tick(delta: float) -> void:
	for runner in _runners.values():
		(runner as CallinAirRunner).apply_tick(delta)


## Host: `peer` died or left the raid.
func apply_caller_gone(peer: int) -> void:
	for runner in _runners.values():
		(runner as CallinAirRunner).apply_caller_gone(peer)
