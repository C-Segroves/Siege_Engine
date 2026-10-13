class_name BattleNavigation
extends Node
## Walkable paths over a battlefield for the AI (InfantryBot; any AI with its own agent profile): a navigation
## mesh baked from the battlefield's static colliders (terrain, interiors, buildings, props), tile by tile where
## and when a path is asked for, kept for the rest of the battle.
##
## Why a baked mesh and not the originals' data: Tribes 2 ships AI graphs (.nav / .spn) for only 28 of its 52
## missions, in an undocumented binary format; Tribes 1 has no AI path data at all (its bots follow mission path
## markers), and the Earthsiege / Starsiege worlds none either. A mesh baked from the same collision the bodies
## walk on fits every map of every pack, interiors included, and cannot disagree with the physics.
##
## Each agent profile ({radius, height, climb, slope_deg}) has its own navigation map. Baking is asynchronous:
## until the tiles between two points are baked, make_path returns [] and the caller moves as it did without
## navigation (straight at its goal). Child "Navigation" of the Battle (of(battle) makes it on first use).

const NODE_NAME := "Navigation"
## Tile edge (metres) and how many tiles one request may queue (a long path gets its first stretch first).
const TILE_SIZE := 96.0
const MAX_TILES_PER_REQUEST := 9
const RING_4 := [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const RING_8 := [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1),
	Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
## Vertical extent of a tile's bake box (metres above / below the lowest and highest point asked about).
const TILE_HEIGHT_MARGIN := 120.0
const CELL_SIZE := 0.6   # the soldier radius in one cell, the tile border in two
const CELL_HEIGHT := 0.1
## A Tribes soldier: capsule radius 0.6 (T2 light boundingBox 1.2 / 2), 2.3 m tall. He gets up ledges as high as
## a jump and a short jet (3 m: the bot jumps and jets at a ledge in its way, as the originals' bots took the jet
## edges of their graphs - converted bases' doorsills sit up to ~3 m above the terrain outside) and up slopes to
## 60 degrees (steeper ones he jets or skis).
const SOLDIER := {"name": "soldier", "radius": 0.6, "height": 2.3, "climb": 3.0, "slope_deg": 60.0}
const EDGE_CONNECTION_MARGIN := 1.0

var _root: Node3D
var _source: NavigationMeshSourceGeometryData3D
var _maps := {}          # profile name -> navigation map RID
var _tiles := {}         # "profile|x|z" -> region RID (baked) or null (baking)
var _pending := 0


## The battle's navigation (made on first use).
static func of(battle: Node3D) -> BattleNavigation:
	var n := battle.get_node_or_null(NODE_NAME) as BattleNavigation
	if n == null:
		n = BattleNavigation.new()
		n._root = battle
		n.name = NODE_NAME
		battle.add_child(n)
	return n


func _exit_tree() -> void:
	for rid in _tiles.values():
		if rid is RID and (rid as RID).is_valid():
			NavigationServer3D.free_rid(rid)
	for rid in _maps.values():
		NavigationServer3D.free_rid(rid)
	_tiles.clear()
	_maps.clear()


## A walkable path from `from` to (the walkable point nearest) `to` for `profile`, [] while the tiles between them
## are still baking or when no walkable surface is near. Queues the missing tiles.
func make_path(from: Vector3, to: Vector3, profile := SOLDIER) -> PackedVector3Array:
	var missing := _request_tiles(from, to, profile)
	if missing > 0:
		return PackedVector3Array()
	var map := _map_of(profile)
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(map, from, to, true)


## True when every tile between `from` and `to` is baked for `profile` (tests).
func is_ready(from: Vector3, to: Vector3, profile := SOLDIER) -> bool:
	return _request_tiles(from, to, profile) == 0 and NavigationServer3D.map_get_iteration_id(_map_of(profile)) > 0


## Tiles being baked now.
func pending_tiles() -> int:
	return _pending


# ------------------------------------------------------------------ tiles

## Queues the unbaked tiles along from -> to (at most MAX_TILES_PER_REQUEST, nearest first); the number of tiles
## still missing.
func _request_tiles(from: Vector3, to: Vector3, profile: Dictionary, most := MAX_TILES_PER_REQUEST) -> int:
	var missing := 0
	var queued := 0
	for tile in make_tiles_between(from, to):
		var key := "%s|%d|%d" % [profile.name, tile.x, tile.y]
		if _tiles.has(key):
			if _tiles[key] == null:
				missing += 1
			continue
		missing += 1
		if queued < most:
			queued += 1
			_bake_tile(key, tile, minf(from.y, to.y), maxf(from.y, to.y), profile)
	return missing


## The tile cells (x, z) a straight line from `from` to `to` crosses, with their neighbours (the whole ring round
## both ends: a base's floors and ramps may reach into the next tile), nearest to `from` first.
static func make_tiles_between(from: Vector3, to: Vector3) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var steps := maxi(1, int(ceil(Vector2(to.x - from.x, to.z - from.z).length() / (TILE_SIZE * 0.5))))
	for i in steps + 1:
		var p := from.lerp(to, float(i) / steps)
		var c := Vector2i(floori(p.x / TILE_SIZE), floori(p.z / TILE_SIZE))
		var ring := RING_8 if i == 0 or i == steps else RING_4
		for d in ring:
			if not out.has(c + d):
				out.append(c + d)
	return out


## Bakes the tiles round `points` now (a mode's bases: stations, flags), so paths into them are ready when the AI
## first asks.
func apply_prebake(points: Array, profile := SOLDIER) -> void:
	for p in points:
		_request_tiles(p, p, profile, MAX_TILES_PER_REQUEST * 2)


func _bake_tile(key: String, tile: Vector2i, low: float, high: float, profile: Dictionary) -> void:
	_tiles[key] = null
	_pending += 1
	var nm := _make_navmesh(profile)
	var lo := Vector3(tile.x * TILE_SIZE, low - TILE_HEIGHT_MARGIN, tile.y * TILE_SIZE)
	nm.filter_baking_aabb = AABB(lo, Vector3(TILE_SIZE, high - low + TILE_HEIGHT_MARGIN * 2.0, TILE_SIZE))
	nm.border_size = float(profile.radius) * 2.0
	NavigationServer3D.bake_from_source_geometry_data_async(nm, _source_geometry(), _on_baked.bind(key, nm, profile))


func _on_baked(key: String, nm: NavigationMesh, profile: Dictionary) -> void:
	_pending -= 1
	if not is_inside_tree() or not _tiles.has(key):
		return
	var region := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, _map_of(profile))
	NavigationServer3D.region_set_navigation_mesh(region, nm)
	_tiles[key] = region


static func _make_navmesh(profile: Dictionary) -> NavigationMesh:
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.cell_size = CELL_SIZE
	nm.cell_height = CELL_HEIGHT
	nm.agent_radius = float(profile.radius)
	nm.agent_height = float(profile.height)
	nm.agent_max_climb = float(profile.climb)
	nm.agent_max_slope = float(profile.slope_deg)
	return nm


## The battlefield's static colliders, parsed once (main thread; the bakes reuse it).
func _source_geometry() -> NavigationMeshSourceGeometryData3D:
	if _source == null:
		_source = NavigationMeshSourceGeometryData3D.new()
		NavigationServer3D.parse_source_geometry_data(_make_navmesh(SOLDIER), _source, _root)
	return _source


func _map_of(profile: Dictionary) -> RID:
	if not _maps.has(profile.name):
		var map := NavigationServer3D.map_create()
		NavigationServer3D.map_set_cell_size(map, CELL_SIZE)
		NavigationServer3D.map_set_cell_height(map, CELL_HEIGHT)
		NavigationServer3D.map_set_edge_connection_margin(map, EDGE_CONNECTION_MARGIN)
		NavigationServer3D.map_set_active(map, true)
		_maps[profile.name] = map
	return _maps[profile.name]
