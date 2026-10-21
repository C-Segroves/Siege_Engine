class_name InfantryCheapStep
extends RefCounted
## The cheap body step of an AI soldier far from every human (BotSleep MID tier; docs/DEDICATED_SERVER_SCALING.md
## section 8.5.3). move_and_slide costs about 220 us on a map with terrain and building colliders; this step costs
## two or three ray casts: the velocity is integrated, a down ray finds the floor under the new spot (terrain, building
## floors and roofs alike), a waist-high ray toward the new spot stops the soldier at a wall (and slides him along it
## once), an airborne soldier lands when his feet reach the floor. Other bodies are ignored (nobody is near to see it).
## Infantry._drive uses it while `far_lod` is set and re-snaps to the floor with the real body when the soldier is
## promoted, so the switch neither teleports nor jitters.

## The ground probe starts this far above the feet plus the climb a step may make.
const PROBE_UP := 0.6
## A grounded soldier follows the floor this far below his feet plus the drop a step may make (the body's floor snap is 0.5 m).
const PROBE_DOWN := 0.6
const WALL_HEIGHT := 1.0
## A surface whose normal leans less than this from the horizontal is a wall.
const WALL_NORMAL_Y := 0.7
const MAX_UNIT_SKIPS := 3
const SLIDES := 2
const MIN_STEP_M := 0.001
## An airborne soldier reaching a slope too steep to stand on is held this far off it.
const STEEP_SKIN := 0.05

## Off: far soldiers use move_and_slide as the NEAR ones do (the load bench's `--no-cheap-step`, to measure the saving).
static var enabled := true

static var _query: PhysicsRayQueryParameters3D
static var _exclude: Array[RID] = []


## Moves `s` for `delta` seconds from its velocity; sets its position, velocity and `cheap_floor`.
static func apply(s: Infantry, delta: float) -> void:
	var before := s.velocity
	var pos := s.global_position
	var flat := Vector3(s.velocity.x, 0.0, s.velocity.z) * delta
	var grounded := s.cheap_floor and s.velocity.y <= 0.0   # a jump or jet takeoff leaves the floor
	var next := _make_next_spot(s, pos, flat, s.velocity.y * delta, grounded)
	if next.blocked:
		s.velocity.x = 0.0
		s.velocity.z = 0.0
	if next.landed:
		_apply_landing(s, before, next.normal)
		s.velocity.y = 0.0
	elif next.get("slide", false):
		s.velocity = s.velocity.slide(next.normal)   # a slope too steep to stand on: he skids down it like move_and_slide
	elif next.grounded:
		s.velocity.y = 0.0
	s.cheap_floor = next.grounded
	s.global_position = next.position


## {position, grounded, landed, blocked, normal, slide?}: where the step ends. Up to SLIDES attempts, each along the wall
## the last one met.
static func _make_next_spot(s: Infantry, pos: Vector3, flat: Vector3, rise: float, grounded: bool) -> Dictionary:
	var move := flat
	var spot := {}
	for _attempt in SLIDES:
		spot = _make_floor_spot(s, pos, move, rise, grounded)
		var wall := _cast_wall(s, pos, spot.position, flat.length() > MIN_STEP_M)
		if wall.is_empty():
			return spot
		move = _make_slide(move, wall.normal)
		if move.length() < MIN_STEP_M:
			break
	return {"position": pos, "grounded": grounded, "landed": false, "blocked": true, "normal": Vector3.UP}


static func _make_slide(move: Vector3, normal: Vector3) -> Vector3:
	var flat_normal := Vector3(normal.x, 0.0, normal.z).normalized()
	return move - flat_normal * move.dot(flat_normal)


## The spot after `move` on the floor: a grounded soldier follows the floor, an airborne one falls by `rise` and lands
## when his feet reach the floor.
static func _make_floor_spot(s: Infantry, pos: Vector3, move: Vector3, rise: float, grounded: bool) -> Dictionary:
	var target := pos + move
	var up := PROBE_UP + (move.length() if grounded else 0.0)
	var top := target.y + up if grounded else maxf(pos.y, pos.y + rise) + PROBE_UP + move.length()   # (a slope may rise as far as the soldier travels)
	var bottom := target.y - PROBE_DOWN - move.length() if grounded else pos.y + rise
	var hit := _cast(s, Vector3(target.x, top, target.z), Vector3(target.x, bottom, target.z))
	var walkable := not hit.is_empty() and (hit.normal as Vector3).y >= cos(s.floor_max_angle)
	if grounded:
		if walkable:
			return {"position": hit.position, "grounded": true, "landed": false, "blocked": false, "normal": hit.normal}
		return {"position": target, "grounded": false, "landed": false, "blocked": false, "normal": Vector3.UP}   # walked off an edge
	target.y = pos.y + rise
	if not hit.is_empty() and not walkable and float(hit.position.y) >= target.y - MIN_STEP_M:
		return {"position": hit.position + (hit.normal as Vector3) * STEEP_SKIN, "grounded": false, "landed": false, "blocked": false, "normal": hit.normal, "slide": true}
	if walkable and float(hit.position.y) >= target.y - MIN_STEP_M:
		return {"position": hit.position, "grounded": true, "landed": true, "blocked": false, "normal": hit.normal}
	return {"position": target, "grounded": false, "landed": false, "blocked": false, "normal": Vector3.UP}


## The wall met on the way from `from` to `to` at waist height ({} when clear).
static func _cast_wall(s: Infantry, from: Vector3, to: Vector3, moving: bool) -> Dictionary:
	var along := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if not moving or along.length() < MIN_STEP_M:
		return {}
	var reach := along.normalized() * float(s.armor.get("capsule_radius", 0.6))
	var lift := Vector3.UP * WALL_HEIGHT
	var hit := _cast(s, from + lift, to + lift + reach)
	if hit.is_empty() or (hit.normal as Vector3).y >= WALL_NORMAL_Y:
		return {}
	return hit


## What move_and_slide + InfantryMotion.apply_fall_damage do on touching down: the speed along the surface normal hurts.
static func _apply_landing(s: Infantry, before: Vector3, normal: Vector3) -> void:
	if before.length() <= float(s.armor.get("fall_min_speed", INF)):
		return
	InfantryMotion.apply_impact_damage(s, -before.dot(normal))


## First hit of a ray from `from` to `to`, passing through unit bodies (soldiers and vehicles); {} when none.
static func _cast(s: Infantry, from: Vector3, to: Vector3) -> Dictionary:
	if _query == null:
		_query = PhysicsRayQueryParameters3D.new()
	_query.from = from
	_query.to = to
	_exclude.clear()
	_exclude.append(s.get_rid())
	var space := s.get_world_3d().direct_space_state
	for skip in MAX_UNIT_SKIPS:
		_query.exclude = _exclude
		var hit := space.intersect_ray(_query)
		if hit.is_empty() or not (hit.collider is CharacterBody3D):
			return hit
		_exclude.append(hit.rid)
	return {}
