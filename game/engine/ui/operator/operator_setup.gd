class_name OperatorSetup
extends Node
## Operator Setup: the one loadout screen of every mode (docs/design/lobby_loadout_economy.md section 6), a full-screen
## ModalSheet over the lobby (or over any host Control, standalone).
##   var setup := OperatorSetup.open(host, LoadoutContext.make_for(settings), slot_index)
##   setup.closed.connect(func(changed: bool) -> void: ...)     # the lobby announces the slot again when `changed`
## Top: the three character slots as tabs and the credits. Left: the loadout rows of the open slot (infantry or vehicle;
## the kit and stash in a raid). Centre: the model, the card of the part last added or hovered, the side switch. Right:
## the store and the look pickers. Under 900 px (Siege/narrow_width) the three columns become three panes with tabs.
## Every change is saved at once. Keys and pad: ui_* move, ui_accept equips / buys, menu_secondary (right click, X)
## removes, menu_tab_prev/next (LB/RB) slots or store categories, menu_zone_prev/next (LT/RT) loadout / store / look,
## menu_switch_kind (View) infantry / vehicle, menu_info (Y) pins the detail plate, menu_back (B) closes.

signal closed(changed: bool)

const TITLE := "OPERATOR SETUP"
const ZONE_LOADOUT := 0
const ZONE_STORE := 1
const ZONE_LOOK := 2
const PANE_LABELS := ["Loadout", "Store", "Look"]
const LEFT_WIDTH_RATIO := 3.0
const CENTRE_WIDTH_RATIO := 3.2
const RIGHT_WIDTH_RATIO := 4.4
const LOOK_MIN_HEIGHT := 150
const SHEET_STATUS_DEFAULT := "Remove: right click / X"
const RAID_STATUS := "A raid risks your paid look and kit. Re-buy: 100 cr."

var sheet: ModalSheet
var state: OperatorState
var tabs: SlotTabs
var list: LoadoutList
var preview: ArmourPreview
var store: StorePanel
var look: LookPanel
var stash: StashTab
var tooltip: ItemTooltip
var credits: CreditsBadge
var is_narrow := false
var pane := ZONE_LOADOUT

var _left: VBoxContainer
var _wide_root: HBoxContainer
var _right: VBoxContainer
var _narrow_root: VBoxContainer
var _pane_tabs: HBoxContainer
var _pane_loadout: VBoxContainer
var _layout_holder: VBoxContainer
var _refresh_queued := false
var _link_queued := false


## Opens Operator Setup over `parent` for the profile of the local pilot (or `p_profile`), on slot `slot_index`
## (-1 = the active slot). `with_3d` false leaves the hangar view out (tests that do not render).
static func open(parent: Control, ctx: LoadoutContext, slot_index := -1, p_profile: OperatorProfile = null, with_3d := true) -> OperatorSetup:
	var setup := OperatorSetup.new()
	setup._build(parent, ctx, slot_index, p_profile, with_3d)
	return setup


func close() -> void:
	sheet.close()


## The focusable controls of zone ZONE_LOADOUT / ZONE_STORE / ZONE_LOOK, top to bottom.
func make_zone_controls(zone: int) -> Array[Control]:
	var out: Array[Control] = []
	match zone:
		ZONE_LOADOUT:
			out = stash.make_controls() if state.side == OperatorState.SIDE_STASH else list.make_rows()
			out.append_array(preview.make_controls())
		ZONE_STORE:
			out = store.make_controls()
		ZONE_LOOK:
			out = look.make_pickers()
	return out


## Jumps focus to zone `zone` (switching the pane in the narrow layout).
func apply_zone(zone: int) -> void:
	if is_narrow:
		_apply_pane(zone)
	var controls := make_zone_controls(zone)
	if not controls.is_empty():
		controls[0].grab_focus()


# ------------------------------------------------------------------ building

func _build(parent: Control, ctx: LoadoutContext, slot_index: int, p_profile: OperatorProfile, with_3d: bool) -> void:
	var profile := p_profile if p_profile != null else OperatorProfile.load_for(Net.player_name)
	if slot_index >= 0:
		profile.apply_select_slot(slot_index)
	state = OperatorState.make_for(profile, ctx)
	sheet = ModalSheet.open(parent, TITLE)
	sheet.add_child(self)
	_build_parts(with_3d)
	_build_chrome()
	_connect_state()
	var width := parent.size.x if parent.size.x > 0.0 else parent.get_viewport_rect().size.x
	_apply_layout(width < Widgets.metric("narrow_width"))
	_refresh_all()
	sheet.resized.connect(_on_sheet_resized)
	sheet.closed.connect(_on_sheet_closed)
	apply_zone.call_deferred(ZONE_LOADOUT)


func _build_parts(with_3d: bool) -> void:
	tooltip = ItemTooltip.new()
	sheet.add_child(tooltip)
	tabs = SlotTabs.new(state)
	list = LoadoutList.new(state, tooltip)
	stash = StashTab.new(state)
	preview = ArmourPreview.new(state, with_3d)
	store = StorePanel.new(state, tooltip)
	look = LookPanel.new(state)
	_left = VBoxContainer.new()
	_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left.add_child(list)
	_left.add_child(stash)


