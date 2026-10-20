class_name LookPanel
extends VBoxContainer
## The look pickers of Operator Setup (right bottom): the armour (model class), the body (e.g. a Bioderm), the armour skin,
## the preferred vehicle and its skin. Parts that cost credits show their price and are bought on choosing them; parts
## this mode forbids are greyed. One drop-down per row, so mouse, keyboard and gamepad all work.

signal rebuilt

const ROW_ARMOUR := "armour"
const ROW_BODY := "body"
const ROW_SKIN := "skin"
const ROW_VEHICLE := "vehicle"
const ROW_HERC_SKIN := "herc_skin"
const COLUMNS := 2
const LABEL_WIDTH := 72
const LABELS := {ROW_ARMOUR: "Armour", ROW_BODY: "Body", ROW_SKIN: "Skin", ROW_VEHICLE: "Vehicle", ROW_HERC_SKIN: "Veh. skin"}

var _state: OperatorState
var _rows: GridContainer
var _pickers := {}   # row key -> OptionButton
var _choices := {}   # row key -> [{label, entry}] in item order; an empty entry is the free default
var _focus_key := ""


func _init(state: OperatorState) -> void:
	_state = state
	add_child(Widgets.section("LOOK"))
	_rows = GridContainer.new()
	_rows.columns = COLUMNS
	add_child(_rows)


func make_pickers() -> Array[Control]:
	var out: Array[Control] = []
	for key in LABELS:
		if _pickers.has(key):
			out.append(_pickers[key])
	return out


func get_picker(key: String) -> OptionButton:
	return _pickers.get(key)


## Rebuilds every picker from the open slot (a choice may change what the others offer).
func refresh() -> void:
	_remember_focus()
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	_pickers.clear()
	_choices.clear()
	var slot := _state.make_slot()
	_add_picker(ROW_ARMOUR, _make_armour_choices(), slot.armor)
	_add_picker(ROW_BODY, _make_body_choices(slot), slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor))
	_add_picker(ROW_SKIN, _make_skin_choices(slot), slot.skin)
	_add_picker(ROW_VEHICLE, _make_vehicle_choices(), slot.vehicle)
	_add_picker(ROW_HERC_SKIN, _make_herc_skin_choices(slot), slot.herc_skin)
	_restore_focus.call_deferred()
	rebuilt.emit()


# ------------------------------------------------------------------ choices

## [{label, entry, current}]: the first/default rows have an empty entry.
func _make_armour_choices() -> Array:
	var filter := {"category": "armour", "pack": _state.ctx.pack}
	var show_game := _state.ctx.pack == "" and CatalogBridge.make_infantry_packs().size() > 1
	return StoreCatalog.make_entries(filter, _state.ctx, _state.profile).map(func(e: Dictionary) -> Dictionary:
		var game := "  (%s)" % Packs.pack_name(str(e.pack)) if show_game else ""
		return {"label": str(e.name) + game, "entry": e, "ref": UnlockId.ref_of(str(e.id))})


func _make_body_choices(slot: CharacterSlot) -> Array:
	var out := []
	var bodies := CatalogBridge.make_bodies(slot.armor)
	if bodies.size() <= 1:
		return out
	for b in bodies:
		out.append({"label": str(b.label), "entry": StoreCatalog.make_entry(UnlockId.make("body", str(b.id)), _state.ctx, _state.profile), "ref": str(b.id)})
	return out


func _make_skin_choices(slot: CharacterSlot) -> Array:
	var shown := slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
	var skins := CatalogBridge.make_skins(shown)
	if skins.size() <= 1:
		return []
	var out := []
	for s in skins:
		var entry := {} if str(s.id) == "" else StoreCatalog.make_entry(UnlockId.make("skin", UnlockId.make_skin_ref(shown, str(s.id))), _state.ctx, _state.profile)
		out.append({"label": str(s.label), "entry": entry, "ref": str(s.id)})
	return out


