extends Node3D
## Headless check: every Tribes / Starsiege map carries a darkstar_sky whose images exist, and
## MapEnvironment turns it into the Darkstar sky shader; a few maps are fully built (MapBuilder).
##
##   Godot --headless --path game --audio-driver Dummy res://tests/darkstar_sky_check.tscn

const PACKS := ["tribes", "starsiege"]
const BUILD_MAPS := ["tribes:Raindance", "tribes:SeekAndDestroy", "starsiege:DM_Avalanche", "starsiege:HA0",
	"starsiege:CA0"]
const SHADER_PATH := "res://engine/shaders/darkstar_sky.gdshader"

var failures := 0


func _ready() -> void:
	var checked := 0
	for pack in PACKS:
		for e in Assets.load_json("maps/_index.json", pack):
			_check_map("%s:%s" % [pack, e.id])
			checked += 1
	for map_id in BUILD_MAPS:
		_check_build(map_id)
	print("darkstar_sky_check: %d maps, %d failures" % [checked, failures])
	get_tree().quit(1 if failures else 0)


func _check_map(map_id: String) -> void:
	var m := MapBuilder.load_map(map_id)
	var sky = m.get("environment", {}).get("darkstar_sky")
	if not sky is Dictionary:
		_fail(map_id, "no darkstar_sky")
		return
	for f in [sky.get("panels")] + sky.get("planets", []).map(func(p): return p.image):
		if f is String and not FileAccess.file_exists(String(m._dir).path_join(f)):
			_fail(map_id, "missing " + f)
	var holder := Node3D.new()
	add_child(holder)
	MapEnvironment.build(holder, m.environment, m._dir)
	var env: Environment = (holder.get_child(0) as WorldEnvironment).environment
	var mat := env.sky.sky_material as ShaderMaterial if env.sky else null
	if mat == null or mat.shader.resource_path != SHADER_PATH:
		_fail(map_id, "sky shader not applied")
	elif mat.get_shader_parameter("has_panels") != (sky.get("panels") is String):
		_fail(map_id, "panel texture not loaded")
	holder.queue_free()


func _check_build(map_id: String) -> void:
	var root := Node3D.new()
	add_child(root)
	var built := MapBuilder.build(root, map_id)
	if built.is_empty() or not built.map.has("environment"):
		_fail(map_id, "map did not build")
	root.queue_free()


func _fail(map_id: String, why: String) -> void:
	failures += 1
	printerr("FAIL %s: %s" % [map_id, why])
