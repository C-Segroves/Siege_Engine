class_name TribesRepairBeam
extends MeshInstance3D
## The repair beam between a repairing soldier and the base object he works on (shown on every peer): a thin glowing
## cylinder stretched between the two points (the originals draw the RepairBolt / DefaultRepairBeam from the gun).

const COLOR := Color(0.35, 1.0, 0.55, 0.9)
## Where the beam starts on a soldier and ends on an object, above their origins (metres).
const SOLDIER_CHEST := 1.3
const OBJECT_MIDDLE := 1.5
const MIN_LENGTH := 0.05


static func make(parent: Node) -> TribesRepairBeam:
	var b := TribesRepairBeam.new()
	b.name = "RepairBeam"
	var cyl := CylinderMesh.new()
	cyl.top_radius = float(BaseRepairRules.feedback().get("beam_radius_m", 0.06))
	cyl.bottom_radius = cyl.top_radius
	cyl.height = 1.0
	cyl.radial_segments = 8
	cyl.rings = 1
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = COLOR
	cyl.material = mat
	b.mesh = cyl
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(b)
	return b


## Stretches the beam from `a` to `b` (world).
func apply_between(a: Vector3, b: Vector3) -> void:
	var d := b - a
	var length := d.length()
	visible = length > MIN_LENGTH
	if not visible:
		return
	var n := d / length
	var rot := Basis(Vector3.RIGHT, PI) if n.dot(Vector3.UP) < -0.9999 else Basis(Quaternion(Vector3.UP, n))
	global_transform = Transform3D(rot * Basis.from_scale(Vector3(1.0, length, 1.0)), (a + b) * 0.5)
