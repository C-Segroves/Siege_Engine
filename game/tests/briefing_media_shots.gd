extends Node
## Windowed renders of the campaign lobby's briefing pane (ES1 talking head, ES2 mission movie) at 1280x720, 1920x1080 and
## 2560x1440, plus the media rect checks: the media box lies inside the left half and above the other rows.
##   godot --audio-driver Dummy --path game res://tests/briefing_media_shots.tscn [-- --out=<dir> --fullscreen]
## The media box must lie inside the window and at most half its height. Writes <out>/briefing_media_<pack>_<w>x<h>.png. Needs a window; runs in an isolated store.

const LAUNCHER_SCENE := "res://launcher.tscn"
const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440)]

var _out := ""
var _fails := 0


func _ready() -> void:
	_out = ProjectSettings.globalize_path("res://").path_join("../renders")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	_run.call_deferred()


func _run() -> void:
	var guard = preload("res://tests/saved_campaign_guard.gd").new()
	guard.back_up()
	var sizes: Array = SIZES.duplicate()
	if OS.get_cmdline_user_args().has("--fullscreen"):
		sizes = [Vector2i(-1, -1)]
	for pack in ["es1", "es2"]:
		Session.start_new_campaign({"pack": pack, "variant": ""}, "QA Media")
		var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
		add_child(launcher)
		await get_tree().create_timer(0.5).timeout
		launcher.show_started_campaign()
		for size in sizes:
			if size.x < 0:
				get_window().mode = Window.MODE_FULLSCREEN
			else:
				DisplayServer.window_set_size(size)
			UiScale.apply(get_tree().root)
			await get_tree().create_timer(2.5).timeout
			await _check_and_save(pack, "fullscreen" if size.x < 0 else "%dx%d" % [size.x, size.y])
		Net.leave()
		launcher.queue_free()
		await get_tree().process_frame
	Session.clear_campaign()
	guard.restore()
	print("briefing_media_shots: %d failed" % _fails)
	get_tree().quit(_fails)


func _check_and_save(pack: String, tag: String) -> void:
	var view := get_viewport().get_visible_rect().size
	var boxes := get_tree().root.find_children("*", "MediaBox", true, false)
	for b in boxes:
		var r: Rect2 = (b as Control).get_global_rect()
		var ok := r.end.x <= view.x + 1.0 and r.position.x >= 0.0 and r.size.y <= view.y * 0.5 + 1.0
		print("briefing_media_shots: %s %s box %s view %s %s" % [pack, tag, r, view, "ok" if ok else "FAIL"])
		if not ok:
			_fails += 1
	if boxes.is_empty():
		print("briefing_media_shots: %s %s no media box" % [pack, tag])
		_fails += 1
	for i in 4:
		await RenderingServer.frame_post_draw
	var path := _out.path_join("briefing_media_%s_%s.png" % [pack, tag])
	get_viewport().get_texture().get_image().save_png(path)
	print("briefing_media_shots: ", path)
