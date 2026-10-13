class_name WeaponMount
extends RefCounted
## Where and how each original game hangs a weapon model on a vehicle (docs/formats/weapon_mounts.md):
## the hardpoint frame (a Marker3D under the vehicle node the original draws the weapon with, at the
## original attach point, oriented like that node), the native pod placement inside that frame and
## the muzzle (projectile origin) at the barrel.
##
## Frames come from the gun records:
##  - 3Space GL records (Earthsiege 1/2: "offset" + "mount_group"): the node of the Herc shape part
##    whose id is the GL mount id, at the GL offset (DBSIM 0x12c00 findPart + 0x12b58 rebinds the pod
##    to that node; 0xb918 = GL offset + pod push-out; 0xa308 moves the pod vertices there);
##  - explicit points ("attach_node" + "muzzle_units": Battledrome, Starsiege, Tribes): that node, at
##    that point;
##  - anything else: the shape's common locator markers, else the cockpit node.

const FRAME_NAME := "hardpoint%d"
const MUZZLE_NAME := "muzzle"
## Torque image shapes mark their barrel tip with this node (lower case).
const MUZZLE_NODE_NAME := "muzzlepoint"
## 3Space GL mount groups (DBSIM 0xbbd4, jump table 0x91240): the pod is pushed out of the GL point
## by its half extent: 0 up (+z), 1 down (-z), 2 left (-x), 3 right (+x); above 3 = internal, no pod.
const GROUP_TOP := 0
const GROUP_BOTTOM := 1
const GROUP_LEFT := 2
const GROUP_RIGHT := 3
const NODE_COCKPIT := 11
## Common 3Space locator markers used when a vehicle lists no mounts at all.
const FALLBACK_MOUNT_MARKERS := [8, 9, 10, 11, 18]


## One hardpoint frame per gun of `vdef` (gun order, never skipping a gun), built on shape `s`.
static func build_frames(vdef: Dictionary, s: ShapeInstance) -> Array:
	var out := []
	var guns: Array = vdef.get("guns", [])
	for i in guns.size():
		var g: Dictionary = guns[i]
		var f := Marker3D.new()
		f.name = FRAME_NAME % i
		_frame_parent(g, s).add_child(f)
		f.position = _frame_position(g)
		out.append(f)
	return out


static func _frame_parent(g: Dictionary, s: ShapeInstance) -> Node3D:
	if is_gl_record(g):
		return part_node(s, int(g.get("mount_node", -1)))
	if g.get("muzzle_units") is Array:
		return node_or_root(s, int(g.get("attach_node", -1)))
	return fallback_mount(s)


static func _frame_position(g: Dictionary) -> Vector3:
	if is_gl_record(g):
		return ShapeInstance.es_to_godot(g.offset)
	if g.get("muzzle_units") is Array:
		return ShapeInstance.es_to_godot(g.muzzle_units)
	return Vector3.ZERO


## True for an Earthsiege 1/2 GL gun record (mount id + offset + mount group).
static func is_gl_record(g: Dictionary) -> bool:
	return g.get("offset") is Array and g.has("mount_group")


## The node a 3Space part id hangs on (DBSIM 0x12c00: findPart(id)->node, part +4). findPart walks the
## whole part tree depth first, so a cell part (damage cell) matches by its own id before its pieces: the
## internal-gun mount id 5 is the torso's cell part on every ES1/ES2 Herc (node 11; Headhunter node 12).
## No such part, or a part without a node (-1): the shape root, as the muzzle code's fallback matrix
## (ES2 0x40e7d9, 0x6c572c).
static func part_node(s: ShapeInstance, part_id: int) -> Node3D:
	return node_or_root(s, make_part_node_index(s.shape, s.lod, part_id))


## Node index of part `part_id` in detail level `lod` of `shape` (see part_node); -1 when none.
static func make_part_node_index(shape: Dictionary, lod: int, part_id: int) -> int:
	var lods: Array = shape.get("lods", [])
	if lods.is_empty():
		return -1
	var detail: Dictionary = lods[clampi(lod, 0, lods.size() - 1)]
	var cells: Array = detail.get("cells", [])
	for piece in detail.get("pieces", []):
		var ci := int(piece.get("cell", -1))
		if ci >= 0 and ci < cells.size() and int(cells[ci].get("id", -1)) == part_id:
			return int(cells[ci].get("node", -1))
		if int(piece.get("id", -1)) == part_id:
			return int(piece.get("node", -1))
	return -1


## Node `index` of shape `s`, or `s` itself when the index is out of range (-1 = the shape's root).
static func node_or_root(s: ShapeInstance, index: int) -> Node3D:
	return s.nodes[index] if index >= 0 and index < s.nodes.size() else s


## The mount of a vehicle without gun records: a common locator marker, else the cockpit node.
static func fallback_mount(s: ShapeInstance) -> Node3D:
	for id in FALLBACK_MOUNT_MARKERS:
		if s.markers.has(id):
			return s.markers[id]
	return s.nodes[NODE_COCKPIT] if s.nodes.size() > NODE_COCKPIT else s


# ------------------------------------------------------------------ native pod placement

