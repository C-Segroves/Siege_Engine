class_name StashTab
extends VBoxContainer
## The raid-only third side of Operator Setup: everything the player has for a raid, stash and kit together, grouped by
## kind with counts (docs/design/lobby_loadout_economy.md section 6.1, extraction extras). Nothing is moved here: the kit
## is chosen in the Loadout list's drop-downs, and supplies are bought in the store under "Supplies". The one action is
## Sell, from a row's context menu (StashRow: right click, pad X, the menu key): loot, salvage and spare supplies go
## for their sell price into the credits wallet.

signal rebuilt

const PAGE_SIZE := 40
const BANNER := "Dying loses the kit, the worn paid armour, body and skin, and a called-in vehicle. Re-buy the look for 100 cr. The insured slot keeps one."

var _state: OperatorState
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _shown := PAGE_SIZE


func _init(state: OperatorState) -> void:
	_state = state
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(Widgets.section("STASH"))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)


## The focusable controls (only "Show more" when the list is long).
func make_controls() -> Array[Control]:
	return UiActions.focusables(_rows)


## Rebuilds the view from the extraction profile.
func refresh() -> void:
	var keep := _remember_place()
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	var profile := _state.extraction
	if profile == null:
		return
	_rows.add_child(Widgets.paragraph(BANNER, "BadgeAtRisk"))
	_rows.add_child(Widgets.paragraph(ExtractionScreenText.make_insured_text(profile), "DimLabel"))
	_rows.add_child(Widgets.paragraph("Kit: " + ExtractionScreenText.make_kit_summary(profile), "DimLabel"))
	_add_groups(ExtractionKitEditor.make_overview(profile))
	_restore_place.call_deferred(keep)
	rebuilt.emit()


## Where the view was before a rebuild (a sale rebuilds it): the scroll position and the focused row (its stack and place).
func _remember_place() -> Dictionary:
	var place := {"scroll": _scroll.scroll_vertical, "id": "", "index": -1}
	var focused := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused is StashRow and _rows.is_ancestor_of(focused):
		place.id = (focused as StashRow).stack_id()
		place.index = _stash_rows().find(focused)
	return place


## Back to the scroll position, and the focus on the same stack, else on the row that took its place (a sold-out stack leaves).
func _restore_place(place: Dictionary) -> void:
	if not is_inside_tree():
		return
	_scroll.scroll_vertical = int(place.scroll)
	if int(place.index) < 0:
		return
	var rows := _stash_rows()
	if rows.is_empty():
		return
	var target: StashRow = rows[clampi(int(place.index), 0, rows.size() - 1)]
	for r in rows:
		if r.stack_id() == str(place.id):
			target = r
	target.grab_focus()


func _stash_rows() -> Array:
	return _rows.get_children().filter(func(c: Node) -> bool: return c is StashRow and not c.is_queued_for_deletion())


func _add_groups(groups: Array) -> void:
	if groups.is_empty():
		_rows.add_child(Widgets.label("Nothing yet: buy supplies in the store.", "DimLabel"))
		return
	var shown := 0
	var total := 0
	for g in groups:
		total += (g.entries as Array).size()
	for g in groups:
		if shown >= _shown:
			break
		_rows.add_child(Widgets.section(str(g.label)))
		for e in g.entries:
			if shown >= _shown:
				break
			_rows.add_child(_make_entry_row(e))
			shown += 1
	if total > shown:
		_rows.add_child(Widgets.small_button("Show more (%d left)" % (total - shown), func() -> void:
			_shown += PAGE_SIZE
			refresh()))


func _make_entry_row(e: Dictionary) -> Control:
	var id := str(e.id)
	var units := int(e.stash) + int(e.kit)
	var where := PackedStringArray()
	if int(e.kit) > 0:
		where.append("%d in the kit" % int(e.kit))
	if int(e.stash) > 0:
		where.append("%d in the stash" % int(e.stash))
	return StashRow.make(_state, id, ExtractionItems.make_stack_text(id, units),
		"%s  -  %s" % [", ".join(where), ExtractionScreenText.make_item_detail(id, units)])
