extends Node
## Headless check of the playtest group D fixes (docs/PLAYTEST_2026-10-11.md): the library's Host / Join (D2), the
## lobby's ready gating (D3) and instructions (D4), saved player names (D5), the soldier choice (D6, D7), skins
## (D8), the Tribes 2 style theme (D9), the shape viewer's Back (D10), the objectives panel (D11) and the host
## screen's modes, team count and team list (D12, deathmatch by default). settings.json and the saves are backed
## up and restored (saved_campaign_guard).
##   godot --headless --audio-driver Dummy --path game res://tests/fix_d_check.tscn

const SavedGuard := preload("res://tests/saved_campaign_guard.gd")
const LAUNCHER := "res://launcher.tscn"
const LIBRARY := "res://library.tscn"
const VIEWER := "res://tools/shape_viewer.tscn"
const BATTLE := "res://games/es1/battle.tscn"
const FAKE_PEER := 4242
const SETTLE_FRAMES := 6

var _fails := 0
var _guard := SavedGuard.new()


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	get_tree().current_scene = null   # outlive the scene changes (shape viewer -> library)
	_guard.back_up()
	_check_theme()
	_check_profile_name()
	_check_lobby_settings()
	_check_join_team_and_ready()
	_check_skins()
	_check_kill_text()
	await _check_library_buttons()
	await _check_host_screen()
	await _check_lobby_gating()
	await _check_team_list()
	await _check_objectives_panel()
	await _check_objectives_placement()
	await _check_shape_viewer_back()
	_guard.restore()
	print("fix_d_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := SETTLE_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _all_text(root: Node) -> String:
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


func _open_launcher(meta := "") -> Launcher:
	var launcher: Launcher = load(LAUNCHER).instantiate()
	if meta != "":
		launcher.set_meta("start_mode", meta)
	get_tree().root.add_child(launcher)
	return launcher


# ------------------------------------------------------------------ D9 theme

func _check_theme() -> void:
	var t := ThemeDB.get_project_theme()
	for v in ["HudPanel", "HudTitle", "HudLine", "HudDoneLine", "SubtitleLabel", "ContentPanel", "TitleBar", "SectionLabel"]:
		_expect(t.is_type_variation(v, t.get_type_variation_base(v)) or t.get_type_variation_base(v) != "", "theme has variation %s" % v)
	var card := t.get_stylebox("panel", "PanelContainer") as StyleBoxFlat
	_expect(card != null and card.bg_color.a < 1.0, "panels are translucent (alpha %.2f)" % (card.bg_color.a if card else -1.0))
	_expect(t.get_stylebox("normal", "SectionLabel") is StyleBoxFlat, "section labels are header bars")


# ------------------------------------------------------------------ D5 names

func _check_profile_name() -> void:
	PlayerProfile.apply_name("  Tester  ")
	_expect(PlayerProfile.load_name() == "Tester" and Net.player_name == "Tester", "the player name is saved and used (%s)" % PlayerProfile.load_name())
	var saved := FileAccess.get_file_as_string(Assets.SETTINGS_FILE)
	_expect(saved.contains("Tester"), "the name is in settings.json")
	PlayerProfile.apply_name("")
	_expect(Net.player_name == PlayerProfile.DEFAULT_NAME, "an empty name falls back to %s" % PlayerProfile.DEFAULT_NAME)


# ------------------------------------------------------------------ D12 settings

func _check_lobby_settings() -> void:
	var modes := CatalogBridge.make_game_modes({})
	_expect(str(modes[0].id) == CatalogBridge.DEFAULT_GAME_MODE, "deathmatch is the first game mode")
	var dm := LobbySettings.make({"mode": "vs", "game_mode": modes[0]})
	_expect(not dm.teams and dm.get(LobbySettings.GAME_MODE_KEY) == "deathmatch", "versus defaults to a deathmatch without teams")
	var team_mode: Dictionary = modes.filter(func(m: Dictionary) -> bool: return bool(m.team_based))[0]
	var tm := LobbySettings.make({"mode": "vs", "game_mode": team_mode, "team_count": 3})
	_expect(tm.teams and LobbySettings.make_team_count(tm) == 3 and LobbySettings.is_team_match(tm), "a team game mode sets teams and the team count")
	var camp := LobbySettings.make({"mode": "campaign", InfantryBots.CONFIG_KEY: 5})
	_expect(int(camp[InfantryBots.CONFIG_KEY]) == 0, "a co-op campaign asks for no bots (missions field their own units)")
	var raid := LobbySettings.make({"mode": ExtractionRules.MODE, "relations": "all_hostile"})
	_expect(raid.get(LobbySettings.RELATIONS_KEY) == "all_hostile", "an extraction raid keeps the relation preset")
	var vs_cfg := MatchFlow.make_match_config(tm, Packs.pilotable())
	_expect(int(vs_cfg.get("team_count", 0)) == 3, "the battle config carries the team count")
	var bots := LobbySettings.make_planned_bots(tm.merged({InfantryBots.CONFIG_KEY: 6}, true))
	var teams := {}
	for b in bots:
		teams[int(b.team)] = true
	_expect(teams.size() == 3, "bots are dealt round the 3 teams (%s)" % [teams.keys()])
	var r := CatalogBridge.make_team_range(team_mode, {})
	_expect(r.x >= CatalogBridge.MIN_TEAMS and r.y <= CatalogBridge.MAX_TEAMS and r.x <= r.y, "team range within 2..4 (%s)" % r)


# ------------------------------------------------------------------ D3 ready / join teams

func _check_join_team_and_ready() -> void:
	var roster_before := Net.roster.duplicate(true)
	var settings_before := Net.settings.duplicate(true)
	Net.settings = {"mode": "vs", "teams": true, "team_count": 3}
	Net.roster = {1: {"name": "Host", "team": 0, "ready": false}, FAKE_PEER: {"name": "Late", "team": 1, "ready": false}}
	_expect(Net.make_join_team() == TeamAssignment.UNASSIGNED, "a new pilot of a team match joins unassigned")
	Net.roster[1].team = TeamAssignment.UNASSIGNED
	_expect(MatchFlow.make_start_block_reason().begins_with("No team yet: Host"), "the start is blocked while a pilot has no team")
	var placed := TeamAssignment.make_assign_all(Net.roster, Net.settings)
	_expect(placed.size() == 1 and int(placed[1]) in [0, 2], "Assign all puts the host on a smallest team (%s)" % [placed])
	Net.roster[1].team = int(placed[1])
	var many := {}
	for i in 7:
		many[100 + i] = {"name": "P%d" % i, "team": TeamAssignment.UNASSIGNED}
	var dealt := TeamAssignment.make_assign_all(many, {"mode": "vs", "teams": true, "team_count": 3, InfantryBots.CONFIG_KEY: 2})
	var sizes := [0, 0, 0]
	for peer in dealt:
		sizes[int(dealt[peer])] += 1
	sizes[0] += 1
	sizes[1] += 1   # the two bots
	_expect(sizes.max() - sizes.min() <= 1, "Assign all balances the teams with the bots counted (%s)" % [sizes])
	_expect(Array(Net.make_unready_names()) == ["Late"], "the pilots who are not ready are named (the host is never waited for)")
	_expect(MatchFlow.make_start_block_reason().contains("Late"), "the start is blocked while Late is not ready")
	Net.roster[FAKE_PEER].ready = true
	_expect(MatchFlow.make_start_block_reason() == "", "everybody ready: the host may start")
	Net.roster = roster_before
	Net.settings = settings_before


# ------------------------------------------------------------------ D8 skins

func _check_skins() -> void:
	if not Assets.has_pack("tribes2"):
		print("skip  skins (Tribes 2 not installed)")
		return
	var choices := SkinCatalog.make_skin_choices("tribes2:light_male")
	_expect(choices.size() > 1 and str(choices[0].id) == "", "Tribes 2 light armour has skins after the default (%d)" % choices.size())
	if choices.size() < 2:
		return
	var overrides := SkinCatalog.make_texture_overrides("tribes2:light_male", str(choices[1].id))
	_expect(not overrides.is_empty(), "a skin names the textures it replaces")
	var inst := ShapeInstance.new()
	inst.texture_overrides = overrides
	add_child(inst)
	inst.build(Assets.shape("tribes2:light_male"))
	var skinned := 0
	for i in (inst.shape.get("materials", []) as Array).size():
		var mat := inst.call("_override_material", i) as StandardMaterial3D
		if mat != null and mat.albedo_texture != null:
			skinned += 1
	_expect(skinned > 0, "the skin replaces textured materials (%d)" % skinned)
	inst.queue_free()
	if Assets.has_pack("starsiege"):
		var herc_skins := SkinCatalog.make_vehicle_skin_choices("starsiege:tr_apoc")
		_expect(herc_skins.size() > 1, "a Starsiege Herc offers skins (%d)" % herc_skins.size())
	PlayerProfile.apply_herc_skin("starsiege:tr_apoc", "desert")
	_expect(PlayerProfile.load_herc_skin("starsiege:tr_apoc") == "desert", "a Herc skin is saved per Herc")
	var fields := PlayerProfile.make_roster_fields("tribes2", "starsiege:tr_apoc")
	_expect(fields.has(PlayerProfile.ARMOR_KEY) and fields[PlayerProfile.HERC_SKIN_KEY] == "desert", "the roster fields carry armour and Herc skin")


# ------------------------------------------------------------------ kill messages (KillText)

func _make_herc(vehicle_id: String, display_name: String) -> Herc:
	var h := Herc.new()
	h.vehicle_id = vehicle_id
	h.def = Packs.vehicle(vehicle_id)
	h.display_name = display_name
	return h


func _check_kill_text() -> void:
	var ace := _make_herc("es1:RAPTOR", "Ace")
	var cybrid := _make_herc("es1:SCORPION", "Scorpion")
	cybrid.set_meta("ai", true)
	var wing := _make_herc("es1:RAPTOR", "Kozlowski")
	_expect(KillText.make_unit_label(ace) == "Ace (Raptor)", "a pilot's label names him and his Herc (%s)" % KillText.make_unit_label(ace))
	_expect(KillText.make_unit_label(cybrid).begins_with("Cybrid ("), "an unnamed AI unit gets its faction, not the Herc name alone (%s)" % KillText.make_unit_label(cybrid))
	_expect(KillText.make_kill_text(ace, wing) == "Ace (Raptor) was killed by Kozlowski (Raptor)", "killer and victim both labelled (%s)" % KillText.make_kill_text(ace, wing))
	_expect(KillText.make_kill_text(ace, ace) == "Ace (Raptor) was killed by own splash", "own splash")
	KillText.apply_cause(ace, KillText.CAUSE_BOUNDS)
	_expect(KillText.make_kill_text(ace, null) == "Ace (Raptor) died out of bounds", "out of bounds (%s)" % KillText.make_kill_text(ace, null))
	KillText.apply_cause(ace, KillText.CAUSE_COLLISION)
	_expect(KillText.make_kill_text(ace, wing).contains("rammed"), "a collision kill says rammed")
	KillText.apply_cause(ace, "")
	_expect(KillText.make_kill_text(ace, null).ends_with("by the environment"), "an unknown world kill")
	if InfantryCatalog.light_armor_id("tribes2") != "":
		var s := Infantry.new()
		s.display_name = "Bot 3"
		s.armor = InfantryCatalog.armor("tribes2:LIGHT")
		_expect(KillText.make_unit_label(s).begins_with("Bot 3 (on foot, "), "a soldier is named with his suit (%s)" % KillText.make_unit_label(s))
		s.body_shape = "tribes2:bioderm_light"
		_expect(KillText.make_unit_label(s) == "Bot 3 (on foot, Bioderm light)", "a Bioderm body (%s)" % KillText.make_unit_label(s))
		s.free()
	for h in [ace, cybrid, wing]:
		h.free()


# ------------------------------------------------------------------ D2 library

func _check_library_buttons() -> void:
	var library: Library = load(LIBRARY).instantiate()
	get_tree().root.add_child(library)
	await _frames()
	_expect(_find_button(library, "Host LAN game") != null, "the library offers Host LAN game at once")
	_expect(_find_button(library, "Join LAN game") != null, "the library offers Join LAN game at once")
	library.queue_free()
	await _frames()
	var launcher := _open_launcher(Launcher.JOIN_START_MODE)
	await _frames()
	_expect(launcher.current_name == "browser", "Join from the library opens the LAN browser (%s)" % launcher.current_name)
	Net.stop_discovery()
	launcher.queue_free()
	await _frames()


# ------------------------------------------------------------------ D12 host screen, D1 bots

func _check_host_screen() -> void:
	var launcher := _open_launcher()
	await _frames()
	var host: RoutedScreen = launcher.go("host")
	await _frames()
	var s: Dictionary = host.call("make_settings")
	_expect(s.mode == "vs" and not s.teams and s.get("game_mode") == "deathmatch", "the host screen defaults to a deathmatch")
	var text := _all_text(host)
	_expect(not text.contains("Teams ("), "no team list in a deathmatch")
	host = launcher.go("host", {"mode": "team_vs"})
	await _frames()
	_expect(bool(host.call("make_settings").teams) and _all_text(host).contains("Teams ("), "a team mode shows the team count and the team list")
	host = launcher.go("host", {"mode": "vs"})
	if host.call("select_map", "Raindance") and host.call("select_game_mode", "ctf"):
		var ctf_cfg := MatchFlow.make_match_config(host.call("make_settings"), Packs.pilotable())
		_expect(int(ctf_cfg.get("score_limit", -1)) == 0 and _all_text(host).contains("Score limit"),
			"CTF with the limit untouched sends score_limit 0 (the mode decides) and says Score limit")
	host = launcher.go("host", {"mode": ExtractionRules.MODE})
	await _frames()
	text = _all_text(host)
	_expect(text.contains("Faction soldiers") and text.contains("Faction vehicles") and text.contains("Faction relations"),
		"extraction: faction soldiers / vehicles and the relations row")
	host = launcher.go("host", {"mode": "campaign"})
	await _frames()
	text = _all_text(host)
	_expect(text.contains("Co-op campaign: you host") and not _visible_label(host, "Infantry bots"), "co-op campaign: instructions, no bots row")
	host = launcher.go("host", {"mode": "vs", InfantryBots.CONFIG_KEY: 3})
	await _frames()
	var cfg := MatchFlow.make_match_config(host.call("make_settings"), Packs.pilotable())
	_expect(int(cfg.get(InfantryBots.CONFIG_KEY, 0)) == 3, "the host's bot count reaches the battle config (D1)")
	launcher.queue_free()
	await _frames()


func _visible_label(root: Node, text: String) -> bool:
	for c in root.find_children("*", "Label", true, false):
		if str(c.text) == text and (c as Label).is_visible_in_tree():
			return true
	return false


# ------------------------------------------------------------------ D3 / D4 lobby

func _check_lobby_gating() -> void:
	var launcher := _open_launcher()
	await _frames()
	var host: RoutedScreen = launcher.go("host", {"mode": "vs"})
	host.call("create_lobby")
	await _frames()
	if not Net.is_online():
		_expect(false, "the lobby opened (port %d)" % Net.GAME_PORT)
		launcher.queue_free()
		return
	var lobby := launcher.current
	_expect(not lobby.primary_button.disabled, "alone in the lobby the host may start")
	Net.roster[FAKE_PEER] = {"name": "Slowpoke", "vehicle": MatchFlow.DEFAULT_VEHICLE, "team": 0, "ready": false, "loadout": []}
	Net.roster_changed.emit()
	await _frames()
	_expect(lobby.primary_button.disabled and lobby.status_text().contains("Slowpoke"), "Start waits for Slowpoke and names him")
	_expect(_all_text(lobby).contains("not ready"), "the pilot list shows who is not ready")
	_expect(_all_text(lobby).contains("press Start match once every pilot"), "the lobby says what to do next")
	Net.roster[FAKE_PEER].ready = true
	Net.roster_changed.emit()
	await _frames()
	_expect(not lobby.primary_button.disabled and lobby.status_text() == "", "everybody ready: Start is enabled")
	Net.roster.erase(FAKE_PEER)
	_expect(LobbyText.make_instructions({"mode": "campaign"}, false).contains("Press Ready"), "co-op campaign clients are told to press Ready")
	Net.leave()
	launcher.queue_free()
	await _frames()


func _check_team_list() -> void:
	var list := TeamList.new()
	add_child(list)
	var chosen := []
	list.team_chosen.connect(func(peer: int, team: int) -> void: chosen.append([peer, team]))
	var s := {"mode": "vs", "teams": true, "team_count": 3, InfantryBots.CONFIG_KEY: 2, "world_idx": 0}
	list.refresh(s, {1: {"name": "Host", "team": 0}, FAKE_PEER: {"name": "Guest", "team": 2}}, 1, true)
	await _frames()
	var text := _all_text(list)
	_expect(text.contains("Teams (3)") and text.contains("Guest") and text.contains("Bot 1") and text.contains("Unassigned"), "the team list shows Unassigned and 3 teams, pilots and bots")
	var with_ai := s.merged({"ai": 2}, true)
	list.refresh(with_ai, {1: {"name": "Host", "team": -1}}, 1, true)
	_expect(_all_text(list).contains("AI unit 2  (AI vehicle)") and _all_text(list).contains("Bot 2  (infantry bot)"),
		"the team list has a row for every infantry bot and AI unit (H1)")
	_expect(LobbyText.make_pilot_text(1, {"name": "Host", "team": -1, "vehicle": "es1:RAPTOR"}, with_ai).contains("Unassigned"),
		"the pilot list names an unassigned pilot's team Unassigned")
	list.refresh(s, {1: {"name": "Host", "team": 0}, FAKE_PEER: {"name": "Guest", "team": 2}}, 1, true)
	await _frames()
	var grid: GridContainer = list.find_children("*", "GridContainer", true, false)[0]
	_expect(grid.get_child_count() == 4, "one column per team plus Unassigned (%d)" % grid.get_child_count())
	_expect(_find_button(list, "Assign all") != null, "the host has Assign all")
	var pickers := list.find_children("*", "OptionButton", true, false)
	_expect(pickers.size() == 2, "the host may move both pilots (%d pickers)" % pickers.size())
	if pickers.size() == 2:
		var picker := pickers[1] as OptionButton
		_expect(picker.get_item_text(picker.selected) != "" and picker.get_item_icon(picker.selected) != null, "a team picker shows the current team's name and colour (%s)" % picker.get_item_text(picker.selected))
		picker.item_selected.emit(picker.get_item_index(1 + TeamList.PICKER_ID_OFFSET))
		_expect(chosen.size() == 1 and int(chosen[0][1]) == 1, "picking a team reports it (%s)" % [chosen])
	list.refresh(s, {1: {"name": "Host", "team": 0}, FAKE_PEER: {"name": "Guest", "team": 2}}, FAKE_PEER, false)
	await _frames()
	_expect(list.find_children("*", "OptionButton", true, false).size() == 1, "a client picks only his own team")
	list.queue_free()


# ------------------------------------------------------------------ D11 objectives

func _check_objectives_panel() -> void:
	var battle: Battle = load(BATTLE).instantiate()
	battle.config = MatchFlow.make_skirmish_config(MatchFlow.DEFAULT_VEHICLE, [], MapPicker.config_at(0))
	get_tree().root.add_child(battle)
	await _frames(30)
	var panel := battle.overlay.objectives
	_expect(panel != null and panel.line_count() > 0, "a skirmish shows its objective in the side panel (%d lines)" % (panel.line_count() if panel else -1))
	panel.set_process(false)   # the test's lines stay
	panel.apply_lines([{"text": "Reach nav Alpha", "done": true}, {"text": "Destroy the base", "done": false}])
	await _frames(2)
	var done := panel.find_children("*", "Label", true, false).filter(func(l: Label) -> bool: return l.theme_type_variation == "HudDoneLine")
	_expect(done.size() == 1, "a completed objective is drawn as done")
	var was := panel.visible
	panel.toggle()
	_expect(panel.visible != was and DisplaySettings.objectives_panel_on() == panel.visible, "the panel toggles and remembers it")
	panel.toggle()
	battle.queue_free()
	await _frames()


## The objectives panel keeps clear of every cockpit's instruments and panel (ES1, ES2, Starsiege) and of the plain
## HUD, at the usual window sizes, and draws over the cockpit art.
func _check_objectives_placement() -> void:
	var cases := [["plain HUD (on foot)", MatchFlow.make_skirmish_config(MatchFlow.DEFAULT_VEHICLE, [], MapPicker.config_at(0))]]
	for pack in ["es1", "es2", "starsiege"]:
		var v := _first_cockpit_vehicle(pack)
		if v != "":
			cases.append(["%s cockpit (%s)" % [pack, v], Battle.default_config(v)])
	for c in cases:
		var battle: Battle = load(BATTLE).instantiate()
		battle.config = c[1]
		get_tree().root.add_child(battle)
		await _frames(30)
		var panel := battle.overlay.objectives
		panel.set_process(false)   # the test's lines stay
		panel.apply_lines([{"text": "Destroy the Cybrid base and every unit that guards it", "done": false},
			{"text": "Reach the nav points (0 of 3)", "done": false}])
		await _frames(2)
		if c[0] != "plain HUD (on foot)":
			_expect(battle.overlay.cockpit != null, "%s: the cockpit is up" % c[0])
		if battle.overlay.cockpit != null:
			_expect(panel.get_index() > battle.overlay.cockpit.get_index(), "%s: the panel draws over the cockpit" % c[0])
		for screen in [Vector2(1280, 800), Vector2(1920, 1080), Vector2(1024, 768)]:
			panel.apply_placement(screen)
			var occupied := battle.overlay.make_objectives_occupied_rects(screen)
			var r := panel.placed_rect
			_expect(ChatPlacement.is_clear(r, occupied) and Rect2(Vector2.ZERO, screen).encloses(r),
				"%s at %dx%d: the panel %s is clear of the HUD" % [c[0], screen.x, screen.y, r])
		battle.queue_free()
		await _frames()


func _first_cockpit_vehicle(pack: String) -> String:
	for v in Packs.pilotable():
		if str(v.id).begins_with(pack + ":") and not bool(v.get("flyer", false)):
			return str(v.id)
	return ""


# ------------------------------------------------------------------ D10 shape viewer

func _check_shape_viewer_back() -> void:
	if Assets.installed_packs().is_empty():
		print("skip  shape viewer (no packs)")
		return
	get_tree().change_scene_to_file(VIEWER)
	await _frames(10)
	var viewer := get_tree().current_scene
	_expect(viewer != null and _find_button(viewer, "Back to library") != null, "the shape viewer has a Back button")
	var ev := InputEventAction.new()
	ev.action = "menu_back"
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(10)
	var scene := get_tree().current_scene
	_expect(scene != null and scene.scene_file_path == LIBRARY, "menu_back returns to the library (%s)" % (scene.scene_file_path if scene else "none"))
