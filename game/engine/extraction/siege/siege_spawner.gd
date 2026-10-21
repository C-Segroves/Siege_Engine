class_name SiegeSpawner
extends RefCounted
## Brings the Cybrids in (host): a wave appears at a gate on the map's edge, away from the last one. It fields
##   infantry   the Tribes soldier bodies with the Cybrid look (CybridLook), bots of the Cybrid team that hunt everyone
##   hercs      Cybrid Hercs of Earthsiege 1 and 2 and Starsiege (heavier ones from the later waves); where no such
##              pack is installed, Hercs of any game wear the Cybrid look instead
##   flyers     Cybrid flyers where an installed pack has an armed one
## The bot cap (BotBudget) applies at the MATCH priority, above the garrisons': when it refuses, the garrisons farthest
## from every player make room (SiteSpawner.apply_retire_farthest). Every unit is pinned awake (meta keep_awake): the
## bot LOD director lets it walk to its prey from the map edge; far ones are drawn as proxies like all bots.

const META_UNIT := "siege_unit"
const SKILL_FALLBACK := 0.5
## Spots tried around a gate for one with level enough ground; the steepest ground a unit may be set down on (rise per metre).
const PLACE_TRIES := 12
const STANDABLE_REACH_M := 2.0
const STANDABLE_RISE := 0.8

var director: ExtractionDirector
var battle: Battle
var rng := RandomNumberGenerator.new()
var team := -1
## [{unit: Herc, kind: "infantry" | "hercs" | "flyers"}]
var units: Array = []
var last_gate := Vector3.INF
var gates_used := 0


func _init(p_director: ExtractionDirector, p_team: int, p_seed: int) -> void:
	director = p_director
	battle = p_director.battle
	team = p_team
	rng.seed = p_seed


# ------------------------------------------------------------------ pools

## The pack whose soldiers the Cybrids use ("" none).
static func make_infantry_pack() -> String:
	for pack in CybridRules.data().get("infantry_packs", []):
		if InfantryCatalog.light_armor_id(str(pack)) != "" and Packs.is_enabled(str(pack), "infantry"):
			return str(pack)
	return ""


## The Hercs a wave `n` may field, lightest first: the Cybrids' own, else the fallback weights of any pack.
static func make_herc_pool(n: int) -> Array:
	var pool := _make_cybrid_hercs(false)
	if pool.is_empty():
		pool = _make_fallback_hercs()
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("mass", 0.0)) < float(b.get("mass", 0.0)))
	var heavy_from := int(CybridRules.section("waves").get("hercs", {}).get("heavy_from_wave", 6))
	var share := 1.0 if n >= heavy_from else 0.5
	return pool.slice(0, maxi(ceili(pool.size() * share), 1)).map(func(v: Dictionary) -> String: return str(v.id))


static func make_flyer_pool() -> Array:
	return _make_cybrid_hercs(true).filter(func(v: Dictionary) -> bool: return not (v.get("loadout", []) as Array).is_empty()) \
		.map(func(v: Dictionary) -> String: return str(v.id))


## Cybrid vehicles of the rules' packs that walk (`flying` false) or fly.
static func _make_cybrid_hercs(flying: bool) -> Array:
	var packs: Array = CybridRules.data().get("herc_packs", [])
	var transports: Array = ExtractionRules.transport().get("ids", [])
	var out := []
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if str(v.get("side", "")) != ExtractionFactions.KIND_CYBRID or str(v.get("category", "herc")) != "herc" or not packs.has(str(v.pack)):
			continue
		if bool(v.get("flyer", false)) != flying or transports.has(str(id)) or not Packs.is_enabled(str(v.pack), "cybrids"):
			continue
		if flying or bool(v.get("pilotable", false)):
			out.append(v)
	return out


