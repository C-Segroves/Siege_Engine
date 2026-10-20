extends Node
## Tribes: Aerial Assault, every imported map (arena and campaign): the terrain collides where it is drawn, the kill floor
## (MapBounds) lies below every walkable surface, the mission area lies on the terrain, every start is above the floor
## and on the ground (a drop point's file height is not trusted), and a soldier dropped from a start lands and stays up.
##   godot --headless --audio-driver Dummy --path game res://tests/aa_bounds_check.tscn [-- --only=Escalade]
## Skips (exit 0) when Aerial Assault is not imported.

const PACK := "tribes_aa"
## Sample points per side across the mission area.
const GRID := 12
const STAND_HEIGHT := 0.1
## The collision surface may differ from the bilinear height by this much (a triangle versus the bilinear patch).
const SURFACE_TOLERANCE := 1.5
const DROP_HEIGHT := 400.0

var _failures := 0
var _maps := 0


func _ready() -> void:
	await get_tree().process_frame
	if not Assets.has_pack(PACK):
		print("aa_bounds_check: Aerial Assault is not imported, skipped")
		get_tree().quit(0)
		return
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	var dirs := DirAccess.get_directories_at(Assets.data_root.path_join(PACK).path_join("maps"))
	for id in dirs:
		if only == "" or id == only:
			await _check_map("%s:%s" % [PACK, id])
	print("aa_bounds_check: %d maps, %s (%d failures)" % [_maps, "OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _check_map(map_id: String) -> void:
	var root := Node3D.new()
	add_child(root)
	var built := MapBuilder.build(root, map_id)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if built.is_empty():
		print("  FAIL %s: did not build" % map_id)
		_failures += 1
		root.queue_free()
		return
	_maps += 1
	var problems := []
	var b := MapBounds.make_for(root, built)
	var terrain := MapBounds.make_terrain_extent(root)
	var m: Dictionary = built.map
	var space := root.get_world_3d().direct_space_state
	if not terrain.has_area():
		problems.append("no terrain")
	if not b.has_area:
		problems.append("no playable area")
	elif terrain.has_area() and not terrain.grow(0.5).encloses(b.area):
		problems.append("mission area %s leaves the terrain %s" % [b.area, terrain])
	var lowest_terrain := MapBounds.make_lowest_terrain_height(root)
	if b.floor_y > lowest_terrain - MapBounds.FELL_THROUGH_DEPTH * 0.5:
		problems.append("floor %.0f not well below the lowest terrain %.0f" % [b.floor_y, lowest_terrain])
	# Terrain collision against the drawn surface, and standing on it never counts as fallen / outside.
	var bad_surface := 0
	var bad_floor := 0
	var bad_out := 0
	var d: Dictionary = MapTerrain.make_live_terrains(root)[0].get_meta("terrain") if not MapTerrain.make_live_terrains(root).is_empty() else {}
	for i in GRID:
		for k in GRID:
			if not b.has_area:
				break
			var p := Vector3(lerpf(b.area.position.x, b.area.end.x, (i + 0.5) / GRID), 0.0,
				lerpf(b.area.position.y, b.area.end.y, (k + 0.5) / GRID))
			var h := MapTerrain.make_surface_height(root, p)
			if h == INF:
				continue
			p.y = h
			if b.is_outside(p):
				bad_out += 1
			if b.is_below_floor(root, p + Vector3.UP * STAND_HEIGHT):
				bad_floor += 1
			if not d.is_empty() and _is_over_hole(d, p):
				continue
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 500.0, p + Vector3.DOWN * 500.0))
			if hit.is_empty():
				bad_surface += 1
				if bad_surface == 1:
					print("    miss at %s (surface %.1f)" % [p, h])
			elif hit.position.y < _lowest_corner(d, p) - 0.2:
				bad_surface += 1   # (a building above the ground is fine; collision below the drawn ground is not)
	if bad_surface > 0:
		problems.append("%d sample points where the terrain collision is missing or below the drawn surface" % bad_surface)
	if bad_floor > 0:
		problems.append("%d ground points inside the mission area count as fallen through" % bad_floor)
	if bad_out > 0:
		problems.append("%d ground points inside the mission area count as out of bounds" % bad_out)
	# Starts: inside the area, above the floor, on or just above the ground (or on a building).
	var starts: Array = built.get("infantry_spawns", []) + built.get("pad_spawns", []) + built.get("herc_spawns", [])
	if starts.is_empty():
		problems.append("no starts")
	for xf in starts:
		var o: Vector3 = (xf as Transform3D).origin
		if b.is_below_floor(root, o):
			problems.append("start %s counts as fallen through (floor %.0f)" % [o, b.floor_y])
			break
		if b.is_outside(o):
			problems.append("start %s is outside the mission area" % o)
			break
		var fall := _drop(space, o)
		if fall.is_empty():
			problems.append("a soldier dropped at start %s lands on nothing (hole %s)" % [o, _is_over_hole(d, o)])
			break
		var landed: Vector3 = fall.position
		if b.is_below_floor(root, landed + Vector3.UP * STAND_HEIGHT) or b.is_outside(landed):
			problems.append("a soldier dropped at start %s lands at %s, which counts as fallen / outside" % [o, landed])
			break
		if o.y - landed.y > 8.0 and (xf as Transform3D) in built.get("infantry_spawns", []):
			problems.append("infantry start %s hangs %.0f m above the ground (hole %s)" % [o, o.y - landed.y, _is_over_hole(d, o)])
			break
	# The player's real start and a soldier on every other start rest on collision a few physics frames later.
	var settle := await _settle_starts(root, b, built, AAMissionRuntime.make_player_start(root, m).origin)
	if settle != "":
		problems.append(settle)
	# Buildings and interiors collide: every placed shape marked collide has a static body.
	var wanted := 0
	for list_key in ["interiors", "statics"]:
		for e in m.get(list_key, []):
			if e is Dictionary and bool(e.get("collide", true)):
				wanted += 1
	var bodies := b.solids.size()
	if wanted > 0 and bodies == 0:
		problems.append("%d interiors / statics collide in the map, no building has a collision body" % wanted)
	if not problems.is_empty():
		_failures += 1
		print("  FAIL %s: %s" % [map_id, "; ".join(problems)])
	else:
		print("  ok   %s (floor %.0f, %d solids)" % [map_id, b.floor_y, bodies])
	root.queue_free()
	await get_tree().process_frame


