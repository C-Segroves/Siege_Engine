class_name TribesDoor
extends TribesMover
## A Tribes 1 base door (scripts/moveable.cs Door::*): it rests closed at its centre waypoint (Door::onNewPath:
## the last one of a "single" door, else the middle). A soldier of its team touching it opens it (Door::onCollision
## -> trigger: to the first waypoint, or the last for a "left" door); it closes again CLOSE_DELAY seconds after it
## got there with nobody touching it (Door::onFirst / onLast closeTime + 3). Without power it opens and stays
## open (Door::onPower). A force-field door fades out instead of moving.
## A door with the mission field triggerOpen opens only while a teammate (soldier or vehicle) is inside one of the
## GroupTrigger boxes of its group, and closes when the last one leaves (Door::onTrigEnter / onTrigLeave).
## A door the mission marks destroyable takes damage scaled by the game's $DoorScale per damage type
## (Door::onDamage; unknown types count 0, as an unset script global) up to its maxDamage; destroyed it stops where
## it is (Door::onDestroyed). Elevators take no damage (Elevator::onDamage is empty).

## Door::onFirst / onLast: closeTime = getSimTime() + 3.
const CLOSE_DELAY := 3.0

var _close_t := 0.0
## Hit points of a destroyable door (engine/damage; max_hp 0: not destroyable).
var damage := DamageTarget.new()
var hp: float:
	get: return damage.hp
var max_hp: float:
	get: return damage.max_hp
var _triggers: Array = []      # [Transform3D, AABB local box]


func _build(parent: Node3D, p_record: Dictionary, pal: String) -> void:
	super._build(parent, p_record, pal)
	for t in p_record.get("triggers", []):
		var b: Array = t.box
		var lo := Vector3(float(b[0][0]), float(b[0][1]), float(b[0][2]))
		var hi := Vector3(float(b[1][0]), float(b[1][1]), float(b[1][2]))
		_triggers.append([MapBuilder.make_transform(t), AABB(lo, hi - lo)])
	if str(p_record.get("destroyable", "")).to_lower() == "true":
		damage.max_hp = float(p_record.get("max_damage", 0.0)) * TribesMissionRuntime.TRIBES_DAMAGE_SCALE
		damage.hp = damage.max_hp
		damage.profile = TribesDamageProfile.make_door(TribesBase.load_specs("tribes").get("door_scale", {}))
		damage.killed.connect(_on_killed)
		add_to_group(Projectile.SPLASH_TARGETS)


## Triggered (mission field triggerOpen) rather than opened by touch.
func is_trigger_opened() -> bool:
	return str(record.get("triggeropen", "")) != "" and not _triggers.is_empty()


## True when `who` stands inside one of the door's GroupTrigger boxes.
func is_in_trigger(who: Node3D) -> bool:
	for t in _triggers:
		if (t[1] as AABB).has_point((t[0] as Transform3D).affine_inverse() * who.global_position):
			return true
	return false


## Host: a hit, scaled by the door's damage scale of the hit's type (TribesDamageProfile.make_door).
func apply_hit(shield_dmg: float, armor_dmg: float, attacker: Node = null, hit_pos := Vector3.ZERO) -> void:
	if max_hp <= 0.0 or stopped or not multiplayer.is_server():
		return
	damage.apply_event(DamageEvent.make(shield_dmg, armor_dmg, attacker, hit_pos))


func _on_killed(_event: DamageEvent) -> void:
	damage.alive = false
	_stop()
	if Net.is_online():
		_stop.rpc()


@rpc("authority", "call_remote", "reliable")
func _stop() -> void:
	stopped = true


func make_start_waypoint() -> int:
	return make_center()


## Door::onNewPath: the closed waypoint.
func make_center() -> int:
	var n := waypoints.size()
	return n - 1 if str(record.get("side", "single")) == "single" or n <= 2 else n / 2


## Door::onMove "open": the left door to the last waypoint, every other to the first.
func make_open_waypoint() -> int:
	return waypoints.size() - 1 if str(record.get("side", "")) == "left" and waypoints.size() > 2 else 0


func is_open() -> bool:
	return faded or goal != make_center()


func _think(delta: float) -> void:
	if not powered:
		_open()
		return
	if is_trigger_opened():
		if _has_trigger_users():
			_open()
		else:
			send_goal(make_center(), false)
		return
	if not find_users(is_touching).is_empty():
		_open()
		_close_t = CLOSE_DELAY
		return
	if is_at_goal():
		_close_t -= delta
		if _close_t <= 0.0:
			send_goal(make_center(), false)


## Teammates (soldiers or vehicles) inside a trigger box (GroupTrigger::onEnter: players and vehicles).
func _has_trigger_users() -> bool:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.alive and (no_team or team < 0 or int(v.team) == team) and is_in_trigger(v):
			return true
	return false


func _open() -> void:
	send_goal(make_open_waypoint(), fades)
