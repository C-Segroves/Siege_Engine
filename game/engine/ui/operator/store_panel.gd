class_name StorePanel
extends VBoxContainer
## The store of Operator Setup (right top): category tabs, filters (game, text, owned, fits the selected row, allowed in
## this mode, sort) and the entries of StoreCatalog as rows. Free parts (weapons and ammunition outside a raid) show no
## price; a click equips an owned part, asks before buying one for sale, offers a buy back for a lost one. Where there
## is no store (the campaign garage, a bot card) the same list is a plain "PARTS" picker. In a raid the "Supplies"
## category sells the kit stock into the stash.

signal rebuilt
signal entry_chosen(entry: Dictionary)

const PAGE_SIZE := 60
const SORT_WIDTH := 150
const ALL_GAMES := ""
const SORTS := [["Name", StoreCatalog.SORT_NAME], ["Price", StoreCatalog.SORT_PRICE], ["Rating", StoreCatalog.SORT_RATING]]
## Loadout row kinds whose selection narrows the store ("fits slot").
const FITTING_ROWS := ["weapon", "hardpoint", "gear", "pack"]
## The unlock kinds each side of the screen shows (hand weapons and Herc weapons share the "Weapons" tab, skins likewise).
const INFANTRY_KINDS := ["weapon", "ammo", "gear", "pack", "armor", "body", "skin", "vehicle"]
const VEHICLE_KINDS := ["herc_weapon", "vehicle", "herc_skin"]

var _state: OperatorState
var _tooltip: ItemTooltip
var _title: Label
var _category_row: HFlowContainer
var _pack_picker: OptionButton
var _search: LineEdit
var _owned: CheckBox
var _fits: CheckBox
var _allowed: CheckBox
var _sort: OptionButton
var _list: VBoxContainer
var _scroll: ScrollContainer
var _footnote: Label
var _packs: Array = [ALL_GAMES]
var _categories: Array = []
var _category := ""
var _entries: Array = []
var _shown := PAGE_SIZE
var _focus_id := ""


func _init(state: OperatorState, tooltip: ItemTooltip) -> void:
	_state = state
	_tooltip = tooltip
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_title = Widgets.section("STORE" if state.has_store() else "PARTS")
	add_child(_title)
	_build_categories()
	_build_filters()
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	_footnote = Widgets.paragraph("", "DimLabel")
	add_child(_footnote)
	_state.side_changed.connect(_on_side_changed)
	_state.selection_changed.connect(_on_selection_changed)


func get_category() -> String:
	return _category


func make_entries() -> Array:
	return _entries


## Switches to category `id` and redraws.
func apply_category(id: String) -> void:
	if id == _category or not _categories.any(func(c: Dictionary) -> bool: return c.id == id):
		return
	_category = id
	_shown = PAGE_SIZE
	_sync_category_buttons()
	refresh()


## LB / RB: the next (+1) or previous (-1) category, wrapping.
func apply_step_category(direction: int) -> void:
	var ids := _categories.map(func(c: Dictionary) -> String: return str(c.id))
	if ids.size() > 1:
		apply_category(ids[(ids.find(_category) + direction + ids.size()) % ids.size()])


## Sets the text filter (tests and a future type-ahead).
func apply_search(text: String) -> void:
	_search.text = text
	_shown = PAGE_SIZE
	refresh()


## Reads the entries again (the profile or the open slot changed) and redraws, keeping the focused entry.
func refresh() -> void:
	_remember_focus()
	_sync_availability()
	_entries = _make_fitting_first(_make_current_entries())
	_rebuild_rows()
	var hidden := _state.profile.unlocks.make_hidden_count()
	_footnote.text = "%d unlocks need games that are not installed" % hidden if hidden > 0 else ""
	_footnote.visible = hidden > 0


## The focusable controls from the top: category tabs, filters, entries.
func make_controls() -> Array[Control]:
	return UiActions.focusables(self)


