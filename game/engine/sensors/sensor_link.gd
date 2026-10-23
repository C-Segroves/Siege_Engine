class_name SensorLink
extends RefCounted
## Whether the player's side has its sensor link in a battle (docs/COMMAND_MAP.md section 6): a campaign mission
## whose story switches the radar off (the mission runtimes call apply_down from the original's own flag or
## script call) takes the radar and the command map away together, and gives them back when the story turns the
## radar on again. Other battles (versus, arena, extraction, Tribes multiplayer) always have it.

const META := "sensor_link_down"
## Shown when the command map is asked for without the link (remake wording; the originals had no command map).
const DOWN_TEXT := "Command map unavailable - no sensor link"


## True while the radar works (no mission has taken it down).
static func is_up(battle: Node) -> bool:
	return battle == null or not bool(battle.get_meta(META, false))


## Takes the link down (`down`) or brings it back.
static func apply_down(battle: Node, down: bool) -> void:
	if down:
		battle.set_meta(META, true)
	elif battle.has_meta(META):
		battle.remove_meta(META)


## The battle a radar's `unit` fights in (its Battle ancestor), else null.
static func battle_of(unit: Node) -> Node:
	var n := unit
	while n != null and not (n is Battle):
		n = n.get_parent()
	return n
