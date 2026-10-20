class_name AAScriptVM
extends MissionScript
## Runs the state machine of a scripted Aerial Assault mission or training (campaign/logic.json "script", transcribed from the
## PS2 executable by tools/aa_logic.py; format in its module doc). The machine itself is MissionScript; this shim gives it the
## Aerial Assault senses and actions (AAScriptHost) over `game`, an object with the vm_* methods that class lists
## (AAMissionRuntime in a battle, a stub in the tests).


func _init(p_game: Object, p_program: Dictionary) -> void:
	super(AAScriptHost.new(p_game), p_program)