func _make_vehicle_choices() -> Array:
	return StoreCatalog.make_entries({"category": "vehicles"}, _state.ctx, _state.profile).map(func(e: Dictionary) -> Dictionary:
		return {"label": "%s  (%s)" % [e.name, Packs.pack_name(str(e.pack))], "entry": e, "ref": UnlockId.ref_of(str(e.id))})


func _make_herc_skin_choices(slot: CharacterSlot) -> Array:
	var skins := SkinCatalog.make_vehicle_skin_choices(slot.vehicle)
	if slot.vehicle == "" or skins.size() <= 1:
		return []
	var shape := SkinCatalog.make_vehicle_shape(slot.vehicle)
	var out := []
	for s in skins:
		var entry := {} if str(s.id) == "" else StoreCatalog.make_entry(UnlockId.make("herc_skin", UnlockId.make_skin_ref(shape, str(s.id))), _state.ctx, _state.profile)
		out.append({"label": str(s.label), "entry": entry, "ref": str(s.id)})
	return out


# ------------------------------------------------------------------ pickers

func _add_picker(key: String, choices: Array, current_ref: String) -> void:
	if choices.is_empty():
		return
	var picker := Widgets.option_button([])
	var selected := 0
	for i in choices.size():
		picker.add_item(_make_item_text(choices[i]))
		var entry: Dictionary = choices[i].entry
		picker.set_item_disabled(i, str(entry.get("state", "")) == StoreCatalog.STATE_NOT_ALLOWED)
		if not entry.is_empty() and str(entry.reason) != "":
			picker.set_item_tooltip(i, str(entry.reason))
		if str(choices[i].ref) == current_ref:
			selected = i
	picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	picker.select(selected)
	picker.set_meta("row_key", key)
	picker.item_selected.connect(_on_chosen.bind(key))
	_choices[key] = choices
	_pickers[key] = picker
	var row := OptionRow.new(str(LABELS[key]), picker)
	row.label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_child(row)


func _make_item_text(choice: Dictionary) -> String:
	var entry: Dictionary = choice.entry
	var mark := ""
	match str(entry.get("state", "")):
		StoreCatalog.STATE_FOR_SALE:
			mark = "  [%s]" % EconomyRules.make_money_text(int(entry.price))
		StoreCatalog.STATE_LOST:
			mark = "  [buy back %s]" % EconomyRules.make_money_text(int(entry.price))
		StoreCatalog.STATE_NOT_ALLOWED:
			mark = "  [not allowed]"
	return str(choice.label) + mark


func _on_chosen(index: int, key: String) -> void:
	var choice: Dictionary = (_choices[key] as Array)[index]
	var entry: Dictionary = choice.entry
	if entry.is_empty():
		_state.apply_default_look(key)
	else:
		_state.request_equip(entry)
	_sync_selection(key)


## Shows the real choice again when the pick was refused, or is waiting for a purchase to be confirmed.
func _sync_selection(key: String) -> void:
	if not _pickers.has(key) or not is_instance_valid(_pickers[key]):
		return
	var current := _make_current_ref(key)
	var choices: Array = _choices[key]
	for i in choices.size():
		if str(choices[i].ref) == current:
			(_pickers[key] as OptionButton).select(i)
			return


func _make_current_ref(key: String) -> String:
	var slot := _state.make_slot()
	match key:
		ROW_ARMOUR:
			return slot.armor
		ROW_BODY:
			return slot.body if slot.body != "" else PlayerProfile.make_default_body(slot.armor)
		ROW_SKIN:
			return slot.skin
		ROW_VEHICLE:
			return slot.vehicle
	return slot.herc_skin


func _remember_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus is OptionButton and _rows.is_ancestor_of(focus):
		_focus_key = str(focus.get_meta("row_key", ""))


func _restore_focus() -> void:
	if _focus_key == "" or not is_inside_tree():
		return
	var picker: OptionButton = _pickers.get(_focus_key)
	_focus_key = ""
	if picker != null and picker.is_visible_in_tree():
		picker.grab_focus()
