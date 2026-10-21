class_name SiegeZoneFx
extends Node3D
## The safe area's wall as every peer sees it (CybridSiege state): a tall open cylinder at the circle's border, drawn with
## the siege_wall shader. It follows the host's state and glides between two updates.

const SHADER := preload("res://engine/shaders/siege_wall.gdshader")
const FLOOR_Y := -60.0
const TOP_Y := 900.0
const SEGMENTS := 128
const GLIDE_PER_S := 8.0

var _mesh: MeshInstance3D
var _centre := Vector2.ZERO
var _radius := 4400.0
var _shown_radius := 4400.0
var _shown_centre := Vector2.ZERO


func _ready() -> void:
	name = "SiegeZoneFx"
	_mesh = MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = SEGMENTS
	cylinder.rings = 1
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	_mesh.mesh = cylinder
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.extra_cull_margin = 16384.0
	_mesh.visible = false
	add_child(_mesh)


## The host's circle: centre (x, z) and radius; `shown` hides the wall (before the siege).
func apply_circle(centre: Vector2, radius: float, shown: bool) -> void:
	_centre = centre
	_radius = radius
	if shown and not _mesh.visible:
		_shown_centre = centre
		_shown_radius = radius
	_mesh.visible = shown


func _process(delta: float) -> void:
	if not _mesh.visible:
		return
	var k := minf(delta * GLIDE_PER_S, 1.0)
	_shown_centre = _shown_centre.lerp(_centre, k)
	_shown_radius = lerpf(_shown_radius, _radius, k)
	var height := TOP_Y - FLOOR_Y
	_mesh.scale = Vector3(_shown_radius, height, _shown_radius)
	_mesh.position = Vector3(_shown_centre.x, FLOOR_Y + height * 0.5, _shown_centre.y)
