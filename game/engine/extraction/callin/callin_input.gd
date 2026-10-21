class_name CallinInput
extends RefCounted
## The local player's way into the call-in menu: the key (callin_menu) and the pad chord (LB + RB), which also cancels a
## laser designation in progress. CallinDirector forwards its _process and _unhandled_input here.

var _callins: CallinDirector
var _chord := ChordAction.new("callin_menu")


func _init(callins: CallinDirector) -> void:
	_callins = callins


## The menu opens for the local player while he is in the raid and up.
func may_open_menu() -> bool:
	var c := _callins
	return not c.battle.is_over() and c.director.my_status == ExtractionDirector.STATUS_IN_RAID \
		and not DownedState.is_downed(c.battle.player) and not c.director.revive.is_local_reviving()


## One frame of the pad chord: `is_down` answers "is this pad button held?".
func apply_chord_frame(is_down: Callable) -> void:
	_chord.advance_with(is_down)
	if _chord.just_fired and may_open_menu():
		if _callins.designator.is_designating():
			_callins.designator.apply_cancel()
		else:
			_callins.toggle_menu()


## True when `event` was taken (the laser's, or the menu key).
func apply_event(event: InputEvent) -> bool:
	if _callins.designator.apply_input(event):
		return true
	if event.is_action_pressed("callin_menu") and may_open_menu():
		_callins.toggle_menu()
		return true
	return false


static func make_pad_reader() -> Callable:
	var pads := Input.get_connected_joypads()
	var device: int = pads[0] if not pads.is_empty() else -1
	return func(button: int) -> bool: return device >= 0 and Input.is_joy_button_pressed(device, button)
