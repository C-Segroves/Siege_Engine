class_name Structure
extends StaticBody3D
## Destructible mission structure (base building, factory, listening post ...). Destroyed, it plays its game's
## destruction effects (DeathFx: ES1 base blast sequence, ES2 base explosion, Starsiege record explosion tag).

signal destroyed(s: Structure, killer: Node)
## Host: a hit landed (before a destroying one is reported by `destroyed`).
signal damaged(s: Structure, attacker: Node)
## Its side changed (captured, released) or, for a base object, it was disabled or repaired: power and targets follow.
signal state_changed(obj: Structure)

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
## The owner's team while the structure is captured (valid when capture_left > 0).
var home_team := -1
## Seconds the capture still holds (0: not captured). BaseCapture decides who captures and for how long.
var capture_left := 0.0
## A destroyed structure can be repaired back to life (a Tribes base object stays standing as a ruin); the other
## games' destroyed structures are gone for good.
var repairs_ruins := false
## Half width of the shape (metres), measured once.
var _half_width := -1.0
var _repair_sent_msec := 0
## True once the structure has its shape collision (scenery built without one keeps none).
var _collides := false

## A capture's timer is renewed by the capturer's repair work at most this often (seconds).
const CAPTURE_REFRESH_STEP := 1.0
## A repair is sent to the clients at most this often while it goes on (seconds); a revival or the last point at once.
const REPAIR_SEND_STEP := 0.2
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
	if is_captured():       # a captured structure that is destroyed returns to its owner as his ruin
		team = home_team
		capture_left = 0.0
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


# ------------------------------------------------------------------ repair and capture (BaseCapture, RepairDirector)

## The pack of the structure's game ("es1", "starsiege", "tribes2" ...): the key of its RepairRules block.
func make_pack() -> String:
	return shape_id.get_slice(":", 0) if shape_id.contains(":") else ""


## True when repair work can do something here: damaged, and alive or a ruin that may be repaired back.
func can_repair() -> bool:
	return (alive or repairs_ruins) and not is_fully_repaired()


func is_fully_repaired() -> bool:
	return alive and hp >= max_hp


## Distance from `from` to the structure's surface, roughly: centre distance less the shape's half width.
func make_reach_distance(from: Vector3) -> float:
	if _half_width < 0.0:
		_half_width = make_body_size().x
	return maxf(0.0, from.distance_to(global_position) - _half_width)


## Host: `amount` points of repair; a ruin comes back once it has hit points again. The clients follow by RPC.
func apply_repair(amount: float) -> void:
	if not multiplayer.is_server() or amount <= 0.0 or not can_repair():
		return
	var was_alive := alive
	hp = minf(max_hp, maxf(hp, 0.0) + amount)
	var ratio := clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)
	var now := Time.get_ticks_msec()
	if Net.is_online() and (not was_alive or hp >= max_hp or now - _repair_sent_msec >= int(REPAIR_SEND_STEP * 1000.0)):
		_repair_sent_msec = now
		_apply_repaired.rpc(ratio)
	_apply_repaired(ratio)


@rpc("authority", "call_remote", "reliable")
func _apply_repaired(ratio: float) -> void:
	integrity = ratio
	hp = max_hp * ratio
	if not alive and hp > 0.0:
		alive = true
		apply_intact_look()


func is_captured() -> bool:
	return capture_left > 0.0


## The owner's team: the captured object's home team, else its own.
func make_owner_team() -> int:
	return home_team if is_captured() else team


## Host: `by_team` takes the structure for `seconds` (a new capture, or the capturer's repair work refreshing it). When
## `by_team` is the owner's own team the structure goes home (recaptured).
func apply_capture(by_team: int, seconds: float) -> void:
	if not multiplayer.is_server() or seconds <= 0.0:
		return
	if is_captured() and by_team == home_team:
		apply_release()
		return
	if is_captured() and by_team == team:
		if capture_left < seconds - CAPTURE_REFRESH_STEP:      # the capturer's work renews it, a packet a second
			_send_team_state(team, seconds, home_team)
		return
	_send_team_state(by_team, seconds, team if not is_captured() else home_team)


## Host: the structure returns to its owner.
func apply_release() -> void:
	if not multiplayer.is_server() or not is_captured():
		return
	_send_team_state(home_team, 0.0, home_team)


func _send_team_state(p_team: int, left: float, p_home: int) -> void:
	if Net.is_online():
		_apply_team_state.rpc(p_team, left, p_home)
	_apply_team_state(p_team, left, p_home)


@rpc("authority", "call_remote", "reliable")
func _apply_team_state(p_team: int, left: float, p_home: int) -> void:
	var changed := p_team != team
	team = p_team
	capture_left = left
	home_team = p_home
	apply_side_changed()
	if changed:
		state_changed.emit(self)


## A kind of structure reacts to its side changing (a turret drops its target).
func apply_side_changed() -> void:
	pass


## A faction ownership assignment (TribesBase.apply_owners): the owner changes; a held capture goes on.
func apply_owner_team(p_team: int) -> void:
	if is_captured():
		home_team = p_team
	else:
		team = p_team


func _physics_process(delta: float) -> void:
	apply_capture_tick(delta)


## The capture runs out; the host then sends the structure home.
func apply_capture_tick(delta: float) -> void:
	if capture_left <= 0.0:
		return
	capture_left = maxf(capture_left - delta, 0.0)
	if capture_left <= 0.0 and multiplayer.is_server():
		_send_team_state(home_team, 0.0, home_team)
