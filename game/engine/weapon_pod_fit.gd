class_name WeaponPodFit
extends RefCounted
## Weapon pod models on any Herc hardpoint (docs/formats/campaign_availability.md section 4,
## docs/formats/weapon_mounts.md section 6).
##
## Reference pod: per host hardpoint, the box (metres, in the hardpoint frame of WeaponMount) of the pod
## the host game itself draws there: Battledrome the pod baked into the Herc at that bay; Earthsiege the
## host's own MECHWPNS pod of the size class and visual family (the pod of median length) in the
## variant and push-out of the hardpoint's mount group; Starsiege its own pod at the hardpoint. A game
## without a pod of that size borrows the median of the other games' boxes, hung off the hardpoint the
## same way. A foreign model is scaled uniformly so its length matches the reference, its back on the
## reference's back face, its inner face on the reference's inner face (the side facing the Herc) and
## centred across.

## ES1/ES2 weapon pod library: WEAPONS.DAT shape index per mount group (gameplay.md section 4).
const LIBRARY_SHAPE := "%s:MECHWPNS_%d"
const FAMILIES := ["gun", "launcher", "pod"]
## Pod lengths when no installed game has a pod of a size class: ES1 native pods ATC20 3.5 m (S),
## ATC35 4.7 m (M), ATC50 6.2 m (L); X = 1.25 x L.
const FALLBACK_LENGTH_M := {"S": 3.5, "M": 4.7, "L": 6.2, "X": 7.8}
## Fallback box proportions: width = 0.12 x length, a third of the length behind the hardpoint
## (ES1 LAS100: 319 of 949 units behind its mount node).
const FALLBACK_WIDTH := 0.12
const FALLBACK_BACK := 0.33
const MIN_LENGTH := 0.001
## Procedural stand-in pods (original shape units, 256 per metre): body + barrel / rack / pod.
const STAND_IN_PARTS := {
	"gun": [[Vector3(-77, -307, -77), Vector3(77, 154, 77)], [Vector3(-20, 154, -20), Vector3(20, 563, 20)]],
	"launcher": [[Vector3(-154, -128, -102), Vector3(154, 128, 102)]],
	"pod": [[Vector3(-90, -256, -90), Vector3(90, 256, 90)], [Vector3(-26, -307, 90), Vector3(26, 154, 140)]],
}
const STAND_IN_COLOR := Color(0.42, 0.44, 0.46)
## Starsiege weapon shapes name their per-detail-level root pieces "baseA 32" / "baseB16" ...: on most
## pods a flat one- or two-polygon strut down to the hardpoint, which another game's Herc does not
## need; on some (wg_las, wg_hlas) it is the gun body itself (10 polygons), which stays.
const MAX_STRUT_POLYS := 2
const MOUNT_BASE_PATTERN := "^base[a-z]\\s*\\d+$"
const POD_SUFFIX := "#pod"

static var _local_boxes := {}   # shape id -> AABB in the shape's local units
static var _has_shape := {}     # shape id -> bool (file exists with geometry)
static var _refs := {}          # "pack|size|family" -> {"box": AABB, "weapon": id or ""}
static var _pod_shapes := {}    # shape id -> shape without mount-base pieces
static var _stand_in_material: StandardMaterial3D
static var _mount_base_regex: RegEx


## Forgets measured shapes and reference boxes (after the catalog is reloaded).
static func clear_cache() -> void:
	_local_boxes.clear()
	_has_shape.clear()
	_refs.clear()
	_pod_shapes.clear()


## Shape of a pod mounted on another game's Herc: the weapon's shape without its own hardpoint
## strut pieces (unchanged when it has none, or when they are all it has).
static func foreign_pod_shape(shape_id: String) -> Dictionary:
	if _pod_shapes.has(shape_id):
		return _pod_shapes[shape_id]
	var shape := Assets.shape(shape_id)
	var lods := []
	var stripped := false
	for lod in shape.get("lods", []):
		var keep: Array = lod.get("pieces", []).filter(func(p): return not _is_mount_base(p))
		stripped = stripped or keep.size() != lod.get("pieces", []).size()
		var copy: Dictionary = lod.duplicate()
		copy["pieces"] = keep if not keep.is_empty() else lod.get("pieces", [])
		lods.append(copy)
	var out := shape
	if stripped:
		out = shape.duplicate()
		out["lods"] = lods
		out["id"] = shape_id + POD_SUFFIX
	_pod_shapes[shape_id] = out
	return out


