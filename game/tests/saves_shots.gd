extends Node
## Window screenshots of the save pages (run windowed, not headless):
##   renders/saves_new_campaign.png, saves_load.png, saves_save.png, saves_killed_es1.png,
##   saves_killed_es2.png, saves_shell_killed.png (the original shell's MENU1250 with REPLAY),
##   saves_shell_backups.png (CAREER BACKUPS on the same store).
##   godot --audio-driver Dummy --path game res://tests/saves_shots.tscn
## The player's saves are backed up and restored; the pages show fixture saves.

const LAUNCHER_SCENE := "res://launcher.tscn"
const SHELL_SCENE := "res://es1_shell.tscn"
const OUT := "res://../renders/saves_%s.png"
const SETTLE := 0.8
const PILOT := "Ironside"

var _guard = preload("res://tests/saved_campaign_guard.gd").new()


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_guard.back_up()
	_clear_store()
	_make_fixtures()
	await _shoot_launcher("new_campaign", func(l: Launcher) -> void: l.go("new_campaign"))
	await _shoot_launcher("load", func(l: Launcher) -> void: l.go("saves", {"mode": "load"}))
	await _shoot_launcher("save", func(l: Launcher) -> void:
		Session.load_save(SaveGames.make_autosave_id("es2", PILOT))
		l.go("saves", {"mode": "save", "return_to": "lobby"}))
	for pack in ["es1", "es2"]:
		await _shoot_launcher("killed_%s" % pack, func(l: Launcher) -> void:
			Session.start_new_campaign({"pack": pack, "variant": ""}, PILOT)
			Session.last_result = {"success": false, "pilot_killed": true}
			l.go("killed"))
	await _shoot_shell()
	Session.clear_campaign()
	Session.last_result = {}
	_clear_store()
	_guard.restore()
	get_tree().quit()


func _clear_store() -> void:
	for f in DirAccess.get_files_at(SaveGames.DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [SaveGames.DIR, f]))


## A few pilots and campaigns, a named save, a finished campaign and one whose game is missing.
func _make_fixtures() -> void:
	for choice in MatchFlow.make_new_campaign_choices():
		if choice.playable:
			Session.start_new_campaign(choice, PILOT if not choice.get("saga", false) else "Commander Shaw")
			SaveGames.reset_clock(3600.0 * randf())
			Session.autosave()
	Session.start_new_campaign({"pack": "es1", "variant": ""}, "Valkyrie")
	Session.save_manual("Before the Ice World")
	var missing := Session.make_save(SaveGames.KIND_MANUAL, "Friend's Battledrome save")
	missing.meta.merge({"packs": ["bd"], "title": "Battledrome", "campaign_key": "bd"}, true)
	SaveGames.write("save_friend", missing)
	(Session.campaign as Campaign).state = Campaign.STATE_VICTORY
	Session.autosave()
	Session.clear_campaign()


func _shoot_launcher(shot_name: String, open: Callable) -> void:
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	add_child(launcher)
	await get_tree().process_frame
	open.call(launcher)
	await _save(shot_name)
	Net.stop_discovery()
	launcher.queue_free()
	await get_tree().process_frame


func _shoot_shell() -> void:
	if not ShellData.available():
		return
	var shell: EsShell = load(SHELL_SCENE).instantiate()
	add_child(shell)
	await get_tree().create_timer(SETTLE).timeout
	shell.goto_menu(EsShell.MAIN_MENU)
	shell.open_menu(EsShell.KILLED_MENU)
	await _save("shell_killed")
	EsShell.career = shell.careers.list[0] if not shell.careers.list.is_empty() else {}
	shell.goto_menu(EsShell.CAREER_MENU)
	shell.open_menu(EsShell.BACKUPS_MENU)
	await _save("shell_backups")
	EsShell.career = {}
	shell.queue_free()
	await get_tree().process_frame


func _save(shot_name: String) -> void:
	await get_tree().create_timer(SETTLE).timeout
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(OUT % shot_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)
