extends Node3D
## Screenshots of the Earthsiege missile camera (needs a window): renders/missile_cam_<name>.png
##   mfd      Earthsiege 1 cockpit, MFD on the MISSILE CAM page (F6) following a steered EO missile
##   window   the same flight with the MFD on the scanner: the remake's missile cam window shows it instead
##   hit      the MFD page holding the hit, frame flashing
##   place_<w>x<h>  the window's free spot at 1280x800, 1920x1080 and 1024x768 (4:3)
##   godot --audio-driver Dummy --path game res://tests/missile_cam_shots.tscn

const PILOT_ID := "es1:RAPTOR"
const TARGET_ID := "es1:APOLLO"
const EO_RACK := "es1:MLRS6_EO"
const SETTLE_FRAMES := 4
const GROUND_SIZE := 4000.0
const SKY := Color(0.55, 0.65, 0.8)
const GROUND := Color(0.45, 0.4, 0.3)
const FLIGHT_FRAMES := 12
const MAX_FRAMES := 600
const WINDOW_SIZES := [Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(1024, 768)]

## The battle's plain HUD, which the cockpit hides while it shows (CockpitDisplay reads battle.hud).
var hud: HUD
var _out := ""
var _overlay: BattleOverlay


## The battle's effect channel as Weapon calls it (no effects needed here).
func fx(_kind: String, _args: Array, _reliable := false) -> void:
	pass


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	DirAccess.make_dir_recursive_absolute(_out)
	_build_world()
	var pilot := _spawn(PILOT_ID, Vector3.ZERO, 0, [EO_RACK])
	var target := _spawn(TARGET_ID, Vector3(30, 0, -160), 1, [])
	target.set_meta("ai", true)
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(pilot)
	cams.cockpit_cam.current = true
	var overlay := BattleOverlay.new()
	_overlay = overlay
	add_child(overlay)
	hud = overlay.hud
	overlay.occupied_provider = _make_cockpit_rects
	overlay.build_cockpit(pilot, self)
	overlay.cockpit.set_camera(cams.cockpit_cam)
	overlay.cockpit.mfd_mode = CockpitMfd.MODE_MISSILE
	overlay.missile_cam_window.enabled = true
	await get_tree().process_frame
	var w: Weapon = pilot.weapons[0]
	w.trigger = true
	w.fire()
	var m: Projectile = get_tree().get_nodes_in_group("projectiles").back()
	for i in FLIGHT_FRAMES:
		_steer(pilot, m, target)
		await get_tree().physics_frame
	await _save("mfd")
	overlay.cockpit.mfd_mode = CockpitMfd.MODE_SCANNER
	await _save("window")
	for sz in WINDOW_SIZES:
		get_window().size = sz
		overlay.missile_cam_window.apply_placement(Vector2(sz))
		await _save("place_%dx%d" % [sz.x, sz.y])
	get_window().size = WINDOW_SIZES[0]
	overlay.cockpit.mfd_mode = CockpitMfd.MODE_MISSILE
	for i in MAX_FRAMES:
		if not is_instance_valid(m):
			break
		_steer(pilot, m, target)
		await get_tree().physics_frame
	await _save("hit")
	print("missile_cam_shots: OK")
	get_tree().quit(0)


func _make_cockpit_rects() -> Array:
	var c := _overlay.cockpit
	return ChatPlacement.make_screen_rects(CockpitOccupancy.make_rects(c), c.canvas_size, get_viewport().get_visible_rect().size)


func _steer(pilot: Herc, m: Projectile, target: Herc) -> void:
	if not is_instance_valid(m):
		return
	var want := (target.global_position + Vector3.UP * 4.0 - m.global_position).normalized()
	var h := m.make_heading()
	pilot.missile_steering.stick = Vector2(clampf(-h.cross(want).y * 4.0, -1, 1), clampf(-(want.y - h.y) * 4.0, -1, 1))


func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = SKY
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.4, 0.0)
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE, GROUND_SIZE)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GROUND
	plane.material = mat
	ground.mesh = plane
	add_child(ground)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_SIZE, 1, GROUND_SIZE)
	col.shape = box
	body.add_child(col)
	add_child(body)
	body.position = Vector3(0, -0.5, 0)


func _spawn(id: String, at: Vector3, team: int, loadout: Array) -> Herc:
	var h := Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(loadout)
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _save(name: String) -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join("missile_cam_%s.png" % name))
