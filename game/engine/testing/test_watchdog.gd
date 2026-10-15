extends Node
## Autoload: a test scene (res://tests/...) never hangs silently.
## - Its root node must have its script once the scene is up: a script that failed to load (a parse error, a class
##   used before `--import` registered it) leaves a bare node that would wait forever - the run quits with
##   EXIT_SCRIPT_FAILED and says why.
## - Every test run quits with EXIT_TIMEOUT after `--test-timeout=<seconds>` (user argument) or DEFAULT_TIMEOUT of
##   wall-clock time.
## Outside res://tests/ (the game, the editor, tools) it does nothing.

const TESTS_DIR := "res://tests/"
const EXIT_SCRIPT_FAILED := 2
const EXIT_TIMEOUT := 3
const DEFAULT_TIMEOUT := 3600.0
const TIMEOUT_ARG := "--test-timeout="
## Frames to wait for the main scene before judging it (it is added after the autoloads).
const SETTLE_FRAMES := 2

var _deadline_ms := -1


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var scene := get_tree().current_scene
	if scene == null or not scene.scene_file_path.begins_with(TESTS_DIR):
		set_process(false)
		return
	if scene.get_script() == null:
		printerr("TEST WATCHDOG: %s has no script (it failed to load: a parse error, or a class_name used before --import)"
			% scene.scene_file_path)
		get_tree().quit(EXIT_SCRIPT_FAILED)
		return
	_deadline_ms = Time.get_ticks_msec() + int(make_timeout_seconds() * 1000.0)


## The run's wall-clock limit (seconds): the user argument when given, else DEFAULT_TIMEOUT.
static func make_timeout_seconds() -> float:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(TIMEOUT_ARG):
			return maxf(1.0, float(a.trim_prefix(TIMEOUT_ARG)))
	return DEFAULT_TIMEOUT


func _process(_delta: float) -> void:
	if _deadline_ms >= 0 and Time.get_ticks_msec() > _deadline_ms:
		_deadline_ms = -1
		printerr("TEST WATCHDOG: %s timed out after %.0f s" % [get_tree().current_scene.scene_file_path, make_timeout_seconds()])
		get_tree().quit(EXIT_TIMEOUT)
