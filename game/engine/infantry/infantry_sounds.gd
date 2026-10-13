class_name InfantrySounds
extends RefCounted
## A soldier's own sounds (Infantry), named by the armour (InfantryCatalog "sounds"):
##   footsteps  one per foot trigger of the move cycle being played (InfantryAnimation.footsteps: the originals'
##              Player plays the left / right foot sound on the animation's foot triggers 1 / 2): Tribes 1
##              l/rFootSounds, Tribes 2 L/RFootSoftSound on terrain and L/RFootHardSound elsewhere (interiors);
##              heard as the original's sound profile (footstep_range: T1 Profile3dFoot 2-30 m, T2
##              AudioClosest3d 5-30 m, hard AudioClose3d 10-60 m) at the profile's full volume. A body without
##              foot triggers steps every FALLBACK_STEP_LENGTH metres.
##   jet        the jetpack loop while jetting.

## Metres walked per footstep when the move cycle has no foot triggers (remake stand-in).
const FALLBACK_STEP_LENGTH := 2.6
## The originals' profiles play at volume 1.0 (T2 AudioDescription volume, T1 baseVolume 0): no extra gain.
const FOOTSTEP_DB := 0.0
const DEFAULT_RANGE := Vector2(5.0, 30.0)
const JET_LOOP_DB := -10.0

var _jet_loop: AudioStreamPlayer3D
var _step_left := FALLBACK_STEP_LENGTH
var _next_foot := InfantryAnimation.LEFT_FOOT


## Plays the footsteps of this frame: the foot triggers `animation` crossed in its last update, else (no triggers
## in the body's cycles) one every FALLBACK_STEP_LENGTH metres walked.
func apply_steps(soldier: Infantry, animation: InfantryAnimation, delta: float) -> void:
	if animation.airborne or soldier.stowed:
		return
	if animation.has_foot_triggers():
		for foot in animation.footsteps:
			_play_footstep(soldier, foot)
		return
	_step_left -= Vector2(animation.local_velocity.x, animation.local_velocity.z).length() * delta
	if _step_left <= 0.0:
		_step_left = FALLBACK_STEP_LENGTH
		_play_footstep(soldier, _next_foot)
		_next_foot = InfantryAnimation.RIGHT_FOOT if _next_foot == InfantryAnimation.LEFT_FOOT else InfantryAnimation.LEFT_FOOT


## Starts or stops the jet loop to match the soldier's `jetting`.
func apply_jet(soldier: Infantry) -> void:
	if soldier.jetting and _jet_loop == null:
		_jet_loop = Sfx.attach_loop(str(soldier.armor.get("sounds", {}).get("jet", "")), soldier, JET_LOOP_DB)
	elif not soldier.jetting and _jet_loop != null:
		_jet_loop.queue_free()
		_jet_loop = null


## The footstep sound of `foot` on the surface the soldier stands on: {stem, range}.
static func make_footstep(sounds: Dictionary, foot: int, hard: bool) -> Dictionary:
	var side := "left" if foot == InfantryAnimation.LEFT_FOOT else "right"
	var key := "footstep_hard_%s" % side if hard else "footstep_%s" % side
	var stem := str(sounds.get(key, sounds.get("footstep_" + side, sounds.get("footstep", ""))))
	var r: Array = sounds.get("footstep_hard_range" if hard else "footstep_range", [])
	return {"stem": stem, "range": Vector2(float(r[0]), float(r[1])) if r.size() == 2 else DEFAULT_RANGE}


static func _play_footstep(soldier: Infantry, foot: int) -> void:
	var step := make_footstep(soldier.armor.get("sounds", {}), foot, is_on_hard_floor(soldier))
	if str(step.stem) != "":
		Sfx.play_at_range(str(step.stem), soldier.global_position, FOOTSTEP_DB, step.range)


## True when the soldier stands on something other than terrain (an interior or a shape: the hard footsteps).
static func is_on_hard_floor(soldier: Infantry) -> bool:
	for i in soldier.get_slide_collision_count():
		var c := soldier.get_slide_collision(i)
		if c.get_normal().y > 0.5:
			return not _is_terrain(c.get_collider())
	return false


static func _is_terrain(body: Object) -> bool:
	var node := body as Node
	if node == null:
		return true
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is HeightMapShape3D:
			return true
	return false
