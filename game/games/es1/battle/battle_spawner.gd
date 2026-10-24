class_name BattleSpawner
extends RefCounted
## Where vehicles start and how they are created: spawn points, the host's roster / AI spawning,
## and building a vehicle (player, AI Herc or flyer) from a spawn spec on every peer.
##
## Spawn spec (sent with Battle._spawn): {net_id, vehicle, team, owner, xf, loadout, name, ai, protection,
## cloak_s, mounts, garage} where `ai` holds the AI settings ({} for players), `protection` the spawn protection seconds,
## `cloak_s` the seconds a pad-launched vehicle is cloaked, `mounts` the fitted components (HercMounts), and `garage` (campaign Hercs only: Garage.make_battle_tag)
## the garage Herc it is - its condition is applied and the mission result reports it back (BattleSalvage).

const SPAWN_POINT_COUNT := 24
const RING_RADIUS := 120.0          # metres; skirmish / co-op ring round the centre
const RING_RADIUS_VS := 260.0       # metres; deathmatch ring
const TEAM_COLUMNS := 6             # team start lines: 6 Hercs per row
const TEAM_SPACING := 30.0          # metres between Hercs in a team line
const TEAM_LINE_DISTANCE := 320.0   # metres from the centre to a team's first row
const SPAWN_JITTER := 20.0          # metres; spread when a map has fewer Herc spawns than players
const FLYER_LEG := 200.0            # metres; default flyer patrol triangle
const AI_PATROL_LENGTH := 200.0     # metres; default AI patrol: start point and this far ahead
const FLYER_LOADOUT := ["es1:LAS100"]
## Map spawns (Tribes, Starsiege, arenas): a vehicle starts at the first free spawn, in the map's order,
## at least this far from every opposing vehicle already placed, else at the free spawn farthest from them.
const MIN_OPPONENT_SEPARATION := 150.0
## A spawn this close to an already placed vehicle is taken.
const SPAWN_TAKEN_RADIUS := 12.0
## Seconds an arena / versus vehicle can't be damaged after it (re)spawns, unless it fires first.
## Remake addition (the originals have none): small Tribes maps put the starts close together.
const SPAWN_PROTECTION_SECONDS := 3.0
const AI_NET_KEYS := ["group", "order", "leader", "formation_slot", "health", "flyer"]

var battle: Battle
var spawn_points: Array[Transform3D] = []
## The map's vehicle pads: where flying vehicles start (empty: they use spawn_points).
var pad_points: Array[Transform3D] = []
## The map's own starts per team ({team: [Transform3D]}, MapBuilder "team_spawns"): team matches start there.
var team_points := {}
var _next_id := 1


func _init(p_battle: Battle) -> void:
	battle = p_battle


# ------------------------------------------------------------------ spawn points

## A ring of points facing the centre, replaced by the map's own spawns when it has any.
func build_spawn_points(built: Dictionary) -> void:
	spawn_points = make_ring_points(RING_RADIUS_VS if battle.config.get("mode") == "vs" else RING_RADIUS)
	pad_points.assign(built.get("pad_spawns", []))
	team_points = built.get("team_spawns", {})
	if built.has("herc_spawns") and not built.herc_spawns.is_empty():
		spawn_points = make_padded_points(make_points_inside(built.herc_spawns, battle.bounds.bounds if battle.bounds else null))
	elif built.has("spawns"):
		spawn_points.clear()
		for t in built.spawns:   # start pads first (alternating sides), then the ring
			spawn_points.append(t)


## The points inside the playable area (all of them when none is, or there is no area): a start outside it
## would be warned and damaged at once (BattleBounds).
static func make_points_inside(points: Array, area: MapBounds) -> Array:
	if area == null:
		return points
	var inside := points.filter(func(t: Transform3D) -> bool: return not area.is_outside(t.origin))
	return inside if not inside.is_empty() else points


## True when the match is played in teams on the map's own team starts (versus with teams, or more than two).
func uses_map_team_starts() -> bool:
	var config := battle.config
	return config.has("map") and (bool(config.get("teams", false)) or int(config.get("team_count", 2)) > MapTeams.MIN_TEAMS)


## The points a vehicle of `team` starts at: its team's own starts in a team match, else everybody's.
func make_points_for_team(team: int) -> Array[Transform3D]:
	if uses_map_team_starts() and team_points.has(team):
		var own: Array[Transform3D] = []
		own.assign(team_points[team])
		return own
	return spawn_points


static func make_ring_points(radius: float) -> Array[Transform3D]:
	var points: Array[Transform3D] = []
	for i in SPAWN_POINT_COUNT:
		var ang := float(i) / SPAWN_POINT_COUNT * TAU
		var pos := Vector3(cos(ang), 0, sin(ang)) * radius
		points.append(Transform3D(Basis(Vector3.UP, atan2(pos.x, pos.z)), pos))   # face the centre (-z forward)
	return points