static func _is_mount_base(piece: Dictionary) -> bool:
	if _mount_base_regex == null:
		_mount_base_regex = RegEx.create_from_string(MOUNT_BASE_PATTERN)
	return (piece.get("polys", []) as Array).size() <= MAX_STRUT_POLYS 		and _mount_base_regex.search(str(piece.get("name", "")).to_lower()) != null


# ------------------------------------------------------------------ weapon pod shapes

## Pod shape id of weapon `w` for mount group `group` ("" when it has no model): ES1 WEAPONS.DAT
## shape groups, else the engine schema's model.mount_shapes.
static func model_shape_id(w: Dictionary, group: int) -> String:
	var ids := _mount_shape_ids(w)
	if ids.is_empty():
		return ""
	var id := str(ids[clampi(group, 0, ids.size() - 1)])
	return id if id != "" and has_geometry(id) else ""


static func _mount_shape_ids(w: Dictionary) -> Array:
	var out := []
	for n in w.get("shapes", []):
		out.append(LIBRARY_SHAPE % [w.pack, int(n)] if int(n) >= 0 else "")
	if not out.is_empty():
		return out
	var model = w.get("model")
	return model.get("mount_shapes", []) if model is Dictionary else []


## True if the shape exists in its pack and has geometry (no error for missing shapes).
static func has_geometry(shape_id: String) -> bool:
	if not _has_shape.has(shape_id):
		var p := Assets.split_id(shape_id)
		var ok := FileAccess.file_exists(Assets.path("shapes/%s.json" % p[1], p[0]))
		_has_shape[shape_id] = ok and not local_box(Assets.shape(shape_id)).size.is_zero_approx()
	return _has_shape[shape_id]


## Box (metres, mount frame) of a pod shape placed the way its own game places it.
static func metric_box(shape_id: String) -> AABB:
	var shape := Assets.shape(shape_id)
	var s := Packs.shape_scale(str(shape.get("pack", Assets.default_pack)))
	var b := local_box(shape)
	return AABB(b.position * s, b.size * s)


## Bounding box of a shape's visible detail-0 geometry in its own (unscaled) space, as
## ShapeInstance builds it: node default transforms, locator markers and damage states left out.
static func local_box(shape: Dictionary) -> AABB:
	var id := str(shape.get("id", ""))
	if id != "" and _local_boxes.has(id):
		return _local_boxes[id]
	var box := _measure(shape)
	if id != "":
		_local_boxes[id] = box
	return box


static func _measure(shape: Dictionary) -> AABB:
	var lods: Array = shape.get("lods", [])
	if lods.is_empty():
		return AABB()
	var xfs := make_node_transforms(shape)
	var pts := PackedVector3Array()
	for piece in lods[0].get("pieces", []):
		if ShapeInstance.MARKER_IDS.has(int(piece.get("id", 0))) or int(piece.get("state", 0)) != 0:
			continue
		var node := int(piece.get("node", -1))
		var xf: Transform3D = xfs[node] if node >= 0 and node < xfs.size() else Transform3D.IDENTITY
		for poly in piece.get("polys", []):
			if not ShapeInstance.is_drawn(poly):
				continue
			for v in poly.v:
				pts.append(xf * ShapeInstance.es_to_godot(v))
	if pts.is_empty():
		return AABB()
	var box := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		box = box.expand(p)
	return box


## Each node's default transform relative to the shape root.
static func make_node_transforms(shape: Dictionary) -> Array:
	var nodes: Array = shape.get("nodes", [])
	var out := []
	out.resize(nodes.size())
	for i in nodes.size():
		_node_transform(shape, i, out)
	return out


static func _node_transform(shape: Dictionary, i: int, out: Array) -> Transform3D:
	if out[i] != null:
		return out[i]
	var n: Dictionary = shape.nodes[i]
	var local := ShapeInstance.tf_to_transform(shape.transforms[int(n.default)])
	var parent := int(n.parent)
	out[i] = local
	if parent >= 0 and parent < out.size() and parent != i:
		out[i] = _node_transform(shape, parent, out) * local
	return out[i]


static func longest(box: AABB) -> float:
	return maxf(box.size.x, maxf(box.size.y, box.size.z))


# ------------------------------------------------------------------ reference boxes

