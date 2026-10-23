class_name RepairWork
extends RefCounted
## What repair work can reach: the nearest damaged structure (a Tribes base object, an Earthsiege / Starsiege
## Structure) or teammate / vehicle (a Herc, a soldier) within a beam's reach, and how fast a repair pack mends it.
## The originals' repair gun ray-casts for "just about anything that can be damaged" - players, vehicles, static
## shapes, turrets - within the beam range (T2 scripts/packs/repairpack.cs RepairGunImage::onValidate; T1
## RepairBolt::onAcquire). The remake picks the nearest damaged one in reach instead of the aimed one.

## Meta of a soldier repairing something without a pack (a faction's repair crew): the structure, for the beam.
const META_JOB := "repair_job"
## Meta of a soldier whose pack or hold repair works on something this frame: that Node3D (self-repair waits).
const META_TARGET := "repair_target"
## A teammate or vehicle is reached this much closer than its centre (metres).
const UNIT_RADIUS := 1.5
const STRUCTURE_GROUP := "structures"
const UNIT_GROUP := "vehicles"


## The soldier's repair pack is switched on.
static func is_pack_on(unit: Herc) -> bool:
	var soldier := unit as Infantry
	return soldier != null and soldier.kit.pack_active and str(InfantryGear.pack(soldier.kit.pack_id).get("effect", "")) == "repair"


## True while `soldier`'s repair work has something to mend (the pack then does not heal its wearer).
static func has_target(soldier: Herc) -> bool:
	return soldier.has_meta(META_TARGET) and is_instance_valid(soldier.get_meta(META_TARGET))


## Reach of `unit`'s pack beam (metres; 0 when the pack's game has no repair block).
static func make_pack_reach(soldier: Infantry) -> float:
	return float(RepairRules.make_beam(soldier.kit.pack_id).get("range", 0.0))


## The nearest damaged structure within `reach` metres of its surface that a unit of `team` may repair.
static func find_structure(tree: SceneTree, origin: Vector3, team: int, reach: float) -> Structure:
	var best: Structure = null
	for node in tree.get_nodes_in_group(STRUCTURE_GROUP):
		var s := node as Structure
		if s == null or not s.can_repair() or not BaseCapture.may_repair(team, s):
			continue
		var d := s.make_reach_distance(origin)
		if d <= reach:
			reach = d
			best = s
	return best


## The nearest hurt teammate or allied vehicle within `reach` metres of its centre.
static func find_unit(tree: SceneTree, source: Herc, reach: float) -> Herc:
	var best: Herc = null
	for node in tree.get_nodes_in_group(UNIT_GROUP):
		var u := node as Herc
		if u == null or u == source or not u.alive or not TeamRelations.is_allied(source.team, u.team) \
				or not HercDamage.needs_repair(u.components):
			continue
		var d := maxf(0.0, source.global_position.distance_to(u.global_position) - UNIT_RADIUS)
		if d <= reach:
			reach = d
			best = u
	return best


## What `soldier`'s switched-on pack works on: the nearest of a hurt teammate / vehicle and a damaged structure.
static func find_pack_target(tree: SceneTree, soldier: Infantry) -> Node3D:
	var reach := make_pack_reach(soldier)
	if reach <= 0.0:
		return null
	var s := find_structure(tree, soldier.global_position, soldier.team, reach)
	var u := find_unit(tree, soldier, reach)
	if s == null or u == null:
		return s if s != null else u
	var ds := s.make_reach_distance(soldier.global_position)
	var du := maxf(0.0, soldier.global_position.distance_to(u.global_position) - UNIT_RADIUS)
	return s if ds <= du else u


## Points per second the pack of `soldier` mends `target` with: the object rate, except a teammate soldier in a game
## whose gun repairs players at the pack's own (slower) rate (Tribes 2 repairFactorPlayer).
static func make_pack_rate(soldier: Infantry, target: Node3D) -> float:
	var object_rate := float(RepairRules.make_beam(soldier.kit.pack_id).get("per_s", 0.0))
	if target is Infantry and RepairRules.make_unit_rate_source(soldier.kit.pack_id) == RepairRules.UNIT_RATE_PACK:
		return float(InfantryGear.pack(soldier.kit.pack_id).get("repair_per_s", object_rate))
	return object_rate


## Host: `amount` points of repair on a teammate or vehicle.
static func apply_unit_repair(unit: Herc, amount: float) -> void:
	unit.integrity = HercDamage.apply_repair(unit.components, amount)