## The map's Herc spawns, repeated with a random offset until there are SPAWN_POINT_COUNT.
static func make_padded_points(spawns: Array) -> Array[Transform3D]:
	var points: Array[Transform3D] = []
	for t in spawns:
		points.append(t)
	while points.size() < SPAWN_POINT_COUNT:
		var jitter := Vector3(randf_range(-SPAWN_JITTER, SPAWN_JITTER), 0, randf_range(-SPAWN_JITTER, SPAWN_JITTER))
		points.append(spawns[points.size() % spawns.size()].translated(jitter))
	return points


## Start `k` of `team`'s line: the teams' lines stand round the centre (two teams: south and north), each
## facing it.
static func make_team_spawn(team: int, k: int, team_count := MapTeams.MIN_TEAMS) -> Transform3D:
	var ang := float(posmod(team, maxi(team_count, 1))) / maxi(team_count, 1) * TAU
	var back := Vector3(sin(ang), 0, cos(ang))
	var right := Vector3(cos(ang), 0, -sin(ang))
	var pos := right * ((k % TEAM_COLUMNS - 2.5) * TEAM_SPACING) + back * (TEAM_LINE_DISTANCE + TEAM_SPACING * (k / TEAM_COLUMNS))
	return Transform3D(Basis(Vector3.UP, ang), pos)


func _uses_team_spawns() -> bool:
	var config := battle.config
	if config.has("map") or config.has("arena"):
		return false   # maps/arenas provide their own spawn points
	return config.get("mode") != "vs" or config.get("teams", false)


## A respawn point away from the living vehicles (of other teams, in a team match on the map's team starts):
## a random one of the points at least MIN_OPPONENT_SEPARATION from all of them, else the farthest.
func make_respawn_point(team := -1) -> Transform3D:
	var points := make_points_for_team(team)
	var own_team_starts := uses_map_team_starts() and team_points.has(team)
	var living: Array[Vector3] = []
	for h in battle.vehicles.values():
		if is_instance_valid(h) and h.alive and not (own_team_starts and h.team == team):
			living.append(h.global_position)
	var safe := points.filter(func(t: Transform3D) -> bool:
		return make_nearest_distance(t.origin, living) >= MIN_OPPONENT_SEPARATION)
	if not safe.is_empty():
		return safe[randi() % safe.size()]
	return points[make_farthest_index(points, living)]


## The map spawn for a vehicle of `team`, given the vehicles already placed
## (placed: [{"pos": Vector3, "team": int}]); see MIN_OPPONENT_SEPARATION.
static func make_spawn_choice(points: Array[Transform3D], placed: Array, team: int) -> Transform3D:
	var taken: Array[Vector3] = []
	var opponents: Array[Vector3] = []
	for p in placed:
		taken.append(p.pos)
		if int(p.team) != team:
			opponents.append(p.pos)
	var free := points.filter(func(t: Transform3D) -> bool:
		return make_nearest_distance(t.origin, taken) >= SPAWN_TAKEN_RADIUS)
	if free.is_empty():
		free = points.duplicate()
	for t in free:
		if make_nearest_distance(t.origin, opponents) >= MIN_OPPONENT_SEPARATION:
			return t
	return free[make_farthest_index(free, opponents)]


## Distance from `p` to the nearest of `others` (INF when there are none).
static func make_nearest_distance(p: Vector3, others: Array[Vector3]) -> float:
	var best := INF
	for o in others:
		best = minf(best, p.distance_to(o))
	return best


## Index of the point farthest from its nearest of `others`.
static func make_farthest_index(points: Array, others: Array[Vector3]) -> int:
	var best := 0
	var best_d := -1.0
	for i in points.size():
		var d := make_nearest_distance((points[i] as Transform3D).origin, others)
		if d > best_d:
			best = i
			best_d = d
	return best


# ------------------------------------------------------------------ host spawning

func allocate_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


## Host: spawns every roster player, then the mission's units or the config's AI.
func spawn_roster() -> void:
	var placement := {"k": 0, "team_counts": {}, "placed": []}
	for peer in battle.config.roster:
		battle.send_spawn(_make_player_spec(int(peer), battle.config.roster[peer], placement))
	if battle.mission:
		battle.mission.spawn_units()
		return
	for a in battle.config.get("ai", []):
		if not BotBudget.admits(battle, BotBudget.Priority.MATCH):
			break   # the server's bot cap
		battle.send_spawn(_make_ai_spec(a, placement))


