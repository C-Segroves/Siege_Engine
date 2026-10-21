extends Node
## Headless check of leaving and finishing a battle (QA #3, #8):
## - menu_pause (Esc / pad Start) opens the in-battle menu, pauses single player, releases the mouse;
##   menu_pause / menu_back / Resume close it again and unpause; Options opens the options page and
##   menu_back returns to the menu;
## - Leave match (confirmed) ends a skirmish on the results screen; the results list every pilot and
##   offer Rematch, which starts the same match again; a match won by the frag limit names the winner;
## - Abort mission (confirmed) ends a campaign mission as a failure the campaign records;
## - Quit to main menu (confirmed) opens the game library instead of closing the app;
## - the objective text states the rule that really ends the match on every map of the picker.
##   godot --headless --audio-driver Dummy --path game res://tests/battle_menu_check.tscn

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const PLAYER_VEHICLE := "es1:RAPTOR"
const SKIRMISH_AI := [{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.0}]
const SETTLE_SECONDS := 1.5
const STEP_FRAMES := 3

var _fails := 0
var _autosave_guard = preload("res://tests/saved_campaign_guard.gd").new("autosave")


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_autosave_guard.back_up()
	_check_objective_texts()
	var b := await _start_battle(_make_skirmish_config())
	await _check_menu_toggle(b)
	await _check_options_page(b)
	var results := await _check_leave_skirmish(b)
	b = await _check_rematch(results)
	await _check_frag_winner(b)
	await _check_abort_mission()
	await _check_quit_to_main_menu()
	_autosave_guard.restore()
	print("battle_menu_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ helpers

func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := STEP_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true).timeout


func _send_action(action: String) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _send_pad_button(button: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = button
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames()


func _make_skirmish_config() -> Dictionary:
	var cfg := MatchFlow.make_skirmish_config(PLAYER_VEHICLE, [], MapPicker.config_at(0))
	cfg["ai"] = SKIRMISH_AI.duplicate(true)
	return cfg


func _start_battle(cfg: Dictionary) -> Battle:
	var b: Battle = load(BATTLE_SCENE).instantiate()
	b.config = cfg
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	await _wait(SETTLE_SECONDS)
	return b


func _menu_of(b: Battle) -> BattleMenu:
	return b.battle_menu() if is_instance_valid(b) else null


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == text and (c as Button).is_visible_in_tree():
			return c
	return null


func _press(root: Node, text: String) -> bool:
	var b := _find_button(root, text)
	if b == null:
		_expect(false, "button '%s' present" % text)
		return false
	b.pressed.emit()
	await _frames()
	return true


func _confirm_dialog(root: Node) -> void:
	for d in root.find_children("*", "ConfirmDialog", true, false):
		(d as ConfirmDialog).confirm_button.pressed.emit()
	await _frames()


func _current_results() -> MatchResults:
	return get_tree().current_scene as MatchResults


# ------------------------------------------------------------------ checks

func _check_objective_texts() -> void:
	var world := {"world": 0, "zone": 0, "mode": "skirmish"}   # an Earthsiege world without a map file
	_expect(BattleRules.make_objective_text(world).contains("destroy all Cybrids"), "ES1 world skirmish: destroy all Cybrids")
	_expect(BattleRules.make_objective_text({"mode": "vs", "frag_limit": 7}).contains("7 kills"), "versus: frag limit in the objective")
	var entries := MapPicker.make_entries()
	var respawning := 0
	for e in entries:
		var cfg: Dictionary = (e.config as Dictionary).duplicate()
		cfg["mode"] = "skirmish"
		var says_kills := BattleRules.make_objective_text(cfg).contains("kills")
		if says_kills != BattleRules.uses_frag_limit(cfg):
			_expect(false, "objective of '%s' matches its rule" % e.name)
		respawning += 1 if BattleRules.uses_frag_limit(cfg) else 0
	_expect(true, "objective text matches the ending rule on all %d maps (%d by frag limit)" % [entries.size(), respawning])


func _check_menu_toggle(b: Battle) -> void:
	_expect(b.player != null, "skirmish has a player (%s)" % b.config.get("mode"))
	await _send_action("menu_pause")
	_expect(b.is_menu_open() and get_tree().paused, "menu_pause opens the menu and pauses single player")
	_expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "the mouse is released while the menu is open")
	var focus := get_viewport().gui_get_focus_owner()
	_expect(focus is Button and (focus as Button).text == "Options", "first menu entry focused (%s)" % [focus])
	await _send_action("menu_pause")
	_expect(not b.is_menu_open() and not get_tree().paused, "menu_pause again resumes")
	await _send_pad_button(JOY_BUTTON_START)
	_expect(b.is_menu_open() and get_tree().paused, "pad Start opens the menu")
	await _send_pad_button(JOY_BUTTON_B)
	_expect(not b.is_menu_open() and not get_tree().paused, "pad B (menu_back) resumes")
	b.open_menu()
	await _frames()
	await _press(_menu_of(b), "Resume")
	_expect(not b.is_menu_open() and not get_tree().paused, "Resume closes the menu")


