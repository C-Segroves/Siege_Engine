extends Node
## Headless check of the standard lobby (docs/design/lobby_loadout_economy.md section 5, chunk 3): the pure models (squad,
## list rows, cards, read-only options, goals under answer O6, the game options changes, the ready revalidation), the
## screen built for every mode as a host (campaign, co-op, versus with and without teams, skirmish, extraction), the
## client's read-only view, 64 pilots (nodes and time bounded), the narrow tabs, the ready warning dialog, the goal limit
## and a keyboard + gamepad walk (zone jumps, carousel flips, Operator Setup and back). The session is an offline host
## whose settings look like a LAN game, so no port is opened.
##   godot --headless --audio-driver Dummy --path game res://tests/lobby_check.tscn
##   windowed with renders: ... --resolution 1600x900 res://tests/lobby_check.tscn -- --shots=<dir> [--tag=wide]
##   (run again with --resolution 820x900 for the narrow layout of every screen)

const SavedGuard := preload("res://tests/saved_campaign_guard.gd")
const LAUNCHER := "res://launcher.tscn"
const FAKE_PEER := 4242
const SETTLE_FRAMES := 6
const BIG_ROSTER := 64
const MAX_BIG_REFRESH_MSEC := 400
const MAX_BIG_NODES := 1500
const DESKTOP_SIZE := Vector2i(1600, 900)
const NARROW_SIZE := Vector2i(820, 900)

