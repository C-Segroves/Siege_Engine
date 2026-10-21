extends Node
## Promo stills driver: --game=<key> --cat=vehicles|infantry|mix --out=<png> [--title=..] [--sub=..]
const LineupScript := preload("res://tools/lineup.gd")
const TEAL_BG := Color8(4, 18, 22)
const AMBER := Color8(255, 222, 0)
const TEAL := Color8(173, 255, 250)
var game := ""
var cat := ""
var out := ""
var title := ""
var sub := ""
var per_row := 7


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--game="): game = a.substr(7)
		if a.begins_with("--cat="): cat = a.substr(6)
		if a.begins_with("--out="): out = a.substr(6)
		if a.begins_with("--title="): title = a.substr(8)
		if a.begins_with("--sub="): sub = a.substr(6)
		if a.begins_with("--per="): per_row = int(a.substr(6))
	var items := _select()
	print("stills: ", game, " ", cat, " ", items.map(func(v): return v.id))
	if items.is_empty():
		print("stills: EMPTY")
		get_tree().quit()
		return
	var lu: Node3D = LineupScript.new()
	lu.auto_save = false
	add_child(lu)
	SceneLighting.add_studio_environment(lu, {"background": TEAL_BG, "ambient": Color(0.62, 0.7, 0.72)})
	SceneLighting.apply_sun_direction(Vector3(-0.4, -0.75, -0.5))
	items.sort_custom(func(a, b): return a.get("height_m", 0.0) < b.get("height_m", 0.0))
	var rows := []
	var nrows := int(ceil(items.size() / float(per_row)))
	var each := int(ceil(items.size() / float(maxi(nrows, 1))))
	if items.any(func(v): return v.has("promo_row")):
		var g := {}
		for v in items:
			g[v.get("promo_row", 0)] = g.get(v.get("promo_row", 0), []) + [v]
		var ks := g.keys()
		ks.sort()
		for k in ks:
			rows.append(g[k])
	else:
		for i in range(0, items.size(), each):
			rows.append(items.slice(i, i + each))
	var widest := 1.0
	var row_info := []
	var y := 0.0
	var all_h := 0.0
	var first_rh := 0.0
	var last_feet := 0.0
	for r in rows:
		var x := 0.0
		var nodes := []
		var rh := 1.0
		for v in r:
			var sc := lu.get_child_count()
			var sz: Vector2 = lu._place(v, Vector3(x, y, 0), true)
			var n: Node3D = lu.get_child(sc)
			var k := float(v.get("promo_scale", 1.0))
			n.scale = Vector3.ONE * k
			sz *= k
			for l in n.find_children("*", "Label3D", false, false):
				l.visible = false
			nodes.append([n, sz.x, str(v.get("name", v.id)), sz.y])
			rh = maxf(rh, sz.y)
			x += sz.x + 2.4 * maxf(k, 1.0)
		row_info.append([nodes, x - 2.4 * 1.0, y])
		widest = maxf(widest, x - 2.4 * 1.0)
		var fl := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(widest + 40.0, 0.3, 8.0)
		fl.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color8(10, 52, 58)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fl.material_override = m
		fl.position = Vector3(0, y - 0.15, 0)
		lu.add_child(fl)
		row_info[row_info.size() - 1].append(fl)
		if first_rh == 0.0:
			first_rh = rh
		last_feet = y
		y -= rh * 1.0 + 3.2
		all_h += rh * 1.0 + 3.2
	var placed := []
	for ri in row_info:
		ri[3].scale.x = 1.0
		ri[3].position.x = widest * 0.5
		ri[3].mesh.size.x = widest + 6.0
		for p in ri[0]:
			p[0].position.x += (widest - ri[1]) * 0.5
		placed.append_array(ri[0])
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var total_h := all_h + 3.0
	cam.size = maxf(total_h * 1.3, widest * 1.12 * 9.0 / 16.0)
	cam.far = 3000
	lu.add_child(cam)
	cam.position = Vector3(widest * 0.5, (first_rh + last_feet - 2.0) * 0.5 + cam.size * 0.05, 100.0)
	cam.current = true
	var cl := CanvasLayer.new()
	add_child(cl)
	_label(cl, title, Vector2(70, 40), 64, AMBER)
	_label(cl, sub, Vector2(74, 118), 30, TEAL)
	await get_tree().create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	for p in placed:
		var n: Node3D = p[0]
		var foot := cam.unproject_position(n.global_position + Vector3(p[1] * 0.5, 0, 0))
		var l := _label(cl, p[2], foot, 20, TEAL)
		l.size = Vector2(240, 30)
		l.position = foot + Vector2(-120, 10)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out)
	print("stills: saved ", out)
	get_tree().quit()


