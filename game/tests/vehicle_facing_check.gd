extends Node3D
## Which way the vehicles of the newer games face, and how a drop pod stands (docs/CODING_STANDARDS.md section 4).
## The engine flies and drives along -Z (FlightPilot.make_forward), so every model must have its nose at its -Z end:
##   1 the flying convention itself: heading h points the nose along (-sin h, 0, -cos h), nose pitch + is up
##   2 Aerial Assault vehicles: the same mass lies toward the tail as in their Tribes 2 twins (Shrike, Thundersword, Wildcat, Havoc)
##   3 Vengeance Pod, Tank, AssaultShip and Buggy, and the Starsiege dropships: the bones of their nose (the cockpit, the track
##     teeth, the roll cage, the head) lie ahead of the bones of their tail (the tail, the jets, the antennas, the spikes)
##   4 the drop pods: the nose points down while falling and the pod lands standing (its nose up), for every nose axis in the
##     rules; a CallinFx pod advances with the frames' delta (game time), never with the wall clock
##   5 the delivery sling hangs a vehicle clear under the transport's belly
## A pack that is not imported is skipped.
##   godot --headless --audio-driver Dummy --path game res://tests/vehicle_facing_check.tscn
const WATCHDOG_SECONDS := 60.0
const TWINS := {
	"tribes_aa:scout": "tribes2:vehicle_air_scout", "tribes_aa:bombscout": "tribes2:vehicle_air_bomber",
	"tribes_aa:grav_scout": "tribes2:vehicle_grav_scout", "tribes_aa:turrettrans_vehicle": "tribes2:vehicle_air_hapc"}
## shape -> [bone of the nose, bone of the tail]
const NOSE_AND_TAIL := {
	"tribes_v:tv_prop_tank": ["JTTrackTeethFRight", "JTJetRight"],
	"tribes_v:tv_prop_assaultship": ["ASHIPCocpit", "Tail"],
	"tribes_v:tv_prop_buggy": ["RollCage", "AntennaLeft"],
	"tribes_v:tv_prop_pod": ["FinLeftFront", "FinLeftBack"],
	"starsiege:tr_drop": ["head0", "Tail0"],
	"starsiege:kn_drop": ["head0", "Tail0"],
	"starsiege:cy_drop": ["Body0", "AuxC0"]}
const TOLERANCE := 0.001
const MIN_TAIL_HEAVY := 0.01
const MIN_BONE_GAP_M := 0.5

var _failures := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("FAIL ", what)


