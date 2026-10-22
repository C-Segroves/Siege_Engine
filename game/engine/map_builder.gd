class_name MapBuilder
extends RefCounted
## Builds a playable map from the engine map schema (docs/formats/map_schema.md):
## environment (MapEnvironment), heightfield terrain (MapTerrain), buildings ("interiors"), props,
## stations and spawn points. Maps come from any pack: gamedata/<pack>/maps/<id>/map.json.

## Spawns further than this from the terrain (without explicit fields) are inside a base.
const INDOOR_SPAWN_GAP := 3.0
## Explicit "above_terrain" beyond this keeps the spawn's own height.
const RAISED_SPAWN_HEIGHT := 2.0
const SPAWN_LIFT := 0.5
## A start over a terrain hole with a building's floor within this far below it stands on that floor (a deck over the hole).
const HOLE_FLOOR_REACH := 12.0
## A start with no ground under it (over a hole, or beside the heightfield) moves to the nearest solid ground within this far.
const OFF_TERRAIN_REACH := 600.0
## Herc spawns closer than this are duplicates; infantry fallbacks use the wider spacing.
const SPAWN_MERGE_DISTANCE := 3.0
## Group of the map's buildings (the "interiors" list): surfaces a Tribes deployable may be placed on.
const INTERIOR_GROUP := "map_interiors"
const FALLBACK_SPAWN_MERGE_DISTANCE := 8.0


## All maps from all installed packs: [{"id": "pack:map", "pack", "name", "modes", "spawns"}]
static func list_maps() -> Array:
	var out := []
	for p in Assets.installed_packs():
		if not Packs.is_enabled(p, "arenas"):
			continue
		var idx = Assets.load_json("maps/_index.json", p)
		if idx is Array:
			for m in idx:
				var e: Dictionary = m.duplicate()
				e["pack"] = p
				e["id"] = "%s:%s" % [p, m.id]
				out.append(e)
	if VarunaMap.is_available() and Packs.is_enabled(VarunaMap.PACK, "arenas"):
		var v := VarunaMap.make_index_row()
		v["pack"] = VarunaMap.PACK
		v["id"] = VarunaMap.MAP_ID
		out.append(v)
	return out


static func load_map(map_id: String) -> Dictionary:
	if VarunaMap.is_varuna(map_id):
		return VarunaMap.make_map()   # generated at load time (Tribes 2 pack only)
	var sp := Assets.split_id(map_id)
	var j = Assets.load_json("maps/%s/map.json" % sp[1], sp[0])
	if j is Dictionary:
		j["_pack"] = sp[0]
		j["_dir"] = Assets.path("maps/%s" % sp[1], sp[0])
		return j
	return {}


## Returns {"palette", "herc_spawns": [Transform3D], "pad_spawns": [Transform3D] (vehicle pads, for
## flying vehicles), "infantry_spawns": [...], "stations": [{kind, team, xf, node (placed shape or null),
## record (the map.json entry)}], "map": dict}
static func build(parent: Node3D, map_id: String) -> Dictionary:
	var m := load_map(map_id)
	if m.is_empty():
		push_error("map not found: " + map_id)
		return {}
	var pack: String = m._pack
	var pal := Packs.default_palette(pack)
	ShapeInstance.world_palettes.clear()
	if m.get("world_palette") is String:
		ShapeInstance.world_palettes[pack] = m.world_palette
	var world_info := {}
	if m.get("world") is Dictionary:
		var world := _build_es_world(parent, m.world)
		pal = str(world.get("palette", pal))
		world_info = world.get("world", {})
	else:
		_build_ground(parent, m)
	for list_key in ["interiors", "statics"]:
		for o in m.get(list_key, []):
			LoadKeepAlive.pump()
			var placed := _place(parent, o, pal, bool(o.get("collide", true)))
			if placed and list_key == "interiors":
				placed.add_to_group(INTERIOR_GROUP)
	TerrainHoleSeal.apply(parent, INTERIOR_GROUP)   # hole parts no base lies under
	var stations := _build_stations(parent, m, pal)
	var spawns := _make_spawns(parent, m)
	return {"palette": pal, "herc_spawns": spawns.herc, "pad_spawns": spawns.pad, "infantry_spawns": spawns.infantry,
		"team_spawns": _make_team_spawns(parent, m), "stations": stations, "map": m, "world_info": world_info}


static func _build_ground(parent: Node3D, m: Dictionary) -> void:
	MapEnvironment.build(parent, m.get("environment", {}), m._dir)
	MapWater.build(parent, m.get("environment", {}))
	var lights := MapLights.make(m.get("point_lights", []))
	if lights:
		parent.add_child(lights)
	if m.get("terrain") is Dictionary:
		MapTerrain.build(parent, m.terrain, m._dir)
	else:
		_build_flat_ground(parent, float(m.get("ground_y", 0.0)))


## An Earthsiege 1 / 2 arena map (tools/export_es_arenas.py): the original world and zone, built by WorldBuilder;
## the map file adds the generated spawns and the bounds.
static func _build_es_world(parent: Node3D, world: Dictionary) -> Dictionary:
	return WorldBuilder.build(parent, int(world.get("index", 0)), int(world.get("zone", -1)), str(world.get("pack", "es1")))


