class_name Structure
extends StaticBody3D
## Destructible mission structure (base building, factory, listening post ...). Destroyed, it plays its game's
## destruction effects (DeathFx: ES1 base blast sequence, ES2 base explosion, Starsiege record explosion tag).

signal destroyed(s: Structure, killer: Node)
## Host: a hit landed (before a destroying one is reported by `destroyed`).
signal damaged(s: Structure, attacker: Node)

## Group of everything the targeting system may lock besides the vehicles ("vehicles"): Herc-like fields
## display_name, team, alive and integrity (0..1).
const TARGET_GROUP := "targetables"

## Size of a structure without meshes (metres), for its destruction effects.
const DEFAULT_HALF_WIDTH := 6.0
const DEFAULT_HEIGHT := 12.0

var net_id := 0
var team := 0
var display_name := "Structure"
var hp := 15000.0
var max_hp := 15000.0
var alive := true
## hp / max_hp for the target displays; the host sends it to the clients with every hit.
var integrity := 1.0
var shape: ShapeInstance
## "<pack>:<shape>": the pack whose death effects play when it is destroyed (DeathFx).
var shape_id := ""
## DeathFx kind and keys (Starsiege: the record's explosion tag) of its destruction.
var death_kind := DeathFx.KIND_STRUCTURE
var death_keys: Array = []
## True once the structure has its shape collision (scenery built without one keeps none).
var _collides := false

## Meta of the CollisionShape3D built from the shape (rebuilt when the shape changes).
const SHAPE_COLLISION_META := "shape_collision"
## A ruined structure's shape: flattened to this share of its height.
const RUINED_SCALE := Vector3(1, 0.35, 1)


static func create(parent: Node3D, shape_id: String, xf: Transform3D, pal: String, p_team: int, p_hp: float) -> Structure:
	var s := Structure.new()
	s.shape_id = shape_id
	s.transform = xf
	s.team = p_team
	s.max_hp = p_hp
	s.hp = p_hp
	s.name = make_net_name(shape_id, xf.origin)
	parent.add_child(s)
	s.add_to_groups()
	s.shape = ShapeInstance.new()
	s.add_child(s.shape)
	s.shape.build(Assets.shape(shape_id), 0, pal)
	s.build_collision()
	return s


## Trimesh collision of the shape's visible meshes as they stand (every game's structures: Earthsiege, Starsiege,
## Tribes base objects). A ruined or repaired structure rebuilds it, so the collision follows what is drawn.
func build_collision() -> void:
	_collides = true
	for col in find_children("*", "CollisionShape3D", false, false):
		if col.has_meta(SHAPE_COLLISION_META):
			remove_child(col)
			col.queue_free()
	var col := make_shape_collision(self, shape)
	if col != null:
		col.set_meta(SHAPE_COLLISION_META, true)
		add_child(col)


## A trimesh CollisionShape3D of `shape`'s visible meshes in `body`'s frame (null when it has no faces).
static func make_shape_collision(body: Node3D, p_shape: ShapeInstance) -> CollisionShape3D:
	var faces := PackedVector3Array()
	for mi in p_shape.find_children("*", "MeshInstance3D", true, false):
		if not mi.visible:
			continue
		var mxf: Transform3D = body.global_transform.affine_inverse() * mi.global_transform
		for v in mi.mesh.get_faces():
			faces.append(mxf * v)
	if faces.size() < 3:
		return null
	var cs := ConcavePolygonShape3D.new()
	cs.backface_collision = true
	cs.set_faces(faces)
	var col := CollisionShape3D.new()
	col.shape = cs
	return col


## The ruin: every cell in its destroyed state, the shape flattened; the collision follows (a wreck no longer
## blocks at full height).
func apply_ruined_look() -> void:
	for ci in shape.cell_count():
		shape.set_cell_state(ci, 2)
	shape.scale = RUINED_SCALE
	_refresh_collision()


## Back to intact (a Tribes object repaired from destroyed).
func apply_intact_look() -> void:
	shape.scale = Vector3.ONE
	for ci in shape.cell_count():
		shape.set_cell_state(ci, 0)
	_refresh_collision()


func _refresh_collision() -> void:
	if _collides and is_inside_tree():
		build_collision()


## The same node name on every peer (they build the mission identically), so hits and destruction reach the
## clients' copies by RPC.
static func make_net_name(shape_id: String, at: Vector3) -> String:
	return "S_%s_%d_%d_%d" % [shape_id.replace(":", "_"), roundi(at.x), roundi(at.y), roundi(at.z)]


func add_to_groups() -> void:
	add_to_group("structures")
	add_to_group(TARGET_GROUP)


## Takes the structure out of target cycling (scenery: rocks, indestructible props) or puts it back.
func apply_targetable(on: bool) -> void:
	if on:
		add_to_group(TARGET_GROUP)
	else:
		remove_from_group(TARGET_GROUP)


## Mission health < 100 means pre-damaged; 0 = already ruined.
func health_scale(health: float) -> void:
	if health <= 0.0:
		hp = 0.0
		alive = false
		apply_ruined_look()
	elif health < 100.0:
		hp = max_hp * health / 100.0
	integrity = clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)


## Shield-less structures take armour damage directly.
func apply_hit(_shield_dmg: float, armor_dmg: float, attacker: Node = null, _hit_pos := Vector3.ZERO) -> void:
	if not alive or not multiplayer.is_server():
		return
	hp -= armor_dmg
	integrity = clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	damaged.emit(self, attacker)
	if Net.is_online():
		_apply_integrity.rpc(integrity)
	if hp <= 0.0:
		destroy(attacker)


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_integrity(value: float) -> void:
	integrity = value


func destroy(killer: Node = null) -> void:
	if not alive:
		return
	alive = false
	integrity = 0.0
	if Net.is_online() and multiplayer.is_server():
		_apply_destroyed.rpc()
	_play_destruction()
	apply_ruined_look()
	destroyed.emit(self, killer)


@rpc("authority", "call_remote", "reliable")
func _apply_destroyed() -> void:
	destroy()


## Its game's destruction effects (DeathFx), sized to the intact shape.
func _play_destruction() -> void:
	var body := DeathFx.make_body(self, shape_id, death_kind, make_body_size())
	body.keys = death_keys.duplicate()
	DeathFx.play(get_parent(), body)


## Half width and height of the shape (metres, from its meshes).
func make_body_size() -> Vector2:
	var box := AABB()
	var found := false
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		var b: AABB = global_transform.affine_inverse() * mi.global_transform * (mi as MeshInstance3D).get_aabb()
		box = b if not found else box.merge(b)
		found = true
	if not found:
		return Vector2(DEFAULT_HALF_WIDTH, DEFAULT_HEIGHT)
	return Vector2(maxf(box.size.x, box.size.z) * 0.5, maxf(box.end.y, 0.0))