func _build_chrome() -> void:
	credits = CreditsBadge.new(state.profile.credits)
	sheet.add_title_widget(credits)
	sheet.set_back("Back")
	sheet.set_primary("Done", sheet.close)
	sheet.set_status(RAID_STATUS if state.ctx.loss_on_death else SHEET_STATUS_DEFAULT)
	sheet.body.add_child(tabs)
	_layout_holder = VBoxContainer.new()
	_layout_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sheet.body.add_child(_layout_holder)
	_wide_root = HBoxContainer.new()
	_wide_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right = VBoxContainer.new()
	_narrow_root = VBoxContainer.new()
	_narrow_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pane_loadout = VBoxContainer.new()
	_pane_loadout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_pane_tabs()


func _build_pane_tabs() -> void:
	_pane_tabs = HBoxContainer.new()
	var group := ButtonGroup.new()
	for i in PANE_LABELS.size():
		var b := Button.new()
		b.text = PANE_LABELS[i]
		b.theme_type_variation = "TabButton"
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_apply_pane.bind(i))
		_pane_tabs.add_child(b)


func _connect_state() -> void:
	state.changed.connect(_queue_refresh)
	state.selection_changed.connect(_queue_refresh)
	state.side_changed.connect(_queue_refresh)
	state.preview_changed.connect(preview.show_entry)
	state.status_changed.connect(sheet.set_status)
	state.confirm_requested.connect(_on_confirm_requested)
	preview.side_requested.connect(state.apply_side)
	list.row_chosen.connect(func(_key: String) -> void: apply_zone(ZONE_STORE))
	for panel in [list, stash, store, look]:
		panel.rebuilt.connect(_queue_link)


# ------------------------------------------------------------------ layout

func _on_sheet_resized() -> void:
	var narrow := sheet.size.x < Widgets.metric("narrow_width")
	if narrow != is_narrow and sheet.size.x > 0.0:
		_apply_layout(narrow)


## Wide: three columns. Narrow: tabs over one pane at a time. Panels are moved, never rebuilt.
func _apply_layout(narrow: bool) -> void:
	is_narrow = narrow
	for panel in [preview, _left, store, look]:
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
	for root in [_wide_root, _narrow_root]:
		if root.get_parent() != null:
			root.get_parent().remove_child(root)
	if narrow:
		_arrange_narrow()
	else:
		_arrange_wide()
	preview.set_compact(narrow)
	_queue_link()


func _arrange_wide() -> void:
	_layout_holder.add_child(_wide_root)
	_wide_root.add_child(_left)
	_wide_root.add_child(preview)
	_wide_root.add_child(_right)
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left.size_flags_stretch_ratio = LEFT_WIDTH_RATIO
	preview.size_flags_stretch_ratio = CENTRE_WIDTH_RATIO
	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right.size_flags_stretch_ratio = RIGHT_WIDTH_RATIO
	_right.add_child(store)
	_right.add_child(look)
	look.custom_minimum_size = Vector2(0, LOOK_MIN_HEIGHT)
	for panel in [store, look, _left]:
		panel.visible = true


func _arrange_narrow() -> void:
	_layout_holder.add_child(_narrow_root)
	_narrow_root.add_child(_pane_tabs)
	_narrow_root.add_child(_pane_loadout)
	_pane_loadout.add_child(preview)
	_pane_loadout.add_child(_left)
	_narrow_root.add_child(store)
	_narrow_root.add_child(look)
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	look.custom_minimum_size = Vector2.ZERO
	_apply_pane(pane)


## Narrow layout: shows pane `i` (0 loadout, 1 store, 2 look).
func _apply_pane(i: int) -> void:
	pane = clampi(i, 0, PANE_LABELS.size() - 1)
	if not is_narrow:
		return
	_pane_loadout.visible = pane == ZONE_LOADOUT
	store.visible = pane == ZONE_STORE
	look.visible = pane == ZONE_LOOK
	for j in _pane_tabs.get_child_count():
		(_pane_tabs.get_child(j) as Button).set_pressed_no_signal(j == pane)
	_queue_link()


# ------------------------------------------------------------------ refreshing

func _queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		_refresh_all.call_deferred()


## Redraws every panel from the profile (also callable directly).
func _refresh_all() -> void:
	_refresh_queued = false
	if not is_instance_valid(sheet) or not sheet.is_open:
		return
	credits.set_credits(state.profile.credits)
	tabs.refresh()
	var on_stash := state.side == OperatorState.SIDE_STASH
	list.visible = not on_stash
	stash.visible = on_stash
	if on_stash:
		stash.refresh()
	else:
		list.refresh()
	preview.refresh()
	store.refresh()
	look.refresh()


# ------------------------------------------------------------------ focus

