class_name BattleInfantry
extends RefCounted
## The battle's soldiers (Tribes armour, engine/infantry) and where players start (docs/formats/tribes_infantry.md
## section 5, mode defaults):
##   config "start" = "on_foot" (arena, versus, skirmish and co-op from the front end, MatchFlow): every player
##     starts on foot in LIGHT armour next to the vehicle chosen in the lobby, which stands parked and empty at
##     the player's spawn; soldiers respawn (Tribes always respawns its players), destroyed vehicles follow the
##     mode's rule (BattleRules).
##   missions (ES1 / ES2 / Starsiege campaigns) and "start" = "vehicle" (the default of the test / command-line
##     config): the player starts inside the vehicle, as in the originals; leaving it makes the soldier then.
## The host rewrites each player's spawn spec (rewrite_player_spawn); every peer builds soldiers from their spec
## (build_soldier), as BattleSpawner builds vehicles.
## Soldier spec: the vehicle spec keys plus "armor" (armour id); a parked vehicle's spec has "parked": true; a
## vehicle a player starts in has "pilot_peer"; a bot's soldier has "bot": true and a bot id as "owner".
## It also adds the battle's hand-item and backpack director (InfantryGearDirector, child "Gear") and the
## infantry bots (InfantryBots, child "InfantryBots": config "infantry_bots") and the interact action
## (InfantryInteraction, child "Interaction").

const START_ON_FOOT := "on_foot"
const START_IN_VEHICLE := "vehicle"
## Gap between a parked vehicle's hull and the soldier who starts next to it (metres): within the hatch reach,
## so the first press of vehicle_enter_exit boards it.
const START_GAP := 1.5
## Soldiers stand this far above the ground when placed (they settle onto it).
const GROUND_CLEARANCE := 0.3
## Seconds before a soldier killed in a mode without respawning vehicles comes back (BattleRules.RESPAWN_TIME).
const RESPAWN_TIME := BattleRules.RESPAWN_TIME

var battle: Battle
## Pack whose armours the soldiers wear ("" = no infantry installed).
var pack := ""
var gear: InfantryGearDirector
var bots: InfantryBots
## The soldiers' interact action (pickups, loot, switches, boarding).
var interaction: InfantryInteraction
var _respawn_queue := []      # [net_id, seconds left]


func _init(p_battle: Battle) -> void:
	battle = p_battle
	pack = make_infantry_pack(battle.config)
	gear = InfantryGearDirector.new(battle)
	battle.add_child(gear)
	bots = InfantryBots.new(battle)
	battle.add_child(bots)
	interaction = InfantryInteraction.new(battle)
	battle.add_child(interaction)
	interaction.add_provider(battle.occupancy.make_boarding_offer)


## Host, after the roster: the match's infantry bots (InfantryBots; none in missions or without infantry; the
## extraction mode fields its own faction squads, ExtractionSquads).
func spawn_bots() -> void:
	if pack != "" and not str(battle.config.get("mode", "")) in ["mission", ExtractionRules.MODE] and battle.mission == null:
		bots.spawn_all(pack)
		if InfantryBots.make_count(battle.config) > 0:
			BattleNavigation.of(battle).apply_prebake(make_base_points())


## Where the bases are (the stations): their walkable paths are baked first (BattleNavigation).
func make_base_points() -> Array:
	var stations := battle.get_node_or_null("Stations")
	var list: Array = stations.get("stations") if stations and stations.get("stations") is Array else []
	return list.map(func(st) -> Vector3: return (st.xf as Transform3D).origin)


## Whether players start on foot: config "start" = "on_foot", not a mission, and an infantry pack installed.
static func wants_start_on_foot(config: Dictionary) -> bool:
	return str(config.get("start", START_IN_VEHICLE)) == START_ON_FOOT and str(config.get("mode", "")) != "mission" \
		and make_infantry_pack(config) != ""


## Armour pack: the map's own pack when it is a Tribes game's, else Tribes 2 for a Tribes 2 vehicle, else the
## first installed (Tribes 1). config "infantry_pack" overrides.
static func make_infantry_pack(config: Dictionary) -> String:
	var wanted := str(config.get("infantry_pack", ""))
	if wanted == "":
		var map_pack := str(config.get("map", "")).get_slice(":", 0) if str(config.get("map", "")).contains(":") else ""
		wanted = map_pack if map_pack in InfantryCatalog.INFANTRY_PACKS else ""
	if wanted != "" and InfantryCatalog.is_pack_usable(wanted):
		return wanted
	return InfantryCatalog.make_default_pack()


# ------------------------------------------------------------------ host: spawn specs

