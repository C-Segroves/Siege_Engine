extends LauncherScreen
## Host a LAN game -> Create lobby. Mode (versus by default), battlefield, the map's game mode (deathmatch by
## default; GameModes via CatalogBridge), the team count and the teams of a team mode, kill limit, Herc stats, the
## infantry game (both Tribes installed), infantry bots and AI units (an extraction raid: faction soldiers, faction
## vehicles, squads and the factions' relations). Rows a mode does not use are hidden. Settings: LobbySettings.
## args: {"mode": a MatchFlow.MODES key, or "team_vs" (versus in the map's first team mode), "ai": AI units,
## "infantry_bots": bots}.

const DEFAULT_MODE := "vs"
const TEAM_VERSUS_ARG := "team_vs"
const DEFAULT_AI := 4
const MAX_AI := 23
const MAX_FRAG_LIMIT := 100
const MAX_TIME_LIMIT_MIN := 60
const SECONDS_PER_MINUTE := 60
## Game mode families whose limit counts kills (the battle's frag limit); the others score captures / points.
const KILL_FAMILIES := ["deathmatch", "duel"]
const BOT_LABELS := {"default": "Infantry bots", ExtractionRules.MODE: "Faction soldiers"}
const AI_LABELS := {"default": "AI units", ExtractionRules.MODE: "Faction vehicles"}
const CAMPAIGN_HINT := "Co-op campaign: you host your campaign (the running one, or a new Earthsiege career). " \
	+ "In the lobby every pilot picks a Herc from its garage and presses Ready; you start the mission when all are ready. " \
	+ "Campaign missions field their own units (no bots)."

var _mode: OptionButton
var _map: MapPicker
var _game_mode: OptionButton
var _game_modes: Array = []
var _mode_info: Label
var _team_count: HSlider
var _squads: CheckBox
var _relations: OptionButton
var _relation_presets: Array = []
var _frag_limit: HSlider
var _time_limit: HSlider
var _limit_defaults := {}   # the game mode's own {score_limit, time_limit_s} on this map (GameModes; 0 = none)
var _limits_key := ""
var _balance: OptionButton
var _infantry_pack: OptionButton
var _infantry_packs: Array = []
var _ai: HSlider
var _bots: HSlider
var _rows := {}            # row name -> OptionRow (shown per mode)
var _hint: Label
var _teams: TeamList
var _host_team := TeamAssignment.UNASSIGNED


func open(args: Dictionary) -> void:
	set_page_title("host a LAN game")
	set_back("Back", router.back)
	set_primary("Create lobby", create_lobby)
	var wanted := str(args.get("mode", DEFAULT_MODE))
	_build_rows(args, MatchFlow.make_offered_modes().find("vs" if wanted == TEAM_VERSUS_ARG else wanted))
	_rebuild_game_modes(wanted == TEAM_VERSUS_ARG)
	_refresh()


func _build_rows(args: Dictionary, mode_index: int) -> void:
	_mode = Widgets.option_button(MatchFlow.make_offered_modes().map(MatchFlow.make_mode_name), maxi(mode_index, 0))
	_mode.item_selected.connect(func(_i: int) -> void: _refresh())
	content.add_child(OptionRow.new("Mode", _mode))
	_hint = Widgets.paragraph(CAMPAIGN_HINT, "DimLabel")
	content.add_child(_hint)
	_map = MapPicker.new("Map")
	_map.map_changed.connect(func(_i: int) -> void: _rebuild_game_modes(false))
	content.add_child(_map)
	_game_mode = Widgets.option_button([])
	_game_mode.item_selected.connect(func(_i: int) -> void: _refresh())
	_add_row("game_mode", "Game mode", _game_mode)
	_mode_info = Widgets.paragraph("", "DimLabel")
	content.add_child(_mode_info)
	_team_count = Widgets.slider(CatalogBridge.MIN_TEAMS, CatalogBridge.MAX_TEAMS, CatalogBridge.MIN_TEAMS)
	_team_count.value_changed.connect(func(_v: float) -> void: _refresh_teams())
	_add_row("team_count", "Teams", _team_count).with_value_readout()
	_squads = Widgets.check_box("Squads by team", false)
	_squads.toggled.connect(func(_on: bool) -> void: _refresh())
	_add_row("squads", "Squads", _squads)
	_relation_presets = CatalogBridge.make_relation_presets()
	_relations = Widgets.option_button(_relation_presets.map(func(p: Dictionary) -> String: return str(p.label)))
	_add_row("relations", "Faction relations", _relations)
	_add_match_rows(args)
	_teams = TeamList.new()
	_teams.team_chosen.connect(func(_peer: int, team: int) -> void: _apply_host_team(team))
	_teams.assign_all_requested.connect(func() -> void: _apply_host_team(_make_host_preview_team(false)))
	_teams.shuffle_requested.connect(func() -> void: _apply_host_team(_make_host_preview_team(true)))
	content.add_child(_teams)


