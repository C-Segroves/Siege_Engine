extends Node
## Headless check of the shared campaign save store (SaveGames) and every front end on it:
## - New campaign (screen): pilot name + every playable campaign (the saga, Earthsiege, Earthsiege 2,
##   Starsiege human / cybrid) starts it, autosaves at once, opens its first page; a second start of the same
##   pilot and campaign asks first;
## - an autosave after every finished mission (win or loss) for each provider and the saga;
## - a named save round-trips the garage (Hercs, armory, salvage pool), the crew and the playtime;
## - Save / Load screen: overwrite and delete ask first; finished campaigns and saves of games that are
##   not installed are listed but cannot be loaded (nor continued);
## - pilot killed: the mission is not recorded, the launcher opens the killed-in-action prompt, Replay
##   restores the restore point written at launch (garage and mission as before the battle) with its Herc,
##   Quit leaves the campaign at its last save;
## - the original Earthsiege shell: careers are the pilots' autosaves, its CAREER BACKUPS SAVE / RESTORE
##   write and read the same store (overwrite asks with MENU1240), the app's Earthsiege saves show up in
##   its list, and careers of earlier versions are moved into the store once.
##   godot --headless --audio-driver Dummy --path game res://tests/save_load_check.tscn
## Every save, career file and settings.json of the player is backed up and restored (saved_campaign_guard).

const LAUNCHER_SCENE := "res://launcher.tscn"
const SHELL_SCENE := "res://es1_shell.tscn"
const PILOT := "QA Saver"
const SHELL_PILOT := "QABACKUP"
const STEP_FRAMES := 4
const SALVAGE_MARK := 12345
const CREW_KILLS := 3
const PLAYTIME := 5400.0

var _fails := 0
var _guard = preload("res://tests/saved_campaign_guard.gd").new()


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_guard.back_up()
	_clear_store()
	await _check_new_campaign_screen()
	_check_autosave_after_missions()
	_check_round_trip()
	await _check_save_screen_confirms()
	await _check_finished_and_missing()
	await _check_pilot_killed()
	await _check_shell_store()
	_check_legacy_careers()
	_clear_store()
	_guard.restore()
	print("save_load_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ helpers

func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := STEP_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _clear_store() -> void:
	for f in DirAccess.get_files_at(SaveGames.DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [SaveGames.DIR, f]))
	for path in [ShellCareers.LEGACY_FILE, ShellCareers.LEGACY_MOVED_FILE]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _playable_choices() -> Array:
	return MatchFlow.make_new_campaign_choices().filter(func(c: Dictionary) -> bool: return c.playable)


func _open_launcher() -> Launcher:
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	launcher.set_meta("start_mode", Launcher.JOIN_START_MODE)   # the LAN browser is the first page, as when the library opens the launcher
	add_child(launcher)
	await _frames()
	return launcher


func _close(launcher: Launcher) -> void:
	Net.stop_discovery()
	Net.leave()
	launcher.queue_free()
	await _frames()


func _dialog(root: Node) -> ConfirmDialog:
	for d in root.find_children("*", "ConfirmDialog", true, false):
		if not d.is_queued_for_deletion():
			return d
	return null


func _autosave_of(key: String) -> Dictionary:
	return SaveGames.read(SaveGames.make_autosave_id(key, PILOT))


## A battle result for the running campaign's current mission.
func _make_result(success: bool) -> Dictionary:
	return {"success": success, "vars": Session.campaign.prepared_vars(), "salvage": [], "salvage_kg": 0,
		"text": "QA"}


# ------------------------------------------------------------------ new campaign

