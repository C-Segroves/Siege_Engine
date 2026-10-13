class_name PilotPicker
extends VBoxContainer
## The player's soldier (Tribes armour) choices, saved in PlayerProfile: the infantry game (only when both Tribes
## games are installed and the screen lets the player choose it), the starting armour, the body (Tribes 2: Human or
## Bioderm) and the skin (rows with a single choice are left out). Empty when no infantry game is installed.
##   PilotPicker.new(pack, choose_game)   pack: the match's infantry game ("" = the player's preference)
##   changed(fields)                       PlayerProfile.make_roster_fields of the new choice
##   preview_requested(shape_id, skin)     show this body in the hangar

signal changed(fields: Dictionary)
signal preview_requested(shape_id: String, skin_id: String)

var _pack := ""
var _choose_game := false
var _rows: VBoxContainer
var _focus_key := ""      # the row to focus again after a rebuild


func _init(pack := "", choose_game := false) -> void:
	_choose_game = choose_game
	_pack = pack if pack != "" else PlayerProfile.load_infantry_pack()
	_rows = VBoxContainer.new()
	add_child(_rows)
	_build()


## The infantry game the picker shows ("" = none installed).
func pack() -> String:
	return _pack


## Asks for the hangar preview of the current body and skin again (preview_requested).
func request_preview() -> void:
	var body := PlayerProfile.make_body_for(PlayerProfile.make_armor_for(_pack))
	var shown := body if body != "" else PlayerProfile.make_default_body(PlayerProfile.make_armor_for(_pack))
	if shown != "":
		preview_requested.emit(shown, PlayerProfile.make_skin_for(shown))


## The current choice as roster fields (PlayerProfile.make_roster_fields).
func make_fields(vehicle_id := "") -> Dictionary:
	return PlayerProfile.make_roster_fields(_pack, vehicle_id)


func _build() -> void:
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	var packs := CatalogBridge.make_infantry_packs()
	if packs.is_empty() or _pack == "":
		return
	_rows.add_child(Widgets.section("Your soldier"))
	if _choose_game and packs.size() > 1:
		_rows.add_child(_make_game_row(packs))
	var armor := PlayerProfile.make_armor_for(_pack)
	_rows.add_child(_make_choice_row("Starting armour", CatalogBridge.make_armors(_pack), armor, PlayerProfile.ARMOR_KEY))
	var bodies := CatalogBridge.make_bodies(armor)
	var body := PlayerProfile.make_body_for(armor)
	if bodies.size() > 1:
		_rows.add_child(_make_choice_row("Body", bodies, body if body != "" else str(bodies[0].id), PlayerProfile.BODY_KEY))
	var shown_body := body if body != "" else PlayerProfile.make_default_body(armor)
	var skins := CatalogBridge.make_skins(shown_body)
	var skin := PlayerProfile.make_skin_for(shown_body)
	if skins.size() > 1:
		_rows.add_child(_make_choice_row("Armour skin", skins, skin, PlayerProfile.SKIN_KEY))
	preview_requested.emit(shown_body, skin)


func _make_game_row(packs: Array) -> OptionRow:
	var labels := packs.map(func(p: Dictionary) -> String: return str(p.label))
	var index := packs.map(func(p: Dictionary) -> String: return str(p.pack)).find(_pack)
	var o := Widgets.option_button(labels, maxi(index, 0))
	o.item_selected.connect(func(i: int) -> void: _on_game_chosen(str(packs[i].pack)))
	o.set_meta("key", PlayerProfile.PACK_KEY)
	return OptionRow.new("Infantry game", o)


## A row choosing one of `choices` ({id, label}); the pick is saved under PlayerProfile key `key`.
func _make_choice_row(text: String, choices: Array, current: String, key: String) -> OptionRow:
	var labels := choices.map(func(c: Dictionary) -> String: return str(c.label))
	var index := choices.map(func(c: Dictionary) -> String: return str(c.id)).find(current)
	var o := Widgets.option_button(labels, maxi(index, 0))
	o.item_selected.connect(func(i: int) -> void: _on_chosen(key, str(choices[i].id)))
	o.set_meta("key", key)
	return OptionRow.new(text, o)


func _on_game_chosen(p: String) -> void:
	_pack = p
	PlayerProfile.apply_infantry_pack(p)
	_focus_key = PlayerProfile.PACK_KEY
	_rebuild_and_announce()


func _on_chosen(key: String, id: String) -> void:
	PlayerProfile.apply_value(key, id)
	_focus_key = key
	_rebuild_and_announce()


## Rebuilt after the frame: the row whose signal fired is still handling it.
func _rebuild_and_announce() -> void:
	(func() -> void:
		_build()
		_refocus.call_deferred()
		changed.emit(make_fields())).call_deferred()


func _refocus() -> void:
	for o in _rows.find_children("*", "OptionButton", true, false):
		if str(o.get_meta("key", "")) == _focus_key and o.is_inside_tree():
			(o as Control).grab_focus()