func _label(parent: Node, t: String, pos: Vector2, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color(0, 0.05, 0.06))
	parent.add_child(l)
	return l


func _by(pack: String, f: Callable) -> Array:
	var a := []
	for v in Packs.vehicles.values():
		if v.pack == pack and f.call(v):
			a.append(v)
	return a


func _pick(pack: String, names: Array) -> Array:
	var a := []
	for n in names:
		var id := "%s:%s" % [pack, n]
		if Packs.vehicles.has(id):
			a.append(Packs.vehicles[id])
	return a


func _armors(pack: String) -> Array:
	var a := LineupScript._make_infantry_list().filter(func(v): return v.pack == pack)
	var o := []
	for v in a:
		var d: Dictionary = v.duplicate()
		d["promo_scale"] = 2.6 if cat == "infantry" else 3.0
		d["promo_row"] = 2
		o.append(d)
	return o


func _row(a: Array, r: int) -> Array:
	return a.map(func(v): var d: Dictionary = v.duplicate(); d["promo_row"] = r; return d)


func _select() -> Array:
	var herc := func(v): return v.get("category", "herc") == "herc" and String(v.get("kind", "herc")) == "herc" and not v.get("flyer", false) and float(v.get("height_m", 0)) < 30.0
	match [game, cat]:
		["es1", "vehicles"]: return _by("es1", herc)
		["bd", "vehicles"]: return _by("bd", herc)
		["es2", "vehicles"]: return _by("es2", herc)
		["starsiege", "vehicles"]:
			return _pick("starsiege", ["kn_basl", "kn_apoc", "kn_gorg", "kn_mino", "cin_apoc", "ha_apoc", "cy_adju", "cy_exec", "cy_prom", "kn_pala", "kn_disr", "kn_myrm", "cy_bolo", "kn_bans", "tr_bans"])
		["tribes", "vehicles"]: return _by("tribes", func(v): return v.get("category") == "vehicle")
		["tribes2", "vehicles"]: return _by("tribes2", func(v): return v.get("category") == "vehicle")
		["tribes", "infantry"]: return _armors("tribes").filter(func(v): return v.id.get_slice(":", 1) in ["larmor", "marmor", "harmor", "lfemale", "mfemale"])
		["tribes2", "infantry"]: return _armors("tribes2")
		["tribes_aa", "infantry"]: return _armors("tribes_aa")
		["tribes_aa", "vehicles"]: return _by("tribes_aa", func(v): return v.get("category") == "vehicle")
		["tribes_v", "infantry"]: return _armors("tribes_v")
		["mix", _]:
			var a := []
			a += _row(_pick("es1", ["RAPTOR", "APOLLO"]) + _pick("es2", ["OGRE", "PITBULL"]) + _pick("bd", ["STRYDER", "THOR"]) + _pick("starsiege", ["kn_apoc", "cy_adju", "kn_gorg"]), 0)
			a += _row(_pick("tribes2", ["SHRIKE", "BEOWULF", "JERICHO", "HAVOC"]) + _pick("tribes", ["LAPC"]) + _pick("starsiege", ["kn_pala", "cy_bolo"]), 1)
			a += _armors("tribes").filter(func(v): return v.id.ends_with("harmor")) + _armors("tribes2").filter(func(v): return v.id.ends_with("heavy_male") or v.id.ends_with("light_female"))
			a += _armors("tribes_aa").filter(func(v): return v.id.ends_with("medium_male"))
			return a
	return []
