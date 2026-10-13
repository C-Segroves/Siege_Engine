class_name ArenaBuilder
extends RefCounted
## Builds a Battledrome arena (DOA data, see docs/formats/battledrome.md): enclosed dome with
## floor, ceiling and circular wall, obstacles and blaster turrets filtered by density setting,
## and start pads per side.

const PACK := "bd"
const DENSITY := {"NONE": 0, "FEW": 1, "SEVERAL": 2, "MANY": 3}
const LIGHT_LEVELS := {"BRIGHT": 1.0, "DIM": 0.6, "DARK": 0.3}
const ARENA_SIZES := 5
const DEFAULT_CEILING_UNITS := 8200.0
const BACKGROUND := Color(0.02, 0.02, 0.03)
const AMBIENT := Color(0.5, 0.5, 0.5)
const FOG_COLOUR := Color(0.05, 0.05, 0.07)
const FOG_DENSITY_DIM := 0.004
const FOG_DENSITY_DARK := 0.012
const SUN_DIR := Vector3(-0.3, -0.9, 0.3)
## Floor/wall colours are not decoded yet: neutral steel tones.
const FLOOR_COLOUR := Color(0.20, 0.21, 0.23)
const WALL_COLOUR := Color(0.33, 0.34, 0.37)
const CEILING_DARKEN := 0.4
const GRID_LIGHTEN := 0.25
const DISC_THICKNESS := 0.2
const DISC_OVERHANG := 1.02
const RADIAL_SEGMENTS := 64
## Boundary collision: a ring of boxes just outside the wall.
const WALL_BOXES := 48
const WALL_BOX_OVERLAP := 1.05
const WALL_BOX_DEPTH := 2.0
## Floor grid lines (for a sense of speed).
const GRID_STEP := 25.0
const GRID_HEIGHT := 0.05
## Extra starts on a ring so up to 24 pilots get distinct starts.
const RING_SPAWNS := 24
const RING_RADIUS_FACTOR := 0.7
const ANGLE_UNITS := 65536.0
const STYLES := 3


## settings: {size: 1..5, obstacles: "FEW", turrets: "FEW", lighting: "BRIGHT"|"DIM"|"DARK", style: 0..2}
static func build(parent: Node3D, settings: Dictionary) -> Dictionary:
	var idx := clampi(int(settings.get("size", 3)), 1, ARENA_SIZES)
	var a = Assets.load_json("arenas/arena%d.json" % idx, PACK)
	if a == null:
		push_error("Battledrome arena data missing")
		return {}
	var scale := Packs.metres_per_unit(PACK)
	var pal := "%s:%s" % [PACK, a.get("palettes", {}).get("normal", "NRMPAL")]
	var radius := float(a.radius) * scale
	var ceiling := float(a.get("ceiling_z", DEFAULT_CEILING_UNITS)) * scale
	var light: String = settings.get("lighting", "BRIGHT")
	var light_k: float = LIGHT_LEVELS.get(light, 1.0)
	_build_environment(parent, light, light_k)
	_build_shell(parent, radius, ceiling, light_k)
	var spawns := _place_objects(parent, a, settings, {"pal": pal, "scale": scale})
	spawns.append_array(_ring_spawns(radius))
	return {"palette": pal, "radius": radius, "ceiling": ceiling, "spawns": spawns, "name": a.get("name", "")}


static func _build_environment(parent: Node3D, light: String, light_k: float) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT * light_k
	env.fog_enabled = light != "BRIGHT"
	env.fog_light_color = FOG_COLOUR
	env.fog_density = FOG_DENSITY_DIM if light == "DIM" else FOG_DENSITY_DARK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var env_node := WorldEnvironment.new()
	env_node.environment = env
	parent.add_child(env_node)
	SceneLighting.apply_sun_direction(SUN_DIR)


## Start pads, obstacles (up to the obstacle density, in the chosen style) and turrets (up to the
## turret density). Returns the start pads' spawn transforms, the two sides' pads alternating (side 0, side 1, side 0
## ...): the original collects the pads per side and starts each side on one of its own (SIM 0x2AC74, battledrome.md
## section 6), so the first two pilots - a duel's opponents - start on opposite sides. ctx: {pal, scale}.
static func _place_objects(parent: Node3D, a: Dictionary, settings: Dictionary, ctx: Dictionary) -> Array[Transform3D]:
	var obst_level: int = DENSITY.get(settings.get("obstacles", "SEVERAL"), 2)
	var turret_level: int = DENSITY.get(settings.get("turrets", "FEW"), 1)
	var style := int(settings.get("style", randi() % STYLES))
	var pads_by_side := {}
	for o in a.get("objects", []):
		var r: Array = o.get("rot", [0, 0, 0])
		var xf := _object_transform(o, ctx.scale)
		var lvl := int(o.get("level", 0))
		match String(o.type):
			"start_pad":
				var side := int(o.get("side", 0))
				if not pads_by_side.has(side):
					pads_by_side[side] = []
				pads_by_side[side].append(Transform3D(Basis(Vector3.UP, -float(r[2]) / ANGLE_UNITS * TAU), xf.origin))
				WorldBuilder.place_static(parent, "%s:PAD" % PACK, xf, ctx.pal)
			"obstacle":
				if lvl <= obst_level:
					WorldBuilder.place_static(parent, "%s:%s" % [PACK, _obstacle_shape(a, int(o.shape), style)], xf, ctx.pal)
			"turret":
				if lvl <= turret_level:
					var turret_shape := "%s:%s" % [PACK, a.get("turret_shapes", {}).get("normal", "TURRET")]
					var t := ArenaTurret.create(parent, turret_shape, xf, ctx.pal, ctx.scale)
					t.side = int(o.get("side", 0))
					var wreck = a.get("turret_shapes", {}).get("destroyed")
					t.wreck_shape_id = "%s:%s" % [PACK, wreck] if wreck is String and wreck != "" else ""
	return interleave_sides(pads_by_side)


