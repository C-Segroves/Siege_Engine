class_name ThrownItem
extends Node3D
## A thrown grenade or mine (InfantryGear hand item; docs/formats/tribes_infantry.md section 6). It flies under
## Tribes gravity, bounces off the ground and walls (elasticity, friction) and comes to rest:
##   grenade / concussion  bursts when its fuse runs out (T1 Handgrenade::onAdd, T2 *Thrown::onThrow);
##   mine                  arms arm_s after it comes to rest, then bursts when a soldier or vehicle comes
##                         within its proximity (T1 triggerRadius, T2 proximity / armTime).
## The burst does radius damage of the item's damage type (falling off with distance, like a splash) and
## pushes soldiers (kickBackStrength / armour mass). The host's item is the real one; clients fly a visual
## copy that the host's burst message removes (InfantryGearDirector).

## Bounces lose this share of the speed along the surface per unit of friction (remake: the Torque item
## physics are engine code).
const FRICTION_LOSS := 0.3
## Slower than this on a floor it lies still (m/s); a floor faces up at least this much.
const REST_SPEED := 2.0
const FLOOR_NORMAL_Y := 0.7
## The thrower can't hit his own item this long after the throw (T2 setCollisionTimeout).
const THROWER_TIMEOUT := 0.25
## A visual copy that heard no burst is removed this long after its fuse would have run out.
const VISUAL_GRACE := 3.0
const BODY_RADIUS := 0.15
const BURST_SIZE_PER_RADIUS := 0.35
const SURFACE_LIFT := 0.05
const STAND_IN_COLOR := Color(0.25, 0.3, 0.25)

## Burst at `position` (host): InfantryGearDirector sends it to every peer.
signal burst(item: ThrownItem)

var item: Dictionary
var thrower: Herc
var velocity := Vector3.ZERO
var visual_only := false
## Id shared by the host's item and the clients' copies.
var item_net_id := 0
var at_rest := false
var _age := 0.0
var _rest_age := 0.0
var _gravity := Infantry.TRIBES_GRAVITY


func _ready() -> void:
	add_to_group("thrown_items")
	_build_model()


func _build_model() -> void:
	var shape_id = item.get("shape")
	if shape_id is String and not Assets.shape(shape_id).is_empty():
		var model := ShapeInstance.new()
		model.build(Assets.shape(shape_id), 0, Packs.default_palette(str(item.id).get_slice(":", 0)))
		add_child(model)
		return
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = BODY_RADIUS
	m.height = BODY_RADIUS * 2.0
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = STAND_IN_COLOR
	mi.material_override = mat
	add_child(mi)


func is_mine() -> bool:
	return str(item.get("kind", "")) == InfantryGear.KIND_MINE


func _physics_process(delta: float) -> void:
	_age += delta
	if not at_rest:
		_fly(delta)
	if visual_only:
		if not is_mine() and _age > float(item.get("fuse_s", 0.0)) + VISUAL_GRACE:
			queue_free()
		return
	if is_due_to_burst():
		_burst()


## Host: the fuse ran out, or an armed mine senses someone.
func is_due_to_burst() -> bool:
	if not is_mine():
		return _age >= float(item.get("fuse_s", 0.0))
	return at_rest and _age - _rest_age >= float(item.get("arm_s", 0.0)) and _is_anyone_near()


func _fly(delta: float) -> void:
	velocity.y -= _gravity * delta
	var step := velocity * delta
	var exclude: Array[RID] = []
	if is_instance_valid(thrower) and _age < THROWER_TIMEOUT:
		exclude.append(thrower.get_rid())
	var q := PhysicsRayQueryParameters3D.create(global_position, global_position + step, 0xFFFFFFFF, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		global_position += step
		return
	var n: Vector3 = hit.normal
	global_position = hit.position + n * SURFACE_LIFT
	velocity = make_bounce(velocity, n, float(item.get("elasticity", 0.0)), float(item.get("friction", 1.0)))
	if velocity.length() < REST_SPEED and n.y > FLOOR_NORMAL_Y:
		at_rest = true
		_rest_age = _age
		velocity = Vector3.ZERO


## Velocity after a bounce off a surface with normal `n`.
static func make_bounce(v: Vector3, n: Vector3, elasticity: float, friction: float) -> Vector3:
	var normal_part := n * v.dot(n)
	var along := v - normal_part
	return along * maxf(0.0, 1.0 - friction * FRICTION_LOSS) - normal_part * elasticity


func _is_anyone_near() -> bool:
	var reach := float(item.get("proximity", 0.0))
	for v in get_tree().get_nodes_in_group("vehicles"):
		var h := v as Herc
		if h == null or not h.alive:
			continue
		var r := reach if h is Infantry else reach + BoardingRules.make_hull_radius(h)
		if Vector2(h.global_position.x - global_position.x, h.global_position.z - global_position.z).length() <= r \
				and absf(h.global_position.y - global_position.y) <= r + BoardingRules.HATCH_MIN_HEIGHT:
			return true
	return false


func _burst() -> void:
	apply_blast(self, item, global_position, thrower)
	burst.emit(self)
	queue_free()


## A blast radius never below this (metres; a record without one still reaches what it touches).
const MIN_BLAST_RADIUS := 0.01


## Radius damage and push of `record`'s burst at `pos` (host; Blast, with the item's damage type).
static func apply_blast(at: Node, record: Dictionary, pos: Vector3, source: Herc) -> void:
	var damage := float(record.get("damage", 0.0))
	Blast.apply_to_units(at.get_tree(), {"pos": pos, "radius": maxf(float(record.get("radius", 0.0)), MIN_BLAST_RADIUS),
		"shield": damage, "armor": damage, "attacker": source, "kick": float(record.get("kick", 0.0)),
		"weapon": {"damage_type": str(record.get("damage_type", ""))}})


## The burst's look: the item's own explosion (`burst_fx`: T1 MineData explosionId, T2 thrown ItemData
## explosion; tools/fx_deaths.py), the generic one only for an import without it.
static func play_burst(parent: Node, record: Dictionary, pos: Vector3) -> void:
	var ref := str(record.get("burst_fx", "")) if record.get("burst_fx") is String else ""
	if ref == "":
		Effects.fx.play_generic_explosion(parent, pos, float(record.get("radius", 0.0)) * BURST_SIZE_PER_RADIUS)
		return
	Effects.fx.play_effect(parent, ref, Assets.split_id(str(record.get("id", "")))[0], pos)
