class_name SSStructure
extends Structure
## Starsiege static shape / turret / building: a Structure that also reports hits (scripts use
## <name>::structure::onAttacked), carries its mission object id and follows the record's SimShape
## damage block (tools/starsiege_mis.py read_damage / read_fire_block): hit points = sustainable damage,
## pre-damage = current damage, the indestructible flag, and the static-base fire: with fire_threshold
## or less hit points left the shape catches fire (SSFire) and burns burn_rate per second until it is
## destroyed (Starsiege.exe inspect IDITG_FIREDAMAGETHRESH / IDITG_FIREDAMAGERATE).

signal attacked(s: SSStructure, attacker: Node)

## Height of the fire above the shape's origin when it has no bounds; flames spread over this share of
## the shape's footprint.
const DEFAULT_FIRE_HEIGHT := 6.0
const FIRE_SPREAD := 0.3

var ss_id := 0
var indestructible: bool:
	get: return damage.profile.indestructible
	set(value): damage.profile.indestructible = value
## Engine-scale hit points at which the shape catches fire (0 = never) and its burn damage per second.
var fire_threshold := 0.0
var burn_rate := 0.0
var _last_attacker: Node
var _fire: SSFire


static func make(parent: Node3D, shape_id: String, xf: Transform3D, pal: String, p_team: int, p_hp: float, collide := true) -> SSStructure:
	var s := SSStructure.new()
	s.build_body(parent, {"shape": shape_id, "xf": xf, "palette": pal, "team": p_team, "hp": p_hp, "collide": collide})
	return s


## Adds this structure under `parent` and builds its shape (and trimesh collision when spec.collide):
## spec = {shape, xf, palette, team, hp, collide}.
func build_body(parent: Node3D, spec: Dictionary) -> void:
	transform = spec.xf
	shape_id = String(spec.shape)
	team = int(spec.team)
	max_hp = float(spec.hp)
	hp = max_hp
	name = make_net_name(shape_id, transform.origin)
	parent.add_child(self)
	add_to_groups()
	shape = ShapeInstance.new()
	add_child(shape)
	shape.build(Assets.shape(String(spec.shape)), 0, String(spec.palette))
	if bool(spec.get("collide", true)):
		build_collision()


## Damage block of the mission record `d` (original damage units) scaled by `damage_factor` (the
## Starsiege -> engine damage scale): hit points, indestructible flag, pre-damage and fire.
func apply_damage_block(d: Dictionary, damage_factor: float) -> void:
	var points := float(d.get("hit_points", 0.0)) * damage_factor
	if points > 0.0:
		max_hp = points
		hp = points
	indestructible = bool(d.get("indestructible", false))
	if d.get("explosion_tag") != null:
		death_keys = [str(int(d.explosion_tag))]
	fire_threshold = float(d.get("fire_threshold", 0.0)) * damage_factor
	burn_rate = float(d.get("burn_rate", 0.0)) * damage_factor
	var pre := float(d.get("current_damage", 0.0)) * damage_factor
	if pre > 0.0:
		health_scale(100.0 * maxf(max_hp - pre, 0.0) / max_hp)


func is_burning() -> bool:
	return alive and fire_threshold > 0.0 and burn_rate > 0.0 and hp <= fire_threshold


## A hit is remembered (the burn credits it) and reported to the scripts (onAttacked) even when the shape takes none.
func apply_damage_event(event: DamageEvent) -> void:
	if not alive:
		return
	if event.attacker != null:
		_last_attacker = event.attacker
	super.apply_damage_event(event)
	if multiplayer.is_server():
		attacked.emit(self, event.attacker)


func _physics_process(delta: float) -> void:
	super(delta)
	if is_burning() and multiplayer.is_server():
		_apply_burn(delta)
	elif _fire != null and not is_burning():       # repaired above the fire threshold: the flames die down
		_fire.queue_free()
		_fire = null


## An indestructible shape takes no repair either.
func can_repair() -> bool:
	return not indestructible and super()


func _apply_burn(delta: float) -> void:
	if _fire == null:
		_fire = _build_fire()
	damage.apply_event(DamageEvent.make_burn(burn_rate * delta, _last_attacker if is_instance_valid(_last_attacker) else null))


func destroy(killer: Node = null) -> void:
	super.destroy(killer)
	if _fire:
		_fire.queue_free()
		_fire = null


func _build_fire() -> SSFire:
	var bounds := AABB()
	var found := false
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = global_transform.affine_inverse() * mi.global_transform * (mi as MeshInstance3D).get_aabb()
		bounds = box if not found else bounds.merge(box)
		found = true
	if not found:
		return SSFire.make(self, Vector3.UP * DEFAULT_FIRE_HEIGHT, DEFAULT_FIRE_HEIGHT * FIRE_SPREAD)
	var top := Vector3(bounds.get_center().x, bounds.end.y, bounds.get_center().z)
	return SSFire.make(self, top, maxf(bounds.size.x, bounds.size.z) * FIRE_SPREAD)
