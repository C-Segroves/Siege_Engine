extends Node
## Headless check of the walking animation of every walker (Herc / Cybrid) of every pack
## (engine/herc_animator.gd, docs/formats/animation.md):
##   1. every walker has a walk sequence with forward ground motion (no sliding statue);
##   2. walking at its top speed and at a slow walk moves the leg nodes over time;
##   3. stride sync: the planted (lowest) foot mesh slips less than SLIP_LIMIT of the body's travel;
##   4. standing still is a fixed pose; turning on the spot steps when the pack has a turn sequence;
##   5. Earthsiege 1 regression: strides and poses equal the pre-animator maths (factor x ticks) outside
##      the cross-fades;
##   6. every played sequence (walk, run, fast run, stand, turn, death): a pose sampled at a keyframe is
##      that keyframe, and between keyframes no node turns faster than the keyframes it blends (no flips);
##   7. the torso twist / pitch nodes carry no foot (Pitbull/Bulldog twisted a front hip, pitched a thigh);
##   8. clip changes (stand -> walk -> run -> fast run -> stop -> turn) cross-fade: no node jumps more per
##      frame than TRANSITION_MAX_STEP (snapping, the originals' behaviour, is reported for comparison);
##   9. walkers without a death sequence (Starsiege) collapse procedurally: the body sinks to the ground,
##      stays on it, turns no node faster than COLLAPSE_MAX_STEP per frame, never tips past upright + fall.
##   godot --headless --audio-driver Dummy --path game res://tests/animation_check.tscn

const TorsoRig := preload("res://engine/torso_rig.gd")
const WalkerCollapseScript := preload("res://engine/walker_collapse.gd")
const PoseBlend := preload("res://engine/pose_blend.gd")

const FPS := 30.0
const WALK_SECONDS := 3.0
## Leg nodes must move at least this much (m, shape space) while walking.
const MIN_LEG_MOTION := 0.05
## Stride sync: |1 - planted foot's backward travel / body travel| (a sliding statue scores 1.0, legs at
## double speed 1.0 too, a reversed cycle 2.0). Run cycles have flight phases, so it is measured on the
## walk. Per pack the median slow-walk slip must stay under SLIP_LIMIT (single shapes vary with the
## authored gait, e.g. the original ES1/ES2 Colossus), no Herc may walk backwards (REVERSED_SLIP).
const SLIP_LIMIT := 0.35
const REVERSED_SLIP := 1.5
## Gait stride vs the sequence's own ground motion per cycle.
const STRIDE_TOLERANCE := 0.01
const SLOW_WALK_FRACTION := 0.15
const WALK_SWITCH_FRACTION := 0.8
const WALK_TOP_FRACTION := 0.5
## Sole meshes: within this height (m) of the lowest point in the standing pose.
const FOOT_BAND := 0.4
const TURN_RATE := 0.6
## Old Herc maths (ES1 regression): ticks per second at rate 256 per anim ms.
const OLD_TICK_SCALE := 0.256
const OLD_WALK_SEQ := 1
const OLD_RUN_SEQ := 2
const OLD_RUN_FRACTION := 0.6
const POSE_TOLERANCE := 0.0001
## Samples between two 3Space keyframes / per Darkstar cycle for the flip check.
const SAMPLES_PER_KEY := 8
const DARKSTAR_SAMPLES := 256
## Slerp: each sample turns its share of the keyframe step (5% + 0.1 deg slack); a long-way or Euler-wrap
## blend turns more. Darkstar keys are dense: no sample may turn more than DARKSTAR_MAX_STEP (rad).
const STEP_SLACK := 1.05
const STEP_EPS := 0.002
const DARKSTAR_MAX_STEP := 0.35
## Transition profile (frames at TRANSITION_FPS): the largest per-frame change of any mesh node's local
## transform (rad / shape-space m) while clips switch and cross-fade.
const TRANSITION_FPS := 60.0
const TRANSITION_MAX_STEP := 0.35
## ... or the sequences' own largest step (fast runs) times this.
const STEADY_SLACK := 1.2
## Procedural collapse: sampled at FPS for COLLAPSE_SECONDS after a kill mid-stride.
const COLLAPSE_SECONDS := 2.0
const COLLAPSE_MAX_STEP := 0.3
## The collapsed body (mean height of its mesh centres) must end lower than standing, and it or the top of
## the model below this fraction of the standing height ...
const COLLAPSE_SINK_FRACTION := 0.9
## ... with its lowest point on the ground it stood on (fraction of the standing height).
const GROUND_TOLERANCE := 0.005
## Root tilt allowed beyond the fall angle before it counts as a flip (rad).
const TILT_SLACK := 0.05