## Host of a running battle: spawns the soldier of `peer`, who joined late, from his roster `entry` (it is also kept in the
## battle's roster). He stands at a map start until a transport takes him in (ExtractionTransports.start_drop_in).
func spawn_player(peer: int, entry: Dictionary) -> void:
	battle.config.roster[peer] = entry
	battle.send_spawn(_make_player_spec(peer, entry, {"k": 0, "team_counts": {}, "placed": []}))


## Next start transform for a `vehicle_id` of `team`; advances the placement counters.
## Flying vehicles start on the map's vehicle pads when it has any.
func _place(team: int, vehicle_id: String, placement: Dictionary) -> Transform3D:
	var tk: int = placement.team_counts.get(team, 0)
	placement.team_counts[team] = tk + 1
	if _uses_team_spawns():
		return make_team_spawn(team, tk, int(battle.config.get("team_count", MapTeams.MIN_TEAMS)))
	var flying := bool(Packs.vehicle(vehicle_id).get("flyer", false))
	var points := pad_points if flying and not pad_points.is_empty() else make_points_for_team(team)
	var xf := make_spawn_choice(points, placement.placed, team)
	placement.placed.append({"pos": xf.origin, "team": team})
	return xf


## Spawn protection of a match start (none in missions: they keep the original placement rules).
func _make_protection_seconds() -> float:
	return 0.0 if battle.mission else SPAWN_PROTECTION_SECONDS


func _make_player_spec(peer: int, e: Dictionary, placement: Dictionary) -> Dictionary:
	var team := int(e.get("team", 0))
	var xf := _place(team, e.vehicle, placement)
	if battle.mission:
		xf = battle.mission.player_spawn(placement.k)
		team = 0
	placement.k += 1
	var loadout: Array = e.get("loadout", [])
	if loadout.is_empty():
		loadout = Packs.vehicle(e.vehicle).get("loadout", [])
	return {"net_id": allocate_id(), "vehicle": e.vehicle, "team": team, "owner": peer, "xf": xf,
		"loadout": loadout, "name": e.get("name", "Pilot"), "ai": {}, "protection": _make_protection_seconds(),
		"garage": e.get("garage", {}), "skin": str(e.get(PlayerProfile.HERC_SKIN_KEY, "")), "mounts": e.get("mounts", [])}


func _make_ai_spec(a: Dictionary, placement: Dictionary) -> Dictionary:
	var team := int(a.get("team", 1))
	var xf := _place(team, a.vehicle, placement)
	placement.k += 1
	var vdef := Packs.vehicle(a.vehicle)
	var spec := {"net_id": allocate_id(), "vehicle": a.vehicle, "team": team, "owner": 1, "xf": xf,
		"loadout": vdef.get("loadout", []), "name": a.get("name", vdef.get("name", "AI")),
		"ai": {"skill": a.get("skill", 0.5)}, "protection": _make_protection_seconds()}
	if a.get("flyer", false):
		spec.ai["flyer"] = true
		spec.ai["path"] = PackedVector3Array([xf.origin, xf.origin + Vector3(FLYER_LEG, 0, 0), xf.origin + Vector3(FLYER_LEG, 0, FLYER_LEG)])
		spec.loadout = FLYER_LOADOUT.duplicate()
		spec.name = "Skimmer"
	return spec


## Spawn spec for a mission AI unit (see Battle.spawn_ai):
## unit = {vehicle, team, xf, loadout, name, info} where info holds the AI settings.
func make_mission_ai_spec(unit: Dictionary) -> Dictionary:
	var vdef := Packs.vehicle(unit.vehicle)
	var info: Dictionary = unit.info
	var ai := {"skill": info.get("skill", 0.5)}
	for k in AI_NET_KEYS:
		if info.has(k):
			ai[k] = info[k]
	ai["path"] = PackedVector3Array(info.get("path", []))
	var loadout: Array = unit.loadout
	var pname: String = unit.name
	return {"net_id": allocate_id(), "vehicle": unit.vehicle, "team": unit.team, "owner": 1, "xf": unit.xf,
		"loadout": loadout if not loadout.is_empty() else vdef.get("loadout", []),
		"name": pname if pname != "" else vdef.get("name", "AI"), "ai": ai, "garage": info.get("garage", {})}


# ------------------------------------------------------------------ every peer

