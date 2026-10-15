class_name ExtractionSquads
extends RefCounted
## The AI factions' squads of a raid (host; docs/design/extraction.md section 3). Each loot area gets a faction
## (the available ones, shuffled, round the areas) and a squad: soldiers in the faction's armour (InfantryBots,
## guarding the area: InfantryBot guard_point / guard_radius) and AI vehicles from its games (AIPilot GUARD at the
## area). The match settings cap the totals: config "infantry_bots" soldiers and VEHICLES_KEY vehicles.
## Returns the teams in play ({team: faction id}) for the relations (ExtractionFactions.apply_relations).

const VEHICLES_KEY := "faction_vehicles"
const GUARD_RADIUS_FACTOR := 2.5
const VEHICLE_SPREAD := 2.0
const SIZES := ["LIGHT", "MEDIUM", "HEAVY"]

var battle: Battle
var rng: RandomNumberGenerator
## After spawn_all: faction id -> [area points] it guards (the pre-raid tasks find its base there).
var placed_areas := {}
var _soldiers_left := 0
var _vehicles_left := 0


static func make(p_battle: Battle, p_rng: RandomNumberGenerator) -> ExtractionSquads:
	var s := ExtractionSquads.new()
	s.battle = p_battle
	s.rng = p_rng
	s._soldiers_left = InfantryBots.make_count(p_battle.config)
	s._vehicles_left = maxi(int(p_battle.config.get(VEHICLES_KEY, 0)), 0)
	return s


## Spawns a squad at each of `areas`; returns {team: faction id} of the factions placed. The `required` factions
## (the players' pre-raid task targets) are placed first, the others shuffled after them; a faction of `claims`
## ({faction id: base site}, RaidTasks.make_site_claims) takes the area nearest its site.
func spawn_all(areas: Array[Vector3], required: Array = [], claims: Dictionary = {}) -> Dictionary:
	var factions := ExtractionFactions.make_available()
	var teams := {}
	if factions.is_empty():
		return teams
	_shuffle(factions)
	factions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return required.has(str(a.id)) and not required.has(str(b.id)))
	var order := _make_claimed_order(areas, factions, claims)
	for i in areas.size():
		var fi := int(order[i])
		var team := ExtractionFactions.make_team(fi)
		var fid := str(factions[fi].id)
		teams[team] = fid
		if not placed_areas.has(fid):
			placed_areas[fid] = []
		placed_areas[fid].append(areas[i])
		_spawn_squad(factions[fi], team, areas[i])
	return teams


## Faction index per area: claimed factions at the areas nearest their sites, the others round the rest in order.
static func _make_claimed_order(areas: Array[Vector3], factions: Array, claims: Dictionary) -> Array:
	var order := []
	order.resize(areas.size())
	order.fill(-1)
	for fi in factions.size():
		var site = claims.get(str(factions[fi].id))
		if site == null:
			continue
		var best := -1
		for i in areas.size():
			if order[i] < 0 and (best < 0 or areas[i].distance_to(site) < areas[best].distance_to(site)):
				best = i
		if best >= 0:
			order[best] = fi
	var next := 0
	for i in areas.size():
		if order[i] < 0:
			order[i] = next % factions.size()
			next += 1
	return order


func _shuffle(list: Array) -> void:
	for i in range(list.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = list[i]
		list[i] = list[j]
		list[j] = t


func _spawn_squad(faction: Dictionary, team: int, area: Vector3) -> void:
	var squad := ExtractionFactions.make_squad_rules(faction)
	var pack := ExtractionFactions.make_infantry_pack(faction)
	var radius := float(ExtractionRules.map_rules().get("area_radius_m", 28.0))
	if pack != "":
		var n := mini(ExtractionRules.roll_range(rng, squad.get("infantry", [0, 0])), _soldiers_left)
		for k in n:
			_spawn_soldier(faction, pack, team, area, k, squad)
	var pool := ExtractionFactions.make_vehicle_pool(faction)
	if not pool.is_empty():
		var n := mini(ExtractionRules.roll_range(rng, squad.get("vehicles", [0, 0])), _vehicles_left)
		for k in n:
			_spawn_vehicle(str(pool[rng.randi_range(0, pool.size() - 1)]), faction, team, area, radius, squad)


func _make_place(area: Vector3, spread: float) -> Transform3D:
	var a := rng.randf() * TAU
	var p := battle.infantry.make_on_ground(area + Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.3, 1.0) * spread)
	p = SpawnClearance.make(battle).make_clear_origin(p)
	return Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p)


