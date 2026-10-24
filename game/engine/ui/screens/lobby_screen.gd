class_name LobbyScreen
extends LauncherScreen
## The standard lobby (docs/design/lobby_loadout_economy.md section 5): one screen for the campaign, co-op, every versus
## mode and extraction, for the host, the players and (as a client) a dedicated server's session, over LAN or offline.
##   left     Game Options (the host edits, everybody else reads) and the Operator Setup block
##   centre   the pilot's squad as cards in a carousel, everybody else in a compact list, the chat
##   right    Option A: your goals (pick three) and the teammates' goals (read only); Option B: the campaign briefing
## Narrow windows get a tab bar instead of columns. The widgets live in engine/ui/lobby/; this screen wires them to the
## session (Net), the operator profile and MatchFlow. args: {"kind": a GameOptionsModel.KIND_*, "solo": true} opens a
## new session first (otherwise the session exists: a join, or the lobby a game came back to); {"from_hangar": true} comes
## back from the Hangar.

const START_MATCH := "Start match"
const START_MISSION := "Start mission"
const START_ANYWAY := "Start anyway"
const READY_ANYWAY := "Ready anyway"
const READY_TEXT := "Ready"
const NOT_READY_TEXT := "Not ready"
const PENDING_MSEC := 2500
const CHAT_STRETCH := 0.5   # the others list takes twice the chat's share of the centre column

var layout: LobbyLayout
var options: GameOptionsPanel
var setup: OperatorSetupBlock
var carousel: TeamCarousel
var list: SquadList
var goals: TaskListPane
var briefing: BriefingPane
var chat: LobbyChatStrip
var profile: OperatorProfile
var herc_row: LobbyHercRow
var sheets: LobbySheets
var _title_label: Label
var _count_label: Label
var _credits: CreditsBadge
var _instructions: Label
var _squad_box: VBoxContainer
var tasks_scroll: ScrollContainer
var _raid_profile: ExtractionProfile
var _from_hangar := false
var _music_key := ""
var _announce_key := ""
var _mode_chosen := false
var _briefing_key := ""
var _zones: Array = []
var _pending_ready: Variant = null
var _pending_goals: Variant = null
var _pending_until := 0


func open(args: Dictionary) -> void:
	_from_hangar = bool(args.get("from_hangar", false))
	set_page_title("lobby")
	set_back("Leave", _leave)
	if args.has("kind") and Net.roster.is_empty():
		var err := MatchFlow.open_lobby_session(str(args.kind), bool(args.get("solo", false)), bool(args.get("online", false)))
		if err != OK:
			set_status("Could not open port %d (error %d)" % [Net.GAME_PORT, err])
	LobbyChatHub.ensure(get_tree())
	profile = OperatorProfile.load_for(Net.player_name)
	_raid_profile = ExtractionProfile.load_for(Net.player_name)
	sheets = LobbySheets.new(self)
	_build_panes()
	set_primary(START_MATCH if Net.is_host() else READY_TEXT, _on_primary)
	if Net.is_host() and not Net.settings.has(GameOptionsModel.GOAL_SEED_KEY):
		Net.set_settings(GameOptionsModel.make_with_value(Net.settings, GameOptionsModel.GOAL_SEED_KEY, randi()))
	Net.roster_changed.connect(_on_roster_changed)
	resized.connect(_apply_width)
	MatchFlow.publish_campaign_offer()
	_on_roster_changed()
	_apply_width.call_deferred()


func _exit_tree() -> void:
	if Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.disconnect(_on_roster_changed)


# ------------------------------------------------------------------ building