func _queue_link() -> void:
	if not _link_queued:
		_link_queued = true
		_apply_links.call_deferred()


## Wires focus: up/down inside a zone, Tab and Shift+Tab (focus_next / previous) between zones, left/right between the
## columns, the slot tabs above everything and the footer below.
func _apply_links() -> void:
	_link_queued = false
	if not is_instance_valid(sheet) or not sheet.is_open:
		return
	var zones: Array = []
	for z in 3:
		zones.append(_make_chain(z))
	var chains: Array = zones.filter(func(c: Array) -> bool: return not c.is_empty())
	for chain in chains:
		UiActions.link_vertical(chain)
	_link_zone_jumps(chains)
	_link_columns(zones)
	_link_edges(chains)


func _link_zone_jumps(chains: Array) -> void:
	for i in chains.size():
		var next_first: Control = chains[(i + 1) % chains.size()][0]
		var prev_first: Control = chains[(i - 1 + chains.size()) % chains.size()][0]
		for c in chains[i]:
			c.focus_next = c.get_path_to(next_first)
			c.focus_previous = c.get_path_to(prev_first)


func _link_columns(zones: Array) -> void:
	if is_narrow:
		return
	for z in zones.size():
		var neighbour: Array = zones[ZONE_STORE] if z == ZONE_LOADOUT else zones[ZONE_LOADOUT]
		if neighbour.is_empty():
			continue
		for c in zones[z]:
			if not (c is LineEdit or c is LoadoutRow and (c as LoadoutRow).is_adjustable()):
				var side := "focus_neighbor_right" if z == ZONE_LOADOUT else "focus_neighbor_left"
				c.set(side, c.get_path_to(neighbour[0]))


func _link_edges(chains: Array) -> void:
	var slot_tabs := tabs.make_tabs()
	UiActions.link_horizontal(slot_tabs)
	var active := tabs.find_active_tab()
	for chain in chains:
		(chain[0] as Control).focus_neighbor_top = (chain[0] as Control).get_path_to(active) if active != null else NodePath()
		(chain[chain.size() - 1] as Control).focus_neighbor_bottom = (chain[chain.size() - 1] as Control).get_path_to(sheet.primary_button)
	if not chains.is_empty():
		for t in slot_tabs:
			t.focus_neighbor_bottom = t.get_path_to(chains[0][0])
			t.focus_next = t.get_path_to(chains[0][0])
		sheet.primary_button.focus_neighbor_top = sheet.primary_button.get_path_to(chains[0][0])
		sheet.back_button.focus_neighbor_top = sheet.back_button.get_path_to(chains[0][0])


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if not sheet.is_open or _is_covered():
		return
	if UiActions.is_pressed(event, "menu_tab_next"):
		_step_tab(1)
	elif UiActions.is_pressed(event, "menu_tab_prev"):
		_step_tab(-1)
	elif UiActions.is_pressed(event, "menu_zone_next"):
		apply_zone((_find_focus_zone() + 1) % 3)
	elif UiActions.is_pressed(event, "menu_zone_prev"):
		apply_zone((_find_focus_zone() + 2) % 3)
	elif UiActions.is_pressed(event, "menu_switch_kind"):
		_step_side()
	else:
		return
	get_viewport().set_input_as_handled()


## A dialog opened over the sheet (a purchase question) takes every key.
func _is_covered() -> bool:
	var parent := sheet.get_parent()
	return parent != null and parent.get_child(parent.get_child_count() - 1) != sheet


## LB / RB: the store category while the store has the focus, else the slot.
func _step_tab(direction: int) -> void:
	var focus := sheet.get_viewport().gui_get_focus_owner()
	if focus != null and store.is_ancestor_of(focus):
		store.apply_step_category(direction)
	elif not tabs.is_editing():
		tabs.apply_step(direction)


func _step_side() -> void:
	var sides := state.make_sides()
	state.apply_side(sides[(sides.find(state.side) + 1) % sides.size()])


func _find_focus_zone() -> int:
	var focus := sheet.get_viewport().gui_get_focus_owner()
	if focus == null:
		return pane if is_narrow else ZONE_LOADOUT
	for z in 3:
		if make_zone_controls(z).has(focus):
			return z
	return pane if is_narrow else ZONE_LOADOUT


# ------------------------------------------------------------------ dialogs and closing

func _on_confirm_requested(message: String, confirm_text: String, on_confirm: Callable) -> void:
	ConfirmDialog.ask(sheet.get_parent(), message, on_confirm, confirm_text)


func _on_sheet_closed() -> void:
	state.profile.save()
	closed.emit(state.is_dirty)


## The focus chain of zone `z` as shown now: in the narrow layout only the open pane (after its pane tabs).
func _make_chain(z: int) -> Array[Control]:
	var out: Array[Control] = []
	if is_narrow and z != pane:
		return out
	if is_narrow:
		for t in _pane_tabs.get_children():
			out.append(t)
	out.append_array(make_zone_controls(z))
	return out
