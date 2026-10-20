extends Node
## Tribes base equipment (docs/TRIBES_BASE_EQUIPMENT.md), on a Tribes map and a Tribes 2 map in real battles:
##   audit       every installed Tribes / Tribes 2 arena map: its base objects, which have a spec, armed turrets,
##               objects without power at the start (printed as the doc's table);
##   power grid  generators power their group and the groups below; a provides_power group is always powered;
##   turrets     a turret fires at an enemy in range and ignores a teammate;
##   power       destroying the generators powers the turret and the stations down, repairing powers them up;
##               the repair pack repairs a damaged generator;
##   stations    the inventory station is offered through interact, changes the loadout, refills ammo and health;
##               the vehicle station puts a vehicle on the pad; free-for-all makes the base neutral.
## godot --headless --audio-driver Dummy --path game res://tests/tribes_base_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const MAPS := ["tribes:Raindance", "tribes2:Katabatic"]
const AUDIT_PACKS := ["tribes", "tribes2"]
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const TARGET_VEHICLE := "es1:SCORPION"
## Distances (share of the turret's range) and bearings tried for a target spot in the turret's sight.
const SPOT_SHARES := [0.3, 0.5, 0.7]
const SPOT_BEARINGS := 12
const FIRE_WAIT_SECONDS := 6.0
const REPAIR_WAIT_SECONDS := 2.0

var _failures := 0
var _guard := SavedCampaignGuard.new()


func _ready() -> void:
	_guard.back_up()
	await get_tree().process_frame
	_check_audit()
	_check_power_grid()
	for map_id in MAPS:
		if MapBuilder.load_map(map_id).is_empty():
			print("skip %s: not installed" % map_id)
			continue
		await _check_map(map_id)
	Engine.time_scale = 1.0
	_guard.restore()
	print("tribes_base_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true, true).timeout


# ------------------------------------------------------------------ audit (data only)

## One line per map: base objects by kind, specs found, armed turrets, unpowered objects at the start.
func _check_audit() -> void:
	print("audit: map | objects (kinds) | with spec | turrets armed | unpowered at start")
	for pack in AUDIT_PACKS:
		if TribesBase.load_specs(pack).is_empty():
			print("  %s: no base_equipment.json (run tools/export_tribes_base.py)" % pack)
			continue
		var missing := 0
		for e in Assets.load_json("maps/_index.json", pack):
			missing += _audit_map(pack, str(e.id))
		_expect(missing == 0, "%s: every base station of every map has a spec" % pack)


func _audit_map(pack: String, id: String) -> int:
	var m := MapBuilder.load_map("%s:%s" % [pack, id])
	var kinds := {}
	var specs := 0
	var armed := 0
	var turrets := 0
	var missing := 0
	var sources := []
	var objects := []
	for st in m.get("stations", []):
		var spec := TribesBase.make_spec(pack, st)
		if spec.is_empty():
			missing += 1 if str(st.get("kind", "")) in ["turret", "generator", "sensor", "inventory", "vehicle"] else 0
			continue
		specs += 1
		kinds[spec.kind] = int(kinds.get(spec.kind, 0)) + 1
		objects.append([spec, int(st.get("power_group", -1))])
		if spec.kind == "turret":
			turrets += 1
			armed += 1 if spec.get("turret") is Dictionary and not Packs.weapon(str(spec.turret.weapon)).is_empty() else 0
		if spec.kind == "generator":
			sources.append(int(st.get("power_group", -1)))
	var powered := TribesPowerGrid.make_for(m).make_powered_groups(sources)
	var unpowered := objects.filter(func(o: Array) -> bool: return o[0].kind != "generator" and not powered.has(o[1])).size()
	print("  %s:%s | %d %s | %d | %d/%d | %d" % [pack, id, specs, kinds, specs, armed, turrets, unpowered])
	return missing


# ------------------------------------------------------------------ power grid (unit)

func _check_power_grid() -> void:
	print("power grid:")
	var m := {"power_groups": [{"parent": -1}, {"parent": 0}, {"parent": 1}, {"parent": 0}, {"parent": 0, "provides_power": true}]}
	var grid := TribesPowerGrid.make_for(m)
	var on := grid.make_powered_groups([1])
	_expect(on.has(1) and on.has(2) and not on.has(0) and not on.has(3), "a generator powers its group and the groups below only")
	_expect(on.has(4), "a providesPower group is powered without a generator")
	_expect(not grid.make_powered_groups([]).has(1), "no working generator: no power")


# ------------------------------------------------------------------ battle

func _check_map(map_id: String) -> void:
	print("%s:" % map_id)
	var battle := await _start_battle(map_id)
	Engine.time_scale = TIME_SCALE
	var base := TribesBase.of(battle)
	_expect(base != null and not base.objects.is_empty(), "the map's base is built (%d objects)" % (base.objects.size() if base else 0))
	if base:
		_expect(base.objects.all(func(o: TribesBaseObject) -> bool: return o.is_in_group(Structure.TARGET_GROUP)),
			"base objects are targetable structures")
		var turret := _find_turret(base, 0)
		_expect(turret != null, "team 0 has an armed, powered turret")
		if turret:
			await _check_turret(battle, turret)
			await _check_power(battle, base, turret)
		await _check_inventory(battle)
		await _check_vehicle_station(battle)
		_check_neutral(battle, base)
		_check_owners(base)
	Engine.time_scale = 1.0
	battle.queue_free()
	await _frames(4)


func _start_battle(map_id: String) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": map_id, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


## A working armed turret of `team` (outdoor ones first: the longest range).
func _find_turret(base: TribesBase, team: int) -> TribesTurret:
	var best: TribesTurret = null
	for o in base.objects_of(TribesBaseObject.KIND_TURRET):
		var t := o as TribesTurret
		if t and t.team == team and t.is_armed() and t.is_working() and (best == null or t.engage_range > best.engage_range):
			best = t
	return best


## A ground spot in the turret's range, arc and sight ({} when none is found).
func _find_spot(battle: Battle, turret: TribesTurret, dummy: Node3D) -> Dictionary:
	for share in SPOT_SHARES:
		for k in SPOT_BEARINGS:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / SPOT_BEARINGS)
			var p := turret.global_position + dir * turret.engage_range * float(share)
			p.y = MapBuilder.ground_height(battle, p) + 0.5
			dummy.global_position = p
			var aim := p + Vector3.UP * TribesTurret.VEHICLE_AIM_HEIGHT
			if turret.is_in_arc(aim - turret.make_muzzle()) and turret.has_line_of_sight(dummy):
				return {"pos": p}
	return {}