var _fails := 0
var _guard := SavedGuard.new()
var _shots := ""
var _tag := ""
var _launcher: Launcher
var _windowed := DisplayServer.get_name() != "headless"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a.begins_with("--tag="):
			_tag = a.substr(6) + "_"
	_guard.back_up()
	_check_models()
	_check_goals()
	_check_options_model()
	_check_readonly_options()
	_check_revalidate()
	_check_results_award()
	await _check_modes()
	await _check_mode_picker()
	await _check_client_view()
	await _check_big_lobby()
	await _check_narrow()
	await _check_ready_warning()
	await _check_goal_limit()
	await _check_input_walk()
	await _check_chat()
	await _check_wingmen()
	await _check_results_screen()
	_close_lobby()
	_guard.restore()
	print("lobby_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := SETTLE_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


# ------------------------------------------------------------------ helpers

## An offline host whose settings are those of a LAN game of `kind`, with the lobby screen open.
func _open_lobby(kind: String, solo := false, extra := {}) -> LobbyScreen:
	_close_lobby()
	Net.host_offline()
	var s := GameOptionsModel.make_default_settings(kind, solo)
	s.merge(extra, true)
	if kind == GameOptionsModel.KIND_CAMPAIGN:
		Session.start_campaign(0, not solo)
	Net.set_settings(s)
	_launcher = load(LAUNCHER).instantiate()
	get_tree().root.add_child(_launcher)
	await _frames()
	var lobby := _launcher.go("lobby", {}) as LobbyScreen
	await _frames()
	return lobby


func _close_lobby() -> void:
	if is_instance_valid(_launcher):
		_launcher.queue_free()
		_launcher = null
	if Net.is_online() or not Net.roster.is_empty():
		Net.leave()
	Session.clear_campaign()


func _add_fake(peer: int, entry_name: String, team := 0, ready := false) -> void:
	Net.roster[peer] = {"name": entry_name, "vehicle": MatchFlow.DEFAULT_VEHICLE, "team": team, "ready": ready, "loadout": []}


func _text_of(root: Node) -> String:
	var out := PackedStringArray()
	for c in root.find_children("*", "", true, false):
		if c is Label or c is Button:
			out.append(str(c.text))
	return "\n".join(out)


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if str(c.text) == text and (c as Button).is_visible_in_tree():
			return c
	return null


func _send_action(action: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames(2)


func _focus() -> Control:
	return get_viewport().gui_get_focus_owner()


func _shot(name: String) -> void:
	if _shots == "":
		return
	await _frames(8)
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_shots)
	get_viewport().get_texture().get_image().save_png("%s/%s%s.png" % [_shots, _tag, name])


# ------------------------------------------------------------------ pure models

func _check_models() -> void:
	print("models:")
	var roster := {1: {"name": "Host", "team": 0, "ready": true}, 5: {"name": "Kira", "team": 0, "ready": true},
		6: {"name": "Dune", "team": 1, "ready": false}, 7: {"name": "Ash", "team": 0, "ready": false}}
	var teams := {"mode": "vs", "teams": true, "team_count": 2, "world_idx": 0}
	_expect(LobbyModel.make_squad_peers(roster, teams, 5) == [5, 1, 7], "team match: own squad first, then teammates (%s)" % [LobbyModel.make_squad_peers(roster, teams, 5)])
	_expect(LobbyModel.make_squad_peers(roster, {"mode": "vs", "teams": false}, 5) == [5], "free for all: only yourself")
	_expect(LobbyModel.make_squad_peers(roster, {"mode": "coop"}, 5).size() == 4, "co-op: everybody is in the squad")
	var rows := LobbyModel.make_list_rows(roster, teams, 5, [5, 1, 7], [])
	_expect(rows.size() == 1 and rows[0].name == "Dune" and not rows[0].ready, "the list holds the others with their ready state")
	var big := {}
	for i in BIG_ROSTER:
		big[100 + i] = {"name": "P%02d" % i, "team": 0, "ready": i % 2 == 0}
	_expect(LobbyModel.make_squad_peers(big, {"mode": "coop"}, 100).size() == LobbyModel.MAX_SQUAD_CARDS, "a big squad is cut to %d cards" % LobbyModel.MAX_SQUAD_CARDS)
	var card := LobbyCards.make_pilot_card(5, roster[5].merged({"infantry_armor": "tribes:MEDIUM"}), teams, 5)
	_expect(card.you and card.ready and card.team_visible and not card.host, "a card says who it is, ready, team shown")
	_expect(LobbyCards.make_pilot_card(1, roster[1], teams, 5).host, "the host card is marked and always ready")
	_expect(BriefingSource.make_kind({"mode": "campaign"}) == "briefing" and BriefingSource.make_kind({"mode": "vs"}) == "goals"
		and BriefingSource.make_kind({"mode": "vs", "solo": true}) == "none" and BriefingSource.make_kind({"mode": "extraction", "solo": true}) == "goals",
		"the right pane: briefing for a campaign, goals, nothing for a solo skirmish, goals for a solo raid")
	_expect(LobbyModel.make_unready_peers(roster) == [6, 7] or LobbyModel.make_unready_peers(roster).size() == 2, "unready pilots are named")


func _check_goals() -> void:
	print("goals (O6):")
	var s := {"mode": "vs", "game_mode": "ctf", "goal_seed": 5}
	var board := LobbyGoals.make_board(s)
	_expect(not board.is_empty() and board.all(func(g: Dictionary) -> bool: return g.scope == "individual"), "the board has individual goals only (%d)" % board.size())
	_expect(LobbyGoals.make_max_picks(s) == 3, "up to 3 goals")
	var ids := board.map(func(g: Dictionary) -> String: return str(g.id))
	var roster := {1: {"name": "Me", "goals": ids.slice(0, 2)}, 2: {"name": "Kira", "goals": ids.slice(1, 3)}}
	var mates := LobbyGoals.make_teammate_picks(s, roster, [1, 2], 1)
	_expect(mates.size() == 1 and mates[0].name == "Kira" and mates[0].goals.size() == 2, "the teammates' picks are listed for the others only")
	_expect(LobbyGoals.make_picked_ids(roster[1], s) == ids.slice(0, 2), "own picks are read from the roster entry")
	var done := LobbyGoals.make_done(board, ids, {"kills": 99, "vehicle_kills": 99, "objectives": 99, "flag_captures": 99, "survived": true})
	_expect(done.size() == board.size(), "completed goals are found from the match stats")


func _check_options_model() -> void:
	print("game options model:")
	var s := GameOptionsModel.make_default_settings("vs")
	_expect(s.mode == "vs" and s.game_mode == "deathmatch" and not s.teams and s.has("goal_seed"), "a new versus lobby: deathmatch, a goal seed")
	var team_mode := GameOptionsModel.make_game_modes(s).filter(func(m: Dictionary) -> bool: return bool(m.team_based))
	if not team_mode.is_empty():
		var t := GameOptionsModel.make_with_game_mode(s, str(team_mode[0].id))
		_expect(t.teams and LobbySettings.is_team_match(t) and t.member_teams == null if false else t.teams, "a team game mode turns teams on")
		_expect(GameOptionsModel.make_with_team_count(t, 99).team_count <= CatalogBridge.MAX_TEAMS, "the team count is clamped")
	var next := GameOptionsModel.make_with_map(s, 1)
	_expect(next.world_idx == 1 and next.map != s.map and next.goal_seed == s.goal_seed, "another map keeps the other keys (%s)" % next.map)
	_expect(GameOptionsModel.make_with_value(s, "ai", 7).ai == 7 and s.ai != 7, "a change returns new settings")
	_expect(GameOptionsModel.make_with_score_limit(s, 15).frag_limit == 15, "the deathmatch kill limit")
	var raid := GameOptionsModel.make_default_settings("extraction", true)
	_expect(raid.mode == "extraction" and raid.solo and EconomyRules.make_mode_key(raid) == "extraction", "a solo raid still earns (extraction)")
	_expect(EconomyRules.make_mode_key(GameOptionsModel.make_default_settings("vs", true)) == "solo", "a skirmish earns nothing (solo)")
	_expect(EconomyRules.make_mode_key(GameOptionsModel.make_default_settings("campaign")) == "campaign.coop", "a LAN campaign pays as co-op")
	_expect(GameOptionsModel.make_with_mode(s, "coop").mode == "coop", "the host may switch the mode")


func _check_readonly_options() -> void:
	print("read-only options:")
	var rows := GameOptionsPanel.make_readonly_rows(GameOptionsModel.make_default_settings("vs"))
	var labels := rows.map(func(r: Array) -> String: return str(r[0]))
	_expect(labels.has("Game mode") and labels.has("Map") and not labels.has("Mode") and labels.has("Kill limit"), "a client reads the one game mode, the map and limits (%s)" % [labels])
	var panel := GameOptionsPanel.new()
	add_child(panel)
	panel.refresh(GameOptionsModel.make_default_settings("vs"), false)
	_expect(panel.find_children("*", "OptionButton", true, false).is_empty() and panel.find_children("*", "HSlider", true, false).is_empty(),
		"for a non-host the options are text, no control")
	panel.queue_free()


func _check_revalidate() -> void:
	print("ready revalidation:")
	Net.host_offline()
	var s := GameOptionsModel.make_default_settings("vs")
	var slot := CharacterSlot.make_default(0)
	var other_pack := "tribes2" if slot.pack == "tribes" else "tribes"
	if not Assets.has_pack(other_pack) or Net.max_players < 2:
		Net.leave()
		return
	_add_fake(FAKE_PEER, "Kira", 0, true)
	Net.roster[FAKE_PEER]["slot"] = slot.make_roster_snapshot()
	var same := MatchFlow.apply_revalidate_ready(s, s.merged({"ai": 9}, true))
	_expect(same.is_empty() and bool(Net.roster[FAKE_PEER].ready), "unrelated option changes keep Ready")
	var moved := MatchFlow.apply_revalidate_ready(s.merged({"infantry_pack": slot.pack}, true), s.merged({"infantry_pack": other_pack}, true))
	_expect(moved == [FAKE_PEER] and not bool(Net.roster[FAKE_PEER].ready), "an infantry game the build does not fit clears Ready")
	Net.leave()


func _check_results_award() -> void:
	print("results award:")
	var summary := {"mode": "vs", "seconds": 300.0, "winner": "Red", "pilots": [{"name": "Me", "team": 0, "kills": 5, "deaths": 1, "player": true}]}
	var award := ResultsAward.make(summary, {"mode": "vs", "game_mode": "deathmatch"}, "Me", [])
	_expect(int(award.total) > 0 and not (award.lines as Array).is_empty(), "a versus match pays (%d cr)" % int(award.total))
	_expect(ResultsAward.make(summary.merged({"mode": "extraction"}, true), {"mode": "extraction"}, "Me", []).is_empty(), "a raid is paid on extraction, not here")
	_expect(ResultsAward.make(summary, {"mode": "vs", "solo": true}, "Me", []).is_empty(), "a solo match makes no award")
	_expect(ResultsAward.make(summary, {"mode": "vs", "game_mode": "deathmatch"}, "Nobody", []).is_empty(), "a pilot with no row gets no award")
	var net := EconomyNet.new()
	add_child(net)
	net.authority = LocalProfileAuthority.new("AwardPilot")
	var before := OperatorProfile.load_for("AwardPilot").credits
	net.send_award(Net.my_id(), award)
	_expect(OperatorProfile.load_for("AwardPilot").credits == before + int(award.total), "the award is paid into the pilot's operator profile")
	net.queue_free()


# ------------------------------------------------------------------ the screen, every mode

func _check_modes() -> void:
	print("every mode builds:")
	for kind in [GameOptionsModel.KIND_VERSUS, GameOptionsModel.KIND_COOP, GameOptionsModel.KIND_EXTRACTION]:
		var lobby := await _open_lobby(kind)
		_expect(lobby != null and lobby.carousel.card_count() >= 1, "%s: the lobby builds with your card (%d cards)" % [kind, lobby.carousel.card_count()])
		_expect(lobby.options.controls.has("map") and lobby.options.controls.has("options"), "%s: the host edits map and options" % kind)
		_expect(lobby.goals.visible and not lobby.briefing.visible, "%s: Option A, the goals" % kind)
		_expect(lobby.primary_button.text == "Start match" and not lobby.primary_button.disabled, "%s: the host may start alone" % kind)
		_expect(lobby.setup.setup_button.is_visible_in_tree(), "%s: the Operator Setup button" % kind)
		await _shot("lobby_%s_desktop" % kind)
		lobby.carousel.toggle_mode()
		await _shot("lobby_%s_vehicles" % kind)
		_expect(lobby.carousel.ring.mode == "vehicle" and lobby.carousel.ring.light != null, "%s: the toggle switches the ring to vehicles, one spotlight" % kind)
		lobby.carousel.toggle_mode()
	var teams := await _open_lobby(GameOptionsModel.KIND_VERSUS, false, GameOptionsModel.make_with_game_mode(GameOptionsModel.make_default_settings("vs"),
		"team_deathmatch") if _has_game_mode("team_deathmatch") else {})
	if LobbySettings.is_team_match(Net.settings):
		_add_fake(FAKE_PEER, "Kira", 0, true)
		Net.roster[1].team = 0
		Net.roster_changed.emit()
		await _frames()
		_expect(teams.options.controls.has("assign") and teams.options.controls.has("teams"), "a team match: Assign all and Adjust teams for the host")
		teams.carousel.toggle_mode()
		await _shot("lobby_team_vs_vehicles")
		teams.carousel.toggle_mode()
		_expect(teams.carousel.card_count() >= 2, "a team match: the squad on cards (%d)" % teams.carousel.card_count())
		await _shot("lobby_team_vs_desktop")
		teams.carousel.step(1)
		await _frames(30)
		_expect(teams.carousel.ring.focus == 1 and teams.carousel.ring.models.size() >= 2, "stepping turns the ring to the next member (%d platforms)" % teams.carousel.ring.models.size())
		await _shot("lobby_team_vs_second")
		var ring: TeamRing = teams.carousel.ring
		var n := ring.member_count()
		teams.carousel.step(-teams.carousel.focus_index)   # back to the first member
		await _frames(30)
		teams.carousel.step(-1)
		await _frames(30)
		_expect(n < 2 or ring.focus == n - 1, "the ring wraps: before the first member comes the last (focus %d of %d)" % [ring.focus, n])
		teams.carousel.step(1)
		await _frames(30)
		_expect(ring.focus == 0, "... and after the last comes the first again")
		_expect(n < 2 or (not teams.carousel.prev_button.disabled and not teams.carousel.next_button.disabled and teams.carousel.prev_button.visible),
			"with %d members the arrows are shown and never greyed out" % n)
		for ring_mode in ["infantry", "vehicle"]:
			teams.carousel.apply_mode(ring_mode)
			await _frames(3)
			var shown := range(n).filter(func(i: int) -> bool: return ring.platforms[i].visible)
			var empty := shown.filter(func(i: int) -> bool: return ring.make_model_height(i) <= 0.0)
			_expect(shown.size() == mini(n, 3) and empty.is_empty(), "%s mode: the focus and both neighbours stand on their platforms (shown %s, empty %s)" % [ring_mode, shown, empty])
			if _windowed:   # the ring camera needs a window
				var facing := shown.map(func(i: int) -> float: return ring.make_facing_error(i))
				_expect(facing.all(func(e: float) -> bool: return e >= 0.0 and e <= 10.0), "%s mode: every shown model faces the camera (degrees off: %s)" % [ring_mode, facing.map(func(e: float) -> String: return "%.1f" % e)])
			_expect(n < 4 or (ring.platforms[n - 1].visible and ring.platforms[1].visible), "%s mode: the first member's neighbours are the last and the second" % ring_mode)
			if _windowed:
				var centre := ring.camera.unproject_position(ring.platforms[ring.focus].global_position + Vector3(0, 1.0, 0))
				var width := float(ring.viewport.size.x)
				_expect(absf(centre.x - width * 0.5) <= width * 0.05, "%s mode: the focused member stands in the stage's centre (%.0f of %.0f px)" % [ring_mode, centre.x, width])
				var left := ring.camera.unproject_position(ring.platforms[posmod(ring.focus - 1, n)].global_position)
				var right := ring.camera.unproject_position(ring.platforms[posmod(ring.focus + 1, n)].global_position)
				_expect(n < 3 or absf((width * 0.5 - left.x) - (right.x - width * 0.5)) <= width * 0.05, "%s mode: the neighbours stand symmetric (%.0f / %.0f px)" % [ring_mode, left.x, right.x])
		teams.carousel.apply_mode("infantry")
		await _frames(20)
		if _windowed:
			await _check_orbit(teams.carousel)
		else:
			print("  (headless: ring camera, facing and orbit assertions skipped; run windowed)")
		_expect(teams.carousel.prev_button.get_parent() == teams.carousel.ring and teams.carousel.next_button.focus_mode == Control.FOCUS_ALL,
			"the turn arrows sit on the stage and take focus")
	var skirmish := await _open_lobby(GameOptionsModel.KIND_VERSUS, true, {InfantryBots.CONFIG_KEY: 3})
	_expect(not skirmish.goals.visible and not skirmish.briefing.visible, "a skirmish: no task list")
	_expect(skirmish.carousel.card_count() > 1, "a skirmish: the bots are cards (%d)" % skirmish.carousel.card_count())
	await _shot("lobby_skirmish_desktop")
	var campaign := await _open_lobby(GameOptionsModel.KIND_CAMPAIGN, true)
	_expect(campaign.briefing.visible and not campaign.goals.visible, "a campaign: Option B, the briefing")
	_expect(campaign.briefing.heading.text != "" and campaign.briefing.text_label.text != "", "the briefing shows the mission (%s)" % campaign.briefing.heading.text)
	_expect(campaign.options.controls.has("save") and campaign.options.controls.has("hangar"), "a campaign: Save game and Hangar for the host")
	_expect(campaign.herc_row.picker != null, "a campaign: the garage Herc picker")
	_expect(campaign.primary_button.text == "Start mission", "a campaign starts a mission")
	await _shot("lobby_campaign_desktop")
	var coop := await _open_lobby(GameOptionsModel.KIND_CAMPAIGN)
	_expect(coop.briefing.visible and LobbyWingmen.make_cards(Net.settings).is_empty(), "a co-op campaign: briefing, no wingmen")


# ------------------------------------------------------------------ the host's mode picker

## A hosted lobby (a real LAN host): the one Game mode picker is the host's way to every mode. It lists every versus game mode, co-op,
## the co-op campaign, the raid and the training pages; picking one shows that mode's options (map list filtered to the maps that
## can play it, campaign buttons, Game options sheet rows) and leaves a lobby the host can start. A mode no map offers is disabled
## and says why.
func _check_mode_picker() -> void:
	print("the host's game mode picker:")
	_close_lobby()
	Net.password = ""
	var err := Net.host()
	if err != OK:
		_expect(false, "the LAN host opened (port %d, error %d)" % [Net.GAME_PORT, err])
		return
	Net.set_settings(GameOptionsModel.make_default_settings(GameOptionsModel.KIND_VERSUS))
	Net.set_my_info("team", Net.make_join_team())
	Net.set_my_info("vehicle", MatchFlow.DEFAULT_VEHICLE)
	_launcher = load(LAUNCHER).instantiate()
	get_tree().root.add_child(_launcher)
	await _frames()
	var lobby := _launcher.go("lobby", {}) as LobbyScreen
	await _frames()
	var picker := lobby.options.controls.get("game_mode") as OptionButton
	var choices := GameOptionsModel.make_mode_choices()
	var ids := choices.map(func(c: Dictionary) -> String: return str(c.id))
	_expect(picker != null and not lobby.options.controls.has("mode"), "one Game mode picker (no second Mode picker)")
	var missing := ids.filter(func(id: String) -> bool: return lobby.options.find_choice_item(id) < 0)
	_expect(missing.is_empty(), "the picker lists all %d choices (%s missing)" % [ids.size(), missing])
	for id in ["vs:deathmatch", "vs:team_deathmatch", "vs:ctf", "coop", "campaign", "extraction"]:
		_expect(ids.has(id), "the picker lists '%s'" % id)
	var raid := GameOptionsModel.find_mode_choice("extraction")
	_expect(bool(raid.enabled) == ExtractionRules.is_available() and (raid.enabled or str(raid.reason) != ""),
		"the extraction raid is %s" % ["pickable (soldiers installed)" if raid.enabled else "disabled with a reason: %s" % raid.reason])
	var groups := []
	for c in choices:
		if not groups.has(c.group):
			groups.append(c.group)
	_expect(groups.slice(0, 4) == ["Versus", "Co-op", "Campaign", "Extraction"], "the choices are grouped Versus / Co-op / Campaign / Extraction (%s)" % [groups])
	_check_disabled_choices()
	var enabled_kinds := {}
	for c in choices:
		var at := lobby.options.find_choice_item(str(c.id))
		picker = lobby.options.controls.get("game_mode") as OptionButton
		if not bool(c.enabled):
			_expect(picker.is_item_disabled(at) and picker.get_item_text(at).contains(str(c.reason)) and str(c.reason) != "",
				"'%s' is disabled and says why: %s" % [c.id, c.reason])
			var before := Net.settings.duplicate(true)
			picker.item_selected.emit(at)
			await _frames()
			_expect(Net.settings == before, "'%s': picking a disabled mode changes nothing" % c.id)
			continue
		if str(c.kind) == GameOptionsModel.TRAINING_KIND:
			continue
		picker.select(at)
		picker.item_selected.emit(at)
		await _frames()
		var kind := str(c.kind)
		enabled_kinds[kind] = true
		_expect(GameOptionsModel.make_choice_id(Net.settings) == str(c.id), "%s: picked (%s)" % [c.id, GameOptionsModel.make_choice_id(Net.settings)])
		_expect(str(Net.settings.mode) == kind, "%s: the lobby mode is %s" % [c.id, kind])
		if kind == GameOptionsModel.KIND_CAMPAIGN:
			_expect(not lobby.options.controls.has("map"), "%s: no map picker" % c.id)
		else:
			var map := lobby.options.controls.map as MapPicker
			_expect(map.shown_indices() == c.maps, "%s: the map list is exactly the %d maps that can play it (%d shown)" % [c.id, c.maps.size(), map.shown_indices().size()])
			_expect(c.maps.has(int(Net.settings.world_idx)) and map.selected_index() == int(Net.settings.world_idx), "%s: the chosen map fits the mode" % c.id)
			var mode_ids := GameModes.make_mode_ids_for_map(MapPicker.make_entries()[int(Net.settings.world_idx)])
			_expect(mode_ids.has("coop_ai" if kind == "coop" else str(c.get("game_mode", kind))), "%s: the map really offers the mode (%s)" % [c.id, mode_ids])
		_expect(lobby.options.controls.has("options"), "%s: Game options..." % c.id)
		_expect(lobby.options.controls.has("save") == (kind == "campaign"), "%s: Save game / Hangar only for the campaign" % c.id)
		_expect((kind == "campaign") == Session.has_campaign(), "%s: the campaign session %s" % [c.id, "runs" if kind == "campaign" else "is set aside"])
		_expect((kind == "campaign") == lobby.briefing.visible, "%s: the briefing %s" % [c.id, "shows" if kind == "campaign" else "is hidden"])
		if kind == "vs":
			_expect(str(Net.settings.game_mode) == str(c.game_mode), "%s: the game mode is set" % c.id)
			_expect(lobby.options.controls.has("teams") == LobbySettings.is_team_match(Net.settings), "%s: team controls match its teams" % c.id)
			_expect(str(MatchFlow.make_match_config(Net.settings, Packs.pilotable()).get("game_mode", "")) == str(c.game_mode), "%s: it reaches the battle config" % c.id)
		await _check_sheet_rows(lobby, kind)
		if LobbySettings.is_team_match(Net.settings):
			lobby.options.assign_all_requested.emit()
			await _frames()
		_expect(MatchFlow.make_start_block_reason() == "" or Net.make_unready_names().size() > 0, "%s: nothing but readiness blocks the start (%s)" % [c.id, MatchFlow.make_start_block_reason()])
		if kind != "vs" or str(c.game_mode) in ["deathmatch", "team_deathmatch", "ctf"]:
			await _shot("lobby_picker_%s" % str(c.id).replace(":", "_"))
	for kind in ["vs", "coop", "campaign"]:
		_expect(enabled_kinds.has(kind), "%s was pickable" % kind)
	await _check_map_kept(lobby)
	await _check_open_picker_shot(lobby)
	_close_lobby()


## A lobby with no Tribes map, no arena and no soldiers: those modes stay listed, disabled, with the reason in their text.
func _check_disabled_choices() -> void:
	var maps := {"deathmatch": [0], "team_deathmatch": [0], "coop_ai": [0]}
	var choices := GameOptionsModel.make_choices_from(maps, false)
	var by_id := {}
	for c in choices:
		by_id[str(c.id)] = c
	_expect(bool(by_id["vs:deathmatch"].enabled) and bool(by_id.coop.enabled) and bool(by_id.campaign.enabled), "modes with a map stay enabled")
	_expect(not by_id["vs:ctf"].enabled and GameOptionsPanel.make_choice_text(by_id["vs:ctf"]) == "Capture the Flag  (needs a Tribes map)", "CTF without a Tribes map: '%s'" % GameOptionsPanel.make_choice_text(by_id["vs:ctf"]))
	_expect(not by_id.extraction.enabled and GameOptionsPanel.make_choice_text(by_id.extraction).contains("needs Tribes 2"), "the raid without soldiers: '%s'" % GameOptionsPanel.make_choice_text(by_id.extraction))
	_expect(not by_id["vs:duel"].enabled and str(by_id["vs:duel"].reason).contains("Battledrome"), "the arena duel without an arena says so")


## The map choice is kept when it still fits the next mode, and moves to a fitting one when it does not.
func _check_map_kept(lobby: LobbyScreen) -> void:
	var dm := GameOptionsModel.find_mode_choice("vs:deathmatch")
	var co := GameOptionsModel.find_mode_choice("coop")
	var picker := lobby.options.controls.get("game_mode") as OptionButton
	picker.item_selected.emit(lobby.options.find_choice_item("vs:deathmatch"))
	await _frames()
	var both: Array = dm.maps.filter(func(i: int) -> bool: return co.maps.has(i))
	if both.is_empty():
		return
	Net.set_settings(GameOptionsModel.make_with_map(Net.settings, int(both.back())))
	await _frames()
	picker = lobby.options.controls.get("game_mode") as OptionButton
	picker.item_selected.emit(lobby.options.find_choice_item("coop"))
	await _frames()
	_expect(int(Net.settings.world_idx) == int(both.back()), "switching to co-op keeps a map that still fits")
	var raid := GameOptionsModel.find_mode_choice("extraction")
	if bool(raid.enabled) and not raid.maps.has(int(both.back())):
		picker = lobby.options.controls.get("game_mode") as OptionButton
		picker.item_selected.emit(lobby.options.find_choice_item("extraction"))
		await _frames()
		_expect(raid.maps.has(int(Net.settings.world_idx)), "switching to the raid moves to an extraction map (%s)" % Net.settings.map)


## A windowed run opens the picker's pop-up and renders it (looked at by eye).
func _check_open_picker_shot(lobby: LobbyScreen) -> void:
	if not _windowed or _shots == "":
		return
	var picker := lobby.options.controls.get("game_mode") as OptionButton
	picker.show_popup()
	await _frames(4)
	await _shot("lobby_game_mode_picker_open")
	picker.get_popup().hide()
	await _frames()


## The Game options sheet of the lobby's mode shows the rows that mode uses (opponents and bots cap, a raid's relations ...).
func _check_sheet_rows(lobby: LobbyScreen, kind: String) -> void:
	lobby.sheets.open_options()
	await _frames()
	var sheet: GameOptionsSheet = lobby.get_children().filter(func(c: Node) -> bool: return c is GameOptionsSheet).back()
	var campaign := kind == "campaign"
	_expect(sheet.rows.ai.visible != campaign and sheet.rows.max_bots.visible != campaign, "%s: opponents and Max bots %s" % [kind, "hidden" if campaign else "shown"])
	_expect(sheet.rows.relations.visible == (kind == "extraction"), "%s: Faction relations only for a raid" % kind)
	_expect(sheet.rows.squads.visible == (kind == "extraction"), "%s: Squads only for a raid" % kind)
	_expect(sheet.rows.score.visible == (kind in ["vs", "coop"]), "%s: the kill / score limit" % kind)
	sheet.close()
	await _frames()


## Right-drag orbits the view round the focused member, the light follows to the viewer's side, a turn of the ring glides
## the view home, where the model faces the camera again.
func _check_orbit(carousel: TeamCarousel) -> void:
	var ring := carousel.ring
	var home := ring.camera.global_position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_RIGHT
	press.pressed = true
	ring._gui_input(press)
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_RIGHT
	drag.relative = Vector2(-200, 30)
	ring._gui_input(drag)
	await _frames(3)
	var eye := ring.camera.global_position
	_expect(eye.distance_to(home) > 1.0 and absf(ring.orbit_yaw) > 1.0, "right-drag orbits the view (yaw %.2f, camera moved %.1f m)" % [ring.orbit_yaw, eye.distance_to(home)])
	var focus_at := ring.platforms[ring.focus].global_position
	var to_light := Vector2(ring.light.global_position.x - focus_at.x, ring.light.global_position.z - focus_at.z)
	var to_eye := Vector2(eye.x - focus_at.x, eye.z - focus_at.z)
	_expect(to_light.normalized().dot(to_eye.normalized()) > 0.95, "the spotlight follows the view to the viewer's side")
	ring.orbit(0.0, 5.0)
	_expect(ring.orbit_pitch <= TeamRing.ORBIT_PITCH_MAX, "the pitch is clamped (%.2f)" % ring.orbit_pitch)
	ring.orbit(0.0, -5.0)
	ring.orbit(0.0, 0.25)
	await _frames(2)
	await _shot("lobby_team_vs_orbit")
	carousel.step(1)
	await _frames(40)
	_expect(is_zero_approx(ring.orbit_yaw) and ring.camera.global_position.distance_to(home) < 0.05, "a turn of the ring glides the view home")
	_expect(ring.make_facing_error(ring.focus) <= 10.0, "... where the focused model faces the camera (%.1f degrees off)" % ring.make_facing_error(ring.focus))
	ring.orbit(1.0, 0.0)
	var twice := InputEventMouseButton.new()
	twice.button_index = MOUSE_BUTTON_RIGHT
	twice.pressed = true
	twice.double_click = true
	ring._gui_input(twice)
	await _frames(40)
	_expect(is_zero_approx(ring.orbit_yaw), "a right double-click resets the view")
	ring.orbit(1.0, 0.0)
	carousel.toggle_mode()
	await _frames(40)
	_expect(is_zero_approx(ring.orbit_yaw), "switching infantry / vehicles resets the view")
	carousel.toggle_mode()
	carousel.step(-1)
	await _frames(40)


func _has_game_mode(id: String) -> bool:
	return GameOptionsModel.make_game_modes(GameOptionsModel.make_default_settings("vs")).any(func(m: Dictionary) -> bool: return str(m.id) == id)


func _check_client_view() -> void:
	print("a client's view:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	lobby.options.refresh(Net.settings, false)
	await _frames()
	_expect(lobby.options.find_children("*", "OptionButton", true, false).is_empty(), "options are read-only text for a client")
	_expect(_text_of(lobby.options).contains("Kill limit"), "the client still reads the settings")
	lobby.options.refresh(Net.settings, true)


# ------------------------------------------------------------------ 64 pilots

func _check_big_lobby() -> void:
	print("64 pilots:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	var nodes_before := get_tree().get_node_count()
	for i in BIG_ROSTER - 1:
		_add_fake(1000 + i, "Pilot %02d" % i, 0, i % 3 == 0)
	var t0 := Time.get_ticks_msec()
	Net.roster_changed.emit()
	await _frames(2)
	var took := Time.get_ticks_msec() - t0
	var nodes_after := get_tree().get_node_count()
	_expect(lobby.list.row_count() == BIG_ROSTER - 1 or lobby.carousel.card_count() + lobby.list.row_count() == BIG_ROSTER,
		"every pilot is on a card or in the list (%d cards, %d rows)" % [lobby.carousel.card_count(), lobby.list.row_count()])
	_expect(lobby.carousel.card_count() <= LobbyModel.MAX_SQUAD_CARDS + 1, "at most %d cards" % LobbyModel.MAX_SQUAD_CARDS)
	_expect(nodes_after - nodes_before < MAX_BIG_NODES, "node count stays bounded (%d new nodes)" % (nodes_after - nodes_before))
	_expect(took < MAX_BIG_REFRESH_MSEC, "a 64 pilot roster change refreshes in %d ms" % took)
	var t1 := Time.get_ticks_msec()
	for i in 20:
		Net.roster[1000 + i % 40].ready = not bool(Net.roster[1000 + i % 40].ready)
		Net.roster_changed.emit()
	var per_change := (Time.get_ticks_msec() - t1) / 20.0
	_expect(per_change < MAX_BIG_REFRESH_MSEC / 4.0, "a ready change costs %.1f ms" % per_change)
	lobby.list.filter.text = "Pilot 07"
	lobby.list.filter.text_changed.emit("Pilot 07")
	await _frames()
	_expect(lobby.list.row_count() == 1, "the filter box narrows the list")
	lobby.list.filter.text = ""
	lobby.list.filter.text_changed.emit("")
	await _shot("lobby_64_desktop")


# ------------------------------------------------------------------ narrow width, tabs

func _check_narrow() -> void:
	print("narrow width:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	_add_fake(FAKE_PEER, "Kira", 0, true)
	_add_fake(FAKE_PEER + 1, "Dune", 0, false)
	_add_fake(FAKE_PEER + 2, "Ash", 0, true)
	Net.settings = Net.settings.merged({"mode": "coop"}, true)
	Net.roster_changed.emit()
	lobby.set_anchors_preset(Control.PRESET_TOP_LEFT)
	lobby.size = Vector2(NARROW_SIZE)
	await _frames()
	_expect(lobby.layout.narrow, "under 900 px the lobby uses tabs")
	_expect(lobby.layout.tab_buttons.squad.is_visible_in_tree() and lobby.layout.tab == "squad", "the Squad tab is the first view")
	_expect(lobby.carousel.visible_count == 1, "one card at a time")
	lobby.layout.apply_tab("options")
	await _frames()
	_expect(lobby.options.is_visible_in_tree() and not lobby.carousel.is_visible_in_tree(), "the Options tab shows only the options")
	await _shot("lobby_vs_narrow_options")
	lobby.layout.apply_tab("tasks")
	await _frames()
	_expect(lobby.goals.is_visible_in_tree(), "the Tasks tab shows the goals")
	await _shot("lobby_vs_narrow_tasks")
	lobby.layout.apply_tab("chat")
	await _frames()
	_expect(lobby.chat.is_visible_in_tree(), "the Chat tab shows the chat")
	lobby.layout.apply_tab("squad")
	await _frames()
	lobby.carousel.step(1)
	await _frames(30)
	await _shot("lobby_vs_narrow_squad")
	lobby.carousel.toggle_mode()
	await _shot("lobby_vs_narrow_squad_vehicles")
	lobby.carousel.toggle_mode()
	await _send_action("menu_tab_next")
	_expect(lobby.layout.tab == "squad" or lobby.layout.tab == "tasks", "LB / RB step the tabs when focus is not on the carousel (%s)" % lobby.layout.tab)
	lobby.size = Vector2(DESKTOP_SIZE)
	await _frames()
	_expect(not lobby.layout.narrow and lobby.carousel.ring.size.y > 0, "wide again: columns and the ring")


# ------------------------------------------------------------------ ready warning, goal limit

func _check_ready_warning() -> void:
	print("ready warning:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	_add_fake(FAKE_PEER, "Kira", 0, true)
	var profile := lobby.profile
	var other_pack := "tribes2" if profile.make_active_slot().pack == "tribes" else "tribes"
	Net.roster_changed.emit()
	await _frames()
	var started := [false]
	_expect(LobbyReadyFlow.ask(lobby, [], func() -> void: started[0] = true, func() -> void: pass) == null and started[0], "an allowed build goes on without a question")
	if not Assets.has_pack(other_pack):
		return
	Net.set_settings(Net.settings.merged({"infantry_pack": other_pack}, true))
	await _frames()
	var blocks := LobbyAnnouncer.make_blocks(Net.settings, lobby.profile)
	_expect(not blocks.is_empty(), "a build for the other infantry game has blocks (%s)" % [blocks.map(func(b): return b.text)])
	var dialog := LobbyReadyFlow.ask(lobby, blocks, func() -> void: pass, func() -> void: pass)
	await _frames()
	_expect(dialog != null and _text_of(dialog).contains("not allowed here") and _find_button(dialog, "Open Operator Setup") != null
		and _find_button(dialog, "Ready anyway") != null, "the warning lists the parts and offers both answers")
	if dialog != null:
		await _send_action("menu_back")
		_expect(not is_instance_valid(dialog) or dialog.is_queued_for_deletion(), "menu_back closes the warning")


func _check_goal_limit() -> void:
	print("goal limit:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_COOP)
	var ids := lobby.goals.boxes.keys()
	_expect(ids.size() >= 4, "the board offers %d goals" % ids.size())
	for id in ids.slice(0, 3):
		(lobby.goals.boxes[id] as CheckBox).button_pressed = true
	await _frames()
	_expect(Net.roster[1].goals.size() == 3, "three goals picked (%s)" % [Net.roster[1].get("goals")])
	var fourth: CheckBox = lobby.goals.boxes[ids[3]]
	_expect(fourth.disabled, "the fourth box is disabled")
	(lobby.goals.boxes[ids[0]] as CheckBox).button_pressed = false
	await _frames()
	_expect(Net.roster[1].goals.size() == 2 and not fourth.disabled, "dropping one frees a pick")
	_add_fake(FAKE_PEER, "Kira", 0, true)
	Net.roster[FAKE_PEER]["goals"] = [ids[1]]
	Net.roster_changed.emit()
	await _frames()
	_expect(_text_of(lobby.goals).contains("Kira:"), "the teammates' panel shows Kira's pick, read only")
	_expect(lobby.goals.reroll_button.visible, "the host has Reroll")


# ------------------------------------------------------------------ keyboard and gamepad

func _check_input_walk() -> void:
	print("keyboard and gamepad:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	lobby.size = Vector2(DESKTOP_SIZE)
	for i in 3:
		_add_fake(FAKE_PEER + i, "Pilot %d" % i, 0, true)
	Net.roster_changed.emit()
	await _frames()
	_expect(_focus() != null and lobby.is_ancestor_of(_focus()), "focus starts inside the lobby (%s)" % (_focus().name if _focus() else "none"))
	var first := _focus()
	await _send_action("menu_zone_next")
	_expect(_focus() != first and lobby.is_ancestor_of(_focus()), "menu_zone_next jumps to the next zone")
	await _send_action("menu_zone_prev")
	_expect(lobby.setup.is_ancestor_of(_focus()), "menu_zone_prev jumps back to the zone before")
	var seen := {}
	for i in 14:
		await _send_action("menu_zone_next")
		seen[_focus()] = true
	_expect(seen.size() >= 5, "the zones are reachable (%d distinct stops)" % seen.size())
	var before := lobby.carousel.focus_index
	await _send_action("menu_tab_next")
	_expect(lobby.carousel.focus_index == before + 1 or lobby.carousel.card_count() < 2, "menu_tab_next flips the carousel")
	await _send_action("menu_tab_prev")
	_expect(lobby.carousel.focus_index == before, "menu_tab_prev flips it back")
	var reach := {}
	lobby.setup.setup_button.grab_focus()
	for i in 80:
		reach[_focus()] = true
		await _send_action("ui_down")
	_expect(reach.size() >= 12, "ui_down walks the controls (%d reached)" % reach.size())
	lobby.setup.setup_button.grab_focus()
	await _send_action("ui_accept")
	_expect(lobby.has_modal(), "ui_accept on Operator Setup opens the screen")
	await _send_action("menu_back")
	_expect(not lobby.has_modal(), "menu_back closes it")
	var pressed := {"primary": false, "back": false}
	for pair in [[lobby.primary_button, "primary"], [lobby.back_button, "back"]]:
		for c in (pair[0] as Button).pressed.get_connections():
			(pair[0] as Button).pressed.disconnect(c.callable)
		(pair[0] as Button).pressed.connect(func() -> void: pressed[pair[1]] = true)
	await _send_action("menu_primary")
	_expect(pressed.primary, "menu_primary presses the footer's primary action")
	await _send_action("menu_back")
	_expect(pressed.back, "menu_back presses Leave")


func _check_chat() -> void:
	print("chat:")
	var lobby := await _open_lobby(GameOptionsModel.KIND_VERSUS)
	await _frames()
	lobby.chat.line_edit.text = "hello squad"
	lobby.chat.line_edit.text_submitted.emit("hello squad")
	await _frames()
	_expect(lobby.chat.log_view.get_parsed_text().contains("hello squad"), "a chat line shows in the strip")
	lobby.chat.line_edit.text = "/t only team"
	lobby.chat.line_edit.text_submitted.emit("/t only team")
	await _frames()
	_expect(lobby.chat.log_view.get_parsed_text().contains("only team"), "a team line shows too")
	_expect(lobby.chat.quick_button.get_popup().item_count > 0, "the quick chat menu has lines for a gamepad")


# ------------------------------------------------------------------ the results screen with credits

func _check_results_screen() -> void:
	print("results screen:")
	_close_lobby()
	var summary := {"mode": "vs", "headline": "RED WINS", "winner": "Red", "text": "", "seconds": 300.0, "campaign": false, "rematch": false,
		"pilots": [{"name": "Me", "vehicle": "Raptor", "team": 0, "kills": 5, "deaths": 1, "score": 4, "player": true}]}
	var award := ResultsAward.make(summary, {"mode": "vs", "game_mode": "deathmatch"}, "Me", [])
	var results := MatchResults.new()
	results.summary = summary
	results.award = award
	results.credits_after = 1234
	add_child(results)
	await _frames()
	var text := _text_of(results)
	_expect(text.contains("Credits earned") and text.contains("Total +") and text.contains("CR 1,234"), "the results screen lists the credits earned and the new balance")
	_expect(ResultsScreen.make_award_lines(award).size() == (award.lines as Array).size(), "one line per part of the award")
	await _shot("results_credits")
	results.queue_free()


# ------------------------------------------------------------------ campaign wingmen (open question O9)

## A single player Earthsiege campaign whose mission has two wingman slots: cards, the picker sheet, a pick that sticks.
func _check_wingmen() -> void:
	print("campaign wingmen:")
	_close_lobby()
	Net.host_offline()
	Session.start_campaign(0, false)
	var key := "%d|%s" % [Session.campaign.get_instance_id(), str(Session.campaign.current_mission())]
	Session.last_mission = {"groups": [{"members": [0, 1, 2]}], "texts": {"briefing": "Wingman test.", "objectives": []}}
	Session._mission_key = key
	Net.set_settings(GameOptionsModel.make_default_settings("campaign", true))
	_expect(LobbyWingmen.make_slot_count(Net.settings) == 2, "the mission offers two wingman slots (%d)" % LobbyWingmen.make_slot_count(Net.settings))
	var cards := LobbyWingmen.make_cards(Net.settings)
	_expect(cards.size() == 2 and cards[0].kind == "wingman" and cards[0].key == "wingman:0", "one wingman card per slot")
	_launcher = load(LAUNCHER).instantiate()
	get_tree().root.add_child(_launcher)
	await _frames()
	var lobby := _launcher.go("lobby", {}) as LobbyScreen
	await _frames()
	_expect(lobby.carousel.card_count() == 3 and lobby.carousel.card_for("wingman:1") != null, "the carousel: you and two wingmen (%d cards)" % lobby.carousel.card_count())
	lobby.carousel.card_edit.emit("wingman:0")
	await _frames()
	var sheet := lobby.get_children().filter(func(c: Node) -> bool: return c is WingmanSheet)
	_expect(sheet.size() == 1 and (sheet[0] as WingmanSheet).pickers.size() == 2, "the card opens the wingman sheet with a picker per slot")
	if sheet.size() == 1:
		var picker: OptionButton = (sheet[0] as WingmanSheet).pickers[0]
		var choices := LobbyWingmen.make_choices()
		if choices.size() > 1:
			picker.select(1)
			picker.item_selected.emit(1)
			await _frames()
			_expect(LobbyWingmen.make_herc_index(0) == int(choices[1].index), "a pick sticks: slot 1 flies garage Herc %d" % int(choices[1].index))
		await _send_action("menu_back")
		_expect(not lobby.has_modal(), "menu_back closes the sheet")
	_expect(Session.campaign_pack(Session.campaign) != "starsiege", "an Earthsiege campaign has garage wingmen, not locked squadmates")
	_close_lobby()
