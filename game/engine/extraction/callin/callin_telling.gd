class_name CallinTelling
extends RefCounted
## The network half of CallinDirector: who is told about an order and how (the full view to the caller and his team, the
## marker view to players within sight of the zone), the owner's cooldown mirror, and the send helpers every call-in part
## uses (the test tap sees each message the host sends).

const AUDIENCE_RANGE_M := 400.0
const STALE_VIEW_MS := 3000

var callins: CallinDirector


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## Host: tells who needs to know the state of `order`.
func apply_broadcast(order: CallinOrder) -> void:
	var finished := not order.is_open()
	var audience := make_audience(order)
	for peer in audience:
		send_to(int(peer), callins, "_order_view", [order.make_view(bool(audience[peer]) or finished)])


## peer -> true when he gets the full view, false the marker only.
func make_audience(order: CallinOrder) -> Dictionary:
	var out := {order.peer: true}
	for peer in callins.director.make_raid_peers():
		if int(peer) == order.peer:
			continue
		var soldier := callins.battle.occupancy.soldier_of(int(peer))
		if soldier == null:
			continue
		if soldier.team == order.team:
			out[int(peer)] = true
		elif soldier.global_position.distance_to(order.lz) <= AUDIENCE_RANGE_M:
			out[int(peer)] = false
	return out


## Every peer: keeps (or drops, once the order is over) the view the host told.
func apply_view(view: Dictionary) -> void:
	if int(view.state) >= CallinOrder.State.DONE:
		callins.views.erase(int(view.id))
	else:
		view["seen"] = Time.get_ticks_msec()
		callins.views[int(view.id)] = view
	callins.fx.apply_view(view)


## A marker view (no owner) that the host stopped refreshing (its player walked out of sight) is dropped.
func apply_forget_stale_views() -> void:
	var now := Time.get_ticks_msec()
	var views := callins.views
	for id in views.keys():
		if not views[id].has("peer") and now - int(views[id].get("seen", now)) > STALE_VIEW_MS:
			views.erase(id)


## Host: `peer`'s cooldowns and uses go to him (his menu's "on cooldown" and "no more").
func send_player_state(peer: int) -> void:
	var cooldowns := callins.cooldowns
	var cool := {}
	for kind in CallinRules.KINDS + CallinRules.AIR_KINDS:
		cool[kind] = maxf(cooldowns.make_cool_left(peer, kind), 0.0)
	send_to(peer, callins, "_player_state", [{"cool": cool, "shared": maxf(cooldowns.make_shared_left(peer), 0.0),
		"used": cooldowns.make_used_all(peer)}])


func send_to(peer: int, node: Node, method: String, args: Array) -> void:
	if callins.tap.is_valid():
		callins.tap.call(peer, method, args)
	callins.director.send_to(peer, node, method, args)


func send_all(method: String, args: Array) -> void:
	if callins.tap.is_valid():
		callins.tap.call(CallinDirector.ALL_PEERS, method, args)
	ExtractionDirector.send_all_from(callins, method, args)