## Reference box of host game `pack` for a size class and family: {"box": AABB (metres, mount
## frame), "weapon": the host's own representative weapon id, or "" when the box is borrowed}.
static func host_reference(pack: String, size: String, family: String) -> Dictionary:
	var key := "%s|%s|%s" % [pack, size, family]
	if not _refs.has(key):
		_refs[key] = _make_reference(pack, size, family)
	return _refs[key]


static func _make_reference(pack: String, size: String, family: String) -> Dictionary:
	var own := _representative(_native_pods(pack, size, family))
	if not own.is_empty():
		return own
	var other_family := _representative(_native_pods(pack, size, ""))
	if not other_family.is_empty():
		return {"box": other_family.box, "weapon": ""}
	return {"box": _cross_pack_box(size, family), "weapon": ""}


## A game's own pods of a size class (and family; "" = any): [{weapon, shape, box}], one per shape.
static func _native_pods(pack: String, size: String, family: String) -> Array:
	var out := []
	var seen := {}
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if w.pack != pack or str(w.get("category", "herc")) != WeaponFit.HERC_FAMILY or w.get("cybrid_only", false):
			continue
		if WeaponFit.size_of(w) != size or (family != "" and WeaponFit.family_of(w) != family):
			continue
		var sid := model_shape_id(w, 0)
		if sid == "" or seen.has(sid):
			continue
		seen[sid] = true
		out.append({"weapon": str(w.id), "shape": sid, "box": metric_box(sid)})
	return out


## The pod of median length ({} when there is none).
static func _representative(pods: Array) -> Dictionary:
	if pods.is_empty():
		return {}
	pods.sort_custom(func(a, b): return longest(a.box) < longest(b.box) if longest(a.box) != longest(b.box) else a.weapon < b.weapon)
	var p: Dictionary = pods[(pods.size() - 1) / 2]
	return {"box": p.box, "weapon": p.weapon}


## Median of the other games' reference boxes for a size class (same family first).
static func _cross_pack_box(size: String, family: String) -> AABB:
	for fam in [family, ""]:
		var boxes := []
		for p in Packs.packs:
			var r := _representative(_native_pods(str(p), size, fam))
			if not r.is_empty():
				boxes.append({"box": r.box, "weapon": r.weapon})
		var mid := _representative(boxes)
		if not mid.is_empty():
			return mid.box
	return _fallback_box(size)


static func _fallback_box(size: String) -> AABB:
	var length: float = FALLBACK_LENGTH_M.get(size, FALLBACK_LENGTH_M.M)
	var w := length * FALLBACK_WIDTH
	return AABB(Vector3(-w * 0.5, -w * 0.5, -length * (1.0 - FALLBACK_BACK)), Vector3(w, w, length))


## Reference pod of hardpoint i of `vdef` for a size class and family: {"box": AABB (metres,
## hardpoint frame), "outward": side the pod hangs off (frame axes), "front": the box is only a size
## and its front goes on the frame point, "weapon": the host's own representative weapon id or ""}.
static func frame_reference(vdef: Dictionary, i: int, size: String, family: String) -> Dictionary:
	var g: Dictionary = vdef.guns[i]
	var pack := str(vdef.get("pack", ""))
	var outward := WeaponMount.make_outward(g)
	if g.get("pod_box_units") is Dictionary:
		return {"box": _units_box(g.pod_box_units, pack), "outward": Vector3.ZERO, "front": false, "weapon": ""}
	var ref := host_reference(pack, size, family)
	if str(ref.weapon) != "":
		var own := Packs.weapon(str(ref.weapon))
		return {"box": native_box(own, g), "outward": outward, "front": false, "weapon": ref.weapon}
	# Battledrome launchers draw nothing: only the muzzle point is known
	var front := str(g.get("bay", "")) != ""
	return {"box": _hang_out(ref.box, outward), "outward": outward, "front": front, "weapon": ""}


## Box (metres, hardpoint frame) of a weapon's own pod placed the way its game places it on gun
## record `g` (WeaponMount.make_native_placement).
static func native_box(w: Dictionary, g: Dictionary) -> AABB:
	var sid := model_shape_id(w, int(g.get("mount_group", 0)))
	if sid == "":
		return AABB()
	var own_scale := Packs.shape_scale(str(w.get("pack", Assets.default_pack)))
	return WeaponMount.make_native_placement(w, g, own_scale) * local_box(Assets.shape(sid))


