class_name VarunaMap
extends RefCounted
## The extraction map "Varuna's Fall" (docs/design/extraction_map_varuna.md): a map of the engine schema
## (docs/formats/map_schema.md) made at load time from res://engine/extraction/maps/varuna.json (our own layout, terrain
## recipe and spawn data; VarunaTerrain makes the heightfield). It exists only when the Tribes 2 pack is installed: its
## interiors, shapes, sky and terrain textures are referenced from that pack at run time, never copied.
##   MapBuilder.list_maps / load_map offer and load it as "tribes2:varuna".
## The result adds to the plain schema: "sites" (faction, size, spawn areas, headcount), "loot_areas", "exfil" zones.

const FILE := "res://engine/extraction/maps/varuna.json"
const PACK := "tribes2"
const MAP_ID := "tribes2:varuna"
const SKY_FACES := {"front": "sky_front.png", "right": "sky_right.png", "back": "sky_back.png",
	"left": "sky_left.png", "top": "sky_top.png", "bottom": "sky_bottom.png"}
const FALLBACK_COLOURS := {"north_mountains": Color(0.62, 0.64, 0.68), "central_plains": Color(0.55, 0.5, 0.36),
	"south_lakes": Color(0.3, 0.42, 0.25), "east_uplands": Color(0.5, 0.4, 0.3), "west_caves": Color(0.38, 0.3, 0.25),
	"cliff": Color(0.35, 0.32, 0.3)}
const MASK_STEP := 32.0
const SPAWN_TRIES := 14
const SPAWN_CLEAR_OF_PADS := 25.0
## Brightness of the tiles of the baked colour map (each tile picks one): the repeat has no uniform tone.
const TILE_GAINS := [0.96, 1.0, 1.04]

static var _cache := {}
static var _definition := {}


## True when the map can be offered: the Tribes 2 pack (its interiors, sky and textures) is installed.
static func is_available() -> bool:
	return Assets.has_pack(PACK)


static func is_varuna(map_id: String) -> bool:
	return map_id == MAP_ID


static func load_definition() -> Dictionary:
	if _definition.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("VarunaMap: cannot read %s" % FILE)
			return {}
		_definition = d
	return _definition


## The maps/_index.json row of the map (MapBuilder.list_maps).
static func make_index_row() -> Dictionary:
	var d := load_definition()
	var b: Dictionary = d.bounds
	var sites: Array = d.sites
	return {"id": "varuna", "name": str(d.name), "modes": [], "remake_modes": [ExtractionRules.MODE], "terrain": true,
		"spawns": {}, "size_m": [float(b.max[0]) - float(b.min[0]), float(b.max[1]) - float(b.min[1])],
		"interiors": sites.size(), "stations": 0, "factions": sites.map(func(s: Dictionary) -> String: return str(s.faction))}


## Drops the built map (tests).
static func reload() -> void:
	_cache = {}
	_definition = {}


## The map dictionary (map.json schema) with "_pack" and "_dir" set; {} when the pack is missing.
static func make_map() -> Dictionary:
	if not is_available():
		return {}
	if _cache.is_empty():
		_cache = _expand(load_definition())
	var m: Dictionary = _cache.duplicate()
	var sky_dir := Assets.path("maps/%s" % str(m.sky_from), PACK)
	m["_pack"] = PACK
	m["_dir"] = sky_dir
	return m


## The terrain recipe object behind the cached map (tests, spawn checks).
static func get_terrain() -> VarunaTerrain:
	make_map()
	return _cache.get("_terrain")


