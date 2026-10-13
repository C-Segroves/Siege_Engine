class_name HercSelector
extends VBoxContainer
## Herc choice + armory driving a 3D hangar: a VehiclePicker over a LoadoutEditor; the hangar shows
## the picked Herc with its live loadout and highlights the hardpoint being edited. Used by every
## screen where the player chooses a Herc (armory, lobby, pre-mission briefing).
##   HercSelector.new(hangar)            hangar may be null (no 3D view)
##   setup(vehicle_id, initial_loadout, availability)  `initial_loadout` applies while that first
##                                       Herc is picked; `availability` = CampaignAvailability context
##                                       limiting Hercs and weapons ({} = everything)
##   vehicle_changed(id) / loadout_changed(loadout) / skin_changed(skin id)
##   A Herc with skins (SkinCatalog: Starsiege) gets a Skin row; the choice is saved per Herc (PlayerProfile).
##   vehicle_id() / loadout()            current choice
##   select_vehicle(id)                  pick another Herc (as if the player did)

signal vehicle_changed(vehicle_id: String)
signal loadout_changed(loadout: Array)
signal skin_changed(skin_id: String)

var picker: VehiclePicker
var editor: LoadoutEditor
var _skin_box: VBoxContainer
var _hangar: HangarView
var _first_vehicle := ""
var _first_loadout: Array = []
var _availability := {}


func _init(hangar: HangarView = null, label_text := "Your Herc") -> void:
	_hangar = hangar
	picker = VehiclePicker.new(label_text)
	add_child(picker)
	_skin_box = VBoxContainer.new()
	add_child(_skin_box)
	editor = LoadoutEditor.new()
	add_child(editor)
	picker.vehicle_selected.connect(_on_vehicle_selected)
	editor.changed.connect(_on_loadout_edited)
	if _hangar != null:
		editor.hardpoint_focused.connect(_hangar.highlight_hardpoint)


func setup(p_vehicle_id: String, initial_loadout: Array = [], availability := {}) -> void:
	_availability = availability
	if CampaignAvailability.is_restricted(availability):
		picker.set_availability(availability)
	picker.select_vehicle(p_vehicle_id)
	_first_vehicle = picker.selected_id()
	_first_loadout = initial_loadout.duplicate()
	_rebuild_skin_row()
	_rebuild_armory()


func vehicle_id() -> String:
	return picker.selected_id()


func loadout() -> Array:
	return editor.loadout.duplicate()


func select_vehicle(p_vehicle_id: String) -> void:
	picker.select_vehicle(p_vehicle_id)


## The skin chosen for the current Herc ("" = default).
func skin() -> String:
	return PlayerProfile.load_herc_skin(vehicle_id())


func _on_vehicle_selected(_id: String) -> void:
	_rebuild_skin_row()
	_rebuild_armory()
	vehicle_changed.emit(vehicle_id())


func _rebuild_armory() -> void:
	var id := vehicle_id()
	editor.setup(id, _first_loadout if id == _first_vehicle else [], _availability)
	_on_loadout_edited(editor.loadout)


func _on_loadout_edited(lo: Array) -> void:
	loadout_changed.emit(lo.duplicate())
	_show_in_hangar()


func _rebuild_skin_row() -> void:
	for c in _skin_box.get_children():
		_skin_box.remove_child(c)
		c.queue_free()
	var choices := SkinCatalog.make_vehicle_skin_choices(vehicle_id())
	if choices.size() < 2:
		return
	var index := choices.map(func(c: Dictionary) -> String: return str(c.id)).find(skin())
	var o := Widgets.option_button(choices.map(func(c: Dictionary) -> String: return str(c.label)), maxi(index, 0))
	o.item_selected.connect(func(i: int) -> void: _on_skin_chosen(str(choices[i].id)))
	_skin_box.add_child(OptionRow.new("Skin", o))


func _on_skin_chosen(skin_id: String) -> void:
	PlayerProfile.apply_herc_skin(vehicle_id(), skin_id)
	if _hangar != null:
		_hangar.apply_skin(skin_id)
	skin_changed.emit(skin_id)


func _show_in_hangar() -> void:
	if _hangar == null or vehicle_id() == "":
		return
	_hangar.apply_skin(skin())
	_hangar.show_herc(vehicle_id(), editor.loadout)
	var reason := picker.reason_of(vehicle_id())
	_hangar.set_caption(VehiclePicker.make_caption(Packs.vehicle(vehicle_id())) + ("  -  %s" % reason if reason != "" else ""))