## Creates the vehicle of a spawn spec as a child of the battle and registers it.
func build_vehicle(spec: Dictionary) -> Herc:
	var ai: Dictionary = spec.ai
	var h: Herc = Flyer.new() if is_flyer(spec) else Herc.new()
	h.vehicle_id = spec.vehicle
	h.team = spec.team
	h.net_id = spec.net_id
	h.owner_peer = spec.owner
	h.display_name = spec.name
	h.skin = str(spec.get("skin", ""))
	h.palette_id = battle.palette_id
	h.is_puppet = not battle.multiplayer.is_server()
	h.name = "V%d" % spec.net_id
	h.transform = spec.xf
	if ai.has("skill"):
		h.set_meta("ai", true)
	if battle.config.get("balance", "balanced") == "balanced":
		h.set_meta("balanced", true)
	battle.add_child(h)
	h.spawn_protection = float(spec.get("protection", 0.0))
	h.apply_spawn_protection()
	h.add_to_group("team_%d" % spec.team)
	h.equip(spec.loadout)
	apply_pad_cloak(h, float(spec.get("cloak_s", 0.0)))
	apply_mounts(h, spec)
	_apply_garage(h, spec.get("garage", {}))
	battle.vehicles[spec.net_id] = h
	battle.entities.register(spec.net_id, h)
	if h is Flyer and not ai.has("skill"):
		(h as Flyer).apply_player_start()
	return h


## A vehicle leaving a Tribes 2 pad is cloaked for `seconds` by the scripts' timed cloak (serverVehicleHud.cs).
static func apply_pad_cloak(h: Herc, seconds: float) -> void:
	if seconds <= 0.0:
		return
	if not h.cloak.is_equipped():
		h.cloak.apply_profile(CloakProfile.of(CloakProfile.make_timed_id(h)))
	h.cloak.apply_forced(seconds)


## A Starsiege Herc with component slots carries the cloak its pilot fitted (the spec's "mounts", else the garage
## Herc's); a Herc without slots, or with the factory fit everywhere, keeps the cloak of its catalog entry.
static func apply_mounts(h: Herc, spec: Dictionary) -> void:
	var mounts: Array = spec.get("mounts", [])
	if mounts.is_empty():
		mounts = (spec.get("garage", {}) as Dictionary).get("mounts", [])
	if mounts.is_empty() or not HercMounts.has_slots(h.def):
		return
	h.cloak.apply_profile(HercMounts.make_cloak(h.def, HercMounts.make_sanitized(h.def, mounts)))


## A campaign garage Herc starts in the condition it came back in; it remembers which Herc it is.
static func _apply_garage(h: Herc, tag: Dictionary) -> void:
	if tag.is_empty():
		return
	h.set_meta("garage", tag)
	HercCondition.apply_to_herc(h, tag.get("condition", []))


## Flyers: AI units marked as flyers and every vehicle the catalog marks as flying.
static func is_flyer(spec: Dictionary) -> bool:
	return bool(spec.ai.get("flyer", false)) or bool(Packs.vehicle(spec.vehicle).get("flyer", false))


func is_local_player(h: Herc, spec: Dictionary) -> bool:
	return spec.owner == battle.multiplayer.get_unique_id() and not spec.ai.has("skill")


## Host: gives an AI vehicle its brain (FlyerAI patrol or AIPilot).
func attach_ai(h: Herc, spec: Dictionary) -> void:
	if not spec.ai.has("skill"):
		return   # a remote player's vehicle: driven by that player's input
	if h is Flyer:
		_attach_flyer(h as Flyer, spec.ai)
	else:
		h.add_child(_make_ai_pilot(h, spec))


func _attach_flyer(fl: Flyer, ai: Dictionary) -> void:
	fl.start_ai()
	fl.set_meta("group", int(ai.get("group", -1)))
	for v in ai.get("path", PackedVector3Array()):
		fl.patrol.append(v + Vector3.UP * fl.altitude)
	fl.global_position += Vector3.UP * fl.altitude


func _make_ai_pilot(h: Herc, spec: Dictionary) -> AIPilot:
	var ai: Dictionary = spec.ai
	var p := AIPilot.new()
	p.herc = h
	p.skill = float(ai.skill)
	if not ai.has("group"):
		var xf: Transform3D = spec.xf
		p.patrol_points = [xf.origin, xf.origin - xf.basis.z * AI_PATROL_LENGTH]
		return p
	h.set_meta("group", int(ai.group))
	p.order = AIPilot.order_from_original(int(ai.get("order", 8)))
	for v in ai.get("path", PackedVector3Array()):
		p.patrol_points.append(v)
	p.loop_path = p.order == AIPilot.Order.PATROL
	var lead: Herc = battle.vehicles.get(int(ai.get("leader", 0)))
	if lead and lead != h:
		p.leader = lead
		p.formation_offset = battle.mission.formation_offset_local(int(ai.get("formation_slot", 0))) if battle.mission else Vector3.ZERO
	if int(ai.get("health", 100)) < 100:
		h.apply_start_health(int(ai.health))
	return p