func _check_new_campaign_screen() -> void:
	var choices := _playable_choices()
	_expect(choices.size() >= 2 and choices[0].get("saga", false), "New campaign offers the saga and the games' campaigns: %s" % [choices.map(func(c): return c.key)])
	for choice in choices:
		_expect(str(choice.description) != "", "%s has a description" % choice.text)
		var launcher := await _open_launcher()
		var screen := launcher.go("new_campaign")
		await _frames()
		_select_choice(screen, str(choice.key))
		(screen.get("_name_edit") as LineEdit).text = PILOT
		screen.primary_button.pressed.emit()
		await _frames()
		_expect(Session.pilot_name == PILOT and Session.campaign_key() == str(choice.key), "%s starts for %s" % [choice.text, PILOT])
		_expect(launcher.current_name in ["lobby", "saga_choice"], "%s opens its first page (%s)" % [choice.text, launcher.current_name])
		_expect(not _autosave_of(str(choice.key)).is_empty(), "%s is autosaved at once" % choice.text)
		await _close(launcher)
	await _check_restart_asks(choices[choices.size() - 1])


func _select_choice(screen: Node, key: String) -> void:
	var list: Array = screen.get("_choices")
	var boxes: Array = screen.get("_boxes")
	for i in list.size():
		if str(list[i].key) == key:
			(boxes[i] as CheckBox).button_pressed = true


func _check_restart_asks(choice: Dictionary) -> void:
	var launcher := await _open_launcher()
	var screen := launcher.go("new_campaign")
	await _frames()
	_select_choice(screen, str(choice.key))
	(screen.get("_name_edit") as LineEdit).text = PILOT
	screen.primary_button.pressed.emit()
	await _frames()
	_expect(_dialog(launcher) != null and launcher.current_name == "new_campaign",
		"starting %s again for the same pilot asks first" % choice.text)
	await _close(launcher)


# ------------------------------------------------------------------ autosave after every mission

func _check_autosave_after_missions() -> void:
	for choice in _playable_choices():
		Session.start_new_campaign(choice, PILOT)
		if Session.saga != null and Session.saga.needs_choice():
			continue
		for success in [false, true]:
			var before := JSON.stringify(_autosave_of(str(choice.key)).get("campaign", _autosave_of(str(choice.key)).get("saga")))
			Session.last_result = _make_result(success)
			Session.finish_mission()
			var saved := _autosave_of(str(choice.key))
			var state = saved.get("saga", saved.get("campaign"))
			var live = Session.saga.to_dict() if Session.saga != null else Session.campaign.to_dict()
			_expect(JSON.stringify(state) != before and JSON.stringify(state) == JSON.stringify(JSON.parse_string(JSON.stringify(live))),
				"%s: a %s mission is recorded and autosaved" % [choice.text, "won" if success else "lost"])
	Session.clear_campaign()


# ------------------------------------------------------------------ manual save round trip

func _check_round_trip() -> void:
	Session.start_new_campaign({"pack": "es1", "variant": ""}, PILOT)
	var g := Session.garage()
	g.salvage_kg = SALVAGE_MARK
	g.vehicles[0].name = "QA Herc"
	g.stock["es1:LAS100"] = 42
	var pilot := g.crew.pilot_in_slot(0)
	g.crew.apply_mission(str(pilot.id), CREW_KILLS, true)
	SaveGames.reset_clock(PLAYTIME)
	var want := JSON.stringify(JSON.parse_string(JSON.stringify(g.to_dict())))
	var id := Session.save_manual("QA round trip")
	Session.clear_campaign()
	SaveGames.reset_clock(0.0)
	_expect(id != "" and Session.load_save(id), "a named save loads")
	var got := Session.garage()
	_expect(got != null and JSON.stringify(JSON.parse_string(JSON.stringify(got.to_dict()))) == want,
		"the garage (Hercs, armory, salvage pool, crew) round-trips")
	_expect(got.salvage_kg == SALVAGE_MARK and int(got.stock.get("es1:LAS100", 0)) == 42 and got.vehicles[0].name == "QA Herc",
		"salvage %d, armory, Herc name kept" % got.salvage_kg)
	_expect(int(got.crew.pilot(str(pilot.id)).get("kills", 0)) >= CREW_KILLS, "the crew's record kept")
	_expect(SaveGames.clock_seconds() >= PLAYTIME and Session.pilot_name == PILOT, "playtime and pilot kept (%.0f s)" % SaveGames.clock_seconds())
	var entry := SaveGames.make_entry(id, SaveGames.read(id))
	_expect(entry.kind == SaveGames.KIND_MANUAL and entry.title == "Metaltech: Earthsiege" and str(entry.mission) != ""
		and float(entry.playtime) >= PLAYTIME, "the list shows name, campaign, mission, date and playtime: %s" % SaveGames.make_row_text(entry).replace("\n", " | "))


