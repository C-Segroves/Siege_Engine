class_name ES2MissionWorld
extends MissionWorld
## What the shared mission blocks ask of an Earthsiege 2 battle: the living player Herc, the scan test (the squad's order
## target or the scan objectives' targets, ES2Objectives) and the seconds the mission status has forced the end (the player
## outside the mission rectangle, ES2Objectives.get_forced_end_seconds).

var _rt: MissionRuntimeES2


func _init(runtime: MissionRuntimeES2) -> void:
	_rt = runtime
	sink = runtime.get_sink()


func get_player_position() -> Vector3:
	var p := _rt._living_player()
	return p.global_position if p != null else Vector3.ZERO


func is_player_alive() -> bool:
	return _rt._living_player() != null


## Seconds the status "left the mission area" (7 / 8) has held.
func get_out_of_area_seconds() -> float:
	return _rt.rules.get_area_seconds()


## True when a scan target is within `range` (a structure's slack added) of the living player and inside the cone (DBSIM scan).
func is_target_in_view(_id: String, range: float, cone_degrees: float) -> bool:
	var me := _rt._living_player()
	return me != null and _rt.rules.is_facing_scan_target(me, range, deg_to_rad(cone_degrees))
