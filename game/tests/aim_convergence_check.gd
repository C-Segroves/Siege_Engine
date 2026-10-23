extends Node3D
## Every pilotable vehicle shoots where its crosshair is (playtest 2026-10-11 A1):
##   for each vehicle, torso straight and twisted / pitched, a target is put on the ray through the cockpit's
##   crosshair (the HUD reticle; for a vehicle without a cockpit layout the plain HUD's, which Hud._draw_crosshair puts
##   on the projection of the aim ray) at several ranges,
##   and every direct-fire weapon's shot line, from its muzzle along the direction the weapon computes, must
##   pass through the target within MISS_TOLERANCE.
##   godot --headless --audio-driver Dummy --path game res://tests/aim_convergence_check.tscn [-- --only=<pack,...>]

const RANGES := [40.0, 120.0, 300.0]
## Torso poses checked (yaw, pitch in radians), each clamped to the vehicle's limits.
const POSES := [Vector2(0.0, 0.0), Vector2(0.5, 0.15), Vector2(-0.4, -0.1)]
## The shot line may pass this far (m) from the target's centre (a Herc torso is several metres wide).
const MISS_TOLERANCE := 0.75
const TARGET_RADIUS := 1.0
## Weapons whose path is not a straight line from the muzzle (lobbed, dropped, guided to a lock).
const INDIRECT_KINDS := ["mine", "bomb", "artillery", "grenade"]