func make_row_of(entry_id: String) -> StoreRow:
	for c in _list.get_children():
		if c is StoreRow and str((c as StoreRow).entry.id) == entry_id:
			return c
	return null


# ------------------------------------------------------------------ building

func _build_categories() -> void:
	_categories = StoreCatalog.make_categories(_state.ctx) if _state.has_store() else StoreCatalog.make_part_categories()
	_category = str(_categories[0].id) if not _categories.is_empty() else ""
	_category_row = HFlowContainer.new()
	add_child(_category_row)
	var group := ButtonGroup.new()
	for c in _categories:
		var b := Button.new()
		b.text = str(c.label)
		b.theme_type_variation = "TabButton"
		b.toggle_mode = true
		b.button_group = group
		b.set_meta("category", c.id)
		b.pressed.connect(apply_category.bind(str(c.id)))
		_category_row.add_child(b)
	_sync_category_buttons()


func _sync_category_buttons() -> void:
	for b in _category_row.get_children():
		(b as Button).set_pressed_no_signal(str(b.get_meta("category")) == _category)


func _build_filters() -> void:
	var flow := HFlowContainer.new()
	add_child(flow)
	for pack in Packs.packs.keys():
		if Assets.has_pack(str(pack)):
			_packs.append(str(pack))
	_pack_picker = Widgets.option_button(_packs.map(func(p: String) -> String: return "All games" if p == ALL_GAMES else Packs.pack_name(p)))
	_pack_picker.custom_minimum_size = Vector2(Widgets.metric("button_width") * 0.6, Widgets.metric("row_height"))
	_pack_picker.item_selected.connect(func(_i: int) -> void: _on_filter_changed())
	flow.add_child(_pack_picker)
	_search = Widgets.line_edit("", "Search")
	_search.custom_minimum_size = Vector2(Widgets.metric("button_width") * 0.5, Widgets.metric("row_height"))
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t: String) -> void: _on_filter_changed())
	flow.add_child(_search)
	_sort = Widgets.option_button(SORTS.map(func(s: Array) -> String: return "Sort: " + str(s[0])))
	_sort.custom_minimum_size = Vector2(SORT_WIDTH, Widgets.metric("row_height"))
	_sort.item_selected.connect(func(_i: int) -> void: _on_filter_changed())
	flow.add_child(_sort)
	_owned = _make_toggle(flow, "Owned", false)
	_fits = _make_toggle(flow, "Fits slot", false)
	_allowed = _make_toggle(flow, "Allowed", false)


func _make_toggle(parent: Control, text: String, on: bool) -> CheckBox:
	var c := Widgets.check_box(text, on)
	c.toggled.connect(func(_on: bool) -> void: _on_filter_changed())
	parent.add_child(c)
	return c


func _make_side_kinds() -> Array:
	return VEHICLE_KINDS if _state.side == LoadoutLayout.SIDE_VEHICLE else INFANTRY_KINDS


## Greys the categories that hold nothing for the side shown, and moves off one that was open.
func _sync_availability() -> void:
	var kinds := _make_side_kinds()
	var first_open := ""
	for b in _category_row.get_children():
		var id := str(b.get_meta("category"))
		(b as Button).disabled = not _is_open_for(id, kinds)
		if first_open == "" and not (b as Button).disabled:
			first_open = id
	if not _is_open_for(_category, kinds) and first_open != "":
		_category = first_open
		_sync_category_buttons()


func _is_open_for(category_id: String, kinds: Array) -> bool:
	if category_id == StoreCatalog.SUPPLIES:
		return kinds == INFANTRY_KINDS
	for c in StoreCatalog.CATEGORIES:
		if c.id == category_id:
			return (c.kinds as Array).any(func(k: String) -> bool: return kinds.has(k))
	return true


## Showing the vehicle opens the weapons list narrowed to what its hardpoints take.
func _on_side_changed() -> void:
	if _state.side == LoadoutLayout.SIDE_VEHICLE:
		_fits.set_pressed_no_signal(true)
		_category = "weapons" if _is_open_for("weapons", VEHICLE_KINDS) and _has_category("weapons") else _category
		_sync_category_buttons()
	else:
		_fits.set_pressed_no_signal(false)