## Original-unit box {min, max} (x right, y forward, z up) of pack `pack` in metres, Godot axes.
static func _units_box(b: Dictionary, pack: String) -> AABB:
	var k := Packs.shape_scale(pack)
	var a := ShapeInstance.es_to_godot(b.min) * k
	var box := AABB(a, Vector3.ZERO)
	return box.expand(ShapeInstance.es_to_godot(b.max) * k)


## A borrowed box centred across the hardpoint and moved out so its inner face is on the frame point.
static func _hang_out(box: AABB, outward: Vector3) -> AABB:
	if outward.is_zero_approx():
		return box
	var c := box.get_center()
	var out := AABB(box.position - Vector3(c.x, c.y, 0.0), box.size)
	for a in 2:
		if outward[a] > 0.5:
			out.position[a] = 0.0
		elif outward[a] < -0.5:
			out.position[a] = -out.size[a]
	return out


# ------------------------------------------------------------------ placement

## Placement (model local units -> metres in the hardpoint frame) that fits a model with local box
## `model_box` to reference box `ref`: uniform scale to the reference length, back on its back face,
## the face toward the Herc (against `outward`) on the reference's, centred on the other axis.
static func make_fit_transform(model_box: AABB, ref: AABB, outward: Vector3) -> Transform3D:
	var k := longest(ref) / maxf(longest(model_box), MIN_LENGTH)
	var src := model_box.get_center()
	var dst := ref.get_center()
	src.z = model_box.end.z
	dst.z = ref.end.z
	for a in 2:
		if outward[a] > 0.5:
			src[a] = model_box.position[a]
			dst[a] = ref.position[a]
		elif outward[a] < -0.5:
			src[a] = model_box.end[a]
			dst[a] = ref.end[a]
	return Transform3D(Basis.from_scale(Vector3.ONE * k), dst - src * k)


## Placement that scales a model to reference `ref`'s length and puts its front centre on the frame
## point (a Battledrome launcher: only the muzzle point is known).
static func make_front_fit_transform(model_box: AABB, ref: AABB) -> Transform3D:
	var k := longest(ref) / maxf(longest(model_box), MIN_LENGTH)
	var c := model_box.get_center()
	return Transform3D(Basis.from_scale(Vector3.ONE * k), -Vector3(c.x, c.y, model_box.position.z) * k)


# ------------------------------------------------------------------ stand-in pods

## Procedural pod of a family for weapons without any model, as a ShapeInstance of the host's pack.
static func build_stand_in(pack: String, family: String, palette: String) -> ShapeInstance:
	var model := ShapeInstance.new()
	model.build(make_stand_in_shape(pack, family), 0, palette)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = _stand_in_mat()
	return model


## Shape dictionary (3Space JSON layout) of a stand-in pod.
static func make_stand_in_shape(pack: String, family: String) -> Dictionary:
	var polys := []
	for part in STAND_IN_PARTS.get(family, STAND_IN_PARTS.gun):
		polys.append_array(_box_polys(part[0], part[1]))
	var piece := {"node": -1, "id": 0, "cell": -1, "state": 0, "polys": polys}
	return {"id": "%s:standin_%s" % [pack, family], "pack": pack, "texset": null, "nodes": [], "transforms": [],
		"lods": [{"pieces": [piece], "cells": [], "radius": 1, "center": [0, 0, 0]}]}


## Six quads of a box between corners lo and hi (original axes: x right, y forward, z up).
static func _box_polys(lo: Vector3, hi: Vector3) -> Array:
	var c := [lo, hi]
	var out := []
	for axis in 3:
		for side in 2:
			var quad := []
			for corner in [[0, 0], [1, 0], [1, 1], [0, 1]]:
				var p := Vector3.ZERO
				p[axis] = c[side][axis]
				p[(axis + 1) % 3] = c[corner[0]][(axis + 1) % 3]
				p[(axis + 2) % 3] = c[corner[1]][(axis + 2) % 3]
				quad.append([p.x, p.y, p.z])
			var n := [0.0, 0.0, 0.0]
			n[axis] = -1.0 if side == 0 else 1.0
			out.append({"v": quad, "n": n, "m": {"kind": "solid", "index": 0}})
	return out


static func _stand_in_mat() -> StandardMaterial3D:
	if _stand_in_material == null:
		_stand_in_material = StandardMaterial3D.new()
		_stand_in_material.albedo_color = STAND_IN_COLOR
		_stand_in_material.metallic = 0.6
		_stand_in_material.roughness = 0.5
	return _stand_in_material