func _add_match_rows(args: Dictionary) -> void:
	_frag_limit = Widgets.slider(1, MAX_FRAG_LIMIT, MatchFlow.DEFAULT_FRAG_LIMIT)
	_add_row("frag_limit", "Kill / score limit", _frag_limit).with_value_readout()
	_time_limit = Widgets.slider(0, MAX_TIME_LIMIT_MIN, 0)
	_add_row("time_limit", "Time limit (min)", _time_limit).with_value_readout()
	_balance = Widgets.option_button(MatchFlow.BALANCE_NAMES)
	_add_row("balance", "Herc stats", _balance)
	_infantry_packs = CatalogBridge.make_infantry_packs()
	var preferred := _infantry_packs.map(func(p: Dictionary) -> String: return str(p.pack)).find(PlayerProfile.load_infantry_pack())
	_infantry_pack = Widgets.option_button(_infantry_packs.map(func(p: Dictionary) -> String: return str(p.label)), maxi(preferred, 0))
	_add_row("infantry_pack", "Infantry game", _infantry_pack)
	_bots = Widgets.slider(0, InfantryBots.MAX_BOTS, int(args.get(InfantryBots.CONFIG_KEY, 0)))
	_bots.value_changed.connect(func(_v: float) -> void: _refresh_teams())
	_add_row("bots", BOT_LABELS.default, _bots).with_value_readout()
	_ai = Widgets.slider(0, MAX_AI, int(args.get("ai", DEFAULT_AI)))
	_ai.value_changed.connect(func(_v: float) -> void: _refresh_teams())
	_add_row("ai", AI_LABELS.default, _ai).with_value_readout()


func _add_row(key: String, text: String, control: Control) -> OptionRow:
	var row := OptionRow.new(text, control)
	_rows[key] = row
	content.add_child(row)
	return row


## The map's game modes (deathmatch first); keeps the chosen one when the new map offers it too.
func _rebuild_game_modes(prefer_team_mode: bool) -> void:
	var kept := str(_selected_game_mode().get("id", ""))
	_game_modes = CatalogBridge.make_game_modes(_map.selected_entry())
	_game_mode.clear()
	var pick := 0
	for i in _game_modes.size():
		_game_mode.add_item(str(_game_modes[i].label))
		if str(_game_modes[i].id) == kept or (prefer_team_mode and pick == 0 and bool(_game_modes[i].team_based)):
			pick = i
	_game_mode.select(pick)
	_refresh()


func _selected_game_mode() -> Dictionary:
	var i := _game_mode.selected if _game_mode != null else -1
	return _game_modes[i] if i >= 0 and i < _game_modes.size() else {}


func _mode_key() -> String:
	return str(MatchFlow.make_offered_modes()[_mode.selected])


## Shows the rows the chosen mode uses and relabels the shared ones.
func _refresh() -> void:
	if _teams == null:
		return
	var mode := _mode_key()
	var extraction := mode == ExtractionRules.MODE
	var game_mode := _selected_game_mode()
	_rows.game_mode.visible = mode == "vs"
	_game_mode.tooltip_text = str(game_mode.get("description", ""))
	_mode_info.visible = mode == "vs"
	_mode_info.text = "%s
Modes on this map: %s" % [str(game_mode.get("description", "")),
		", ".join(_game_modes.map(func(m: Dictionary) -> String: return str(m.label)))]
	_rows.squads.visible = extraction
	_rows.relations.visible = extraction
	_rows.frag_limit.visible = mode in ["vs", "coop"]
	_seed_limits(mode, game_mode)
	_rows.time_limit.visible = mode == "vs"
	_rows.infantry_pack.visible = _infantry_packs.size() > 1 and mode != "campaign"
	_rows.bots.visible = mode != "campaign" and not _infantry_packs.is_empty()
	_rows.ai.visible = mode != "campaign"
	_rows.bots.label.text = BOT_LABELS.get(mode, BOT_LABELS.default)
	_rows.ai.label.text = AI_LABELS.get(mode, AI_LABELS.default)
	_hint.visible = mode == "campaign"
	var team_range := CatalogBridge.make_team_range(game_mode, _map.selected_config())
	_team_count.min_value = team_range.x
	_team_count.max_value = team_range.y
	_team_count.editable = team_range.y > team_range.x
	_refresh_teams()


## The team count row and the team list: only for a team match.
func _refresh_teams() -> void:
	var s := make_settings()
	var teams := LobbySettings.is_team_match(s)
	_rows.team_count.visible = teams
	_teams.visible = teams
	if teams:
		_teams.refresh(s, _make_preview_roster(), 1, true)


## The host alone, as the lobby will open: on the team he picked here, else unassigned.
func _make_preview_roster() -> Dictionary:
	return {MatchFlow.HOST_ID: {"name": Net.player_name, "team": _host_team}}


