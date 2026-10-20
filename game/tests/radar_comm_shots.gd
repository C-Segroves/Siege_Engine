extends Node3D
## Screenshots (needs a window): renders/radar_comm_<name>.png
##   scanner   Earthsiege 1 cockpit, F4 SCANNER (heading up, ACT label)
##   scanner_passive   the same in passive radar (PASS)
##   comm_a, comm_b    the three wingman comm windows while one wingman talks (two moments: the face moves)
##   godot --audio-driver Dummy --path game res://tests/radar_comm_shots.tscn

const SETTLE_FRAMES := 6
const SRC := """extends Node3D
var chat = Chat.new()
class Chat:
	var radio = Radio.new()
class Radio:
	func is_speaker_talking(_s: String) -> bool:
		return true
"""

var _out := ""
var _layer: CanvasLayer


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	DirAccess.make_dir_recursive_absolute(_out)
	SceneLighting.add_studio_environment(self, {"background": Color(0.55, 0.65, 0.8), "ambient_energy": 0.6})
	_layer = CanvasLayer.new()
	add_child(_layer)
	var s := GDScript.new()
	s.source_code = SRC
	s.reload()
	var battle := Node3D.new()
	battle.set_script(s)
	add_child(battle)
	var host := _spawn(battle, "es1:RAPTOR", Vector3.ZERO, 0)
	for k in 3:
		var m := _spawn(battle, "es1:RAPTOR", Vector3(30 * (k + 1), 0, -40), 0)
		m.display_name = "Wing %d" % (k + 1)
		m.set_meta(WingmanRadio.SLOT_META, k)
	_spawn(battle, "es1:APOLLO", Vector3(60, 0, -250), 1)
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(host)
	cams.cockpit_cam.current = true
	var cockpit := CockpitDisplay.create(host, battle)
	_layer.add_child(cockpit)
	cockpit.set_camera(cams.cockpit_cam)
	cockpit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cockpit.mfd_mode = CockpitMfd.MODE_SCANNER
	await _save("scanner")
	RadarMode.apply_emitting(host, false)
	await _save("scanner_passive")
	cockpit.look_down = true
	await _save("comm_a")
	cockpit.time += 0.3
	await _save("comm_b")
	print("radar_comm_shots: OK")
	get_tree().quit(0)


func _spawn(parent: Node, id: String, at: Vector3, team: int) -> Herc:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	h.team = team
	h.position = at
	parent.add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	for w in h.weapons:
		w.set_physics_process(false)
	return h


func _save(name: String) -> void:
	for i in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join("radar_comm_%s.png" % name))
