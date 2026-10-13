class_name Blast
extends RefCounted
## Radius damage, one way for every game:
## - over units (make_unit_hits / apply_to_units): every living vehicle or soldier whose centre lies within the
##   radius takes the damage falling off linearly with the distance (projectile splash of the games whose splash
##   reaches other units, Tribes grenades and mines with their push);
## - over one unit's components (make_component_hits): Earthsiege's 0x13a7c - each living component, with the
##   blast's chance, takes the damage falling off linearly with the distance from the centre to its COL sphere
##   (the in-unit splash of a weapon hit, EsDamageModel; the Spider's blast, SelfDestructCharge).

const VEHICLES := "vehicles"


## Share of a blast of `radius` that reaches `distance` metres from its centre: 1 at the centre, 0 at the edge.
static func make_falloff(radius: float, distance: float) -> float:
	if radius <= 0.0 or distance >= radius:
		return 0.0
	return (radius - distance) / radius


## [[unit, share]] of every living unit of the groups (vehicles and `extra_group`) the blast at `pos` reaches,
## except `skip`.
static func make_unit_hits(tree: SceneTree, pos: Vector3, radius: float, skip: Node = null, extra_group := "") -> Array:
	var out := []
	var nodes := tree.get_nodes_in_group(VEHICLES)
	if extra_group != "":
		nodes.append_array(tree.get_nodes_in_group(extra_group))
	for v in nodes:
		if v == skip or not v.get("alive"):
			continue
		var f := make_falloff(radius, (v as Node3D).global_position.distance_to(pos))
		if f > 0.0:
			out.append([v, f])
	return out


## Lands blast `spec` on the units it reaches: spec {pos, radius, shield, armor, attacker, weapon (catalog weapon or
## {}), skip, extra_group, kick (a soldier's push, metres per second per unit mass)}.
static func apply_to_units(tree: SceneTree, spec: Dictionary) -> void:
	var pos: Vector3 = spec.pos
	for hit in make_unit_hits(tree, pos, float(spec.radius), spec.get("skip"), str(spec.get("extra_group", ""))):
		var v: Node3D = hit[0]
		var f: float = hit[1]
		DamageModel.apply_weapon_hit(v, DamageModel.make_hit(float(spec.get("shield", 0.0)) * f,
			float(spec.get("armor", 0.0)) * f, spec.get("attacker"), pos, spec.get("weapon", {})))
		var kick := float(spec.get("kick", 0.0))
		if v is Infantry and kick > 0.0:
			var away := (v.global_position + Vector3.UP - pos).normalized()
			(v as Infantry).apply_kick(away * kick / maxf(float((v as Infantry).armor.get("mass", 1.0)), 1.0) * f)


## [[component index, damage]] of `h`'s components a blast of `amount` at `pos` reaches (0x13a7c): each living one
## other than `skip_index`, with chance `chance`, by its sphere's distance within `radius`.
static func make_component_hits(h: Herc, pos: Vector3, spec: Dictionary) -> Array:
	var out := []
	var radius := float(spec.radius)
	for i in h.components.size():
		if i == int(spec.get("skip_index", -1)) or float(h.components[i].hp) <= 0.0 or randf() >= float(spec.chance):
			continue
		var damage := float(spec.amount) * make_falloff(radius, pos.distance_to(h.make_component_position(i)))
		if damage > 0.0:
			out.append([i, damage])
	return out