## Selecting a hardpoint row shows the weapons that fit it.
func _on_selection_changed() -> void:
	if _state.side == LoadoutLayout.SIDE_VEHICLE and _state.selected_row.begins_with("hardpoint:") and _has_category("weapons"):
		_category = "weapons"
		_fits.set_pressed_no_signal(true)
		_sync_category_buttons()


func _has_category(id: String) -> bool:
	return _categories.any(func(c: Dictionary) -> bool: return c.id == id)


func _on_filter_changed() -> void:
	_shown = PAGE_SIZE
	refresh()


# ------------------------------------------------------------------ entries

func _make_filter() -> Dictionary:
	var filter := {"category": _category, "pack": _packs[_pack_picker.selected], "text": _search.text,
		"owned_only": _owned.button_pressed, "allowed_only": _allowed.button_pressed, "sort": SORTS[_sort.selected][1]}
	filter.kinds = _make_side_kinds()
	var row_key := _state.selected_row
	if _fits.button_pressed and FITTING_ROWS.has(row_key.get_slice(":", 0)):
		filter.fits_slot = row_key
		filter.slot = _state.make_slot()
	elif _fits.button_pressed and _state.side == LoadoutLayout.SIDE_VEHICLE and _category == "weapons":
		filter.fits_slot = LoadoutLayout.ROW_ANY_HARDPOINT
		filter.slot = _state.make_slot()
	return filter


## What fits the open slot first, then what does not (each group keeps its sort order).
func _make_fitting_first(entries: Array) -> Array:
	var slot := _state.make_slot()
	var fits := []
	var rest := []
	for e in entries:
		var ok: bool = bool(e.get("stock", false)) or OperatorEquip.make_fit_reason(slot, e, _state.selected_row) == ""
		(fits if ok else rest).append(e)
	return fits + rest


func _make_current_entries() -> Array:
	if MountEntries.is_mount_row(_state.selected_row) and _state.side == LoadoutLayout.SIDE_VEHICLE:
		return MountEntries.make_entries(_state.make_slot(), _state.selected_row)
	if _category == "":
		return []
	return StoreCatalog.make_entries(_make_filter(), _state.ctx, _state.profile)


func _rebuild_rows() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var slot := _state.make_slot()
	for e in _entries.slice(0, _shown):
		_list.add_child(_make_row(e, slot))
	if _entries.is_empty():
		_list.add_child(Widgets.paragraph("Nothing matches these filters.", "DimLabel"))
	elif _entries.size() > _shown:
		_list.add_child(Widgets.small_button("Show more (%d left)" % (_entries.size() - _shown), _show_more))
	_restore_focus.call_deferred()
	rebuilt.emit()


func _make_row(e: Dictionary, slot: CharacterSlot) -> StoreRow:
	var fit_reason := "" if bool(e.get("stock", false)) else OperatorEquip.make_fit_reason(slot, e, _state.selected_row)
	var row := StoreRow.make(e, fit_reason)
	row.pressed.connect(_on_entry_pressed.bind(e))
	row.mouse_entered.connect(_state.apply_preview.bind(e))
	row.focus_entered.connect(_state.apply_preview.bind(e))
	_tooltip.watch(row, OperatorText.make_tooltip.bind(e, fit_reason))
	return row


func _show_more() -> void:
	_shown += PAGE_SIZE
	_rebuild_rows()


func _on_entry_pressed(e: Dictionary) -> void:
	entry_chosen.emit(e)
	_state.request_equip(e)


func _remember_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus is StoreRow and _list.is_ancestor_of(focus):
		_focus_id = str((focus as StoreRow).entry.id)


func _restore_focus() -> void:
	if _focus_id == "" or not is_inside_tree():
		return
	var row := make_row_of(_focus_id)
	_focus_id = ""
	if row != null and row.is_visible_in_tree():
		row.grab_focus()
