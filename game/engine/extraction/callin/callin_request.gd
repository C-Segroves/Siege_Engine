class_name CallinRequest
extends RefCounted
## One call-in asked for, as a value (docs/design/lobby_loadout_economy.md section 9.3): what kind, who asks, WHERE, and
## for the kinds that fly a line (a bombing run) which way. Every way of asking makes one of these: the Targeting Laser
## designation (source "laser": the player painted the point) and the command map ordering (source "map": he clicked it).
## The host's CallinDirector validates it (CallinChecks) and hands it to the runner of its kind; a runner never picks a point
## of its own. It travels over the network as plain values (`make_args` / `from_args`).

const SOURCE_LASER := "laser"
const SOURCE_MAP := "map"
const SOURCES := [SOURCE_LASER, SOURCE_MAP]
## A direction shorter than this (flat, metres of the second click) counts as "none given".
const MIN_DIRECTION_M := 4.0

var kind := ""
## The armour size of an armour drop ("" otherwise).
var variant := ""
## The caller's peer id (the host fills it from the sender of the message).
var peer := 0
## The designated point (the spot painted on, or the map point; the host puts it on the floor).
var point := Vector3.ZERO
## The line a directional kind flies along (flat); zero = the way the caller faces.
var direction := Vector3.ZERO
var source := SOURCE_LASER


static func make(p_kind: String, p_variant: String, p_peer: int, p_point: Vector3, p_direction := Vector3.ZERO,
		p_source := SOURCE_LASER) -> CallinRequest:
	var r := CallinRequest.new()
	r.kind = p_kind
	r.variant = p_variant
	r.peer = p_peer
	r.point = p_point
	r.direction = _flat(p_direction)
	r.source = p_source if p_source in SOURCES else SOURCE_LASER
	return r


## The request of a script or a test: the ground `ahead` metres in front of `soldier` (his own spot is taken by him), no direction.
static func make_at_feet(p_kind: String, p_variant: String, p_peer: int, soldier: Node3D, ahead := 0.0) -> CallinRequest:
	if soldier == null:
		return make(p_kind, p_variant, p_peer, Vector3.ZERO)
	var facing := Vector3(-soldier.global_basis.z.x, 0.0, -soldier.global_basis.z.z).normalized()
	return make(p_kind, p_variant, p_peer, soldier.global_position + facing * ahead)


## The values that go to the host (the sender is the caller): kind, variant, point, direction, source.
func make_args() -> Array:
	return [kind, variant, point, direction, source]


## The request `p_peer` sent as `args` (make_args). Anything off in them is made harmless.
static func from_args(p_peer: int, args: Array) -> CallinRequest:
	if args.size() < 5 or not (args[2] is Vector3) or not (args[3] is Vector3):
		return make("", "", p_peer, Vector3.ZERO)
	return make(str(args[0]), str(args[1]), p_peer, args[2], args[3], str(args[4]))


## True when the caller gave a direction of his own.
func has_direction() -> bool:
	return direction.length() > 0.0


## The line to fly along: the one given, else the way `facing` points (flat), else north.
func make_direction(facing: Vector3) -> Vector3:
	if has_direction():
		return direction
	var flat := _flat(facing)
	return flat if flat.length() > 0.0 else Vector3.FORWARD


## The direction from the first click `point` to a second click `second`: zero when the two are too close to mean one.
static func make_direction_between(from: Vector3, second: Vector3) -> Vector3:
	var gap := Vector2(second.x - from.x, second.z - from.z)
	return _flat(second - from) if gap.length() >= MIN_DIRECTION_M else Vector3.ZERO


## A one-line text for logs and tests.
func make_text() -> String:
	return "%s%s by %d at (%.0f, %.0f, %.0f) via %s%s" % [kind, " " + variant if variant != "" else "", peer, point.x, point.y,
		point.z, source, " dir (%.2f, %.2f)" % [direction.x, direction.z] if has_direction() else ""]


static func _flat(v: Vector3) -> Vector3:
	var f := Vector3(v.x, 0.0, v.z)
	return f.normalized() if f.length() > 0.001 else Vector3.ZERO
