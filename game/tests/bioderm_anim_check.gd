extends Node
## Bioderm (and human) soldier bodies animate in play: for every body of Aerial Assault and Tribes 2, a running soldier's bones
## change pose from frame to frame, both as a local player/puppet following snapshots and as a physics-driven NEAR bot (not far_lod),
## (also at the MID tier, far_lod: stepped every 4th tick, still posed), and the body's run / jet / death sequences move bones.
##   godot --headless --audio-driver Dummy --path game res://tests/bioderm_anim_check.tscn
## Prints "bioderm_anim_check: OK" or "FAILED"; exit code 0 / 1. A pack that is not imported is skipped.
const WATCHDOG_SECONDS := 180.0
const STEP := 1.0 / 60.0
const RUN_FRAMES := 90
const MIN_POSE_CHANGES := 40
## [armour id, body shape id ("" = the armour's own)].
const CASES := [
	["tribes:LIGHT", "tribes_aa:light_bioderm"], ["tribes:MEDIUM", "tribes_aa:medium_bioderm"], ["tribes:HEAVY", "tribes_aa:heavy_bioderm"],
	["tribes:MEDIUM", "tribes_aa:medium_male"], ["tribes:LIGHT", "tribes_aa:light_female"],
	["tribes2:LIGHT", "tribes2:bioderm_light"], ["tribes2:MEDIUM", "tribes2:bioderm_medium"], ["tribes2:HEAVY", "tribes2:bioderm_heavy"],
	["tribes2:LIGHT", ""], ["tribes2:MEDIUM", ""], ["tribes2:HEAVY", ""],
	["tribes:LIGHT", ""], ["tribes:MEDIUM", ""], ["tribes:HEAVY", ""],
]

var _failures := 0
var _world: Node3D


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _run() -> void:
	Assets.refresh()
	Packs.reload()
	_world = Node3D.new()
	add_child(_world)
	_world.add_child(_make_floor())
	for c in CASES:
		var armor_id: String = c[0]
		var body: String = c[1]
		var shape_id := body if body != "" else str(InfantryCatalog.armor(armor_id).get("shape", ""))
		if InfantryCatalog.armor(armor_id).is_empty() or shape_id == "" or not InfantryCatalog.is_shape_installed(shape_id):
			print("skip  %s / %s (not imported)" % [armor_id, body])
			continue
		await _check_puppet(armor_id, body)
		await _check_bot(armor_id, body, false)
		await _check_bot(armor_id, body, true)
	print("bioderm_anim_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000.0, 2.0, 2000.0)
	col.shape = box
	body.add_child(col)
	body.position.y = -1.0
	return body


func _make_soldier(armor_id: String, body: String, puppet: bool) -> Infantry:
	var s := Infantry.new()
	s.armor_id = armor_id
	s.body_shape = body
	s.is_puppet = puppet
	s.net_id = 1
	_world.add_child(s)
	s.global_position = Vector3(0.0, 0.2, 0.0)
	return s


## A soldier following snapshots (a remote player or a puppet bot): moved 8 m/s along his facing, animated each frame.
func _check_puppet(armor_id: String, body: String) -> void:
	var s := _make_soldier(armor_id, body, true)
	var label := "puppet %s / %s" % [armor_id, body if body != "" else "own body"]
	var changes := 0
	var seen := ""
	s.set_physics_process(false)
	s._last_position = s.global_position
	var before := _bone_pose(s)
	for i in RUN_FRAMES:
		s.global_position += -s.global_basis.z * 8.0 * STEP
		s._animate(STEP)
		var now := _bone_pose(s)
		if now != before:
			changes += 1
		before = now
		seen = s._animation.make_current_name()
	_check(seen == "run", "%s plays run (%s)" % [label, seen])
	_check(changes >= MIN_POSE_CHANGES, "%s pose changes in %d of %d frames" % [label, changes, RUN_FRAMES])
	await _check_sequences(s, label)
	s.queue_free()
	await get_tree().physics_frame


## A NEAR AI soldier (far_lod false) driven by the real physics tick: throttle on, the engine runs _physics_process.
func _check_bot(armor_id: String, body: String, far: bool) -> void:
	var s := _make_soldier(armor_id, body, false)
	var label := "%s bot %s / %s" % ["MID (far_lod)" if far else "NEAR", armor_id, body if body != "" else "own body"]
	for i in 20:
		await get_tree().physics_frame
	s.far_lod = far
	s.throttle = 1.0
	s.torso_target = 0.0
	var changes := 0
	var before := _bone_pose(s)
	var start := s.global_position
	for i in RUN_FRAMES:
		await get_tree().physics_frame
		var now := _bone_pose(s)
		if now != before:
			changes += 1
		before = now
	_check((s.global_position - start).length() > 2.0, "%s ran %.1f m" % [label, (s.global_position - start).length()])
	_check(changes >= (MIN_POSE_CHANGES / Infantry.LOD_FAR_STRIDE if far else MIN_POSE_CHANGES), "%s pose changes in %d of %d frames" % [label, changes, RUN_FRAMES])
	s.queue_free()
	await get_tree().physics_frame


## Jet and death move bones too (some bodies' jet is one held pose, so it is compared with the pose he ran in).
func _check_sequences(s: Infantry, label: String) -> void:
	var running := _bone_pose(s)
	s._animation.update(Vector3.ZERO, false, true, 0.1)
	_check(s._animation.make_current_name() == "jet" and _bone_pose(s) != running, "%s jet plays and changes the pose" % label)
	s._animation.apply_death(0.0, 0)
	var d0 := _bone_pose(s)
	s._animation.apply_death(1.0, 0)
	_check(_bone_pose(s) != d0, "%s death plays and moves bones" % label)


func _bone_pose(s: Infantry) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for n in s.shape.nodes:
		var t := (n as Node3D).transform
		out.append_array([t.origin.x, t.origin.y, t.origin.z, t.basis.x.x, t.basis.y.y, t.basis.z.z, t.basis.x.y, t.basis.y.z])
	return out
