class_name MissionScriptHost
extends RefCounted
## What a MissionScript senses and does, apart from its built-in logic. A game's adapter subclasses this (or fills it in
## after construction):
##   register_condition(name, callable)   callable(condition: Array) -> bool; the array is the whole condition, name first
##   register_action(name, callable)      callable(action: Array); the array is the whole action, name first
##   register_edge(rise, fall, sensor)    two conditions "rise(tag)" / "fall(tag)" that hold for the one tick after
##                                        sensor.call(tag) -> bool turned true / false (Aerial Assault became_disabled)
## and overrides the apply_* ports for the built-in actions that reach the player (prompt, audio, objective, info,
## error, and the end of the mission).

var _conditions := {}
var _actions := {}
var _edges := {}                 # rise name -> {fall: String, sensor: Callable}


func register_condition(name: String, handler: Callable) -> void:
	_conditions[name] = handler


func register_action(name: String, handler: Callable) -> void:
	_actions[name] = handler


func register_edge(rise: String, fall: String, sensor: Callable) -> void:
	_edges[rise] = {"fall": fall, "sensor": sensor}


func has_condition(name: String) -> bool:
	return _conditions.has(name)


func has_action(name: String) -> bool:
	return _actions.has(name)


func make_condition(condition: Array) -> bool:
	return bool((_conditions[str(condition[0])] as Callable).call(condition))


func apply_action(action: Array) -> void:
	(_actions[str(action[0])] as Callable).call(action)


func get_edges() -> Dictionary:
	return _edges


## A voice prompt plays (action "prompt").
func apply_prompt(_id: int) -> void:
	pass


## An audio cue plays (action "audio").
func apply_audio(_id: int) -> void:
	pass


## The objectives panel shows text `index` (actions "objective", "objective_by").
func apply_objective(_index: int) -> void:
	pass


## An info or error message of text `index` (actions "info", "error").
func apply_message(_index: int, _is_error: bool) -> void:
	pass


## The script ends the mission (actions "success", "fail"; `id` is the closing voice prompt).
func apply_end(_success: bool, _id: int) -> void:
	pass
