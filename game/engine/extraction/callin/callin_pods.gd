class_name CallinPods
extends RefCounted
## The pods of the call-ins (host; docs/design/lobby_loadout_economy.md section 9.5): what happens when one lands and what it leaves.
##   impact    impact_damage in impact_radius_m to everything on the spot (units, structures; the caller too: the ground
##             ring warns), the impact told to every peer (flash, sound, crater)
##   content   a crate (armour, ammo), a temporary station (repair, inventory) or the vehicle of a delivery
##   ACTIVE    the content lasts ttl_s; the last expiring_s it blinks (EXPIRING); then it is removed
##   stations  every STATION_TICK seconds a repair station heals the allies in its radius, an inventory station refills
##             their health and energy (the supplies themselves are bought at the panel, nothing is free)

const STATION_TICK := 0.5
## Units within this height of the impact point are hit (m).
const IMPACT_HEIGHT := 6.0

var callins: CallinDirector
var _station_left := 0.0


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


# ------------------------------------------------------------------ landing

## Host: the pod of `order` has fallen: impact, then its content; the order is ACTIVE.
func apply_land(order: CallinOrder) -> void:
	order.apply_state(CallinOrder.State.DELIVERING)
	apply_impact(order.lz)
	var rule := CallinRules.rule(order.kind)
	match order.kind:
		CallinRules.KIND_ARMOR, CallinRules.KIND_AMMO:
			_add_crate(order)
		CallinRules.KIND_REPAIR, CallinRules.KIND_INVENTORY:
			_add_station(order)
		CallinRules.KIND_VEHICLE:
			callins.vehicles.apply_pod_delivery(order)   # the vehicle is ACTIVE now
			callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(order.kind), order.team)
			return
	order.ttl_left = CallinRules.make_ttl(callins.battle.config, order.kind)
	order.uses_left = int(rule.get("uses", 0))
	order.eta = -1.0
	order.apply_state(CallinOrder.State.ACTIVE)
	callins.alert.apply_noise(order.lz, CallinRules.make_alert_radius(order.kind), order.team)
	callins.apply_broadcast(order)


## Host: the pod hits `pos`: damage to what is there and the impact told to everybody.
func apply_impact(pos: Vector3) -> void:
	var table := CallinRules.pod()
	var radius := float(table.get("impact_radius_m", 3.5))
	var damage := float(table.get("impact_damage", 400.0))
	for h in callins.battle.vehicles.values():
		if is_instance_valid(h) and h.alive and not h.has_meta("transport") and _is_under(h.global_position, pos, radius):
			(h as Herc).apply_hit(0.0, damage, null, pos)
	for s in callins.get_tree().get_nodes_in_group(Structure.TARGET_GROUP):
		if s is Structure and (s as Structure).alive and _is_under((s as Structure).global_position, pos, radius):
			(s as Structure).apply_hit(0.0, damage, null, pos)
	callins.send_all("_impact", [pos, radius])


static func _is_under(at: Vector3, pos: Vector3, radius: float) -> bool:
	return Vector2(at.x - pos.x, at.z - pos.z).length() <= radius and absf(at.y - pos.y) <= IMPACT_HEIGHT


func _add_crate(order: CallinOrder) -> void:
	order.object_id = callins.make_object_id()
	callins.send_all("_crate_add", [{"id": order.object_id, "kind": order.kind, "variant": order.variant, "team": order.team, "pos": make_crate_point(order.lz),
		"uses": maxi(int(CallinRules.rule(order.kind).get("uses", 1)), 1), "hp": float(CallinRules.rule(order.kind).get("hp", 250.0))}])


## Where the crate stands: the landing point itself, else the nearest standable floor within reach (never in or under
## a slab of the landing zone; LootDropPlacement).
func make_crate_point(lz: Vector3) -> Vector3:
	var battle := callins.battle
	return LootDropPlacement.make_point(battle.get_world_3d().direct_space_state, ExitSafety.make_unit_rids(battle), lz,
		MapBuilder.ground_height(battle, lz), float(ExtractionRules.data().get("pickup_reach_m", 3.0)))


