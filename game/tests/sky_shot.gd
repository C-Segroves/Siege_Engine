extends Node3D
## Renders a map's sky and terrain from its centre in four directions into one 2x2 PNG
## (needs a rendering driver: run without --headless).
##
##   Godot --path game --audio-driver Dummy res://tests/sky_shot.tscn -- --map=tribes:Scarabrae --out=C:/tmp/sky.png
##
## Views: north, east, south at PITCH_DEG, and the last one toward the first Darkstar planet (else west).

const VIEW_HEIGHT := 30.0
const PITCH_DEG := 14.0
const FOV := 80.0
const SETTLE_FRAMES := 6


func _ready() -> void:
	var a := {"map": "tribes:Scarabrae", "out": "user://sky_shot.png"}
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.find("=") > 0:
			a[s.substr(2, s.find("=") - 2)] = s.substr(s.find("=") + 1)
	var m := MapBuilder.load_map(String(a.map))
	if m.is_empty():
		push_error("map not found: " + String(a.map))
		get_tree().quit(1)
		return
	MapEnvironment.build(self, m.get("environment", {}), m._dir)
	if m.get("terrain") is Dictionary:
		MapTerrain.build(self, m.terrain, m._dir)
	var cam := _build_camera(m)
	var shots: Array[Image] = []
	for view in _views(m):
		cam.rotation = Vector3(deg_to_rad(view.y), deg_to_rad(view.x), 0.0)
		for i in SETTLE_FRAMES:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		shots.append(get_viewport().get_texture().get_image())
	_make_grid(shots).save_png(String(a.out))
	print("saved ", a.out)
	get_tree().quit()


func _build_camera(m: Dictionary) -> Camera3D:
	var b: Dictionary = m.get("bounds", {"min": [0, 0], "max": [0, 0]})
	var pos := Vector3((float(b.min[0]) + float(b.max[0])) * 0.5, 0.0, (float(b.min[1]) + float(b.max[1])) * 0.5)
	pos.y = MapTerrain.ground_height(self, pos) + VIEW_HEIGHT
	var cam := Camera3D.new()
	cam.far = 20000.0
	cam.fov = FOV
	add_child(cam)
	cam.position = pos
	cam.current = true
	return cam


## [Vector2(yaw, pitch)] in degrees; Godot yaw 0 looks north (-z), positive turns left.
func _views(m: Dictionary) -> Array:
	var views := [Vector2(0, PITCH_DEG), Vector2(-90, PITCH_DEG), Vector2(180, PITCH_DEG), Vector2(90, PITCH_DEG)]
	var sky = m.get("environment", {}).get("darkstar_sky")
	if sky is Dictionary and not sky.get("planets", []).is_empty():
		var d: Array = sky.planets[0].dir
		var dir := Vector3(float(d[0]), float(d[1]), float(d[2]))
		views[3] = Vector2(rad_to_deg(atan2(-dir.x, -dir.z)), rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))))
	return views


func _make_grid(shots: Array[Image]) -> Image:
	var w := shots[0].get_width() / 2
	var h := shots[0].get_height() / 2
	var out := Image.create(w * 2, h * 2, false, Image.FORMAT_RGB8)
	for i in shots.size():
		var s := shots[i]
		s.convert(Image.FORMAT_RGB8)
		s.resize(w, h)
		out.blit_rect(s, Rect2i(0, 0, w, h), Vector2i((i % 2) * w, (i / 2) * h))
	return out
