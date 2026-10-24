class_name TestProcess
extends RefCounted
## A child Godot process of a test, started from a scene of tests/ with its standard output kept as lines (OS.execute_with_pipe).
## Only the processes a test started are ever killed.
##   var p := TestProcess.start("res://tests/dedicated_client.tscn", ["--name=DxcA"])
##   p.poll(); p.has_line("DXC DxcA LANDED"); p.kill()

var pid := -1
var lines: Array[String] = []
var _stdio: FileAccess
var _stderr: FileAccess
var _partial := {}


## Starts `scene` headless (silent) with the user arguments `user_args`; null when the process did not start.
static func start(scene: String, user_args: Array) -> TestProcess:
	var args := PackedStringArray(["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"), scene, "--"])
	args.append_array(PackedStringArray(user_args))
	var info := OS.execute_with_pipe(OS.get_executable_path(), args, false)
	if info.is_empty():
		return null
	var p := TestProcess.new()
	p.pid = int(info.pid)
	p._stdio = info.stdio
	p._stderr = info.stderr
	return p


func is_running() -> bool:
	return pid > 0 and OS.is_process_running(pid)


## Reads what the process printed since the last call.
func poll() -> void:
	_read(_stdio, "out")
	_read(_stderr, "err")


## True when a line starts with `prefix`.
func has_line(prefix: String) -> bool:
	return lines.any(func(l: String) -> bool: return l.begins_with(prefix))


## The first line starting with `prefix` ("" when none).
func find_line(prefix: String) -> String:
	for l in lines:
		if l.begins_with(prefix):
			return l
	return ""


## Every line starting with `prefix`.
func find_lines(prefix: String) -> Array:
	return lines.filter(func(l: String) -> bool: return l.begins_with(prefix))


## The first line containing `needle` and the `after` lines that follow it (an error and its backtrace); [] when none.
func find_context(needle: String, after := 8) -> Array:
	for i in lines.size():
		if needle in lines[i]:
			return lines.slice(i, i + after + 1)
	return []


func kill() -> void:
	if is_running():
		OS.kill(pid)


func _read(pipe: FileAccess, key: String) -> void:
	if pipe == null or not pipe.is_open():
		return
	var chunk := pipe.get_buffer(8192)
	if chunk.is_empty():
		return
	var text: String = str(_partial.get(key, "")) + chunk.get_string_from_utf8()
	var parts := text.replace("\r", "").split("\n")
	_partial[key] = parts[parts.size() - 1]
	for i in parts.size() - 1:
		if parts[i].strip_edges() != "":
			lines.append(parts[i])
