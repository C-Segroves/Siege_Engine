class_name MoviePlayer
extends Control
## Full-screen cutscene player for converted cinematics (any key, click, gamepad button or input
## action skips).

signal finished

var player: VideoStreamPlayer
var box: MediaBox          # set: embedded in this media area instead of covering the screen
var _aspect_set := false


static func play(parent: Node, rel_path: String) -> MoviePlayer:
	return play_file(parent, Assets.path(rel_path))


## Plays the movie file at `abs_path` (an imported .ogv) over `parent`.
static func play_file(parent: Node, abs_path: String) -> MoviePlayer:
	var m := MoviePlayer.new()
	parent.add_child(m)
	m._start(abs_path)
	return m


## Plays `files` one after another over `parent` (a skip skips the current one); awaitable.
static func play_all(parent: Node, files: Array) -> void:
	for f in files:
		if not is_instance_valid(parent):
			return
		await play_file(parent, str(f)).finished


## Plays `files` one after another inside `box` (a MediaBox): fitted, letterboxed, clipped; awaitable.
static func play_all_in(box: MediaBox, files: Array) -> void:
	for f in files:
		if not is_instance_valid(box):
			return
		var m := MoviePlayer.new()
		m.box = box
		box.add_child(m)
		m._start(str(f))
		await m.finished


func _start(abs_path: String) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if box:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	if not FileAccess.file_exists(abs_path):
		_done.call_deferred()
		return
	player = VideoStreamPlayer.new()
	var vs := VideoStreamTheora.new()
	vs.file = abs_path
	player.stream = vs
	player.expand = true
	if box:
		add_child(player)
		box.fit(player, 1.6)
	else:
		player.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(player)
	player.finished.connect(_done)
	player.play()


func _process(_delta: float) -> void:
	if box and player and not _aspect_set:
		var t := player.get_video_texture()
		if t and t.get_height() > 0:
			_aspect_set = true
			box.fit(player, float(t.get_width()) / t.get_height())


func _input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and not event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
		_done()


func _done() -> void:
	if is_queued_for_deletion():
		return
	finished.emit()
	queue_free()
