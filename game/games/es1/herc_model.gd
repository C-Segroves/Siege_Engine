class_name HercModel
extends RefCounted
## Visual model helpers shared by battles (Herc) and the hangar (HangarBay), so a Herc looks the
## same everywhere: hardpoint frames, weapon pod models and muzzles (docs/formats/weapon_mounts.md).
##
## Any Herc-family weapon can sit on any Herc (campaign_availability.md section 4): a weapon of the
## Herc's own game keeps its original pod and placement (WeaponMount); another game's pod is fitted to
## the host's own pod at that hardpoint (WeaponPodFit.frame_reference); a weapon without a model shows
## its look-alike from the installed packs (WeaponLookalike), else the host's own pod of the same family
## and size, else a procedural stand-in - a mounted weapon is
## never invisible, except where the original draws nothing (internal mounts, Battledrome mine and
## missile launchers).

const NODE_COCKPIT := 11
## GL mount groups above this are internal guns without a visible model (gameplay.md section 3).
const MAX_VISIBLE_MOUNT_GROUP := 3
const PLAN_META := "mount_plan"
const MIN_SCALE := 0.000001
const FIXTURE_PREFIX := "fixture%d"

## How a hardpoint shows its weapon.
enum Look {
	HIDDEN,     ## internal mount (ES1/ES2 mount group > 3), a Battledrome launcher, or no such hardpoint
	BAKED,      ## Battledrome bay pod drawn by the Herc shape itself
	NATIVE,     ## a pod of the host's own game, at its original placement
	FITTED,     ## another game's pod, fitted to the host's pod at that hardpoint
	STAND_IN,   ## procedural pod fitted to the host's pod at that hardpoint
}


## The vehicle's fixtures and one hardpoint frame per gun, built on `s`: gun index -> Marker3D.
## Battles and the hangar call this once per vehicle model.
static func build_mounts(vdef: Dictionary, s: ShapeInstance) -> Dictionary:
	build_fixtures(vdef, s)
	return create_frames(vdef, s)


## Extra shapes that are part of a vehicle, each on one of its nodes ("fixtures": [{shape, attach_node}],
## e.g. a Tribes 2 turret base on the vehicle's mount point 10). A fixture on the torso node turns with it.
static func build_fixtures(vdef: Dictionary, s: ShapeInstance) -> Array:
	var out := []
	var host_scale := maxf(Packs.shape_scale(str(vdef.get("pack", Assets.default_pack))), MIN_SCALE)
	for i in (vdef.get("fixtures", []) as Array).size():
		var f: Dictionary = vdef.fixtures[i]
		var fixture := ShapeInstance.new()
		fixture.name = FIXTURE_PREFIX % i
		fixture.build(Assets.shape(str(f.get("shape", ""))), 0, s.palette_name)
		var own_scale := Packs.shape_scale(str(fixture.shape.get("pack", Assets.default_pack)))
		fixture.scale = Vector3.ONE * own_scale / host_scale
		attach_node(s, int(f.get("attach_node", -1))).add_child(fixture)
		out.append(fixture)
	return out


## Node `index` of shape `s`, or `s` itself when the index is out of range (-1 = the shape's root).
static func attach_node(s: ShapeInstance, index: int) -> Node3D:
	return WeaponMount.node_or_root(s, index)


## The hardpoint frames of every gun (WeaponMount.build_frames): gun index -> Marker3D.
static func create_frames(vdef: Dictionary, s: ShapeInstance) -> Dictionary:
	var out := {}
	var frames := WeaponMount.build_frames(vdef, s)
	for i in frames.size():
		out[i] = frames[i]
	return out


## How hardpoint i of vehicle `vdef` shows weapon `wdef`: {"look": Look, "weapon": id of the weapon
## whose pod is placed, "gun": the gun record, "shape": pod shape id, "box": reference AABB (metres, hardpoint frame), "outward":
## side the pod hangs off, "front": pod front on the frame point, "hide_cells": baked pod cells to hide,
## "lookalike": for a weapon without a model, which WeaponLookalike rule chose which weapon's model}.
static func mount_plan(vdef: Dictionary, i: int, wdef: Dictionary) -> Dictionary:
	var guns: Array = vdef.get("guns", [])
	if i < 0 or i >= guns.size():
		return {"look": Look.HIDDEN}
	var g: Dictionary = guns[i]
	var group := int(g.get("mount_group", 0))
	if group < 0 or group > MAX_VISIBLE_MOUNT_GROUP:
		return {"look": Look.HIDDEN}
	var native := str(wdef.get("pack", "")) == str(vdef.get("pack", ""))
	var base := {"weapon": str(wdef.get("id", "")), "gun": g}
	if native and g.has("pod_cells"):
		return _plan(base, {"look": Look.BAKED})
	if native and str(g.get("bay", "")) != "":
		return _plan(base, {"look": Look.HIDDEN})   # Battledrome mine / missile launchers draw nothing
	var shape_id := WeaponPodFit.model_shape_id(wdef, group)
	if shape_id != "" and native:
		return _plan(base, {"look": Look.NATIVE, "shape": shape_id})
	if str(wdef.get("category", WeaponFit.HERC_FAMILY)) != WeaponFit.HERC_FAMILY:
		return {"look": Look.HIDDEN}   # vehicle-family weapons show their own model or none (bomb bays)
	return _plan(base, _foreign_plan(vdef, i, wdef, shape_id))


