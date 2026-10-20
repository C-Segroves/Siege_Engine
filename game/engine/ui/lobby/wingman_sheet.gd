class_name WingmanSheet
extends ModalSheet
## The campaign wingmen of the next mission (LobbyWingmen): a picker per slot among the garage Hercs that can fly, and a
## button to arm them in the Hangar. Every pick is saved at once; `changed` tells the lobby to redraw its cards.

signal changed

const HANGAR_TEXT := "Arm wingmen in the Hangar"

var pickers: Array = []


## Opens the sheet over `host`; `on_hangar` opens the Hangar screen (an empty Callable leaves the button out).
static func show_over(host: Control, on_hangar: Callable) -> WingmanSheet:
	var sheet := WingmanSheet.new()
	sheet.set_title("WINGMEN")
	sheet._return_focus = host.get_viewport().gui_get_focus_owner()
	host.add_child(sheet)
	sheet._build(on_hangar)
	return sheet


func _build(on_hangar: Callable) -> void:
	var choices := LobbyWingmen.make_choices()
	for slot in LobbyWingmen.make_slot_count(Net.settings):
		var picker := Widgets.option_button(choices.map(func(c: Dictionary) -> String: return str(c.text)))
		var current := LobbyWingmen.make_herc_index(slot)
		picker.select(choices.find_custom(func(c: Dictionary) -> bool: return int(c.index) == current))
		picker.item_selected.connect(func(i: int) -> void:
			LobbyWingmen.apply_slot(slot, int(choices[i].index))
			changed.emit())
		pickers.append(picker)
		body.add_child(OptionRow.new("Wingman %d" % (slot + 1), picker))
	if on_hangar.is_valid():
		body.add_child(Widgets.button(HANGAR_TEXT, on_hangar))
	set_back("Back")
	set_primary("Done", close)
	focus_first.call_deferred()
