class_name SelfDestructCharge
extends Node
## The Earthsiege 1 / 2 Spider (Arachnitron): a unit that blows itself up on contact (DAT 0x4a self_destruct;
## playtest A8). Its rules come from the simulator at import (tools/self_destruct_rules.py -> catalog
## "self_destruct"; docs/formats/gameplay.md section 2):
##   - think (DBSIM 0x18320 / 1.0 0x41e570): walks at its target for walk_s, then lunges for lunge_s at
##     lunge_steps move steps per tick (three times its pace), and walks again;
##   - every move step (0x18278 / 0x41e488) checks contact: another unit closer than both contact radii (DAT 0x6e),
##     or a building it runs into; then it detonates;
##   - the blast (0x1f75c / 0x426a20): each unit within blast_radius_m of the centre (Earthsiege 2: of its hull, and
##     never the Spider itself) - Earthsiege 2 first lets the shield bank facing the blast absorb the damage - then
##     each of its living components, with component_hit_chance (about one in two), takes the damage falling off
##     linearly with the distance from the centre to that component (0x13a7c / 0x4187d0), past the shields;
##   - then self_damage (32000) on each of its own components: it dies;
##   - killed by gunfire it does not blast (0x13919 plays only its death).
## The remake credits the Spider with the kills of its blast (the original passes no attacker in Earthsiege 1).

const VEHICLES := "vehicles"
const STRUCTURES := "structures"

var host: Herc
var rules: Dictionary
## True during a lunge.
var lunging := false
var _state_left := 0.0


func _init(p_host: Herc) -> void:
	host = p_host
	rules = host.def.get("self_destruct", {})
	name = "SelfDestructCharge"


func _physics_process(delta: float) -> void:
	if host.is_puppet or not host.alive:
		host.move_steps = 1
		return
	apply_state_step(delta)
	if make_contact() != null:
		detonate()


## The walk / lunge cycle: the first think finds its (zero) walk timer run out and starts with a lunge.
func apply_state_step(delta: float) -> void:
	_state_left -= delta
	if _state_left <= 0.0:
		lunging = not lunging
		var span: Array = rules.lunge_s if lunging else rules.walk_s
		_state_left = randf_range(float(span[0]), float(span[1]))
	host.move_steps = int(rules.lunge_steps) if lunging else 1


## What the host touches: a living unit closer than both contact radii, else a building it ran into; null if none.
func make_contact() -> Node3D:
	var r := host.make_contact_radius()
	for v in host.get_tree().get_nodes_in_group(VEHICLES):
		if v == host or not (v is Herc) or not v.alive or v.has_meta("dormant"):
			continue
		if host.global_position.distance_to(v.global_position) < r + (v as Herc).make_contact_radius():
			return v
	for i in host.get_slide_collision_count():
		var c := host.get_slide_collision(i).get_collider()
		if c is Node and (c as Node).is_in_group(STRUCTURES):
			return c
	return null


## Blast radius in metres.
func make_blast_radius() -> float:
	return float(rules.blast_radius_m)


## Damage a component `distance` metres from the centre takes when the blast reaches it with `damage`.
func make_component_damage(damage: float, distance: float) -> float:
	return damage * Blast.make_falloff(make_blast_radius(), distance)


## True when the blast at `at` reaches unit `v`.
func is_in_reach(v: Herc, at: Vector3) -> bool:
	var d := at.distance_to(v.global_position)
	if bool(rules.reach_adds_unit_radius):
		d -= v.make_contact_radius()
	return d < make_blast_radius()


## The blast on every unit in reach, then the host's own end.
func detonate() -> void:
	var at := host.global_position
	for v in host.get_tree().get_nodes_in_group(VEHICLES):
		if v is Herc and v.alive and (v != host or not bool(rules.skips_self)) and is_in_reach(v, at):
			apply_blast_to(v, at)
	for i in host.components.size():
		host.apply_component_hit(i, float(rules.self_damage), host)
	host.move_steps = 1


## The blast on one unit: the facing shield bank first (Earthsiege 2), then the component splash.
func apply_blast_to(v: Herc, at: Vector3) -> void:
	var damage := float(rules.blast_damage)
	if bool(rules.shields_absorb):
		damage = v.apply_shield_absorb(damage, at)
	if damage <= 0.0:
		return
	for hit in Blast.make_component_hits(v, at, {"amount": damage, "radius": make_blast_radius(),
			"chance": float(rules.component_hit_chance)}):
		if not v.alive:
			return
		v.apply_component_hit(int(hit[0]), float(hit[1]), host)