func _run() -> void:
	_check_flying_convention()
	_check_twins()
	_check_noses()
	_check_pod_poses()
	await _check_pod_fx()
	_check_sling()
	print("vehicle_facing_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures else 0)


func _has(id: String) -> bool:
	return Assets.has_pack(Assets.split_id(id)[0]) and not Assets.shape(id).is_empty()


func _build(id: String) -> ShapeInstance:
	var inst := ShapeInstance.new()
	add_child(inst)
	inst.build(Assets.shape(id), 0, Packs.default_palette(Assets.split_id(id)[0]))
	return inst


# ------------------------------------------------------------------ 1 the flying convention

func _check_flying_convention() -> void:
	for h in [0.0, 0.7, -2.1, PI]:
		var ahead := FlightPilot.make_forward(h)
		var body := Basis(Vector3.UP, h) * Vector3.FORWARD
		_check(ahead.distance_to(body) < TOLERANCE, "heading %.2f: the flight forward %s is the body's -Z %s" % [h, ahead, body])
	var model := FlightModel.new({})
	model.heading = 0.4
	model.pitch = 0.3
	var nose: Vector3 = model.make_nose_basis() * Vector3.FORWARD
	var flat := Vector2(nose.x, nose.z).normalized()
	_check(nose.y > 0.0 and flat.distance_to(Vector2(-sin(0.4), -cos(0.4))) < TOLERANCE, "nose pitch + is up and keeps the heading (%s)" % nose)


# ------------------------------------------------------------------ 2 Aerial Assault

## How far toward +Z the surface area lies, as a share of the model's length (+ = the tail is the heavy end).
func _make_tail_weight(inst: Node3D) -> float:
	var weighted := 0.0
	var area := 0.0
	var lo := INF
	var hi := -INF
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		var xf := (mi as MeshInstance3D).global_transform
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx = arrays[Mesh.ARRAY_INDEX]
			var count := idx.size() if idx.size() > 0 else v.size()
			for t in range(0, count - 2, 3):
				var tri: Array[Vector3] = []
				for k in 3:
					tri.append(xf * v[idx[t + k] if idx.size() > 0 else t + k])
				var a := (tri[1] - tri[0]).cross(tri[2] - tri[0]).length() * 0.5
				weighted += a * (tri[0].z + tri[1].z + tri[2].z) / 3.0
				area += a
				for p in tri:
					lo = minf(lo, p.z)
					hi = maxf(hi, p.z)
	return (weighted / maxf(area, 0.0001) - (lo + hi) * 0.5) / maxf(hi - lo, 0.0001)


func _check_twins() -> void:
	for id in TWINS:
		if not _has(id) or not _has(TWINS[id]):
			print("  skipped %s (it or its twin is not imported)" % id)
			continue
		var own := _make_tail_weight(_build(id))
		var twin := _make_tail_weight(_build(TWINS[id]))
		_check(own > MIN_TAIL_HEAVY and twin > MIN_TAIL_HEAVY, "%s is heavier at the tail like %s (%.3f / %.3f)" % [id, TWINS[id], own, twin])


# ------------------------------------------------------------------ 3 nose and tail bones

func _bone_z(inst: ShapeInstance, bone: String) -> float:
	var nodes: Array = inst.shape.get("nodes", [])
	for i in nodes.size():
		if str(nodes[i].name) == bone:
			return inst.nodes[i].global_position.z
	_check(false, "%s has a bone %s" % [inst.shape.get("name", "?"), bone])
	return 0.0


func _check_noses() -> void:
	for id in NOSE_AND_TAIL:
		if not _has(id):
			print("  skipped %s (not imported)" % id)
			continue
		var bones: Array = NOSE_AND_TAIL[id]
		var inst := _build(id)
		var front := _bone_z(inst, bones[0])
		var back := _bone_z(inst, bones[1])
		_check(front < back - MIN_BONE_GAP_M, "%s: %s (z %.1f) is ahead of %s (z %.1f), nose toward -Z" % [id, bones[0], front, bones[1], back])


# ------------------------------------------------------------------ 4 the pods

func _check_pod_poses() -> void:
	var axes: Dictionary = CallinRules.pod().get("nose_axes", {})
	for id in CallinRules.pod().get("pod_shapes", []):
		_check(axes.has(id), "%s has a nose axis in the rules" % id)
	var noses: Array = [CallinPodPose.FALLBACK_NOSE]
	for id in axes:
		noses.append(CallinPodPose.make_nose_axis(id))
	for nose in noses:
		var falling: Vector3 = CallinPodPose.make_basis(nose, 400.0) * nose
		var landed: Vector3 = CallinPodPose.make_basis(nose, 0.0) * nose
		var half: Vector3 = CallinPodPose.make_basis(nose, CallinPodPose.make_flip_height() * 0.5) * nose
		_check(falling.distance_to(Vector3.DOWN) < TOLERANCE, "pod nose %s points down while it falls (%s)" % [nose, falling])
		_check(landed.distance_to(Vector3.UP) < TOLERANCE, "pod nose %s points up once landed: it stands upright (%s)" % [nose, landed])
		_check(absf(half.y) < 0.5, "halfway through the flip it is on its side (%s)" % half)


func _check_pod_fx() -> void:
	var fx := CallinFx.new()
	add_child(fx)
	fx.set_process(false)
	var view := {"id": 1, "kind": CallinRules.KIND_ARMOR, "state": int(CallinOrder.State.INBOUND), "lz": Vector3(5, 0, 5),
		"radius": 3.0, "fall_s": 5.0, "fall_left": 5.0, "peer": 1}
	fx.apply_view(view)
	var m: Dictionary = fx.markers.get(1, {})
	_check(m.get("pod") != null, "a pod is falling over the zone")
	if m.get("pod") == null:
		return
	OS.delay_msec(120)
	_check(is_equal_approx(float(m.fall_left), 5.0), "the wall clock does not move the pod (%.2f s left)" % float(m.fall_left))
	fx._process(1.0)
	_check(is_equal_approx(float(m.fall_left), 4.0), "a frame's delta of 1 s moves it 1 s (%.2f s left)" % float(m.fall_left))
	var down: Vector3 = (m.pod_body as Node3D).global_basis * m.nose
	_check(down.distance_to(Vector3.DOWN) < TOLERANCE, "high up it falls nose down (%s)" % down)
	for _i in 8:
		fx._process(1.0)
	var up: Vector3 = (m.pod_body as Node3D).global_basis * m.nose
	_check(float(m.fall_left) == 0.0 and up.distance_to(Vector3.UP) < TOLERANCE, "landed it stands upright, nose up (%s)" % up)
	var centre := (m.pod as Node3D).position.y
	_check(absf(centre - CallinFx.POD_LENGTH * 0.5) < TOLERANCE, "and rests on the ground (centre %.2f m up)" % centre)
	fx.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------ 5 the sling

func _check_sling() -> void:
	var minimum := float(CallinRules.rule(CallinRules.KIND_VEHICLE).get("sling_m", 8.0))
	_check(CallinVehicleRun.make_sling_m(0.0, 11.0) >= 11.0 + CallinVehicleRun.SLING_CLEARANCE_M - TOLERANCE, "an 11 m Herc hangs below a belly at the origin")
	_check(CallinVehicleRun.make_sling_m(-7.9, 7.4) >= 7.4 + 7.9, "a transport whose origin is mid-hull carries it below the belly too")
	_check(is_equal_approx(CallinVehicleRun.make_sling_m(0.0, 1.0), minimum), "a small vehicle keeps the rule's sling (%.1f m)" % minimum)
