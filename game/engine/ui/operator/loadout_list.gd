class_name LoadoutList
extends VBoxContainer
## The left column of Operator Setup: the fit bar and one row per place the armour or vehicle has (LoadoutLayout.make_rows):
## armour, each weapon followed by its ammunition, gear, backpack; or the vehicle's hardpoints and skin. Selecting a row
## filters the store to what fits it; right click / pad X removes. Rebuilt from OperatorState on every change.

signal rebuilt
signal row_chosen(row_key: String)

var _state: OperatorState
var _title: Label
var _fit_label: Label
var _fit_bar: ProgressBar
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _tooltip: ItemTooltip
var _focus_key := ""


func _init(state: OperatorState, tooltip: ItemTooltip) -> void:
	_state = state
	_tooltip = tooltip
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_title = Widgets.section("LOADOUT")
	add_child(_title)
	_fit_label = Widgets.label("")
	add_child(_fit_label)
	_fit_bar = ProgressBar.new()
	_fit_bar.show_percentage = false
	_fit_bar.max_value = 1.0
	_fit_bar.custom_minimum_size = Vector2(0, 10)
	_fit_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fit_bar)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)


## Rebuilds the rows and the fit line from the open slot.
func refresh() -> void:
	_remember_focus()
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	_refresh_fit()
	var rows := _state.make_rows()
	if rows.is_empty():
		_rows.add_child(Widgets.paragraph(_make_empty_text(), "DimLabel"))
	var blocks := _state.make_block_texts()
	var at_risk := _state.make_at_risk_ids()
	for r in rows:
		_rows.add_child(_make_row(r, blocks, at_risk))
	_restore_focus.call_deferred()
	rebuilt.emit()


## The focusable rows, top to bottom.
func make_rows() -> Array[Control]:
	return UiActions.focusables(_rows)


## The row control holding `row_key`, or null.
func find_row(row_key: String) -> LoadoutRow:
	for c in _rows.get_children():
		if c is LoadoutRow and str((c as LoadoutRow).row.key) == row_key:
			return c
	return null


## The drop-down row (a raid's kit) holding `row_key`, or null.
func find_kit_row(row_key: String) -> KitRow:
	for c in _rows.get_children():
		if c is KitRow and str((c as KitRow).row.key) == row_key:
			return c
	return null


func _make_empty_text() -> String:
	return "No vehicle yet: pick one under Look." if _state.side == LoadoutLayout.SIDE_VEHICLE else "No infantry game is installed."


func _refresh_fit() -> void:
	var fit := _state.make_fit()
	_fit_label.text = OperatorText.make_fit_text(_state.side, fit)
	_fit_label.theme_type_variation = "" if bool(fit.ok) else "BadgeNotAllowed"
	_fit_bar.visible = _state.side == LoadoutLayout.SIDE_INFANTRY and float(fit.kg_max) > 0.0
	_fit_bar.value = clampf(float(fit.kg) / maxf(float(fit.kg_max), 0.001), 0.0, 1.0)
	_title.text = "LOADOUT  -  %s" % ("INFANTRY" if _state.side == LoadoutLayout.SIDE_INFANTRY else "VEHICLE")


func _make_row(r: Dictionary, blocks: Dictionary, at_risk: Array) -> Control:
	if r.has("choices"):
		return _make_kit_row(r, blocks, at_risk)
	r = _make_shown_row(r)
	var id := OperatorText.make_row_unlock_id(r)
	var lost := id != "" and _state.ctx.loss_on_death and _state.profile.unlocks.is_lost(id)
	var badge := OperatorText.make_row_badge(str(blocks.get(r.key, "")), at_risk.has(id), lost)
	var row := LoadoutRow.make(r, _make_part_name(r), badge)
	row.pressed.connect(_on_row_pressed.bind(str(r.key)))
	row.removed.connect(_state.apply_remove)
	row.adjusted.connect(_state.apply_adjust)
	row.mouse_entered.connect(_on_row_hover.bind(id))
	row.focus_entered.connect(_on_row_hover.bind(id))
	_tooltip.watch(row, _make_row_tooltip.bind(r, str(blocks.get(r.key, "")), id))
	if str(r.key) == _state.selected_row:
		row.theme_type_variation = "TabButton"
		row.toggle_mode = true
		row.set_pressed_no_signal(true)
	return row


