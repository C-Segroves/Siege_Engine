class_name FxRing
extends MeshInstance3D
## Torque shockwave / splash ring (Tribes 2 ShockwaveData, SplashData; weapon_fx.md 7.2): a band of
## `segments` quads around the hit point whose inner edge runs at radius r(t) = radius_start + velocity t +
## acceleration t^2 / 2 and whose outer edge lies `width` further out and `height` higher (a flat ring when
## height is 0), the texture repeated `tex_wrap` times around it, coloured by the colors[] keyed at times[]
## over its lifetime, drawn additively. Oriented to the surface normal (orient_to_normal) or level.
## It frees itself when its life is over.

const DEFAULT_SEGMENTS := 16
const MIN_SEGMENTS := 3

var _ring := {}
var _age := 0.0
var _life := 0.5
var _segments := DEFAULT_SEGMENTS
var _mesh := ImmediateMesh.new()
var _material: StandardMaterial3D
var _gradient: Gradient
var _normal := Vector3.UP


## Builds the ring for a layer's `ring` block of `pack`; `normal` = the surface it lies on.
static func create(ring: Dictionary, pack: String, normal: Vector3) -> FxRing:
	var r := FxRing.new()
	r._setup(ring, pack, normal)
	return r


func _setup(ring: Dictionary, pack: String, normal: Vector3) -> void:
	_ring = ring
	_life = maxf(0.05, float(ring.get("lifetime", 0.5)))
	_segments = maxi(MIN_SEGMENTS, int(ring.get("segments", DEFAULT_SEGMENTS)))
	_gradient = _make_gradient(ring)
	var tex: Texture2D = null
	if ring.get("texture") is String and ring.texture != "":
		tex = FxLibrary.texture(str(ring.texture), pack, "rgba", "")
	_material = FxMaterials.make_unshaded(Color.WHITE, tex, true)
	if tex:
		_material.texture_repeat = true
	mesh = _mesh
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_normal = normal.normalized() if bool(ring.get("orient_to_normal", false)) and normal.length() > 0.001 else Vector3.UP


static func _make_gradient(ring: Dictionary) -> Gradient:
	var g := Gradient.new()
	var times: Array = ring.get("times", [0.0, 1.0])
	var colors: Array = ring.get("colors", [[1, 1, 1, 1]])
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for i in colors.size():
		var t := float(times[i]) if i < times.size() else 1.0
		g.add_point(t, FxLibrary.make_color(colors[i]))
	return g


func _ready() -> void:
	if absf(_normal.dot(Vector3.UP)) < 0.999:
		global_basis = Basis(Quaternion(Vector3.UP, _normal))
	_rebuild()


func _process(delta: float) -> void:
	_age += delta
	if _age >= _life:
		queue_free()
		return
	_rebuild()


func _radius(t: float) -> float:
	return maxf(0.0, float(_ring.get("radius_start", 0.0)) + float(_ring.get("velocity", 0.0)) * t
		+ 0.5 * float(_ring.get("acceleration", 0.0)) * t * t)


func _rebuild() -> void:
	var inner := _radius(_age)
	var outer := inner + float(_ring.get("width", 0.5))
	var height := float(_ring.get("height", 0.0))
	var wrap := maxf(1.0, float(_ring.get("tex_wrap", 1.0)))
	_material.albedo_color = _gradient.sample(clampf(_age / _life, 0.0, 1.0))
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in _segments + 1:
		var a := TAU * float(i) / _segments
		var dir := Vector3(cos(a), 0.0, sin(a))
		var u := wrap * float(i) / _segments
		_mesh.surface_set_uv(Vector2(u, 1.0))
		_mesh.surface_add_vertex(dir * inner)
		_mesh.surface_set_uv(Vector2(u, 0.0))
		_mesh.surface_add_vertex(dir * outer + Vector3.UP * height)
	_mesh.surface_end()
