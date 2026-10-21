class_name GameOptionsPanel
extends VBoxContainer
## Game Options, the lobby's top left (docs/design/lobby_loadout_economy.md section 5): the host edits the mode, the game
## mode, the map and (in sheets) the detailed options and the teams; everybody else sees the same rows as read-only text
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
const OPPONENTS_TEXT := "%d %s, %d %s"

var controls := {}          # key -> Control of the host's rows (tests, focus)
var settings := {}
var is_host := false
var _structure := ""
var _game_mode_ids: Array = []
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
	if _can_change_mode():
		var modes := _make_changeable_modes()
		var picker := Widgets.option_button(modes.map(_make_short_mode_name))   # the long names ("Extraction raid (loot, exfil, PvPvE)") clip in the row
		picker.item_selected.connect(func(i: int) -> void: _emit(GameOptionsModel.make_with_mode(settings, str(modes[i]))))
		_add_row("mode", "Mode", picker)
	if mode == GameOptionsModel.KIND_VERSUS:
		var picker := Widgets.option_button([])
		_game_mode_ids = []
		picker.item_selected.connect(func(i: int) -> void: _emit(GameOptionsModel.make_with_game_mode(settings, str(_game_mode_ids[i]))))
		_add_row("game_mode", "Game mode", picker)
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
	_build_training_buttons(mode)
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


## Training: the Tribes missions are single player scenarios, picked on their own screen (the lobby is left).
func _build_training_buttons(mode: String) -> void:
	if mode == GameOptionsModel.KIND_CAMPAIGN:
		return
	for pack in TribesMissionRuntime.PACKS:
		if TribesMissionRuntime.list_missions(pack).is_empty():
			continue
		var button := Widgets.button("%s training..." % Packs.pack_name(pack), func() -> void: training_requested.emit(pack))
		_body.add_child(button)
		controls["training_%s" % pack] = button


func _build_campaign_buttons() -> void:
	var save := Widgets.small_button("Save game", func() -> void: save_requested.emit())
	var hangar := Widgets.small_button("Hangar", func() -> void: hangar_requested.emit())
	_body.add_child(Widgets.row([save, hangar]))
	controls["save"] = save
	controls["hangar"] = hangar


func _add_row(key: String, text: String, control: Control) -> void:
	controls[key] = control
	_body.add_child(OptionRow.new(text, control))


## The mode's short title, which fits the picker at any width.
static func _make_short_mode_name(mode: String) -> String:
	return str(LobbySettings.MODE_TITLES.get(mode, MatchFlow.make_mode_name(mode)))


func _can_change_mode() -> bool:
	return Net.is_online() and _make_changeable_modes().size() > 1


## The modes a host may switch between inside the lobby (MatchFlow.make_offered_modes: versus, co-op, co-op campaign, raid).
func _make_changeable_modes() -> Array:
	return MatchFlow.make_offered_modes()


## Puts the settings into the host's controls without sending anything.
func _sync_values() -> void:
	if not is_host:
		return
	_syncing = true
	if controls.has("mode"):
		var picker := controls.mode as OptionButton
		picker.select(maxi(_make_changeable_modes().find(str(settings.get("mode", ""))), 0))
		picker.tooltip_text = MatchFlow.make_mode_name(str(settings.get("mode", "")))
	if controls.has("game_mode"):
		_sync_game_modes(controls.game_mode as OptionButton)
	if controls.has("map"):
		(controls.map as MapPicker).select_index(int(settings.get("world_idx", 0)))
	_syncing = false


## The picker lists the game modes of the lobby's map (they change with the map) and shows the chosen one.
func _sync_game_modes(picker: OptionButton) -> void:
	var modes := GameOptionsModel.make_game_modes(settings)
	var ids := modes.map(func(m: Dictionary) -> String: return str(m.id))
	if ids != _game_mode_ids:
		_game_mode_ids = ids
		picker.clear()
		for m in modes:
			picker.add_item(str(m.label))
	picker.select(maxi(ids.find(str(settings.get(LobbySettings.GAME_MODE_KEY, ""))), 0))


func _emit(new_settings: Dictionary) -> void:
	if not _syncing:
		settings_changed.emit(new_settings)


# ------------------------------------------------------------------ everybody else's rows

func _build_read_only_rows() -> void:
	for row in make_readonly_rows(settings):
		_body.add_child(OptionRow.make_readonly(str(row[0]), str(row[1])))


## [label, text] per setting a non-host sees: the mode, game mode, map, limits, opponents, teams, infantry game, relations.
static func make_readonly_rows(s: Dictionary) -> Array:
	var mode := str(s.get("mode", ""))
	var rows := [["Mode", str(LobbySettings.MODE_TITLES.get(mode, mode))]]
	if mode == GameOptionsModel.KIND_VERSUS:
		rows.append(["Game mode", LobbySettings.make_game_mode_label(s)])
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
