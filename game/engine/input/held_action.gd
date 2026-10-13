class_name HeldAction
extends RefCounted
## "Tap = one action, hold = another" on the gamepad (the Call of Duty convention, docs/CODING_STANDARDS.md
## section 2): the tap keeps its own action (it acts on press); holding the same pad button for `seconds` also
## fires this one once. Keyboard / mouse holds never fire it (the keyboard has its own key for the held action).
## The holds are SiegeInput.HELD_ACTIONS (held action -> [tap action, seconds]).

## The held action (e.g. "inventory_toggle"), the tap action whose pad button is held, and how long.
var held_action := ""
var action := ""
var seconds := 0.5
## True for the one frame in which the hold reached `seconds`.
var just_fired := false
var _held := 0.0


func _init(p_held_action: String) -> void:
	held_action = p_held_action
	var entry: Array = SiegeInput.HELD_ACTIONS.get(p_held_action, ["", 0.0])
	action = str(entry[0])
	seconds = float(entry[1])
	if action == "":
		push_error("HeldAction: '%s' is not in SiegeInput.HELD_ACTIONS" % p_held_action)


## Advances the hold timer by `delta`; sets just_fired on the frame the pad button has been held long enough.
func advance(delta: float) -> void:
	just_fired = false
	if not (SiegeInput.is_gamepad_active() and Input.is_action_pressed(action)):
		_held = 0.0
		return
	var before := _held
	_held += delta
	just_fired = before < seconds and _held >= seconds
