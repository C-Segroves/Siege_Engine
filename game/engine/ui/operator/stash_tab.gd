class_name StashTab
extends VBoxContainer
## The raid-only third side of Operator Setup: the kit that goes into the raid and the stash behind it
## (docs/design/lobby_loadout_economy.md section 6.1, extraction extras). Move stacks between them, fill the one insured
## slot with a kit stack or a worn paid look unlock, and read what a death costs. Weapons, ammunition and gear are
## physical stock here, lost with the kit; they are bought in the store under "Supplies".

signal rebuilt

const PAGE_SIZE := 40
const BANNER := "Dying loses the kit, the worn paid armour, body and skin, and a called-in vehicle. Re-buy the look for 100 cr. The insured slot keeps one."

var _state: OperatorState
var _rows: VBoxContainer
var _stash_shown := PAGE_SIZE
var _focus_key := ""


func _init(state: OperatorState) -> void:
	_state = state
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(Widgets.section("KIT AND STASH"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)


func make_controls() -> Array[Control]:
	return UiActions.focusables(_rows)


## Rebuilds the banner, the insured slot, the kit and the stash from the extraction profile.
func refresh() -> void:
	_remember_focus()
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	var profile := _state.extraction
	if profile == null:
		return
	_rows.add_child(Widgets.paragraph(BANNER, "BadgeAtRisk"))
	_rows.add_child(Widgets.paragraph(ExtractionScreenText.make_insured_text(profile), "DimLabel"))
	_add_worn_unlocks(profile)
	_rows.add_child(Widgets.section("Kit"))
	_rows.add_child(Widgets.paragraph(ExtractionScreenText.make_kit_summary(profile), "DimLabel"))
	for id in profile.kit.stacks.keys():
		_rows.add_child(_make_kit_row(profile, str(id)))
	_rows.add_child(Widgets.section("Stash"))
	_add_stash(profile)
	_restore_focus.call_deferred()
	rebuilt.emit()


func _add_worn_unlocks(profile: ExtractionProfile) -> void:
	var at_risk := _state.profile.make_raid_start_risk(_state.ctx)
	for id in at_risk:
		var insured := profile.make_insured_unlock_id() == str(id)
		var button := _make_button("Uninsure" if insured else "Insure", "worn:" + str(id), func() -> void:
			_change(profile.apply_uninsure if insured else func() -> void: profile.apply_insure_unlock(str(id), at_risk)))
		_rows.add_child(ItemRow.make("%s  (worn, at risk)" % SlotCheck.make_name(str(id)), "Lost on death unless insured", [button]))


func _make_kit_row(profile: ExtractionProfile, id: String) -> Control:
	var units := maxi(profile.kit.count(id), 1)
	var insured: bool = id == profile.make_insured_id()
	var insure := _make_button("Uninsure" if insured else "Insure", "insure:" + id, func() -> void:
		_change(profile.apply_uninsure if insured else func() -> void: profile.apply_insure(id)))
	var to_stash := _make_button("To stash", "kit:" + id, func() -> void: _change(func() -> void: profile.apply_move_to_stash(id, units)))
	_add_secondary(insure, to_stash)
	_add_secondary(to_stash, to_stash)
	return ItemRow.make(ExtractionItems.make_stack_text(id, units) + ("   [INSURED]" if insured else ""), ExtractionScreenText.make_item_detail(id, units), [insure, to_stash])


func _add_stash(profile: ExtractionProfile) -> void:
	var ids := profile.stash.stacks.keys()
	if ids.is_empty():
		_rows.add_child(Widgets.label("Empty.", "DimLabel"))
		return
	for id in ids.slice(0, _stash_shown):
		_rows.add_child(_make_stash_row(profile, str(id)))
	if ids.size() > _stash_shown:
		_rows.add_child(Widgets.small_button("Show more (%d left)" % (ids.size() - _stash_shown), func() -> void:
			_stash_shown += PAGE_SIZE
			refresh()))


func _make_stash_row(profile: ExtractionProfile, id: String) -> Control:
	var units := profile.stash.count(id)
	var lot := ExtractionShop.make_buy_units(id)
	var to_kit := _make_button("To kit", "stash:" + id, func() -> void: _move_to_kit(profile, id, lot))
	return ItemRow.make(ExtractionItems.make_stack_text(id, units), ExtractionScreenText.make_item_detail(id, units), [to_kit])


func _move_to_kit(profile: ExtractionProfile, id: String, units: int) -> void:
	var moved := profile.apply_move_to_kit(id, units)
	_state.apply_status("" if moved > 0 else "No room in the kit for %s." % ExtractionItems.make_name(id))
	_state.apply_changed()


func _change(change: Callable) -> void:
	change.call()
	_state.apply_changed()


func _make_button(text: String, key: String, on_pressed: Callable) -> Button:
	var b := Widgets.small_button(text, on_pressed)
	b.set_meta("focus_key", key)
	return b


## Right click / pad X on a kit row's buttons: `target` is pressed (the stack goes back to the stash).
func _add_secondary(button: Button, target: Button) -> void:
	button.gui_input.connect(func(event: InputEvent) -> void:
		if RowButton.is_secondary(event):
			button.accept_event()
			target.pressed.emit())


func _remember_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus != null and _rows.is_ancestor_of(focus):
		_focus_key = str(focus.get_meta("focus_key", ""))


func _restore_focus() -> void:
	if _focus_key == "" or not is_inside_tree():
		return
	var key := _focus_key
	_focus_key = ""
	for c in UiActions.focusables(_rows):
		if str(c.get_meta("focus_key", "")) == key:
			c.grab_focus()
			return
