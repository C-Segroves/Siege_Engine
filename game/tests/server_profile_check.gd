extends Node
## The server profile (collision only) must not change what the world collides with: the same downward rays hit the
## same heights on Varuna's Fall built with and without the render-only parts, and the server build has far fewer
## meshes. Prints "SERVER PROFILE OK" / "SERVER PROFILE FAILED: <why>" and quits 0 / 1.
##   godot --headless --audio-driver Dummy --path game res://tests/server_profile_check.tscn
const GRID := 24
const RAY_TOP := 3000.0
const RAY_DEPTH := 6000.0
const TOLERANCE := 0.01


func _ready() -> void:
	_run.call_deferred()


func _fail(why: String) -> void:
	print("SERVER PROFILE FAILED: ", why)
	ServerProfile.set_collision_only(false)
	get_tree().quit(1)


func _build() -> Node3D:
	var world := Node3D.new()
	add_child(world)
	MapBuilder.build(world, VarunaMap.MAP_ID)
	return world


func _sample(world: Node3D) -> PackedFloat32Array:
	var hits := PackedFloat32Array()
	var space := world.get_world_3d().direct_space_state
	var half := 2000.0
	for iz in GRID:
		for ix in GRID:
			var x := lerpf(-half, half, float(ix) / (GRID - 1))
			var z := lerpf(-half, half, float(iz) / (GRID - 1))
			var q := PhysicsRayQueryParameters3D.create(Vector3(x, RAY_TOP, z), Vector3(x, RAY_TOP - RAY_DEPTH, z))
			var hit := space.intersect_ray(q)
			hits.append(float(hit.position.y) if not hit.is_empty() else -99999.0)
	return hits


func _run() -> void:
	ServerProfile.set_collision_only(false)
	var full := _build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var full_hits := _sample(full)
	var full_meshes := full.find_children("*", "MeshInstance3D", true, false).size()
	remove_child(full)
	full.free()
	ServerProfile.set_collision_only(true)
	var server := _build()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var server_hits := _sample(server)
	var server_meshes := server.find_children("*", "MeshInstance3D", true, false).size()
	var hit_count := 0
	for i in full_hits.size():
		if full_hits[i] > -99999.0:
			hit_count += 1
		if absf(full_hits[i] - server_hits[i]) > TOLERANCE:
			return _fail("ray %d hits y=%.3f full, y=%.3f server" % [i, full_hits[i], server_hits[i]])
	if hit_count < GRID * GRID / 2:
		return _fail("only %d of %d rays hit anything (map not built?)" % [hit_count, full_hits.size()])
	if server_meshes != 0 or full_meshes <= server_meshes:
		return _fail("meshes: full %d, server %d (the server world must draw nothing)" % [full_meshes, server_meshes])
	print("SERVER PROFILE OK: %d rays (%d hits) identical; meshes full %d, server %d" % [full_hits.size(), hit_count, full_meshes, server_meshes])
	ServerProfile.set_collision_only(false)
	get_tree().quit(0)
