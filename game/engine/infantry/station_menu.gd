class_name StationMenu
extends PanelContainer
## The menu a Tribes station opens for a soldier standing on it (docs/formats/tribes_infantry.md section 4):
##   inventory station: armour, weapons, grenade type and backpack (Tribes 1 buy menu / Tribes 2 inventory hud),
##   free (no economy yet); only packs whose effect the remake models are offered (InfantryGear.packs_of);
##   vehicle station: which vehicle to put on the pad.
## A modal panel built from the shared widgets (OptionRow, Widgets.button, theme variations ModalShade /
## ModalPanel): keyboard and gamepad move the focus; menu_back or Cancel closes it; Buy is bottom-right.
## The battle keeps running while it is open, as in the originals.

signal bought(choice: Dictionary)
signal closed

const LAYER := 80
const NO_WEAPON := "(none)"

var _rows: VBoxContainer
var _armor_picker: OptionButton
var _weapon_pickers: Array[OptionButton] = []
var _vehicle_picker: OptionButton
var _grenade_picker: OptionButton
var _pack_picker: OptionButton
var _grenades: Array = []
var _packs: Array = []
var _armors: Array = []
var _vehicles: Array = []
var _buy_button: Button


## The inventory menu for a soldier in `armor_id` carrying `loadout` and `kit`, offering the armours of `armors`.
static func open_inventory(parent: Node, armors: Array, armor_id: String, loadout: Array, kit: InfantryKit = null) -> StationMenu:
	var m := StationMenu.new()
	m._armors = armors
	m._build("INVENTORY STATION")
	m._build_armor_row(armor_id)
	m._build_weapon_rows(loadout)
	m._build_gear_rows(kit if kit else InfantryKit.new())
	_open(parent, m)
	return m


## The vehicle station menu offering `vehicles` (catalog records).
static func open_vehicles(parent: Node, vehicles: Array) -> StationMenu:
	var m := StationMenu.new()
	m._vehicles = vehicles
	m._build("VEHICLE STATION")
	m._vehicle_picker = Widgets.option_button(vehicles.map(func(v: Dictionary) -> String: return str(v.get("name", v.id))))
	m._rows.add_child(OptionRow.new("Vehicle", m._vehicle_picker))
	_open(parent, m)
	return m


static func _open(parent: Node, m: StationMenu) -> void:
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	layer.name = "StationMenuLayer"
	layer.add_child(m)
	parent.add_child(layer)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	m._link_focus()


func _build(title: String) -> void:
	theme_type_variation = "ModalShade"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "ModalPanel"
	center.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	box.add_child(Widgets.label(title, "HeaderLabel"))
	box.add_child(Widgets.label("Free in this match (no team energy yet).", "DimLabel"))
	_rows = VBoxContainer.new()
	box.add_child(_rows)
	_buy_button = Widgets.button("Buy", _buy, Widgets.PRIMARY)
	var buttons := Widgets.row([Widgets.button("Cancel", close), _buy_button])
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)


func _build_armor_row(armor_id: String) -> void:
	var names := _armors.map(func(a: Dictionary) -> String: return str(a.name))
	var current := maxi(0, _armors.find(InfantryCatalog.armor(armor_id)))
	_armor_picker = Widgets.option_button(names, current)
	_armor_picker.item_selected.connect(func(_i: int) -> void: _rebuild_weapon_rows())
	_rows.add_child(OptionRow.new("Armor", _armor_picker))


## One weapon row per slot the chosen armour has ($MaxWeapons), preset from `loadout`.
func _build_weapon_rows(loadout: Array) -> void:
	var armor := selected_armor()
	var allowed: Array = armor.get("weapons", [])
	var items := [NO_WEAPON]
	items.append_array(allowed.map(func(id: String) -> String: return str(Packs.weapon(id).get("display_name", id))))
	_weapon_pickers.clear()
	for slot in int(armor.get("max_weapons", 3)):
		var wid: String = str(loadout[slot]) if slot < loadout.size() else ""
		var picker := Widgets.option_button(items, allowed.find(wid) + 1)
		_weapon_pickers.append(picker)
		_rows.add_child(OptionRow.new("Weapon %d" % (slot + 1), picker))


## The grenade row (one type: T2 maxGrenades 1) and the backpack row of the chosen armour, preset from `kit`.
func _build_gear_rows(kit: InfantryKit) -> void:
	var armor := selected_armor()
	_grenades = InfantryGear.grenades_of(armor)
	_packs = InfantryGear.packs_of(armor)
	_grenade_picker = _make_item_picker(_grenades, kit.grenade_id, InfantryGear.item)
	_rows.add_child(OptionRow.new("Grenades", _grenade_picker))
	_pack_picker = _make_item_picker(_packs, kit.pack_id, InfantryGear.pack)
	_rows.add_child(OptionRow.new("Pack", _pack_picker))


static func _make_item_picker(ids: Array, current: String, record: Callable) -> OptionButton:
	var items := [NO_WEAPON]
	items.append_array(ids.map(func(id: String) -> String: return str(record.call(id).get("name", id))))
	return Widgets.option_button(items, ids.find(current) + 1)


func _rebuild_weapon_rows() -> void:
	var keep := make_loadout()
	var kit := InfantryKit.new()
	kit.grenade_id = selected_grenade()
	kit.pack_id = selected_pack()
	for r in _rows.get_children():
		if r is OptionRow and ((r as OptionRow).control in _weapon_pickers or (r as OptionRow).control in [_grenade_picker, _pack_picker]):
			r.queue_free()
			_rows.remove_child(r)
	_build_weapon_rows(keep.filter(func(id: String) -> bool: return (selected_armor().get("weapons", []) as Array).has(id)))
	_build_gear_rows(kit)
	_link_focus()


## The chosen grenade type ("" = none).
func selected_grenade() -> String:
	return _grenades[_grenade_picker.selected - 1] if _grenade_picker and _grenade_picker.selected > 0 else ""


## The chosen backpack ("" = none).
func selected_pack() -> String:
	return _packs[_pack_picker.selected - 1] if _pack_picker and _pack_picker.selected > 0 else ""


func selected_armor() -> Dictionary:
	return _armors[_armor_picker.selected] if _armor_picker and not _armors.is_empty() else {}


## Weapon ids of the weapon rows (empty rows left out).
func make_loadout() -> Array:
	var allowed: Array = selected_armor().get("weapons", [])
	var out := []
	for p in _weapon_pickers:
		if p.selected > 0 and p.selected - 1 < allowed.size():
			out.append(allowed[p.selected - 1])
	return out


func _buy() -> void:
	var choice := {}
	if _armor_picker:
		choice = {"armor": str(selected_armor().get("id", "")), "loadout": make_loadout(),
			"grenade": selected_grenade(), "pack": selected_pack()}
	elif _vehicle_picker and not _vehicles.is_empty():
		choice = {"vehicle": str(_vehicles[_vehicle_picker.selected].id)}
	bought.emit(choice)
	close()


func close() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()
	get_parent().queue_free()


func _link_focus() -> void:
	var chain := UiActions.focusables(self)
	UiActions.link_vertical(chain)
	if not chain.is_empty():
		chain[0].grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_back(event):
		get_viewport().set_input_as_handled()
		close()