# ------------------------------------------------------------------ Save / Load screen

func _check_save_screen_confirms() -> void:
	Session.start_new_campaign({"pack": "es1", "variant": ""}, PILOT)
	var launcher := await _open_launcher()
	launcher.show_started_campaign()   # Back returns to the page Save game was opened from (the navigation stack)
	await _frames()
	var screen := launcher.go("saves", {"mode": "save", "return_to": "lobby"})
	await _frames()
	(screen.get("_name_edit") as LineEdit).text = "QA slot"
	screen.primary_button.pressed.emit()
	await _frames()
	_expect(SaveGames.exists(SaveGames.make_manual_id("QA slot")) and _dialog(launcher) == null, "Save writes a new named save without asking")
	screen = launcher.current
	(screen.get("_name_edit") as LineEdit).text = "QA slot"
	screen.primary_button.pressed.emit()
	await _frames()
	var d := _dialog(launcher)
	_expect(d != null, "saving over an existing name asks first")
	if d:
		d.confirm_button.pressed.emit()
		await _frames()
	_expect(launcher.current.status_text().contains("Saved"), "Overwrite saves ('%s')" % launcher.current.status_text())
	await _check_delete_asks(launcher, "QA slot")
	launcher.current.back_button.pressed.emit()
	await _frames()
	_expect(launcher.current_name == "lobby", "Back returns to the lobby")
	await _close(launcher)


func _check_delete_asks(launcher: Launcher, save_name: String) -> void:
	var delete := _row_delete_button(launcher.current, save_name)
	_expect(delete != null, "the save's row has Delete")
	if delete == null:
		return
	delete.pressed.emit()
	await _frames()
	var d := _dialog(launcher)
	_expect(d != null and SaveGames.exists(SaveGames.make_manual_id(save_name)), "Delete asks first")
	if d:
		d.confirm_button.pressed.emit()
		await _frames()
	_expect(not SaveGames.exists(SaveGames.make_manual_id(save_name)), "Delete removes the save")


func _row_delete_button(screen: Node, save_name: String) -> Button:
	for b in screen.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("%s  (" % save_name):
			for sibling in b.get_parent().get_children():
				if sibling is Button and (sibling as Button).text == "Delete":
					return sibling
	return null


# ------------------------------------------------------------------ finished / missing games

func _check_finished_and_missing() -> void:
	_clear_store()
	Session.start_new_campaign({"pack": "es1", "variant": ""}, PILOT)
	(Session.campaign as Campaign).state = Campaign.STATE_VICTORY
	Session.autosave()
	var finished_id := SaveGames.make_autosave_id("es1", PILOT)
	var bogus := Session.make_save(SaveGames.KIND_MANUAL, "QA missing game")
	bogus.meta.packs = ["qa_not_installed"]
	bogus.meta.finished = false
	SaveGames.write("save_qa_missing", bogus)
	Session.clear_campaign()
	_expect(bool(SaveGames.make_entry(finished_id, SaveGames.read(finished_id)).finished), "a won campaign's save is marked finished")
	_expect(not Session.load_save(finished_id) and Session.campaign == null, "a finished campaign is not loaded")
	_expect(not Session.load_save("save_qa_missing"), "a save needing a game that is not installed is not loaded")
	_expect(SaveGames.find_newest_continuable().is_empty(), "neither is offered by Continue")
	var launcher := await _open_launcher()
	launcher.go("saves", {"mode": "load"})
	await _frames()
	var rows := launcher.current.find_children("*", "Button", true, false).filter(func(b: Button) -> bool: return b.text.contains("\n"))
	_expect(rows.size() == 2 and rows.all(func(b: Button) -> bool: return b.disabled), "both are listed but cannot be loaded")
	_expect(rows.any(func(b: Button) -> bool: return b.text.contains("finished")) and rows.any(func(b: Button) -> bool: return b.text.contains("unavailable")),
		"the list says why: finished / unavailable")
	await _close(launcher)
	_clear_store()


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == text and (c as Button).is_visible_in_tree():
			return c
	return null