var _failures := 0
var _only := []
var _checked := 0
var _worst := {}          # pack -> [miss m, where]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = Array(a.substr(7).split(","))
	for v in Packs.pilotable(_only):
		await _check_vehicle(v)
	await _check_soldiers()
	for pack in _worst:
		print("  %s: worst miss %.3f m (%s)" % [pack, _worst[pack][0], _worst[pack][1]])
	_expect(_checked > 0, "some vehicles checked")
	print("aim_convergence_check: %s (%d vehicles, %d failures)" % ["OK" if _failures == 0 else "FAILED", _checked, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _spawn(id: String) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _check_vehicle(v: Dictionary) -> void:
	var id := str(v.id)
	var host := _spawn(id)
	if host is Flyer:
		host.position.y = 30.0
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(host)
	cams.cockpit_cam.current = true
	var cockpit := CockpitDisplay.create(host, self)
	if cockpit != null:
		add_child(cockpit)
		cockpit.set_process(false)
		cockpit.set_camera(cams.cockpit_cam)
	_checked += 1
	for pose in POSES:
		_apply_pose(host, pose)
		cams.apply_sight(host)
		await get_tree().process_frame
		await _check_pose(host, cams.cockpit_cam, cockpit, "%s pose %s" % [id, pose])
	if cockpit != null:
		cockpit.free()
	cams.release_cockpit_camera(host)
	host.free()


func _apply_pose(host: Herc, pose: Vector2) -> void:
	if host is Flyer:
		host.pitch = clampf(pose.y, -0.3, 0.3)
		host.torso_yaw = 0.0
		host._animate(0.0)
		return
	host.torso_yaw = clampf(pose.x, -host.torso_limit, host.torso_limit)
	host.pitch = clampf(pose.y, host.pitch_min, host.pitch_max)
	host.torso.apply(host.torso_yaw, host.pitch, host.animator.animates)


## The crosshair's point on the cockpit canvas -> the camera ray through it. Built from the camera's own projection
## (Camera3D.project_ray_normal leaves out a frustum camera's offset, which puts the HUD centre row on the axis).
func _crosshair_ray(host: Herc, cam: Camera3D, cockpit: CockpitDisplay) -> Array:
	if cockpit == null:                    # plain HUD: the reticle is drawn where the aim ray projects
		return [host.aim_origin(), -host.aim_basis().z]
	var share := Vector2(0.5, 0.5)
	if cockpit != null:
		share = cockpit.make_crosshair_point() / cockpit.canvas_size
	var ndc := Vector4(share.x * 2.0 - 1.0, 1.0 - share.y * 2.0, 1.0, 1.0)
	var v := cam.get_camera_projection().inverse() * ndc
	var local := Vector3(v.x, v.y, v.z) / v.w
	return [cam.global_position, (cam.global_basis * local).normalized()]


func _check_pose(host: Herc, cam: Camera3D, cockpit: CockpitDisplay, where: String) -> void:
	var ray := _crosshair_ray(host, cam, cockpit)
	for r in RANGES:
		var at: Vector3 = ray[0] + ray[1] * r
		var body := _build_target(at)
		await get_tree().physics_frame
		await get_tree().physics_frame
		for w in host.weapons:
			if w.is_passive() or w.kind in INDIRECT_KINDS or r > w.weapon_range:
				continue
			var from: Vector3 = w.muzzle().global_position
			var dir: Vector3 = w.make_aim_direction(from)
			var miss := _miss_distance(from, dir, at)
			_note(host, miss, "%s %s at %.0f m" % [where, w.weapon_id, r])
			_expect(miss <= MISS_TOLERANCE, "%s: %s at %.0f m misses the crosshair target by %.2f m" % [where, w.weapon_id, r, miss])
		body.free()


## Soldiers with the hand weapons of Aerial Assault and Vengeance (infantry_rules.json): the shot from the muzzle in hand
## passes through a target on the eye's aim ray, level and pitched, at several ranges.
func _check_soldiers() -> void:
	var armor_pack := InfantryCatalog.make_default_pack()
	for pack in ["tribes_aa", "tribes_v"]:
		if armor_pack == "" or not Assets.installed_packs().has(pack) or (not _only.is_empty() and not _only.has(pack)):
			continue
		for size in ["LIGHT", "HEAVY"]:
			var rules := InfantryCatalog.make_pack_rules(pack, size)
			var s := Infantry.new()
			s.armor_id = "%s:%s" % [armor_pack, size]
			s.net_id = 1
			add_child(s)
			s.set_physics_process(false)
			s.equip((rules.weapons as Array).slice(0, int(rules.max_weapons)))
			_checked += 1
			for slot in s.weapons.size():
				s.apply_weapon_slot(slot)
				s.weapons[slot].set_physics_process(false)
				for pitch in [0.0, 0.5, -0.3]:
					s.pitch = pitch
					s._animate(0.0)
					await _check_soldier_weapon(s, s.weapons[slot], "%s pitch %.1f" % [s.armor_id, pitch])
			s.free()


func _check_soldier_weapon(s: Infantry, w: Weapon, where: String) -> void:
	if w.is_passive() or w.kind in INDIRECT_KINDS:
		return
	var eye: Vector3 = s.aim_origin()
	var dir: Vector3 = -s.aim_basis().z
	for r in [20.0, 60.0]:
		if r > w.weapon_range:
			continue
		var at: Vector3 = eye + dir * r
		var body := _build_target(at)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var from: Vector3 = w.muzzle().global_position
		var miss := _miss_distance(from, w.make_aim_direction(from), at)
		_note(s, miss, "%s %s at %.0f m" % [where, w.weapon_id, r])
		_expect(miss <= MISS_TOLERANCE, "%s: %s at %.0f m misses the aim point by %.2f m" % [where, w.weapon_id, r, miss])
		body.free()


func _note(host: Herc, miss: float, where: String) -> void:
	var pack := str(host.def.get("pack", "?"))
	if not _worst.has(pack) or miss > float(_worst[pack][0]):
		_worst[pack] = [miss, where]


## Distance from `at` to the shot line from `from` along `dir` (infinite if the target is behind the muzzle).
static func _miss_distance(from: Vector3, dir: Vector3, at: Vector3) -> float:
	var along := (at - from).dot(dir)
	if along <= 0.0:
		return INF
	return (from + dir * along).distance_to(at)


func _build_target(at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = TARGET_RADIUS
	col.shape = sphere
	body.add_child(col)
	add_child(body)
	body.global_position = at
	return body
