class_name CallinContent
extends RefCounted
## What a delivered pod leaves behind: the crates (armour, ammunition) and the temporary stations, their use and the
## interact offer for them. The RPCs that build and update them stay on CallinDirector (a node path every peer shares).

const CRATE_REACH := 3.0
const STATION_HEIGHT := 3.5

var callins: CallinDirector
var _next_object := 1


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


func make_object_id() -> int:
	var id := _next_object
	_next_object += 1
	return id


## Host: `peer` uses crate `crate_id`: the armour change or the ammunition refill.
func apply_use_crate(peer: int, crate_id: int) -> void:
	var director := callins.director
	var soldier := callins.battle.occupancy.soldier_of(peer)
	var crate := callins.crates.get(crate_id) as CallinCrate
	var order := find_order_of_object(crate_id)
	if soldier == null or crate == null or not crate.alive or order == null or not director.is_in_raid(peer) or not soldier.alive or soldier.stowed \
			or DownedState.is_downed(soldier) or order.uses_left <= 0:
		return
	if Vector2(crate.global_position.x - soldier.global_position.x, crate.global_position.z - soldier.global_position.z).length() > CRATE_REACH + 1.0:
		return
	if crate.station_kind == CallinRules.KIND_ARMOR:
		if not callins.supplies.apply_temp_armor(peer, soldier, crate.variant):
			director.notify(peer, "This game has no %s armour." % crate.variant)
			return
		director.notify(peer, "Wearing %s armour for a while; your kit stays." % crate.variant)
	else:
		CallinSupplies.apply_ammo_refill(soldier)
		director.notify(peer, "Ammunition refilled.")
	order.uses_left -= 1
	callins.send_all("_crate_state", [crate_id, order.uses_left, crate.expiring])


## The order whose pod content is object `object_id` (null when none).
func find_order_of_object(object_id: int) -> CallinOrder:
	for o in callins.orders.values():
		if (o as CallinOrder).object_id == object_id and (o as CallinOrder).is_open():
			return o
	return null


## Host: the content of `order` starts to blink (its last seconds).
func apply_content_expiring(order: CallinOrder) -> void:
	if callins.crates.has(order.object_id):
		callins.send_all("_crate_state", [order.object_id, order.uses_left, true])
	elif callins.stations.has(order.object_id):
		callins.send_all("_station_state", [order.object_id, true])


func find_inventory_station(soldier: Infantry) -> TempStation:
	if soldier == null:
		return null
	for st in callins.stations.values():
		var station := st as TempStation
		if is_instance_valid(station) and station.alive and station.station_kind == CallinRules.KIND_INVENTORY \
				and TeamRelations.is_allied(soldier.team, station.team):
			var rel := soldier.global_position - station.global_position
			var reach := float(CallinRules.rule(CallinRules.KIND_INVENTORY).get("radius_m", 2.5)) + 1.0
			if Vector2(rel.x, rel.z).length() <= reach and absf(rel.y) <= STATION_HEIGHT:
				return station
	return null


## InfantryInteraction provider: a crate within reach, or the call-in inventory station underfoot.
func make_offer(soldier: Infantry) -> Dictionary:
	var director := callins.director
	if director.my_status != ExtractionDirector.STATUS_IN_RAID or DownedState.is_downed(soldier):
		return {}
	var crate := _find_crate_near(soldier.global_position)
	if crate != null:
		return {"distance": Vector2(crate.global_position.x - soldier.global_position.x, crate.global_position.z - soldier.global_position.z).length(),
			"text": "use the %s" % crate.make_title(), "apply": func() -> void: callins.request_use_crate(crate.station_id)}
	var station := find_inventory_station(soldier)
	if station != null:
		return {"distance": soldier.global_position.distance_to(station.global_position), "text": "use the inventory station",
			"apply": func() -> void: director.station.open_for(soldier)}
	return {}


func _find_crate_near(p: Vector3) -> CallinCrate:
	var best: CallinCrate = null
	var best_d := CRATE_REACH
	for c in callins.crates.values():
		if not is_instance_valid(c) or not (c as CallinCrate).alive:
			continue
		var d := Vector2(c.global_position.x - p.x, c.global_position.z - p.z).length()
		if d <= best_d and absf(c.global_position.y - p.y) <= CRATE_REACH:
			best_d = d
			best = c
	return best