## Where a 3Space pod's origin sits relative to the GL point, in original units (x right, y forward,
## z up): DBSIM 0xbbd4 takes the weapon's half extent (record +0x46 x, +0x4a z; y always 0) and keeps
## only the component that points away from the Herc for the mount group.
static func make_pod_offset(wdef: Dictionary, group: int) -> Vector3:
	var m: Dictionary = wdef.get("model") if wdef.get("model") is Dictionary else {}
	var e: Array = m.get("pod_extent", []) if m.get("pod_extent") is Array else []
	var x := float(e[0]) if e.size() > 2 else 0.0
	var z := float(e[2]) if e.size() > 2 else 0.0
	match group:
		GROUP_TOP:
			return Vector3(0, 0, z)
		GROUP_BOTTOM:
			return Vector3(0, 0, -z)
		GROUP_LEFT:
			return Vector3(-x, 0, 0)
		GROUP_RIGHT:
			return Vector3(x, 0, 0)
	return Vector3.ZERO


## Native placement of a pod model on gun record `g` (model local units -> metres in the hardpoint
## frame), at the pod's own metric scale:
##  - 3Space: origin pushed out by the mount group's pod offset, no rotation, no mirroring (the mirrored /
##    rolled variants are separate MECHWPNS shapes per mount group);
##  - Starsiege: origin on the hardpoint, rolled about the forward axis by the hardpoint side
##    (Starsiege.exe 0x494dd0: T / I 0, B 180, L -90, R +90 degrees: the gun's top faces outward).
static func make_native_placement(wdef: Dictionary, g: Dictionary, own_scale: float) -> Transform3D:
	var scale := Basis.from_scale(Vector3.ONE * own_scale)
	if is_gl_record(g):
		var off := make_pod_offset(wdef, int(g.mount_group))
		return Transform3D(scale, ShapeInstance.es_to_godot([off.x, off.y, off.z]) * own_scale)
	return Transform3D(make_side_roll(g) * scale, Vector3.ZERO)


## Darkstar hardpoint side letters -> the outward direction of the gun's top (frame axes).
const SIDE_UP := {"T": Vector3.UP, "B": Vector3.DOWN, "L": Vector3.LEFT, "R": Vector3.RIGHT}


## Roll of a Starsiege gun about the forward axis that turns its top (+up) to the hardpoint side.
static func make_side_roll(g: Dictionary) -> Basis:
	var up: Vector3 = SIDE_UP.get(str(g.get("side", "")), Vector3.UP)
	return Basis(Vector3.BACK, Vector3.UP.signed_angle_to(up, Vector3.BACK))


## Direction (frame axes) in which the pod hangs off the hardpoint: up / down / left / right for the
## 3Space mount groups and the Starsiege sides, zero when the pod is centred on the point.
static func make_outward(g: Dictionary) -> Vector3:
	if g.get("side") is String:
		return SIDE_UP.get(str(g.side), Vector3.ZERO)
	if not is_gl_record(g):
		return Vector3.ZERO
	match int(g.mount_group):
		GROUP_TOP:
			return Vector3.UP
		GROUP_BOTTOM:
			return Vector3.DOWN
		GROUP_LEFT:
			return Vector3.LEFT
		GROUP_RIGHT:
			return Vector3.RIGHT
	return Vector3.ZERO


# ------------------------------------------------------------------ muzzles

## Muzzle point (model local units) of weapon `wdef` drawn as `model`: the model's own muzzle node
## (Torque "muzzlePoint": Tribes 2 getMuzzlePoint), else the weapon's own muzzle ("model.muzzle_units":
## 3Space record +0x40 in the pod frame, Starsiege weaponShot in the gun frame) when the model is its own,
## else the front centre of the pod geometry (barrel tip).
static func make_local_muzzle(wdef: Dictionary, model: ShapeInstance) -> Vector3:
	var node := _muzzle_node(model.shape)
	if node >= 0:
		return (WeaponPodFit.make_node_transforms(model.shape)[node] as Transform3D).origin
	var m: Dictionary = wdef.get("model", {}) if wdef.get("model") is Dictionary else {}
	if m.get("muzzle_units") is Array and str(model.shape.get("pack", "")) == str(wdef.get("pack", "")):
		return ShapeInstance.es_to_godot(m.muzzle_units)
	var box := WeaponPodFit.local_box(model.shape)
	var c := box.get_center()
	return Vector3(c.x, c.y, box.position.z)


static func _muzzle_node(shape: Dictionary) -> int:
	var nodes: Array = shape.get("nodes", [])
	for i in nodes.size():
		if str((nodes[i] as Dictionary).get("name", "")).to_lower() == MUZZLE_NODE_NAME:
			return i
	return -1


## Puts the muzzle marker of a hardpoint frame at the barrel tip of the model just attached to it
## (replaces an earlier one).
static func apply_muzzle(frame: Node3D, model: ShapeInstance, wdef: Dictionary) -> void:
	apply_muzzle_at(frame, model.transform * make_local_muzzle(wdef, model))


## Puts the muzzle marker of a hardpoint frame at `at` (frame space; replaces an earlier one).
static func apply_muzzle_at(frame: Node3D, at: Vector3) -> void:
	var old := frame.get_node_or_null(MUZZLE_NAME)
	if old != null:
		frame.remove_child(old)
		old.queue_free()
	var m := Marker3D.new()
	m.name = MUZZLE_NAME
	frame.add_child(m)
	m.position = at


## The projectile origin of a hardpoint: its muzzle marker, else the frame itself.
static func muzzle_of(frame: Node3D) -> Node3D:
	var m := frame.get_node_or_null(MUZZLE_NAME)
	return m if m != null else frame
