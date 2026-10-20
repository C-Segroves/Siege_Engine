class_name AAScriptHost
extends MissionScriptHost
## The Aerial Assault half of the script machine (campaign/logic.json "script"): the senses and actions the PS2
## executable's scripts use beyond MissionScript's built-ins, registered over `game`, an object with the vm_* methods
## below (AAMissionRuntime in a battle, a stub in the tests).
##
##   senses   vm_alive(team) -> int            living soldiers of team 0 (allies) / 1 (enemies)
##            vm_distance(tag) -> float        player to the nearest object tagged `tag` (0 when the map has none)
##            vm_ally_distance() -> float      player to the closest living ally (BIG_DISTANCE with none)
##            vm_enemy_distance(tag) -> float  the closest living enemy to the object tagged `tag`
##            vm_disabled(tag) -> bool         the base object tagged `tag` is disabled or destroyed
##            vm_destroyed() / vm_deployed() -> int   base objects destroyed / deployed so far
##            vm_switch() -> bool              the player reached the control switch
##            vm_boarded() -> bool             the player is on a vehicle (the vehicle pad is reached where there is none)
##            vm_voice_playing() -> bool       a voice prompt is playing
##            vm_input(name) -> float          the strength (0..1) of an input of the training lessons
##            vm_count(name) -> int            a training counter
##   actions  vm_prompt(id)  vm_audio(id)  vm_end(success, id)  vm_spawn(team, wave)  vm_order(team, task, target, slot)
##            vm_waypoint(tag, on)  vm_objective(index)  vm_message(index, is_error)  vm_destroy(tag)  vm_give(item, count)

## Distance answered when nothing is there to measure (no player, no living ally or enemy).
const BIG_DISTANCE := 100000.0

var game: Object


func _init(p_game: Object) -> void:
	game = p_game
	_register_senses()
	_register_actions()
	register_edge("became_disabled", "became_enabled", game.vm_disabled)


func apply_prompt(id: int) -> void:
	game.vm_prompt(id)


func apply_audio(id: int) -> void:
	game.vm_audio(id)


func apply_objective(index: int) -> void:
	game.vm_objective(index)


func apply_message(index: int, is_error: bool) -> void:
	game.vm_message(index, is_error)


func apply_end(success: bool, id: int) -> void:
	game.vm_end(success, id)


func _register_senses() -> void:
	register_condition("enemies", func(c: Array) -> bool: return MissionScript.compare(game.vm_alive(1), str(c[1]), float(c[2])))
	register_condition("allies", func(c: Array) -> bool: return MissionScript.compare(game.vm_alive(0), str(c[1]), float(c[2])))
	register_condition("near", func(c: Array) -> bool: return float(game.vm_distance(str(c[1]))) < float(c[2]))
	register_condition("far", func(c: Array) -> bool: return float(game.vm_distance(str(c[1]))) > float(c[2]))
	register_condition("ally_far", func(c: Array) -> bool: return float(game.vm_ally_distance()) > float(c[1]))
	register_condition("enemy_near", func(c: Array) -> bool: return float(game.vm_enemy_distance(str(c[1]))) < float(c[2]))
	register_condition("disabled", func(c: Array) -> bool: return bool(game.vm_disabled(str(c[1]))))
	register_condition("destroyed", func(c: Array) -> bool: return MissionScript.compare(game.vm_destroyed(), str(c[1]), float(c[2])))
	register_condition("deployed", func(c: Array) -> bool: return MissionScript.compare(game.vm_deployed(), str(c[1]), float(c[2])))
	register_condition("switch", func(_c: Array) -> bool: return bool(game.vm_switch()))
	register_condition("boarded", func(_c: Array) -> bool: return bool(game.vm_boarded()))
	register_condition("voice_playing", func(_c: Array) -> bool: return bool(game.vm_voice_playing()))
	register_condition("input", func(c: Array) -> bool:
		return float(game.vm_input(str(c[1]))) >= float(c[2]) if c.size() > 2 else float(game.vm_input(str(c[1]))) > 0.0)
	register_condition("count", func(c: Array) -> bool: return MissionScript.compare(game.vm_count(str(c[1])), str(c[2]), float(c[3])))


func _register_actions() -> void:
	register_action("spawn", func(a: Array) -> void: game.vm_spawn(_make_team(a[1]), int(a[2])))
	register_action("order", func(a: Array) -> void:
		game.vm_order(_make_team(a[1]), int(a[2]), a[3] if a[3] != null else "", int(a[4])))
	register_action("waypoint", func(a: Array) -> void: game.vm_waypoint(str(a[1]), true))
	register_action("clear", func(a: Array) -> void: game.vm_waypoint(str(a[1]), false))
	register_action("destroy", func(a: Array) -> void: game.vm_destroy(str(a[1])))
	register_action("give", func(a: Array) -> void: game.vm_give(str(a[1]), int(a[2])))


## The side a script names: "enemies" are team 1, anything else the allies (team 0).
static func _make_team(side: Variant) -> int:
	return 1 if str(side) == "enemies" else 0
