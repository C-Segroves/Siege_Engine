extends Node3D
## The first-person cockpit view shows none of the vehicle's own model except the cockpit interior its game draws
## from inside (Starsiege "cockpit*" objects, CockpitEye.make_interior_meshes): for every pilotable vehicle, every
## own mesh in front of the near plane and inside the view is either hidden from the cockpit camera (its render
## layer is culled) or one of the interior meshes. Saves renders/cockpit_view_<vehicle>.png for SHOT_IDS.
##   godot --audio-driver Dummy --path game res://tests/cockpit_view_check.tscn

const SHOT_IDS := ["starsiege:mg_seek", "starsiege:cy_seek", "starsiege:tr_talo", "es1:RAPTOR", "tribes2:SHRIKE"]
const SETTLE_FRAMES := 4

var _failures := 0
var _checked := 0


func _ready() -> void:
	SceneLighting.add_studio_environment(self, {"background": Color(0.55, 0.65, 0.8), "ambient_energy": 0.6})
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.4, 0.0)
	add_child(sun)
	var out := ProjectSettings.globalize_path("res://").path_join("../renders")
	for v in Packs.pilotable():
		await _check_vehicle(str(v.id), out)
	_expect(_checked > 0, "some vehicles checked")
	print("cockpit_view_check: %s (%d vehicles, %d failures)" % ["OK" if _failures == 0 else "FAILED", _checked, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL ", what)
		_failures += 1


func _check_vehicle(id: String, out: String) -> void:
	var h: Herc = Flyer.new() if Packs.vehicle(id).get("flyer", false) else Herc.new()
	h.vehicle_id = id
	add_child(h)
	h.set_physics_process(false)
	h.equip(h.def.get("loadout", []))
	var cams := BattleCameras.new()
	cams.build_cockpit_camera(h)
	var cam := cams.cockpit_cam
	cam.current = true
	_checked += 1
	var interior := CockpitEye.make_interior_meshes(h)
	for mi in h.find_children("*", "MeshInstance3D", true, false):
		if not (mi as MeshInstance3D).is_visible_in_tree() or interior.has(mi):
			continue
		var shown := (cam.cull_mask & (mi as MeshInstance3D).layers) != 0
		_expect(not (shown and _is_in_view(cam, mi)), "%s: own mesh %s/%s shows in the cockpit view" % [id, mi.get_parent().name, mi.name])
	if id in SHOT_IDS:
		for i in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("cockpit_view_%s.png" % id.replace(":", "_")))
	cams.release_cockpit_camera(h)
	h.free()


## True when a corner of `mi`'s box lies in front of the near plane and inside the camera's frustum.
static func _is_in_view(cam: Camera3D, mi: MeshInstance3D) -> bool:
	var box: AABB = mi.global_transform * mi.mesh.get_aabb()
	for k in 8:
		var p := box.get_endpoint(k)
		if cam.is_position_in_frustum(p):
			return true
	return false