## The specs to send for one spawn spec: a player's vehicle becomes a parked vehicle plus the player's soldier
## (start on foot), or keeps its pilot (start inside); a player whose "vehicle" is an armour (Tribes training
## missions) is a soldier in that armour; other specs pass unchanged.
func rewrite_player_spawn(spec: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = [spec]
	if not is_player_vehicle_spec(spec):
		return out
	if not InfantryCatalog.armor(str(spec.vehicle)).is_empty():
		return [make_armored_spec(spec)]
	if not wants_start_on_foot(battle.config):
		spec["pilot_peer"] = int(spec.owner)
		return out
	var soldier := make_soldier_spec(int(spec.owner), int(spec.team), str(spec.name), spec.xf)
	soldier["protection"] = spec.get("protection", 0.0)
	soldier["beside"] = int(spec.net_id)
	spec["parked"] = true
	spec["owner"] = VehicleOccupancy.EMPTY
	spec["name"] = str(Packs.vehicle(str(spec.vehicle)).get("name", spec.vehicle))
	out.append(soldier)
	return out


static func is_player_vehicle_spec(spec: Dictionary) -> bool:
	return not spec.has("armor") and not spec.has("parked") and (spec.get("ai", {}) as Dictionary).is_empty() \
		and int(spec.get("owner", 0)) > 0


## A soldier spec for `peer` with the spawn loadout: in the armour, body and skin his roster entry chose
## ("infantry_armor", "infantry_body", "infantry_skin"; InfantryCatalog.make_armors / make_bodies / make_skins),
## else in light armour.
func make_soldier_spec(peer: int, team: int, pname: String, xf: Transform3D) -> Dictionary:
	var entry: Dictionary = battle.config.get("roster", {}).get(peer, {})
	var armor_id := make_chosen_armor(entry)
	var body := str(entry.get("infantry_body", ""))
	return {"net_id": battle.spawner.allocate_id(), "vehicle": armor_id, "armor": armor_id, "team": team,
		"owner": peer, "xf": xf, "loadout": InfantryCatalog.armor(armor_id).get("default_loadout", []),
		"name": pname, "ai": {}, "protection": 0.0, "spawn_armor": armor_id,
		"body_shape": body if InfantryCatalog.has_body(armor_id, body) else "",
		"skin": str(entry.get("infantry_skin", ""))}


## The roster entry's armour when it is one of this battle's pack, else the pack's light armour.
func make_chosen_armor(entry: Dictionary) -> String:
	var chosen := str(entry.get("infantry_armor", ""))
	var a := InfantryCatalog.armor(chosen)
	return chosen if not a.is_empty() and str(a.get("pack", "")) == pack else InfantryCatalog.light_armor_id(pack)


## The soldier spec of a player spec whose vehicle is armour `spec.vehicle`: the same net id, place and team.
func make_armored_spec(spec: Dictionary) -> Dictionary:
	var armor_id := str(spec.vehicle)
	var soldier := make_soldier_spec(int(spec.owner), int(spec.team), str(spec.name), spec.xf)
	soldier.net_id = int(spec.net_id)
	soldier.vehicle = armor_id
	soldier.armor = armor_id
	soldier.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	soldier.protection = spec.get("protection", 0.0)
	return soldier


## Host, before sending: a soldier spec with "beside" (the net id of his parked vehicle, already built) starts
## on that vehicle's right, facing the same way, on the ground.
func apply_start_place(spec: Dictionary) -> void:
	var vehicle: Herc = battle.vehicles.get(int(spec.get("beside", -1)))
	if vehicle == null:
		return
	var xf := vehicle.global_transform.orthonormalized()
	var p := xf.origin + xf.basis.x * (BoardingRules.make_hull_radius(vehicle) + START_GAP)
	spec.xf = Transform3D(xf.basis, make_on_ground(p))


## `p` lifted onto the terrain (soldiers fall onto floors above it by themselves). Over a terrain hole (the entrance
## of an underground base) onto the hole's rim height: the soldier drops into the base instead of starting below it
## with nothing under him.
func make_on_ground(p: Vector3) -> Vector3:
	var ground := MapBuilder.ground_height(battle, Vector3(p.x, -INF, p.z))
	if ground == -INF:
		var rim := MapTerrain.make_surface_height(battle, p)
		ground = rim if rim < INF else p.y
	return Vector3(p.x, maxf(p.y, ground) + GROUND_CLEARANCE, p.z)


# ------------------------------------------------------------------ every peer: building soldiers

## Builds the soldier of a spawn spec as a child of the battle and registers it (BattleSpawner.build_vehicle
## for soldiers).
func build_soldier(spec: Dictionary) -> Infantry:
	var s := Infantry.new()
	s.armor_id = str(spec.armor)
	s.team = int(spec.team)
	s.net_id = int(spec.net_id)
	s.owner_peer = int(spec.owner)
	s.display_name = str(spec.name)
	s.body_shape = str(spec.get("body_shape", ""))
	s.skin_id = str(spec.get("skin", ""))
	s.spawn_armor_id = str(spec.get("spawn_armor", ""))
	s.palette_id = battle.palette_id
	if spec.get("bot", false):
		s.set_meta("bot_id", int(spec.owner))
	s.is_puppet = not battle.multiplayer.is_server()
	s.name = "S%d" % s.net_id
	s.transform = spec.xf
	s.torso_target = s.rotation.y
	battle.add_child(s)
	s.spawn_protection = float(spec.get("protection", 0.0))
	s.apply_spawn_protection()
	s.add_to_group("team_%d" % s.team)
	s.kit.apply_spawn(s.armor)
	s.equip(spec.get("loadout", []))
	battle.vehicles[s.net_id] = s
	return s


## A parked vehicle stands still on the ground: jets land instead of starting at cruise height.
static func apply_parked(h: Herc) -> void:
	h.throttle = 0.0
	if h is Flyer:
		(h as Flyer).apply_landed_start()


# ------------------------------------------------------------------ host: respawning soldiers

## Host: a soldier died. In modes whose vehicles respawn BattleRules brings it back; otherwise it comes back
## here after RESPAWN_TIME (Tribes always respawns its players).
func on_soldier_destroyed(s: Infantry) -> void:
	if battle.mission or BattleRules.uses_frag_limit(battle.config) or BattleRules.is_decided_by_mode(battle.config):
		return
	_respawn_queue.append([s.net_id, RESPAWN_TIME])


func update(delta: float) -> void:
	for r in _respawn_queue.duplicate():
		r[1] -= delta
		if r[1] > 0.0:
			continue
		_respawn_queue.erase(r)
		var s: Herc = battle.vehicles.get(r[0])
		if s and not battle.is_over():
			s.respawn(battle.spawner.make_respawn_point(s.team))