func _check_turret(battle: Battle, turret: TribesTurret) -> void:
	var enemy := battle.spawn_ai(TARGET_VEHICLE, 1, Transform3D(Basis(), turret.global_position + Vector3(0, 500, 0)), [], "Target", {"skill": 0.0})
	for c in enemy.get_children():
		if c is AIPilot:
			c.queue_free()
	enemy.end_spawn_protection()
	var spot := _find_spot(battle, turret, enemy)
	_expect(not spot.is_empty(), "%s: found a spot in its sight" % turret.display_name)
	if spot.is_empty():
		enemy.queue_free()
		return
	enemy.team = 0
	await _frames(3)
	turret._think_t = 0.0
	await _frames(3)
	_expect(turret.find_target() == null and turret.target == null, "%s ignores a teammate in range" % turret.display_name)
	enemy.team = 1
	enemy.global_position = spot.pos
	var shots := turret.shots_fired
	var health := _make_health(enemy)
	await _seconds(FIRE_WAIT_SECONDS)
	_expect(turret.target == enemy or not enemy.alive, "%s targets the enemy" % turret.display_name)
	_expect(turret.shots_fired > shots, "%s fires at the enemy (%d shots)" % [turret.display_name, turret.shots_fired - shots])
	_expect(not enemy.alive or _make_health(enemy) < health, "the enemy is hit (shields + armour %.0f -> %.0f)" % [health, _make_health(enemy)])
	if is_instance_valid(enemy):
		enemy.global_position += Vector3(0, 2000, 0)


## Shields plus armour left (a Herc's shields take the first hits).
static func _make_health(h: Herc) -> float:
	return h.shield_front + h.shield_rear + h.integrity * 10000.0


