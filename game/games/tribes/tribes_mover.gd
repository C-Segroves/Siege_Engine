class_name TribesMover
extends AnimatableBody3D
## A Tribes 1 Moveable of a base (docs/TRIBES_BASE_EQUIPMENT.md section 2): a door (TribesDoor) or an elevator
## (TribesElevator) that runs along the waypoints of the SimPath beside it in the mission (map.json "movers") at
## its MoveableData speed, powered like the rest of the base (TribesBase). The host decides where it goes (the
## subclass rules, from scripts/moveable.cs); every peer moves it there the same way (`goal`, sent reliably), so
## soldiers standing on an elevator ride it. A force-field door ($ForceFields) fades instead of moving: open, it
## has no collision and is not drawn.

const NODE_PREFIX := "MV_"
## A soldier this close to the mover's box (metres, horizontally, beyond the datablock's triggerRadius) touches it
## (Door::onCollision / Elevator::onCollision fire on contact).
const TOUCH_REACH := 1.0
## How far above an elevator's deck a soldier still counts as standing on it (metres).
const DECK_HEIGHT := 3.0

var kind := ""
var team := -1
var power_group := -1
var powered := false
var speed := 10.0
var waypoints: Array[Vector3] = []
var trigger_radius := 0.0
var no_team := false
var fades := false
var record: Dictionary = {}
## The waypoint it is moving to (or resting at), and whether a fading door is faded (open).
var goal := 0
var faded := false
## Destroyed or disabled: it stays where it is (Door::onDestroyed / onDisabled: Moveable::stop).
var stopped := false
var shape: ShapeInstance
var _box := AABB()
var _collisions: Array[CollisionShape3D] = []


## The door or elevator of map entry `p_record` under `parent` (null for other kinds).
static func make(parent: Node3D, p_record: Dictionary, pal: String) -> TribesMover:
	var m: TribesMover = TribesDoor.new() if str(p_record.get("kind", "")) == "door" else \
		TribesElevator.new() if str(p_record.get("kind", "")) == "elevator" else null
	if m:
		m._build(parent, p_record, pal)
	return m


func _build(parent: Node3D, p_record: Dictionary, pal: String) -> void:
	record = p_record
	kind = str(p_record.kind)
	team = int(p_record.get("team", -1))
	power_group = int(p_record.get("power_group", -1))
	speed = maxf(float(p_record.get("speed", 10.0)), 0.1)
	trigger_radius = float(p_record.get("trigger_radius", 0.0))
	no_team = str(p_record.get("noteam", "")) != ""
	fades = bool(p_record.get("fades", false))
	for w in p_record.get("waypoints", [p_record.pos]):
		waypoints.append(Vector3(float(w[0]), float(w[1]), float(w[2])))
	transform = MapBuilder.make_transform(p_record)
	name = "%s%d_%d_%d" % [NODE_PREFIX, roundi(position.x), roundi(position.y), roundi(position.z)]
	sync_to_physics = true
	parent.add_child(self)
	shape = ShapeInstance.new()
	add_child(shape)
	shape.build(Assets.shape(str(p_record.get("shape", ""))), 0, pal)
	TribesBaseObject.add_shape_collision(self, shape)
	for c in get_children():
		if c is CollisionShape3D:
			_collisions.append(c)
	_box = TribesBaseObject.make_shape_bounds(self, shape)
	goal = make_start_waypoint()
	global_position = waypoints[goal]


## Where it rests when the mission starts (the subclass rule).
func make_start_waypoint() -> int:
	return 0


func apply_power(on: bool) -> void:
	powered = on


func _physics_process(delta: float) -> void:
	if stopped:
		return
	if multiplayer.is_server():
		_think(delta)
	var to := waypoints[goal]
	global_position = global_position.move_toward(to, speed * delta)


## Host: the subclass rules (where to go next).
func _think(_delta: float) -> void:
	pass


func is_at_goal() -> bool:
	return global_position.distance_to(waypoints[goal]) < 0.01


## Host: moves to waypoint `index` (and fades / unfades) on every peer.
func send_goal(index: int, p_faded: bool) -> void:
	if index == goal and p_faded == faded:
		return
	_receive_goal(index, p_faded)
	if Net.is_online():
		_receive_goal.rpc(index, p_faded)


@rpc("authority", "call_remote", "reliable")
func _receive_goal(index: int, p_faded: bool) -> void:
	goal = clampi(index, 0, waypoints.size() - 1)
	faded = p_faded
	shape.visible = not faded
	for c in _collisions:
		c.set_deferred("disabled", faded)


## True when `soldier` may work it: alive, of its team (or it has none / noTeam set; Door / Elevator::onCollision).
func may_use(soldier: Infantry) -> bool:
	return soldier.alive and not soldier.stowed and (no_team or team < 0 or soldier.team == team)


## True when `soldier` touches the mover's box (grown by its trigger radius).
func is_touching(soldier: Node3D) -> bool:
	var local := global_transform.affine_inverse() * soldier.global_position
	return _box.grow(trigger_radius + TOUCH_REACH).has_point(local)


## True when `soldier` stands on the deck (inside the box horizontally, just above or on its top).
func is_on_deck(soldier: Node3D) -> bool:
	var local := global_transform.affine_inverse() * soldier.global_position
	var flat := AABB(Vector3(_box.position.x, _box.end.y - DECK_HEIGHT, _box.position.z),
		Vector3(_box.size.x, DECK_HEIGHT * 2.0, _box.size.z))
	return flat.grow(TOUCH_REACH * 0.5).has_point(local)


## The soldiers of the battle (the mover's parent) that may use it and pass `test`.
func find_users(test: Callable) -> Array:
	var out := []
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v is Infantry and may_use(v) and bool(test.call(v)):
			out.append(v)
	return out
