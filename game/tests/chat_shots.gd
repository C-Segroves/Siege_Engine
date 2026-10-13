extends Node
## Screenshots of the chat panel (docs/formats/cockpit.md section 9.6) in several cockpits and HUDs, on foot, open
## with its history and filter tabs, the quick-chat menu, and the options screen's chat section, to
## renders/chat_<name>.png. Needs a window:
##   godot --audio-driver Dummy --path game res://tests/chat_shots.tscn [-- --out=<dir>]
## The chat lines are the remake's own sample texts; user://settings.json is backed up and restored.

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const SETTLE_SECONDS := 3.0
const SHOTS := [
	{"name": "es1_raptor", "vehicle": "es1:RAPTOR"},
	{"name": "es2_maverick", "vehicle": "es2:MAVERICK"},
	{"name": "starsiege_tr_bans", "vehicle": "starsiege:tr_bans"},
	{"name": "bd_thor", "vehicle": "bd:THOR"},
	{"name": "tribes2_beowulf", "vehicle": "tribes2:BEOWULF"},
	{"name": "plain_hud", "vehicle": "es1:SKIMMER"},
	{"name": "on_foot", "vehicle": "es1:RAPTOR", "start": "on_foot", "map": "tribes:Broadside"},
]
const SAMPLE := [
	["system", "", "Nav point 2 reached."],
	["radio", "Wingman", "Enemy contact, two units at the ridge."],
	["all", "Rook", "good luck everybody"],
	["team", "Ace", "I'll cover the left flank, follow me in when the shields are up again"],
	["radio", "Command", "Hold your position until the convoy arrives."],
]
const SETTINGS_FILE := "user://settings.json"

var _out := ""
var _saved_settings := ""
var _had_settings := false


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	_had_settings = FileAccess.file_exists(SETTINGS_FILE)
	_saved_settings = FileAccess.get_file_as_string(SETTINGS_FILE) if _had_settings else ""
	ChatSettings.reset()
	for s in SHOTS:
		if Packs.vehicle(str(s.vehicle)).is_empty():
			print("chat_shots: skip %s (vehicle not installed)" % s.name)
			continue
		var b := await _start(s)
		_fill(b)
		await _save("chat_%s" % s.name)
		if s.name == "es1_raptor":
			await _shoot_open_modes(b)
			await _shoot_options(b)
		b.queue_free()
		await get_tree().process_frame
	_restore_settings()
	print("chat_shots: done -> %s" % _out)
	get_tree().quit()


func _start(s: Dictionary) -> Battle:
	var cfg := BattleSetup.make_default_config(str(s.vehicle))
	cfg.ai = (cfg.ai as Array).slice(0, 2)
	if s.has("start"):
		cfg.start = s.start
		cfg.mode = "vs"
		cfg.map = s.map
	var b: Battle = load(BATTLE_SCENE).instantiate()
	b.config = cfg
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	return b


func _fill(b: Battle) -> void:
	for line in SAMPLE:
		b.overlay.chat_log.add(str(line[0]), str(line[1]), str(line[2]))


func _shoot_open_modes(b: Battle) -> void:
	for i in 20:
		b.overlay.chat_log.add(ChatChannels.SYSTEM, "", "older history line %d" % i)
	_fill(b)
	b.chat.panel.open_history()
	b.chat.panel.scroll = 3
	await _save("chat_open_history")
	b.chat.panel.close()
	b.chat.panel.open_typing(ChatChannels.TEAM)
	await _save("chat_typing")
	b.chat.panel.close()
	b.chat.panel.open_quick()
	await _save("chat_quick")
	b.chat.panel.close()


func _shoot_options(b: Battle) -> void:
	b.open_menu()
	await get_tree().create_timer(0.5).timeout
	for c in b.battle_menu().find_children("*", "Button", true, false):
		if (c as Button).text == "Options":
			(c as Button).pressed.emit()
	await get_tree().create_timer(0.5).timeout
	var section: Control = b.battle_menu().find_children("*", "ChatOptions", true, false)[0]
	var scroll := section.get_parent()
	while scroll != null and not (scroll is ScrollContainer):
		scroll = scroll.get_parent()
	if scroll:
		(scroll as ScrollContainer).scroll_vertical = int(section.position.y)
	await _save("chat_options")


func _save(shot_name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("%s.png" % shot_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("chat_shots: ", path)


func _restore_settings() -> void:
	if _had_settings:
		var f := FileAccess.open(SETTINGS_FILE, FileAccess.WRITE)
		f.store_string(_saved_settings)
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))
