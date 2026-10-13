extends RefCounted
## Procedural death collapse of a walker whose pack has no death sequence (remake addition: Starsiege
## Hercs keep their last pose when destroyed, docs/formats/animation.md). Over DURATION the legs fold
## toward one of the shape's own crouch poses (Starsiege squat / landing: pelvis low, knees bent), each node
## by a critically damped approach that starts later the deeper it hangs, while the whole body pitches
## forward and rolls toward the ground; the lowest point stays on the ground it stood on. The crouch and
## the forward pitch are the pair that leaves the body lowest: a Herc with long forward guns would otherwise
## stand on its muzzles with its legs in the air.
## Every pose is a function of the seconds since the kill, so a puppet replays the same collapse.

const DURATION := 1.5
## Crouch poses the legs may fold into: [Darkstar sequence name suffix, cycle phase] (Starsiege Seq04_squat,
## and Seq10_land early in the landing, knees deep in the absorb).
const CROUCH_POSES := [["squat", 0.0], ["land", 0.2], ["land", 0.35]]
## How far past a crouch pose (measured from the stand pose) the knees may give way: short-legged Hercs
## (Olympian, Gorgon) barely sink in their authored crouch.
const CROUCH_DEPTHS: Array[float] = [1.0, 1.35, 1.7]
const STAND_SEQUENCE := "stand"
const FALL_PITCHES: Array[float] = [deg_to_rad(15.0), deg_to_rad(30.0), deg_to_rad(45.0)]
const FALL_ROLL := deg_to_rad(12.0)
## Time constant (s) of a hip's fold; each hierarchy level further down is FOLD_STAGGER slower.
const FOLD_TIME_CONSTANT := 0.16
const FOLD_STAGGER := 0.3
## Time constant (s) of the body's fall (slower than the legs: the knees give way first).
const FALL_TIME_CONSTANT := 0.32
const NO_PARENT := -1
const PoseBlend := preload("res://engine/pose_blend.gd")

var shape: ShapeInstance
var _from := {}
var _crouch := {}
var _roots: Array[int] = []
var _ground_y := 0.0
var _pitch := 0.0


func _init(inst: ShapeInstance) -> void:
	shape = inst
	var nodes: Array = inst.shape.get("nodes", [])
	for i in nodes.size():
		if int(nodes[i].parent) == NO_PARENT:
			_roots.append(i)


## Starts the collapse from the pose the walker shows now (legs and torso twist).
func begin() -> void:
	_from = PoseBlend.make_capture(shape, range(shape.nodes.size()))
	_ground_y = shape.lowest_point()
	_choose_lowest_fall(_make_crouches())
	PoseBlend.apply(shape, _from)


## Poses the collapse `seconds` after the kill (held from DURATION on).
func apply(seconds: float) -> void:
	var t := clampf(seconds, 0.0, DURATION)
	var folded := {}
	for i in _crouch:
		var from: Transform3D = _from[i]
		folded[i] = from.interpolate_with(_crouch[i], make_progress(t, _fold_time_constant(i)))
	PoseBlend.apply(shape, folded)
	var fall := make_progress(t, FALL_TIME_CONSTANT)
	var tilt := Transform3D(Basis.from_euler(Vector3(-_pitch * fall, 0.0, FALL_ROLL * fall)), Vector3.ZERO)
	for r in _roots:
		shape.nodes[r].transform = tilt * (_from[r] as Transform3D)
	var lift := _ground_y - shape.lowest_point()
	for r in _roots:
		shape.nodes[r].position.y += lift


## The shape's crouch poses at each depth (roots excluded: they carry the fall); one empty pose when it
## has none. Poses the instance.
func _make_crouches() -> Array:
	var stand := PoseBlend.make_sample(shape, ShapeCycles.find(shape, STAND_SEQUENCE), 0.0)
	var out := []
	for c in CROUCH_POSES:
		var index := ShapeCycles.find(shape, c[0])
		if index < 0:
			continue
		var pose := PoseBlend.make_sample(shape, index, float(c[1]), false)
		for r in _roots:
			pose.erase(r)
		var base := {}
		for i in pose:
			base[i] = stand.get(i, PoseBlend.default_transform(shape, i))
		for depth in CROUCH_DEPTHS:
			out.append(PoseBlend.make_mix(shape, base, pose, depth))
	return out if not out.is_empty() else [{}]


## Settles every crouch x pitch candidate and keeps the one that leaves the body lowest.
func _choose_lowest_fall(crouches: Array) -> void:
	var lowest := INF
	var best := [crouches[0], FALL_PITCHES[0]]
	for crouch in crouches:
		for pitch in FALL_PITCHES:
			PoseBlend.apply(shape, _from)
			_crouch = crouch
			_pitch = pitch
			apply(DURATION)
			var height := make_body_height(shape)
			if height < lowest:
				lowest = height
				best = [crouch, pitch]
	_crouch = best[0]
	_pitch = best[1]


## Mean height of the visible meshes' centres in the instance's space (where the body's bulk is).
static func make_body_height(inst: ShapeInstance) -> float:
	var to_local := inst.global_transform.affine_inverse()
	var sum := 0.0
	var count := 0
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if mi.is_visible_in_tree():
			sum += (to_local * mi.global_transform * (mi as MeshInstance3D).mesh.get_aabb().get_center()).y
			count += 1
	return sum / maxi(count, 1)


## 0..1 progress of a critically damped approach with time constant `tau`, scaled to reach 1 at DURATION
## (no snap when the collapse is held).
static func make_progress(t: float, tau: float) -> float:
	return clampf(_damped(t, tau) / _damped(DURATION, tau), 0.0, 1.0)


static func _damped(t: float, tau: float) -> float:
	return 1.0 - (1.0 + t / tau) * exp(-t / tau)


func _fold_time_constant(i: int) -> float:
	return FOLD_TIME_CONSTANT * (1.0 + FOLD_STAGGER * _depth(i))


func _depth(i: int) -> int:
	var depth := 0
	var p := int(shape.shape.nodes[i].parent)
	while p != NO_PARENT:
		depth += 1
		p = int(shape.shape.nodes[p].parent)
	return depth