func _make_kit_row(r: Dictionary, blocks: Dictionary, at_risk: Array) -> KitRow:
	var id := OperatorText.make_row_unlock_id(r)
	var lost := id != "" and _state.ctx.loss_on_death and _state.profile.unlocks.is_lost(id)
	var row := KitRow.make(r, OperatorText.make_row_badge(str(blocks.get(r.key, "")), at_risk.has(id), lost))
	row.chosen.connect(_state.apply_choose)
	row.removed.connect(_state.apply_remove)
	row.option.mouse_entered.connect(_on_row_hover.bind(id))
	row.option.focus_entered.connect(_on_row_hover.bind(id))
	_tooltip.watch(row.option, _make_row_tooltip.bind(r, str(blocks.get(r.key, "")), id))
	return row


## The row as drawn: the armour row says "Armour" (its name is the part), an ammunition row needs no name (the weapon is the row above).
func _make_shown_row(r: Dictionary) -> Dictionary:
	var shown := r.duplicate()
	if str(r.kind) == "armour":
		shown.label = "Armour"
	return shown


func _make_part_name(r: Dictionary) -> String:
	if str(r.kind) == "ammo":
		return ""
	if str(r.kind) == MountEntries.KIND_ROW:
		return str(r.current)
	if str(r.kind) == "gear" and str(r.current) != "":
		return ""
	if str(r.key) == "herc_skin":
		return _make_herc_skin_name(str(r.current))
	return OperatorText.make_row_name(r, _state.has_store())


func _make_herc_skin_name(skin_id: String) -> String:
	for s in SkinCatalog.make_vehicle_skin_choices(_state.make_slot().vehicle):
		if str(s.id) == skin_id:
			return str(s.label)
	return "Default"


func _make_row_tooltip(r: Dictionary, blocked: String, id: String) -> Dictionary:
	if id == "":
		var hint := "Pick from the drop-down. Right click / X empties it." if r.has("choices") else "Right click / X removes. Pick a part in the store."
		return {"title": str(r.label), "lines": [hint], "warning": blocked}
	var data := OperatorText.make_tooltip(StoreCatalog.make_entry(id, _state.ctx, _state.profile))
	data.warning = blocked if blocked != "" else str(data.warning)
	return data


func _on_row_pressed(row_key: String) -> void:
	var r := _state.find_row(row_key)
	if r.is_empty():
		return
	if str(r.kind) == MountEntries.KIND_ROW and bool(r.locked):
		_state.apply_status("In a raid the vehicle is fitted at the call-in, not here.")
		return
	if str(r.kind) == MountEntries.KIND_ROW:
		_state.apply_select_row(row_key)
		row_chosen.emit(row_key)
		return
	if str(r.kind) in ["ammo", "gear"]:
		_state.apply_fill(row_key)
		return
	if str(r.kind) == "hardpoint" and bool(r.locked):
		_state.apply_status(OperatorText.make_hardpoint_locked_text(_state.ctx))
		return
	if bool(r.locked) or str(r.kind) == "armour":
		_state.apply_status("The armour is chosen under Look.")
		return
	_state.apply_select_row(row_key)
	row_chosen.emit(row_key)


func _on_row_hover(id: String) -> void:
	if id != "":
		_state.apply_preview(StoreCatalog.make_entry(id, _state.ctx, _state.profile))


func _remember_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus is LoadoutRow and _rows.is_ancestor_of(focus):
		_focus_key = str((focus as LoadoutRow).row.key)
	elif focus is OptionButton and _rows.is_ancestor_of(focus):
		_focus_key = str(focus.get_meta("row_key", ""))


func _restore_focus() -> void:
	if _focus_key == "" or not is_inside_tree():
		return
	var row: Control = find_row(_focus_key)
	if row == null and find_kit_row(_focus_key) != null:
		row = find_kit_row(_focus_key).option
	_focus_key = ""
	if row != null and row.is_visible_in_tree():
		row.grab_focus()
