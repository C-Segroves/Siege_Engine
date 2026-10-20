class_name SSMissionWorld
extends MissionWorld
## What the shared mission blocks ask of a Starsiege battle: whether the player lives, and the target the player has
## locked (the scan). The sink stays the base one: the scan's stage texts are empty here (SSMissionSink is the radio).

var _rt: StarsiegeMissionRuntime
## The target the player keeps locked (null when none): set by SSSensors before each scan step.
var locked_target: Node3D = null


func _init(runtime: StarsiegeMissionRuntime) -> void:
	_rt = runtime


func get_player_position() -> Vector3:
	return _rt.battle.player.global_position


func is_player_alive() -> bool:
	return not _rt.player_dead


func get_target_position(_id: String) -> Vector3:
	return locked_target.global_position


## The lock is the aim: any direction counts, only the range does.
func is_target_in_view(_id: String, range: float, _cone_degrees: float) -> bool:
	return locked_target != null and get_player_position().distance_to(locked_target.global_position) <= range
