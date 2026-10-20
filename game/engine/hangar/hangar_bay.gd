class_name HangarBay
extends Node3D
## The Herc hangar: one procedural industrial maintenance bay (concrete floor with painted bay
## markings, ribbed back wall with a blast door, crane, gantry + catwalks fitted around the Herc,
## tool racks, floodlights) in which any pack's Herc / Cybrid / infantry armor is shown at its true
## metric size. Built entirely from primitive geometry and procedural shaders (no original assets).
##
## Used by every Herc selection screen through HangarView (the ES1 shell's career hangar, the
## launcher's pickers / lobby / pre-mission hangar).
##   show_herc(vehicle_id, loadout)   builds the Herc like Battle does (ShapeInstance + weapon pods)
##   highlight_hardpoint(i)           glowing marker on hardpoint i (-1 = none)
##   set_caption(text)                caption shown by the HangarView overlay
##   frame_center                     where the Herc's centre sits on screen (0..1), for side panels
## The camera frames the Herc by its height, so a 2 m armor and a 14 m Starsiege Herc both fit.

signal caption_changed(text: String)

const SURFACE_SHADER := preload("res://engine/hangar/hangar_surface.gdshader")
const MARKER_SHADER := """
shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, blend_add;
uniform vec4 color : source_color = vec4(1.0, 0.8, 0.2, 1.0);
uniform float pulse = 0.0;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
}
void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float k = 0.5 + 0.5 * sin(TIME * 7.0);
	float ring = smoothstep(0.62, 0.72, r) * (1.0 - smoothstep(0.86, 0.98, r));
	float dot_ = 1.0 - smoothstep(0.18, 0.3, r);
	float a = (ring + dot_ * 0.8) * color.a * mix(1.0, 0.55 + 0.45 * k, pulse);
	ALBEDO = color.rgb * a;
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

## Light travel direction for the Herc's original 3Space lighting (global shader parameter):
## from the front, above and slightly left, like a studio key light.
const HANGAR_SUN := Vector3(0.35, -0.7, -0.62)

@export var turntable := true
@export var turn_rate := 0.22                 # rad/s
## Seconds after a manual orbit before the turntable resumes.
@export var idle_resume := 4.0

var vehicle_id := ""
var loadout: Array = []
## The skin the model is drawn in (SkinCatalog id, "" = default; apply_skin).
var skin := ""
var caption := ""
var herc_height := 8.0
var herc_radius := 3.0
## Screen position (0..1) of the Herc's centre, e.g. (0.4, 0.47) when a panel covers the right side.
var frame_center := Vector2(0.5, 0.5)
## Fraction of the view height the Herc fills.
var frame_fill := 0.78
## Default facing: a 3/4 front view.
var pose_yaw := -0.5
var orbit_yaw := 0.0
var orbit_pitch := deg_to_rad(9.0)
var zoom := 1.0

var camera: Camera3D
var vdef: Dictionary = {}
var model: ShapeInstance

var _pivot: Node3D                 # turntable: rotates Herc + plate
var _holder: Node3D                # centres the Herc on the plate
var _plate: MeshInstance3D
var _gantry: Node3D
var _markers: Node3D
var _marker_nodes: Array = []      # [MeshInstance3D, Label3D] per hardpoint
var _mounts: Array = []
var _muzzles := {}
var _weapon_models: Array = []
var _highlight := -1
var show_all_hardpoints := false
var _mats := {}
var _floor_mat: ShaderMaterial
var _marker_shader: Shader
var _idle := 1000.0
var _pending: Array = []


func _ready() -> void:
	_make_materials()
	_build_hall()
	_pivot = Node3D.new()
	_pivot.name = "Turntable"
	add_child(_pivot)
	_holder = Node3D.new()
	_pivot.add_child(_holder)
	_plate = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.height = 0.12
	cyl.radial_segments = 48
	_plate.mesh = cyl
	_plate.material_override = _mats.plate
	_pivot.add_child(_plate)
	_gantry = Node3D.new()
	_gantry.name = "Gantry"
	add_child(_gantry)
	_markers = Node3D.new()
	_markers.name = "Hardpoints"
	add_child(_markers)
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.near = 0.05
	camera.far = 260.0
	add_child(camera)
	camera.current = true
	RenderingServer.global_shader_parameter_set("sun_dir", HANGAR_SUN.normalized())
	_fit_bay()
	if not _pending.is_empty():
		var p: Array = _pending
		_pending = []
		show_herc(str(p[0]), p[1])


# ================================================================== public API

## Shows the model in skin `skin_id` (SkinCatalog; "" = its default), rebuilding it when the skin changes.
func apply_skin(skin_id: String) -> void:
	if skin_id == skin:
		return
	skin = skin_id
	if model != null:
		var shown := vehicle_id
		vehicle_id = ""
		show_herc(shown, loadout)


## Shows vehicle `p_vehicle_id` (any pack; a bare shape id works too, e.g. "tribes:larmor") with
## weapon ids per hardpoint. A changed loadout on the same vehicle only swaps the weapon pods.
func show_herc(p_vehicle_id: String, p_loadout: Array = []) -> void:
	if not is_inside_tree() or _pivot == null:
		_pending = [p_vehicle_id, p_loadout.duplicate()]
		return
	if p_vehicle_id == vehicle_id and model != null:
		if p_loadout != loadout:
			loadout = p_loadout.duplicate()
			_attach_weapons()
		return
	vehicle_id = p_vehicle_id
	loadout = p_loadout.duplicate()
	_clear_model()
	if vehicle_id == "":
		return
	vdef = Packs.vehicle(vehicle_id)
	var shape_id := str(vdef.get("shape", vdef.get("id", vehicle_id))) if not vdef.is_empty() else vehicle_id
	var sdef := Assets.shape(shape_id)
	if (sdef.get("lods", [{}])[0] as Dictionary).get("pieces", []).is_empty():
		return
	model = ShapeInstance.new()
	model.name = "Herc"
	model.texture_overrides = SkinCatalog.make_texture_overrides(str(sdef.get("id", "")), skin)
	_holder.add_child(model)
	model.build(sdef, 0, Packs.default_palette(str(sdef.get("pack", "es1"))))
	_muzzles = HercModel.build_mounts(vdef, model)
	HercAnimator.new(vdef, model).apply_stand()
	_attach_weapons()
	model.position = Vector3(0, -model.lowest_point() * model.scale.y, 0)
	_measure()
	_fit_bay()
	_pivot.rotation.y = PI + pose_yaw
	_idle = 1000.0


func clear() -> void:
	vehicle_id = ""
	_clear_model()


## Glowing marker on hardpoint i (gun order, like loadouts); -1 hides it.
func highlight_hardpoint(i: int) -> void:
	_highlight = i
	_update_markers()


func set_caption(text: String) -> void:
	caption = text
	caption_changed.emit(text)


func hardpoint_count() -> int:
	return LoadoutEditor.hardpoint_masks(vdef).size() if not vdef.is_empty() else 0


## World position of hardpoint i (null when the Herc has none).
func hardpoint_position(i: int) -> Variant:
	if _mounts.is_empty() or i < 0:
		return null
	var n: Node3D = _mounts[i % _mounts.size()]
	return n.global_position if is_instance_valid(n) else null


## Hardpoints in viewport pixels: [[gun index, Vector2], ...] (only those in front of the camera).
func hardpoint_screen_points() -> Array:
	var out: Array = []
	for i in hardpoint_count():
		var p: Variant = hardpoint_position(i)
		if p is Vector3 and not camera.is_position_behind(p):
			out.append([i, camera.unproject_position(p)])
	return out


## Mouse orbit (radians) and zoom (factor) - the turntable pauses for a moment.
func orbit(dyaw: float, dpitch: float) -> void:
	orbit_yaw = wrapf(orbit_yaw + dyaw, -PI, PI)
	orbit_pitch = clampf(orbit_pitch + dpitch, deg_to_rad(-5.0), deg_to_rad(60.0))
	_idle = 0.0


func zoom_by(f: float) -> void:
	zoom = clampf(zoom * f, 0.5, 3.0)
	_idle = 0.0


## Back to the default 3/4 view, turntable stopped at the start pose when `hold` is set.
func reset_view(hold := false) -> void:
	orbit_yaw = 0.0
	orbit_pitch = deg_to_rad(9.0)
	zoom = 1.0
	if _pivot:
		_pivot.rotation.y = PI + pose_yaw
	turntable = not hold


# ================================================================== frame loop

func _process(delta: float) -> void:
	_idle += delta
	if turntable and _idle > idle_resume and model != null:
		_pivot.rotation.y = wrapf(_pivot.rotation.y + turn_rate * delta, -PI, PI)
	_update_camera()
	_update_markers()


func _update_camera() -> void:
	if camera == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	var t := tan(deg_to_rad(camera.fov * 0.5))
	var half_v := herc_height * 0.5 / frame_fill
	var half_h := herc_radius * 1.15 / 0.8
	var dist := maxf(half_v / t, half_h / (t * aspect)) + herc_radius * 0.6
	dist /= zoom
	var target := Vector3(0, herc_height * 0.5, 0)
	var off := Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * dist
	camera.position = target + off
	camera.look_at(target, Vector3.UP)
	camera.h_offset = (0.5 - frame_center.x) * 2.0 * dist * t * aspect
	camera.v_offset = (frame_center.y - 0.5) * 2.0 * dist * t


# ================================================================== the Herc

func _clear_model() -> void:
	if model:
		model.queue_free()
		model = null
	vdef = {}
	_mounts = []
	_muzzles = {}
	_weapon_models = []
	for c in _markers.get_children():
		c.queue_free()
	_marker_nodes = []


func _attach_weapons() -> void:
	for w in _weapon_models:
		if is_instance_valid(w):
			(w as Node).queue_free()
	_weapon_models = []
	if model == null:
		return
	_mounts = HercModel.mount_nodes(vdef, model, _muzzles) if not vdef.is_empty() else [model]
	HercModel.show_baked_pods(vdef, model)
	var guns: Array = vdef.get("guns", [])
	var cat := str(vdef.get("category", "herc"))
	for i in mini(loadout.size(), guns.size()):
		var wid := str(loadout[i]) if loadout[i] != null else ""
		if wid == "":
			continue
		var wdef := Packs.weapon(wid)
		if wdef.is_empty() or str(wdef.get("category", "herc")) != cat:
			continue   # weapon families never mix
		# same pods as in battle: native, fitted from another game, or a stand-in (HercModel)
		var m := HercModel.weapon_model(vdef, i, wdef, model.palette_name)
		if m == null:
			continue   # internal mount or a pod baked into the Herc shape
		HercModel.attach_weapon_model(_mounts[i % _mounts.size()], m, vdef)
		_weapon_models.append(m)
	_build_markers()


## Height / footprint of the Herc in turntable space; centres it on the plate.
func _measure() -> void:
	var box := AABB()
	var first := true
	var inv := _holder.global_transform.affine_inverse()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if not m.is_visible_in_tree() or m.mesh == null:
			continue
		var bb: AABB = (inv * m.global_transform) * m.mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	if first:
		box = AABB(Vector3(-1, 0, -1), Vector3(2, 4, 2))
	var c := box.get_center()
	model.position.x -= c.x
	model.position.z -= c.z
	herc_height = maxf(box.size.y, 0.5)
	herc_radius = maxf(Vector2(box.size.x, box.size.z).length() * 0.5, 0.4)


func _build_markers() -> void:
	for c in _markers.get_children():
		c.queue_free()
	_marker_nodes = []
	if _marker_shader == null:
		_marker_shader = Shader.new()
		_marker_shader.code = MARKER_SHADER
	var sz := clampf(herc_height * 0.085, 0.25, 1.3)
	for i in hardpoint_count():
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(sz, sz)
		mi.mesh = q
		var mat := ShaderMaterial.new()
		mat.shader = _marker_shader
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		_markers.add_child(mi)
		var l := Label3D.new()
		l.text = str(i + 1)
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0012
		l.font_size = 40
		l.outline_size = 10
		l.modulate = Color(1.0, 0.85, 0.3)
		l.outline_modulate = Color(0, 0, 0, 0.85)
		l.visible = false
		l.render_priority = 2
		_markers.add_child(l)
		_marker_nodes.append([mi, l, mat, sz])


func _update_markers() -> void:
	for i in _marker_nodes.size():
		var e: Array = _marker_nodes[i]
		var mi: MeshInstance3D = e[0]
		var l: Label3D = e[1]
		var mat: ShaderMaterial = e[2]
		var on := i == _highlight or show_all_hardpoints
		var p: Variant = hardpoint_position(i)
		if not on or not p is Vector3:
			mi.visible = false
			l.visible = false
			continue
		var sel := i == _highlight
		mi.visible = true
		mi.global_position = p
		mi.scale = Vector3.ONE * (1.5 if sel else 0.8)
		mat.set_shader_parameter("color", Color(1.0, 0.82, 0.2, 1.0) if sel else Color(0.3, 0.75, 1.0, 0.6))
		mat.set_shader_parameter("pulse", 1.0 if sel else 0.0)
		l.visible = sel
		l.global_position = (p as Vector3) + Vector3.UP * float(e[3]) * 0.9


# ================================================================== the hall

func _surface(kind: int, base: Color, rust: float, panel := Vector2(2.4, 1.6), metal := 0.55, rust_col := Color(0.42, 0.18, 0.07)) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("kind", kind)
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("rust_color", rust_col)
	m.set_shader_parameter("rust_amount", rust)
	m.set_shader_parameter("panel_size", panel)
	m.set_shader_parameter("metallic_amount", metal)
	return m


func _emissive(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _make_materials() -> void:
	_mats.steel = _surface(0, Color(0.22, 0.27, 0.33), 0.32)
	_mats.steel_dark = _surface(0, Color(0.11, 0.13, 0.16), 0.18, Vector2(4.0, 3.0), 0.4)
	_mats.door = _surface(0, Color(0.27, 0.32, 0.38), 0.4, Vector2(3.0, 2.5), 0.6)
	_mats.paint = _surface(3, Color(0.62, 0.29, 0.07), 0.45, Vector2(1.8, 1.2), 0.3)
	_mats.olive = _surface(3, Color(0.24, 0.28, 0.2), 0.3, Vector2(1.2, 0.8), 0.2)
	_mats.hazard = _surface(2, Color(0.8, 0.6, 0.1), 0.3)
	_mats.grate = _surface(4, Color(0.34, 0.37, 0.4), 0.0)
	_mats.plate = _surface(4, Color(0.2, 0.23, 0.26), 0.0)
	_mats.hose = _surface(3, Color(0.06, 0.06, 0.06), 0.0, Vector2(0.5, 0.5), 0.0)
	_floor_mat = _surface(1, Color(0.36, 0.36, 0.35), 0.0)
	_mats.floor = _floor_mat
	_mats.lamp_warm = _emissive(Color(1.0, 0.72, 0.4), 4.0)
	_mats.lamp_cool = _emissive(Color(0.55, 0.75, 1.0), 3.0)
	_mats.beacon = _emissive(Color(1.0, 0.35, 0.08), 5.0)


# ---------------------------------------------------------------- batched primitive geometry

var _unit_box: BoxMesh
var _unit_cyl: CylinderMesh


func _batch_add(batch: Dictionary, key: String, mesh: Mesh, xf: Transform3D) -> void:
	if not batch.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		batch[key] = st
	(batch[key] as SurfaceTool).append_from(mesh, 0, xf)


func _box(batch: Dictionary, key: String, center: Vector3, size: Vector3, b := Basis()) -> void:
	if _unit_box == null:
		_unit_box = BoxMesh.new()
	_batch_add(batch, key, _unit_box, Transform3D(b * Basis.from_scale(size), center))


func _cyl(batch: Dictionary, key: String, center: Vector3, radius: float, height: float, b := Basis()) -> void:
	if _unit_cyl == null:
		_unit_cyl = CylinderMesh.new()
		_unit_cyl.top_radius = 0.5
		_unit_cyl.bottom_radius = 0.5
		_unit_cyl.height = 1.0
		_unit_cyl.radial_segments = 12
		_unit_cyl.rings = 1
	_batch_add(batch, key, _unit_cyl, Transform3D(b * Basis.from_scale(Vector3(radius * 2.0, height, radius * 2.0)), center))


## A square beam from a to b.
func _beam(batch: Dictionary, key: String, a: Vector3, b: Vector3, thick: float) -> void:
	var d := b - a
	var ln := d.length()
	if ln < 0.001:
		return
	var y := d / ln
	var x := y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	_box(batch, key, (a + b) * 0.5, Vector3(thick, ln, thick), Basis(x, y, z))


func _commit(batch: Dictionary, parent: Node3D, shadows := true) -> void:
	for key in batch:
		var st: SurfaceTool = batch[key]
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = _mats[key]
		mi.name = str(key)
		if not shadows:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)


const HALL_X := 28.0       # side walls at +-HALL_X
const BACK_Z := -18.0      # back wall
const FRONT_Z := 44.0
const ROOF_Y := 32.0


func _build_hall() -> void:
	var hall := Node3D.new()
	hall.name = "Hall"
	add_child(hall)
	var b := {}
	# floor
	_box(b, "floor", Vector3(0, -0.25, 13), Vector3(HALL_X * 2.0, 0.5, FRONT_Z - BACK_Z))
	# back wall: panels, ribs, beams, blast door with hazard frame
	_box(b, "steel", Vector3(0, ROOF_Y * 0.5, BACK_Z - 0.5), Vector3(HALL_X * 2.0, ROOF_Y, 1.0))
	var x := -HALL_X + 2.0
	while x < HALL_X - 1.0:
		if absf(x) > 10.5:
			_box(b, "steel_dark", Vector3(x, ROOF_Y * 0.5, BACK_Z + 0.3), Vector3(0.7, ROOF_Y, 0.9))
		x += 3.5
	for y in [7.0, 15.0, 23.0]:
		_box(b, "steel_dark", Vector3(0, y, BACK_Z + 0.5), Vector3(HALL_X * 2.0, 0.9, 1.3))
	_box(b, "door", Vector3(0, 10.5, BACK_Z + 0.15), Vector3(19.0, 21.0, 0.5))
	_box(b, "steel_dark", Vector3(0, 10.5, BACK_Z + 0.45), Vector3(0.18, 21.0, 0.2))
	for y in [3.5, 7.0, 10.5, 14.0, 17.5]:
		_box(b, "steel_dark", Vector3(0, y, BACK_Z + 0.45), Vector3(19.0, 0.25, 0.15))
	for sx in [-1.0, 1.0]:
		_box(b, "hazard", Vector3(sx * 10.2, 10.5, BACK_Z + 0.7), Vector3(1.2, 21.0, 0.7))
	_box(b, "hazard", Vector3(0, 21.6, BACK_Z + 0.7), Vector3(21.6, 1.2, 0.7))
	_box(b, "paint", Vector3(0, 23.0, BACK_Z + 1.3), Vector3(21.6, 0.5, 0.5))
	# pipes along the back wall
	var rz := Basis(Vector3.FORWARD, PI * 0.5)
	_cyl(b, "paint", Vector3(0, 2.6, BACK_Z + 1.3), 0.28, HALL_X * 2.0, rz)
	_cyl(b, "steel", Vector3(0, 3.4, BACK_Z + 1.2), 0.18, HALL_X * 2.0, rz)
	_cyl(b, "olive", Vector3(0, 25.5, BACK_Z + 1.2), 0.4, HALL_X * 2.0, rz)
	# side walls with ribs and a high walkway
	for sx in [-1.0, 1.0]:
		_box(b, "steel", Vector3(sx * (HALL_X + 0.5), ROOF_Y * 0.5, 13), Vector3(1.0, ROOF_Y, FRONT_Z - BACK_Z))
		var z := BACK_Z + 2.0
		while z < FRONT_Z:
			_box(b, "steel_dark", Vector3(sx * (HALL_X - 0.3), ROOF_Y * 0.5, z), Vector3(0.9, ROOF_Y, 0.7))
			z += 4.0
		_box(b, "steel_dark", Vector3(sx * (HALL_X - 1.0), 7.0, 13), Vector3(2.0, 0.3, FRONT_Z - BACK_Z))
		_box(b, "paint", Vector3(sx * (HALL_X - 2.0), 8.0, 13), Vector3(0.1, 0.1, FRONT_Z - BACK_Z))
		_box(b, "hazard", Vector3(sx * (HALL_X - 2.0), 7.05, 13), Vector3(0.1, 0.3, FRONT_Z - BACK_Z))
	# roof and trusses
	_box(b, "steel_dark", Vector3(0, ROOF_Y + 0.5, 13), Vector3(HALL_X * 2.0, 1.0, FRONT_Z - BACK_Z))
	for z in [-12.0, -4.0, 4.0, 12.0, 20.0, 28.0]:
		_box(b, "steel_dark", Vector3(0, ROOF_Y - 1.0, z), Vector3(HALL_X * 2.0, 1.0, 0.6))
		_box(b, "steel_dark", Vector3(0, ROOF_Y - 3.5, z), Vector3(HALL_X * 2.0, 0.4, 0.4))
		var tx := -HALL_X + 3.5
		while tx < HALL_X:
			_beam(b, "steel_dark", Vector3(tx, ROOF_Y - 3.5, z), Vector3(tx + 3.5, ROOF_Y - 1.0, z), 0.25)
			tx += 7.0
		_box(b, "lamp_cool", Vector3(0, ROOF_Y - 3.8, z), Vector3(10.0, 0.15, 0.3))
	# crane: rails, bridge, trolley
	for sx in [-1.0, 1.0]:
		_box(b, "paint", Vector3(sx * 7.0, 27.5, 13), Vector3(0.8, 1.2, FRONT_Z - BACK_Z))
	_box(b, "paint", Vector3(0, 26.6, -1.0), Vector3(16.0, 1.4, 1.6))
	_box(b, "hazard", Vector3(0, 26.6, -0.15), Vector3(16.0, 0.5, 0.12))
	_box(b, "steel_dark", Vector3(0, 25.4, -1.0), Vector3(2.6, 1.2, 2.6))
	# warm strip lights high on the back wall
	for sx in [-1.0, 1.0]:
		_box(b, "lamp_warm", Vector3(sx * 19.0, 23.6, BACK_Z + 1.2), Vector3(12.0, 0.25, 0.25))
	# tool racks, crates, gas bottles, barrels
	for sx in [-1.0, 1.0]:
		_rack(b, Vector3(sx * (HALL_X - 2.2), 0, -12.0), sx)
		_rack(b, Vector3(sx * (HALL_X - 2.2), 0, -4.5), sx)
		for k in 5:
			_cyl(b, "olive" if k % 2 == 0 else "paint", Vector3(sx * (HALL_X - 1.6), 0.85, 2.0 + k * 0.7), 0.28, 1.7)
		for k in 3:
			_cyl(b, "paint" if k != 1 else "steel", Vector3(sx * (14.0 + k * 1.3), 0.6, -14.5 + (k % 2) * 1.1), 0.45, 1.2)
		_box(b, "olive", Vector3(sx * 15.5, 0.9, 6.0), Vector3(2.4, 1.8, 1.6))
		_box(b, "paint", Vector3(sx * 15.5, 2.15, 6.0), Vector3(1.6, 0.7, 1.2))
		_box(b, "hazard", Vector3(sx * 13.0, 0.5, 14.0), Vector3(0.5, 1.0, 0.5))
		_box(b, "hazard", Vector3(sx * 13.0, 0.5, 18.0), Vector3(0.5, 1.0, 0.5))
	# floodlight fixtures
	for fx in _flood_positions():
		var p: Vector3 = fx[0]
		_box(b, "steel_dark", p + Vector3(0, 0.4, 0), Vector3(1.4, 0.8, 1.4))
		_box(b, "lamp_warm" if fx[2] else "lamp_cool", p, Vector3(1.1, 0.12, 1.1))
	_commit(b, hall)
	_lights(hall)
	_environment(hall)
	# bay number painted on the floor
	var l := Label3D.new()
	l.text = "BAY 07"
	l.font_size = 220
	l.pixel_size = 0.01
	l.modulate = Color(0.85, 0.62, 0.1, 0.75)
	l.outline_size = 0
	l.rotation = Vector3(-PI * 0.5, 0, 0)
	l.position = Vector3(0, 0.02, 0)
	l.name = "BayNumber"
	l.shaded = true
	hall.add_child(l)


func _rack(b: Dictionary, base: Vector3, sx: float) -> void:
	var w := 6.0
	var d := 1.6
	var h := 6.0
	for px in [-w * 0.5, w * 0.5]:
		for pz in [-d * 0.5, d * 0.5]:
			_box(b, "paint", base + Vector3(pz * sx, h * 0.5, px), Vector3(0.15, h, 0.15))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(absf(base.z) * 13.0 + (7.0 if sx > 0 else 0.0))
	for k in 4:
		var y := 0.2 + k * 1.9
		_box(b, "steel_dark", base + Vector3(0, y, 0), Vector3(d, 0.1, w))
		if k == 3:
			break
		var z := -w * 0.5 + 0.4
		while z < w * 0.5 - 0.6:
			var cw := rng.randf_range(0.6, 1.4)
			var ch := rng.randf_range(0.5, 1.5)
			if rng.randf() < 0.8:
				_box(b, ["olive", "paint", "steel", "olive"][rng.randi() % 4], base + Vector3(0, y + 0.05 + ch * 0.5, z + cw * 0.5), Vector3(d * 0.8, ch, cw * 0.9))
			z += cw + 0.15


## [position, aim point, warm]
func _flood_positions() -> Array:
	return [
		[Vector3(-11, 21, 17), Vector3(0, 4, 0), true],
		[Vector3(11, 21, 17), Vector3(0, 4, 0), true],
		[Vector3(0, 24, -10), Vector3(0, 5, 1), false],
		[Vector3(-18, 13, -6), Vector3(0, 3, 0), false],
	]


func _lights(hall: Node3D) -> void:
	var k := 0
	for fx in _flood_positions():
		var p: Vector3 = fx[0]
		var aim: Vector3 = fx[1]
		var s := SpotLight3D.new()
		s.position = p
		hall.add_child(s)
		s.look_at(aim, Vector3.UP if absf((aim - p).normalized().y) < 0.99 else Vector3.FORWARD)
		s.spot_range = 60.0
		s.spot_angle = 26.0 if k < 2 else 30.0
		s.spot_angle_attenuation = 1.6
		s.light_color = Color(1.0, 0.82, 0.6) if fx[2] else Color(0.6, 0.75, 1.0)
		s.light_energy = 12.0 if k < 2 else 6.0
		s.shadow_enabled = k < 2
		k += 1
	# warm work lights at the back corners, cool fill from the roof
	for sx in [-1.0, 1.0]:
		var o := OmniLight3D.new()
		o.position = Vector3(sx * 20.0, 6.0, BACK_Z + 3.0)
		o.omni_range = 16.0
		o.light_color = Color(1.0, 0.6, 0.3)
		o.light_energy = 2.2
		hall.add_child(o)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0, 20, 14)
	fill.omni_range = 40.0
	fill.light_color = Color(0.5, 0.62, 0.85)
	fill.light_energy = 1.2
	hall.add_child(fill)


func _environment(hall: Node3D) -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.36, 0.44, 0.58)
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05
	SceneLighting.apply_scene_light(Color.WHITE, env.ambient_light_color, true)   # palette models undo the FILMIC curve
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.2
	env.fog_enabled = true
	env.fog_light_color = Color(0.1, 0.13, 0.18)
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.0
	we.environment = env
	hall.add_child(we)


# ---------------------------------------------------------------- gantry fitted to the Herc

## Rebuilds the gantry, catwalks, hoses, crane hook and floor markings for the current Herc size.
func _fit_bay() -> void:
	if _gantry == null:
		return
	for c in _gantry.get_children():
		c.queue_free()
	var h := herc_height
	var r := herc_radius
	var gx := maxf(r * 0.95 + 1.6, 2.4)
	var zb := -maxf(r * 0.8 + 1.4, 2.2)
	var zf := maxf(r * 0.8 + 1.4, 2.2)
	var ch := maxf(h * 1.08, 3.2)
	var b := {}
	for sx in [-1.0, 1.0]:
		for z in [zb, zf]:
			_box(b, "steel", Vector3(sx * gx, ch * 0.5, z), Vector3(0.45, ch, 0.45))
			_box(b, "hazard", Vector3(sx * gx, 0.6, z), Vector3(0.5, 1.2, 0.5))
			_box(b, "beacon", Vector3(sx * gx, ch + 0.15, z), Vector3(0.25, 0.3, 0.25))
		_box(b, "steel", Vector3(sx * gx, ch, (zb + zf) * 0.5), Vector3(0.4, 0.4, zf - zb + 0.45))
		# X braces between the columns
		_beam(b, "steel_dark", Vector3(sx * gx, 0.2, zb), Vector3(sx * gx, ch * 0.5, zf), 0.14)
		_beam(b, "steel_dark", Vector3(sx * gx, ch * 0.5, zb), Vector3(sx * gx, 0.2, zf), 0.14)
	_box(b, "steel", Vector3(0, ch, zb), Vector3(gx * 2.0 + 0.45, 0.4, 0.4))
	# catwalks (and hoses) only around Herc-sized machines; armor gets a plain fitting frame
	var levels: Array = [h * 0.42, h * 0.8] if h > 6.0 else ([h * 0.62] if h > 3.5 else [])
	for y in levels:
		var yy: float = y
		var span := zf - zb
		var zc := (zb + zf) * 0.5
		for sx in [-1.0, 1.0]:
			var cx: float = sx * (gx - 0.75)
			_box(b, "grate", Vector3(cx, yy, zc), Vector3(1.5, 0.1, span))
			_box(b, "hazard", Vector3(sx * (gx - 1.5), yy - 0.05, zc), Vector3(0.06, 0.2, span))
			for rx in [gx + 0.05, gx - 1.5]:
				_box(b, "paint", Vector3(sx * rx, yy + 1.05, zc), Vector3(0.07, 0.07, span))
				_box(b, "paint", Vector3(sx * rx, yy + 0.55, zc), Vector3(0.05, 0.05, span))
				var pz := zb
				while pz <= zf + 0.01:
					_box(b, "paint", Vector3(sx * rx, yy + 0.53, pz), Vector3(0.07, 1.05, 0.07))
					pz += maxf(span / 3.0, 1.0)
		_box(b, "grate", Vector3(0, yy, zb - 0.75), Vector3(gx * 2.0, 0.1, 1.5))
		_box(b, "paint", Vector3(0, yy + 1.05, zb - 1.5), Vector3(gx * 2.0, 0.07, 0.07))
	# umbilical hoses from the upper catwalk to the Herc's back
	var top: float = levels.back() if not levels.is_empty() else -1.0
	for sx in ([-1.0, 1.0] if top > 0.0 else []):
		var a := Vector3(sx * (gx - 1.4), top + 0.4, zb * 0.3)
		var e := Vector3(sx * r * 0.35, h * 0.72, zb * 0.35)
		var mid := (a + e) * 0.5 + Vector3(0, -minf(h * 0.12, 1.2), 0)
		_beam(b, "hose", a, mid, 0.12)
		_beam(b, "hose", mid, e, 0.12)
	# crane hook above the Herc
	var hook_y := minf(h + 2.2, 24.0)
	_box(b, "steel_dark", Vector3(0, (hook_y + 25.0) * 0.5, -1.0), Vector3(0.08, 25.0 - hook_y, 0.08))
	_box(b, "paint", Vector3(0, hook_y, -1.0), Vector3(0.9, 1.0, 0.6))
	_box(b, "hazard", Vector3(0, hook_y - 0.2, -0.68), Vector3(0.9, 0.3, 0.05))
	_commit(b, _gantry)
	# floor markings and the turntable plate follow the bay size
	var ring := r * 1.05 + 0.3
	_floor_mat.set_shader_parameter("bay", Vector3(gx + 1.0, zf + 1.0, ring))
	(_plate.mesh as CylinderMesh).top_radius = ring - 0.15
	(_plate.mesh as CylinderMesh).bottom_radius = ring - 0.15
	_plate.position.y = 0.0
	var num := get_node_or_null("Hall/BayNumber") as Label3D
	if num:
		num.position = Vector3(0, 0.02, zf + 3.2)
		num.pixel_size = clampf(gx * 0.0009, 0.002, 0.007)
