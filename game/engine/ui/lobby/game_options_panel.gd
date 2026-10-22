class_name GameOptionsPanel
extends VBoxContainer
## Game Options, the lobby's top left (docs/design/lobby_loadout_economy.md section 5): the host edits the one Game mode (every
## versus mode, co-op, the co-op campaign, the extraction raid and the training pages), the map (only the maps that mode can be
## played on) and (in sheets) the detailed options and the teams; everybody else sees the same rows as read-only text
## (OptionRow.make_readonly). A campaign adds the host's Save game and Hangar buttons. The panel never touches Net: it
## sends `settings_changed(new_settings)` and the lobby applies them.
##   refresh(settings, is_host, roster)
##   settings_changed(s) / assign_all_requested / shuffle_requested / save_requested / hangar_requested /
##   teams_requested / options_requested / training_requested(pack)

signal settings_changed(new_settings: Dictionary)
signal assign_all_requested
signal shuffle_requested
signal save_requested
signal hangar_requested
signal teams_requested
signal options_requested
signal training_requested(pack: String)

const READ_ONLY_HINT := "Only the host changes these."
const HOST_HINT := "You are the host: these are yours to change."
const DISABLED_TEXT := "%s  (%s)"
const OPPONENTS_TEXT := "%d %s, %d %s"

var controls := {}          # key -> Control of the host's rows (tests, focus)
var settings := {}
var is_host := false
var _structure := ""
var _syncing := false
var _hint: Label
var _body: VBoxContainer


func _init() -> void:
	add_child(Widgets.section("Game options"))
	_hint = Widgets.paragraph("", "DimLabel")
	add_child(_hint)
	_body = VBoxContainer.new()
	add_child(_body)


## Shows `current` settings; the host's controls are rebuilt only when the rows change (a new map, mode or role).
func refresh(current: Dictionary, host_view: bool, _roster := {}) -> void:
	settings = current
	is_host = host_view
	var key := _make_structure_key()
	if key != _structure:
		_structure = key
		_rebuild()
	else:
		_sync_values()


func _make_structure_key() -> String:
	return JSON.stringify([is_host, settings.get("mode"), settings.get("world_idx"), settings.get(LobbySettings.GAME_MODE_KEY),
		LobbySettings.is_team_match(settings), settings.get("solo"), Net.is_online()]) \
		+ ("" if is_host else JSON.stringify(make_readonly_rows(settings)))


func _rebuild() -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	controls.clear()
	_hint.text = HOST_HINT if is_host else READ_ONLY_HINT
	_hint.visible = Net.is_online()
	if is_host:
		_build_host_rows()
	else:
		_build_read_only_rows()
	_sync_values()


# ------------------------------------------------------------------ the host's rows

func _build_host_rows() -> void:
	var mode := str(settings.get("mode", ""))
	_add_row("game_mode", "Game mode", _make_mode_picker())
	if mode != GameOptionsModel.KIND_CAMPAIGN:
		var map := MapPicker.new("Map")
		map.map_changed.connect(func(i: int) -> void:
			if not _syncing:
				_emit(GameOptionsModel.make_with_map(settings, i)))
		controls["map"] = map
		_body.add_child(map)
	_body.add_child(Widgets.button("Game options...", func() -> void: options_requested.emit()))
	controls["options"] = _body.get_child(_body.get_child_count() - 1)
	_build_team_buttons()
	if mode == GameOptionsModel.KIND_CAMPAIGN:
		_build_campaign_buttons()


func _build_team_buttons() -> void:
	if not LobbySettings.is_team_match(settings):
		return
	_body.add_child(Widgets.button("Adjust teams...", func() -> void: teams_requested.emit()))
	controls["teams"] = _body.get_child(_body.get_child_count() - 1)
	var assign := Widgets.small_button("Assign all", func() -> void: assign_all_requested.emit())
	var shuffle := Widgets.small_button("Shuffle teams", func() -> void: shuffle_requested.emit())
	_body.add_child(Widgets.row([assign, shuffle]))
	controls["assign"] = assign
	controls["shuffle"] = shuffle


## The one Game mode picker: the choices in groups under separators, a mode no installed map offers disabled with its reason.
## Picking a training page opens it (the lobby is left); the picker then shows the lobby's own mode again.
func _make_mode_picker() -> OptionButton:
	var picker := Widgets.option_button([])
	var group := ""
	for c in _make_shown_choices():
		if str(c.group) != group:
			group = str(c.group)
			picker.add_separator(group)
		var at := picker.item_count
		picker.add_item(make_choice_text(c))
		picker.set_item_metadata(at, str(c.id))
		picker.set_item_disabled(at, not bool(c.enabled))
		picker.set_item_tooltip(at, str(c.reason))
	picker.item_selected.connect(func(i: int) -> void: _pick_choice(str(picker.get_item_metadata(i))))
	return picker