func _spawn_soldier(faction: Dictionary, pack: String, team: int, area: Vector3, k: int, squad: Dictionary) -> InfantryBot:
	_soldiers_left -= 1
	var radius := float(ExtractionRules.map_rules().get("area_radius_m", 28.0))
	var id := battle.infantry.bots.allocate_bot_id()
	var spec := battle.infantry.make_soldier_spec(id, team, "%s soldier" % str(faction.name), _make_place(area, radius))
	var armor_id := "%s:%s" % [pack, _make_size(k, squad)]
	if not InfantryCatalog.armor(armor_id).is_empty():
		spec.armor = armor_id
		spec.vehicle = armor_id
		spec.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	spec["body_shape"] = ExtractionFactions.make_body_shape(faction, str(spec.armor))
	spec["bot"] = true
	spec["faction"] = str(faction.id)
	var brain := battle.infantry.bots.spawn_bot(spec, float(squad.get("skill", 0.45)))
	if brain:
		brain.guard_point = area
		brain.guard_radius = radius * GUARD_RADIUS_FACTOR
	return brain


## Every medium_every-th soldier medium, every heavy_every-th heavy, the rest light.
static func _make_size(k: int, squad: Dictionary) -> String:
	var heavy := int(squad.get("heavy_every", 0))
	var medium := int(squad.get("medium_every", 0))
	if heavy > 0 and k % heavy == heavy - 1:
		return SIZES[2]
	if medium > 0 and k % medium == medium - 1:
		return SIZES[1]
	return SIZES[0]


func _spawn_vehicle(vehicle_id: String, faction: Dictionary, team: int, area: Vector3, radius: float, squad: Dictionary) -> Herc:
	_vehicles_left -= 1
	var vdef := Packs.vehicle(vehicle_id)
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": vehicle_id, "team": team, "owner": 1,
		"xf": _make_place(area, radius * VEHICLE_SPREAD), "loadout": vdef.get("loadout", []),
		"name": "%s %s" % [str(faction.name), str(vdef.get("name", vehicle_id))],
		"ai": {"skill": float(squad.get("skill", 0.45))}, "protection": 0.0}
	battle.send_spawn(spec)
	var h: Herc = battle.vehicles.get(int(spec.net_id))
	if h == null:
		return null
	for c in h.get_children():
		if c is AIPilot:
			(c as AIPilot).order = AIPilot.Order.GUARD
			(c as AIPilot).guard_point = area
	return h


## A flag-theft response squad of faction `faction_id` (team `team`) at `at`: `soldiers` infantry bots and, when
## `with_vehicle`, one armed faction vehicle. Ignores the raid's bot caps. Returns {bots: [InfantryBot], vehicle: Herc}.
func spawn_response(faction_id: String, team: int, at: Vector3, soldiers: int, with_vehicle: bool) -> Dictionary:
	var out := {"bots": [], "vehicle": null}
	var faction := {}
	for f in ExtractionFactions.make_available():
		if str(f.id) == faction_id:
			faction = f
	if faction.is_empty():
		return out
	var squad := ExtractionFactions.make_squad_rules(faction)
	var pack := ExtractionFactions.make_infantry_pack(faction)
	if pack != "":
		for k in soldiers:
			var b := _spawn_soldier(faction, pack, team, at, k, squad)
			if b:
				out.bots.append(b)
	var pool := ExtractionFactions.make_vehicle_pool(faction)
	if with_vehicle and not pool.is_empty():
		out.vehicle = _spawn_vehicle(str(pool[rng.randi_range(0, pool.size() - 1)]), faction, team, at, 6.0, squad)
	return out
