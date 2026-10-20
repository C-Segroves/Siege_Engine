class_name Objective
extends RefCounted
## One thing the mission asks of the player. The base keeps the identity, the text and the state; a kind decides the state
## in _make_state(world, dt). DONE and FAILED stay once reached. Kinds live in engine/mission/objectives/.

enum State { PENDING, ACTIVE, DONE, FAILED, AT_RISK }

var id := ""
var text := ""
## The mission cannot end in success while a required objective is open.
var required := true
## Primary objectives list first.
var primary := true
var state := State.ACTIVE


func _init(p_id := "", p_text := "") -> void:
	id = p_id
	text = p_text


func is_done() -> bool:
	return state == State.DONE


func is_failed() -> bool:
	return state == State.FAILED


## Moves the objective on by `dt` seconds; true when its state changed.
func apply_tick(world: MissionWorld, dt: float) -> bool:
	if state == State.DONE or state == State.FAILED or state == State.PENDING:
		return false
	var next := _make_state(world, dt)
	if next == state:
		return false
	state = next
	return true


## Starts a pending objective.
func apply_activate() -> void:
	if state == State.PENDING:
		state = State.ACTIVE


## The line of the objectives panel: {text, done}.
func make_line() -> Dictionary:
	return {"text": text, "done": state == State.DONE}


func _make_state(_world: MissionWorld, _dt: float) -> State:
	return state