func _build_panes() -> void:
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_build_header())
	layout = LobbyLayout.new()
	content.add_child(layout)
	options = GameOptionsPanel.new()
	options.settings_changed.connect(apply_settings)
	options.options_requested.connect(func() -> void: sheets.open_options())
	options.teams_requested.connect(func() -> void: sheets.open_teams())
	options.assign_all_requested.connect(func() -> void: MatchFlow.apply_team_choices(TeamAssignment.make_assign_all(Net.roster, Net.settings)))
	options.shuffle_requested.connect(func() -> void: MatchFlow.apply_team_choices(TeamAssignment.make_shuffle(Net.roster, Net.settings, RandomNumberGenerator.new())))
	options.training_requested.connect(_open_training)
	options.save_requested.connect(func() -> void: router.go("saves", {"mode": "save", "return_to": "lobby"}))
	options.hangar_requested.connect(func() -> void: launcher().open_hangar("lobby"))
	setup = OperatorSetupBlock.new()
	setup.setup_requested.connect(_open_setup)
	herc_row = LobbyHercRow.new()
	herc_row.entry_changed.connect(func(entry: Dictionary) -> void: _announce_herc.call_deferred(entry))
	setup.add_child(herc_row)
	setup.move_child(herc_row, setup.setup_button.get_index())
	_squad_box = VBoxContainer.new()
	_instructions = Widgets.paragraph("", "DimLabel")
	_squad_box.add_child(_instructions)
	carousel = TeamCarousel.new()
	carousel.ready_toggled.connect(_set_ready)
	carousel.team_picked.connect(func(team: int) -> void: Net.set_my_info("team", team))
	carousel.card_edit.connect(func(_key: String) -> void: sheets.open_wingmen())
	_squad_box.add_child(carousel)
	list = SquadList.new()
	goals = TaskListPane.new()
	goals.goal_toggled.connect(_on_goal_toggled)
	goals.reroll_requested.connect(func() -> void: apply_settings(GameOptionsModel.make_with_value(Net.settings, GameOptionsModel.GOAL_SEED_KEY, randi())))
	briefing = BriefingPane.new()
	var tasks_box := VBoxContainer.new()
	tasks_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tasks_box.add_child(goals)
	tasks_box.add_child(briefing)
	tasks_scroll = _wrap_scroll(tasks_box)
	chat = LobbyChatStrip.new()
	chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat.size_flags_stretch_ratio = CHAT_STRETCH
	chat.custom_minimum_size = Vector2(0, Widgets.metric("row_height") * 3)
	layout.add_panes({"options": _wrap_scroll(options), "setup": setup, "carousel": _squad_box, "list": list,
		"tasks": tasks_scroll, "chat": chat})
	layout.tab_changed.connect(func(_t: String) -> void: _refresh_focus.call_deferred())


func _build_header() -> Control:
	var row := HBoxContainer.new()
	_title_label = Widgets.label("", "HeaderLabel")
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.clip_text = true
	row.add_child(_title_label)
	_credits = CreditsBadge.new()
	row.add_child(_credits)
	_count_label = Widgets.label("", "DimLabel")
	row.add_child(_count_label)
	return row


func _wrap_scroll(inner: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.theme_type_variation = "ContentPanel"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)
	return scroll


## Narrow below Siege/narrow_width; the carousel shows as many cards as the width holds.
func _apply_width() -> void:
	layout.apply_narrow(size.x < Widgets.metric("narrow_width"))
	carousel.set_narrow(layout.narrow)
	_refresh_focus.call_deferred()


# ------------------------------------------------------------------ refreshing

func _on_roster_changed() -> void:
	var s := Net.settings
	_title_label.text = LobbyModel.make_title(s)
	_count_label.text = LobbyModel.make_count_text(Net.roster)
	_credits.set_credits(profile.credits)
	_instructions.text = LobbyText.make_instructions(s, Net.is_host())
	_play_lobby_music()
	options.refresh(s, Net.is_host(), Net.roster)
	setup.refresh(profile, s)
	_refresh_pilot_build()
	refresh_squad()
	_refresh_right_pane()
	sheets.refresh()
	_refresh_primary()
	_refresh_focus.call_deferred()


## Announces the pilot's build again when what it depends on changed (the settings, his slot, the raid kit).
func _refresh_pilot_build() -> void:
	var s := Net.settings
	var is_campaign := str(s.get("mode", "")) == "campaign"
	setup.visible = true
	herc_row.visible = is_campaign
	if is_campaign:
		herc_row.refresh(s, _from_hangar)
		return
	var key := JSON.stringify([s.get("mode"), s.get(LobbySettings.INFANTRY_PACK_KEY), s.get(LobbySettings.GAME_MODE_KEY), s.get("world_idx"),
		profile.make_active_slot().to_dict(), profile.unlocks.make_owned_ids(), _raid_profile.make_kit_dict() if ExtractionRules.is_extraction(s) else {}])
	if key != _announce_key and Net.roster.has(Net.my_id()):
		_announce_key = key
		LobbyAnnouncer.announce.call_deferred(s, profile)


func refresh_squad() -> void:
	if not _mode_chosen:   # a campaign mission flies a Herc: its ring starts on the vehicles
		_mode_chosen = true
		if str(Net.settings.get("mode", "")) == "campaign":
			carousel.apply_mode(TeamRing.MODE_VEHICLE)
	var s := Net.settings
	var my := Net.my_id()
	var squad := LobbyModel.make_squad_peers(Net.roster, s, my)
	var cards := squad.map(func(peer: int) -> Dictionary: return _make_own_view(LobbyCards.make_pilot_card(peer, Net.roster[peer], s, my)))
	var bots := LobbyModel.make_squad_bots(Net.roster, s, my, LobbyModel.MAX_SQUAD_CARDS - squad.size())
	cards.append_array(bots.map(func(b: Dictionary) -> Dictionary: return LobbyCards.make_bot_card(b, s)))
	cards.append_array(LobbyWingmen.make_cards(s))
	carousel.set_header(LobbyModel.make_squad_header(Net.roster, s, my, cards.size()))
	carousel.refresh(cards, LobbyViews.make_team_choices(s))
	list.refresh(LobbyModel.make_list_rows(Net.roster, s, my, squad, bots))