func _add_station(order: CallinOrder) -> void:
	var rule := CallinRules.rule(order.kind)
	order.object_id = callins.make_object_id()
	callins.send_all("_station_add", [{"id": order.object_id, "kind": order.kind, "team": order.team, "pos": order.lz,
		"hp": float(rule.get("hp", 1500.0))}])


# ------------------------------------------------------------------ ACTIVE

## Host: one frame of an ACTIVE or EXPIRING pod order; true once it is over (removed).
func apply_active_tick(order: CallinOrder, delta: float) -> bool:
	order.ttl_left -= delta
	var gone := order.ttl_left <= 0.0 or _is_content_gone(order)
	if not gone and order.state == CallinOrder.State.ACTIVE and order.ttl_left <= float(CallinRules.pod().get("expiring_s", 8.0)):
		order.apply_state(CallinOrder.State.EXPIRING)
		callins.apply_content_expiring(order)
		callins.apply_broadcast(order)
	if gone:
		apply_remove_content(order)
	return gone


## True when the crate is used up or the station was destroyed.
func _is_content_gone(order: CallinOrder) -> bool:
	match order.kind:
		CallinRules.KIND_ARMOR, CallinRules.KIND_AMMO:
			var crate: CallinCrate = callins.crates.get(order.object_id)
			return order.uses_left <= 0 or crate == null or not is_instance_valid(crate) or not crate.alive
		CallinRules.KIND_REPAIR, CallinRules.KIND_INVENTORY:
			var st: TempStation = callins.stations.get(order.object_id)
			return st == null or not is_instance_valid(st) or not st.alive
	return false


func apply_remove_content(order: CallinOrder) -> void:
	match order.kind:
		CallinRules.KIND_ARMOR, CallinRules.KIND_AMMO:
			callins.send_all("_crate_remove", [order.object_id])
		CallinRules.KIND_REPAIR, CallinRules.KIND_INVENTORY:
			callins.send_all("_station_remove", [order.object_id])


# ------------------------------------------------------------------ stations at work

## Host, every physics frame: the stations act every STATION_TICK seconds.
func apply_station_tick(delta: float) -> void:
	_station_left -= delta
	if _station_left > 0.0:
		return
	_station_left = STATION_TICK
	for st in callins.stations.values():
		if is_instance_valid(st) and (st as TempStation).alive:
			_apply_station(st as TempStation)


func _apply_station(st: TempStation) -> void:
	var rule := CallinRules.rule(st.station_kind)
	var radius := float(rule.get("radius_m", 6.0))
	for h in callins.battle.vehicles.values():
		if not is_instance_valid(h) or not h.alive or h.has_meta("transport") or not TeamRelations.is_allied(h.team, st.team):
			continue
		if Vector2(h.global_position.x - st.global_position.x, h.global_position.z - st.global_position.z).length() > radius \
				or absf(h.global_position.y - st.global_position.y) > IMPACT_HEIGHT:
			continue
		if st.station_kind == CallinRules.KIND_REPAIR:
			_apply_repair(h as Herc, rule)
		elif h is Infantry and not (h as Infantry).stowed:
			_apply_refill(h as Infantry)


## A repair station: a soldier gains heal_per_s of health, a vehicle's living components a share of their maximum.
func _apply_repair(h: Herc, rule: Dictionary) -> void:
	if h is Infantry:
		InfantryPack.apply_repair(h as Infantry, float(rule.get("heal_per_s", 60.0)) * STATION_TICK)
		return
	var share := float(rule.get("vehicle_heal_share_per_s", 0.04)) * STATION_TICK
	for c in h.components:
		if float(c.hp) > 0.0:
			c.hp = minf(float(c.max), float(c.hp) + float(c.max) * share)
	h.integrity = HercDamage.integrity_of(h.components)


## An inventory station: health and energy back (gear is bought at its panel, never free).
func _apply_refill(soldier: Infantry) -> void:
	InfantryPack.apply_repair(soldier, float(soldier.components[0].max))
	soldier.capacitor = soldier.capacitor_max
