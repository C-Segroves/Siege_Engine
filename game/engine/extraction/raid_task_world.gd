class_name RaidTaskWorld
extends MissionWorld
## What the objectives of a raid task (RaidTasks) ask of the raid: kills scored, base objects destroyed and the flags
## a player carries. RaidTasks fills it in from the raid's events, then ticks the task's objective once.
## Names are the task key ("<peer>:<task id>"); the carried flags are those of the player being paid out.

var kills := {}                  # task key -> kills scored against the task's faction
var destroyed := {}              # task key -> true once the task's generator is gone
var flags_carried := 0


func get_kill_count(group: String) -> int:
	return int(kills.get(group, 0))


func is_target_destroyed(id: String) -> bool:
	return bool(destroyed.get(id, false))


func is_item_carried(_id: String) -> bool:
	return flags_carried > 0
