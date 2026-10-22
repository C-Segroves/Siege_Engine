extends RefCounted
## The physics half of the spawn audit (spawn_audit_check.gd): a cohort of probes, each one real unit (a Tribes soldier or a
## Herc / vehicle) set down at one spawn transform of a built map, then
##   1 checked for starting inside collision (penetration depth of its own capsule),
##   2 dropped: SETTLE_FRAMES physics frames of the unit's own gravity and floor snap,
##   3 judged: fell below the world's floor, spawned high in the air (dropped more than AIR_LIMIT_M), still falling,
##     outside the playable area, dead,
##   4 driven forward DRIVE_FRAMES frames (and, when that is blocked, the other three headings) to see it move MOVE_NEEDED_M.
## The probes of a cohort do not collide with each other (collision layer 0); they all stand in the map's world.
##
## A probe is a Dictionary: {unit: String, xf: Transform3D, body: Herc, result: String, reason: String, ...}.
## Results: ok, inside (starts inside collision), air (dropped from a great height), fell (fell through the world),
## falling (never landed), outside (outside the playable area), dead (died in the settle), stuck (cannot move).

const SETTLE_FRAMES := 90
const DRIVE_FRAMES := 150
const MOVE_NEEDED_M := 2.0
## A unit that drops further than this during the settle was set down in the air.
const AIR_LIMIT_M := 5.0
## Downward speed (m/s) of a body that has not landed: gravity alone reaches it within a second.
const FALLING_SPEED := 8.0
## Deepest penetration (m) of a unit's capsule into the world at its start that still counts as standing on it (a Herc's wide
## capsule touches the slope beside it; the physics engine pushes it out at once).
const INSIDE_DEPTH_SOLDIER := 0.35
const INSIDE_DEPTH_VEHICLE := 1.0
const HEADINGS := 4
const PROTECTED_SECONDS := 3600.0
## Order of the failures (the first one that applies is the probe's result).
const OK := "ok"

var _tree: SceneTree
var _world: Node3D
var _bounds: MapBounds


func _init(p_tree: SceneTree, p_world: Node3D, p_bounds: MapBounds) -> void:
	_tree = p_tree
	_world = p_world
	_bounds = p_bounds


## Runs the whole audit of `probes` (each has "xf" and "make": Callable() -> Herc); fills in result and reason.
func run(probes: Array) -> void:
	for p in probes:
		var body: Herc = p.make.call()
		body.transform = p.xf
		_world.add_child(body)
		body.collision_layer = 0
		body.spawn_protection = PROTECTED_SECONDS   # (a mission's turrets are still there)
		body.apply_spawn_protection()
		p["body"] = body
	await _tree.physics_frame
	for p in probes:
		_check_start(p)
	for f in SETTLE_FRAMES:
		await _tree.physics_frame
	for p in probes:
		_judge_settled(p)
	await _drive(probes)
	for p in probes:
		if p.result == "":
			p.result = OK
		p["end"] = (p.body as Herc).global_position
		if p.result != OK:
			p.reason = "%s (rest %.1f %.1f %.1f)" % [p.reason, p.end.x, p.end.y, p.end.z]
		(p.body as Node).queue_free()
	await _tree.physics_frame


func _check_start(p: Dictionary) -> void:
	p["result"] = ""
	p["reason"] = ""
	p["start_y"] = (p.body as Herc).global_position.y
	var depth := _penetration_depth(p.body)
	p["depth"] = depth
	var limit := INSIDE_DEPTH_SOLDIER if p.body is Infantry else INSIDE_DEPTH_VEHICLE
	if depth > limit:
		_fail(p, "inside", "starts %.2f m inside collision" % depth)


func _judge_settled(p: Dictionary) -> void:
	var body: Herc = p.body
	var feet := body.global_position
	p["settled"] = feet
	if p.result == "inside":
		return   # (kept: whatever the unit does next, it started in collision)
	if not body.alive:
		_fail(p, "dead", "died in the first %d frames" % SETTLE_FRAMES)
	elif _bounds.is_below_floor(_world, feet):
		_fail(p, "fell", "fell through the world to %.0f (floor %.0f)" % [feet.y, _bounds.floor_y])
	elif _bounds.is_outside(feet):
		_fail(p, "outside", "rests outside the playable area at %s" % [feet])
	elif body.velocity.y < -FALLING_SPEED and not body.is_on_floor():
		_fail(p, "falling", "still falling after %d frames (%.0f m/s)" % [SETTLE_FRAMES, body.velocity.y])
	elif float(p.start_y) - feet.y > AIR_LIMIT_M:
		_fail(p, "air", "set down %.1f m above its floor" % (float(p.start_y) - feet.y))


## Throttle forward on each heading in turn until the unit has moved MOVE_NEEDED_M (only the units that passed so far).
func _drive(probes: Array) -> void:
	var movers := probes.filter(func(p: Dictionary) -> bool: return p.result == "" or p.result == "air")
	var pending := movers.duplicate()
	for heading in HEADINGS:
		if pending.is_empty():
			break
		for p in pending:
			p["from"] = (p.body as Herc).global_position
			_aim(p.body, float(p.get("yaw", 0.0)) + heading * PI * 0.5)
			(p.body as Herc).throttle = 1.0
		for f in DRIVE_FRAMES:
			await _tree.physics_frame
		var still := []
		for p in pending:
			var body: Herc = p.body
			var moved := Vector2(body.global_position.x - p.from.x, body.global_position.z - p.from.z).length()
			p["moved"] = maxf(float(p.get("moved", 0.0)), moved)
			if not body.alive or moved >= MOVE_NEEDED_M:
				body.throttle = 0.0
				if not body.alive and p.result == "":
					_fail(p, "dead", "died while driving")
			else:
				still.append(p)
		pending = still
	for p in pending:
		(p.body as Herc).throttle = 0.0
		if p.result == "" or p.result == "air":
			_fail(p, "stuck", "cannot move %.0f m in %d directions (best %.1f m)" % [MOVE_NEEDED_M, HEADINGS, float(p.moved)])


func _aim(body: Herc, yaw: float) -> void:
	if body is Infantry:
		body.torso_target = yaw
		body.rotation.y = yaw
	else:
		body.rotation.y = yaw


func _fail(p: Dictionary, result: String, reason: String) -> void:
	if p.result == "" or p.result == "air":
		p.result = result
		p.reason = reason


## Deepest penetration (m) of the unit's collision capsule into the world's bodies.
func _penetration_depth(body: Herc) -> float:
	var col: CollisionShape3D = null
	for c in body.get_children():
		if c is CollisionShape3D:
			col = c
	if col == null:
		return 0.0
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = col.shape
	q.transform = col.global_transform
	q.exclude = [body.get_rid()]
	q.collision_mask = body.collision_mask
	var pairs := _world.get_world_3d().direct_space_state.collide_shape(q, 64)
	var deepest := 0.0
	var i := 0
	while i + 1 < pairs.size():
		deepest = maxf(deepest, (pairs[i] as Vector3).distance_to(pairs[i + 1]))
		i += 2
	return deepest
