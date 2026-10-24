class_name LocalServer
extends RefCounted
## "Run dedicated server...": a headless dedicated-server process (server/dedicated_server.gd) started from this installed app
## on this machine, with its output kept for the sheet's log tail. One at a time. The process is a child of this app; it
## keeps running until stopped (or until the app quits through the library's Quit).
## Its settings go through a config file in user:// (so a password never shows in a process list); the file is removed
## as soon as the server is ready or stopped.

const SERVER_SCENE := "res://server/dedicated_server.tscn"
const CONFIG_FILE := "user://local_server.json"
const MAX_LINES := 200
const READY_MARK := "SERVER READY"
const FAILED_MARK := "SERVER FAILED"
## The sheet's keys that go to the server (the rest of ServerConfig keeps its defaults).
const SHEET_KEYS := ["name", "map", "mode", "game_mode", "port", "max_players", "password", "max_bots", "master", "list_port", "bots", "ai", "lobby_seconds", "results_seconds",
	"relations", "raid_fast", "raid_empty_seconds", "raid_reset_minutes", "party_wait_seconds", "results_hold_seconds"]

static var _pid := -1
static var _stdio: FileAccess
static var _stderr: FileAccess
static var _lines: Array[String] = []
static var _partial := {}
static var _ready := false
static var _failed := false
static var _exited := false


static func is_running() -> bool:
	return _pid > 0 and OS.is_process_running(_pid)


## "stopped", "starting", "running", "failed" or "exited".
static func make_state() -> String:
	if _pid <= 0:
		return "stopped"
	if _failed:
		return "failed"
	if not OS.is_process_running(_pid):
		return "exited"
	return "running" if _ready else "starting"


static func tail(count: int) -> PackedStringArray:
	return PackedStringArray(_lines.slice(maxi(0, _lines.size() - count)))


## The arguments that run the server scene with `config_path`: the exported app runs its own pack, a project run (the editor
## binary) names the project folder.
static func make_args(config_path: String, exported: bool) -> PackedStringArray:
	var args := PackedStringArray(["--headless", "--audio-driver", "Dummy"])
	if not exported:
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array([SERVER_SCENE, "--", "--server", "--config=" + config_path, "--data_dir=" + Assets.data_root])
	return args


## Starts the server with the sheet values `sheet` (SHEET_KEYS). Returns OK or an error.
static func start(sheet: Dictionary) -> Error:
	if is_running():
		return ERR_ALREADY_IN_USE
	var cfg := {}
	for k in SHEET_KEYS:
		if sheet.has(k):
			cfg[k] = sheet[k]
	var f := FileAccess.open(CONFIG_FILE, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(cfg))
	f.close()
	var info := OS.execute_with_pipe(OS.get_executable_path(), make_args(ProjectSettings.globalize_path(CONFIG_FILE), OS.has_feature("template")), false)
	if info.is_empty():
		_remove_config()
		return FAILED
	_pid = int(info.pid)
	_stdio = info.stdio
	_stderr = info.stderr
	_lines.clear()
	_partial.clear()
	_ready = false
	_failed = false
	_exited = false
	_add_line("starting the server (process %d)" % _pid)
	return OK


## Reads what the server printed since the last call; call it every frame or so while the sheet is open.
static func poll() -> void:
	_read(_stdio, "out")
	_read(_stderr, "err")
	if _pid > 0 and not _ready and not OS.is_process_running(_pid):
		_exited = true
	if _ready or _failed or _exited:
		_remove_config()


static func stop() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	_stdio = null
	_stderr = null
	_ready = false
	_failed = false
	_exited = false
	_remove_config()


static func _read(pipe: FileAccess, key: String) -> void:
	if pipe == null or not pipe.is_open():
		return
	var chunk := pipe.get_buffer(4096)
	if chunk.is_empty():
		return
	var text: String = str(_partial.get(key, "")) + chunk.get_string_from_utf8()
	var parts := text.replace("\r", "").split("\n")
	_partial[key] = parts[parts.size() - 1]
	for i in parts.size() - 1:
		_add_line(parts[i])


static func _add_line(line: String) -> void:
	if line.strip_edges() == "":
		return
	_lines.append(line)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	if line.begins_with(READY_MARK):
		_ready = true
	elif line.begins_with(FAILED_MARK):
		_failed = true


static func _remove_config() -> void:
	if FileAccess.file_exists(CONFIG_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONFIG_FILE))
