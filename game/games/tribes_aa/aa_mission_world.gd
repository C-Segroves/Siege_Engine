class_name AAMissionWorld
extends MissionWorld
## What the mission blocks ask of an Aerial Assault battle: where the player is, the arena score and whether a fallback
## goal's generator is down (target id "gen:N", N the index in the runtime's `targets`).

## Where a missing player is: nowhere any area reaches.
const NO_PLAYER := Vector3(1.0e9, 1.0e9, 1.0e9)
const GENERATOR_ID := "gen:%d"

var _runtime: AAMissionRuntime


func _init(p_runtime: AAMissionRuntime, p_sink: MissionSink) -> void:
	_runtime = p_runtime
	sink = p_sink


func get_player_position() -> Vector3:
	var p: Herc = _runtime.battle.player
	return p.global_position if p != null and is_instance_valid(p) else NO_PLAYER


func get_score(_team: int) -> int:
	return _runtime.arena_score()


func is_target_destroyed(id: String) -> bool:
	return _runtime.is_generator_down(int(id.get_slice(":", 1)))