static func _expand(d: Dictionary) -> Dictionary:
	var terrain := VarunaTerrain.make(d)
	var td: Dictionary = d.terrain
	var m := {"pack": PACK, "id": d.id, "name": d.name, "source": "res://engine/extraction/maps/varuna.json", "modes": [],
		"remake_modes": [ExtractionRules.MODE], "bounds": d.bounds, "sky_from": d.sky_from, "_terrain": terrain,
		"flight_ceiling": 700.0}
	m["terrain"] = {"heights_data": terrain.make_heights(), "size": [terrain.samples, terrain.samples], "square": terrain.square,
		"origin": [terrain.origin.x, terrain.origin.y], "height_scale": 1.0, "albedo_data": _bake_albedo(terrain, d),
		"albedo_repeat": 1.0, "detail": td.get("detail", {})}
	var env: Dictionary = (d.environment as Dictionary).duplicate(true)
	env["skybox_faces"] = SKY_FACES
	env["skybox_layout"] = MapEnvironment.LAYOUT_TORQUE
	env["water"] = d.water
	if env.has("day_cycle"):   # the raid's day (its night weighs the site timers) also drives the picture
		(env.day_cycle as Dictionary)["timing"] = SiteSpawner.rules().get("day", {})
	m["environment"] = env
	var out := {"interiors": [], "statics": [], "stations": [], "mode_objects": [], "power_groups": [], "sites": [], "loot_areas": []}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(d.seed)
	var faction_ids := []
	for s in d.sites:
		if s.get("flag", false) and not faction_ids.has(str(s.faction)):
			faction_ids.append(str(s.faction))
	m["exfil"] = d.exfil.map(func(e: Dictionary) -> Dictionary: return {"label": e.label, "pos": e.pos})
	for s in d.sites:
		LoadKeepAlive.pump()
		_add_site(out, d, terrain, s, faction_ids.find(str(s.faction)), rng)
	m.merge(out)
	m["spawns"] = []
	m["rules"] = d.rules
	m["cybrid_siege"] = d.get("cybrid_siege", {})   # the hidden easter egg (CybridSiege)
	m["notes"] = str(d.notes)
	return m


# ------------------------------------------------------------------ sites

static func _find_pad_height(terrain: VarunaTerrain, c: Vector2) -> float:
	for p in terrain.pads:
		if (p.center as Vector2).is_equal_approx(c):
			return float(p.height)
	return terrain.height_at(c.x, c.y)


static func _add_site(out: Dictionary, d: Dictionary, terrain: VarunaTerrain, s: Dictionary, team: int, rng: RandomNumberGenerator) -> void:
	var c := Vector2(float(s.pos[0]), float(s.pos[1]))
	var y := _find_pad_height(terrain, c)
	var yaw := float(s.get("yaw", 0.0))
	for o in s.interiors:
		var p := c + Vector2(float(o.dx), float(o.dz)).rotated(deg_to_rad(-yaw))
		out.interiors.append({"shape": o.shape, "pos": [p.x, y, p.y], "yaw": yaw + float(o.yaw), "scale": 1.0, "collide": true})
	for o in s.get("outposts", []):
		var p := c + Vector2(float(o.dx), float(o.dz))
		out.interiors.append({"shape": o.shape, "pos": [p.x, _find_pad_height(terrain, p), p.y], "yaw": 0.0, "scale": 1.0, "collide": true})
	for o in s.get("pontoons", []):
		var p := c + Vector2(float(o.dx), float(o.dz)).rotated(deg_to_rad(-yaw))
		out.interiors.append({"shape": o.shape, "pos": [p.x, terrain.water_level + 0.4, p.y], "yaw": yaw + float(o.yaw), "scale": 1.0, "collide": true})
	var group: int = out.power_groups.size()
	out.power_groups.append({"name": str(s.id), "parent": -1, "provides_power": false})
	if not s.get("bare", false):
		_add_equipment(out, d, s, c, y, yaw, group, team)
	var size_rules: Dictionary = d.site_sizes[str(s.size)]
	var loot := _make_ring_points(c, float(s.pad_radius) * 0.45, int(size_rules.loot_areas), rng.randf() * TAU)
	for p in loot:
		out.loot_areas.append({"pos": [p.x, p.y], "site": str(s.id), "faction": str(s.faction)})
	out.sites.append({"id": str(s.id), "name": str(s.name), "faction": str(s.faction), "size": str(s.size), "pos": [c.x, y, c.y],
		"pad_radius": float(s.pad_radius), "headcount": size_rules.headcount, "reinforce_s": size_rules.reinforce_s,
		"vehicles": int(size_rules.get("vehicles", 0)), "flag": bool(s.get("flag", false)),
		"spawn_areas": _make_spawn_areas(terrain, d, s, c, int(size_rules.areas), rng)})


