class_name TaskListPane
extends VBoxContainer
## Option A of the lobby's right pane (docs/design/lobby_loadout_economy.md section 5.4, O6): "Your goals" - check up to
## three; "Teammates' goals" - what the squad's other pilots picked, read-only text (the squad coordinates in the
## chat). The host has Reroll for the board. The pane shows what the lobby gives it and reports toggles; it never
## reads Net.
##   show_goals(view)     view: {board, picked, max, teammates: [{name, goals}], squad_mode, is_host, rerollable}
##   goal_toggled(id, on) / reroll_requested

signal goal_toggled(goal_id: String, on: bool)
signal reroll_requested

const YOUR_GOALS := "Your goals (pick up to %d)"
const TEAMMATE_GOALS := "Teammates' goals (read only)"
const CHAT_HINT := "Talk to your squad in the chat to agree who does what."

var boxes := {}             # goal id -> CheckBox
var reroll_button: Button
var _title: Label
var _list: VBoxContainer
var _teammates_title: Label
var _teammates: VBoxContainer
var _hint: Label
var _board_key := ""
var _syncing := false


func _init() -> void:
	_title = Widgets.section("")
	add_child(_title)
	_list = VBoxContainer.new()
	add_child(_list)
	reroll_button = Widgets.small_button("Reroll goals", func() -> void: reroll_requested.emit())
	add_child(reroll_button)
	_teammates_title = Widgets.section(TEAMMATE_GOALS)
	add_child(_teammates_title)
	_teammates = VBoxContainer.new()
	add_child(_teammates)
	_hint = Widgets.paragraph(CHAT_HINT, "DimLabel")
	add_child(_hint)


func show_goals(view: Dictionary) -> void:
	_title.text = YOUR_GOALS % int(view.max)
	_sync_board(view)
	reroll_button.visible = bool(view.is_host) and bool(view.rerollable)
	var squad_mode: bool = bool(view.squad_mode)
	_teammates_title.visible = squad_mode
	_teammates.visible = squad_mode
	_hint.visible = squad_mode
	if squad_mode:
		_fill_teammates(view.teammates)


## The check boxes follow the board; picking is kept in place so focus stays on the box that was pressed.
func _sync_board(view: Dictionary) -> void:
	var key := JSON.stringify(view.board.map(func(g: Dictionary) -> String: return str(g.id)))
	if key != _board_key:
		_board_key = key
		_rebuild_boxes(view.board)
	_syncing = true
	var picked: Array = view.picked
	var full: bool = picked.size() >= int(view.max)
	for id in boxes:
		var box: CheckBox = boxes[id]
		box.button_pressed = picked.has(id)
		box.disabled = full and not picked.has(id)
	_syncing = false


func _rebuild_boxes(board: Array) -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	boxes.clear()
	if board.is_empty():
		_list.add_child(Widgets.paragraph("No goals for this mode.", "DimLabel"))
	for goal in board:
		var id := str(goal.id)
		var box := Widgets.check_box(LobbyGoals.make_goal_text(goal), false)
		box.toggled.connect(func(on: bool) -> void:
			if not _syncing:
				goal_toggled.emit(id, on))
		boxes[id] = box
		_list.add_child(box)


func _fill_teammates(mates: Array) -> void:
	for c in _teammates.get_children():
		_teammates.remove_child(c)
		c.queue_free()
	if mates.is_empty():
		_teammates.add_child(Widgets.paragraph(LobbyGoals.NO_TEAMMATES, "DimLabel"))
	for mate in mates:
		var goals: Array = mate.goals
		var text := "none picked yet" if goals.is_empty() else "; ".join(PackedStringArray(goals.map(func(g: Dictionary) -> String: return str(g.text))))
		_teammates.add_child(Widgets.paragraph("%s: %s" % [mate.name, text]))
