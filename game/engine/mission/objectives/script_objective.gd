class_name ScriptObjective
extends Objective
## An objective a script drives: its state and text are set from outside (Starsiege brief objectives, Tribes HUD lines,
## Vengeance on_objective, Aerial Assault vm_objective).


func apply_state(p_state: State) -> void:
	state = p_state


func apply_text(p_text: String) -> void:
	text = p_text