static func _make_ring_points(c: Vector2, radius: float, n: int, start: float) -> Array:
	var out := []
	for i in n:
		var a := start + TAU * i / maxf(n, 1)
		out.append(c + Vector2(cos(a), sin(a)) * radius)
	return out


static func _add_equipment(out: Dictionary, d: Dictionary, s: Dictionary, c: Vector2, y: float, yaw: float, group: int, team: int) -> void:
	var kinds: Dictionary = d.equipment_kinds
	var barrels: Array = d.turret_barrels
	var ring := float(s.ring_m)
	var turret_n := 0
	for e in d.equipment[str(s.size)]:
		var k: Dictionary = kinds[str(e.kind)]
		var a := deg_to_rad(float(e.a) + yaw)
		var p := c + Vector2(cos(a), sin(a)) * ring
		var rec := {"kind": k.kind, "shape": k.shape, "pos": [p.x, y, p.y], "team": team, "datablock": k.datablock,
			"yaw": rad_to_deg(-a) + 90.0, "name": str(s.name), "power_group": group, "spec": k.spec}
		if str(e.kind) == "turret":
			var b: Dictionary = barrels[turret_n % barrels.size()]
			turret_n += 1
			rec["barrel"] = b.barrel
			rec["spec"] = "%s+%s" % [k.spec, b.spec]
		elif k.has("barrel"):
			rec["barrel"] = k.barrel
			rec["spec"] = "%s+%s" % [k.spec, k.barrel_spec]
		out.stations.append(rec)
		if str(e.kind) == "generator" and s.get("flag", false):
			out.mode_objects.append({"kind": "generator", "team": team, "pos": [p.x, y, p.y], "yaw": rec.yaw, "datablock": k.datablock,
				"modes": [], "name": "%s generator" % str(s.name), "id": out.mode_objects.size() + 1})
	if s.get("flag", false):
		var fa := deg_to_rad(250.0 + yaw)
		var fp := c + Vector2(cos(fa), sin(fa)) * ring * 0.8
		out.statics.append({"shape": "tribes2:ext_flagstand", "pos": [fp.x, y, fp.y], "yaw": 0.0, "scale": 1.0, "collide": true})
		out.mode_objects.append({"kind": "flag", "team": team, "pos": [fp.x, y + 0.6, fp.y], "yaw": 0.0, "datablock": "Flag",
			"modes": [], "name": "%s flag" % str(s.faction), "shape": "tribes2:flag", "id": out.mode_objects.size() + 1})


## Spawn areas round a site: spread on a ring outside the pad, on walkable ground (gentle slope, dry), clear of other
## pads and out of sight of every exfil zone that is within sight range (VarunaTerrain.is_line_clear).
static func _make_spawn_areas(terrain: VarunaTerrain, d: Dictionary, s: Dictionary, c: Vector2, n: int, rng: RandomNumberGenerator) -> Array:
	var out := []
	var start := rng.randf() * TAU
	for i in n:
		var base := start + TAU * i / n
		var found := false
		for t in SPAWN_TRIES:
			var a := base + deg_to_rad(18.0) * t * (1 if t % 2 == 0 else -1)
			var r := float(s.pad_radius) + 35.0 + 14.0 * t
			var p := c + Vector2(cos(a), sin(a)) * r
			if is_spawn_ok(terrain, d, s, p):
				out.append([p.x, p.y])
				found = true
				break
		if not found:
			out.append([c.x, c.y + float(s.pad_radius) + 20.0])
	return out