# ------------------------------------------------------------------ pilot killed

func _check_pilot_killed() -> void:
	for choice in _playable_choices():
		if choice.get("saga", false):
			continue
		Session.start_new_campaign(choice, PILOT)
		if Session.garage() == null:
			continue   # Tribes campaigns keep no garage: nothing is restored on a replay, and there is no Herc to compare
		var mission := str(Session.campaign.current_mission())
		var garage_before := JSON.stringify(Session.garage().to_dict())
		var e := Session.garage().make_battle_entry()
		Session.save_restore_point({"vehicle": str(e.vehicle), "loadout": e.loadout, "garage": e.get("garage", {})})
		Session.garage().salvage_kg += SALVAGE_MARK      # what the lost battle changed
		Session.last_result = _make_result(false).merged({"pilot_killed": true})
		_expect(Session.must_replay(), "%s: a killed pilot must replay" % choice.text)
		await _check_killed_prompt(choice)
		var launch := Session.replay_from_restore_point()
		_expect(str(Session.campaign.current_mission()) == mission and JSON.stringify(Session.garage().to_dict()) == garage_before,
			"%s: Replay restores the pre-mission campaign (mission %s, garage)" % [choice.text, mission])
		_expect(str(launch.get("vehicle", "")) == str(e.vehicle), "%s: Replay flies the same Herc (%s)" % [choice.text, launch.get("vehicle", "")])
	await _check_killed_quit()


## The launcher opens the prompt (not the debriefing) and the result is not recorded.
func _check_killed_prompt(choice: Dictionary) -> void:
	var mission := str(Session.campaign.current_mission())
	var launcher := await _open_launcher()
	_expect(launcher.current_name == "killed", "%s: back from the battle the launcher asks to replay (%s)" % [choice.text, launcher.current_name])
	_expect(launcher.current.primary_button.text == "Replay mission" and launcher.current.back_button.text == "Quit to main menu",
		"%s: Replay mission / Quit to main menu" % choice.text)
	Session.finish_mission()
	_expect(str(Session.campaign.current_mission()) == mission, "%s: the killed pilot's mission is not recorded" % choice.text)
	await _close(launcher)


func _check_killed_quit() -> void:
	Session.start_new_campaign({"pack": "es1", "variant": ""}, PILOT)
	var mission := str(Session.campaign.current_mission())
	Session.last_result = _make_result(false).merged({"pilot_killed": true})
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	launcher.set_meta("start_mode", Launcher.JOIN_START_MODE)   # the LAN browser is the first page, as when the library opens the launcher
	get_tree().root.add_child(launcher)
	get_tree().current_scene = launcher   # the main menu (the library) replaces the launcher scene
	await _frames()
	launcher.current.back_button.pressed.emit()
	await _frames()
	await _frames()
	_expect(get_tree().current_scene is Library and Session.campaign == null, "Quit to main menu leaves the campaign for the library")
	Net.stop_discovery()
	if get_tree().current_scene != self:
		get_tree().current_scene.queue_free()
	get_tree().current_scene = self
	var saved := _autosave_of("es1")
	_expect(str(saved.campaign.mission) == mission, "the campaign stays at its last save (mission %s)" % mission)
	await _frames()


# ------------------------------------------------------------------ the original shell

