class_name GameOptionsSheet
extends ModalSheet
## The host's detailed game options (docs/design/lobby_loadout_economy.md section 5): limits, team count, squads, the
## computer-controlled opponents, Herc stats, the infantry game, a raid's faction relations and the password. Opened from
## Game Options; every change is a new settings dictionary (GameOptionsModel) sent through `settings_changed` at once.

signal settings_changed(new_settings: Dictionary)

const MAX_BOTS_SLIDER := 200

var settings := {}
var rows := {}          # key -> OptionRow
var controls := {}      # key -> Control
var _packs: Array = []
var _presets: Array = []


## Opens the sheet over `host` for `current` settings.
static func show_over(host: Control, current: Dictionary) -> GameOptionsSheet:
	var sheet := GameOptionsSheet.new()
	sheet.set_title("GAME OPTIONS")
	sheet.settings = current
	sheet._return_focus = host.get_viewport().gui_get_focus_owner()
	host.add_child(sheet)
	sheet._build()
	return sheet


func _build() -> void:
	var mode := str(settings.get("mode", ""))
	var raid := mode == ExtractionRules.MODE
	_packs = CatalogBridge.make_infantry_packs()
	_add_slider("score", "Kill limit", 0, GameOptionsModel.MAX_FRAG_LIMIT, _on_score)
	_add_slider("time", "Time limit (min)", 0, GameOptionsModel.MAX_TIME_LIMIT_MIN, _on_time)
	_add_slider("teams", "Teams", CatalogBridge.MIN_TEAMS, CatalogBridge.MAX_TEAMS, func(v: float) -> void: _change(GameOptionsModel.make_with_team_count(settings, int(v))))
	var squads := Widgets.check_box("Squads by team", bool(settings.get("teams", false)))
	squads.toggled.connect(func(on: bool) -> void: _change(GameOptionsModel.make_with_squads(settings, on)))
	_add_row("squads", "Squads", squads)
	_add_slider("bots", "Faction soldiers" if raid else "Infantry bots", 0, InfantryBots.MAX_BOTS,
		func(v: float) -> void: _change(GameOptionsModel.make_with_value(settings, InfantryBots.CONFIG_KEY, int(v))))
	_add_slider("ai", "Faction vehicles" if raid else "AI units", 0, GameOptionsModel.MAX_AI,
		func(v: float) -> void: _change(GameOptionsModel.make_with_value(settings, "ai", int(v))))
	_add_slider("max_bots", "Max bots (0 = no cap)", 0, MAX_BOTS_SLIDER,
		func(v: float) -> void: _change(GameOptionsModel.make_with_value(settings, BotBudget.CONFIG_KEY, int(v))))
	var balance := Widgets.option_button(MatchFlow.BALANCE_NAMES, MatchFlow.BALANCES.find(str(settings.get("balance", MatchFlow.BALANCES[0]))))
	balance.item_selected.connect(func(i: int) -> void: _change(GameOptionsModel.make_with_value(settings, "balance", MatchFlow.BALANCES[i])))
	_add_row("balance", "Herc stats", balance)
	var pack_index := _packs.map(func(p: Dictionary) -> String: return str(p.pack)).find(str(settings.get(LobbySettings.INFANTRY_PACK_KEY, "")))
	var pack := Widgets.option_button(_packs.map(func(p: Dictionary) -> String: return str(p.label)), maxi(pack_index, 0))
	pack.item_selected.connect(func(i: int) -> void: _change(GameOptionsModel.make_with_value(settings, LobbySettings.INFANTRY_PACK_KEY, str(_packs[i].pack))))
	_add_row("pack", "Infantry game", pack)
	_presets = CatalogBridge.make_relation_presets()
	var relations := Widgets.option_button(_presets.map(func(p: Dictionary) -> String: return str(p.label)),
		_presets.map(func(p: Dictionary) -> String: return str(p.id)).find(str(settings.get(LobbySettings.RELATIONS_KEY, ""))))
	relations.item_selected.connect(func(i: int) -> void: _change(GameOptionsModel.make_with_value(settings, LobbySettings.RELATIONS_KEY, str(_presets[i].id))))
	_add_row("relations", "Faction relations", relations)
	var password := Widgets.line_edit(Net.password, "none")
	password.text_changed.connect(func(t: String) -> void: Net.password = t)
	_add_row("password", "Password", password)
	set_back("Back")
	set_primary("Done", close)
	_apply_values()


func _add_slider(key: String, text: String, low: int, high: int, on_change: Callable) -> void:
	var slider := Widgets.slider(low, high, low)
	slider.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			on_change.call(v))
	_add_row(key, text, slider).with_value_readout()


func _add_row(key: String, text: String, control: Control) -> OptionRow:
	var row := OptionRow.new(text, control)
	rows[key] = row
	controls[key] = control
	body.add_child(row)
	return row


var _syncing := false


func _on_score(v: float) -> void:
	_change(GameOptionsModel.make_with_score_limit(settings, int(v)))


func _on_time(v: float) -> void:
	_change(GameOptionsModel.make_with_time_limit(settings, int(v)))


func _change(new_settings: Dictionary) -> void:
	settings = new_settings
	settings_changed.emit(new_settings)
	_apply_values()


## Takes the settings the lobby has now (another host action, a map change) without rebuilding the rows.
func apply_settings(current: Dictionary) -> void:
	settings = current
	_apply_values()


## Shows the rows the mode uses and their values; moving a slider here sends nothing.
func _apply_values() -> void:
	_syncing = true
	var mode := str(settings.get("mode", ""))
	var versus := mode == GameOptionsModel.KIND_VERSUS
	var raid := mode == ExtractionRules.MODE
	var campaign := mode == GameOptionsModel.KIND_CAMPAIGN
	var team_range := GameOptionsModel.team_range(settings)
	rows.score.visible = mode in [GameOptionsModel.KIND_VERSUS, GameOptionsModel.KIND_COOP]
	rows.score.label.text = "Kill limit" if GameOptionsModel.is_kill_limit(settings) else "Score limit"
	(controls.score as HSlider).min_value = 1 if GameOptionsModel.is_kill_limit(settings) else 0
	_set_slider("score", GameOptionsModel.make_shown_score_limit(settings))
	rows.time.visible = versus
	_set_slider("time", GameOptionsModel.make_shown_time_limit(settings))
	rows.teams.visible = versus and bool(settings.get("teams", false)) and team_range.y > team_range.x
	(controls.teams as HSlider).min_value = team_range.x
	(controls.teams as HSlider).max_value = team_range.y
	_set_slider("teams", LobbySettings.make_team_count(settings))
	rows.squads.visible = raid
	(controls.squads as CheckBox).button_pressed = bool(settings.get("teams", false))
	rows.bots.visible = not campaign and not _packs.is_empty()
	_set_slider("bots", int(settings.get(InfantryBots.CONFIG_KEY, 0)))
	rows.ai.visible = not campaign
	_set_slider("ai", int(settings.get("ai", 0)))
	rows.max_bots.visible = not campaign
	_set_slider("max_bots", int(settings.get(BotBudget.CONFIG_KEY, 0)))
	rows.balance.visible = true
	rows.pack.visible = _packs.size() > 1 and not campaign
	rows.relations.visible = raid
	rows.password.visible = Net.is_host() and Net.is_online()
	_syncing = false


func _set_slider(key: String, value: int) -> void:
	var slider := controls[key] as HSlider
	slider.value = clampf(value, slider.min_value, slider.max_value)