static func _plan(base: Dictionary, look: Dictionary) -> Dictionary:
	var out := base.duplicate()
	out.merge(look, true)
	return out


## Another game's weapon (or one without a model) on hardpoint i: fitted to the host's own pod there.
static func _foreign_plan(vdef: Dictionary, i: int, wdef: Dictionary, shape_id: String) -> Dictionary:
	var g: Dictionary = vdef.guns[i]
	var size := reference_size(vdef, i, wdef)
	var ref := WeaponPodFit.frame_reference(vdef, i, size, WeaponFit.family_of(wdef))
	var fit := {"box": ref.box, "outward": ref.outward, "front": ref.front, "hide_cells": g.get("pod_cells", []),
		"size": size}
	if shape_id != "":
		return _plan(fit, {"look": Look.FITTED, "shape": shape_id})
	var choice := WeaponLookalike.choose(wdef, vdef)
	if str(choice.rule) != "":
		return _lookalike_plan(vdef, g, fit, choice)
	return _fallback_plan(g, fit, ref, choice)


## A model-less weapon drawn as its look-alike (WeaponLookalike): a pod of the host's own game of the
## same size at its original placement, else the look-alike fitted to the host's pod there.
static func _lookalike_plan(vdef: Dictionary, g: Dictionary, fit: Dictionary, choice: Dictionary) -> Dictionary:
	var src := Packs.weapon(str(choice.weapon))
	var group := int(g.get("mount_group", 0))
	var shape_id := WeaponPodFit.model_shape_id(src, group)
	if shape_id == "":
		shape_id = WeaponPodFit.model_shape_id(src, 0)
	var looks := {"shape": shape_id, "weapon": str(src.id), "lookalike": choice}
	if str(src.pack) == str(vdef.get("pack", "")) and WeaponFit.size_of(src) == str(fit.size):
		return _plan({"gun": g}, _plan(looks, {"look": Look.NATIVE}))
	return _plan(fit, _plan(looks, {"look": Look.FITTED}))


## No look-alike installed: the host game's own pod of the same family and size, else a stand-in.
static func _fallback_plan(g: Dictionary, fit: Dictionary, ref: Dictionary, choice: Dictionary) -> Dictionary:
	var own := Packs.weapon(str(ref.weapon)) if str(ref.weapon) != "" else {}
	var own_pod := WeaponPodFit.model_shape_id(own, int(g.get("mount_group", 0))) if not own.is_empty() else ""
	if own_pod != "":
		var host_pod := {"rule": WeaponLookalike.RULE_HOST_POD, "weapon": str(own.id), "archetype": choice.archetype}
		return {"look": Look.NATIVE, "shape": own_pod, "weapon": str(own.id), "gun": g, "lookalike": host_pod}
	var stand_in := {"rule": WeaponLookalike.RULE_STAND_IN, "weapon": "", "archetype": choice.archetype}
	return _plan(fit, {"look": Look.STAND_IN, "lookalike": stand_in})


## Size class whose reference pod a weapon is fitted to: its own, capped at the hardpoint's.
static func reference_size(vdef: Dictionary, i: int, wdef: Dictionary) -> String:
	var hardpoint := WeaponFit.hardpoint_size(vdef, i)
	var own := WeaponFit.size_of(wdef)
	if hardpoint == "":
		return own if WeaponFit.rank(own) >= 0 and own != WeaponFit.INTERNAL else "M"
	return WeaponFit.smaller(own, hardpoint) if WeaponFit.rank(own) >= 0 else hardpoint


## Weapon pod model for hardpoint i of vehicle `vdef`, built but not attached; null when the
## hardpoint shows none of its own (internal mounts, Battledrome baked pods and launchers).
static func weapon_model(vdef: Dictionary, i: int, wdef: Dictionary, palette: String) -> ShapeInstance:
	var plan := mount_plan(vdef, i, wdef)
	var model: ShapeInstance
	match int(plan.look):
		Look.NATIVE:
			model = ShapeInstance.new()
			model.build(Assets.shape(str(plan.shape)), 0, palette)
		Look.FITTED:
			model = ShapeInstance.new()
			model.build(WeaponPodFit.foreign_pod_shape(str(plan.shape)), 0, palette)
		Look.STAND_IN:
			model = WeaponPodFit.build_stand_in(str(vdef.get("pack", Assets.default_pack)), WeaponFit.family_of(wdef), palette)
		_:
			return null
	model.name = "weapon%d" % i
	plan["mounted"] = str(wdef.get("id", ""))
	model.set_meta(PLAN_META, plan)
	return model


