class_name HercAnimator
extends RefCounted
## Leg animation of a walking vehicle (Herc / Cybrid) for every pack: stand, walk, run, fast run,
## turn in place and death, driven by ground speed so the feet do not skate.
##
## The original games move a Herc by the ground displacement its walk/run sequence authors per cycle
## (ES1/ES2 node 0, Battledrome seq 0/2 node 0, Starsiege the "bounds" node), so the cycle phase advances
## by distance / stride. The vehicle def's "anim" record (PackVehicleLoader, per pack) names the
## sequences and switch speeds; docs/formats/animation.md has the per-pack evidence.
##
## Remake additions (the originals snap): a change of clip (stand / walk / run / fast run / turn, and into
## a death sequence) cross-fades over a short window (PoseBlend), and a walker without a death sequence
## collapses procedurally (WalkerCollapse). Outside a cross-fade every pose is the original sequence pose.
##
## anim keys: walk, run, fast_run, stand, turn, fast_turn, death (3Space index or Darkstar name suffix),
## run_switch_speed / fast_run_speed (m/s), run_switch_rate (fraction of the authored walk speed),
## fast_turn_rate (rad/s), tick_seconds (3Space tick at rate 256), death_rate (fraction of rate 256).

signal footstep

## Below this ground speed (m/s) the legs stand (or turn in place).
const MOVE_EPS := 0.05
## Below this yaw rate (rad/s) a standing Herc does not step around.
const TURN_EPS := 0.05
## Without a catalog switch speed the run starts at this fraction of top speed.
const RUN_SWITCH_FRACTION := 0.6
## Stride from the ES "m/s per speed unit" factors: speed 256 = authored rate, 1 tick = tick_ms.
const ANIM_TICK_SCALE := 0.256
## Rate 256 = authored speed (3Space anim rates).
const RATE_UNITS := 256.0
const DEFAULT_TICK_SECONDS := 0.001
const NO_SEQUENCE := -1
## Cross-fade (s) between stand / walk / run / fast run / turn in place.
const TRANSITION_SECONDS := 0.3
## Cross-fade (s) from the last leg pose into a death sequence.
const DEATH_BLEND_SECONDS := 0.2
## What a clip plays at: a fixed pose, the gait phase or the turn phase.
enum Clip { STAND, GAIT, TURN }
const PoseBlend := preload("res://engine/pose_blend.gd")
const WalkerCollapse := preload("res://engine/walker_collapse.gd")

var shape: ShapeInstance
## Gait cycle position (cycles walked; negative = backwards). Shared by walk/run like the original, so a
## walk <-> run cross-fade keeps both cycles in step.
var gait_phase := 0.0
## Turn-in-place cycle position.
var turn_phase := 0.0
var walk_seq := NO_SEQUENCE
var run_seq := NO_SEQUENCE
var fast_run_seq := NO_SEQUENCE
var stand_seq := NO_SEQUENCE
var turn_seq := NO_SEQUENCE
var fast_turn_seq := NO_SEQUENCE
var death_seq := NO_SEQUENCE
## Ground metres per cycle by sequence index.
var strides := {}
## Yaw (rad, + = left) per turn cycle by sequence index.
var turn_angles := {}
var run_switch_speed := INF
var fast_run_speed := INF
var fast_turn_rate := INF
var death_seconds_per_cycle := 0.0
## Cross-fade length (s); 0 snaps between clips like the original games.
var transition_seconds := TRANSITION_SECONDS

## Clip shown: Vector2i(Clip, sequence index).
var _active := Vector2i(Clip.STAND, NO_SEQUENCE)
var _active_nodes := {}
## Outgoing clip of a cross-fade, played on at its own phase ...
var _from := Vector2i(Clip.STAND, NO_SEQUENCE)
var _from_nodes := {}
## ... or the pose frozen when a new switch interrupts a cross-fade (then not empty).
var _from_pose := {}
var _blend_elapsed := INF
var _last_mix := {}
var _dying := false
var _death_from := {}
## Procedural collapse of a walker whose pack has no death sequence (null otherwise).
var _collapse: WalkerCollapse


## `def` = vehicle definition (Packs.vehicle), `inst` = its built model, `max_speed` for the default switch.
func _init(def: Dictionary, inst: ShapeInstance, max_speed := 0.0) -> void:
	shape = inst
	var anim: Dictionary = def.get("anim", {})
	_resolve_sequences(anim)
	_measure_strides(def, anim)
	_resolve_switches(def, anim, max_speed)
	if death_seq == NO_SEQUENCE and has_gait():
		_collapse = WalkerCollapse.new(inst)


func has_gait() -> bool:
	return walk_seq != NO_SEQUENCE