var _failures := 0
var _summary := []
var _pack_slips := {}


func _ready() -> void:
	var walkers := _walkers()
	_expect(walkers.size() > 0, "walkers in the catalog: %d" % walkers.size())
	for v in walkers:
		_check_walker(v)
	for pack in _pack_slips:
		var slips: Array = _pack_slips[pack]
		slips.sort()
		var median: float = slips[slips.size() / 2]
		_expect(median < SLIP_LIMIT, "%s median slow-walk foot slip %.2f" % [pack, median])
		_summary.append("  %s: median slow-walk foot slip %.2f over %d walkers" % [pack, median, slips.size()])
	for v in walkers:
		if str(v.pack) == "es1":
			_check_es1_unchanged(v)
	for line in _summary:
		print(line)
	print("animation_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


## Legged vehicles: category herc, not a flyer, kind herc (engine schema) or a 3Space walker.
func _walkers() -> Array:
	var out := []
	for id in Packs.vehicles:
		var v: Dictionary = Packs.vehicles[id]
		if str(v.get("category", "")) != "herc" or bool(v.get("flyer", false)):
			continue
		if str(v.get("kind", "herc")) != "herc":
			continue
		out.append(v)
	return out


func _build(v: Dictionary) -> ShapeInstance:
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	return inst


func _check_walker(v: Dictionary) -> void:
	var inst := _build(v)
	var anim := HercAnimator.new(v, inst, float(v.max_speed))
	_expect(anim.has_gait(), "%s has a walk sequence with ground motion" % v.id)
	if not anim.has_gait():
		inst.free()
		return
	var top := _walk(inst, anim, float(v.max_speed))
	var walk_speed := minf(anim.run_switch_speed * WALK_SWITCH_FRACTION, float(v.max_speed) * WALK_TOP_FRACTION)
	var walk := _walk(inst, anim, walk_speed)
	var slow := _walk(inst, anim, float(v.max_speed) * SLOW_WALK_FRACTION)
	_expect(top.motion > MIN_LEG_MOTION, "%s legs move at top speed (%.2f m)" % [v.id, top.motion])
	_expect(slow.motion > MIN_LEG_MOTION, "%s legs move at a slow walk (%.2f m)" % [v.id, slow.motion])
	_expect(walk.slip < REVERSED_SLIP and slow.slip < REVERSED_SLIP,
		"%s feet move backwards under the body: slip %.2f / %.2f (walk / slow)" % [v.id, walk.slip, slow.slip])
	_expect_stride_is_authored(v, inst, anim)
	_pack_slips[v.pack] = _pack_slips.get(v.pack, []) + [slow.slip]
	_expect(_stands_still(inst, anim), "%s standing pose is fixed" % v.id)
	var turns := anim.turn_seq != HercAnimator.NO_SEQUENCE
	if turns:
		_expect(_turn_motion(inst, anim) > MIN_LEG_MOTION, "%s steps when turning on the spot" % v.id)
	_check_sequences(v, inst, anim)
	_check_torso_nodes(v, inst, anim)
	_check_transitions(v, inst, anim)
	if anim.death_seq == HercAnimator.NO_SEQUENCE:
		_check_collapse(v, inst, anim)
	_summary.append("  %-22s walk %d run %d frun %d turn %d death %d  stride %.2f/%.2f m  switch %.1f m/s  slip %.2f/%.2f" % [
		v.id, anim.walk_seq, anim.run_seq, anim.fast_run_seq, anim.turn_seq, anim.death_seq,
		anim.strides[anim.walk_seq], anim.strides.get(anim.run_seq, 0.0), anim.run_switch_speed, walk.slip, slow.slip])
	inst.free()


## Walks `seconds` at `speed`: {motion: largest node travel in shape space, slip: planted foot slip ratio}.
func _walk(inst: ShapeInstance, anim: HercAnimator, speed: float) -> Dictionary:
	anim.apply_stand()
	var start := _node_positions(inst)
	var contacts := _foot_contacts(inst)
	var motion := 0.0
	var body := 0.0
	var planted_body := 0.0
	var foot_back := 0.0
	var prev := {}
	for f in int(WALK_SECONDS * FPS):
		anim.update(speed, 0.0, 1.0 / FPS)
		body += speed / FPS
		var foot := _planted(inst, contacts)
		if anim.is_blending():
			foot = {}
		elif not prev.is_empty() and prev.index == foot.index:
			foot_back += foot.point.z - prev.point.z    # shape space: forward = -z
			planted_body += speed / FPS
		prev = foot
		var now := _node_positions(inst)
		for i in now.size():
			motion = maxf(motion, now[i].distance_to(start[i]))
	return {"motion": motion, "slip": absf(1.0 - foot_back / maxf(planted_body, 0.001))}


## Sole points: each mesh reaching within FOOT_BAND of the ground in the standing pose, with its lowest
## vertex (mesh space) - a fixed point on the sole that a planted foot keeps still.
func _foot_contacts(inst: ShapeInstance) -> Array:
	var all := []
	var ground := INF
	var to_parent := inst.transform * inst.global_transform.affine_inverse()
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if not mi.visible:
			continue
		var low := _lowest_vertex(mi as MeshInstance3D, to_parent)
		all.append({"mesh": mi, "point": low.point, "y": low.y})
		ground = minf(ground, low.y)
	var feet := []
	for c in all:
		if c.y < ground + FOOT_BAND:
			feet.append(c)
	return feet


func _lowest_vertex(mi: MeshInstance3D, to_parent: Transform3D) -> Dictionary:
	var xf := to_parent * mi.global_transform
	var best := {"point": Vector3.ZERO, "y": INF}
	for si in mi.mesh.get_surface_count():
		for v in mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			var y: float = (xf * v).y
			if y < best.y:
				best = {"point": v, "y": y}
	return best


## The lowest sole point this frame: {index, point (instance parent space)}.
func _planted(inst: ShapeInstance, contacts: Array) -> Dictionary:
	var to_parent := inst.transform * inst.global_transform.affine_inverse()
	var best := {"index": -1, "point": Vector3(0, INF, 0)}
	for i in contacts.size():
		var p: Vector3 = (to_parent * contacts[i].mesh.global_transform) * contacts[i].point
		if p.y < best.point.y:
			best = {"index": i, "point": p}
	return best


## Every gait advances one cycle per authored ground motion (node 0 / Darkstar bounds), so the body
## moves exactly as far as the feet push.
func _expect_stride_is_authored(v: Dictionary, inst: ShapeInstance, anim: HercAnimator) -> void:
	for seq in anim.strides:
		if seq == HercAnimator.NO_SEQUENCE:
			continue
		var authored := absf(ShapeCycles.ground_motion(inst, seq).x)
		_expect(absf(float(anim.strides[seq]) - authored) <= authored * STRIDE_TOLERANCE,
			"%s seq %d stride %.3f m = authored ground motion %.3f m" % [v.id, seq, anim.strides[seq], authored])


func _stands_still(inst: ShapeInstance, anim: HercAnimator) -> bool:
	while true:
		anim.update(0.0, 0.0, 1.0 / FPS)
		if not anim.is_blending():
			break
	var a := _node_positions(inst)
	for f in 10:
		anim.update(0.0, 0.0, 1.0 / FPS)
	var b := _node_positions(inst)
	for i in a.size():
		if a[i].distance_to(b[i]) > POSE_TOLERANCE:
			return false
	return true


func _turn_motion(inst: ShapeInstance, anim: HercAnimator) -> float:
	anim.apply_stand()
	var start := _node_positions(inst)
	var motion := 0.0
	for f in int(FPS):
		anim.update(0.0, TURN_RATE / FPS, 1.0 / FPS)
		var now := _node_positions(inst)
		for i in now.size():
			motion = maxf(motion, now[i].distance_to(start[i]))
	return motion


## Node positions in the instance's parent space (metres).
func _node_positions(inst: ShapeInstance) -> Array:
	var out := []
	var to_local := inst.global_transform.affine_inverse()
	for n in inst.nodes:
		out.append(inst.transform * (to_local * n.global_position))
	return out


# ------------------------------------------------------------------ keyframes and flips

func _played_sequences(anim: HercAnimator) -> Array:
	var out := []
	for seq in [anim.walk_seq, anim.run_seq, anim.fast_run_seq, anim.stand_seq, anim.turn_seq, anim.fast_turn_seq,
			anim.death_seq]:
		if seq != HercAnimator.NO_SEQUENCE and not out.has(seq):
			out.append(seq)
	return out


func _check_sequences(v: Dictionary, inst: ShapeInstance, anim: HercAnimator) -> void:
	for seq in _played_sequences(anim):
		var wrap: bool = seq != anim.death_seq
		if ShapeCycles.is_darkstar(inst):
			_check_darkstar_sequence(v, inst, seq, wrap)
		else:
			_check_es_sequence(v, inst, seq, wrap)
	anim.apply_stand()


## 3Space: each keyframe exactly; each sample between keyframes a and b turns at most its share of a -> b.
func _check_es_sequence(v: Dictionary, inst: ShapeInstance, seq: int, wrap: bool) -> void:
	var data: Dictionary = inst.shape.sequences[seq]
	var parts: Array = data.parts
	var nframes: int = data.frames.size()
	var ticks := inst.sequence_ticks(seq)
	var key_err := 0.0
	var worst := {"excess": 0.0, "what": ""}
	var start := 0.0
	for fi in nframes:
		var length := float(data.frames[fi][0])
		var fj := (fi + 1) % nframes
		var last := fi == nframes - 1 and not wrap
		ShapeCycles.pose(inst, seq, start / ticks, wrap)
		var prev := _local_bases(inst, parts)
		for p in parts.size():
			var want := ShapeInstance.tf_to_transform(inst.shape.transforms[int(data.tf[fi * parts.size() + p])])
			key_err = maxf(key_err, _transform_error(inst.nodes[int(parts[p])].transform, want))
		for k in range(1, SAMPLES_PER_KEY + 1):
			if last:
				break
			ShapeCycles.pose(inst, seq, (start + length * k / SAMPLES_PER_KEY) / ticks, wrap)
			var now := _local_bases(inst, parts)
			for p in parts.size():
				var a := ShapeInstance.tf_to_transform(inst.shape.transforms[int(data.tf[fi * parts.size() + p])]).basis
				var b := ShapeInstance.tf_to_transform(inst.shape.transforms[int(data.tf[fj * parts.size() + p])]).basis
				var allowed := _turn_angle(a, b) / SAMPLES_PER_KEY * STEP_SLACK + STEP_EPS
				var excess := _turn_angle(prev[p], now[p]) - allowed
				if excess > worst.excess:
					worst = {"excess": excess, "what": "node %d frame %d sample %d" % [parts[p], fi, k]}
			prev = now
		start += length
	_expect(key_err < POSE_TOLERANCE, "%s seq %d keyframe poses equal the keyframes (max error %.6f)" % [v.id, seq, key_err])
	_expect(worst.excess <= 0.0, "%s seq %d no node flips between keyframes (%s turns %.3f rad too far)" % [
		v.id, seq, worst.what, worst.excess])


## Darkstar: every track key exactly at its position; no sample within the cycle turns more than
## DARKSTAR_MAX_STEP. The wrap is not sampled: some cycles end on another key than they start (Starsiege
## Seeker t45 calf 28 deg, Shepherd frun 23 deg), an authored snap the original shows too.
func _check_darkstar_sequence(v: Dictionary, inst: ShapeInstance, seq: int, wrap: bool) -> void:
	var tracks: Array = inst.shape.ds_sequences[seq].tracks
	var key_err := 0.0
	for track in tracks:
		var ni := int(track.node)
		if ni < 0 or ni >= inst.nodes.size() or not ShapeCycles.animated_nodes(inst, seq).has(ni):
			continue
		for key in track.keys:
			if float(key[0]) >= 1.0 and wrap:
				continue
			ShapeCycles.pose(inst, seq, float(key[0]), wrap)
			var want := ShapeInstance.tf_to_transform(inst.shape.transforms[int(key[1])])
			key_err = maxf(key_err, _transform_error(inst.nodes[ni].transform, want))
	var nodes: Array = ShapeCycles.animated_nodes(inst, seq).keys().filter(func(i): return _carries_mesh(inst.nodes[i]))
	ShapeCycles.pose(inst, seq, 0.0, wrap)
	var prev := _local_bases(inst, nodes)
	var worst := 0.0
	for k in range(1, DARKSTAR_SAMPLES):
		ShapeCycles.pose(inst, seq, float(k) / DARKSTAR_SAMPLES, wrap)
		var now := _local_bases(inst, nodes)
		for i in nodes.size():
			worst = maxf(worst, _turn_angle(prev[i], now[i]))
		prev = now
	_expect(key_err < POSE_TOLERANCE, "%s seq %d keyframe poses equal the keys (max error %.6f)" % [v.id, seq, key_err])
	_expect(worst < DARKSTAR_MAX_STEP, "%s seq %d no node flips (largest step %.3f rad)" % [v.id, seq, worst])


## Geometry-less dummies (Starsiege cinematic "dummy_facial*") may snap without being seen.
static func _carries_mesh(n: Node3D) -> bool:
	return not n.find_children("*", "MeshInstance3D", true, false).is_empty()


func _local_bases(inst: ShapeInstance, node_ids: Array) -> Array:
	var out := []
	for i in node_ids:
		out.append(inst.nodes[int(i)].transform.basis)
	return out


## Rotation angle between two bases (atan2 form: exact for tiny angles, unlike acos of a dot product).
static func _turn_angle(a: Basis, b: Basis) -> float:
	var q := (a.orthonormalized().inverse() * b.orthonormalized()).get_rotation_quaternion()
	return 2.0 * atan2(Vector3(q.x, q.y, q.z).length(), absf(q.w))


static func _transform_error(a: Transform3D, b: Transform3D) -> float:
	return maxf(_turn_angle(a.basis, b.basis), a.origin.distance_to(b.origin))


# ------------------------------------------------------------------ torso nodes

## The twist (torso_node) and the pitch (cockpit_node) turn the upper body: no sole mesh may hang below
## them unless the rig counter-rotates its branch (lower_body_nodes).
func _check_torso_nodes(v: Dictionary, inst: ShapeInstance, anim: HercAnimator) -> void:
	anim.apply_stand()
	var kept: Array = v.get("lower_body_nodes", []).map(func(i): return int(i))
	for key in ["torso_node", "cockpit_node"]:
		var ni := int(v.get(key, TorsoRig.DEFAULT_TORSO_NODE if key == "torso_node" else TorsoRig.DEFAULT_PITCH_NODE))
		if ni < 0 or ni >= inst.nodes.size():
			continue
		for c in _foot_contacts(inst):
			var foot: Node3D = c.mesh
			_expect(not _below(foot, inst.nodes[ni], inst, kept),
				"%s %s %d carries the foot %s" % [v.id, key, ni, foot.get_parent().name])


## True when `n` hangs below `top` without passing a counter-rotated lower-body node.
static func _below(n: Node, top: Node3D, inst: ShapeInstance, kept: Array) -> bool:
	var p := n.get_parent()
	while p != null and p != inst:
		if p == top:
			return true
		if kept.has(inst.nodes.find(p)):
			return false
		p = p.get_parent()
	return false


# ------------------------------------------------------------------ ES1 regression

## The animator reproduces the old Herc maths exactly: stride = walk_factor x ticks x 0.256 x tick ms,
## run above def.run_switch_speed, pose(seq, phase x ticks).
func _check_es1_unchanged(v: Dictionary) -> void:
	var inst := _build(v)
	var ref := _build(v)
	var anim := HercAnimator.new(v, inst, float(v.max_speed))
	var uses_old_layout: bool = int(v.anim.walk) == OLD_WALK_SEQ
	if not uses_old_layout:
		print("  es1 %s: own sequence layout walk %d run %d (was walk 1 / run 2)" % [v.id, anim.walk_seq, anim.run_seq])
		inst.free()
		ref.free()
		return
	var tick := OLD_TICK_SCALE * float(v.get("anim_tick_ms", 1.0))
	var strides := [float(v.walk_factor) * ref.sequence_ticks(OLD_WALK_SEQ) * tick,
		float(v.run_factor) * ref.sequence_ticks(OLD_RUN_SEQ) * tick]
	var phase := 0.0
	var worst := 0.0
	var switch: float = v.get("run_switch_speed", float(v.max_speed) * OLD_RUN_FRACTION)
	for f in int(WALK_SECONDS * FPS):
		var speed := float(v.max_speed) * float(f) / (WALK_SECONDS * FPS)
		if speed <= HercAnimator.MOVE_EPS:
			continue
		var running := speed > switch
		phase += speed / FPS / (strides[1] if running else strides[0])
		var seq := OLD_RUN_SEQ if running else OLD_WALK_SEQ
		ref.pose(seq, phase * ref.sequence_ticks(seq))
		anim.update(speed, 0.0, 1.0 / FPS)
		if anim.is_blending():
			continue    # a cross-fade (remake addition) is not a sequence pose
		for i in inst.nodes.size():
			worst = maxf(worst, inst.nodes[i].transform.origin.distance_to(ref.nodes[i].transform.origin))
			worst = maxf(worst, (inst.nodes[i].transform.basis.get_euler() - ref.nodes[i].transform.basis.get_euler()).length())
	_expect(is_equal_approx(anim.strides[anim.walk_seq], strides[0]) and is_equal_approx(anim.strides[anim.run_seq], strides[1]),
		"%s strides unchanged (%.4f / %.4f m)" % [v.id, strides[0], strides[1]])
	_expect(worst < POSE_TOLERANCE, "%s poses equal the old maths (max diff %.6f)" % [v.id, worst])
	inst.free()
	ref.free()


# ------------------------------------------------------------------ transitions

## Largest per-frame jump over a stand -> top speed -> stop -> turn profile, cross-faded and snapped.
func _check_transitions(v: Dictionary, inst: ShapeInstance, anim: HercAnimator) -> void:
	var nodes := _mesh_nodes(inst)
	var blended := _profile_jump(v, inst, anim, nodes)
	anim.transition_seconds = 0.0
	var snapped := _profile_jump(v, inst, anim, nodes)
	anim.transition_seconds = HercAnimator.TRANSITION_SECONDS
	anim.apply_stand()
	var bound := maxf(TRANSITION_MAX_STEP, blended.steady * STEADY_SLACK)
	_expect(blended.switch < bound, "%s clip changes cross-fade (largest step %.3f, own motion %.3f, snapped %.3f)" % [
		v.id, blended.switch, blended.steady, snapped.switch])
	_summary.append("  %-22s transition step %.3f (own motion %.3f, snapped %.3f)" % [v.id, blended.switch, blended.steady, snapped.switch])


## Speed / yaw rate per frame of the profile: rest, accelerate to top speed, hold, brake, rest, turn.
static func _profile(v: Dictionary) -> Array:
	var top := float(v.max_speed)
	var out := []
	for f in int(TRANSITION_FPS * 0.3):
		out.append(Vector2.ZERO)
	for f in int(TRANSITION_FPS * 3.0):
		out.append(Vector2(top * f / (TRANSITION_FPS * 3.0), 0.0))
	for f in int(TRANSITION_FPS * 0.5):
		out.append(Vector2(top, 0.0))
	for f in int(TRANSITION_FPS * 2.0):
		out.append(Vector2(top * (1.0 - f / (TRANSITION_FPS * 2.0)), 0.0))
	for f in int(TRANSITION_FPS * 0.5):
		out.append(Vector2.ZERO)
	for f in int(TRANSITION_FPS * 1.0):
		out.append(Vector2(0.0, TURN_RATE))
	for f in int(TRANSITION_FPS * 0.5):
		out.append(Vector2.ZERO)
	return out


## Largest per-frame step of any mesh node {switch: within a cross-fade window after a clip change,
## steady: elsewhere - the sequences' own motion}. Frames that wrap a cycle are skipped: some Darkstar
## cycles end on another key than they start, an authored snap (see _check_darkstar_sequence).
func _profile_jump(v: Dictionary, inst: ShapeInstance, anim: HercAnimator, nodes: Array) -> Dictionary:
	anim.apply_stand()
	var prev := _local_transforms(inst, nodes)
	var clip := _clip_of(anim, Vector2.ZERO)
	var window := 0
	var worst := 0.0
	var steady := 0.0
	for step in _profile(v):
		var cycles := Vector2(floorf(anim.gait_phase), floorf(anim.turn_phase))
		anim.update(step.x, step.y / TRANSITION_FPS, 1.0 / TRANSITION_FPS)
		var wrapped := cycles != Vector2(floorf(anim.gait_phase), floorf(anim.turn_phase))
		var now_clip := _clip_of(anim, step)
		window = int(HercAnimator.TRANSITION_SECONDS * TRANSITION_FPS) + 1 if now_clip != clip else window - 1
		clip = now_clip
		var now := _local_transforms(inst, nodes)
		for i in nodes.size():
			var e := _transform_error(prev[i], now[i])
			if wrapped:
				continue
			if window > 0:
				worst = maxf(worst, e)
			else:
				steady = maxf(steady, e)
		prev = now
	return {"switch": worst, "steady": steady}


## The sequence the animator plays for a profile step (speed, yaw rate), tagged with its kind.
static func _clip_of(anim: HercAnimator, step: Vector2) -> Vector2i:
	if absf(step.x) > HercAnimator.MOVE_EPS:
		return Vector2i(1, anim.gait_for(absf(step.x)))
	if absf(step.y) > HercAnimator.TURN_EPS and anim.turn_seq != HercAnimator.NO_SEQUENCE:
		return Vector2i(2, anim.turn_for(step.y))
	return Vector2i(0, anim.stand_seq)


func _mesh_nodes(inst: ShapeInstance) -> Array:
	var out := []
	for i in inst.nodes.size():
		if _carries_mesh(inst.nodes[i]):
			out.append(i)
	return out


func _local_transforms(inst: ShapeInstance, node_ids: Array) -> Array:
	var out := []
	for i in node_ids:
		out.append(inst.nodes[int(i)].transform)
	return out


# ------------------------------------------------------------------ procedural collapse

## Killed mid-stride, a walker without a death sequence sinks onto the ground without flipping.
func _check_collapse(v: Dictionary, inst: ShapeInstance, anim: HercAnimator) -> void:
	anim.apply_stand()
	var height := _highest_point(inst) - inst.lowest_point()
	var standing := WalkerCollapseScript.make_body_height(inst) - inst.lowest_point()
	for f in int(FPS * 0.4):
		anim.update(float(v.max_speed) * WALK_TOP_FRACTION, 0.0, 1.0 / FPS)
	var ground := inst.lowest_point()
	var nodes := _mesh_nodes(inst)
	var prev := _local_transforms(inst, nodes)
	var stats := {"step": 0.0, "off_ground": 0.0, "tilt": 0.0}
	for f in int(COLLAPSE_SECONDS * FPS):
		anim.apply_death((f + 1) / FPS)
		var now := _local_transforms(inst, nodes)
		for i in nodes.size():
			stats.step = maxf(stats.step, _transform_error(prev[i], now[i]))
		prev = now
		stats.off_ground = maxf(stats.off_ground, absf(inst.lowest_point() - ground))
		stats.tilt = maxf(stats.tilt, _root_tilt(inst))
	var sunk := (WalkerCollapseScript.make_body_height(inst) - ground) / standing
	var top := (_highest_point(inst) - ground) / height
	var fall := Vector2(WalkerCollapseScript.FALL_PITCHES.max(), WalkerCollapseScript.FALL_ROLL).length()
	_expect(sunk < 1.0 and minf(sunk, top) < COLLAPSE_SINK_FRACTION, "%s collapses (body at %.2f, top at %.2f of standing)" % [
		v.id, sunk, top])
	_expect(stats.off_ground < height * GROUND_TOLERANCE, "%s collapse stays on the ground (off by %.3f of the height)" % [
		v.id, stats.off_ground / height])
	_expect(stats.step < COLLAPSE_MAX_STEP, "%s collapse turns no node too fast (step %.3f)" % [v.id, stats.step])
	_expect(stats.tilt < fall + TILT_SLACK, "%s collapse does not flip (tilt %.2f rad)" % [v.id, stats.tilt])
	_summary.append("  %-22s collapse: body at %.2f, top at %.2f of standing  step %.3f  tilt %.2f rad" % [
		v.id, sunk, top, stats.step, stats.tilt])
	anim.apply_stand()


## Largest tilt of a root node's up axis from its default (rad).
static func _root_tilt(inst: ShapeInstance) -> float:
	var worst := 0.0
	for i in inst.nodes.size():
		if inst.nodes[i].get_parent() == inst:
			var rest := PoseBlend.default_transform(inst, i).basis.y.normalized()
			worst = maxf(worst, inst.nodes[i].transform.basis.y.normalized().angle_to(rest))
	return worst


## Highest point of the visible geometry in the instance's space.
static func _highest_point(inst: ShapeInstance) -> float:
	var high := -INF
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree():
			continue
		var aabb: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = inst.global_transform.affine_inverse() * mi.global_transform
		for k in 8:
			high = maxf(high, (xf * aabb.get_endpoint(k)).y)
	return high