## Puts a weapon model on its hardpoint frame (WeaponMount), hides the baked pod it replaces and puts
## the frame's muzzle at the model's barrel. The model lives inside the (already scaled) Herc shape,
## so its placement in metres is divided by the Herc's shape scale.
static func attach_weapon_model(frame: Node3D, model: ShapeInstance, vdef: Dictionary) -> void:
	frame.add_child(model)
	var host_scale := maxf(Packs.shape_scale(str(vdef.get("pack", Assets.default_pack))), MIN_SCALE)
	model.transform = Transform3D(Basis.from_scale(Vector3.ONE / host_scale), Vector3.ZERO) * placement(model)
	var plan: Dictionary = model.get_meta(PLAN_META, {})
	_hide_cells(frame, plan.get("hide_cells", []))
	# the muzzle of the model actually drawn (a look-alike's own muzzle, not the mounted weapon's)
	WeaponMount.apply_muzzle(frame, model, Packs.weapon(str(plan.get("weapon", plan.get("mounted", "")))))


## An Earthsiege internal gun (GL mount group above MAX_VISIBLE_MOUNT_GROUP) draws no pod, but still fires
## from the GL point plus the weapon's own muzzle offset: the original muzzle is node · gun aim · (weapon
## +0x40..+0x44 + attach point) for every gun (ES1 DBSIM 0xadd4, ES2 0x40e788). Without the offset the
## shot starts inside the torso. Another game's weapon there uses the host game's own weapon of its size
## and family (WeaponPodFit.host_reference). Other hardpoints without a model keep firing from the frame.
static func apply_internal_muzzle(frame: Node3D, vdef: Dictionary, i: int, wdef: Dictionary) -> void:
	var guns: Array = vdef.get("guns", [])
	if i < 0 or i >= guns.size() or not WeaponMount.is_gl_record(guns[i]):
		return
	if int(guns[i].mount_group) <= MAX_VISIBLE_MOUNT_GROUP:
		return
	var offset: Variant = _own_muzzle_units(vdef, i, wdef)
	if offset is Array:
		WeaponMount.apply_muzzle_at(frame, ShapeInstance.es_to_godot(offset))


## The 3Space muzzle offset (`model.muzzle_units`) of `wdef` if it is the host's own game's weapon, else of
## the host's representative weapon for that hardpoint; null when neither has one.
static func _own_muzzle_units(vdef: Dictionary, i: int, wdef: Dictionary) -> Variant:
	var pack := str(vdef.get("pack", ""))
	var source := wdef
	if str(wdef.get("pack", "")) != pack:
		var ref := WeaponPodFit.host_reference(pack, reference_size(vdef, i, wdef), WeaponFit.family_of(wdef))
		source = Packs.weapon(str(ref.weapon)) if str(ref.weapon) != "" else {}
	var m: Dictionary = source.get("model", {}) if source.get("model") is Dictionary else {}
	return m.muzzle_units if m.get("muzzle_units") is Array else null


static func _hide_cells(frame: Node3D, cells: Array) -> void:
	var host := frame.get_parent()
	while host != null and not host is ShapeInstance:
		host = host.get_parent()
	if host == null:
		return
	for ci in cells:
		(host as ShapeInstance).set_cell_hidden(int(ci), true)


## Shows every baked pod again (before a new loadout is attached in the hangar).
static func show_baked_pods(vdef: Dictionary, s: ShapeInstance) -> void:
	for g in vdef.get("guns", []):
		for ci in g.get("pod_cells", []):
			s.set_cell_hidden(int(ci), false)


## Model local units -> metres in the hardpoint frame.
static func placement(model: ShapeInstance) -> Transform3D:
	var plan: Dictionary = model.get_meta(PLAN_META, {})
	var look := int(plan.get("look", Look.NATIVE))
	if look == Look.FITTED or look == Look.STAND_IN:
		var box := WeaponPodFit.local_box(model.shape)
		if plan.get("front", false):
			return WeaponPodFit.make_front_fit_transform(box, plan.box)
		return WeaponPodFit.make_fit_transform(box, plan.box, plan.get("outward", Vector3.ZERO))
	var own_scale := Packs.shape_scale(str(model.shape.get("pack", Assets.default_pack)))
	return WeaponMount.make_native_placement(Packs.weapon(str(plan.get("weapon", ""))), plan.get("gun", {}), own_scale)


## Hardpoint frames in gun order (`frames` from build_mounts); the vehicle's fallback mount when it
## lists no guns.
static func mount_nodes(vdef: Dictionary, s: ShapeInstance, frames: Dictionary) -> Array:
	var out := []
	for i in (vdef.get("guns", []) as Array).size():
		if frames.has(i):
			out.append(frames[i])
	if out.is_empty():
		out.append(WeaponMount.fallback_mount(s))
	return out


## Projectile origin of a hardpoint frame (its muzzle marker, else the frame).
static func muzzle_of(frame: Node3D) -> Node3D:
	return WeaponMount.muzzle_of(frame)