## No Cybrid pack: pilotable ground Hercs of the rules' fallback weights from any installed game.
static func _make_fallback_hercs() -> Array:
	var weights: Array = CybridRules.data().get("fallback_weights", ["heavy"])
	return Packs.pilotable([], "herc").filter(func(v: Dictionary) -> bool:
		return weights.has(str(v.get("weight", ""))) and not bool(v.get("flyer", false)) and str(v.get("category", "herc")) == "herc")


# ------------------------------------------------------------------ gates

## A point on the edge of the map, away from the last gate (the farthest of gate_tries dry candidates).
func make_gate() -> Vector3:
	var map := director.map
	var w := CybridRules.section("waves")
	var half := (map.bounds_max - map.bounds_min) * 0.5 - Vector2.ONE * float(w.get("gate_inset_m", 90.0))
	var best := Vector3.INF
	var best_score := -INF
	for i in int(w.get("gate_tries", 14)):
		var a := rng.randf() * TAU
		var dir := Vector2(cos(a), sin(a))
		var scale := minf(half.x / maxf(absf(dir.x), 0.001), half.y / maxf(absf(dir.y), 0.001))
		var p := map.make_ground(map.make_center() + dir * scale)
		if MapWater.is_in_water(battle.get_tree(), p):
			continue
		var score := p.distance_to(last_gate) if last_gate != Vector3.INF else rng.randf()
		if score > best_score:
			best_score = score
			best = p
	if best == Vector3.INF:
		best = map.make_ground(map.make_center())
	last_gate = best
	gates_used += 1
	return best


# ------------------------------------------------------------------ spawning

## Brings wave `n` in at a new gate, as many units as fit under max_units (the flyers and Hercs first, the infantry
## fills the rest); returns how many came.
func spawn_wave(n: int) -> int:
	var gate := make_gate()
	var comp := SiegeWaves.make_composition(n)
	var room := maxi(int(CybridRules.section("waves").get("max_units", 64)) - count_alive(), 0)
	var made := 0
	var flyers := make_flyer_pool()
	for i in mini(int(comp.flyers), room):
		if not flyers.is_empty() and _spawn_flyer(str(flyers[rng.randi_range(0, flyers.size() - 1)]), gate) != null:
			made += 1
	var pool := make_herc_pool(n)
	for i in mini(int(comp.hercs), maxi(room - made, 0)):
		if not pool.is_empty() and _spawn_herc(str(pool[rng.randi_range(0, pool.size() - 1)]), gate) != null:
			made += 1
	return made + _spawn_infantry(mini(int(comp.infantry), maxi(room - made, 0)), gate)


func count_alive(kind := "") -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u.unit) and (u.unit as Herc).alive and (kind == "" or str(u.kind) == kind):
			n += 1
	return n


func _make_place(gate: Vector3) -> Transform3D:
	var spread := float(CybridRules.section("waves").get("gate_spread_m", 40.0))
	var p := Vector3.ZERO
	for attempt in PLACE_TRIES:
		var a := rng.randf() * TAU
		p = battle.infantry.make_on_ground(gate + Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.2, 1.0) * spread)
		if is_standable(p):
			break
	p = SpawnClearance.make(battle).make_clear_origin(p)
	var toward := director.map.make_center() - Vector2(p.x, p.z)
	return Transform3D(Basis(Vector3.UP, atan2(-toward.x, -toward.y)), p)


## True when the ground around `p` is not a cliff: a soldier set down on a face steeper than STANDABLE_RISE slips into the
## heightfield and falls out of the world (the gates lie on the map's edge, where the mountains are).
func is_standable(p: Vector3) -> bool:
	for offset in [Vector3(STANDABLE_REACH_M, 0, 0), Vector3(-STANDABLE_REACH_M, 0, 0), Vector3(0, 0, STANDABLE_REACH_M), Vector3(0, 0, -STANDABLE_REACH_M)]:
		var rise := absf(MapBuilder.ground_height(battle, p + offset) - MapBuilder.ground_height(battle, p))
		if rise > STANDABLE_REACH_M * STANDABLE_RISE:
			return false
	return true