## Destroying the generators that feed the turret's group powers it (and the base's stations) down; repairing
## them powers them up again; the repair pack repairs a generator.
func _check_power(battle: Battle, base: TribesBase, turret: TribesTurret) -> void:
	var gens := base.objects_of(TribesBaseObject.KIND_GENERATOR).filter(
		func(g: TribesBaseObject) -> bool: return base.grid.make_powered_groups([g.power_group]).has(turret.power_group))
	_expect(not gens.is_empty(), "the turret's group is fed by %d generator(s)" % gens.size())
	var stations: TribesStations = battle.get_node("Stations")
	var station := _station_fed_by(stations, base, gens)
	for g in gens:
		for i in 4:     # a Tribes 2 generator's shield energy takes the first hit
			g.apply_hit(0.0, g.max_hp, null)
	await _seconds(TribesBase.STATE_CHECK_SECONDS * 2.0)
	_expect(gens.all(func(g: TribesBaseObject) -> bool: return not g.alive), "the generators are destroyed")
	_expect(not turret.powered and not turret.is_working(), "the turret loses power")
	var shots := turret.shots_fired
	await _seconds(1.0)
	_expect(turret.shots_fired == shots and turret.target == null, "an unpowered turret does not fire")
	if station >= 0:
		_expect(not TribesBase.is_working(stations.stations[station].object), "a station of that base is off")
	for g in gens:
		g.apply_repair(g.max_hp)
	await _seconds(TribesBase.STATE_CHECK_SECONDS * 2.0)
	_expect(gens.all(func(g: TribesBaseObject) -> bool: return g.alive and g.is_enabled()), "the repaired generators are enabled")
	_expect(turret.powered and turret.is_working(), "the turret has power again")
	if station >= 0:
		_expect(TribesBase.is_working(stations.stations[station].object), "the station works again")
	await _check_repair_pack(battle, base, gens[0] if not gens.is_empty() else null)


func _station_fed_by(stations: TribesStations, base: TribesBase, gens: Array) -> int:
	for i in stations.stations.size():
		var obj = stations.stations[i].get("object")
		for g in gens:
			if obj is TribesBaseObject and base.grid.make_powered_groups([g.power_group]).has(obj.power_group):
				return i
	return -1


func _check_repair_pack(battle: Battle, base: TribesBase, gen: TribesBaseObject) -> void:
	var s := battle.player as Infantry
	var repair_pack := _repair_pack_id(s)
	_expect(repair_pack != "", "the armour can wear a repair pack")
	if gen == null or repair_pack == "":
		return
	gen.apply_hit(0.0, gen.max_hp * 0.3, null)
	var hurt := gen.hp
	s.team = gen.team
	s.kit.pack_id = repair_pack
	s.kit.pack_active = true
	s.global_position = gen.global_position + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	_expect(base.find_repair_target(s) == gen, "the repair pack finds the damaged generator in reach")
	await _seconds(REPAIR_WAIT_SECONDS)
	_expect(gen.hp > hurt, "the repair pack repairs it (%.0f -> %.0f hp)" % [hurt, gen.hp])
	s.kit.pack_active = false
	s.team = 0


func _repair_pack_id(s: Infantry) -> String:
	for id in InfantryGear.packs_of(s.armor):
		if str(InfantryGear.pack(id).get("effect", "")) == "repair":
			return str(id)
	return ""


# ------------------------------------------------------------------ stations

func _station_of(stations: TribesStations, kind: String) -> int:
	for i in stations.stations.size():
		var st: Dictionary = stations.stations[i]
		if st.kind == kind and int(st.team) in [-1, 0] and TribesBase.is_working(st.get("object")):
			return i
	return -1


func _check_inventory(battle: Battle) -> void:
	var s := battle.player as Infantry
	var stations: TribesStations = battle.get_node("Stations")
	var inv := _station_of(stations, "inventory")
	_expect(inv >= 0, "a working team 0 inventory station")
	if inv < 0 or s == null:
		return
	s.global_position = (stations.stations[inv].xf as Transform3D).origin + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	await _frames(3)
	_close_menu(battle)
	await _frames(2)
	var offer := InfantryInteraction.of(battle).make_offer(s)
	_expect(str(offer.get("text", "")).contains("inventory"), "interact offers the inventory station: '%s'" % offer.get("text", ""))
	var armors := InfantryCatalog.armors_of(str(s.armor.pack))
	var heavy: Dictionary = armors[armors.size() - 1]
	var loadout: Array = (heavy.get("weapons", []) as Array).slice(0, 2)
	stations.apply_inventory(1, str(heavy.id), loadout)
	await _frames(2)
	_expect(s.armor_id == str(heavy.id) and s.make_loadout() == loadout, "buys %s with %s" % [heavy.id, loadout])
	var w := _ammo_weapon(s)
	if w:
		w.ammo = 0
	s.components[0].hp = float(s.components[0].max) * 0.25
	stations.apply_inventory(1, str(heavy.id), loadout)
	await _frames(2)
	var refilled := _ammo_weapon(s)
	_expect(refilled == null or refilled.ammo == refilled.ammo_max, "a purchase refills the ammunition")
	_expect(is_equal_approx(float(s.components[0].hp), float(s.components[0].max)), "and the health")
	_close_menu(battle)


