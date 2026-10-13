extends Node3D
## Screenshots of the playtest group A fixes (needs a window): renders/fix_a_<name>.png
##   es1_friend      Earthsiege 1 cockpit, a targeted teammate (friend-coloured box, FRIEND), heading tape waypoint
##   starsiege_hud   Starsiege HUD, the remake's heading tape with the waypoint, an enemy target, radar blips
##   soldier_hud     a soldier's plain HUD: compass with the waypoint, radar, name plate over a teammate
##   godot --audio-driver Dummy --path game res://tests/fix_a_shots.tscn

const SETTLE_FRAMES := 6
const GROUND_SIZE := 4000.0
const SKY := Color(0.55, 0.65, 0.8)
const GROUND := Color(0.45, 0.4, 0.3)

var _layer: CanvasLayer
var _out := ""


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	DirAccess.make_dir_recursive_absolute(_out)
	_build_world()
	_layer = CanvasLayer.new()
	add_child(_layer)
	var nav := Node3D.new()
	nav.set_meta("label", "2")
	nav.add_to_group("nav_points")
	add_child(nav)
	nav.global_position = Vector3(200, 0, -300)
	await _shoot_cockpit("es1:RAPTOR", "es1_friend", 0)
	await _shoot_cockpit("starsiege:cy_prom", "starsiege_hud", 1)
	await _shoot_soldier()
	print("fix_a_shots: OK")
	get_tree().quit(0)


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


func _spawn(id: String, at: Vector3, team: int) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _save(name: String) -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out.path_join("fix_a_%s.png" % name))


## A cockpit view with a target 70 m ahead, slightly left, of team `target_team` (0 = the player's team).
func _shoot_cockpit(id: String, name: String, target_team: int) -> void:
	var host := _spawn(id, Vector3.ZERO, 0)
	var target := _spawn("es1:APOLLO", Vector3(-12, 0, -70), target_team)
	target.display_name = "Wingman Alpha" if target_team == 0 else "Cybrid"
	var foe := _spawn("es1:APOLLO", Vector3(60, 0, -250), 1)
	host.target = target
	host.torso_yaw = 0.1
	host.torso.apply(host.torso_yaw, 0.0, host.animator.animates)
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(host)
	cams.cockpit_cam.current = true
	var cockpit := CockpitDisplay.create(host, self)
	_layer.add_child(cockpit)
	cockpit.set_camera(cams.cockpit_cam)
	cockpit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await _save(name)
	cockpit.free()
	cams.release_cockpit_camera(host)
	for n in [host, target, foe]:
		n.free()


func _shoot_soldier() -> void:
	var soldier := Infantry.new()
	soldier.armor_id = InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())
	add_child(soldier)
	soldier.set_physics_process(false)
	soldier.rotation.y = -0.4
	var mate := _spawn("es1:RAPTOR", Vector3(14, 0, -45), 0)
	mate.display_name = "LAN Player 2"
	var foe := _spawn("es1:APOLLO", Vector3(30, 0, -120), 1)
	soldier.target = foe
	var battle := Node.new()
	battle.set_script(_make_battle_script())
	add_child(battle)
	battle.set("player", soldier)
	var plates := Nameplates.new(battle)
	plates.occupied_provider = func(): return HUD.make_occupied_rects(get_viewport().get_visible_rect().size)
	add_child(plates)
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(soldier)
	cams.cockpit_cam.current = true
	var hud := HUD.new()
	hud.herc = soldier
	hud.camera = cams.cockpit_cam
	_layer.add_child(hud)
	await _save("soldier_hud")
	for n in [hud, plates, battle]:
		n.free()
	cams.release_cockpit_camera(soldier)
	for n in [soldier, mate, foe]:
		n.free()


static func _make_battle_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar player: Herc\n"
	s.reload()
	return s