## Room for one more unit under the bot cap (the garrisons give way); false when there is none.
func _make_room() -> bool:
	if BotBudget.admits(battle, BotBudget.Priority.MATCH):
		return true
	if director.site_spawner != null:
		director.site_spawner.apply_retire_farthest(int(CybridRules.section("waves").get("retire_garrison_batch", 4)))
	return BotBudget.admits(battle, BotBudget.Priority.MATCH)


func _spawn_infantry(count: int, gate: Vector3) -> int:
	var pack := make_infantry_pack()
	if pack == "":
		return 0
	var kind := CybridRules.section("waves").get("infantry", {}) as Dictionary
	var made := 0
	for k in count:
		if not _make_room():
			break
		var brain := _spawn_trooper(pack, SiegeWaves.make_size(k, kind), gate, float(kind.get("skill", SKILL_FALLBACK)))
		if brain != null:
			made += 1
	return made


func _spawn_trooper(pack: String, size: String, gate: Vector3, skill: float) -> InfantryBot:
	var armor_id := "%s:%s" % [pack, size]
	if InfantryCatalog.armor(armor_id).is_empty():
		armor_id = InfantryCatalog.light_armor_id(pack)
	var spec := battle.infantry.make_soldier_spec(battle.infantry.bots.allocate_bot_id(), team, "Cybrid trooper", _make_place(gate))
	spec.armor = armor_id
	spec.vehicle = armor_id
	spec.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	spec["body_shape"] = ""
	spec["bot"] = true
	var brain := battle.infantry.bots.spawn_bot(spec, skill)
	if brain != null:
		brain.guard_radius = 0.0
		_note(brain.soldier, "infantry", brain)
	return brain


func _spawn_herc(vehicle_id: String, gate: Vector3) -> Herc:
	if not _make_room():
		return null
	var skill := float(CybridRules.section("waves").get("hercs", {}).get("skill", SKILL_FALLBACK))
	var h := _send_vehicle(vehicle_id, _make_place(gate), {"skill": skill})
	if h != null:
		_note(h, "hercs", _find_pilot(h))
	return h


func _spawn_flyer(vehicle_id: String, gate: Vector3) -> Herc:
	if not _make_room():
		return null
	var kind := CybridRules.section("waves").get("flyers", {}) as Dictionary
	var path := PackedVector3Array()
	for p in make_targets():
		path.append(p)
	var fl := _send_vehicle(vehicle_id, _make_place(gate), {"skill": float(kind.get("skill", SKILL_FALLBACK)), "flyer": true, "path": path})
	if fl is Flyer:
		(fl as Flyer).altitude = float(kind.get("altitude_m", 90.0))
		_note(fl, "flyers", null)
	return fl


func _send_vehicle(vehicle_id: String, xf: Transform3D, ai: Dictionary) -> Herc:
	var vdef := Packs.vehicle(vehicle_id)
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": vehicle_id, "team": team, "owner": 1, "xf": xf,
		"loadout": vdef.get("loadout", []), "name": "Cybrid %s" % str(vdef.get("name", vehicle_id)), "ai": ai, "protection": 0.0}
	battle.send_spawn(spec)
	return battle.vehicles.get(int(spec.net_id)) as Herc


static func _find_pilot(h: Herc) -> AIPilot:
	for c in h.get_children():
		if c is AIPilot:
			return c as AIPilot
	return null


func _note(h: Herc, kind: String, brain: Object) -> void:
	h.set_meta("keep_awake", true)
	h.set_meta(META_UNIT, true)
	director.watch(h)
	units.append({"unit": h, "kind": kind, "brain": brain})


## The places the Cybrids march on: every faction site, then the players on foot.
func make_targets() -> Array:
	var out := []
	if director.site_spawner != null:
		for s in director.site_spawner.sites:
			out.append(s.pos)
	for peer in director.make_raid_peers():
		var soldier := director.battle.occupancy.soldier_of(int(peer))
		if soldier != null and soldier.alive and not soldier.stowed:
			out.append(soldier.global_position)
	return out
