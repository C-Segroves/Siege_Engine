extends Node3D
## Group portrait: every pilotable Herc/Cybrid from every imported game standing in a row at its
## true converted size, with the infantry armors standing in front. Saves a PNG and quits.
##   godot --path game res://tools/lineup.tscn -- --out=<png> [--width=3840] [--height=1600]

const GAP := 2.5            # metres between figures
const INFANTRY_GAP := 1.0
const INFANTRY_ROW_Z := 4.0
const ROW_GAP := 16.0       # metres between game rows
const PER_ROW := 14
const MAX_HERC_HEIGHT := 30.0   # walking Hercs only: no carriers
const SKY := Color(0.62, 0.66, 0.72)

var out_path := "user://lineup.png"
var width := 3840
var height := 1600
## false: only build() the figures (e.g. for the trailer's dolly shot), no portrait and no quit.
var auto_save := true


func _ready() -> void:
	if not auto_save:
		return
	for a in OS.get_cmdline_user_args():
		_apply_flag(a)
	get_window().size = Vector2i(width, height)
	var extent := build()
	_build_camera(extent.x, extent.y, extent.z)
	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	_make_cropped(get_viewport().get_texture().get_image()).save_png(out_path)
	print("saved ", ProjectSettings.globalize_path(out_path))
	get_tree().quit()


## Builds the floor, sky and every figure; returns (widest row, tallest figure, depth of the rows).
func build() -> Vector3:
	_build_environment()
	var mechs := _make_mech_list()
	var infantry := _make_infantry_list()
	print("lineup: %d mechs, %d infantry" % [mechs.size(), infantry.size()])
	var rows := _make_rows(mechs)
	var size := _place_rows(rows)
	_place_infantry(infantry, size.x)
	return Vector3(size.x, size.y, rows.size() * ROW_GAP)


func _apply_flag(a: String) -> void:
	if a.begins_with("--out="):
		out_path = a.substr(6)
	elif a.begins_with("--width="):
		width = int(a.substr(8))
	elif a.begins_with("--height="):
		height = int(a.substr(9))


## Walking Hercs and Cybrids: no tanks, drones, flyers or carriers.
static func _make_mech_list() -> Array:
	var mechs := []
	for v in Packs.vehicles.values():
		if v.get("category", "herc") == "herc" and v.get("side", "herc") in ["herc", "cybrid"] 				and String(v.get("kind", "herc")) == "herc" and not v.get("flyer", false) 				and float(v.get("height_m", 0.0)) < MAX_HERC_HEIGHT:
			mechs.append(v)
	return mechs


## Catalog infantry, plus the armor shapes of packs that have no catalog entries yet.
static func _make_infantry_list() -> Array:
	var infantry := []
	var catalog_packs := {}
	for v in Packs.vehicles.values():
		if v.get("category", "herc") == "infantry":
			infantry.append(v)
			catalog_packs[v.pack] = true
	for p in Assets.installed_packs():
		if catalog_packs.has(p) or not DirAccess.dir_exists_absolute(Assets.path("shapes", p)):
			continue
		for f in DirAccess.get_files_at(Assets.path("shapes", p)):
			if f.ends_with(".json") and _is_armor_shape(f.get_basename().to_lower()):
				var n := f.get_basename()
				infantry.append({"id": "%s:%s" % [p, n], "shape": "%s:%s" % [p, n], "name": n.capitalize(), "pack": p})
	return infantry


static func _is_armor_shape(ln: String) -> bool:
	if ln.begins_with("statue"):
		return false
	return ln.ends_with("armor") or ln.ends_with("female") or ln.begins_with("armor") or ln.ends_with("_male")


## One row per game (long games split), shortest first in a row, tallest rows furthest back.
func _make_rows(mechs: Array) -> Array:
	var by_pack := {}
	for v in mechs:
		if not by_pack.has(v.pack):
			by_pack[v.pack] = []
		by_pack[v.pack].append(v)
	var rows := []
	for p in by_pack:
		var list: Array = by_pack[p]
		list.sort_custom(func(a, b): return a.get("height_m", 0.0) < b.get("height_m", 0.0))
		for i in range(0, list.size(), PER_ROW):
			rows.append(list.slice(i, i + PER_ROW))
	rows.sort_custom(func(a, b): return _avg_h(a) > _avg_h(b))
	return rows