## True while two clips are cross-faded (the pose is not a single sequence's pose).
func is_blending() -> bool:
	return _blend_elapsed < transition_seconds


## True when the pose applied this frame wrote node `i` (the torso twist then builds on that pose).
func animates(i: int) -> bool:
	return _active_nodes.has(i) or (is_blending() and _from_nodes.has(i))


## Legs for this frame: `speed` signed m/s, `yaw_delta` rad turned this frame (+ = left).
func update(speed: float, yaw_delta: float, delta: float) -> void:
	if not has_gait():
		return
	var rate := yaw_delta / delta if delta > 0.0 else 0.0
	if absf(speed) > MOVE_EPS:
		_advance_gait(speed, delta)
		_play(Vector2i(Clip.GAIT, gait_for(absf(speed))), delta)
	elif absf(rate) > TURN_EPS and turn_seq != NO_SEQUENCE:
		_advance_turn(yaw_delta, rate)
		_play(Vector2i(Clip.TURN, turn_for(rate)), delta)
	else:
		_play(Vector2i(Clip.STAND, stand_seq), delta)


## Standing pose at once (hangar idle, a respawn): no cross-fade; nodes the stand sequence does not
## pose return to their default, as a cross-fade into the stand leaves them.
func apply_stand() -> void:
	shape.reset_pose()
	_dying = false
	gait_phase = 0.0
	turn_phase = 0.0
	_blend_elapsed = INF
	_set_active(Vector2i(Clip.STAND, stand_seq))
	_apply_clip(_active)


## Death collapse `seconds` after the kill (held on its last frame): the pack's death sequence,
## cross-faded in from the last leg pose, or the procedural collapse.
func apply_death(seconds: float) -> void:
	if not _dying:
		_begin_death()
	if _collapse != null:
		_collapse.apply(seconds)
		return
	if death_seconds_per_cycle <= 0.0:
		return
	var pose := PoseBlend.make_sample(shape, death_seq, seconds / death_seconds_per_cycle, false)
	if seconds < DEATH_BLEND_SECONDS:
		pose = PoseBlend.make_mix(shape, _death_from, pose, PoseBlend.make_weight(seconds / DEATH_BLEND_SECONDS))
	PoseBlend.apply(shape, pose)


## Walk/run/fast-run sequence for ground speed `s` (m/s).
func gait_for(s: float) -> int:
	if fast_run_seq != NO_SEQUENCE and s > fast_run_speed:
		return fast_run_seq
	if run_seq != NO_SEQUENCE and s > run_switch_speed:
		return run_seq
	return walk_seq


## Turn-in-place sequence for yaw rate `rate` (rad/s).
func turn_for(rate: float) -> int:
	if fast_turn_seq != NO_SEQUENCE and absf(rate) > fast_turn_rate:
		return fast_turn_seq
	return turn_seq


# ------------------------------------------------------------------ per frame

## Cycle by ground covered (one step sound per half cycle).
func _advance_gait(speed: float, delta: float) -> void:
	var s := absf(speed)
	var before := floorf(gait_phase * 2.0)
	gait_phase += signf(speed) * s * delta / float(strides[gait_for(s)])
	_emit_steps(before, gait_phase)


## Stepping round on the spot, one cycle per authored turn angle.
func _advance_turn(yaw_delta: float, rate: float) -> void:
	var before := floorf(turn_phase * 2.0)
	turn_phase += yaw_delta / float(turn_angles[turn_for(rate)])
	_emit_steps(before, turn_phase)


func _emit_steps(before: float, phase: float) -> void:
	if floorf(phase * 2.0) != before:
		footstep.emit()


## Shows `clip`, cross-fading from the previous one after a switch.
func _play(clip: Vector2i, delta: float) -> void:
	if clip != _active:
		_begin_transition(clip)
	_blend_elapsed += delta
	if is_blending():
		_apply_mix()
	else:
		_apply_clip(_active)


## The outgoing clip plays on during the cross-fade; a switch during a cross-fade fades from the
## pose shown last instead.
func _begin_transition(clip: Vector2i) -> void:
	if is_blending():
		_from_pose = _last_mix
		_from_nodes = _last_mix
		_from = Vector2i(Clip.STAND, NO_SEQUENCE)
	else:
		_from_pose = {}
		_from_nodes = _active_nodes
		_from = _active
	_blend_elapsed = 0.0
	_set_active(clip)


func _apply_mix() -> void:
	var from := _from_pose if not _from_pose.is_empty() else _sample(_from)
	var weight := PoseBlend.make_weight(_blend_elapsed / transition_seconds)
	_last_mix = PoseBlend.make_mix(shape, from, _sample(_active), weight)
	PoseBlend.apply(shape, _last_mix)