func _make_host_preview_team(shuffle: bool) -> int:
	var roster := _make_preview_roster()
	if shuffle:
		roster[MatchFlow.HOST_ID].team = TeamAssignment.UNASSIGNED
	var placed := TeamAssignment.make_assign_all(roster, make_settings())
	return int(placed.get(MatchFlow.HOST_ID, _host_team))


func _apply_host_team(team: int) -> void:
	_host_team = team
	_refresh_teams()


## The limit sliders follow the map's game mode: a kill limit for the deathmatch family, else the mode's own
## score limit (0 = none) seeded from its defaults on this map; the time limit likewise (minutes).
func _seed_limits(mode: String, game_mode: Dictionary) -> void:
	var id := str(game_mode.get("id", GameModes.DEFAULT)) if mode == "vs" else ""
	var key := "%s/%s/%d" % [mode, id, _map.selected_index()]
	if key == _limits_key:
		return
	_limits_key = key
	var map_id := str(_map.selected_config().get("map", ""))
	_limit_defaults = GameModes.make_default_limits(id, MapBuilder.load_map(map_id) if map_id != "" else {}) if id != "" else {}
	var kills := is_kill_limit(mode, id)
	_rows.frag_limit.label.text = "Kill limit" if kills else "Score limit"
	_frag_limit.min_value = 1 if kills else 0
	_frag_limit.value = MatchFlow.DEFAULT_FRAG_LIMIT if kills else float(_limit_defaults.get(GameModes.SCORE_LIMIT_KEY, 0.0))
	_time_limit.value = roundf(float(_limit_defaults.get(GameModes.TIME_LIMIT_KEY, 0.0)) / SECONDS_PER_MINUTE)


## True when the limit of `mode` / game mode `id` counts kills (deathmatch family, co-op).
static func is_kill_limit(mode: String, id: String) -> bool:
	return mode != "vs" or GameModes.family_of(id) in KILL_FAMILIES


## The score / time limits to send: a slider the host left at the mode's default sends 0 (the mode decides).
func make_limit_choices() -> Dictionary:
	var id := str(_selected_game_mode().get("id", GameModes.DEFAULT))
	var out := {"score_limit": 0, "time_limit_s": 0}
	if not is_kill_limit(_mode_key(), id) and _frag_limit.value != float(_limit_defaults.get(GameModes.SCORE_LIMIT_KEY, 0.0)):
		out.score_limit = int(_frag_limit.value)
	var default_min := roundf(float(_limit_defaults.get(GameModes.TIME_LIMIT_KEY, 0.0)) / SECONDS_PER_MINUTE)
	if _time_limit.value != default_min:
		out.time_limit_s = int(_time_limit.value) * SECONDS_PER_MINUTE
	return out


## Picks the first game mode of the map whose id or label contains `part` (automation --game_mode=).
func select_game_mode(part: String) -> bool:
	for i in _game_modes.size():
		if str(_game_modes[i].id).contains(part) or str(_game_modes[i].label).to_lower().contains(part.to_lower()):
			_game_mode.select(i)
			_refresh()
			return true
	return false


## Picks the first map whose name contains `name_part` (automation --map=); false when none does.
func select_map(name_part: String) -> bool:
	var entries := MapPicker.make_entries()
	for i in entries.size():
		if str(entries[i].name).to_lower().contains(name_part.to_lower()):
			_map.select_index(i)
			return true
	return false


## Opens the lobby with the chosen settings (also used by --autohost / --page=lobby).
func create_lobby() -> void:
	PlayerProfile.apply_infantry_pack(make_settings().get(LobbySettings.INFANTRY_PACK_KEY, ""))
	var err := MatchFlow.host_lobby(make_settings(), str(router.context.vehicle))
	if err != OK:
		set_status("Could not open port %d (error %d)" % [Net.GAME_PORT, err])
		return
	if LobbySettings.is_team_match(make_settings()):
		Net.set_my_info("team", _host_team)
	router.go("lobby")


func make_settings() -> Dictionary:
	var pack_index := _infantry_pack.selected
	return LobbySettings.make({"mode": _mode_key(), "game_mode": _selected_game_mode(), "team_count": _team_count.value,
		"squads": _squads.button_pressed, "frag_limit": _frag_limit.value, "limits": make_limit_choices(), "ai": _ai.value,
		InfantryBots.CONFIG_KEY: _bots.value, "balance": MatchFlow.BALANCES[_balance.selected],
		"map_name": _map.selected_name(), "world_idx": _map.selected_index(),
		"infantry_pack": str(_infantry_packs[pack_index].pack) if pack_index >= 0 and pack_index < _infantry_packs.size() else "",
		"relations": str(_relation_presets[_relations.selected].id) if _relations.selected >= 0 else ""})