## The local pilot's card shows his pending Ready click until the host's roster agrees.
func _make_own_view(card: Dictionary) -> Dictionary:
	if bool(card.you):
		card["warning"] = _make_warning_text()
	if bool(card.you) and _pending_ready != null and Time.get_ticks_msec() < _pending_until and not bool(card.host):
		card["ready"] = bool(_pending_ready)
	return card


func _refresh_right_pane() -> void:
	var s := Net.settings
	var kind := BriefingSource.make_kind(s)
	tasks_scroll.visible = kind != BriefingSource.KIND_NONE
	goals.visible = kind == BriefingSource.KIND_GOALS
	briefing.visible = kind == BriefingSource.KIND_BRIEFING
	layout.refresh_tasks_visibility()
	if kind == BriefingSource.KIND_GOALS:
		goals.show_goals(LobbyViews.make_goals_view(s, Net.roster, Net.my_id(), _raid_profile, _pending_goals if Time.get_ticks_msec() < _pending_until else null))
	elif kind == BriefingSource.KIND_BRIEFING:
		var key := MatchFlow.make_mission_heading() + JSON.stringify(s.get(MatchFlow.CAMPAIGN_OFFER, {}).get("heading", ""))
		if key != _briefing_key:
			_briefing_key = key
			briefing.show_briefing(BriefingSource.make_briefing(s))


## Host: Start is enabled once every pilot is ready, else the footer says who is missing. Client: Ready / Not ready.
func _refresh_primary() -> void:
	if not Net.is_host():
		primary_button.text = NOT_READY_TEXT if _is_ready() else READY_TEXT
		set_status("")
		return
	primary_button.text = START_MISSION if Net.settings.get("mode") == "campaign" else START_MATCH
	var reason := MatchFlow.make_start_block_reason()
	primary_button.disabled = reason != ""
	set_status(reason)


## "2 parts are not allowed here" for the local pilot's build, "" when it is fine.
func _make_warning_text() -> String:
	if str(Net.settings.get("mode", "")) == "campaign":
		return ""
	var count := LobbyAnnouncer.make_blocks(Net.settings, profile).size()
	return "%d part%s not allowed here, left off" % [count, "" if count == 1 else "s"] if count > 0 else ""


func _is_ready() -> bool:
	if _pending_ready != null and Time.get_ticks_msec() < _pending_until:
		return bool(_pending_ready)
	return bool((Net.roster.get(Net.my_id(), {}) as Dictionary).get("ready", false))


# ------------------------------------------------------------------ actions

## Host: a game option changed (Game Options, its sheets, the goal reroll). Pilots whose build the new options treat differently must ready up again.
func apply_settings(new_settings: Dictionary) -> void:
	if not Net.is_host():
		return
	MatchFlow.apply_revalidate_ready(Net.settings, new_settings)
	MatchFlow.apply_teams_for_settings(Net.settings, new_settings)
	MatchFlow.apply_campaign_for_settings(Net.settings, new_settings)
	Net.set_settings(new_settings)
	MatchFlow.publish_campaign_offer()


## Host: the Tribes training missions are single player: the lobby session ends and the training page opens.
func _open_training(pack: String) -> void:
	Net.leave()
	router.replace("training", {"pack": pack})


func _on_primary() -> void:
	if Net.is_host():
		_ask_then(func() -> void: set_status(MatchFlow.try_start_hosted_match()), START_ANYWAY)
	else:
		_set_ready(not _is_ready())


## Ready (or off): readying first checks the build for parts this mode forbids.
func _set_ready(on: bool) -> void:
	if not on:
		_apply_ready(false)
		return
	var dialog := _ask_then(_apply_ready.bind(true), READY_ANYWAY)
	if dialog != null:
		dialog.closed.connect(refresh_squad, CONNECT_DEFERRED)


func _apply_ready(on: bool) -> void:
	_pending_ready = on
	_pending_until = Time.get_ticks_msec() + PENDING_MSEC
	Net.set_my_info("ready", on)
	refresh_squad()
	_refresh_primary()


func _ask_then(on_go: Callable, go_text: String) -> ConfirmDialog:
	var blocks := LobbyAnnouncer.make_blocks(Net.settings, profile) if str(Net.settings.get("mode", "")) != "campaign" else []
	return LobbyReadyFlow.ask(self, blocks, on_go, _open_setup, go_text)


