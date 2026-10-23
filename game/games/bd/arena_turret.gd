class_name ArenaTurret
extends StaticBody3D
## Battledrome blaster turret: fires at the nearest hostile Herc in range (host only). Destructible. A turret belongs
## to a side (arena DOA `side`, battledrome.md section 6: "side = owner"; the referee penalises shooting your own
## turret): side k is team k, so it holds fire at its own side's Hercs.

## The arena hazard's weapon in the Battledrome catalog (tools/export_bd_weapons.py).
const BLASTER_ID := "bd:TURRET_BLASTER"
## Turret body for its death effects (metres; the collision sphere's size).
const BODY_RADIUS := 3.0
const BODY_HEIGHT := 3.0

var side := 0
## The owning side as a team (other code asks vehicles and turrets alike for `team`).
var team: int:
	get: return side
var hp := 6000.0
var alive := true
var range_m := 220.0
var refire := 1.4
var shield_damage := 600.0
var armor_damage := 900.0
var _cool := 0.0
var _target_profile: TargetProfile
var shape: ShapeInstance
## "bd:<shape>": its destruction plays the Battledrome turret death (DeathFx, SIM turret.cpp 0x1537e).
var shape_id := ""
## The wreck that replaces it (arena turret_shapes "destroyed": TURHLK, battledrome.md section 6); "" hides it.
var wreck_shape_id := ""
var _pal := ""


static func create(parent: Node3D, shape_id: String, xf: Transform3D, pal: String, metres_per_unit: float) -> ArenaTurret:
	var t := ArenaTurret.new()
	t.shape_id = shape_id
	t.transform = xf
	parent.add_child(t)
	t.add_to_group("turrets")
	t.shape = ShapeInstance.new()
	t.add_child(t.shape)
	t.shape.build(Assets.shape(shape_id), 0, pal)
	t._pal = pal
	var col := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = BODY_RADIUS
	col.shape = sph
	t.add_child(col)
	return t


## True when `v` is not on this turret's side (TeamRelations: free-for-all pilots are hostile to both sides).
func is_hostile(v: Node) -> bool:
	return TeamRelations.is_hostile(side, int(v.get("team")) if v.get("team") != null else -1)


func apply_hit(_s: float, armor: float, _attacker: Node = null, _p := Vector3.ZERO) -> void:
	if not alive or not multiplayer.is_server():
		return
	hp -= armor
	if hp <= 0.0:
		apply_destroyed()
		get_parent().fx("turret_down", [get_path()], true) if get_parent().has_method("fx") else null


## Destroyed (host, or a client told by the turret_down message): its game's turret death, then hidden.
func apply_destroyed() -> void:
	alive = false
	DeathFx.play(get_parent(), DeathFx.make_body(self, shape_id, DeathFx.KIND_TURRET, Vector2(BODY_RADIUS, BODY_HEIGHT)))
	if wreck_shape_id != "" and not Assets.shape(wreck_shape_id).is_empty():
		shape.build(Assets.shape(wreck_shape_id), 0, _pal)
	else:
		shape.visible = false


func _physics_process(delta: float) -> void:
	if not alive or not multiplayer.is_server():
		return
	_cool -= delta
	if _cool > 0.0:
		return
	if _target_profile == null:
		_target_profile = TargetProfile.make_turret()
	_target_profile.range_m = range_m
	var best := TargetSelector.pick(get_tree(), _target_profile, {"from": global_position, "team": side})
	if best == null:
		return
	_cool = refire
	var from := global_position
	var to := best.global_position + Vector3.UP * 4.0
	var bolt := Packs.weapon(BLASTER_ID)
	if bolt.is_empty():
		_fire_beam(from, to)
	else:
		_fire_bolt(bolt, from, to, best)


## The original turret's blaster bolt (catalog weapon TURRET_BLASTER: its own look and damage).
func _fire_bolt(bolt: Dictionary, from: Vector3, to: Vector3, target: Node3D) -> void:
	WeaponShot.launch_projectile({"shooter": self, "def": bolt, "from": from, "dir": (to - from).normalized(), "target": target})
	Sfx.play_at(bolt.get("sounds", {}).get("fire", "LAS100"), from)


## Without the Battledrome weapon catalog: an instant beam.
func _fire_beam(from: Vector3, to: Vector3) -> void:
	var q := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var end: Vector3 = hit.position if hit else to
	var battle := get_parent()
	if battle.has_method("fx"):
		battle.fx("beam", [from, end, Color(0.4, 1.0, 0.4), "LAS100"])
	if hit and hit.collider and hit.collider.has_method("apply_hit"):
		hit.collider.apply_hit(shield_damage, armor_damage, self, end)
