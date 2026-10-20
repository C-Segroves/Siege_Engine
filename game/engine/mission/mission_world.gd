class_name MissionWorld
extends RefCounted
## What the mission blocks may ask of the battle (docs/MECHANICS_UNIFICATION.md section 2). A game's adapter subclasses it and
## answers from its own battle; the defaults describe an empty world, so a block can be tested on a small stub.
## Targets and units are named by an id (a String the adapter understands: a tag, a name, a structure index).

## The output port the blocks talk to.
var sink: MissionSink = MissionSink.new()


func get_player_position() -> Vector3:
	return Vector3.ZERO


## The way the player faces (scans look along it).
func get_player_forward() -> Vector3:
	return Vector3.FORWARD


func is_player_alive() -> bool:
	return true


## Living players and bots of `team` (0 the player's side, 1 the enemy).
func get_living_count(_team: int) -> int:
	return 0


func get_target_position(_id: String) -> Vector3:
	return Vector3.ZERO


## True when the target is gone or disabled; an unknown target counts as not destroyed.
func is_target_destroyed(_id: String) -> bool:
	return false


func is_unit_alive(_id: String) -> bool:
	return true


## Kills the player's side has scored against `group` (a group name, or "" for any enemy).
func get_kill_count(_group: String) -> int:
	return 0


## Points of `team` (a score limit, a frag count).
func get_score(_team: int) -> int:
	return 0


func is_item_carried(_id: String) -> bool:
	return false


## Seconds the player has been outside the playable area (0 inside).
func get_out_of_area_seconds() -> float:
	return 0.0


## True when target `id` is within `range` of the player and inside the `cone_degrees` half-angle of where the player
## looks (scans). A game with its own sight rules (several players, a torso that turns) overrides this.
func is_target_in_view(id: String, range: float, cone_degrees: float) -> bool:
	var to_target := get_target_position(id) - get_player_position()
	if to_target.length() > range:
		return false
	return to_target.length() < 0.001 or rad_to_deg(get_player_forward().angle_to(to_target)) <= cone_degrees


## Straight distance from the player to target `id`.
func make_player_distance(id: String) -> float:
	return get_player_position().distance_to(get_target_position(id))
