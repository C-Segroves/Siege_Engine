class_name TribesForceField
extends StaticBody3D
## A base force field (docs/TRIBES_BASE_EQUIPMENT.md section 2), powered like the rest of the base (TribesBase):
##   Tribes 2  ForceFieldBare: a box from its position (a corner) over its scale; ForceFieldBareData::gainPower
##             closes it, losePower opens it (scripts/forceField.cs). teamPermiable lets its own team through,
##             otherPermiable everyone else; it shows in the datablock's colour at baseTranslucency.
##   Tribes 1  the StaticShape ForceField: its shape's box, solid to everyone while powered.
## Who may pass is kept as collision exceptions on the vehicles and soldiers near it (apply_permeability).

const NODE_PREFIX := "FF_"
## Bodies closer than this to the field's centre get their pass-through rule refreshed (metres).
const PERMEABILITY_REACH := 30.0
## The T1 shape field's thickness when its shape is flat (metres).
const MIN_THICKNESS := 0.25

var team := -1
var power_group := -1
var team_permeable := false
var other_permeable := false
var powered := false
var _mesh: MeshInstance3D
var _collision: CollisionShape3D
var _excepted := {}          # instance id -> body with an exception


## The field of map entry `record` (map.json "force_fields") under `parent`.
static func make(parent: Node3D, record: Dictionary, pal: String) -> TribesForceField:
	var f := TribesForceField.new()
	f.transform = MapBuilder.make_transform(record)
	f.name = "%s%d_%d_%d" % [NODE_PREFIX, roundi(f.transform.origin.x), roundi(f.transform.origin.y), roundi(f.transform.origin.z)]
	f.team = int(record.get("team", -1))
	f.power_group = int(record.get("power_group", -1))
	f.team_permeable = bool(record.get("team_permeable", false))
	f.other_permeable = bool(record.get("other_permeable", false))
	parent.add_child(f)
	f._build_box(f._make_box(record, pal), record)
	return f


## The box in the field's own frame: Tribes 2 corner + size (Torque y north = engine -z); Tribes 1 its shape's bounds.
func _make_box(record: Dictionary, pal: String) -> AABB:
	if record.get("size") is Array:
		var s: Array = record.size
		return AABB(Vector3(0.0, 0.0, -float(s[2])), Vector3(float(s[0]), float(s[1]), float(s[2])))
	var shape := ShapeInstance.new()
	add_child(shape)
	shape.build(Assets.shape(str(record.get("shape", ""))), 0, pal)
	var box := TribesBaseObject.make_shape_bounds(self, shape)
	shape.queue_free()
	return box.grow(MIN_THICKNESS * 0.5) if box.size.length() > 0.0 else AABB(Vector3.ZERO, Vector3.ONE)


func _build_box(box: AABB, record: Dictionary) -> void:
	var shape := BoxShape3D.new()
	shape.size = box.size
	_collision = CollisionShape3D.new()
	_collision.shape = shape
	_collision.position = box.get_center()
	add_child(_collision)
	var mesh := BoxMesh.new()
	mesh.size = box.size
	var mat := StandardMaterial3D.new()
	var c: Array = record.get("color", [0.0, 0.55, 0.99])
	mat.albedo_color = Color(float(c[0]), float(c[1]), float(c[2]), float(record.get("translucency", 0.3)))
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	_mesh = MeshInstance3D.new()
	_mesh.mesh = mesh
	_mesh.position = box.get_center()
	add_child(_mesh)
	apply_power(false)


## Closed (solid, shown) while powered, open (gone) without power.
func apply_power(on: bool) -> void:
	powered = on
	_collision.set_deferred("disabled", not on)
	_mesh.visible = on


func is_closed() -> bool:
	return powered


## The field's box is drawn (closed).
func visible_box() -> bool:
	return _mesh.visible


## True when a body of `body_team` passes through the closed field.
func is_permeable_to(body_team: int) -> bool:
	return team_permeable if body_team == team and team >= 0 else other_permeable


## Refreshes the pass-through exceptions of the vehicles and soldiers near the field.
func apply_permeability(bodies: Array) -> void:
	var centre := global_transform * _collision.position
	for b in bodies:
		var body := b as PhysicsBody3D
		if body == null or body.global_position.distance_to(centre) > PERMEABILITY_REACH:
			continue
		var passes := is_permeable_to(int(body.get("team")))
		var id := body.get_instance_id()
		if passes and not _excepted.has(id):
			body.add_collision_exception_with(self)
			_excepted[id] = body
		elif not passes and _excepted.has(id):
			body.remove_collision_exception_with(self)
			_excepted.erase(id)
