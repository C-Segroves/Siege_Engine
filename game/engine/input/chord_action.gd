class_name ChordAction
extends RefCounted
## "Two pad buttons together = one action" (docs/CODING_STANDARDS.md section 2): the call-in menu is LB + RB
## because every single pad button is taken on foot. The keyboard keeps its own key for the action.
## The chords are SiegeInput.CHORD_ACTIONS (chord action -> the buttons). Call advance() once per frame.

var chord_action := ""
var buttons: Array = []
## True for the one frame in which the last of the buttons went down.
var just_fired := false
var _was_down := false


func _init(p_chord_action: String) -> void:
	chord_action = p_chord_action
	buttons = SiegeInput.CHORD_ACTIONS.get(p_chord_action, [])
	if buttons.is_empty():
		push_error("ChordAction: '%s' is not in SiegeInput.CHORD_ACTIONS" % p_chord_action)


## Reads the first connected pad this frame.
func advance() -> void:
	var pads := Input.get_connected_joypads()
	var device: int = pads[0] if not pads.is_empty() else -1
	advance_with(func(button: int) -> bool: return device >= 0 and Input.is_joy_button_pressed(device, button))


## `is_down` answers "is this pad button held?" (a Callable taking a JoyButton).
func advance_with(is_down: Callable) -> void:
	var all_down := not buttons.is_empty() and buttons.all(func(b) -> bool: return is_down.call(b))
	just_fired = all_down and not _was_down
	_was_down = all_down