static func _object_transform(o: Dictionary, scale: float) -> Transform3D:
	var p: Array = o.pos
	var r: Array = o.get("rot", [0, 0, 0])
	var xf := ShapeInstance.tf_to_transform([r[0], r[1], r[2], 0, 0, 0])
	xf.origin = ShapeInstance.es_dir([p[0], p[1], p[2]]) * scale
	return xf


## Obstacle shape name: the arena's shape, or its variant for the chosen style.
static func _obstacle_shape(a: Dictionary, si: int, style: int) -> String:
	var variants: Array = a.get("shape_variants", [])
	var shapes: Array = a.get("shapes", [])
	if si < variants.size() and variants[si].size() > style:
		return variants[si][style]
	return String(shapes[si]).get_basename().to_upper()


## The pads of every side taken in turn (side order 0, 1, ...): pad 0 of each side, then pad 1 of each side ...
static func interleave_sides(pads_by_side: Dictionary) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var sides := pads_by_side.keys()
	sides.sort()
	var most := 0
	for side in sides:
		most = maxi(most, (pads_by_side[side] as Array).size())
	for k in most:
		for side in sides:
			if k < (pads_by_side[side] as Array).size():
				out.append(pads_by_side[side][k])
	return out


static func _ring_spawns(radius: float) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var ring := radius * RING_RADIUS_FACTOR
	for i in RING_SPAWNS:
		var ang := float(i) / RING_SPAWNS * TAU
		var pos := Vector3(cos(ang), 0, sin(ang)) * ring
		out.append(Transform3D(Basis(Vector3.UP, atan2(pos.x, pos.z)), pos))
	return out


## Floor, ceiling and the cylindrical boundary wall.
static func _build_shell(parent: Node3D, radius: float, ceiling: float, light_k: float) -> void:
	var floor_col := FLOOR_COLOUR * light_k
	var body := StaticBody3D.new()
	body.name = "ArenaShell"
	parent.add_child(body)
	var fcol := CollisionShape3D.new()
	fcol.shape = WorldBoundaryShape3D.new()
	body.add_child(fcol)
	body.add_child(_disc(radius, -DISC_THICKNESS * 0.5, floor_col))
	body.add_child(_disc(radius, ceiling + DISC_THICKNESS * 0.5, floor_col.darkened(CEILING_DARKEN)))
	body.add_child(_wall(radius, ceiling, WALL_COLOUR * light_k))
	_add_wall_collision(body, radius, ceiling)
	body.add_child(_floor_grid(radius, floor_col.lightened(GRID_LIGHTEN)))


static func _disc(radius: float, y: float, colour: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius * DISC_OVERHANG
	cyl.bottom_radius = radius * DISC_OVERHANG
	cyl.height = DISC_THICKNESS
	cyl.radial_segments = RADIAL_SEGMENTS
	mi.mesh = cyl
	mi.position.y = y
	mi.material_override = _flat(colour)
	return mi


static func _wall(radius: float, ceiling: float, colour: Color) -> MeshInstance3D:
	var wall := MeshInstance3D.new()
	var wm := CylinderMesh.new()
	wm.top_radius = radius
	wm.bottom_radius = radius
	wm.height = ceiling
	wm.radial_segments = RADIAL_SEGMENTS
	wm.cap_top = false
	wm.cap_bottom = false
	wall.mesh = wm
	wall.position.y = ceiling * 0.5
	var wmat := _flat(colour)
	wmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wall.material_override = wmat
	return wall


static func _add_wall_collision(body: StaticBody3D, radius: float, ceiling: float) -> void:
	for i in WALL_BOXES:
		var ang := float(i) / WALL_BOXES * TAU
		var c := CollisionShape3D.new()
		var b := BoxShape3D.new()
		b.size = Vector3(TAU * radius / WALL_BOXES * WALL_BOX_OVERLAP, ceiling, WALL_BOX_DEPTH)
		c.shape = b
		c.position = Vector3(cos(ang), 0, sin(ang)) * (radius + 1.0) + Vector3.UP * ceiling * 0.5
		c.rotation.y = -ang + PI / 2
		body.add_child(c)


static func _floor_grid(radius: float, colour: Color) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var k := -radius
	while k <= radius:
		var h := sqrt(maxf(radius * radius - k * k, 0.0))
		im.surface_add_vertex(Vector3(k, GRID_HEIGHT, -h))
		im.surface_add_vertex(Vector3(k, GRID_HEIGHT, h))
		im.surface_add_vertex(Vector3(-h, GRID_HEIGHT, k))
		im.surface_add_vertex(Vector3(h, GRID_HEIGHT, k))
		k += GRID_STEP
	im.surface_end()
	var lines := MeshInstance3D.new()
	lines.mesh = im
	lines.material_override = _flat(colour)
	return lines


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	return m
