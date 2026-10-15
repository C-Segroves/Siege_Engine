extends Node
## Windowed renders of an extraction raid (plain HUD, objectives panel, chat, command map) at 1280x720, 1920x1080 and
## 2560x1440 with the UI scale on Auto, to renders/ui_scale_<w>x<h>[_map].png, plus the Options > Display row:
##   godot --audio-driver Dummy --path game res://tests/ui_scale_shots.tscn [-- --out=<dir>]
## Needs a window. Tests run in isolated stores; the profile is the QA one.

const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440)]
const MAP := "tribes2:Katabatic"

var _out := ""


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	Net.player_name = "QA UiScale"
	var p := ExtractionProfile.load_for("QA UiScale")
	for s in ExtractionProfile.make_starter_stacks(InfantryCatalog.armor(p.kit_armor)):
		p.kit.apply_add(str(s[0]), int(s[1]))
	var flag := {"id": "qa_flag", "kind": RaidTaskBoard.KIND_FLAG, "faction": "knights", "count": 1}
	flag["reward"] = RaidTaskBoard.make_reward(flag)
	p.tasks = [flag]
	p.save()
	var config := MatchFlow.make_extraction_solo_config(p, {"map": MAP, "respawn": true}, 2, 0)
	config[ExtractionRules.FAST_CONFIG_KEY] = true
	config["extraction_seed"] = 4242
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await get_tree().create_timer(6.0).timeout
	battle.overlay.chat_log.add("all", "Rook", "good luck everybody")
	for size in SIZES:
		DisplayServer.window_set_size(size)
		UiScale.apply(get_tree().root)
		await get_tree().create_timer(1.0).timeout
		await _save("ui_scale_%dx%d" % [size.x, size.y])
		var input := battle.get_node(CommandMapInput.NODE_NAME) as CommandMapInput
		input.apply_toggle()
		await get_tree().create_timer(2.5).timeout
		await _save("ui_scale_%dx%d_map" % [size.x, size.y])
		input.apply_toggle()
		await get_tree().create_timer(0.5).timeout
	print("ui_scale_shots: done -> ", _out)
	get_tree().quit()


func _save(shot_name: String) -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("%s.png" % shot_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("ui_scale_shots: ", path, " ", get_viewport().get_visible_rect().size, " win ", get_window().size)
