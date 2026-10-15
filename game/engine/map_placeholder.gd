class_name MapPlaceholder
extends RefCounted
## Marker boxes for map placements whose shape a pack has not converted yet (a pack that sets
## "placeholder_shapes": true in pack.json, e.g. Aerial Assault until its .SHP shapes are decoded). The map entry's
## "marker" [x, y, z] gives the box size in metres (default DEFAULT_SIZE); the box stands on the entry's position.

const FLAG := "placeholder_shapes"
const DEFAULT_SIZE := Vector3(3, 3, 3)
const COLOR := Color(0.55, 0.58, 0.62)


## True when `shape_id` belongs to a placeholder pack and has no converted shape file.
static func is_unconverted(shape_id: String) -> bool:
	var sp := Assets.split_id(shape_id)
	if sp[0] == "" or not bool(Packs.packs.get(sp[0], {}).get(FLAG, false)):
		return false
	return not FileAccess.file_exists(Assets.path("shapes/%s.json" % sp[1], sp[0]))


## A box for map entry `o` under `parent` (a static body with a collision box when `collide`).
static func place(parent: Node3D, o: Dictionary, xf: Transform3D, collide: bool) -> StaticBody3D:
	var size := DEFAULT_SIZE
	if o.get("marker") is Array and (o.marker as Array).size() >= 3:
		size = Vector3(float(o.marker[0]), float(o.marker[1]), float(o.marker[2]))
	var body := StaticBody3D.new()
	body.name = "Placeholder"
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR
	box.material = mat
	mesh.mesh = box
	mesh.position.y = size.y * 0.5
	body.add_child(mesh)
	if collide:
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		col.position.y = size.y * 0.5
		body.add_child(col)
	parent.add_child(body)
	body.transform = xf
	return body
