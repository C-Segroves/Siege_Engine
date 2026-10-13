class_name DiscImporter
extends Node
## Runs the bundled disc importer (siege-importer) that converts the user's original game discs
## (.iso) into content packs under Assets.user_packs_dir().
##
## Importer command-line contract (implemented by tools/siege_import.py, frozen to
## siege-importer.exe for releases):
##   siege-importer identify <iso>
##       -> one JSON line: {"game": "es1", "pack": "es1", "name": "Metaltech: Earthsiege",
##                          "disc": 1, "discs": 1, "needs": []}   or {"error": "..."}
##   siege-importer import --out <packs_dir> <iso> [<iso> ...]
##       -> JSON lines {"stage": "...", "progress": 0..1, "message": "..."} then
##          {"done": true, "pack": "es1"} or {"error": "..."}
##   siege-importer identify-release --pack <pack dir> <iso>
##       -> {"done": true, "pack", "release"} or {"error"}: the disc's release written into the pack's pack.json

signal progress(fraction: float, message: String)
signal finished(ok: bool, pack: String, message: String)

var _pipe: FileAccess
var _err: FileAccess
var _pid := -1
var _buf := ""
var _pack := ""
var _done := false


## The importer command: [executable, prefix args...]. Release builds ship siege-importer next to
## the app; a source checkout runs the Python tool directly.
static func command() -> Array:
	var base := OS.get_executable_path().get_base_dir()
	for p in [base.path_join("siege-importer/siege-importer.exe"), base.path_join("siege-importer.exe")]:
		if FileAccess.file_exists(p):
			return [p]
	var tool := ProjectSettings.globalize_path("res://").path_join("../tools/siege_import.py").simplify_path()
	if FileAccess.file_exists(tool):
		return ["python", tool]
	return []


static func available() -> bool:
	return not command().is_empty()


## Blocking identify (fast: only reads the ISO directory).
static func identify(iso: String) -> Dictionary:
	var cmd := command()
	if cmd.is_empty():
		return {"error": "importer not found"}
	var out := []
	var args: Array = cmd.slice(1) + ["identify", iso]
	OS.execute(cmd[0], PackedStringArray(args), out, true)
	for line in String("".join(out)).split("\n"):
		var j = JSON.parse_string(line.strip_edges())
		if j is Dictionary:
			return j
	return {"error": "importer gave no answer"}


## True while an import started by this node is running (between start and `finished`).
func is_busy() -> bool:
	return _pipe != null and not _done


## Starts an import in the background; watch `progress` / `finished`.
func start(isos: PackedStringArray) -> bool:
	return _run(["import", "--out", Assets.user_packs_dir()] + Array(isos))


## Identifies the release of an imported pack's disc (writes pack.json "release", converts nothing); `finished`.
func start_identify_release(pack: String, iso: String) -> bool:
	return _run(["identify-release", "--pack", Assets.data_root.path_join(pack), iso])


## Imports ripped soundtrack folders (MP3/FLAC/WAV per game) into the soundtrack store.
func start_soundtracks(folders: PackedStringArray) -> bool:
	return _run(["soundtracks", "--out", Assets.user_packs_dir()] + Array(folders))


func _run(cli: Array) -> bool:
	var cmd := command()
	if cmd.is_empty():
		finished.emit(false, "", "Importer not found")
		return false
	var args: Array = cmd.slice(1) + cli
	var r := OS.execute_with_pipe(cmd[0], PackedStringArray(args), false)
	if r.is_empty():
		finished.emit(false, "", "Could not start the importer")
		return false
	_pipe = r.stdio
	_err = r.stderr
	_pid = r.pid
	_done = false
	return true


func _process(_delta: float) -> void:
	if _pipe == null or _done:
		return
	var chunk := _pipe.get_buffer(65536)
	if chunk.size() > 0:
		_buf += chunk.get_string_from_utf8()
		var lines := _buf.split("\n")
		_buf = lines[lines.size() - 1]
		for i in lines.size() - 1:
			_handle(lines[i].strip_edges())
	if not OS.is_process_running(_pid) and not _done:
		if _buf.strip_edges() != "":
			_handle(_buf.strip_edges())
		if not _done:
			var err := _err.get_as_text() if _err else ""
			_finish(false, "Importer stopped unexpectedly. " + err.right(400))


func _handle(line: String) -> void:
	if line == "":
		return
	var j = JSON.parse_string(line)
	if not j is Dictionary:
		progress.emit(-1.0, line)
		return
	if j.has("error"):
		_finish(false, String(j.error))
	elif j.get("done", false):
		_pack = String(j.get("pack", ", ".join(PackedStringArray(j.get("packs", [])))))
		_finish(true, ("Identified " if j.has("release") else "Imported ") + _pack)
	else:
		progress.emit(float(j.get("progress", -1.0)), String(j.get("message", j.get("stage", ""))))


func _finish(ok: bool, msg: String) -> void:
	_done = true
	_pipe = null
	if ok:
		# refresh before announcing, so listeners see the new pack
		Assets.refresh()
		Packs.reload()
	finished.emit(ok, _pack, msg)


func cancel() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_finish(false, "Cancelled")
