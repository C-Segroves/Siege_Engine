class_name MoviePlayer
extends Control
## Full-screen cutscene player for converted cinematics (any key, click, gamepad button or input
## action skips).

signal finished

var player: VideoStreamPlayer


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


func _start(abs_path: String) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	player.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(player)
	player.finished.connect(_done)
	player.play()


func _input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo() and not event is InputEventJoypadMotion:
		get_viewport().set_input_as_handled()
		_done()


func _done() -> void:
	if is_queued_for_deletion():
		return
	finished.emit()
	queue_free()