static func _build_flat_ground(parent: Node3D, height := 0.0) -> void:
	var ground := StaticBody3D.new()
	ground.position.y = height
	var col := CollisionShape3D.new()
	col.shape = WorldBoundaryShape3D.new()
	ground.add_child(col)
	parent.add_child(ground)


static func _build_stations(parent: Node3D, m: Dictionary, pal: String) -> Array:
	var stations := []
	for s in m.get("stations", []):
		LoadKeepAlive.pump()
		var body: Node3D = null
		if s.get("shape") != null and String(s.shape) != "":
			body = _place(parent, s, pal, true)
		stations.append({"kind": s.get("kind", ""), "team": int(s.get("team", 0)), "xf": _xf(s), "node": body, "record": s})
	return stations


## {herc: [Transform3D], pad: [Transform3D], infantry: [Transform3D]}.
## Vehicle pads (Tribes) are kept apart for flying vehicles: their decks have rims a walking or
## driving vehicle can't leave (Tribes 2 pads are built for hover craft). "herc" spawns the exporter
## placed on a pad count as the pad. Maps without other Herc starts use the infantry spawns (drop
## points are often inside bases; a Herc goes on the terrain above them), and the pads when there
## are none at all. A Herc start under cover (inside a base) or on a slope moves to the nearest open level ground, and
## every vehicle spawn is lifted out of any solid it would start inside (SpawnClearance).
static func _make_spawns(parent: Node3D, m: Dictionary) -> Dictionary:
	var pads: Array[Transform3D] = []
	var ground: Array[Transform3D] = []
	var infantry: Array[Transform3D] = []
	var clearance := SpawnClearance.make(parent)
	for s in m.get("spawns", []):
		var xf := make_spawn_transform(parent, s, clearance)
		match String(s.get("kind", "herc")):
			"vehicle_pad":
				xf.origin = clearance.make_clear_origin(xf.origin)
				_append_unique(pads, xf, SPAWN_MERGE_DISTANCE)
			"herc":
				xf.origin = clearance.make_clear_origin(clearance.make_level_ground_origin(xf.origin))
				_append_unique(ground, xf, SPAWN_MERGE_DISTANCE)
			"infantry":
				infantry.append(xf)
	ground = ground.filter(func(t: Transform3D) -> bool: return not _has_near(pads, t.origin, SPAWN_MERGE_DISTANCE))
	if ground.is_empty():
		ground = _make_infantry_fallbacks(parent, infantry, clearance)
	if ground.is_empty():
		ground = pads.duplicate()
	ground = _make_open_facings(ground, clearance, make_centre(m))
	return {"herc": ground, "pad": pads, "infantry": infantry}


## {team: [Transform3D]}: each team's own vehicle starts (MapTeams), the team's Herc spawns, else Hercs on the
## terrain at its infantry drop points, else its vehicle pads. Neutral spawns (team -1) belong to no team.
static func _make_team_spawns(parent: Node3D, m: Dictionary) -> Dictionary:
	var out := {}
	var clearance := SpawnClearance.make(parent)
	for team in MapTeams.make_spawn_teams(m):
		var by_kind := {"herc": [] as Array[Transform3D], "infantry": [] as Array[Transform3D], "vehicle_pad": [] as Array[Transform3D]}
		for s in m.get("spawns", []):
			var kind := String(s.get("kind", "herc"))
			if s.get("team") != null and int(s.team) == team and by_kind.has(kind):
				by_kind[kind].append(make_spawn_transform(parent, s, clearance))
		var points: Array[Transform3D] = []
		for xf in by_kind.herc:
			_append_unique(points, Transform3D(xf.basis, clearance.make_clear_origin(clearance.make_level_ground_origin(xf.origin))), SPAWN_MERGE_DISTANCE)
		if points.is_empty():
			points = _make_infantry_fallbacks(parent, by_kind.infantry, clearance)
		if points.is_empty():
			points.assign(by_kind.vehicle_pad)
		if not points.is_empty():
			out[team] = _make_open_facings(points, clearance, make_centre(m))
	return out


## Herc starts on the terrain at the infantry drop points, or next to the base they are in.
static func _make_infantry_fallbacks(parent: Node3D, infantry: Array[Transform3D], clearance: SpawnClearance) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for t in infantry:
		var hx: Transform3D = t
		hx.origin.y = ground_height(parent, hx.origin) + SPAWN_LIFT
		hx.origin = clearance.make_clear_origin(clearance.make_level_ground_origin(hx.origin))
		_append_unique(out, hx, FALLBACK_SPAWN_MERGE_DISTANCE)
	return out


## Every start turned away from a wall in front of it (SpawnClearance.make_open_facing).
static func _make_open_facings(points: Array[Transform3D], clearance: SpawnClearance, centre: Vector3) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for xf in points:
		out.append(clearance.make_open_facing(xf, centre))
	return out