func _apply_clip(clip: Vector2i) -> void:
	if clip.y == NO_SEQUENCE:
		shape.reset_pose()
	else:
		ShapeCycles.pose(shape, clip.y, _phase_of(clip))


func _sample(clip: Vector2i) -> Dictionary:
	return PoseBlend.make_sample(shape, clip.y, _phase_of(clip))


func _phase_of(clip: Vector2i) -> float:
	match clip.x:
		Clip.GAIT:
			return gait_phase
		Clip.TURN:
			return turn_phase
	return 0.0


func _set_active(clip: Vector2i) -> void:
	_active = clip
	_active_nodes = ShapeCycles.animated_nodes(shape, clip.y)


func _begin_death() -> void:
	_dying = true
	_blend_elapsed = INF
	if _collapse != null:
		_collapse.begin()
		return
	var nodes := PoseBlend.make_union(_active_nodes, ShapeCycles.animated_nodes(shape, death_seq))
	_death_from = PoseBlend.make_capture(shape, nodes)
	_set_active(Vector2i(Clip.STAND, death_seq))


# ------------------------------------------------------------------ setup

func _resolve_sequences(anim: Dictionary) -> void:
	walk_seq = ShapeCycles.find(shape, anim.get("walk"))
	run_seq = ShapeCycles.find(shape, anim.get("run"))
	fast_run_seq = ShapeCycles.find(shape, anim.get("fast_run"))
	stand_seq = ShapeCycles.find(shape, anim.get("stand"))
	turn_seq = ShapeCycles.find(shape, anim.get("turn"))
	fast_turn_seq = ShapeCycles.find(shape, anim.get("fast_turn"))
	death_seq = ShapeCycles.find(shape, anim.get("death"))


## Strides from the ES speed factors when the catalog has them (ES1/ES2: unchanged original maths),
## else from the sequences' own ground motion. Gaits without forward motion are dropped.
func _measure_strides(def: Dictionary, anim: Dictionary) -> void:
	var tick := ANIM_TICK_SCALE * float(def.get("anim_tick_ms", 1.0))
	var factors := {walk_seq: float(def.get("walk_factor", 0.0)), run_seq: float(def.get("run_factor", 0.0))}
	for seq in [walk_seq, run_seq, fast_run_seq]:
		if seq == NO_SEQUENCE or strides.has(seq):
			continue
		var factor: float = factors.get(seq, 0.0)
		strides[seq] = factor * shape.sequence_ticks(seq) * tick if factor > 0.0 else absf(ShapeCycles.ground_motion(shape, seq).x)
	run_seq = run_seq if float(strides.get(run_seq, 0.0)) > 0.0 else NO_SEQUENCE
	fast_run_seq = fast_run_seq if float(strides.get(fast_run_seq, 0.0)) > 0.0 else NO_SEQUENCE
	walk_seq = walk_seq if float(strides.get(walk_seq, 0.0)) > 0.0 else NO_SEQUENCE
	for seq in [turn_seq, fast_turn_seq]:
		if seq != NO_SEQUENCE:
			turn_angles[seq] = ShapeCycles.ground_motion(shape, seq).y
	turn_seq = turn_seq if absf(float(turn_angles.get(turn_seq, 0.0))) > 0.0 else NO_SEQUENCE
	fast_turn_seq = fast_turn_seq if absf(float(turn_angles.get(fast_turn_seq, 0.0))) > 0.0 else NO_SEQUENCE
	var tick_seconds := float(anim.get("tick_seconds", DEFAULT_TICK_SECONDS))
	var death_rate := float(anim.get("death_rate", 1.0))
	death_seconds_per_cycle = ShapeCycles.cycle_seconds(shape, death_seq, tick_seconds) / maxf(death_rate, 0.001)


func _resolve_switches(def: Dictionary, anim: Dictionary, max_speed: float) -> void:
	if anim.has("run_switch_rate") and walk_seq != NO_SEQUENCE:
		var walk_cycle := ShapeCycles.cycle_seconds(shape, walk_seq, float(anim.get("tick_seconds", DEFAULT_TICK_SECONDS)))
		run_switch_speed = float(strides[walk_seq]) / maxf(walk_cycle, 0.001) * float(anim.run_switch_rate)
	else:
		run_switch_speed = float(anim.get("run_switch_speed", def.get("run_switch_speed", max_speed * RUN_SWITCH_FRACTION)))
	fast_run_speed = float(anim.get("fast_run_speed", INF))
	fast_turn_rate = float(anim.get("fast_turn_rate", INF))
