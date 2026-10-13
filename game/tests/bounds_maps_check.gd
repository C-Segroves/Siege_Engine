extends Node
## Every arena map's kill floor (MapBounds, playtest G1): built map by map, the floor lies below the lowest
## interior / prop / structure and the terrain, and no start (Herc, pad, soldier drop point, also those inside
## underground bases) counts as fallen out of the world, and nobody standing on the terrain under a building's
## footprint (a bridge, a floating base, an interior above the ground) does either. Tribes / Tribes 2 maps: every
## part of every terrain hole has something under it (a base, else TerrainHoleSeal's patch), and the floor strip of
## Katabatic's sbunk2 that only the interior's null surfaces carry is solid.
## godot --headless --audio-driver Dummy --path game res://tests/bounds_maps_check.tscn [-- --only=tribes]

## Samples per side of each building footprint; a soldier's feet this far above the terrain.
const GRID := 5
## A terrain hole under a building whose bottom is 100 m above it (F's report: the floor was the building's).
const KATABATIC := "tribes2:Katabatic"
const KATABATIC_HOLE := Vector3(354, 0, 185)
const STAND_HEIGHT := 0.1
## Terrain holes are sampled HOLE_SAMPLES x HOLE_SAMPLES per square, from this far above the surface.
const HOLE_SAMPLES := 4
const HOLE_PROBE_LIFT := 2.0
const VOID_PACKS := ["tribes", "tribes2"]
## Katabatic's sbunk2: a 3.5 m strip of the room floor exists only as Torque null surfaces (a bot fell through it).
const KATABATIC_PIT := Vector3(340.0, 85.0, 195.0)
const KATABATIC_PIT_DEPTH := 30.0

var _failures := 0
var _maps := 0


func _ready() -> void:
	await get_tree().process_frame
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	for e in MapBuilder.list_maps():
		if only == "" or str(e.pack) == only:
			await _check_map(str(e.id))
	print("bounds_maps_check: %d maps, %s (%d failures)" % [_maps, "OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _check_map(map_id: String) -> void:
	var root := Node3D.new()
	add_child(root)
	var built := MapBuilder.build(root, map_id)
	await get_tree().process_frame
	if built.is_empty():
		root.queue_free()
		return
	_maps += 1
	var b := MapBounds.make_for(root, built)
	var lowest := INF
	for box in b.solids:
		lowest = minf(lowest, box.position.y)
	var problems := []
	if lowest < INF and lowest <= b.floor_y:
		problems.append("lowest building %.1f at or below the floor %.1f" % [lowest, b.floor_y])
	var starts: Array = built.get("herc_spawns", []) + built.get("pad_spawns", []) + built.get("infantry_spawns", [])
	var deepest := 0.0
	for t in starts:
		var o := (t as Transform3D).origin
		deepest = maxf(deepest, MapTerrain.ground_height(root, o) - o.y)
		if b.is_below_floor(root, o):
			problems.append("start %s counts as fallen through" % (t as Transform3D).origin)
			break
	var standing := _find_terrain_under_buildings_below_floor(root, b)
	if map_id == KATABATIC and b.is_below_floor(root, Vector3(KATABATIC_HOLE.x, MapTerrain.make_surface_height(root, KATABATIC_HOLE) + STAND_HEIGHT, KATABATIC_HOLE.z)):
		problems.append("the Katabatic base entrance (a terrain hole under a raised building) counts as fallen through")
	if standing != Vector3.INF:
		problems.append("standing on the terrain at %s under a building counts as fallen through" % standing)
	if Assets.split_id(map_id)[0] in VOID_PACKS:
		var open_hole := _find_open_hole(root, b)
		if open_hole != Vector3.INF:
			problems.append("the terrain hole at %s has nothing under it (TerrainHoleSeal)" % open_hole)
		if map_id == KATABATIC and _is_open_below(root, KATABATIC_PIT, KATABATIC_PIT_DEPTH):
			problems.append("the sbunk2 generator pit floor (null surfaces) is missing at %s" % KATABATIC_PIT)
	if deepest > MapBounds.FELL_THROUGH_DEPTH * 0.5:
		print("  info %s: a start %.0f m below the terrain, floor %.0f" % [map_id, deepest, b.floor_y])
	if not problems.is_empty():
		_failures += 1
		print("  FAIL %s: %s" % [map_id, "; ".join(problems)])
	root.queue_free()
	await get_tree().process_frame


## A point on the terrain under a building footprint (GRID x GRID samples each) that counts as fallen through,
## Vector3.INF when there is none.
func _find_terrain_under_buildings_below_floor(root: Node3D, b: MapBounds) -> Vector3:
	for box in b.solids:
		for i in GRID:
			for k in GRID:
				var p := Vector3(lerpf(box.position.x, box.end.x, (i + 0.5) / GRID), 0.0,
					lerpf(box.position.z, box.end.z, (k + 0.5) / GRID))
				p.y = MapTerrain.make_surface_height(root, p)
				if p.y < INF and b.is_below_floor(root, p + Vector3.UP * STAND_HEIGHT):
					return p
	return Vector3.INF



## A point in a terrain hole with nothing under it down to the world floor; Vector3.INF when there is none.
func _find_open_hole(root: Node3D, b: MapBounds) -> Vector3:
	var terrains := MapTerrain.make_live_terrains(root).filter(func(t: Node) -> bool: return root.is_ancestor_of(t))
	if terrains.is_empty():
		return Vector3.INF
	var d: Dictionary = terrains[0].get_meta("terrain")
	var holes: PackedByteArray = d.get("holes", PackedByteArray())
	var w := int(d.w)
	for i in holes.size():
		if holes[i] != MapTerrain.HOLE:
			continue
		for a in HOLE_SAMPLES:
			for k in HOLE_SAMPLES:
				var fx := i % (w - 1) + (a + 0.5) / HOLE_SAMPLES
				var fz := i / (w - 1) + (k + 0.5) / HOLE_SAMPLES
				var p := Vector3(float(d.x0) + fx * float(d.sq), MapTerrain.make_grid_height(d, fx, fz) + HOLE_PROBE_LIFT,
					float(d.z0) + fz * float(d.sq))
				if _is_open_below(root, p, p.y - b.floor_y):
					return p
	return Vector3.INF


func _is_open_below(root: Node3D, p: Vector3, depth: float) -> bool:
	var ray := PhysicsRayQueryParameters3D.create(p, p + Vector3.DOWN * depth)
	return root.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