func _check_options_page(b: Battle) -> void:
	b.open_menu()
	await _frames()
	await _press(_menu_of(b), "Options")
	_expect(_menu_of(b).current_name == "options", "Options opens the options page over the battle")
	await _send_action("menu_back")
	_expect(_menu_of(b) != null and _menu_of(b).current_name == "pause" and get_tree().paused,
		"menu_back from options returns to the paused menu")
	await _send_action("menu_back")
	_expect(not b.is_menu_open(), "menu_back on the menu resumes")


func _check_leave_skirmish(b: Battle) -> MatchResults:
	b.open_menu()
	await _frames()
	await _press(_menu_of(b), "Leave match")
	_expect(b.find_children("*", "ConfirmDialog", true, false).size() == 1, "Leave match asks first")
	await _confirm_dialog(b)
	await _frames()
	var results := _current_results()
	_expect(results != null, "leaving the skirmish opens the results screen (now %s)" % get_tree().current_scene)
	_expect(not get_tree().paused, "the results screen runs unpaused")
	if results == null:
		return null
	_expect(results.summary.headline == BattleSummary.MATCH_ABANDONED, "headline '%s'" % results.summary.headline)
	_expect((results.summary.pilots as Array).size() == 1 + SKIRMISH_AI.size(), "every pilot listed (%d rows)" % (results.summary.pilots as Array).size())
	_expect(_find_button(results, "Rematch") != null and _find_button(results, "Continue") != null, "Continue and Rematch offered")
	return results


func _check_rematch(results: MatchResults) -> Battle:
	if results == null:
		return null
	await _press(results, "Rematch")
	await _wait(SETTLE_SECONDS)
	var b := get_tree().current_scene as Battle
	_expect(b != null and b.player != null and b.config.get("mode") == "skirmish", "Rematch starts the same skirmish again")
	return b


func _check_frag_winner(b: Battle) -> void:
	if b == null:
		return
	var winner := b.player.display_name
	b.player.kills = 3
	b.end_match("%s wins the match!" % winner, {}, winner)
	b.finish_match()
	await _frames()
	var results := _current_results()
	_expect(results != null and results.summary.winner == winner, "a won match names the winner")
	if results == null:
		return
	var top: Dictionary = results.summary.pilots[0]
	_expect(int(top.kills) == 3 and int(top.score) == BattleSummary.make_score(3, 0), "pilot table: kills and score (%s)" % [top])
	_expect(["assists", "vehicle_kills", "bot_kills", "objectives", "damage", "seconds_alive", "survived"].all(func(k: String) -> bool: return top.has(k)) and results.summary.has("awards"),
		"the host's summary carries the pilot's stats and the awards")
	Session.front_end = "res://library.tscn"
	await _press(results, "Continue")
	await _wait(0.5)
	_expect(get_tree().current_scene is Library, "Continue returns to the front end (%s)" % get_tree().current_scene)


func _check_abort_mission() -> void:
	Session.start_stage_campaign("es1")
	var before := str(Session.campaign.current_mission())
	var b := await _start_battle(MatchFlow.make_mission_config(PLAYER_VEHICLE, []))
	b.open_menu()
	await _frames()
	_expect(_find_button(_menu_of(b), "Abort mission") != null, "a mission's menu offers Abort mission")
	await _press(_menu_of(b), "Abort mission")
	await _confirm_dialog(b)
	await _frames()
	var results := _current_results()
	_expect(results != null and results.summary.headline == BattleSummary.MISSION_HEADLINES.aborted, "aborted mission on the results screen")
	_expect(not bool(Session.last_result.get("success", true)) and bool(Session.last_result.get("aborted", false)),
		"the campaign receives a failed (aborted) mission")
	MatchFlow.apply_mission_result()
	var c: Campaign = Session.campaign
	_expect(not c.last_success and str(c.history.back().mission) == before, "Earthsiege records %s as failed (next %s)" % [before, c.current_mission()])
	if results:
		results.queue_free()


func _check_quit_to_main_menu() -> void:
	var b := await _start_battle(MatchFlow.make_mission_config(PLAYER_VEHICLE, []))
	b.open_menu()
	await _frames()
	_expect(_find_button(_menu_of(b), "Quit to main menu") != null, "the menu offers Quit to main menu")
	await _press(_menu_of(b), "Quit to main menu")
	await _confirm_dialog(b)
	await _frames(6)
	var scene := get_tree().current_scene
	_expect(scene != null and scene.scene_file_path == Session.MAIN_MENU_SCENE,
		"Quit to main menu opens the library (%s)" % (scene.scene_file_path if scene else "none"))