func _ammo_weapon(s: Infantry) -> InfantryWeapon:
	for w in s.weapons:
		if (w as InfantryWeapon).ammo_max > 0:
			return w
	return null


func _close_menu(battle: Battle) -> void:
	var layer := battle.find_child("StationMenuLayer", false, false)
	if layer:
		(layer.get_child(0) as StationMenu).close()


func _check_vehicle_station(battle: Battle) -> void:
	var s := battle.player as Infantry
	var stations: TribesStations = battle.get_node("Stations")
	var veh := _station_of(stations, "vehicle")
	_expect(veh >= 0, "a working team 0 vehicle station")
	if veh < 0 or s == null:
		return
	var vehicles := stations.make_station_vehicles(s)
	_expect(not vehicles.is_empty(), "the station sells %d vehicles" % vehicles.size())
	if vehicles.is_empty():
		return
	s.global_position = (stations.stations[veh].xf as Transform3D).origin + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	await _frames(3)
	_close_menu(battle)
	_clear_pads(battle, stations)
	_expect(stations.find_station(s) == veh, "standing on the vehicle station (%d)" % stations.find_station(s))
	_expect(not stations.find_clear_pad((stations.stations[veh].xf as Transform3D).origin).is_empty(), "its pad is clear")
	var count := battle.vehicles.size()
	stations.apply_vehicle_purchase(1, str(vehicles[0].id), veh)
	await _frames(3)
	_expect(battle.vehicles.size() == count + 1, "the vehicle station spawns a %s" % vehicles[0].id)
	if battle.player != s:
		battle.occupancy.apply_enter_exit(1)
		await _frames(3)
	_close_menu(battle)


## Moves the vehicles parked on the pads (the player's own Herc starts on one) out of the way.
func _clear_pads(battle: Battle, stations: TribesStations) -> void:
	for pad in battle.spawner.pad_points:
		for h in battle.vehicles.values():
			if not (h is Infantry) and h.global_position.distance_to((pad as Transform3D).origin) < TribesStations.PAD_CLEAR_RADIUS:
				h.global_position += Vector3(0, 0, 3.0 * TribesStations.PAD_CLEAR_RADIUS)


## A free-for-all makes the base neutral (turrets fire at everyone; GameModes.is_free_for_all).
## Factions own base objects (raids): a turret in an owner's area takes its team, so the faction's soldiers are no targets.
func _check_owners(base: TribesBase) -> void:
	var o := base.objects[0]
	var before := o.team
	base.apply_owners([{"pos": o.global_position, "radius": 5.0, "team": 777}, {"pos": o.global_position + Vector3(900, 0, 0), "radius": 5.0, "team": 778}])
	_expect(o.team == 777, "a base object inside a faction's area belongs to that faction")
	var far := base.objects.filter(func(x: TribesBaseObject) -> bool: return x.global_position.distance_to(o.global_position) > 100.0)
	if not far.is_empty():
		var t: int = far[0].team
		base.apply_owners([{"pos": o.global_position, "radius": 5.0, "team": 777}])
		_expect(far[0].team == t, "one outside every area keeps its team")
	_expect(not TeamRelations.is_hostile(777, o.team), "its faction's soldiers are not its enemies")
	o.team = before


func _check_neutral(battle: Battle, base: TribesBase) -> void:
	var teams = battle.config.get("teams")
	battle.config["teams"] = false
	_expect(base.is_neutral_match(), "free-for-all: the base is neutral")
	battle.config["teams"] = teams
	_expect(not base.is_neutral_match(), "team match: the base belongs to the map's teams")
