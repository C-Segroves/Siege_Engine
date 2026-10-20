class_name ES1MissionWorld
extends MissionWorld
## What the shared mission blocks ask of an Earthsiege 1 battle: the living player Herc, the player's time outside the
## map, and the player squad's order target (MSN group 0's target, ES1WinRules) and the datalink to it. The two ids are
## the targets the blocks are given.

## The squad's order target: what is destroyed, protected or guarded.
const ORDER_TARGET := "order_target"
## The object the datalink connects to (a group target's first living member).
const DATALINK_TARGET := "datalink"

var _rt: MissionRuntime


func _init(runtime: MissionRuntime) -> void:
	_rt = runtime
	sink = runtime.get_sink()


func get_player_position() -> Vector3:
	var p := _rt._living_player()
	return p.global_position if p != null else Vector3.ZERO


func is_player_alive() -> bool:
	return _rt._living_player() != null


func get_out_of_area_seconds() -> float:
	return _rt.make_player_out_seconds()


## True once the order target is destroyed (a group: all members lost).
func is_target_destroyed(_id: String) -> bool:
	var t = _rt.win_rules.squad_target()
	return t is Dictionary and _rt.win_rules.target_status(t) == ES1WinRules.STATUS_DESTROYED


## False once the order target is lost (heavily damaged or destroyed): the guard order fails on it.
func is_unit_alive(_id: String) -> bool:
	var t = _rt.win_rules.squad_target()
	return not (t is Dictionary and _rt.win_rules.target_status(t) >= ES1WinRules.STATUS_LOST)


## The datalink position (DBSIM 0x1cda0, 0x15f80): any living player Herc within `range` of the link on the ground
## plane and facing it, with its torso, inside the cone.
func is_target_in_view(_id: String, range: float, cone_degrees: float) -> bool:
	var link := _rt.win_rules._datalink_node()
	if link == null:
		return false
	for v in _rt.win_rules.get_living_players():
		if _is_facing(v, link, range, deg_to_rad(cone_degrees)):
			return true
	return false


static func _is_facing(v: Node3D, link: Node3D, range: float, cone: float) -> bool:
	var to := link.global_position - v.global_position
	to.y = 0.0
	if to.length() >= range:
		return false
	if to.is_zero_approx():
		return true
	var torso := float(v.get("torso_yaw")) if v.get("torso_yaw") != null else 0.0
	var forward := (v.global_basis * Basis(Vector3.UP, torso)) * Vector3.FORWARD
	forward.y = 0.0
	return forward.angle_to(to) < cone
