class_name GaragePicker
extends VBoxContainer
## "Your Herc" for a campaign mission, the same in every game: the garage's Hercs (plus the Herc the
## mission issues, when it dictates one) in a picker, the chosen Herc's weapons, and a button that
## opens the Hangar screen. The choice stands in a HangarView. Picking a garage Herc selects it in the
## garage. Used by the campaign briefing and the co-op campaign lobby (a client picks from a copy of
## the host's garage and has no Hangar button).
##   GaragePicker.new(hangar, garage, mission_herc, on_open_hangar)   mission_herc {} = none; the
##                                     mission's Herc is chosen first when there is one; an empty
##                                     Callable() for on_open_hangar leaves the Hangar button out
##   select_garage()                   choose the garage's selected Herc instead
##   changed(entry)                    {vehicle, loadout, name} of the new choice
##   entry() -> Dictionary             the current choice
##   choice_count() / select_choice(i) the choices (garage Hercs, then the mission's Herc)

signal changed(entry: Dictionary)

const MISSION_LABEL := "Mission Herc: %s  (issued for this mission)"
const HANGAR_BUTTON := "Hangar: build, scrap, arm"
const IN_FACTORY := "  -  in the factory (%d)"

var _garage: Garage
var _mission_herc: Dictionary
var _hangar: HangarView
var _options: OptionButton
var _weapons: Label


func _init(hangar: HangarView, garage: Garage, mission_herc: Dictionary, on_open_hangar: Callable) -> void:
	_hangar = hangar
	_garage = garage
	_mission_herc = mission_herc
	_options = Widgets.option_button(_make_labels())
	for i in _garage.vehicles.size():
		_options.set_item_disabled(i, not Garage.is_ready(_garage.vehicles[i]))   # still in the factory
	_options.select(_garage.vehicles.size() if not _mission_herc.is_empty() else _garage.selected)
	_options.item_selected.connect(_on_picked)
	add_child(OptionRow.new("Your Herc", _options))
	_weapons = Widgets.paragraph("", "DimLabel")
	add_child(_weapons)
	if on_open_hangar.is_valid():
		add_child(Widgets.button(HANGAR_BUTTON, on_open_hangar))
	_show_choice()


## Number of choices (the garage's Hercs, plus the mission's Herc when it issues one).
func choice_count() -> int:
	return _options.item_count


## Picks choice `i` as the player would.
func select_choice(i: int) -> void:
	_options.select(i)
	_on_picked(i)


func select_garage() -> void:
	_options.select(_garage.selected)
	_show_choice()


func entry() -> Dictionary:
	if _options.selected < _garage.vehicles.size():
		return _garage.make_battle_entry()
	var vid := str(_mission_herc.vehicle)
	return {"vehicle": vid, "loadout": (_mission_herc.get("loadout", []) as Array).duplicate(),
		"name": str(Packs.vehicle(vid).get("name", vid))}


## "Name  -  Type  [Game]  -  2/4 armed  -  84 %": one owned Herc (also the Hangar screen's list); a
## damaged Herc shows its condition, one being built when it will be ready.
static func make_entry_label(e: Dictionary) -> String:
	var v := Packs.vehicle(str(e.vehicle))
	var label := "%s  [%s]  -  %d/%d armed" % [make_entry_name(e), Packs.pack_name(str(v.get("pack", ""))),
		Garage.make_armed_count(e), (e.loadout as Array).size()]
	if not Garage.is_ready(e):
		return label + IN_FACTORY % int(e.build_left)
	var condition: Array = e.get("condition", [])
	return label + ("  -  %d %%" % HercCondition.make_percent(str(e.vehicle), condition) if not HercCondition.is_pristine(condition) else "")


## "Lucky  -  Raptor", or just "Raptor" while the Herc carries its type's name.
static func make_entry_name(e: Dictionary) -> String:
	var type_name := str(Packs.vehicle(str(e.vehicle)).get("name", e.vehicle))
	return type_name if str(e.name) == type_name else "%s  -  %s" % [e.name, type_name]


## "LAS100, ATC20" or "no weapons".
static func make_weapons_text(loadout: Array) -> String:
	var names: PackedStringArray = []
	for wid in loadout:
		if str(wid) != Garage.EMPTY:
			var w := Packs.weapon(str(wid))
			names.append(str(w.get("display_name", w.get("name", wid))))
	return "Weapons: " + (", ".join(names) if not names.is_empty() else "none")


func _make_labels() -> Array:
	var labels: Array = _garage.vehicles.map(make_entry_label)
	if not _mission_herc.is_empty():
		var vid := str(_mission_herc.vehicle)
		labels.append(MISSION_LABEL % Packs.vehicle(vid).get("name", vid))
	return labels


func _on_picked(i: int) -> void:
	if i < _garage.vehicles.size():
		_garage.apply_select(i)
	_show_choice()


func _show_choice() -> void:
	var e := entry()
	_weapons.text = make_weapons_text(e.get("loadout", []))
	if _hangar != null and not e.is_empty():
		_hangar.show_herc(str(e.vehicle), e.loadout)
		_hangar.set_caption(VehiclePicker.make_caption(Packs.vehicle(str(e.vehicle))))
	changed.emit(e)