func _check_shell_store() -> void:
	if not ShellData.available():
		print("skip  shell checks (shell data not exported)")
		return
	_clear_store()
	Session.start_new_campaign({"pack": "es1", "variant": ""}, PILOT)
	Session.save_manual("QA app save")
	Session.clear_campaign()
	var shell: EsShell = load(SHELL_SCENE).instantiate()
	add_child(shell)
	await _frames()
	_expect(shell.careers.has_name(PILOT), "the app's Earthsiege campaign is a shell career (%s)" % [shell.careers.names()])
	var career := shell.careers.make_new(SHELL_PILOT)
	MissionLaunch.ensure_campaign_state(career)
	shell.careers.save(career)
	EsShell.career = career
	_expect(SaveGames.exists(ShellCareers.autosave_id(SHELL_PILOT)), "a new shell career is its pilot's autosave")
	await _check_shell_save(shell)
	await _check_shell_restore(shell)
	EsShell.career = {}
	shell.queue_free()
	await _frames()


func _check_shell_save(shell: EsShell) -> void:
	shell.goto_menu(EsShell.CAREER_MENU)
	shell.open_menu(EsShell.BACKUPS_MENU)
	shell.commands.run(shell.top(), ShellBackups.SAVE_ID)
	var id := SaveGames.make_manual_id(SHELL_PILOT)
	_expect(SaveGames.exists(id) and SaveGames.read(id).meta.campaign_key == "es1", "SAVE writes a named save of the same store")
	var items: Array = shell.top().find(ShellBackups.LIST_ID).items
	_expect(items.has(SHELL_PILOT) and items.has("QA APP SAVE"), "the backups list holds the shell's and the app's saves %s" % [items])
	_expect(SaveGames.list_entries().any(func(e: Dictionary) -> bool: return e.id == id), "the app's Save / Load list shows the shell's backup")
	shell.commands.run(shell.top(), ShellBackups.SAVE_ID)
	_expect(shell.top().id == EsShell.OVERWRITE_BACKUP_MENU and str(shell.top().find(ShellBackups.NAME_TEXT_ID, ShellMenu.T_TEXT).label) == SHELL_PILOT,
		"SAVE over an existing backup asks first (MENU1240 names it)")
	shell.commands.run(shell.top(), EsShell.OK_ID)
	_expect(shell.top().id == EsShell.BACKUPS_MENU, "OVERWRITE saves and returns to CAREER BACKUPS")
	await _frames(1)


func _check_shell_restore(shell: EsShell) -> void:
	EsShell.career["missions"] = 99
	var items: Array = shell.top().find(ShellBackups.LIST_ID).items
	shell.top().find(ShellBackups.LIST_ID).sel = items.find(SHELL_PILOT)
	shell.commands.run(shell.top(), ShellBackups.RESTORE_ID)
	_expect(str(EsShell.career.name) == SHELL_PILOT and int(EsShell.career.get("missions", -1)) == 0, "RESTORE brings the backup back as the career")
	var saved := SaveGames.read(ShellCareers.autosave_id(SHELL_PILOT))
	_expect(int(saved.shell.get("missions", -1)) == 0, "the restored career is its pilot's autosave again")
	await _frames(1)


func _check_legacy_careers() -> void:
	_clear_store()
	var legacy := [{"name": "QALEGACY", "campaign": 0, "slot": 0, "missions": 4, "kills": 2, "next_mission": ShellCareers.FIRST_MISSION}]
	var f := FileAccess.open(ShellCareers.LEGACY_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(legacy))
	f.close()
	var careers := ShellCareers.new()
	careers.load_all()
	_expect(careers.has_name("QALEGACY") and int(careers.list[careers.index_of("QALEGACY")].missions) == 4,
		"a career file of an earlier version is moved into the store")
	_expect(not FileAccess.file_exists(ShellCareers.LEGACY_FILE) and FileAccess.file_exists(ShellCareers.LEGACY_MOVED_FILE),
		"... once (the old file is renamed)")
