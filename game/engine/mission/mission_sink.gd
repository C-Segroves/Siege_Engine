class_name MissionSink
extends RefCounted
## The output port of the mission blocks: what a mission shows and plays. The game's adapter overrides these (the battle's
## radio, objectives panel and nav display); the base ignores everything, so a block runs without a battle.


func apply_message(_message: MissionMessage) -> void:
	pass


func apply_voice(_voice: MissionVoice) -> void:
	pass


func apply_objectives_changed() -> void:
	pass


## Shows (`on`) or clears the nav marker / waypoint `id`.
func apply_nav(_id: String, _on: bool) -> void:
	pass


func is_voice_playing() -> bool:
	return false