static func is_spawn_ok(terrain: VarunaTerrain, d: Dictionary, s: Dictionary, p: Vector2) -> bool:
	var b: Dictionary = d.bounds
	if p.x < float(b.min[0]) + 100.0 or p.x > float(b.max[0]) - 100.0 or p.y < float(b.min[1]) + 100.0 or p.y > float(b.max[1]) - 100.0:
		return false
	if terrain.grid_height(p.x, p.y) < terrain.water_level + 1.5 or terrain.grid_slope(p.x, p.y) > 0.45:
		return false
	for o in terrain.pads:
		var oc: Vector2 = o.center
		if oc.distance_to(p) < float(o.radius) + SPAWN_CLEAR_OF_PADS and not (oc.distance_to(Vector2(float(s.pos[0]), float(s.pos[1]))) < 1.0):
			return false
	var rules: Dictionary = d.rules
	for e in d.exfil:
		var ep := Vector2(float(e.pos[0]), float(e.pos[1]))
		var dist := ep.distance_to(p)
		if dist < float(rules.spawn_min_exfil_m):
			return false
		if dist < float(rules.spawn_exfil_sight_m) and terrain.is_line_clear(p, ep):
			return false
	return true


# ------------------------------------------------------------------ terrain textures

## The baked colour map: each region's Tribes 2 terrain patch (a crop of another Tribes 2 map's baked colour map, loaded
## from the installed pack) tiled over the map and blended by the region weights, cliffs on steep slopes.
static func _bake_albedo(terrain: VarunaTerrain, d: Dictionary) -> Image:
	var td: Dictionary = d.terrain
	var size := int(td.get("albedo_size", 768))
	var tex: Dictionary = d.textures
	var world := float(d.bounds.max[0]) - float(d.bounds.min[0])
	var m_per_px := world / size
	var patch_px := int(tex.get("patch_px", 256))
	var tile := maxi(int(round(patch_px / m_per_px)), 8)
	var ids: Array = terrain.regions.map(func(r: Dictionary) -> String: return str(r.id))
	var base := _make_tiled(tex[ids[0]], ids[0], size, tile, patch_px)
	var grid := _make_mask_grid(terrain)
	var cumulative := PackedFloat32Array()
	cumulative.resize(grid.n * grid.n)
	for i in ids.size():
		LoadKeepAlive.pump()
		var w: PackedFloat32Array = grid.w[i]
		var alpha := PackedFloat32Array()
		alpha.resize(w.size())
		for k in w.size():
			cumulative[k] += w[k]
			alpha[k] = w[k] / maxf(cumulative[k], 0.0001)
		if i == 0:
			continue
		var layer := _make_tiled(tex[ids[i]], ids[i], size, tile, patch_px)
		base.blend_rect(_make_faded(layer, alpha, grid.n), Rect2i(0, 0, size, size), Vector2i.ZERO)
	var cliff := _make_tiled(tex["cliff"], "cliff", size, tile, patch_px)
	var slope_alpha := PackedFloat32Array()
	slope_alpha.resize(terrain.samples * terrain.samples)
	var hs := terrain.make_heights()
	var s := terrain.samples
	var lo := float(tex.get("cliff_slope", 0.62))
	for row in range(1, s - 1):
		LoadKeepAlive.pump()
		for col in range(1, s - 1):
			var i := row * s + col
			var dx := hs[i + 1] - hs[i - 1]
			var dz := hs[i + s] - hs[i - s]
			slope_alpha[i] = smoothstep(lo, lo + 0.35, sqrt(dx * dx + dz * dz) / (2.0 * terrain.square))
	base.blend_rect(_make_faded(cliff, slope_alpha, s), Rect2i(0, 0, size, size), Vector2i.ZERO)
	return base