## The middle of the map's playable area (its bounds; the origin without).
static func make_centre(m: Dictionary) -> Vector3:
	var b = m.get("bounds")
	if not (b is Dictionary and b.has("min") and b.has("max")):
		return Vector3.ZERO
	return Vector3((float(b.min[0]) + float(b.max[0])) * 0.5, 0.0, (float(b.min[1]) + float(b.max[1])) * 0.5)


static func _append_unique(list: Array[Transform3D], xf: Transform3D, merge_distance: float) -> void:
	if not _has_near(list, xf.origin, merge_distance):
		list.append(xf)


## Spawns on raised pads / inside bases keep their original height; others sit on the terrain.
## Without explicit fields, a spawn well above/below the terrain is in a base (raised or underground). A kept height with
## no floor under it (a drop point the file puts in the air) comes down onto the highest surface below
## (SpawnClearance.make_supported_origin; `clearance` the map's, made here when not given).
static func make_spawn_transform(parent: Node3D, s: Dictionary, clearance: SpawnClearance = null) -> Transform3D:
	var xf := _xf(s)
	var gh := ground_height(parent, xf.origin)
	var keep := bool(s.get("indoor", false)) or absf(float(s.get("above_terrain", 0.0))) > RAISED_SPAWN_HEIGHT
	if not s.has("indoor") and not s.has("above_terrain") and absf(xf.origin.y - gh) > INDOOR_SPAWN_GAP:
		keep = true
	if xf.origin.y - gh > INDOOR_SPAWN_GAP:
		keep = true   # well above the terrain whatever the fields say (an AA drop point inside a tower): it stands on what is under it
	if keep:
		xf.origin = (clearance if clearance != null else SpawnClearance.make(parent)).make_supported_origin(xf.origin)
		xf.origin.y += SPAWN_LIFT
	elif gh == xf.origin.y:
		# Over a terrain hole (a base's entrance) or off the terrain: on the floor of a building just under the point (a
		# bridge or deck over the hole), else the nearest solid ground, never the open pit.
		var clear: SpawnClearance = clearance if clearance != null else SpawnClearance.make(parent)
		var floor_y := clear.make_floor_height_below(xf.origin, HOLE_FLOOR_REACH)
		if floor_y > -INF:
			xf.origin.y = floor_y + SPAWN_LIFT
		else:
			var solid := MapTerrain.make_nearest_solid_ground(parent, xf.origin, OFF_TERRAIN_REACH)
			xf.origin = (solid if solid != Vector3.INF else xf.origin) + Vector3.UP * SPAWN_LIFT
	else:
		# Above the collision triangles too, which on a steep square rise over the bilinear height.
		xf.origin.y = MapTerrain.make_collision_height(parent, xf.origin) + SPAWN_LIFT
	return xf


static func _has_near(list: Array, p: Vector3, d: float) -> bool:
	for t in list:
		if t.origin.distance_to(p) < d:
			return true
	return false


## The placement of map entry `o` (pos + yaw/pitch/roll or basis, scale) as a transform.
static func make_transform(o: Dictionary) -> Transform3D:
	return _xf(o)


static func _xf(o: Dictionary) -> Transform3D:
	var p: Array = o.get("pos", [0, 0, 0])
	var b := Basis()
	if o.get("basis") is Array:
		var r: Array = o.basis
		b = Basis(Vector3(r[0][0], r[1][0], r[2][0]), Vector3(r[0][1], r[1][1], r[2][1]), Vector3(r[0][2], r[1][2], r[2][2]))
	else:
		b = Basis.from_euler(Vector3(deg_to_rad(float(o.get("pitch", 0))), deg_to_rad(float(o.get("yaw", 0))), deg_to_rad(float(o.get("roll", 0)))), EULER_ORDER_YXZ)
	var s := float(o.get("scale", 1.0)) if not (o.get("scale") is Array) else 1.0
	return Transform3D(b.scaled(Vector3.ONE * s), Vector3(float(p[0]), float(p[1]), float(p[2])))


static func _place(parent: Node3D, o: Dictionary, pal: String, collide: bool) -> Node3D:
	var sid := String(o.get("shape", ""))
	if sid == "" or (sid.contains(":") and not Assets.has_pack(Assets.split_id(sid)[0])):
		return null   # a borrowed shape (the Starsiege maps' Tribes stations) needs its game installed
	if MapPlaceholder.is_unconverted(sid):
		return MapPlaceholder.place(parent, o, _xf(o), collide)
	if Assets.shape(sid).get("lods", [{}])[0].get("pieces", []).is_empty():
		return null
	var spack: String = Assets.split_id(sid)[0]
	if spack != "" and Packs.default_palette(spack) != "":
		pal = Packs.default_palette(spack)   # a shape borrowed from another pack (e.g. Tribes stations) keeps its own palette
	var body := WorldBuilder.place_static(parent, sid, _xf(o), pal)
	if not collide:
		for c in body.get_children():
			if c is CollisionShape3D:
				c.queue_free()
	return body


## Terrain height at a world position, p.y where there is none (see MapTerrain.ground_height).
static func ground_height(parent: Node3D, p: Vector3) -> float:
	return MapTerrain.ground_height(parent, p)