func _announce_herc(entry: Dictionary) -> void:
	Net.set_my_infos({"vehicle": str(entry.vehicle), "loadout": entry.loadout})
	if Net.is_host() and bool(Net.settings.get("solo", false)) and Net.roster.has(Net.my_id()):
		Net.roster[Net.my_id()]["garage"] = entry.get("garage", {})


func _on_goal_toggled(goal_id: String, on: bool) -> void:
	if ExtractionRules.is_extraction(Net.settings):
		_toggle_raid_task(goal_id, on)
		return
	var picked: Array = LobbyGoals.make_picked_ids(Net.roster.get(Net.my_id(), {}), Net.settings) if _pending_goals == null else _pending_goals
	picked = picked.filter(func(id: Variant) -> bool: return str(id) != goal_id)
	if on and picked.size() < LobbyGoals.make_max_picks(Net.settings):
		picked.append(goal_id)
	_pending_goals = picked
	_pending_until = Time.get_ticks_msec() + PENDING_MSEC
	LobbyAnnouncer.announce_goals(picked)
	_refresh_right_pane()


func _toggle_raid_task(task_id: String, on: bool) -> void:
	if on:
		_raid_profile.apply_take_task(task_id)
	else:
		_raid_profile.apply_drop_task(task_id)
	_raid_profile.save()
	_announce_key = ""
	Net.set_my_info("kit", _raid_profile.make_kit_dict())
	_refresh_right_pane()


func _open_setup() -> void:
	sheets.open_setup(profile)


func on_setup_closed(_changed := true) -> void:
	profile = OperatorProfile.load_for(Net.player_name)
	_raid_profile = ExtractionProfile.load_for(Net.player_name)
	_announce_key = ""
	_on_roster_changed()


func _leave() -> void:
	if MatchFlow.is_solo_campaign(Net.settings):
		Session.autosave()
		Session.clear_campaign()
		Net.leave()
		launcher().go_main_menu()
		return
	router.back()
	Net.leave()


## The menu music of the game whose map the match is on (a co-op campaign: the host's campaign); chosen
## again only when the map changes.
func _play_lobby_music() -> void:
	var key := "%s/%s" % [Net.settings.get("mode", ""), Net.settings.get("world_idx", "")]
	if key == _music_key:
		return
	_music_key = key
	if Net.settings.get("mode") == "campaign":
		MenuMusic.play_for_campaign("lobby")
		return
	var entries := MapPicker.make_entries()
	var i := int(Net.settings.get("world_idx", -1))
	if i >= 0 and i < entries.size():
		MenuMusic.play_for_pack(MenuMusic.make_pack_of_map_config(entries[i].config))


# ------------------------------------------------------------------ input and focus

func _input(event: InputEvent) -> void:
	if has_modal():
		return
	if UiActions.is_pressed(event, "menu_zone_next"):
		_jump(1)
	elif UiActions.is_pressed(event, "menu_zone_prev"):
		_jump(-1)
	elif UiActions.is_pressed(event, "menu_tab_next"):
		_step_tab(1)
	elif UiActions.is_pressed(event, "menu_tab_prev"):
		_step_tab(-1)
	elif UiActions.is_pressed(event, "menu_switch_kind"):
		carousel.toggle_mode()
	elif UiActions.is_pressed(event, "menu_primary") and primary_button.visible and not primary_button.disabled:
		primary_button.pressed.emit()
	else:
		return
	get_viewport().set_input_as_handled()


## True while a sheet or dialog is open over the lobby (it handles its own input).
func has_modal() -> bool:
	return get_children().slice(1).any(func(c: Node) -> bool: return c.has_signal("closed") and c.is_inside_tree())   # child 0 is the frame's background


func _jump(delta: int) -> void:
	LobbyFocus.jump(_zones, get_viewport().gui_get_focus_owner(), delta)


func _step_tab(delta: int) -> void:
	if layout.narrow and not carousel.has_focus_inside():
		layout.step_tab(delta)
	else:
		carousel.step(delta)


func _refresh_focus() -> void:
	_focus_dirty = false
	if not is_inside_tree():
		return
	_zones = LobbyFocus.make_live_zones(LobbyZones.make_zones(self, _footer_buttons()))
	LobbyFocus.link(_zones)
	var owner_control := get_viewport().gui_get_focus_owner()
	if not _opened or owner_control == null or not is_ancestor_of(owner_control):
		_opened = true
		focus_first()


func focus_first() -> void:
	var start: Control = setup.setup_button if setup.setup_button.is_visible_in_tree() else (primary_button if primary_button.visible else null)
	if start != null:
		start.grab_focus()