static func _make_mask_grid(terrain: VarunaTerrain) -> Dictionary:
	var n := int(ceil(terrain.square * (terrain.samples - 1) / MASK_STEP)) + 1
	var w := []
	for i in terrain.regions.size():
		var a := PackedFloat32Array()
		a.resize(n * n)
		w.append(a)
	for row in n:
		LoadKeepAlive.pump()
		for col in n:
			var ws := terrain.make_weights(terrain.origin.x + col * MASK_STEP, terrain.origin.y + row * MASK_STEP)
			for i in ws.size():
				w[i][row * n + col] = ws[i]
	return {"n": n, "w": w}


## `layer` with its alpha channel set to `alpha` (n x n values, scaled up to the layer's size): what blend_rect mixes in.
static func _make_faded(layer: Image, alpha: PackedFloat32Array, n: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(n * n * 4)
	for i in alpha.size():
		if i % 4096 == 0:
			LoadKeepAlive.pump()
		bytes[i * 4 + 3] = int(clampf(alpha[i], 0.0, 1.0) * 255.0)
	var mask := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, bytes)
	mask.resize(layer.get_width(), layer.get_height(), Image.INTERPOLATE_BILINEAR)
	var mask_bytes := mask.get_data()
	var out := layer.get_data()
	for i in range(3, out.size(), 4):
		if i % 65536 == 3:
			LoadKeepAlive.pump()
		out[i] = mask_bytes[i]
	return Image.create_from_data(layer.get_width(), layer.get_height(), false, Image.FORMAT_RGBA8, out)


static func _make_tiled(spec: Dictionary, region_id: String, size: int, tile: int, patch_px: int) -> Image:
	var patch := _load_patch(spec, region_id, patch_px)
	patch.resize(tile, tile, Image.INTERPOLATE_LANCZOS)
	var variants := _make_tile_variants(patch)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var row := 0
	for ty in range(0, size, tile):
		var col := 0
		for tx in range(0, size, tile):
			var h := _hash_cell(col, row, region_id.hash())
			img.blit_rect(variants[h % variants.size()], Rect2i(0, 0, tile, tile), Vector2i(tx, ty))
			col += 1
		row += 1
	return img


## The patch in its eight orientations (flips and quarter turns) each at three brightnesses, so neighbouring tiles
## differ in layout and tone instead of a mirrored checkerboard.
static func _make_tile_variants(patch: Image) -> Array[Image]:
	var turns: Array[Image] = [patch]
	var fx := patch.duplicate() as Image
	fx.flip_x()
	turns.append(fx)
	var cur := patch
	for _q in 3:
		cur = cur.duplicate() as Image
		cur.rotate_90(CLOCKWISE)
		turns.append(cur)
	var fy := patch.duplicate() as Image
	fy.flip_y()
	turns.append(fy)
	var out: Array[Image] = []
	for t in turns:
		for gain in TILE_GAINS:
			var v := t.duplicate() as Image
			for y in v.get_height():
				for x in v.get_width():
					var c := v.get_pixel(x, y)
					v.set_pixel(x, y, Color(minf(c.r * gain, 1.0), minf(c.g * gain, 1.0), minf(c.b * gain, 1.0), c.a))
			out.append(v)
	return out


static func _hash_cell(col: int, row: int, salt: int) -> int:
	return absi(hash(Vector3i(col, row, salt)))


## A square crop of another Tribes 2 map's baked colour map (spec {map, at}); a flat colour when the file is missing.
static func _load_patch(spec: Dictionary, region_id: String, patch_px: int) -> Image:
	var path := Assets.path("maps/%s/albedo.png" % str(spec.map), PACK)
	var src := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	var out := Image.create(patch_px, patch_px, false, Image.FORMAT_RGBA8)
	if src == null or src.get_width() < int(spec.at[0]) + patch_px or src.get_height() < int(spec.at[1]) + patch_px:
		out.fill(FALLBACK_COLOURS.get(region_id, Color(0.5, 0.45, 0.4)))
		return out
	src.convert(Image.FORMAT_RGBA8)
	return src.get_region(Rect2i(int(spec.at[0]), int(spec.at[1]), patch_px, patch_px))