## The lowest of the four grid heights around `p`: the collision triangles never dip below it.
func _lowest_corner(d: Dictionary, p: Vector3) -> float:
	var fx := (p.x - float(d.x0)) / float(d.sq)
	var fz := (p.z - float(d.z0)) / float(d.sq)
	var w := int(d.w)
	var x0 := mini(int(fx), w - 2)
	var z0 := mini(int(fz), int(d.h) - 2)
	var lo := INF
	for dz in 2:
		for dx in 2:
			lo = minf(lo, d.heights[(z0 + dz) * w + x0 + dx])
	return lo


func _is_over_hole(d: Dictionary, p: Vector3) -> bool:
	var holes: PackedByteArray = d.get("holes", PackedByteArray())
	if holes.is_empty():
		return false
	var w := int(d.w)
	var fx := int((p.x - float(d.x0)) / float(d.sq))
	var fz := int((p.z - float(d.z0)) / float(d.sq))
	var idx := mini(fz, int(d.h) - 2) * (w - 1) + mini(fx, w - 2)
	return holes[idx] == MapTerrain.HOLE


## Where a soldier released DROP_HEIGHT above `o`'s x/z... from the start itself, straight down: the first surface.
func _drop(space: PhysicsDirectSpaceState3D, o: Vector3) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(o + Vector3.UP * 1.0, o + Vector3.DOWN * DROP_HEIGHT))


const SETTLE_FRAMES := 90
const FLOOR_MAX_ANGLE := 85.0   ## degrees: a start on a steep slope still counts as standing
const CAPSULE_HEIGHT := 1.8
const CAPSULE_RADIUS := 0.4
const GRAVITY := 30.0
## Downward speed (m/s) of a body that has not landed: gravity alone reaches it within a second.
const FALLING_SPEED := 8.0


## Soldier-sized bodies released at the player's start (as the runtime places him: the file height plus a lift) and at
## the map's infantry starts and soldier points (on the ground, as BattleInfantry.make_on_ground puts them), then
## SETTLE_FRAMES physics frames of gravity: each must come to rest on collision (not fallen through, an
## infantry or player start not outside the area, none still falling after the frames). Returns the first failure, "" when all settle.
func _settle_starts(root: Node3D, b: MapBounds, built: Dictionary, player_start: Vector3) -> String:
	var probes := [{"label": "player start", "pos": player_start}]
	for xf in built.get("infantry_spawns", []):
		probes.append({"label": "infantry start", "pos": _on_ground(root, (xf as Transform3D).origin)})
	for w in built.map.get("waypoints", []):
		if not AAScript.parse_spawn_tag(str(w.get("tag", ""))).is_empty():
			var q: Array = w.pos
			probes.append({"label": "soldier point %s" % w.get("tag", ""), "pos": _on_ground(root, Vector3(q[0], q[1], q[2]))})
	var bodies := []
	for pr in probes:
		var body := CharacterBody3D.new()
		var shape := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = CAPSULE_RADIUS
		cap.height = CAPSULE_HEIGHT
		shape.shape = cap
		body.add_child(shape)
		body.collision_layer = 0
		body.floor_max_angle = deg_to_rad(FLOOR_MAX_ANGLE)
		root.add_child(body)
		body.global_position = (pr.pos as Vector3) + Vector3.UP * CAPSULE_HEIGHT * 0.5
		bodies.append(body)
	for _f in SETTLE_FRAMES:
		await get_tree().physics_frame
		for body in bodies:
			body.velocity.y -= GRAVITY / 60.0
			body.move_and_slide()
	var failure := ""
	for i in bodies.size():
		var feet: Vector3 = (bodies[i] as CharacterBody3D).global_position - Vector3.UP * CAPSULE_HEIGHT * 0.5
		var start: Vector3 = probes[i].pos
		var why := ""
		if b.is_below_floor(root, feet):
			why = "fell through the world"
		elif b.is_outside(feet) and not str(probes[i].label).begins_with("soldier point"):   # (a wave point may lie past the area)
			why = "ended outside the mission area"
		elif (bodies[i] as CharacterBody3D).velocity.y < -FALLING_SPEED and start.y - feet.y > 1.0:   # (a body wedged in a solid is not falling)
			why = "is still falling after %d frames" % SETTLE_FRAMES
		if why != "" and failure == "":
			failure = "%s at %s %s (rest %s, terrain %.1f)" % [probes[i].label, start, why, feet, MapTerrain.make_surface_height(root, feet)]
		(bodies[i] as Node).queue_free()
	return failure


## BattleInfantry.make_on_ground for a test without a battle: onto the terrain, onto the hole rim over a hole.
func _on_ground(root: Node3D, p: Vector3) -> Vector3:
	var ground := MapTerrain.ground_height(root, Vector3(p.x, -INF, p.z))
	if ground == -INF:
		var rim := MapTerrain.make_surface_height(root, p)
		ground = rim if rim < INF else p.y
	return Vector3(p.x, maxf(p.y, ground) + BattleInfantry.GROUND_CLEARANCE, p.z)