## A choice's picker text: its label, and for a disabled one the reason in brackets.
static func make_choice_text(choice: Dictionary) -> String:
	return str(choice.label) if bool(choice.enabled) else DISABLED_TEXT % [choice.label, choice.reason]


## Online the host may switch to any mode; an offline session keeps its own kind of game (versus modes, or the one mode).
func _make_shown_choices() -> Array:
	var mode := str(settings.get("mode", ""))
	return GameOptionsModel.make_mode_choices().filter(func(c: Dictionary) -> bool:
		return Net.is_online() or str(c.kind) in [mode, GameOptionsModel.TRAINING_KIND])


## The row of choice `id` in the host's Game mode picker (separators count), -1 when it is not listed.
func find_choice_item(id: String) -> int:
	var picker := controls.get("game_mode") as OptionButton
	for i in picker.item_count if picker != null else 0:
		if str(picker.get_item_metadata(i)) == id:
			return i
	return -1


## What picking choice `id` does (also the tests' and the automation's way in).
func _pick_choice(id: String) -> void:
	var choice := GameOptionsModel.find_mode_choice(id)
	if str(choice.get("kind", "")) == GameOptionsModel.TRAINING_KIND:
		training_requested.emit(str(choice.pack))
		_sync_values()
	elif not _syncing:
		_emit(GameOptionsModel.make_with_choice(settings, id))
		_sync_values()


func _build_campaign_buttons() -> void:
	var save := Widgets.small_button("Save game", func() -> void: save_requested.emit())
	var hangar := Widgets.small_button("Hangar", func() -> void: hangar_requested.emit())
	_body.add_child(Widgets.row([save, hangar]))
	controls["save"] = save
	controls["hangar"] = hangar


func _add_row(key: String, text: String, control: Control) -> void:
	controls[key] = control
	_body.add_child(OptionRow.new(text, control))


## Puts the settings into the host's controls without sending anything.
func _sync_values() -> void:
	if not is_host:
		return
	_syncing = true
	var id := GameOptionsModel.make_choice_id(settings)
	var picker := controls.game_mode as OptionButton
	for i in picker.item_count:
		if str(picker.get_item_metadata(i)) == id:
			picker.select(i)
			picker.tooltip_text = str(picker.get_item_text(i))
	if controls.has("map"):
		var map := controls.map as MapPicker
		map.set_allowed(GameOptionsModel.make_maps_for_choice(id))
		map.select_index(int(settings.get("world_idx", 0)))
	_syncing = false


func _emit(new_settings: Dictionary) -> void:
	if not _syncing:
		settings_changed.emit(new_settings)


# ------------------------------------------------------------------ everybody else's rows

func _build_read_only_rows() -> void:
	for row in make_readonly_rows(settings):
		_body.add_child(OptionRow.make_readonly(str(row[0]), str(row[1])))


## [label, text] per setting a non-host sees: the game mode, map, limits, opponents, teams, infantry game, relations.
static func make_readonly_rows(s: Dictionary) -> Array:
	var mode := str(s.get("mode", ""))
	var rows := [["Game mode", GameOptionsModel.make_choice_label(s)]]
	if mode != GameOptionsModel.KIND_CAMPAIGN:
		rows.append(["Map", str(s.get("map", ""))])
	rows.append_array(_make_limit_rows(s, mode))
	if mode != GameOptionsModel.KIND_CAMPAIGN:
		rows.append(["Opponents", _make_opponents_text(s, mode)])
	if LobbySettings.is_team_match(s):
		rows.append(["Teams", str(LobbySettings.make_team_count(s)) if mode == GameOptionsModel.KIND_VERSUS else "squads by team"])
	if mode == ExtractionRules.MODE:
		rows.append(["Faction relations", str(s.get(LobbySettings.RELATIONS_KEY, ""))])
	if str(s.get(LobbySettings.INFANTRY_PACK_KEY, "")) != "":
		rows.append(["Infantry game", Packs.pack_name(str(s.get(LobbySettings.INFANTRY_PACK_KEY, "")))])
	return rows


static func _make_limit_rows(s: Dictionary, mode: String) -> Array:
	var rows := []
	if mode in [GameOptionsModel.KIND_VERSUS, GameOptionsModel.KIND_COOP]:
		var limit := GameOptionsModel.make_shown_score_limit(s)
		rows.append(["Kill limit" if GameOptionsModel.is_kill_limit(s) else "Score limit", str(limit) if limit > 0 else "none"])
	if mode == GameOptionsModel.KIND_VERSUS:
		var minutes := GameOptionsModel.make_shown_time_limit(s)
		rows.append(["Time limit", "%d min" % minutes if minutes > 0 else "none"])
	return rows


static func _make_opponents_text(s: Dictionary, mode: String) -> String:
	var raid := mode == ExtractionRules.MODE
	return OPPONENTS_TEXT % [int(s.get(InfantryBots.CONFIG_KEY, 0)), "faction soldiers" if raid else "infantry bots",
		int(s.get("ai", 0)), "faction vehicles" if raid else "AI units"]
