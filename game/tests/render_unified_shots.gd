extends Node
## Windowed renders for render_unified (docs/RENDER_UNIFICATION.md): shapes of every pack, each on its own world and
## on foreign worlds, drawn the old way and the unified way.
##   RU_SHOT_DIR=<folder> [RU_ONLY=substring] [RU_SAME_SUN=1] godot --audio-driver Dummy --path game res://tests/render_unified_shots.tscn
const SETTLE_FRAMES := 20
const SIZE := Vector2i(960, 540)
const MAPS := {"t2": ["tribes2", "Abominable"], "t1": ["tribes", "5_CTF"], "ss": ["starsiege", "CA0"]}
const SHAPES := {
	"es1herc": "es1:RAPTOR", "t2veh": "tribes2:vehicle_grav_tank", "t2man": "tribes2:light_male",
	"t1man": "tribes:larmor", "ssherc": "starsiege:ha_apoc", "es2herc": "es2:SAMSON", "bdherc": "bd:AVENGER",
	"t2bio": "tribes2:bioderm_light", "t1skin": "tribes:larmor|blue", "ssskin": "starsiege:cy_bolo|grass", "t2skin": "tribes2:bioderm_light|baseb", "aabase": "tribes_aa:bbunk1", "aaveh": "tribes_aa:at_debris01", "vtree": "tribes_v:alpine__tree", "vrock": "tribes_v:alpine__boulder1",
}
## [shot name, shape key, world]
const COMBOS := [
	["es1herc_es1world", "es1herc", "es1"], ["t2veh_t2map", "t2veh", "t2"], ["es1herc_t2map", "es1herc", "t2"],
	["t2veh_es1world", "t2veh", "es1"], ["t2man_t2map", "t2man", "t2"], ["t1man_t1map", "t1man", "t1"],
	["ssherc_ssmap", "ssherc", "ss"], ["es2herc_es2world", "es2herc", "es2"], ["bdherc_bdarena", "bdherc", "bd"],
	["t2bio_t2map", "t2bio", "t2"], ["t1skin_t1map", "t1skin", "t1"], ["ssskin_ssmap", "ssskin", "ss"], ["t2skin_t2map", "t2skin", "t2"],
	["aabase_t2map", "aabase", "t2"], ["aadeb_t2map", "aaveh", "t2"], ["vtree_t2map", "vtree", "t2"], ["vrock_t2map", "vrock", "t2"],
	["ssherc_es1world", "ssherc", "es1"], ["ssherc_bdarena", "ssherc", "bd"], ["es2herc_t2map", "es2herc", "t2"],
]

var _out := ""


func _ready() -> void:
	get_tree().create_timer(600.0, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	_run.call_deferred()


func _run() -> void:
	_out = OS.get_environment("RU_SHOT_DIR")
	var only := OS.get_environment("RU_ONLY")
	get_window().size = SIZE
	for c in COMBOS:
		if only != "" and not String(c[0]).contains(only):
			continue
		for unified in [false, true]:
			RenderUnified.force = unified
			await _shot("%s_%s" % [c[0], "new" if unified else "old"], SHAPES[c[1]], c[2])
	get_tree().quit()


func _ground(root: Node3D, mat: Material) -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	root.add_child(ground)
	ground.material_override = mat


## Builds the world; returns the 3Space palette id for the shape ("" = the shape's default).
func _world(root: Node3D, world: String) -> String:
	match world:
		"es1":
			WorldBuilder.build(root, 0, -1, "es1")
			_ground(root, Palette.material("es1:WORLD0", {"kind": "solid", "index": 90}))
			return ""
		"es2":
			return String(ES2WorldBuilder.build(root, 0, -1).palette)
		"bd":
			return String(ArenaBuilder.build(root, {"size": 2, "obstacles": "FEW", "turrets": "FEW", "lighting": "DIM", "style": 0}).palette)
		_:
			var m: Array = MAPS[world]
			var d: Dictionary = Assets.load_json("maps/%s/map.json" % m[1], m[0])
			MapEnvironment.build(root, d.environment, Assets.path("maps/%s" % m[1], m[0]))
			var gm := StandardMaterial3D.new()
			gm.albedo_color = Color(0.35, 0.35, 0.38)
			_ground(root, gm)
			return ""


func _shot(shot_name: String, shape_id: String, world: String) -> void:
	var root := Node3D.new()
	add_child(root)
	var pal := _world(root, world)
	if OS.get_environment("RU_SAME_SUN") == "1" and MAPS.has(world):   # isolates colour handling from light direction
		var w := WorldBuilder.load_world(0, "es1")
		SceneLighting.apply_sun_direction(SceneLighting.make_3space_sun(w.get("light", {}).get("vector_assumed_RzRyRx", WorldBuilder.DEFAULT_SUN)))
	var holder := Node3D.new()
	root.add_child(holder)
	var inst := ShapeInstance.new()
	holder.add_child(inst)
	var skin := ""
	if shape_id.contains("|"):
		skin = shape_id.get_slice("|", 1)
		shape_id = shape_id.get_slice("|", 0)
		inst.texture_overrides = SkinCatalog.make_texture_overrides(shape_id, skin)
	if pal != "":
		inst.build(Assets.shape(shape_id), 0, pal)
	else:
		inst.build(Assets.shape(shape_id), 0)
	var low := inst.lowest_point()
	inst.position.y = -low * inst.scale.y
	holder.rotation.y = deg_to_rad(215)
	var aabb := AABB()
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		aabb = aabb.merge(mi.global_transform * mi.get_aabb()) if aabb.size != Vector3.ZERO else mi.global_transform * mi.get_aabb()
	var r := maxf(aabb.size.length(), 2.0) * (float(OS.get_environment("RU_DIST")) if OS.get_environment("RU_DIST") != "" else 1.0)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(r * 0.9, r * 0.45 + 1.0, r * 1.1) + aabb.get_center() * Vector3(1, 0, 1)
	cam.look_at(aabb.get_center(), Vector3.UP)
	cam.far = 3000.0
	cam.current = true
	for _f in SETTLE_FRAMES:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_out.path_join(shot_name + ".png"))
	print("saved ", shot_name, " aabb=", aabb.size)
	root.queue_free()
	await get_tree().process_frame