## Places the rows, each centred on the widest; returns (widest row, tallest figure).
func _place_rows(rows: Array) -> Vector2:
	var widest := 1.0
	var tallest := 1.0
	var z := -ROW_GAP * rows.size()
	var row_nodes := []
	for r in rows:
		var x := 0.0
		var nodes := []
		for v in r:
			var start_count := get_child_count()
			var w := _place(v, Vector3(x, 0, z), true)
			nodes.append(get_child(start_count))
			tallest = maxf(tallest, w.y)
			x += w.x + GAP
		row_nodes.append([nodes, x - GAP])
		widest = maxf(widest, x - GAP)
		z += ROW_GAP
	for rn in row_nodes:
		for n in rn[0]:
			n.position.x += (widest - float(rn[1])) * 0.5
	return Vector2(widest, tallest)


func _place_infantry(infantry: Array, widest: float) -> void:
	var ix := 0.0
	var placed := []
	for v in infantry:
		var start_count := get_child_count()
		var w := _place(v, Vector3(ix, 0, INFANTRY_ROW_Z), false)
		placed.append(get_child(start_count))
		ix += w.x + INFANTRY_GAP
	for n in placed:
		n.position.x += (widest - (ix - INFANTRY_GAP)) * 0.5


## Places one figure with its left edge at `pos.x`; returns its (width, height).
func _place(v: Dictionary, pos: Vector3, back_row: bool) -> Vector2:
	var root := Node3D.new()
	add_child(root)
	if not back_row:
		root.set_meta("front", true)
	# shapes face -z (forward); turn them around so they face the camera
	var holder := Node3D.new()
	holder.rotation.y = PI
	root.add_child(holder)
	var inst := ShapeInstance.new()
	holder.add_child(inst)
	inst.build(Assets.shape(v.get("shape", v.id)), 0)
	var aabb := _bounds_in(root)
	holder.position = Vector3(-aabb.position.x, -aabb.position.y, -aabb.get_center().z)
	root.position = pos
	var h := aabb.size.y
	var lbl := Label3D.new()
	lbl.text = "%s\n%.1f m" % [v.get("name", v.id), h]
	lbl.font_size = 64
	lbl.pixel_size = (0.012 if back_row else 0.005)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.outline_size = 12
	lbl.position = Vector3(aabb.size.x * 0.5, h + (0.8 if back_row else 0.5), 0.0)
	root.add_child(lbl)
	return Vector2(aabb.size.x, h)


## Visible geometry bounds in `space`'s coordinates (includes scales/rotations below it).
func _bounds_in(space: Node3D) -> AABB:
	var first := true
	var box := AABB()
	for mi in space.find_children("*", "MeshInstance3D", true, false):
		if not mi.visible:
			continue
		var xf: Transform3D = space.global_transform.affine_inverse() * mi.global_transform
		var b: AABB = xf * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _avg_h(r: Array) -> float:
	var t := 0.0
	for v in r:
		t += float(v.get("height_m", 0.0))
	return t / maxf(r.size(), 1)


func _build_camera(row_width: float, tallest: float, depth: float) -> void:
	height = int(width * 0.42)
	get_window().size = Vector2i(width, height)
	var cam := Camera3D.new()
	cam.fov = 28.0
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var aspect := float(width) / float(height)
	var hfov := 2.0 * atan(tan(deg_to_rad(cam.fov) * 0.5) * aspect)
	var dist := (row_width * 0.55) / tan(hfov * 0.5) + 8.0
	# low, slightly elevated "group photo" camera that keeps the infantry row in frame
	cam.far = 2000
	add_child(cam)
	cam.look_at_from_position(Vector3(row_width * 0.5, tallest * 1.1, 6.0 + dist * 0.8), Vector3(row_width * 0.5, tallest * 0.28, -depth * 0.4))
	cam.current = true


func _build_environment() -> void:
	SceneLighting.add_studio_environment(self, {"background": SKY, "ambient": Color(0.7, 0.7, 0.7)})
	SceneLighting.apply_sun_direction(Vector3(-0.4, -0.75, -0.5))
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(2000, 200)
	floor_mi.mesh = pm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.40, 0.36)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	floor_mi.material_override = m
	add_child(floor_mi)


## Crops to the figures (pixels that are neither sky nor floor) plus a margin, keeping a strip of floor.
func _make_cropped(img: Image) -> Image:
	var flo := img.get_pixel(img.get_width() / 2, img.get_height() - 2)
	var minx := img.get_width()
	var miny := img.get_height()
	var maxx := 0
	var maxy := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if _close(c, SKY) or _close(c, flo):
				continue
			minx = mini(minx, x)
			maxx = maxi(maxx, x)
			miny = mini(miny, y)
			maxy = maxi(maxy, y)
	if maxx <= minx:
		return img
	var m := int(img.get_width() * 0.02)
	var r := Rect2i(maxi(minx - m, 0), maxi(miny - m, 0), 0, 0)
	r.end = Vector2i(mini(maxx + m, img.get_width()), mini(maxy + m, img.get_height()))
	return img.get_region(r)


func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) < 0.05
